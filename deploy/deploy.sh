#!/usr/bin/env bash
# deploy.sh — pull images, rolling restart with health gate, rollback on failure.
# Run from repo root on the EC2 host as user prabhix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="${ENV_FILE:-deploy/.env.prod}"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
MAX_WAIT="${MAX_WAIT:-120}"

# Remembered before the env file is sourced, and reapplied after.
#
# deploy/.env.prod carries its own `TAG=latest` for Compose's variable substitution, and
# `set -a && source` below would overwrite whatever the caller asked for with it. That silently
# turned `TAG=<sha> bash deploy/deploy.sh` into a deploy of `latest` — worst of all when the
# requested tag was an older build someone was trying to roll back to.
REQUESTED_TAG="${TAG:-}"

log() { echo "[deploy $(date -Iseconds)] $*"; }

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE — copy from deploy/.env.prod.example" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a

TAG="${REQUESTED_TAG:-${TAG:-latest}}"

PREVIOUS_TAG=""
if docker inspect prabhix-backend-1 &>/dev/null 2>&1; then
  PREVIOUS_TAG=$(docker inspect prabhix-backend-1 --format='{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || echo "")
fi

rollback() {
  log "ROLLBACK: deployment failed, restoring previous stack"
  if [ -n "$PREVIOUS_TAG" ] && [ "$PREVIOUS_TAG" != "$TAG" ]; then
    TAG="$PREVIOUS_TAG" $COMPOSE --env-file "$ENV_FILE" up -d --no-build
  else
    $COMPOSE --env-file "$ENV_FILE" up -d --no-build
  fi
  exit 1
}

trap rollback ERR

# ECR tokens last twelve hours, so a deploy authenticates itself rather than depending on a login
# somebody did by hand at some point. Matched on the registry host so the Docker Hub path is
# untouched: there, REGISTRY is a namespace and `docker pull` uses the stored credential.
case "${REGISTRY:-}" in
  *.dkr.ecr.*.amazonaws.com)
    log "Authenticating to ECR ($REGISTRY)"
    aws ecr get-login-password --region "${AWS_REGION:-ap-south-1}" \
      | docker login --username AWS --password-stdin "$REGISTRY"
    ;;
esac

log "Pulling images (tag=$TAG)"
export TAG
$COMPOSE --env-file "$ENV_FILE" pull backend web admin mailroom marketing

# Both datastores are managed services in production and their containers sit behind the `never`
# profile, so neither is named here — naming a service on the command line enables its profile,
# which would start the very container the profile exists to keep down.
#
# A host with a dot in it is RDS; a bare name is the local container, which is how a developer runs
# this script against a compose-only stack.
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
case "$POSTGRES_HOST" in
  *.*) DB_IS_MANAGED=true ;;
  *)   DB_IS_MANAGED=false ;;
esac

if [ "$DB_IS_MANAGED" = false ]; then
  log "Starting local postgres"
  $COMPOSE --env-file "$ENV_FILE" up -d postgres
  log "Waiting for postgres"
  until $COMPOSE --env-file "$ENV_FILE" exec -T postgres pg_isready -U "${POSTGRES_USER:-oneops}" >/dev/null 2>&1; do
    sleep 2
  done
else
  log "Using managed database at $POSTGRES_HOST"
fi

log "Starting pgbouncer"
$COMPOSE --env-file "$ENV_FILE" up -d pgbouncer

log "Waiting for pgbouncer"
until $COMPOSE --env-file "$ENV_FILE" exec -T pgbouncer pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-oneops}" >/dev/null 2>&1; do
  sleep 2
done

# Runs a read-only query against whichever database is in use and echoes the single value.
#
# Against RDS this cannot go through `compose exec postgres`, because that container does not run.
# It borrows the pooler's network namespace instead of joining the compose network by name, so it
# does not have to guess the project-prefixed network name — and it exercises pgbouncer, which is
# the path the application actually takes.
query_db() {
  local sql="$1"
  if [ "$DB_IS_MANAGED" = false ]; then
    $COMPOSE --env-file "$ENV_FILE" exec -T postgres \
      psql -U "${POSTGRES_USER:-oneops}" -d "${POSTGRES_DB:-oneops}" -tAc "$sql" 2>/dev/null |
      tr -d '[:space:]'
  else
    docker run --rm \
      --network "container:$($COMPOSE --env-file "$ENV_FILE" ps -q pgbouncer)" \
      -e PGPASSWORD="${POSTGRES_PASSWORD:-}" \
      -e PGCONNECT_TIMEOUT=15 \
      "${PSQL_IMAGE:-postgres:18-alpine}" \
      psql -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-oneops}" -d "${POSTGRES_DB:-oneops}" \
        -tAc "$sql" 2>/dev/null |
      tr -d '[:space:]'
  fi
}

log "Deploying backend (Flyway migrations run on Boot startup)"
$COMPOSE --env-file "$ENV_FILE" up -d --no-deps backend

log "Health-gating backend readiness probe"
elapsed=0
until $COMPOSE --env-file "$ENV_FILE" exec -T backend \
  curl -fsS http://127.0.0.1:8080/actuator/health/readiness >/dev/null 2>&1; do
  sleep 3
  elapsed=$((elapsed + 3))
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    log "Backend readiness timed out after ${MAX_WAIT}s"
    rollback
  fi
done
log "Backend is ready"

# Mail that was logged instead of sent used to be recorded SENT, so nobody could tell the
# difference between delivered and discarded. The router no longer selects the logging transport
# outside dev, and V60 corrected the rows it had already written — so from here on any row at all is
# a regression, and one worth stopping a deploy for. Silent mail loss is not something a dashboard
# would surface later.
log "Asserting no mail was delivered via the logging transport"
logged_mail=$(query_db \
  "SELECT count(*) FROM mail_outbox WHERE transport_used = 'LOGGING' AND status = 'SENT'")

if [ -z "$logged_mail" ]; then
  # A failed query must not read as a pass. Empty means psql could not answer, not zero rows.
  log "Could not read mail_outbox to verify transport usage"
  rollback
fi
if [ "$logged_mail" != "0" ]; then
  log "$logged_mail outbox row(s) are marked SENT via the LOGGING transport — that mail was never delivered"
  log "Inspect with: SELECT id, to_addresses, template_key, sent_at FROM mail_outbox WHERE transport_used = 'LOGGING' AND status = 'SENT'"
  rollback
fi

log "Deploying frontends"
$COMPOSE --env-file "$ENV_FILE" up -d web admin mailroom marketing

# Recreated unconditionally, not just when the image changes. The Caddyfile arrives as a single-file
# bind mount, and a pull that rewrites it gives the file a new inode that the running container is
# not attached to — so a new site block appears on disk, `caddy reload` says it worked, and the
# hostname still fails its TLS handshake because Caddy never saw the block and never asked for a
# certificate. Recreating re-resolves the mount. It costs about a second and keeps its certificates,
# which live in the caddy_data volume.
log "Recreating caddy so a changed Caddyfile actually takes effect"
$COMPOSE --env-file "$ENV_FILE" up -d --force-recreate caddy

log "Pruning dangling images"
docker image prune -f >/dev/null 2>&1 || true

log "Deploy succeeded (tag=$TAG)"
$COMPOSE --env-file "$ENV_FILE" ps

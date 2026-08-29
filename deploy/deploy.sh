#!/usr/bin/env bash
# deploy.sh — pull images, rolling restart with health gate, rollback on failure.
# Run from repo root on the EC2 host as user prabhix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="${ENV_FILE:-deploy/.env.prod}"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
TAG="${TAG:-latest}"
MAX_WAIT="${MAX_WAIT:-120}"

log() { echo "[deploy $(date -Iseconds)] $*"; }

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE — copy from deploy/.env.prod.example" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a

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

log "Pulling images (tag=$TAG)"
export TAG
$COMPOSE --env-file "$ENV_FILE" pull backend web admin marketing

log "Starting infrastructure (postgres, pgbouncer, redis)"
$COMPOSE --env-file "$ENV_FILE" up -d postgres pgbouncer redis

log "Waiting for postgres"
until $COMPOSE --env-file "$ENV_FILE" exec -T postgres pg_isready -U "${POSTGRES_USER:-prabhix}" >/dev/null 2>&1; do
  sleep 2
done

log "Waiting for pgbouncer"
until $COMPOSE --env-file "$ENV_FILE" exec -T pgbouncer pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-prabhix}" >/dev/null 2>&1; do
  sleep 2
done

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

log "Deploying frontends"
$COMPOSE --env-file "$ENV_FILE" up -d web admin marketing

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

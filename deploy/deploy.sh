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

# Every service, the variable that pins its image, and the container the running one is in.
#
# One list rather than three named variables, because the bug this guards against was introduced by
# adding a fourth. Anything added here is remembered, exported, logged and rolled back by the code
# below without that code changing, which is the only way a per-service tag stays honest.
SERVICES="backend web admin marketing identity mailroom mobistack-backend mobistack-web app-store"
tag_var_for() {
  case "$1" in
    backend) echo BACKEND_TAG ;;
    web) echo WEB_TAG ;;
    admin) echo ADMIN_TAG ;;
    marketing) echo MARKETING_TAG ;;
    identity) echo IDENTITY_TAG ;;
    mailroom) echo MAILROOM_TAG ;;
    mobistack-backend) echo MOBISTACK_BACKEND_TAG ;;
    mobistack-web) echo MOBISTACK_WEB_TAG ;;
    app-store) echo APP_STORE_TAG ;;
  esac
}
TAG_VARS="TAG"
for s in $SERVICES; do TAG_VARS="$TAG_VARS $(tag_var_for "$s")"; done

# Remembered before the env file is sourced, and reapplied after.
#
# deploy/.env.prod carries its own `TAG=latest` for Compose's variable substitution, and
# `set -a && source` below would overwrite whatever the caller asked for with it. That silently
# turned `TAG=<sha> bash deploy/deploy.sh` into a deploy of `latest` — worst of all when the
# requested tag was an older build someone was trying to roll back to.
#
# Every one of them, not just TAG. Protecting only TAG left the rest with exactly the bug above: an
# `IDENTITY_TAG=<sha> bash deploy/deploy.sh` reported success, pulled the sha already named in the
# env file, and left the old container running — so a fix could be built, pushed, deployed and
# verified as still broken, with nothing in the output saying the new image had never been fetched.
for v in $TAG_VARS; do
  eval "REQUESTED_$v=\${$v:-}"
done

log() { echo "[deploy $(date -Iseconds)] $*"; }

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE — copy from deploy/.env.prod.example, or run deploy/env-store.sh pull" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a

# The file on disk is a cache of the Parameter Store copy when it says so. Refreshed before every
# deploy, so an edit made to the parameter is what runs and an edit made to the file alone is
# overwritten — which is the point: the parameter is the copy a rebuilt box can start from, and a
# value that exists only on this disk is a value that exists nowhere once the disk is gone.
#
# Defaults to the file, like SECRETS_SOURCE, so nothing changes until the line is flipped. No
# fallback from ssm to the stale file, for the same reason there is none for secrets.
ENV_SOURCE="${ENV_SOURCE:-file}"
if [ "$ENV_SOURCE" = "ssm" ]; then
  log "Refreshing $ENV_FILE from Parameter Store"
  if ! ENV_FILE="$ENV_FILE" bash "$SCRIPT_DIR/env-store.sh" pull; then
    log "Could not read the environment parameter — refusing to deploy from a file that may be stale"
    exit 1
  fi
  # shellcheck disable=SC1090
  set -a && source "$ENV_FILE" && set +a
fi

# Secrets come from AWS Secrets Manager, not from the env file.
#
# Defaulting to `env` is the same reasoning as AUTH_UPSTREAM in the Caddyfile: the switch ships
# before the thing it switches to, so nothing changes on the next deploy and the cutover is one line
# in deploy/.env.prod. Its rollback is the same line.
#
# There is no fallback from aws to env. A deploy that quietly reverted to a stale password in the env
# file would come up healthy on the old value and drift from the rotation that was the reason for
# moving, and nothing downstream would notice until the old password was retired.
SECRETS_SOURCE="${SECRETS_SOURCE:-env}"
if [ "$SECRETS_SOURCE" = "aws" ]; then
  log "Reading secrets from AWS Secrets Manager"
  # Command substitution swallows a non-zero exit, so the failure has to be checked separately:
  # without this, an AccessDenied would eval to nothing and the deploy would carry on to compose
  # with every password unset.
  # Through bash rather than executed directly: these files are edited on Windows and arrive without
  # an executable bit, which would fail as "Permission denied" — an error that reads like a
  # credentials problem.
  if ! secret_exports=$(bash "$SCRIPT_DIR/secrets-env.sh"); then
    log "Could not read secrets — refusing to deploy with unset passwords"
    exit 1
  fi
  eval "$secret_exports"
  unset secret_exports
else
  log "Secrets from $ENV_FILE (set SECRETS_SOURCE=aws to use Secrets Manager)"
fi

TAG="${REQUESTED_TAG:-${TAG:-latest}}"
export TAG

# The per-service ones are left unset unless something set them: compose already falls back to TAG,
# and exporting an empty value would read as a deliberate empty tag rather than as absence.
for s in $SERVICES; do
  v=$(tag_var_for "$s")
  req="REQUESTED_$v"
  if [ -n "${!req}" ]; then eval "$v=\${$req}"; fi
  if [ -n "${!v:-}" ]; then export "${v?}"; fi
done

# What each service is running right now, read off the container rather than out of a label.
#
# The label this used to read (org.opencontainers.image.revision) is only set on the backend image,
# so extending the old approach to six services would have rolled five of them back to an empty tag.
# The image reference is on every container by definition, and the text after its last colon is
# exactly the tag to go back to.
declare -A PREVIOUS_TAGS=()
for s in $SERVICES; do
  ref=$(docker inspect "prabhix-$s-1" --format='{{.Config.Image}}' 2>/dev/null || true)
  case "$ref" in
    *:*) PREVIOUS_TAGS[$s]="${ref##*:}" ;;
  esac
done

# Each service back to its own previous tag, not all of them to one.
#
# Rolling the whole stack back to a single TAG was survivable while one tag described four images
# built together. It is not now: identity and mailroom release on their own schedules, so a rollback
# that set TAG alone would leave whichever service had a tag in the env file exactly where it was —
# and the one service a failed deploy most needs reverted is the one that just changed.
rollback() {
  log "ROLLBACK: deployment failed, restoring the previous image of each service"
  local overrides=()
  for s in $SERVICES; do
    local previous="${PREVIOUS_TAGS[$s]:-}"
    [ -n "$previous" ] || continue
    local v
    v=$(tag_var_for "$s")
    overrides+=("$v=$previous")
    log "  $s -> $previous"
  done
  # env rather than exports, so the values are scoped to this one command and a caller reading the
  # environment afterwards is not told the rollback tags are what it asked for.
  #
  # The empty case is a first deploy onto a box with no containers to read a tag from. There is
  # nothing to restore, and expanding an empty array here would fail under `set -u` on older bash.
  if [ ${#overrides[@]} -gt 0 ]; then
    env "${overrides[@]}" $COMPOSE --env-file "$ENV_FILE" up -d --no-build
  else
    $COMPOSE --env-file "$ENV_FILE" up -d --no-build
  fi

  # Restoring an image does not restore the database. Flyway ran forward on the way in and has no
  # way back, so a rollback across a migration puts old code on a newer schema — and while every
  # migration was additive that was harmless enough to leave unsaid. oneOps V4 moves the mail tables
  # into their own schema, which is the first one that takes something away: the restored backend
  # comes up, passes its readiness probe, and cannot find a mail table. Say so here rather than let
  # it be discovered from the fact that no mail is going out.
  if [ -n "${SCHEMA_RANK_BEFORE:-}" ]; then
    local rank_now
    rank_now=$(query_db "SELECT coalesce(max(installed_rank)::text, '0') FROM flyway_schema_history")
    if [ -n "$rank_now" ] && [ "$rank_now" != "$SCHEMA_RANK_BEFORE" ]; then
      log "  WARNING: Flyway applied migrations during this deploy (rank $SCHEMA_RANK_BEFORE -> $rank_now)."
      log "  Those are not undone by restoring an older image. If the restored backend cannot find a"
      log "  table it expects, this is why. Fix forward — do not roll back further."
    fi
  fi
  exit 1
}

trap rollback ERR

# ECR tokens last twelve hours, so a deploy authenticates itself rather than depending on a login
# somebody did by hand at some point.
#
# The default here has to match the one in the compose files. It used to switch on REGISTRY being
# set, which was right while Docker Hub was still a possibility and is a trap now that it is not:
# compose defaults REGISTRY to the ECR host, so an unset REGISTRY still resolves to ECR at pull
# time, while this block would have skipped the login and left `docker pull` to fail with `no basic
# auth credentials` — an error that reads like a broken image name.
REGISTRY="${REGISTRY:-029096972251.dkr.ecr.ap-south-1.amazonaws.com}"
export REGISTRY

log "Authenticating to ECR ($REGISTRY)"
aws ecr get-login-password --region "${AWS_REGION:-ap-south-1}" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# Every service named with the tag it will actually be pulled at, because the ones that were not
# named are the ones that went wrong silently. A deploy that says "tag=abc123" while leaving identity
# on last week's image is a deploy whose log agrees with what the operator asked for and not with
# what happened.
pull_line=""
for s in $SERVICES; do
  v=$(tag_var_for "$s")
  pull_line="$pull_line $s=${!v:-$TAG}"
done
log "Pulling images (TAG=$TAG)$pull_line"

# Asked of compose rather than listed here, so a service that a profile has switched off is not
# pulled. The hardcoded list used to include mailroom, whose image comes from another repository and
# is tagged with that repository's commits — so `pull` looked for it at this repo's sha, found
# nothing, and failed a deploy in which the four Platform services were all present and correct.
#
# postgres, redis, caddy and pgbouncer are excluded: the first two do not run here, and the last two
# are third-party images handled further down.
ALL_SERVICES="$($COMPOSE --env-file "$ENV_FILE" config --services | sort)"
APP_SERVICES=""
for service in $ALL_SERVICES; do
  case "$service" in
    postgres|redis|pgbouncer|caddy|mailpit|prometheus|grafana) continue ;;
    *) APP_SERVICES="$APP_SERVICES $service" ;;
  esac
done
log "Application services in this deploy:$APP_SERVICES"
# shellcheck disable=SC2086
$COMPOSE --env-file "$ENV_FILE" pull $APP_SERVICES

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
# -q as well as -tA. Without it psql prints a status tag for anything that is not a SELECT, and the
# tr below welds it onto the answer: a query prefaced by SET returns "SET0" rather than "0", which
# reads as neither empty nor zero and fails whatever it is compared against.
query_db() {
  local sql="$1"
  if [ "$DB_IS_MANAGED" = false ]; then
    $COMPOSE --env-file "$ENV_FILE" exec -T postgres \
      psql -U "${POSTGRES_USER:-oneops}" -d "${POSTGRES_DB:-oneops}" -tAqc "$sql" 2>/dev/null |
      tr -d '[:space:]'
  else
    docker run --rm \
      --network "container:$($COMPOSE --env-file "$ENV_FILE" ps -q pgbouncer)" \
      -e PGPASSWORD="${POSTGRES_PASSWORD:-}" \
      -e PGCONNECT_TIMEOUT=15 \
      "${PSQL_IMAGE:-postgres:18-alpine}" \
      psql -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-oneops}" -d "${POSTGRES_DB:-oneops}" \
        -tAqc "$sql" 2>/dev/null |
      tr -d '[:space:]'
  fi
}

# Identity, before the backend and health-gated like it.
#
# It was named alongside `backend` in the frontends exclusion below, but unlike the backend nothing
# else ever deployed it — so `compose pull` fetched the new image, the old container kept running,
# and the deploy reported success. Every identity deploy was a no-op, which is a hard thing to
# notice: the log says the tag it was asked for, health stays green because the old container is
# genuinely healthy, and only the behaviour that was supposed to change gives it away.
#
# Before the backend because the backend verifies RS256 tokens against identity's JWKS. Bringing
# identity up second would leave a window where the backend is serving and the key source it depends
# on is restarting, and the sign-ins that land in it fail.
if echo "$APP_SERVICES" | grep -qw identity; then
  log "Deploying identity"
  $COMPOSE --env-file "$ENV_FILE" up -d --no-deps identity

  # On Docker's own health status rather than a curl of a known path: identity's healthcheck lives in
  # its image, so this stays correct if that check changes, and it needs no opinion about which
  # actuator endpoints are exposed without credentials.
  log "Health-gating identity"
  elapsed=0
  identity_health() {
    docker inspect "$($COMPOSE --env-file "$ENV_FILE" ps -q identity)" \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo missing
  }
  until [ "$(identity_health)" = "healthy" ]; do
    status=$(identity_health)
    # An image with no healthcheck must not hang the deploy for MAX_WAIT and then roll back a
    # perfectly good release. Nothing to wait for is not the same as failing to become ready.
    if [ "$status" = "none" ]; then
      log "Identity image declares no healthcheck; continuing without a gate"
      break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
      log "Identity did not become healthy after ${MAX_WAIT}s (last status: $status)"
      rollback
    fi
  done
  log "Identity is ready"
fi

# Read before the backend starts, so a rollback can tell whether Flyway moved the schema underneath
# the image it is restoring. Empty is fine and means "could not tell", which the rollback treats as
# nothing to warn about.
SCHEMA_RANK_BEFORE=$(query_db "SELECT coalesce(max(installed_rank)::text, '0') FROM flyway_schema_history")

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
#
# search_path rather than a qualified name, because this script and the migration that moved the
# table ship from different repositories and will not always be in step. mail_outbox is in the mail
# schema from oneOps V4 onward and in public before it; unqualified against both schemas is right
# either way. Qualifying it would have made this check fail on exactly the deploy that carries V4 —
# and an unreadable table is treated as a failure below, so the deploy would have migrated the
# schema and then rolled the backend back onto code that can no longer find it.
log "Asserting no mail was delivered via the logging transport"
logged_mail=$(query_db \
  "SET search_path = mail, public; \
   SELECT count(*) FROM mail_outbox WHERE transport_used = 'LOGGING' AND status = 'SENT'")

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

# MobiStack's backend, when its profile is on. After the platform backend rather than in parallel
# with it, because both run Flyway against the same RDS instance on startup and the connection
# budget there is small; and health-gated on its own, so a broken MobiStack image rolls MobiStack
# back without touching the four services that were fine.
if echo "$APP_SERVICES" | grep -qw mobistack-backend; then
  log "Deploying mobistack-backend (Flyway migrations run on Boot startup)"
  $COMPOSE --env-file "$ENV_FILE" up -d --no-deps mobistack-backend

  log "Health-gating mobistack-backend"
  elapsed=0
  mobistack_health() {
    docker inspect "$($COMPOSE --env-file "$ENV_FILE" ps -q mobistack-backend)" \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo missing
  }
  until [ "$(mobistack_health)" = "healthy" ]; do
    status=$(mobistack_health)
    if [ "$status" = "none" ]; then
      log "mobistack-backend image declares no healthcheck; continuing without a gate"
      break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    # Its healthcheck allows a 180s start period, so the gate is generous by the same amount.
    if [ "$elapsed" -ge $((MAX_WAIT + 180)) ]; then
      log "mobistack-backend did not become healthy after $((MAX_WAIT + 180))s (last status: $status)"
      rollback
    fi
  done
  log "mobistack-backend is ready"
fi

log "Deploying frontends"
FRONTENDS=""
for service in $APP_SERVICES; do
  case "$service" in
    # Already deployed above, each behind its own health gate.
    backend|identity|mobistack-backend) continue ;;
    *) FRONTENDS="$FRONTENDS $service" ;;
  esac
done
# shellcheck disable=SC2086
$COMPOSE --env-file "$ENV_FILE" up -d $FRONTENDS

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

log "Deploy succeeded (TAG=$TAG)$pull_line"
$COMPOSE --env-file "$ENV_FILE" ps

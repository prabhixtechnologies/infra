#!/usr/bin/env bash
set -euo pipefail
EMAIL="${ADMIN_EMAIL:-admin@prabhixtechnologies.com}"
# basic sanitize
case "$EMAIL" in
  *\'*|*\\*|*\`*|*\$*|*\;*) echo "unsafe email"; exit 1 ;;
esac

cd /opt/prabhix
if [[ -f deploy/.env.prod ]]; then
  set -a
  # shellcheck disable=SC1091
  source deploy/.env.prod
  set +a
fi

RDS_HOST="${POSTGRES_HOST:?POSTGRES_HOST missing}"
CID=$(docker ps --format '{{.ID}} {{.Names}}' | awk '/mobistack-backend/ {print $1; exit}')
[[ -n "$CID" ]] || { echo "mobistack-backend not running"; exit 1; }

USER=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CID" \
  | awk -F= '/^SPRING_DATASOURCE_USERNAME=/{print $2; exit}')
PASS=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CID" \
  | awk -F= '/^SPRING_DATASOURCE_PASSWORD=/{print $2; exit}')
USER="${USER:-mobistack}"

echo "==> Promoting $EMAIL as user=$USER on $RDS_HOST"
docker run --rm \
  -e PGPASSWORD="$PASS" \
  public.ecr.aws/docker/library/postgres:16-alpine \
  psql "host=$RDS_HOST user=$USER dbname=mobistack sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -c "UPDATE users SET system_admin = true, active = true, updated_at = now() WHERE lower(email) = lower('${EMAIL}');" \
  -c "SELECT id, full_name, email, system_admin, active FROM users WHERE lower(email) = lower('${EMAIL}');" \
  -c "SELECT count(*) AS captured_orders FROM billing_orders WHERE status = 'CAPTURED';"

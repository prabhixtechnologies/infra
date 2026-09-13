#!/usr/bin/env bash
# Force-pull and recreate platform services with specific ECR tags (skip git sync).
set -euo pipefail
cd /opt/prabhix

export TAG=latest
export BACKEND_TAG=${BACKEND_TAG:-1c1754b}
export WEB_TAG=${WEB_TAG:-1ef96b8}
export ADMIN_TAG=${ADMIN_TAG:-1ef96b8}

echo "[remote] deploying BACKEND_TAG=$BACKEND_TAG WEB_TAG=$WEB_TAG ADMIN_TAG=$ADMIN_TAG"
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin 029096972251.dkr.ecr.ap-south-1.amazonaws.com

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
ENV_FILE=deploy/.env.prod

# Export tags into the shell for compose interpolation
set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a
export TAG BACKEND_TAG WEB_TAG ADMIN_TAG

$COMPOSE --env-file "$ENV_FILE" pull backend web admin
$COMPOSE --env-file "$ENV_FILE" up -d --no-deps --force-recreate backend
echo "[remote] waiting for backend readiness..."
for i in $(seq 1 60); do
  if $COMPOSE --env-file "$ENV_FILE" exec -T backend curl -fsS http://127.0.0.1:8080/actuator/health/readiness >/dev/null 2>&1; then
    echo "[remote] backend ready"
    break
  fi
  sleep 3
done
$COMPOSE --env-file "$ENV_FILE" up -d --no-deps --force-recreate web admin
$COMPOSE --env-file "$ENV_FILE" up -d --force-recreate caddy
$COMPOSE --env-file "$ENV_FILE" ps backend web admin caddy
echo "[remote] platform deploy done"

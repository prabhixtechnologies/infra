#!/usr/bin/env bash
# Pull and restart MobiStack images without requiring git pull (host may lack GitHub deploy key).
# Compose pins via IMAGE_TAG in /opt/mobistack/.env — update that, then pull/recreate.
set -euo pipefail
cd /opt/mobistack
TAG="${MOBISTACK_TAG:-c60fb0d}"
echo "[mobi] deploying images tagged $TAG"
if grep -q '^IMAGE_TAG=' .env; then
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$TAG/" .env
else
  echo "IMAGE_TAG=$TAG" >> .env
fi
grep '^IMAGE_TAG=' .env
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin 029096972251.dkr.ecr.ap-south-1.amazonaws.com
if [[ -f docker-compose.shared.yml ]]; then
  COMPOSE="docker compose -f docker-compose.yml -f docker-compose.shared.yml"
elif [[ -f docker-compose.prod.yml ]]; then
  COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
else
  COMPOSE="docker compose -f docker-compose.yml"
fi
echo "[mobi] using: $COMPOSE"
$COMPOSE pull backend web
$COMPOSE up -d --force-recreate --no-deps backend web
$COMPOSE ps
for i in $(seq 1 60); do
  if docker exec mobistack-backend wget -q -O - http://127.0.0.1:8080/actuator/health 2>/dev/null | grep -q '"status":"UP"'; then
    echo "[mobi] backend UP"
    break
  fi
  sleep 3
done
docker inspect -f '{{.Name}} {{.Config.Image}}' mobistack-backend mobistack-web
echo "[mobi] done"

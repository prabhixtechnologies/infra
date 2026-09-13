#!/usr/bin/env bash
set -euo pipefail
cd /opt/prabhix
if [[ -f deploy/.env.prod ]]; then
  echo "==> .env.prod keys matching DB/MOBISTACK/PASS:"
  grep -E '^(MOBISTACK|DB_|POSTGRES_|SPRING_).*' deploy/.env.prod | cut -d= -f1 || true
fi
echo "==> containers:"
docker ps --format '{{.Names}}' | head -50
echo "==> env keys inside *mobistack* containers:"
for n in $(docker ps --format '{{.Names}}' | grep -i mobi || true); do
  echo "--- $n ---"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$n" | cut -d= -f1 | grep -Ei 'pass|user|url|host|db' || true
done
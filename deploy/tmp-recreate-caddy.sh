#!/usr/bin/env bash
set -uo pipefail
cd /opt/prabhix
set -a && source deploy/.env.prod && set +a
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"

echo "=== recreating caddy so it re-resolves the Caddyfile bind mount ==="
sudo -u prabhix $COMPOSE --env-file deploy/.env.prod up -d --force-recreate caddy 2>&1 | tail -5

echo
echo "=== confirming caddy now sees the admin block ==="
sudo docker exec prabhix-caddy-1 grep -c 'admin.prabhixtechnologies.com' /etc/caddy/Caddyfile

echo
echo "=== waiting for the certificate ==="
for i in $(seq 1 30); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://admin.prabhixtechnologies.com/ 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then echo "admin host answering with $code after ${i}x2s"; break; fi
  sleep 2
done

echo
echo "=== what each host now serves ==="
for h in oneops admin; do
  printf '%-8s ' "$h"
  curl -fsS --max-time 15 "https://$h.prabhixtechnologies.com/" 2>/dev/null | grep -o '<title>[^<]*</title>' || echo "(no response)"
done

echo
echo "=== certificate subject for admin ==="
echo | openssl s_client -servername admin.prabhixtechnologies.com -connect 127.0.0.1:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates 2>/dev/null || echo "(handshake failed)"

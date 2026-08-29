#!/usr/bin/env bash
set -uo pipefail

echo "=== is the admin container answering internally? ==="
sudo docker exec prabhix-caddy-1 wget -q -O - http://admin:80/ 2>&1 | grep -o '<title>[^<]*</title>' || echo "no response from admin:80"

echo
echo "=== does caddy have the admin host in its running config? ==="
sudo docker exec prabhix-caddy-1 wget -q -O - http://127.0.0.1:2019/config/apps/http/servers 2>/dev/null \
  | tr ',' '\n' | grep -i 'admin.prabhix' | head -5 || echo "admin host NOT in running config"

echo
echo "=== TLS handshake from the host itself ==="
curl -sS -o /dev/null -w 'https status=%{http_code} tls=%{ssl_verify_result}\n' --max-time 25 https://admin.prabhixtechnologies.com/ 2>&1

echo
echo "=== caddy log lines mentioning admin ==="
sudo docker logs prabhix-caddy-1 --since 10m 2>&1 | grep -i 'admin' | tail -12

#!/usr/bin/env bash
set -uo pipefail
cd /opt/prabhix

echo "=== reloading caddy so the admin site block takes effect ==="
# The Caddyfile is a bind mount, so `up -d caddy` sees no image change and leaves the running
# container alone. Without an explicit reload the new host block simply is not served.
sudo docker exec prabhix-caddy-1 caddy reload --config /etc/caddy/Caddyfile 2>&1 | tail -5

echo
echo "=== waiting for the certificate for admin.prabhixtechnologies.com ==="
for i in $(seq 1 20); do
  if sudo docker logs prabhix-caddy-1 --since 5m 2>&1 | grep -q "certificate obtained successfully.*admin.prabhix"; then
    echo "certificate obtained"
    break
  fi
  sleep 3
done
sudo docker logs prabhix-caddy-1 --since 5m 2>&1 | grep -iE "admin\.prabhix" | tail -8

echo
echo "=== did migration V59 apply? ==="
sudo docker exec prabhix-postgres-1 psql -U prabhix -d prabhix -t -c \
  "select version, description, success, installed_on from flyway_schema_history order by installed_rank desc limit 3;"

echo
echo "=== do the new columns exist on device_sessions? ==="
sudo docker exec prabhix-postgres-1 psql -U prabhix -d prabhix -t -c \
  "select column_name, data_type from information_schema.columns where table_name='device_sessions' and column_name like 'cookie%';"

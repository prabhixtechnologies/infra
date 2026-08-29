#!/usr/bin/env bash
set -uo pipefail
cd /opt/prabhix

echo "=== what caddy sees at /etc/caddy/Caddyfile ==="
sudo docker exec prabhix-caddy-1 grep -n 'prabhixtechnologies.com {' /etc/caddy/Caddyfile

echo
echo "=== the file on the host ==="
grep -n 'prabhixtechnologies.com {' deploy/Caddyfile

echo
echo "=== how it is mounted ==="
sudo docker inspect prabhix-caddy-1 --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{println}}{{end}}'

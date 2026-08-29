#!/usr/bin/env bash
set -uo pipefail
cd /opt/prabhix
sudo -u prabhix bash deploy/deploy.sh 2>&1 | tail -25
echo
echo "=== caddy: did the admin site block load and get a certificate? ==="
sudo docker logs prabhix-caddy-1 --since 3m 2>&1 | grep -iE "admin|certificate obtained|error" | tail -15

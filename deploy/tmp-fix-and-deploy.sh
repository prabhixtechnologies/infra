#!/usr/bin/env bash
set -uo pipefail
cd /opt/prabhix

echo "=== what the server changed in the Caddyfile that the repo does not have ==="
sudo -u prabhix git diff -- deploy/Caddyfile | head -60

echo
echo "=== does the repo version already contain the mail redirect? ==="
sudo -u prabhix git show origin/main:deploy/Caddyfile | grep -c 'oneops.prabhixtechnologies.com/inbox' || true

echo
echo "=== discarding the server-local Caddyfile and pulling ==="
sudo -u prabhix git checkout -- deploy/Caddyfile
sudo -u prabhix git pull --ff-only 2>&1 | tail -5
sudo -u prabhix git log --oneline -1

echo
echo "=== confirming the admin pieces arrived ==="
grep -c 'admin.prabhixtechnologies.com' deploy/Caddyfile
grep -c 'admin:' docker-compose.yml
grep -c 'prabhix-admin' docker-compose.prod.yml

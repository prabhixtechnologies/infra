#!/usr/bin/env bash
set -uo pipefail
cd /opt/prabhix

echo "=== pulling latest source ==="
sudo -u prabhix git pull --ff-only 2>&1 | tail -3

echo
echo "=== ensuring ADMIN_URL is present in .env.prod ==="
if sudo grep -q '^ADMIN_URL=' deploy/.env.prod; then
  echo "ADMIN_URL already set: $(sudo grep '^ADMIN_URL=' deploy/.env.prod)"
else
  echo "ADMIN_URL missing - adding"
  sudo sed -i '/^API_URL=/a ADMIN_URL=https://admin.prabhixtechnologies.com' deploy/.env.prod
fi

echo
echo "=== CORS_ORIGINS must include the admin host ==="
if sudo grep '^CORS_ORIGINS=' deploy/.env.prod | grep -q 'admin.prabhixtechnologies.com'; then
  echo "admin origin already allowed"
else
  echo "adding admin origin to CORS_ORIGINS"
  sudo sed -i 's|^\(CORS_ORIGINS=.*\)$|\1,https://admin.prabhixtechnologies.com|' deploy/.env.prod
fi
sudo grep '^CORS_ORIGINS=' deploy/.env.prod

echo
echo "=== session cookie settings ==="
for kv in "SESSION_COOKIE_DOMAIN=.prabhixtechnologies.com" "SESSION_COOKIE_SECURE=true"; do
  key="${kv%%=*}"
  if sudo grep -q "^${key}=" deploy/.env.prod; then
    echo "${key} already set: $(sudo grep "^${key}=" deploy/.env.prod)"
  else
    echo "adding ${kv}"
    printf '%s\n' "$kv" | sudo tee -a deploy/.env.prod >/dev/null
  fi
done

echo
echo "=== running deploy ==="
sudo -u prabhix bash deploy/deploy.sh 2>&1 | tail -30

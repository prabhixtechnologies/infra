#!/usr/bin/env bash
# Dry-run checklist for coordinated secret rotation. Does not read or write secret values.
#
#   bash deploy/check-secrets-rotation-rehearsal.sh
#
# Use with deploy/RUNBOOK-secrets-rotation.md before an approved rotation window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

fail=0
check() {
  local label=$1
  shift
  if "$@"; then
    echo "ok   $label"
  else
    echo "FAIL $label"
    fail=1
  fi
}

check "security config validator" python deploy/check-security-config.py
check "YAML duplicate-key guard" python deploy/check-yaml.py docker-compose.yml docker-compose.prod.yml
check "IAM JSON policies parse" bash -c 'for f in deploy/aws/*.json; do python3 -m json.tool "$f" >/dev/null; done'
check "rotation runbook present" test -f deploy/RUNBOOK-secrets-rotation.md
check "secrets read policy split" test -f deploy/aws/secrets-read-policy.json
check "bootstrap write policy split" test -f deploy/aws/secrets-bootstrap-policy.json
check "break-glass write policy" test -f deploy/aws/secrets-break-glass-policy.json

if [ -f deploy/.env.prod.example ]; then
  check ".env.prod.example names MAIL_LMTP_TOKEN" grep -q '^MAIL_LMTP_TOKEN=' deploy/.env.prod.example
  check ".env.prod.example names MAIL_LMTP_SIGNING_SECRET" grep -q '^MAIL_LMTP_SIGNING_SECRET=' deploy/.env.prod.example
  check ".env.prod.example names REDIS_PASSWORD" grep -q '^REDIS_PASSWORD=' deploy/.env.prod.example
else
  echo "FAIL deploy/.env.prod.example missing"
  fail=1
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "Rotation rehearsal checks passed (no secrets were read or written)."
  exit 0
fi
echo "Rotation rehearsal checks failed."
exit 1

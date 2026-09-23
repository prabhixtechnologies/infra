#!/usr/bin/env bash
# Moves the production secrets out of deploy/.env.prod and into AWS Secrets Manager.
#
# Run once, on the production host, as the prabhix user:
#
#   bash deploy/aws/secrets-bootstrap.sh           # copy into Secrets Manager and verify
#   bash deploy/aws/secrets-bootstrap.sh --prune   # ...and then strip them from .env.prod
#
# It runs on the host and not from a workstation on purpose. The values are already on this disk;
# copying them to a laptop first would put them somewhere new, which is the opposite of the point.
#
# Idempotent: creates each secret, or adds a new version if it already exists. Never prints a secret
# value — it compares checksums to prove the round-trip, so a truncated or re-encoded value is caught
# without the value appearing in a terminal or a log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$DEPLOY_DIR/.env.prod}"
REGION="${AWS_REGION:-ap-south-1}"
PREFIX="${SECRETS_PREFIX:-prabhix/prod}"
PRUNE=false
[ "${1:-}" = "--prune" ] && PRUNE=true

[ -f "$ENV_FILE" ] || { echo "No $ENV_FILE" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# Sourced rather than parsed, so the value read here is the value compose reads. A hand-rolled
# `cut -d=` parser would disagree with compose on quoting, and the one variable where that matters is
# the signing key.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Which variables belong in which secret. Grouped by what forces a rotation: the database password
# moves with RDS, the JWT secret signs out every session, the signing key invalidates tokens in
# flight. See deploy/secrets-env.sh, which reads these back.
DATABASE_VARS="POSTGRES_PASSWORD DB_PASSWORD IDENTITY_DB_PASSWORD"
JWT_VARS="JWT_SECRET"
SIGNING_VARS="IDENTITY_SIGNING_KEY"

ALL_VARS="$DATABASE_VARS $JWT_VARS $SIGNING_VARS"

sum() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# Builds a JSON object from a list of variable names, using --arg so jq does the escaping. The PEM
# has newlines and would break any string concatenation done here.
build_json() {
  local args=() filter="{}" name
  for name in $1; do
    local value="${!name-}"
    if [ -z "$value" ]; then
      echo "  $name is empty or unset in $(basename "$ENV_FILE") — refusing to store a blank secret" >&2
      return 1
    fi
    args+=(--arg "$name" "$value")
    filter="$filter | .$name = \$$name"
  done
  jq -n "${args[@]}" "$filter"
}

put_secret() {
  local name="$1"
  local vars="$2"
  local id="$PREFIX/$name"
  local payload
  echo "== $id"

  payload=$(build_json "$vars") || return 1

  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$id" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --region "$REGION" --secret-id "$id" \
      --secret-string "$payload" --query VersionId --output text | sed 's/^/  new version: /'
  else
    aws secretsmanager create-secret --region "$REGION" --name "$id" \
      --description "Prabhix production — managed by deploy/aws/secrets-bootstrap.sh" \
      --secret-string "$payload" --query ARN --output text | sed 's/^/  created: /'
  fi

  # Proves what was stored is what was read, per variable, without printing either.
  local readback name_
  readback=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$id" \
    --query SecretString --output text)
  for name_ in $vars; do
    local mine theirs
    mine=$(sum "${!name_}")
    theirs=$(sum "$(echo "$readback" | jq -r --arg k "$name_" '.[$k]')")
    if [ "$mine" = "$theirs" ]; then
      printf '  %-22s round-trip ok (%s)\n' "$name_" "$mine"
    else
      printf '  %-22s MISMATCH: local %s, stored %s\n' "$name_" "$mine" "$theirs"
      return 1
    fi
  done
}

put_secret "database"             "$DATABASE_VARS"
put_secret "jwt"                  "$JWT_VARS"
put_secret "identity-signing-key" "$SIGNING_VARS"

echo
if [ "$PRUNE" = false ]; then
  echo "Stored and verified. Nothing has been removed from $(basename "$ENV_FILE") yet."
  echo "Check that a deploy works with SECRETS_SOURCE=aws, then re-run with --prune."
  exit 0
fi

backup="$ENV_FILE.before-secrets-manager.$(date +%Y%m%d%H%M%S)"
cp -p "$ENV_FILE" "$backup"
echo "Backed up to $(basename "$backup")"

# Commented out rather than deleted, so anyone reading the file can see where the value went. A
# variable that has simply vanished is the kind of thing someone re-adds by hand at 2am.
for name in $ALL_VARS; do
  sed -i "s|^$name=.*|# $name moved to Secrets Manager ($PREFIX) — see deploy/secrets-env.sh|" "$ENV_FILE"
done

if grep -qE "^($(echo "$ALL_VARS" | tr ' ' '|'))=" "$ENV_FILE"; then
  echo "A secret is still assigned in $(basename "$ENV_FILE") — pruning did not work, restoring" >&2
  cp -p "$backup" "$ENV_FILE"
  exit 1
fi

echo "Pruned. $(basename "$ENV_FILE") now holds configuration only."
echo "Set SECRETS_SOURCE=aws in it so deploy.sh fetches them."

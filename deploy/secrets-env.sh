#!/usr/bin/env bash
# Prints `export VAR=value` lines for every production secret, read from AWS Secrets Manager.
#
#   eval "$(bash deploy/secrets-env.sh)"
#
# deploy.sh does this for you. Run it by hand before any manual `docker compose` command, because the
# compose files declare the secrets with `${VAR:?}` and will refuse to start without them — which is
# the point: a container that comes up with a blank database password is worse than one that does not
# come up at all.
#
# Prints to stdout and nothing else, so it can be eval'd. Diagnostics go to stderr.
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
PREFIX="${SECRETS_PREFIX:-prabhix/prod}"

# Three secrets rather than one, split on how each one rotates.
#
# The database password can only change in step with RDS, the JWT secret invalidates every signed-in
# session the moment it changes, and the identity signing key invalidates every RS256 token in
# flight. One blob would mean every rotation rewrites all three and any mistake takes down more than
# it had to. One secret per variable would be the other extreme: three API calls become six, for
# values that genuinely do move together.
SECRETS=(
  "database"
  "jwt"
  "identity-signing-key"
)

for name in "${SECRETS[@]}"; do
  id="$PREFIX/$name"

  if ! payload=$(aws secretsmanager get-secret-value \
        --region "$REGION" --secret-id "$id" \
        --query SecretString --output text 2>&1); then
    echo "secrets-env.sh: cannot read $id" >&2
    echo "$payload" | tail -2 >&2
    echo "" >&2
    echo "If this says AccessDenied, the instance role is missing deploy/aws/secrets-policy.json." >&2
    echo "If it says ResourceNotFound, run deploy/aws/secrets-bootstrap.sh once." >&2
    exit 1
  fi

  # @sh quotes for the shell, which matters for exactly one of these: the signing key is a PEM and
  # carries newlines. Unquoted, eval would read its second line as a command.
  if ! echo "$payload" | jq -e -r 'to_entries[] | "export \(.key)=\(.value|@sh)"' 2>/dev/null; then
    echo "secrets-env.sh: $id is not a JSON object of VAR:value pairs" >&2
    exit 1
  fi
done

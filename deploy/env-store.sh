#!/usr/bin/env bash
# env-store.sh — deploy/.env.prod in AWS Systems Manager Parameter Store.
#
#   bash deploy/env-store.sh push    # local deploy/.env.prod  -> /prabhix/prod/env
#   bash deploy/env-store.sh pull    # /prabhix/prod/env       -> local deploy/.env.prod
#   bash deploy/env-store.sh diff    # what push would change, or what pull would
#
# The environment file used to exist only on the instance's disk, which made the instance the single
# copy of the production configuration: a rebuilt box started from the .example and a memory of what
# had been filled in. Now the parameter is the copy that matters and the file on disk is a cache of
# it. deploy.sh refreshes that cache before every deploy when the file says ENV_SOURCE=ssm — the same
# arrangement as SECRETS_SOURCE, one line in the file, and the same line to reverse.
#
# Only assignments are stored. Comments and blank lines are stripped on the way up, both because the
# parameter has an 8 KB ceiling and because deploy/.env.prod.example is where the documentation lives;
# the live file carries values, and a comment in it is a note that nobody else will read. The
# secrets marked [S] in the example are not here either when SECRETS_SOURCE=aws — they are blank in
# the file and come from Secrets Manager at deploy time — so this parameter is configuration, not the
# keys to it. It is a SecureString all the same, because Razorpay and S3 credentials are in it until
# they too move.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.prod}"
REGION="${AWS_REGION:-ap-south-1}"
PARAMETER="${ENV_PARAMETER:-/prabhix/prod/env}"
LIMIT=8192

usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# `KEY=value` lines only; a `# comment` after a value is kept because Compose strips it and bash
# does not read the file as a whole — see the parsing notes at the top of the .example.
strip() {
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" || true
}

fetch() {
  aws ssm get-parameter --region "$REGION" --name "$PARAMETER" --with-decryption \
    --query Parameter.Value --output text
}

case "${1:-}" in
  push)
    [ -f "$ENV_FILE" ] || { echo "env-store.sh: no $ENV_FILE to push" >&2; exit 1; }
    body="$(strip "$ENV_FILE")"
    if ! grep -Eq '^ENV_SOURCE=ssm([[:space:]]|$)' <<<"$body"; then
      echo "env-store.sh: $ENV_FILE does not say ENV_SOURCE=ssm." >&2
      echo "Set it before pushing, or deploy.sh will keep reading the file and never this parameter," >&2
      echo "and the two will drift apart." >&2
      exit 1
    fi
    size=${#body}
    if [ "$size" -gt "$LIMIT" ]; then
      echo "env-store.sh: $size bytes of assignments; the parameter holds $LIMIT." >&2
      echo "Move a long value (the CORS list, a PEM) to Secrets Manager, or split the parameter." >&2
      exit 1
    fi
    # Advanced tier for the 8 KB ceiling (standard is 4 KB, and the file is already past it).
    # --overwrite: a parameter that exists is the normal case after the first push.
    aws ssm put-parameter --region "$REGION" --name "$PARAMETER" --type SecureString \
      --tier Advanced --overwrite --value "$body" \
      --query Version --output text | sed 's/^/pushed version /'
    echo "$size bytes, $(grep -c . <<<"$body") assignments"
    ;;

  pull)
    body="$(fetch)"
    if [ -f "$ENV_FILE" ]; then
      backup="$ENV_FILE.bak-$(date -u +%Y%m%dT%H%M%SZ)"
      cp -p "$ENV_FILE" "$backup"
      echo "previous file kept as $backup"
    fi
    # Written whole, then moved, so a deploy reading the file at the wrong moment sees the old one
    # or the new one and never half of each. 600 because it holds credentials.
    umask 077
    printf '%s\n' "$body" > "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
    echo "wrote $ENV_FILE ($(grep -c . <<<"$body") assignments)"
    ;;

  diff)
    if [ -f "$ENV_FILE" ]; then local_body="$(strip "$ENV_FILE")"; else local_body=""; fi
    remote_body="$(fetch)"
    # Keys only unless asked, because this is what a terminal history keeps.
    if [ "${2:-}" = "--values" ]; then
      diff <(sort <<<"$local_body") <(sort <<<"$remote_body") \
        && echo "identical" || true
    else
      diff <(sed 's/=.*//' <<<"$local_body" | sort) <(sed 's/=.*//' <<<"$remote_body" | sort) \
        && echo "same keys (pass --values to compare values)" || true
    fi
    ;;

  *) usage ;;
esac

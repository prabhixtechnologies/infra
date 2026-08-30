#!/usr/bin/env bash
# Creates the ECR repositories the four CI pipelines push to, and applies the shared lifecycle
# policy to each. Idempotent: re-running it repairs drift rather than failing.
#
# One repository per image, not one shared repository with prefixed tags. Lifecycle policies,
# scan-on-push results and IAM resource ARNs are all per repository, so a single shared one would
# mean "expire old images" could not distinguish the backend's history from the marketing site's,
# and the CI role could not be granted push to one image without granting it to all of them.
#
# Needs ecr:CreateRepository and ecr:PutLifecyclePolicy. The `prabhix` IAM user does not have them.
#
#   bash deploy/aws/ecr-create-repos.sh
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# prabhix-mail does not exist yet. It is created now so the IAM policies, which name it, do not have
# to be edited on the day the mail service is extracted from the backend.
REPOSITORIES=(
  prabhix-backend
  prabhix-web
  prabhix-admin
  prabhix-marketing
  prabhix-identity
  prabhix-mailroom
  prabhix-mail
  mobistack-backend
  mobistack-web
)

for repo in "${REPOSITORIES[@]}"; do
  if aws ecr describe-repositories --region "$REGION" --repository-names "$repo" >/dev/null 2>&1; then
    echo "exists   $repo"
  else
    # MUTABLE because every build re-points `latest` at a new image, which IMMUTABLE would reject.
    # The immutable identity is the short-SHA tag alongside it, and that is what a deploy pins.
    aws ecr create-repository \
      --region "$REGION" \
      --repository-name "$repo" \
      --image-tag-mutability MUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 \
      >/dev/null
    echo "created  $repo"
  fi

  # Applied every run, not only on create, so editing ecr-lifecycle.json and re-running is how the
  # policy is rolled out.
  aws ecr put-lifecycle-policy \
    --region "$REGION" \
    --repository-name "$repo" \
    --lifecycle-policy-text "file://$SCRIPT_DIR/ecr-lifecycle.json" \
    >/dev/null
  echo "         lifecycle applied"
done

echo
echo "Registry host for REGISTRY in deploy/.env.prod:"
echo "  $(aws sts get-caller-identity --query Account --output text).dkr.ecr.${REGION}.amazonaws.com"

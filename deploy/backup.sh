#!/usr/bin/env bash
# backup.sh — pg_dump to S3 with retention pruning.
# Schedule via cron: 0 3 * * * /opt/prabhix/deploy/backup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/deploy/.env.prod}"

if [ -f "$ENV_FILE" ]; then
  set -a && source "$ENV_FILE" && set +a
fi

POSTGRES_DB="${POSTGRES_DB:-oneops}"
POSTGRES_USER="${POSTGRES_USER:-oneops}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-prabhix-backups}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP_FILE="/tmp/prabhix-${POSTGRES_DB}-${TIMESTAMP}.sql.gz"
S3_KEY="postgres/${POSTGRES_DB}/${TIMESTAMP}.sql.gz"

echo "==> Dumping database $POSTGRES_DB"
docker compose -f "$REPO_ROOT/docker-compose.yml" exec -T postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl \
  | gzip > "$DUMP_FILE"

echo "==> Uploading to s3://${BACKUP_S3_BUCKET}/${S3_KEY}"
aws s3 cp "$DUMP_FILE" "s3://${BACKUP_S3_BUCKET}/${S3_KEY}" --region "$AWS_DEFAULT_REGION"

rm -f "$DUMP_FILE"

echo "==> Pruning backups older than ${RETENTION_DAYS} days"
CUTOFF="$(date -u -d "-${RETENTION_DAYS} days" +%Y-%m-%dT 2>/dev/null || date -u -v-${RETENTION_DAYS}d +%Y-%m-%dT)"
aws s3 ls "s3://${BACKUP_S3_BUCKET}/postgres/${POSTGRES_DB}/" --region "$AWS_DEFAULT_REGION" \
  | while read -r line; do
      file_date=$(echo "$line" | awk '{print $1"T"$2}')
      key=$(echo "$line" | awk '{print $4}')
      if [[ "$file_date" < "$CUTOFF" ]]; then
        echo "Deleting s3://${BACKUP_S3_BUCKET}/postgres/${POSTGRES_DB}/${key}"
        aws s3 rm "s3://${BACKUP_S3_BUCKET}/postgres/${POSTGRES_DB}/${key}" --region "$AWS_DEFAULT_REGION"
      fi
    done

echo "Backup complete: s3://${BACKUP_S3_BUCKET}/${S3_KEY}"
echo ""
echo "Restore example:"
echo "  aws s3 cp s3://${BACKUP_S3_BUCKET}/${S3_KEY} - | gunzip | \\"
echo "    docker compose -f docker-compose.yml exec -T postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}"

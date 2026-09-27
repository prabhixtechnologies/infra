# Coordinated secret rotation (no values in git)

This runbook rotates production credentials **without recording secret values** in tickets,
chat, or git. Execute only during an approved maintenance window. Rehearse first:

```bash
bash deploy/check-secrets-rotation-rehearsal.sh
```

Record **version ids**, **image tags**, **Flyway ranks**, and **recovery point ids** outside git.
Never paste secret material into logs.

## Policies

| Policy | Attach to | Purpose |
| --- | --- | --- |
| `deploy/aws/secrets-read-policy.json` | EC2 instance role (`prabhix-ec2-ecr-pull`) | Runtime deploy reads only |
| `deploy/aws/secrets-bootstrap-policy.json` | Break-glass IAM user/role during bootstrap | Initial copy + `secrets-bootstrap.sh` |
| `deploy/aws/secrets-break-glass-policy.json` | Short-lived rotation role | `PutSecretValue` during rotation |

Runtime roles must **not** carry `secretsmanager:PutSecretValue`, `CreateSecret`, or
`ListSecrets`. Attach bootstrap/break-glass policies only for the rotation window, then detach.

## Order (dependencies)

1. **Database (`POSTGRES_PASSWORD`, `DB_PASSWORD`, `IDENTITY_DB_PASSWORD`)** — rotate in RDS first,
   then update `prabhix/prod/database` in Secrets Manager, then rolling restart: `pgbouncer` →
   `identity` → `backend` → `mobistack-backend` → mail-server Postgres maps (Postfix `pgsql-*.cf`
   by hand per `RUNBOOK-rds.md`).
2. **Redis (`REDIS_PASSWORD` / Valkey auth)** — update ElastiCache auth, then `deploy/.env.prod`,
   then restart JVM services that use the deny-list and rate limits.
3. **Identity signing (`IDENTITY_SIGNING_KEY`)** — new key in `prabhix/prod/identity-signing-key`,
   deploy `identity`, verify JWKS, then deploy all products that verify tokens.
4. **Platform JWT (`JWT_SECRET`)** — update `prabhix/prod/jwt`, deploy `backend`, expect global
   refresh invalidation (~15 minutes access TTL).
5. **Internal service tokens (`MAIL_LMTP_TOKEN`, `MAIL_LMTP_SIGNING_SECRET`, BFF/internal headers)**
   — rotate token and signing secret together or signing-only if the token is unchanged; update
   backend env and Postfix/mail profile env together, restart mail transport + backend.
6. **Mail credentials** — mailbox `password_hash` rows via console API (re-encrypt at rest), SMTP
   relay passwords, SES keys; restart outbox worker path (`backend`) and Postfix smarthost env.
7. **Payment (`RAZORPAY_*`)** — dashboard new keys, update env, redeploy backend + MobiStack web if
   key id is baked into the bundle, update webhook secret in Razorpay.
8. **Cloud object storage (`S3_*`)** — rotate IAM/user keys, update env, verify uploads/downloads.
9. **Monitoring** — replace Prometheus bearer token file and Grafana admin password on the monitoring
   profile host only; never reuse `admin` / example placeholders.

## Re-encryption and data at rest

After database or application master-key rotation, run the product-specific re-encryption tasks
documented in each service runbook (mailbox passwords, encrypted columns, Identity challenges).
Complete DB password rotation **before** re-encrypting columns that use keys derived from connection
material.

## Session and client impact

Plan for **global session revocation** when rotating `JWT_SECRET`, `IDENTITY_SIGNING_KEY`, or when
following `security-remediation-release.yml` cutover. Mobile minimum-version gates may be required
before enforcing new issuers or TLS pins.

## Verification (no secret output)

- `eval "$(bash deploy/secrets-env.sh)"` then `docker compose ... config` succeeds.
- `deploy/smoke.ps1` against public hosts passes.
- Edge denies `/internal*`, MobiStack admin APIs, public inbound mail, and non-health actuator.
- Mail: outbound outbox drains; inbound LMTP succeeds from Postfix network only.
- CloudWatch/EventBridge alerts (below) show no unexpected `PutSecretValue` or SSM commands.

## CloudWatch / EventBridge alerts

See `deploy/aws/cloudwatch-alarms.md` §4 for rules on Secrets Manager writes and SSM
`SendCommand`. Subscribe the same SNS topic used for application alarms.

## Rollback

Restore previous Secrets Manager **version ids** (not values in git), redeploy prior image tags
from `deploy/security-remediation-release.yml` or last known-good tags, and restore RDS from the
recorded recovery point if database rotation failed mid-flight.

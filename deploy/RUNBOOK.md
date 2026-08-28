# Prabhix Production Runbook

Operations guide for EC2 + Docker Compose deployments.

---

## First deploy

1. **Launch EC2** — Ubuntu 24.04, t3.small or larger, Elastic IP attached.
2. **Bootstrap the host:**
   ```bash
   sudo ENABLE_MAIL_PORTS=true bash deploy/ec2-bootstrap.sh   # if using mailserver profile
   # or without mail ports for EXTERNAL_IMAP-only
   sudo bash deploy/ec2-bootstrap.sh
   ```
3. **Clone repo** to `/opt/prabhix` as user `prabhix`.
4. **Create secrets:**
   ```bash
   cp deploy/.env.prod.example deploy/.env.prod
   # Fill every [M] variable — especially JWT_SECRET, DB_PASSWORD, Razorpay, S3
   ```
5. **DNS** — point A records for `@`, `www`, `oneops`, `api` to the Elastic IP.
   Also point `app` there: Caddy serves it purely to redirect to `oneops`, so dropping the record
   would break bookmarks and the links in transactional email already sitting in people's inboxes.
   For mail: `mail` A record + MX (see [mail-server/README.md](../mail-server/README.md)).
   `mobistack` is a separate deployment — point it at that host, not this one.
6. **Deploy:**
   ```bash
   cd /opt/prabhix
   bash deploy/deploy.sh
   ```
7. **Verify from your workstation:**
   ```powershell
   .\deploy\smoke.ps1 -ApiBase "https://api.prabhixtechnologies.com" `
     -MarketingBase "https://prabhixtechnologies.com" `
     -ConsoleBase "https://oneops.prabhixtechnologies.com" `
     -OrgSlug "<your NEXT_PUBLIC_ORG_SLUG>"
   ```
8. **Configure Razorpay webhook** → `https://api.prabhixtechnologies.com/api/v1/billing/webhooks/razorpay`

---

## Routine deploy

CI pushes images to Docker Hub on merge to `main`. On the server:

```bash
cd /opt/prabhix
git pull
export TAG=<short-sha-from-ci>   # or latest
bash deploy/deploy.sh
```

Or trigger GitHub Actions **Deploy** workflow (`workflow_dispatch`) which SSHes and runs `deploy/deploy.sh`.

Flyway migrations run automatically when the new backend container starts.

---

## Rollback

If deploy fails, `deploy.sh` attempts automatic rollback. Manual rollback:

```bash
cd /opt/prabhix
export TAG=<previous-known-good-sha>
docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file deploy/.env.prod pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file deploy/.env.prod up -d
```

Database migrations are **forward-only**. If a migration broke prod, restore DB from backup
(see below) *before* rolling back to an older image that expects the previous schema.

---

## Database restore

List backups:

```bash
aws s3 ls s3://prabhix-backups/postgres/prabhix/
```

Restore (destructive — stops backend first):

```bash
cd /opt/prabhix
docker compose -f docker-compose.yml -f docker-compose.prod.yml stop backend
aws s3 cp s3://prabhix-backups/postgres/prabhix/<TIMESTAMP>.sql.gz - | gunzip | \
  docker compose -f docker-compose.yml exec -T postgres \
  psql -U prabhix -d prabhix
docker compose -f docker-compose.yml -f docker-compose.prod.yml start backend
```

---

## Rotating JWT_SECRET

1. Generate a new 64+ character random string.
2. Update `JWT_SECRET` in `deploy/.env.prod`.
3. Redeploy backend: `docker compose ... up -d backend`
4. **All existing refresh tokens invalidate** on next access-token refresh cycle (15 min TTL).
   Communicate a brief re-login window to users.

---

## Rotating Razorpay keys

1. Create new keys in Razorpay Dashboard (test → live separately).
2. Update `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET` in `deploy/.env.prod`.
3. Update webhook endpoint secret in Razorpay to match.
4. Redeploy backend.
5. Rebuild/redeploy **web** if the key id is baked into the console build (check billing integration).

---

## When mail stops flowing

### Outbound (platform → customer)

| Check | Command / action |
|---|---|
| Outbox backlog | Query `mail_outbox` for `status = 'FAILED'` or growing `PENDING` |
| Transport setting | `MAIL_TRANSPORT` in `.env.prod` matches your setup |
| SMTP connectivity | `docker compose exec backend curl -v telnet://postfix:587` |
| AWS port 25 | If direct delivery, verify unblock; else set `MAIL_RELAY_HOST` |
| Mailpit in prod? | Ensure `mailpit` profile is `never` in prod compose |

### Inbound (customer → shared inbox)

| Mode | Check |
|---|---|
| EXTERNAL_IMAP | `MAIL_IMAP_ENABLED=true`, mailbox `imap_*` fields, poll errors in logs |
| SELF_HOSTED | Mailserver profile running, MX points to Elastic IP, Postfix logs |
| LMTP push | `MAIL_LMTP_TOKEN` matches, `/api/v1/mail/inbound/lmtp` reachable from postfix network |

### Self-hosted transport

```bash
docker compose -f mail-server/docker-compose.mail.yml --profile mailserver logs postfix
docker compose -f mail-server/docker-compose.mail.yml --profile mailserver logs rspamd
```

- **550 unknown user** — mailbox not in `mail_mailboxes` or wrong `mode` on domain
- **Gmail spam folder** — fix PTR, SPF, DKIM, DMARC (mail-tester.com)
- **Deferred / timeout on outbound** — port 25 blocked → enable smarthost relay

See [mail-server/README.md](../mail-server/README.md) for full deliverability checklist.

---

## Backups

Nightly cron on EC2:

```cron
0 3 * * * /opt/prabhix/deploy/backup.sh >> /var/log/prabhix-backup.log 2>&1
```

---

## Logs

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f backend
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f caddy
```

Caddy access log (inside container): `/var/log/caddy/access.log`

---

## Support contacts

- AWS port 25: [EC2 email limitation form](https://aws.amazon.com/forms/ec2-email-limit-rds-request)
- Razorpay webhooks: Dashboard → Webhooks → verify `X-Razorpay-Signature`

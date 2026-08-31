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
5. **DNS** — point A records for `@`, `www`, `oneops`, `admin`, `api` to the Elastic IP.
   Also point `app` there: Caddy serves it purely to redirect to `oneops`, so dropping the record
   would break bookmarks and the links in transactional email already sitting in people's inboxes.
   For mail: `mail` A record + MX (see [mail-server/README.md](../../Mailroom/mail-server/README.md)).
   `mobistack` is a separate deployment — point it at that host, not this one.

   A subdomain with no record of its own does not fail loudly. The registrar's wildcard answers
   instead, so the name resolves to a parking IP and the browser reports a TLS trust error rather
   than anything DNS-shaped — and Caddy, never receiving a request, never requests a certificate.
   Confirm each name resolves to the Elastic IP:

   ```powershell
   "@","www","oneops","admin","api","app" | ForEach-Object {
     $n = if ($_ -eq "@") { "prabhixtechnologies.com" } else { "$_.prabhixtechnologies.com" }
     "$n -> $((Resolve-DnsName $n -Type A).IPAddress -join ',')"
   }
   ```
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

CI pushes images to Docker Hub on merge to `main`. Moving them onto the server is **always manual** —
no SSH private key is stored in GitHub, so nothing in Actions can reach the host. From your
workstation:

```powershell
.\deploy\deploy-remote.ps1                 # deploy :latest
.\deploy\deploy-remote.ps1 -Tag 78a9ec6    # deploy a specific tag
```

That pulls the repo on the host, runs `deploy/deploy.sh`, then runs the smoke checks. To do the same
by hand on the server:

```bash
cd /opt/prabhix
git pull
export TAG=<short-sha-from-ci>   # or latest
bash deploy/deploy.sh
```

Flyway migrations run automatically when the new backend container starts.

### If CI has not pushed the image you need

`deploy.sh` pulls from Amazon ECR, so it can only deploy what CI managed to push. When the **Docker
images** job is failing, the registry still holds the previous build and a deploy silently reinstalls
it — which is how a fixed marketing bug came back once already. Check what the registry actually has
before deploying:

```powershell
# Newest tag pushed, per image
"prabhix-backend","prabhix-web","prabhix-admin","prabhix-marketing" | ForEach-Object {
  $t = aws ecr describe-images --region ap-south-1 --repository-name "prabhix/$_" `
         --query 'sort_by(imageDetails,&imagePushedAt)[-1].[imagePushedAt,imageTags]' --output text
  "$_ last pushed: $t"
}
```

CI reaches ECR by assuming `arn:aws:iam::029096972251:role/prabhix-github-ecr-push` through GitHub's
OIDC provider, so there is no registry secret to expire or mistype. If that step fails it is a trust
policy or permissions problem on the role, not a credential on the repository.

To ship without CI, build and push the image yourself, then deploy as above:

```powershell
$registry = "029096972251.dkr.ecr.ap-south-1.amazonaws.com"
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin $registry
docker build --provenance=false --sbom=false --platform linux/amd64 `
  -t "$registry/prabhix/prabhix-marketing:latest" `
  --build-arg NEXT_PUBLIC_API_URL=https://api.prabhixtechnologies.com `
  --build-arg NEXT_PUBLIC_SITE_URL=https://prabhixtechnologies.com `
  --build-arg NEXT_PUBLIC_CONSOLE_URL=https://oneops.prabhixtechnologies.com `
  --build-arg NEXT_PUBLIC_MOBISTACK_URL=https://mobistack.prabhixtechnologies.com `
  --build-arg NEXT_PUBLIC_ORG_SLUG=<slug> --build-arg NEXT_PUBLIC_ORG_ID=<id> `
  -f marketing/Dockerfile marketing
docker push "$registry/prabhix/prabhix-marketing:latest"
```

`NEXT_PUBLIC_*` values are inlined at build time, so they must be passed as `--build-arg`. The
`--provenance=false --sbom=false` flags matter: without them Buildx emits a manifest list with an
attestation manifest, which the older Docker on the host cannot `docker load`.

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
aws s3 ls s3://prabhix-backups/postgres/oneops/
```

Restore (destructive — stops backend first):

```bash
cd /opt/prabhix
docker compose -f docker-compose.yml -f docker-compose.prod.yml stop backend
aws s3 cp s3://prabhix-backups/postgres/oneops/<TIMESTAMP>.sql.gz - | gunzip | \
  docker compose -f docker-compose.yml exec -T postgres \
  psql -U oneops -d oneops
docker compose -f docker-compose.yml -f docker-compose.prod.yml start backend
```

---

## Secrets

Five variables are secrets: `POSTGRES_PASSWORD`, `DB_PASSWORD`, `IDENTITY_DB_PASSWORD`,
`JWT_SECRET`, `IDENTITY_SIGNING_KEY`. The other 58 in `deploy/.env.prod` are hostnames, URLs and
feature flags, and stay in the file.

`SECRETS_SOURCE` in `deploy/.env.prod` decides where the five come from:

| Value | Behaviour |
| --- | --- |
| `env` | Read from `deploy/.env.prod`, as they always were |
| `aws` | Read from Secrets Manager at deploy time; the env file's copies are ignored |

Three secrets hold them, split by what forces a rotation:

| Secret | Holds |
| --- | --- |
| `prabhix/prod/database` | `POSTGRES_PASSWORD`, `DB_PASSWORD`, `IDENTITY_DB_PASSWORD` |
| `prabhix/prod/jwt` | `JWT_SECRET` |
| `prabhix/prod/identity-signing-key` | `IDENTITY_SIGNING_KEY` |

Each is a JSON object keyed by variable name, so adding a variable does not change any code.

### Moving to Secrets Manager

Needs `deploy/aws/secrets-policy.json` attached to the instance role (`prabhix-ec2-ecr-pull`) —
the instance has no Secrets Manager access by default and every step below fails with `AccessDenied`
until it does.

```bash
cd /opt/prabhix
bash deploy/aws/secrets-bootstrap.sh          # copy in, verify by checksum, change nothing
SECRETS_SOURCE=aws bash deploy/deploy.sh      # prove a deploy works reading from AWS
bash deploy/aws/secrets-bootstrap.sh --prune  # comment them out of .env.prod, keeping a backup
sed -i 's/^SECRETS_SOURCE=env/SECRETS_SOURCE=aws/' deploy/.env.prod
```

The bootstrap runs on the host, not from a workstation: the values are already on that disk, and
copying them to a laptop to upload them would put them somewhere new.

### Running compose by hand afterwards

The compose files declare the secrets as `${VAR:?}`, so once they are out of the env file a bare
`docker compose up` refuses to start rather than bringing containers up on blank passwords:

```bash
eval "$(bash deploy/secrets-env.sh)"    # then any docker compose command works
```

`ps` and `logs` need this too — they interpolate the same variables.

---

## Rotating JWT_SECRET

1. Generate a new 64+ character random string.
2. Update it:
   - `SECRETS_SOURCE=aws`: `aws secretsmanager put-secret-value --secret-id prabhix/prod/jwt
     --secret-string '{"JWT_SECRET":"..."}'`
   - `SECRETS_SOURCE=env`: edit `JWT_SECRET` in `deploy/.env.prod`
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
docker compose -f ../Mailroom/mail-server/docker-compose.mail.yml --profile mailserver logs postfix
docker compose -f ../Mailroom/mail-server/docker-compose.mail.yml --profile mailserver logs rspamd
```

- **550 unknown user** — mailbox not in `mail_mailboxes` or wrong `mode` on domain
- **Gmail spam folder** — fix PTR, SPF, DKIM, DMARC (mail-tester.com)
- **Deferred / timeout on outbound** — port 25 blocked → enable smarthost relay

See [mail-server/README.md](../../Mailroom/mail-server/README.md) for full deliverability checklist.

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

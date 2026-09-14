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
4. **Create secrets and the environment:**
   ```bash
   cp deploy/.env.prod.example deploy/.env.prod
   # Fill every [M] variable — especially JWT_SECRET, DB_PASSWORD, Razorpay, S3
   # Production keeps this file in Parameter Store. Push once, then deploy.sh pulls it:
   bash deploy/env-store.sh push
   # Fallback while SSM is not ready: set ENV_SOURCE=file in deploy/.env.prod
   ```
5. **DNS** — point A records for `@`, `www`, `oneops`, `admin`, `api` to the Elastic IP.
   Also point `app` there: Caddy serves it purely to redirect to `oneops`, so dropping the record
   would break bookmarks and the links in transactional email already sitting in people's inboxes.
   For mail: `mail` A record + MX (see [mail-server/README.md](../../Mailroom/mail-server/README.md)).
   `mobistack` and `api.mobistack` point here too — MobiStack runs on this box behind the
   `mobistack` compose profile, and both site blocks are in the `Caddyfile`.

   A subdomain with no record of its own does not fail loudly. The registrar's wildcard answers
   instead, so the name resolves to a parking IP and the browser reports a TLS trust error rather
   than anything DNS-shaped — and Caddy, never receiving a request, never requests a certificate.
   Confirm each name resolves to the Elastic IP:

   ```powershell
   "@","www","oneops","admin","api","app","mail","mobistack","store" | ForEach-Object {
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

## Moving the host onto this repository

**Do this once, before anything else here applies.** `/opt/prabhix` is a checkout of the old
`Platform` monorepo. The deploy tooling now lives here, and the reduction of `Platform` to the
marketing site is held on the branch `split/reduce-to-marketing` precisely so that the host's next
`git pull` is still a no-op until this is done.

Nothing about the running containers changes. The compose project name, the service names, the
volumes and the Caddy certificates are all identical — only the directory the files are read from
moves. Expect no downtime.

```bash
# 1. Confirm what is running, so the new checkout can be proven identical to it.
cd /opt/prabhix
sudo docker compose -f docker-compose.yml -f docker-compose.prod.yml ps --format '{{.Service}} {{.Image}}'
git rev-parse --short HEAD

# 2. Clone Infra alongside, as prabhix — not as root, or the deploy key is not the one in use.
cd /opt
git clone git@github-infra:prabhixtechnologies/Infra.git prabhix-infra

# 3. Carry across the two files that are not in git: the live secrets, and any local Caddy include.
sudo cp /opt/prabhix/deploy/.env.prod /opt/prabhix-infra/deploy/.env.prod
sudo cp -n /opt/prabhix/deploy/conf.d/*.caddyfile /opt/prabhix-infra/deploy/conf.d/ 2>/dev/null || true
sudo chown -R prabhix:prabhix /opt/prabhix-infra

# 4. Prove the new checkout resolves to the same stack before switching to it. This only reads.
cd /opt/prabhix-infra
sudo docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file deploy/.env.prod \
  config --services | sort
```

The service list must match step 1. If it does, swap the directories — the old one is kept, so the
way back is the same two `mv` commands reversed:

```bash
cd /opt
sudo mv prabhix prabhix-platform-preswitch
sudo mv prabhix-infra prabhix
cd /opt/prabhix && sudo bash deploy/deploy.sh
```

`deploy.sh` recreates Caddy from the bind-mounted `Caddyfile` at the new path, which is the only
thing in the stack that reads a file out of the checkout at runtime.

Once a deploy has succeeded from the new location, merge `split/reduce-to-marketing` in `Platform`.
Doing it in that order matters: merging first would delete `deploy/` from the directory the host is
still deploying out of.

---

## Routine deploy

CI in each repository pushes its images to ECR on merge to `main`, tagged with the commit's short
sha and `latest`. Moving them onto the server is a separate, deliberate step, and there is one way
to do it: **Actions → Deploy → Run workflow** in this repository. It runs `deploy/deploy.sh` on the
host through Systems Manager — no SSH key anywhere in GitHub — and then checks every public host
from outside. Setup is in `deploy/aws/README.md`, "Deploys from GitHub"; the admin console's
Promote button calls the same workflow.

Every service has its own tag input. The eight images are built from five repositories, so a sha
from one history does not exist in the others: fill in the tags for the services that moved, leave
the rest blank and they follow `tag`, which defaults to `latest`.

When GitHub or SSM is what is broken, the same script over SSH from a workstation that holds the key:

```powershell
.\deploy\deploy-remote.ps1                        # everything at :latest
.\deploy\deploy-remote.ps1 -Tag 78a9ec6           # everything at one tag
.\deploy\deploy-remote.ps1 -BackendTag 78a9ec6    # one service, the rest untouched
```

The switches are `-BackendTag`, `-WebTag`, `-AdminTag`, `-MarketingTag`, `-IdentityTag`,
`-MailroomTag`, `-MobiStackBackendTag` and `-MobiStackWebTag`. Or by hand on the server:

```bash
cd /opt/prabhix
git pull
export BACKEND_TAG=<short-sha-from-oneOps-ci>   # or TAG=latest for the lot
bash deploy/deploy.sh
```

Whichever way it is started, `deploy.sh` pulls only the services whose profile is on
(`COMPOSE_PROFILES` in `deploy/.env.prod` — `identity,mailroom,mobistack` in production), gates each
backend on its own health check, and rolls every service back to the image it was running if any
gate fails. Flyway migrations run when each new backend container starts.

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

`deploy.sh` reads the Flyway rank before starting the backend, and if a rollback happens after
migrations ran it says so in the log. Believe it. Every migration up to oneOps V3 was additive, so
old code on a newer schema simply ignored what it did not know about; **V4 is the first that takes
something away**. It moves the 24 mail tables out of `public` into a `mail` schema, and a backend
image from before it queries them unqualified. That backend starts, passes its readiness probe, and
answers every mail request with a missing-table error — nothing in the health gate looks at mail, so
the deploy reads as a success.

So: across V4, fix forward. Rolling the backend back is only safe together with a database restore
to a snapshot taken before the migration ran, which loses everything written since.

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

## Environment file (Parameter Store)

`ENV_SOURCE=ssm` is the production default. `deploy.sh` refreshes `deploy/.env.prod` from the
SecureString parameter `/prabhix/prod/env` before every deploy, so a rebuilt box can start from
Parameter Store rather than from a file that only existed on the old disk.

`ENV_SOURCE=file` is the fallback: the copy on disk is the only copy. Use it for first bootstrap
until `deploy/aws/env-parameter-policy.json` is on the instance role and `bash deploy/env-store.sh
push` has run once.

Do not put live secrets in git. The five `[S]` values stay in Secrets Manager when
`SECRETS_SOURCE=aws`; the rest of the file is hostnames, URLs and flags.

See `deploy/aws/README.md`, "The environment file: Parameter Store instead of one disk".

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

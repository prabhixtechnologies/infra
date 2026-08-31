# Infra

How Prabhix runs. Compose, Caddy, the deploy scripts, the databases' init SQL, and the documents
that describe the whole system. No application code lives here.

This repository was carved out of the `Platform` monorepo along with `oneOps`. Before the split, one
repository held the backend, both consoles, mobile, marketing, the mail transport and the
deployment, and a single release tag stood for all six — so shipping a one-line marketing fix
re-tagged the backend, and a rollback moved things nobody had touched.

## Layout on disk

Compose builds from sibling checkouts, so a laptop wants all of them:

```
PrabhixTechnologies/
  Infra/        this repository
  oneOps/       backend, the OneOps and Admin consoles, mobile
  Platform/     the marketing site
  Mailroom/     mail front ends, and the Postfix/Dovecot/Rspamd transport
  Identity/     sign-in
  MobiStack/    co-located, keeps its own compose
```

The production host needs only this repository. Every service there resolves an image from ECR, and
the build contexts pointing at absent siblings cost nothing.

## Running it

```bash
make up            # whole stack locally, built from the siblings
make down
make fresh         # destructive: wipes volumes first
```

Production, from a workstation:

```powershell
.\deploy\deploy-remote.ps1 -Tag 78a9ec6          # everything at one tag
.\deploy\deploy-remote.ps1 -BackendTag 78a9ec6   # one service, the rest untouched
```

## Image tags

`TAG` is the fallback. Each service also reads its own — `BACKEND_TAG`, `WEB_TAG`, `ADMIN_TAG`,
`MARKETING_TAG`, `IDENTITY_TAG`, `MAILROOM_TAG` — and a service without one follows `TAG`.

Per-service tags are not a convenience. The six images are built from five repositories, so a sha
that exists in one history does not exist in the others, and a single `TAG` would ask ECR for tags
nobody ever pushed.

The failure mode they invite is real and has happened here: an `IDENTITY_TAG` in `deploy/.env.prod`
once beat the one passed on the command line, and the deploy reported success while pulling nothing.
`deploy/deploy.sh` handles all of them through one list — remembered across sourcing the env file,
named individually in the log line, and rolled back per service to whatever tag its own container
was running.

## What is where

| Path | |
| --- | --- |
| `docker-compose.yml` | the stack; `.local.yml` and `.prod.yml` overlay it |
| `deploy/Caddyfile` | every hostname and what it proxies to |
| `deploy/deploy.sh` | runs on the host: pull, health-gate, roll back on failure |
| `deploy/aws/` | ECR, IAM, Secrets Manager, SES |
| `docker/` | Postgres init, PgBouncer, Prometheus, Grafana |
| `docs/` | architecture, strategy, operations, and the identity and mail designs |

Runbooks: [`deploy/RUNBOOK.md`](deploy/RUNBOOK.md) for a normal deploy,
[`deploy/RUNBOOK-rds.md`](deploy/RUNBOOK-rds.md) for the database,
[`deploy/RUNBOOK-mail.md`](deploy/RUNBOOK-mail.md) for deliverability.

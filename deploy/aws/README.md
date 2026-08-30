# AWS resources the deployment expects

Applied by hand today. Nothing here is created by `deploy.sh`, which only ever restarts containers
on an existing box.

Account `029096972251`, region `ap-south-1`, instance `i-05496f940af0517ae`, instance role
`PrabhixTechnologies`. The `prabhix` IAM user is denied `iam:*` and cannot create any of the roles or
policies below — those need root or an administrator.

| File | What it is for |
| --- | --- |
| `iam-platform-deployer.json` | What the `prabhix` user needs before any of the below will run |
| `ses-send-policy.json` | Outbound mail through SES, attached to the instance role |
| `ecr-create-repos.sh` | Creates the nine image repositories and applies the lifecycle policy |
| `ecr-lifecycle.json` | Expiry rules, applied to every repository |
| `github-oidc-trust.json` | Trust policy: which GitHub repositories may assume the CI role |
| `ecr-push-policy.json` | What the CI role may do — push and read, nine named repositories |
| `ecr-pull-policy.json` | What the instance role may do — read only, no push |

## `iam-platform-deployer.json` — unblocking the deployer itself

Attach this to the IAM user that runs the deployment, currently `prabhix`. Everything in it was
found missing by probing the account, not guessed from the plan: each statement corresponds to a
step in the runbooks below that returned `AccessDenied`. Until it is attached, the ECR, Valkey,
OIDC, CloudWatch and SES steps all fail at the first call.

Scoped to `ap-south-1` and to this account. The resource wildcards that remain are ones the API
requires — ECR's `GetAuthorizationToken` and the ElastiCache and Logs describes are account-level
calls that reject a resource ARN.

The IAM statements are deliberately narrow. `CreateRole` on the whole account would let this user
grant itself anything, so it is limited to the two role names the GitHub OIDC federation needs, and
`CreateOpenIDConnectProvider` is limited to GitHub's issuer.

The user cannot attach this to itself — it is denied `iam:*`, which is the thing being fixed — so it
needs root or an administrator:

```bash
aws iam create-policy \
  --policy-name PrabhixPlatformDeployer \
  --policy-document file://deploy/aws/iam-platform-deployer.json

aws iam attach-user-policy \
  --user-name prabhix \
  --policy-arn arn:aws:iam::029096972251:policy/PrabhixPlatformDeployer
```

Then confirm from the `prabhix` credentials, which should stop returning `AccessDenied`:

```bash
aws sts get-caller-identity
aws ecr describe-repositories --region ap-south-1
```

## Container images: ECR instead of Docker Hub

Two problems with Docker Hub here. The credentials are a long-lived username and token copied into
four repositories' secrets, and the images are pulled across the public internet into an instance
that is already inside AWS. ECR in `ap-south-1` removes both: CI authenticates with a token that
expires in twelve hours and is never stored, and the instance pulls over the AWS network using the
role it already has.

Both sides are switched by one variable, and clearing it is the rollback:

- **CI** — repository variable `AWS_CI_ROLE_ARN`. Set, the workflow assumes the role and pushes to
  ECR. Unset, it logs in to Docker Hub exactly as before. The four repositories can move one at a
  time.
- **The box** — `REGISTRY` in `deploy/.env.prod`. Set to the registry host, `deploy.sh`
  authenticates to ECR before pulling. Blank, it keeps using the Docker Hub namespace.

### 1. Create the repositories

```bash
bash deploy/aws/ecr-create-repos.sh
```

It prints the registry host to put in `REGISTRY`. Nine repositories rather than one shared one,
because lifecycle policies, scan results and IAM ARNs are all per repository — see the comment at
the top of the script.

### 2. Register GitHub as an OIDC provider

Once per account, not once per repository:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

No thumbprint is passed. AWS maintains the trust for this provider itself, and a pinned thumbprint
is one more thing that expires without warning.

### 3. Create the CI role

```bash
aws iam create-role \
  --role-name PrabhixGitHubActions \
  --assume-role-policy-document file://deploy/aws/github-oidc-trust.json

aws iam create-policy \
  --policy-name PrabhixEcrPush \
  --policy-document file://deploy/aws/ecr-push-policy.json

aws iam attach-role-policy \
  --role-name PrabhixGitHubActions \
  --policy-arn arn:aws:iam::029096972251:policy/PrabhixEcrPush
```

The trust policy is the security boundary, and it is worth reading rather than skimming. It allows
only the five named repositories, and within each only pushes to the default branch — the `sub`
claim for a pull request is `pull_request`, not `ref:refs/heads/main`, so a fork's PR cannot assume
this role even though its workflow runs. Widening it to `repo:prabhixtechnologies/*:*` would let any
workflow in the org, on any branch, push any image the deployment then runs.

Two things bite here. The repository name in the `sub` claim is **case-sensitive**, and GitHub sends
the canonical casing — `Identity` and `Mailroom` are capitalised, `platform` is not. And Mobistack's
default branch is `master`, not `main`. Getting either wrong produces `Not authorized to perform
sts:AssumeRoleWithWebIdentity`, which does not say which condition failed.

Then set the ARN as a repository variable — Settings → Secrets and variables → Actions → Variables
— in each of `platform`, `Identity`, `Mailroom` and `Mobistack`:

```
AWS_CI_ROLE_ARN = arn:aws:iam::029096972251:role/PrabhixGitHubActions
```

The Docker Hub secrets can stay where they are. They become unused, and they are what the rollback
falls back to.

### 4. Let the instance pull

```bash
aws iam create-policy \
  --policy-name PrabhixEcrPull \
  --policy-document file://deploy/aws/ecr-pull-policy.json

aws iam attach-role-policy \
  --role-name PrabhixTechnologies \
  --policy-arn arn:aws:iam::029096972251:policy/PrabhixEcrPull
```

Read-only on purpose: the box runs images, it does not build them. A compromised instance can pull
what it already runs and cannot replace it with something else.

`deploy.sh` runs `aws ecr get-login-password` itself when `REGISTRY` looks like an ECR host, so the
box needs the AWS CLI:

```bash
# On the box, as root.
apt-get update && apt-get install -y unzip
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip
unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install --update

# Confirm the instance role is what answers, with no keys configured anywhere.
aws sts get-caller-identity
```

Then verify a pull works before changing `REGISTRY`, so the first failure is not during a deploy:

```bash
REG=029096972251.dkr.ecr.ap-south-1.amazonaws.com
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin "$REG"
docker pull "$REG/prabhix-backend:latest"
```

### 5. Switch the box over

Set `REGISTRY` in `deploy/.env.prod` to the registry host and deploy normally. `deploy.sh` logs in
and pulls from ECR. To roll back, blank the line and deploy again — the Docker Hub images are still
there until their tags are deleted.

## Cache: ElastiCache Valkey instead of the Redis container

Two serverless caches, `prabhixtechnologies` and `mobistack`. The Prabhix services share the first
deliberately: the token deny list is one keyspace that Identity writes and every product reads, so
two caches would mean a revocation only half the fleet could see. MobiStack has no share in that and
gets its own, which also keeps an eviction or a stray `FLUSHALL` from crossing between products.

Serverless is always cluster mode and always TLS, which the `host`/`port` settings cannot express.
That is what the `valkey` Spring profile is for: `SPRING_PROFILES_ACTIVE=prod,valkey` swaps the
connection to a cluster endpoint with TLS. The endpoint goes in `REDIS_CLUSTER_NODES`:

```bash
aws elasticache describe-serverless-caches --region ap-south-1 \
  --query 'ServerlessCaches[].{Name:ServerlessCacheName,Endpoint:Endpoint.Address,Port:Endpoint.Port}' \
  --output table
```

### The security group is the access control

Serverless caches have no password by default; reachability is the whole control. The cache's
security group must allow 6379 from the instance's security group — by group, not by IP address, so
it survives the instance being replaced:

```bash
aws ec2 authorize-security-group-ingress \
  --region ap-south-1 \
  --group-id <cache-sg> \
  --protocol tcp --port 6379 \
  --source-group <instance-sg>
```

Verify before deploying, because a blocked port looks exactly like a working cache that is empty —
requests succeed, the rate limiter and the deny list simply have nothing in them:

```bash
# On the box. TLS is mandatory, so a plain redis-cli connection will hang rather than refuse.
docker run --rm redis:7-alpine redis-cli \
  -h <endpoint> -p 6379 --tls --cluster-mode ping
```

The readiness probe now includes the cache for exactly this reason: `deploy.sh` gates the rollout on
`/actuator/health/readiness`, so a deploy against an unreachable cache fails and rolls back instead
of quietly serving traffic with revocation disabled.

### What the code had to change

- `RedisPresenceStore` used `KEYS`, which is O(keyspace) and has to be fanned out to every shard.
  It uses `SCAN` now. Values are still fetched one key at a time on purpose — `MGET` needs every key
  in one hash slot, and presence keys are spread across the keyspace by design.
- `RealtimePubSubMonitor` was added. A cluster endpoint can retire the node a subscribe connection
  is pinned to without telling the client, which stops every SSE stream — chat, mail and AI — while
  the socket still looks alive and every health check stays green. It publishes a probe on a timer,
  and rebuilds the subscriptions when the probe stops coming back. Watch
  `prabhix.realtime.pubsub.recoveries`: anything above zero means this is happening.

## `ses-send-policy.json` — outbound mail through SES

The instance role `PrabhixTechnologies` (account `029096972251`, instance `i-05496f940af0517ae`)
has **no SES permissions**, so attaching this is what makes `MAIL_TRANSPORT=SES` work. `SesTransport`
authenticates through the default credential chain whenever `SES_ACCESS_KEY` is blank, so the
instance role is enough and no static keys are needed.

Neither the `prabhix` IAM user nor the instance role can run these — both are denied `iam:*` — so
they need root or an administrator.

```bash
aws iam create-policy \
  --policy-name PrabhixSesSend \
  --policy-document file://ses-send-policy.json

# Attach to the role behind the instance profile, not to the profile itself.
aws iam attach-role-policy \
  --role-name PrabhixTechnologies \
  --policy-arn arn:aws:iam::029096972251:policy/PrabhixSesSend
```

The `ses:FromAddress` condition means a leaked instance role cannot be used to send as anyone
else's domain, which is the difference between a compromised box and a compromised sender
reputation.

The policy also grants `ses:GetAccount` and `ses:GetEmailIdentity`. They are reads, and they are what
`SesTransport.healthy()` uses to report *why* mail is not leaving — an unverified domain and a
sandboxed account are otherwise indistinguishable from mail that vanishes. Omit them and the
transport still sends; `/actuator/health` just says the sender identity is unconfirmed.

## Before SES can deliver anything

Three things are independent of the code and each will silently ruin deliverability on its own.
`docs/MAIL.md` has the detail; in short:

1. **Verify the domain identity** in SES and publish the three DKIM CNAMEs it issues.

   ```bash
   aws sesv2 create-email-identity \
     --region ap-south-1 \
     --email-identity prabhixtechnologies.com \
     --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT

   # The three CNAMEs to add at GoDaddy.
   aws sesv2 get-email-identity \
     --region ap-south-1 \
     --email-identity prabhixtechnologies.com \
     --query 'DkimAttributes.Tokens'
   ```

   Each token `T` becomes a CNAME `T._domainkey` → `T.dkim.amazonses.com`.

2. **Add `include:amazonses.com` to SPF.** The live record is
   `v=spf1 include:secureserver.net -all`, and that `-all` hard-fails SES. With DMARC at
   `p=quarantine`, the mail is not marked, it is filed away unseen. The record becomes:

   ```
   v=spf1 include:secureserver.net include:amazonses.com -all
   ```

   This is additive — GoDaddy keeps working, so existing mailboxes are unaffected.

3. **Leave the SES sandbox.** In the sandbox, SES accepts mail only to verified addresses, and
   rejects everything else with `MessageRejected` — visible in `mail_outbox.last_error`.

Only steps 1 and 2 need DNS. Step 3 is a support request and usually same-day.

### Checking it worked without sending anything

`SesTransport` probes SES once a minute and says which of the three steps is outstanding. The
health endpoint is public, so it is deliberately terse (`show-details: never`) and gives only
`status`; the reason is in the log:

```bash
# On the box. Silence here means SES is usable.
docker logs prabhix-backend-1 --since 5m | grep -E 'SES cannot send|sandbox'
```

Once mail is flowing, `/actuator/health` returns 200 again. It reports `DOWN` for as long as nothing
can deliver, which is the intended meaning — see the health section of `docs/MAIL.md`. Nothing
orchestration-level reads it: the container healthcheck, `deploy.sh` and `deploy/smoke.ps1` all use
`/actuator/health/readiness`, a separate group that excludes mail.

A failed send records the same string in `mail_outbox.last_error`, so a specific message can be
diagnosed after the fact:

```sql
SELECT to_addresses, status, attempt_count, transport_used, last_error
FROM mail_outbox ORDER BY created_at DESC LIMIT 5;
```

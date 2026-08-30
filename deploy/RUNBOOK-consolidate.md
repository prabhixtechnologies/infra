# Consolidating onto one instance

Two `t3.small` instances today. The target is one `t3.medium` running both products, with the
databases on RDS, the caches on ElastiCache, and staging launched on demand instead of kept running.

| | Now | After |
| --- | --- | --- |
| `i-05496f940af0517ae` (PrabhixTechnologies) | t3.small, platform | t3.medium, both products |
| `i-069a080a3068da761` (Mobistack) | t3.small, MobiStack | terminated, Elastic IP released |
| Postgres | two containers | RDS, `ap-south-1` |
| Redis | two containers | two ElastiCache Valkey serverless caches |
| Staging | none | launched from an AMI for a rehearsal, then terminated |

`i-05496f940af0517ae` is the one to keep, and not by coin toss: it holds the Elastic IP the DNS
records point at, Caddy's certificate store, the hardened SSH config, the UFW rules, and it is the
instance the RDS security group already admits. Keeping the other one would mean rebuilding all of
that, and every minute of it would be downtime.

## The order is not negotiable

Two constraints, both discovered rather than assumed, and both of which cause an outage if the steps
are reordered.

**The databases must move before the instances merge.** The memory budget in
`docker-compose.prod.yml` allots 512m to the Postgres container. That fits on a box running one
product and does not fit once MobiStack's JVM is also there — 4 GiB does not stretch to two
Postgres containers, four JVMs and the rest. Moving MobiStack across first means both stacks
competing for memory the box does not have, resolved by the kernel OOM killer.

**MobiStack must be on the unified compose stack before Caddy proxies to it.** Both products name
services `backend`, `web` and `postgres`. Docker's embedded DNS registers the service name as a
network alias and offers no way to suppress it, so two containers on one network answering to
`backend` produce two A records for that name — measured, not assumed. Caddy would round-robin
between the two products' backends on a name its other site blocks already use, sending roughly half
of all API traffic to the wrong application. That is what the Infra repository's single compose file
fixes, by giving every service a name unique across both products.

So: **RDS first, then ElastiCache, then the resize, then the unified compose stack, then the Caddy
fragment, then terminate.**

## 1. Databases to RDS

Covered in `deploy/RUNBOOK-rds.md`. Nothing to dump or restore — the product has no live users, so
the databases are created empty and Flyway builds them from a single baseline migration per service.

Empty is not the same as usable: the migrations deliberately create no user, so the seed scripts in
step 6 of that runbook are what makes any of this signable-in to. Do not skip to the resize before
confirming you can sign in, because from then on a failure has two possible causes instead of one.

## 2. Caches to ElastiCache

Covered in `deploy/aws/README.md`. Set `REDIS_CLUSTER_NODES` and add `valkey` to
`SPRING_PROFILES_ACTIVE`, and check the security group before deploying — a blocked port is
indistinguishable from a cache that is simply empty.

## 3. Resize to t3.medium

Stop, resize, start. A stop-start moves the instance to different host hardware, which matters here:

```bash
aws ec2 stop-instances --region ap-south-1 --instance-ids i-05496f940af0517ae
aws ec2 wait instance-stopped --region ap-south-1 --instance-ids i-05496f940af0517ae

aws ec2 modify-instance-attribute --region ap-south-1 \
  --instance-id i-05496f940af0517ae \
  --instance-type '{"Value":"t3.medium"}'

aws ec2 start-instances --region ap-south-1 --instance-ids i-05496f940af0517ae
aws ec2 wait instance-running --region ap-south-1 --instance-ids i-05496f940af0517ae
```

The Elastic IP survives a stop-start, so DNS does not change. Anything on instance store does not
survive, and neither does the public IPv4 of any instance *without* an Elastic IP — which is the
trap if this is ever done to the other box.

Expect a few minutes of downtime. Containers come back on their own if Docker is enabled at boot;
confirm rather than assume:

```bash
systemctl is-enabled docker
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps
```

### 4 GiB is a fit, not a comfort

`docker-compose.prod.yml` carries a per-service memory limit, and the arithmetic is in the comment
at the top of that file. Two things follow from it:

- **Prometheus and Grafana stay off this box.** They are behind the `monitoring` compose profile,
  which nothing activates, and that is deliberate — together they want more than the headroom the
  budget leaves. Use CloudWatch for metrics that need to outlive the container.
- **The JVMs are tuned individually, not uniformly.** `MaxRAMPercentage` is 60 rather than the
  images' default 75, because metaspace, code cache and direct buffers are not counted against that
  percentage and still have to fit inside the container limit. Identity uses SerialGC — smallest
  heap, short request/response work, no SSE — while the platform backend keeps G1 because it holds
  streaming connections where a stop-the-world pause is visible to users.

One correction worth recording, because the obvious change here is the wrong one: capping Tomcat's
thread pool only helps Identity. The platform backend runs with `VIRTUAL_THREADS=true` and MobiStack
sets `spring.threads.virtual.enabled: true`, so neither holds a fixed pool of platform threads whose
stacks could be reclaimed. Identity sets neither, so its default ceiling of 200 is real, and it is
capped at 50 in `application.yml`.

## 4. Move MobiStack across

MobiStack joins the unified compose stack in the Infra repository, for the DNS reason above. Before
terminating anything, take what only exists on that box:

```bash
# The live environment file. It holds secrets that exist nowhere else.
scp mobistack:/home/ec2-user/Mobistack/.env ./mobistack.env.backup

# A snapshot of the root volume, as a way back for a week or two.
aws ec2 describe-instances --region ap-south-1 --instance-ids i-069a080a3068da761 \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' --output text

aws ec2 create-snapshot --region ap-south-1 \
  --volume-id <volume-id> \
  --description "Mobistack pre-consolidation $(date -I)"
```

Then, on the kept box, bring MobiStack up under the unified stack and check it answers on the
container names Caddy will use:

```bash
docker run --rm --network prabhix alpine:3 sh -c \
  "apk add -q curl && curl -fsS http://mobistack-backend:8080/actuator/health/readiness"
```

## 5. Point DNS and enable the Caddy fragment

Repoint `mobistack.prabhixtechnologies.com` at the kept box's Elastic IP and wait for it to
propagate. Only then enable the site block — Caddy requests a certificate for every name it is
configured to serve, so enabling it while DNS still resolves elsewhere produces failing ACME orders
on a loop against a per-name weekly rate limit:

```bash
dig +short mobistack.prabhixtechnologies.com          # must be the kept box

mv deploy/conf.d/mobistack.caddyfile.example deploy/conf.d/mobistack.caddyfile
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --force-recreate caddy
docker logs prabhix-caddy-1 --since 2m | grep -Ei 'certificate|error'
```

Rollback is the same rename in reverse, then recreate Caddy again.

## 6. Terminate and release

Only after the site has been served from the kept box long enough to trust it — a day is reasonable.

```bash
aws ec2 terminate-instances --region ap-south-1 --instance-ids i-069a080a3068da761

# The Elastic IP is billed while it is allocated and not attached to a running instance, so
# terminating without this step costs more than it did before.
aws ec2 release-address --region ap-south-1 --allocation-id eipalloc-0695e6c16e98b07d7
```

Check nothing still points at the released address before releasing it, because the address is gone
for good and cannot be reclaimed:

```bash
dig +short mobistack.prabhixtechnologies.com www.mobistack.prabhixtechnologies.com
```

## Staging, when it is needed

No permanent staging instance. It is a rehearsal environment used for a few hours a month, and
running one continuously costs the same as the production box.

Take an AMI of the kept box after the consolidation settles, and launch from it when a deploy needs
rehearsing:

```bash
aws ec2 create-image --region ap-south-1 \
  --instance-id i-05496f940af0517ae \
  --name "prabhix-staging-base-$(date -I)" \
  --no-reboot

aws ec2 run-instances --region ap-south-1 \
  --image-id <ami-id> --instance-type t3.medium \
  --key-name <key> --security-group-ids <staging-sg> \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=prabhix-staging}]'
```

`--no-reboot` keeps production up while the image is taken, at the cost of a filesystem snapshot
that is not quite crash-consistent. That is an acceptable trade for a base image whose databases are
replaced on first boot anyway.

Two things to change before it serves anything: point it at staging databases rather than
production's, and give it its own hostnames. An AMI of production is a machine configured to be
production, including which RDS instance it writes to.

Terminate it when the rehearsal is done. The whole point is that it does not exist most of the time:

```bash
aws ec2 terminate-instances --region ap-south-1 --instance-ids <staging-instance>
```

## Backups, now that data is not on the box

Postgres on RDS gets automated backups; set the retention window and be done. What is left on the
instance is Caddy's certificate store and the environment files, which are cheap to snapshot and
annoying to reconstruct. A Data Lifecycle Manager policy is less to forget than a cron job:

```bash
# The policy selects by tag, so tag the instance first or it silently backs up nothing.
aws ec2 create-tags --region ap-south-1 \
  --resources i-05496f940af0517ae \
  --tags Key=Backup,Value=daily

aws dlm create-lifecycle-policy --region ap-south-1 \
  --description "Daily root volume snapshot, 7 day retention" \
  --state ENABLED \
  --execution-role-arn arn:aws:iam::029096972251:role/AWSDataLifecycleManagerDefaultRole \
  --policy-details file://deploy/aws/dlm-daily-snapshot.json
```

`19:30` UTC is 01:00 IST — outside the window when anyone is deploying. The schedule is in UTC
regardless of how the console displays it.

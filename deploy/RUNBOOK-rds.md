# Databases to RDS

Three Postgres containers become three databases on one RDS instance, renamed on the way:

| | Now | After |
| --- | --- | --- |
| Platform | `prabhix` container, role `prabhix` | `oneops` on RDS, role `oneops` |
| Identity | `prabhix_identity` container, role `prabhix` | `identity` on RDS, role `identity` |
| MobiStack | `fixflow` container, role `fixflow` | `mobistack` on RDS, role `mobistack` |

Nothing is dumped and restored. The product has no live users, so the databases are created empty
and each service's Flyway builds its own from a single baseline migration. That is the whole reason
this step is cheap, and it stops being true the day someone signs up.

Three separate roles, not one. A database the platform's own user owns is not a boundary — the
platform's credentials would reach the users table and a stray join would work. Until now both
services connected as `prabhix`, so the separation the code claimed was a convention.

## Before you start

The three baselines are generated files, verified by replaying them into an empty database and
requiring an identical dump. If a schema change has landed since, regenerate rather than hand-edit:

```bash
python deploy/squash-baseline.py --service all
python deploy/check-baseline.py          # prints the counts the CI floors are set from
```

CI applies each baseline to an empty database on every push, so a baseline that cannot build a
database from nothing fails the build rather than the cutover. That check exists because the
migration history it replaced could not: `V64` recreated an index `V6` had already created, which no
existing database could hit because they were all long past `V6`.

## 1. The instance

One `db.t4g.micro` in `ap-south-1`, in the same VPC as `i-05496f940af0517ae`. Not publicly
accessible: the only thing that needs to reach it is the EC2 instance.

```bash
aws rds describe-db-instances --region ap-south-1 \
  --query 'DBInstances[].{Id:DBInstanceIdentifier,Endpoint:Endpoint.Address,Class:DBInstanceClass,Version:EngineVersion,Public:PubliclyAccessible,SG:VpcSecurityGroups[].VpcSecurityGroupId}'
```

Note the endpoint; every step below calls it `$RDS`. If the instance does not exist yet, create it
with `--no-publicly-accessible`, `--backup-retention-period 7`, and a `--master-username` that is
**not** any of the three application roles.

Check the security group admits 5432 from the EC2 instance's security group, not from a CIDR:

```bash
aws ec2 describe-security-groups --region ap-south-1 --group-ids <rds-sg> \
  --query 'SecurityGroups[].IpPermissions'
```

A blocked port and an empty database look identical from the application's logs, which is why this
is checked before anything is created rather than after the first boot fails.

## 2. Roles and databases

Run as the master user. It is a member of `rds_superuser` but is **not** a superuser, and that
changes one thing: it cannot hand a database to a role it is not a member of. Hence the `GRANT` on
each role before the `CREATE DATABASE`, and the `REVOKE` after — leaving the master in the role would
mean the master's credentials could read every database, which is the thing being prevented.

```bash
export RDS=<endpoint>
psql "host=$RDS user=<master> dbname=postgres sslmode=require" -v ON_ERROR_STOP=1
```

```sql
-- Passwords: generate three, store them in the .env files, do not reuse one.
CREATE ROLE oneops    LOGIN PASSWORD '<oneops-password>';
CREATE ROLE identity  LOGIN PASSWORD '<identity-password>';
CREATE ROLE mobistack LOGIN PASSWORD '<mobistack-password>';

GRANT oneops, identity, mobistack TO CURRENT_USER;

CREATE DATABASE oneops    OWNER oneops;
CREATE DATABASE identity  OWNER identity;
CREATE DATABASE mobistack OWNER mobistack;

REVOKE oneops, identity, mobistack FROM CURRENT_USER;

-- Nothing else gets to connect. RDS grants CONNECT on a new database to PUBLIC by default, so
-- without this any role on the instance can open any of the three.
REVOKE CONNECT ON DATABASE oneops    FROM PUBLIC;
REVOKE CONNECT ON DATABASE identity  FROM PUBLIC;
REVOKE CONNECT ON DATABASE mobistack FROM PUBLIC;
GRANT  CONNECT ON DATABASE oneops    TO oneops;
GRANT  CONNECT ON DATABASE identity  TO identity;
GRANT  CONNECT ON DATABASE mobistack TO mobistack;
```

No `GRANT` on the `public` schema is needed. Since Postgres 15 `public` is owned by
`pg_database_owner` rather than being writable by all, and each role owns its own database, so it
picks up `CREATE` that way. A role with only `LOGIN` on someone else's database would not.

## 3. Extensions

Per database, as the master user:

```bash
psql "host=$RDS user=<master> dbname=oneops sslmode=require" -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS citext;
      CREATE EXTENSION IF NOT EXISTS pgcrypto;
      CREATE EXTENSION IF NOT EXISTS pg_trgm;
      CREATE EXTENSION IF NOT EXISTS unaccent;'

psql "host=$RDS user=<master> dbname=identity sslmode=require" -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS citext;
      CREATE EXTENSION IF NOT EXISTS pgcrypto;'

psql "host=$RDS user=<master> dbname=mobistack sslmode=require" -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto;
      CREATE EXTENSION IF NOT EXISTS pg_trgm;
      CREATE EXTENSION IF NOT EXISTS unaccent;'
```

Strictly optional. All four are *trusted* extensions, so the owner of a database can install them
without being a superuser, and each baseline creates the ones it needs. Doing it here means the first
boot is not the thing that discovers otherwise — and repeating a `CREATE EXTENSION IF NOT EXISTS`
that has already run skips with a notice rather than failing.

## 4. Point the platform at it

In `deploy/.env.prod` on the host. `POSTGRES_HOST` is the only host to change: pgbouncer, Flyway,
identity and Dovecot all derive from it.

```bash
POSTGRES_HOST=<endpoint>
POSTGRES_DB=oneops
POSTGRES_USER=oneops
POSTGRES_PASSWORD=<oneops-password>

DB_USERNAME=oneops
DB_PASSWORD=<oneops-password>

# Flyway alone bypasses pgbouncer, so it is not covered by the pooler's TLS setting and needs its own.
FLYWAY_URL=jdbc:postgresql://<endpoint>:5432/oneops?sslmode=verify-full

IDENTITY_DB_NAME=identity
IDENTITY_DB_USER=identity
IDENTITY_DB_PASSWORD=<identity-password>
IDENTITY_DB_URL=jdbc:postgresql://<endpoint>:5432/identity?sslmode=verify-full

PGBOUNCER_SERVER_TLS_SSLMODE=verify-full
```

`verify-full` needs the RDS root certificate where the client will look for it. `require` encrypts
without checking who answered, which against a private endpoint is a defensible shortcut, but
`verify-full` costs one file:

```bash
sudo curl -fsSL -o /usr/local/share/ca-certificates/rds-ap-south-1.crt \
  https://truststore.pki.rds.amazonaws.com/ap-south-1/ap-south-1-bundle.pem
sudo update-ca-certificates
```

For the JVM, the bundle has to be in the truststore rather than the OS store — or use `require` for
the two JDBC URLs and `verify-full` only for pgbouncer, which reads the OS store. Decide, and write
down which, because a mixed setup that nobody recorded is the sort of thing that looks like a
certificate expiry two years from now.

### Postfix needs editing by hand

`postfix/pgsql-*.cf` is read by a C client that does no variable expansion, so the host is written
into all three files. Dovecot takes it from the environment; Postfix does not.

```bash
cd /opt/Mailroom/mail-server/postfix
sudo sed -i "s/^hosts = .*/hosts = <endpoint>/" pgsql-virtual-*.cf
sudo grep -H '^hosts' pgsql-virtual-*.cf
```

The `user`, `password` and `dbname` lines in those files are already `oneops`. If the password
differs from the default, set it there too — Postfix will not read it from `.env`.

## 5. First boot

```bash
cd /opt/prabhix
./deploy/deploy.sh
```

Flyway applies one migration per database. Watch for it rather than assuming:

```bash
docker compose logs backend | grep -i flyway
psql "host=$RDS user=oneops dbname=oneops sslmode=require" -tAc \
  "SELECT version, description, success FROM flyway_schema_history"
```

Then check the counts match what CI asserts — 106 tables and 60 permissions for `oneops`, 61 and 29
for `mobistack`, 9 tables for `identity`:

```bash
psql "host=$RDS user=oneops dbname=oneops sslmode=require" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'"
psql "host=$RDS user=oneops dbname=oneops sslmode=require" -tAc "SELECT count(*) FROM permissions"
```

A database with a successful history row and no tables in it would mean Flyway had baselined instead
of migrating. It should not happen — `baseline-on-migrate` is off in all three services precisely so
that a non-empty schema with no history fails loudly instead — but it is two queries to rule out.

## 6. Seed the accounts

The migrations create the schema, the permissions, the roles, the plans and the mail templates. They
deliberately do not create a user: a migration that ships a password ships it to every environment
that ever runs it. So at this point all three databases are complete and nobody can sign in to any of
them.

Four scripts, and the order matters only in that Identity and Platform must agree:

```bash
# Infra: the Prabhix organization, the first OWNER, the shared mailboxes and their aliases.
psql "host=$RDS user=oneops dbname=oneops sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -v owner_email=you@prabhixtechnologies.com \
  -v owner_password="$OWNER_PASSWORD" \
  -v owner_name='Your Name' \
  -f oneOps/deploy/seed.sql

# Identity: the same person, on the side that issues the tokens.
psql "host=$RDS user=identity dbname=identity sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -v owner_email=you@prabhixtechnologies.com \
  -v owner_password="$OWNER_PASSWORD" \
  -v owner_name='Your Name' \
  -f Identity/deploy/seed.sql

# MobiStack: the platform admin, and the shared compatibility catalog.
psql "host=$RDS user=mobistack dbname=mobistack sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -v admin_email=admin@prabhixtechnologies.com \
  -v admin_password="$ADMIN_PASSWORD" \
  -v admin_name='Your Name' \
  -f MobiStack/deploy/seed.sql
psql "host=$RDS user=mobistack dbname=mobistack sslmode=require" \
  -v ON_ERROR_STOP=1 -f MobiStack/deploy/seed-commons.sql
```

Take the passwords from the environment rather than typing them into the command, which would put
them in the shell history. All four are safe to run again; the two account scripts rotate the password
and clear a lockout on a second run, which is the way back in when nobody can sign in to fix it.

**The owner's id must match across the two databases.** Identity signs a token whose `sub` is its
`users.id`, and Platform looks up its own `users` row by that uuid — a mismatch lets the sign-in
succeed and then fails every API call with "this account is not provisioned on the platform". Both
scripts default to the same constant so that following the steps above is enough, and each refuses
rather than proceeds if the address is already seeded under a different id. Worth confirming anyway,
since it is one query and the failure is confusing to diagnose from the other end:

```bash
psql "host=$RDS user=oneops   dbname=oneops   sslmode=require" -tAc "SELECT id FROM users"
psql "host=$RDS user=identity dbname=identity sslmode=require" -tAc "SELECT id FROM users"
```

Then sign in and check that the admin console is not merely reachable but populated. `platform_admin`
on the Platform row is what gates `/api/v1/admin/**`, and the `OWNER` staff role is what lets you
grant the rest of the team theirs from the UI instead of from here.

## 7. Stop the containers

Only once the application is serving from RDS.

```bash
cd /opt/prabhix
docker compose -f docker-compose.yml -f docker-compose.prod.yml stop postgres
docker compose -f docker-compose.yml -f docker-compose.prod.yml rm -f postgres
```

The volume is left in place deliberately, as the rollback: clear `POSTGRES_HOST` and redeploy and the
old database is still there. Delete it once RDS has a backup you have restored from at least once.

That frees the 512m the container was allotted, which is what the consolidation in
`deploy/RUNBOOK-consolidate.md` needs before MobiStack's JVM arrives on the same box.

## 8. Backups

RDS takes automated backups; the retention window is the whole configuration.

```bash
aws rds modify-db-instance --region ap-south-1 \
  --db-instance-identifier <id> \
  --backup-retention-period 7 \
  --preferred-backup-window 19:30-20:00 \
  --apply-immediately
```

`19:30` UTC is 01:00 IST. The window is in UTC however the console displays it.

`deploy/backup.sh` still dumps to S3 and is worth keeping: an RDS snapshot restores to a new
instance, which is the right tool for losing an instance and the wrong one for losing a table. Point
it at the endpoint by setting `POSTGRES_HOST`, same as everything else.

## What this does not cover

- **MobiStack's own `.env`**, which has the same three variables and its own `mobistack` password.
- **Deleting the old databases.** There is nothing to delete: these are new, empty, and named
  differently, so the containers' `prabhix` and `fixflow` databases are untouched until step 7.

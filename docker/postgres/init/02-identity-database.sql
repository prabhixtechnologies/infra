-- The Prabhix Identity database and its role, created before Identity's own Flyway ever runs.
--
-- A separate database rather than a schema in this one. The point of the extraction is that the
-- platform cannot read or write the users table, and a schema in the same database would leave that
-- to convention: the platform's credentials would still reach it, so a stray join would work and
-- nobody would find out until the two services disagreed about a password.
--
-- Its own role for the same reason. A separate database the platform's own user owns is not a
-- boundary either, which is what this was until the RDS move: both services connected as the
-- platform's user, so either could read the other's tables.
--
-- Same Postgres instance, though. On one EC2 box a second instance buys isolation nobody asked for
-- and doubles what has to be backed up. On RDS both are databases on one instance, separated by
-- role rather than by hardware. See deploy/RUNBOOK-rds.md for the same steps run there, where the
-- master user is not a superuser and must be granted the role before it can hand ownership over.
--
-- Runs only on an empty data directory, which is how docker-entrypoint-initdb.d works. On a host
-- whose volume already exists, run the same statements by hand:
--   docker compose exec postgres psql -U oneops -f /docker-entrypoint-initdb.d/02-identity-database.sql

-- Local development password. Overridden everywhere else by IDENTITY_DB_PASSWORD, and there is
-- nothing in a local identity database worth protecting from someone already on the host.
SELECT 'CREATE ROLE identity LOGIN PASSWORD ''identity'''
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity') \gexec

SELECT 'CREATE DATABASE identity OWNER identity'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'identity') \gexec

\connect identity

-- Identity's V1 creates these too, but having them here means a psql session or an import script
-- sees citext from first boot rather than after the first migration.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- No GRANT on public needed. Since Postgres 15 the public schema is owned by pg_database_owner
-- rather than being writable by everyone, and the identity role is the owner of this database, so it
-- picks up CREATE that way. A role that merely has LOGIN on someone else's database would not.

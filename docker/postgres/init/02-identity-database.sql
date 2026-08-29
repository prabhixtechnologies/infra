-- The Prabhix Identity database, created before Identity's own Flyway ever runs.
--
-- A separate database rather than a schema in this one. The point of the extraction is that the
-- platform cannot read or write the users table, and a schema in the same database would leave that
-- to convention: the platform's credentials would still reach it, so a stray join would work and
-- nobody would find out until the two services disagreed about a password.
--
-- Same Postgres instance, though. On one EC2 box a second instance buys isolation nobody asked for
-- and doubles what has to be backed up. Phase 3 moves both to RDS, where they can be separate
-- instances for real.
--
-- Runs only on an empty data directory, which is how docker-entrypoint-initdb.d works. On a host
-- whose volume already exists, create it by hand:
--   docker compose exec postgres psql -U prabhix -c 'CREATE DATABASE prabhix_identity'
--   docker compose exec postgres psql -U prabhix -d prabhix_identity \
--     -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS citext;'

SELECT 'CREATE DATABASE prabhix_identity'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'prabhix_identity') \gexec

\connect prabhix_identity

-- Identity's V1 creates these too, but having them here means a psql session or an import script
-- sees citext from first boot rather than after the first migration.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

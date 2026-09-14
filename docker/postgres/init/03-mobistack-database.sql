-- The MobiStack database and its role, on the shared local instance.
--
-- Same arrangement as identity: its own database and its own login role, so the repair-shop product
-- and the platform cannot read each other's tables by accident. On RDS the same statements are run by
-- hand (deploy/RUNBOOK-rds.md); this file only runs on an empty local data directory.
--
-- Local development password. Overridden everywhere else by MOBISTACK_DB_PASSWORD.
SELECT 'CREATE ROLE mobistack LOGIN PASSWORD ''mobistack'''
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mobistack') \gexec

SELECT 'CREATE DATABASE mobistack OWNER mobistack'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'mobistack') \gexec

\connect mobistack
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

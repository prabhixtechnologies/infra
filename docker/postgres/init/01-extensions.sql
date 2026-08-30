-- Bootstrap extensions before Flyway's first migration runs.
-- V1__baseline.sql also creates these (CREATE EXTENSION IF NOT EXISTS), but this file ensures psql
-- sessions and non-Flyway tooling see them from first boot.
--
-- On RDS the equivalent is run once by the master user as part of creating each database. All four
-- are trusted extensions, so the owning role could install them itself, but doing it up front keeps
-- the first boot from being the thing that discovers otherwise. See deploy/RUNBOOK-rds.md.

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digest()
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive email/domain identity
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- fuzzy search on names and subjects
CREATE EXTENSION IF NOT EXISTS unaccent;   -- fold diacritics for search

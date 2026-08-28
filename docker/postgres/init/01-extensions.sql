-- Bootstrap extensions before Flyway's first migration runs.
-- Flyway V1__core_foundation.sql also creates these (CREATE EXTENSION IF NOT EXISTS),
-- but this file ensures psql sessions and non-Flyway tooling see them from first boot.

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digest()
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive email/domain identity
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- fuzzy search on names and subjects
CREATE EXTENSION IF NOT EXISTS unaccent;   -- fold diacritics for search

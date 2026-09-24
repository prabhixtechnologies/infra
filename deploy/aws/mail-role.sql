-- The mail service's database role.
--
-- Run against the oneops database, as its owner or the RDS master. Not a Flyway migration: roles are
-- cluster-wide, and on RDS the application user has no CREATE ROLE. Set :password before running.
--
--   psql "$OWNER_URL" -v password="$(openssl rand -base64 24)" -f deploy/aws/mail-role.sql
--
-- Two phases. Phase 1 creates the role and gives it exactly what the mail service needs; the mail
-- module keeps running inside the platform as `oneops`, so both users work and nothing changes for
-- the running system. Phase 2 hands the schema over and shuts the platform out, and belongs to the
-- deploy that moves mail into Mailroom. Do not run phase 2 early: the tables are read in-process
-- today and the platform would lose them.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- Phase 1 — the role, and the least it can be given
-- ---------------------------------------------------------------------------

-- Built as text and run, rather than a DO block: psql does not substitute :'password' inside
-- dollar quoting, so a DO block would try to execute the literal characters :'password'.
SELECT format(
    CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mail')
         THEN 'ALTER ROLE mail LOGIN PASSWORD %L'
         ELSE 'CREATE ROLE mail LOGIN PASSWORD %L'
    END, :'password') AS create_mail_role
\gset
:create_mail_role;

GRANT CONNECT ON DATABASE oneops TO mail;

-- Its own schema, including CREATE: Mailroom brings its own Flyway history and will add tables here.
GRANT USAGE, CREATE ON SCHEMA mail TO mail;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA mail TO mail;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA mail TO mail;

-- Tables Mailroom creates later, so a new migration does not need a new grant.
ALTER DEFAULT PRIVILEGES IN SCHEMA mail
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO mail;
ALTER DEFAULT PRIVILEGES IN SCHEMA mail
    GRANT USAGE, SELECT ON SEQUENCES TO mail;

-- Enough of public to resolve a name, and nothing more. USAGE on the schema grants nothing on any
-- table in it.
GRANT USAGE ON SCHEMA public TO mail;

-- oneOps V9 dropped the foreign keys from schema mail to organizations, users, teams, and
-- stored_files. Mail now stores those ids and does not need REFERENCES to insert a row. The grants
-- below stay so a later constraint can be added without a new privilege change. They still do not
-- include SELECT: the mail role cannot read those tables.
GRANT REFERENCES (id) ON public.organizations  TO mail;
GRANT REFERENCES (id) ON public.users          TO mail;
GRANT REFERENCES (id) ON public.teams          TO mail;
GRANT REFERENCES (id) ON public.stored_files   TO mail;

-- Belt and braces. PUBLIC holds no table rights by default in Postgres 15+, but this database
-- predates nothing and an inherited grant here would silently undo the paragraph above.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM mail;
GRANT REFERENCES (id) ON public.organizations  TO mail;
GRANT REFERENCES (id) ON public.users          TO mail;
GRANT REFERENCES (id) ON public.teams          TO mail;
GRANT REFERENCES (id) ON public.stored_files   TO mail;

-- Prove it rather than assume it. Mail no longer needs these grants to insert, so a missing one
-- would stay invisible until a foreign key is added back. Fail here instead.
DO $$
DECLARE
    missing text;
BEGIN
    SELECT string_agg(t, ', ') INTO missing
    FROM unnest(ARRAY['organizations', 'users', 'teams', 'stored_files']) AS t
    WHERE NOT has_column_privilege('mail', 'public.' || t, 'id', 'REFERENCES');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'mail lacks REFERENCES on: %', missing;
    END IF;

    SELECT string_agg(t, ', ') INTO missing
    FROM unnest(ARRAY['organizations', 'users', 'teams', 'stored_files']) AS t
    WHERE has_table_privilege('mail', 'public.' || t, 'SELECT');
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'mail can read platform tables it should not: %', missing;
    END IF;

    IF NOT has_schema_privilege('mail', 'mail', 'USAGE') THEN
        RAISE EXCEPTION 'mail cannot use its own schema';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Phase 2 — hand the schema over. Run with the deploy that starts Mailroom.
-- ---------------------------------------------------------------------------
--
-- Until this runs, `oneops` owns the mail tables and the in-process mail module reads them as
-- itself. After it runs, `mail` owns them and `oneops` cannot see them, so the platform must already
-- be reaching mail over HTTP through MailRequestHandler.
--
--   DO $$
--   DECLARE r record;
--   BEGIN
--       FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'mail' LOOP
--           EXECUTE format('ALTER TABLE mail.%I OWNER TO mail', r.tablename);
--       END LOOP;
--   END $$;
--   ALTER SCHEMA mail OWNER TO mail;
--   REVOKE ALL ON SCHEMA mail FROM oneops;
--   REVOKE ALL ON ALL TABLES IN SCHEMA mail FROM oneops;
--
-- The platform keeps public.mail_requests either way. It is the outbox the rest of the backend
-- writes "please send this" into, and it belongs to the side that asks for mail.

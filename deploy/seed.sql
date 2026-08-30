-- First run against an empty oneops database: the one account that can sign in, and the company's
-- own mailboxes.
--
-- Flyway's baseline creates the schema, the permissions, the six system roles, the plans, the email
-- templates and one organization row. It deliberately does not create a user, because a migration
-- that ships a password is a migration that ships a password to every environment. This does, and
-- takes it as an argument.
--
-- Safe to run twice. Every statement is guarded on a natural key, so a second run adds only what a
-- first run missed. That is the point: it is the thing that makes wiping the database cheap.
--
--   psql "host=$RDS user=oneops dbname=oneops sslmode=require" \
--     -v ON_ERROR_STOP=1 \
--     -v owner_email=you@prabhixtechnologies.com \
--     -v owner_password='<something long>' \
--     -v owner_name='Your Name' \
--     -f deploy/seed.sql
--
-- Locally:
--
--   docker compose exec -T postgres psql -U oneops -d oneops -v ON_ERROR_STOP=1 \
--     -v owner_password='dev-password' -f - < deploy/seed.sql
--
-- The password is hashed here by pgcrypto, with the same algorithm and cost the application uses:
-- bcrypt at strength 12, which produces a $2a$12$ hash that Spring's BCryptPasswordEncoder accepts.
-- Checked rather than assumed, in both directions.
--
-- It does appear in this session's psql history and in the server log if log_statement is on. For a
-- first-owner password that is about to be changed that is an acceptable trade; for anything else,
-- generate the hash elsewhere and pass owner_password_hash instead.
--
-- Run Identity/deploy/seed.sql as well, with the same owner_email and owner_password. Once auth is
-- routed to Identity it issues the token and this database only mirrors the account, matched on the
-- uuid in the token's `sub` — so both rows must carry the same id. That is why owner_id below is a
-- constant rather than a gen_random_uuid(): two scripts against two databases cannot agree on a
-- generated value, and the pair has to agree.

\set ON_ERROR_STOP on

-- admin@ rather than owner@ because this address has to receive mail. The default was owner@, which
-- is not a mailbox at the domain's mail host, so the first magic link Identity ever sent to it was
-- rejected — a seeded owner who cannot be sent a sign-in link or a password reset.
\if :{?owner_email}
\else
  \set owner_email 'admin@prabhixtechnologies.com'
\endif

-- Shared with Identity/deploy/seed.sql, which defaults to the same value. Fixed rather than random
-- so that a wipe and reseed lands on the same id and the two databases still line up; there is
-- nothing to protect by making it unpredictable, since a user id is not a credential and appears in
-- every token as `sub`. Follows the sentinel organization at ...0001.
\if :{?owner_id}
\else
  \set owner_id '00000000-0000-4000-8000-000000000002'
\endif

\if :{?owner_name}
\else
  \set owner_name 'Prabhix Owner'
\endif

\if :{?mail_domain}
\else
  \set mail_domain 'prabhixtechnologies.com'
\endif

-- RAISE rather than \quit, which takes no status and would exit 0 — a seed that silently did
-- nothing is worse than one that failed.
\if :{?owner_password}
\else
  DO $$ BEGIN
    RAISE EXCEPTION 'owner_password is required: psql -v owner_password=<value> -f deploy/seed.sql';
  END $$;
\endif

BEGIN;

-- ---------------------------------------------------------------------------------------------
-- The organization
-- ---------------------------------------------------------------------------------------------

-- The baseline seeds this row. Repeated here so the script also works against a database where it
-- was removed, and so the id below has one definition rather than being assumed.
INSERT INTO organizations (id, name, slug, status, seat_limit, timezone, locale, currency)
SELECT '00000000-0000-4000-8000-000000000001', 'Prabhix Platform', 'prabhix-platform',
       'ACTIVE', 999, 'Asia/Kolkata', 'en-IN', 'INR'
WHERE NOT EXISTS (SELECT 1 FROM organizations WHERE slug = 'prabhix-platform');

-- ---------------------------------------------------------------------------------------------
-- The first user
-- ---------------------------------------------------------------------------------------------

-- Two ways the id and the address can disagree with what is already here, and both are refused.
--
-- Neither would fail on its own. An id held by a different address fails on the primary key, which
-- reports a constraint name and no hint that owner_id is the problem. An address held by a different
-- id fails at nothing at all: the insert below is guarded on the address, so it skips, the script
-- reports success, and the owner_id that was carefully passed is quietly ignored — which is the worse
-- of the two, because it is how the platform and identity databases end up disagreeing about who the
-- owner is, and that only surfaces later as "this account is not provisioned on the platform".
--
-- The conditions are read out here and the raise is separate, rather than one PL/pgSQL block doing
-- both. psql does not substitute its variables inside dollar quotes — the body of a DO block is one
-- string literal to it — so :'owner_id' inside $$ ... $$ reaches the server verbatim and is a syntax
-- error. Hence \gset for the lookups, where substitution does happen, and constant messages inside.
SELECT
  EXISTS (
    SELECT 1 FROM users WHERE id = :'owner_id' AND email <> :'owner_email'::citext
  ) AS id_taken,
  COALESCE(
    (SELECT email::text FROM users WHERE id = :'owner_id' AND email <> :'owner_email'::citext),
    ''
  ) AS id_owner,
  EXISTS (
    SELECT 1 FROM users WHERE email = :'owner_email'::citext AND id <> :'owner_id'
  ) AS email_moved,
  COALESCE(
    (SELECT id::text FROM users WHERE email = :'owner_email'::citext AND id <> :'owner_id'),
    ''
  ) AS email_id
\gset

\if :id_taken
  \echo 'owner_id' :'owner_id' 'already belongs to' :'id_owner'
  DO $$ BEGIN
    RAISE EXCEPTION 'owner_id already belongs to a different address. Pass -v owner_id=<other>, or '
                    'use the address above as owner_email.';
  END $$;
\endif

\if :email_moved
  \echo 'This address is already seeded under id' :'email_id' 'not' :'owner_id'
  DO $$ BEGIN
    RAISE EXCEPTION 'This address already exists under a different id. Reseed with -v owner_id set '
                    'to the id above so both databases agree, or delete the row first.';
  END $$;
\endif

-- email is citext, so the unique index already treats casings as one address and there is no need
-- to lower() it here. email_verified_at is set: this address was typed by whoever ran the script,
-- and leaving it null would send a verification mail to a mail system that is not up yet.
--
-- password_hash is written even though Identity is what checks passwords once auth is routed there.
-- It is what makes the account usable before that point, and it is the way back in if Identity is
-- down: point AUTH_UPSTREAM at the backend and the local login path still works.
--
-- platform_admin is normally written only by PlatformStaffService, which derives it from staff roles.
-- Set directly here because there is no application running yet to grant the first role through, and
-- kept honest by the platform_staff_roles insert below — the flag and the role agree.
INSERT INTO users (id, email, full_name, password_hash, password_changed_at, email_verified_at,
                   status, platform_admin, default_organization_id)
SELECT :'owner_id',
       :'owner_email',
       :'owner_name',
       crypt(:'owner_password', gen_salt('bf', 12)),
       now(),
       now(),
       'ACTIVE',
       true,
       (SELECT id FROM organizations WHERE slug = 'prabhix-platform')
WHERE NOT EXISTS (SELECT 1 FROM users WHERE email = :'owner_email');

-- ---------------------------------------------------------------------------------------------
-- Membership of the platform organization, as OWNER
-- ---------------------------------------------------------------------------------------------

-- The six system roles are global: organization_id is null and every organization points at the
-- same row. So this is a lookup, not an insert.
INSERT INTO organization_memberships (organization_id, user_id, role_id, status,
                                      display_name, email, joined_at)
SELECT o.id, u.id, r.id, 'ACTIVE', u.full_name, u.email, now()
FROM organizations o
JOIN users u ON u.email = :'owner_email'
JOIN roles r ON r.role_key = 'OWNER' AND r.organization_id IS NULL
WHERE o.slug = 'prabhix-platform'
  AND NOT EXISTS (
    SELECT 1 FROM organization_memberships m
    WHERE m.organization_id = o.id AND m.user_id = u.id
  );

-- Recomputed rather than incremented, so running this twice cannot inflate it.
UPDATE organizations o
SET member_count = (
      SELECT count(*) FROM organization_memberships m
      WHERE m.organization_id = o.id AND m.status = 'ACTIVE'
    )
WHERE o.slug = 'prabhix-platform';

-- ---------------------------------------------------------------------------------------------
-- Platform staff
-- ---------------------------------------------------------------------------------------------

-- Separate from organization membership on purpose. Being OWNER of an organization says what you
-- can do inside that tenant; a staff role says what you can do to the platform — read another
-- tenant's logs, impersonate a customer, change someone's billing. The admin console gates on
-- these, so without a row here the console is empty however many organizations you own.
--
-- OWNER is the only staff role that can grant staff roles, which is why it is the one seeded: every
-- other role can then be handed out through the UI rather than through SQL.
--
-- id has no default on this table, unlike most, so it is supplied.
INSERT INTO platform_staff_roles (id, user_id, role, granted_at, note)
SELECT gen_random_uuid(), u.id, 'OWNER', now(), 'Seeded by deploy/seed.sql on first setup'
FROM users u
WHERE u.email = :'owner_email'
  AND NOT EXISTS (
    SELECT 1 FROM platform_staff_roles s
    WHERE s.user_id = u.id AND s.role = 'OWNER' AND s.revoked_at IS NULL
  );

-- ---------------------------------------------------------------------------------------------
-- The subscription
-- ---------------------------------------------------------------------------------------------

-- Every feature in the product is gated on a live subscription row: EntitlementService reaches the
-- plan through it, and with no row each lookup raises SUBSCRIPTION_INACTIVE, which is a 402. In the
-- running application the row is created by TrialSubscriptionService, on the OrganizationCreated
-- event — which this script cannot publish, because it writes the organization with SQL. So a
-- seeded database produced an organization nobody could use: signing in worked, and then chat, mail
-- and AI all answered 402. Production was in exactly that state, and it showed on the public site,
-- where the marketing chat widget could not open a conversation.
--
-- enterprise-custom rather than the starter plan a trial would have picked, for two reasons. This
-- is the company's own tenant, so a subscription that lapses in a fortnight is wrong. And starter
-- allows one mailbox and one mail domain, while the sections below create several of each: the
-- inserts would go in regardless, being SQL, and the limit would then be discovered on the day
-- somebody tried to add one through the console.
--
-- ACTIVE with no trial_ends_at, at whatever the plan charges, which for this plan is nothing.
-- current_period_end is far out rather than empty because the column is NOT NULL. next_billing_at
-- is left null on purpose: the renewal job selects on IS NOT NULL, so null is how a subscription
-- says it never renews, and a date would eventually mean an invoice for a plan that costs nothing.
INSERT INTO billing_subscriptions (organization_id, plan_id, status, seats,
                                   current_period_start, current_period_end, next_billing_at,
                                   locked_amount_paise, locked_per_seat_paise, currency)
SELECT o.id, p.id, 'ACTIVE', p.included_seats,
       now(), now() + interval '100 years', NULL,
       p.amount_paise, p.per_seat_paise, o.currency
FROM organizations o
JOIN billing_plans p ON p.plan_key = 'enterprise-custom'
WHERE o.slug = 'prabhix-platform'
  AND NOT EXISTS (
    SELECT 1 FROM billing_subscriptions s
    WHERE s.organization_id = o.id
      AND s.status IN ('TRIALING', 'ACTIVE', 'PAST_DUE', 'PAUSED')
  );

-- seat_limit was set to 999 when the organization was inserted, which is a guess made before the
-- plan was known. Membership is checked against the subscription's seats, so leaving the two
-- disagreeing means the number shown in the console is not the number enforced.
UPDATE organizations o
SET seat_limit = s.seats
FROM billing_subscriptions s
WHERE s.organization_id = o.id
  AND o.slug = 'prabhix-platform'
  AND s.status IN ('TRIALING', 'ACTIVE', 'PAST_DUE', 'PAUSED')
  AND o.seat_limit <> s.seats;

-- ---------------------------------------------------------------------------------------------
-- The mail domain
-- ---------------------------------------------------------------------------------------------

-- Left PENDING deliberately. Status is meant to record what DNS actually says, and the application
-- has a check that sets it; writing VERIFIED here would only mean the app stops looking and starts
-- trusting a claim nobody made. Run the domain verification from the console once MX, SPF, DKIM and
-- DMARC are published.
INSERT INTO mail_domains (organization_id, domain, status, mode, verification_token, is_default)
SELECT o.id, :'mail_domain', 'PENDING', 'SELF_HOSTED',
       encode(gen_random_bytes(24), 'hex'), true
FROM organizations o
WHERE o.slug = 'prabhix-platform'
  AND NOT EXISTS (SELECT 1 FROM mail_domains WHERE domain = :'mail_domain');

-- ---------------------------------------------------------------------------------------------
-- Shared mailboxes
-- ---------------------------------------------------------------------------------------------

-- One row per address the company publishes. SHARED rather than PERSONAL: several people work a
-- support queue and the thread has to stay visible when one of them is away.
-- ::citext on every comparison against an address column, and not for tidiness. citext casts to
-- text implicitly but text only casts to citext on assignment, so `citext_column = text_value`
-- resolves to the text operator and compares case-sensitively — the opposite of what the column
-- type was chosen for. Literals are fine untyped; anything built with || is text.
INSERT INTO mail_mailboxes (organization_id, mail_domain_id, address, name, description, kind,
                            status, timezone)
SELECT o.id, d.id, box.address::citext, box.name, box.description, 'SHARED', 'ACTIVE', 'Asia/Kolkata'
FROM organizations o
JOIN mail_domains d ON d.domain = :'mail_domain'
CROSS JOIN (VALUES
    ('support@'  || :'mail_domain', 'Support',  'Customer questions and incident reports'),
    ('billing@'  || :'mail_domain', 'Billing',  'Invoices, payment failures and plan changes'),
    ('security@' || :'mail_domain', 'Security', 'Vulnerability reports and abuse'),
    ('careers@'  || :'mail_domain', 'Careers',  'Applications and referrals')
  ) AS box(address, name, description)
WHERE o.slug = 'prabhix-platform'
  AND NOT EXISTS (SELECT 1 FROM mail_mailboxes m WHERE m.address = box.address::citext);

-- no-reply is a mailbox rather than a bare From address so that a reply to an automated mail lands
-- somewhere a person eventually looks, instead of bouncing.
INSERT INTO mail_mailboxes (organization_id, mail_domain_id, address, name, description, kind,
                            status, timezone)
SELECT o.id, d.id, ('no-reply@' || :'mail_domain')::citext, 'No reply',
       'From address for automated mail. Replies land here rather than bouncing.',
       'SYSTEM', 'ACTIVE', 'Asia/Kolkata'
FROM organizations o
JOIN mail_domains d ON d.domain = :'mail_domain'
WHERE o.slug = 'prabhix-platform'
  AND NOT EXISTS (
    SELECT 1 FROM mail_mailboxes m WHERE m.address = ('no-reply@' || :'mail_domain')::citext
  );

-- ---------------------------------------------------------------------------------------------
-- The owner's own mailbox
-- ---------------------------------------------------------------------------------------------

-- Only when the owner's address is on this domain. Someone setting up with a gmail address gets no
-- mailbox, which is correct: there is nothing to deliver to.
--
-- password_hash here is the mailbox credential, which is what Dovecot checks for IMAP and SMTP
-- authentication. It is not the same secret as the account password above, and it is separate on
-- purpose — a mail client holds it forever and hands it over on every connection. Set to the same
-- value at seed time only so there is one thing to remember on day one; change it from the console.
INSERT INTO mail_mailboxes (organization_id, mail_domain_id, address, name, kind, status,
                            timezone, owner_user_id, password_hash, password_updated_at)
SELECT o.id, d.id, u.email, u.full_name, 'PERSONAL', 'ACTIVE', 'Asia/Kolkata', u.id,
       crypt(:'owner_password', gen_salt('bf', 12)), now()
FROM organizations o
JOIN mail_domains d ON d.domain = :'mail_domain'
JOIN users u ON u.email = :'owner_email'
WHERE o.slug = 'prabhix-platform'
  AND lower(u.email::text) LIKE '%@' || lower(:'mail_domain')
  AND NOT EXISTS (SELECT 1 FROM mail_mailboxes m WHERE m.address = u.email);

-- ---------------------------------------------------------------------------------------------
-- Aliases
-- ---------------------------------------------------------------------------------------------

-- Addresses people guess, pointed at a queue that exists. Cheaper than four more mailboxes and one
-- less inbox for someone to forget to read.
-- The VALUES list comes before the mailbox join, not after: a table reference can only see what is
-- to its left, so joining on a.target ahead of declaring a does not parse.
INSERT INTO mail_aliases (organization_id, mailbox_id, address)
SELECT o.id, m.id, a.address::citext
FROM organizations o
CROSS JOIN (VALUES
    ('info@'     || :'mail_domain', 'support@'  || :'mail_domain'),
    ('hello@'    || :'mail_domain', 'support@'  || :'mail_domain'),
    ('contact@'  || :'mail_domain', 'support@'  || :'mail_domain'),
    ('help@'     || :'mail_domain', 'support@'  || :'mail_domain'),
    ('sales@'    || :'mail_domain', 'support@'  || :'mail_domain'),
    ('accounts@' || :'mail_domain', 'billing@'  || :'mail_domain'),
    ('invoices@' || :'mail_domain', 'billing@'  || :'mail_domain'),
    ('abuse@'    || :'mail_domain', 'security@' || :'mail_domain'),
    -- RFC 2142 requires these two of anyone running a domain. Mail from other operators' automated
    -- systems goes here, and a domain that bounces them looks broken to the people least likely to
    -- chase it up by other means.
    ('postmaster@' || :'mail_domain', 'support@'  || :'mail_domain'),
    ('hostmaster@' || :'mail_domain', 'security@' || :'mail_domain')
  ) AS a(address, target)
JOIN mail_mailboxes m ON m.address = a.target::citext
WHERE o.slug = 'prabhix-platform'
  AND NOT EXISTS (SELECT 1 FROM mail_aliases x WHERE x.address = a.address::citext);

-- ---------------------------------------------------------------------------------------------
-- Mailbox access
-- ---------------------------------------------------------------------------------------------

-- The owner leads every shared queue, so day one is not "the mail arrived and nobody can open it".
-- LEAD rather than MEMBER: assignment and SLA settings are gated on it.
INSERT INTO mail_mailbox_members (organization_id, mailbox_id, user_id, access_level, notify)
SELECT m.organization_id, m.id, u.id, 'LEAD', true
FROM mail_mailboxes m
JOIN users u ON u.email = :'owner_email'
WHERE m.kind = 'SHARED'
  AND m.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM mail_mailbox_members x
    WHERE x.mailbox_id = m.id AND x.user_id = u.id
  );

COMMIT;

-- ---------------------------------------------------------------------------------------------
-- What it built
-- ---------------------------------------------------------------------------------------------

\echo ''
\echo 'Seeded:'
SELECT
  (SELECT count(*) FROM users)                                              AS users,
  (SELECT count(*) FROM organization_memberships WHERE status = 'ACTIVE')   AS memberships,
  (SELECT count(*) FROM platform_staff_roles WHERE revoked_at IS NULL)      AS staff_roles,
  (SELECT count(*) FROM mail_domains)                                       AS mail_domains,
  (SELECT count(*) FROM mail_mailboxes WHERE deleted_at IS NULL)            AS mailboxes,
  (SELECT count(*) FROM mail_aliases)                                       AS aliases;

\echo ''
\echo 'Sign in with the owner_email and owner_password given above, then:'
\echo '  - change the mailbox password from the console, it is not the account password'
\echo '  - publish MX, SPF, DKIM and DMARC, then run domain verification'
\echo '  - grant the rest of the team their staff roles from the admin console'
\echo ''
\echo 'Then run Identity/deploy/seed.sql against the identity database with the same owner_email,'
\echo 'owner_password and owner_id, so the account exists on the side that issues the tokens.'

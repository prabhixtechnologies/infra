# Prabhix strategy — one identity, many products

`docs/ROADMAP.md` is the honest inventory of what is built today. This is the forward plan: what is
being built, in what order, and why that order.

**Status.** Phases A through F are built and tested. A and B are not yet cut over in production —
`AUTH_UPSTREAM` still points at the backend, which is deliberate and is documented step by step in
[IDENTITY.md](IDENTITY.md#cutover-order). AWS hardening is deferred by decision. The per-phase notes
below say which is which, so nothing here should be read as a description of what production does
today.

The thesis in one paragraph: **Prabhix becomes an identity provider that happens to own products,
rather than products that each own a login.** Every surface — OneOps, the admin console, MobiStack,
Mailroom, the marketing site, and the thousand sites intended after them — redirects to one place to
sign in, and receives back a token it can only verify, never mint. Everything else in this document
follows from that sentence.

---

## The four repositories

| Repo | Owns | Does not own |
| --- | --- | --- |
| `Identity` | Who you are. Credentials, lockout, sessions, refresh rotation, magic links, OTP, SSO linking, and the OAuth/OIDC protocol surface. | What you can do. No organization, shop, role or permission appears in its schema. |
| `Platform` | OneOps and the admin console: organizations, memberships, roles, permissions, mail, chat, files, commerce, billing. | Authentication. |
| `MobiStack` | Two things that are being separated — a global component-compatibility commons, and per-shop inventory. | Authentication. |
| `Mailroom` | Personal mailboxes with folders: a web client and an Android app. | Authentication, its own mailbox API — that lives in the platform, which owns the mail schema — and its own transport, since Postfix/Dovecot already exist in `Platform/mail-server`. |

Each product keeps a thin local `users` mirror keyed by the identity `sub`, so existing foreign keys
(`created_by`, `assignee_id`, `organization_memberships.user_id`) keep working.

---

## Phase A — Prove the split on the platform

**Built, not yet cut over.** Nothing else should be built on the identity service until one product
actually runs on it.

- Backend verifies via **JWKS**, while still accepting its own HS256 tokens. Both at once is what
  keeps already-issued tokens working through the switch, so nobody is signed out.
- Permissions resolve **per request** from the platform's own database, behind the Redis cache
  `PermissionResolver` already has. Strictly better than today, where permissions freeze into the JWT
  at login and a revoked role keeps working for up to 15 minutes.
- Active tenant moves to the **`X-Prabhix-Org` header**, validated against membership rather than read
  from a token claim. Applied to identity tokens; the HS256 path keeps `selectOrganization` until
  HS256 is dropped, so the two can coexist through the switch.
- The local `users` mirror fills itself in from `/internal/users/lookup` on the first request naming a
  subject this database has not seen, since the bulk import only covers the population at the time.
  It never writes `platform_admin`: staff authority is granted here and nowhere else.
- Flip `AUTH_UPSTREAM` to `identity:8081`. Drop HS256 only after one refresh-token lifetime.

Procedure and rollback: [IDENTITY.md](IDENTITY.md).

Also in this phase, because it is currently broken: **the email-verification link 404s.**
`EmailVerificationService` sends users to `{CONSOLE_URL}/auth/verify-email`, and the console has no
such route. Magic-link and password-reset had the same defect and were fixed; this one was missed.

---

## Phase B — Identity becomes a provider, not a login endpoint

**Built, not yet cut over.** Spring Authorization Server is wired in, the four first-party clients are
seeded from configuration with PKCE S256 mandatory and exact-match redirect URIs, the hosted login page
is served from Identity's origin, and both consoles redirect to it behind `VITE_IDENTITY_ISSUER`. Both
Android apps now sign in through AppAuth over a Custom Tab and have no password field at all: their
login, OTP, magic-link and refresh calls are deleted, refresh goes to Identity's token endpoint, and
each variant's redirect scheme is its own application id — including the `.debug` suffix, so a debug
build cannot receive a code minted for the release build.

Today Identity is a **token issuer**: an app posts credentials and gets a JWT. That works for
first-party apps and cannot work for a thousand sites, because every one of those sites would be
handling passwords — the exact thing centralising identity is supposed to prevent.

What Google does is redirect. Credentials are only ever typed on one origin.

### Use Spring Authorization Server

Do not hand-write the protocol. An OAuth server is one of the few places where a subtle mistake is a
full account takeover. Spring Authorization Server is OIDC-certified, maintained by the Spring team,
and composes with what already exists: it owns the protocol, Identity keeps owning authentication.

Surface to add:

| Endpoint | For |
| --- | --- |
| `GET /authorize` | Authorization code + **PKCE S256 mandatory**, with `state` and `nonce`. |
| `POST /token` | Code exchange and refresh. |
| `GET /userinfo` | Claims for clients that would rather ask than parse. |
| `POST /introspect`, `POST /revoke` | Opaque-token checks and explicit revocation. |
| `GET /logout` | RP-initiated logout, plus front-channel logout for single sign-out. |
| `/.well-known/openid-configuration`, `/.well-known/jwks.json` | Already built. |

A client registry table: `client_id`, secret hash for confidential clients, **exact-match** redirect
URI allowlist (never wildcards — an open redirect here leaks authorization codes), allowed scopes,
allowed grant types, and a first-party flag that skips the consent screen for our own apps.

### The login UI moves to Identity's origin

Each app has its own login form today. For real SSO there is exactly one login UI, served from
`id.prabhixtechnologies.com`, and every app redirects to it. That is the "one identity URL" — a page
redirect, not an API call.

**The hard part is already done.** `SessionCookieService` — the shared cookie on the Identity origin —
is precisely what lets a second app's `/authorize` return without asking for a password again. That
cookie *is* single sign-on.

### Mobile uses Custom Tabs, never a WebView

AppAuth for Android, through Custom Tabs. Custom Tabs share the system browser's cookie jar, so
signing into OneOps signs you into MobiStack and Mailroom on the same phone. A WebView has its own
jar, silently breaks SSO, and is blocked outright by Google's sign-in.

Native username/password forms in the apps go away. This is a real behaviour change for existing
users and belongs in the same release as the hosted login UI.

MFA/TOTP and SAML land here, after parity — not as part of the extraction.

---

## Phase C — Who may create an account, and where they may go

**Built.** Two requirements that sound contradictory and are not: anyone may self-serve, but OneOps accounts are
created only by a tenant admin. They are different layers.

**An identity may be created by anyone** — email, Google SSO, or phone OTP. It grants access to
nothing. It is only a verified way of proving who you are.

**Product access is a separate grant.** OneOps access requires an `organization_memberships` row, and
only a tenant admin can create one. If the invited person has no identity yet, the invite creates one,
which is how `InvitationService` already works.

The domain restriction is now in place:

- `organization_domains` — a domain per tenant, proved by a **DNS TXT record**, with `verified_at`.
  Public providers (`gmail.com` and the rest) are refused outright: claiming one would let a tenant
  restrict or auto-join half the internet.
- The invite path refuses addresses outside a verified domain, so "an admin can only create accounts
  for their domain" is enforced rather than trusted. A tenant that has claimed nothing is unrestricted,
  which is what keeps this from breaking every existing organization.
- Optional **domain auto-join** falls out for free: anyone with a verified `@customer.com` address
  joins that tenant automatically, if the tenant enables it. Only permitted on a verified domain.
- A DNS resolver outage is reported as an outage, not as a failed verification, so a customer is never
  told their correctly-published record is wrong.

Phone OTP runs over Twilio behind an `SmsSender` seam, with a `DisabledSmsSender` that refuses
explicitly rather than accepting a request and dropping the message. Numbers are normalised to E.164
and must be verified before they can be used to sign in, and a number already verified against one
account cannot be claimed by another.

SCIM comes when an enterprise customer asks to sync from their own directory. Not before.

---

## Phase D — Platform roles, before the team arrives

**Built.** Platform staff access used to be one boolean, `users.platform_admin`. The first support hire
would have got break-glass token revocation and every tenant's data. That is not a defensible policy,
and retrofitting authorization onto people who already have access is far harder than granting it
correctly on day one.

| Role | May |
| --- | --- |
| `SUPPORT` | Read tenant data, impersonate with consent. |
| `BILLING` | Invoices, credits, subscription state. |
| `OPERATOR` | Health, deploys, queue and outbox inspection. |
| `SECURITY` | Token revocation, audit trail, session termination. |
| `OWNER` | All of the above, including granting roles. |

Grants live in `platform_staff_roles` as events — who granted, when, why — because "who gave this
person the ability to revoke anyone's session" is a question that gets asked and a boolean column
cannot answer it. Existing admins were backfilled to `OWNER`, since that is what the flag meant;
narrowing an individual is then a deliberate decision rather than a side effect of a migration.

Two paths are narrowed, and they are the two that matter:

- **Break glass.** `/admin/platform/staff/break-glass/users/{id}/revoke-tokens` requires `SECURITY` or
  `OWNER`, takes a mandatory reason, and writes its audit row synchronously.
- **Reaching into a tenant you are not a member of** requires `SUPPORT` or `OWNER`. Not `BILLING`,
  not `OPERATOR` — whoever is replaying a stuck mail queue has no reason to read the mail in it. The
  role lookup sits behind the branch that only runs when staff name an organization, so ordinary
  traffic pays nothing for it.

`users.platform_admin` survives as the coarse "is staff at all" gate that the security config and
twenty call sites read, but `PlatformStaffService` is its only writer — set on the first grant, cleared
on the last revocation — so it cannot drift from the table it summarises. Revoking the last `OWNER` is
refused: recovering from that means editing the database by hand, during whatever incident prompted it.

Impersonation stays audit-logged and banner-visible.

---

## Phase E — MobiStack: a commons and a tenant, not one confused thing

**Built.** MobiStack held two products with **opposite data-sharing rules**, both behind a single
"organization" concept. That was the whole source of the confusion: "organization" meant something
different on each side.

**Component compatibility** — does this screen fit that model — is only valuable *shared across every
shop*. It is a network-effect dataset. Scoping it per-tenant destroys it: a hundred shops each
maintaining a private copy is a hundred times the work for a hundredth of the coverage.

**Shop inventory** — stock, purchases, sales, customers — is strictly private. Leaking it across
tenants is a breach.

One is a commons. The other is a tenant.

What was built (MobiStack's schema, since squashed into its `V1__baseline.sql`):

- **A global compatibility graph, not shop-scoped.** `catalog_brands`, `catalog_devices`,
  `catalog_components` and `catalog_fitments`, none of which has a `shop_id` column at all. The edge
  carries `contributed_by`, `verified_by`, `confirmations`, `disputes` and `disputed` — counts rather
  than a boolean, because "one person said so" and "forty shops fitted it and two objected" are
  different claims and whoever is ordering the part needs to tell them apart. A disputed edge is kept
  and ranked last, never deleted: a missing edge invites the same wrong claim to be re-added next week
  by somebody who never saw the argument.
- **Contributions are proposals.** A trusted contributor's change applies immediately, everyone else's
  queues, and a *dispute* always queues regardless of standing — it removes information others rely on,
  so it is the one action where being wrong is worse than being slow. A *confirmation* is exempt in the
  other direction and always applies: it only increments a counter, and it is the signal most likely to
  be offered by somebody who will not fill in a form.
- **Reputation is granted, not computed.** An automatic promotion at N accepted contributions is a
  thing to game — submit N trivially-correct rows, then the wrong one that matters.
- **No workspace is involved.** `/api/v1/commons` is exempt from `WorkspaceGuardFilter`, for writes as
  well as reads. Somebody looks up what fits before they have a shop, and an unpaid shop can still
  contribute.
- **Reviewing is a different authority** from `COMPATIBILITY_APPROVE`, which is about a shop's own
  private groups. `COMMONS_REVIEW` changes what every other shop reads.
- **Shops stay tenants** for inventory, exactly as they are. The per-shop `brands`, `device_models` and
  `compatibility_groups` tables are untouched — nothing was migrated behind anyone's back, because a
  rewrite would have to guess which of a hundred shops' conflicting private opinions is the true one,
  which is precisely what the review queue is for.
- **Inventory references the catalog** by `product_variants.catalog_component_id`, nullable, linked one
  variant at a time. That join is what makes both halves worth more together, and it is the whole point
  of `findStockForCatalogDevice`: the existing per-shop lookup can only find what a shop itself recorded,
  so a shop that never built its private graph gets an empty answer while holding the part on a shelf.

"Organization creation" now means exactly one thing: creating a shop.

It also settles the commercial model without deciding it separately — the commons is free and drives
acquisition through network effects; inventory is the paid product.

---

## Phase F — Mailroom

**Done.** Personal mailboxes with folders, which the schema could not express before: `mail_mailboxes`
was org-scoped and shared, there was thread *status* rather than folders, compose was reply-only, and
`mail_thread_drafts` and `mail_aliases` had schema but no API.

Built in order — API first, then the clients, because a client written against an imagined contract
gets rewritten when the real one lands.

The mailbox schema (since squashed into `V1__baseline.sql`) and `/api/v1/mailbox`:

- **Folders, not statuses.** `mail_folders` with a `kind` for the six system folders so code can find
  "the trash folder for this mailbox" without matching on a name a person is free to rename.
  `mail_thread_folders` is one row per thread rather than a many-to-many, because what somebody means
  by "move to Archive" is that it is no longer in the inbox. Existing threads were backfilled from the
  status they had; only `SPAM` and `TRASH` carried a location, and everything else went to the inbox —
  a resolved ticket is still a thread you can find.
- **Flags belong to a reader, not a thread.** A shared mailbox has several readers and
  `mail_threads.unread_count` cannot be true for all of them at once. `mail_thread_flags` is keyed on
  `(thread_id, user_id)`; absence of a row means unread, so marking a new arrival unread only has to
  clear the rows that say otherwise rather than write one per reader per thread.
- **Filing an arrival is not the same as filing a new thread.** A reply to an archived thread brings it
  back to the inbox; a message to a thread in Spam leaves it there. Deleting a custom folder moves its
  threads to the inbox rather than deleting mail.
- **Standalone drafts.** `mail_thread_drafts.thread_id` became nullable with a partial unique index, so
  one reply draft per thread per author still holds while a person may have any number of unsent new
  messages.
- **Ownership is recorded rather than inferred.** `mail_mailboxes.owner_user_id`, backfilled only for
  personal mailboxes with exactly one member — anything else is a guess, and a wrong guess here hands
  one person's mail to another.

**Web** on `mail.prabhixtechnologies.com`, replacing the redirect to the console: three panes, mail
HTML behind DOMPurify and a mail-specific CSP that permits remote images but no scripts and no forms,
autosaved drafts. **Android** as `com.prabhix.mailroom`, one module and one flavor.

Both are OIDC clients of Identity — `prabhix-mailroom` and `prabhix-mailroom-android`, separate so a
redirect registered for a browser cannot be used from an app — and neither has a password form. That
made Mailroom the honest test of Identity as a general provider, being the first product with no legacy
auth of its own, and it passed: the clients contain no authentication code beyond a redirect and a code
exchange.

The two clients differ where a phone and a desktop differ rather than sharing a core. Android shows the
`text/plain` alternative instead of rendering HTML, has no autosaved draft and no reply-all; `Mailroom/
android/README.md` lists each omission and why. Mail is still the natural *second* service extraction
after identity — 22 tables, IMAP pollers, outbox workers, SES webhooks, already cleanly packaged — and
that has not been done.

---

## Deferred — AWS hardening

Deferred by decision, not because it does not matter. Ranked by risk removed, so it can be picked up
in the right order rather than the interesting one:

1. **The database is a container on a single box with no point-in-time recovery.** Everything below is
   a distant second. Nightly `pg_dump` to a versioned S3 bucket, and a **tested** restore — an
   untested backup is not a backup. Then RDS.
2. **No staging.** Flyway migrations are the most dangerous thing deployed, and they currently
   rehearse on production. A second compose project on the same box is not isolation but does allow
   rehearsal against a prod-shaped dump.
3. **Secrets in an on-disk `.env`.** SSM Parameter Store; Secrets Manager only when rotation is
   needed.
4. **Deploys are not health-gated.** `TAG` is already pinned per service, which is what makes rollback
   possible. Add: wait for `/actuator/health` before Caddy switches, abort leaving the old container
   running, and pin by image digest.
5. **ElastiCache** — Redis holds sessions and the deny list for every product. If it dies, everyone is
   signed out.
6. **ECR** instead of Docker Hub — private, IAM-scoped, no pull limits.
7. **ALB in front of ECS Fargate**, once there are genuinely four services and someone else deploys
   them.

Infrastructure should be **its own compose project** — Postgres, Redis, Caddy — with a lifecycle
independent of the apps, so redeploying a product cannot take the database down with it.

**Kubernetes is a non-goal.** At four services with a small team it is a second full-time job.

---

## Non-goals, and things not to do

- **Do not hand-write the OAuth server.** See Phase B.
- **Do not use wildcard redirect URIs.** An open redirect on `/authorize` leaks authorization codes.
- **Do not put product permissions in the token.** It is what makes revocation take 15 minutes today.
- **Do not scope the compatibility graph to organizations.** It is the one dataset whose value comes
  from being shared.
- **Do not add surfaces before the existing ones are finished.** The count is already around ten —
  marketing, OneOps web and Android, admin web and Android, the Identity login UI, Mailroom web and
  Android, MobiStack web and Android — before iOS adds four or five. Breadth is what turns a system
  into a collection of prototypes. Specifically: Mailroom Android did not start until Mailroom web was
  real, and iOS does not start until all nine of those are finished.
- **Do not rewrite git history** without a separate decision. MobiStack has commits authored from an
  employer address, and removing them means a force push where every SHA changes and the deployed tag
  stops matching any commit.

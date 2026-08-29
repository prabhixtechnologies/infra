# Prabhix strategy — one identity, many products

`docs/ROADMAP.md` is the honest inventory of what is built today. This is the forward plan: what is
being built, in what order, and why that order.

**Status.** Phases A through D are built and tested, and A and B are not yet cut over in production —
`AUTH_UPSTREAM` still points at the backend, which is deliberate and is documented step by step in
[IDENTITY.md](IDENTITY.md#cutover-order). Phases E and F are unstarted. The per-phase notes below say
which is which, so nothing here should be read as a description of what production does today.

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
| `Mailroom` | Personal mailboxes with folders. | Authentication, and its own transport — Postfix/Dovecot already exist in `Platform/mail-server`. |

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

**Unstarted.** MobiStack currently holds two products with **opposite data-sharing rules**, both behind a single
"organization" concept. That is the whole source of the confusion: "organization" means something
different on each side.

**Component compatibility** — does this screen fit that model — is only valuable *shared across every
shop*. It is a network-effect dataset. Scoping it per-tenant destroys it: a hundred shops each
maintaining a private copy is a hundred times the work for a hundredth of the coverage.

**Shop inventory** — stock, purchases, sales, customers — is strictly private. Leaking it across
tenants is a breach.

One is a commons. The other is a tenant.

- **A global compatibility graph, not org-scoped.** `devices`, `components`, `compatibility_edges`,
  carrying `contributed_by`, `verified_by`, `confidence` and `disputed`. Any signed-in identity reads
  it. Contributions are proposals; trusted contributors' edits auto-apply and everyone else's queue
  for review. Reputation is earned by accepted contributions. **No organization is involved** — an
  identity and a reputation score are enough.
- **Shops stay tenants** for inventory, exactly as they are.
- **Inventory references the catalog** by `component_id`. That join is what makes both halves worth
  more together: "I have 12 of this part, and it fits these 40 models."

"Organization creation" then means exactly one thing: creating a shop.

It also settles the commercial model without deciding it separately — the commons is free and drives
acquisition through network effects; inventory is the paid product.

---

## Phase F — Mailroom

**Unstarted; the repository holds only a README.** Personal mailboxes with folders, which the current
schema cannot express: `mail_mailboxes` is
org-scoped and shared, there is thread *status* rather than folders, compose is reply-only, and
`mail_thread_drafts` and `mail_aliases` have schema but no API.

Build the `mailbox` API in the platform backend first, then the clients. Mail is the natural *second*
extraction after identity — 22 tables, IMAP pollers, outbox workers, SES webhooks, already cleanly
packaged — but not concurrently with it.

Web on `mail.prabhixtechnologies.com`, replacing the redirect to the console. Android as
`com.prabhix.mailroom`. Both are OIDC clients of Identity, so it is also the honest test of whether
Identity works as a general provider: Mailroom is the first product with no legacy auth of its own.

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
  into a collection of prototypes. Specifically: Mailroom Android does not start until Mailroom web is
  real.
- **Do not rewrite git history** without a separate decision. MobiStack has commits authored from an
  employer address, and removing them means a force push where every SHA changes and the deployed tag
  stops matching any commit.

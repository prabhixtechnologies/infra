# Prabhix — Architecture

> **PRABHIX** — Progressive Research & Automation Business Hub for Innovation & eXperience
> _Building software that simplifies business._

What each product *is* and where its boundaries lie is settled in [PRODUCTS.md](PRODUCTS.md). This
document is how the pieces fit: hosts, repositories, the shared packages, the backend shape, tenancy,
authorization, mail, payments, and the conventions the code follows.

---

## 1. Surfaces and hosts

| Host | Audience | Served by |
|---|---|---|
| `prabhixtechnologies.com` | Public — prospects, shoppers, candidates | `Platform/marketing` (Next.js) |
| `oneops.prabhixtechnologies.com` | Customers operating their organization | `oneOps/web` built with `APP=oneops` |
| `admin.prabhixtechnologies.com` | Prabhix staff operating the platform | `oneOps/web` built with `APP=admin` |
| `api.prabhixtechnologies.com` | Every client | Caddy: `/api/v1/auth/*`, `/oauth2/*`, `/login`, `/.well-known/*` → Identity; everything else → oneOps backend |
| `mail.prabhixtechnologies.com` | A person with a hosted address | `Mailroom/web`; MX / IMAP / SMTP on the same name via `Mailroom/mail-server` |
| `mobistack.prabhixtechnologies.com` | Repair shops | `MobiStack/web` and `MobiStack/backend` |
| `store.prabhixtechnologies.com` | Anyone installing an app | `Infra/deploy/app-store`, APKs streamed from S3 |

`app.prabhixtechnologies.com` permanently redirects to `oneops.`; `id.prabhixtechnologies.com`
resolves but is not yet the issuer — moving the issuer invalidates every token in flight and is a
one-time change to make in a planned window.

Every host is one Caddy on one EC2 instance, in one Compose project (`Infra/docker-compose.yml`).
Databases are on one RDS instance (`oneops`, `identity`, `mobistack`), caches on ElastiCache Valkey.

### What belongs where

- **`Platform/marketing` is a public site that is also a public API client.** Its storefront, chat
  widget and visitor beacon call `/api/v1/{commerce,chat,visitor}/public/{orgSlug}/...`: unauthenticated
  endpoints scoped to Prabhix's own organization, guarded by an `Origin` allowlist. It holds no JWT.
- **The OneOps console is the product.** Everything that acts on one organization lives here: the
  helpdesk inbox, live chat, visitors, storefront administration, members and roles, billing, and the
  organization's mail settings. Prabhix's own team uses it as customer #1.
- **The admin console is a control tower, not a second copy of the product.** Tenants and shops,
  identity users, revenue, infrastructure and deploys, mail health, staff roles, cross-tenant event
  logs. A page that cannot be rendered without naming an organization belongs in OneOps. Support is a
  handoff: "Open" in the tenant directory opens OneOps with `?viewAs=<orgId>`, honoured only after the
  server confirms a platform admin, under an unmissable banner.
- **The admin console talks to one backend.** The oneOps backend is the admin BFF: it reaches
  MobiStack's and Identity's internal admin APIs over the shared service token, naming the acting
  staff member on every call. The browser never calls MobiStack or Identity's admin surface directly,
  so platform staff roles are the only human admin authority.
- **Mailroom is one person's mail.** No queue, no assignee, no SLA. Admins additionally get *Company
  mail* — see PRODUCTS.md, decision 1.
- **A capability is not a product.** Helpdesk is a section of OneOps. `Platform/marketing/src/content/products.ts`
  encodes this with `kind: app | module`; only an `app` gets an "Open app" link.

---

## 2. Repositories and what they publish

| Repository | Deploys | Publishes for others |
|---|---|---|
| `Identity` | `prabhix/identity` image | `com.prabhix:identity-spring-boot-starter` — JWKS verification, the authentication filter, the user mirror, the `/internal` service-token client |
| `oneOps` | `prabhix/backend`, `prabhix/web`, `prabhix/admin` images | `@prabhix/oneops-api` (TypeScript) and the Dart client, generated from springdoc on every build |
| `MobiStack` | `mobistack-backend`, `mobistack-web` images | `@prabhix/mobistack-api` and its Dart client, likewise |
| `Mailroom` | `prabhix/mailroom` image; the mail transport compose | — |
| `web-kit` | — | `@prabhix/brand` (tokens, marks), `@prabhix/ui` (primitives), `@prabhix/oidc-client` (PKCE flow) |
| `Mobile` | APKs to `s3://prabhix-apk-downloads/` | — |
| `Platform` | `prabhix/marketing` image | — |
| `Infra` | the Compose project, Caddy, `deploy.yml` | these documents |

Nothing is copied between repositories. If two apps need the same code, it is published from the
repository that owns the concern and pinned by version in the others.

---

## 3. Stack

| Concern | Choice |
|---|---|
| Backends | Java 25, Spring Boot 4.1, PostgreSQL 16, Flyway (`ddl-auto: validate`), Spring Data JPA, Valkey/Redis 7, springdoc-openapi, JUnit 5 + Testcontainers |
| Identity | Spring Authorization Server (OIDC, PKCE S256 mandatory, RS256 + JWKS), webauthn4j for passkeys |
| Web consoles | React 19, Vite 8, TypeScript strict, Tailwind CSS 4, TanStack Query, Zod at every response boundary |
| Marketing | Next.js 16 (App Router), React 19, Tailwind CSS 4 |
| Mobile | Flutter (Dart SDK ^3.5), Melos workspace, flutter_appauth, Dio |
| Infrastructure | Docker Compose → ECR → one EC2 behind Caddy (automatic TLS); RDS; ElastiCache; SES; S3; CloudWatch metrics and alarms |

---

## 4. Backend module layout (oneOps)

A **modular monolith**. One deployable, but modules are separated so any of them can be extracted
without a rewrite — mail is the one most likely to be.

```
com.prabhix.platform
├── common/          # shared primitives — no dependencies on feature modules
├── config/          # Spring @Configuration (Jackson, Redis, async, OpenAPI, S3, CloudWatch)
├── security/        # authentication + authorization plumbing (verification via identity-spring-boot-starter)
├── auth/            # /auth/me, invitations; credentials live in Identity
├── user/            # the local users mirror
├── org/             # organizations, members, teams, roles, domains
├── mail/            # domain, inbound, outbound, helpdesk, mailbox (personal), provisioning, ai
├── chat/            # live chat with visitors, agent side
├── visitor/         # beacon ingest, presence, analytics
├── commerce/        # catalog, cart, checkout, orders, provisioning
├── billing/         # Razorpay — plans, subscriptions, invoices, dunning
├── ai/              # provider-agnostic assists
├── files/           # S3 uploads, signed URLs, scanning
├── flags/           # feature flags per organization
├── audit/           # append-only audit log
├── observability/   # structured event logs (/event-logs)
├── push/            # FCM / APNs
├── dashboard/       # tenant KPIs
├── site/            # public endpoints for the marketing site (leads, careers, contact) and their admin
└── ops/             # platform administration: overview, tenants, staff roles, infra, revenue, and the
                     # BFF clients for MobiStack and Identity
```

### Module rules

1. `common`, `config`, `security` may be imported by anyone. They import no feature module.
2. Feature modules **must not** import each other's `domain/` or `repository/` packages. Cross-module
   calls go through a published service interface or a domain event.
3. Every module follows the same internal shape: `domain/`, `repository/`, `service/`, `web/`, `dto/`,
   `event/`.

---

## 5. Multi-tenancy

**Model:** shared schema, shared tables, discriminator column `organization_id`. Chosen over
schema-per-tenant because 100k-user organizations need connection pooling and online migrations that
per-schema designs make painful.

Isolation is enforced in **three layers**, deliberately redundant:

1. **`X-Prabhix-Org` header** — the active organization, validated on every request against the
   caller's active memberships. Identity tokens carry no organization and no permissions; claims are
   never a source of authority.
2. **`TenantFilter`** resolves it into a request-scoped `TenantContext`.
3. **Hibernate filter** — `TenantScopedEntity` subclasses carry an `@FilterDef` that appends
   `organization_id = :orgId` to every query. A missing tenant context throws rather than returning
   all rows.

Postgres **Row-Level Security** is additionally enabled on the highest-risk tables (`mail_messages`,
`mail_threads`, `billing_invoices`).

Cross-organization access is only possible through `ops/`, under a distinct `PLATFORM_ADMIN`
authority narrowed by staff role, and writes every access to the audit log.

---

## 6. Authorization (RBAC)

```
User ──< OrganizationMembership >── Organization
              │
              ├── Role (system or custom, per-organization)
              │     └──< RolePermission >── Permission
              └──< TeamMembership >── Team
```

- **Permissions** are fine-grained string codes (`MAIL_READ`, `MAIL_READ_ALL`, `MAIL_SEND`,
  `BILLING_MANAGE`, `ORG_MEMBER_INVITE`, ...). They are the only thing code checks.
- **Roles** bundle permissions. System roles (`OWNER`, `ADMIN`, `MANAGER`, `AGENT`, `MEMBER`, `VIEWER`)
  are seeded; organizations may define custom roles.
- Enforcement is declarative: `@PreAuthorize(Authorize.MAIL_SEND)`.
- Permissions are resolved **per request** from the database behind a short Redis cache
  (`PermissionResolver`), never embedded in the token, so a revoked role stops working immediately.

**Platform staff** hold `SUPPORT`, `BILLING`, `OPERATOR`, `SECURITY` or `OWNER` in
`platform_staff_roles`, granted as events (who, when, why). `users.platform_admin` is the coarse "is
staff at all" gate and is written only by `PlatformStaffService`.

---

## 7. Email subsystem

Three layers that can run independently — see [MAIL.md](MAIL.md).

| Layer | Responsibility |
|---|---|
| **Transport** (`Mailroom/mail-server/`) | Postfix + Dovecot + Rspamd. MX for customer domains, SPF/DKIM/DMARC, Maildir, IMAP/SMTP. Outbound goes via SES from EC2. |
| **Helpdesk** (`mail/inbound`, `mail/helpdesk`) | Pull from IMAP or accept LMTP/webhook push, parse MIME, thread, route by rule, assign, track SLA. Surfaced in OneOps `/inbox`. |
| **Personal mail** (`mail/mailbox`) | Folders, per-reader flags, drafts, aliases, compose. Surfaced in Mailroom. |
| **Transactional** (`mail/outbound`) | Templated, queued, retried outbound mail with bounce and complaint handling. |

Key invariants:

- Inbound ingestion is **idempotent** on RFC 5322 `Message-ID` + mailbox.
- Sending goes through an **outbox table**, never a direct SMTP call inside a request transaction.
- Threading uses `In-Reply-To` / `References` first, falling back to normalized subject + participants.
- **Who sees what:** a mailbox is visible to its members (directly or through a team) and to holders
  of `MAIL_READ_ALL`. A `PERSONAL` mailbox always records its owner *and* gives the owner a member
  row, so visibility never depends on an admin permission. Every cross-mailbox read by a
  `MAIL_READ_ALL` holder emits `MAIL_ADMIN_READ`.

---

## 8. Payments — Razorpay

```
Plan ──< Subscription >── Organization
             │
             ├──< Invoice >──< Payment
             └── entitlements → feature flags + seat limits
```

- Order creation is server-side only; amounts are never trusted from the client.
- Signature verification on the return path; **webhooks are the source of truth**, persisted raw and
  processed idempotently on `event.id`.
- One-time orders, recurring subscriptions, seat-based proration, refunds, GST invoice numbering,
  dunning on a 1/3/7-day backoff.

---

## 9. Designing for 100,000 users in one organization

| Pressure point | Mitigation |
|---|---|
| Stateless API | No server session state; JWT + Redis. Scale horizontally behind a load balancer when needed. |
| Connection pool exhaustion | HikariCP capped per instance; PgBouncer in transaction mode in front of Postgres. |
| Hot tables (`mail_messages`) | Covering indexes on `(thread_id, occurred_at, id)` and `(mailbox_id, occurred_at desc)`; monthly partitioning past ~50M rows. `audit_logs` is already partitioned. |
| Deep pagination | Cursor (keyset) pagination on all list endpoints; `OFFSET` is banned in hot paths. |
| Permission checks | Per request behind a short Redis cache; never in the token. |
| Background work | Outbox + worker with `SELECT ... FOR UPDATE SKIP LOCKED`, safe to run N workers. |
| Full-text search | Postgres `tsvector` + `pg_trgm`; a swap to OpenSearch is isolated behind `search/`. |
| Attachments | Never in Postgres — S3 with signed URLs. |
| Real-time updates | Server-Sent Events per organization channel, fanned out via Redis pub/sub. |
| Rate limiting | Per-IP and per-organization token buckets in Redis. |

---

## 10. Conventions

### Java
- Records for all DTOs, grouped as nested types inside `<Area>Dtos.java`.
- Lombok `@RequiredArgsConstructor` + `@Getter/@Setter`; constructor injection only.
- `@Transactional` on service methods, never on controllers.
- Validate with Jakarta Bean Validation on the DTO record components.
- Return `PageResponse<T>` or `CursorPage<T>`, never a raw `Page`.
- Throw `ApiException.of(ErrorCode.X, "message")`; never leak stack traces.
- Emit a `LogEventCode` from the service that owns the fact; a code nobody emits is deleted.

### TypeScript
- `strict: true`, `noUnusedLocals`, `noUnusedParameters`; path alias `@/*` → `src/*`.
- API types come from `@prabhix/oneops-api` / `@prabhix/mobistack-api`; hand-written response
  schemas use `.nullish()`, never `.nullable()`, because the API omits null fields.
- Server state via TanStack Query. No Redux.
- Brand tokens from `@prabhix/brand`, primitives from `@prabhix/ui`, sign-in from `@prabhix/oidc-client`.

### Dart
- API models come from the generated client in `prabhix_api_core`; screens never hand-roll JSON.
- Sign-in only through `prabhix_identity` (AppAuth over Custom Tabs). Never a WebView.

### SQL
- Flyway `V<n>__<snake_case_description>.sql`, forward-only, safe against a live table.
- Every table gets `id uuid primary key default gen_random_uuid()`, `created_at`, `updated_at`; tenant
  tables also `organization_id`. Every foreign key gets an explicit index.

### Comments
Explain business rules, invariants and non-obvious trade-offs. Do not narrate code.

---

## 11. Environments

| Env | How | Notes |
|---|---|---|
| Local | `cd Infra && make up` (`docker-compose.yml` + `.local.yml`, profiles `identity`, `mailroom`, `mobistack`) | Ports published, demo seed, mailpit instead of real SMTP, Razorpay test keys. |
| Production | `Infra/.github/workflows/deploy.yml` (or `deploy-remote.ps1`) → `deploy.sh` on the box | Images from ECR pinned per service (`BACKEND_TAG`, `WEB_TAG`, `ADMIN_TAG`, `MARKETING_TAG`, `IDENTITY_TAG`, `MAILROOM_TAG`, `MOBISTACK_BACKEND_TAG`, `MOBISTACK_WEB_TAG`), health-gated, rolled back per service. Secrets from SSM Parameter Store. |
| Staging | Launched from an AMI for a rehearsal, then terminated | See `deploy/RUNBOOK-consolidate.md`. |

Secrets are never committed. `.env.example` documents every variable the stack reads.

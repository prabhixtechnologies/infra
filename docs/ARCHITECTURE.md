# Prabhix Platform — Architecture

> **PRABHIX** — Progressive Research & Automation Business Hub for Innovation & eXperience
> _Building software that simplifies business._

---

## 1. What this is

A single platform that serves two audiences from one codebase:

| Surface | Audience | App |
|---|---|---|
| `prabhixtechnologies.com` | Public — prospects, candidates, press, shoppers | `marketing/` (Next.js, SSR/SSG) |
| `oneops.prabhixtechnologies.com` | Operators — customer organizations | `web/` built with `APP=oneops` |
| `admin.prabhixtechnologies.com` | Prabhix staff — the platform itself | `web/` built with `APP=admin` |
| `api.prabhixtechnologies.com` | Both surfaces + integrations | `backend/` (Spring Boot) |
| `mail.prabhixtechnologies.com` | Anyone with a hosted address — personal mail | `../Mailroom/web`, and MX / IMAP / SMTP on the same host via `Mailroom/mail-server/` |
| `mobistack.prabhixtechnologies.com` | MobiStack customers | Separate deployment, not in this repo |

One hostname serves two unrelated things there, which is worth stating plainly: Caddy serves the
Mailroom client on 443, and Postfix and Dovecot answer on 25, 587 and 993. They share the name
because a person typing it means their mail either way, and they share the Elastic IP because the MX
record has to resolve to the machine that accepts the mail.

`app.prabhixtechnologies.com` is the console's former host and now permanently redirects to
`oneops.` — see `deploy/Caddyfile`.

### What belongs where

The distinction that matters, because it is easy to blur:

- **`marketing/` is a public site that is also a public API client.** Its storefront, chat widget
  and visitor beacon call `/api/v1/{commerce,chat,visitor}/public/{orgSlug}/...`. These are
  unauthenticated endpoints scoped to Prabhix's own organization, guarded by an `Origin`
  allowlist rather than a token. The marketing app holds no JWT and no operator capability.
- **`web/` (OneOps) is the product.** Everything that acts on one organization lives here: the
  shared inbox, the agent side of chat, visitor analytics, storefront administration, staff and
  roles, billing, logs. It is what customers buy — and what Prabhix's own team uses, because the
  company runs its business as a customer of its own product.
- **The admin console is a control tower, not a second copy of the product.** It mounts the
  platform surfaces and nothing else: the tenant directory, the marketing pipeline (leads,
  subscribers, applications) and platform-wide event logs. There is no inbox here, no chat, no shop
  and no settings, because each of those acts on a single organization and this console's subject is
  the platform.

  The line is **operating the platform** versus **working inside one organization**. It is not a
  matter of who may see what — it is what the page is *about*. A page that cannot be rendered
  without naming an organization belongs in OneOps. Billing is in OneOps for the same reason from
  the other direction: the company that owns the platform has no subscription to manage.

  **Support is a handoff, not a page.** There is no admin API for a customer's mail, chat or
  orders — `/admin/platform/*` returns counts and directory rows precisely so an operator can judge
  the platform's health without reading anybody's mail. Reading a customer's data means the ordinary
  tenant endpoints with `X-Prabhix-Org` naming them, which the server allows for platform admins and
  records. So "Open" in the tenant directory opens **OneOps** in a new tab with `?viewAs=<orgId>`;
  OneOps honours it only after the server confirms the caller is a platform admin, and shows an
  unmissable banner naming the customer. Support staff then look at exactly the screen the customer
  is describing, rather than a second implementation of it that drifts.

  This was got wrong twice, in instructive ways. First admin was the whole of OneOps plus one
  Platform link — indistinguishable on screen, and ambiguous about whose data any page held. Then
  the tenant pages were gated behind choosing an organization, which fixed the behaviour but left
  admin still *containing* the entire product: 22 of 23 feature directories, 75 of the bundle's
  chunks. Both times the mistake was treating the split as a visibility problem.
- **A capability is not a product.** Helpdesk is a section of OneOps, not a separate deployment.
  `marketing/src/content/products.ts` encodes this with a `kind` of `app` or `module`, and only
  an `app` gets an "Open app" link. Getting this wrong is what previously advertised
  "Open app" for things that had no app.

The product is **multi-tenant SaaS**. Each customer is an `organization` with an isolated
data boundary. A single organization must scale to **100,000 users**, which drives most of
the non-obvious decisions in this document.

---

## 2. Stack

### Backend — `backend/`

| Concern | Choice | Version |
|---|---|---|
| Language | Java | 21 (source/target overridable to 17 for local dev) |
| Framework | Spring Boot | 3.5.x |
| Database | PostgreSQL | 16 |
| Migrations | Flyway | Boot-managed, `ddl-auto: validate` |
| Persistence | Spring Data JPA / Hibernate | Boot-managed |
| Cache / queue coordination | Redis | 7 |
| Auth | Spring Security + JWT (jjwt) | 0.12.x |
| Mail | Jakarta Mail (SMTP send + IMAP fetch) | Boot-managed |
| Templating | Thymeleaf (HTML email) | Boot-managed |
| Object storage | S3-compatible (AWS SDK v2) | attachments, exports |
| API docs | springdoc-openapi | 2.8.x |
| Tests | JUnit 5, Mockito, Testcontainers | — |

### Frontends

| App | Stack |
|---|---|
| `marketing/` | Next.js 15 (App Router), React 19, TypeScript, Tailwind CSS 4 |
| `web/` | React 19, Vite 7, TypeScript, Tailwind CSS 4, shadcn/ui, TanStack Query |

### Infrastructure

Docker Compose → Docker Hub → AWS EC2, fronted by **Caddy** for automatic TLS.
Postgres and Redis are never published to the host in production.

---

## 3. Backend module layout

A **modular monolith**. One deployable, but modules are strictly separated so any of them
can be extracted into its own service later without a rewrite.

```
com.prabhix.platform
├── PrabhixApplication.java
├── common/          # shared primitives — no dependencies on feature modules
│   ├── entity/      # BaseEntity, AuditableEntity, TenantScopedEntity
│   ├── error/       # ApiException, ErrorCode, GlobalExceptionHandler
│   ├── web/         # PageResponse, ApiResponse, cursor pagination
│   └── util/        # ids, slugs, hashing, clock
├── config/          # Spring @Configuration beans (Jackson, Redis, async, OpenAPI, S3)
├── security/        # authentication + authorization plumbing
│   ├── jwt/         # JwtService, JwtAuthenticationFilter
│   ├── rbac/        # Permission, SystemRole, Authorize constants
│   └── tenant/      # TenantContext, TenantFilter, row-level guards
├── auth/            # login, refresh, magic link, OTP, SSO, device sessions
├── org/             # organizations, members, teams, roles, invites
├── mail/            # the email subsystem — see docs/MAIL.md
│   ├── domain/      # Mailbox, MailThread, MailMessage, MailAddress...
│   ├── inbound/     # IMAP fetcher, MIME parser, threading, routing rules
│   ├── outbound/    # SMTP sender, outbox worker, templates, tracking
│   ├── helpdesk/    # assignment, SLA, canned replies, tags, notes
│   └── provisioning/# mailbox/alias/domain provisioning for the mail server
├── billing/         # Razorpay — plans, subscriptions, orders, webhooks, invoices
├── notify/          # in-app notifications, push, SMS/WhatsApp, notification outbox
├── audit/           # append-only audit log
├── files/           # S3 uploads, signed URLs, virus-scan hook
├── search/          # Postgres full-text + trigram search
├── flags/           # feature flags per organization
├── admin/           # Prabhix-internal platform administration
└── site/            # public endpoints for the marketing site (leads, careers, contact)
```

### Module rules

1. `common`, `config`, `security` may be imported by anyone. They import no feature module.
2. Feature modules **must not** import each other's `domain/` or `repository/` packages.
   Cross-module calls go through a published service interface or a domain event.
3. Every module follows the same internal shape:

```
<module>/
  domain/       # JPA entities
  repository/   # Spring Data interfaces
  service/      # business logic, @Transactional
  web/          # @RestController
  dto/          # Java records, one *Dtos.java per area
  event/        # published domain events
```

---

## 4. Multi-tenancy

**Model:** shared schema, shared tables, discriminator column `organization_id`.
Chosen over schema-per-tenant because 100k-user orgs need connection pooling and online
migrations that per-schema designs make painful.

Isolation is enforced in **three layers**, deliberately redundant:

1. **JWT claim** — every access token carries `org` (the active organization id).
2. **`TenantFilter`** resolves `org` into a `TenantContext` request-scoped holder and
   validates it against the caller's memberships.
3. **Hibernate filter** — `TenantScopedEntity` subclasses carry an `@FilterDef` that
   appends `organization_id = :orgId` to every query automatically. A missing tenant
   context throws rather than silently returning all rows.

Postgres **Row-Level Security** is additionally enabled on the highest-risk tables
(`mail_messages`, `mail_threads`, `billing_invoices`) as a defence-in-depth backstop.

Cross-organization access is only possible through the `admin/` module, which runs under a
distinct `PLATFORM_ADMIN` authority and writes every access to the audit log.

---

## 5. Authorization (RBAC)

Two-level model, same shape that proved out in MobiStack but with team scoping added.

```
User ──< OrganizationMembership >── Organization
              │
              ├── Role (system or custom, per-organization)
              │     └──< RolePermission >── Permission
              └──< TeamMembership >── Team
```

- **Permissions** are fine-grained string codes: `MAIL_READ`, `MAIL_SEND`, `BILLING_MANAGE`,
  `ORG_MEMBER_INVITE`, `PROJECT_WRITE`. They are the only thing code checks.
- **Roles** bundle permissions. System roles (`OWNER`, `ADMIN`, `MANAGER`, `AGENT`,
  `MEMBER`, `VIEWER`) are seeded; organizations may define custom roles.
- Enforcement is declarative:

```java
@PreAuthorize(Authorize.MAIL_SEND)
public MailMessageDto reply(...) { ... }
```

- Permissions are resolved once at token issue and embedded in the JWT (`perms` claim) to
  keep the hot path free of database round-trips. Token TTL is short (15 min) so revocation
  lag is bounded; a Redis-backed deny-list handles immediate revocation.

---

## 6. Email subsystem

The largest and most differentiated part of the platform. It has three layers that can be
run independently — see **[docs/MAIL.md](./MAIL.md)** for the full design.

| Layer | Responsibility |
|---|---|
| **Mail transport** (`Mailroom/mail-server/`) | Self-hosted Postfix + Dovecot + Rspamd. Owns MX for customer domains, enforces SPF/DKIM/DMARC, stores mail in Maildir, exposes IMAP/SMTP. |
| **Shared inbox / helpdesk** (`mail/inbound`, `mail/helpdesk`) | Pulls from IMAP (or accepts LMTP/webhook push), parses MIME, threads conversations, routes to the right inbox by rule, assigns to agents, tracks SLA. |
| **Transactional engine** (`mail/outbound`) | Templated, queued, retried outbound mail with per-provider failover, bounce/complaint handling, and open/click tracking. |

Key invariants:

- Inbound ingestion is **idempotent** on RFC 5322 `Message-ID` + mailbox.
- Sending goes through an **outbox table**, never a direct SMTP call inside a request
  transaction. A worker drains it, so a provider outage never fails a user action.
- Threading uses `In-Reply-To` / `References` first, falling back to a normalized-subject +
  participant-set heuristic.

---

## 7. Payments — Razorpay

Full lifecycle, INR-first:

```
Plan ──< Subscription >── Organization
             │
             ├──< Invoice >──< Payment
             └── entitlements → feature flags + seat limits
```

- **Order creation** is server-side only; amounts are never trusted from the client.
- **Signature verification** on the return path: `HMAC-SHA256(order_id|payment_id, secret)`.
- **Webhooks are the source of truth** (`X-Razorpay-Signature` verified against the webhook
  secret), not the browser callback. Every webhook is persisted raw before processing and
  processed idempotently on `event.id`. This closes the gap MobiStack has today.
- Supports one-time orders, recurring subscriptions, seat-based proration, refunds,
  GST-compliant invoice numbering, and dunning on failed renewals.

---

## 8. Designing for 100,000 users in one organization

| Pressure point | Mitigation |
|---|---|
| Stateless API | No server session state; JWT + Redis. Scale horizontally behind an ALB. |
| Connection pool exhaustion | HikariCP capped per instance; PgBouncer in transaction mode in front of Postgres. |
| Hot tables (`mail_messages`) | Covering indexes on `(thread_id, occurred_at, id)` and `(mailbox_id, occurred_at desc)`. Unpartitioned today so `mail_attachments` can keep a plain foreign key; monthly range partitioning becomes worth the composite-key cost past roughly 50M rows. `audit_logs` **is** already partitioned, because nothing references it. |
| Deep pagination | **Cursor pagination** (keyset) on all list endpoints; `OFFSET` is banned in hot paths. |
| Permission checks | Precomputed into the JWT; no per-request permission query. |
| Member/mailbox lists | Redis read-through cache with explicit invalidation on write. |
| Background work | Outbox + worker pattern with `SELECT ... FOR UPDATE SKIP LOCKED`, safe to run N workers. |
| Full-text search | Postgres `tsvector` generated columns + `pg_trgm`; a swap to OpenSearch is isolated behind `search/`. |
| Attachments | Never in Postgres — S3 with signed URLs. |
| Audit growth | Append-only, partitioned, archived to S3 after 90 days. |
| Real-time updates | Server-Sent Events per organization channel, fanned out via Redis pub/sub. |
| Rate limiting | Per-IP and per-organization token buckets in Redis. |

---

## 9. Conventions

### Java
- Records for all DTOs, grouped as nested types inside `<Area>Dtos.java`.
- Lombok `@RequiredArgsConstructor` + `@Getter/@Setter`; constructor injection only.
- `@Transactional` on service methods, never on controllers.
- Validate with Jakarta Bean Validation on the DTO record components.
- Return `PageResponse<T>` or `CursorPage<T>`, never a raw `Page`.
- Throw `ApiException.of(ErrorCode.X, "message")`; never leak stack traces.

### TypeScript
- `strict: true`, plus `noUnusedLocals` / `noUnusedParameters`.
- Path alias `@/*` → `src/*`.
- Zod schemas for every API response boundary; infer types from them.
- Server state via TanStack Query. No Redux.
- Components are function components; `PascalCase.tsx` for components,
  `kebab-case.ts` for libs and hooks.

### SQL
- Flyway file naming: `V<n>__<snake_case_description>.sql`.
- Every table gets `id uuid primary key default gen_random_uuid()`,
  `created_at`, `updated_at`; tenant tables also get `organization_id`.
- Every foreign key gets an explicit index.
- Migrations are forward-only and must be safe to run against a live table
  (no blocking `ALTER TABLE ... ADD COLUMN ... NOT NULL DEFAULT` on large tables).

### Comments
Explain business rules, invariants, and non-obvious trade-offs. Do not narrate code.

---

## 10. Environments

| Env | Compose file | Notes |
|---|---|---|
| Local | `docker-compose.yml` + `docker-compose.local.yml` | Ports published, demo seed data, MailDev instead of real SMTP, Razorpay test keys. |
| Production | `docker-compose.yml` + `docker-compose.prod.yml` | Pre-built images from Docker Hub, Caddy TLS, no published DB ports, real secrets from `deploy/.env.prod`. |

Secrets are never committed. `.env.example` documents every variable the stack reads.

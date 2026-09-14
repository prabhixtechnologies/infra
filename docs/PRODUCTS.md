# Products and their boundaries

One sentence per product, and the two boundary decisions that everything else in these repositories
has to agree with. When a page, an endpoint or a line of marketing copy does not fit one of these
sentences, the sentence wins and the code moves.

## The products

- **OneOps** — the operations console for a small online business: website visitors and live chat, a
  shared helpdesk inbox, storefront and orders, team and billing. Sold per organization at
  `oneops.prabhixtechnologies.com`. Repository `oneOps` (backend, console, admin console).
- **MobiStack** — mobile-repair shop management, built around one counter motion: search a phone,
  see what fits, see stock, sell. Two halves with opposite sharing rules: a **Fitment Catalog** shared
  by every shop, and **My Shop** inventory that is private to one shop. Repository `MobiStack`.
- **Mailroom** — a person's own mail on a Prabhix-hosted address, with folders, stars and drafts. An
  organization admin additionally gets a **Company mail** view of every mailbox the organization owns.
  Repository `Mailroom`.
- **Prabhix Identity** — who you are, for every product: sign-in, sessions, passkeys, account
  self-service, and the OIDC surface products redirect to. It holds no roles or permissions. Repository
  `Identity`.
- **Admin console** — Prabhix's own control plane at `admin.prabhixtechnologies.com`: tenants and
  shops, identity users, revenue, infrastructure and deploys, mail health, staff roles. It operates the
  platform; it never works inside one customer's organization. Built from `oneOps/web` with `APP=admin`.
- **Marketing site** — `prabhixtechnologies.com`. Also the public storefront, chat widget and visitor
  beacon for Prabhix's own organization. Repository `Platform`.
- **Mobile** — the Flutter apps for OneOps, Admin, Mailroom and MobiStack, in one Melos workspace.
  Repository `Mobile`.
- **Infra** — how it all runs: one Compose project, one Caddy, one deploy workflow, the runbooks and
  these documents. Repository `Infra`.

## Decision 1 — the helpdesk belongs to OneOps

The shared team inbox (threads with an assignee, SLA clock, tags, canned replies, routing rules) is a
**OneOps** feature, reached at `/inbox` in the OneOps console. Mail administration — mailboxes,
domains and DKIM, routing, tags, canned replies — lives under OneOps Settings → Mail, because it is an
organization-admin task.

**Mailroom** is one person's mail. It never shows a queue, an assignee or an SLA. Its only
organization-wide surface is *Company mail*, available to members holding `MAIL_READ_ALL`
(organization OWNER, ADMIN and MANAGER by default): every mailbox the organization owns, grouped by
owner, with each cross-mailbox read recorded as an event. An ordinary member sees exactly the
mailboxes they own or have been granted, and nothing else.

Why this way round: the mail module, its 74 endpoints and its permission model already live in the
oneOps backend; marketing and pricing already sell the helpdesk as part of OneOps; and the owner's
own description of Mailroom is personal mail with company oversight, not a ticket queue. The queue UI
was moved into Mailroom during the repository split by accident of convenience, not by design.

Consequences:

- `Mailroom/web` loses `/queue` and `/settings/{mailboxes,tags,canned-replies}`; OneOps gains
  `features/helpdesk` and Settings → Mail.
- The half-extracted Mailroom backend is deleted. Mail stays a module of the oneOps backend behind
  `api.prabhixtechnologies.com`, which is the only API host any Mailroom client talks to. A service
  extraction can be redone later on top of the shared identity client, when there is a reason.
- `Platform/marketing/src/content/products.ts` describes Helpdesk as a OneOps module and Mailroom as
  personal mail — and lists Mailroom as live once hosted addresses receive internet mail.

### Inbound transport

Outbound already uses SES in `ap-south-1`. For inbound, **SES email receiving in the same region**
(receipt rules → S3 → SNS → platform ingest) is the intended path: the region has
`inbound-smtp.ap-south-1.amazonaws.com`. That ingest is not wired yet (today's inbound is LMTP from
Postfix and IMAP poll; the existing SES SNS webhook is bounce/complaint only). Until it is,
inbound MX stays at GoDaddy. The fallback is a dedicated mail-server instance
(`Mailroom/mail-server`, compose profile `mailserver`). See [RUNBOOK-mail.md](../deploy/RUNBOOK-mail.md).
Mailroom is not marketed as live while MX still points at the registrar.

## Decision 2 — Flutter is the only mobile codebase

`Mobile/` (Flutter, Melos) is the single mobile implementation for all four apps. The native trees
were archived onto `archive/native-oneops`, `archive/native-mailroom`, and
`archive/native-mobistack` and removed from the product working trees. See
[Mobile/ARCHIVE.md](../../Mobile/ARCHIVE.md) and [SURFACES.md](SURFACES.md).

Why: three stacks at three levels of completeness is the whole cause of "the mobile app is not in sync
with the web app". The Flutter workspace already holds the shared identity and API packages and more
code than the other two combined.

Parity is defined per surface, not as "every web page on a phone". [SURFACES.md](SURFACES.md) is the
list of what each product offers on web, on mobile, and deliberately on web only.

## What is deliberately not shared

Authentication is centralised in Identity. Authorization is not: OneOps has organizations, roles and
around fifty permissions; MobiStack has shops with an inventory permission set, plan entitlements and
device limits. Identity answers "who is this"; each product answers "what may they do here" from its
own database. A service that owned both permission models would need a coordinated release of three
things for every permission change.

Platform staff authority (the `SUPPORT`, `BILLING`, `OPERATOR`, `SECURITY` and `OWNER` roles in the
oneOps database) is the **only** human admin authority. MobiStack's `system_admin` flag and Identity's
internal endpoints are reached through the oneOps backend acting on a staff member's behalf, over the
shared service token, and every such call names the acting user.

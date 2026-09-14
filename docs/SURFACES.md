# Surfaces — what each product offers, where

This replaces `mobile-api-contract.md`. Parity is the *mobile-appropriate subset*, not every web page
on a phone. Web-only surfaces stay on the web on purpose.

Flutter in `Mobile/` is the only mobile codebase that takes new work. Native trees
were archived (`archive/native-oneops`, `archive/native-mailroom`,
`archive/native-mobistack`); see [Mobile/ARCHIVE.md](../../Mobile/ARCHIVE.md).

Account management is not a product feature. Every app deep-links to Identity `/account`.

## OneOps

| Surface | Web | Flutter |
|---|---|---|
| Dashboard | yes | yes |
| Inbox (read / reply / assign) | yes | yes |
| Live chat | yes | yes |
| Visitors (live + detail) | yes | yes |
| Orders (view / fulfil) | yes | yes |
| Members (view / invite) | yes | yes |
| Notifications | yes | yes |
| Account | Identity `/account` | Identity `/account` |
| Product editing | yes | web only |
| Discounts | yes | web only |
| Feature flags | yes | web only |
| Event logs | yes | web only |
| AI settings | yes | web only |
| Files | yes | web only |

## Mailroom

| Surface | Web | Flutter |
|---|---|---|
| Mail (read, folders, flags) | yes | yes |
| Compose | yes | yes |
| Aliases and signature | yes | yes |
| Company mail mode (`MAIL_READ_ALL`) | yes | yes |
| Helpdesk queue | OneOps `/inbox` | OneOps Flutter inbox |
| Mail admin (domains, routing, tags, canned) | OneOps Settings → Mail | web only |

## MobiStack

| Surface | Web | Flutter |
|---|---|---|
| Fitment Catalog (shared commons) | yes | yes |
| My Shop (inventory, sales, repairs) | yes | yes |
| Purchases, suppliers, members, movements, inbox | yes | yes |
| Private fitment notes + propose-to-catalog | yes | yes |
| Barcode | yes | yes |
| Offline sync (commons subset) | — | yes |
| Catalog import | yes | web only |
| Audit log | yes | web only |
| Health | yes | web only |

## Admin console

Reached at `admin.prabhixtechnologies.com` (web) and the Admin Flutter app. Every write goes
through the oneOps BFF. The browser never calls MobiStack or Identity directly.

| Section | Staff role | Web | Flutter |
|---|---|---|---|
| Overview | any staff | yes | yes |
| Tenants and shops | SUPPORT | yes | yes |
| Identity (users, sessions, clients, keys, events) | SECURITY | yes | read + disable/unlock |
| Revenue (MRR, churn INR) | BILLING | yes | read |
| Infra (AWS, ECR, GitHub, Promote) | OPERATOR | yes | read + Promote |
| Mail health (SES, outbox, domains) | SUPPORT | yes | read |
| Staff grants + break-glass | OWNER | yes | grant + break-glass |
| MobiStack ops (releases, live users, kick, flags, plans) | SUPPORT | yes | kick + suspend shop |
| Commons review | SUPPORT | yes | read + approve |
| Event logs | any staff | yes | web only |

## Kill list for this document

The previous contract documented password login against product backends. That path is gone.
Sign-in is Identity OIDC + PKCE on every surface.

# Security remediation register

This is the release gate for `deploy/security-remediation-release.yml`. A row is complete only when
the code change, automated regression test, migration rehearsal and user-facing acceptance case all
pass. Production deployment and secret rotation remain separately approved operations.

## Release blockers

- [ ] `ID-01` Invite acceptance is bound to the authenticated, verified Identity email and subject;
  duplicate product users are reconciled.
- [ ] `ID-02` Verification, password-reset, magic-link, Google, passkey and logout journeys complete
  on Identity and return to the initiating product.
- [ ] `EDGE-01` No public host routes `/internal*` or MobiStack platform-admin APIs.
- [ ] `TENANT-01` Organization/shop isolation tests cover headers, path ids, repositories, files,
  chat, commerce, mail and staff `viewAs`.
- [ ] `MOBI-01` Full paid-shop inventory, purchase, sale, repair, customer, member and settings
  surfaces work on web and Flutter; catalog plans remain capability-scoped.
- [ ] `MOBI-02` A shop joins a fitment-sharing group only through owner-approved consent.
- [ ] `SALE-01` Server-authoritative prices/costs and bounded discounts protect stock and accounting.
- [ ] `COMMERCE-01` Discounts redeem only on idempotent captured payment; abandoned checkout is safe.
- [ ] `MAIL-01` Inbound mail is private/authenticated, Postfix is not a trusted-network relay, legacy
  mailbox credentials are encrypted, and redirect targets are safe.
- [ ] `CUTOVER-01` Identity/product user ids reconcile, all sessions revoke cleanly, and old clients
  receive an upgrade or security-sign-in recovery screen without losing business data.

## High and medium controls

- [ ] Dedicated service authentication, acting-staff validation, failed-token limits and audit.
- [ ] Trusted-proxy client IP resolution and Redis-degraded auth throttling.
- [ ] Generic account responses plus per-IP/account/destination authentication budgets.
- [ ] Public BFF credentials/origin policy, validated legacy token adoption and query-free chat SSE.
- [ ] Atomic seat, discount, inventory and payment transitions with concurrency tests.
- [ ] Razorpay event ordering and payment identifier/amount/currency validation.
- [ ] SNS confirmation HTTPS/AWS host validation.
- [ ] Production Swagger/actuator denial at application and edge.
- [ ] Notification, support and feature-flag permissions.
- [ ] Runtime role cannot create or overwrite production secrets.

## Low-severity and defence-in-depth controls

- [ ] Cryptographic rate-limit token keys and defined Redis fallback.
- [ ] POST-only logout and two-step magic links.
- [ ] Staff/admin WebAuthn user verification.
- [ ] Remote mail images blocked by default with an explicit load action.
- [ ] Dovecot break-glass file disabled or monitored in production.
- [ ] Production rejects known development credentials and monitoring defaults.
- [ ] Release mobile builds reject insecure issuers and validate deep links.
- [ ] Dependency audits, CSP checks, log redaction and minimum-version behavior pass.

## Evidence required before cutover

1. Approved immutable image/package/mobile versions recorded in the release manifest.
2. Production-like Flyway rehearsal and identity-reconciliation dry-run reports.
3. RDS recovery point, running image tags, Flyway ranks and previous secret-version ids recorded
   outside git without secret values.
4. New-user and returning-user E2E evidence for OneOps, Admin, MobiStack, Mailroom and storefront.
5. Payment sandbox and inbound/outbound mail evidence.
6. `deploy/smoke.ps1` success and named go/no-go authority.

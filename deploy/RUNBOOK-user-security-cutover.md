# User identity reconciliation and security cutover

This runbook preserves business records while moving every product to the hardened Identity
contract. Production execution requires an approved maintenance window. Never copy service tokens,
cookies, email addresses, or database credentials into tickets or logs.

## Preconditions

1. Record the approved image tags, mobile version codes, Flyway ranks, and RDS recovery point
   outside git.
2. Confirm the minimum supported mobile versions are available to users before enabling the gate.
3. Put write paths in maintenance mode and stop background workers that create users, invitations,
   payments, or mailboxes.
4. Verify Identity, oneOps, MobiStack, and Mailroom health from the private Docker network.

## Reconciliation

1. Call `GET /internal/oneops/users/reconcile/dry-run` from the private network with the dedicated
   service credential. Save only aggregate counts and conflict identifiers in the evidence record.
2. Stop if any group has no authoritative Identity UUID, conflicting tenant ownership, or a
   foreign-key conflict. Resolve that group explicitly; do not guess by creation date.
3. For each conflict-free email group, call `POST /internal/oneops/users/reconcile/apply` with the
   normalized email. The operation transfers every catalogued business-data foreign key to the
   Identity-backed user, retires the duplicate, and is safe to rerun.
4. Repeat the dry-run. The release gate requires zero actionable duplicate groups and zero
   unresolved foreign-key conflicts.
5. Run read-only tenant totals before and after reconciliation for organizations, memberships,
   invoices, payments, mailboxes, tickets, files, and audit events. Counts may move between user
   identifiers but must not disappear.

## Session revocation

1. Rotate credentials in the order defined by `RUNBOOK-secrets-rotation.md`.
2. Call `POST /internal/identity/sessions/revoke-all?reason=security_cutover` from the private
   network with the Identity service credential. Record only the returned counts.
3. Call the endpoint a second time. All returned counts must be zero; this proves the bounded batch
   operation finished and is idempotent.
4. Verify an old browser access token and refresh token are rejected, and an old mobile session is
   sent to the security sign-in screen without deleting its local business cache.

## User acceptance matrix

- New user: hosted registration -> email verification -> organization/shop onboarding -> product
  home; invite links return to the intended product after authentication.
- Existing matching user: security sign-in -> existing organization/shop and historical data;
  no duplicate organization or starter data is created.
- Existing user with the wrong active account: invite screen offers account switching, forces
  hosted login, then accepts only a verified email matching the invitation.
- Expired verification/reset/magic link: generic safe error -> resend -> two-step confirmation ->
  initiating product.
- Mobile user below the minimum version: blocking upgrade screen with store action; local data is
  retained. Supported versions show security sign-in and resume after authentication.
- Offline mobile user: cached business data remains readable where policy allows; mutations queue
  or fail clearly and never bypass server authorization or server-authoritative pricing.

## Go/no-go and rollback

Do not remove maintenance mode unless reconciliation is clean, global revocation is idempotent, and
the full acceptance matrix passes. On failure, keep writes disabled, restore the recorded image tags
and prior secret version ids, and restore the RDS recovery point only when data integrity—not merely
application behavior—was damaged. Never reactivate retired duplicate users independently; rerun the
reconciliation dry-run after rollback.

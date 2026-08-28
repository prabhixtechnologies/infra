# Prabhix Mail — End-to-End Email Subsystem

Three independent layers. Each works alone; together they give you a mail stack you own
outright, with no per-seat vendor fee.

```
                       ┌───────────────────────────────────────────┐
  Internet MX ────────►│  LAYER 1 · TRANSPORT   (mail-server/)     │
                       │  Postfix · Dovecot · Rspamd · OpenDKIM    │
                       └──────────────┬────────────────────────────┘
                                      │ LMTP push  /  IMAP pull
                       ┌──────────────▼────────────────────────────┐
                       │  LAYER 2 · SHARED INBOX  (mail/inbound,   │
                       │             mail/helpdesk)                │
                       │  MIME parse · thread · route · assign ·   │
                       │  SLA · tags · canned replies · notes      │
                       └──────────────┬────────────────────────────┘
                                      │
                       ┌──────────────▼────────────────────────────┐
                       │  LAYER 3 · TRANSACTIONAL (mail/outbound)  │
                       │  templates · outbox · retry · failover ·  │
                       │  bounce/complaint · open/click tracking   │
                       └───────────────────────────────────────────┘
```

---

## Current production state (prabhixtechnologies.com)

Mail is **deliberately not delivering** in production. `MAIL_TRANSPORT` is `SMTP_RELAY` pointed at
`localhost`, so sends fail and retry into the outbox until `MAIL_OUTBOX_MAX_ATTEMPTS` is reached.
The transport is set to a real value rather than `LOGGING` only because
`MailTransportStartupValidator` refuses to boot on `LOGGING` outside dev.

Two consequences worth knowing before relying on the platform: **password reset and email-OTP
sign-in cannot complete**, so the password login is the only way in; and `/actuator/health`
reports 503 because Spring's mail health indicator drags the aggregate down. Liveness and
readiness are unaffected, and the container healthcheck targets
`/actuator/health/readiness`, so this does not restart anything — but do not point an uptime
monitor at plain `/actuator/health`.

### What the domain's DNS already dictates

The domain is registered at GoDaddy and **already has working email there**, which constrains the
options more than the code does. Verified against `8.8.8.8`:

| Record | Live value | Consequence |
|---|---|---|
| `MX` | `0 smtp.secureserver.net`, `10 mailstore1.secureserver.net` | Inbound mail goes to GoDaddy, not here |
| `SPF` | `v=spf1 include:secureserver.net -all` | `-all` hard-fails anything sent from elsewhere |
| `DMARC` | `v=DMARC1; p=quarantine; ...` | Those failures get quarantined, not just marked |

So sending as `@prabhixtechnologies.com` through SES or any other provider **without first editing
SPF and publishing DKIM** lands in spam. This is the trap: the send succeeds, the logs look clean,
and the mail quietly never arrives.

Reachability from the EC2 host, tested directly:

| Port | Status |
|---|---|
| 587 / 465 (submission, GoDaddy · SES · M365) | open |
| 993 (IMAP over TLS) | open |
| 25 (raw SMTP) | **blocked** — AWS blocks egress by default |

Blocked :25 rules out Layer 1 self-hosting until AWS grants a limit removal *and* a PTR record on
the elastic IP.

### The two ways forward

**Relay through GoDaddy** — works with no DNS change, because SPF and DKIM already authorise
GoDaddy for this domain. Suited to OTPs and receipts; GoDaddy caps daily volume in the low
hundreds, so not for bulk. Note the backend's relay is Spring's `JavaMailSender`, so it reads the
`SMTP_*` variables below, **not** the `MAIL_RELAY_*` ones — those configure Postfix's smarthost in
the optional `mail-server` stack and the backend ignores them.

```
MAIL_TRANSPORT=SMTP_RELAY
SMTP_HOST=smtpout.secureserver.net   # GoDaddy Professional Email, per the MX above.
SMTP_PORT=587                        # M365-through-GoDaddy would be smtp.office365.com instead.
SMTP_AUTH=true
SMTP_STARTTLS=true
SMTP_USERNAME=<mailbox address>
SMTP_PASSWORD=<mailbox password, or an app password if 2FA is on>
MAIL_FROM=<the same mailbox address>
```

`MAIL_FROM` has to match the authenticated mailbox: GoDaddy rejects mismatched senders, so the
default `no-reply@` fails unless a mailbox by that name genuinely exists.

**Move to SES** for volume. Needs an IAM policy allowing `ses:SendRawEmail` — the `prabhix` IAM
user currently has no SES permissions at all — plus DKIM CNAMEs and `include:amazonses.com` added
to SPF. The instance already carries an instance profile, so SES can authenticate through the
default credential chain and needs no static keys; `PrabhixProperties.Mail.Ses` falls back to that
whenever the access key is blank.

Receiving is a separate decision. `DomainMode.EXTERNAL_IMAP` is the default precisely so the
platform can pull from an existing host over IMAP and leave MX where it is; taking over MX is only
required for Layer 1.

---

## Layer 1 — Self-hosted transport (`mail-server/`)

### Components

| Container | Image basis | Role |
|---|---|---|
| `postfix` | Alpine + Postfix 3.9 | MTA. Receives on :25 (MX), submission on :587/:465. Relays outbound. |
| `dovecot` | Alpine + Dovecot 2.3 | IMAP/POP3 store (Maildir), LMTP delivery target, SASL auth source. |
| `rspamd` | rspamd/rspamd | Spam filtering, DKIM signing/verification, greylisting, DMARC reporting. |
| `mail-auth` | our backend | Postfix/Dovecot ask the platform "does this mailbox exist / is this password valid" over a tiny HTTP socketmap + auth endpoint. |

Mailboxes are **not** files in a config — they live in Postgres (`mail_domains`,
`mail_mailboxes`, `mail_aliases`) and are provisioned through the platform UI. Postfix
resolves recipients via a `socketmap` lookup against `mail-auth`, so adding a mailbox takes
effect immediately with no reload.

### Deliverability checklist (non-negotiable)

Self-hosting mail fails on deliverability, not on software. All of these are automated by
`mail/provisioning`, which generates the exact DNS records to publish per domain:

| Record | Purpose |
|---|---|
| `MX` | `10 mail.prabhixtechnologies.com` |
| `SPF` | `v=spf1 mx a:mail.prabhixtechnologies.com -all` |
| `DKIM` | 2048-bit key per domain, selector rotated yearly; public key in `<selector>._domainkey` |
| `DMARC` | `v=DMARC1; p=quarantine; rua=mailto:dmarc@...; pct=100` |
| `PTR` | Reverse DNS on the EC2 elastic IP must match the HELO name |
| `MTA-STS` + `TLS-RPT` | Enforce TLS for inbound |
| `A` | `mail.` → elastic IP |

The provisioning service exposes `GET /api/v1/mail/domains/{id}/dns` returning the required
records plus a live verification status for each, and re-checks them on a schedule.

> **Operational note:** AWS blocks outbound :25 on EC2 by default and must be unblocked by
> support request. Until then, Postfix relays outbound through SES/Sendinblue as a smarthost
> while still owning inbound. `MAIL_RELAY_HOST` switches this.

---

## Layer 2 — Shared inbox / helpdesk

### Data model

```
mail_domains ──< mail_mailboxes ──< mail_threads ──< mail_messages ──< mail_attachments
                       │                  │                 │
                       │                  ├──< mail_thread_tags
                       │                  ├──< mail_thread_notes      (internal, never sent)
                       │                  ├──  assignee → users
                       │                  └──  sla_due_at, first_response_at
                       ├──< mail_routing_rules
                       └──< mail_mailbox_members   (which agents can see this inbox)
```

A **mailbox** is a shared address (`support@`, `sales@`, `hr@`). A mailbox has members,
routing rules, a signature, an SLA policy, and business hours. A **thread** is a
conversation; a **message** is one email in it, `direction ∈ {INBOUND, OUTBOUND}`.

### Ingestion pipeline

```
ImapFetchScheduler (per mailbox, staggered)
   → fetch UIDs > last_seen_uid          (UIDVALIDITY-aware)
   → for each: raw MIME → S3, row → mail_inbound_raw
   → MimeParser: headers, text/html body, inline vs attached parts, charset repair
   → dedupe on (mailbox_id, message_id_header)      ← idempotency
   → ThreadResolver
   → RoutingRuleEngine
   → SlaCalculator + assignment
   → publish MailMessageReceivedEvent → notify/ + SSE fan-out
```

Every stage is restartable. `mail_inbound_raw` keeps the original bytes, so a parser bug can
be fixed and the batch replayed without data loss.

### Threading algorithm

1. If `In-Reply-To` or `References` matches a known `message_id_header` → that thread.
2. Else if the subject contains our thread token `[#PBX-a1b2c3]` → that thread.
3. Else if normalized subject (strip `Re:`/`Fwd:`/whitespace/case) matches an open thread in
   the same mailbox **and** the participant sets intersect **and** it is < 30 days old → that thread.
4. Else → new thread.

Outbound messages inject the thread token into the subject and set `In-Reply-To`, so replies
from any client thread correctly even if the remote mailer mangles `References`.

### Routing rules

Declarative, evaluated in priority order, first match wins unless `continue = true`:

```json
{
  "name": "Enterprise tickets to Tier 2",
  "priority": 10,
  "conditions": [
    { "field": "FROM_DOMAIN", "op": "IN",       "value": ["acme.com", "globex.com"] },
    { "field": "SUBJECT",     "op": "CONTAINS", "value": "outage" }
  ],
  "match": "ALL",
  "actions": [
    { "type": "ASSIGN_TEAM",  "value": "tier-2" },
    { "type": "SET_PRIORITY", "value": "URGENT" },
    { "type": "ADD_TAG",      "value": "incident" },
    { "type": "APPLY_SLA",    "value": "enterprise-1h" }
  ]
}
```

Supported fields: `FROM`, `FROM_DOMAIN`, `TO`, `CC`, `SUBJECT`, `BODY`, `HAS_ATTACHMENT`,
`SPAM_SCORE`, `HEADER:<name>`. Operators: `EQUALS`, `CONTAINS`, `MATCHES` (regex, timeout-guarded),
`IN`, `GT`, `LT`.

### Collision prevention

Two agents replying to the same customer is the classic shared-inbox failure. Prevented by:

- **Presence** — `mail_thread_viewers` in Redis with a 30s TTL, broadcast over SSE
  ("Priya is viewing", "Priya is typing").
- **Optimistic assignment** — replying to an unassigned thread claims it atomically.
- **Draft locks** — one active draft per thread per mailbox, surfaced to everyone.

### SLA

Per-mailbox policy: first-response target, resolution target, business-hours calendar
(timezone + working days + holidays). `SlaCalculator` computes `sla_due_at` in business
minutes, pauses while a thread is `PENDING_CUSTOMER`, and a scheduled job escalates breaches.

---

## Layer 3 — Transactional engine

### Templates

Thymeleaf templates stored in the database per organization (with file-based defaults),
rendered server-side with a strict variable contract:

```
mail_templates(organization_id, key, locale, subject, html_body, text_body, variables jsonb)
```

`key` examples: `auth.magic-link`, `auth.otp`, `billing.invoice`, `billing.dunning`,
`org.invite`, `mail.sla-breach`. A template renders to both HTML and a plain-text
alternative; missing required variables fail at render time, not at send time.

### Outbox and workers

Nothing sends inside a request transaction:

```
service → mail_outbox INSERT (status=PENDING, dedupe_key, priority, scheduled_at)
                │
       commit ──┘
                ▼
OutboxWorker ×N:  SELECT ... WHERE status='PENDING' AND scheduled_at <= now()
                  ORDER BY priority, scheduled_at
                  FOR UPDATE SKIP LOCKED  LIMIT 50
                → render → send via provider → status=SENT / FAILED(+attempt, next_retry_at)
```

- `dedupe_key` makes "send the invoice email" idempotent across retries and redeploys.
- Retry is exponential with jitter, capped at 6 attempts, then `DEAD` + alert.
- `SELECT ... FOR UPDATE SKIP LOCKED` means you can run as many workers as you like.

### Provider abstraction and failover

```java
public interface MailTransport {
    MailTransportResult send(OutboundMail mail);
    String providerId();
    boolean healthy();
}
```

Implementations: `SelfHostedSmtpTransport` (our Postfix), `SesTransport`, `SmtpRelayTransport`,
`LoggingTransport` (dev). A `MailTransportRouter` picks by organization policy, message class
(transactional vs bulk), and a circuit breaker on recent failure rate — so a Postfix outage
silently drains through SES instead of queueing indefinitely.

### Bounces, complaints, suppression

- Inbound bounces (DSN) and `List-Unsubscribe` hits are parsed into `mail_suppressions`.
- A suppressed address is skipped at outbox drain time with reason `SUPPRESSED`.
- Hard bounce → permanent suppression. Soft bounce → 3 strikes in 7 days → suppression.
- Complaint (FBL / ARF) → immediate permanent suppression + audit entry.

### Tracking

Opt-in per template, off by default for auth mail:

- **Open** — 1×1 GIF at `/api/v1/mail/t/o/{token}`.
- **Click** — links rewritten to `/api/v1/mail/t/c/{token}` then 302.
- Tokens are HMAC-signed, single-purpose, and carry no PII.

---

## API surface (selected)

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v1/mail/mailboxes` | Inboxes visible to the caller |
| `POST` | `/api/v1/mail/mailboxes` | Create a shared inbox |
| `GET` | `/api/v1/mail/threads` | Cursor-paginated, filter by mailbox/status/assignee/tag |
| `GET` | `/api/v1/mail/threads/{id}` | Thread with messages, notes, events |
| `POST` | `/api/v1/mail/threads/{id}/reply` | Reply (queues to outbox) |
| `POST` | `/api/v1/mail/threads/{id}/assign` | Assign to user or team |
| `PATCH` | `/api/v1/mail/threads/{id}` | Status, priority, tags |
| `POST` | `/api/v1/mail/threads/{id}/notes` | Internal note |
| `GET` | `/api/v1/mail/domains/{id}/dns` | Required DNS records + verification status |
| `POST` | `/api/v1/mail/templates/{key}/preview` | Render a template with sample variables |
| `GET` | `/api/v1/mail/stream` | SSE — new mail, presence, assignment changes |
| `POST` | `/api/v1/mail/inbound/lmtp` | Push ingestion from Postfix (internal, mTLS) |

---

## Why pull *and* push

IMAP polling works everywhere, including against Google Workspace and Zoho, so it is the
default and the only thing needed if you never self-host. LMTP push from our own Postfix is
near-instant and avoids polling cost, so it takes over once the mail server is live. Both
paths converge on the same `MailIngestionService`, so behaviour is identical either way.

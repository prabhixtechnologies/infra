# Prabhix Platform — Log Taxonomy

Operational event catalogue for the Prabhix Technologies platform. Every event emitted by application code must use a `LogEventCode` enum entry — raw string codes are not permitted.

## Audit log vs event log

| | **Audit log** (`audit_logs`) | **Event log** (`event_logs`) |
|---|---|---|
| **Purpose** | Compliance: who changed what | Operations: what happened in the system |
| **Typical consumer** | Security officer, compliance | Support, SRE, owner diagnosing incidents |
| **Content** | Actor, resource, field-level changes, outcome | Event code, severity, safe payload, correlation id |
| **Cross-reference** | Include `correlationId` in audit `metadata` | Always stores `correlation_id` column |
| **Retention** | Monthly partitions, long retention | Configurable (`prabhix.observability.event-log-retention`, default 90d) |

Use **both** for security-sensitive mutations: audit for the compliance record, event log for operational search and alerting.

## Configuration

| Property | Default | Description |
|---|---|---|
| `prabhix.observability.log-format` | `console` | Set to `json` in production for log shipping |
| `prabhix.observability.event-log-retention` | `P90D` | Postgres event log retention |
| `prabhix.observability.event-log-retention-cron` | `0 45 2 * * *` | Nightly purge job |
| `prabhix.observability.slow-request-threshold` | `PT1S` | Access log slow flag |
| `prabhix.observability.sample-rate` | `1.0` | HTTP access log sampling (0–1) |

**Production JSON logs:** set environment variable `LOG_FORMAT=json` or `prabhix.observability.log-format=json`.

## Redaction policy

Never logged (application or persisted payload):

- `Authorization` headers, bearer tokens, refresh tokens, API keys, passwords
- Card numbers, CVV, full PAN
- Request/response bodies on `/auth/**`, `/billing/webhooks/**`, payment and webhook endpoints

The `LogRedactor` utility enforces this before structured logging and persistence.

## Event catalogue

Source of truth: `com.prabhix.platform.observability.taxonomy.LogEventCode`

See the enum for the full list of 100+ codes covering AUTH, ORG, MAIL, BILLING, COMMERCE, CHAT, VISITOR, FILE, AI, JOB, INTEGRATION, SECURITY, and PLATFORM domains. Each entry declares: dotted code, category, severity, security-sensitive flag, and PII flag.

**Retention:** all event log rows honour `prabhix.observability.event-log-retention` (default 90 days).

## API endpoints

| Method | Path | Permission |
|---|---|---|
| GET | `/api/v1/event-logs` | `LOG_READ` |
| GET | `/api/v1/event-logs/{id}` | `LOG_READ` |
| GET | `/api/v1/event-logs/trace/{correlationId}` | `LOG_READ` |
| GET | `/api/v1/event-logs/stats` | `LOG_READ` |
| GET | `/api/v1/event-logs/export?format=csv\|ndjson` | `LOG_EXPORT` |

Platform admins may pass `organizationId` to query another tenant.

## Correlation

Every HTTP request receives `X-Correlation-Id`. The same value is echoed on the response and stored on event log rows.

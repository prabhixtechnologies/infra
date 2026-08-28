# Prabhix Operator Mobile API Contract

Shared contract for the native Android (Kotlin) and iOS (Swift) operator apps. Derived from the Spring Boot backend at `backend/` — **do not guess**; update this doc when controllers change.

**Base URL:** `{API_HOST}/api/v1` (default dev: `http://localhost:8080/api/v1`)

**OpenAPI:** `{API_HOST}/v3/api-docs` (springdoc)

---

## Global request conventions

| Header | Required | Value |
|--------|----------|-------|
| `Authorization` | Authenticated routes | `Bearer {accessToken}` |
| `X-Prabhix-Org` | When acting in a specific org | UUID — must match token org or user must call org select first |
| `X-Correlation-Id` | Recommended | Client-generated UUID; echoed in response on errors |
| `X-Prabhix-Device` | Recommended | `mobile-android` or `mobile-ios` |
| `Content-Type` | JSON bodies | `application/json` |

**Tenancy:** The JWT embeds the active `organizationId`. Multi-org users call `POST /organizations/{id}/select` to receive new tokens scoped to that org. `X-Prabhix-Org` can pin org per request but cannot bypass membership (returns `CROSS_TENANT_ACCESS`).

---

## Error envelope

Every failure returns:

```json
{
  "code": "TOKEN_EXPIRED",
  "message": "Human-readable, safe to show",
  "fieldErrors": { "email": "must be valid" },
  "traceId": "a1b2c3d4",
  "path": "/api/v1/auth/login",
  "timestamp": "2026-08-28T10:00:00Z"
}
```

- Branch on `code` (enum name), never on `message`.
- `fieldErrors` is present for `VALIDATION_FAILED`.
- `traceId` correlates with server logs (first 8 chars of correlation id).

Common codes: `UNAUTHENTICATED`, `TOKEN_EXPIRED`, `TOKEN_INVALID`, `TOKEN_REVOKED`, `PERMISSION_DENIED`, `INVALID_CURSOR`, `RATE_LIMITED`, `STALE_RESOURCE`.

---

## Cursor pagination

All large lists use **keyset pagination**, not page numbers.

**Request:** `?cursor={opaque}&limit={1..200}` — omit `cursor` for first page. Default limit 25, max 200.

**Response:**

```json
{
  "items": [ ... ],
  "nextCursor": "base64url-encoded-opaque-string-or-null",
  "hasMore": true
}
```

Treat `nextCursor` as opaque. Sort key server-side is `(created_at desc, id desc)`.

---

## Authentication

### POST `/auth/login`

```json
{ "email": "agent@example.com", "password": "...", "deviceId": "uuid", "deviceName": "Pixel 8", "deviceType": "MOBILE" }
```

**Response `TokenResponse`:**

```json
{
  "accessToken": "eyJ...",
  "refreshToken": "...",
  "expiresInSeconds": 900,
  "organizationId": "uuid-or-null",
  "permissions": ["CHAT_READ", "MAIL_READ", ...]
}
```

### POST `/auth/refresh`

```json
{ "refreshToken": "..." }
```

Returns new `TokenResponse`. Implement **single-flight refresh** on 401.

### POST `/auth/logout` (authenticated)

```json
{ "refreshToken": "..." }
```

### GET `/auth/me` (authenticated)

```json
{
  "userId": "uuid",
  "email": "...",
  "displayName": "...",
  "organizationId": "uuid",
  "sessionId": "uuid",
  "permissions": ["..."],
  "platformAdmin": false
}
```

### Passwordless

| Method | Path | Body |
|--------|------|------|
| POST | `/auth/magic-link/request` | `{ "email" }` → `{ "message" }` |
| POST | `/auth/magic-link/verify` | `{ "token" }` → `TokenResponse` |
| POST | `/auth/otp/request` | `{ "email" }` → `{ "message" }` |
| POST | `/auth/otp/verify` | `{ "email", "code" }` → `TokenResponse` |

---

## Organizations

| Method | Path | Permission | Notes |
|--------|------|------------|-------|
| GET | `/organizations` | authenticated | List orgs for current user |
| POST | `/organizations/{id}/select` | authenticated | Returns new `TokenResponse` for org |

**OrganizationView:** `{ id, name, slug, status, memberCount, seatLimit, trialEndsAt, timezone, locale, currency, createdAt }`

---

## Chat

Permissions: `CHAT_READ`, `CHAT_READ_ALL`, `CHAT_REPLY`, `CHAT_ASSIGN`, `CHAT_MANAGE`

### Queues

| `queue` param | Meaning | Permission |
|---------------|---------|------------|
| `mine` | Assigned to current agent | `CHAT_READ` |
| `unassigned` | No assignee | `CHAT_READ` |
| `all` | Every conversation | `CHAT_READ_ALL` |

Default queue: `mine` (or `all` if user has `CHAT_READ_ALL`).

Optional `status` filter: `OPEN`, `PENDING`, `RESOLVED`, `CLOSED`.

### Endpoints

| Method | Path | Notes |
|--------|------|-------|
| GET | `/chat/conversations?queue=&status=&cursor=&limit=` | `CursorPage<ConversationSummary>` |
| GET | `/chat/conversations/counts` | `{ unassigned, mineUnread }` |
| GET | `/chat/conversations/{id}` | Detail + embedded messages |
| GET | `/chat/conversations/{id}/messages?cursor=&limit=` | Paginated history (newest first) |
| POST | `/chat/conversations/{id}/messages?note=false` | Send reply; `note=true` or body `{ internal: true }` for internal note |
| POST | `/chat/conversations/{id}/assign` | `{ agentId }` |
| PATCH | `/chat/conversations/{id}` | `{ status, priority, tags }` |
| GET | `/chat/canned-replies` | List canned replies |
| GET | `/chat/settings` | `CHAT_MANAGE` |

**ConversationSummary:** `{ id, status, priority, subject, visitorName, visitorEmail, assignedAgentId, tags, unreadAgentCount, lastMessageAt, lastMessagePreview, visitorId }`

**MessageView:** `{ id, senderType, senderUserId, body, fileId, occurredAt }`

**SenderType:** `VISITOR`, `AGENT`, `SYSTEM`, `NOTE` — render `NOTE` distinctly from customer-visible replies.

**Priority:** `LOW`, `NORMAL`, `HIGH`, `URGENT`

### SSE realtime — GET `/chat/stream`

- `Accept: text/event-stream`
- Events named `message` (JSON body) or `heartbeat` (`ping`)
- Message payload: `{ "type": "message", "conversationId": "uuid", "payload": { "messageId", "senderType" } }`
- Heartbeat every 15s — use for keepalive detection
- Reconnect with exponential backoff; on resume, fetch conversations/messages since last known timestamp

---

## Mail

Permissions: `MAIL_READ`, `MAIL_READ_ALL`, `MAIL_SEND`, `MAIL_ASSIGN`, `MAIL_THREAD_UPDATE`, `MAIL_NOTE_WRITE`, `MAIL_MAILBOX_READ`

| Method | Path | Notes |
|--------|------|-------|
| GET | `/mail/threads?mailboxId=&status=&priority=&assigneeUserId=&tagId=&unreadOnly=&hasAttachment=&q=&cursor=&limit=` | Inbox |
| GET | `/mail/threads/{id}` | Thread + messages + notes + events |
| PATCH | `/mail/threads/{id}` | `{ status, priority }` |
| POST | `/mail/threads/{id}/reply` | `{ to[], cc[], subject, bodyHtml, attachmentIds[] }` |
| POST | `/mail/threads/{id}/assign` | `{ userId }` or `{ teamId }` |
| POST | `/mail/threads/{id}/unassign` | |
| POST | `/mail/threads/{id}/notes` | `{ bodyHtml }` |
| POST | `/mail/threads/{id}/tags` | `{ tagId }` |
| DELETE | `/mail/threads/{id}/tags/{tagId}` | |
| GET | `/mail/mailboxes` | Shared inboxes |
| GET | `/mail/canned-replies` | |
| GET | `/mail/tags` | Tag list |

**ThreadStatus:** `OPEN`, `PENDING_CUSTOMER`, `ON_HOLD`, `RESOLVED`, `CLOSED`, `SPAM`, `TRASH`

**ThreadSummary:** includes `slaDueAt`, `slaBreachedAt` for SLA alerts.

### SSE — GET `/mail/stream`

Same pattern as chat. Event body: `{ "type": "new-message"|"presence"|..., "payload": {} }`

---

## Visitors

Permission: `VISITOR_READ`, `VISITOR_ANALYTICS`

| Method | Path | Notes |
|--------|------|-------|
| GET | `/visitors/live` | `[ LiveVisitor ]` — currently on site |
| GET | `/visitors?cursor=&limit=` | Historical visitors |
| GET | `/visitors/{id}` | Profile + sessions |
| GET | `/visitors/analytics/summary?days=30` | `VISITOR_ANALYTICS` |

**LiveVisitor:** `{ visitorId, externalKey, currentPath, currentTitle, since, email, displayName }`

To chat with a live visitor: use `visitorId` when creating/finding a conversation (agent-initiated chat may require matching by visitor — use conversation list filtered or backend follow-up for proactive chat endpoint).

---

## Dashboard

| Method | Path | Notes |
|--------|------|-------|
| GET | `/dashboard` | Aggregate KPIs |

**DashboardResponse:**

```json
{
  "kpis": {
    "openThreads": 0,
    "avgFirstResponseMinutes": 0.0,
    "slaBreaches": 0,
    "seatsUsed": 0,
    "seatsLimit": 0,
    "mrr": 0,
    "currency": "INR"
  },
  "recentActivity": [{ "id", "type", "description", "actor", "createdAt" }],
  "threadsTrend": [{ "date", "value" }],
  "responseTimeTrend": [{ "date", "value" }]
}
```

Combine with `GET /chat/conversations/counts` for chat-specific operator metrics.

---

## Files (attachments)

| Method | Path | Permission |
|--------|------|------------|
| GET | `/files/{id}` | `FILE_READ` — download (302 redirect or bytes) |
| POST | `/files` | `FILE_UPLOAD` — multipart `file`, `purpose=MAIL_ATTACHMENT` |

---

## Permissions vocabulary

UI must hide actions the user cannot perform. Full enum in `Permission.java`. Mobile-relevant subset:

- Chat: `CHAT_READ`, `CHAT_READ_ALL`, `CHAT_REPLY`, `CHAT_ASSIGN`, `CHAT_MANAGE`
- Mail: `MAIL_READ`, `MAIL_SEND`, `MAIL_ASSIGN`, `MAIL_THREAD_UPDATE`, `MAIL_NOTE_WRITE`
- Visitors: `VISITOR_READ`
- Files: `FILE_READ`, `FILE_UPLOAD`
- Org: `ORG_READ`

---

## Push notifications — **BACKEND FOLLOW-UP REQUIRED**

No push-token endpoint exists today. Client apps implement against this proposed contract:

### POST `/devices/push-tokens` (authenticated)

```json
{
  "token": "fcm-or-apns-device-token",
  "platform": "FCM",
  "deviceId": "stable-install-id",
  "deviceName": "Pixel 8 Pro",
  "appVersion": "1.0.0"
}
```

`platform`: `FCM` | `APNS`

**Response:** `204 No Content` or `{ "id": "uuid" }`

### DELETE `/devices/push-tokens/{token}` (authenticated)

Unregister on logout.

### Server → device payload (FCM/APNs data)

```json
{
  "type": "chat.assigned" | "chat.message" | "mail.new" | "mail.sla_breach" | "mention",
  "organizationId": "uuid",
  "conversationId": "uuid",
  "threadId": "uuid",
  "title": "...",
  "body": "..."
}
```

Deep link: `prabhix://chat/{conversationId}` or `prabhix://mail/{threadId}`

**Client behavior when endpoint 404:** Log once, continue; local notifications from SSE while foregrounded.

---

## Local dev networking

| Environment | API host |
|-------------|----------|
| Android Emulator | `http://10.0.2.2:8080` |
| iOS Simulator | `http://localhost:8080` |
| Physical device | `http://{LAN_IP}:8080` |

CORS does not apply to native apps. Ensure backend binds `0.0.0.0` or machine firewall allows port 8080.

---

## Idempotency for outbound queue

When offline, queue outbound chat messages with client-generated `Idempotency-Key: {uuid}` header on `POST /chat/conversations/{id}/messages`. **Backend follow-up:** honor this header to prevent double-send on retry. Until then, client tracks pending message local IDs and dedupes on flush.

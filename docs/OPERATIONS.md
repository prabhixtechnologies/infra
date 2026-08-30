# Operations — PgBouncer, monitoring, and realtime SSE

## PgBouncer

The Compose stack routes application traffic through **PgBouncer** in **transaction pooling** mode.
Postgres remains reachable as `postgres:5432` for admin access; the backend uses `pgbouncer:5432`.

### JDBC requirement (application.yml)

Transaction pooling forbids server-side prepared statements. The Compose `DB_URL` includes
`prepareThreshold=0`. If you run the backend outside Compose, set:

```yaml
spring:
  datasource:
    url: jdbc:postgresql://pgbouncer:6432/oneops?prepareThreshold=0
```

### Flyway (direct Postgres)

Flyway should **not** use PgBouncer (migrations need session-level features). Add to
`application.yml` (outside this package's scope):

```yaml
spring:
  flyway:
    url: ${FLYWAY_URL:${spring.datasource.url}}
```

In Compose / prod env:

```bash
FLYWAY_URL=jdbc:postgresql://postgres:5432/oneops
DB_URL=jdbc:postgresql://pgbouncer:5432/oneops?prepareThreshold=0
```

Until `spring.flyway.url` is wired, Flyway runs against whatever `DB_URL` points at — use direct
Postgres for the first deploy after adding PgBouncer, or run migrations manually against `postgres`.

### Pool sizing

| Setting | Value | Rationale |
|---------|-------|-----------|
| `MAX_CLIENT_CONN` | 10,000 | Many backend replicas × Hikari pools without opening 10k PG backends |
| `DEFAULT_POOL_SIZE` | 50 | Server connections per db/user; multiplexes idle SSE-heavy instances |
| `MAX_DB_CONNECTIONS` | 80 | Stays under Postgres `max_connections` with admin/Flyway headroom |

Each backend instance uses `DB_POOL_MAX` (default 20) Hikari connections toward PgBouncer, not Postgres.

---

## Monitoring (Compose profile)

Prometheus and Grafana are behind the **`monitoring`** profile so normal local dev stays light:

```bash
# Local with metrics
docker compose -f docker-compose.yml -f docker-compose.local.yml --profile monitoring up

# Prod (add profile to deploy command when ready)
docker compose -f docker-compose.yml -f docker-compose.prod.yml --profile monitoring up -d
```

| Service | URL (local) | Notes |
|---------|-------------|-------|
| Prometheus | http://localhost:9090 | Scrapes backend every 15s |
| Grafana | http://localhost:3001 | Default `admin` / `admin` (override via env) |

### Actuator auth

`/actuator/prometheus` requires **`PLATFORM_ADMIN`** authority. Prometheus uses bearer token auth:

1. Copy `docker/prometheus/secrets/bearer_token.example` to `docker/prometheus/secrets/bearer_token`
2. Paste a valid platform-admin JWT (or service token once available)
3. Restart Prometheus

Optional hardening (requires `SecurityConfig` change): permit `/actuator/prometheus` from the Docker
internal network only.

### Alerts

Rules live in `docker/prometheus/alerts.yml`:

- API 5xx error rate
- API p99 latency
- Mail outbox pending / failed (`prabhix_mail_outbox_*`)
- SSE connection count (`prabhix_realtime_sse_connections`)
- HikariCP pool saturation
- Backend scrape / availability

Mail outbox **age** is not exported today; pending count is the proxy alert.

### Dashboard

Grafana loads `docker/grafana/dashboards/prabhix-platform.json` via provisioning.

---

## Realtime SSE

SSE streams (mail, chat, AI, visitor presence) share one `RedisMessageListenerContainer` via
`RealtimeChannelRegistry`. Each Redis channel is subscribed once per backend instance; local
`SseEmitter`s are reference-counted per channel.

Metric: `prabhix.realtime.sse.connections` (Prometheus: `prabhix_realtime_sse_connections`).

Heartbeats: `event: heartbeat` / `data: ping` every 15 seconds (unchanged wire format).

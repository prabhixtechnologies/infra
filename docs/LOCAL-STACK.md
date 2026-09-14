# Local laptop stack (no AWS, no git push)

> **One login:** see [AUTH-ARCHITECTURE.md](./AUTH-ARCHITECTURE.md). Credentials only on Identity `:8081`.

## Signup (Create an account)

Hosted signup at `http://localhost:8081/signup` is shown when Identity and the platform share
`IDENTITY_SERVICE_TOKEN` (compose.local defaults to `local-dev-identity-service-token`). That call
creates the **OneOps organization**; MobiStack shops are created after sign-in in the app.

Products should start registration with OIDC `prompt=create` (OneOps / MobiStack `beginSignup`) so
the browser returns to the product that started signup.

## URL matrix (env-controlled)

Product links are build-time. Missing marketing env used to fall back to **production** hostnames — that is why local “Mailroom” opened prod. Defaults are now **localhost**; Docker and `.env.local` must still set them explicitly.

| Surface | Local URL | Env key |
|---|---|---|
| Marketing | http://localhost:3000 | `NEXT_PUBLIC_SITE_URL` |
| OneOps | http://localhost:5173 | `NEXT_PUBLIC_CONSOLE_URL` / `VITE_IDENTITY_ISSUER` |
| Admin | http://localhost:5174 | `ADMIN_URL` |
| Mailroom | http://localhost:5175 | `NEXT_PUBLIC_MAILROOM_URL` |
| MobiStack | http://localhost:5176 | `NEXT_PUBLIC_MOBISTACK_URL` |
| Identity | http://localhost:8081 | `NEXT_PUBLIC_IDENTITY_ISSUER` / `VITE_IDENTITY_ISSUER` |
| App store | http://store.prabhixtechnologies.com:8090 | `NEXT_PUBLIC_STORE_URL` |
| MobiStack API (direct) | http://localhost:8082 | (compose publish only) |

Marketing: `Platform/marketing/.env.local` for `npm run dev`; Infra compose passes the same as Docker **build args**.

## Quick start (full local stack)

```powershell
cd Infra
docker compose -f docker-compose.yml -f docker-compose.local.yml --profile identity --profile mailroom --profile mobistack up -d --build
```

Core: postgres, redis, mailpit, identity (:8081), app-store (:8090), platform backend/web/admin/marketing, mailroom web (:5175), MobiStack API (:8082) and web (:5176).

Sign in at Identity `http://localhost:8081` with the seeded owner
(`admin@prabhixtechnologies.com` / `dev-password` after both seed scripts).

## Hosts file (Administrator once)

```
127.0.0.1 store.prabhixtechnologies.com
```

Then open http://store.prabhixtechnologies.com:8090/

## Identity DB on an existing Postgres volume

Init scripts only run on empty data dirs. If Identity fails with `password authentication failed for user "identity"`:

```powershell
docker exec -e PGPASSWORD=prabhix prabhix-postgres-1 psql -h 127.0.0.1 -U prabhix -d postgres -c "CREATE ROLE identity LOGIN PASSWORD 'identity';"
docker exec -e PGPASSWORD=prabhix prabhix-postgres-1 psql -h 127.0.0.1 -U prabhix -d postgres -c "CREATE DATABASE identity OWNER identity;"
docker exec -e PGPASSWORD=prabhix prabhix-postgres-1 psql -h 127.0.0.1 -U prabhix -d identity -c "CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS citext;"
```

(This volume uses `prabhix`/`prabhix` — not the `.env.example` `oneops` defaults.)

## Mailroom's API

There is no Mailroom backend. The web client and the Flutter app talk to the platform backend on
`:8080` for everything (`/api/v1/mailbox/*` for personal mail); the partial `:8083` extraction was
deleted. See `PRODUCTS.md`, decision 1.

## APKs

Drop files into `store-artifacts/{mobistack,oneops,mailroom}/android.apk`.

## MobiStack

Included in the Infra compose `mobistack` profile (same command as Quick start). Local overlay
publishes **:5176** (web) and **:8082** (API) on the shared postgres/redis. Do not start the
old MobiStack compose project alongside this — it collided on service names.

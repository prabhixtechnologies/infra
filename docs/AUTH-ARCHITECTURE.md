# One sign-in architecture (local)

## The rule

**Prabhix Identity is the only place that collects credentials.**

| Surface | Role |
|---|---|
| Identity `:8081` (prod: `api.prabhixtechnologies.com` when deployed) | Hosted login / signup / passkeys / SMS / WhatsApp / Google |
| OneOps `:5173`, Admin `:5174`, Mailroom `:5175`, MobiStack web | OIDC clients only — redirect to Identity, redeem code at `/auth/callback` |
| Marketing `:3000` | Company site — “Sign in” opens a **product**, which then starts OIDC |

## Why you used to see three different login UIs

1. **`localhost:5173/login` with purple Password / Magic link / Email OTP** — old OneOps console build (credentials in the product). **Removed.** Hard-refresh or rebuild if you still see it.
2. **`localhost:8081/login`** — local Identity (correct for laptop).
3. **`api.prabhixtechnologies.com/login`** — **production** Identity (old “PA” UI until you approve an AWS redeploy). Bookmarks and builds pointed at prod will keep showing that.

Local compose forces `VITE_IDENTITY_ISSUER=http://localhost:8081` so the laptop never silently talks to production Identity.

## Product URLs must be env-driven

Marketing and Identity product redirects are controlled by env (and Docker **build args** for Next/Vite):

- `NEXT_PUBLIC_MAILROOM_URL` → Mailroom web (`http://localhost:5175` locally)
- `NEXT_PUBLIC_MOBISTACK_URL` → MobiStack web (`http://localhost:5176`)
- `NEXT_PUBLIC_CONSOLE_URL` → OneOps
- `NEXT_PUBLIC_IDENTITY_ISSUER` / `VITE_IDENTITY_ISSUER` → Identity

`site-config.ts` defaults to localhost so a missing build arg cannot send you to production. Production compose must set the https hostnames.

## Flow

```
Marketing "Sign in → Mailroom"
        → http://localhost:5175/login
        → OIDC /oauth2/authorize
        → http://localhost:8081/login  (credentials here only)
        → /auth/callback on :5175
```

Same pattern for OneOps `:5173`, Admin `:5174`, MobiStack `:5176`.

Platform API credential login (`POST /api/v1/auth/login`, magic link, OTP, …) returns **410** locally (`LEGACY_CREDENTIAL_LOGIN=false`).

## Mobile

Android (OneOps / Admin / Mailroom / MobiStack Expo) and iOS OneOps use the same Identity OIDC clients (Custom Tabs / `ASWebAuthenticationSession`). Tokens refresh against Identity; `/auth/me` still comes from the platform.

## Bring-up

See `LOCAL-STACK.md` (Infra `--profile identity --profile mailroom`, then MobiStack `--profile full`).

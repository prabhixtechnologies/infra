# Prabhix Identity — running it, and cutting over to it

Identity lives in the sibling `Identity/` repository. This document is the platform side: how the
gateway routes to it, what has to exist before it can start, and the order the cutover has to happen
in so nobody is signed out.

Identity owns **who you are**. It does not own what you can do — there is no organization, shop, role
or permission in its schema. Each product resolves those per request from its own database.

```
                    api.prabhixtechnologies.com  (Caddy, one origin)
                              │
        ┌─────────────────────┼──────────────────────────┐
        │                     │                          │
  /api/v1/auth/*        /.well-known/*              everything else
        │                     │                          │
        ▼                     ▼                          ▼
   {$AUTH_UPSTREAM}     {$AUTH_UPSTREAM}            backend:8080
   default backend:8080                                  │
                                                   verifies tokens
                                                   via JWKS ────────► identity:8081
```

One origin is deliberate. The web apps, both Android apps, and every magic link already sitting in
someone's inbox call `api.prabhixtechnologies.com`; routing auth behind that name makes this a
deployment change rather than a client change, and avoids a second CORS origin and a second cookie
domain for the sign-in flow. Later extractions — mail is the intended next one — become a routing
change in the same file.

---

## The cutover switch

`AUTH_UPSTREAM` in `deploy/.env.prod` is the whole cutover, and the same line is the whole rollback.

| Value | Effect |
| --- | --- |
| unset (default `backend:8080`) | Auth stays on the platform. `/.well-known/*` 404s, which is correct — nothing is issuing RS256 tokens yet. |
| `identity:8081` | Identity serves sign-in and publishes discovery and JWKS. |

It defaults to the backend on purpose. These paths carry live sign-in traffic: hardcoding
`identity:8081` before that container exists would 502 every login on the next `docker compose up`,
and rolling back would mean editing proxy config under pressure.

**Do not flip it on its own.** Identity issues RS256 tokens without `organizationId` or permissions.
A backend still verifying HS256 would reject every one of them, so every request after a successful
login would 401. The flip and the backend cutover ship together — see the order below.

---

## Before identity can start

### 1. A signing key

RS256, PKCS#8 PEM, in `IDENTITY_SIGNING_KEY`. Blank is refused outside a local profile: an ephemeral
key signs every user out on restart, and with two replicas neither would accept the other's tokens.

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out identity-signing.pem
```

Keep it out of git. Phase 3 moves it to Secrets Manager; until then it is a line in
`deploy/.env.prod` like the rest.

Rotation is why `IDENTITY_RETIRED_PUBLIC_KEYS` exists: publish the old public key alongside the new
one for at least one access-token lifetime (`IDENTITY_ACCESS_TTL`, 15 minutes), so tokens signed a
moment before the swap still verify.

### 2. Its database

`docker/postgres/init/02-identity-database.sql` creates `prabhix_identity` — but
`docker-entrypoint-initdb.d` only runs on an **empty data directory**, so on any host whose volume
already exists, including production, it never runs. Create it by hand once:

```bash
docker compose exec postgres psql -U prabhix -c 'CREATE DATABASE prabhix_identity'
docker compose exec postgres psql -U prabhix -d prabhix_identity \
  -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS citext;'
```

Identity's own Flyway creates the tables on first boot. A separate database rather than a schema, so
"the platform cannot read the users table" is enforced by credentials rather than convention.

### 3. The issuer, exactly right

`IDENTITY_ISSUER` must match what products verify against **string for string** — a trailing slash or
`http` for `https` invalidates every token. It is `https://api.prabhixtechnologies.com` for now,
because that is where the Caddyfile serves discovery.

`id.prabhixtechnologies.com` is deliberately absent from the Caddyfile until its A record exists:
Caddy asks Let's Encrypt for a certificate per site name at startup, and a name that does not resolve
fails the HTTP-01 challenge and retries with backoff. Moving the issuer later invalidates every token
in flight, so it is a one-time change to make **before** the platform starts trusting the new tokens.

---

## Cutover order

Platform first, MobiStack second. MobiStack is live and its auth is entangled with billing gating in
`WorkspaceGuardFilter` and per-device session limits.

1. Create the database and the signing key. Start identity with `--profile identity` while
   `AUTH_UPSTREAM` still points at the backend, so nothing routes to it yet.
2. Import the platform's users:
   `psql -f Identity/scripts/import-platform-users.sql`. It preserves ids, so the platform's existing
   foreign keys (`created_by`, `assignee_id`, `organization_memberships.user_id`) keep working against
   its local mirror. Check for email collisions first — the script does this and stops.
3. Teach the backend to verify via JWKS **while still accepting its own HS256 tokens**. Both at once
   means already-issued tokens keep working through the switch, so nobody is signed out.
4. Flip `AUTH_UPSTREAM` to `identity:8081` and reload Caddy. New sign-ins now come from identity.
5. After one refresh-token lifetime (`IDENTITY_REFRESH_TTL`, 30 days) no HS256 token can still be in
   circulation. Drop HS256 verification from the backend then, not before.

Rollback at any point before step 5 is unsetting `AUTH_UPSTREAM`.

BCrypt makes step 2 safe without anyone resetting a password: a BCrypt hash carries its own cost
factor, so the platform's strength-10 hashes and MobiStack's strength-12 hashes both verify.

---

## Verifying it

```bash
# Discovery and JWKS, once AUTH_UPSTREAM points at identity.
curl -s https://api.prabhixtechnologies.com/.well-known/openid-configuration | jq .issuer
curl -s https://api.prabhixtechnologies.com/.well-known/jwks.json | jq '.keys[].kid'

# A token, and what is deliberately not in it.
curl -sX POST https://api.prabhixtechnologies.com/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"...","password":"..."}' | jq -r .accessToken \
  | cut -d. -f2 | base64 -d | jq
```

The payload should carry `sub`, `email`, `email_verified`, `name`, `sid` and `amr`, and **no**
`organizationId` and no permissions. If you see either, the platform is still minting the token and
`AUTH_UPSTREAM` has not taken effect.

The active tenant moves to the `X-Prabhix-Org` header, validated against membership rather than read
from a token claim. That is strictly better than today, where permissions freeze into the JWT at
login and a revoked role keeps working for up to 15 minutes.

---

## Internal endpoints

`/internal/*` is guarded by `IDENTITY_SERVICE_TOKEN`, which a product presents as
`X-Prabhix-Service-Token` and identity compares in constant time. Blank disables the endpoints
entirely, which is the right default for a deployment nobody gave a token. They are not routed through
Caddy — they are reachable only on the compose network.

| Endpoint | For |
| --- | --- |
| `POST /internal/users/lookup` | A product filling in its local user mirror, by id or address. |
| `POST /internal/users/{id}/revoke-tokens` | Break-glass "this account is compromised". Has to work even when the attacker holds a valid session, which is why it is a service call rather than a user-authenticated one. |

The deny list is one set of Redis keys that identity writes and every product reads, which is why
identity shares the platform's Redis rather than having its own.

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
  /api/v1/auth/*      /login, /oauth2/*,           everything else
        │             /.well-known/*, /userinfo,          │
        │             /connect/*, /assets/*               │
        ▼                     ▼                          ▼
   {$AUTH_UPSTREAM}    {$OIDC_UPSTREAM}            backend:8080
   default backend:8080  default identity:8081            │
                                                   verifies tokens
                                                   via JWKS ────────► identity:8081
```

One origin is deliberate. The web apps, both Android apps, and every magic link already sitting in
someone's inbox call `api.prabhixtechnologies.com`; routing auth behind that name makes this a
deployment change rather than a client change, and avoids a second CORS origin and a second cookie
domain for the sign-in flow. Later extractions — mail is the intended next one — become a routing
change in the same file.

---

## The two cutover switches

The routing is split because the two halves carry very different risk.

`OIDC_UPSTREAM` — the hosted login page, discovery, JWKS, and the authorization endpoints.

| Value | Effect |
| --- | --- |
| unset (default `identity:8081`) | Identity serves the login page and publishes discovery and JWKS. |
| `prabhix-backend:8080` | The backend answers, which means 404: it serves none of these paths. |

Defaulted **to identity**, because nothing in production calls these paths until an app is built with
`VITE_IDENTITY_ISSUER`. There is no traffic to break, and leaving them on the backend has a cost: the
login page cannot be loaded, so nothing about it can be checked before the day it has to work.

`AUTH_UPSTREAM` — the legacy JSON auth API at `/api/v1/auth/*`, which every product calls today.

| Value | Effect |
| --- | --- |
| unset (default `backend:8080`) | Sign-in stays on the platform. |
| `identity:8081` | Identity answers sign-in for every existing client. |

This one defaults to the backend on purpose. It carries live sign-in traffic: hardcoding
`identity:8081` before that container exists would 502 every login on the next `docker compose up`,
and rolling back would mean editing proxy config under pressure.

**Do not flip `AUTH_UPSTREAM` on its own.** Identity issues RS256 tokens without `organizationId` or
permissions. A backend still verifying HS256 would reject every one of them, so every request after a
successful login would 401. The flip and the backend cutover ship together — see the order below.

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

`docker/postgres/init/02-identity-database.sql` creates the `identity` role and the `identity`
database it owns — but `docker-entrypoint-initdb.d` only runs on an **empty data directory**, so on
any host whose volume already exists it never runs. Run the same file by hand once:

```bash
docker compose exec postgres psql -U oneops -f /docker-entrypoint-initdb.d/02-identity-database.sql
```

On RDS the steps are the same but the master user is not a superuser, which changes two of them. See
[deploy/RUNBOOK-rds.md](../deploy/RUNBOOK-rds.md).

Identity's own Flyway creates the tables on first boot. A separate database *and* its own role, so
"the platform cannot read the users table" is enforced by credentials rather than convention — a
separate database that the platform's own user owns would not be a boundary at all.

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

**MobiStack cutover is in progress.** Dual-verify (HS256 + Identity RS256) is shipped in the MobiStack
backend; the web app redirects to hosted Identity login when `VITE_IDENTITY_ISSUER` is set. Remaining:
import users (`Identity/scripts/import-mobistack-users.sql`), set `IDENTITY_ISSUER` /
`IDENTITY_SERVICE_TOKEN` / `MOBISTACK_URL` in prod env, rebuild the web image with
`VITE_IDENTITY_ISSUER`, then Expo AppAuth for mobile. Do not drop HS256 until one refresh-token
lifetime after web cutover.

**Platform steps 0 to 6 are done in production.** `AUTH_UPSTREAM=identity:8081`, both consoles are built with
`VITE_IDENTITY_ISSUER`, and their password forms are deleted rather than disabled. Step 7 is the only
one left on this list, and it is a date rather than a task: 30 days after the flip, when no HS256
token can still be in circulation. The steps below are kept as written because they are also the
rollback, in reverse.

0. Load `https://api.prabhixtechnologies.com/login` and sign in on it by hand, for each method the
   deployment offers. `OIDC_UPSTREAM` defaults to identity, so this works before any of the steps
   below and independently of them: no product is pointed at it yet, and a failure here costs
   nothing. Doing it first is the point — every step after this one is harder to undo.
1. Create the database and the signing key. Start identity with `--profile identity` while
   `AUTH_UPSTREAM` still points at the backend, so no existing client routes to it yet.
2. Import the platform's users:
   `psql -f Identity/scripts/import-platform-users.sql`. It preserves ids, so the platform's existing
   foreign keys (`created_by`, `assignee_id`, `organization_memberships.user_id`) keep working against
   its local mirror. Check for email collisions first — the script does this and stops.
3. Set `IDENTITY_ISSUER` on the **backend** and restart it. It now verifies identity's RS256 tokens
   as well as its own HS256 ones. Both at once is what keeps already-issued tokens working, so
   nobody is signed out. This must happen *before* step 4 — with `AUTH_UPSTREAM` flipped and the
   issuer untrusted, sign-in succeeds and then every subsequent request is a 401.

   Confirm it took effect in the backend log: `Loaded N identity verification key(s)`. The keys are
   fetched from `IDENTITY_JWKS_URI`, which defaults to the identity container directly rather than the
   public issuer URL. Both resolve to identity now, but the direct route does not depend on the proxy
   or on TLS to fetch the keys the backend needs in order to accept anybody at all.
4. Set `IDENTITY_SERVICE_TOKEN` to the same value on **both** the backend and identity. This is what
   lets the backend fill in a local `users` row for anyone who signs up through identity after the
   import. Blank, such a person is refused with "not provisioned on the platform" — correct before
   step 2 and a bug after it.
5. Flip `AUTH_UPSTREAM` to `identity:8081` and reload Caddy. New sign-ins now come from identity.

   Two paths do not move with it, and the Caddyfile pins both to the backend ahead of the wildcard.

   `/api/v1/auth/me`, because the two services answer it differently: identity says who someone is
   and deliberately nothing about a tenant, while the console requires `organizationId` and
   `permissions` and its schema rejects a body without them. Moving it too would let sign-in succeed,
   exchange a code, and then fail parsing the response — a failure that would first appear at step 6.

   `/api/v1/auth/invites/*`, because identity has no such path and could not answer it: an invitation
   names an organization, a role and a sender, and identity holds no organizations. Unpinned, the
   invitation page 404s for people who have no account yet and no way to report it.

   `POST /api/v1/auth/register` moves, and identity now answers it properly. This was the thing that
   held the step up: the two services disagreed about what the path means. The backend's creates a user
   *and* an organization from `organizationName`; identity's created a user and ignored the field,
   because it has no organizations. After a flip that would have made accounts with no tenant, which a
   console can show nothing to — and pinning it to the backend instead would have made accounts in the
   platform's user table that the hosted login page, which reads identity's, could not sign in.

   Identity owns it now and asks the platform for the tenant half over `POST /internal/organizations`.
   Both records or neither: if the platform will not provision, the account is withdrawn, because half
   a signup takes an address hostage — the person can neither use it nor sign up again with it.

   Two consequences worth knowing. `/internal` is answered with a 404 at the edge, so that endpoint is
   reachable only from the container network and only with the shared token. And the response identity
   returns carries no `organizationId` or `permissions`, which is fine: those fields are optional in
   the console's schema, and it learns both from `/auth/me` a moment later.

   `/signup` needs its own `handle` in the Caddyfile. It is not under `/login`, so the catch-all sends
   it to the backend, which has no such path and answers a JSON 401 — a page for people with no account
   saying authentication is required.
6. Only now rebuild the two console images with `VITE_IDENTITY_ISSUER` set. That is what turns the
   password form into a redirect to the hosted login page.

   `/oauth2/authorize` already works at this point — `OIDC_UPSTREAM` sent it to identity from step 0 —
   so what makes this step last is not the routing but steps 3 and 4: with the issuer untrusted, the
   redirect succeeds, the code exchanges, and then every API call the console makes is a 401.

   The consoles' own forms are deleted in the same commit, not left behind the flag. Keeping a second
   path costs the property that made hosting them on identity worth doing: a console that never renders
   a password field cannot leak one, and that holds only while there is no other way to type one in. A
   build with no `VITE_IDENTITY_ISSUER` now says which setting is missing.

   `/signup` in a console redirects through `/oauth2/authorize?prompt=create` rather than to the signup
   URL directly. The redirect is what makes identity save the authorization request, and the saved
   request is what returns the new customer to the product they started in — without it they all land
   on whatever `urls.console` points at.
7. After one refresh-token lifetime (`IDENTITY_REFRESH_TTL`, 30 days) no HS256 token can still be in
   circulation. Drop HS256 verification from the backend then, not before.

Rollback before step 6 is unsetting `AUTH_UPSTREAM`. After step 6 it is that plus rebuilding the
consoles without `VITE_IDENTITY_ISSUER`, so treat 6 as the point of no easy return and leave a gap
between it and 5. Leaving `IDENTITY_ISSUER` set costs nothing: with nothing minting RS256 tokens,
nothing presents one.

What the backend does with an identity token is the other half of the change. Such a token carries no
organization and no permissions, so both are resolved per request: the tenant comes from
`X-Prabhix-Org` validated against an active membership, and the permissions from `PermissionResolver`
against this database. Claims in the token are never a source of authority — `JwtServiceIdentityTest`
pins that, including that a correctly signed token asserting `padm` and `PLATFORM_ADMIN` gets
neither.

A subject with no row in the platform's own `users` table is fetched from `/internal/users/lookup` on
the first request naming it, and only refused with "not provisioned on the platform" if identity does
not know them either or no service token is configured. Step 2 handles the existing population in
bulk; this handles everyone who signs up afterwards.

The mirror never writes `platform_admin`. Staff authority is granted in the platform's database and
nowhere else, so a compromised identity service cannot elevate itself here — which is the blast radius
the split exists to remove.

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

The platform answers one going the other way, on the same secret, because it is one trust
relationship and a second secret would be a second thing to forget to rotate.

| Endpoint | For |
| --- | --- |
| `POST /internal/organizations` | Identity creating the tenant half of a signup. Idempotent on an existing active membership: the caller is a network hop away, so a timeout it retries after may already have succeeded, and two organizations is not a harmless duplicate — they would compete to be the one `default_organization_id` names, and the loser would be invisible to the person who owns it. |

Unlike identity's, the platform's `/internal` is on a hostname Caddy serves, so the Caddyfile answers
`/internal*` with a 404 — first among the handles, so nothing added later can expose it. Without that,
the endpoint that creates an organization and grants its ownership would be a public URL with a shared
secret as its only defence.

The deny list is one set of Redis keys that identity writes and every product reads, which is why
identity shares the platform's Redis rather than having its own.

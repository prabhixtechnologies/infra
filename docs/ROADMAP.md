# Roadmap and known gaps

An honest inventory of what is built, what is stubbed, and what is deliberately deferred.
Kept current so nobody discovers a gap at the worst possible moment.

---

## Verified working

| Area | Evidence |
|---|---|
| Backend unit tests | `mvn -Djava.version=17 test` → 290 green, ~530 source files |
| Flyway migrates cleanly from empty | `mvn -Djava.version=17 test -Pintegration` → migrations applied against a real `postgres:16` container |
| Flyway migrates cleanly on an existing database | Booted against the dev database: 47 validated, V51–V58 applied, schema now at v58 |
| `ddl-auto: validate` entity/schema agreement | Same run. Automated, not a human starting the app |
| Tenant isolation at the database layer | `TenantIsolationIntegrationTest` — two orgs, real Hibernate tenant filter, cross-tenant read returns nothing |
| API surface end to end | `backend/smoke.ps1` → 136 checks green against a booted stack (auth, mail, billing, files, visitors, chat, commerce, AI, logs, push, idempotency, cross-tenant refusals) |
| Console builds and typechecks | `npx tsc --noEmit` + `npm run build` pass; largest chunk 308 kB |
| Console unit tests | `npm test` → 16 tests |
| Marketing builds and typechecks | `npx tsc --noEmit` + `npm run build` pass, 33 routes, blog and products pre-rendered |
| Marketing unit tests | `npm test` → 4 tests |
| Compose files parse | `docker compose config` exit 0 for local, mail, and the layered prod override, with and without `--profile monitoring` |
| Reverse proxy config | `caddy validate` on `deploy/Caddyfile` → valid. Marketing on the apex, OneOps on `oneops.`, API on `api.`, `app.` permanently redirected |
| Deploy smoke suite | `deploy/smoke.ps1` → 7 checks green, including cursor-page shape and the public-endpoint origin allowlist refusing a foreign origin |
| Structured event logs reach the database | Against production: a good login, a bad password and an unknown email produced `auth.login.succeeded` ×1 and `auth.login.failed` ×2 in `event_logs`, and the Ops Hub overview reported `securityEventsLast24h: 2` |
| Ops Hub is platform-admin only | Against production: `/api/v1/admin/platform/overview` → 401 with no token and with a forged token, 200 with the platform-admin token. The console guards `/ops` with `PlatformAdminRoute` |

> Note on the marketing build: on Windows the final copy into `.next/standalone` fails
> intermittently with `EBUSY`, usually on a `.wasm` file under `.next/server/edge-chunks/` and
> sometimes on a font manifest. It is Defender scanning files Next.js has just written, not a build
> error — everything up to `Collecting build traces` has already succeeded. A clean build does *not*
> reliably avoid it, contrary to what this note used to claim; **re-running `npm run build` does**,
> because the files have been scanned by then. Linux and the Docker build are unaffected.
>
> Use `npm start` rather than `next start` to serve the result. `output: "standalone"` excludes
> `public/` and `.next/static/`, so `next start` warns and serves a different server than production;
> `scripts/start-standalone.mjs` assembles the same layout the Dockerfile does.

## Not yet verified

| Area | Why | How to close |
|---|---|---|
| iOS app compiles | No Xcode on the dev machine (Windows). **The iOS app has never been compiled** | `cd mobile/ios && xcodegen generate && swift build`, then work through the errors. The project is now generated from the checked-in `project.yml`, and `.github/workflows/ios.yml` runs the whole thing on a macOS runner on demand, so no Mac is needed to get the first error list |
| Mail transport end to end | Postfix/Dovecot/Rspamd never started | `docker compose -f mail-server/docker-compose.mail.yml --profile mailserver up`, then `swaks` per `mail-server/README.md` |
| SES delivery and the new SNS bounce webhook | No AWS account wired | Set `MAIL_TRANSPORT=SES`, subscribe an SNS topic to `POST /api/v1/mail/webhooks/ses`, bounce a message at the SES simulator |
| Razorpay against real keys | No test credentials configured | Add test keys, run a checkout, replay a webhook, and let one renewal cycle run |
| ClamAV scanning | Scanner implemented, never run against a real clamd | Start clamd, set `prabhix.files.scan.provider=CLAMAV`, upload EICAR |
| FCM / APNs delivery | Providers implemented, no credentials | Android is wired and needs only `app/google-services.json` (four apps in one Firebase project) plus `PUSH_PROVIDER=FCM` and an `FCM_SERVICE_ACCOUNT_JSON` on the server — see `mobile/android/README.md`. iOS additionally needs `push_tokens` to record which app and APNs environment a token came from, because `ApnsPushProvider` sends every notification to the single configured `APNS_BUNDLE_ID` and there are now two iOS bundle ids |
| SSE fan-out across multiple API instances | Single-instance dev only | Scale `backend` to 2 replicas and confirm presence events reach both |
| PgBouncer under load | Backend now serves all traffic through it in the containerised stack, but never load-tested | Run sustained load and watch for prepared-statement errors (`prepareThreshold=0` is set; Flyway bypasses the pooler via `FLYWAY_URL`) |
| Prometheus scrape auth | Rules and dashboards provisioned; scrape needs a real token | Put a platform-admin token in `docker/prometheus/secrets/bearer_token` |
| Most of the log taxonomy is declared but never emitted | `LogEventCode` defines 80+ codes. Only three call sites emit anything: `AccessLogFilter` (HTTP requests, deliberately not persisted), `GlobalExceptionHandler` (unhandled errors) and now `AuthService` (login succeeded/failed, account locked, token reused, logout, refresh). Mail, billing, files, chat, commerce and AI codes are unused, so the Ops Hub and the Event Logs page can only ever show auth and error activity | Emit the remaining codes from the services that own them. Events raised on a path that then throws must use `StructuredEventLogger.logNow`, since the `AFTER_COMMIT` listener drops anything whose transaction rolls back |
| Admin and API-key endpoints reject a valid bearer token | `contract.live.test.ts` gets 200s across the console but `401 TOKEN_INVALID` on `/settings/api-keys`, `/admin/platform/*` and `/admin/site/*` — with the same token, in the same run. A permissions failure would be `403 FORBIDDEN`, and `TOKEN_INVALID` is only thrown by `JwtService` on a parse or signature failure, so something is re-parsing the token differently on those paths | Run the live contract test with a platform-admin account and trace which filter rejects it. Suspect a second authentication filter matching those paths and refusing a JWT |

---

## Recently completed

Closed in the last pass, with tests, and green through `mvn test` + `smoke.ps1`:

- **Two emailed links that went nowhere.** Email verification pointed at
  `{CONSOLE_URL}/auth/verify-email`, a route that never existed, so no address could be verified by
  clicking the link. Invitations pointed at `/invites/accept?token=`, while the route is
  `/invite/:token` — a query parameter where a path segment was expected, and plural where the route
  is singular — so an invitee fell through the catch-all to a protected page and landed on the
  sign-in form with no account to sign in with. Both now match `routes-shell.tsx`.
  `/verify-email` is deliberately outside `publicRoutes`, because that group redirects an
  authenticated visitor to `/` and the usual case is somebody already signed in who requested the
  email from their settings — under that guard they were bounced before the token was consumed.
- **API key scope narrowing** — a key can now be created with an explicit subset of the creator's
  permissions, validated at creation and still re-intersected on every request.
- **Mailbox credentials** — IMAP/SMTP passwords are settable through the API, encrypted at rest and
  write-only. External mailboxes no longer require a direct database write.
- **SES bounce feedback loop** — an SNS webhook with signature verification and idempotency feeds
  bounces and complaints into the same suppression path the SMTP DSN parser already used.
- **Malware scanning** — a real ClamAV INSTREAM client, selectable by config, fail-closed by default.
- **Push providers** — FCM (HTTP v1) and APNs (HTTP/2, ES256) implemented behind the existing router.
- **Dunning** — now retries the charge on a 1/3/7-day backoff with persisted attempt state and a
  Redis lock, before escalating to suspension.
- **Subscription renewals** — self-managed renewal orders close the loop that
  `PaymentCompletionService` and the `subscription.charged` webhook were already written for.
- **Storefront subscriptions and provisioning** — `SUBSCRIPTION` products check out recurring, and
  post-payment provisioning now covers `PHYSICAL` (shipment record with carrier and tracking),
  `SERVICE` (engagement with SLA) and `SUBSCRIPTION`, not just `DIGITAL`.
- **AI** — `request-timeout` is enforced, per-org model preferences take effect, structured output is
  used where the provider supports it, and the chat first responder is wired into the visitor flow.
- **AI in the console** — the backend AI layer was complete but had no UI at all. The console now has
  streaming reply suggestions in mail and chat, thread summarize and triage, draft rewrite, handoff
  summary, sentiment, plus AI settings and AI usage pages.
- **Responsive pass** — dialogs are scroll-safe on short landscape viewports, composers cap their
  height with the keyboard open, tables degrade to cards, and touch targets on the cart and checkout
  paths meet 44px.

### The first responder is event-driven on purpose

It was first written as an inline call inside the visitor's write transaction. That held a database
transaction open for the length of a provider round trip and created a bean cycle
(`ChatAiService` → `ChatMessageService` → `ChatFirstResponderService` → back). It now hangs off the
already-published `ChatMessageReceived` event with `@TransactionalEventListener(AFTER_COMMIT)` and
`@Async`, so the visitor's message returns at write speed no matter how slow the model is. Because
`@Async` means a pooled thread, the work is wrapped in an explicit `TenantContext.runAs` rather than
trusting `InheritableThreadLocal`.

---

## Module follow-ups

### Mobile — the largest remaining gap

Both apps are native (Android: Kotlin/Compose; iOS: SwiftUI) and both are still well short of the
console. Treat the estimates below as real work, not polish.

Both platforms are now split into two apps, matching the web console: the OneOps product sold to
customers and the private admin app. On Android these are product flavors with separate application
ids. On iOS the two targets are declared in `mobile/ios/project.yml` but build identical screens,
because the platform surface has not been written there yet — the iOS split is still cosmetic.

**The split is now structural rather than a matter of visibility, on web and on Android.** Admin
mounts the platform surfaces and nothing else; the product is not merely hidden from it but absent.
On Android the product's screens, Room database, SSE client, send queue, push and Retrofit APIs live
in `app/src/oneops/`, each flavor supplies its own `PrabhixNavHost`, and `SessionLifecycle` is the
seam that let the data layer divide — `AuthRepository` calling `RealtimeHub` directly had kept a Hilt
provider for it in both apps, so nothing could be stripped. On web the tenant routes moved to
`routes-tenant.tsx`, which only the OneOps entry point imports, because a module-scope
`lazy(() => import(...))` is emitted into every bundle importing the file that declares it.

Support is a handoff: admin's tenant directory opens OneOps with `?viewAs=<orgId>`, honoured only
after the server confirms a platform admin, with a banner naming the customer. Prabhix's own team
uses OneOps for its own inbox and shop, as customer #1.

Two earlier attempts are worth remembering, because both looked finished. The first shipped admin as
the entire customer product with one page appended — it built and stripped correctly but was
indistinguishable from OneOps in use, and the release APKs differed by 0.1 MB. The second gated the
tenant screens behind choosing an organization, which fixed the behaviour while admin still contained
22 of 23 feature directories and 75 of the web bundle's chunks. Admin is now 21 chunks and 686 KB
against OneOps' 74 and 949 KB; the APKs are 2.56 MB against 2.95 MB.

1. **Android now compiles and produces an APK.** `./gradlew :app:assembleOneopsDebug` is green and the
   wrapper jar is committed, so a clean clone can build. Fixing the first compile exposed three real
   defects, now closed: `MainActivity` extended `ComponentActivity` where `BiometricPrompt` requires
   a `FragmentActivity`; `Models.kt` used `@JsonIgnoreUnknownKeys`, which needs kotlinx.serialization
   1.8+ against the pinned 1.7.3 (redundant anyway — the shared `Json` sets `ignoreUnknownKeys`); and
   `AuthAuthenticator` → `TokenRefresher` → `AuthApi` → Retrofit → `OkHttpClient` formed a Dagger
   cycle, broken with a `Provider<TokenRefresher>`. It has still never run on a device or emulator.
2. **A signed production release APK now builds.** `:app:assembleOneopsRelease` is green, signed from a
   git-ignored `keystore.properties`, and verified to contain the production API URL rather than the
   emulator's `10.0.2.2`. Enabling the release build exposed a defect that would only have surfaced
   at runtime: `proguard-rules.pro` carried a Gson keep rule while the app uses Kotlinx
   Serialization, and had no rules for it, so R8 stripped the generated `Companion.serializer()`
   members — the APK would have installed and then failed to parse every API response. Official
   Kotlinx Serialization and Retrofit keep rules are now in place, and the resulting dex was checked
   for surviving `$$serializer` classes. Push is inert without `google-services.json`, which
   `PushTokenManager` catches, so the app works while open but gets no background notifications.
3. **iOS has never been compiled.** The dev machine is Windows, so this is blocked on tooling rather
   than on decisions. What changed: the project is now generated from a checked-in
   `mobile/ios/project.yml`, replacing six manual Xcode steps that had to be repeated identically on
   every machine, and `.github/workflows/ios.yml` builds both targets on a macOS runner when started
   by hand — so the first error list can be obtained without owning a Mac. Budget real time for the
   shakedown; ~2,000 lines that have never seen a compiler will not build cleanly.
4. **The iOS admin app has no admin screens.** Both targets exist and differ correctly in identity,
   entitlements and compilation conditions, but the platform overview, tenant directory and "view as"
   banner that Android and the web console have are not written for iOS.
5. **Coverage is roughly a fifth of the console.** Present: auth, org select, dashboard, chat
   list/detail, mail list/detail with reply, and AI assist. Absent: commerce, billing, members,
   files, audit, logs, settings, mailboxes, domains, templates, tags admin, flags, site admin.
6. **No automated tests on either platform.** CI assembles both Android flavors and audits the APK
   for leaked admin endpoints, which catches a broken build but asserts nothing about behaviour.
7. **Offline is chat-only.** There is no outbound queue for mail on either platform.

### Mail

1. **`mail_messages` partitioning** — unpartitioned by design for now; revisit past ~50M rows.
   Requires moving `mail_attachments` to a composite foreign key.

### Billing

1. **Proration edges** — mid-cycle downgrades and currency other than INR are untested.
2. **Off-session renewal needs a saved token** — the storefront must enable Razorpay tokenization at
   checkout. Without a token, a renewal still creates the order and enters dunning, but cannot
   auto-charge.

### Auth and org

1. **No SSO** — `AuthIdentity` has `MICROSOFT`, `GITHUB` and `SAML` enum values but only Google has
   an implementation. Required by most enterprise buyers; not needed to start.
2. **No TOTP/WebAuthn second factor** — passwordless email links and passwords only.

### Commerce

1. **No carrier integration** — shipments record carrier and tracking number, but nothing talks to a
   carrier API or prints labels. The model is shaped so an adapter can be added.

### AI

1. **No provider key configured** — provider-agnostic with Gemini as the default, degrading to
   `available: false` rather than erroring. Set `GEMINI_API_KEY` to turn it on.
2. **No retrieval** — this is the one genuinely unfinished AI capability. `embed()` is implemented on
   the Gemini and OpenAI providers and the embedding models are configured, but nothing calls them:
   there is no vector store and no grounding. Prompts are templated with request context only.

### Site

1. **`SITE_INTERNAL_ORG_ID`** — until set, job applications are accepted and flagged in internal
   notes rather than silently losing the résumé, but the file is not stored.

### Marketing / console boundary

`prabhixtechnologies.com` is the public site, `oneops.prabhixtechnologies.com` is the operator
console, `mobistack.` is its own deployment, and `app.` permanently redirects to `oneops.`.
`marketing/src/content/products.ts` distinguishes an `app` (own deployment, own URL) from a `module`
(a capability inside OneOps), so "Open app" is only offered for something that can be opened.
What is left:

1. **Duplicated contracts** — `marketing/src/lib/commerce/schemas.ts` and
   `web/src/lib/schemas/commerce.ts` describe the same backend DTOs in two trees and have already
   drifted. Same for the money helpers and the brand tokens in `globals.css` vs `index.css`. A
   generated client or a shared workspace package would remove the class of bug; both apps are
   independently Dockerized, so this is a build-system change, not a file move.
2. **Storefront placement** — `/shop` lives in the marketing app and talks to the public commerce
   API. Defensible (SEO wants server rendering on the apex), but it is why the public site is also
   an API client.
3. **`NEXT_PUBLIC_*` is baked at build time** — the marketing image must be *built* with the right
   values; setting them on the container does nothing.

### Frontend

1. **No E2E coverage** — both apps have unit tests. Playwright on login → inbox → reply would be the
   highest-value next test.
2. **Client schemas can drift from the API without any test noticing.** Six console pages were broken
   at once — dashboard, live chat, feature flags, billing, and two settings panels — because their Zod
   schemas required fields the API omits. The API is configured `non_null`, so a null field is left
   out of the JSON; `.nullable()` still demands the key, so each page failed on exactly the rows where
   the value is unset (an unassigned thread, an unused API key, an org not on trial). Every request
   was a 200, so nothing in the logs pointed at it. Use `.nullish()` in response schemas — see the
   note at the top of `web/src/lib/schemas/common.ts`. `web/src/lib/schemas/contract.live.test.ts`
   fetches all 47 console endpoints and parses each with the real schema; it skips unless
   `PBX_CONTRACT_EMAIL` / `PBX_CONTRACT_PASSWORD` are set. Worth running against staging on every
   release, and worth pointing at a seeded tenant in CI, since fixture-based tests cannot catch this
   class of bug — they encode the same wrong assumption as the schema.
2. **`marketing` has 2 advisories** from PostCSS bundled inside Next 15.5.x; clearing them needs a
   Next 16 major bump.

### Platform

1. **Audit archival is off by default** — the job exports partitions to object storage and drops
   them, verified durable before dropping, but ships disabled with `dry-run: true`.
2. **CI does not run the integration profile** — `.github/workflows/ci.yml` runs the unit suite only.
   Add `mvn test -Pintegration` so schema drift is caught before merge, not at deploy.
3. **No log shipper** — `LOG_FORMAT=json` emits one JSON object per line ready for indexing, but
   nothing collects it. 117 typed event codes are queryable in Postgres via `/api/v1/event-logs`.

---

## Suggested order of work

1. Set `GEMINI_API_KEY` and exercise the AI surfaces that are now wired end to end.
2. Set `SITE_INTERNAL_ORG_ID`, wire real Razorpay test keys, and run a payment end to end including
   a webhook and one renewal cycle.
3. Run the Android APK on a device or emulator against the live backend, then create the Xcode
   project and compile the iOS app for the first time.
4. Add `mvn test -Pintegration` to CI so schema drift can never reach a deploy again.
5. Deploy to EC2 in `EXTERNAL_IMAP` mode with `MAIL_TRANSPORT=SES` and subscribe the SNS bounce
   topic. Only take on self-hosted mail once the rest is stable; it is the single largest
   operational burden in this repository.
6. Turn on the monitoring profile and put a real token in the Prometheus secret, so the first
   production incident is observed rather than reported by a customer.
7. Stand up ClamAV before the storefront and helpdesk take uploads from strangers.
8. SSO and a second factor, when the first enterprise buyer asks.

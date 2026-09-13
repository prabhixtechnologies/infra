# Prabhix Flutter mobile (all products)

Natives (Kotlin Compose / Expo / unfinished SwiftUI) keep shipping until each Flutter app reaches
parity. New work lives in the sibling **`Mobile/`** Melos workspace at the workspace root:

```
PrabhixTechnologies/Mobile/
  packages/
    prabhix_identity/     # flutter_appauth, secure storage, refresh, logout
    prabhix_api_core/     # Dio: Bearer, org/device headers, 401 → Identity refresh
  apps/
    admin/                # com.prabhix.admin
    mailroom/             # com.prabhix.mailroom
    oneops/               # com.prabhix.operator
    mobistack/            # app.prabhix.fixflow + OAuth scheme mobistack
```

## Frozen Identity contract

| App | OIDC client | Package / bundle | Redirect |
| --- | --- | --- | --- |
| OneOps | `prabhix-oneops-android` | `com.prabhix.operator` | `{applicationId}:/oauth2redirect` (+ `.debug`) |
| Admin | `prabhix-admin-android` | `com.prabhix.admin` | same; `prompt=select_account` |
| Mailroom | `prabhix-mailroom-android` | `com.prabhix.mailroom` | same |
| MobiStack | `prabhix-mobistack-android` | `app.prabhix.fixflow` | **`mobistack:/oauth2redirect`** and `mobistack://…` |

Issuer (prod): `https://api.prabhixtechnologies.com`. Custom Tabs / ASWebAuthenticationSession only —
never WebView login. Product authorization via `GET /auth/me` (or MobiStack equivalent); refresh only
against Identity.

Do **not** rename package IDs or OAuth schemes. Admin ships as a **separate app binary** (no chat/SSE
in that APK).

## Cutover order

1. Shared packages (`prabhix_identity`, `prabhix_api_core`)
2. Admin → Mailroom → OneOps → MobiStack
3. CI release APK/IPA → `s3://prabhix-apk-downloads/` (Admin internal only)
4. Freeze and archive natives after each product’s parity checklist

## Local debug defaults

- API: `http://10.0.2.2:8080/api/v1` (emulator → host)
- Identity: `http://10.0.2.2:8081`
- MobiStack API (when applicable): `http://10.0.2.2:8085`

Pass via `--dart-define=IDENTITY_ISSUER=...` / `API_BASE_URL=...` or flavor configs in each app.

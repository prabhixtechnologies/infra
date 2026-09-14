# Android release signing

Release APKs for OneOps, Admin, Mailroom, and MobiStack are signed from a local
`keystore.properties` (git-ignored) or from GitHub Actions secrets. This document is the checklist
for making signed builds without putting the keystore in git.

**Do not commit `.jks` / `.keystore` files or real passwords.**

## Per-app keystore files (local)

| App | Properties file | Example |
| --- | --- | --- |
| Flutter (all four apps) | `Mobile/apps/<app>/android/keystore.properties` | see `Mobile/ANDROID-RELEASE-SIGNING.md` if present |
| Native (archived) | on `archive/native-*` under the old `mobile/android` / `android` trees | `keystore.properties.example` on those branches |

Create a key (once per application id, forever):

```bash
keytool -genkeypair -v -keystore prabhix-release.jks -alias prabhix \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=Prabhix Technologies, O=Prabhix Technologies, C=IN"
```

Back the `.jks` up somewhere durable. Losing it means installed apps cannot be updated in place.

## GitHub Actions secrets

Where Flutter CI in the Mobile repository assembles a release APK, set:

| Secret | Purpose |
| --- | --- |
| `ANDROID_RELEASE_KEYSTORE_BASE64` | `base64 -w0` of the `.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | store password |
| `ANDROID_KEY_ALIAS` | alias (usually `prabhix` / `mobistack`) |
| `ANDROID_KEY_PASSWORD` | key password |

Native product-repo Android CI is gone. Flutter APKs are built from `Mobile/`.
Admin is staff-only — do not publish it on the public download page.

## Blocked on you

1. Generate or recover each release keystore.
2. Store backups offline.
3. Add the four secrets above to the GitHub repos that should produce installable release APKs.
4. Approve a deploy/release workflow run when you want artifacts published.

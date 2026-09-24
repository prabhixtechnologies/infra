# Android release signing

Upload keystore for **Play and sideload release** of the four Flutter apps.

**Do not commit `.jks` / `.keystore` files or real passwords.**

Canonical playbook (Play Console steps, SHA-256, listings): [PLAY-STORE.md](PLAY-STORE.md).

## This machine

| Item | Path |
| --- | --- |
| Keystore | `D:\Projects\KEYS\prabhix-play-upload.jks` |
| Alias | `upload` |
| Credentials | `D:\Projects\KEYS\prabhix-play-upload.credentials.txt` |
| Gradle properties | `D:\Projects\KEYS\prabhix-play-upload.key.properties` |
| Per-app copy | `Mobile/apps/<app>/android/key.properties` (git-ignored) |
| Example | `Mobile/key.properties.example` |

SHA-256 (public, safe to share with Play):

`30:94:AA:00:BC:18:7A:4E:1A:6E:A2:24:29:53:99:8D:C0:78:B1:64:D4:64:72:5E:0B:7C:2C:4C:64:A0:60:F6`

Release Gradle uses that keystore when `key.properties` exists; otherwise it falls back to the debug key (local-only, never for Play).

MobiStack’s **Play** upload certificate is this keystore. Confirmed in Play
Console on 2026-09-24 (SHA-1 `65:7A:6E:38:…:62`). The older SHA-1 `E9:C5:DC:40:…:7E`
is no longer the upload certificate. Upload `1.2.1+5` before bumping versionCode.

**Not** the Play upload key (do not use these to sign Play MobiStack updates):

| File | SHA-1 | What it is |
|---|---|---|
| `C:\Users\abhis\.prabhix-secrets\platform-leftovers\prabhix-release.jks` | `52:66:18:5B:…` | Aug 2026 sideload key |
| `~\.android\debug.keystore` | `63:BE:06:E7:…` | Android debug |
| `D:\Projects\KEYS\ageinminutes.jks` | (other app, 2021) | Unrelated |

USB install: `powershell -File Mobile/scripts/install-device-apks.ps1` (uninstalls Play-signed copies first).

## GitHub Actions secrets

| Secret | Purpose |
| --- | --- |
| `ANDROID_RELEASE_KEYSTORE_BASE64` | `base64 -w0` of the `.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | store password |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | key password (same as store) |

Admin is staff-only — do not publish it on the public S3 download page or Play Production without an explicit decision.

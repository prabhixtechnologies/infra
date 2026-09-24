# Google Play — Prabhix Android apps

Canonical playbook for publishing the four Flutter apps. Read this before
touching Play Console, signing, or package names.

**Secrets stay out of git.** The upload keystore lives at
`D:\Projects\KEYS\prabhix-play-upload.jks`. Passwords are in
`D:\Projects\KEYS\prabhix-play-upload.credentials.txt`.

## Continue here (2026-09-24) — next session

**Upload key reset is approved.** Checked live in Play Console → MobiStack →
App signing. The **Upload key certificate** is this machine’s keystore:

- SHA-1 `65:7A:6E:38:0D:42:03:A1:97:51:9F:5D:C5:F0:E0:07:01:B1:87:62`
- SHA-256 `30:94:AA:00:BC:18:7A:4E:1A:6E:A2:24:29:53:99:8D:C0:78:B1:64:D4:64:72:5E:0B:7C:2C:4C:64:A0:60:F6`

Do not request another reset. The old upload SHA-1 `E9:C5:DC:40:…:7E` is no
longer the certificate Play will accept.

**MobiStack 1.2.1 (versionCode 5) is on Internal testing.** Published
2026-09-24 20:46. Play accepted the upload key. Testers:
https://play.google.com/apps/internaltest/4699612970327663424
(uninstall any USB/sideload copy first or Play download conflicts).

The catalog-payment phone build is the same versionCode 5, so it cannot replace
this release. Bump versionCode before the next MobiStack upload.

### Do this next

1. Closed Alpha (track `4698130848654705919`): target **India**, send for
   review. Closed opt-in stays disabled until that track is live.
2. After a versionCode bump, upload the catalog-gate build.

### What is already true

| Item | Status |
|---|---|
| New upload keystore | `D:\Projects\KEYS\prabhix-play-upload.jks` alias `upload` |
| New upload SHA-1 / SHA-256 | `65:7A:6E:38:…:62` / `30:94:AA:00:…:F6` |
| PEM used for reset | `D:\Projects\KEYS\prabhix-play-upload.pem` |
| Reset request | **Approved** (confirmed in Play Console 2026-09-24). Upload certificate matches this keystore |
| Old Play upload SHA-1 | `E9:C5:DC:40:…:7E` — **private key not on this PC** |
| Search (2026-09-22) | `prabhix-play-upload.jks`, leftover `prabhix-release.jks`, debug keystore, `ageinminutes.jks`, Recycle Bin, git — none match `E9:C5` |
| Leftover sideload jks | `C:\Users\abhis\.prabhix-secrets\platform-leftovers\prabhix-release.jks` SHA-1 `52:66:18:5B:…` — **not** the Play upload key |
| MobiStack Play Internal | **1.2.0 (versionCode 4)** 28 Aug, still downloadable |
| OneOps / Mailroom / Admin Internal | `1.0.0` live; email list **Internal Testing** (3) attached 2026-09-21 |
| Closed testers opted in | **0** (Internal joins do not count) |
| MobiStack installer check | Turned **off** 2026-09-22 (Flutter) |
| Phone used for USB | Samsung SM-F415F (`RZ8NA0SCSSE`) |
| Sideload on SM-F415F | **Done 2026-09-22** (Play splits uninstalled first). On device now: Admin/Mailroom/OneOps `1.0.0` (vc 1), MobiStack `1.2.1` (vc 5). Signed with upload key (`816183e1`). APKs: `Mobile/build/play/*-release.apk`. Play Store install will conflict until these USB copies are uninstalled. |

Tester emails (shared list): `admin@prabhixtechnologies.com`,
`abhishek734891@gmail.com`, `abhisheksingh.nsut@gmail.com`.

## Apps

| Play name | Package (permanent) | Flutter app | Play app ID | Production API |
|---|---|---|---|---|
| MobiStack | `app.prabhix.fixflow` | `Mobile/apps/mobistack` | `4973154792921325769` | `https://mobistack.prabhixtechnologies.com/api/v1` |
| Prabhix OneOps | `com.prabhix.operator` | `Mobile/apps/oneops` | `4976008391199476950` | `https://api.prabhixtechnologies.com/api/v1` |
| Prabhix Mailroom | `com.prabhix.mailroom` | `Mobile/apps/mailroom` | `4976030296612135497` | `https://api.prabhixtechnologies.com/api/v1` |
| Prabhix Admin | `com.prabhix.admin` | `Mobile/apps/admin` | `4972838248291930473` | `https://api.prabhixtechnologies.com/api/v1` |

Identity issuer for all four: `https://api.prabhixtechnologies.com`.

All four apps (including Admin) are intended for **Production**. Play still
blocks public Production on this new developer account until a **closed test**
meets Google’s criteria (historically **12 opted-in testers for 14 days**, then
**Apply for production**). That gate cannot be skipped from the Console.

## Upload key (this machine, 2026-09-20)

| Field | Value |
|---|---|
| File | `D:\Projects\KEYS\prabhix-play-upload.jks` |
| Alias | `upload` |
| Algorithm | RSA 4096, PKCS12, 10000-day validity |
| SHA-1 | `65:7A:6E:38:0D:42:03:A1:97:51:9F:5D:C5:F0:E0:07:01:B1:87:62` |
| SHA-256 | `30:94:AA:00:BC:18:7A:4E:1A:6E:A2:24:29:53:99:8D:C0:78:B1:64:D4:64:72:5E:0B:7C:2C:4C:64:A0:60:F6` |
| Public cert | `D:\Projects\KEYS\prabhix-play-upload.pem` |
| Gradle props | `D:\Projects\KEYS\prabhix-play-upload.key.properties` (copied to each `android/key.properties`) |

MobiStack already shows **four other** SHA-256 fingerprints on Android developer
verification. Those are **Play App Signing** certificates Google holds. Do **not**
paste them onto the other apps. Register **this upload SHA-256** on Admin,
Mailroom, and OneOps. For MobiStack, **add** this SHA-256 as an extra key, and if
Play already has a different upload key, use **Request upload key reset** and
upload `prabhix-play-upload.pem`.

### Backup (human)

Copy `prabhix-play-upload.jks` + `prabhix-play-upload.credentials.txt` into a
password manager and an encrypted USB. Losing both means we cannot upload updates
until Play resets the upload key. **Never commit these files.**

## Build signed AABs

```powershell
cd Mobile
powershell -File scripts/build-play-aabs.ps1
```

Outputs: `Mobile/build/play/{admin,mailroom,oneops,mobistack}-release.aab`

USB sideload (Play copies are uninstalled first — different signing cert):

```powershell
cd Mobile
powershell -File scripts/install-device-apks.ps1
```

Copies: `Mobile/build/play/{admin,mailroom,oneops,mobistack}-release.apk`

Release builds default to production Identity/API when `kReleaseMode` is true.
Debug still uses `10.0.2.2`.

## Android developer verification (deadline 30 Sep 2026)

Submitted 2026-09-20 from this account (`admin@prabhixtechnologies.com`,
developer `6734750926040334176`). Google may take up to 48 hours; watch
`admin@prabhixtechnologies.com`.

| Package | Status after submit |
|---|---|
| `app.prabhix.fixflow` (MobiStack) | Already **Registered**. Upload SHA-256 added → **In review** |
| `com.prabhix.admin` | **In review** (ownership APK submitted) |
| `com.prabhix.mailroom` | **In review** (ownership APK submitted) |
| `com.prabhix.operator` | **In review** (ownership APK submitted) |

Account ADI snippet (not a secret, unique to this Play account):
`DGSSC5PJCXJBAAAAAAAAAAAAAA`

Tiny signed proof APKs (12 KB, not the store build) live at
`Mobile/build/play/{admin,mailroom,oneops,mobistack}-adi.apk`. They contain only
`assets/adi-registration.properties` and are signed with the upload key.

If Play asks again: **Verify** → upload the matching `*-adi.apk` → **Submit**.

## Create / publish each Play listing

Play Console apps were created 2026-09-20 (MobiStack already existed).
Automatic protection was **turned off** on the new apps (Flutter AABs).

Progress as of 2026-09-21 (browser). Production was requested for **all four
including Admin**. Public Production is still **locked by Play** until closed
testing completes (see below).

### Done in Play Console

- **Default store listings** saved (en-IN / en-US copy + graphics) for all four:
  512 icon, 1024×500 feature graphic, ≥2 phone screenshots, 7-inch and 10-inch
  tablet screenshots (canvas-generated from CORS icons when device shots were
  unavailable).
- **Store settings** on all four: category **Business**; contact email
  `privacy@prabhixtechnologies.com`; website `https://prabhixtechnologies.com`.
- **Privacy policy** on all four:
  `https://prabhixtechnologies.com/legal/privacy`.
- **Advertising ID** declared **No** on all four.
- **Health apps**: “My app does not have any health features” saved on all four.
- MobiStack also already had content rating, target audience 18+, Data safety,
  Government apps, Financial features, Ads, and sign-in details on the
  dashboard (10/13 then category + health).
- **Internal testing live**:
  - MobiStack: **1.2.0 (version code 4)**, Aug 28 — testers can install this now
    (USB/debug builds must be uninstalled first).
  - OneOps: `1 (1.0.0)` available; tester list attached 2026-09-21.
  - Mailroom + Admin: `1 (1.0.0)` **published** 2026-09-21 (tracks Active).
- **MobiStack 1.2.1+5 AAB** built 2026-09-22
  (`Mobile/build/play/mobistack-release.aab`). Play **rejected** the upload:
  then-current upload key SHA-1 `E9:C5:DC:40:…:7E` vs this keystore `65:7A:6E:38:…:62`.
  **Upload key reset was approved** (confirmed 2026-09-24). Re-upload 1.2.1+5;
  do not bump version again until that AAB is accepted.
- **MobiStack Closed testing – Alpha** (track
  `4698130848654705919`): testers list **Internal Testing** (1 user) selected;
  draft release exists. Countries still **0** (India is listed as Not targeted;
  Edit countries stayed disabled).

Graphics upload in Play: **Add assets** → library → **Upload** (CORS
`http://127.0.0.1:8765`) → **Crop** → **Save as copy** → **add_photo_alternate
Add**. Unique filenames for phone vs tablet or Play **deduplicates** assets.

### Production gate (cannot skip)

Dashboard → Production:

- Publish a **closed testing** release
- **≥ 12 testers opted in** (currently 0 on MobiStack)
- Run that test **≥ 14 days**
- Then **Apply for production**

Until then **Send app for review** stays disabled (“complete the required steps
in the app dashboard”).

Remaining:

1. Target **India** on each closed track (Countries / regions → Edit / Add).
2. Preview + send the Alpha (and other apps’) closed releases for review.
3. Grow the **Internal Testing** email list to 12 Play-account emails and have
   them opt in via the join link (shown after the closed release is live).
   Already on the list (2026-09-21): `admin@prabhixtechnologies.com`,
   `abhishek734891@gmail.com`, `abhisheksingh.nsut@gmail.com` (3 of 12).
   Play does **not** email invites. Testers must open the join link while
   signed into that Google account, then tap **Become a tester**.
   Internal testing join links (available now):
   - MobiStack: https://play.google.com/apps/internaltest/4699612970327663424
   - OneOps: https://play.google.com/apps/internaltest/4700442168866171837
   - Mailroom: https://play.google.com/apps/internaltest/4701189268027727163
   - Admin: https://play.google.com/apps/internaltest/4699708840145338278
   Closed-testing opt-in URLs stay disabled until that track is published.
4. After Google approves the **MobiStack upload key reset**, upload the already
   built `1.2.1+5` AAB to Internal. USB/debug installs must be uninstalled first
   or Play download fails with a signature conflict.
5. Repeat closed-track testers + countries + rollout for OneOps, Mailroom,
   Admin.
6. After 14 days with 12 testers: **Apply for production** on all four.
7. **App access**: Play-reviewer Identity login (sample org). Do not paste a
   personal production admin password.
8. If Play rejects the upload key: Request reset with
   `D:\Projects\KEYS\prabhix-play-upload.pem`.

## GitHub Actions (optional later)

Repo `prabhixtechnologies/Mobile` secrets:

| Secret | Value |
|---|---|
| `ANDROID_RELEASE_KEYSTORE_BASE64` | `certutil -encode` / `base64 -w0` of the `.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | from credentials file |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | same as store password |

Until those exist, CI still falls back to unsigned/debug APKs for the S3 store.

## Do not

- Rename package IDs or OAuth redirect schemes.
- Register the Android **debug** keystore (`~/.android/debug.keystore`) on Play.
- Commit `*.jks`, `key.properties`, or passwords.
- Reuse MobiStack’s four existing Play fingerprints on the other apps.

# Public APK downloads (OneOps + Mailroom + MobiStack)

Admin is excluded. Staff get Admin builds through an internal channel, not this page.

## Live path

1. Upload release APKs to the private bucket `prabhix-apk-downloads` (ap-south-1):

```
s3://prabhix-apk-downloads/
  mobistack/android.apk
  oneops/android.apk
  mailroom/android.apk
  mobistack/latest.apk   # optional alias
  oneops/latest.apk
  mailroom/latest.apk
```

2. The `app-store` container on the platform host streams those objects over
   `https://store.prabhixtechnologies.com/{product}/android.apk` using the EC2
   instance role (`PrabhixApkDownloadsRead` on `prabhix-ec2-ecr-pull`).

3. MobiStack `/app` links to the store URL. `mobistack…/download/android` permanently
   redirects there and never serves bytes.

## Flutter cutover

New builds live under `Mobile/apps/{oneops,mailroom,mobistack,admin}` (see
[MOBILE-FLUTTER.md](../../docs/MOBILE-FLUTTER.md) and [Mobile/CUTOVER.md](../../../Mobile/CUTOVER.md)).
Keep the same S3 keys and applicationIds so store URLs and Play continuity stay stable.
Until Flutter release APKs replace natives, CI still may publish native debug artifacts.

## Status (2026-09-13)

Bucket exists; store streams from S3; MobiStack no longer hosts Android APKs.
Flutter Melos workspace scaffolded; Identity-only Expo stopgap shipped for MobiStack
while Flutter MobiStack reaches parity.

Still open for a future `downloads.prabhixtechnologies.com` marketing page: CloudFront (or
public-read) + DNS, and CI upload after release-signed assemble
(see `docs/ANDROID-RELEASE-SIGNING.md`).

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

## Status (2026-09-13)

Bucket exists; store streams from S3; MobiStack no longer hosts Android APKs.

Still open for a future `downloads.prabhixtechnologies.com` marketing page: CloudFront (or
public-read) + DNS, and CI upload after release-signed assemble
(see `docs/ANDROID-RELEASE-SIGNING.md`).

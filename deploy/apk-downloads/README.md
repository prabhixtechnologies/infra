# Public APK downloads (OneOps + Mailroom + MobiStack)

Admin is excluded. Staff get Admin builds through an internal channel, not this page.

## Goal

- Private S3 bucket `prabhix-apk-downloads` (ap-south-1) holding release APKs
- Public CloudFront (or S3 website) origin serving a minimal HTML index + signed object URLs, **or**
  public-read objects under `/apps/{oneops,mailroom,mobistack}/latest.apk`
- CI uploads after a signed release assemble (see `docs/ANDROID-RELEASE-SIGNING.md`)

## Layout (proposed)

```
s3://prabhix-apk-downloads/
  oneops/latest.apk
  oneops/oneops-<version>.apk
  mailroom/latest.apk
  mailroom/mailroom-<version>.apk
  mobistack/latest.apk
  mobistack/mobistack-<version>.apk
  index.html
```

## index.html

A static page (checked in under `Infra/deploy/apk-downloads/index.html`) lists three download
buttons. No Admin link. Host it at `https://downloads.prabhixtechnologies.com` once DNS + cert are
ready — **not applied until you approve a deploy**.

## Terraform / apply

Skeleton: `Infra/deploy/apk-downloads/` (HTML + README). Bucket + CloudFront belong in your existing
AWS account workflow; do not `terraform apply` or touch production DNS until approved.

## Status (2026-09-13)

Bucket `prabhix-apk-downloads` exists in ap-south-1 (private). Objects currently present:

- `mobistack/latest.apk`, `mobistack/mobistack-1.0.0.apk`
- `oneops/latest.apk`
- `mailroom/latest.apk` (debug build until a release-signed APK is produced)
- `index.html`

Live download UX today does **not** read this bucket yet:

- MobiStack `/app` serves from the EC2 volume `/opt/mobistack/downloads/MobiStack.apk`
- Company store serves from `/opt/prabhix/store-artifacts/{app}/android.apk`

Still open: CloudFront (or public-read) + `downloads.prabhixtechnologies.com` DNS, and CI upload after
release-signed assemble (see `docs/ANDROID-RELEASE-SIGNING.md`).

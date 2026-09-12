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

## Blocked on you

1. Confirm AWS IAM allows creating the bucket / CloudFront distribution (earlier `prabhix` IAM was
   missing S3 write).
2. Approve creation of the bucket and the `downloads` DNS name.
3. Provide release keystores so CI can upload real APKs rather than debug artifacts.

# Local company app store

Hostname: **store.prabhixtechnologies.com** (company lineup — not MobiStack-only).

## Laptop hosts file

Add once (Administrator):

```
127.0.0.1 store.prabhixtechnologies.com
```

Then open http://store.prabhixtechnologies.com:8090/ (or the port published by compose).

## Artifacts

Drop APKs into `Infra/store-artifacts/{mobistack,oneops,mailroom}/android.apk`.
Until a file exists, product pages show “build pending”.

## Not included yet

- AWS DNS / ACM / S3 / CloudFront
- Admin APK listing
- `git push` / CI upload

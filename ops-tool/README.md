# Ops Tool (deprecated)

This FastAPI microservice has been **consolidated into the platform backend**
(`oneOps/backend`, artifact `platform`). Do not deploy this container.

## New endpoints (platform-admin JWT)

Base: `/api/v1/admin/platform`

| Method | Path |
|--------|------|
| GET | `/aws/summary?range=30d` |
| GET | `/aws/costs?range=30d` |
| GET | `/aws/instances` |
| GET | `/health/products` |
| GET | `/github/checks` |
| GET | `/pnl?mobiCaptured=&oneopsCaptured=&awsMtd=` |

Example:

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://api.prabhixtechnologies.com/api/v1/admin/platform/aws/summary?range=30d"
```

## Config

See `prabhix.ops.*` in `oneOps/backend/src/main/resources/application.yml`.

- AWS: `DefaultCredentialsProvider` on the platform instance role
- Attach `Infra/deploy/aws/ops-tool-read-policy.json` to that role (Cost Explorer, EC2, CloudWatch)
- Optional: `GITHUB_TOKEN` env on the platform container for Actions checks

The Python sources under `app/` are retained only as a reference and are unused in compose.

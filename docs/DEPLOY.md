# Deploy and database changes

A push to `main` builds that repository and, when the build is green, pushes container images to
ECR in `ap-south-1`. It does not restart production. Production moves only after a person approves
it.

## What a push builds

| Repository | Images pushed to ECR on a green `main` push |
|---|---|
| `oneOps` | `prabhix/backend`, `prabhix/web`, `prabhix/admin` |
| `MobiStack` | `prabhix/mobistack-backend`, `prabhix/mobistack-web` |
| `Platform` | `prabhix/marketing` |
| `Identity` | `prabhix/identity` |
| `Mailroom` | `prabhix/mailroom` |
| `Infra` | `prabhix/app-store` |
| `Mobile` | no container. Store APKs are a separate job. Play upload is manual. |
| `web-kit` | no image. It publishes three npm packages; a tag starting `v` triggers that. |

Each image is tagged with the 7-character commit and with `latest`. Account
`029096972251`, registry `029096972251.dkr.ecr.ap-south-1.amazonaws.com`.

### web-kit is a dependency, not a build context

There is nothing to coordinate before a build any more. `@prabhixtechnologies/brand`, `/ui` and
`/oidc-client` are published to GitHub Packages, and each app depends on a version range with the
exact tarball pinned in its own lockfile — `oneOps/web/package-lock.json`,
`MobiStack/web/package-lock.json`, `Mailroom/web/package-lock.json` and
`Platform/marketing/package-lock.json`. One lockfile serves that app's gates, tests and image, so
there is no second reference to keep in step and Dependabot can move it.

This replaced a `WEBKIT_REF` commit SHA set by hand at the top of four workflow files. It had to be
kept equal in two places per repository — the gate job cloned that commit, the image build vendored
it as a `webkit` build context — because when they were allowed to differ, the gates passed against
a newer web-kit than the one being shipped and the image build then failed on an import the job
above it had just verified. The lockfile removes the class of problem rather than the instance.

Upgrading is still deliberate: bump the range in that app's package.json, run `npm install`, and
commit the lockfile. Use npm 10 or newer — npm 8 writes lockfile entries with no `resolved` URL
and no `integrity` hash, which leaves `npm ci` nothing to verify.

GitHub Packages requires a token even though all three packages are public, which is the
registry's behaviour and not a permission left unset. In CI that is the built-in `GITHUB_TOKEN`
with `packages: read`, so no PAT is stored in any repository. Image builds receive it as a
BuildKit secret (`secrets: gh_token=…`) rather than a build arg, because a build arg is recorded
in the image history and these images are pushed to ECR. Building locally needs `GH_TOKEN` in the
environment; see LOCAL-STACK.md.

### `toomanyrequests: Data limit exceeded`

Not Docker Hub: every base image already comes from `public.ecr.aws`, and that mirror has its own
anonymous pull quota. It is a quota, not a defect — the same Dockerfile builds when the quota is
clear, so a re-run usually passes. Pushing several repositories at once is what exhausts it,
because each build pulls the same node, nginx and temurin bases anonymously.

The durable fix is to authenticate before building, which raises the limit:

    aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

That needs `ecr-public:GetAuthorizationToken` and `sts:GetServiceBearerToken`, which the `prabhix`
user does not currently have — the call fails with `AccessDeniedException`. Until those are added
to `PrabhixPlatformDeployer`, re-running the job is the only remedy.

## Put images on the server

The host is `i-05496f940af0517ae`, Elastic IP `35.154.59.116`, checkout `/opt/prabhix`, user
`prabhix`. The SSH key is `D:\Projects\KEYS\PrabhixTechnologies.pem` or
`%USERPROFILE%\.ssh\PrabhixTechnologies.pem`.

From `Infra`:

```powershell
powershell -File deploy/pull-restart.ps1 -All -Confirm
powershell -File deploy/pull-restart.ps1 -Service backend,mobistack-backend -Confirm
powershell -File deploy/pull-restart.ps1 -Service backend -Tag 771ecf0 -Confirm
```

`-Confirm` is the approval. The script SSHs in, pulls that tag, and restarts only those containers.
It does not `git pull` the host. A tag of `latest` is the images CI just published. An older sha
rolls that service back.

The same action is GitHub → Infra → Actions → **Deploy** → Run workflow. Leave the tag boxes blank
to use `latest`. That workflow does not run on push. Before relying on it, create a GitHub
environment named `production` on the Infra repository and add yourself as a required reviewer
(Settings → Environments). The laptop script is the path that works without Systems Manager.

## Database changes

Schema changes are Flyway files in the service that owns the database:

- oneOps, including the `mail` schema: `oneOps/backend/src/main/resources/db/migration`
- MobiStack: `MobiStack/backend/src/main/resources/db/migration`
- Identity: `Identity` migrations, applied when the identity container starts

They run when that container starts, which is the approved restart above. There is no separate
migration command, and SQL is not run from a laptop. The database password stays in
`/opt/prabhix/deploy/.env.prod`.

A migration that deletes or renames data has to be written so a database that still holds rows
fails closed, the way `V7__drop_credential_leftovers.sql` does. Do not empty production tables to
make a migration pass unless the person who owns production has said, in that conversation, to
delete those rows.

If the new container does not become healthy, the restart script exits and prints the container
log. The previous image is no longer running. Start it again with `-Tag` set to the previous sha.

## Google Play

Play is not part of a push. GitHub → Mobile → Actions → **Play upload** → Run workflow.

- Track `internal` (the default), `alpha`, or `beta`: type `deploy` in the confirm box.
- Track `production`: type `APPROVE PRODUCTION`.

The workflow needs secret `PLAY_SERVICE_ACCOUNT_JSON` (Play Console → Setup → API access → a
service account with release permission) and the existing upload-keystore secrets. Raise
`version` in that app's `pubspec.yaml` before the run. Play rejects a version code it already has.
Package names stay `app.prabhix.fixflow`, `com.prabhix.operator`, `com.prabhix.mailroom`, and
`com.prabhix.admin`.

## Who may do this

An agent does not deploy, does not upload to Play, and does not change production data unless the
person asked for that production action in the current conversation. A green build is not approval.

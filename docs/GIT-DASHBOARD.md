# Prabhix Control Center

Double-click `Infra\open-control-center.cmd` to manage repositories, production, and Android
releases without an agent. The old `open-git-dashboard.cmd` launcher remains compatible.

## What the controls do

- **Refresh** reads local branch, working-tree, ahead, and behind status. It does not contact GitHub.
- **Fetch all** updates remote references without merging or changing working files.
- **Check CI** shows the latest GitHub Actions result for each repository's current commit.
- **View diff** displays the selected repository's unstaged diff.
- **Select all** checks every repository. The same control is on the deploy service list and the
  production environment list. Clicking the **ALL** column header does the same thing.
- **Commit selected** runs `git add -A` and creates one commit in every checked repository that has
  changes. Review the status/diff first. Common key, certificate, credentials, and environment files
  are blocked.
- **Open log** opens today's log file, `Infra\logs\dashboard-YYYYMMDD.log`. Every button, confirmation,
  cancellation, and the full output of fetch, push, deploy, cleanup, and server checks is appended
  there and kept after the window closes. Password, token, signing-key, and private-key values are
  replaced with `[redacted]` before they are written. The file is not committed.
- **Push all pending** previews and then runs `scripts/push-waves.ps1` inside the dashboard log. It pushes
  every repository that is ahead of its upstream—not only checked rows—and waits for CI between
  dependency waves.
- **AWS status** compares each local source commit with ECR's `latest` image tag and the immutable
  tag pinned in production. `LocalInEcr=False` means CI has not published that local commit yet;
  `Deploy available` means ECR has a newer immutable image than production.
- **Deploy** opens a service list and fills each deploy tag from that service's latest immutable
  ECR image. Services with a newer image than production start selected. Check the rows you want,
  or use **Select all**, then click **Deploy now**. Selected services run one after another. Each tag is
  verified in ECR, the matching production pin is backed up and updated, and a failed deploy
  restores its pin. It never deploys `latest`. `deploy.sh` runs detached on the server in
  `~/deploy-runs/<time>-<service>/` (`output.log`, `exit`), and the dashboard polls it with short SSH
  calls, so a dropped connection cannot hang a deploy. If contact is lost, read that folder before
  deploying again.
- **Monitor** opens the production monitor. It opens by itself when a deploy starts.
  The **Deployment** tab lists each selected service with its status, current step, progress, and
  time, plus the live deploy output. Steps come from `deploy.sh` (ECR sign-in, image pull, start,
  health check, version saved). A rollback is flagged, and a failure skips the remaining services.
  The **Server (EC2)** tab shows the instance state, status checks, CPU, load, memory, disk, uptime,
  and every container's health. It refreshes every 15 seconds and reads no secrets
  (`deploy/server-status.ps1`). Closing the monitor only hides it; the deploy keeps running.
- **Environment** loads `/opt/prabhix/deploy/.env.prod` over the production SSH key. Secret values stay
  hidden and are kept when left blank. Every setting starts selected; clear **Select all** to update
  only the rows you check. Saving requires `UPDATE ENV`, first creates a timestamped `.pre-edit`
  backup, and then replaces the file. It does not restart containers; the new values take effect on
  the next deploy or restart. If `ENV_SOURCE` is `ssm`, that next deploy can replace the file from
  Parameter Store.
- **Clean ECR** previews old tagged application releases, then requires typing `DELETE`. It always
  preserves `latest`, every production-pinned image, and the selected rollback window. The minimum
  is three recent images; ten is the default. Untagged multi-architecture manifests remain under
  ECR's existing lifecycle rule so direct deletion cannot break a referenced image. This cleans the
  registry, not the EC2 disk.
- **Clean disk** previews the production server disk, then requires typing `DELETE`. It removes
  Docker images no container is using, Docker build cache, systemd journal beyond the newest 80 MB,
  and deploy run logs older than 14 days. Running containers, the images they use, Docker volumes,
  ECR, and S3 are left in place.
- **Play Store** opens Android release control for Admin, Mailroom, OneOps, and MobiStack. It shows
  package IDs and versions, safely updates selected `pubspec.yaml` files, builds signed AAB/APK
  artifacts, installs selected APKs over USB, and dispatches the manual Play workflow to Internal,
  Closed testing (`alpha`), Beta, or Production. Guided controls keep each step separate.
  **Quick release** requires a clean Mobile `main`, then updates only selected version files,
  commits and pushes them, starts the selected Play track, and displays the GitHub workflow link.
  Other Mobile changes stay uncommitted; a changed keystore, key file, or environment file stops the
  release. Test tracks require a confirmation button;
  Production still requires typing `APPROVE PRODUCTION` and cannot bypass Google's testing gate.

The dashboard never deploys or deletes anything without the explicit confirmation words above. It
does not upload mobile builds, merge branches, rebase, create tags, or resolve conflicts.

## Existing automatic ECR retention

`deploy/aws/ecr-lifecycle.json` already expires untagged images after seven days and keeps at most 20
images per application repository. The manual cleanup is for an intentional one-time reduction. Do
not keep only one or two images: that removes a practical rollback window. Third-party mirror images
under `prabhix/third-party/*` are outside this cleanup.

## Agent policy

The always-applied workspace rule in `.cursor/rules/multi-repo-push.mdc` prohibits agents from
committing or pushing unless the user explicitly requests that action in the current conversation.
Use the dashboard for routine Git work; use an agent when a diff, conflict, or failed check needs
technical investigation.

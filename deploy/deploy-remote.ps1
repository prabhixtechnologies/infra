# deploy-remote.ps1 — production deploy from a Windows workstation, over SSH.
#
# The same deploy.sh that .github/workflows/deploy.yml runs through SSM. This is the path for when
# GitHub or SSM is what is broken; the workflow is the everyday one, because it leaves a record and
# needs no key on a laptop.
#
# Usage:
#   .\deploy\deploy-remote.ps1                       # deploy :latest to the production host
#   .\deploy\deploy-remote.ps1 -Tag 78a9ec6          # deploy a specific image tag
#   .\deploy\deploy-remote.ps1 -BackendTag 78a9ec6   # move one service, leave the rest alone
#   .\deploy\deploy-remote.ps1 -SkipSmoke            # skip the post-deploy checks

param(
    [string]$HostAddress = "35.154.59.116",
    [string]$User = "prabhix",
    [string]$KeyPath = "$env:USERPROFILE\.ssh\PrabhixTechnologies.pem",
    # The fallback tag: every service without one of its own is deployed at this. CI tags each build
    # with the short SHA as well as `latest`.
    [string]$Tag = "latest",
    # Per-service overrides, for the normal case where one repository has moved and the others have
    # not. Empty means "follow -Tag", and is not sent at all — sending an empty value would read to
    # compose as a deliberate empty tag.
    [string]$BackendTag = "",
    [string]$WebTag = "",
    [string]$AdminTag = "",
    [string]$MarketingTag = "",
    [string]$IdentityTag = "",
    [string]$MailroomTag = "",
    [string]$MobiStackBackendTag = "",
    [string]$MobiStackWebTag = "",
    [string]$AppStoreTag = "",
    [string]$RemoteRoot = "/opt/prabhix",
    # Deploy the checkout that is already on the host, at the commit you say it is at, instead of
    # pulling. For when the host cannot reach GitHub -- a deploy key not yet added, an outage.
    #
    # It takes the sha rather than being a bare -SkipPull because the pull is what normally
    # guarantees the host is running the tooling in the repository. Skipping it silently is how a
    # deploy comes to be driven by a deploy.sh from three weeks ago; asserting the commit keeps the
    # guarantee and only changes how it is met.
    [string]$AtCommit = "",
    [switch]$SkipSmoke
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $KeyPath)) {
    throw "SSH key not found at $KeyPath. Pass -KeyPath, or see deploy/RUNBOOK.md for key setup."
}

<#
The remote script is shipped base64-encoded rather than passed as an ssh argument.

Two things otherwise corrupt it. PowerShell rewrites quoting when it hands arguments to a native
command, so a quoted bash pattern arrives at the remote shell unquoted and splits on its own pipes
and spaces. And a here-string written on Windows carries CRLF endings, which bash reads as part of
each command — producing `$'\r': command not found` on every line. Encoding sidesteps both: the
bytes travel as a single opaque token and are decoded by the remote shell.
#>
function Invoke-Remote {
    param([string]$Script)
    $lf = $Script.Replace("`r`n", "`n")
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))

    <#
    stderr is merged into stdout on the remote side, and $ErrorActionPreference is relaxed for the
    duration of the call.

    Both are needed. Plenty of healthy tools report progress on stderr — `git pull` announces
    "From https://github.com/..." there, and `docker compose` writes every container transition
    there — and PowerShell turns each such line into a NativeCommandError. Under
    $ErrorActionPreference = "Stop" the first one aborts the deploy while it is still succeeding.
    #>
    $prior = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & ssh -i $KeyPath -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
            "$User@$HostAddress" "echo $b64 | base64 -d | bash 2>&1" |
            ForEach-Object { Write-Host $_ }
    }
    finally {
        $ErrorActionPreference = $prior
    }
}

$overrides = [ordered]@{
    BACKEND_TAG   = $BackendTag
    WEB_TAG       = $WebTag
    ADMIN_TAG     = $AdminTag
    MARKETING_TAG = $MarketingTag
    IDENTITY_TAG  = $IdentityTag
    MAILROOM_TAG  = $MailroomTag
    MOBISTACK_BACKEND_TAG = $MobiStackBackendTag
    MOBISTACK_WEB_TAG     = $MobiStackWebTag
    APP_STORE_TAG         = $AppStoreTag
}
$exports = ($overrides.GetEnumerator() | Where-Object { $_.Value } |
    ForEach-Object { "export $($_.Key)=`"$($_.Value)`"" }) -join "`n"

$named = ($overrides.GetEnumerator() | Where-Object { $_.Value } |
    ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " "
$summary = if ($named) { "tag '$Tag' with $named" } else { "tag '$Tag'" }
Write-Host "==> Deploying $summary to $User@$HostAddress" -ForegroundColor Cyan

$sync = if ($AtCommit) {
    @"
echo "[remote] not pulling; asserting the checkout is at $AtCommit"
actual=`$(git rev-parse --short=7 HEAD)
if [ "`$actual" != "$AtCommit" ]; then
  echo "[remote] checkout is at `$actual, not $AtCommit -- refusing to deploy"
  exit 1
fi
echo "[remote] commit: `$(git log --oneline -1)"
if [ -n "`$(git status --porcelain)" ]; then
  echo "[remote] checkout has local modifications -- refusing to deploy"
  git status --porcelain
  exit 1
fi
"@
} else {
    @"
echo "[remote] commit before: `$(git log --oneline -1)"
git pull --ff-only
echo "[remote] commit after:  `$(git log --oneline -1)"
"@
}

$remote = @"
set -euo pipefail
cd $RemoteRoot

$sync

export TAG="$Tag"
$exports
bash deploy/deploy.sh
"@

Invoke-Remote -Script $remote
if ($LASTEXITCODE -ne 0) {
    throw "Remote deploy failed with exit code $LASTEXITCODE. deploy.sh rolls the stack back on failure; check the output above."
}

Write-Host "==> Remote deploy finished" -ForegroundColor Green

if ($SkipSmoke) {
    Write-Host "==> Skipping smoke checks (-SkipSmoke)" -ForegroundColor Yellow
    return
}

Write-Host "==> Running smoke checks" -ForegroundColor Cyan

# OrgSlug is the organization oneOps/deploy/seed.sql creates. It said prabhix-technologies, which is not in
# the database -- the same wrong slug the marketing image was built with -- so the storefront and
# origin-allowlist checks were not exercising the org the site actually calls.
#
# The comment lives here rather than inside the call because a comment between backtick-continued
# lines ends the continuation, and PowerShell then tries to run the next argument as a command.
& "$PSScriptRoot\smoke.ps1" `
    -ApiBase "https://api.prabhixtechnologies.com" `
    -MarketingBase "https://prabhixtechnologies.com" `
    -ConsoleBase "https://oneops.prabhixtechnologies.com" `
    -MailroomBase "https://mail.prabhixtechnologies.com" `
    -OrgSlug "prabhix-platform"

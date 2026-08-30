# deploy-remote.ps1 — manual production deploy from a Windows workstation.
#
# Deploys are deliberately manual: no SSH private key is stored in GitHub, so there is no Actions
# workflow that can reach the host. CI's job ends at pushing images to Amazon ECR; this script is
# what moves them onto the server.
#
# Usage:
#   .\deploy\deploy-remote.ps1                       # deploy :latest to the production host
#   .\deploy\deploy-remote.ps1 -Tag 78a9ec6          # deploy a specific image tag
#   .\deploy\deploy-remote.ps1 -SkipSmoke            # skip the post-deploy checks

param(
    [string]$HostAddress = "35.154.59.116",
    [string]$User = "prabhix",
    [string]$KeyPath = "$env:USERPROFILE\.ssh\PrabhixTechnologies.pem",
    # Image tag to deploy. CI tags each build with the short SHA as well as `latest`.
    [string]$Tag = "latest",
    [string]$RemoteRoot = "/opt/prabhix",
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

Write-Host "==> Deploying tag '$Tag' to $User@$HostAddress" -ForegroundColor Cyan

$remote = @"
set -euo pipefail
cd $RemoteRoot

echo "[remote] commit before: `$(git log --oneline -1)"
git pull --ff-only
echo "[remote] commit after:  `$(git log --oneline -1)"

export TAG="$Tag"
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
& "$PSScriptRoot\smoke.ps1" `
    -ApiBase "https://api.prabhixtechnologies.com" `
    -MarketingBase "https://prabhixtechnologies.com" `
    -ConsoleBase "https://oneops.prabhixtechnologies.com" `
    -MailroomBase "https://mail.prabhixtechnologies.com" `
    # The organization deploy/seed.sql creates. This said prabhix-technologies, which is not in the
    # database -- the same wrong slug the marketing image was built with -- so the storefront check
    # was either passing against an empty result or failing unnoticed. With the real slug it now
    # verifies the storefront the marketing site actually calls.
    -OrgSlug "prabhix-platform"

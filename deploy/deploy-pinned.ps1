# Deploys one production service at an immutable ECR tag and persists that pin.
# The pin file is restored if deploy.sh fails. This script never accepts :latest.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Service,
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Region = "ap-south-1",
    [string]$HostAddress = "35.154.59.116",
    [string]$User = "prabhix",
    [string]$KeyPath = "$env:USERPROFILE\.ssh\PrabhixTechnologies.pem",
    [string]$RemoteRoot = "/opt/prabhix",
    [switch]$Confirm
)

$ErrorActionPreference = "Stop"

if (-not $Confirm) {
    throw "Refusing to deploy production. Re-run with -Confirm after explicitly approving this deploy."
}
if ($Tag -eq "latest" -or $Tag -notmatch "^[0-9a-f]{7,40}$") {
    throw "Use an immutable 7-40 character commit tag, not '$Tag'."
}
if (-not (Test-Path $KeyPath)) {
    throw "SSH key not found at $KeyPath."
}

$known = [ordered]@{
    "backend" = @{ Pin = "BACKEND_TAG"; Repo = "prabhix/backend" }
    "web" = @{ Pin = "WEB_TAG"; Repo = "prabhix/web" }
    "admin" = @{ Pin = "ADMIN_TAG"; Repo = "prabhix/admin" }
    "marketing" = @{ Pin = "MARKETING_TAG"; Repo = "prabhix/marketing" }
    "identity" = @{ Pin = "IDENTITY_TAG"; Repo = "prabhix/identity" }
    "mailroom" = @{ Pin = "MAILROOM_TAG"; Repo = "prabhix/mailroom" }
    "mobistack-backend" = @{ Pin = "MOBISTACK_BACKEND_TAG"; Repo = "prabhix/mobistack-backend" }
    "mobistack-web" = @{ Pin = "MOBISTACK_WEB_TAG"; Repo = "prabhix/mobistack-web" }
    "app-store" = @{ Pin = "APP_STORE_TAG"; Repo = "prabhix/app-store" }
}

if (-not $known.Contains($Service)) {
    throw "Unknown service '$Service'. Known: $($known.Keys -join ', ')"
}

$prior = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & aws ecr describe-images --region $Region --repository-name $known[$Service].Repo `
        --image-ids "imageTag=$Tag" --output json *> $null
    $found = $LASTEXITCODE -eq 0
} finally {
    $ErrorActionPreference = $prior
}
if (-not $found) {
    throw "$($known[$Service].Repo):$Tag does not exist in ECR. Wait for CI or choose an existing immutable tag."
}

$pin = $known[$Service].Pin
$remote = @"
set -euo pipefail
cd "$RemoteRoot"
env_file="deploy/.env.prod"
backup="`$env_file.pre-deploy-`$(date -u +%Y%m%dT%H%M%SZ)"
grep -q '^$pin=' "`$env_file"
cp -p "`$env_file" "`$backup"
restore_pin() {
  cp -p "`$backup" "`$env_file"
  echo "[remote] restored the previous pin file after deploy failure" >&2
}
trap restore_pin ERR
sed -i -E 's/^$pin=.*/$pin=$Tag/' "`$env_file"
export $pin="$Tag"
echo "[remote] $Service -> $Tag; backup: `$backup"
bash deploy/deploy.sh
trap - ERR
echo "[remote] production pin persisted: $pin=$Tag"
"@

$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote.Replace("`r`n", "`n")))
Write-Host "==> Production deploy: $Service -> $Tag" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
try {
    & ssh -i $KeyPath -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
        "$User@$HostAddress" "echo $encoded | base64 -d | bash 2>&1" |
        ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = "Stop"
}
if ($exitCode -ne 0) {
    throw "Production deploy failed with exit code $exitCode. The previous pin file was restored."
}
Write-Host "==> Production is pinned to ${Service}:$Tag" -ForegroundColor Green

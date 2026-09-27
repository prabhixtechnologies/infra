# pull-restart.ps1 — put images that CI already pushed to ECR onto the production host.
#
# This script does not build anything and it does not change the server checkout. GitHub Actions
# builds on push to main and pushes :latest plus the commit sha. After that build is green, and
# only when a person has decided production should move, run this. The remote action delegates to
# deploy/deploy.sh so ordering, Flyway gates and rollback have one implementation.
#
#   powershell -File deploy/pull-restart.ps1 -All -Confirm
#   powershell -File deploy/pull-restart.ps1 -Service backend,mobistack-backend -Confirm
#   powershell -File deploy/pull-restart.ps1 -Service backend -Tag 771ecf0 -Confirm
#
# -Confirm is the approval. Without it the script stops. Flyway runs when backend or
# mobistack-backend starts, so a new image is also the database migration. See docs/DEPLOY.md.

param(
    [string]$HostAddress = "35.154.59.116",
    [string]$User = "prabhix",
    [string]$KeyPath = "$env:USERPROFILE\.ssh\PrabhixTechnologies.pem",
    [string]$Service = "",
    [switch]$All,
    [string]$Tag = "latest",
    [string]$RemoteRoot = "/opt/prabhix",
    [switch]$Confirm
)

$ErrorActionPreference = "Stop"

if (-not $Confirm) {
    throw "Refusing to touch production. Re-run with -Confirm after you have decided this deploy should go live."
}
if ($All -and $Service) {
    throw "Pass -All or -Service, not both."
}
if (-not $All -and -not $Service) {
    throw "Name the containers with -Service backend,web or pass -All."
}
if ($Tag -notmatch '^[A-Za-z0-9_.-]{1,128}$') {
    throw "Tag '$Tag' is not an image tag."
}
if (-not (Test-Path $KeyPath)) {
    throw "SSH key not found at $KeyPath."
}

$known = [ordered]@{
    "backend"            = "BACKEND_TAG"
    "web"                = "WEB_TAG"
    "admin"              = "ADMIN_TAG"
    "marketing"          = "MARKETING_TAG"
    "identity"           = "IDENTITY_TAG"
    "mailroom"           = "MAILROOM_TAG"
    "mobistack-backend"  = "MOBISTACK_BACKEND_TAG"
    "mobistack-web"      = "MOBISTACK_WEB_TAG"
    "app-store"          = "APP_STORE_TAG"
}

$selected = if ($All) { @($known.Keys) } else { $Service.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
foreach ($name in $selected) {
    if (-not $known.Contains($name)) {
        throw "Unknown service '$name'. Known: $($known.Keys -join ', ')"
    }
}

$exports = ($selected | ForEach-Object { "export $($known[$_])=$Tag" }) -join "`n"
$serviceList = $selected -join " "
Write-Host "==> Production: deploy $serviceList at $Tag and revalidate the stack" -ForegroundColor Cyan

$remote = @"
set -euo pipefail
cd $RemoteRoot
$exports
echo "[remote] invoking the audited deploy orchestrator for $serviceList"
bash deploy/deploy.sh
"@

$lf = $remote.Replace("`r`n", "`n")
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))
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
if ($LASTEXITCODE -ne 0) {
    throw "Production restart failed with exit code $LASTEXITCODE."
}
Write-Host "==> Production is on $Tag for $serviceList" -ForegroundColor Green

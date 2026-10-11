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
exec 8>/tmp/prabhix-deploy.lock
flock 8
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

function Invoke-RemoteBash {
    param([string]$Script, [int]$TimeoutSeconds = 45)
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script.Replace("`r`n", "`n")))
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "ssh"
    $startInfo.Arguments = (
        "-n -i `"$KeyPath`" -o BatchMode=yes -o StrictHostKeyChecking=accept-new " +
        "-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 " +
        "$User@$HostAddress `"echo $payload | base64 -d | bash`""
    )
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            return [pscustomobject]@{ ExitCode = -1; Output = ""; Error = "timed out after $TimeoutSeconds seconds" }
        }
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result; Error = $stderr.Result.Trim() }
    } finally {
        $process.Dispose()
    }
}

# deploy.sh runs detached on the server and is polled with short SSH calls, so a
# dropped or half-closed connection cannot leave the deploy waiting forever.
$runId = "$(Get-Date -Format 'yyyyMMddTHHmmss')-$Service"
$runDir = "`$HOME/deploy-runs/$runId"
$remoteEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote.Replace("`r`n", "`n")))
$launch = @"
set -euo pipefail
mkdir -p "$runDir"
echo "$remoteEncoded" | base64 -d > "$runDir/deploy.sh"
nohup setsid bash -c 'bash "`$1/deploy.sh" > "`$1/output.log" 2>&1; echo `$? > "`$1/exit.tmp"; mv "`$1/exit.tmp" "`$1/exit"' _ "$runDir" < /dev/null > /dev/null 2>&1 &
echo started
"@

Write-Host "==> Production deploy: $Service -> $Tag" -ForegroundColor Cyan
$started = Invoke-RemoteBash $launch 45
if ($started.ExitCode -ne 0 -or $started.Output -notmatch "started") {
    throw "Could not start the production deploy ($($started.Error)). Nothing was changed."
}
Write-Host "[remote] deploy running on the server; run folder ~/deploy-runs/$runId"

$linesSeen = 0
$exitCode = $null
$failures = 0
$deadline = (Get-Date).AddMinutes(30)
while ($null -eq $exitCode) {
    if ((Get-Date) -gt $deadline) {
        throw "No result after 30 minutes. Check ~/deploy-runs/$runId on the server before deploying again."
    }
    Start-Sleep -Seconds 3
    $poll = Invoke-RemoteBash @"
log="$runDir/output.log"
code=`$(cat "$runDir/exit" 2>/dev/null || true)
total=`$(wc -l < "`$log" 2>/dev/null || echo 0)
if [ "`$total" -gt $linesSeen ]; then sed -n "$($linesSeen + 1),`${total}p" "`$log"; fi
echo "__LINES__=`$total"
echo "__EXIT__=`$code"
"@ 30
    if ($poll.ExitCode -ne 0) {
        $failures++
        Write-Host "[dashboard] status check failed ($($poll.Error)); retrying ($failures)"
        if ($failures -ge 20) {
            throw "Lost contact with the server. The deploy may still be running; check ~/deploy-runs/$runId."
        }
        continue
    }
    $failures = 0
    foreach ($line in @($poll.Output -split "`r?`n")) {
        if ($line -match '^__LINES__=(\d+)$') { $linesSeen = [int]$Matches[1]; continue }
        if ($line -match '^__EXIT__=(\d*)$') { if ($Matches[1] -ne "") { $exitCode = [int]$Matches[1] }; continue }
        if ($line -ne "") { Write-Host $line }
    }
}

if ($exitCode -ne 0) {
    throw "Production deploy failed with exit code $exitCode. The previous pin file was restored."
}
Write-Host "==> Production is pinned to ${Service}:$Tag" -ForegroundColor Green

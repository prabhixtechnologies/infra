# Frees space on the production EC2 disk. Preview is the default.
# Deletion requires -Apply -ConfirmWord DELETE.
#
# Removes Docker images that no container references, leftover build cache,
# systemd journal beyond the newest 80 MB, and deploy run folders older than
# 14 days. Running containers, their images, Docker volumes, ECR, and S3 are
# left alone.
[CmdletBinding()]
param(
    [string]$HostAddress = "35.154.59.116",
    [string]$User = "prabhix",
    [string]$KeyPath = "$env:USERPROFILE\.ssh\PrabhixTechnologies.pem",
    [switch]$Apply,
    [string]$ConfirmWord = ""
)

$ErrorActionPreference = "Stop"

if ($Apply -and $ConfirmWord -cne "DELETE") {
    throw "Deletion requires -Apply -ConfirmWord DELETE."
}
if (-not (Test-Path $KeyPath)) {
    throw "SSH key not found at $KeyPath."
}

$report = @'
set -euo pipefail
echo "=== disk ==="
df -h /
echo "=== docker ==="
docker system df
echo "=== journal ==="
sudo journalctl --disk-usage
echo "=== deploy run logs ==="
du -sh "$HOME/deploy-runs" 2>/dev/null || echo "none"
'@

$clean = @'
set -euo pipefail
echo "=== before ==="
df -h /
docker system df
sudo journalctl --disk-usage
echo "=== removing images not used by a container ==="
docker image prune -a -f
echo "=== removing build cache ==="
docker builder prune -af || echo "no build cache"
echo "=== keeping the newest 80 MB of system journal ==="
sudo journalctl --vacuum-size=80M
echo "=== removing deploy run logs older than 14 days ==="
if [ -d "$HOME/deploy-runs" ]; then
  find "$HOME/deploy-runs" -mindepth 1 -maxdepth 1 -type d -mtime +14 -print -exec rm -rf {} +
fi
echo "=== after ==="
df -h /
docker system df
sudo journalctl --disk-usage
'@

function Invoke-ProductionBash {
    param([string]$Script, [int]$TimeoutSeconds)
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script.Replace("`r`n", "`n")))
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "ssh"
    $startInfo.Arguments = (
        "-n -i `"$KeyPath`" -o BatchMode=yes -o ConnectTimeout=10 " +
        "-o ServerAliveInterval=5 -o ServerAliveCountMax=3 " +
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
            throw "The server did not finish within $TimeoutSeconds seconds. Run the preview again before deleting."
        }
        $process.WaitForExit()
        $text = (@($stdout.Result, $stderr.Result) | Where-Object { $_ }) -join [Environment]::NewLine
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $text.TrimEnd() }
    } finally {
        $process.Dispose()
    }
}

if ($Apply) {
    Write-Host "==> Cleaning unused images and old logs on $HostAddress"
    $result = Invoke-ProductionBash $clean 180
} else {
    Write-Host "==> Disk cleanup preview for $HostAddress. Nothing will be deleted."
    Write-Host "Apply removes: images no container uses, Docker build cache, journal beyond 80 MB,"
    Write-Host "and deploy run logs older than 14 days."
    Write-Host "Left in place: running containers, their images, Docker volumes, ECR, and S3."
    $result = Invoke-ProductionBash $report 60
}

if ($result.Output) { Write-Host $result.Output }
if ($result.ExitCode -ne 0) {
    throw "Disk cleanup failed with exit code $($result.ExitCode)."
}
if (-not $Apply) {
    Write-Host "==> Preview only. Type DELETE in the dashboard to apply this cleanup."
}

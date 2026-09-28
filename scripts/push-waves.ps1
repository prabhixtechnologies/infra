# Pushes the repositories in waves instead of all at once.
#
# Every repository that builds a container image pulls its base layers from public.ecr.aws during
# CI. Pushing eight repositories together starts eight concurrent builds, they pull at the same
# moment, and the gallery answers `429 toomanyrequests: Data limit exceeded`. The builds that fail
# this way are not broken -- a documentation-only commit has failed on it -- so the signal is lost
# and a real failure looks the same as a neighbour's traffic.
#
# Two things fix it and this script is the cheap one: cap how many image builds run at once. The
# durable one is mirroring the base images into private ECR, which needs an IAM change first --
# see deploy/aws/README.md and mirror-third-party.ps1.
#
# The waves are ordered by dependency, not by size. web-kit goes alone and first because the other
# seven clone it during their own CI, so a wave that pushed a consumer alongside it could test the
# consumer against the previous web-kit. After that the only rule is at most two image builders per
# wave; Mobile has no Dockerfile and rides along at the end.
#
# Usage:
#   pwsh Infra/scripts/push-waves.ps1              # push what is ahead, waiting between waves
#   pwsh Infra/scripts/push-waves.ps1 -WhatIf      # show the plan, push nothing
#   pwsh Infra/scripts/push-waves.ps1 -NoWait      # push every wave without waiting for CI
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Skip the wait between waves. Faster, and gives up the thing the script is for -- use it only
    # when none of the pending commits touches a Dockerfile or anything a container build reads.
    [switch]$NoWait,
    # How long to wait for one wave's CI before moving on regardless.
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = "Stop"

# git and gh write ordinary progress to stderr, which under ErrorActionPreference = Stop becomes a
# terminating error on a command that succeeded. build-push.ps1 has the same wrapper for the same
# reason.
function Invoke-Native {
    param([Parameter(Mandatory = $true)][scriptblock]$Command)
    $prior = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Command 2>&1 | Out-String } finally { $ErrorActionPreference = $prior }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

# Images is how many container images the repository's CI builds. It decides the wave layout, so
# it has to be updated when a repository gains or loses a Dockerfile.
$waves = @(
    @{ Name = "web-kit";   Repos = @("web-kit") },
    @{ Name = "web";       Repos = @("Platform", "oneOps") },
    @{ Name = "apps";      Repos = @("MobiStack", "Mailroom") },
    @{ Name = "platform";  Repos = @("Identity", "Infra") },
    @{ Name = "mobile";    Repos = @("Mobile") }
)

function Get-Pending {
    param([string]$Repo)
    $path = Join-Path $root $Repo
    if (-not (Test-Path $path)) { return $null }
    Push-Location $path
    try {
        $ahead = @(& git -c core.pager=cat log '@{u}..HEAD' --oneline 2>$null)
        $dirty = @(& git status --porcelain)
        return [pscustomobject]@{
            Repo  = $Repo
            Path  = $path
            Ahead = $ahead.Count
            Dirty = $dirty.Count
        }
    } finally { Pop-Location }
}

function Wait-ForCi {
    param([string[]]$Repos, [int]$Minutes)
    $deadline = (Get-Date).AddMinutes($Minutes)
    $waiting = [System.Collections.ArrayList]::new()
    $Repos | ForEach-Object { [void]$waiting.Add($_) }

    while ($waiting.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        foreach ($repo in @($waiting)) {
            Push-Location (Join-Path $root $repo)
            try {
                $head = (& git -c core.pager=cat rev-parse HEAD).Trim()
                $json = Invoke-Native { gh run list --limit 15 --json status,conclusion,headSha,event }
                $runs = $null
                try { $runs = $json | ConvertFrom-Json } catch { }
                # Only the push-triggered runs. Dependabot's own update checks are attributed to
                # the same commit under the `dynamic` event, and two of those are permanently red
                # for reasons that have nothing to do with the push -- counting them reported
                # "2 failing" on a commit whose CI was entirely green.
                #
                # No run for this commit yet means CI has not picked it up; keep waiting rather
                # than reading the previous commit's result as this one's.
                $mine = @($runs | Where-Object { $_.headSha -eq $head -and $_.event -eq "push" })
                if ($mine.Count -eq 0) { continue }
                if (@($mine | Where-Object { $_.status -ne "completed" }).Count -gt 0) { continue }

                $failed = @($mine | Where-Object { $_.conclusion -ne "success" }).Count
                $verdict = "green"
                if ($failed -gt 0) { $verdict = "$failed failing" }
                Write-Host ("    {0,-10} {1}" -f $repo, $verdict)
                $waiting.Remove($repo)
            } finally { Pop-Location }
        }
    }

    foreach ($repo in $waiting) {
        Write-Host ("    {0,-10} still running after {1}m, moving on" -f $repo, $Minutes)
    }
}

$pushedAny = $false

foreach ($wave in $waves) {
    $pending = @($wave.Repos | ForEach-Object { Get-Pending $_ } | Where-Object { $_ -and $_.Ahead -gt 0 })

    $blocked = @($wave.Repos | ForEach-Object { Get-Pending $_ } | Where-Object { $_ -and $_.Dirty -gt 0 })
    foreach ($b in $blocked) {
        Write-Warning ("{0} has {1} uncommitted file(s); pushing only what is committed." -f $b.Repo, $b.Dirty)
    }

    if ($pending.Count -eq 0) { continue }

    Write-Host ""
    Write-Host ("==> wave '{0}': {1}" -f $wave.Name, (($pending | ForEach-Object { "$($_.Repo) (+$($_.Ahead))" }) -join ", "))

    $sent = @()
    foreach ($p in $pending) {
        if (-not $PSCmdlet.ShouldProcess($p.Repo, "git push origin HEAD")) { continue }
        Push-Location $p.Path
        try {
            $out = Invoke-Native { git push origin HEAD }
            if ($LASTEXITCODE -ne 0) { throw "push failed for $($p.Repo): $out" }
            Write-Host ("    pushed {0}" -f $p.Repo)
            $sent += $p.Repo
            $pushedAny = $true
        } finally { Pop-Location }
    }

    if ($sent.Count -gt 0 -and -not $NoWait -and $wave -ne $waves[-1]) {
        Write-Host "    waiting for CI before the next wave"
        Wait-ForCi -Repos $sent -Minutes $TimeoutMinutes
    }
}

Write-Host ""
if ($pushedAny) {
    Write-Host "==> Done. Image builds were spread across waves rather than run together."
} else {
    Write-Host "==> Nothing to push; every repository is level with its remote."
}

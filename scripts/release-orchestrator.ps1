# Releases one or more selected modules without another prompt after approval.
#
# The sequence is version upgrade, commit, dependency-wave push, CI, ECR verification,
# sequential AWS deployment, production verification, and then Play upload. Play starts only
# after every selected AWS service succeeds. Image builds stay inside the existing wave limits.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repos,
    [string]$Services = "",
    [string]$Apps = "",
    [string]$Versions = "",
    [ValidateSet("internal", "alpha", "beta", "production")]
    [string]$Track = "internal",
    [Parameter(Mandatory = $true)][string]$CommitMessage,
    [string]$Confirm = "",
    [switch]$WhatIf,
    [int]$CiTimeoutMinutes = 25
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$pushScript = Join-Path $PSScriptRoot "push-waves.ps1"
$awsStatusScript = Join-Path $root "Infra\deploy\aws-status.ps1"
$deployScript = Join-Path $root "Infra\deploy\deploy-pinned.ps1"
$playScript = Join-Path $root "Mobile\scripts\play-release.ps1"

$repoOrder = @("web-kit", "Platform", "oneOps", "MobiStack", "Mailroom", "Identity", "Infra", "Mobile")
$serviceOrder = @(
    "identity", "backend", "mobistack-backend", "web", "admin",
    "marketing", "mailroom", "mobistack-web", "app-store"
)
$serviceSources = [ordered]@{
    backend = "oneOps"
    web = "oneOps"
    admin = "oneOps"
    marketing = "Platform"
    identity = "Identity"
    mailroom = "Mailroom"
    "mobistack-backend" = "MobiStack"
    "mobistack-web" = "MobiStack"
    "app-store" = "Infra"
}
$appOrder = @("admin", "mailroom", "oneops", "mobistack")
$appModules = @{
    admin = "Admin"
    mailroom = "Mailroom"
    oneops = "OneOps"
    mobistack = "MobiStack"
}
$secretPattern = '(^|/)(\.env(\..*)?|key\.properties|[^/]*\.(jks|pem|p12|pfx)|[^/]*credentials[^/]*)$'

function Split-CsvValue {
    param([string]$Value)
    @(
        $Value.Split(",") |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $root
    )
    $prior = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Push-Location $WorkingDirectory
        try {
            $lines = @(& $FilePath @Arguments 2>&1)
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }
    } finally {
        $ErrorActionPreference = $prior
    }
    [pscustomobject]@{
        ExitCode = $code
        Output = ($lines | Out-String).TrimEnd()
        Lines = $lines
    }
}

function Get-ChangedPaths {
    param([string]$RepoPath)
    $status = Invoke-Native "git" @("-C", $RepoPath, "status", "--porcelain=v1", "--untracked-files=all")
    if ($status.ExitCode -ne 0) { throw "Could not read git status for $RepoPath." }
    @(
        foreach ($line in @($status.Lines | ForEach-Object { "$_" })) {
            if ($line -match '^.. (.+)$') {
                ($Matches[1] -split ' -> ')[-1].Trim('"').Replace('\', '/')
            }
        }
    )
}

function Assert-ReleaseSelection {
    $selectedRepos = @(Split-CsvValue $Repos)
    if ($selectedRepos.Count -eq 0) { throw "Select at least one repository." }
    foreach ($repo in $selectedRepos) {
        if ($repoOrder -notcontains $repo) { throw "Unknown repository '$repo'." }
        if (-not (Test-Path (Join-Path (Join-Path $root $repo) ".git"))) {
            throw "Repository '$repo' is missing."
        }
    }

    $selectedServices = @(Split-CsvValue $Services)
    foreach ($service in $selectedServices) {
        if (-not $serviceSources.Contains($service)) { throw "Unknown service '$service'." }
        $source = $serviceSources[$service]
        if ($selectedRepos -notcontains $source) {
            throw "Service '$service' requires repository '$source' to be selected."
        }
    }

    $selectedApps = @(Split-CsvValue $Apps | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($app in $selectedApps) {
        if ($appOrder -notcontains $app) { throw "Unknown Android app '$app'." }
        if ($selectedRepos -notcontains "Mobile") { throw "Android release requires the Mobile repository." }
    }
    if ($selectedApps.Count -gt 0 -and -not $Versions) { throw "Selected Android apps require versions." }

    [pscustomobject]@{
        Repos = @($repoOrder | Where-Object { $selectedRepos -contains $_ })
        Services = @($serviceOrder | Where-Object { $selectedServices -contains $_ })
        Apps = @($appOrder | Where-Object { $selectedApps -contains $_ })
    }
}

function Assert-ReleaseReady {
    param($Selection)
    foreach ($command in @("git", "gh")) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "$command is required for commit, push, and CI verification."
        }
    }
    foreach ($repo in $Selection.Repos) {
        $path = Join-Path $root $repo
        $branch = (Invoke-Native "git" @("-C", $path, "branch", "--show-current")).Output.Trim()
        if ($branch -ne "main") { throw "$repo must be on main, not '$branch'." }
        $secrets = @(Get-ChangedPaths $path | Where-Object { $_ -match $secretPattern })
        if ($secrets.Count -gt 0) {
            throw "$repo has sensitive changes: $($secrets -join ', ')"
        }
    }
    if ($Selection.Services.Count -gt 0) {
        foreach ($command in @("aws", "ssh")) {
            if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required for AWS deployment." }
        }
        $key = Join-Path $env:USERPROFILE ".ssh\PrabhixTechnologies.pem"
        if (-not (Test-Path $key)) { throw "Production SSH key is missing at $key." }
    }
}

function Update-MobileVersions {
    param($Selection)
    if ($Selection.Apps.Count -eq 0) { return }
    Write-Host "==> Phase 1: upgrade Android versions"
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $playScript,
        "-Action", "SaveVersions",
        "-Apps", ($Selection.Apps -join ","),
        "-Versions", $Versions
    )
    if ($WhatIf) { $arguments += "-DryRun" }
    $result = Invoke-Native "powershell.exe" $arguments
    if ($result.Output) { Write-Host $result.Output }
    if ($result.ExitCode -ne 0) { throw "Android version upgrade failed." }
}

function Commit-SelectedRepos {
    param($Selection)
    Write-Host "==> Phase 2: commit selected repositories"
    foreach ($repo in $Selection.Repos) {
        $path = Join-Path $root $repo
        $changed = @(Get-ChangedPaths $path)
        if ($changed.Count -eq 0) {
            Write-Host "    ${repo}: clean"
            continue
        }
        Write-Host "    ${repo}: $($changed.Count) changed"
        if ($WhatIf) { continue }
        $add = Invoke-Native "git" @("-C", $path, "add", "-A")
        if ($add.ExitCode -ne 0) { throw "Could not stage ${repo}: $($add.Output)" }
        $commit = Invoke-Native "git" @("-C", $path, "commit", "-m", $CommitMessage)
        if ($commit.ExitCode -ne 0) { throw "Could not commit ${repo}: $($commit.Output)" }
        Write-Host "    ${repo}: committed"
    }
}

function Push-SelectedRepos {
    param($Selection)
    Write-Host "==> Phase 3: push in dependency waves"
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $pushScript,
        "-Repos", ($Selection.Repos -join ","),
        "-TimeoutMinutes", "$CiTimeoutMinutes"
    )
    if ($WhatIf) {
        $arguments += "-WhatIf"
    } else {
        $arguments += "-FailOnCi"
    }
    $result = Invoke-Native "powershell.exe" $arguments
    if ($result.Output) { Write-Host $result.Output }
    if ($result.ExitCode -ne 0) { throw "Push or CI failed." }
}

function Get-RepoTag {
    param([string]$Repo)
    $result = Invoke-Native "git" @("-C", (Join-Path $root $Repo), "rev-parse", "--short=7", "HEAD")
    if ($result.ExitCode -ne 0) { throw "Could not read the commit for $Repo." }
    $result.Output.Trim()
}

function Wait-ForEcrTags {
    param($Selection)
    if ($Selection.Services.Count -eq 0 -or $WhatIf) { return @{} }
    Write-Host "==> Phase 4: verify immutable images in ECR"
    $expected = @{}
    foreach ($service in $Selection.Services) {
        $expected[$service] = Get-RepoTag $serviceSources[$service]
        Write-Host "    ${service}: $($expected[$service])"
    }
    $deadline = (Get-Date).AddMinutes($CiTimeoutMinutes)
    while ($true) {
        $result = Invoke-Native "powershell.exe" @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $awsStatusScript, "-Json"
        )
        if ($result.ExitCode -ne 0) { throw "Could not read ECR status: $($result.Output)" }
        $json = [string]$result.Output
        $start = $json.IndexOf("[")
        if ($start -lt 0) { throw "ECR status did not return service data." }
        $rows = @(ConvertFrom-Json -InputObject $json.Substring($start))
        $ready = $true
        foreach ($service in $Selection.Services) {
            $row = @($rows | Where-Object { $_.Service -eq $service } | Select-Object -First 1)[0]
            $present = $false
            if ($row) {
                $present = [bool]$row.LocalInEcr -or [string]$row.EcrLatest -eq $expected[$service]
            }
            if (-not $present) { $ready = $false }
        }
        if ($ready) { return $expected }
        if ((Get-Date) -gt $deadline) {
            throw "Timed out waiting for the selected immutable images in ECR."
        }
        Write-Host "    images are still publishing; checking again in 20 seconds"
        Start-Sleep -Seconds 20
    }
}

function Deploy-SelectedServices {
    param($Selection, $Tags)
    if ($Selection.Services.Count -eq 0) { return }
    Write-Host "==> Phase 5: deploy AWS services sequentially"
    foreach ($service in $Selection.Services) {
        $tag = if ($WhatIf) { "<commit-after-push>" } else { $Tags[$service] }
        Write-Host "    ${service}: $tag"
        if ($WhatIf) { continue }
        $result = Invoke-Native "powershell.exe" @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $deployScript,
            "-Service", $service, "-Tag", $tag, "-Confirm"
        )
        if ($result.Output) { Write-Host $result.Output }
        if ($result.ExitCode -ne 0) { throw "AWS deployment failed for $service." }
    }
}

function Publish-SelectedApps {
    param($Selection)
    if ($Selection.Apps.Count -eq 0) { return }
    Write-Host "==> Phase 6: upload selected apps to Play ($Track)"
    if (-not $Confirm) { throw "Play upload requires its confirmation word." }
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $playScript,
        "-Action", "Upload",
        "-Apps", ($Selection.Apps -join ","),
        "-Track", $Track,
        "-Confirm", $Confirm
    )
    if ($WhatIf) { $arguments += "-DryRun" }
    $result = Invoke-Native "powershell.exe" $arguments
    if ($result.Output) { Write-Host $result.Output }
    if ($result.ExitCode -ne 0) { throw "Play upload failed." }
}

$selection = Assert-ReleaseSelection
Assert-ReleaseReady $selection
Write-Host ("==> Release plan: repos={0}; services={1}; apps={2}; track={3}" -f `
    ($selection.Repos -join ","),
    ($(if ($selection.Services.Count) { $selection.Services -join "," } else { "none" })),
    ($(if ($selection.Apps.Count) { $selection.Apps -join "," } else { "none" })),
    $Track)

Update-MobileVersions $selection
Commit-SelectedRepos $selection
Push-SelectedRepos $selection
$tags = Wait-ForEcrTags $selection
Deploy-SelectedServices $selection $tags
Publish-SelectedApps $selection
Write-Host "==> Release complete."

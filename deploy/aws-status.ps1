[CmdletBinding()]
param(
    [string]$Region = "ap-south-1",
    [string]$HostAddress = "35.154.59.116",
    [string]$User = "prabhix",
    [string]$KeyPath = "$env:USERPROFILE\.ssh\PrabhixTechnologies.pem",
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$images = @(
    [pscustomobject]@{ Service = "backend"; Repo = "prabhix/backend"; Source = "oneOps"; Pin = "BACKEND_TAG" }
    [pscustomobject]@{ Service = "web"; Repo = "prabhix/web"; Source = "oneOps"; Pin = "WEB_TAG" }
    [pscustomobject]@{ Service = "admin"; Repo = "prabhix/admin"; Source = "oneOps"; Pin = "ADMIN_TAG" }
    [pscustomobject]@{ Service = "marketing"; Repo = "prabhix/marketing"; Source = "Platform"; Pin = "MARKETING_TAG" }
    [pscustomobject]@{ Service = "identity"; Repo = "prabhix/identity"; Source = "Identity"; Pin = "IDENTITY_TAG" }
    [pscustomobject]@{ Service = "mailroom"; Repo = "prabhix/mailroom"; Source = "Mailroom"; Pin = "MAILROOM_TAG" }
    [pscustomobject]@{ Service = "mobistack-backend"; Repo = "prabhix/mobistack-backend"; Source = "MobiStack"; Pin = "MOBISTACK_BACKEND_TAG" }
    [pscustomobject]@{ Service = "mobistack-web"; Repo = "prabhix/mobistack-web"; Source = "MobiStack"; Pin = "MOBISTACK_WEB_TAG" }
    [pscustomobject]@{ Service = "app-store"; Repo = "prabhix/app-store"; Source = "Infra"; Pin = "APP_STORE_TAG" }
)

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory = $root)
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
    [pscustomobject]@{ ExitCode = $code; Output = ($lines | Out-String).TrimEnd() }
}

if (-not (Test-Path $KeyPath)) {
    throw "SSH key not found at $KeyPath."
}

$pinNames = ($images.Pin -join "|")
$remote = "awk -F= '/^($pinNames)=/{print `$1""=""`$2}' /opt/prabhix/deploy/.env.prod"
$remoteEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
$pinResult = Invoke-Native "ssh" @(
    "-i", $KeyPath, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
    "$User@$HostAddress", "echo $remoteEncoded | base64 -d | bash"
)
if ($pinResult.ExitCode -ne 0) {
    throw "Could not read production image pins: $($pinResult.Output)"
}

$pins = @{}
foreach ($line in @($pinResult.Output -split "`r?`n")) {
    if ($line -match "^([A-Z_]+)=(.+)$") {
        $pins[$Matches[1]] = $Matches[2].Trim()
    }
}

$rows = foreach ($image in $images) {
    $sourcePath = Join-Path $root $image.Source
    $localHead = "-"
    if (Test-Path (Join-Path $sourcePath ".git")) {
        $head = Invoke-Native "git" @("-C", $sourcePath, "rev-parse", "--short=7", "HEAD")
        if ($head.ExitCode -eq 0) { $localHead = $head.Output.Trim() }
    }

    $describe = Invoke-Native "aws" @(
        "ecr", "describe-images", "--region", $Region,
        "--repository-name", $image.Repo,
        "--image-ids", "imageTag=latest",
        "--output", "json"
    )
    $latestTag = "-"
    $pushedAt = $null
    $localBuilt = $false
    if ($describe.ExitCode -eq 0) {
        $payload = $describe.Output | ConvertFrom-Json
        $detail = @($payload.imageDetails) | Select-Object -First 1
        if ($detail) {
            $tags = @($detail.imageTags)
            $shaTags = @($tags | Where-Object { $_ -match "^[0-9a-f]{7,40}$" })
            if ($shaTags.Count -gt 0) {
                $latestTag = $shaTags | Sort-Object Length | Select-Object -First 1
            }
            $localBuilt = @($tags | Where-Object { $_ -eq $localHead -or $_.StartsWith($localHead) }).Count -gt 0
            $pushedAt = $detail.imagePushedAt
        }
    }

    $prodTag = if ($pins.ContainsKey($image.Pin)) { $pins[$image.Pin] } else { "-" }
    $deployment = if ($latestTag -eq "-") {
        "No latest image"
    } elseif ($prodTag -eq $latestTag) {
        "Current"
    } else {
        "Deploy available"
    }

    [pscustomobject]@{
        Service = $image.Service
        Local = $localHead
        LocalInEcr = $localBuilt
        EcrLatest = $latestTag
        Production = $prodTag
        Deployment = $deployment
        PushedAt = $pushedAt
        Repository = $image.Repo
    }
}

if ($Json) {
    $rows | ConvertTo-Json -Depth 4
} else {
    $rows |
        Format-Table Service, Local, LocalInEcr, EcrLatest, Production, Deployment, PushedAt -AutoSize |
        Out-String -Width 240 |
        Write-Host
}

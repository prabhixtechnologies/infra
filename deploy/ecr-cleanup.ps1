# Safely removes old application images while preserving rollback and every production pin.
# Preview is the default. Deletion requires -Apply -ConfirmWord DELETE.
[CmdletBinding()]
param(
    [ValidateRange(3, 100)][int]$KeepRecent = 10,
    [string]$Region = "ap-south-1",
    [string]$HostAddress = "35.154.59.116",
    [string]$User = "prabhix",
    [string]$KeyPath = "$env:USERPROFILE\.ssh\PrabhixTechnologies.pem",
    [switch]$Apply,
    [string]$ConfirmWord = ""
)

$ErrorActionPreference = "Stop"

$repositories = [ordered]@{
    "prabhix/backend" = "BACKEND_TAG"
    "prabhix/web" = "WEB_TAG"
    "prabhix/admin" = "ADMIN_TAG"
    "prabhix/marketing" = "MARKETING_TAG"
    "prabhix/identity" = "IDENTITY_TAG"
    "prabhix/mailroom" = "MAILROOM_TAG"
    "prabhix/mail" = $null
    "prabhix/mobistack-backend" = "MOBISTACK_BACKEND_TAG"
    "prabhix/mobistack-web" = "MOBISTACK_WEB_TAG"
    "prabhix/app-store" = "APP_STORE_TAG"
}

if ($Apply -and $ConfirmWord -cne "DELETE") {
    throw "Deletion requires -Apply -ConfirmWord DELETE."
}
if (-not (Test-Path $KeyPath)) {
    throw "SSH key not found at $KeyPath. Cleanup refuses to run without reading production pins."
}

$pinNames = @($repositories.Values | Where-Object { $_ }) -join "|"
$remote = "awk -F= '/^($pinNames)=/{print `$1""=""`$2}' /opt/prabhix/deploy/.env.prod"
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
$prior = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $pinLines = @(& ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=10 `
        -o ServerAliveInterval=10 -o ServerAliveCountMax=3 `
        "$User@$HostAddress" "echo $encoded | base64 -d | bash" 2>&1)
    $sshExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prior
}
if ($sshExit -ne 0) {
    throw "Could not read production pins; refusing cleanup: $($pinLines -join [Environment]::NewLine)"
}

$pins = @{}
foreach ($line in $pinLines) {
    if ("$line" -match "^([A-Z_]+)=(.+)$") {
        $pins[$Matches[1]] = $Matches[2].Trim()
    }
}

$candidates = [System.Collections.ArrayList]::new()
$kept = 0
$untaggedManagedByLifecycle = 0

foreach ($entry in $repositories.GetEnumerator()) {
    $repository = $entry.Key
    $productionTag = if ($entry.Value -and $pins.ContainsKey($entry.Value)) { $pins[$entry.Value] } else { $null }

    $json = & aws ecr describe-images --region $Region --repository-name $repository --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "$repository could not be read: $($json | Out-String)"
        continue
    }
    $allDetails = @(($json | Out-String | ConvertFrom-Json).imageDetails |
        Sort-Object { [DateTime]$_.imagePushedAt } -Descending)
    # Multi-architecture images have untagged child manifests referenced by the tagged manifest
    # list. Deleting those directly can break the tagged image. The existing seven-day lifecycle
    # rule is ECR-aware and owns untagged cleanup; this manual tool only reduces tagged releases.
    $details = @($allDetails | Where-Object {
        @($_.imageTags | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }).Count -gt 0
    })
    $untaggedManagedByLifecycle += $allDetails.Count - $details.Count

    for ($index = 0; $index -lt $details.Count; $index++) {
        $detail = $details[$index]
        $tags = @($detail.imageTags | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
        $reasons = [System.Collections.Generic.List[string]]::new()
        if ($index -lt $KeepRecent) { $reasons.Add("recent") }
        if ($tags -contains "latest") { $reasons.Add("latest") }
        if ($productionTag -and $tags -contains $productionTag) { $reasons.Add("production:$productionTag") }

        if ($reasons.Count -gt 0) {
            $kept++
            continue
        }
        [void]$candidates.Add([pscustomobject]@{
            Repository = $repository
            Digest = $detail.imageDigest
            Tags = if ($tags.Count) { $tags -join "," } else { "(untagged)" }
            PushedAt = $detail.imagePushedAt
        })
    }
}

Write-Host "ECR cleanup plan: keep the newest $KeepRecent image(s) per repository, plus latest and production pins."
Write-Host "Protected images: $kept"
Write-Host "Untagged manifests left to the existing 7-day lifecycle rule: $untaggedManagedByLifecycle"
Write-Host "Candidates: $($candidates.Count)"
if ($candidates.Count -gt 0) {
    $candidates | Format-Table Repository, Tags, PushedAt, Digest -AutoSize
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "Preview only. No image was deleted."
    exit 0
}

foreach ($candidate in $candidates) {
    Write-Host "Deleting $($candidate.Repository) $($candidate.Tags) $($candidate.Digest)"
    & aws ecr batch-delete-image --region $Region --repository-name $candidate.Repository `
        --image-ids "imageDigest=$($candidate.Digest)" --output json *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Deletion failed for $($candidate.Repository) $($candidate.Digest)."
    }
}

Write-Host "Deleted $($candidates.Count) old ECR image(s)."

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$orchestrator = Join-Path $PSScriptRoot "release-orchestrator.ps1"
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Throws {
    param([string]$Name, [scriptblock]$Action, [string]$Pattern)
    try {
        & $Action | Out-Null
        $failures.Add("$Name did not fail.")
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            $failures.Add("$Name failed with '$($_.Exception.Message)', expected '$Pattern'.")
        }
    }
}

Assert-Throws "unknown repository" {
    & $orchestrator -Repos "Unknown" -CommitMessage "test" -WhatIf
} "Unknown repository"

Assert-Throws "service without source" {
    & $orchestrator -Repos "Mobile" -Services "backend" -CommitMessage "test" -WhatIf
} "requires repository 'oneOps'"

Assert-Throws "app without Mobile" {
    & $orchestrator -Repos "MobiStack" -Apps "mobistack" -Versions "mobistack=1.3.18+29" -CommitMessage "test" -WhatIf
} "requires the Mobile repository"

$preview = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $orchestrator `
    -Repos "Mobile" -CommitMessage "preview release" -WhatIf 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $preview -notmatch "Release plan: repos=Mobile") {
    $failures.Add("Mobile preview did not build the release plan.")
}
if ($preview -match "git (commit|push)|workflow run") {
    $failures.Add("Preview executed a mutating Git or Play command.")
}

$multi = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $orchestrator `
    -Repos "MobiStack,Mailroom" -Services "mobistack-backend,mailroom" `
    -CommitMessage "preview release" -WhatIf 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $multi -notmatch "services=mobistack-backend,mailroom") {
    $failures.Add("Multiple-module preview did not preserve dependency service order.")
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" }
    exit 1
}
Write-Host "PASS: release selection, mapping, and preview checks"

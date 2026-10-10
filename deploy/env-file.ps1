# Reads and replaces /opt/prabhix/deploy/.env.prod through the production SSH key.
# Replacement copies the current file to a timestamped backup first. Nothing here restarts a container.

$script:ProductionEnvHost = "35.154.59.116"
$script:ProductionEnvUser = "prabhix"
$script:ProductionEnvKey = "$env:USERPROFILE\.ssh\PrabhixTechnologies.pem"
$script:ProductionEnvPath = "/opt/prabhix/deploy/.env.prod"
# deploy.sh defaults a missing ENV_SOURCE to file and a missing SECRETS_SOURCE to env.
# Only the image pins must be present, so an edit cannot drop the running release.
$script:RequiredEnvKeys = @(
    "TAG",
    "BACKEND_TAG", "WEB_TAG", "ADMIN_TAG", "MARKETING_TAG", "IDENTITY_TAG",
    "MAILROOM_TAG", "MOBISTACK_BACKEND_TAG", "MOBISTACK_WEB_TAG", "APP_STORE_TAG"
)

function Test-SecretEnvName {
    param([string]$Name)
    $Name -match '(?i)(PASSWORD|SECRET|TOKEN|CREDENTIAL|SIGNING_KEY|AUTH_TOKEN)'
}

function ConvertTo-EnvEntries {
    param([string]$Text)
    $entries = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in ($Text -replace "`r`n", "`n" -replace "`r", "`n").Split("`n")) {
        $lineNumber++
        if ($line -match '^\s*$' -or $line -match '^\s*#') {
            $entries.Add([pscustomobject]@{ Kind = "raw"; Text = $line; Line = $lineNumber })
            continue
        }
        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            throw "Line $lineNumber is not a comment, a blank line, or a KEY=value assignment."
        }
        $name = $Matches[1]
        $value = $Matches[2]
        $entries.Add([pscustomobject]@{
            Kind = "value"
            Key = $name
            Value = $value
            Secret = (Test-SecretEnvName $name) -or ($value -match 'BEGIN [A-Z ]*PRIVATE KEY')
            Line = $lineNumber
        })
    }
    $seen = @{}
    foreach ($entry in $entries) {
        if ($entry.Kind -ne "value") { continue }
        if ($seen.ContainsKey($entry.Key)) {
            throw "The environment file repeats $($entry.Key)."
        }
        $seen[$entry.Key] = $true
    }
    foreach ($required in $script:RequiredEnvKeys) {
        if (-not $seen.ContainsKey($required)) {
            throw "The environment file is missing required setting $required."
        }
    }
    return ,$entries
}

function ConvertFrom-EnvEntries {
    param($Entries)
    $text = (($Entries | ForEach-Object {
        if ($_.Kind -eq "raw") { $_.Text } else { "$($_.Key)=$($_.Value)" }
    }) -join "`n").TrimEnd("`n") + "`n"
    [void](ConvertTo-EnvEntries $text)
    return $text
}

function Invoke-ProductionSsh {
    param([string]$ScriptText)
    if (-not (Test-Path $script:ProductionEnvKey)) {
        throw "SSH key not found at $($script:ProductionEnvKey)."
    }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "ssh"
    $startInfo.Arguments = "-i `"$($script:ProductionEnvKey)`" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 $($script:ProductionEnvUser)@$($script:ProductionEnvHost) bash -s"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    # PowerShell here-strings on Windows contain CR. Bash treats that CR as part of "pipefail".
    $remoteScript = (($ScriptText -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n")) + "`n"
    $process.StandardInput.Write($remoteScript)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(60000)) {
        $process.Kill()
        throw "The production SSH command timed out."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        $reason = if ($stderr.Trim()) { $stderr.Trim() } else { "SSH command failed." }
        throw $reason
    }
    return $stdout
}

function Get-ProductionEnvFile {
    $command = @'
set -euo pipefail
test -f '__PATH__'
base64 -w 0 '__PATH__'
'@
    $command = $command.Replace("__PATH__", $script:ProductionEnvPath)
    $encoded = Invoke-ProductionSsh $command
    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded.Trim()))
    return ,(ConvertTo-EnvEntries $text)
}

function Set-ProductionEnvFile {
    param([Parameter(Mandatory = $true)][string]$Content)
    $normalized = ConvertFrom-EnvEntries (ConvertTo-EnvEntries $Content)
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    $requiredTests = ($script:RequiredEnvKeys | ForEach-Object {
        "grep -Eq '^$_=.+' `"`$tmp`""
    }) -join "`n"
    $command = @'
set -euo pipefail
cd /opt/prabhix
umask 077
src='__PATH__'
test -f "$src"
backup="${src}.pre-edit-$(date -u +%Y%m%dT%H%M%SZ)"
tmp=$(mktemp)
printf '%s' '__PAYLOAD__' | base64 -d > "$tmp"
test -s "$tmp"
__REQUIRED__
cp -p "$src" "$backup"
chmod --reference="$src" "$tmp" 2>/dev/null || chmod 600 "$tmp"
mv "$tmp" "$src"
printf 'backup=%s\n' "$backup"
'@
    $command = $command.Replace("__PATH__", $script:ProductionEnvPath).Replace("__PAYLOAD__", $payload).Replace("__REQUIRED__", $requiredTests)
    $result = Invoke-ProductionSsh $command
    if ($result -notmatch '(?m)^backup=(.+)$') {
        throw "The environment file was not confirmed by the server."
    }
    return $Matches[1].Trim()
}

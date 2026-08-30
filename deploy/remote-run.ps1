# Runs a local bash script on the production box.
#
# For the ad-hoc half of operations: reading state, checking why something is down, running a one-off
# query. deploy-remote.ps1 is for deploys and knows the deploy sequence; this knows nothing and just
# carries a script over.
#
#   .\deploy\remote-run.ps1 -ScriptPath .\some-check.sh
#
# The script is base64-encoded before it crosses the wire, which is not for secrecy. PowerShell
# rewrites quoting in arguments it passes to native commands, so a heredoc or a nested quote in the
# script would arrive mangled; base64 has no characters PowerShell wants to touch. deploy-remote.ps1
# does the same thing for the same reason.
#
# Output is streamed line by line rather than collected, so a script that hangs still shows how far
# it got. stderr is folded into stdout because these scripts are diagnostics, where the error text is
# usually the answer.
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string]$HostAddress = "35.154.59.116",
    [string]$User = "prabhix",
    [string]$KeyPath = "$env:USERPROFILE\.ssh\PrabhixTechnologies.pem"
)

if (-not (Test-Path $ScriptPath)) { throw "No script at $ScriptPath" }
if (-not (Test-Path $KeyPath)) { throw "No SSH key at $KeyPath" }

# Written on Windows, run by bash: CRLF would make bash read `\r` as part of the last token on every
# line, so `fi` becomes `fi\r` and the script dies somewhere unrelated to the real mistake.
$lf = (Get-Content -Raw $ScriptPath).Replace("`r`n", "`n")
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))

# ssh writes progress to stderr, which PowerShell turns into a terminating error under a strict
# ErrorActionPreference even when the command succeeds.
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

# Read-only snapshot of the production server for the dashboard monitor.
# Reports EC2 state, recent CPU, load, memory, disk, and container health. Never prints the env file.
[CmdletBinding()]
param(
    [string]$Region = "ap-south-1",
    [string]$InstanceId = "i-05496f940af0517ae",
    [string]$HostAddress = "35.154.59.116",
    [string]$User = "prabhix",
    [string]$KeyPath = "$env:USERPROFILE\.ssh\PrabhixTechnologies.pem"
)

$ErrorActionPreference = "Stop"

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments)
    $prior = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& $FilePath @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prior
    }
    [pscustomobject]@{ ExitCode = $code; Output = ($lines | Out-String).Trim() }
}

$snapshot = [ordered]@{
    CheckedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    InstanceId = $InstanceId
    State = "-"
    Type = "-"
    Zone = "-"
    PublicIp = "-"
    LaunchedAt = "-"
    SystemCheck = "-"
    InstanceCheck = "-"
    CpuPercent = "-"
    Uptime = "-"
    Load = "-"
    Cpus = "-"
    Memory = "-"
    Disk = "-"
    Containers = @()
    Errors = @()
}

$instance = Invoke-Native "aws" @(
    "ec2", "describe-instances", "--region", $Region, "--instance-ids", $InstanceId,
    "--query", "Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,Ip:PublicIpAddress,Zone:Placement.AvailabilityZone,Launch:LaunchTime}",
    "--output", "json"
)
if ($instance.ExitCode -eq 0) {
    $info = $instance.Output | ConvertFrom-Json
    $snapshot.State = [string]$info.State
    $snapshot.Type = [string]$info.Type
    $snapshot.Zone = [string]$info.Zone
    $snapshot.PublicIp = [string]$info.Ip
    $snapshot.LaunchedAt = [string]$info.Launch
} else {
    $snapshot.Errors += "EC2: $($instance.Output)"
}

$checks = Invoke-Native "aws" @(
    "ec2", "describe-instance-status", "--region", $Region, "--instance-ids", $InstanceId,
    "--query", "InstanceStatuses[0].{System:SystemStatus.Status,Instance:InstanceStatus.Status}",
    "--output", "json"
)
if ($checks.ExitCode -eq 0 -and $checks.Output -and $checks.Output -ne "null") {
    $status = $checks.Output | ConvertFrom-Json
    $snapshot.SystemCheck = [string]$status.System
    $snapshot.InstanceCheck = [string]$status.Instance
}

$end = (Get-Date).ToUniversalTime()
$cpu = Invoke-Native "aws" @(
    "cloudwatch", "get-metric-statistics", "--region", $Region,
    "--namespace", "AWS/EC2", "--metric-name", "CPUUtilization",
    "--dimensions", "Name=InstanceId,Value=$InstanceId",
    "--start-time", $end.AddMinutes(-15).ToString("yyyy-MM-ddTHH:mm:ssZ"),
    "--end-time", $end.ToString("yyyy-MM-ddTHH:mm:ssZ"),
    "--period", "300", "--statistics", "Average", "--output", "json"
)
if ($cpu.ExitCode -eq 0) {
    $points = @(($cpu.Output | ConvertFrom-Json).Datapoints | Sort-Object Timestamp)
    if ($points.Count -gt 0) {
        $snapshot.CpuPercent = "{0:N1}" -f [double]$points[-1].Average
    }
}

if (Test-Path $KeyPath) {
    $remote = @'
echo "uptime=$(uptime -p)"
read l1 l5 l15 _ < /proc/loadavg
echo "load=$l1 $l5 $l15"
echo "cpus=$(nproc)"
free -m | awk '/^Mem:/{print "memory="$3" MB used of "$2" MB"}'
df -h / | awk 'NR==2{print "disk="$3" used of "$2" ("$5")"}'
docker ps -a --format 'container={{.Names}}|{{.Image}}|{{.Status}}'
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote.Replace("`r`n", "`n")))
    $ssh = Invoke-Native "ssh" @(
        "-i", $KeyPath, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
        "$User@$HostAddress", "echo $encoded | base64 -d | bash"
    )
    if ($ssh.ExitCode -eq 0) {
        $containers = @()
        foreach ($line in @($ssh.Output -split "`r?`n")) {
            if ($line -match '^uptime=(.*)$') { $snapshot.Uptime = $Matches[1] }
            elseif ($line -match '^load=(.*)$') { $snapshot.Load = $Matches[1] }
            elseif ($line -match '^cpus=(.*)$') { $snapshot.Cpus = $Matches[1] }
            elseif ($line -match '^memory=(.*)$') { $snapshot.Memory = $Matches[1] }
            elseif ($line -match '^disk=(.*)$') { $snapshot.Disk = $Matches[1] }
            elseif ($line -match '^container=([^|]*)\|([^|]*)\|(.*)$') {
                $name = $Matches[1]
                $image = $Matches[2] -replace '^.*/', ''
                $state = $Matches[3]
                $health = if ($state -match '\(unhealthy\)') { "Unhealthy" }
                    elseif ($state -match '\(health: starting\)') { "Starting" }
                    elseif ($state -match '\(healthy\)') { "Healthy" }
                    elseif ($state -match '^Up') { "Running" }
                    elseif ($state -match '^Restarting') { "Restarting" }
                    else { "Stopped" }
                $containers += [pscustomobject]@{
                    Name = $name; Image = $image; Health = $health; Status = $state
                }
            }
        }
        $snapshot.Containers = @($containers | Sort-Object Name)
    } else {
        $snapshot.Errors += "SSH: $($ssh.Output)"
    }
} else {
    $snapshot.Errors += "SSH key not found at $KeyPath."
}

[pscustomobject]$snapshot | ConvertTo-Json -Depth 4

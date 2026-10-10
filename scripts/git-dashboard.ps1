[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = "Stop"

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "Git Dashboard requires Windows."
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

if ([Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    [System.Windows.Forms.MessageBox]::Show(
        "Start this dashboard with Infra\open-git-dashboard.cmd so it runs in STA mode.",
        "Git Dashboard",
        "OK",
        "Error"
    ) | Out-Null
    exit 1
}

if (-not $Root) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$repoNames = @(
    "web-kit",
    "Platform",
    "oneOps",
    "MobiStack",
    "Mailroom",
    "Identity",
    "Infra",
    "Mobile"
)
$pushScript = Join-Path $Root "Infra\scripts\push-waves.ps1"

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = $Root
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

function Invoke-Git {
    param([string]$RepoPath, [string[]]$Arguments)
    Invoke-Native -FilePath "git" -Arguments (@("-C", $RepoPath) + $Arguments)
}

function Get-RepoState {
    param([string]$Name)

    $path = Join-Path $Root $Name
    if (-not (Test-Path (Join-Path $path ".git"))) {
        return [pscustomobject]@{
            Name = $Name; Path = $path; Branch = "-"; Changes = 0
            Ahead = 0; Behind = 0; Upstream = "-"; Status = "Missing"; Details = ""
        }
    }

    $branchResult = Invoke-Git $path @("branch", "--show-current")
    $branch = if ($branchResult.Output) { $branchResult.Output } else { "(detached)" }
    $statusResult = Invoke-Git $path @("status", "--porcelain=v1")
    $changeLines = @($statusResult.Lines | Where-Object { "$_".Trim().Length -gt 0 })
    $upstreamResult = Invoke-Git $path @("rev-parse", "--abbrev-ref", "@{u}")
    $upstream = if ($upstreamResult.ExitCode -eq 0) { $upstreamResult.Output.Trim() } else { "-" }
    $ahead = 0
    $behind = 0

    if ($upstream -ne "-") {
        $counts = Invoke-Git $path @("rev-list", "--left-right", "--count", "HEAD...@{u}")
        if ($counts.ExitCode -eq 0 -and $counts.Output -match "^\s*(\d+)\s+(\d+)\s*$") {
            $ahead = [int]$Matches[1]
            $behind = [int]$Matches[2]
        }
    }

    [pscustomobject]@{
        Name = $Name
        Path = $path
        Branch = $branch
        Changes = $changeLines.Count
        Ahead = $ahead
        Behind = $behind
        Upstream = $upstream
        Status = if ($changeLines.Count) { "$($changeLines.Count) changed" } else { "Clean" }
        Details = ($changeLines | Out-String).TrimEnd()
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Prabhix Git Dashboard"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object Drawing.Size(1080, 760)
$form.MinimumSize = New-Object Drawing.Size(900, 650)
$form.Font = New-Object Drawing.Font("Segoe UI", 9)

$toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
$toolbar.Dock = "Top"
$toolbar.Height = 44
$toolbar.Padding = New-Object Windows.Forms.Padding(8, 7, 8, 4)
$toolbar.WrapContents = $false
$form.Controls.Add($toolbar)

function New-Button {
    param([string]$Text, [int]$Width = 105)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = 28
    $button
}

$refreshButton = New-Button "Refresh"
$fetchButton = New-Button "Fetch all"
$ciButton = New-Button "Check CI"
$diffButton = New-Button "View diff"
$pushButton = New-Button "Push pending" 120
$toolbar.Controls.AddRange(@($refreshButton, $fetchButton, $ciButton, $diffButton, $pushButton))

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = "Fill"
$split.Orientation = "Horizontal"
$split.SplitterDistance = 330
$form.Controls.Add($split)
$split.BringToFront()

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.AutoGenerateColumns = $false
$grid.MultiSelect = $false
$grid.SelectionMode = "FullRowSelect"
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [Drawing.Color]::White

$pickColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$pickColumn.Name = "Pick"
$pickColumn.HeaderText = ""
$pickColumn.Width = 35
$grid.Columns.Add($pickColumn) | Out-Null

foreach ($definition in @(
    @("Repo", "Repository", 125),
    @("Branch", "Branch", 135),
    @("Status", "Working tree", 110),
    @("Ahead", "Ahead", 60),
    @("Behind", "Behind", 60),
    @("Upstream", "Upstream", 170),
    @("CI", "Latest CI", 120)
)) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $definition[0]
    $column.HeaderText = $definition[1]
    $column.Width = $definition[2]
    $column.ReadOnly = $true
    $grid.Columns.Add($column) | Out-Null
}
$split.Panel1.Controls.Add($grid)

$bottom = New-Object System.Windows.Forms.TableLayoutPanel
$bottom.Dock = "Fill"
$bottom.ColumnCount = 1
$bottom.RowCount = 3
$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle("Percent", 62)))
$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 42)))
$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle("Percent", 38)))
$split.Panel2.Controls.Add($bottom)

$details = New-Object System.Windows.Forms.TextBox
$details.Dock = "Fill"
$details.Multiline = $true
$details.ReadOnly = $true
$details.ScrollBars = "Both"
$details.WordWrap = $false
$details.Font = New-Object Drawing.Font("Consolas", 9)
$bottom.Controls.Add($details, 0, 0)

$commitPanel = New-Object System.Windows.Forms.TableLayoutPanel
$commitPanel.Dock = "Fill"
$commitPanel.ColumnCount = 3
$commitPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Absolute", 110)))
$commitPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Percent", 100)))
$commitPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Absolute", 150)))
$commitLabel = New-Object System.Windows.Forms.Label
$commitLabel.Text = "Commit message:"
$commitLabel.Dock = "Fill"
$commitLabel.TextAlign = "MiddleLeft"
$commitMessage = New-Object System.Windows.Forms.TextBox
$commitMessage.Dock = "Fill"
$commitButton = New-Button "Commit selected" 140
$commitButton.Dock = "Fill"
$commitPanel.Controls.Add($commitLabel, 0, 0)
$commitPanel.Controls.Add($commitMessage, 1, 0)
$commitPanel.Controls.Add($commitButton, 2, 0)
$bottom.Controls.Add($commitPanel, 0, 1)

$log = New-Object System.Windows.Forms.TextBox
$log.Dock = "Fill"
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = "Vertical"
$log.Font = New-Object Drawing.Font("Consolas", 9)
$bottom.Controls.Add($log, 0, 2)

function Add-Log {
    param([string]$Message)
    $log.AppendText("[$(Get-Date -Format HH:mm:ss)] $Message`r`n")
}

function Set-Busy {
    param([bool]$Busy)
    $form.UseWaitCursor = $Busy
    foreach ($control in @($refreshButton, $fetchButton, $ciButton, $diffButton, $pushButton, $commitButton)) {
        $control.Enabled = -not $Busy
    }
    [Windows.Forms.Application]::DoEvents()
}

function Refresh-Grid {
    Set-Busy $true
    try {
        $grid.Rows.Clear()
        foreach ($name in $repoNames) {
            $state = Get-RepoState $name
            $index = $grid.Rows.Add($false, $state.Name, $state.Branch, $state.Status,
                $state.Ahead, $state.Behind, $state.Upstream, "")
            $row = $grid.Rows[$index]
            $row.Tag = $state
            if ($state.Behind -gt 0) {
                $row.DefaultCellStyle.BackColor = [Drawing.Color]::MistyRose
            } elseif ($state.Changes -gt 0) {
                $row.DefaultCellStyle.BackColor = [Drawing.Color]::LightGoldenrodYellow
            } elseif ($state.Ahead -gt 0) {
                $row.DefaultCellStyle.BackColor = [Drawing.Color]::Honeydew
            }
        }
        if ($grid.Rows.Count -gt 0) {
            $grid.Rows[0].Selected = $true
        }
        Add-Log "Repository status refreshed."
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Refresh failed", "OK", "Error") | Out-Null
    } finally {
        Set-Busy $false
    }
}

function Get-PickedRows {
    @($grid.Rows | Where-Object { $_.Cells["Pick"].Value -eq $true })
}

$grid.Add_SelectionChanged({
    if ($grid.SelectedRows.Count -eq 0) { return }
    $state = $grid.SelectedRows[0].Tag
    if (-not $state) { return }
    $stat = Invoke-Git $state.Path @("diff", "--stat", "HEAD")
    $details.Text = @(
        "$($state.Name)  [$($state.Branch)]"
        "Path: $($state.Path)"
        "Upstream: $($state.Upstream)  Ahead: $($state.Ahead)  Behind: $($state.Behind)"
        ""
        $state.Details
        ""
        $stat.Output
    ) -join "`r`n"
})

$refreshButton.Add_Click({ Refresh-Grid })

$diffButton.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) { return }
    $state = $grid.SelectedRows[0].Tag
    $diff = Invoke-Git $state.Path @("diff", "--", ".")
    $details.Text = if ($diff.Output) { $diff.Output } else { "No unstaged diff. Check staged or untracked files in the status above." }
})

$fetchButton.Add_Click({
    if ([Windows.Forms.MessageBox]::Show(
        "Fetch remotes for all repositories? This does not merge or change working files.",
        "Fetch all", "YesNo", "Question"
    ) -ne "Yes") { return }
    Set-Busy $true
    try {
        foreach ($name in $repoNames) {
            $path = Join-Path $Root $name
            if (-not (Test-Path (Join-Path $path ".git"))) { continue }
            Add-Log "Fetching $name..."
            $result = Invoke-Git $path @("fetch", "--prune")
            if ($result.ExitCode -ne 0) { Add-Log "$name fetch failed: $($result.Output)" }
        }
        Refresh-Grid
    } finally {
        Set-Busy $false
    }
})

$ciButton.Add_Click({
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        [Windows.Forms.MessageBox]::Show("GitHub CLI (gh) is not installed.", "Check CI", "OK", "Warning") | Out-Null
        return
    }
    Set-Busy $true
    try {
        foreach ($row in $grid.Rows) {
            $state = $row.Tag
            if (-not $state -or $state.Status -eq "Missing") { continue }
            $head = (Invoke-Git $state.Path @("rev-parse", "HEAD")).Output.Trim()
            $result = Invoke-Native "gh" @("run", "list", "--limit", "10",
                "--json", "status,conclusion,headSha,event") $state.Path
            $label = "Unavailable"
            if ($result.ExitCode -eq 0) {
                try {
                    $runs = @($result.Output | ConvertFrom-Json)
                    $run = $runs | Where-Object { $_.headSha -eq $head -and $_.event -in @("push", "pull_request") } |
                        Select-Object -First 1
                    if ($run) {
                        $label = if ($run.status -eq "completed") { $run.conclusion } else { $run.status }
                    } else {
                        $label = "No run"
                    }
                } catch {
                    $label = "Parse error"
                }
            }
            $row.Cells["CI"].Value = $label
        }
        Add-Log "CI status refreshed."
    } finally {
        Set-Busy $false
    }
})

$commitButton.Add_Click({
    $picked = @(Get-PickedRows | Where-Object { $_.Tag.Changes -gt 0 })
    $message = $commitMessage.Text.Trim()
    if ($picked.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show("Select at least one changed repository.", "Commit", "OK", "Information") | Out-Null
        return
    }
    if (-not $message) {
        [Windows.Forms.MessageBox]::Show("Enter a commit message.", "Commit", "OK", "Information") | Out-Null
        return
    }

    $sensitive = @()
    foreach ($row in $picked) {
        foreach ($line in @($row.Tag.Details -split "`r?`n")) {
            $path = if ($line.Length -gt 3) { $line.Substring(3).Trim() } else { "" }
            if ($path -match "(^|/)(\.env(\..*)?|key\.properties|[^/]*\.(jks|pem|p12|pfx)|[^/]*credentials[^/]*)$") {
                $sensitive += "$($row.Tag.Name): $path"
            }
        }
    }
    if ($sensitive.Count -gt 0) {
        [Windows.Forms.MessageBox]::Show(
            "Commit blocked because these files may contain secrets:`r`n`r`n$($sensitive -join "`r`n")",
            "Sensitive file detected", "OK", "Error"
        ) | Out-Null
        return
    }

    $summary = ($picked | ForEach-Object { "$($_.Tag.Name) ($($_.Tag.Changes) changed)" }) -join "`r`n"
    if ([Windows.Forms.MessageBox]::Show(
        "Stage every change and commit in these repositories?`r`n`r`n$summary`r`n`r`nMessage: $message",
        "Confirm commit", "YesNo", "Warning"
    ) -ne "Yes") { return }

    Set-Busy $true
    try {
        foreach ($row in $picked) {
            $state = $row.Tag
            Add-Log "Staging $($state.Name)..."
            $add = Invoke-Git $state.Path @("add", "-A")
            if ($add.ExitCode -ne 0) {
                Add-Log "$($state.Name) staging failed: $($add.Output)"
                continue
            }
            $commit = Invoke-Git $state.Path @("commit", "-m", $message)
            if ($commit.ExitCode -eq 0) {
                Add-Log "$($state.Name) committed."
            } else {
                Add-Log "$($state.Name) commit failed: $($commit.Output)"
            }
        }
        $commitMessage.Clear()
        Refresh-Grid
    } finally {
        Set-Busy $false
    }
})

$pushButton.Add_Click({
    if (-not (Test-Path $pushScript)) {
        [Windows.Forms.MessageBox]::Show("Push script not found: $pushScript", "Push", "OK", "Error") | Out-Null
        return
    }
    $preview = Invoke-Native "powershell.exe" @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $pushScript, "-WhatIf"
    )
    if ($preview.ExitCode -ne 0) {
        [Windows.Forms.MessageBox]::Show($preview.Output, "Push preview failed", "OK", "Error") | Out-Null
        return
    }
    if ($preview.Output -match "Nothing to push") {
        [Windows.Forms.MessageBox]::Show("No repository is ahead of its remote.", "Push", "OK", "Information") | Out-Null
        return
    }
    if ([Windows.Forms.MessageBox]::Show(
        "$($preview.Output)`r`n`r`nPush these commits in dependency waves and wait for CI?",
        "Confirm wave push", "YesNo", "Warning"
    ) -ne "Yes") { return }

    Start-Process "powershell.exe" -ArgumentList @(
        "-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$pushScript`""
    )
    Add-Log "Wave push opened in a separate console. The dashboard itself did not bypass the wave script."
})

$form.Add_Shown({ Refresh-Grid })
[void]$form.ShowDialog()

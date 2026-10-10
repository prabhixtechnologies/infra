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
Add-Type -AssemblyName Microsoft.VisualBasic

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
$awsStatusScript = Join-Path $Root "Infra\deploy\aws-status.ps1"
$deployScript = Join-Path $Root "Infra\deploy\deploy-pinned.ps1"
$cleanupScript = Join-Path $Root "Infra\deploy\ecr-cleanup.ps1"
$envFileScript = Join-Path $Root "Infra\deploy\env-file.ps1"
$serverStatusScript = Join-Path $Root "Infra\deploy\server-status.ps1"
. $envFileScript

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

$theme = @{
    Canvas = [Drawing.ColorTranslator]::FromHtml("#F4F7FB")
    Surface = [Drawing.Color]::White
    Navy = [Drawing.ColorTranslator]::FromHtml("#101828")
    Muted = [Drawing.ColorTranslator]::FromHtml("#667085")
    Border = [Drawing.ColorTranslator]::FromHtml("#E4E7EC")
    Primary = [Drawing.ColorTranslator]::FromHtml("#2563EB")
    PrimaryHover = [Drawing.ColorTranslator]::FromHtml("#1D4ED8")
    Success = [Drawing.ColorTranslator]::FromHtml("#067647")
    SuccessSoft = [Drawing.ColorTranslator]::FromHtml("#ECFDF3")
    Warning = [Drawing.ColorTranslator]::FromHtml("#B54708")
    WarningSoft = [Drawing.ColorTranslator]::FromHtml("#FFFAEB")
    Danger = [Drawing.ColorTranslator]::FromHtml("#B42318")
    DangerSoft = [Drawing.ColorTranslator]::FromHtml("#FEF3F2")
    Purple = [Drawing.ColorTranslator]::FromHtml("#6941C6")
    PurpleSoft = [Drawing.ColorTranslator]::FromHtml("#F4F3FF")
    Code = [Drawing.ColorTranslator]::FromHtml("#111827")
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Prabhix Workspace"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object Drawing.Size(1280, 860)
$form.MinimumSize = New-Object Drawing.Size(1040, 720)
$form.Font = New-Object Drawing.Font("Segoe UI", 9.5)
$form.BackColor = $theme.Canvas
$form.ForeColor = $theme.Navy

$shell = New-Object System.Windows.Forms.TableLayoutPanel
$shell.Dock = "Fill"
$shell.ColumnCount = 1
$shell.RowCount = 3
$shell.Margin = New-Object Windows.Forms.Padding(0)
$shell.Padding = New-Object Windows.Forms.Padding(0)
$shell.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 82)))
$shell.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 150)))
$shell.RowStyles.Add((New-Object Windows.Forms.RowStyle("Percent", 100)))
$form.Controls.Add($shell)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Fill"
$header.BackColor = $theme.Navy
$header.Padding = New-Object Windows.Forms.Padding(24, 14, 24, 12)
$shell.Controls.Add($header, 0, 0)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Prabhix Workspace"
$title.Font = New-Object Drawing.Font("Segoe UI Semibold", 18)
$title.ForeColor = [Drawing.Color]::White
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(22, 12)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Source control, delivery and production operations in one safe workspace"
$subtitle.Font = New-Object Drawing.Font("Segoe UI", 9.5)
$subtitle.ForeColor = [Drawing.ColorTranslator]::FromHtml("#98A2B3")
$subtitle.AutoSize = $true
$subtitle.Location = New-Object Drawing.Point(25, 48)
$header.Controls.Add($subtitle)

$activityStatus = New-Object System.Windows.Forms.Label
$activityStatus.Text = "READY"
$activityStatus.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
$activityStatus.ForeColor = [Drawing.ColorTranslator]::FromHtml("#6CE9A6")
$activityStatus.BackColor = [Drawing.ColorTranslator]::FromHtml("#17382B")
$activityStatus.AutoSize = $false
$activityStatus.Size = New-Object Drawing.Size(112, 30)
$activityStatus.TextAlign = "MiddleCenter"
$activityStatus.Anchor = "Top,Right"
$activityStatus.Location = New-Object Drawing.Point(($form.ClientSize.Width - 142), 25)
$header.Controls.Add($activityStatus)
$header.Add_Resize({
    $activityStatus.Left = [Math]::Max(20, $header.ClientSize.Width - $activityStatus.Width - 24)
})

$actions = New-Object System.Windows.Forms.TableLayoutPanel
$actions.Dock = "Fill"
$actions.BackColor = $theme.Surface
$actions.Padding = New-Object Windows.Forms.Padding(18, 8, 18, 8)
$actions.ColumnCount = 2
$actions.RowCount = 1
$actions.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Percent", 56)))
$actions.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Percent", 44)))
$shell.Controls.Add($actions, 0, 1)

function New-ActionGroup {
    param([string]$Title)
    $group = New-Object System.Windows.Forms.TableLayoutPanel
    $group.Dock = "Fill"
    $group.RowCount = 2
    $group.ColumnCount = 1
    $group.Margin = New-Object Windows.Forms.Padding(6, 0, 6, 0)
    $group.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 25)))
    $group.RowStyles.Add((New-Object Windows.Forms.RowStyle("Percent", 100)))
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Title.ToUpperInvariant()
    $label.Dock = "Fill"
    $label.Font = New-Object Drawing.Font("Segoe UI Semibold", 8)
    $label.ForeColor = $theme.Muted
    $label.TextAlign = "MiddleLeft"
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = "Fill"
    $flow.WrapContents = $true
    $flow.Margin = New-Object Windows.Forms.Padding(0)
    $flow.Padding = New-Object Windows.Forms.Padding(0, 2, 0, 0)
    $group.Controls.Add($label, 0, 0)
    $group.Controls.Add($flow, 0, 1)
    [pscustomobject]@{ Container = $group; Flow = $flow }
}

function New-Button {
    param(
        [string]$Text,
        [int]$Width = 105,
        [Drawing.Color]$BackColor = $theme.Surface,
        [Drawing.Color]$ForeColor = $theme.Navy
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = 38
    $button.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 6)
    $button.FlatStyle = "Flat"
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = if ($BackColor -eq $theme.Surface) { $theme.Border } else { $BackColor }
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    $button.Add_MouseEnter({
        if ($this.Enabled) {
            $color = $this.BackColor
            $this.Tag = $color
            $this.BackColor = [Drawing.Color]::FromArgb(
                $color.A,
                [Math]::Max(0, $color.R - 18),
                [Math]::Max(0, $color.G - 18),
                [Math]::Max(0, $color.B - 18)
            )
        }
    })
    $button.Add_MouseLeave({
        if ($this.Tag -is [Drawing.Color]) { $this.BackColor = $this.Tag }
    })
    $button
}

function Show-TextPrompt {
    param(
        [string]$Message,
        [string]$Title,
        [string]$Default = ""
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.ClientSize = New-Object Drawing.Size(560, 205)
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.BackColor = $theme.Canvas
    $dialog.Font = $form.Font

    $promptHeader = New-Object System.Windows.Forms.Panel
    $promptHeader.Dock = "Top"
    $promptHeader.Height = 50
    $promptHeader.BackColor = $theme.Navy
    $promptTitle = New-Object System.Windows.Forms.Label
    $promptTitle.Text = $Title
    $promptTitle.ForeColor = [Drawing.Color]::White
    $promptTitle.Font = New-Object Drawing.Font("Segoe UI Semibold", 12)
    $promptTitle.AutoSize = $true
    $promptTitle.Location = New-Object Drawing.Point(18, 14)
    $promptHeader.Controls.Add($promptTitle)
    $dialog.Controls.Add($promptHeader)

    $promptLabel = New-Object System.Windows.Forms.Label
    $promptLabel.Text = $Message
    $promptLabel.ForeColor = $theme.Muted
    $promptLabel.Location = New-Object Drawing.Point(20, 66)
    $promptLabel.Size = New-Object Drawing.Size(520, 50)
    $dialog.Controls.Add($promptLabel)

    $answerBox = New-Object System.Windows.Forms.TextBox
    $answerBox.Text = $Default
    $answerBox.Location = New-Object Drawing.Point(22, 119)
    $answerBox.Size = New-Object Drawing.Size(516, 28)
    $answerBox.Font = New-Object Drawing.Font("Segoe UI", 10)
    $dialog.Controls.Add($answerBox)

    $ok = New-Button "Continue" 100 $theme.Primary ([Drawing.Color]::White)
    $ok.Location = New-Object Drawing.Point(438, 162)
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel = New-Button "Cancel" 90
    $cancel.Location = New-Object Drawing.Point(338, 162)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($ok)
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    $dialog.Add_Shown({ $answerBox.Select(); $answerBox.SelectAll() }.GetNewClosure())

    $answer = ""
    if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        $answer = [string]$answerBox.Text
    }
    $dialog.Dispose()
    return $answer
}

function Confirm-DashboardAction {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Details,
        [string]$ActionText
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.ClientSize = New-Object Drawing.Size(560, 340)
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.BackColor = $theme.Canvas
    $dialog.Font = $form.Font

    $promptHeader = New-Object System.Windows.Forms.Panel
    $promptHeader.Dock = "Top"
    $promptHeader.Height = 50
    $promptHeader.BackColor = $theme.Navy
    $promptTitle = New-Object System.Windows.Forms.Label
    $promptTitle.Text = $Title
    $promptTitle.ForeColor = [Drawing.Color]::White
    $promptTitle.Font = New-Object Drawing.Font("Segoe UI Semibold", 12)
    $promptTitle.AutoSize = $true
    $promptTitle.Location = New-Object Drawing.Point(18, 14)
    $promptHeader.Controls.Add($promptTitle)
    $dialog.Controls.Add($promptHeader)

    $promptLabel = New-Object System.Windows.Forms.Label
    $promptLabel.Text = $Message
    $promptLabel.ForeColor = $theme.Muted
    $promptLabel.Location = New-Object Drawing.Point(20, 64)
    $promptLabel.Size = New-Object Drawing.Size(520, 36)
    $dialog.Controls.Add($promptLabel)

    $detailBox = New-Object System.Windows.Forms.TextBox
    $detailBox.Text = $Details
    $detailBox.Multiline = $true
    $detailBox.ReadOnly = $true
    $detailBox.ScrollBars = "Vertical"
    $detailBox.Location = New-Object Drawing.Point(20, 106)
    $detailBox.Size = New-Object Drawing.Size(520, 150)
    $detailBox.Font = New-Object Drawing.Font("Cascadia Mono", 10)
    $detailBox.BackColor = $theme.Surface
    $dialog.Controls.Add($detailBox)

    $ok = New-Button $ActionText 170 $theme.Purple ([Drawing.Color]::White)
    $ok.Location = New-Object Drawing.Point(370, 278)
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel = New-Button "Cancel" 90
    $cancel.Location = New-Object Drawing.Point(270, 278)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($ok)
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel

    $confirmed = $dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK
    $dialog.Dispose()
    return $confirmed
}

function Connect-SelectAll {
    param(
        [System.Windows.Forms.CheckBox]$CheckBox,
        [System.Windows.Forms.DataGridView]$Grid,
        [string]$Column
    )
    $state = [pscustomobject]@{ Ignore = $false }
    $CheckBox.Add_CheckedChanged({
        if ($state.Ignore) { return }
        $target = [bool]$CheckBox.Checked
        $state.Ignore = $true
        try {
            [void]$Grid.EndEdit()
            foreach ($row in @($Grid.Rows)) {
                if ($row.IsNewRow) { continue }
                $row.Cells[$Column].Value = $target
            }
            $Grid.RefreshEdit()
            $Grid.Invalidate()
        } finally {
            $state.Ignore = $false
        }
    }.GetNewClosure())
    $Grid.Add_CurrentCellDirtyStateChanged({
        if ($Grid.IsCurrentCellDirty) {
            [void]$Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }.GetNewClosure())
    $Grid.Add_CellValueChanged({
        if ($state.Ignore) { return }
        if ($_.RowIndex -lt 0 -or $Grid.Columns[$_.ColumnIndex].Name -ne $Column) { return }
        $rows = @($Grid.Rows | Where-Object { -not $_.IsNewRow })
        $allChecked = $rows.Count -gt 0 -and @($rows | Where-Object { $_.Cells[$Column].Value -ne $true }).Count -eq 0
        if ($CheckBox.Checked -eq $allChecked) { return }
        $state.Ignore = $true
        $CheckBox.Checked = $allChecked
        $state.Ignore = $false
    }.GetNewClosure())
    $Grid.Add_ColumnHeaderMouseClick({
        if ($_.ColumnIndex -ge 0 -and $Grid.Columns[$_.ColumnIndex].Name -eq $Column) {
            $CheckBox.Checked = -not $CheckBox.Checked
        }
    }.GetNewClosure())
}

function Show-DeploySelection {
    $services = @(
        "backend", "web", "admin", "marketing", "identity", "mailroom",
        "mobistack-backend", "mobistack-web", "app-store"
    )
    $statusNote = "Loading the latest immutable ECR tags. This takes about 20 seconds."
    Add-Log "Reading ECR tags for deployment..."
    $lookup = [powershell]::Create()
    [void]$lookup.AddScript({
        param($ScriptPath)
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Json 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }).AddArgument($awsStatusScript)
    $lookupHandle = $lookup.BeginInvoke()

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Deploy AWS production"
    $dialog.StartPosition = "CenterScreen"
    $dialog.ClientSize = New-Object Drawing.Size(980, 580)
    $dialog.MinimumSize = New-Object Drawing.Size(820, 480)
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.BackColor = $theme.Canvas
    $dialog.Font = $form.Font

    $promptHeader = New-Object System.Windows.Forms.Panel
    $promptHeader.Dock = "Top"
    $promptHeader.Height = 72
    $promptHeader.BackColor = $theme.Navy
    $promptTitle = New-Object System.Windows.Forms.Label
    $promptTitle.Text = "Choose services"
    $promptTitle.ForeColor = [Drawing.Color]::White
    $promptTitle.Font = New-Object Drawing.Font("Segoe UI Semibold", 14)
    $promptTitle.AutoSize = $true
    $promptTitle.Location = New-Object Drawing.Point(18, 12)
    $promptHint = New-Object System.Windows.Forms.Label
    $promptHint.Text = $statusNote
    $promptHint.ForeColor = [Drawing.ColorTranslator]::FromHtml("#98A2B3")
    $promptHint.AutoSize = $true
    $promptHint.Location = New-Object Drawing.Point(20, 40)
    $promptHeader.Controls.Add($promptTitle)
    $promptHeader.Controls.Add($promptHint)
    $dialog.Controls.Add($promptHeader)

    $selectAll = New-Object System.Windows.Forms.CheckBox
    $selectAll.Text = "Select all"
    $selectAll.AutoSize = $true
    $selectAll.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
    $selectAll.ForeColor = $theme.Navy
    $selectAll.Location = New-Object Drawing.Point(18, 84)
    $dialog.Controls.Add($selectAll)

    $deployGrid = New-Object System.Windows.Forms.DataGridView
    $deployGrid.Location = New-Object Drawing.Point(18, 114)
    $deployGrid.Size = New-Object Drawing.Size(944, 390)
    $deployGrid.Anchor = "Top,Bottom,Left,Right"
    $deployGrid.AllowUserToAddRows = $false
    $deployGrid.AllowUserToDeleteRows = $false
    $deployGrid.RowHeadersVisible = $false
    $deployGrid.SelectionMode = "FullRowSelect"
    $deployGrid.BackgroundColor = $theme.Surface
    $deployGrid.BorderStyle = "None"
    $deployGrid.AutoGenerateColumns = $false
    $deployGrid.RowTemplate.Height = 36
    $pick = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $pick.Name = "Pick"
    $pick.HeaderText = "ALL"
    $pick.Width = 52
    $serviceColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $serviceColumn.Name = "Service"
    $serviceColumn.HeaderText = "SERVICE"
    $serviceColumn.ReadOnly = $true
    $serviceColumn.Width = 170
    $productionColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $productionColumn.Name = "Production"
    $productionColumn.HeaderText = "PRODUCTION"
    $productionColumn.ReadOnly = $true
    $productionColumn.Width = 150
    $stateColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $stateColumn.Name = "State"
    $stateColumn.HeaderText = "STATUS"
    $stateColumn.ReadOnly = $true
    $stateColumn.Width = 140
    $tagColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $tagColumn.Name = "Tag"
    $tagColumn.HeaderText = "DEPLOY TAG"
    $tagColumn.AutoSizeMode = "Fill"
    [void]$deployGrid.Columns.Add($pick)
    [void]$deployGrid.Columns.Add($serviceColumn)
    [void]$deployGrid.Columns.Add($productionColumn)
    [void]$deployGrid.Columns.Add($stateColumn)
    [void]$deployGrid.Columns.Add($tagColumn)
    foreach ($service in $services) {
        [void]$deployGrid.Rows.Add($false, $service, "...", "Loading", "")
    }
    $dialog.Controls.Add($deployGrid)
    Connect-SelectAll $selectAll $deployGrid "Pick"

    $deploy = New-Button "Deploy selected" 140 $theme.Purple ([Drawing.Color]::White)
    $deploy.Enabled = $false

    $lookupTimer = New-Object System.Windows.Forms.Timer
    $lookupTimer.Interval = 300
    $lookupTimer.Add_Tick({
        if (-not $lookupHandle.IsCompleted) { return }
        $lookupTimer.Stop()
        $statusByService = @{}
        try {
            $result = @($lookup.EndInvoke($lookupHandle))[0]
            if (-not $result -or $result.ExitCode -ne 0) { throw "status failed" }
            $json = [string]$result.Output
            $jsonStart = $json.IndexOf("[")
            if ($jsonStart -lt 0) { $jsonStart = $json.IndexOf("{") }
            if ($jsonStart -lt 0) { throw "no status data" }
            # Windows PowerShell 5.1 emits a JSON array as one pipeline object, so enumerate it explicitly.
            $parsed = ConvertFrom-Json -InputObject $json.Substring($jsonStart)
            foreach ($item in $parsed) {
                if ($item.Service) { $statusByService[[string]$item.Service] = $item }
            }
            if ($statusByService.Count -eq 0) { throw "no services in status data" }
            $promptHint.Text = "Tags are filled from the latest immutable image in ECR. Newer images start selected."
            Add-Log "Deployment tags loaded."
        } catch {
            $promptHint.Text = "ECR tags could not be loaded. Enter an immutable commit tag for each selected service."
            Add-Log "Could not load deployment tags."
        } finally {
            $lookup.Dispose()
        }
        foreach ($row in $deployGrid.Rows) {
            $info = $statusByService[[string]$row.Cells["Service"].Value]
            $latest = if ($info) { [string]$info.EcrLatest } else { "" }
            $tag = if ($latest -match "^[0-9a-f]{7,40}$") { $latest } else { "" }
            $deployment = if ($info) { [string]$info.Deployment } else { "Unknown" }
            $row.Cells["Production"].Value = if ($info) { [string]$info.Production } else { "-" }
            $row.Cells["State"].Value = $deployment
            $row.Cells["Tag"].Value = $tag
            $row.Cells["Pick"].Value = [bool]($deployment -eq "Deploy available" -and $tag)
        }
        $deploy.Enabled = $true
    }.GetNewClosure())
    $dialog.Add_Shown({ $lookupTimer.Start() }.GetNewClosure())
    $dialog.Add_FormClosed({
        $lookupTimer.Stop()
        $lookupTimer.Dispose()
        if (-not $lookupHandle.IsCompleted) { [void]$lookup.BeginStop($null, $null) }
        $script:deployChooser = $null
    }.GetNewClosure())
    $deploy.Anchor = "Bottom,Right"
    $deploy.Location = New-Object Drawing.Point(822, 528)
    $cancel = New-Button "Cancel" 90
    $cancel.Anchor = "Bottom,Right"
    $cancel.Location = New-Object Drawing.Point(720, 528)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.CancelButton = $cancel
    $dialog.Controls.Add($deploy)
    $dialog.Controls.Add($cancel)
    $deploy.Add_Click({
        $deployGrid.EndEdit()
        $chosen = foreach ($row in $deployGrid.Rows) {
            if ($row.Cells["Pick"].Value -ne $true) { continue }
            $serviceName = [string]$row.Cells["Service"].Value
            $imageTag = ([string]$row.Cells["Tag"].Value).Trim()
            if ($imageTag -eq "latest" -or $imageTag -notmatch "^[0-9a-f]{7,40}$") {
                [Windows.Forms.MessageBox]::Show(
                    "Enter an immutable 7-40 character commit tag for $serviceName.",
                    "Deploy AWS", "OK", "Warning"
                ) | Out-Null
                return
            }
            [pscustomobject]@{ Service = $serviceName; Tag = $imageTag }
        }
        $chosen = @($chosen)
        if ($chosen.Count -eq 0) {
            [Windows.Forms.MessageBox]::Show("Select at least one service.", "Deploy AWS", "OK", "Information") | Out-Null
            return
        }
        $summary = ($chosen | ForEach-Object { "$($_.Service)    $($_.Tag)" }) -join "`r`n"
        $confirmed = Confirm-DashboardAction `
            -Title "Confirm production deploy" `
            -Message "This updates the production version and may run database migrations. A backup is taken first." `
            -Details $summary `
            -ActionText "Deploy now"
        if (-not $confirmed) {
            Add-Log "Production deploy cancelled."
            return
        }
        $dialog.Close()
        $script:pendingTasks.Clear()
        foreach ($item in @($chosen | Select-Object -Skip 1)) {
            $script:pendingTasks.Enqueue([pscustomobject]@{
                ScriptPath = $deployScript
                Arguments = @("-Service", $item.Service, "-Tag", $item.Tag, "-Confirm")
                Label = "Deploying $($item.Service) at $($item.Tag). Progress appears below."
            })
        }
        $first = $chosen[0]
        Start-MonitorDeploy $chosen
        Start-DashboardTask -ScriptPath $deployScript -ScriptArguments @(
            "-Service", $first.Service, "-Tag", $first.Tag, "-Confirm"
        ) -Label "Deploying $($first.Service) at $($first.Tag). Live progress is in the Production monitor."
    }.GetNewClosure())

    $script:deployChooser = $dialog
    [void]$dialog.Show()
}

$gitActions = New-ActionGroup "Workspace actions"
$productionActions = New-ActionGroup "Production controls"
$actions.Controls.Add($gitActions.Container, 0, 0)
$actions.Controls.Add($productionActions.Container, 1, 0)

$refreshButton = New-Button "Refresh" 105
$fetchButton = New-Button "Fetch all" 110
$ciButton = New-Button "Check CI" 105
$diffButton = New-Button "View diff" 110
$pushButton = New-Button "Push pending" 130 $theme.Primary ([Drawing.Color]::White)
$logButton = New-Button "Open log" 100
$awsButton = New-Button "AWS status" 120
$deployButton = New-Button "Deploy" 105 $theme.Purple ([Drawing.Color]::White)
$cleanupButton = New-Button "Clean ECR" 105
$envButton = New-Button "Environment" 130
$gitActions.Flow.Controls.AddRange(@($refreshButton, $fetchButton, $ciButton, $diffButton, $pushButton, $logButton))
$monitorButton = New-Button "Monitor" 105 $theme.Navy ([Drawing.Color]::White)
$productionActions.Flow.Controls.AddRange(@($awsButton, $deployButton, $monitorButton, $envButton, $cleanupButton))

$tooltips = New-Object System.Windows.Forms.ToolTip
$tooltips.AutoPopDelay = 9000
$tooltips.InitialDelay = 350
$tooltips.SetToolTip($refreshButton, "Refresh local branch, working tree and ahead/behind status.")
$tooltips.SetToolTip($fetchButton, "Fetch every remote without merging or changing local files.")
$tooltips.SetToolTip($ciButton, "Read the latest GitHub Actions result for each current commit.")
$tooltips.SetToolTip($diffButton, "Show the selected repository's unstaged changes.")
$tooltips.SetToolTip($pushButton, "Preview and push every ahead repository in safe dependency waves.")
$tooltips.SetToolTip($logButton, "Open today's dashboard log. Passwords and keys are left out of it.")
$tooltips.SetToolTip($awsButton, "Compare local commits, ECR images and production pins.")
$tooltips.SetToolTip($deployButton, "Deploy one immutable image tag to production.")
$tooltips.SetToolTip($envButton, "Safely view and update the production environment file.")
$tooltips.SetToolTip($cleanupButton, "Preview protected ECR retention before deleting anything.")
$tooltips.SetToolTip($monitorButton, "Live deployment progress and EC2 server health.")

$workspaceCard = New-Object System.Windows.Forms.Panel
$workspaceCard.Dock = "Fill"
$workspaceCard.Padding = New-Object Windows.Forms.Padding(18, 12, 18, 16)
$workspaceCard.BackColor = $theme.Canvas
$shell.Controls.Add($workspaceCard, 0, 2)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = "Fill"
$split.Orientation = "Horizontal"
$split.SplitterDistance = 350
$split.SplitterWidth = 8
$split.BackColor = $theme.Canvas
$workspaceCard.Controls.Add($split)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.AutoGenerateColumns = $false
$grid.MultiSelect = $false
$grid.SelectionMode = "FullRowSelect"
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = $theme.Surface
$grid.BorderStyle = "None"
$grid.CellBorderStyle = "SingleHorizontal"
$grid.GridColor = $theme.Border
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersBorderStyle = "None"
$grid.ColumnHeadersHeight = 42
$grid.ColumnHeadersHeightSizeMode = "DisableResizing"
$grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.ColorTranslator]::FromHtml("#F9FAFB")
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $theme.Muted
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font("Segoe UI Semibold", 8.5)
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [Drawing.ColorTranslator]::FromHtml("#F9FAFB")
$grid.DefaultCellStyle.BackColor = $theme.Surface
$grid.DefaultCellStyle.ForeColor = $theme.Navy
$grid.DefaultCellStyle.SelectionBackColor = [Drawing.ColorTranslator]::FromHtml("#EFF4FF")
$grid.DefaultCellStyle.SelectionForeColor = $theme.Navy
$grid.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(7, 0, 7, 0)
$grid.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.ColorTranslator]::FromHtml("#FCFCFD")
$grid.RowTemplate.Height = 38

$pickColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$pickColumn.Name = "Pick"
$pickColumn.HeaderText = "ALL"
$pickColumn.Width = 52
$pickColumn.ToolTipText = "Select all repositories"
$grid.Columns.Add($pickColumn) | Out-Null

foreach ($definition in @(
    @("Repo", "REPOSITORY", 150),
    @("Branch", "BRANCH", 145),
    @("Status", "WORKING TREE", 150),
    @("Ahead", "AHEAD", 72),
    @("Behind", "BEHIND", 72),
    @("Upstream", "UPSTREAM", 210),
    @("CI", "LATEST CI", 135)
)) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $definition[0]
    $column.HeaderText = $definition[1]
    $column.Width = $definition[2]
    $column.ReadOnly = $true
    $grid.Columns.Add($column) | Out-Null
}
$grid.Columns["Upstream"].AutoSizeMode = "Fill"
$grid.Columns["Upstream"].MinimumWidth = 170
$repoBar = New-Object System.Windows.Forms.Panel
$repoBar.Dock = "Top"
$repoBar.Height = 38
$repoBar.BackColor = $theme.Surface
$selectAllRepos = New-Object System.Windows.Forms.CheckBox
$selectAllRepos.Text = "Select all"
$selectAllRepos.AutoSize = $true
$selectAllRepos.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
$selectAllRepos.ForeColor = $theme.Navy
$selectAllRepos.Location = New-Object Drawing.Point(12, 9)
$repoBar.Controls.Add($selectAllRepos)
$split.Panel1.Controls.Add($grid)
$split.Panel1.Controls.Add($repoBar)
Connect-SelectAll $selectAllRepos $grid "Pick"

$bottom = New-Object System.Windows.Forms.TableLayoutPanel
$bottom.Dock = "Fill"
$bottom.ColumnCount = 1
$bottom.RowCount = 2
$bottom.BackColor = $theme.Canvas
$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle("Percent", 100)))
$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 58)))
$split.Panel2.Controls.Add($bottom)

$outputTabs = New-Object System.Windows.Forms.TabControl
$outputTabs.Dock = "Fill"
$outputTabs.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
$outputTabs.Padding = New-Object Drawing.Point(14, 6)
$outputTabs.Appearance = "Normal"
$outputTabs.BackColor = $theme.Surface
$detailsTab = New-Object System.Windows.Forms.TabPage
$detailsTab.Text = "  Details  "
$detailsTab.BackColor = $theme.Surface
$detailsTab.Padding = New-Object Windows.Forms.Padding(10)
$activityTab = New-Object System.Windows.Forms.TabPage
$activityTab.Text = "  Activity  "
$activityTab.BackColor = $theme.Code
$activityTab.Padding = New-Object Windows.Forms.Padding(10)
$outputTabs.TabPages.AddRange(@($detailsTab, $activityTab))
$bottom.Controls.Add($outputTabs, 0, 0)

$details = New-Object System.Windows.Forms.TextBox
$details.Dock = "Fill"
$details.Multiline = $true
$details.ReadOnly = $true
$details.ScrollBars = "Both"
$details.WordWrap = $false
$details.BorderStyle = "None"
$details.BackColor = $theme.Surface
$details.ForeColor = $theme.Navy
$details.Font = New-Object Drawing.Font("Cascadia Mono", 9)
$detailsTab.Controls.Add($details)

$commitPanel = New-Object System.Windows.Forms.TableLayoutPanel
$commitPanel.Dock = "Fill"
$commitPanel.ColumnCount = 3
$commitPanel.BackColor = $theme.Surface
$commitPanel.Padding = New-Object Windows.Forms.Padding(10, 9, 10, 8)
$commitPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Absolute", 125)))
$commitPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Percent", 100)))
$commitPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Absolute", 165)))
$commitLabel = New-Object System.Windows.Forms.Label
$commitLabel.Text = "COMMIT MESSAGE"
$commitLabel.Dock = "Fill"
$commitLabel.Font = New-Object Drawing.Font("Segoe UI Semibold", 8)
$commitLabel.ForeColor = $theme.Muted
$commitLabel.TextAlign = "MiddleLeft"
$commitMessage = New-Object System.Windows.Forms.TextBox
$commitMessage.Dock = "Fill"
$commitMessage.BorderStyle = "FixedSingle"
$commitMessage.Font = New-Object Drawing.Font("Segoe UI", 10)
$commitMessage.Margin = New-Object Windows.Forms.Padding(0, 2, 10, 2)
$commitButton = New-Button "Commit selected" 150 $theme.Primary ([Drawing.Color]::White)
$commitButton.Dock = "Fill"
$commitButton.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 0)
$commitPanel.Controls.Add($commitLabel, 0, 0)
$commitPanel.Controls.Add($commitMessage, 1, 0)
$commitPanel.Controls.Add($commitButton, 2, 0)
$bottom.Controls.Add($commitPanel, 0, 1)

$log = New-Object System.Windows.Forms.TextBox
$log.Dock = "Fill"
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = "Vertical"
$log.BorderStyle = "None"
$log.BackColor = $theme.Code
$log.ForeColor = [Drawing.ColorTranslator]::FromHtml("#D1D5DB")
$log.Font = New-Object Drawing.Font("Cascadia Mono", 9)
$activityTab.Controls.Add($log)

$script:dashboardLog = Join-Path $Root ("Infra\logs\dashboard-{0}.log" -f (Get-Date -Format "yyyyMMdd"))

function Protect-LogText {
    param([string]$Text)
    if (-not $Text) { return "" }
    $Text = $Text -replace '(?i)((?:PASSWORD|SECRET|TOKEN|CREDENTIAL|SIGNING_KEY|AUTH_TOKEN|API_KEY)\s*=\s*)\S+', '$1[redacted]'
    $Text = $Text -replace '(?i)(://[^:\s]+:)[^@\s]+@', '$1[redacted]@'
    $Text = $Text -replace '(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----', '[redacted private key]'
    return $Text
}

function Write-DashboardLog {
    param([string]$Message)
    try {
        $directory = Split-Path $script:dashboardLog
        if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
        $line = "[{0}] {1}{2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), (Protect-LogText $Message), [Environment]::NewLine
        [IO.File]::AppendAllText($script:dashboardLog, $line)
    } catch {
        # A logging failure must not stop the action the user asked for.
    }
}

function Add-Log {
    param([string]$Message)
    $log.AppendText("[$(Get-Date -Format HH:mm:ss)] $Message`r`n")
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
    Write-DashboardLog $Message
}

function Format-ProcessArgument {
    param([string]$Value)
    if ($Value -match '[\s"]') { '"' + ($Value -replace '"', '\"') + '"' } else { $Value }
}

$script:outputQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:activeTask = $null
$script:refreshAfterTask = $false
$script:pendingTasks = New-Object System.Collections.Generic.Queue[object]
$script:lastTaskOutputAt = $null
$script:taskStallReported = $false
$outputTimer = New-Object System.Windows.Forms.Timer
$outputTimer.Interval = 200
$outputTimer.Add_Tick({
    $line = ""
    while ($script:outputQueue.TryDequeue([ref]$line)) {
        $script:lastTaskOutputAt = Get-Date
        $script:taskStallReported = $false
        $log.AppendText("$line`r`n")
        Write-DashboardLog $line
        if ($script:monitorDeployActive) { Update-MonitorLine $line }
    }
    if ($line) {
        $log.SelectionStart = $log.TextLength
        $log.ScrollToCaret()
    }
    $pumpsDone = $true
    foreach ($pump in @($script:outputPumps)) {
        if ($pump -and -not $pump.Handle.IsCompleted) { $pumpsDone = $false }
    }
    if (
        $script:activeTask -and -not $script:activeTask.HasExited -and
        $script:lastTaskOutputAt -and -not $script:taskStallReported -and
        ((Get-Date) - $script:lastTaskOutputAt).TotalSeconds -ge 45
    ) {
        $script:taskStallReported = $true
        $message = "No deploy output for 45 seconds. The SSH connection may be interrupted; the dashboard is still waiting."
        Add-Log $message
        if ($script:monitorDeployActive -and $script:monitor) {
            $script:monitor.Subtitle.Text = $message
            if ($script:monitor.Index -ge 0 -and $script:monitor.Index -lt $script:monitor.Services.Rows.Count) {
                $script:monitor.Services.Rows[$script:monitor.Index].Cells["Step"].Value =
                    "Waiting for the production SSH connection"
            }
        }
    }
    if ($script:activeTask -and $script:activeTask.HasExited -and $pumpsDone -and $script:refreshAfterTask) {
        $exitCode = $script:activeTask.ExitCode
        Add-Log "Finished with exit code $exitCode."
        if ($script:monitorDeployActive) { Complete-MonitorService $exitCode }
        if ($exitCode -eq 0 -and $script:pendingTasks.Count -gt 0) {
            $next = $script:pendingTasks.Dequeue()
            Start-DashboardTask -ScriptPath $next.ScriptPath -ScriptArguments $next.Arguments -Label $next.Label
            return
        }
        if ($exitCode -ne 0 -and $script:pendingTasks.Count -gt 0) {
            Add-Log "Stopped the remaining deploys because this one failed."
        }
        $script:pendingTasks.Clear()
        $script:refreshAfterTask = $false
        Set-Busy $false
        if ($exitCode -eq 0) { Refresh-Grid }
    }
})
$outputTimer.Start()
$form.Add_FormClosed({
    Write-DashboardLog "Dashboard closed."
    $outputTimer.Stop()
})

# Long operations stay inside this window. Their output is appended here instead of opening a console.
function Start-DashboardTask {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($script:activeTask -and -not $script:activeTask.HasExited) {
        [Windows.Forms.MessageBox]::Show(
            "Wait for the current operation to finish.", "Git Dashboard", "OK", "Information"
        ) | Out-Null
        return
    }

    $outputTabs.SelectedTab = $activityTab
    Add-Log $Label
    Set-Busy $true
    $argumentText = (
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $ScriptArguments |
            ForEach-Object { Format-ProcessArgument $_ }
    ) -join " "

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = $argumentText
    $startInfo.WorkingDirectory = $Root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $script:outputPumps = @(
        Start-OutputPump $process "StandardOutput" $script:outputQueue
        Start-OutputPump $process "StandardError" $script:outputQueue
    )
    $script:activeTask = $process
    $script:refreshAfterTask = $true
    $script:lastTaskOutputAt = Get-Date
    $script:taskStallReported = $false
}

# .NET process events do not reliably share PowerShell variables, so a runspace reads each stream.
function Start-OutputPump {
    param($Process, [string]$StreamName, $Queue)
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    $shell.Runspace.SessionStateProxy.SetVariable("proc", $Process)
    $shell.Runspace.SessionStateProxy.SetVariable("queue", $Queue)
    $shell.Runspace.SessionStateProxy.SetVariable("streamName", $StreamName)
    [void]$shell.AddScript({
        $stream = $proc.$streamName
        while (($line = $stream.ReadLine()) -ne $null) {
            $queue.Enqueue($line)
        }
    })
    [pscustomobject]@{ Runspace = $runspace; PowerShell = $shell; Handle = $shell.BeginInvoke() }
}

function Set-Busy {
    param([bool]$Busy)
    $form.UseWaitCursor = $Busy
    $activityStatus.Text = if ($Busy) { "WORKING" } else { "READY" }
    $activityStatus.ForeColor = if ($Busy) {
        [Drawing.ColorTranslator]::FromHtml("#FEC84B")
    } else {
        [Drawing.ColorTranslator]::FromHtml("#6CE9A6")
    }
    $activityStatus.BackColor = if ($Busy) {
        [Drawing.ColorTranslator]::FromHtml("#3D3218")
    } else {
        [Drawing.ColorTranslator]::FromHtml("#17382B")
    }
    foreach ($control in @(
        $refreshButton, $fetchButton, $ciButton, $diffButton, $pushButton, $logButton,
        $awsButton, $deployButton, $cleanupButton, $envButton, $commitButton
    )) {
        $control.Enabled = -not $Busy
    }
    [Windows.Forms.Application]::DoEvents()
}

function Refresh-Grid {
    Set-Busy $true
    try {
        $grid.Rows.Clear()
        $changedRepos = 0
        $aheadRepos = 0
        $behindRepos = 0
        foreach ($name in $repoNames) {
            $state = Get-RepoState $name
            $workingTree = if ($state.Changes -gt 0) { "$($state.Changes) changed" } else { "Clean" }
            $index = $grid.Rows.Add($false, $state.Name, $state.Branch, $workingTree,
                $state.Ahead, $state.Behind, $state.Upstream, "")
            $row = $grid.Rows[$index]
            $row.Tag = $state
            if ($state.Behind -gt 0) {
                $behindRepos++
                $row.Cells["Status"].Style.ForeColor = $theme.Danger
                $row.DefaultCellStyle.BackColor = $theme.DangerSoft
            } elseif ($state.Changes -gt 0) {
                $changedRepos++
                $row.Cells["Status"].Style.ForeColor = $theme.Warning
                $row.DefaultCellStyle.BackColor = $theme.WarningSoft
            } elseif ($state.Ahead -gt 0) {
                $aheadRepos++
                $row.Cells["Status"].Style.ForeColor = $theme.Success
                $row.DefaultCellStyle.BackColor = $theme.SuccessSoft
            } else {
                $row.Cells["Status"].Style.ForeColor = $theme.Success
            }
            if ($state.Ahead -gt 0 -and $state.Changes -gt 0) { $aheadRepos++ }
            $row.Cells["Repo"].Style.Font = New-Object Drawing.Font("Segoe UI Semibold", 9.5)
        }
        $subtitle.Text = "8 repositories  |  $changedRepos with changes  |  $aheadRepos ahead  |  $behindRepos behind"
        if ($selectAllRepos.Checked) { $selectAllRepos.Checked = $false }
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
    $outputTabs.SelectedTab = $detailsTab
})

$refreshButton.Add_Click({ Refresh-Grid })

$diffButton.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) { return }
    $state = $grid.SelectedRows[0].Tag
    $diff = Invoke-Git $state.Path @("diff", "--", ".")
    $details.Text = if ($diff.Output) { $diff.Output } else { "No unstaged diff. Check staged or untracked files in the status above." }
    $outputTabs.SelectedTab = $detailsTab
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
    if ($preview.Output -notmatch "(?m)^==> wave '") {
        [Windows.Forms.MessageBox]::Show("No repository is ahead of its remote.", "Push", "OK", "Information") | Out-Null
        return
    }
    if ([Windows.Forms.MessageBox]::Show(
        "$($preview.Output)`r`n`r`nPush these commits in dependency waves and wait for CI?",
        "Confirm wave push", "YesNo", "Warning"
    ) -ne "Yes") { return }

    Start-DashboardTask -ScriptPath $pushScript -Label "Pushing in dependency waves. Progress appears below."
})

$awsButton.Add_Click({
    if (-not (Test-Path $awsStatusScript)) {
        [Windows.Forms.MessageBox]::Show("AWS status script not found: $awsStatusScript", "AWS status", "OK", "Error") | Out-Null
        return
    }
    Set-Busy $true
    try {
        Add-Log "Reading ECR latest tags and production pins..."
        $result = Invoke-Native "powershell.exe" @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $awsStatusScript
        )
        $details.Text = $result.Output
        $outputTabs.SelectedTab = $detailsTab
        if ($result.ExitCode -eq 0) {
            Add-Log "AWS image and deployment status refreshed."
        } else {
            Add-Log "AWS status failed: $($result.Output)"
        }
    } finally {
        Set-Busy $false
    }
})

$script:monitor = $null
$script:monitorDeployActive = $false

function New-StatCard {
    param($Parent, [string]$Title)
    $card = New-Object System.Windows.Forms.Panel
    $card.Size = New-Object Drawing.Size(196, 70)
    $card.Margin = New-Object Windows.Forms.Padding(0, 0, 10, 10)
    $card.BackColor = $theme.Surface
    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = $Title.ToUpperInvariant()
    $caption.Font = New-Object Drawing.Font("Segoe UI Semibold", 7.5)
    $caption.ForeColor = $theme.Muted
    $caption.Location = New-Object Drawing.Point(12, 10)
    $caption.AutoSize = $true
    $value = New-Object System.Windows.Forms.Label
    $value.Text = "-"
    $value.Font = New-Object Drawing.Font("Segoe UI Semibold", 11)
    $value.ForeColor = $theme.Navy
    $value.Location = New-Object Drawing.Point(12, 32)
    $value.Size = New-Object Drawing.Size(178, 30)
    $value.AutoEllipsis = $true
    $card.Controls.Add($caption)
    $card.Controls.Add($value)
    $Parent.Controls.Add($card)
    $value
}

function New-MonitorGrid {
    $view = New-Object System.Windows.Forms.DataGridView
    $view.Dock = "Fill"
    $view.AllowUserToAddRows = $false
    $view.AllowUserToDeleteRows = $false
    $view.AllowUserToResizeRows = $false
    $view.ReadOnly = $true
    $view.RowHeadersVisible = $false
    $view.SelectionMode = "FullRowSelect"
    $view.BackgroundColor = $theme.Surface
    $view.BorderStyle = "None"
    $view.CellBorderStyle = "SingleHorizontal"
    $view.GridColor = $theme.Border
    $view.EnableHeadersVisualStyles = $false
    $view.ColumnHeadersBorderStyle = "None"
    $view.ColumnHeadersHeight = 38
    $view.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.ColorTranslator]::FromHtml("#F9FAFB")
    $view.ColumnHeadersDefaultCellStyle.ForeColor = $theme.Muted
    $view.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font("Segoe UI Semibold", 8.5)
    $view.DefaultCellStyle.SelectionBackColor = [Drawing.ColorTranslator]::FromHtml("#EFF4FF")
    $view.DefaultCellStyle.SelectionForeColor = $theme.Navy
    $view.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(6, 0, 6, 0)
    $view.RowTemplate.Height = 34
    $view
}

function Add-MonitorColumn {
    param($View, [string]$Name, [string]$Header, [int]$Width, [switch]$Fill)
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $Name
    $column.HeaderText = $Header
    $column.Width = $Width
    if ($Fill) { $column.AutoSizeMode = "Fill" }
    [void]$View.Columns.Add($column)
}

function New-OpsMonitor {
    if ($script:monitor -and -not $script:monitor.Form.IsDisposed) { return }

    $m = @{}
    $window = New-Object System.Windows.Forms.Form
    $window.Text = "Production monitor"
    $window.StartPosition = "CenterScreen"
    $window.Size = New-Object Drawing.Size(1180, 780)
    $window.MinimumSize = New-Object Drawing.Size(960, 620)
    $window.BackColor = $theme.Canvas
    $window.Font = $form.Font
    $m.Form = $window

    $head = New-Object System.Windows.Forms.Panel
    $head.Dock = "Top"
    $head.Height = 112
    $head.BackColor = $theme.Navy
    $m.Title = New-Object System.Windows.Forms.Label
    $m.Title.Text = "Production monitor"
    $m.Title.ForeColor = [Drawing.Color]::White
    $m.Title.Font = New-Object Drawing.Font("Segoe UI Semibold", 16)
    $m.Title.AutoSize = $true
    $m.Title.Location = New-Object Drawing.Point(22, 12)
    $m.Subtitle = New-Object System.Windows.Forms.Label
    $m.Subtitle.Text = "No deployment running. Server health refreshes every 15 seconds."
    $m.Subtitle.ForeColor = [Drawing.ColorTranslator]::FromHtml("#98A2B3")
    $m.Subtitle.AutoSize = $true
    $m.Subtitle.Location = New-Object Drawing.Point(24, 46)
    $m.Progress = New-Object System.Windows.Forms.ProgressBar
    $m.Progress.Location = New-Object Drawing.Point(24, 76)
    $m.Progress.Size = New-Object Drawing.Size(860, 14)
    $m.Progress.Anchor = "Top,Left,Right"
    $m.Progress.Minimum = 0
    $m.Progress.Maximum = 100
    $m.Elapsed = New-Object System.Windows.Forms.Label
    $m.Elapsed.Text = ""
    $m.Elapsed.ForeColor = [Drawing.Color]::White
    $m.Elapsed.Font = New-Object Drawing.Font("Segoe UI Semibold", 10)
    $m.Elapsed.TextAlign = "MiddleRight"
    $m.Elapsed.Size = New-Object Drawing.Size(240, 24)
    $m.Elapsed.Anchor = "Top,Right"
    $m.Elapsed.Location = New-Object Drawing.Point(900, 70)
    $head.Controls.AddRange(@($m.Title, $m.Subtitle, $m.Progress, $m.Elapsed))
    $window.Controls.Add($head)

    $m.Tabs = New-Object System.Windows.Forms.TabControl
    $m.Tabs.Dock = "Fill"
    $m.Tabs.Padding = New-Object Drawing.Point(16, 6)
    $m.Tabs.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
    $m.DeployTab = New-Object System.Windows.Forms.TabPage
    $m.DeployTab.Text = "  Deployment  "
    $m.DeployTab.BackColor = $theme.Canvas
    $m.DeployTab.Padding = New-Object Windows.Forms.Padding(12)
    $m.ServerTab = New-Object System.Windows.Forms.TabPage
    $m.ServerTab.Text = "  Server (EC2)  "
    $m.ServerTab.BackColor = $theme.Canvas
    $m.ServerTab.Padding = New-Object Windows.Forms.Padding(12)
    $m.Tabs.TabPages.Add($m.DeployTab)
    $m.Tabs.TabPages.Add($m.ServerTab)
    $window.Controls.Add($m.Tabs)
    $m.Tabs.BringToFront()

    $deploySplit = New-Object System.Windows.Forms.SplitContainer
    $deploySplit.Dock = "Fill"
    $deploySplit.Orientation = "Horizontal"
    $deploySplit.SplitterDistance = 230
    $deploySplit.SplitterWidth = 8
    $m.DeployTab.Controls.Add($deploySplit)
    $m.Services = New-MonitorGrid
    Add-MonitorColumn $m.Services "Service" "SERVICE" 180
    Add-MonitorColumn $m.Services "Tag" "TAG" 110
    Add-MonitorColumn $m.Services "State" "STATUS" 120
    Add-MonitorColumn $m.Services "Percent" "PROGRESS" 90
    Add-MonitorColumn $m.Services "Step" "CURRENT STEP" 300 -Fill
    Add-MonitorColumn $m.Services "Duration" "TIME" 80
    $deploySplit.Panel1.Controls.Add($m.Services)
    $m.Log = New-Object System.Windows.Forms.TextBox
    $m.Log.Dock = "Fill"
    $m.Log.Multiline = $true
    $m.Log.ReadOnly = $true
    $m.Log.ScrollBars = "Both"
    $m.Log.WordWrap = $false
    $m.Log.BorderStyle = "None"
    $m.Log.BackColor = $theme.Code
    $m.Log.ForeColor = [Drawing.ColorTranslator]::FromHtml("#D1D5DB")
    $m.Log.Font = New-Object Drawing.Font("Cascadia Mono", 9)
    $deploySplit.Panel2.Controls.Add($m.Log)

    $serverLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $serverLayout.Dock = "Fill"
    $serverLayout.ColumnCount = 1
    $serverLayout.RowCount = 3
    [void]$serverLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 40)))
    [void]$serverLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 170)))
    [void]$serverLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle("Percent", 100)))
    $m.ServerTab.Controls.Add($serverLayout)
    $serverBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $serverBar.Dock = "Fill"
    $m.RefreshServer = New-Button "Refresh now" 120
    $m.RefreshServer.Margin = New-Object Windows.Forms.Padding(0, 0, 12, 0)
    $m.ServerChecked = New-Object System.Windows.Forms.Label
    $m.ServerChecked.Text = "Loading server status..."
    $m.ServerChecked.ForeColor = $theme.Muted
    $m.ServerChecked.AutoSize = $true
    $m.ServerChecked.Margin = New-Object Windows.Forms.Padding(0, 11, 0, 0)
    $serverBar.Controls.Add($m.RefreshServer)
    $serverBar.Controls.Add($m.ServerChecked)
    $serverLayout.Controls.Add($serverBar, 0, 0)
    $cards = New-Object System.Windows.Forms.FlowLayoutPanel
    $cards.Dock = "Fill"
    $cards.WrapContents = $true
    $m.CardState = New-StatCard $cards "Instance"
    $m.CardChecks = New-StatCard $cards "Status checks"
    $m.CardCpu = New-StatCard $cards "CPU (last 5 min)"
    $m.CardLoad = New-StatCard $cards "Load average"
    $m.CardMemory = New-StatCard $cards "Memory"
    $m.CardDisk = New-StatCard $cards "Disk /"
    $m.CardUptime = New-StatCard $cards "Uptime"
    $m.CardHost = New-StatCard $cards "Type and address"
    $m.CardContainers = New-StatCard $cards "Containers"
    $m.CardZone = New-StatCard $cards "Availability zone"
    $serverLayout.Controls.Add($cards, 0, 1)
    $m.Containers = New-MonitorGrid
    Add-MonitorColumn $m.Containers "Name" "CONTAINER" 230
    Add-MonitorColumn $m.Containers "Image" "IMAGE" 260
    Add-MonitorColumn $m.Containers "Health" "HEALTH" 110
    Add-MonitorColumn $m.Containers "Status" "STATUS" 300 -Fill
    $serverLayout.Controls.Add($m.Containers, 0, 2)

    $m.Queue = @()
    $m.Index = -1
    $m.Started = $null
    $m.ServiceStarted = $null
    $m.ServiceBest = 0
    $m.ServerLookup = $null
    $m.ServerHandle = $null
    $m.ServerNext = [DateTime]::MinValue

    $m.Timer = New-Object System.Windows.Forms.Timer
    $m.Timer.Interval = 500
    $m.Timer.Add_Tick({ Update-OpsMonitorTick })
    $m.RefreshServer.Add_Click({ Start-ServerRefresh -Force })
    $window.Add_FormClosing({
        param($sender, $e)
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $sender.Hide()
        }
    })
    $form.Add_FormClosed({
        if ($script:monitor) {
            $script:monitor.Timer.Stop()
            $script:monitor.Form.Dispose()
        }
    })

    $script:monitor = $m
    $m.Timer.Start()
}

function Show-OpsMonitor {
    param([ValidateSet("deploy", "server")][string]$Tab = "server")
    New-OpsMonitor
    $m = $script:monitor
    $m.Tabs.SelectedTab = if ($Tab -eq "deploy") { $m.DeployTab } else { $m.ServerTab }
    if (-not $m.Form.Visible) { $m.Form.Show($form) }
    $m.Form.Activate()
    Start-ServerRefresh
}

function Start-ServerRefresh {
    param([switch]$Force)
    $m = $script:monitor
    if (-not $m) { return }
    if ($m.ServerHandle -and -not $m.ServerHandle.IsCompleted) { return }
    if (-not $Force -and (Get-Date) -lt $m.ServerNext) { return }
    $m.ServerChecked.Text = "Checking the server..."
    $lookup = [powershell]::Create()
    [void]$lookup.AddScript({
        param($ScriptPath)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1 | Out-String
    }).AddArgument($serverStatusScript)
    $m.ServerLookup = $lookup
    $m.ServerHandle = $lookup.BeginInvoke()
}

function Get-HealthColor {
    param([string]$Value)
    switch -Regex ($Value) {
        '^(Healthy|Running|running|ok|passed|Succeeded)$' { return $theme.Success }
        '^(Starting|Restarting|pending|initializing|Running deploy|Rolling back)$' { return $theme.Warning }
        '^(Unhealthy|Stopped|stopped|impaired|Failed|failed|Skipped)' { return $theme.Danger }
    }
    return $theme.Navy
}

function Set-HealthColor {
    param($Target, [string]$Value)
    $color = Get-HealthColor $Value
    if ($Target -is [System.Windows.Forms.Control]) { $Target.ForeColor = $color }
    else { $Target.Style.ForeColor = $color }
}

function Apply-ServerSnapshot {
    param([string]$Text)
    $m = $script:monitor
    $start = $Text.IndexOf("{")
    if ($start -lt 0) {
        $m.ServerChecked.Text = "Server status could not be read. $($Text.Trim())"
        return
    }
    $snap = ConvertFrom-Json -InputObject $Text.Substring($start)
    $m.CardState.Text = [string]$snap.State
    Set-HealthColor $m.CardState ([string]$snap.State)
    $m.CardChecks.Text = "System $($snap.SystemCheck), instance $($snap.InstanceCheck)"
    $m.CardCpu.Text = if ($snap.CpuPercent -ne "-") { "$($snap.CpuPercent)%" } else { "-" }
    $m.CardLoad.Text = "$($snap.Load)  ($($snap.Cpus) vCPU)"
    $m.CardMemory.Text = [string]$snap.Memory
    $m.CardDisk.Text = [string]$snap.Disk
    $m.CardUptime.Text = [string]$snap.Uptime
    $m.CardHost.Text = "$($snap.Type)  $($snap.PublicIp)"
    $m.CardZone.Text = [string]$snap.Zone

    $m.Containers.Rows.Clear()
    $healthy = 0
    $total = 0
    foreach ($c in $snap.Containers) {
        if (-not $c.Name) { continue }
        $total++
        if ($c.Health -in @("Healthy", "Running")) { $healthy++ }
        $index = $m.Containers.Rows.Add([string]$c.Name, [string]$c.Image, [string]$c.Health, [string]$c.Status)
        $row = $m.Containers.Rows[$index]
        Set-HealthColor $row.Cells["Health"] ([string]$c.Health)
        if ($c.Health -in @("Unhealthy", "Stopped", "Restarting")) {
            $row.DefaultCellStyle.BackColor = $theme.DangerSoft
        }
    }
    $m.CardContainers.Text = "$healthy of $total up"
    $m.CardContainers.ForeColor = if ($total -gt 0 -and $healthy -eq $total) { $theme.Success } else { $theme.Warning }
    $errorsText = (@($snap.Errors) | Where-Object { $_ }) -join "  "
    $m.ServerChecked.Text = "Last checked $($snap.CheckedAt). Refreshes every 15 seconds." +
        $(if ($errorsText) { "  Problem: $errorsText" } else { "" })
}

function Get-DeployStep {
    param([string]$Line)
    $steps = @(
        @('==> Production deploy', 3, 'Verifying image in ECR'),
        @('\[remote\] .* -> .*backup', 8, 'Backed up the environment file'),
        @('Refreshing .* from Parameter Store', 12, 'Refreshing environment'),
        @('Secrets from|Reading secrets', 15, 'Loading secrets'),
        @('Authenticating to ECR', 20, 'Signing in to ECR'),
        @('Pulling images', 30, 'Pulling images'),
        @('Application services in this deploy', 42, 'Images pulled'),
        @('postgres|managed database', 46, 'Checking the database'),
        @('pgbouncer', 50, 'Restarting the connection pool'),
        @('Deploying identity', 58, 'Starting identity'),
        @('Health-gating identity', 64, 'Waiting for identity to be healthy'),
        @('Identity is ready', 68, 'Identity is healthy'),
        @('Deploying backend', 70, 'Starting backend (database migrations)'),
        @('Health-gating backend', 74, 'Waiting for backend to be ready'),
        @('Backend is ready', 78, 'Backend is ready'),
        @('Deploying mobistack-backend', 80, 'Starting MobiStack backend'),
        @('Health-gating mobistack-backend', 83, 'Waiting for MobiStack backend'),
        @('mobistack-backend is ready', 86, 'MobiStack backend is ready'),
        @('Deploying frontends', 88, 'Starting frontends'),
        @('Recreating caddy', 92, 'Reloading the web proxy'),
        @('Pruning dangling images', 95, 'Cleaning up old images'),
        @('Deploy succeeded', 98, 'Deploy succeeded'),
        @('production pin persisted', 100, 'Version saved to the environment file')
    )
    foreach ($step in $steps) {
        if ($Line -match $step[0]) { return [pscustomobject]@{ Percent = $step[1]; Label = $step[2] } }
    }
    if ($Line -match 'ROLLBACK') { return [pscustomobject]@{ Percent = -1; Label = 'Rolling back to the previous images' } }
    return $null
}

function Start-MonitorDeploy {
    param($Items)
    Show-OpsMonitor -Tab deploy
    $m = $script:monitor
    $m.Queue = @($Items)
    $m.Index = 0
    $m.Started = Get-Date
    $m.ServiceStarted = Get-Date
    $m.ServiceBest = 0
    $m.Log.Clear()
    $m.Services.Rows.Clear()
    foreach ($item in $m.Queue) {
        [void]$m.Services.Rows.Add($item.Service, $item.Tag, "Queued", "0%", "Waiting", "")
    }
    Set-MonitorRowState 0 "Running deploy"
    $m.Title.Text = "Deploying $($m.Queue.Count) service$(if ($m.Queue.Count -ne 1) { 's' })"
    $m.Subtitle.Text = "Deploying $($m.Queue[0].Service) at $($m.Queue[0].Tag)"
    $m.Progress.Value = 0
    $script:monitorDeployActive = $true
}

function Set-MonitorRowState {
    param([int]$Index, [string]$State)
    $m = $script:monitor
    if ($Index -lt 0 -or $Index -ge $m.Services.Rows.Count) { return }
    $row = $m.Services.Rows[$Index]
    $row.Cells["State"].Value = $State
    Set-HealthColor $row.Cells["State"] $State
    $row.DefaultCellStyle.BackColor = switch ($State) {
        "Running deploy" { [Drawing.ColorTranslator]::FromHtml("#EFF4FF") }
        "Rolling back" { $theme.WarningSoft }
        "Succeeded" { $theme.SuccessSoft }
        "Failed" { $theme.DangerSoft }
        default { $theme.Surface }
    }
}

function Update-MonitorLine {
    param([string]$Line)
    $m = $script:monitor
    if (-not $m -or $m.Form.IsDisposed) { return }
    $m.Log.AppendText("$Line`r`n")
    $step = Get-DeployStep $Line
    if (-not $step -or $m.Index -lt 0 -or $m.Index -ge $m.Queue.Count) { return }
    $row = $m.Services.Rows[$m.Index]
    $row.Cells["Step"].Value = $step.Label
    if ($step.Percent -lt 0) {
        Set-MonitorRowState $m.Index "Rolling back"
        return
    }
    if ($step.Percent -gt $m.ServiceBest) { $m.ServiceBest = $step.Percent }
    $row.Cells["Percent"].Value = "$($m.ServiceBest)%"
    $overall = [int](($m.Index * 100 + $m.ServiceBest) / [Math]::Max(1, $m.Queue.Count))
    $m.Progress.Value = [Math]::Min(100, [Math]::Max(0, $overall))
}

function Complete-MonitorService {
    param([int]$ExitCode)
    $m = $script:monitor
    if (-not $m -or $m.Index -lt 0 -or $m.Index -ge $m.Queue.Count) { return }
    $row = $m.Services.Rows[$m.Index]
    $row.Cells["Duration"].Value = Format-Elapsed ((Get-Date) - $m.ServiceStarted)
    if ($ExitCode -eq 0) {
        Set-MonitorRowState $m.Index "Succeeded"
        $row.Cells["Percent"].Value = "100%"
        $row.Cells["Step"].Value = "Live and pinned in the environment file"
    } else {
        Set-MonitorRowState $m.Index "Failed"
        $row.Cells["Step"].Value = "Failed. The previous version and pin were restored."
        for ($i = $m.Index + 1; $i -lt $m.Queue.Count; $i++) {
            $m.Services.Rows[$i].Cells["State"].Value = "Skipped"
            $m.Services.Rows[$i].Cells["Step"].Value = "Not started because an earlier deploy failed"
        }
    }
    $m.Index++
    $m.ServiceBest = 0
    $m.ServiceStarted = Get-Date
    if ($ExitCode -eq 0 -and $m.Index -lt $m.Queue.Count) {
        Set-MonitorRowState $m.Index "Running deploy"
        $m.Subtitle.Text = "Deploying $($m.Queue[$m.Index].Service) at $($m.Queue[$m.Index].Tag)"
        $m.Progress.Value = [int]($m.Index * 100 / $m.Queue.Count)
        return
    }
    $script:monitorDeployActive = $false
    $total = Format-Elapsed ((Get-Date) - $m.Started)
    if ($ExitCode -eq 0) {
        $m.Progress.Value = 100
        $m.Title.Text = "Deployment complete"
        $m.Subtitle.Text = "All $($m.Queue.Count) service(s) are live. Total time $total."
    } else {
        $m.Title.Text = "Deployment failed"
        $m.Subtitle.Text = "Check the output below. The failed service was rolled back. Total time $total."
    }
    Start-ServerRefresh -Force
}

function Format-Elapsed {
    param([TimeSpan]$Span)
    "{0:00}:{1:00}" -f [Math]::Floor($Span.TotalMinutes), $Span.Seconds
}

function Update-OpsMonitorTick {
    $m = $script:monitor
    if (-not $m -or $m.Form.IsDisposed) { return }
    if ($script:monitorDeployActive -and $m.Started) {
        $m.Elapsed.Text = "Elapsed " + (Format-Elapsed ((Get-Date) - $m.Started))
        if ($m.Index -ge 0 -and $m.Index -lt $m.Services.Rows.Count) {
            $m.Services.Rows[$m.Index].Cells["Duration"].Value = Format-Elapsed ((Get-Date) - $m.ServiceStarted)
        }
    }
    if ($m.ServerHandle -and $m.ServerHandle.IsCompleted) {
        $text = ""
        try {
            $text = [string](@($m.ServerLookup.EndInvoke($m.ServerHandle)) -join "")
            Apply-ServerSnapshot $text
        } catch {
            $m.ServerChecked.Text = "Server status could not be read: $($_.Exception.Message)"
        } finally {
            $m.ServerLookup.Dispose()
            $m.ServerLookup = $null
            $m.ServerHandle = $null
            $m.ServerNext = (Get-Date).AddSeconds(15)
        }
    }
    if ($m.Form.Visible) { Start-ServerRefresh }
}

$deployButton.Add_Click({
    if (-not (Test-Path $deployScript)) {
        [Windows.Forms.MessageBox]::Show("Deploy script not found: $deployScript", "Deploy AWS", "OK", "Error") | Out-Null
        return
    }
    if ($script:activeTask -and -not $script:activeTask.HasExited) {
        [Windows.Forms.MessageBox]::Show(
            "Wait for the current operation to finish.", "Deploy AWS", "OK", "Information"
        ) | Out-Null
        return
    }
    if ($script:deployChooser -and -not $script:deployChooser.IsDisposed) {
        $script:deployChooser.Activate()
        return
    }
    Show-DeploySelection
})

$monitorButton.Add_Click({ Show-OpsMonitor -Tab $(if ($script:monitorDeployActive) { "deploy" } else { "server" }) })

$cleanupButton.Add_Click({
    if (-not (Test-Path $cleanupScript)) {
        [Windows.Forms.MessageBox]::Show("Cleanup script not found: $cleanupScript", "Clean ECR", "OK", "Error") | Out-Null
        return
    }
    $keepText = Show-TextPrompt `
        -Message "How many recent images should each repository keep?`r`nProduction pins and latest are always kept. Minimum: 3." `
        -Title "Preview ECR cleanup" `
        -Default "10"
    $keepText = $keepText.Trim()
    if (-not $keepText) { return }
    $keep = 0
    if (-not [int]::TryParse($keepText, [ref]$keep) -or $keep -lt 3 -or $keep -gt 100) {
        [Windows.Forms.MessageBox]::Show("Enter a number from 3 to 100.", "Clean ECR", "OK", "Error") | Out-Null
        return
    }

    Set-Busy $true
    try {
        Add-Log "Previewing ECR cleanup with a $keep-image rollback window..."
        $preview = Invoke-Native "powershell.exe" @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $cleanupScript,
            "-KeepRecent", "$keep"
        )
        $details.Text = $preview.Output
        $outputTabs.SelectedTab = $detailsTab
        if ($preview.ExitCode -ne 0) {
            [Windows.Forms.MessageBox]::Show($preview.Output, "ECR cleanup preview failed", "OK", "Error") | Out-Null
            return
        }
    } finally {
        Set-Busy $false
    }

    $word = Show-TextPrompt `
        -Message "Review the cleanup plan in the details pane.`r`n`r`nDeleting ECR images cannot be undone. Type DELETE to apply it:" `
        -Title "Confirm ECR cleanup" `
        -Default ""
    if ($word -cne "DELETE") {
        Add-Log "ECR cleanup left in preview mode; nothing was deleted."
        return
    }
    Start-DashboardTask -ScriptPath $cleanupScript -ScriptArguments @(
        "-KeepRecent", "$keep", "-Apply", "-ConfirmWord", "DELETE"
    ) -Label "Cleaning ECR with a $keep-image rollback window. Progress appears below."
})

function Show-ProductionEnvEditor {
    Set-Busy $true
    try {
        Add-Log "Loading production environment settings..."
        $entries = Get-ProductionEnvFile
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Production env", "OK", "Error") | Out-Null
        Add-Log "Could not load the production environment file."
        return
    } finally {
        Set-Busy $false
    }

    $editor = New-Object System.Windows.Forms.Form
    $editor.Text = "Production environment"
    $editor.StartPosition = "CenterParent"
    $editor.Size = New-Object Drawing.Size(980, 700)
    $editor.MinimumSize = New-Object Drawing.Size(780, 560)
    $editor.Font = $form.Font
    $editor.BackColor = $theme.Canvas
    $editor.Padding = New-Object Windows.Forms.Padding(18)
    $note = New-Object System.Windows.Forms.Label
    $note.Dock = "Top"
    $note.Height = 86
    $note.Padding = New-Object Windows.Forms.Padding(16, 12, 16, 10)
    $note.BackColor = $theme.PurpleSoft
    $note.ForeColor = $theme.Purple
    $note.Font = New-Object Drawing.Font("Segoe UI", 9.5)
    $source = @($entries | Where-Object { $_.Kind -eq "value" -and $_.Key -eq "ENV_SOURCE" } | Select-Object -First 1)
    $ssmNote = ""
    if ($source.Count -eq 1 -and $source[0].Value -match '^ssm(\s|$)') {
        $ssmNote = " ENV_SOURCE is ssm, so the next deploy refreshes this file from Parameter Store and can replace this edit."
    }
    $note.Text = "This edits /opt/prabhix/deploy/.env.prod on the server. A timestamped backup is created before it is replaced. Running containers keep their current environment until the next deploy. Hidden secret values stay unchanged when left blank.$ssmNote"
    $editor.Controls.Add($note)

    $envGrid = New-Object System.Windows.Forms.DataGridView
    $envGrid.Dock = "Fill"
    $envGrid.AllowUserToAddRows = $false
    $envGrid.AllowUserToDeleteRows = $false
    $envGrid.AllowUserToResizeRows = $false
    $envGrid.AutoGenerateColumns = $false
    $envGrid.RowHeadersVisible = $false
    $envGrid.SelectionMode = "FullRowSelect"
    $envGrid.BackgroundColor = $theme.Surface
    $envGrid.BorderStyle = "None"
    $envGrid.CellBorderStyle = "SingleHorizontal"
    $envGrid.GridColor = $theme.Border
    $envGrid.EnableHeadersVisualStyles = $false
    $envGrid.ColumnHeadersBorderStyle = "None"
    $envGrid.ColumnHeadersHeight = 42
    $envGrid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.ColorTranslator]::FromHtml("#F9FAFB")
    $envGrid.ColumnHeadersDefaultCellStyle.ForeColor = $theme.Muted
    $envGrid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font("Segoe UI Semibold", 8.5)
    $envGrid.DefaultCellStyle.SelectionBackColor = [Drawing.ColorTranslator]::FromHtml("#EFF4FF")
    $envGrid.DefaultCellStyle.SelectionForeColor = $theme.Navy
    $envGrid.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(8, 0, 8, 0)
    $envGrid.RowTemplate.Height = 38
    $envPick = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $envPick.Name = "Pick"
    $envPick.HeaderText = "ALL"
    $envPick.Width = 52
    $envPick.ToolTipText = "Select all settings"
    $keyColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $keyColumn.Name = "Key"
    $keyColumn.HeaderText = "SETTING"
    $keyColumn.Width = 300
    $keyColumn.ReadOnly = $true
    $valueColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $valueColumn.Name = "Value"
    $valueColumn.HeaderText = "VALUE"
    $valueColumn.AutoSizeMode = "Fill"
    [void]$envGrid.Columns.Add($envPick)
    [void]$envGrid.Columns.Add($keyColumn)
    [void]$envGrid.Columns.Add($valueColumn)

    foreach ($entry in $entries) {
        if ($entry.Kind -ne "value") { continue }
        $shown = if ($entry.Secret) { "" } else { $entry.Value }
        $index = $envGrid.Rows.Add($true, $entry.Key, $shown)
        $envGrid.Rows[$index].Tag = $entry
        if ($entry.Secret) {
            $envGrid.Rows[$index].Cells["Value"].ToolTipText = "Hidden. Leave blank to keep the current value."
            $envGrid.Rows[$index].DefaultCellStyle.BackColor = $theme.PurpleSoft
            $envGrid.Rows[$index].Cells["Key"].Style.ForeColor = $theme.Purple
        }
        $envGrid.Rows[$index].Cells["Key"].Style.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
    }

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = "Bottom"
    $buttons.Height = 58
    $buttons.FlowDirection = "RightToLeft"
    $buttons.Padding = New-Object Windows.Forms.Padding(8, 10, 8, 6)
    $buttons.BackColor = $theme.Surface
    $save = New-Button "Save backup and update" 190 $theme.Primary ([Drawing.Color]::White)
    $addSetting = New-Button "Add setting" 125
    $showSecrets = New-Object System.Windows.Forms.CheckBox
    $showSecrets.Text = "Show secrets"
    $showSecrets.AutoSize = $true
    $showSecrets.ForeColor = $theme.Muted
    $showSecrets.Margin = New-Object Windows.Forms.Padding(12, 10, 14, 0)
    $selectAllEnv = New-Object System.Windows.Forms.CheckBox
    $selectAllEnv.Text = "Select all"
    $selectAllEnv.Checked = $true
    $selectAllEnv.AutoSize = $true
    $selectAllEnv.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
    $selectAllEnv.ForeColor = $theme.Navy
    $selectAllEnv.Margin = New-Object Windows.Forms.Padding(12, 10, 8, 0)
    $buttons.Controls.Add($save)
    $buttons.Controls.Add($addSetting)
    $buttons.Controls.Add($showSecrets)
    $buttons.Controls.Add($selectAllEnv)
    Connect-SelectAll $selectAllEnv $envGrid "Pick"
    $editor.Controls.Add($buttons)
    $editor.Controls.Add($envGrid)

    $addSetting.Add_Click({
        $name = Show-TextPrompt "Enter a name such as FEATURE_FLAG." "Add environment setting" ""
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $name = $name.Trim()
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            [Windows.Forms.MessageBox]::Show("Use a name such as FEATURE_FLAG.", "Add setting", "OK", "Warning") | Out-Null
            return
        }
        if (@($entries | Where-Object { $_.Kind -eq "value" -and $_.Key -eq $name })) {
            [Windows.Forms.MessageBox]::Show("$name is already in the file.", "Add setting", "OK", "Warning") | Out-Null
            return
        }
        $value = Show-TextPrompt "Value for ${name}:" "Add environment setting" ""
        $entry = [pscustomobject]@{ Kind = "value"; Key = $name; Value = $value; Secret = (Test-SecretEnvName $name); Line = 0 }
        $entries.Add($entry)
        $index = $envGrid.Rows.Add($true, $name, $value)
        $envGrid.Rows[$index].Tag = $entry
    })

    $showSecrets.Add_CheckedChanged({
        foreach ($row in $envGrid.Rows) {
            $entry = $row.Tag
            if (-not $entry.Secret) { continue }
            $current = [string]$row.Cells["Value"].Value
            if ($showSecrets.Checked) {
                if ([string]::IsNullOrEmpty($current)) { $row.Cells["Value"].Value = $entry.Value }
            } elseif ($current -eq $entry.Value) {
                $row.Cells["Value"].Value = ""
            }
        }
    })

    $save.Add_Click({
        $envGrid.EndEdit()
        if (@($envGrid.Rows | Where-Object { $_.Cells["Pick"].Value -eq $true }).Count -eq 0) {
            [Windows.Forms.MessageBox]::Show("Select at least one setting to update.", "Production env", "OK", "Information") | Out-Null
            return
        }
        $updated = foreach ($entry in $entries) {
            if ($entry.Kind -eq "raw") { $entry; continue }
            $row = @($envGrid.Rows | Where-Object { $_.Cells["Key"].Value -eq $entry.Key }) | Select-Object -First 1
            $typed = [string]$row.Cells["Value"].Value
            $value = if ($row.Cells["Pick"].Value -ne $true -or ($entry.Secret -and [string]::IsNullOrEmpty($typed))) {
                $entry.Value
            } else {
                $typed
            }
            [pscustomobject]@{ Kind = "value"; Key = $entry.Key; Value = $value; Secret = $entry.Secret }
        }
        try {
            $content = ConvertFrom-EnvEntries $updated
        } catch {
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Production env", "OK", "Error") | Out-Null
            return
        }
        $word = Show-TextPrompt `
            -Message "A backup will be created, then the production environment file will be replaced.`r`n`r`nType UPDATE ENV to continue:" `
            -Title "Confirm environment update" `
            -Default ""
        if ($word -cne "UPDATE ENV") {
            Add-Log "Production environment update cancelled."
            return
        }
        $editor.UseWaitCursor = $true
        try {
            $backup = Set-ProductionEnvFile -Content $content
            Add-Log "Production environment updated. Backup: $backup"
            [Windows.Forms.MessageBox]::Show(
                "Updated the production environment file.`r`nBackup: $backup`r`n`r`nRestart or deploy a service before a running container sees the change.",
                "Production env", "OK", "Information"
            ) | Out-Null
            $editor.Close()
        } catch {
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Production env update failed", "OK", "Error") | Out-Null
            Add-Log "Production environment update failed."
        } finally {
            $editor.UseWaitCursor = $false
        }
    })

    [void]$editor.ShowDialog($form)
}

$envButton.Add_Click({ Show-ProductionEnvEditor })

$logButton.Add_Click({
    if (-not (Test-Path $script:dashboardLog)) { Write-DashboardLog "Log file created." }
    Start-Process $script:dashboardLog
})

Write-DashboardLog "Dashboard opened."
$form.Add_Shown({ Refresh-Grid })
[void]$form.ShowDialog()

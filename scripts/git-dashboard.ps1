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

function Connect-SelectAll {
    param(
        [System.Windows.Forms.CheckBox]$CheckBox,
        [System.Windows.Forms.DataGridView]$Grid,
        [string]$Column
    )
    $state = [pscustomobject]@{ Ignore = $false }
    $CheckBox.Add_CheckedChanged({
        if ($state.Ignore) { return }
        foreach ($row in @($Grid.Rows)) {
            if ($row.IsNewRow) { continue }
            $row.Cells[$Column].Value = $CheckBox.Checked
        }
    }.GetNewClosure())
    $Grid.Add_CurrentCellDirtyStateChanged({
        if ($Grid.IsCurrentCellDirty) {
            [void]$Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }.GetNewClosure())
    $Grid.Add_CellValueChanged({
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
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Deploy AWS production"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object Drawing.Size(760, 560)
    $dialog.MinimumSize = New-Object Drawing.Size(640, 460)
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
    $promptHint.Text = "Select one or more services and enter an immutable image tag for each."
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
    $deployGrid.Size = New-Object Drawing.Size(724, 380)
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
    $serviceColumn.Width = 220
    $tagColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $tagColumn.Name = "Tag"
    $tagColumn.HeaderText = "IMMUTABLE TAG"
    $tagColumn.AutoSizeMode = "Fill"
    $deployGrid.Columns.AddRange(@($pick, $serviceColumn, $tagColumn))
    foreach ($service in $services) { [void]$deployGrid.Rows.Add($false, $service, "") }
    $dialog.Controls.Add($deployGrid)
    Connect-SelectAll $selectAll $deployGrid "Pick"

    $deploy = New-Button "Deploy selected" 140 $theme.Purple ([Drawing.Color]::White)
    $deploy.Anchor = "Bottom,Right"
    $deploy.Location = New-Object Drawing.Point(602, 512)
    $cancel = New-Button "Cancel" 90
    $cancel.Anchor = "Bottom,Right"
    $cancel.Location = New-Object Drawing.Point(500, 512)
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
        $dialog.Tag = $chosen
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
    })

    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return @() }
    return @($dialog.Tag)
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
$awsButton = New-Button "AWS status" 120
$deployButton = New-Button "Deploy" 105 $theme.Purple ([Drawing.Color]::White)
$cleanupButton = New-Button "Clean ECR" 105
$envButton = New-Button "Environment" 130
$gitActions.Flow.Controls.AddRange(@($refreshButton, $fetchButton, $ciButton, $diffButton, $pushButton))
$productionActions.Flow.Controls.AddRange(@($awsButton, $deployButton, $envButton, $cleanupButton))

$tooltips = New-Object System.Windows.Forms.ToolTip
$tooltips.AutoPopDelay = 9000
$tooltips.InitialDelay = 350
$tooltips.SetToolTip($refreshButton, "Refresh local branch, working tree and ahead/behind status.")
$tooltips.SetToolTip($fetchButton, "Fetch every remote without merging or changing local files.")
$tooltips.SetToolTip($ciButton, "Read the latest GitHub Actions result for each current commit.")
$tooltips.SetToolTip($diffButton, "Show the selected repository's unstaged changes.")
$tooltips.SetToolTip($pushButton, "Preview and push every ahead repository in safe dependency waves.")
$tooltips.SetToolTip($awsButton, "Compare local commits, ECR images and production pins.")
$tooltips.SetToolTip($deployButton, "Deploy one immutable image tag to production.")
$tooltips.SetToolTip($envButton, "Safely view and update the production environment file.")
$tooltips.SetToolTip($cleanupButton, "Preview protected ECR retention before deleting anything.")

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

function Add-Log {
    param([string]$Message)
    $log.AppendText("[$(Get-Date -Format HH:mm:ss)] $Message`r`n")
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
}

function Format-ProcessArgument {
    param([string]$Value)
    if ($Value -match '[\s"]') { '"' + ($Value -replace '"', '\"') + '"' } else { $Value }
}

$script:outputQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:activeTask = $null
$script:refreshAfterTask = $false
$script:pendingTasks = New-Object System.Collections.Generic.Queue[object]
$outputTimer = New-Object System.Windows.Forms.Timer
$outputTimer.Interval = 200
$outputTimer.Add_Tick({
    $line = ""
    while ($script:outputQueue.TryDequeue([ref]$line)) {
        $log.AppendText("$line`r`n")
    }
    if ($line) {
        $log.SelectionStart = $log.TextLength
        $log.ScrollToCaret()
    }
    $pumpsDone = $true
    foreach ($pump in @($script:outputPumps)) {
        if ($pump -and -not $pump.Handle.IsCompleted) { $pumpsDone = $false }
    }
    if ($script:activeTask -and $script:activeTask.HasExited -and $pumpsDone -and $script:refreshAfterTask) {
        $exitCode = $script:activeTask.ExitCode
        Add-Log "Finished with exit code $exitCode."
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
$form.Add_FormClosed({ $outputTimer.Stop() })

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
        $refreshButton, $fetchButton, $ciButton, $diffButton, $pushButton,
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
    $chosen = @(Show-DeploySelection)
    if ($chosen.Count -eq 0) { return }
    $summary = ($chosen | ForEach-Object { "$($_.Service) @ $($_.Tag)" }) -join "`r`n"
    $word = Show-TextPrompt `
        -Message "This changes production and may run database migrations.`r`n`r`n$summary`r`n`r`nType DEPLOY to continue:" `
        -Title "Confirm production deploy" `
        -Default ""
    if ($word -cne "DEPLOY") {
        Add-Log "Production deploy cancelled."
        return
    }

    $script:pendingTasks.Clear()
    foreach ($item in @($chosen | Select-Object -Skip 1)) {
        $script:pendingTasks.Enqueue([pscustomobject]@{
            ScriptPath = $deployScript
            Arguments = @("-Service", $item.Service, "-Tag", $item.Tag, "-Confirm")
            Label = "Deploying $($item.Service) at $($item.Tag). Progress appears below."
        })
    }
    $first = $chosen[0]
    Start-DashboardTask -ScriptPath $deployScript -ScriptArguments @(
        "-Service", $first.Service, "-Tag", $first.Tag, "-Confirm"
    ) -Label "Deploying $($first.Service) at $($first.Tag). Progress appears below."
})

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
    $envGrid.Columns.AddRange(@($envPick, $keyColumn, $valueColumn))

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

$form.Add_Shown({ Refresh-Grid })
[void]$form.ShowDialog()

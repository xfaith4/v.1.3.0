#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Module Imports and State
# Import other application modules (paths are relative to this script's directory)
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

Import-Module (Join-Path $scriptRoot 'App.Auth.psm1')       -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'App.CoreAdapter.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'App.Index.psm1')       -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'App.Export.psm1')      -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'App.Reporting.psm1')   -Force -ErrorAction Stop

# Application state container
$script:State = [PSCustomObject]@{
    Window          = $null
    Controls        = @{}
    AuthContext     = $null
    CurrentRun      = $null        # Holds info about the active or loaded run
    CurrentRunJob   = $null
    JobStatePoller  = $null
    RunMonitorTimer = $null
    PageIndex       = 0
    PageSize        = 50
    RunIndex        = @()
    FilteredIndex   = @()
    RunDataView     = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    IsOffline       = ($env:APP_OFFLINE -eq '1')
}
#endregion

#region UI Initialization

function Show-ConversationAnalysisWindow {
    # ── Load XAML ────────────────────────────────────────────────────────────
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

        $xamlPath = Join-Path $scriptRoot 'MainWindow.xaml'
        if (-not [System.IO.File]::Exists($xamlPath)) {
            throw "MainWindow.xaml not found at: $xamlPath"
        }

        # Strip x:Class so WPF does not look for a compiled backing class
        $xamlContent = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
        $xamlContent = $xamlContent -replace 'x:Class="[^"]*"', ''

        $reader = New-Object System.IO.StringReader($xamlContent)
        $xmlReader = [System.Xml.XmlReader]::Create($reader)
        try {
            $script:State.Window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
        } finally {
            $xmlReader.Dispose()
            $reader.Dispose()
        }
    } catch {
        [System.Windows.MessageBox]::Show(
            "Failed to load MainWindow.xaml:`n$($_.Exception.Message)",
            'Genesys Conversation Analysis - Fatal Error', 'OK', 'Error')
        return
    }

    # ── Map named controls via logical tree traversal ─────────────────────────
    _MapNamedControls $script:State.Window

    # ── Wire event handlers ───────────────────────────────────────────────────
    Register-EventHandlers

    # ── Initialize application state ──────────────────────────────────────────
    Initialize-Application

    # ── Show window ───────────────────────────────────────────────────────────
    $null = $script:State.Window.ShowDialog()
}

function _MapNamedControls {
    param([System.Windows.DependencyObject]$root)
    # Recursively walk the logical tree and collect all FrameworkElements with a Name.
    $queue = New-Object System.Collections.Generic.Queue[System.Windows.DependencyObject]
    $queue.Enqueue($root)
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        if ($node -is [System.Windows.FrameworkElement] -and -not [string]::IsNullOrEmpty($node.Name)) {
            $script:State.Controls[$node.Name] = $node
        }
        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
            if ($child -is [System.Windows.DependencyObject]) {
                $queue.Enqueue($child)
            }
        }
    }
}

function Register-EventHandlers {
    $c = $script:State.Controls

    # Header
    if ($c.ContainsKey('BtnConnect'))       { $c.BtnConnect.add_Click({ Handle-ConnectClick }) }
    if ($c.ContainsKey('BtnSettings'))      { $c.BtnSettings.add_Click({ Handle-SettingsClick }) }

    # Run Configuration
    if ($c.ContainsKey('BtnPreviewRun'))    { $c.BtnPreviewRun.add_Click({ Handle-RunClick -IsPreview $true }) }
    if ($c.ContainsKey('BtnRun'))           { $c.BtnRun.add_Click({ Handle-RunClick -IsPreview $false }) }
    if ($c.ContainsKey('BtnCancelRun'))     { $c.BtnCancelRun.add_Click({ Handle-CancelRunClick }) }
    if ($c.ContainsKey('BtnOpenRun'))       { $c.BtnOpenRun.add_Click({ Handle-OpenRunClick }) }

    # Conversations Tab
    if ($c.ContainsKey('BtnSearch'))        { $c.BtnSearch.add_Click({ Handle-SearchClick }) }
    if ($c.ContainsKey('CmbFilterDirection')) { $c.CmbFilterDirection.add_SelectionChanged({ Handle-SearchClick }) }
    if ($c.ContainsKey('CmbFilterMedia'))     { $c.CmbFilterMedia.add_SelectionChanged({ Handle-SearchClick }) }
    if ($c.ContainsKey('BtnPrevPage'))      { $c.BtnPrevPage.add_Click({ Handle-PagingClick -Direction 'Prev' }) }
    if ($c.ContainsKey('BtnNextPage'))      { $c.BtnNextPage.add_Click({ Handle-PagingClick -Direction 'Next' }) }
    if ($c.ContainsKey('BtnExportPageCsv')) { $c.BtnExportPageCsv.add_Click({ Handle-ExportClick -Scope 'Page' }) }
    if ($c.ContainsKey('BtnExportRunCsv'))  { $c.BtnExportRunCsv.add_Click({ Handle-ExportClick -Scope 'Run' }) }
    if ($c.ContainsKey('DgConversations'))  { $c.DgConversations.add_SelectionChanged({ Handle-ConversationSelectionChanged }) }

    # Drilldown Tab
    if ($c.ContainsKey('BtnGenerateReport')) { $c.BtnGenerateReport.add_Click({ Handle-GenerateReportClick }) }
    if ($c.ContainsKey('BtnExpandJson'))     { $c.BtnExpandJson.add_Click({ Handle-ExpandJsonClick }) }

    # Run Console Tab
    if ($c.ContainsKey('BtnCopyDiagnostics')) { $c.BtnCopyDiagnostics.add_Click({ Handle-CopyDiagnosticsClick }) }
}

function Initialize-Application {
    $c = $script:State.Controls

    # Set default date range
    if ($c.ContainsKey('DtpStartDate')) { $c.DtpStartDate.SelectedDate = (Get-Date).Date.AddDays(-1) }
    if ($c.ContainsKey('DtpEndDate'))   { $c.DtpEndDate.SelectedDate   = (Get-Date).Date }

    # Bind the DataGrid to the observable collection
    if ($c.ContainsKey('DgConversations')) {
        $c.DgConversations.ItemsSource = $script:State.RunDataView
    }

    # Initialize Core Adapter (Gate A) — skip in offline mode
    if ($script:State.IsOffline) {
        Update-Status '[Offline] Running in demo mode. Connect and Run features are disabled.'
        if ($c.ContainsKey('BtnRun'))        { $c.BtnRun.IsEnabled        = $false }
        if ($c.ContainsKey('BtnPreviewRun')) { $c.BtnPreviewRun.IsEnabled = $false }
        if ($c.ContainsKey('BtnConnect'))    { $c.BtnConnect.IsEnabled    = $false }
        return
    }

    if ([string]::IsNullOrWhiteSpace($env:GENESYS_CORE_MODULE_PATH)) {
        Update-Status 'Warning: GENESYS_CORE_MODULE_PATH not set. Run features disabled until resolved.'
        if ($c.ContainsKey('BtnRun'))        { $c.BtnRun.IsEnabled        = $false }
        if ($c.ContainsKey('BtnPreviewRun')) { $c.BtnPreviewRun.IsEnabled = $false }
    } else {
        try {
            # Derive catalog/schema paths from the module path.
            # Expected layout: <CoreRoot>/modules/Genesys.Core/Genesys.Core.psd1
            # Catalog at:      <CoreRoot>/catalog/...
            $moduleFile = (Resolve-Path $env:GENESYS_CORE_MODULE_PATH -ErrorAction Stop).Path
            $moduleDir  = Split-Path -Parent $moduleFile   # .../modules/Genesys.Core
            $modulesDir = Split-Path -Parent $moduleDir    # .../modules
            $coreRoot   = Split-Path -Parent $modulesDir   # <CoreRoot>

            # Check env var overrides first, then derive
            $catalogPath = if ($env:GENESYS_CORE_CATALOG_PATH) {
                $env:GENESYS_CORE_CATALOG_PATH
            } else {
                Join-Path $coreRoot 'catalog\genesys.catalog.json'
            }
            $schemaPath = if ($env:GENESYS_CORE_SCHEMA_PATH) {
                $env:GENESYS_CORE_SCHEMA_PATH
            } else {
                Join-Path $coreRoot 'catalog\schema\genesys.catalog.schema.json'
            }

            Initialize-CoreAdapter -CatalogPath $catalogPath -SchemaPath $schemaPath
            Update-Status 'Ready. Core engine initialized.'
        } catch {
            $msg = "Could not initialize Genesys.Core.`n`n$($_.Exception.Message)`n`nRun ./scripts/Invoke-Smoke.ps1 -Verbose for diagnostics."
            Update-Status "Warning: Core init failed. $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($msg, 'Genesys Conversation Analysis - Warning', 'OK', 'Warning')
            # Non-fatal: UI still opens; user can fix paths via app settings or env vars.
        }
    }

    # Setup job state poller
    $script:State.JobStatePoller = [System.Windows.Threading.DispatcherTimer]::new()
    $script:State.JobStatePoller.Interval = [TimeSpan]::FromSeconds(1)
    $script:State.JobStatePoller.add_Tick({ Check-JobState })

    # Setup run artifact monitor
    $script:State.RunMonitorTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:State.RunMonitorTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:State.RunMonitorTimer.add_Tick({ Update-ProgressFromArtifacts })
}
#endregion

#region Event Handlers

function Handle-ConnectClick {
    Update-Status 'Connecting...'
    $c = $script:State.Controls
    if ($c.ContainsKey('BtnConnect')) { $c.BtnConnect.IsEnabled = $false }

    try {
        $authMode = if ($env:GENESYS_AUTH_MODE) { $env:GENESYS_AUTH_MODE.ToLower() } else { 'client_credentials' }
        $region   = if ($env:GENESYS_REGION) { $env:GENESYS_REGION } else { 'usw2.pure.cloud' }

        switch ($authMode) {
            'client_credentials' {
                $clientId     = $env:GENESYS_CLIENT_ID
                $clientSecret = $env:GENESYS_CLIENT_SECRET
                if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
                    throw @"
GENESYS_CLIENT_ID and GENESYS_CLIENT_SECRET must be set before connecting.

Set them in your PowerShell session:
  `$env:GENESYS_CLIENT_ID     = '<your-oauth-client-id>'
  `$env:GENESYS_CLIENT_SECRET = '<your-oauth-client-secret>'
  `$env:GENESYS_REGION        = 'usw2.pure.cloud'

Then restart the app or re-click Connect.
"@
                }
                $script:State.AuthContext = Connect-App -ClientId $clientId -ClientSecret $clientSecret -Region $region
            }
            'bearer' {
                # Connect-App reads GENESYS_BEARER_TOKEN internally for bearer mode.
                $script:State.AuthContext = Connect-App -Region $region
            }
            default {
                # Delegate to Connect-App; it will throw an informative error for unknown modes.
                $script:State.AuthContext = Connect-App -ClientId $env:GENESYS_CLIENT_ID -ClientSecret $env:GENESYS_CLIENT_SECRET -Region $region
            }
        }

        $displayMode = $authMode.ToUpper()
        if ($c.ContainsKey('ElpConnStatus'))      { $c.ElpConnStatus.Fill      = [System.Windows.Media.Brushes]::LightGreen }
        if ($c.ContainsKey('LblConnectionStatus')) { $c.LblConnectionStatus.Text = "Connected  |  $region  |  $displayMode" }
        Update-Status "Connected to $region ($displayMode)"
    } catch {
        if ($c.ContainsKey('ElpConnStatus'))       { $c.ElpConnStatus.Fill      = [System.Windows.Media.Brushes]::Salmon }
        if ($c.ContainsKey('LblConnectionStatus')) { $c.LblConnectionStatus.Text = 'Connection failed' }
        Update-Status "Connection failed: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Connection Error', 'OK', 'Warning')
    } finally {
        if ($c.ContainsKey('BtnConnect')) { $c.BtnConnect.IsEnabled = $true }
    }
}

function Handle-RunClick($IsPreview) {
    # Guard: offline mode and connection state checked together for clarity.
    if ($script:State.IsOffline) {
        [System.Windows.MessageBox]::Show(
            'The app is running in offline mode. Run features are disabled.',
            'Offline Mode', 'OK', 'Information')
        return
    }
    if (-not $script:State.AuthContext) {
        [System.Windows.MessageBox]::Show(
            'Please connect to Genesys Cloud first (click Connect).',
            'Not Connected', 'OK', 'Information')
        return
    }

    $c = $script:State.Controls

    # Validate date selection before accessing .Value (SelectedDate is Nullable<DateTime>)
    if (-not $c.ContainsKey('DtpStartDate') -or -not $c.DtpStartDate.SelectedDate.HasValue) {
        [System.Windows.MessageBox]::Show('Please select a start date.', 'Date Required', 'OK', 'Warning')
        return
    }
    if (-not $c.ContainsKey('DtpEndDate') -or -not $c.DtpEndDate.SelectedDate.HasValue) {
        [System.Windows.MessageBox]::Show('Please select an end date.', 'Date Required', 'OK', 'Warning')
        return
    }

    $start = $c.DtpStartDate.SelectedDate.Value.ToUniversalTime()
    $end   = $c.DtpEndDate.SelectedDate.Value.ToUniversalTime()

    if ($end -le $start) {
        [System.Windows.MessageBox]::Show(
            'End date must be after start date.',
            'Invalid Date Range', 'OK', 'Warning')
        return
    }

    $interval = "{0:s}Z/{1:s}Z" -f $start, $end

    # Choose the correct dataset key based on whether this is a preview or full run.
    $datasetKey = if ($IsPreview) { 'analytics-conversation-details-query' } else { 'analytics-conversation-details' }

    # Build filters from UI controls
    $segmentFilters     = [System.Collections.Generic.List[object]]::new()
    $conversationFilters = [System.Collections.Generic.List[object]]::new()

    if ($c.ContainsKey('TxtQueue') -and -not [string]::IsNullOrWhiteSpace($c.TxtQueue.Text)) {
        $segmentFilters.Add(@{
            type = 'or'
            predicates = @(@{ dimension = 'queueId'; value = $c.TxtQueue.Text })
        })
    }
    if ($c.ContainsKey('CmbDirection') -and $c.CmbDirection.SelectedItem -and
        $c.CmbDirection.SelectedItem.Content -ne '(all)') {
        $conversationFilters.Add(@{
            type = 'or'
            predicates = @(@{ dimension = 'direction'; value = $c.CmbDirection.SelectedItem.Content })
        })
    }
    if ($c.ContainsKey('CmbMediaType') -and $c.CmbMediaType.SelectedItem -and
        $c.CmbMediaType.SelectedItem.Content -ne '(all)') {
        $conversationFilters.Add(@{
            type = 'or'
            predicates = @(@{ dimension = 'mediaType'; value = $c.CmbMediaType.SelectedItem.Content })
        })
    }

    $datasetParams = @{
        interval            = $interval
        segmentFilters      = $segmentFilters.ToArray()
        conversationFilters = $conversationFilters.ToArray()
    }
    if ($IsPreview -and $c.ContainsKey('TxtPreviewPageSize') -and
        $c.TxtPreviewPageSize.Text -match '^\d+$') {
        $datasetParams.paging = @{ pageSize = [int]$c.TxtPreviewPageSize.Text }
    }

    $outputRoot = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'GenesysConversationAnalysis', 'runs')
    if (-not (Test-Path $outputRoot)) { $null = New-Item -Path $outputRoot -ItemType Directory -Force }

    # Start the extraction job (Gate B)
    try {
        $script:State.CurrentRunJob = Start-CoreExtraction `
            -DatasetKey        $datasetKey `
            -AuthContext       $script:State.AuthContext `
            -OutputRoot        $outputRoot `
            -DatasetParameters $datasetParams

        Set-RunInProgressState $true
        $script:State.JobStatePoller.Start()
        $script:State.RunMonitorTimer.Start()
        if ($c.ContainsKey('TabWorkspace')) { $c.TabWorkspace.SelectedIndex = 2 }
        Update-Status "Starting run for dataset '$datasetKey'..."
    } catch {
        Update-Status "Failed to start run: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Run Error', 'OK', 'Error')
    }
}

function Handle-CancelRunClick {
    if ($script:State.CurrentRunJob) {
        Update-Status 'Cancelling run...'
        Stop-Job -Job $script:State.CurrentRunJob -ErrorAction SilentlyContinue
    }
}

function Handle-OpenRunClick {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description        = 'Select a Genesys.Core run folder'
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -eq 'OK') {
        Load-Run -RunFolder $dialog.SelectedPath
    }
}

function Handle-SearchClick {
    $c          = $script:State.Controls
    $searchText = if ($c.ContainsKey('TxtSearch')) { $c.TxtSearch.Text } else { '' }

    # Read post-extraction filter values from the Conversations toolbar combos.
    $filterDirection = ''
    if ($c.ContainsKey('CmbFilterDirection') -and $c.CmbFilterDirection.SelectedItem) {
        $sel = $c.CmbFilterDirection.SelectedItem.Content
        if ($sel -ne 'All directions') { $filterDirection = $sel }
    }
    $filterMedia = ''
    if ($c.ContainsKey('CmbFilterMedia') -and $c.CmbFilterMedia.SelectedItem) {
        $sel = $c.CmbFilterMedia.SelectedItem.Content
        if ($sel -ne 'All media') { $filterMedia = $sel }
    }

    $filtered = @($script:State.RunIndex)

    if (-not [string]::IsNullOrWhiteSpace($searchText)) {
        $lo = $searchText.ToLowerInvariant()
        $filtered = @($filtered | Where-Object { $_.ConversationId -like "*$lo*" })
    }
    if (-not [string]::IsNullOrWhiteSpace($filterDirection)) {
        $filtered = @($filtered | Where-Object { $_.Direction -eq $filterDirection })
    }
    if (-not [string]::IsNullOrWhiteSpace($filterMedia)) {
        $filtered = @($filtered | Where-Object { $_.MediaType -eq $filterMedia })
    }

    $script:State.FilteredIndex = $filtered

    $hasFilter = (-not [string]::IsNullOrWhiteSpace($searchText)) -or
                 (-not [string]::IsNullOrWhiteSpace($filterDirection)) -or
                 (-not [string]::IsNullOrWhiteSpace($filterMedia))
    if ($hasFilter) {
        Update-Status "Found $($script:State.FilteredIndex.Count) matches."
    } else {
        Update-Status 'Filters cleared.'
    }
    Load-ConversationPage -PageIndex 0
}

function Handle-ExportClick($Scope) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.SaveFileDialog]::new()
    $dialog.Filter   = 'CSV Files (*.csv)|*.csv'
    $dialog.FileName = "export_${Scope}_$(Get-Date -Format 'yyyyMMdd-HHmm').csv"

    if ($dialog.ShowDialog() -eq 'OK') {
        Update-Status "Exporting $Scope to $($dialog.FileName)..."
        try {
            if ($Scope -eq 'Page') {
                $script:State.RunDataView | Export-Csv -Path $dialog.FileName -NoTypeInformation
            } elseif ($Scope -eq 'Run') {
                if (-not $script:State.CurrentRun) { throw 'No run loaded. Open a run folder first.' }
                Export-RunToCsv -RunFolder $script:State.CurrentRun.runFolder -OutputPath $dialog.FileName
            }
            Update-Status 'Export complete.'
        } catch {
            Update-Status "Export failed: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Export Error', 'OK', 'Error')
        }
    }
}

function Handle-GenerateReportClick {
    Update-Status 'Generating impact report...'
    try {
        $searchText = ''
        if ($script:State.Controls.ContainsKey('TxtSearch')) { $searchText = $script:State.Controls.TxtSearch.Text }
        $report = New-ImpactReport -FilteredIndex $script:State.FilteredIndex -ReportTitle "Impact Report: $searchText"
        if ($script:State.Controls.ContainsKey('TxtDrillSummary')) {
            $script:State.Controls.TxtDrillSummary.Text = $report | ConvertTo-Json -Depth 8
        }
        Update-Status 'Impact report generated.'
    } catch {
        Update-Status "Failed to generate report: $($_.Exception.Message)"
    }
}

function Handle-SettingsClick {
    $cfg = Get-AppConfig
    $msg = @"
Current Application Settings
─────────────────────────────────────────
  Output Root   : $($cfg.OutputRoot)
  Core Module   : $(if ($env:GENESYS_CORE_MODULE_PATH) { $env:GENESYS_CORE_MODULE_PATH } else { '(not set)' })
  Auth Module   : $(if ($env:GENESYS_AUTH_MODULE_PATH) { $env:GENESYS_AUTH_MODULE_PATH } else { '(not set)' })
  Auth Mode     : $(if ($env:GENESYS_AUTH_MODE) { $env:GENESYS_AUTH_MODE } else { 'client_credentials (default)' })
  Region        : $(if ($env:GENESYS_REGION) { $env:GENESYS_REGION } else { 'usw2.pure.cloud (default)' })
  Page Size     : $($script:State.PageSize)
  Offline Mode  : $($script:State.IsOffline)

To change settings update environment variables or create appsettings.json.
Run ./scripts/Invoke-Smoke.ps1 -Verbose for full diagnostics.
"@
    [System.Windows.MessageBox]::Show($msg, 'Settings', 'OK', 'Information')
}

function Handle-CopyDiagnosticsClick {
    $c        = $script:State.Controls
    $diagText = if ($c.ContainsKey('TxtDiagnostics')) { $c.TxtDiagnostics.Text } else { '' }
    $progress = if ($c.ContainsKey('TxtRunProgress'))  { $c.TxtRunProgress.Text } else { '' }
    $connected = if ($script:State.AuthContext) { 'Yes' } else { 'No' }
    $text = @"
=== Diagnostics Snapshot ===
Core Module  : $(if ($env:GENESYS_CORE_MODULE_PATH) { $env:GENESYS_CORE_MODULE_PATH } else { '(not set)' })
Auth Module  : $(if ($env:GENESYS_AUTH_MODULE_PATH) { $env:GENESYS_AUTH_MODULE_PATH } else { '(not set)' })
Auth Mode    : $(if ($env:GENESYS_AUTH_MODE) { $env:GENESYS_AUTH_MODE } else { 'client_credentials' })
Region       : $(if ($env:GENESYS_REGION) { $env:GENESYS_REGION } else { '(not set)' })
Connected    : $connected
Run Progress : $progress

$diagText
"@
    try {
        [System.Windows.Clipboard]::SetText($text)
        Update-Status 'Diagnostics copied to clipboard.'
    } catch {
        Update-Status "Could not copy to clipboard: $($_.Exception.Message)"
    }
}

function Handle-ExpandJsonClick {
    $c = $script:State.Controls
    if (-not $c.ContainsKey('TxtRawJson') -or [string]::IsNullOrEmpty($c.TxtRawJson.Text)) {
        Update-Status 'No JSON to copy. Select a conversation first.'
        return
    }
    try {
        [System.Windows.Clipboard]::SetText($c.TxtRawJson.Text)
        Update-Status 'Raw JSON copied to clipboard.'
    } catch {
        Update-Status "Could not copy JSON to clipboard: $($_.Exception.Message)"
    }
}

function Handle-PagingClick($Direction) {
    $newIndex = $script:State.PageIndex
    if ($Direction -eq 'Next') { $newIndex++ }
    if ($Direction -eq 'Prev') { $newIndex-- }
    Load-ConversationPage -PageIndex $newIndex
}

function Handle-ConversationSelectionChanged {
    $c            = $script:State.Controls
    $selectedItem = if ($c.ContainsKey('DgConversations')) { $c.DgConversations.SelectedItem } else { $null }
    if (-not $selectedItem) { return }

    # Gate C: Load full record for drilldown
    $fullRecord = Get-RunRecordById -Index $script:State.RunIndex -ConversationId $selectedItem.ConversationId
    if (-not $fullRecord) { return }

    if ($c.ContainsKey('LblSelectedConversation')) { $c.LblSelectedConversation.Text = $fullRecord.conversationId }
    if ($c.ContainsKey('TabWorkspace'))             { $c.TabWorkspace.SelectedIndex   = 1 }
    if ($c.ContainsKey('TxtRawJson'))               { $c.TxtRawJson.Text              = $fullRecord | ConvertTo-Json -Depth 10 }
    if ($c.ContainsKey('DgParticipants') -and $fullRecord.PSObject.Properties['participants']) {
        $c.DgParticipants.ItemsSource = $fullRecord.participants
    }

    # Flatten segments for grid view
    if ($c.ContainsKey('DgSegments') -and $fullRecord.PSObject.Properties['participants']) {
        $allSegments = [System.Collections.Generic.List[object]]::new()
        foreach ($p in $fullRecord.participants) {
            if (-not $p.PSObject.Properties['sessions']) { continue }
            foreach ($s in $p.sessions) {
                if (-not $s.PSObject.Properties['segments']) { continue }
                foreach ($seg in $s.segments) {
                    # The XAML column {Binding Purpose} expects a 'Purpose' property on each
                    # segment row.  Genesys segments don't carry purpose natively – it lives on
                    # the parent participant – so we promote it here.
                    try { $seg.PSObject.Properties.Add([psnoteproperty]::new('Purpose',         $p.purpose)) } catch { }
                    try { $seg.PSObject.Properties.Add([psnoteproperty]::new('ParticipantName', $p.participantName)) } catch { }
                    $allSegments.Add($seg)
                }
            }
        }
        $c.DgSegments.ItemsSource = $allSegments
    }
}
#endregion

#region Job and Run Monitoring

function Check-JobState {
    $job = $script:State.CurrentRunJob
    if (-not $job) { $script:State.JobStatePoller.Stop(); return }

    $c = $script:State.Controls
    if ($c.ContainsKey('TxtRunStatus')) { $c.TxtRunStatus.Text = "Run status: $($job.State)" }

    if ($job.HasMoreData) {
        $runObject = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue
        if ($runObject -and -not $script:State.CurrentRun) {
            $script:State.CurrentRun = $runObject
        }
    }

    if ($job.State -in 'Completed', 'Failed', 'Stopped') {
        $script:State.JobStatePoller.Stop()
        $script:State.RunMonitorTimer.Stop()
        $finalState = $job.State
        Remove-Job -Job $job -ErrorAction SilentlyContinue
        $script:State.CurrentRunJob = $null
        Set-RunInProgressState $false
        Update-Status "Run finished with status: $finalState."

        if ($finalState -eq 'Completed' -and $script:State.CurrentRun) {
            Load-Run -RunFolder $script:State.CurrentRun.runFolder
        }
    }
}
#endregion

#region UI Helpers

function Update-Status($Message, $Level = 'Info') {
    $c = $script:State.Controls
    if ($c.ContainsKey('TxtStatusMain')) { $c.TxtStatusMain.Text = $Message }
}

function Set-RunInProgressState($IsRunning) {
    $c = $script:State.Controls
    if ($c.ContainsKey('BtnPreviewRun')) { $c.BtnPreviewRun.IsEnabled = -not $IsRunning }
    if ($c.ContainsKey('BtnRun'))        { $c.BtnRun.IsEnabled        = -not $IsRunning }
    if ($c.ContainsKey('BtnCancelRun'))  { $c.BtnCancelRun.IsEnabled  = $IsRunning }
    if ($c.ContainsKey('PrgRun')) {
        $c.PrgRun.IsIndeterminate = $IsRunning
        if (-not $IsRunning) { $c.PrgRun.Value = 0 }
    }
}

function Update-ProgressFromArtifacts {
    if (-not $script:State.CurrentRun) { return }

    $runFolder   = $script:State.CurrentRun.runFolder
    $summaryPath = Join-Path $runFolder 'summary.json'
    $eventsPath  = Join-Path $runFolder 'events.jsonl'
    $c           = $script:State.Controls

    if ((Test-Path $summaryPath) -and $c.ContainsKey('TxtRunProgress')) {
        try {
            $summary = Get-Content -Raw -Path $summaryPath | ConvertFrom-Json
            $c.TxtRunProgress.Text = "Records: $($summary.recordCount)  |  Errors: $($summary.errorCount)  |  Elapsed: $($summary.elapsed)"
            if ($c.ContainsKey('TxtConsoleStatus')) { $c.TxtConsoleStatus.Text = $summary.status }
        } catch { }
    }

    if ((Test-Path $eventsPath) -and $c.ContainsKey('DgRunEvents')) {
        try {
            $events = Get-Content -Path $eventsPath | ConvertFrom-Json
            $c.DgRunEvents.ItemsSource = $events
            if ($events -and $c.DgRunEvents.Items.Count -gt 0) {
                $c.DgRunEvents.ScrollIntoView($events[-1])
            }
        } catch { }
    }
}

function Load-Run {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunFolder)

    Update-Status "Loading run from '$RunFolder'..."
    $script:State.CurrentRun = @{ runFolder = $RunFolder }
    $indexPath = Join-Path $RunFolder 'index.jsonl'

    # Gate C: Build or load the run index
    if (Test-Path $indexPath) {
        Update-Status 'Loading existing index...'
        try {
            $script:State.RunIndex = Get-Content -Raw -Path $indexPath | ConvertFrom-Json
        } catch {
            Update-Status "Index file unreadable; rebuilding. $_"
            $script:State.RunIndex = Build-RunIndex -RunFolder $RunFolder
        }
    } else {
        Update-Status 'No index found. Building index (may take a moment for large runs)...'
        $script:State.Window.Dispatcher.InvokeAsync({
            $script:State.RunIndex    = Build-RunIndex -RunFolder $RunFolder
            $script:State.FilteredIndex = $script:State.RunIndex
            Update-Status "Index built. $($script:State.RunIndex.Count) records."
            Load-ConversationPage -PageIndex 0
        }) | Out-Null
        return
    }

    $script:State.FilteredIndex = $script:State.RunIndex
    Update-Status "Run loaded. $($script:State.RunIndex.Count) records indexed."
    Load-ConversationPage -PageIndex 0
    if ($script:State.Controls.ContainsKey('TabWorkspace')) {
        $script:State.Controls.TabWorkspace.SelectedIndex = 0
    }
}

function Load-ConversationPage {
    [CmdletBinding()]
    param([int]$PageIndex)

    $total = $script:State.FilteredIndex.Count
    $c     = $script:State.Controls

    if ($total -eq 0) {
        $script:State.RunDataView.Clear()
        if ($c.ContainsKey('TxtPageInfo')) { $c.TxtPageInfo.Text = '0 records found' }
        return
    }

    $totalPages = [math]::Ceiling($total / $script:State.PageSize)
    if ($PageIndex -lt 0 -or $PageIndex -ge $totalPages) { return }

    $script:State.PageIndex = $PageIndex
    Update-Status "Loading page $($PageIndex + 1) of $totalPages..."

    $pageData = Get-RunPage -Index $script:State.FilteredIndex -PageIndex $PageIndex -PageSize $script:State.PageSize
    $script:State.RunDataView.Clear()
    foreach ($item in $pageData) { $script:State.RunDataView.Add($item) }

    if ($c.ContainsKey('TxtPageInfo'))  { $c.TxtPageInfo.Text              = "Page $($PageIndex + 1) of $totalPages  |  $total records" }
    if ($c.ContainsKey('BtnPrevPage'))  { $c.BtnPrevPage.IsEnabled          = ($PageIndex -gt 0) }
    if ($c.ContainsKey('BtnNextPage'))  { $c.BtnNextPage.IsEnabled          = ($PageIndex -lt ($totalPages - 1)) }
    Update-Status "Page $($PageIndex + 1) loaded."
}
#endregion

Export-ModuleMember -Function Show-ConversationAnalysisWindow

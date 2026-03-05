#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Module Imports and State
# Import other application modules
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module (Join-Path $scriptRoot 'App.Auth.psm1') -Force
Import-Module (Join-Path $scriptRoot 'App.CoreAdapter.psm1') -Force
Import-Module (Join-Path $scriptRoot 'App.Index.psm1') -Force
Import-Module (Join-Path $scriptRoot 'App.Export.psm1') -Force
Import-Module (Join-Path $scriptRoot 'App.Reporting.psm1') -Force

# Application state container
$script:State = [PSCustomObject]@{
    Window          = $null
    Controls        = @{}
    AuthContext     = $null
    CurrentRun      = $null # Holds info about the active or loaded run
    CurrentRunJob   = $null
    JobStatePoller  = $null
    RunMonitorTimer = $null
    PageIndex       = 0
    PageSize        = 50
    RunIndex        = @()
    FilteredIndex   = @()
    RunDataView     = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
}
#endregion

#region UI Initialization
function Show-ConversationAnalysisWindow {
    # Load XAML and map controls
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $xamlPath = Join-Path $scriptRoot 'MainWindow.xaml'
        $reader = [System.Xml.XmlNodeReader]::new((Get-Content $xamlPath -Raw).psobject.BaseObject)
        $script:State.Window = [System.Windows.Markup.XamlReader]::Load($reader)
    }
    catch {
        [System.Windows.MessageBox]::Show("Failed to load MainWindow.xaml: $($_.Exception.Message)", "Fatal Error", "OK", "Error")
        return
    }

    # Map all named controls from XAML to a hashtable for easy access
    $namedControls = $script:State.Window.Content.FindName('*', $script:State.Window.Content) | ForEach-Object { $_.Name } | Where-Object { $_ }
    foreach ($controlName in $namedControls) {
        $control = $script:State.Window.FindName($controlName)
        if ($control) {
            $script:State.Controls[$controlName] = $control
        }
    }

    # Wire up event handlers
    Register-EventHandlers

    # Initialize application state
    Initialize-Application

    # Show the window
    $null = $script:State.Window.ShowDialog()
}

function Register-EventHandlers {
    # Header
    $script:State.Controls.BtnConnect.add_Click({ Handle-ConnectClick })

    # Run Configuration
    $script:State.Controls.BtnPreviewRun.add_Click({ Handle-RunClick -IsPreview $true })
    $script:State.Controls.BtnRun.add_Click({ Handle-RunClick -IsPreview $false })
    $script:State.Controls.BtnCancelRun.add_Click({ Handle-CancelRunClick })
    $script:State.Controls.BtnOpenRun.add_Click({ Handle-OpenRunClick })

    # Conversations Tab
    $script:State.Controls.BtnSearch.add_Click({ Handle-SearchClick })
    $script:State.Controls.BtnPrevPage.add_Click({ Handle-PagingClick -Direction 'Prev' })
    $script:State.Controls.BtnNextPage.add_Click({ Handle-PagingClick -Direction 'Next' })
    $script:State.Controls.BtnExportPageCsv.add_Click({ Handle-ExportClick -Scope 'Page' })
    $script:State.Controls.BtnExportRunCsv.add_Click({ Handle-ExportClick -Scope 'Run' })
    $script:State.Controls.DgConversations.add_SelectionChanged({ Handle-ConversationSelectionChanged })

    # Drilldown Tab
    $script:State.Controls.BtnGenerateReport.add_Click({ Handle-GenerateReportClick })

    # Run Console Tab
    # $script:State.Controls.BtnCopyDiagnostics.add_Click({ Handle-CopyDiagnosticsClick })
}

function Initialize-Application {
    # Set default dates
    $script:State.Controls.DtpStartDate.SelectedDate = (Get-Date).Date.AddDays(-1)
    $script:State.Controls.DtpEndDate.SelectedDate = (Get-Date).Date

    # Bind the DataGrid to the observable collection
    $script:State.Controls.DgConversations.ItemsSource = $script:State.RunDataView

    # Initialize Core Adapter (Gate A)
    try {
        $coreRoot = Split-Path -Path (Resolve-Path $env:GENESYS_CORE_MODULE_PATH).Path -Parent | Split-Path -Parent
        $catalogPath = Join-Path $coreRoot 'catalog/genesys.catalog.json'
        $schemaPath = Join-Path $coreRoot 'catalog/schema/genesys.catalog.schema.json'
        Initialize-CoreAdapter -CatalogPath $catalogPath -SchemaPath $schemaPath
        Update-Status "Ready. Core engine initialized."
    }
    catch {
        Update-Status "FATAL: Could not initialize Genesys.Core. $($_.Exception.Message)" "Error"
        [System.Windows.MessageBox]::Show("Could not initialize or validate Genesys.Core components. Check paths and catalog files.`n`n$($_.Exception.Message)", "Fatal Error", "OK", "Error")
        $script:State.Window.Close()
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
    Update-Status "Connecting..."
    $script:State.Controls.BtnConnect.IsEnabled = $false

    try {
        # This would be replaced with a settings window in a real app
        $clientId = $env:GENESYS_CLIENT_ID
        $clientSecret = $env:GENESYS_CLIENT_SECRET
        $region = 'usw2.pure.cloud' # Or from a settings file

        if (-not ($clientId -and $clientSecret)) {
            throw "GENESYS_CLIENT_ID and GENESYS_CLIENT_SECRET environment variables must be set."
        }

        $script:State.AuthContext = Connect-App -ClientId $clientId -ClientSecret $clientSecret -Region $region
        $script:State.Controls.ElpConnStatus.Fill = $script:State.Controls.TryFindResource('BrushGreen')
        $script:State.Controls.LblConnectionStatus.Text = "Connected to $($region)"
        Update-Status "Connection successful."
    }
    catch {
        $script:State.Controls.ElpConnStatus.Fill = $script:State.Controls.TryFindResource('BrushRed')
        $script:State.Controls.LblConnectionStatus.Text = "Connection failed"
        Update-Status "Connection failed: $($_.Exception.Message)" "Error"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Connection Error", "OK", "Warning")
    }
    finally {
        $script:State.Controls.BtnConnect.IsEnabled = $true
    }
}

function Handle-RunClick($IsPreview) {
    if (-not $script:State.AuthContext) {
        [System.Windows.MessageBox]::Show("Please connect to Genesys Cloud first.", "Not Connected", "OK", "Information")
        return
    }

    # Assemble parameters
    $datasetKey = if ($IsPreview) { 'analytics-conversation-details-query' } else { 'analytics-conversation-details' }
    $interval = "{0:s}Z/{1:s}Z" -f $script:State.Controls.DtpStartDate.SelectedDate.Value.ToUniversalTime(), $script:State.Controls.DtpEndDate.SelectedDate.Value.ToUniversalTime()

    # Build filters from UI controls
    $segmentFilters = [System.Collections.Generic.List[object]]::new()
    if ($script:State.Controls.TxtQueue.Text) {
        $segmentFilters.Add(@{
            type = 'or'
            predicates = @(
                @{ dimension = 'queueId'; value = $script:State.Controls.TxtQueue.Text }
            )
        })
    }

    $conversationFilters = [System.Collections.Generic.List[object]]::new()
    if ($script:State.Controls.CmbDirection.SelectedItem.Content -ne '(all)') {
        $conversationFilters.Add(@{
            type = 'or'
            predicates = @(
                @{ dimension = 'direction'; value = $script:State.Controls.CmbDirection.SelectedItem.Content }
            )
        })
    }
    if ($script:State.Controls.CmbMediaType.SelectedItem.Content -ne '(all)') {
        $conversationFilters.Add(@{
            type = 'or'
            predicates = @(
                @{ dimension = 'mediaType'; value = $script:State.Controls.CmbMediaType.SelectedItem.Content }
            )
        })
    }

    $datasetParams = @{
        interval = $interval
        segmentFilters = $segmentFilters.ToArray()
        conversationFilters = $conversationFilters.ToArray()
    }
    if ($IsPreview) { $datasetParams.paging = @{ pageSize = [int]$script:State.Controls.TxtPreviewPageSize.Text } }

    $outputRoot = Join-Path $env:LOCALAPPDATA "GenesysConversationAnalysis/runs"
    if (-not (Test-Path $outputRoot)) { $null = New-Item -Path $outputRoot -ItemType Directory }

    # Start the extraction job (Gate B)
    try {
        $script:State.CurrentRunJob = Start-CoreExtraction `
            -DatasetKey $datasetKey `
            -AuthContext $script:State.AuthContext `
            -OutputRoot $outputRoot `
            -DatasetParameters $datasetParams

        Set-RunInProgressState($true)
        $script:State.JobStatePoller.Start()
        $script:State.RunMonitorTimer.Start()
        $script:State.Controls.TabWorkspace.SelectedIndex = 2 # Switch to Run Console
        Update-Status "Starting run for dataset '$($datasetKey)'..."
    }
    catch {
        Update-Status "Failed to start run: $($_.Exception.Message)" "Error"
    }
}

function Handle-CancelRunClick {
    if ($script:State.CurrentRunJob) {
        Update-Status "Cancelling run..."
        Stop-Job -Job $script:State.CurrentRunJob
        # The Check-JobState handler will do the final cleanup
    }
}

function Handle-OpenRunClick {
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = "Select a Genesys.Core run folder"
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -eq 'OK') {
        Load-Run -RunFolder $dialog.SelectedPath
    }
}

function Handle-SearchClick {
    $searchText = $script:State.Controls.TxtSearch.Text
    if ([string]::IsNullOrWhiteSpace($searchText)) {
        $script:State.FilteredIndex = $script:State.RunIndex
        Update-Status "Search cleared."
    }
    else {
        Update-Status "Searching for '$searchText'..."
        # Filter the index locally. Since the index is lightweight, this is fast.
        $script:State.FilteredIndex = $script:State.RunIndex | Where-Object {
            $_.ConversationId -like "*$searchText*"
        }
        Update-Status "Found $($script:State.FilteredIndex.Count) matches."
    }
    Load-ConversationPage -PageIndex 0
}

function Handle-ExportClick($Scope) {
    $dialog = [System.Windows.Forms.SaveFileDialog]::new()
    $dialog.Filter = "CSV Files (*.csv)|*.csv"
    $dialog.FileName = "export_$Scope_$(Get-Date -Format 'yyyyMMdd-HHmm').csv"

    if ($dialog.ShowDialog() -eq 'OK') {
        Update-Status "Exporting $Scope to $($dialog.FileName)..."
        try {
            if ($Scope -eq 'Page') {
                $script:State.RunDataView | Export-Csv -Path $dialog.FileName -NoTypeInformation
            }
            elseif ($Scope -eq 'Run') {
                if (-not $script:State.CurrentRun) { throw "No run loaded." }
                Export-RunToCsv -RunFolder $script:State.CurrentRun.runFolder -OutputPath $dialog.FileName
            }
            Update-Status "Export complete."
        }
        catch {
            Update-Status "Export failed: $($_.Exception.Message)" "Error"
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Export Error", "OK", "Error")
        }
    }
}

function Handle-GenerateReportClick {
    Update-Status "Generating impact report..."
    try {
        $reportTitle = "Impact Report: $($script:State.Controls.TxtSearch.Text)"
        $report = New-ImpactReport -FilteredIndex $script:State.FilteredIndex -ReportTitle $reportTitle
        $script:State.Controls.TxtDrillSummary.Text = $report | ConvertTo-Json -Depth 8
        Update-Status "Impact report generated."
    }
    catch {
        Update-Status "Failed to generate report: $($_.Exception.Message)" "Error"
    }
}

function Handle-PagingClick($Direction) {
    $newIndex = $script:State.PageIndex
    if ($Direction -eq 'Next') { $newIndex++ }
    if ($Direction -eq 'Prev') { $newIndex-- }

    Load-ConversationPage -PageIndex $newIndex
}

function Handle-ConversationSelectionChanged {
    $selectedItem = $script:State.Controls.DgConversations.SelectedItem
    if (-not $selectedItem) { return }

    # Load the full record for drilldown (Gate C)
    $fullRecord = Get-RunRecordById -Index $script:State.RunIndex -ConversationId $selectedItem.ConversationId
    if (-not $fullRecord) { return }

    # Update Drilldown Tab
    $script:State.Controls.LblSelectedConversation.Text = $fullRecord.conversationId
    $script:State.Controls.TabWorkspace.SelectedIndex = 1 # Switch to Drilldown

    # Populate drilldown sub-tabs
    $script:State.Controls.TxtRawJson.Text = $fullRecord | ConvertTo-Json -Depth 10
    $script:State.Controls.DgParticipants.ItemsSource = $fullRecord.participants

    # Flatten segments for easier viewing in the grid
    $allSegments = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $fullRecord.participants) {
        foreach ($s in $p.sessions) {
            foreach ($seg in $s.segments) {
                $seg.PSObject.Properties.Add([psnoteproperty]::new('ParticipantPurpose', $p.purpose))
                $seg.PSObject.Properties.Add([psnoteproperty]::new('ParticipantName', $p.participantName))
                $allSegments.Add($seg)
            }
        }
    }
    $script:State.Controls.DgSegments.ItemsSource = $allSegments
}

# ... other handlers ...
#endregion

#region Job and Run Monitoring
function Check-JobState {
    $job = $script:State.CurrentRunJob
    if (-not $job) {
        $script:State.JobStatePoller.Stop()
        return
    }

    # Update progress from job state
    $script:State.Controls.TxtRunStatus.Text = "Run status: $($job.State)"
    if ($job.State -in 'Running', 'Completed', 'Failed', 'Stopped') {
        # Receive job output (the run object)
        if ($job.HasMoreData) {
            $runObject = Receive-Job -Job $job -Keep
            if ($runObject -and -not $script:State.CurrentRun) {
                $script:State.CurrentRun = $runObject
            }
        }
    }

    # Finalize on completion
    if ($job.State -in 'Completed', 'Failed', 'Stopped') {
        $script:State.JobStatePoller.Stop()
        $script:State.RunMonitorTimer.Stop()
        Remove-Job -Job $job
        $script:State.CurrentRunJob = $null
        Set-RunInProgressState($false)
        Update-Status "Run finished with status: $($job.State)."

        if ($job.State -eq 'Completed') {
            Load-Run -RunFolder $script:State.CurrentRun.runFolder
        }
    }
}
#endregion

#region UI Helpers
function Update-Status($Message, $Level = 'Info') {
    $script:State.Controls.TxtStatusMain.Text = $Message
    # Could also change status bar color based on level
}

function Set-RunInProgressState($IsRunning) {
    $script:State.Controls.BtnPreviewRun.IsEnabled = -not $IsRunning
    $script:State.Controls.BtnRun.IsEnabled = -not $IsRunning
    $script:State.Controls.BtnCancelRun.IsEnabled = $IsRunning
    $script:State.Controls.PrgRun.IsIndeterminate = $IsRunning
    if (-not $IsRunning) {
        $script:State.Controls.PrgRun.Value = 0
    }
}

function Update-ProgressFromArtifacts {
    if (-not $script:State.CurrentRun) { return }

    $runFolder = $script:State.CurrentRun.runFolder
    $summaryPath = Join-Path $runFolder 'summary.json'
    $eventsPath = Join-Path $runFolder 'events.jsonl'

    # Update from summary.json
    if (Test-Path $summaryPath) {
        $summary = Get-Content -Raw -Path $summaryPath | ConvertFrom-Json
        $script:State.Controls.TxtRunProgress.Text = "Records: $($summary.recordCount) | Errors: $($summary.errorCount) | Elapsed: $($summary.elapsed)"
        $script:State.Controls.TxtConsoleStatus.Text = $summary.status
    }

    # Update from events.jsonl
    if (Test-Path $eventsPath) {
        # In a real app, you would tail this file and only read new lines.
        # For simplicity here, we re-read it.
        $events = Get-Content -Path $eventsPath | ConvertFrom-Json
        $script:State.Controls.DgRunEvents.ItemsSource = $events
        if ($events) {
            $script:State.Controls.DgRunEvents.ScrollIntoView($events[-1])
        }
    }
}

function Load-Run {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunFolder
    )

    Update-Status "Loading run from '$($RunFolder)'..."
    $script:State.CurrentRun = @{ runFolder = $RunFolder }
    $indexPath = Join-Path $RunFolder 'index.jsonl'

    # Gate C: Build or load the index for the run
    if (Test-Path $indexPath) {
        Update-Status "Loading existing index..."
        $script:State.RunIndex = Get-Content -Raw -Path $indexPath | ConvertFrom-Json
    }
    else {
        Update-Status "No index found. Building index for run... (this may take a moment)"
        # Use dispatcher to allow UI to update before blocking on index build
        $script:State.Window.Dispatcher.InvokeAsync({
            $script:State.RunIndex = Build-RunIndex -RunFolder $RunFolder
            $script:State.FilteredIndex = $script:State.RunIndex
            Update-Status "Index built. $($script:State.RunIndex.Count) records found."
            Load-ConversationPage -PageIndex 0
        }) | Out-Null
        return
    }

    Update-Status "Run loaded. $($script:State.RunIndex.Count) records indexed."
    $script:State.FilteredIndex = $script:State.RunIndex
    Load-ConversationPage -PageIndex 0
    $script:State.Controls.TabWorkspace.SelectedIndex = 0 # Switch to Conversations tab
}

function Load-ConversationPage {
    [CmdletBinding()]
    param([int]$PageIndex)

    $totalRecords = $script:State.FilteredIndex.Count
    if ($totalRecords -eq 0) {
        $script:State.RunDataView.Clear()
        $script:State.Controls.TxtPageInfo.Text = "0 records found"
        return
    }

    $totalPages = [math]::Ceiling($totalRecords / $script:State.PageSize)
    if ($PageIndex -lt 0 -or $PageIndex -ge $totalPages) { return } # Out of bounds

    $script:State.PageIndex = $PageIndex
    Update-Status "Loading page $($PageIndex + 1) of $($totalPages)..."

    $pageData = Get-RunPage -Index $script:State.FilteredIndex -PageIndex $PageIndex -PageSize $script:State.PageSize
    $script:State.RunDataView.Clear()
    $pageData.ForEach({ $script:State.RunDataView.Add($_) })

    $script:State.Controls.TxtPageInfo.Text = "Page $($PageIndex + 1) of $($totalPages)  |  $($totalRecords) records"
    $script:State.Controls.BtnPrevPage.IsEnabled = ($PageIndex > 0)
    $script:State.Controls.BtnNextPage.IsEnabled = ($PageIndex < ($totalPages - 1))
    Update-Status "Page $($PageIndex + 1) loaded."
}
#endregion

Export-ModuleMember -Function Show-ConversationAnalysisWindow

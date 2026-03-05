#Requires -Version 5.1
Set-StrictMode -Version Latest

# ── App.UI.ps1 ────────────────────────────────────────────────────────────────
# Dot-sourced by App.ps1 after XAML is loaded.
# All WPF control references are resolved here from $script:Window.
# ─────────────────────────────────────────────────────────────────────────────

# ── Control map ──────────────────────────────────────────────────────────────

function _Ctrl { param([string]$Name) $script:Window.FindName($Name) }

# Header
$script:ElpConnStatus          = _Ctrl 'ElpConnStatus'
$script:LblConnectionStatus    = _Ctrl 'LblConnectionStatus'
$script:BtnConnect             = _Ctrl 'BtnConnect'
$script:BtnSettings            = _Ctrl 'BtnSettings'

# Left panel
$script:DtpStartDate           = _Ctrl 'DtpStartDate'
$script:DtpEndDate             = _Ctrl 'DtpEndDate'
$script:CmbDirection           = _Ctrl 'CmbDirection'
$script:CmbMediaType           = _Ctrl 'CmbMediaType'
$script:TxtQueue               = _Ctrl 'TxtQueue'
$script:TxtPreviewPageSize     = _Ctrl 'TxtPreviewPageSize'
$script:BtnPreviewRun          = _Ctrl 'BtnPreviewRun'
$script:BtnRun                 = _Ctrl 'BtnRun'
$script:BtnCancelRun           = _Ctrl 'BtnCancelRun'
$script:TxtRunStatus           = _Ctrl 'TxtRunStatus'
$script:PrgRun                 = _Ctrl 'PrgRun'
$script:TxtRunProgress         = _Ctrl 'TxtRunProgress'
$script:LstRecentRuns          = _Ctrl 'LstRecentRuns'
$script:BtnOpenRun             = _Ctrl 'BtnOpenRun'

# Conversations tab
$script:TxtSearch              = _Ctrl 'TxtSearch'
$script:BtnSearch              = _Ctrl 'BtnSearch'
$script:CmbFilterDirection     = _Ctrl 'CmbFilterDirection'
$script:CmbFilterMedia         = _Ctrl 'CmbFilterMedia'
$script:DgConversations        = _Ctrl 'DgConversations'
$script:BtnPrevPage            = _Ctrl 'BtnPrevPage'
$script:BtnNextPage            = _Ctrl 'BtnNextPage'
$script:TxtPageInfo            = _Ctrl 'TxtPageInfo'
$script:BtnExportPageCsv       = _Ctrl 'BtnExportPageCsv'
$script:BtnExportRunCsv        = _Ctrl 'BtnExportRunCsv'

# Drilldown tab
$script:LblSelectedConversation = _Ctrl 'LblSelectedConversation'
$script:TxtDrillSummary        = _Ctrl 'TxtDrillSummary'
$script:DgParticipants         = _Ctrl 'DgParticipants'
$script:DgSegments             = _Ctrl 'DgSegments'
$script:TxtAttributeSearch     = _Ctrl 'TxtAttributeSearch'
$script:DgAttributes           = _Ctrl 'DgAttributes'
$script:TxtMosQuality          = _Ctrl 'TxtMosQuality'
$script:TxtRawJson             = _Ctrl 'TxtRawJson'
# BtnExpandJson exists in XAML but has no bound handler (known nuance – preserved by design)

# Run Console tab
$script:TxtConsoleStatus       = _Ctrl 'TxtConsoleStatus'
$script:DgRunEvents            = _Ctrl 'DgRunEvents'
$script:BtnCopyDiagnostics     = _Ctrl 'BtnCopyDiagnostics'
$script:TxtDiagnostics         = _Ctrl 'TxtDiagnostics'

# Footer
$script:TxtStatusMain          = _Ctrl 'TxtStatusMain'
$script:TxtStatusRight         = _Ctrl 'TxtStatusRight'

# ── Application state bag ─────────────────────────────────────────────────────

$script:State = @{
    CurrentRunFolder    = $null
    CurrentIndex        = @()          # filtered index entries for current view
    CurrentPage         = 1
    PageSize            = 50
    TotalPages          = 0
    SearchText          = ''
    FilterDirection     = ''
    FilterMedia         = ''
    BackgroundRunJob    = $null        # PSDataCollection / runspace handle
    BackgroundRunspace  = $null
    PollingTimer        = $null
    DiagnosticsContext  = $null        # last run folder for diagnostics
    IsRunning           = $false
    RunCancelled        = $false
    PkceCancel          = $null        # CancellationTokenSource for PKCE
}

# ── Dispatcher helper ─────────────────────────────────────────────────────────

function _Dispatch {
    param([scriptblock]$Action)
    $script:Window.Dispatcher.Invoke([System.Action]$Action)
}

# ── Status helpers ─────────────────────────────────────────────────────────────

function _SetStatus {
    param([string]$Text, [string]$Right = '')
    _Dispatch {
        $script:TxtStatusMain.Text  = $Text
        $script:TxtStatusRight.Text = $Right
    }
}

function _UpdateConnectionStatus {
    $info = Get-ConnectionInfo
    _Dispatch {
        if ($null -ne $info) {
            $exp = $info.ExpiresAt.ToString('HH:mm:ss') + ' UTC'
            $script:LblConnectionStatus.Text = "$($info.Region)  |  $($info.Flow)  |  expires $exp"
            $script:ElpConnStatus.Fill       = [System.Windows.Media.Brushes]::LightGreen
        } else {
            $script:LblConnectionStatus.Text = 'Not connected'
            $script:ElpConnStatus.Fill       = [System.Windows.Media.Brushes]::Salmon
        }
    }
}

# ── Recent runs ───────────────────────────────────────────────────────────────

function _RefreshRecentRuns {
    $cfg         = Get-AppConfig
    $fromConfig  = @(Get-RecentRuns)
    $fromDisk    = @(Get-RecentRunFolders -OutputRoot $cfg.OutputRoot -Max $cfg.MaxRecentRuns)
    # Merge and deduplicate; config list takes precedence for ordering
    $combined    = ($fromConfig + $fromDisk) | Select-Object -Unique
    _Dispatch {
        $script:LstRecentRuns.Items.Clear()
        foreach ($f in $combined) {
            $label = [System.IO.Path]::GetFileName($f)
            $script:LstRecentRuns.Items.Add([pscustomobject]@{ Display = $label; FullPath = $f })
        }
        $script:LstRecentRuns.DisplayMemberPath = 'Display'
    }
}

# ── Index / paging ────────────────────────────────────────────────────────────

function _LoadRunAndRefreshGrid {
    param([string]$RunFolder)
    if ([string]::IsNullOrEmpty($RunFolder)) { return }
    _SetStatus "Loading index: $([System.IO.Path]::GetFileName($RunFolder)) …"

    $script:State.CurrentRunFolder = $RunFolder
    $script:State.DiagnosticsContext = $RunFolder

    # Load or build index (may take a moment for large runs)
    $allIdx = Load-RunIndex -RunFolder $RunFolder
    $script:State.CurrentPage = 1
    _ApplyFiltersAndRefresh -AllIndex $allIdx
    _SetStatus "Loaded $($allIdx.Count) records from $([System.IO.Path]::GetFileName($RunFolder))"
    $script:TxtStatusRight.Text = [datetime]::Now.ToString('HH:mm:ss')
}

function _ApplyFiltersAndRefresh {
    param([object[]]$AllIndex = $null)

    if ($null -eq $AllIndex) {
        if ($null -eq $script:State.CurrentRunFolder) { return }
        $AllIndex = Load-RunIndex -RunFolder $script:State.CurrentRunFolder
    }

    $dir    = $script:State.FilterDirection
    $media  = $script:State.FilterMedia
    $search = $script:State.SearchText

    $filtered = $AllIndex | Where-Object {
        $ok = $true
        if ($dir    -and $_.direction -ne $dir)          { $ok = $false }
        if ($media  -and $_.mediaType -ne $media)         { $ok = $false }
        if ($search) {
            $lo = $search.ToLowerInvariant()
            if ($_.id    -notlike "*$lo*" -and
                $_.queue -notlike "*$lo*") { $ok = $false }
        }
        $ok
    }
    $script:State.CurrentIndex = @($filtered)
    $script:State.TotalPages   = [math]::Max(1, [math]::Ceiling($filtered.Count / $script:State.PageSize))
    if ($script:State.CurrentPage -gt $script:State.TotalPages) {
        $script:State.CurrentPage = $script:State.TotalPages
    }
    _RenderCurrentPage
}

function _RenderCurrentPage {
    $idx      = $script:State.CurrentIndex
    $page     = $script:State.CurrentPage
    $pageSize = $script:State.PageSize
    $total    = $idx.Count
    $pages    = $script:State.TotalPages

    $startIdx = ($page - 1) * $pageSize
    $endIdx   = [math]::Min($startIdx + $pageSize - 1, $total - 1)

    if ($startIdx -gt $endIdx -or $total -eq 0) {
        _Dispatch {
            $script:DgConversations.ItemsSource = $null
            $script:TxtPageInfo.Text = 'Page 0 of 0  |  0 records'
        }
        return
    }

    $pageEntries = $idx[$startIdx..$endIdx]
    $displayRows = $pageEntries | ForEach-Object { Get-ConversationDisplayRow -IndexEntry $_ }

    _Dispatch {
        $script:DgConversations.ItemsSource = [System.Collections.ObjectModel.ObservableCollection[object]]($displayRows)
        $script:TxtPageInfo.Text = "Page $page of $pages  |  $total records"
        $script:BtnPrevPage.IsEnabled = ($page -gt 1)
        $script:BtnNextPage.IsEnabled = ($page -lt $pages)
    }
}

# ── Drilldown ─────────────────────────────────────────────────────────────────

function _LoadDrilldown {
    param([string]$ConversationId)
    if ($null -eq $script:State.CurrentRunFolder) { return }

    _SetStatus "Loading drilldown: $ConversationId …"
    $record = Get-ConversationRecord -RunFolder $script:State.CurrentRunFolder -ConversationId $ConversationId

    if ($null -eq $record) {
        _Dispatch {
            $script:LblSelectedConversation.Text = "(not found)"
            $script:TxtDrillSummary.Text = "Record not found for conversation ID: $ConversationId"
        }
        _SetStatus "Drilldown: record not found"
        return
    }

    _Dispatch {
        $script:LblSelectedConversation.Text = $ConversationId

        # ── Summary tab ──
        $flat = ConvertTo-FlatRow -Record $record -IncludeAttributes
        $sb   = New-Object System.Text.StringBuilder
        foreach ($k in $flat.Keys) {
            [void]$sb.AppendLine("$($k): $($flat[$k])")
        }
        $script:TxtDrillSummary.Text = $sb.ToString()

        # ── Participants tab ──
        $parts = @()
        if ($record.PSObject.Properties['participants']) { $parts = @($record.participants) }
        $script:DgParticipants.ItemsSource = [System.Collections.ObjectModel.ObservableCollection[object]]($parts)

        # ── Segments tab ──
        $segRows = New-Object System.Collections.Generic.List[object]
        foreach ($p in $parts) {
            if (-not $p.PSObject.Properties['sessions']) { continue }
            foreach ($s in @($p.sessions)) {
                if (-not $s.PSObject.Properties['segments']) { continue }
                foreach ($seg in @($s.segments)) {
                    $durSec = 0
                    if ($seg.PSObject.Properties['segmentStart'] -and $seg.PSObject.Properties['segmentEnd']) {
                        try {
                            $ss = [datetime]::Parse($seg.segmentStart)
                            $se = [datetime]::Parse($seg.segmentEnd)
                            $durSec = [int]($se - $ss).TotalSeconds
                        } catch { }
                    }
                    $segRows.Add([pscustomobject]@{
                        Purpose       = if ($p.PSObject.Properties['purpose']) { $p.purpose } else { '' }
                        SegmentType   = if ($seg.PSObject.Properties['segmentType'])   { $seg.segmentType }   else { '' }
                        SegmentStart  = if ($seg.PSObject.Properties['segmentStart'])  { $seg.segmentStart }  else { '' }
                        SegmentEnd    = if ($seg.PSObject.Properties['segmentEnd'])    { $seg.segmentEnd }    else { '' }
                        DurationSec   = $durSec
                        QueueName     = if ($seg.PSObject.Properties['queueName'])     { $seg.queueName }     else { '' }
                        DisconnectType = if ($seg.PSObject.Properties['disconnectType']) { $seg.disconnectType } else { '' }
                    })
                }
            }
        }
        $script:DgSegments.ItemsSource = [System.Collections.ObjectModel.ObservableCollection[object]]($segRows.ToArray())

        # ── Attributes tab ──
        $attrRows = New-Object System.Collections.Generic.List[object]
        if ($record.PSObject.Properties['attributes'] -and $null -ne $record.attributes) {
            foreach ($prop in $record.attributes.PSObject.Properties) {
                $attrRows.Add([pscustomobject]@{ Name = $prop.Name; Value = $prop.Value })
            }
        }
        $script:DgAttributes.ItemsSource = [System.Collections.ObjectModel.ObservableCollection[object]]($attrRows.ToArray())

        # ── MOS / Quality tab ──
        $mosSb = New-Object System.Text.StringBuilder
        foreach ($p in $parts) {
            if (-not $p.PSObject.Properties['sessions']) { continue }
            foreach ($s in @($p.sessions)) {
                if (-not $s.PSObject.Properties['metrics']) { continue }
                foreach ($m in @($s.metrics)) {
                    if ($m.PSObject.Properties['name'] -and ($m.name -like '*mos*' -or $m.name -like '*Mos*')) {
                        [void]$mosSb.AppendLine("Metric : $($m.name)")
                        if ($m.PSObject.Properties['stats']) {
                            $st = $m.stats
                            [void]$mosSb.AppendLine("  Stats: $($st | ConvertTo-Json -Compress)")
                        }
                        [void]$mosSb.AppendLine()
                    }
                }
            }
        }
        $script:TxtMosQuality.Text = if ($mosSb.Length -eq 0) { '(no MOS metrics)' } else { $mosSb.ToString() }

        # ── Raw JSON tab ──
        $script:TxtRawJson.Text = $record | ConvertTo-Json -Depth 20
    }
    _SetStatus "Drilldown loaded: $ConversationId"
}

# ── Run orchestration ─────────────────────────────────────────────────────────

function _GetDatasetParameters {
    $params = @{}
    $cfg    = Get-AppConfig

    if ($script:DtpStartDate.SelectedDate) {
        $params['StartDateTime'] = $script:DtpStartDate.SelectedDate.Value.ToString('o')
    }
    if ($script:DtpEndDate.SelectedDate) {
        $params['EndDateTime'] = $script:DtpEndDate.SelectedDate.Value.ToString('o')
    }

    $selDir = $script:CmbDirection.SelectedItem
    if ($selDir -and $selDir.Content -ne '(all)') {
        $params['Direction'] = $selDir.Content
    }

    $selMedia = $script:CmbMediaType.SelectedItem
    if ($selMedia -and $selMedia.Content -ne '(all)') {
        $params['MediaType'] = $selMedia.Content
    }

    $q = $script:TxtQueue.Text.Trim()
    if ($q) { $params['Queue'] = $q }

    return $params
}

function _SetRunning {
    param([bool]$IsRunning)
    $script:State.IsRunning = $IsRunning
    _Dispatch {
        $script:BtnRun.IsEnabled        = -not $IsRunning
        $script:BtnPreviewRun.IsEnabled = -not $IsRunning
        $script:BtnCancelRun.IsEnabled  = $IsRunning
        if (-not $IsRunning) {
            $script:PrgRun.Value = 0
        }
    }
}

function _StartRunInBackground {
    param(
        [string]$RunType,   # 'preview' | 'full'
        [hashtable]$DatasetParameters
    )
    if ($script:State.IsRunning) { return }

    $cfg     = Get-AppConfig
    $headers = Get-StoredHeaders

    # Resolve env-overridden paths (same logic as App.ps1)
    $corePath    = if ($env:GENESYS_CORE_MODULE)  { $env:GENESYS_CORE_MODULE  } else { $cfg.CoreModulePath }
    $catalogPath = if ($env:GENESYS_CORE_CATALOG) { $env:GENESYS_CORE_CATALOG } else { $cfg.CatalogPath    }
    $outputRoot  = $cfg.OutputRoot

    $script:State.RunCancelled = $false
    _SetRunning $true
    _Dispatch {
        $script:TxtRunStatus.Text   = "Starting $RunType run…"
        $script:TxtConsoleStatus.Text = 'Running'
        $script:TxtRunProgress.Text  = ''
        $script:DgRunEvents.ItemsSource = $null
        $script:TxtDiagnostics.Text  = ''
    }

    # Create runspace – must re-initialize CoreAdapter (module state is runspace-local)
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    $appDir = $PSScriptRoot

    [void]$ps.AddScript({
        param($AppDir, $CorePath, $CatalogPath, $OutputRoot, $RunType, $DatasetParams, $Headers)
        Set-StrictMode -Version Latest
        Import-Module (Join-Path $AppDir 'App.CoreAdapter.psm1') -Force
        Initialize-CoreAdapter -CoreModulePath $CorePath -CatalogPath $CatalogPath -OutputRoot $OutputRoot
        if ($RunType -eq 'preview') {
            Start-PreviewRun -DatasetParameters $DatasetParams -Headers $Headers
        } else {
            Start-FullRun -DatasetParameters $DatasetParams -Headers $Headers
        }
    })
    [void]$ps.AddArgument($appDir)
    [void]$ps.AddArgument($corePath)
    [void]$ps.AddArgument($catalogPath)
    [void]$ps.AddArgument($outputRoot)
    [void]$ps.AddArgument($RunType)
    [void]$ps.AddArgument($DatasetParameters)
    [void]$ps.AddArgument($headers)

    $asyncResult = $ps.BeginInvoke()

    $script:State.BackgroundRunspace = $rs
    $script:State.BackgroundRunJob   = @{ Ps = $ps; Async = $asyncResult }

    # Start polling timer
    $timer           = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval  = [System.TimeSpan]::FromSeconds(2)
    $script:State.PollingTimer = $timer

    $timer.Add_Tick({
        param($sender, $e)
        _PollBackgroundRun
    })
    $timer.Start()
}

function _PollBackgroundRun {
    $job  = $script:State.BackgroundRunJob
    if ($null -eq $job) { return }

    $ps    = $job.Ps
    $async = $job.Async

    # Update events display
    if ($null -ne $script:State.CurrentRunFolder) {
        $events = Get-RunEvents -RunFolder $script:State.CurrentRunFolder -LastN 50
        if ($events.Count -gt 0) {
            _Dispatch {
                $script:DgRunEvents.ItemsSource = [System.Collections.ObjectModel.ObservableCollection[object]]($events)
            }
        }
    } else {
        # Try to find the run folder that was just created
        $cfg     = Get-AppConfig
        $folders = Get-RecentRunFolders -OutputRoot $cfg.OutputRoot -Max 1
        if ($folders.Count -gt 0) {
            $script:State.CurrentRunFolder   = $folders[0]
            $script:State.DiagnosticsContext = $folders[0]
        }
    }

    # Show run status
    $statusText = if ($script:State.RunCancelled) { 'Cancelling…' } else { 'Running…' }
    _Dispatch {
        $script:TxtRunStatus.Text     = $statusText
        $script:TxtConsoleStatus.Text = $statusText
    }

    if (-not $async.IsCompleted) { return }

    # Run finished
    $script:State.PollingTimer.Stop()
    $script:State.PollingTimer = $null

    $errors = $ps.Streams.Error
    $ps.EndInvoke($async) | Out-Null
    $script:State.BackgroundRunspace.Close()
    $script:State.BackgroundRunJob   = $null
    $script:State.BackgroundRunspace = $null

    _SetRunning $false

    if ($errors.Count -gt 0) {
        $errText = ($errors | ForEach-Object { $_.ToString() }) -join "`n"
        _Dispatch {
            $script:TxtRunStatus.Text     = "Run failed"
            $script:TxtConsoleStatus.Text = "Failed"
            $script:TxtDiagnostics.Text   = $errText
        }
        _SetStatus "Run failed: $($errors[0])"
        return
    }

    # Load run results
    if ($null -ne $script:State.CurrentRunFolder) {
        Add-RecentRun -RunFolder $script:State.CurrentRunFolder
        _RefreshRecentRuns
        _LoadRunAndRefreshGrid -RunFolder $script:State.CurrentRunFolder
    }

    _Dispatch {
        $script:TxtRunStatus.Text     = 'Run complete'
        $script:TxtConsoleStatus.Text = 'Complete'
        if ($null -ne $script:State.DiagnosticsContext) {
            $script:TxtDiagnostics.Text = Get-DiagnosticsText -RunFolder $script:State.DiagnosticsContext
        }
    }
    _SetStatus 'Run complete'
}

function _CancelBackgroundRun {
    if (-not $script:State.IsRunning) { return }
    $script:State.RunCancelled = $true
    $job = $script:State.BackgroundRunJob
    if ($null -ne $job) {
        try { $job.Ps.Stop() } catch { }
    }
    $script:State.PollingTimer.Stop()
    $script:State.PollingTimer = $null
    _SetRunning $false
    _Dispatch {
        $script:TxtRunStatus.Text     = 'Run cancelled'
        $script:TxtConsoleStatus.Text = 'Cancelled'
    }
    _SetStatus 'Run cancelled'
}

# ── Connect dialog ─────────────────────────────────────────────────────────────

function _ShowConnectDialog {
    $cfg     = Get-AppConfig
    $dialog  = New-Object System.Windows.Window
    $dialog.Title   = 'Connect to Genesys Cloud'
    $dialog.Width   = 440
    $dialog.Height  = 360
    $dialog.Owner   = $script:Window
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Background = [System.Windows.Media.Brushes]::FromHex('#1E1E2E')
    $dialog.Foreground = [System.Windows.Media.Brushes]::FromHex('#CDD6F4')

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(16)

    function _AddLbl { param($t) $lbl = New-Object System.Windows.Controls.TextBlock; $lbl.Text = $t; $lbl.Margin = [System.Windows.Thickness]::new(0,6,0,2); $sp.Children.Add($lbl) | Out-Null }
    function _AddTxt { param($name,$ph) $tb = New-Object System.Windows.Controls.TextBox; $tb.Name=$name; $tb.Height=28; $tb.Tag=$ph; $sp.Children.Add($tb) | Out-Null; return $tb }
    function _AddPwd { $pw = New-Object System.Windows.Controls.PasswordBox; $pw.Height=28; $sp.Children.Add($pw) | Out-Null; return $pw }

    _AddLbl 'Region (e.g. mypurecloud.com)'
    $tbRegion = _AddTxt 'tbRegion' 'mypurecloud.com'
    $tbRegion.Text = $cfg.Region

    _AddLbl 'Client ID'
    $tbClientId = _AddTxt 'tbClientId' ''

    _AddLbl 'Client Secret (leave empty for PKCE)'
    $pwSecret = _AddPwd

    $pnlBtns = New-Object System.Windows.Controls.StackPanel
    $pnlBtns.Orientation = 'Horizontal'
    $pnlBtns.HorizontalAlignment = 'Right'
    $pnlBtns.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)

    $btnPkce = New-Object System.Windows.Controls.Button
    $btnPkce.Content = 'Browser / PKCE'
    $btnPkce.Width   = 130; $btnPkce.Height = 30; $btnPkce.Margin = [System.Windows.Thickness]::new(0,0,8,0)

    $btnLogin = New-Object System.Windows.Controls.Button
    $btnLogin.Content = 'Login'
    $btnLogin.Width   = 80; $btnLogin.Height = 30; $btnLogin.Margin = [System.Windows.Thickness]::new(0,0,8,0)

    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = 'Cancel'
    $btnCancel.Width   = 70; $btnCancel.Height = 30

    $pnlBtns.Children.Add($btnPkce)   | Out-Null
    $pnlBtns.Children.Add($btnLogin)  | Out-Null
    $pnlBtns.Children.Add($btnCancel) | Out-Null
    $sp.Children.Add($pnlBtns) | Out-Null

    $dialog.Content = $sp

    $btnLogin.Add_Click({
        $region   = $tbRegion.Text.Trim()
        $clientId = $tbClientId.Text.Trim()
        $secret   = $pwSecret.Password
        if (-not $region -or -not $clientId -or -not $secret) {
            [System.Windows.MessageBox]::Show('Region, Client ID, and Secret are required for client-credentials login.', 'Validation')
            return
        }
        try {
            Connect-GenesysCloudApp -ClientId $clientId -ClientSecret $secret -Region $region | Out-Null
            Update-AppConfig -Key 'Region' -Value $region
            _UpdateConnectionStatus
            _SetStatus "Connected ($region)"
            $dialog.Close()
        } catch {
            [System.Windows.MessageBox]::Show("Login failed: $_", 'Error')
        }
    })

    $btnPkce.Add_Click({
        $region   = $tbRegion.Text.Trim()
        $clientId = $tbClientId.Text.Trim()
        if (-not $region -or -not $clientId) {
            [System.Windows.MessageBox]::Show('Region and Client ID are required for PKCE login.', 'Validation')
            return
        }
        $cfg2       = Get-AppConfig
        $redirectUri = if ($cfg2.PkceRedirectUri) { $cfg2.PkceRedirectUri } else { 'http://localhost:8080/callback' }

        $dialog.Close()

        # Run PKCE in a separate runspace so it doesn't block the UI
        $cts = New-Object System.Threading.CancellationTokenSource
        $script:State.PkceCancel = $cts

        $rs2  = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); $rs2.Open()
        $ps2  = [System.Management.Automation.PowerShell]::Create(); $ps2.Runspace = $rs2
        $appDir = $PSScriptRoot
        [void]$ps2.AddScript({
            param($AppDir, $ClientId, $Region, $RedirectUri, $CancelToken)
            Import-Module (Join-Path $AppDir 'App.Auth.psm1') -Force
            Connect-GenesysCloudPkce -ClientId $ClientId -Region $Region `
                -RedirectUri $RedirectUri -CancellationToken $CancelToken
        })
        [void]$ps2.AddArgument($appDir)
        [void]$ps2.AddArgument($clientId)
        [void]$ps2.AddArgument($region)
        [void]$ps2.AddArgument($redirectUri)
        [void]$ps2.AddArgument($cts.Token)

        $ar2 = $ps2.BeginInvoke()

        # Poll for PKCE completion
        $pkceTimer = New-Object System.Windows.Threading.DispatcherTimer
        $pkceTimer.Interval = [System.TimeSpan]::FromSeconds(1)
        $pkceTimer.Add_Tick({
            if (-not $ar2.IsCompleted) { return }
            $pkceTimer.Stop()
            try {
                $ps2.EndInvoke($ar2) | Out-Null
                $rs2.Close()
                _UpdateConnectionStatus
                Update-AppConfig -Key 'Region' -Value $region
                _SetStatus "Connected via PKCE ($region)"
            } catch {
                [System.Windows.MessageBox]::Show("PKCE login failed: $_", 'Error')
            }
        })
        $pkceTimer.Start()
    })

    $btnCancel.Add_Click({ $dialog.Close() })
    $dialog.ShowDialog() | Out-Null
}

# ── Settings dialog ─────────────────────────────────────────────────────────

function _ShowSettingsDialog {
    $cfg    = Get-AppConfig
    $dialog = New-Object System.Windows.Window
    $dialog.Title  = 'Settings'
    $dialog.Width  = 560; $dialog.Height = 420
    $dialog.Owner  = $script:Window
    $dialog.WindowStartupLocation = 'CenterOwner'

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(16)

    function _Row { param($label, $val)
        $g = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(160)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::new(1, 'Star')
        $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
        $g.Margin = [System.Windows.Thickness]::new(0,4,0,0)
        $lbl = New-Object System.Windows.Controls.TextBlock; $lbl.Text = $label; $lbl.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
        $tb  = New-Object System.Windows.Controls.TextBox; $tb.Text = $val; $tb.Height = 26
        [System.Windows.Controls.Grid]::SetColumn($tb, 1)
        $g.Children.Add($lbl) | Out-Null; $g.Children.Add($tb) | Out-Null
        $sp.Children.Add($g) | Out-Null
        return $tb
    }

    $tbPageSize      = _Row 'Page size'            $cfg.PageSize
    $tbPrevPageSize  = _Row 'Preview page size'    $cfg.PreviewPageSize
    $tbRegion        = _Row 'Region'               $cfg.Region
    $tbOutputRoot    = _Row 'Output root'          $cfg.OutputRoot
    $tbCorePath      = _Row 'Core module path'     $cfg.CoreModulePath
    $tbCatalogPath   = _Row 'Catalog path'         $cfg.CatalogPath
    $tbPkceClientId  = _Row 'PKCE client ID'       $cfg.PkceClientId
    $tbPkceRedirect  = _Row 'PKCE redirect URI'    $cfg.PkceRedirectUri

    $pnlBtns = New-Object System.Windows.Controls.StackPanel
    $pnlBtns.Orientation = 'Horizontal'; $pnlBtns.HorizontalAlignment = 'Right'
    $pnlBtns.Margin = [System.Windows.Thickness]::new(0,12,0,0)

    $btnSave   = New-Object System.Windows.Controls.Button; $btnSave.Content = 'Save';   $btnSave.Width = 80; $btnSave.Height = 30; $btnSave.Margin = [System.Windows.Thickness]::new(0,0,8,0)
    $btnCancelS = New-Object System.Windows.Controls.Button; $btnCancelS.Content = 'Cancel'; $btnCancelS.Width = 70; $btnCancelS.Height = 30
    $pnlBtns.Children.Add($btnSave) | Out-Null; $pnlBtns.Children.Add($btnCancelS) | Out-Null
    $sp.Children.Add($pnlBtns) | Out-Null

    $dialog.Content = $sp

    $btnSave.Add_Click({
        try {
            $cfg2 = Get-AppConfig
            $cfg2 | Add-Member -NotePropertyName 'PageSize'          -NotePropertyValue ([int]$tbPageSize.Text)     -Force
            $cfg2 | Add-Member -NotePropertyName 'PreviewPageSize'   -NotePropertyValue ([int]$tbPrevPageSize.Text)  -Force
            $cfg2 | Add-Member -NotePropertyName 'Region'            -NotePropertyValue $tbRegion.Text.Trim()        -Force
            $cfg2 | Add-Member -NotePropertyName 'OutputRoot'        -NotePropertyValue $tbOutputRoot.Text.Trim()    -Force
            $cfg2 | Add-Member -NotePropertyName 'CoreModulePath'    -NotePropertyValue $tbCorePath.Text.Trim()      -Force
            $cfg2 | Add-Member -NotePropertyName 'CatalogPath'       -NotePropertyValue $tbCatalogPath.Text.Trim()   -Force
            $cfg2 | Add-Member -NotePropertyName 'PkceClientId'      -NotePropertyValue $tbPkceClientId.Text.Trim()  -Force
            $cfg2 | Add-Member -NotePropertyName 'PkceRedirectUri'   -NotePropertyValue $tbPkceRedirect.Text.Trim()  -Force
            Save-AppConfig -Config $cfg2
            $script:State.PageSize = [int]$tbPageSize.Text
            $dialog.Close()
            _SetStatus 'Settings saved'
        } catch {
            [System.Windows.MessageBox]::Show("Save failed: $_", 'Error')
        }
    })
    $btnCancelS.Add_Click({ $dialog.Close() })
    $dialog.ShowDialog() | Out-Null
}

# ── Export actions ────────────────────────────────────────────────────────────

function _ExportPageCsv {
    if ($null -eq $script:State.CurrentRunFolder) { _SetStatus 'No run loaded'; return }

    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title      = 'Export Page to CSV'
    $dlg.Filter     = 'CSV files (*.csv)|*.csv'
    $dlg.FileName   = "page_$($script:State.CurrentPage).csv"
    if (-not $dlg.ShowDialog()) { return }

    $idx      = $script:State.CurrentIndex
    $page     = $script:State.CurrentPage
    $pageSize = $script:State.PageSize
    $startIdx = ($page - 1) * $pageSize
    $endIdx   = [math]::Min($startIdx + $pageSize - 1, $idx.Count - 1)
    if ($startIdx -gt $endIdx) { return }

    $entries  = $idx[$startIdx..$endIdx]
    $records  = Get-IndexedPage -RunFolder $script:State.CurrentRunFolder -IndexEntries $entries
    Export-PageToCsv -Records $records -OutputPath $dlg.FileName
    _SetStatus "Exported page to $($dlg.FileName)"
}

function _ExportRunCsv {
    if ($null -eq $script:State.CurrentRunFolder) { _SetStatus 'No run loaded'; return }

    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title    = 'Export Full Run to CSV'
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = "run_export.csv"
    if (-not $dlg.ShowDialog()) { return }

    try {
        _SetStatus 'Exporting…'
        Export-RunToCsv -RunFolder $script:State.CurrentRunFolder -OutputPath $dlg.FileName
        _SetStatus "Exported full run to $($dlg.FileName)"
    } catch {
        [System.Windows.MessageBox]::Show("Export failed: $_", 'Error')
        _SetStatus 'Export failed'
    }
}

function _ExportConversationJson {
    if ($null -eq $script:State.CurrentRunFolder) { return }
    $convId = $script:LblSelectedConversation.Text
    if ($convId -eq '(none selected)' -or [string]::IsNullOrEmpty($convId)) { return }

    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title    = 'Export Conversation to JSON'
    $dlg.Filter   = 'JSON files (*.json)|*.json'
    $dlg.FileName = "$convId.json"
    if (-not $dlg.ShowDialog()) { return }

    $record = Get-ConversationRecord -RunFolder $script:State.CurrentRunFolder -ConversationId $convId
    if ($null -eq $record) { _SetStatus 'Conversation not found'; return }
    Export-ConversationToJson -Record $record -OutputPath $dlg.FileName
    _SetStatus "Exported conversation to $($dlg.FileName)"
}

# ── Attribute search filter ────────────────────────────────────────────────────

function _FilterAttributes {
    $search = $script:TxtAttributeSearch.Text.Trim().ToLowerInvariant()
    $all    = $script:DgAttributes.Tag   # stored on Tag
    if ($null -eq $all) { return }
    if (-not $search) {
        $script:DgAttributes.ItemsSource = [System.Collections.ObjectModel.ObservableCollection[object]]($all)
        return
    }
    $filtered = @($all | Where-Object { $_.Name -like "*$search*" -or $_.Value -like "*$search*" })
    $script:DgAttributes.ItemsSource = [System.Collections.ObjectModel.ObservableCollection[object]]($filtered)
}

# ── Event wire-up ─────────────────────────────────────────────────────────────

$script:BtnConnect.Add_Click({ _ShowConnectDialog })

$script:BtnSettings.Add_Click({ _ShowSettingsDialog })

$script:BtnRun.Add_Click({
    $params = _GetDatasetParameters
    _StartRunInBackground -RunType 'full' -DatasetParameters $params
})

$script:BtnPreviewRun.Add_Click({
    $pageSizeText = $script:TxtPreviewPageSize.Text.Trim()
    $previewSize  = 25
    if ($pageSizeText -match '^\d+$') { $previewSize = [int]$pageSizeText }
    $params = _GetDatasetParameters
    $params['PageSize'] = $previewSize
    _StartRunInBackground -RunType 'preview' -DatasetParameters $params
})

$script:BtnCancelRun.Add_Click({ _CancelBackgroundRun })

$script:BtnSearch.Add_Click({
    $script:State.SearchText    = $script:TxtSearch.Text.Trim()
    $script:State.CurrentPage   = 1
    _ApplyFiltersAndRefresh
})

$script:TxtSearch.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return) {
        $script:State.SearchText  = $script:TxtSearch.Text.Trim()
        $script:State.CurrentPage = 1
        _ApplyFiltersAndRefresh
    }
})

$script:CmbFilterDirection.Add_SelectionChanged({
    $sel = $script:CmbFilterDirection.SelectedItem
    $script:State.FilterDirection = if ($sel -and $sel.Content -ne 'All directions') { $sel.Content } else { '' }
    $script:State.CurrentPage     = 1
    _ApplyFiltersAndRefresh
})

$script:CmbFilterMedia.Add_SelectionChanged({
    $sel = $script:CmbFilterMedia.SelectedItem
    $script:State.FilterMedia = if ($sel -and $sel.Content -ne 'All media') { $sel.Content } else { '' }
    $script:State.CurrentPage = 1
    _ApplyFiltersAndRefresh
})

$script:BtnPrevPage.Add_Click({
    if ($script:State.CurrentPage -gt 1) {
        $script:State.CurrentPage--
        _RenderCurrentPage
    }
})

$script:BtnNextPage.Add_Click({
    if ($script:State.CurrentPage -lt $script:State.TotalPages) {
        $script:State.CurrentPage++
        _RenderCurrentPage
    }
})

$script:DgConversations.Add_SelectionChanged({
    $sel = $script:DgConversations.SelectedItem
    if ($null -ne $sel) {
        $convId = $sel.ConversationId
        _LoadDrilldown -ConversationId $convId
        # Switch to Drilldown tab
        $tabCtrl = _Ctrl 'TabWorkspace'
        $tabCtrl.SelectedIndex = 1
    }
})

$script:BtnOpenRun.Add_Click({
    $sel = $script:LstRecentRuns.SelectedItem
    if ($null -ne $sel -and $sel.FullPath) {
        _LoadRunAndRefreshGrid -RunFolder $sel.FullPath
    }
})

$script:LstRecentRuns.Add_MouseDoubleClick({
    $sel = $script:LstRecentRuns.SelectedItem
    if ($null -ne $sel -and $sel.FullPath) {
        _LoadRunAndRefreshGrid -RunFolder $sel.FullPath
    }
})

$script:BtnExportPageCsv.Add_Click({ _ExportPageCsv })

$script:BtnExportRunCsv.Add_Click({ _ExportRunCsv })

$script:BtnCopyDiagnostics.Add_Click({
    $diagText = $script:TxtDiagnostics.Text
    if (-not [string]::IsNullOrEmpty($diagText)) {
        [System.Windows.Clipboard]::SetText($diagText)
        _SetStatus 'Diagnostics copied to clipboard'
    } elseif ($null -ne $script:State.DiagnosticsContext) {
        $txt = Get-DiagnosticsText -RunFolder $script:State.DiagnosticsContext
        $script:TxtDiagnostics.Text = $txt
        [System.Windows.Clipboard]::SetText($txt)
        _SetStatus 'Diagnostics collected and copied'
    }
})

$script:TxtAttributeSearch.Add_TextChanged({
    _FilterAttributes
})

# ── Initialise UI state ────────────────────────────────────────────────────────

$cfg = Get-AppConfig
$script:State.PageSize = $cfg.PageSize

# Restore last dates
if ($cfg.LastStartDate) {
    try { $script:DtpStartDate.SelectedDate = [datetime]::Parse($cfg.LastStartDate) } catch { }
}
if ($cfg.LastEndDate) {
    try { $script:DtpEndDate.SelectedDate = [datetime]::Parse($cfg.LastEndDate) } catch { }
}

_RefreshRecentRuns
_UpdateConnectionStatus
_SetStatus 'Ready'

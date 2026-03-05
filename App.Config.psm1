#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:ConfigDir  = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'GenesysConversationAnalysis')
$script:ConfigFile = [System.IO.Path]::Combine($script:ConfigDir, 'config.json')

$script:DefaultCoreModulePath = 'G:\Development\20_Staging\GenesysCloud\Genesys.Core\src\ps-module\Genesys.Core\Genesys.Core.psd1'
$script:DefaultCatalogPath    = 'G:\Development\20_Staging\GenesysCloud\Genesys.Core\catalog\genesys-core.catalog.json'
$script:DefaultSchemaPath     = 'G:\Development\20_Staging\GenesysCloud\Genesys.Core\catalog\schema\genesys-core.catalog.schema.json'

function _GetDefaultOutputRoot {
    return [System.IO.Path]::Combine($env:LOCALAPPDATA, 'GenesysConversationAnalysis', 'runs')
}

function Get-AppConfig {
    <#
    .SYNOPSIS
        Returns the merged application configuration (persisted file + defaults).
    #>
    $defaults = [ordered]@{
        CoreModulePath  = $script:DefaultCoreModulePath
        CatalogPath     = $script:DefaultCatalogPath
        SchemaPath      = $script:DefaultSchemaPath
        OutputRoot      = _GetDefaultOutputRoot
        Region          = 'mypurecloud.com'
        PageSize        = 50
        PreviewPageSize = 25
        MaxRecentRuns   = 20
        RecentRuns      = @()
        LastStartDate   = ''
        LastEndDate     = ''
        PkceClientId    = ''
        PkceRedirectUri = 'http://localhost:8080/callback'
    }

    if (-not [System.IO.File]::Exists($script:ConfigFile)) {
        return [pscustomobject]$defaults
    }

    try {
        $raw = [System.IO.File]::ReadAllText($script:ConfigFile, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
    } catch {
        Write-Warning "Config file unreadable; using defaults. Error: $_"
        return [pscustomobject]$defaults
    }

    # Merge: fill any missing keys with defaults
    foreach ($key in $defaults.Keys) {
        if ($null -eq $obj.PSObject.Properties[$key]) {
            $obj | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
        }
    }
    return $obj
}

function Save-AppConfig {
    <#
    .SYNOPSIS
        Persists a config object to disk.
    #>
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )
    if (-not [System.IO.Directory]::Exists($script:ConfigDir)) {
        [System.IO.Directory]::CreateDirectory($script:ConfigDir) | Out-Null
    }
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($script:ConfigFile, $json, [System.Text.Encoding]::UTF8)
}

function Update-AppConfig {
    <#
    .SYNOPSIS
        Updates a single config key and persists.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][object]$Value
    )
    $cfg = Get-AppConfig
    $cfg | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    Save-AppConfig -Config $cfg
}

function Add-RecentRun {
    <#
    .SYNOPSIS
        Prepends a run folder to the recent-runs list and trims to MaxRecentRuns.
    #>
    param(
        [Parameter(Mandatory)][string]$RunFolder
    )
    $cfg  = Get-AppConfig
    $runs = @($cfg.RecentRuns) | Where-Object { $_ -ne $RunFolder }
    $runs = @($RunFolder) + @($runs)
    $max  = if ($cfg.MaxRecentRuns -gt 0) { $cfg.MaxRecentRuns } else { 20 }
    if ($runs.Count -gt $max) {
        $runs = $runs[0..($max - 1)]
    }
    $cfg | Add-Member -NotePropertyName 'RecentRuns' -NotePropertyValue $runs -Force
    Save-AppConfig -Config $cfg
}

function Get-RecentRuns {
    <#
    .SYNOPSIS
        Returns the persisted list of recent run folders.
    #>
    $cfg = Get-AppConfig
    return @($cfg.RecentRuns)
}

Export-ModuleMember -Function Get-AppConfig, Save-AppConfig, Update-AppConfig, Add-RecentRun, Get-RecentRuns

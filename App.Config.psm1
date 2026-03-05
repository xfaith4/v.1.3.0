#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:ConfigDir  = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'GenesysConversationAnalysis')
$script:ConfigFile = [System.IO.Path]::Combine($script:ConfigDir, 'config.json')

# Default paths use the v2 modules/ layout.
# These are relative to the Genesys.Core repo root (one level above this repo).
$script:DefaultCoreModulePath = '..\Genesys.Core\modules\Genesys.Core\Genesys.Core.psd1'
$script:DefaultAuthModulePath = '..\Genesys.Core\modules\Genesys.Auth\Genesys.Auth.psd1'

function _GetDefaultOutputRoot {
    return [System.IO.Path]::Combine($env:LOCALAPPDATA, 'GenesysConversationAnalysis', 'runs')
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve-DependencyPaths
# Resolves Genesys.Core and Genesys.Auth module manifest paths using the
# following precedence (first valid path wins):
#   1. Explicit CLI parameters
#   2. Environment variables (GENESYS_CORE_MODULE_PATH / GENESYS_AUTH_MODULE_PATH)
#   3. Repo-local config file (appsettings.json next to this module)
#   4. Auto-detection from ./modules/ subfolder
# Returns a PSCustomObject with CoreModulePath and AuthModulePath.
# Throws a consolidated, actionable error if either path cannot be resolved.
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-DependencyPaths {
    [CmdletBinding()]
    param(
        [string]$GenesysCoreModulePath = '',
        [string]$GenesysAuthModulePath = '',
        [string]$RepoRoot = $PSScriptRoot
    )

    # Build ordered candidate lists per dependency
    $coreCandidates = [ordered]@{}
    $authCandidates = [ordered]@{}

    # Precedence 1: CLI parameters
    if (-not [string]::IsNullOrWhiteSpace($GenesysCoreModulePath)) {
        $coreCandidates['CLI -GenesysCoreModulePath'] = $GenesysCoreModulePath
    }
    if (-not [string]::IsNullOrWhiteSpace($GenesysAuthModulePath)) {
        $authCandidates['CLI -GenesysAuthModulePath'] = $GenesysAuthModulePath
    }

    # Precedence 2: Environment variables
    if (-not [string]::IsNullOrWhiteSpace($env:GENESYS_CORE_MODULE_PATH)) {
        $coreCandidates['env:GENESYS_CORE_MODULE_PATH'] = $env:GENESYS_CORE_MODULE_PATH
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GENESYS_AUTH_MODULE_PATH)) {
        $authCandidates['env:GENESYS_AUTH_MODULE_PATH'] = $env:GENESYS_AUTH_MODULE_PATH
    }

    # Precedence 3: Repo-local config file (appsettings.json)
    $appSettingsPath = [System.IO.Path]::Combine($RepoRoot, 'appsettings.json')
    if ([System.IO.File]::Exists($appSettingsPath)) {
        try {
            $appCfg = [System.IO.File]::ReadAllText($appSettingsPath) | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($appCfg.GenesysCoreModulePath)) {
                $coreCandidates["appsettings.json 'GenesysCoreModulePath'"] = $appCfg.GenesysCoreModulePath
            }
            if (-not [string]::IsNullOrWhiteSpace($appCfg.GenesysAuthModulePath)) {
                $authCandidates["appsettings.json 'GenesysAuthModulePath'"] = $appCfg.GenesysAuthModulePath
            }
        } catch {
            Write-Verbose "Could not parse appsettings.json: $_"
        }
    }

    # Precedence 4: Auto-detection from ./modules/ subfolder
    $autoModulesDir = [System.IO.Path]::Combine($RepoRoot, 'modules')
    $autoCore = [System.IO.Path]::Combine($autoModulesDir, 'Genesys.Core', 'Genesys.Core.psd1')
    $autoAuth = [System.IO.Path]::Combine($autoModulesDir, 'Genesys.Auth', 'Genesys.Auth.psd1')
    if ([System.IO.File]::Exists($autoCore)) {
        $coreCandidates['auto-detect ./modules/Genesys.Core/Genesys.Core.psd1'] = $autoCore
    }
    if ([System.IO.File]::Exists($autoAuth)) {
        $authCandidates['auto-detect ./modules/Genesys.Auth/Genesys.Auth.psd1'] = $autoAuth
    }

    # Resolve each path: first valid .psd1 that exists on disk wins
    function _FirstValid {
        param([ordered]$candidates, [string]$repoRoot)
        foreach ($entry in $candidates.GetEnumerator()) {
            $raw = $entry.Value
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            if (-not $raw.EndsWith('.psd1', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            # Try as absolute path first
            if ([System.IO.File]::Exists($raw)) { return $raw }
            # Try as path relative to repo root
            $abs = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($repoRoot, $raw))
            if ([System.IO.File]::Exists($abs)) { return $abs }
        }
        return $null
    }

    $corePath = _FirstValid $coreCandidates $RepoRoot
    $authPath = _FirstValid $authCandidates $RepoRoot

    # Build consolidated error if either path is missing
    $errors = @()
    if (-not $corePath) {
        $tried = if ($coreCandidates.Count -gt 0) { $coreCandidates.Keys -join ' | ' } else { '(no sources tried)' }
        $errors += @"
  Genesys.Core module not resolved. Sources tried: $tried
  Fix options (choose one):
    a) Pass CLI param:     pwsh -File ./App.ps1 -GenesysCoreModulePath "<abs-path>"
    b) Set env var:        `$env:GENESYS_CORE_MODULE_PATH = "C:\Source\Genesys.Core\modules\Genesys.Core\Genesys.Core.psd1"
    c) Create appsettings.json in repo root: { "GenesysCoreModulePath": "<abs-path>" }
    d) Place module at:    .\modules\Genesys.Core\Genesys.Core.psd1
"@
    }
    if (-not $authPath) {
        $tried = if ($authCandidates.Count -gt 0) { $authCandidates.Keys -join ' | ' } else { '(no sources tried)' }
        $errors += @"
  Genesys.Auth module not resolved. Sources tried: $tried
  Fix options (choose one):
    a) Pass CLI param:     pwsh -File ./App.ps1 -GenesysAuthModulePath "<abs-path>"
    b) Set env var:        `$env:GENESYS_AUTH_MODULE_PATH = "C:\Source\Genesys.Core\modules\Genesys.Auth\Genesys.Auth.psd1"
    c) Create appsettings.json in repo root: { "GenesysAuthModulePath": "<abs-path>" }
    d) Place module at:    .\modules\Genesys.Auth\Genesys.Auth.psd1
"@
    }

    if ($errors.Count -gt 0) {
        throw "Dependency resolution failed:`n`n$($errors -join "`n")`n`nFor offline/UI-only mode: pwsh -File ./App.ps1 -Offline"
    }

    return [pscustomobject]@{
        CoreModulePath = $corePath
        AuthModulePath = $authPath
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Invoke-AuthPreflight
# Validates that the required environment variables for the chosen auth mode
# are present. Non-fatal: emits warnings but does not throw, because auth
# is completed in the UI via the Connect button.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-AuthPreflight {
    [CmdletBinding()]
    param(
        [string]$AuthMode = ''
    )

    if ([string]::IsNullOrWhiteSpace($AuthMode)) {
        $AuthMode = if ($env:GENESYS_AUTH_MODE) { $env:GENESYS_AUTH_MODE } else { 'client_credentials' }
    }

    $missing = [System.Collections.Generic.List[string]]::new()

    switch ($AuthMode.ToLower()) {
        'client_credentials' {
            if ([string]::IsNullOrWhiteSpace($env:GENESYS_CLIENT_ID))     { [void]$missing.Add('GENESYS_CLIENT_ID     (format: UUID, e.g. a1b2c3d4-...)') }
            if ([string]::IsNullOrWhiteSpace($env:GENESYS_CLIENT_SECRET))  { [void]$missing.Add('GENESYS_CLIENT_SECRET (format: secret string)') }
            if ([string]::IsNullOrWhiteSpace($env:GENESYS_REGION))         { [void]$missing.Add('GENESYS_REGION        (format: e.g. usw2.pure.cloud or mypurecloud.com)') }
        }
        'pkce' {
            if ([string]::IsNullOrWhiteSpace($env:GENESYS_CLIENT_ID))     { [void]$missing.Add('GENESYS_CLIENT_ID     (format: UUID)') }
            if ([string]::IsNullOrWhiteSpace($env:GENESYS_REGION))         { [void]$missing.Add('GENESYS_REGION        (format: e.g. usw2.pure.cloud)') }
        }
        'bearer' {
            if ([string]::IsNullOrWhiteSpace($env:GENESYS_BEARER_TOKEN))   { [void]$missing.Add('GENESYS_BEARER_TOKEN') }
        }
        default {
            Write-Warning "Unknown GENESYS_AUTH_MODE='$AuthMode'. Supported: client_credentials, pkce, bearer. Checking client_credentials."
            if ([string]::IsNullOrWhiteSpace($env:GENESYS_CLIENT_ID))     { [void]$missing.Add('GENESYS_CLIENT_ID') }
            if ([string]::IsNullOrWhiteSpace($env:GENESYS_CLIENT_SECRET))  { [void]$missing.Add('GENESYS_CLIENT_SECRET') }
            if ([string]::IsNullOrWhiteSpace($env:GENESYS_REGION))         { [void]$missing.Add('GENESYS_REGION') }
        }
    }

    if ($missing.Count -gt 0) {
        $missingList = ($missing | ForEach-Object { "    `$env:$_" }) -join "`n"
        Write-Warning @"
Auth preflight warning (mode: $AuthMode) — missing environment variables:
$missingList

Set them before clicking Connect, or use PKCE browser login in the UI.
Quick fix:
    `$env:GENESYS_CLIENT_ID     = '<your-client-id>'
    `$env:GENESYS_CLIENT_SECRET = '<your-client-secret>'
    `$env:GENESYS_REGION        = 'usw2.pure.cloud'

Run smoke test for full diagnostics:
    pwsh -NoProfile -File ./scripts/Invoke-Smoke.ps1 -Verbose
"@
    } else {
        Write-Verbose "Auth preflight: OK (mode=$AuthMode)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Application config (persisted to %LOCALAPPDATA%)
# ─────────────────────────────────────────────────────────────────────────────

function Get-AppConfig {
    <#
    .SYNOPSIS
        Returns the merged application configuration (persisted file + defaults).
    #>
    $defaults = [ordered]@{
        CoreModulePath  = $script:DefaultCoreModulePath
        AuthModulePath  = $script:DefaultAuthModulePath
        OutputRoot      = _GetDefaultOutputRoot
        Region          = 'usw2.pure.cloud'
        PageSize        = 50
        PreviewPageSize = 25
        MaxRecentRuns   = 20
        RecentRuns      = @()
        LastStartDate   = ''
        LastEndDate     = ''
        PkceClientId    = ''
        PkceRedirectUri = 'http://localhost:8085/callback'
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

Export-ModuleMember -Function `
    Resolve-DependencyPaths, `
    Invoke-AuthPreflight, `
    Get-AppConfig, Save-AppConfig, Update-AppConfig, `
    Add-RecentRun, Get-RecentRuns

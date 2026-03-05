#Requires -Version 5.1
[CmdletBinding()]
param(
    # Explicit path to Genesys.Core module manifest (.psd1).
    # Overrides env:GENESYS_CORE_MODULE_PATH and appsettings.json.
    [string]$GenesysCoreModulePath = '',

    # Explicit path to Genesys.Auth module manifest (.psd1).
    # Overrides env:GENESYS_AUTH_MODULE_PATH and appsettings.json.
    [string]$GenesysAuthModulePath = '',

    # Skip dependency resolution and auth preflight; launch UI in offline/demo mode.
    # Equivalent to setting APP_OFFLINE=1 in the environment.
    [switch]$Offline
)
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Genesys Conversation Analysis - canonical entrypoint.
.DESCRIPTION
    Supported launch command:
        pwsh -NoProfile -ExecutionPolicy Bypass -File ./App.ps1

    Startup sequence:
        1. Import App.Config.psm1 (provides Resolve-DependencyPaths, Invoke-AuthPreflight).
        2. Resolve Genesys.Core and Genesys.Auth module paths (4-level precedence).
        3. Set GENESYS_CORE_MODULE_PATH / GENESYS_AUTH_MODULE_PATH for child modules.
        4. Auth preflight: warn if required env vars are missing (non-fatal).
        5. Load WPF assemblies.
        6. Import XAML/App.UI.ps1 and launch Show-ConversationAnalysisWindow.

    Offline mode (-Offline or APP_OFFLINE=1):
        Steps 2-4 are skipped. The UI launches with extraction features disabled.

    Path resolution precedence (first valid .psd1 wins):
        (a) CLI parameters  -GenesysCoreModulePath / -GenesysAuthModulePath
        (b) Environment     GENESYS_CORE_MODULE_PATH / GENESYS_AUTH_MODULE_PATH
        (c) Repo config     ./appsettings.json  (keys: GenesysCoreModulePath, GenesysAuthModulePath)
        (d) Auto-detect     ./modules/Genesys.Core/Genesys.Core.psd1 (if present)

    Auth mode (GENESYS_AUTH_MODE env var, default: client_credentials):
        client_credentials  -> requires GENESYS_CLIENT_ID, GENESYS_CLIENT_SECRET, GENESYS_REGION
        pkce                -> requires GENESYS_CLIENT_ID, GENESYS_REGION
        bearer              -> requires GENESYS_BEARER_TOKEN

    If startup fails: run ./scripts/Invoke-Smoke.ps1 -Verbose for diagnostics.
#>

$AppDir = $PSScriptRoot
if (-not $AppDir) { $AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

# ── 1. Import App.Config.psm1 ─────────────────────────────────────────────────
try {
    Import-Module (Join-Path $AppDir 'App.Config.psm1') -Force -ErrorAction Stop
} catch {
    Write-Error "Fatal: Cannot import App.Config.psm1 from '$AppDir': $_"
    exit 1
}

# ── 2 & 3. Resolve dependency paths and propagate as env vars ─────────────────
$isOffline = $Offline.IsPresent -or ($env:APP_OFFLINE -eq '1')

if (-not $isOffline) {
    try {
        $resolved = Resolve-DependencyPaths `
            -GenesysCoreModulePath $GenesysCoreModulePath `
            -GenesysAuthModulePath $GenesysAuthModulePath `
            -RepoRoot              $AppDir
        # Propagate to environment so XAML child modules can find the dependencies.
        $env:GENESYS_CORE_MODULE_PATH = $resolved.CoreModulePath
        $env:GENESYS_AUTH_MODULE_PATH = $resolved.AuthModulePath
        Write-Verbose "Core  : $($resolved.CoreModulePath)"
        Write-Verbose "Auth  : $($resolved.AuthModulePath)"
    } catch {
        # Show a console error + a message box so the failure is visible
        # whether run interactively or via shortcut.
        $errMsg = "Startup failed - dependency resolution error:`n`n$_"
        Write-Error $errMsg
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
            [System.Windows.MessageBox]::Show(
                $errMsg,
                'Genesys Conversation Analysis - Startup Error',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        } catch { }
        exit 1
    }

    # ── 4. Auth preflight (non-fatal: warns but does not block launch) ────────
    Invoke-AuthPreflight
} else {
    Write-Host '[Offline] Skipping dependency resolution and auth preflight. UI runs in read-only demo mode.'
}

# ── 5. Load WPF assemblies ────────────────────────────────────────────────────
try {
    Add-Type -AssemblyName PresentationFramework  -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore       -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase            -ErrorAction Stop
    Add-Type -AssemblyName System.Xaml            -ErrorAction Stop
    Add-Type -AssemblyName Microsoft.Win32.Primitives -ErrorAction SilentlyContinue
} catch {
    Write-Error "Fatal: Failed to load WPF assemblies. This app requires Windows with .NET/WPF: $_"
    exit 1
}

# ── 6. Import XAML/App.UI.ps1 and launch UI ──────────────────────────────────
$xamlDir = Join-Path $AppDir 'XAML'
$uiScript = Join-Path $xamlDir 'App.UI.ps1'

if (-not [System.IO.File]::Exists($uiScript)) {
    $msg = "Fatal: UI script not found at '$uiScript'. Repository may be incomplete."
    Write-Error $msg
    try {
        [System.Windows.MessageBox]::Show($msg, 'Genesys Conversation Analysis - Startup Error',
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    } catch { }
    exit 1
}

try {
    Import-Module $uiScript -Force -ErrorAction Stop
    Show-ConversationAnalysisWindow
} catch {
    $msg = "Fatal startup error in UI:`n`n$_`n`nRun ./scripts/Invoke-Smoke.ps1 -Verbose for diagnostics."
    Write-Error $msg
    try {
        [System.Windows.MessageBox]::Show($msg, 'Genesys Conversation Analysis - Startup Error',
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    } catch { }
    exit 1
}

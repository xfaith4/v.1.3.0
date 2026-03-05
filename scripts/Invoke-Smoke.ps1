#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke test – verifies day-one readiness of Genesys Conversation Analysis.
.DESCRIPTION
    Runs a series of checks and exits with code 0 (PASS) or 1 (FAIL).

    Checks performed:
        1. Imports   – App.Config.psm1 and XAML modules can be imported.
        2. Paths     – Resolve-DependencyPaths finds Genesys.Core + Genesys.Auth.
        3. Auth      – Required env vars are present for chosen auth mode.
        4. Token     – (Online only) Client-Credentials token acquisition succeeds.
        5. UI Artefact – MainWindow.xaml exists and is parseable (x:Class stripped).

    Usage:
        # Offline (no secrets needed – validates imports and XAML only):
        pwsh -NoProfile -File ./scripts/Invoke-Smoke.ps1 -Offline

        # Online (requires env vars GENESYS_CLIENT_ID / SECRET / REGION):
        pwsh -NoProfile -File ./scripts/Invoke-Smoke.ps1

        # With explicit paths:
        pwsh -NoProfile -File ./scripts/Invoke-Smoke.ps1 `
            -GenesysCoreModulePath 'C:\Source\Genesys.Core\modules\Genesys.Core\Genesys.Core.psd1' `
            -GenesysAuthModulePath 'C:\Source\Genesys.Core\modules\Genesys.Auth\Genesys.Auth.psd1'

    Expected output on success:
        [PASS] Imports
        [PASS] Paths
        [PASS] Auth env-vars
        [PASS] Token acquisition      (online only)
        [PASS] XAML artefact
        --- Smoke: PASS ---

    Exit codes:
        0 = all checks passed
        1 = one or more checks failed
#>
[CmdletBinding()]
param(
    [string]$GenesysCoreModulePath = '',
    [string]$GenesysAuthModulePath = '',
    [switch]$Offline
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # collect failures, don't abort early

$ScriptDir = $PSScriptRoot
$RepoRoot  = Split-Path -Parent $ScriptDir   # scripts/ is one level inside repo root

$results  = [ordered]@{}
$anyFail  = $false

function _Pass($label) {
    $script:results[$label] = 'PASS'
    Write-Host "[PASS] $label" -ForegroundColor Green
}

function _Fail($label, $reason) {
    $script:results[$label] = "FAIL: $reason"
    $script:anyFail = $true
    Write-Host "[FAIL] $label" -ForegroundColor Red
    Write-Host "       $reason" -ForegroundColor Yellow
}

function _Skip($label, $reason) {
    $script:results[$label] = "SKIP: $reason"
    Write-Host "[SKIP] $label  ($reason)" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "=== Genesys Conversation Analysis – Smoke Test ===" -ForegroundColor White
Write-Host "    Repo root : $RepoRoot"
Write-Host "    Offline   : $($Offline.IsPresent -or $env:APP_OFFLINE -eq '1')"
Write-Host "    Auth mode : $(if ($env:GENESYS_AUTH_MODE) { $env:GENESYS_AUTH_MODE } else { 'client_credentials (default)' })"
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 1 – Module imports
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "--- Check 1: Module imports ---"
$label1 = 'Imports'
try {
    Import-Module (Join-Path $RepoRoot 'App.Config.psm1') -Force -ErrorAction Stop
    $xamlDir = Join-Path $RepoRoot 'XAML'
    Import-Module (Join-Path $xamlDir 'App.Auth.psm1')        -Force -ErrorAction Stop
    Import-Module (Join-Path $xamlDir 'App.CoreAdapter.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $xamlDir 'App.Index.psm1')       -Force -ErrorAction Stop
    Import-Module (Join-Path $xamlDir 'App.Export.psm1')      -Force -ErrorAction Stop
    Import-Module (Join-Path $xamlDir 'App.Reporting.psm1')   -Force -ErrorAction Stop
    _Pass $label1
} catch {
    _Fail $label1 "$_"
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 2 – Dependency path resolution
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Check 2: Dependency paths ---"
$label2  = 'Paths'
$resolved = $null
$isOffline = $Offline.IsPresent -or ($env:APP_OFFLINE -eq '1')

if ($isOffline) {
    _Skip $label2 'offline mode'
} else {
    try {
        $resolved = Resolve-DependencyPaths `
            -GenesysCoreModulePath $GenesysCoreModulePath `
            -GenesysAuthModulePath $GenesysAuthModulePath `
            -RepoRoot              $RepoRoot
        Write-Verbose "  Core : $($resolved.CoreModulePath)"
        Write-Verbose "  Auth : $($resolved.AuthModulePath)"
        _Pass $label2
    } catch {
        _Fail $label2 "$_"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 3 – Auth environment variables
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Check 3: Auth environment variables ---"
$label3   = 'Auth env-vars'
$authMode = if ($env:GENESYS_AUTH_MODE) { $env:GENESYS_AUTH_MODE.ToLower() } else { 'client_credentials' }

if ($isOffline) {
    _Skip $label3 'offline mode'
} else {
    $missing = @()
    switch ($authMode) {
        'client_credentials' {
            if (-not $env:GENESYS_CLIENT_ID)     { $missing += 'GENESYS_CLIENT_ID' }
            if (-not $env:GENESYS_CLIENT_SECRET)  { $missing += 'GENESYS_CLIENT_SECRET' }
            if (-not $env:GENESYS_REGION)         { $missing += 'GENESYS_REGION' }
        }
        'pkce' {
            if (-not $env:GENESYS_CLIENT_ID)     { $missing += 'GENESYS_CLIENT_ID' }
            if (-not $env:GENESYS_REGION)         { $missing += 'GENESYS_REGION' }
        }
        'bearer' {
            if (-not $env:GENESYS_BEARER_TOKEN)   { $missing += 'GENESYS_BEARER_TOKEN' }
        }
        default {
            if (-not $env:GENESYS_CLIENT_ID)     { $missing += 'GENESYS_CLIENT_ID' }
            if (-not $env:GENESYS_CLIENT_SECRET)  { $missing += 'GENESYS_CLIENT_SECRET' }
            if (-not $env:GENESYS_REGION)         { $missing += 'GENESYS_REGION' }
        }
    }

    if ($missing.Count -gt 0) {
        _Fail $label3 "Missing env vars for mode '$authMode': $($missing -join ', ')"
        Write-Host "" -ForegroundColor Yellow
        Write-Host "  Quick fix:" -ForegroundColor Yellow
        foreach ($v in $missing) {
            Write-Host "    `$env:$v = '<value>'" -ForegroundColor Yellow
        }
    } else {
        _Pass $label3
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 4 – Token acquisition (online + client_credentials only)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Check 4: Token acquisition ---"
$label4 = 'Token acquisition'

if ($isOffline) {
    _Skip $label4 'offline mode'
} elseif ($authMode -ne 'client_credentials') {
    _Skip $label4 "auth mode is '$authMode' (only client_credentials can be tested headlessly)"
} elseif ($missing.Count -gt 0) {
    _Skip $label4 'auth env-vars check failed'
} elseif ($null -eq $resolved) {
    _Skip $label4 'path resolution failed'
} else {
    try {
        # Set env vars so App.Auth.psm1 can load Genesys.Auth
        $env:GENESYS_AUTH_MODULE_PATH = $resolved.AuthModulePath

        $token = Connect-App `
            -ClientId     $env:GENESYS_CLIENT_ID `
            -ClientSecret $env:GENESYS_CLIENT_SECRET `
            -Region       $env:GENESYS_REGION

        if ($null -eq $token) { throw 'Connect-App returned null' }
        # Don't log the token value – just confirm it's non-null
        Write-Verbose "  Token type   : $($token.GetType().Name)"
        _Pass $label4
    } catch {
        # Sanitize error: remove any potential secret leakage from the message
        $safeMsg = "$_" -replace $env:GENESYS_CLIENT_SECRET, '<SECRET>'
        _Fail $label4 $safeMsg
        Write-Host "" -ForegroundColor Yellow
        Write-Host "  Common causes:" -ForegroundColor Yellow
        Write-Host "    - Invalid client ID or secret" -ForegroundColor Yellow
        Write-Host "    - Region format wrong (use e.g. usw2.pure.cloud, NOT https://...)" -ForegroundColor Yellow
        Write-Host "    - OAuth client does not have analytics permissions" -ForegroundColor Yellow
        Write-Host "    - Network/firewall blocking outbound HTTPS to Genesys Cloud" -ForegroundColor Yellow
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 5 – XAML artefact (MainWindow.xaml parseable)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Check 5: XAML artefact ---"
$label5   = 'XAML artefact'
$xamlPath = Join-Path $RepoRoot 'XAML\MainWindow.xaml'

try {
    if (-not [System.IO.File]::Exists($xamlPath)) {
        throw "MainWindow.xaml not found at: $xamlPath"
    }

    # Load WPF assemblies (may already be loaded)
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue
    Add-Type -AssemblyName WindowsBase           -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Xaml           -ErrorAction SilentlyContinue

    $xamlContent = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
    $xamlContent = $xamlContent -replace 'x:Class="[^"]*"', ''   # strip backing class

    $reader    = New-Object System.IO.StringReader($xamlContent)
    $xmlReader = [System.Xml.XmlReader]::Create($reader)
    try {
        $window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
        if ($null -eq $window) { throw 'XamlReader.Load returned null' }
        Write-Verbose "  XAML parsed OK: $($window.GetType().Name)"
    } finally {
        $xmlReader.Dispose()
        $reader.Dispose()
    }
    _Pass $label5
} catch {
    _Fail $label5 "$_"
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor White
foreach ($entry in $results.GetEnumerator()) {
    $color = switch -Wildcard ($entry.Value) {
        'PASS' { 'Green' }
        'SKIP*' { 'Cyan' }
        default { 'Red' }
    }
    Write-Host ("  {0,-30} {1}" -f $entry.Key, $entry.Value) -ForegroundColor $color
}

Write-Host ""
if ($anyFail) {
    Write-Host "--- Smoke: FAIL ---" -ForegroundColor Red
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Fix each [FAIL] item above." -ForegroundColor Yellow
    Write-Host "  2. Re-run: pwsh -NoProfile -File ./scripts/Invoke-Smoke.ps1 -Verbose" -ForegroundColor Yellow
    Write-Host "  3. If path issues persist, set env vars explicitly and re-run." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "--- Smoke: PASS ---" -ForegroundColor Green
    Write-Host ""
    Write-Host "The app is ready. Launch with:" -ForegroundColor White
    Write-Host "  pwsh -NoProfile -ExecutionPolicy Bypass -File ./App.ps1" -ForegroundColor White
    exit 0
}

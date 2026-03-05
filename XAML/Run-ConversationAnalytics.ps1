#Requires -Version 5.1
<#
.SYNOPSIS
    DEPRECATED launcher – use ./App.ps1 instead.
.DESCRIPTION
    This script is a backwards-compatibility shim. It forwards all arguments
    to the canonical entrypoint (./App.ps1) and prints a deprecation warning.

    Supported launch command (canonical):
        pwsh -NoProfile -ExecutionPolicy Bypass -File ./App.ps1

    Supported parameters (forwarded to App.ps1):
        -GenesysCoreModulePath <path>   Override Genesys.Core module path
        -GenesysAuthModulePath <path>   Override Genesys.Auth module path
        -Offline                        Start in offline/demo mode
#>
[CmdletBinding()]
param(
    [string]$GenesysCoreModulePath = $env:GENESYS_CORE_MODULE_PATH,
    [string]$GenesysAuthModulePath = $env:GENESYS_AUTH_MODULE_PATH,
    [switch]$Offline
)

Write-Warning @"

  DEPRECATED LAUNCHER
  -------------------
  This script (XAML/Run-ConversationAnalytics.ps1) is deprecated and will be
  removed in a future release.

  Use the canonical entrypoint instead:
      pwsh -NoProfile -ExecutionPolicy Bypass -File ./App.ps1

  Forwarding to ./App.ps1 now...

"@

$canonicalEntry = Join-Path (Split-Path -Parent $PSScriptRoot) 'App.ps1'

if (-not (Test-Path -LiteralPath $canonicalEntry)) {
    Write-Error "Cannot find canonical entrypoint at: $canonicalEntry"
    exit 1
}

$forwardParams = @{}
if ($GenesysCoreModulePath) { $forwardParams['GenesysCoreModulePath'] = $GenesysCoreModulePath }
if ($GenesysAuthModulePath) { $forwardParams['GenesysAuthModulePath'] = $GenesysAuthModulePath }
if ($Offline)               { $forwardParams['Offline']               = $true }

& $canonicalEntry @forwardParams
exit $LASTEXITCODE

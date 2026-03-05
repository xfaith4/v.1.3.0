[CmdletBinding()]
param (
    # This makes the app detachable, as required by acceptance tests.
    # In a CI/CD or production deployment, this would be set globally.
    [string]$GenesysCoreModulePath = $env:GENESYS_CORE_MODULE_PATH,
    [string]$GenesysAuthModulePath = $env:GENESYS_AUTH_MODULE_PATH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Set environment variables for the child modules to consume.
# This is the cleanest way to pass dependency paths without polluting function signatures.
if ($GenesysCoreModulePath) { $env:GENESYS_CORE_MODULE_PATH = $GenesysCoreModulePath }
if ($GenesysAuthModulePath) { $env:GENESYS_AUTH_MODULE_PATH = $GenesysAuthModulePath }

if (-not $env:GENESYS_CORE_MODULE_PATH) {
    throw "FATAL: GENESYS_CORE_MODULE_PATH environment variable is not set. Cannot locate Genesys.Core."
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Import the UI module and start the application.
Import-Module (Join-Path $scriptRoot 'App.UI.ps1') -Force

Show-ConversationAnalysisWindow

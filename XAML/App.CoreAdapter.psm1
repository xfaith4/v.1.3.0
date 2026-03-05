#Requires -Version 5.1
Set-StrictMode -Version Latest

function Initialize-CoreAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogPath,

        [Parameter(Mandatory = $true)]
        [string]$SchemaPath
    )

    # Gate D: This is the ONLY file that imports Genesys.Core
    if (-not $env:GENESYS_CORE_MODULE_PATH) {
        throw "GENESYS_CORE_MODULE_PATH environment variable is not set. This is required to locate Genesys.Core."
    }
    if (-not (Test-Path $env:GENESYS_CORE_MODULE_PATH)) {
        throw "Genesys.Core module not found at path: $($env:GENESYS_CORE_MODULE_PATH)"
    }
    Import-Module $env:GENESYS_CORE_MODULE_PATH -Force

    # Gate A: Validate the catalog at startup.
    try {
        Assert-Catalog -CatalogPath $CatalogPath -SchemaPath $SchemaPath -Strict
    }
    catch {
        throw "Catalog validation failed: $_"
    }
}

function Start-CoreExtraction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatasetKey,

        [Parameter(Mandatory = $true)]
        [hashtable]$AuthContext,

        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [hashtable]$DatasetParameters
    )

    # Gate B: All extraction MUST happen via Invoke-Dataset.
    # The call is wrapped in Start-Job to keep the UI responsive.
    #
    # IMPORTANT: Start-Job creates a clean PowerShell runspace that does not
    # inherit the parent session's loaded modules.  We must explicitly import
    # Genesys.Core inside the scriptblock so Invoke-Dataset is available.
    $coreModulePath = $env:GENESYS_CORE_MODULE_PATH
    if ([string]::IsNullOrWhiteSpace($coreModulePath)) {
        throw "GENESYS_CORE_MODULE_PATH is not set. Cannot start extraction job."
    }

    $jobParams = [ordered]@{
        DatasetKey        = $DatasetKey
        AuthContext       = $AuthContext
        OutputRoot        = $OutputRoot
        DatasetParameters = $DatasetParameters
    }

    $scriptBlock = {
        param($corePath, $params)
        Import-Module $corePath -Force -ErrorAction Stop
        Invoke-Dataset @params
    }
    return Start-Job -ScriptBlock $scriptBlock -ArgumentList $coreModulePath, $jobParams
}

Export-ModuleMember -Function 'Initialize-CoreAdapter', 'Start-CoreExtraction'

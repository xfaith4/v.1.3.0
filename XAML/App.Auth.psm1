#Requires -Version 5.1

function Connect-App {
    [CmdletBinding()]
    param(
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$Region
    )

    # Gate E: Use the shared Genesys.Auth module if it exists.
    if (-not $env:GENESYS_AUTH_MODULE_PATH) {
        throw "GENESYS_AUTH_MODULE_PATH is not defined. Cannot perform authentication."
    }
    if (-not (Test-Path $env:GENESYS_AUTH_MODULE_PATH)) {
        throw "Genesys.Auth module not found at '$($env:GENESYS_AUTH_MODULE_PATH)'"
    }

    Import-Module $env:GENESYS_AUTH_MODULE_PATH -Force

    # Delegate directly to the Auth module's Client Credentials flow.
    return Connect-GenesysCloudApp -ClientId $ClientId -ClientSecret $ClientSecret -Region $Region
}

function Disconnect-App {
    # If the shared Auth module supports a disconnect/clear function, call it here.
    if (Get-Command 'Clear-StoredToken' -ErrorAction SilentlyContinue) {
        Clear-StoredToken
    }
}

Export-ModuleMember -Function 'Connect-App', 'Disconnect-App'

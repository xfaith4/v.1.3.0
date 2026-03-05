#Requires -Version 5.1
Set-StrictMode -Version Latest

function Connect-App {
    [CmdletBinding()]
    param(
        [string]$ClientId     = '',
        [string]$ClientSecret = '',
        [string]$Region       = ''
    )

    # Resolve region fallback once.
    if ([string]::IsNullOrWhiteSpace($Region)) {
        $Region = if ($env:GENESYS_REGION) { $env:GENESYS_REGION } else { 'usw2.pure.cloud' }
    }

    $authMode = if ($env:GENESYS_AUTH_MODE) { $env:GENESYS_AUTH_MODE.ToLower() } else { 'client_credentials' }

    switch ($authMode) {
        'bearer' {
            # Gate E (bearer path): construct an AuthContext directly from the supplied token.
            $token = $env:GENESYS_BEARER_TOKEN
            if ([string]::IsNullOrWhiteSpace($token)) {
                throw "GENESYS_BEARER_TOKEN must be set when GENESYS_AUTH_MODE=bearer."
            }
            return [PSCustomObject]@{
                AccessToken = $token
                Region      = $Region
                AuthMode    = 'bearer'
            }
        }
        'pkce' {
            # PKCE requires an interactive browser redirect and cannot be completed
            # headlessly via a simple Connect-App call.
            throw "PKCE authentication requires an interactive browser flow and cannot be used via the Connect button.`n`nTo resolve: set GENESYS_AUTH_MODE to 'client_credentials' or 'bearer'."
        }
        default {
            # Gate E (client_credentials path): delegate to the shared Genesys.Auth module.
            if ([string]::IsNullOrWhiteSpace($env:GENESYS_AUTH_MODULE_PATH)) {
                throw "GENESYS_AUTH_MODULE_PATH is not defined. Cannot perform authentication."
            }
            if (-not (Test-Path $env:GENESYS_AUTH_MODULE_PATH)) {
                throw "Genesys.Auth module not found at '$($env:GENESYS_AUTH_MODULE_PATH)'."
            }
            Import-Module $env:GENESYS_AUTH_MODULE_PATH -Force
            return Connect-GenesysCloudApp -ClientId $ClientId -ClientSecret $ClientSecret -Region $Region
        }
    }
}

function Disconnect-App {
    # If the shared Auth module supports a disconnect/clear function, call it here.
    if (Get-Command 'Clear-StoredToken' -ErrorAction SilentlyContinue) {
        Clear-StoredToken
    }
}

Export-ModuleMember -Function 'Connect-App', 'Disconnect-App'

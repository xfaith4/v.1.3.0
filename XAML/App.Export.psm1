#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Export-RunToCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunFolder,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $dataFolder = Join-Path $RunFolder 'data'
    $dataFiles = Get-ChildItem -Path $dataFolder -Filter '*.jsonl' -File
    if (-not $dataFiles) {
        throw "No data files found in '$dataFolder'."
    }

    # This pipeline streams the data, which is critical for large runs.
    # Get-Content reads line-by-line, ConvertFrom-Json processes one object,
    # and Export-Csv appends to the file. Memory usage stays low.
    Get-Content -Path $dataFiles.FullName |
        ConvertFrom-Json |
        Select-Object conversationId, conversationStart, conversationEnd, @{N='ParticipantCount';E={$_.participants.Count}} | # Add more flattened properties here
        Export-Csv -Path $OutputPath -NoTypeInformation
}

Export-ModuleMember -Function 'Export-RunToCsv'

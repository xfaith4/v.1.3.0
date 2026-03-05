#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Build-RunIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunFolder
    )

    $dataFolder = Join-Path $RunFolder 'data'
    $indexPath = Join-Path $RunFolder 'index.jsonl'
    $index = [System.Collections.Generic.List[object]]::new()

    $dataFiles = Get-ChildItem -Path $dataFolder -Filter '*.jsonl' -File
    if (-not $dataFiles) { return @() }

    foreach ($file in $dataFiles) {
        $filePath = $file.FullName
        $byteOffset = 0
        $encoding = [System.Text.Encoding]::UTF8

        # Use StreamReader for efficient line-by-line reading without loading the whole file
        $reader = [System.IO.StreamReader]::new($filePath, $encoding)
        try {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                $lineBytes = $encoding.GetByteCount($line) + $encoding.GetByteCount([Environment]::NewLine)

                if ([string]::IsNullOrWhiteSpace($line)) {
                    $byteOffset += $lineBytes
                    continue
                }

                # Parse only enough to get key fields for the index
                # This is faster than a full ConvertFrom-Json on every line
                $convIdMatch = [regex]::Match($line, '"conversationId":\s*"([^"]+)"')

                if ($convIdMatch.Success) {
                    $convId = $convIdMatch.Groups[1].Value

                    # Extract a few other useful fields for the grid display
                    $startTimeMatch = [regex]::Match($line, '"conversationStart":\s*"([^"]+)"')

                    # Extract arrays of IDs for powerful local filtering and reporting.
                    # This is a huge performance win over parsing the full JSON later.
                    $divisionIds = @([regex]::Matches($line, '"divisionIds":\s*\[([^\]]+)\]') | ForEach-Object { $_.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim().Trim('"') } })
                    $userIds = @([regex]::Matches($line, '"userId":\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
                    $queueIds = @([regex]::Matches($line, '"queueId":\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })

                    # Extract direction – Genesys surfaces this as originatingDirection at
                    # conversation level or as direction at session level; try both.
                    $dirMatch = [regex]::Match($line, '"originatingDirection":\s*"([^"]+)"')
                    if (-not $dirMatch.Success) {
                        $dirMatch = [regex]::Match($line, '"direction":\s*"([^"]+)"')
                    }
                    $direction = if ($dirMatch.Success) { $dirMatch.Groups[1].Value } else { '' }

                    # Extract the first mediaType found (session-level field).
                    $mediaMatch = [regex]::Match($line, '"mediaType":\s*"([^"]+)"')
                    $mediaType  = if ($mediaMatch.Success) { $mediaMatch.Groups[1].Value } else { '' }

                    $indexEntry = [PSCustomObject]@{
                        ConversationId    = $convId
                        File              = $filePath
                        Offset            = $byteOffset
                        # Pre-parsed fields for grid performance and filtering
                        ConversationStart = if ($startTimeMatch.Success) { [datetime]$startTimeMatch.Groups[1].Value } else { $null }
                        Direction         = $direction
                        MediaType         = $mediaType
                        # Store unique IDs for reporting and filtering
                        DivisionIds       = $divisionIds | Select-Object -Unique
                        UserIds           = $userIds | Select-Object -Unique
                        QueueIds          = $queueIds | Select-Object -Unique
                    }
                    $index.Add($indexEntry)
                }
                $byteOffset += $lineBytes
            }
        }
        finally {
            if ($reader) { $reader.Dispose() }
        }
    }

    # Save the index to the run folder
    $index.ToArray() | ConvertTo-Json -Compress | Set-Content -Path $indexPath -Encoding UTF8

    return $index.ToArray()
}

function Get-RunPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Index,

        [Parameter(Mandatory = $true)]
        [int]$PageIndex,

        [Parameter(Mandatory = $true)]
        [int]$PageSize
    )

    $skip = $PageIndex * $PageSize
    $pageIndexEntries = $Index | Select-Object -Skip $skip -First $PageSize

    $results = [System.Collections.Generic.List[object]]::new()
    $encoding = [System.Text.Encoding]::UTF8

    # Group by file to minimize file open/close operations
    foreach ($fileGroup in ($pageIndexEntries | Group-Object File)) {
        $filePath = $fileGroup.Name
        $reader = [System.IO.StreamReader]::new($filePath, $encoding)
        try {
            foreach ($entry in $fileGroup.Group) {
                # Seek to the exact byte offset and read one line
                $reader.BaseStream.Position = $entry.Offset
                $reader.DiscardBufferedData()
                $line = $reader.ReadLine()

                # Now do the full parse for the records on this page
                $results.Add(($line | ConvertFrom-Json))
            }
        }
        finally {
            if ($reader) { $reader.Dispose() }
        }
    }

    return $results.ToArray()
}

function Get-RunRecordById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Index,

        [Parameter(Mandatory = $true)]
        [string]$ConversationId
    )

    $entry = $Index | Where-Object { $_.ConversationId -eq $ConversationId } | Select-Object -First 1
    if (-not $entry) { return $null }

    $encoding = [System.Text.Encoding]::UTF8
    $reader = [System.IO.StreamReader]::new($entry.File, $encoding)
    try {
        $reader.BaseStream.Position = $entry.Offset
        $reader.DiscardBufferedData()
        $line = $reader.ReadLine()
        return ($line | ConvertFrom-Json)
    }
    finally {
        if ($reader) { $reader.Dispose() }
    }
}

Export-ModuleMember -Function 'Build-RunIndex', 'Get-RunPage', 'Get-RunRecordById'

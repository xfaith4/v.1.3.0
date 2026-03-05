#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ImpactReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$FilteredIndex,

        [string]$ReportTitle = "Conversation Impact Report"
    )

    if ($FilteredIndex.Count -eq 0) {
        return [PSCustomObject]@{
            ReportTitle      = $ReportTitle
            GeneratedAt      = Get-Date -Format o
            Message          = "No conversations found in the current filter to generate a report."
            TotalConversations = 0
        }
    }

    # --- Aggregations ---
    # Because the index is now rich with IDs, these operations are fast and don't require re-reading data files.

    $impactByDivision = $FilteredIndex |
        Where-Object { $_.DivisionIds } |
        Select-Object -ExpandProperty DivisionIds |
        Group-Object |
        Select-Object @{N = 'DivisionId'; E = { $_.Name } }, Count |
        Sort-Object Count -Descending

    $impactByQueue = $FilteredIndex |
        Where-Object { $_.QueueIds } |
        Select-Object -ExpandProperty QueueIds |
        Group-Object |
        Select-Object @{N = 'QueueId'; E = { $_.Name } }, Count |
        Sort-Object Count -Descending

    $affectedAgents = $FilteredIndex |
        Where-Object { $_.UserIds } |
        Select-Object -ExpandProperty UserIds |
        Group-Object |
        Select-Object @{N = 'AgentId'; E = { $_.Name } }, Count |
        Sort-Object Count -Descending

    # --- Assemble Report Object ---
    $report = [PSCustomObject]@{
        ReportTitle        = $ReportTitle
        GeneratedAt        = Get-Date -Format o
        TotalConversations = $FilteredIndex.Count
        TimeWindow         = [PSCustomObject]@{
            Start = ($FilteredIndex | Sort-Object ConversationStart | Select-Object -First 1).ConversationStart
            End   = ($FilteredIndex | Sort-Object ConversationStart -Descending | Select-Object -First 1).ConversationStart
        }
        ImpactByDivision   = $impactByDivision
        ImpactByQueue      = $impactByQueue
        AffectedAgents     = $affectedAgents
    }

    return $report
}

Export-ModuleMember -Function 'New-ImpactReport'

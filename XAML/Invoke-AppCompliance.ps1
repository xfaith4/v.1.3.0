### BEGIN FILE: Tests/Invoke-AppCompliance.ps1
[CmdletBinding()]
param(
  [Parameter()]
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,

  # Path to the Core module (used only to EXCLUDE it from forbidden scans if present on disk elsewhere)
  [Parameter()]
  [string]$CoreModulePath = $env:GENESYS_CORE_MODULE_PATH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-Fail {
  param([string]$Message, [object]$Details = $null)
  Write-Error $Message
  if ($null -ne $Details) {
    $Details | Format-List * | Out-String | Write-Host
  }
  throw $Message
}

function Get-AppFiles {
  param([string]$Root)
  # Scan PowerShell + XAML; exclude typical build folders
  $exclude = @("\bin\", "\obj\", "\.git\", "\.venv\", "\node_modules\")
  Get-ChildItem -Path $Root -Recurse -File |
    Where-Object {
      ($_.Extension -in @(".ps1",".psm1",".psd1",".xaml",".json",".md")) -and
      ($exclude | ForEach-Object { $_ } | Where-Object { $_ -and $_ -in $_.FullName }) -eq $null
    }
}

function Select-StringSafe {
  param(
    [string[]]$Paths,
    [string]$Pattern
  )
  $hits = @()
  foreach ($p in $Paths) {
    try {
      $m = Select-String -LiteralPath $p -Pattern $Pattern -AllMatches -ErrorAction SilentlyContinue
      if ($m) { $hits += $m }
    } catch { }
  }
  return $hits
}

# -----------------------------
# Identify app source files
# -----------------------------
$appFiles = Get-AppFiles -Root $RepoRoot
$psFiles  = $appFiles | Where-Object { $_.Extension -in @(".ps1",".psm1",".psd1") } | Select-Object -ExpandProperty FullName
$xamlFiles= $appFiles | Where-Object { $_.Extension -eq ".xaml" } | Select-Object -ExpandProperty FullName

if (-not $psFiles) { New-Fail "No PowerShell files found under RepoRoot: $RepoRoot" }

# -----------------------------
# Gate D: Forbidden patterns
# -----------------------------
$forbiddenPattern = "(Invoke-RestMethod|Invoke-WebRequest|/api/v2/)"
$forbiddenHits = Select-StringSafe -Paths $psFiles -Pattern $forbiddenPattern

# Exclude hits if they are inside Genesys.Core module folder (ONLY if the app repo accidentally contains it)
# But we ALSO separately fail if Genesys.Core is copied into the repo (see below).
if ($forbiddenHits.Count -gt 0) {
  New-Fail "Forbidden API patterns found in app source. The app must not call Genesys endpoints directly." ($forbiddenHits | Select-Object Path,LineNumber,Line)
}

# -----------------------------
# Gate: Genesys.Core must NOT be copied into repo
# -----------------------------
$coreCopied = Get-ChildItem -Path $RepoRoot -Recurse -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -eq "Genesys.Core" -or $_.FullName -match "Genesys\.Core\\src\\ps-module" } |
  Select-Object -First 1

if ($coreCopied) {
  New-Fail "Genesys.Core appears to be copied into this repo ($($coreCopied.FullName)). Core must be a referenced dependency, not vendored into the app."
}

# -----------------------------
# Gate: Genesys.Core import must ONLY occur in App.CoreAdapter.psm1
# -----------------------------
$importPattern = "(Import-Module\s+.*Genesys\.Core|Import-Module\s+.*Genesys\.Core\.psd1|Assert-Catalog|Invoke-Dataset)"
$importHits = Select-StringSafe -Paths $psFiles -Pattern $importPattern

if (-not $importHits) {
  New-Fail "No evidence of Genesys.Core usage (Import-Module/Assert-Catalog/Invoke-Dataset) found. App must use Genesys.Core via Invoke-Dataset."
}

$coreAdapter = Join-Path $RepoRoot "App.CoreAdapter.psm1"
if (-not (Test-Path -LiteralPath $coreAdapter)) {
  New-Fail "Missing required module: App.CoreAdapter.psm1 (the only allowed Core integration seam)."
}

# Ensure Invoke-Dataset & Assert-Catalog appear in CoreAdapter
$coreAdapterHits = Select-String -LiteralPath $coreAdapter -Pattern "(Assert-Catalog|Invoke-Dataset)" -AllMatches -ErrorAction SilentlyContinue
if (-not $coreAdapterHits) {
  New-Fail "App.CoreAdapter.psm1 does not contain Assert-Catalog and/or Invoke-Dataset usage."
}

# Ensure Import-Module Genesys.Core appears only in CoreAdapter
$importCoreHits = Select-StringSafe -Paths $psFiles -Pattern "Import-Module\s+.*Genesys\.Core"
$importOutside = $importCoreHits | Where-Object { $_.Path -ne $coreAdapter }
if ($importOutside) {
  New-Fail "Genesys.Core is imported outside App.CoreAdapter.psm1. Only CoreAdapter may import Genesys.Core." ($importOutside | Select-Object Path,LineNumber,Line)
}

# -----------------------------
# Gate: StrictMode
# -----------------------------
$strictHits = Select-StringSafe -Paths $psFiles -Pattern "Set-StrictMode\s+-Version\s+Latest"
if (-not $strictHits) {
  New-Fail "Set-StrictMode -Version Latest not found. Require strict mode for reliability."
}

# -----------------------------
# Gate: Parser gotcha ($var:)
# - heuristic check: finds "$name:" style occurrences in double-quoted strings
#   and recommends $($name): instead. Not perfect, but catches common mistakes.
# -----------------------------
$colonVarHits = Select-StringSafe -Paths $psFiles -Pattern '"[^"]*\$[A-Za-z_][A-Za-z0-9_]*:'
if ($colonVarHits) {
  New-Fail "Potential PowerShell parser issue: variable followed by ':' inside double quotes. Use `$($var):` form." ($colonVarHits | Select-Object Path,LineNumber,Line)
}

Write-Host "✅ Compliance checks passed." -ForegroundColor Green
### END FILE: Tests\Invoke-AppCompliance.ps1

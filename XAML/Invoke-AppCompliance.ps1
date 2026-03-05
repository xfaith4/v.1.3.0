### BEGIN FILE: XAML/Invoke-AppCompliance.ps1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..') -ErrorAction Stop).Path,

    # Path to the Core module (used only to exclude it from forbidden-pattern scans)
    [Parameter()]
    [string]$CoreModulePath = $env:GENESYS_CORE_MODULE_PATH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FailCount = 0

function New-Fail {
    param([string]$Message, [object]$Details = $null)
    $script:FailCount++
    Write-Host "[FAIL] $Message" -ForegroundColor Red
    if ($null -ne $Details) {
        $Details | Format-List * | Out-String | Write-Host
    }
}

function New-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function New-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Get-AppFiles {
    param([string]$Root)
    $exclude = @('\bin\', '\obj\', '\.git\', '\.venv\', '\node_modules\', '\scripts\')
    Get-ChildItem -Path $Root -Recurse -File |
        Where-Object {
            ($_.Extension -in @('.ps1', '.psm1', '.psd1', '.xaml', '.json', '.md')) -and
            (-not ($exclude | Where-Object { $_.FullName.Contains($_) }))
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

Write-Host ""
Write-Host "=== App Compliance Checks ===" -ForegroundColor White
Write-Host "    Repo root: $RepoRoot"
Write-Host ""

# ── Identify app source files ─────────────────────────────────────────────────
$appFiles = Get-AppFiles -Root $RepoRoot
$psFiles  = $appFiles | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') } |
                Select-Object -ExpandProperty FullName
$mdFiles  = $appFiles | Where-Object { $_.Extension -eq '.md' } |
                Select-Object -ExpandProperty FullName

if (-not $psFiles) { New-Fail "No PowerShell files found under RepoRoot: $RepoRoot"; exit 1 }

# ─────────────────────────────────────────────────────────────────────────────
# GATE D: No forbidden direct API calls
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "--- Gate D: Forbidden API patterns ---"
$forbiddenPattern = '(Invoke-RestMethod|Invoke-WebRequest|/api/v2/)'
$forbiddenHits    = Select-StringSafe -Paths $psFiles -Pattern $forbiddenPattern
if ($forbiddenHits.Count -gt 0) {
    New-Fail "Forbidden API patterns found. App must not call Genesys endpoints directly." `
             ($forbiddenHits | Select-Object Path, LineNumber, Line)
} else {
    New-Pass 'No forbidden API patterns'
}

# ─────────────────────────────────────────────────────────────────────────────
# GATE: Genesys.Core must NOT be vendored into this repo
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Gate: Core not vendored ---"
$coreCopied = Get-ChildItem -Path $RepoRoot -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'Genesys.Core' -or $_.FullName -match 'Genesys\.Core\\src\\ps-module' } |
    Select-Object -First 1
if ($coreCopied) {
    New-Fail "Genesys.Core appears vendored into this repo ($($coreCopied.FullName)). Core must be a referenced dependency, not copied in."
} else {
    New-Pass 'Genesys.Core not vendored'
}

# ─────────────────────────────────────────────────────────────────────────────
# GATE: Genesys.Core import only in App.CoreAdapter.psm1
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Gate: Core import boundary ---"
$importPattern = '(Import-Module\s+.*Genesys\.Core|Assert-Catalog|Invoke-Dataset)'
$importHits    = Select-StringSafe -Paths $psFiles -Pattern $importPattern

if (-not $importHits) {
    New-Fail "No evidence of Genesys.Core usage found. App must use Genesys.Core via App.CoreAdapter.psm1."
} else {
    $coreAdapter = Join-Path $RepoRoot 'XAML\App.CoreAdapter.psm1'
    if (-not (Test-Path -LiteralPath $coreAdapter)) {
        New-Fail "Missing required module: XAML\App.CoreAdapter.psm1."
    } else {
        $coreAdapterHits = Select-String -LiteralPath $coreAdapter -Pattern '(Assert-Catalog|Invoke-Dataset)' -AllMatches -ErrorAction SilentlyContinue
        if (-not $coreAdapterHits) {
            New-Fail "App.CoreAdapter.psm1 does not contain Assert-Catalog and/or Invoke-Dataset usage."
        } else {
            # Ensure Import-Module Genesys.Core only appears in CoreAdapter
            $importCoreHits = Select-StringSafe -Paths $psFiles -Pattern 'Import-Module\s+.*Genesys\.Core'
            $importOutside  = $importCoreHits | Where-Object { $_.Path -ne $coreAdapter }
            if ($importOutside) {
                New-Fail "Genesys.Core imported outside App.CoreAdapter.psm1." `
                         ($importOutside | Select-Object Path, LineNumber, Line)
            } else {
                New-Pass 'Core import boundary respected'
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# GATE: Set-StrictMode present
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Gate: StrictMode ---"
$strictHits = Select-StringSafe -Paths $psFiles -Pattern 'Set-StrictMode\s+-Version\s+Latest'
if (-not $strictHits) {
    New-Fail "Set-StrictMode -Version Latest not found in any PowerShell file."
} else {
    New-Pass 'Set-StrictMode -Version Latest present'
}

# ─────────────────────────────────────────────────────────────────────────────
# GATE: Parser gotcha – $var: in double-quoted strings
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Gate: Variable colon gotcha ---"
$colonVarHits = Select-StringSafe -Paths $psFiles -Pattern '"[^"]*\$[A-Za-z_][A-Za-z0-9_]*:'
if ($colonVarHits) {
    New-Fail "Potential PowerShell parser issue: variable followed by ':' in double-quoted string. Use `$(`$var): form." `
             ($colonVarHits | Select-Object Path, LineNumber, Line)
} else {
    New-Pass 'No variable-colon parser issues found'
}

# ─────────────────────────────────────────────────────────────────────────────
# GATE: Canonical entrypoint (App.ps1) exists and is the documented launch path
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Gate: Canonical entrypoint ---"
$canonicalEntry = Join-Path $RepoRoot 'App.ps1'
if (-not (Test-Path -LiteralPath $canonicalEntry)) {
    New-Fail "Canonical entrypoint App.ps1 not found at repo root."
} else {
    New-Pass 'App.ps1 exists at repo root'
}

# README must reference App.ps1 as the launch command
$readmePath = Join-Path $RepoRoot 'README.md'
if (Test-Path -LiteralPath $readmePath) {
    $readmeHitsAppPs1 = Select-String -LiteralPath $readmePath -Pattern 'App\.ps1' -AllMatches -ErrorAction SilentlyContinue
    if (-not $readmeHitsAppPs1) {
        New-Fail "README.md does not reference 'App.ps1' as the launch command."
    } else {
        New-Pass "README.md references App.ps1"
    }

    # README must not promote the deprecated launcher as the primary path
    $readmeDeprecated = Select-String -LiteralPath $readmePath -Pattern 'Run-ConversationAnalytics\.ps1' -AllMatches -ErrorAction SilentlyContinue
    if ($readmeDeprecated) {
        $nonDeprecatedLines = $readmeDeprecated | Where-Object { $_.Line -notmatch '(?i)(deprecated|legacy|shim)' }
        if ($nonDeprecatedLines) {
            New-Warn "README.md still references Run-ConversationAnalytics.ps1 without a 'deprecated/legacy' label. Review those lines."
        } else {
            New-Pass "README.md mentions Run-ConversationAnalytics.ps1 only with deprecated/legacy labels"
        }
    } else {
        New-Pass "README.md does not reference deprecated launcher"
    }
} else {
    New-Warn "README.md not found – cannot verify canonical entrypoint documentation."
}

# ─────────────────────────────────────────────────────────────────────────────
# GATE: README must not reference deprecated module paths (src/ps-module)
#       unless they are labelled as legacy/shim/deprecated
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Gate: Deprecated path references ---"
$deprecatedPathPattern = 'src/ps-module|src\\ps-module'
if (Test-Path -LiteralPath $readmePath) {
    $deprecatedPathHits = Select-String -LiteralPath $readmePath -Pattern $deprecatedPathPattern -AllMatches -ErrorAction SilentlyContinue
    if ($deprecatedPathHits) {
        $unlabelled = $deprecatedPathHits | Where-Object { $_.Line -notmatch '(?i)(deprecated|legacy|shim|old)' }
        if ($unlabelled) {
            New-Fail "README.md references deprecated src/ps-module paths without a legacy label." `
                     ($unlabelled | Select-Object LineNumber, Line)
        } else {
            New-Pass "All src/ps-module references in README.md are labelled as legacy/deprecated"
        }
    } else {
        New-Pass "README.md has no deprecated src/ps-module path references"
    }
}

# Also check all .md files
$allMdDeprecatedHits = Select-StringSafe -Paths $mdFiles -Pattern $deprecatedPathPattern
$allMdUnlabelled = $allMdDeprecatedHits | Where-Object { $_.Line -notmatch '(?i)(deprecated|legacy|shim|old)' }
if ($allMdUnlabelled) {
    New-Warn "Some .md files reference deprecated src/ps-module paths. Review:"
    $allMdUnlabelled | Select-Object Path, LineNumber, Line | Format-Table | Out-String | Write-Host
}

# ─────────────────────────────────────────────────────────────────────────────
# GATE: Resolve-DependencyPaths function must exist
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Gate: Resolve-DependencyPaths ---"
$resolverHits = Select-StringSafe -Paths $psFiles -Pattern 'function\s+Resolve-DependencyPaths'
if (-not $resolverHits) {
    New-Fail "Resolve-DependencyPaths function not found in any module. Required for deterministic path resolution."
} else {
    New-Pass 'Resolve-DependencyPaths function exists'
}

# ─────────────────────────────────────────────────────────────────────────────
# GATE: Smoke script must exist and be referenced in README
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Gate: Smoke script ---"
$smokeScript = Join-Path $RepoRoot 'scripts\Invoke-Smoke.ps1'
if (-not (Test-Path -LiteralPath $smokeScript)) {
    New-Fail "Smoke script not found at scripts\Invoke-Smoke.ps1. Create it for day-one verification."
} else {
    New-Pass 'scripts\Invoke-Smoke.ps1 exists'
}

if (Test-Path -LiteralPath $readmePath) {
    $smokeRefHits = Select-String -LiteralPath $readmePath -Pattern 'Invoke-Smoke' -AllMatches -ErrorAction SilentlyContinue
    if (-not $smokeRefHits) {
        New-Warn "README.md does not reference Invoke-Smoke.ps1. Consider adding a 'troubleshooting' section."
    } else {
        New-Pass 'README.md references Invoke-Smoke.ps1'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Final result
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
if ($script:FailCount -eq 0) {
    Write-Host "=== Compliance checks passed. ===" -ForegroundColor Green
} else {
    Write-Host "=== $($script:FailCount) compliance check(s) FAILED. ===" -ForegroundColor Red
    Write-Host "    Fix all [FAIL] items before submitting a PR." -ForegroundColor Yellow
    exit 1
}
### END FILE: XAML/Invoke-AppCompliance.ps1

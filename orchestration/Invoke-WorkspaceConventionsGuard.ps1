#Requires -Version 7.6
<#
.SYNOPSIS
Fails when tracked files use stale workspace repo-directory names or when
tracked PowerShell files miss the required `#Requires -Version 7.6` header.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-TrackedFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $output = & git -C $RepoRoot ls-files
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files failed for $RepoRoot"
    }

    @($output | Where-Object { $_ })
}

function Get-GrepMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $output = & git -C $RepoRoot grep -n -I -E $Pattern -- . 2>$null
    if ($LASTEXITCODE -eq 1) {
        return @()
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git grep failed for $RepoRoot"
    }

    @($output | Where-Object { $_ })
}

$trackedFiles = @(Get-TrackedFiles -RepoRoot $RepoRoot)
$staleRepoDirPatterns = @(
    '(^|[^A-Za-z0-9-])\./overlord-(agents|be|tooling)([\\/]|$)',
    '(^|[^A-Za-z0-9-])\.\./overlord-(agents|be|tooling)([\\/]|$)',
    '%OVERLORD_PROJECT_DIR%\\overlord-(agents|be|tooling)(\\|$)',
    'Join-Path[[:space:]]+\$[A-Za-z0-9_]+[[:space:]]+"overlord-(agents|be|tooling)\\',
    '[├└]──[[:space:]]+overlord-(agents|be|tooling)(/|$)',
    '`overlord-(agents|be|tooling)/(docs|scripts|overlord-be-coordinator|overlord-be-db|runtime|README\.md|AGENTS\.md|BACKLOG(_ARCHIVE)?\.md|overlord\.toml(\.example)?)`'
)
$staleRepoDirMatches = @()
foreach ($pattern in $staleRepoDirPatterns) {
    $staleRepoDirMatches += @(Get-GrepMatches -RepoRoot $RepoRoot -Pattern $pattern)
}
$staleRepoDirMatches = @($staleRepoDirMatches | Sort-Object -Unique)
$trackedPowerShellFiles = @($trackedFiles | Where-Object { $_ -like '*.ps1' })
$missingRequiresHeaders = @()

foreach ($relativePath in $trackedPowerShellFiles) {
    $absolutePath = Join-Path $RepoRoot $relativePath
    $firstLine = (Get-Content -LiteralPath $absolutePath -TotalCount 1)
    if ($firstLine -ne '#Requires -Version 7.6') {
        $missingRequiresHeaders += $relativePath
    }
}

$summary = [pscustomobject]@{
    schemaVersion = 'workspace-conventions-guard-summary/v1'
    repoRoot = $RepoRoot
    scannedTrackedFiles = $trackedFiles.Count
    trackedPowerShellFiles = $trackedPowerShellFiles.Count
    staleRepoDirMatches = $staleRepoDirMatches
    missingRequiresHeaders = $missingRequiresHeaders
    passed = ($staleRepoDirMatches.Count -eq 0 -and $missingRequiresHeaders.Count -eq 0)
}

$summary | ConvertTo-Json -Depth 6

if (-not $summary.passed) {
    throw 'Workspace conventions guard failed'
}

<#
.SYNOPSIS
Fails when tracked files contain local user-profile paths or configured
personal-name filename leaks.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$PolicyPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    $PolicyPath = Join-Path $RepoRoot "schemas\privacy-guard\policy.v1.json"
}

function Get-TrackedFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $output = & git -C $RepoRoot ls-files -z
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files failed for $RepoRoot"
    }

    @($output -split "`0" | Where-Object { $_ })
}

function Test-RelativePathAgainstRegexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,
        [Parameter(Mandatory = $true)]
        [object[]]$Rules
    )

    foreach ($rule in $Rules) {
        if ($RelativePath -match $rule.regex) {
            return [pscustomobject]@{
                matched = $true
                reason = $rule.reason
                regex = $rule.regex
            }
        }
    }

    [pscustomobject]@{
        matched = $false
        reason = $null
        regex = $null
    }
}

function Get-ContentMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [object[]]$Rules
    )

    $matches = @()
    foreach ($rule in $Rules) {
        $output = & git -C $RepoRoot grep -n -I -E $rule.regex -- . 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            foreach ($line in @($output)) {
                $matches += [pscustomobject]@{
                    rule = $rule.id
                    reason = $rule.reason
                    match = $line
                }
            }
        }
    }

    $matches
}

if (-not (Test-Path $PolicyPath)) {
    throw "Privacy-guard policy not found at $PolicyPath"
}

$policy = Get-Content -Raw $PolicyPath | ConvertFrom-Json -AsHashtable
$trackedFiles = @(Get-TrackedFiles -RepoRoot $RepoRoot)
$pathMatches = @()

foreach ($relativePath in $trackedFiles) {
    $pathResult = Test-RelativePathAgainstRegexes -RelativePath $relativePath -Rules $policy.pathRules
    if ($pathResult.matched) {
        $pathMatches += [pscustomobject]@{
            path = $relativePath
            reason = $pathResult.reason
            regex = $pathResult.regex
        }
    }
}

$contentMatches = @(Get-ContentMatches -RepoRoot $RepoRoot -Rules $policy.contentRules)

$summary = [pscustomobject]@{
    schemaVersion = "privacy-guard-summary/v1"
    repoRoot = $RepoRoot
    policyVersion = $policy.policyVersion
    scannedTrackedFiles = $trackedFiles.Count
    pathMatches = $pathMatches
    contentMatches = $contentMatches
    passed = ($pathMatches.Count -eq 0 -and $contentMatches.Count -eq 0)
}

$summary | ConvertTo-Json -Depth 8

if (-not $summary.passed) {
    throw "Tracked-file privacy guard failed"
}

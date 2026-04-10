#Requires -Version 7.6
<#
.SYNOPSIS
Fails when tracked files contain local user-profile paths or configured
personal-name filename leaks.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$PolicyPath = "",
    [string]$LocalPolicyPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    $PolicyPath = Join-Path $RepoRoot "schemas\privacy-guard\policy.v1.json"
}

if ([string]::IsNullOrWhiteSpace($LocalPolicyPath)) {
    $LocalPolicyPath = Join-Path $RepoRoot "schemas\privacy-guard\policy.local.json"
}

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

function Test-RelativePathAgainstRegexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,
        [object[]]$Rules
    )

    if (@($Rules).Count -eq 0) {
        return [pscustomobject]@{
            matched = $false
            reason = $null
            regex = $null
        }
    }

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
        [object[]]$Rules
    )

    $matches = @()
    if (@($Rules).Count -eq 0) {
        return $matches
    }
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

function Merge-PolicyRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$BasePolicy,
        [Parameter(Mandatory = $true)]
        [hashtable]$ExtraPolicy
    )

    $BasePolicy.pathRules = @($BasePolicy.pathRules) + @($ExtraPolicy.pathRules)
    $BasePolicy.contentRules = @($BasePolicy.contentRules) + @($ExtraPolicy.contentRules)
}

function New-IdentifierRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Identifiers
    )

    $pathRules = @()
    foreach ($identifier in $Identifiers) {
        if ([string]::IsNullOrWhiteSpace($identifier)) {
            continue
        }

        $escaped = [regex]::Escape($identifier.Trim())
        $pathRules += [ordered]@{
            id = "local-identifier-filename"
            reason = "Tracked filenames must not embed configured personal identifiers."
            regex = "(^|[\\\\/])[^\\\\/]*$escaped[^\\\\/]*$"
        }
    }

    @{
        pathRules = $pathRules
        contentRules = @()
    }
}

if (-not (Test-Path $PolicyPath)) {
    throw "Privacy-guard policy not found at $PolicyPath"
}

$policy = Get-Content -Raw $PolicyPath | ConvertFrom-Json -AsHashtable
$policy.pathRules = @($policy.pathRules)
$policy.contentRules = @($policy.contentRules)

if (Test-Path $LocalPolicyPath) {
    $localPolicy = Get-Content -Raw $LocalPolicyPath | ConvertFrom-Json -AsHashtable
    Merge-PolicyRules -BasePolicy $policy -ExtraPolicy $localPolicy
}

if (-not [string]::IsNullOrWhiteSpace($env:OVERLORD_PRIVACY_GUARD_IDENTIFIERS)) {
    $identifierPolicy = New-IdentifierRules -Identifiers ($env:OVERLORD_PRIVACY_GUARD_IDENTIFIERS -split ",")
    Merge-PolicyRules -BasePolicy $policy -ExtraPolicy $identifierPolicy
}
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

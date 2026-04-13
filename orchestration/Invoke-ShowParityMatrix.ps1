#Requires -Version 7.6

[CmdletBinding()]
param(
    [ValidateSet("All", "cell", "campaign")]
    [string]$ScenarioKind = "All",
    [ValidateSet("All", "kad2", "ed2k", "mixed")]
    [string]$Protocol = "All",
    [ValidateSet("All", "available", "planned")]
    [string]$Availability = "All",
    [ValidateSet("All", "deterministic-private", "broad-private", "realnet-confidence")]
    [string]$Tier = "All"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ParityScenarioModel.ps1")

$repoRoot = Resolve-ToolingRepoRoot -StartPath $PSScriptRoot
Get-ScenarioManifests -RepoRoot $repoRoot |
    Where-Object {
        $manifest = $_.Manifest
        if (@("cell", "campaign") -notcontains [string]$manifest.scenarioKind) { return $false }
        if ($ScenarioKind -ne "All" -and [string]$manifest.scenarioKind -ne $ScenarioKind) { return $false }
        if ($Protocol -ne "All" -and [string]$manifest.protocol -ne $Protocol) { return $false }
        if ($Tier -ne "All" -and [string]$manifest.tier -ne $Tier) { return $false }
        $manifestAvailability = if ([string]$manifest.scenarioKind -eq "campaign") { [string]$manifest.campaign.availability } else { [string]$manifest.parity.availability }
        if ($Availability -ne "All" -and $manifestAvailability -ne $Availability) { return $false }
        return $true
    } |
    ForEach-Object {
        $manifest = $_.Manifest
        $parity = if ($manifest.ContainsKey("parity")) { $manifest.parity } else { $null }
        $execution = if ($manifest.ContainsKey("execution")) { $manifest.execution } else { $null }
        $campaign = if ($manifest.ContainsKey("campaign")) { $manifest.campaign } else { $null }
        $cellId = if ($null -ne $parity -and $parity.ContainsKey("cellId")) { $parity.cellId } else { $null }
        $expectedBranch = if ($null -ne $parity -and $parity.ContainsKey("expectedBranch")) { $parity.expectedBranch } else { $null }
        $comparisonMode = if ($null -ne $parity -and $parity.ContainsKey("comparisonMode")) { $parity.comparisonMode } else { $null }
        $command = if ($null -ne $execution -and $execution.ContainsKey("command")) { $execution.command } else { $null }
        $summarySourceScenarioId = if ($null -ne $execution -and $execution.ContainsKey("summarySourceScenarioId")) { $execution.summarySourceScenarioId } else { $null }
        [pscustomobject]@{
            scenarioId = $_.ScenarioId
            scenarioKind = $manifest.scenarioKind
            protocol = $manifest.protocol
            tier = $manifest.tier
            matrixId = if ($null -ne $parity -and $parity.ContainsKey("matrixId")) { $parity.matrixId } else { $null }
            cellId = $cellId
            availability = if ([string]$manifest.scenarioKind -eq "campaign") { $campaign.availability } else { $parity.availability }
            command = $command
            summarySourceScenarioId = $summarySourceScenarioId
            memberCount = if ($null -ne $campaign -and $campaign.ContainsKey("members")) { @($campaign.members).Count } else { 0 }
            expectedBranch = $expectedBranch
            comparisonMode = $comparisonMode
            description = $manifest.description
        }
    }

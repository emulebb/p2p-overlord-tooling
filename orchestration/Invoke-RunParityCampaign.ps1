#Requires -Version 7.6

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenarioId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ParityScenarioModel.ps1")

$repoRoot = Resolve-ToolingRepoRoot -StartPath $PSScriptRoot
$result = Invoke-ToolingParityCampaign -RepoRoot $repoRoot -ScenarioId $ScenarioId
if ([string]$result.RunSummary.status -ne "passed") {
    throw "Parity campaign '$ScenarioId' finished with status '$($result.RunSummary.status)'. See $($result.RunSummaryPath)"
}

$result.RunSummary

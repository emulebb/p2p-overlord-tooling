#Requires -Version 7.6

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenarioId,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExecutionArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ParityScenarioModel.ps1")

$repoRoot = Resolve-ToolingRepoRoot -StartPath $PSScriptRoot
$result = Invoke-ToolingParityCell -RepoRoot $repoRoot -ScenarioId $ScenarioId -AdditionalExecutionArguments $ExecutionArguments
if ([string]$result.RunSummary.status -ne "passed") {
    throw "Parity cell '$ScenarioId' finished with status '$($result.RunSummary.status)'. See $($result.RunSummaryPath)"
}

$result.RunSummary

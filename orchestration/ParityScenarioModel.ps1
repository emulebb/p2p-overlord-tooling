#Requires -Version 7.6

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\subsystems\RuntimeContext.ps1")
. (Join-Path $PSScriptRoot "..\cli\CommandRegistry.ps1")

function Get-ScenarioManifestPath {
    param([string]$RepoRoot, [string]$ScenarioId)
    Join-Path $RepoRoot ("scenarios\{0}\manifest.v1.json" -f $ScenarioId)
}

function Read-ScenarioManifest {
    param([string]$RepoRoot, [string]$ScenarioId)
    $manifestPath = Get-ScenarioManifestPath -RepoRoot $RepoRoot -ScenarioId $ScenarioId
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Scenario manifest not found at $manifestPath" }
    Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
}

function Get-ScenarioManifests {
    param([string]$RepoRoot)
    Get-ChildItem -Path (Join-Path $RepoRoot "scenarios") -Directory |
        ForEach-Object {
            $manifestPath = Join-Path $_.FullName "manifest.v1.json"
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
            $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
            [pscustomobject]@{ ScenarioId = [string]$manifest.scenarioId; Manifest = $manifest; ManifestPath = $manifestPath }
        } |
        Sort-Object ScenarioId
}

function ConvertTo-ToolingScriptInvocationArgs {
    param([string[]]$Tokens = @())
    $named = @{}
    $positional = @()
    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        $token = [string]$Tokens[$index]
        if ($token.StartsWith("-")) {
            $parameterName = $token.TrimStart("-").TrimEnd(":")
            $nextIsValue = $index + 1 -lt $Tokens.Count -and -not ([string]$Tokens[$index + 1]).StartsWith("-")
            if ($nextIsValue) {
                $named[$parameterName] = $Tokens[$index + 1]
                $index++
            }
            else {
                $named[$parameterName] = $true
            }
            continue
        }
        $positional += $token
    }
    [pscustomobject]@{ Named = $named; Positional = $positional }
}

function Write-JsonFile {
    param([string]$Path, [object]$Value, [int]$Depth = 12)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Get-LatestScenarioRunRecord {
    param([string]$TmpDir, [string]$ScenarioId, [string[]]$ExcludeRunIds = @())
    $scenarioRunRoot = Join-Path $TmpDir ("overlord-tooling\runs\{0}" -f $ScenarioId)
    if (-not (Test-Path -LiteralPath $scenarioRunRoot -PathType Container)) { return $null }
    foreach ($candidateDir in (Get-ChildItem -LiteralPath $scenarioRunRoot -Directory | Where-Object { $ExcludeRunIds -notcontains $_.Name } | Sort-Object LastWriteTimeUtc -Descending)) {
        $runSummaryPath = Join-Path $candidateDir.FullName "run-summary.json"
        if (-not (Test-Path -LiteralPath $runSummaryPath -PathType Leaf)) { continue }
        $runManifestPath = Join-Path $candidateDir.FullName "run-manifest.json"
        [pscustomobject]@{
            RunId = $candidateDir.Name
            ArtifactRoot = $candidateDir.FullName
            RunSummaryPath = $runSummaryPath
            RunManifestPath = $runManifestPath
            RunSummary = (Get-Content -Raw -LiteralPath $runSummaryPath | ConvertFrom-Json -AsHashtable)
            RunManifest = if (Test-Path -LiteralPath $runManifestPath -PathType Leaf) { Get-Content -Raw -LiteralPath $runManifestPath | ConvertFrom-Json -AsHashtable } else { $null }
        }
        return
    }
}

function Get-ScenarioSummaryStatus {
    param([hashtable]$RunSummary)
    if ($RunSummary.ContainsKey("status") -and -not [string]::IsNullOrWhiteSpace([string]$RunSummary.status)) { return [string]$RunSummary.status }
    if ($RunSummary.ContainsKey("completed")) { return $(if ([bool]$RunSummary.completed) { "passed" } else { "failed" }) }
    if ($RunSummary.ContainsKey("passed")) { return $(if ([bool]$RunSummary.passed) { "passed" } else { "failed" }) }
    "unknown"
}

function Invoke-ScenarioExecutionCommand {
    param([string]$RepoRoot, [string]$CommandName, [string[]]$Tokens = @())
    $command = Get-ToolingCommand -RepoRoot $RepoRoot -Name $CommandName
    if ($null -eq $command) { throw "Tooling command '$CommandName' is not registered" }
    if ([string]$command.Kind -ne "script") { throw "Tooling command '$CommandName' is not script-backed" }
    $invocationArgs = ConvertTo-ToolingScriptInvocationArgs -Tokens $Tokens
    Invoke-ToolingScript -ScriptPath $command.ScriptPath -NamedArguments $invocationArgs.Named -PositionalArguments $invocationArgs.Positional
}

function New-WrapperArtifacts {
    param([string]$TmpDir, [string]$ScenarioId)
    if ([string]::IsNullOrWhiteSpace($TmpDir)) { throw "OVERLORD_TMP_DIR is not set" }
    $runId = "{0}-{1}" -f $ScenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
    $artifactRoot = Join-Path $TmpDir ("overlord-tooling\runs\{0}\{1}" -f $ScenarioId, $runId)
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
    [pscustomobject]@{
        RunId = $runId
        ArtifactRoot = $artifactRoot
        RunManifestPath = Join-Path $artifactRoot "run-manifest.json"
        RunSummaryPath = Join-Path $artifactRoot "run-summary.json"
    }
}

function Invoke-ToolingParityCell {
    param([string]$RepoRoot, [string]$ScenarioId, [string[]]$AdditionalExecutionArguments = @())
    $runtimeContext = Get-ToolingRuntimeContext -SourcePath $PSScriptRoot
    $manifest = Read-ScenarioManifest -RepoRoot $RepoRoot -ScenarioId $ScenarioId
    if ([string]$manifest.scenarioKind -ne "cell") { throw "Scenario '$ScenarioId' is not a parity cell" }
    if ([string]$manifest.parity.availability -ne "available") { throw "Parity cell '$ScenarioId' is not runnable" }
    $commandName = [string]$manifest.execution.command
    if ([string]::IsNullOrWhiteSpace($commandName)) { throw "Parity cell '$ScenarioId' does not declare execution.command" }
    $sourceScenarioId = if ([string]::IsNullOrWhiteSpace([string]$manifest.execution.summarySourceScenarioId)) { $ScenarioId } else { [string]$manifest.execution.summarySourceScenarioId }
    $existingRunIds = @()
    $existingRunsRoot = Join-Path $runtimeContext.TmpDir ("overlord-tooling\runs\{0}" -f $sourceScenarioId)
    if (Test-Path -LiteralPath $existingRunsRoot -PathType Container) { $existingRunIds = @(Get-ChildItem -LiteralPath $existingRunsRoot -Directory | Select-Object -ExpandProperty Name) }
    $artifacts = New-WrapperArtifacts -TmpDir $runtimeContext.TmpDir -ScenarioId $ScenarioId
    $executionTokens = @()
    if ($manifest.execution.ContainsKey("arguments")) { $executionTokens += @($manifest.execution.arguments | ForEach-Object { [string]$_ }) }
    $executionTokens += @($AdditionalExecutionArguments | ForEach-Object { [string]$_ })
    Write-JsonFile -Path $artifacts.RunManifestPath -Value ([ordered]@{
        schemaVersion = "run-manifest/v1"
        scenarioId = $ScenarioId
        runId = $artifacts.RunId
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        artifactRoot = $artifacts.ArtifactRoot
        inputs = [ordered]@{
            protocol = $manifest.protocol
            tier = $manifest.tier
            matrixId = $manifest.parity.matrixId
            cellId = $manifest.parity.cellId
            expectedBranch = $manifest.parity.expectedBranch
            comparisonMode = $manifest.parity.comparisonMode
            command = $commandName
            commandArguments = $executionTokens
            summarySourceScenarioId = $sourceScenarioId
        }
    })

    $delegatedRun = $null
    $failureMessage = $null
    try {
        Invoke-ScenarioExecutionCommand -RepoRoot $RepoRoot -CommandName $commandName -Tokens $executionTokens | Out-Null
        $delegatedRun = Get-LatestScenarioRunRecord -TmpDir $runtimeContext.TmpDir -ScenarioId $sourceScenarioId -ExcludeRunIds $existingRunIds
        if ($null -eq $delegatedRun) { throw "Delegated scenario '$sourceScenarioId' did not produce a new run summary" }
    }
    catch {
        $failureMessage = $_.Exception.Message
        if ($null -eq $delegatedRun) { $delegatedRun = Get-LatestScenarioRunRecord -TmpDir $runtimeContext.TmpDir -ScenarioId $sourceScenarioId -ExcludeRunIds $existingRunIds }
    }

    $status = if ($delegatedRun) { Get-ScenarioSummaryStatus -RunSummary $delegatedRun.RunSummary } else { "failed" }
    $requiredArtifacts = if ($manifest.parity.ContainsKey("requiredArtifacts")) { @($manifest.parity.requiredArtifacts) } else { @() }
    $requiredHarnessHooks = if ($manifest.parity.ContainsKey("requiredHarnessHooks")) { @($manifest.parity.requiredHarnessHooks) } else { @() }
    $requiredAgentEvidence = if ($manifest.parity.ContainsKey("requiredAgentEvidence")) { @($manifest.parity.requiredAgentEvidence) } else { @() }
    $summary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $ScenarioId
        runId = $artifacts.RunId
        status = $status
        protocol = $manifest.protocol
        tier = $manifest.tier
        parity = [ordered]@{
            matrixId = $manifest.parity.matrixId
            cellId = $manifest.parity.cellId
            expectedBranch = $manifest.parity.expectedBranch
            comparisonMode = $manifest.parity.comparisonMode
            requiredArtifacts = $requiredArtifacts
            requiredHarnessHooks = $requiredHarnessHooks
            requiredAgentEvidence = $requiredAgentEvidence
        }
        delegated = [ordered]@{
            command = $commandName
            commandArguments = $executionTokens
            scenarioId = $sourceScenarioId
            runId = if ($delegatedRun) { $delegatedRun.RunId } else { $null }
            status = if ($delegatedRun) { Get-ScenarioSummaryStatus -RunSummary $delegatedRun.RunSummary } else { $null }
        }
        artifactPaths = [ordered]@{
            runManifestPath = $artifacts.RunManifestPath
            summaryPath = $artifacts.RunSummaryPath
            delegatedRunManifestPath = if ($delegatedRun) { $delegatedRun.RunManifestPath } else { $null }
            delegatedRunSummaryPath = if ($delegatedRun) { $delegatedRun.RunSummaryPath } else { $null }
        }
        finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    if ($delegatedRun) { $summary.delegatedSummary = $delegatedRun.RunSummary }
    if ($delegatedRun -and $delegatedRun.RunSummary.ContainsKey("firstDivergence")) { $summary.firstDivergence = $delegatedRun.RunSummary.firstDivergence }
    if (-not [string]::IsNullOrWhiteSpace($failureMessage)) { $summary.error = $failureMessage }
    Write-JsonFile -Path $artifacts.RunSummaryPath -Value $summary
    [pscustomobject]@{ Manifest = $manifest; RunSummary = $summary; RunSummaryPath = $artifacts.RunSummaryPath }
}

function Invoke-ToolingParityCampaign {
    param([string]$RepoRoot, [string]$ScenarioId)
    $runtimeContext = Get-ToolingRuntimeContext -SourcePath $PSScriptRoot
    $manifest = Read-ScenarioManifest -RepoRoot $RepoRoot -ScenarioId $ScenarioId
    if ([string]$manifest.scenarioKind -ne "campaign") { throw "Scenario '$ScenarioId' is not a parity campaign" }
    $artifacts = New-WrapperArtifacts -TmpDir $runtimeContext.TmpDir -ScenarioId $ScenarioId
    Write-JsonFile -Path $artifacts.RunManifestPath -Value ([ordered]@{
        schemaVersion = "run-manifest/v1"
        scenarioId = $ScenarioId
        runId = $artifacts.RunId
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        artifactRoot = $artifacts.ArtifactRoot
        inputs = [ordered]@{ protocol = $manifest.protocol; tier = $manifest.tier; matrixId = $manifest.parity.matrixId; memberCount = @($manifest.campaign.members).Count }
    })

    $memberResults = foreach ($member in @($manifest.campaign.members)) {
        $memberScenarioId = [string]$member.scenarioId
        $memberRequired = if ($member.ContainsKey("required")) { [bool]$member.required } else { $true }
        $memberNote = if ($member.ContainsKey("note")) { $member.note } else { $null }
        try {
            $memberResult = Invoke-ToolingParityCell -RepoRoot $RepoRoot -ScenarioId $memberScenarioId
            $memberError = if ($memberResult.RunSummary.PSObject.Properties.Name -contains "error") {
                $memberResult.RunSummary.error
            }
            else {
                $null
            }
            [ordered]@{
                scenarioId = $memberScenarioId
                required = $memberRequired
                note = $memberNote
                status = $memberResult.RunSummary.status
                runId = $memberResult.RunSummary.runId
                summaryPath = $memberResult.RunSummary.artifactPaths.summaryPath
                error = $memberError
            }
        }
        catch {
            [ordered]@{
                scenarioId = $memberScenarioId
                required = $memberRequired
                note = $memberNote
                status = "failed"
                runId = $null
                summaryPath = $null
                error = $_.Exception.Message
            }
        }
    }

    $requiredFailures = @($memberResults | Where-Object { $_.required -and $_.status -ne "passed" })
    $summary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $ScenarioId
        runId = $artifacts.RunId
        status = $(if ($requiredFailures.Count -eq 0) { "passed" } else { "failed" })
        protocol = $manifest.protocol
        tier = $manifest.tier
        parity = [ordered]@{ matrixId = $manifest.parity.matrixId; availability = $manifest.campaign.availability }
        counters = [ordered]@{ memberCount = $memberResults.Count; requiredFailureCount = $requiredFailures.Count; passedCount = @($memberResults | Where-Object { $_.status -eq "passed" }).Count }
        members = $memberResults
        artifactPaths = [ordered]@{ runManifestPath = $artifacts.RunManifestPath; summaryPath = $artifacts.RunSummaryPath }
        finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-JsonFile -Path $artifacts.RunSummaryPath -Value $summary
    [pscustomobject]@{ Manifest = $manifest; RunSummary = $summary; RunSummaryPath = $artifacts.RunSummaryPath }
}

#Requires -Version 7.6
<#
.SYNOPSIS
Runs the first deterministic Kad eMule harness and agent parity scenario.

.DESCRIPTION
Creates a scenario-owned eMule harness profile, launches the eMule harness with an explicit
profile-root override, launches the agent, triggers a deterministic manual
publish, captures artifacts, and writes run manifest and summary JSON files.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\kad.startup.hello.publish.realnet.v1\manifest.v1.json"),
    [string]$SeedBundleId = "canonical",
    [string]$InterfaceAlias = "hide.me",
    [string]$BindAddr,
    [int]$EmuleHarnessTcpPort = 46671,
    [int]$EmuleHarnessUdpPort = 46673,
    [int]$EmuleHarnessServerUdpPort = 0,
    [int]$AgentInterfaceIndex = 0,
    [int]$AgentCapturePort = 41000,
    [int]$EmuleHarnessWarmupSeconds = 20,
    [int]$PublishObserveSeconds = 20,
    [int]$PublishReadyTimeoutSeconds = 180,
    [switch]$KeepSessionsRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-BindAddress {
    param(
        [string]$ExplicitBindAddr,
        [Parameter(Mandatory = $true)]
        [object]$ResolvedAdapter
    )

    if ($ExplicitBindAddr) {
        return $ExplicitBindAddr
    }

    return [string]$ResolvedAdapter.IPAddress
}

function New-MilestoneMap {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Milestones
    )

    $map = [ordered]@{}
    foreach ($milestone in $Milestones) {
        $map[$milestone.id] = [ordered]@{
            id = $milestone.id
            status = "failed"
            details = $milestone.description
        }
    }
    return $map
}

function Set-MilestonePassed {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$MilestoneMap,
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [string]$Details
    )

    $MilestoneMap[$Id].status = "passed"
    $MilestoneMap[$Id].details = $Details
}

function Get-EmuleHarnessTraceSlice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionDir
    )

    $metadataPath = Join-Path $SessionDir "emule-harness-session.json"
    $metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
    $tracePath = $metadata.TraceLogPath
    if (-not (Test-Path $tracePath)) {
        return [pscustomobject]@{
            TracePath = $tracePath
            SlicePath = $null
            LineCount = 0
            HelloEvents = 0
            PublishEvents = 0
            PublishAccepts = 0
        }
    }

    $slicePath = Join-Path $SessionDir "emule-harness-trace-new.log"
    $traceLines = Get-Content $tracePath | Select-Object -Skip ([int]$metadata.TraceLinesBefore)
    $traceLines | Set-Content -Encoding utf8NoBOM $slicePath

    $helloEvents = @($traceLines | Where-Object {
        $_ -match "event=(hello_|key_|track_out_add.*opcode=KADEMLIA2_HELLO)"
    }).Count
    $publishEvents = @($traceLines | Where-Object {
        $_ -match "event=(publish_|search_storekeyword_prepare|search_storefile_prepare)"
    }).Count
    $publishAccepts = @($traceLines | Where-Object { $_ -match "event=publish_res_accept" }).Count

    return [pscustomobject]@{
        TracePath = $tracePath
        SlicePath = $slicePath
        LineCount = @($traceLines).Count
        HelloEvents = $helloEvents
        PublishEvents = $publishEvents
        PublishAccepts = $publishAccepts
    }
}

function Get-AgentStatsSlice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $stats = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 20
    $stats | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8NoBOM $DestinationPath
    return $stats
}

function Wait-AgentControlReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
            if ($null -ne $response) {
                return
            }
        } catch {
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "Agent stats endpoint did not become ready at $StatsUrl within $TimeoutSeconds seconds"
}

function Invoke-SeedPopularWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$Ed2kHash,
        [Parameter(Mandatory = $true)]
        [string]$CanonicalName,
        [Parameter(Mandatory = $true)]
        [UInt64]$Size,
        [Parameter(Mandatory = $true)]
        [UInt32]$SourceCount,
        [Parameter(Mandatory = $true)]
        [string]$ControlUrl,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    $lastError = $null

    do {
        $attempt++
        try {
            & $ScriptPath `
                -Ed2kHash $Ed2kHash `
                -CanonicalName $CanonicalName `
                -Size $Size `
                -SourceCount $SourceCount `
                -ControlUrl $ControlUrl | Out-Null
            return [pscustomobject]@{
                Attempts = $attempt
                AcceptedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            }
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 5
        }
    } while ((Get-Date) -lt $deadline)

    throw "Manual publish was not accepted within $TimeoutSeconds seconds. Last error: $lastError"
}

function Get-RequiredMilestoneIds {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest
    )

    if ($Manifest.PSObject.Properties.Name -contains "requiredMilestoneIds" -and $Manifest.requiredMilestoneIds) {
        return @($Manifest.requiredMilestoneIds)
    }

    return @($Manifest.milestones | ForEach-Object { $_.id })
}

function Test-MilestonesPassed {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$MilestoneMap,
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredMilestoneIds
    )

    foreach ($milestoneId in $RequiredMilestoneIds) {
        if (-not $MilestoneMap.Contains($milestoneId)) {
            return $false
        }
        if ($MilestoneMap[$milestoneId].status -ne "passed") {
            return $false
        }
    }

    return $true
}

function Resolve-EmuleHarnessRuntimeExePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolingRoot
    )

    $resolverPath = Join-Path $ToolingRoot "subsystems\emule-harness\helper-emule-harness-resolve-harness-debug-dir.ps1"
    $harnessDebugDir = & $resolverPath
    return (Join-Path $harnessDebugDir "eMule_v072a_parity.exe")
}

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$networkResolverPath = Join-Path $toolingRoot "subsystems\network\helper-network-resolve-adapter.ps1"
$manifest = Get-Content -Raw $ScenarioManifestPath | ConvertFrom-Json
$requiredMilestoneIds = @(Get-RequiredMilestoneIds -Manifest $manifest)
$resolvedAdapter = & $networkResolverPath -PreferredInterfaceAlias $InterfaceAlias
$resolvedInterfaceAlias = [string]$resolvedAdapter.InterfaceAlias
$bindAddrValue = Resolve-BindAddress -ExplicitBindAddr $BindAddr -ResolvedAdapter $resolvedAdapter

if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}
if (-not $env:OVERLORD_LOG_DIR) {
    throw "OVERLORD_LOG_DIR is not set"
}

$requiredPaths = @(
    (Join-Path $toolingRoot "profiles\\New-EmuleHarnessProfile.ps1"),
    (Join-Path $toolingRoot "subsystems\emule-harness\helper-emule-harness-start-parity-session.ps1"),
    (Join-Path $toolingRoot "subsystems\emule-harness\helper-emule-harness-stop-parity-session.ps1"),
    (Join-Path $toolingRoot "subsystems\agent\helper-agent-start-parity-session.ps1"),
    (Join-Path $toolingRoot "subsystems\agent\helper-agent-stop-parity-session.ps1"),
    (Join-Path $toolingRoot "subsystems\agent\helper-agent-post-seed-popular.ps1"),
    (Join-Path $toolingRoot "subsystems\agent\helper-agent-extract-publish-log.ps1"),
    (Join-Path $toolingRoot "subsystems\parity\helper-parity-compare-udp-jsonl.py")
)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path $requiredPath)) {
        throw "Required helper path not found at $requiredPath"
    }
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "python is not available on PATH"
}

$lockRoot = Join-Path $env:OVERLORD_TMP_DIR "overlord-tooling\locks"
New-Item -ItemType Directory -Path $lockRoot -Force | Out-Null
$lockPath = Join-Path $lockRoot ($manifest.scenarioId + ".lock")
if (Test-Path $lockPath) {
    throw "Scenario lock already exists at $lockPath"
}

$runId = "{0}-{1}" -f $manifest.scenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\{0}\{1}" -f $manifest.scenarioId, $runId)
$emuleHarnessProfileRoot = Join-Path $artifactRoot "emule-harness-profile"
$manifestPath = Join-Path $artifactRoot "run-manifest.json"
$summaryPath = Join-Path $artifactRoot "run-summary.json"
$parityOutputPath = Join-Path $artifactRoot "udp-parity.txt"
$agentStatsPath = Join-Path $artifactRoot "agent-stats.json"

New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
"lock" | Set-Content -Encoding utf8NoBOM $lockPath

$milestoneMap = New-MilestoneMap -Milestones $manifest.milestones
$emuleHarnessSession = $null
$agentSession = $null
$emuleHarnessTraceSlice = $null
$agentPublishArtifacts = $null
$agentSessionMetadata = $null
$emuleHarnessStopScriptPath = Join-Path $toolingRoot "subsystems\emule-harness\helper-emule-harness-stop-parity-session.ps1"
$agentStopScriptPath = Join-Path $toolingRoot "subsystems\agent\helper-agent-stop-parity-session.ps1"

try {
    $seedRoot = Join-Path $toolingRoot ".local\emule-harness-seeds\$SeedBundleId"
    foreach ($requiredFile in @($manifest.seedBundle.requiredFiles)) {
        $requiredPath = Join-Path $seedRoot $requiredFile
        if (-not (Test-Path $requiredPath)) {
            throw "Seed bundle '$SeedBundleId' is missing required file '$requiredFile'"
        }
    }
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "seed-bundle-ready" -Details "Using local seed bundle '$SeedBundleId' from $seedRoot"

    $profileScriptPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessProfile.ps1"
    $profile = & $profileScriptPath `
        -ScenarioManifestPath $ScenarioManifestPath `
        -ProfileRoot $emuleHarnessProfileRoot `
        -SeedBundleId $SeedBundleId `
        -BindAddr $bindAddrValue `
        -TcpPort $EmuleHarnessTcpPort `
        -UdpPort $EmuleHarnessUdpPort `
        -ServerUdpPort $EmuleHarnessServerUdpPort
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "emule-harness-profile-materialized" -Details "Profile root created at $($profile.ProfileRoot)"

    $emuleHarnessRuntimeExePath = Resolve-EmuleHarnessRuntimeExePath -ToolingRoot $toolingRoot
    $runManifest = [ordered]@{
        schemaVersion = "run-manifest/v1"
        scenarioId = $manifest.scenarioId
        runId = $runId
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        artifactRoot = $artifactRoot
        requiredMilestoneIds = $requiredMilestoneIds
        binary = [ordered]@{
            emuleHarness = $emuleHarnessRuntimeExePath
        }
        inputs = [ordered]@{
            requestedInterfaceAlias = $InterfaceAlias
            interfaceAlias = $resolvedInterfaceAlias
            interfaceFallbackUsed = $resolvedAdapter.UsedFallback
            bindAddr = $bindAddrValue
            emuleHarnessTcpPort = $EmuleHarnessTcpPort
            emuleHarnessUdpPort = $EmuleHarnessUdpPort
            emuleHarnessServerUdpPort = $EmuleHarnessServerUdpPort
            seedBundleId = $SeedBundleId
            scenarioManifestPath = (Resolve-Path $ScenarioManifestPath).Path
        }
        artifacts = [ordered]@{
            emuleHarnessProfileRoot = $profile.ProfileRoot
            emuleHarnessProfileManifestPath = $profile.ProfileManifestPath
        }
    }
    $runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $manifestPath

    $emuleHarnessStartScriptPath = Join-Path $toolingRoot "subsystems\emule-harness\helper-emule-harness-start-parity-session.ps1"
    $emuleHarnessSession = & $emuleHarnessStartScriptPath `
        -InterfaceAlias $resolvedInterfaceAlias `
        -CapturePort $EmuleHarnessUdpPort `
        -SessionPrefix $runId `
        -WaitAfterLaunchSeconds $EmuleHarnessWarmupSeconds `
        -ProfileRoot $profile.ProfileRoot
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "emule-harness-started" -Details "eMule harness launched with profile root $($profile.ProfileRoot)"

    $agentStartScriptPath = Join-Path $toolingRoot "subsystems\agent\helper-agent-start-parity-session.ps1"
    $agentSession = & $agentStartScriptPath `
        -InterfaceIndex $AgentInterfaceIndex `
        -InterfaceAlias $resolvedInterfaceAlias `
        -CapturePort $AgentCapturePort `
        -SessionPrefix $runId
    Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "agent-started" -Details "Agent launched and exposed stats at $($agentSession.StatsUrl)"

    $seedScriptPath = Join-Path $toolingRoot "subsystems\agent\helper-agent-post-seed-popular.ps1"
    $publishAttempt = Invoke-SeedPopularWithRetry `
        -ScriptPath $seedScriptPath `
        -Ed2kHash $manifest.agent.seedRequest.hash `
        -CanonicalName $manifest.agent.seedRequest.canonicalName `
        -Size ([uint64]$manifest.agent.seedRequest.size) `
        -SourceCount ([uint32]$manifest.agent.seedRequest.sourceCount) `
        -ControlUrl $agentSession.ControlUrl `
        -TimeoutSeconds $PublishReadyTimeoutSeconds
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "manual-publish-triggered" -Details "Triggered manual publish for $($manifest.agent.seedRequest.canonicalName) after $($publishAttempt.Attempts) attempt(s)"

    if ($PublishObserveSeconds -gt 0) {
        Start-Sleep -Seconds $PublishObserveSeconds
    }

    $null = Get-AgentStatsSlice -StatsUrl $agentSession.StatsUrl -DestinationPath $agentStatsPath
    $agentExtractScriptPath = Join-Path $toolingRoot "subsystems\agent\helper-agent-extract-publish-log.ps1"
    $agentPublishArtifacts = & $agentExtractScriptPath -SessionDir $agentSession.SessionDir
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "agent-artifacts-captured" -Details "Agent publish log saved to $($agentPublishArtifacts.PublishLogPath)"

    $emuleHarnessTraceSlice = Get-EmuleHarnessTraceSlice -SessionDir $emuleHarnessSession.SessionDir
    if ($emuleHarnessSession.PacketDumpPath -or $emuleHarnessTraceSlice.LineCount -gt 0) {
        $emuleHarnessArtifactDetails = if ($emuleHarnessSession.PacketDumpPath -and $emuleHarnessTraceSlice.LineCount -gt 0) {
            "eMule harness UDP dump and trace slice captured"
        } elseif ($emuleHarnessSession.PacketDumpPath) {
            "eMule harness UDP dump captured at $($emuleHarnessSession.PacketDumpPath)"
        } else {
            "eMule harness trace slice saved to $($emuleHarnessTraceSlice.SlicePath)"
        }
        Set-MilestonePassed -MilestoneMap $milestoneMap -Id "emule-harness-artifacts-captured" -Details $emuleHarnessArtifactDetails
    }

    if (-not $KeepSessionsRunning) {
        & $emuleHarnessStopScriptPath -SessionDir $emuleHarnessSession.SessionDir | Out-Null
        & $agentStopScriptPath -SessionDir $agentSession.SessionDir | Out-Null
    }

    $agentSessionMetadataPath = Join-Path $agentSession.SessionDir "agent-session.json"
    $agentSessionMetadata = Get-Content -Raw $agentSessionMetadataPath | ConvertFrom-Json
    if ($agentSessionMetadata.PacketDumpPath -and $emuleHarnessSession.PacketDumpPath) {
        $compareToolPath = Join-Path $toolingRoot "subsystems\parity\helper-parity-compare-udp-jsonl.py"
        $compareOutput = & python $compareToolPath `
            --emule-harness $emuleHarnessSession.PacketDumpPath `
            --agent $agentSessionMetadata.PacketDumpPath `
            --opcodes KADEMLIA2_HELLO_REQ KADEMLIA2_HELLO_RES KADEMLIA2_HELLO_RES_ACK KADEMLIA2_PUBLISH_KEY_REQ KADEMLIA2_PUBLISH_SOURCE_REQ KADEMLIA2_PUBLISH_RES
        $compareOutput | Set-Content -Encoding utf8NoBOM $parityOutputPath
        Set-MilestonePassed -MilestoneMap $milestoneMap -Id "udp-parity-compared" -Details "UDP parity report saved to $parityOutputPath"
    }

    $runStatus = if (Test-MilestonesPassed -MilestoneMap $milestoneMap -RequiredMilestoneIds $requiredMilestoneIds) {
        "passed"
    } else {
        "failed"
    }

    $emuleHarnessTraceLines = if ($emuleHarnessTraceSlice) { $emuleHarnessTraceSlice.LineCount } else { 0 }
    $emuleHarnessHelloEvents = if ($emuleHarnessTraceSlice) { $emuleHarnessTraceSlice.HelloEvents } else { 0 }
    $emuleHarnessPublishEvents = if ($emuleHarnessTraceSlice) { $emuleHarnessTraceSlice.PublishEvents } else { 0 }
    $emuleHarnessPublishAccepts = if ($emuleHarnessTraceSlice) { $emuleHarnessTraceSlice.PublishAccepts } else { 0 }
    $agentPublishLogLines = if ($agentPublishArtifacts) { $agentPublishArtifacts.PublishLineCount } else { 0 }
    $agentUdpDumpPresent = if ($agentSessionMetadata) { [bool]$agentSessionMetadata.PacketDumpPath } else { $false }
    $emuleHarnessUdpDumpPresent = if ($emuleHarnessSession) { [bool]$emuleHarnessSession.PacketDumpPath } else { $false }
    $emuleHarnessSessionDir = if ($emuleHarnessSession) { $emuleHarnessSession.SessionDir } else { $null }
    $agentSessionDir = if ($agentSession) { $agentSession.SessionDir } else { $null }
    $emuleHarnessPacketDumpPath = if ($emuleHarnessSession) { $emuleHarnessSession.PacketDumpPath } else { $null }
    $emuleHarnessTraceSlicePath = if ($emuleHarnessTraceSlice) { $emuleHarnessTraceSlice.SlicePath } else { $null }
    $agentPacketDumpPath = if ($agentSessionMetadata) { $agentSessionMetadata.PacketDumpPath } else { $null }
    $agentPublishLogPath = if ($agentPublishArtifacts) { $agentPublishArtifacts.PublishLogPath } else { $null }
    $udpParityPath = if (Test-Path $parityOutputPath) { $parityOutputPath } else { $null }

    $runSummary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $manifest.scenarioId
        runId = $runId
        status = $runStatus
        requiredMilestoneIds = $requiredMilestoneIds
        milestones = @($milestoneMap.Values)
        counters = [ordered]@{
            emuleHarnessTraceLines = $emuleHarnessTraceLines
            emuleHarnessHelloEvents = $emuleHarnessHelloEvents
            emuleHarnessPublishEvents = $emuleHarnessPublishEvents
            emuleHarnessPublishAccepts = $emuleHarnessPublishAccepts
            agentPublishLogLines = $agentPublishLogLines
            agentUdpDumpPresent = $agentUdpDumpPresent
            emuleHarnessUdpDumpPresent = $emuleHarnessUdpDumpPresent
        }
        artifactPaths = [ordered]@{
            runManifestPath = $manifestPath
            emuleHarnessProfileRoot = $profile.ProfileRoot
            emuleHarnessSessionDir = $emuleHarnessSessionDir
            agentSessionDir = $agentSessionDir
            emuleHarnessPacketDumpPath = $emuleHarnessPacketDumpPath
            emuleHarnessTraceSlicePath = $emuleHarnessTraceSlicePath
            agentPacketDumpPath = $agentPacketDumpPath
            agentStatsPath = $agentStatsPath
            agentPublishLogPath = $agentPublishLogPath
            udpParityPath = $udpParityPath
            summaryPath = $summaryPath
        }
    }
    $runSummary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $summaryPath
    if ($runStatus -ne "passed") {
        throw "Required scenario milestones were not all satisfied"
    }
    $runSummary
}
catch {
    $failureSummary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $manifest.scenarioId
        runId = $runId
        status = "failed"
        requiredMilestoneIds = $requiredMilestoneIds
        milestones = @($milestoneMap.Values)
        counters = [ordered]@{}
        artifactPaths = [ordered]@{
            runManifestPath = $manifestPath
            summaryPath = $summaryPath
        }
        error = $_.Exception.Message
    }
    $failureSummary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $summaryPath
    throw
}
finally {
    if (-not $KeepSessionsRunning) {
        if ($agentSession -and (Test-Path $agentSession.SessionDir)) {
            try {
                & $agentStopScriptPath -SessionDir $agentSession.SessionDir | Out-Null
            } catch {
            }
        }
        if ($emuleHarnessSession -and (Test-Path $emuleHarnessSession.SessionDir)) {
            try {
                & $emuleHarnessStopScriptPath -SessionDir $emuleHarnessSession.SessionDir | Out-Null
            } catch {
            }
        }
    }
    if (Test-Path $lockPath) {
        Remove-Item -LiteralPath $lockPath -Force
    }
}

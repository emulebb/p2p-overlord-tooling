#Requires -Version 7.6
<#
.SYNOPSIS
Runs the first deterministic Kad oracle+agent parity scenario.

.DESCRIPTION
Creates a clean-room oracle profile, launches the oracle with an explicit
profile-root override, launches the agent, triggers a deterministic manual
publish, captures artifacts, and writes run manifest and summary JSON files.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\kad.startup.hello.publish.realnet.v1\manifest.v1.json"),
    [string]$SeedBundleId = "canonical",
    [string]$InterfaceAlias = "hide.me",
    [string]$BindAddr,
    [int]$OracleTcpPort = 46671,
    [int]$OracleUdpPort = 46673,
    [int]$OracleServerUdpPort = 0,
    [int]$AgentInterfaceIndex = 0,
    [int]$AgentCapturePort = 41000,
    [int]$OracleWarmupSeconds = 20,
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
        [string]$AdapterAlias
    )

    if ($ExplicitBindAddr) {
        return $ExplicitBindAddr
    }

    $vpnIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.InterfaceAlias -eq $AdapterAlias -and $_.AddressState -eq "Preferred" } |
        Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $vpnIp) {
        throw "No preferred IPv4 address found on interface '$AdapterAlias'"
    }

    return $vpnIp
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

function Get-OracleTraceSlice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionDir
    )

    $metadataPath = Join-Path $SessionDir "oracle-session.json"
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

    $slicePath = Join-Path $SessionDir "oracle-trace-new.log"
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

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$workspaceRoot = Resolve-Path (Join-Path $toolingRoot "..")
$manifest = Get-Content -Raw $ScenarioManifestPath | ConvertFrom-Json
$requiredMilestoneIds = @(Get-RequiredMilestoneIds -Manifest $manifest)
$bindAddrValue = Resolve-BindAddress -ExplicitBindAddr $BindAddr -AdapterAlias $InterfaceAlias

if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}
if (-not $env:OVERLORD_LOG_DIR) {
    throw "OVERLORD_LOG_DIR is not set"
}

$requiredPaths = @(
    (Join-Path $toolingRoot "profiles\\New-OracleProfile.ps1"),
    (Join-Path $toolingRoot "helper-oracle-start-parity-session.ps1"),
    (Join-Path $toolingRoot "helper-oracle-stop-parity-session.ps1"),
    (Join-Path $toolingRoot "helper-agent-start-parity-session.ps1"),
    (Join-Path $toolingRoot "helper-agent-stop-parity-session.ps1"),
    (Join-Path $toolingRoot "helper-agent-post-seed-popular.ps1"),
    (Join-Path $toolingRoot "helper-agent-extract-publish-log.ps1"),
    (Join-Path $toolingRoot "helper-parity-compare-udp-jsonl.py")
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
$oracleProfileRoot = Join-Path $artifactRoot "oracle-profile"
$manifestPath = Join-Path $artifactRoot "run-manifest.json"
$summaryPath = Join-Path $artifactRoot "run-summary.json"
$parityOutputPath = Join-Path $artifactRoot "udp-parity.txt"
$agentStatsPath = Join-Path $artifactRoot "agent-stats.json"

New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
"lock" | Set-Content -Encoding utf8NoBOM $lockPath

$milestoneMap = New-MilestoneMap -Milestones $manifest.milestones
$oracleSession = $null
$agentSession = $null
$oracleTraceSlice = $null
$agentPublishArtifacts = $null
$agentSessionMetadata = $null
$oracleStopScriptPath = Join-Path $toolingRoot "helper-oracle-stop-parity-session.ps1"
$agentStopScriptPath = Join-Path $toolingRoot "helper-agent-stop-parity-session.ps1"

try {
    $seedRoot = Join-Path $toolingRoot ".local\oracle-seeds\$SeedBundleId"
    foreach ($requiredFile in @($manifest.seedBundle.requiredFiles)) {
        $requiredPath = Join-Path $seedRoot $requiredFile
        if (-not (Test-Path $requiredPath)) {
            throw "Seed bundle '$SeedBundleId' is missing required file '$requiredFile'"
        }
    }
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "seed-bundle-ready" -Details "Using local seed bundle '$SeedBundleId' from $seedRoot"

    $profileScriptPath = Join-Path $toolingRoot "profiles\New-OracleProfile.ps1"
    $profile = & $profileScriptPath `
        -ScenarioManifestPath $ScenarioManifestPath `
        -ProfileRoot $oracleProfileRoot `
        -SeedBundleId $SeedBundleId `
        -BindAddr $bindAddrValue `
        -TcpPort $OracleTcpPort `
        -UdpPort $OracleUdpPort `
        -ServerUdpPort $OracleServerUdpPort
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "oracle-profile-materialized" -Details "Profile root created at $($profile.ProfileRoot)"

    $runManifest = [ordered]@{
        schemaVersion = "run-manifest/v1"
        scenarioId = $manifest.scenarioId
        runId = $runId
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        artifactRoot = $artifactRoot
        requiredMilestoneIds = $requiredMilestoneIds
        binary = [ordered]@{
            oracle = (Join-Path $workspaceRoot ($manifest.oracle.binaryRelativePath -replace '/', '\'))
        }
        inputs = [ordered]@{
            interfaceAlias = $InterfaceAlias
            bindAddr = $bindAddrValue
            oracleTcpPort = $OracleTcpPort
            oracleUdpPort = $OracleUdpPort
            oracleServerUdpPort = $OracleServerUdpPort
            seedBundleId = $SeedBundleId
            scenarioManifestPath = (Resolve-Path $ScenarioManifestPath).Path
        }
        artifacts = [ordered]@{
            oracleProfileRoot = $profile.ProfileRoot
            oracleProfileManifestPath = $profile.ProfileManifestPath
        }
    }
    $runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $manifestPath

    $oracleStartScriptPath = Join-Path $toolingRoot "helper-oracle-start-parity-session.ps1"
    $oracleSession = & $oracleStartScriptPath `
        -InterfaceAlias $InterfaceAlias `
        -CapturePort $OracleUdpPort `
        -SessionPrefix $runId `
        -WaitAfterLaunchSeconds $OracleWarmupSeconds `
        -ProfileRoot $profile.ProfileRoot
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "oracle-started" -Details "Oracle launched with profile root $($profile.ProfileRoot)"

    $agentStartScriptPath = Join-Path $toolingRoot "helper-agent-start-parity-session.ps1"
    $agentSession = & $agentStartScriptPath `
        -InterfaceIndex $AgentInterfaceIndex `
        -InterfaceAlias $InterfaceAlias `
        -CapturePort $AgentCapturePort `
        -SessionPrefix $runId
    Wait-AgentControlReady -StatsUrl $manifest.agent.statsUrl
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "agent-started" -Details "Agent launched and exposed stats at $($manifest.agent.statsUrl)"

    $seedScriptPath = Join-Path $toolingRoot "helper-agent-post-seed-popular.ps1"
    $publishAttempt = Invoke-SeedPopularWithRetry `
        -ScriptPath $seedScriptPath `
        -Ed2kHash $manifest.agent.seedRequest.hash `
        -CanonicalName $manifest.agent.seedRequest.canonicalName `
        -Size ([uint64]$manifest.agent.seedRequest.size) `
        -SourceCount ([uint32]$manifest.agent.seedRequest.sourceCount) `
        -ControlUrl $manifest.agent.controlUrl `
        -TimeoutSeconds $PublishReadyTimeoutSeconds
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "manual-publish-triggered" -Details "Triggered manual publish for $($manifest.agent.seedRequest.canonicalName) after $($publishAttempt.Attempts) attempt(s)"

    if ($PublishObserveSeconds -gt 0) {
        Start-Sleep -Seconds $PublishObserveSeconds
    }

    $null = Get-AgentStatsSlice -StatsUrl $manifest.agent.statsUrl -DestinationPath $agentStatsPath
    $agentExtractScriptPath = Join-Path $toolingRoot "helper-agent-extract-publish-log.ps1"
    $agentPublishArtifacts = & $agentExtractScriptPath -SessionDir $agentSession.SessionDir
    Set-MilestonePassed -MilestoneMap $milestoneMap -Id "agent-artifacts-captured" -Details "Agent publish log saved to $($agentPublishArtifacts.PublishLogPath)"

    $oracleTraceSlice = Get-OracleTraceSlice -SessionDir $oracleSession.SessionDir
    if ($oracleSession.PacketDumpPath -or $oracleTraceSlice.LineCount -gt 0) {
        $oracleArtifactDetails = if ($oracleSession.PacketDumpPath -and $oracleTraceSlice.LineCount -gt 0) {
            "Oracle UDP dump and trace slice captured"
        } elseif ($oracleSession.PacketDumpPath) {
            "Oracle UDP dump captured at $($oracleSession.PacketDumpPath)"
        } else {
            "Oracle trace slice saved to $($oracleTraceSlice.SlicePath)"
        }
        Set-MilestonePassed -MilestoneMap $milestoneMap -Id "oracle-artifacts-captured" -Details $oracleArtifactDetails
    }

    if (-not $KeepSessionsRunning) {
        & $oracleStopScriptPath -SessionDir $oracleSession.SessionDir | Out-Null
        & $agentStopScriptPath -SessionDir $agentSession.SessionDir | Out-Null
    }

    $agentSessionMetadataPath = Join-Path $agentSession.SessionDir "agent-session.json"
    $agentSessionMetadata = Get-Content -Raw $agentSessionMetadataPath | ConvertFrom-Json
    if ($agentSessionMetadata.PacketDumpPath -and $oracleSession.PacketDumpPath) {
        $compareToolPath = Join-Path $toolingRoot "helper-parity-compare-udp-jsonl.py"
        $compareOutput = & python $compareToolPath `
            --oracle $oracleSession.PacketDumpPath `
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

    $oracleTraceLines = if ($oracleTraceSlice) { $oracleTraceSlice.LineCount } else { 0 }
    $oracleHelloEvents = if ($oracleTraceSlice) { $oracleTraceSlice.HelloEvents } else { 0 }
    $oraclePublishEvents = if ($oracleTraceSlice) { $oracleTraceSlice.PublishEvents } else { 0 }
    $oraclePublishAccepts = if ($oracleTraceSlice) { $oracleTraceSlice.PublishAccepts } else { 0 }
    $agentPublishLogLines = if ($agentPublishArtifacts) { $agentPublishArtifacts.PublishLineCount } else { 0 }
    $agentUdpDumpPresent = if ($agentSessionMetadata) { [bool]$agentSessionMetadata.PacketDumpPath } else { $false }
    $oracleUdpDumpPresent = if ($oracleSession) { [bool]$oracleSession.PacketDumpPath } else { $false }
    $oracleSessionDir = if ($oracleSession) { $oracleSession.SessionDir } else { $null }
    $agentSessionDir = if ($agentSession) { $agentSession.SessionDir } else { $null }
    $oraclePacketDumpPath = if ($oracleSession) { $oracleSession.PacketDumpPath } else { $null }
    $oracleTraceSlicePath = if ($oracleTraceSlice) { $oracleTraceSlice.SlicePath } else { $null }
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
            oracleTraceLines = $oracleTraceLines
            oracleHelloEvents = $oracleHelloEvents
            oraclePublishEvents = $oraclePublishEvents
            oraclePublishAccepts = $oraclePublishAccepts
            agentPublishLogLines = $agentPublishLogLines
            agentUdpDumpPresent = $agentUdpDumpPresent
            oracleUdpDumpPresent = $oracleUdpDumpPresent
        }
        artifactPaths = [ordered]@{
            runManifestPath = $manifestPath
            oracleProfileRoot = $profile.ProfileRoot
            oracleSessionDir = $oracleSessionDir
            agentSessionDir = $agentSessionDir
            oraclePacketDumpPath = $oraclePacketDumpPath
            oracleTraceSlicePath = $oracleTraceSlicePath
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
        if ($oracleSession -and (Test-Path $oracleSession.SessionDir)) {
            try {
                & $oracleStopScriptPath -SessionDir $oracleSession.SessionDir | Out-Null
            } catch {
            }
        }
    }
    if (Test-Path $lockPath) {
        Remove-Item -LiteralPath $lockPath -Force
    }
}

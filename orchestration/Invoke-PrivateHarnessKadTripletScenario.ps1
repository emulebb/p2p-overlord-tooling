#Requires -Version 7.6
<#
.SYNOPSIS
Runs a local loopback-only Kad cluster with three eMule harness instances and one agent.

.DESCRIPTION
Builds the eMule harness through the canonical eMule-build entrypoint, starts the
coordinator if needed, materializes three isolated harness profiles, boots one
local agent against the cluster, waits for harness publishes, triggers one manual
agent publish, runs a coordinator keyword search for "ubuntu linux", and captures
the resulting artifacts.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\kad.harness.triplet.local.v1\manifest.v1.json"),
    [ValidateSet("Debug")]
    [string]$HarnessBuildConfig = "Debug",
    [int]$HarnessContactTimeoutSeconds = 240,
    [int]$HarnessPublishSettleSeconds = 120,
    [int]$AgentPublishTimeoutSeconds = 180,
    [int]$SearchTimeoutSeconds = 180,
    [int]$SearchRetryDelaySeconds = 15,
    [switch]$KeepSessionsRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Wait-AgentControlReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
            if ($null -ne $response) {
                return $response
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }

    throw "Agent stats endpoint did not become ready at $StatsUrl within $TimeoutSeconds seconds"
}

function Wait-AgentKadBootstrapReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 180,
        [int]$MinimumPeersConnected = 1
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
            if ($null -ne $response -and [int]$response.peers_connected -ge $MinimumPeersConnected) {
                return $response
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }

    throw "Agent Kad bootstrap did not become ready at $StatsUrl within $TimeoutSeconds seconds"
}

function Wait-CoordinatorReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CoordinatorUrl,
        [int]$TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $CoordinatorUrl.TrimEnd("/") -TimeoutSec 10 -SkipHttpErrorCheck
            if ($null -ne $response -and [int]$response.StatusCode -gt 0) {
                return
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }

    throw "Coordinator did not become ready at $CoordinatorUrl within $TimeoutSeconds seconds"
}

function Get-CoordinatorProcesses {
    @(
        Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*node_modules\\vite\\bin\\vite.js*' }
    )
}

function New-SeedPdfFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$MarkerText,
        [Parameter(Mandatory = $true)]
        [int]$RepeatCount
    )

    $line = "%PDF-1.4`n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj`n2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj`n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>endobj`n4 0 obj<</Length 128>>stream`nBT /F1 12 Tf 32 120 Td ($MarkerText) Tj ET`nendstream`nendobj`nxref`n0 5`n0000000000 65535 f `ntrailer<</Size 5/Root 1 0 R>>`nstartxref`n0`n%%EOF`n"
    $builder = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt $RepeatCount; $index++) {
        [void]$builder.Append($line)
    }

    [System.IO.File]::WriteAllText(
        $Path,
        $builder.ToString(),
        (New-Object System.Text.ASCIIEncoding)
    )
}

function Parse-Ed2kLinkFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $link = (Get-Content -LiteralPath $Path -Raw).Trim()
    $pattern = '^ed2k://\|file\|(?<Name>[^|]+)\|(?<Size>\d+)\|(?<Hash>[0-9A-Fa-f]{32})\|'
    if ($link -notmatch $pattern) {
        throw "ED2K link at $Path is not in the expected format"
    }

    [pscustomobject]@{
        Link = $link
        FileName = $matches.Name
        FileSize = [UInt64]$matches.Size
        FileHash = $matches.Hash.ToLowerInvariant()
    }
}

function Wait-Path {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for path $Path"
}

function Get-NewHarnessTraceLines {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HarnessSession
    )

    if (-not (Test-Path -LiteralPath $HarnessSession.TraceLogPath)) {
        return @()
    }

    return @(
        Get-Content -LiteralPath $HarnessSession.TraceLogPath |
            Select-Object -Skip ([int]$HarnessSession.TraceLinesBefore)
    )
}

function Wait-HarnessPublishReady {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HarnessSession,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $tracePattern = 'event=(publish_|search_storefile_prepare|search_storekeyword_prepare|search_storesource_prepare)'
    $verbosePattern = 'eMule harness publish gate ready|eMule harness publish start family='
    while ((Get-Date) -lt $deadline) {
        $lines = @(Get-NewHarnessTraceLines -HarnessSession $HarnessSession)
        $publishLines = @($lines | Where-Object { $_ -match $tracePattern })
        if ($publishLines.Count -gt 0) {
            return [pscustomobject]@{
                Ready = $true
                Source = "trace"
                TraceLineCount = $lines.Count
                PublishLineCount = $publishLines.Count
            }
        }

        if (Test-Path -LiteralPath $HarnessSession.VerboseLogPath) {
            $verboseLines = @(Get-Content -LiteralPath $HarnessSession.VerboseLogPath)
            $verbosePublishLines = @($verboseLines | Where-Object { $_ -match $verbosePattern })
            if ($verbosePublishLines.Count -gt 0) {
                return [pscustomobject]@{
                    Ready = $true
                    Source = "verbose"
                    TraceLineCount = $lines.Count
                    PublishLineCount = $verbosePublishLines.Count
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "Harness session $($HarnessSession.EmuleHarnessProfileRoot) did not emit publish-ready trace markers within $TimeoutSeconds seconds"
}

function Wait-HarnessContactReady {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HarnessSession,
        [int]$TimeoutSeconds = 240
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $contactPattern = 'Updating contact, passed key check'
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $HarnessSession.VerboseLogPath) {
            $match = Select-String -LiteralPath $HarnessSession.VerboseLogPath -Pattern $contactPattern | Select-Object -Last 1
            if ($match) {
                return [pscustomobject]@{
                    Ready = $true
                    MatchedLine = $match.Line
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "Harness session $($HarnessSession.EmuleHarnessProfileRoot) did not validate any Kad contact within $TimeoutSeconds seconds"
}

function Invoke-AgentManualPublishWhenReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeedScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$ControlUrl,
        [Parameter(Mandatory = $true)]
        [string]$Ed2kHash,
        [Parameter(Mandatory = $true)]
        [string]$CanonicalName,
        [Parameter(Mandatory = $true)]
        [UInt64]$Size,
        [UInt32]$SourceCount = 1,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            & $SeedScriptPath `
                -Ed2kHash $Ed2kHash `
                -CanonicalName $CanonicalName `
                -Size $Size `
                -SourceCount $SourceCount `
                -ControlUrl $ControlUrl | Out-Null
            return
        }
        catch {
            $lastError = $_
            $message = [string]$_.Exception.Message
            if (
                $message -notmatch 'kad node is not bootstrapped yet' -and
                $message -notmatch '\b501\b'
            ) {
                throw
            }
        }

        Start-Sleep -Seconds 2
    }

    if ($null -ne $lastError) {
        throw $lastError
    }

    throw "Agent manual Kad publish did not become ready within $TimeoutSeconds seconds"
}

function Get-HarnessPublishSummary {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HarnessSession
    )

    $tracePattern = 'event=(publish_|search_storefile_prepare|search_storekeyword_prepare|search_storesource_prepare)'
    $verbosePattern = 'eMule harness publish gate ready|eMule harness publish start family='
    $traceLines = @(Get-NewHarnessTraceLines -HarnessSession $HarnessSession)
    $tracePublishLines = @($traceLines | Where-Object { $_ -match $tracePattern })
    $verbosePublishLines = @()
    if (Test-Path -LiteralPath $HarnessSession.VerboseLogPath) {
        $verbosePublishLines = @(
            Get-Content -LiteralPath $HarnessSession.VerboseLogPath |
                Where-Object { $_ -match $verbosePattern }
        )
    }

    [pscustomobject]@{
        TraceLineCount = $traceLines.Count
        PublishLineCount = $tracePublishLines.Count + $verbosePublishLines.Count
        TracePublishLineCount = $tracePublishLines.Count
        VerbosePublishLineCount = $verbosePublishLines.Count
    }
}

function Wait-AgentManualPublish {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $stats = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
            $observability = $stats.publish_observability
            if (
                $null -ne $observability -and
                $null -ne $observability.last_seed_source -and
                [string]$observability.last_seed_source -eq "manual_api" -and
                $null -ne $observability.latest_keyword_batch -and
                [int]$observability.latest_keyword_batch.attempted_contacts -gt 0
            ) {
                return $stats
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }

    throw "Agent manual Kad publish did not become observable at $StatsUrl within $TimeoutSeconds seconds"
}

function Invoke-CoordinatorKeywordSearch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CoordinatorUrl,
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $payload = [pscustomobject]@{
        protocol = "kad2"
        kind = "keyword"
        query = $Query
    }

    Invoke-RestMethod `
        -Method Post `
        -Uri ("{0}/api/search" -f $CoordinatorUrl.TrimEnd("/")) `
        -ContentType "application/json" `
        -Body ($payload | ConvertTo-Json -Depth 5)
}

function Get-CoordinatorSearchJob {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CoordinatorUrl,
        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    Invoke-RestMethod -Uri ("{0}/api/search/{1}" -f $CoordinatorUrl.TrimEnd("/"), $JobId) -TimeoutSec 10
}

function Get-SearchMatchedNames {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$SearchJob
    )

    $names = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($SearchJob.results)) {
        foreach ($name in @($record.names)) {
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [void]$names.Add([string]$name)
            }
        }
    }

    return @($names | Sort-Object)
}

function Test-SearchContainsRequiredFiles {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$SearchJob,
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredFileNames,
        [int]$ExpectedMinimumResults = 0
    )

    if ([int]$SearchJob.result_count -lt $ExpectedMinimumResults) {
        return $false
    }

    $matchedNames = Get-SearchMatchedNames -SearchJob $SearchJob
    foreach ($requiredFileName in $RequiredFileNames) {
        if ($requiredFileName -notin $matchedNames) {
            return $false
        }
    }

    return $true
}

function Wait-CoordinatorSearchResultSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CoordinatorUrl,
        [Parameter(Mandatory = $true)]
        [string]$JobId,
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredFileNames,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedMinimumResults,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastJob = $null
    while ((Get-Date) -lt $deadline) {
        $lastJob = Get-CoordinatorSearchJob -CoordinatorUrl $CoordinatorUrl -JobId $JobId
        if (
            Test-SearchContainsRequiredFiles `
                -SearchJob $lastJob `
                -RequiredFileNames $RequiredFileNames `
                -ExpectedMinimumResults $ExpectedMinimumResults
        ) {
            return $lastJob
        }

        if (@("failed", "cancelled") -contains [string]$lastJob.status) {
            break
        }

        Start-Sleep -Seconds 2
    }

    if ($null -ne $lastJob) {
        return $lastJob
    }

    throw "Coordinator search job $JobId did not become readable"
}

function Copy-IfExists {
    param(
        [string]$Path,
        [string]$DestinationRoot
    )

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Copy-Item -LiteralPath $Path -Destination (Join-Path $DestinationRoot (Split-Path -Leaf $Path)) -Force
    }
}

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifest = Get-Content -Raw $ScenarioManifestPath | ConvertFrom-Json
$agentBootstrapReadyContacts = if ($null -ne $manifest.agent.bootstrapReadyContacts) {
    [int]$manifest.agent.bootstrapReadyContacts
}
else {
    10
}

if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}
if (-not $env:OVERLORD_LOG_DIR) {
    throw "OVERLORD_LOG_DIR is not set"
}
if (-not $env:OVERLORD_PROJECT_DIR) {
    throw "OVERLORD_PROJECT_DIR is not set"
}

$runId = "{0}-{1}" -f $manifest.scenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\{0}\{1}" -f $manifest.scenarioId, $runId)
$harnessArtifactRoot = Join-Path $artifactRoot "harnesses"
$agentArtifactRoot = Join-Path $artifactRoot "agent"
$coordinatorArtifactRoot = Join-Path $artifactRoot "coordinator"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$searchResultPath = Join-Path $artifactRoot "search-result.json"
$agentStatsPath = Join-Path $artifactRoot "agent-stats.json"

foreach ($path in @($artifactRoot, $harnessArtifactRoot, $agentArtifactRoot, $coordinatorArtifactRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$buildScriptPath = Join-Path $toolingRoot "helper-emule-harness-build-debug.ps1"
$harnessDirResolverPath = Join-Path $toolingRoot "helper-emule-harness-resolve-harness-debug-dir.ps1"
$profileScriptPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"
$harnessStartScriptPath = Join-Path $toolingRoot "helper-emule-harness-start-private-ed2k-session.ps1"
$harnessStopScriptPath = Join-Path $toolingRoot "helper-emule-harness-stop-parity-session.ps1"
$harnessCleanupScriptPath = Join-Path $toolingRoot "helper-emule-harness-clean-runtime.ps1"
$agentStartScriptPath = Join-Path $toolingRoot "helper-agent-start-private-ed2k-session.ps1"
$agentStopScriptPath = Join-Path $toolingRoot "helper-agent-stop-parity-session.ps1"
$agentSeedScriptPath = Join-Path $toolingRoot "helper-agent-post-seed-popular.ps1"
$coordinatorStartScriptPath = Join-Path $env:OVERLORD_PROJECT_DIR "p2p-overlord-be\overlord-be-coordinator\scripts\windows\coordinator_run_start_direct.cmd"

foreach ($requiredPath in @(
    $buildScriptPath,
    $harnessDirResolverPath,
    $profileScriptPath,
    $harnessStartScriptPath,
    $harnessStopScriptPath,
    $harnessCleanupScriptPath,
    $agentStartScriptPath,
    $agentStopScriptPath,
    $agentSeedScriptPath,
    $coordinatorStartScriptPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required scenario helper not found at $requiredPath"
    }
}

$buildUsedFallback = $false
$buildFallbackReason = $null
try {
    & $buildScriptPath | Out-Null
}
catch {
    $harnessDebugDir = & $harnessDirResolverPath
    $runtimeExePath = Join-Path $harnessDebugDir "eMule_v072a_parity.exe"
    if (-not (Test-Path -LiteralPath $runtimeExePath)) {
        throw
    }

    $buildUsedFallback = $true
    $buildFallbackReason = $_.Exception.Message
}

& $harnessCleanupScriptPath -CapturePort 0 | Out-Null

$preexistingCoordinatorPids = @(
    Get-CoordinatorProcesses | ForEach-Object { [int]$_.ProcessId }
)
$startedCoordinatorPids = @()
$harnessProfiles = @()
$harnessSessions = @()
$harnessPublishSummaries = @()
$harnessContactSummaries = @()
$harnessLinkRecords = @()
$agentSession = $null
$agentStats = $null
$searchAttempts = @()
$successfulSearch = $null
$failedReason = $null

$runManifest = [ordered]@{
    schemaVersion = "run-manifest/v1"
    scenarioId = $manifest.scenarioId
    runId = $runId
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    artifactRoot = $artifactRoot
    coordinatorUrl = $manifest.coordinator.url
    searchQuery = $manifest.search.query
    harnessCount = @($manifest.harnesses).Count
}
$runManifest | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8NoBOM $runManifestPath

try {
    if ($preexistingCoordinatorPids.Count -eq 0) {
        Start-Process `
            -FilePath "cmd.exe" `
            -ArgumentList "/c", $coordinatorStartScriptPath `
            -WorkingDirectory $env:OVERLORD_PROJECT_DIR `
            -WindowStyle Hidden | Out-Null
    }

    Wait-CoordinatorReady -CoordinatorUrl $manifest.coordinator.url -TimeoutSeconds 120
    if ($preexistingCoordinatorPids.Count -eq 0) {
        $startedCoordinatorPids = @(
            Get-CoordinatorProcesses |
                Where-Object { $_.ProcessId -notin $preexistingCoordinatorPids } |
                ForEach-Object { [int]$_.ProcessId }
        )
    }

    foreach ($harness in @($manifest.harnesses)) {
        $profileRoot = Join-Path $artifactRoot $harness.id
        $seedPath = Join-Path $profileRoot ("Incoming\{0}" -f $harness.seedFileName)
        $linkPath = Join-Path $profileRoot "seed.ed2k"

        $profile = & $profileScriptPath `
            -ProfileRoot $profileRoot `
            -BindAddr $harness.bindAddr `
            -TcpPort ([UInt16]$harness.tcpPort) `
            -UdpPort ([UInt16]$harness.udpPort) `
            -ServerUdpPort ([UInt16]$harness.serverUdpPort) `
            -WebPort ([UInt16]$harness.webPort) `
            -KadUdpKey ([UInt32]$harness.kadUdpKey) `
            -KadIdHex $harness.kadIdHex `
            -EnableKademlia $true `
            -EnableEd2k $false `
            -ResetTransientState

        New-SeedPdfFile -Path $seedPath -MarkerText $harness.markerText -RepeatCount ([int]$harness.seedRepeatCount)

        $startParams = @{
            ProfileRoot = $profile.ProfileRoot
            SeedFilePath = $seedPath
            ExportLinkPath = $linkPath
            AgentBootstrapNode = [string]$harness.bootstrapPeers
            BuildConfig = $HarnessBuildConfig
            SkipRuntimeCleanup = $true
        }
        $session = & $harnessStartScriptPath @startParams

        $harnessProfiles += $profile
        $harnessSessions += $session
        Wait-Path -Path $linkPath -TimeoutSeconds 60
        $harnessLinkRecords += (Parse-Ed2kLinkFile -Path $linkPath)
    }

    foreach ($session in @($harnessSessions)) {
        $harnessContactSummaries += (Wait-HarnessContactReady -HarnessSession $session -TimeoutSeconds $HarnessContactTimeoutSeconds)
    }

    if ($HarnessPublishSettleSeconds -gt 0) {
        Start-Sleep -Seconds $HarnessPublishSettleSeconds
    }

    $firstHarnessBootstrap = "{0}:{1}" -f $manifest.harnesses[0].bindAddr, [UInt16]$manifest.harnesses[0].udpPort
    $agentSession = & $agentStartScriptPath `
        -ScenarioRoot (Join-Path $artifactRoot "agent-runtime") `
        -EmuleHarnessBootstrapNode $firstHarnessBootstrap `
        -ControlPort ([UInt16]$manifest.agent.controlPort) `
        -KadPort ([UInt16]$manifest.agent.kadPort) `
        -Ed2kPort ([UInt16]$manifest.agent.ed2kPort) `
        -P2pBindIp $manifest.agent.p2pBindIp `
        -KadBootstrapReadyContacts ([UInt32]$agentBootstrapReadyContacts)

    $agentStats = Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl -TimeoutSeconds 180
    $agentStats = Wait-AgentKadBootstrapReady `
        -StatsUrl $agentSession.StatsUrl `
        -TimeoutSeconds 180 `
        -MinimumPeersConnected $agentBootstrapReadyContacts

    Invoke-AgentManualPublishWhenReady `
        -SeedScriptPath $agentSeedScriptPath `
        -Ed2kHash $manifest.agent.manualPublish.hash `
        -CanonicalName $manifest.agent.manualPublish.canonicalName `
        -Size ([UInt64]$manifest.agent.manualPublish.size) `
        -SourceCount ([UInt32]$manifest.agent.manualPublish.sourceCount) `
        -ControlUrl $agentSession.ControlUrl `
        -TimeoutSeconds $AgentPublishTimeoutSeconds

    $agentStats = Wait-AgentManualPublish -StatsUrl $agentSession.StatsUrl -TimeoutSeconds $AgentPublishTimeoutSeconds
    $agentStats | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8NoBOM $agentStatsPath

    foreach ($session in @($harnessSessions)) {
        $harnessPublishSummaries += (Get-HarnessPublishSummary -HarnessSession $session)
    }

    $requiredFileNames = @($manifest.harnesses | ForEach-Object { [string]$_.seedFileName })
    for ($attempt = 1; $attempt -le [int]$manifest.search.retryCount; $attempt++) {
        $searchJob = Invoke-CoordinatorKeywordSearch `
            -CoordinatorUrl $manifest.coordinator.url `
            -Query $manifest.search.query

        $finalJob = Wait-CoordinatorSearchResultSet `
            -CoordinatorUrl $manifest.coordinator.url `
            -JobId $searchJob.job_id `
            -RequiredFileNames $requiredFileNames `
            -ExpectedMinimumResults ([int]$manifest.search.expectedMinimumResults) `
            -TimeoutSeconds $SearchTimeoutSeconds

        $attemptRecord = [ordered]@{
            attempt = $attempt
            jobId = $searchJob.job_id
            status = $finalJob.status
            resultCount = $finalJob.result_count
            matchedNames = @(Get-SearchMatchedNames -SearchJob $finalJob)
        }
        $searchAttempts += [pscustomobject]$attemptRecord

        if (
            Test-SearchContainsRequiredFiles `
                -SearchJob $finalJob `
                -RequiredFileNames $requiredFileNames `
                -ExpectedMinimumResults ([int]$manifest.search.expectedMinimumResults)
        ) {
            $successfulSearch = $finalJob
            break
        }

        if ($attempt -lt [int]$manifest.search.retryCount) {
            Start-Sleep -Seconds $SearchRetryDelaySeconds
        }
    }

    if ($null -eq $successfulSearch) {
        throw "Coordinator keyword search never returned the expected harness file set"
    }

    $successfulSearch | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8NoBOM $searchResultPath

    for ($index = 0; $index -lt $harnessSessions.Count; $index++) {
        $session = $harnessSessions[$index]
        $destinationRoot = Join-Path $harnessArtifactRoot ([string]$manifest.harnesses[$index].id)
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null

        $traceSlicePath = Join-Path $destinationRoot "harness-trace-new.log"
        (Get-NewHarnessTraceLines -HarnessSession $session) | Set-Content -Encoding utf8NoBOM $traceSlicePath

        foreach ($path in @(
            $session.ExportLinkPath,
            $session.TraceLogPath,
            $session.VerboseLogPath,
            $session.StatusLogPath,
            $session.EmuleHarnessUdpDumpPath,
            $session.EmuleHarnessEd2kTcpDumpPath
        )) {
            Copy-IfExists -Path $path -DestinationRoot $destinationRoot
        }
    }

    foreach ($path in @(
        (Join-Path $agentSession.LogRoot "overlord-agent-emule.log"),
        (Get-ChildItem -LiteralPath $agentSession.LogRoot -Filter "agent-udp-dump-*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem -LiteralPath $agentSession.LogRoot -Filter "agent-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1 -ExpandProperty FullName),
        $agentStatsPath,
        $searchResultPath
    )) {
        Copy-IfExists -Path $path -DestinationRoot $agentArtifactRoot
    }

    foreach ($logPath in @(
        (Join-Path $env:OVERLORD_LOG_DIR "coordinator_stdout.log"),
        (Join-Path $env:OVERLORD_LOG_DIR "coordinator_stderr.log")
    )) {
        Copy-IfExists -Path $logPath -DestinationRoot $coordinatorArtifactRoot
    }

    $runSummary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $manifest.scenarioId
        runId = $runId
        completed = $true
        coordinatorStartedByScenario = [bool]($startedCoordinatorPids.Count -gt 0)
        harnessBuildUsedFallback = $buildUsedFallback
        harnessBuildFallbackReason = $buildFallbackReason
        harnessContactLines = @($harnessContactSummaries | ForEach-Object { $_.MatchedLine })
        harnessPublishLineCounts = @($harnessPublishSummaries | ForEach-Object { $_.PublishLineCount })
        harnessFiles = @($harnessLinkRecords | ForEach-Object {
            [ordered]@{
                name = $_.FileName
                hash = $_.FileHash
                size = $_.FileSize
            }
        })
        agentPublish = [ordered]@{
            lastSeedSource = $agentStats.publish_observability.last_seed_source
            keywordPublishedItems = $agentStats.publish_observability.latest_keyword_batch.published_items
            keywordAttemptedContacts = $agentStats.publish_observability.latest_keyword_batch.attempted_contacts
            keywordAckedContacts = $agentStats.publish_observability.latest_keyword_batch.acked_contacts
            sourcePublishedItems = $agentStats.publish_observability.latest_source_batch.published_items
            sourceAttemptedContacts = $agentStats.publish_observability.latest_source_batch.attempted_contacts
            sourceAckedContacts = $agentStats.publish_observability.latest_source_batch.acked_contacts
        }
        search = [ordered]@{
            query = $manifest.search.query
            attempts = @($searchAttempts)
            finalJobId = $successfulSearch.job_id
            finalStatus = $successfulSearch.status
            finalResultCount = $successfulSearch.result_count
            matchedNames = @(Get-SearchMatchedNames -SearchJob $successfulSearch)
        }
        finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $runSummary | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    $runSummary
}
catch {
    $failedReason = $_.Exception.Message
    throw
}
finally {
    if (-not $KeepSessionsRunning) {
        foreach ($session in @($harnessSessions)) {
            & $harnessStopScriptPath -SessionDir $session.SessionDir | Out-Null
        }

        if ($agentSession) {
            & $agentStopScriptPath -SessionDir $agentSession.SessionDir | Out-Null
            if ($agentSession.ConfigBackupPath -and (Test-Path -LiteralPath $agentSession.ConfigBackupPath)) {
                Copy-Item -LiteralPath $agentSession.ConfigBackupPath -Destination $agentSession.ConfigPath -Force
            }
        }

        foreach ($coordinatorPid in @($startedCoordinatorPids)) {
            Stop-Process -Id $coordinatorPid -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $runSummaryPath)) {
        $failedSummary = [ordered]@{
            schemaVersion = "run-summary/v1"
            scenarioId = $manifest.scenarioId
            runId = $runId
            completed = $false
            coordinatorStartedByScenario = [bool]($startedCoordinatorPids.Count -gt 0)
            harnessBuildUsedFallback = $buildUsedFallback
            harnessBuildFallbackReason = $buildFallbackReason
            failedReason = $failedReason
            searchAttempts = @($searchAttempts)
            finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $failedSummary | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    }
}

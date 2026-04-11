#Requires -Version 7.6
<#
.SYNOPSIS
Runs a deterministic private eMule harness-to-agent Kad+ED2K download scenario.

.DESCRIPTION
Creates one local experimental eMule harness profile, shares one deterministic file,
boots the agent in local-only mode, waits for eMule harness Kad publish activity, then
posts a normal ED2K enrich/download request and waits for the transfer manifest
to complete.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\kad.emule-harness.ed2k.download.private.v1\manifest.v1.json"),
    [ValidateSet("Debug", "Release")]
    [string]$EmuleHarnessBuildConfig = "Debug",
    [switch]$EnableObfuscation,
    [int]$EmuleHarnessPublishTimeoutSeconds = 180,
    [int]$DownloadTimeoutSeconds = 300,
    [switch]$KeepSessionsRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Wait-AgentControlReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
            if ($null -ne $response) {
                return
            }
        }
        catch {
        }
        Start-Sleep -Seconds 2
    }

    throw "Agent stats endpoint did not become ready at $StatsUrl within $TimeoutSeconds seconds"
}

function New-SeedPdfFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [int]$RepeatCount
    )

    $line = "%PDF-1.4`n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj`n2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj`n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>endobj`n4 0 obj<</Length 44>>stream`nBT /F1 12 Tf 72 120 Td (Ubuntu Linux private parity) Tj ET`nendstream`nendobj`nxref`n0 5`n0000000000 65535 f `ntrailer<</Size 5/Root 1 0 R>>`nstartxref`n0`n%%EOF`n"
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

function Get-NewEmuleHarnessTraceLines {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$EmuleHarnessSession
    )

    if (-not (Test-Path -LiteralPath $EmuleHarnessSession.TraceLogPath)) {
        return @()
    }

    return @(
        Get-Content -LiteralPath $EmuleHarnessSession.TraceLogPath |
            Select-Object -Skip ([int]$EmuleHarnessSession.TraceLinesBefore)
    )
}

function Wait-EmuleHarnessPublishReady {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$EmuleHarnessSession,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $tracePattern = 'event=(publish_|search_storefile_prepare|search_storekeyword_prepare|search_storesource_prepare)'
    $verbosePattern = 'eMule harness publish gate ready|eMule harness publish start family='
    while ((Get-Date) -lt $deadline) {
        $lines = @(Get-NewEmuleHarnessTraceLines -EmuleHarnessSession $EmuleHarnessSession)
        $publishLines = @($lines | Where-Object { $_ -match $tracePattern })
        if ($publishLines.Count -gt 0) {
            return [pscustomobject]@{
                Ready = $true
                Source = "trace"
                TraceLineCount = $lines.Count
                PublishLineCount = $publishLines.Count
            }
        }

        if (Test-Path -LiteralPath $EmuleHarnessSession.VerboseLogPath) {
            $verboseLines = @(Get-Content -LiteralPath $EmuleHarnessSession.VerboseLogPath)
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

    throw "eMule harness did not emit publish-ready trace markers within $TimeoutSeconds seconds"
}

function Wait-TransferManifestState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ManifestPath) {
            $manifest = Get-Content -Raw $ManifestPath | ConvertFrom-Json
            if ($manifest.completed) {
                return $manifest
            }
        }
        Start-Sleep -Seconds 2
    }

    if (Test-Path -LiteralPath $ManifestPath) {
        return (Get-Content -Raw $ManifestPath | ConvertFrom-Json)
    }

    throw "Transfer manifest did not appear at $ManifestPath within $TimeoutSeconds seconds"
}

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifest = Get-Content -Raw $ScenarioManifestPath | ConvertFrom-Json

if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}

$runId = "{0}-{1}" -f $manifest.scenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\{0}\{1}" -f $manifest.scenarioId, $runId)
$emuleHarnessProfileRoot = Join-Path $artifactRoot "emule-harness-profile"
$emuleHarnessSeedPath = Join-Path $emuleHarnessProfileRoot "Incoming\$($manifest.emuleHarness.seedFileName)"
$emuleHarnessLinkPath = Join-Path $emuleHarnessProfileRoot "seed.ed2k"
$agentScenarioRoot = Join-Path $artifactRoot "agent"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$emuleHarnessArtifactsRoot = Join-Path $artifactRoot "emule-harness-artifacts"
$agentArtifactsRoot = Join-Path $artifactRoot "agent-artifacts"

foreach ($path in @($artifactRoot, $emuleHarnessArtifactsRoot, $agentArtifactsRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$profileScriptPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"
$emuleHarnessStartScriptPath = Join-Path $toolingRoot "helper-emule-harness-start-private-ed2k-session.ps1"
$emuleHarnessStopScriptPath = Join-Path $toolingRoot "helper-emule-harness-stop-parity-session.ps1"
$agentStartScriptPath = Join-Path $toolingRoot "helper-agent-start-private-ed2k-session.ps1"
$agentStopScriptPath = Join-Path $toolingRoot "helper-agent-stop-parity-session.ps1"
$enrichScriptPath = Join-Path $toolingRoot "helper-agent-post-enrich-download.ps1"
$collectTransferScriptPath = Join-Path $toolingRoot "helper-agent-collect-ed2k-transfer.ps1"

foreach ($requiredPath in @(
    $profileScriptPath,
    $emuleHarnessStartScriptPath,
    $emuleHarnessStopScriptPath,
    $agentStartScriptPath,
    $agentStopScriptPath,
    $enrichScriptPath,
    $collectTransferScriptPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required scenario helper not found at $requiredPath"
    }
}

$profile = & $profileScriptPath `
    -ProfileRoot $emuleHarnessProfileRoot `
    -BindAddr $manifest.emuleHarness.bindAddr `
    -TcpPort ([UInt16]$manifest.emuleHarness.tcpPort) `
    -UdpPort ([UInt16]$manifest.emuleHarness.udpPort) `
    -ServerUdpPort ([UInt16]$manifest.emuleHarness.serverUdpPort) `
    -WebPort ([UInt16]$manifest.emuleHarness.webPort) `
    -KadUdpKey ([UInt32]$manifest.emuleHarness.kadUdpKey) `
    -ResetTransientState

New-SeedPdfFile -Path $emuleHarnessSeedPath -RepeatCount ([int]$manifest.emuleHarness.seedRepeatCount)

$runManifest = [ordered]@{
    schemaVersion = "run-manifest/v1"
    scenarioId = $manifest.scenarioId
    runId = $runId
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    artifactRoot = $artifactRoot
    emuleHarness = [ordered]@{
        profileRoot = $profile.ProfileRoot
        seedFilePath = $emuleHarnessSeedPath
    }
    agent = [ordered]@{
        scenarioRoot = $agentScenarioRoot
    }
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runManifestPath

$emuleHarnessSession = $null
$agentSession = $null
$parsedLink = $null
$publishSummary = $null
$failedReason = $null

try {
    $agentBootstrapNode = "127.0.0.1:{0}" -f [UInt16]$manifest.agent.kadPort
    $emuleHarnessSession = & $emuleHarnessStartScriptPath `
        -ProfileRoot $profile.ProfileRoot `
        -SeedFilePath $emuleHarnessSeedPath `
        -ExportLinkPath $emuleHarnessLinkPath `
        -AgentBootstrapNode $agentBootstrapNode `
        -BuildConfig $EmuleHarnessBuildConfig

    Wait-Path -Path $emuleHarnessLinkPath -TimeoutSeconds 60
    $parsedLink = Parse-Ed2kLinkFile -Path $emuleHarnessLinkPath

    $oracleBootstrapNode = "127.0.0.1:{0}" -f [UInt16]$manifest.emuleHarness.udpPort
    $agentStartParams = @{
        ScenarioRoot = $agentScenarioRoot
        EmuleHarnessBootstrapNode = $oracleBootstrapNode
        ControlPort = [UInt16]$manifest.agent.controlPort
        KadPort = [UInt16]$manifest.agent.kadPort
        Ed2kPort = [UInt16]$manifest.agent.ed2kPort
    }
    if ($EnableObfuscation) {
        $agentStartParams.EnableObfuscation = $true
    }
    $agentSession = & $agentStartScriptPath @agentStartParams
    Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl -TimeoutSeconds 180

    $publishSummary = Wait-EmuleHarnessPublishReady -EmuleHarnessSession $emuleHarnessSession -TimeoutSeconds $EmuleHarnessPublishTimeoutSeconds

    & $enrichScriptPath `
        -FileHash $parsedLink.FileHash `
        -FileName $parsedLink.FileName `
        -FileSize $parsedLink.FileSize `
        -ControlUrl $agentSession.ControlUrl | Out-Null

    $manifestPath = Join-Path $agentSession.TransferRoot ($parsedLink.FileHash.ToLowerInvariant()) "resume-manifest.json"
    $manifestState = Wait-TransferManifestState -ManifestPath $manifestPath -TimeoutSeconds $DownloadTimeoutSeconds
    $transferSummary = & $collectTransferScriptPath `
        -TransferRoot $agentSession.TransferRoot `
        -FileHash $parsedLink.FileHash `
        -DestinationRoot $agentArtifactsRoot

    $emuleHarnessTraceSlicePath = Join-Path $emuleHarnessArtifactsRoot "emule-harness-trace-new.log"
    (Get-NewEmuleHarnessTraceLines -EmuleHarnessSession $emuleHarnessSession) | Set-Content -Encoding utf8NoBOM $emuleHarnessTraceSlicePath
    foreach ($path in @(
        $emuleHarnessSession.ExportLinkPath,
        $emuleHarnessSession.TraceLogPath,
        $emuleHarnessSession.VerboseLogPath,
        $emuleHarnessSession.StatusLogPath,
        $emuleHarnessSession.EmuleHarnessUdpDumpPath,
        $emuleHarnessSession.EmuleHarnessEd2kTcpDumpPath
    )) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $emuleHarnessArtifactsRoot (Split-Path -Leaf $path)) -Force
        }
    }

    $agentLogPath = Join-Path $agentSession.LogRoot "overlord-agent-emule.log"
    $agentUdpDumpPath = Get-ChildItem -LiteralPath $agentSession.LogRoot -Filter "agent-udp-dump-*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    $agentEd2kDumpPath = Get-ChildItem -LiteralPath $agentSession.LogRoot -Filter "agent-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    foreach ($path in @($agentLogPath, $agentUdpDumpPath, $agentEd2kDumpPath)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $agentArtifactsRoot (Split-Path -Leaf $path)) -Force
        }
    }

    $runSummary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $manifest.scenarioId
        runId = $runId
        completed = [bool]$manifestState.completed
        fileHash = $parsedLink.FileHash
        fileName = $parsedLink.FileName
        fileSize = $parsedLink.FileSize
        obfuscationEnabled = [bool]$EnableObfuscation
        oraclePublishLineCount = $publishSummary.PublishLineCount
        oracleTraceLineCount = $publishSummary.TraceLineCount
        transferVerifiedRanges = @($manifestState.verified_ranges).Count
        transferManifestPath = $manifestPath
        agentControlUrl = $agentSession.ControlUrl
        emuleHarnessProfileRoot = $emuleHarnessSession.EmuleHarnessProfileRoot
        transferCollected = [bool]$transferSummary.Completed
        finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $runSummary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    $runSummary
}
catch {
    $failedReason = $_.Exception.Message
    throw
}
finally {
    if (-not $KeepSessionsRunning) {
        if ($emuleHarnessSession) {
            & $emuleHarnessStopScriptPath -SessionDir $emuleHarnessSession.SessionDir | Out-Null
        }
        if ($agentSession) {
            & $agentStopScriptPath -SessionDir $agentSession.SessionDir | Out-Null
            if ($agentSession.ConfigBackupPath -and (Test-Path -LiteralPath $agentSession.ConfigBackupPath)) {
                Copy-Item -LiteralPath $agentSession.ConfigBackupPath -Destination $agentSession.ConfigPath -Force
            }
        }
    }

    if (-not (Test-Path -LiteralPath $runSummaryPath)) {
        $failedSummary = [ordered]@{
            schemaVersion = "run-summary/v1"
            scenarioId = $manifest.scenarioId
            runId = $runId
            completed = $false
            fileHash = if ($parsedLink) { $parsedLink.FileHash } else { $null }
            fileName = if ($parsedLink) { $parsedLink.FileName } else { $null }
            fileSize = if ($parsedLink) { $parsedLink.FileSize } else { $null }
            obfuscationEnabled = [bool]$EnableObfuscation
            failedReason = $failedReason
            finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $failedSummary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    }
}

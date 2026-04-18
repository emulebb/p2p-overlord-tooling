#Requires -Version 7.6
<#
.SYNOPSIS
Runs a deterministic private Kad plus ED2K large-file download from the agent to a fresh eMule harness profile.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\kad.agent.emule-harness.download.private.large.v1\manifest.v1.json"),
    [ValidateSet("Debug")]
    [string]$EmuleHarnessBuildConfig = "Debug",
    [UInt64]$FileSizeBytes = 0,
    [string]$FileName,
    [string]$FilePattern,
    [switch]$EnableObfuscation,
    [switch]$KeepSessionsRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\subsystems\agent\AgentSubsystem.ps1")
. (Join-Path $PSScriptRoot "..\subsystems\emule-harness\EmuleHarnessSubsystem.ps1")

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

function Wait-AgentKadReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 120,
        [int]$MinimumPeerCount = 1
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastState = $null
    $lastPeerCount = 0
    $lastP2pReady = $false

    while ((Get-Date) -lt $deadline) {
        try {
            $stats = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
            if ($null -ne $stats) {
                $lastState = [string]$stats.agent_activity.state
                $lastPeerCount = if ($null -ne $stats.peers_connected) { [int]$stats.peers_connected } else { 0 }
                $lastP2pReady = [bool]$stats.interface_report.p2p.ready
                if ($lastP2pReady -and $lastState -ne "bootstrapping" -and $lastPeerCount -ge $MinimumPeerCount) {
                    return
                }
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }

    throw "Agent Kad readiness wait timed out at $StatsUrl within $TimeoutSeconds seconds (last_state=$lastState last_peers=$lastPeerCount p2p_ready=$lastP2pReady minimum_peers=$MinimumPeerCount)"
}

function Wait-AgentLogPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [int]$TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $LogPath) {
            $matched = Select-String -Path $LogPath -Pattern $Pattern -Quiet -ErrorAction SilentlyContinue
            if ($matched) {
                return
            }
        }
        Start-Sleep -Seconds 2
    }

    throw "Agent log $LogPath did not contain pattern '$Pattern' within $TimeoutSeconds seconds"
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

function New-DeterministicBinaryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [UInt64]$SizeBytes,
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $patternBytes = [System.Text.Encoding]::ASCII.GetBytes($Pattern)
    if ($patternBytes.Length -eq 0) {
        throw "Pattern must not be empty"
    }

    $buffer = New-Object byte[] 65536
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        [UInt64]$written = 0
        while ($written -lt $SizeBytes) {
            $remaining = $SizeBytes - $written
            $chunk = if ($remaining -gt [UInt64]$buffer.Length) {
                $buffer.Length
            }
            else {
                [int]$remaining
            }
            for ($index = 0; $index -lt $chunk; $index++) {
                $buffer[$index] = $patternBytes[($written + [UInt64]$index) % [UInt64]$patternBytes.Length]
            }
            $stream.Write($buffer, 0, $chunk)
            $written += [UInt64]$chunk
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Wait-FileCompleted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [UInt64]$ExpectedSize,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-Item -LiteralPath $Path
            if ([UInt64]$item.Length -eq $ExpectedSize) {
                return $item
            }
        }
        Start-Sleep -Seconds 2
    }

    throw "File $Path did not reach size $ExpectedSize within $TimeoutSeconds seconds"
}

function Copy-IfExists {
    param(
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Copy-Item -LiteralPath $Path -Destination (Join-Path $DestinationRoot (Split-Path -Leaf $Path)) -Force
    }
}

function Get-LatestAgentEd2kDumpPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogRoot
    )

    Get-ChildItem -LiteralPath $LogRoot -Filter "agent-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Convert-HexStringToByteArray {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hex
    )

    if ($Hex.Length % 2 -ne 0) {
        throw "Hex string length must be even"
    }

    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    $bytes
}

function Convert-ByteArrayToBase32 {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $builder = New-Object System.Text.StringBuilder
    [UInt32]$bitBuffer = 0
    [int]$bitCount = 0

    foreach ($byte in $Bytes) {
        $bitBuffer = ($bitBuffer -shl 8) -bor [UInt32]$byte
        $bitCount += 8
        while ($bitCount -ge 5) {
            $bitCount -= 5
            $index = ($bitBuffer -shr $bitCount) -band 0x1F
            [void]$builder.Append($alphabet[$index])
        }
    }

    if ($bitCount -gt 0) {
        $index = ($bitBuffer -shl (5 - $bitCount)) -band 0x1F
        [void]$builder.Append($alphabet[$index])
    }

    $builder.ToString()
}

function Convert-AichRootHexToBase32 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hex
    )

    Convert-ByteArrayToBase32 -Bytes (Convert-HexStringToByteArray -Hex $Hex)
}

function Get-Ed2kFileIdentifierLength {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$PayloadBytes
    )

    if ($PayloadBytes.Length -lt 17) {
        throw "Short FileIdentifier payload length $($PayloadBytes.Length)"
    }

    $descriptor = $PayloadBytes[0]
    if (($descriptor -band 0xF8) -ne 0) {
        throw ("Unsupported FileIdentifier descriptor 0x{0:X2}" -f $descriptor)
    }
    if (($descriptor -band 0x01) -eq 0) {
        throw ("FileIdentifier descriptor 0x{0:X2} missing MD4 bit" -f $descriptor)
    }

    $length = 1 + 16
    if (($descriptor -band 0x02) -ne 0) {
        $length += 8
    }
    if (($descriptor -band 0x04) -ne 0) {
        $length += 20
    }
    $length
}

function Get-Ed2kHashsetOptionsFromPayloadHex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PayloadHex
    )

    $payloadBytes = Convert-HexStringToByteArray -Hex $PayloadHex
    $identifierLength = Get-Ed2kFileIdentifierLength -PayloadBytes $payloadBytes
    if ($payloadBytes.Length -le $identifierLength) {
        throw "Short hashset payload length $($payloadBytes.Length) missing options byte"
    }

    $options = $payloadBytes[$identifierLength]
    [pscustomobject]@{
        RawOptions = $options
        RequestsMd4 = [bool](($options -band 0x01) -ne 0)
        RequestsAich = [bool](($options -band 0x02) -ne 0)
    }
}

function Get-Ed2kDumpRecordEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DumpPath,
        [Parameter(Mandatory = $true)]
        [string]$OpcodeName,
        [Parameter(Mandatory = $true)]
        [ValidateSet("send", "recv")]
        [string]$Direction
    )

    $record = Get-Content -LiteralPath $DumpPath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { $_.opcode_name -eq $OpcodeName -and $_.direction -eq $Direction } |
        Select-Object -First 1

    if ($null -eq $record) {
        throw "Did not find $Direction $OpcodeName in $DumpPath"
    }

    $options = Get-Ed2kHashsetOptionsFromPayloadHex -PayloadHex ([string]$record.payload_hex)
    [pscustomobject]@{
        EventSeq = [UInt64]$record.event_seq
        RemoteAddr = [string]$record.remote_addr
        Direction = [string]$record.direction
        OpcodeName = [string]$record.opcode_name
        RawOptions = $options.RawOptions
        RequestsMd4 = [bool]$options.RequestsMd4
        RequestsAich = [bool]$options.RequestsAich
    }
}

function Get-Ed2kDumpRecords {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DumpPath
    )

    @(
        Get-Content -LiteralPath $DumpPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
}

function Test-Ed2kDumpHasOpcode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DumpPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet("send", "recv")]
        [string]$Direction,
        [Parameter(Mandatory = $true)]
        [string[]]$OpcodeNames
    )

    $records = Get-Ed2kDumpRecords -DumpPath $DumpPath
    [bool]@(
        $records |
            Where-Object {
                $_.direction -eq $Direction -and
                $OpcodeNames -contains [string]$_.opcode_name
            }
    ).Count
}

function Get-Ed2kDumpTransportModes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DumpPath
    )

    @(
        (Get-Ed2kDumpRecords -DumpPath $DumpPath) |
            Where-Object {
                $_.direction -ne "meta" -and
                -not [string]::IsNullOrWhiteSpace([string]$_.transport_mode)
            } |
            Select-Object -ExpandProperty transport_mode -Unique
    )
}

function Wait-HarnessSearchResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SearchResultsPath,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedHash,
        [int]$TimeoutSeconds = 300
    )

    $normalizedHash = $ExpectedHash.ToLowerInvariant()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $SearchResultsPath) {
            $records = @(
                Get-Content -LiteralPath $SearchResultsPath |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object { $_ | ConvertFrom-Json }
            )
            $snapshot = @($records | Where-Object { $_.event -eq "results_snapshot" } | Select-Object -Last 1)
            if ($snapshot.Count -gt 0) {
                $match = @($snapshot[0].results | Where-Object { ([string]$_.hash).ToLowerInvariant() -eq $normalizedHash })
                if ($match.Count -gt 0) {
                    return [pscustomobject]@{
                        Snapshot = $snapshot[0]
                        Result = $match[0]
                    }
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "Harness search results at $SearchResultsPath did not include hash $ExpectedHash within $TimeoutSeconds seconds"
}

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifest = Get-Content -Raw $ScenarioManifestPath | ConvertFrom-Json
$resolvedScenarioManifestPath = (Resolve-Path $ScenarioManifestPath).Path
$effectiveFileName = if ($PSBoundParameters.ContainsKey("FileName") -and -not [string]::IsNullOrWhiteSpace($FileName)) {
    $FileName
}
else {
    [string]$manifest.file.name
}
$effectiveFileSizeBytes = if ($PSBoundParameters.ContainsKey("FileSizeBytes") -and [UInt64]$FileSizeBytes -gt 0) {
    [UInt64]$FileSizeBytes
}
else {
    [UInt64]$manifest.file.sizeBytes
}
$effectiveFilePattern = if ($PSBoundParameters.ContainsKey("FilePattern") -and -not [string]::IsNullOrWhiteSpace($FilePattern)) {
    $FilePattern
}
else {
    [string]$manifest.file.pattern
}
$effectiveEnableObfuscation = [bool]$EnableObfuscation
$expectedTransportMode = if ($effectiveEnableObfuscation) { "obfuscated" } else { "plaintext" }
$agentP2pBindIp = if ($null -ne $manifest.agent -and -not [string]::IsNullOrWhiteSpace([string]$manifest.agent.p2pBindIp)) {
    [string]$manifest.agent.p2pBindIp
}
else {
    "127.0.0.1"
}

if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}

$runId = "{0}-{1}" -f $manifest.scenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\{0}\{1}" -f $manifest.scenarioId, $runId)
$bootstrapProfileRoot = Join-Path $artifactRoot "bootstrap-harness-profile"
$downloaderProfileRoot = Join-Path $artifactRoot "downloader-harness-profile"
$agentScenarioRoot = Join-Path $artifactRoot "agent"
$sourceRoot = Join-Path $artifactRoot "source"
$sourceFilePath = Join-Path $sourceRoot $effectiveFileName
$downloadLinkPath = Join-Path $artifactRoot "download-link.ed2k"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$bootstrapArtifactsRoot = Join-Path $artifactRoot "bootstrap-harness-artifacts"
$downloaderArtifactsRoot = Join-Path $artifactRoot "downloader-harness-artifacts"
$agentArtifactsRoot = Join-Path $artifactRoot "agent-artifacts"

foreach ($path in @($artifactRoot, $sourceRoot, $bootstrapArtifactsRoot, $downloaderArtifactsRoot, $agentArtifactsRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$profileScriptPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"
if (-not (Test-Path -LiteralPath $profileScriptPath)) {
    throw "Required scenario helper not found at $profileScriptPath"
}

Build-EmuleHarnessDebug | Out-Null

$runManifest = [ordered]@{
    schemaVersion = "run-manifest/v1"
    scenarioId = $manifest.scenarioId
    scenarioManifestPath = $resolvedScenarioManifestPath
    runId = $runId
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    artifactRoot = $artifactRoot
    transportMode = $expectedTransportMode
    file = [ordered]@{
        name = $effectiveFileName
        sizeBytes = $effectiveFileSizeBytes
        pattern = $effectiveFilePattern
        sourcePath = $sourceFilePath
    }
    download = [ordered]@{
        linkPath = $downloadLinkPath
        directSourcesEmbedded = $false
    }
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runManifestPath

$bootstrapSession = $null
$stoppedBootstrapSession = $null
$downloaderSession = $null
$stoppedDownloaderSession = $null
$agentStage1Session = $null
$agentStage2Session = $null
$ingestSummary = $null
$downloadedFile = $null
$failedReason = $null

try {
    $bootstrapProfile = & $profileScriptPath `
        -ProfileRoot $bootstrapProfileRoot `
        -BindAddr $manifest.bootstrapHarness.bindAddr `
        -TcpPort ([UInt16]$manifest.bootstrapHarness.tcpPort) `
        -UdpPort ([UInt16]$manifest.bootstrapHarness.udpPort) `
        -ServerUdpPort ([UInt16]$manifest.bootstrapHarness.serverUdpPort) `
        -WebPort ([UInt16]$manifest.bootstrapHarness.webPort) `
        -KadUdpKey ([UInt32]$manifest.bootstrapHarness.kadUdpKey) `
        -EnableKademlia $true `
        -EnableEd2k $true `
        -ResetTransientState
    Set-EmuleHarnessObfuscationMode -Mode $(if ($effectiveEnableObfuscation) { "ObfuscatedPreferred" } else { "PlaintextOnly" }) -ProfileRoot $bootstrapProfile.ProfileRoot | Out-Null

    $bootstrapSession = Start-EmuleHarnessPrivateEd2kSession `
        -ProfileRoot $bootstrapProfile.ProfileRoot `
        -BuildConfig $EmuleHarnessBuildConfig

    New-DeterministicBinaryFile -Path $sourceFilePath -SizeBytes $effectiveFileSizeBytes -Pattern $effectiveFilePattern

    $bootstrapNode = "{0}:{1}" -f [string]$manifest.bootstrapHarness.bindAddr, [UInt16]$manifest.bootstrapHarness.udpPort
    $agentStage1Session = Start-AgentPrivateEd2kSession `
        -ScenarioRoot $agentScenarioRoot `
        -EmuleHarnessBootstrapNode $bootstrapNode `
        -ControlPort ([UInt16]$manifest.agent.controlPort) `
        -KadPort ([UInt16]$manifest.agent.kadPort) `
        -Ed2kPort ([UInt16]$manifest.agent.ed2kPort) `
        -P2pBindIp $agentP2pBindIp `
        -KadBootstrapReadyContacts 1 `
        -EnableObfuscation:$effectiveEnableObfuscation
    Wait-AgentControlReady -StatsUrl $agentStage1Session.StatsUrl -TimeoutSeconds 180

    $ingestSummary = Post-AgentIngestLocalFile `
        -SourcePath $sourceFilePath `
        -CanonicalName $effectiveFileName `
        -ControlUrl $agentStage1Session.ControlUrl
    if ([string]::IsNullOrWhiteSpace([string]$ingestSummary.fileHash)) {
        throw "Agent local ingest did not return a file hash"
    }
    if ([string]::IsNullOrWhiteSpace([string]$ingestSummary.aichRoot)) {
        throw "Agent local ingest did not return an AICH root"
    }

    Wait-AgentLogPattern -LogPath $agentStage1Session.AgentLogPath -Pattern 'bootstrap complete - routing table has' -TimeoutSeconds 180
    Start-Sleep -Seconds 2

    Post-AgentSeedPopular `
        -Ed2kHash ([string]$ingestSummary.fileHash) `
        -CanonicalName $effectiveFileName `
        -Size ([UInt64]$ingestSummary.fileSize) `
        -SourceCount 1 `
        -ControlUrl $agentStage1Session.ControlUrl | Out-Null

    $agentStage2Session = $agentStage1Session
    $agentStage1Session = $null

    if ([int]$manifest.timeouts.agentPublishSeconds -gt 0) {
        Start-Sleep -Seconds ([int]$manifest.timeouts.agentPublishSeconds)
    }

    $aichBase32 = Convert-AichRootHexToBase32 -Hex ([string]$ingestSummary.aichRoot)
    $downloadLink = "ed2k://|file|{0}|{1}|{2}|h={3}|/" -f `
        $effectiveFileName, `
        [UInt64]$ingestSummary.fileSize, `
        ([string]$ingestSummary.fileHash).ToUpperInvariant(), `
        $aichBase32
    [System.IO.File]::WriteAllText(
        $downloadLinkPath,
        $downloadLink + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Wait-Path -Path $downloadLinkPath -TimeoutSeconds 10

    $downloaderProfile = & $profileScriptPath `
        -ProfileRoot $downloaderProfileRoot `
        -BindAddr $manifest.downloaderHarness.bindAddr `
        -TcpPort ([UInt16]$manifest.downloaderHarness.tcpPort) `
        -UdpPort ([UInt16]$manifest.downloaderHarness.udpPort) `
        -ServerUdpPort ([UInt16]$manifest.downloaderHarness.serverUdpPort) `
        -WebPort ([UInt16]$manifest.downloaderHarness.webPort) `
        -KadUdpKey ([UInt32]$manifest.downloaderHarness.kadUdpKey) `
        -EnableKademlia $true `
        -EnableEd2k $true `
        -ResetTransientState
    Set-EmuleHarnessObfuscationMode -Mode $(if ($effectiveEnableObfuscation) { "ObfuscatedPreferred" } else { "PlaintextOnly" }) -ProfileRoot $downloaderProfile.ProfileRoot | Out-Null

    $agentBootstrapNode = "{0}:{1}" -f $agentP2pBindIp, [UInt16]$manifest.agent.kadPort
    $downloaderSession = Start-EmuleHarnessPrivateEd2kSession `
        -ProfileRoot $downloaderProfile.ProfileRoot `
        -AgentBootstrapNode $agentBootstrapNode `
        -DownloadLinkPath $downloadLinkPath `
        -BuildConfig $EmuleHarnessBuildConfig `
        -SkipRuntimeCleanup

    $downloadedFilePath = Join-Path $downloaderProfile.IncomingRoot $effectiveFileName
    $downloadedFile = Wait-FileCompleted `
        -Path $downloadedFilePath `
        -ExpectedSize ([UInt64]$ingestSummary.fileSize) `
        -TimeoutSeconds ([int]$manifest.timeouts.harnessDownloadSeconds)

    if (-not $KeepSessionsRunning) {
        $stoppedDownloaderSession = Stop-EmuleHarnessParitySession -SessionDir $downloaderSession.SessionDir
    }

    $agentEd2kDumpPath = Get-LatestAgentEd2kDumpPath -LogRoot $agentStage2Session.LogRoot
    if (-not $agentEd2kDumpPath) {
        throw "Agent ED2K TCP dump was not created under $($agentStage2Session.LogRoot)"
    }
    Copy-IfExists -Path $agentStage2Session.AgentLogPath -DestinationRoot $agentArtifactsRoot
    Copy-IfExists -Path $agentEd2kDumpPath -DestinationRoot $agentArtifactsRoot
    Collect-AgentEd2kTransfer `
        -TransferRoot $agentStage2Session.TransferRoot `
        -FileHash ([string]$ingestSummary.fileHash) `
        -DestinationRoot $agentArtifactsRoot | Out-Null

    foreach ($path in @(
        $(if ($stoppedBootstrapSession) { $stoppedBootstrapSession.TraceLogPath } else { $bootstrapSession.TraceLogPath }),
        $(if ($stoppedBootstrapSession) { $stoppedBootstrapSession.VerboseLogPath } else { $bootstrapSession.VerboseLogPath }),
        $(if ($stoppedBootstrapSession) { $stoppedBootstrapSession.StatusLogPath } else { $bootstrapSession.StatusLogPath }),
        $(if ($stoppedBootstrapSession) { $stoppedBootstrapSession.EmuleHarnessUdpDumpPath } else { $bootstrapSession.EmuleHarnessUdpDumpPath }),
        $(if ($stoppedBootstrapSession) { $stoppedBootstrapSession.EmuleHarnessEd2kTcpDumpPath } else { $bootstrapSession.EmuleHarnessEd2kTcpDumpPath })
    )) {
        Copy-IfExists -Path $path -DestinationRoot $bootstrapArtifactsRoot
    }

    $downloaderTraceLogPath = if ($stoppedDownloaderSession) { $stoppedDownloaderSession.TraceLogPath } else { $downloaderSession.TraceLogPath }
    $downloaderVerboseLogPath = if ($stoppedDownloaderSession) { $stoppedDownloaderSession.VerboseLogPath } else { $downloaderSession.VerboseLogPath }
    $downloaderStatusLogPath = if ($stoppedDownloaderSession) { $stoppedDownloaderSession.StatusLogPath } else { $downloaderSession.StatusLogPath }
    $downloaderUdpDumpPath = if ($stoppedDownloaderSession) { $stoppedDownloaderSession.EmuleHarnessUdpDumpPath } else { $downloaderSession.EmuleHarnessUdpDumpPath }
    $downloaderEd2kDumpPath = if ($stoppedDownloaderSession) { $stoppedDownloaderSession.EmuleHarnessEd2kTcpDumpPath } else { $downloaderSession.EmuleHarnessEd2kTcpDumpPath }

    foreach ($path in @(
        $downloadLinkPath,
        $downloaderTraceLogPath,
        $downloaderVerboseLogPath,
        $downloaderStatusLogPath,
        $downloaderUdpDumpPath,
        $downloaderEd2kDumpPath
    )) {
        Copy-IfExists -Path $path -DestinationRoot $downloaderArtifactsRoot
    }

    $harnessDumpPath = Get-ChildItem -LiteralPath $downloaderArtifactsRoot -Filter "emule-harness-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $harnessDumpPath) {
        throw "Downloader harness ED2K TCP dump was not copied to $downloaderArtifactsRoot"
    }

    $hashsetRequest = Get-Ed2kDumpRecordEvidence -DumpPath $harnessDumpPath -OpcodeName "OP_HASHSETREQUEST2" -Direction "send"
    $hashsetAnswer = Get-Ed2kDumpRecordEvidence -DumpPath $harnessDumpPath -OpcodeName "OP_HASHSETANSWER2" -Direction "recv"
    $compressedTransfer = Test-Ed2kDumpHasOpcode -DumpPath $harnessDumpPath -Direction "recv" -OpcodeNames @("OP_COMPRESSEDPART", "OP_COMPRESSEDPART_I64")
    if (-not $compressedTransfer) {
        throw "Harness Kad downloader did not receive compressed part packets"
    }
    $transportModes = @(Get-Ed2kDumpTransportModes -DumpPath $harnessDumpPath)
    if (-not ($transportModes -contains $expectedTransportMode)) {
        throw "Harness Kad downloader dump did not show expected transport mode '$expectedTransportMode' (observed: $($transportModes -join ', '))"
    }

    $verboseLogPath = Get-ChildItem -LiteralPath $downloaderArtifactsRoot -Filter "eMule_Verbose.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $verboseLogPath) {
        throw "Harness verbose log was not copied to $downloaderArtifactsRoot"
    }
    $verifierAichOk = Select-String -Path $verboseLogPath -Pattern 'MD4: OK - AICH: OK' -Quiet
    if (-not $verifierAichOk) {
        throw "Harness verbose log did not report 'MD4: OK - AICH: OK'"
    }

    if ($stoppedDownloaderSession) {
        $downloaderSession = $null
    }

    $runSummary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $manifest.scenarioId
        scenarioManifestPath = $resolvedScenarioManifestPath
        runId = $runId
        completed = $true
        fileHash = [string]$ingestSummary.fileHash
        fileName = $effectiveFileName
        fileSize = [UInt64]$ingestSummary.fileSize
        transportMode = $expectedTransportMode
        agentTransferManifestPath = Join-Path $agentStage2Session.TransferRoot ([string]$ingestSummary.fileHash) "resume-manifest.json"
        harnessDownloadedFilePath = $downloadedFile.FullName
        downloadLinkPath = $downloadLinkPath
        ingestSummary = $ingestSummary
        evidence = [ordered]@{
            agentIngestAichRootPresent = [bool](-not [string]::IsNullOrWhiteSpace([string]$ingestSummary.aichRoot))
            downloadLinkHasAich = [bool]($downloadLink -match '\|h=')
            downloadLinkHasDirectSources = [bool]($downloadLink -match '\|sources,')
            harnessHashsetRequestAich = [bool]$hashsetRequest.RequestsAich
            agentHashsetAnswerAich = [bool]$hashsetAnswer.RequestsAich
            harnessCompressedParts = [bool]$compressedTransfer
            harnessTransportModes = @($transportModes)
            harnessVerifierAichOk = [bool]$verifierAichOk
        }
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
        if ($downloaderSession) {
            Stop-EmuleHarnessParitySession -SessionDir $downloaderSession.SessionDir | Out-Null
        }
        if ($bootstrapSession) {
            Stop-EmuleHarnessParitySession -SessionDir $bootstrapSession.SessionDir | Out-Null
        }
        if ($agentStage2Session) {
            Stop-AgentParitySession -SessionDir $agentStage2Session.SessionDir | Out-Null
            if ($agentStage2Session.ConfigBackupPath -and (Test-Path -LiteralPath $agentStage2Session.ConfigBackupPath)) {
                Copy-Item -LiteralPath $agentStage2Session.ConfigBackupPath -Destination $agentStage2Session.ConfigPath -Force
            }
        }
        if ($agentStage1Session) {
            Stop-AgentParitySession -SessionDir $agentStage1Session.SessionDir | Out-Null
            if ($agentStage1Session.ConfigBackupPath -and (Test-Path -LiteralPath $agentStage1Session.ConfigBackupPath)) {
                Copy-Item -LiteralPath $agentStage1Session.ConfigBackupPath -Destination $agentStage1Session.ConfigPath -Force
            }
        }
    }

    if (-not (Test-Path -LiteralPath $runSummaryPath)) {
        $failedSummary = [ordered]@{
            schemaVersion = "run-summary/v1"
            scenarioId = $manifest.scenarioId
            scenarioManifestPath = $resolvedScenarioManifestPath
            runId = $runId
            completed = $false
            fileHash = if ($ingestSummary) { [string]$ingestSummary.fileHash } else { $null }
            fileName = $effectiveFileName
            fileSize = if ($ingestSummary) { [UInt64]$ingestSummary.fileSize } else { $effectiveFileSizeBytes }
            failedReason = $failedReason
            finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $failedSummary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    }
}

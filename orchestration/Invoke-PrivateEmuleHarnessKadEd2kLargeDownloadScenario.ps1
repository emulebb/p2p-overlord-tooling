#Requires -Version 7.6
<#
.SYNOPSIS
Runs a deterministic private Kad plus ED2K large-file download from the eMule harness to the agent.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\kad.emule-harness.agent.download.private.large.v1\manifest.v1.json"),
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

function Get-HarnessSeedExportTimeoutSeconds {
    param(
        [Parameter(Mandatory = $true)]
        [UInt64]$FileSizeBytes,
        [Parameter(Mandatory = $true)]
        [int]$BaseTimeoutSeconds
    )

    $oneGiB = 1GB
    $extraSecondsPerGiB = 300
    $sizeGiB = [math]::Ceiling(([double]$FileSizeBytes) / [double]$oneGiB)
    $scaledTimeout = $BaseTimeoutSeconds + ([int]$sizeGiB * $extraSecondsPerGiB)
    return [Math]::Max($BaseTimeoutSeconds, $scaledTimeout)
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
    $fileName = [string]$matches.Name
    $fileSize = [UInt64]$matches.Size
    $fileHash = ([string]$matches.Hash).ToLowerInvariant()

    $aichRoot = $null
    if ($link -match '\|h=(?<Aich>[A-Za-z2-7]+)\|') {
        $aichRoot = $matches.Aich
    }

    [pscustomobject]@{
        Link = $link
        FileName = $fileName
        FileSize = $fileSize
        FileHash = $fileHash
        AichRoot = $aichRoot
    }
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

function Get-LatestAgentUdpDumpPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogRoot
    )

    Get-ChildItem -LiteralPath $LogRoot -Filter "agent-udp-dump-*.jsonl" -ErrorAction SilentlyContinue |
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
$seedExportTimeoutSeconds = Get-HarnessSeedExportTimeoutSeconds `
    -FileSizeBytes $effectiveFileSizeBytes `
    -BaseTimeoutSeconds 60
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
$emuleHarnessProfileRoot = Join-Path $artifactRoot "emule-harness-profile"
$emuleHarnessSeedPath = Join-Path $emuleHarnessProfileRoot "Incoming\$effectiveFileName"
$emuleHarnessLinkPath = Join-Path $emuleHarnessProfileRoot "seed.ed2k"
$emuleHarnessAichPath = Join-Path $emuleHarnessProfileRoot "seed.aich.json"
$agentScenarioRoot = Join-Path $artifactRoot "agent"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$emuleHarnessArtifactsRoot = Join-Path $artifactRoot "emule-harness-artifacts"
$agentArtifactsRoot = Join-Path $artifactRoot "agent-artifacts"

foreach ($path in @($artifactRoot, $emuleHarnessArtifactsRoot, $agentArtifactsRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$profileScriptPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"
if (-not (Test-Path -LiteralPath $profileScriptPath)) {
    throw "Required scenario helper not found at $profileScriptPath"
}

Build-EmuleHarnessDebug | Out-Null

$profile = & $profileScriptPath `
    -ProfileRoot $emuleHarnessProfileRoot `
    -BindAddr $manifest.emuleHarness.bindAddr `
    -TcpPort ([UInt16]$manifest.emuleHarness.tcpPort) `
    -UdpPort ([UInt16]$manifest.emuleHarness.udpPort) `
    -ServerUdpPort ([UInt16]$manifest.emuleHarness.serverUdpPort) `
    -WebPort ([UInt16]$manifest.emuleHarness.webPort) `
    -KadUdpKey ([UInt32]$manifest.emuleHarness.kadUdpKey) `
    -ResetTransientState

Set-EmuleHarnessObfuscationMode -Mode $(if ($effectiveEnableObfuscation) { "ObfuscatedPreferred" } else { "PlaintextOnly" }) -ProfileRoot $profile.ProfileRoot | Out-Null
New-DeterministicBinaryFile -Path $emuleHarnessSeedPath -SizeBytes $effectiveFileSizeBytes -Pattern $effectiveFilePattern

$runManifest = [ordered]@{
    schemaVersion = "run-manifest/v1"
    scenarioId = $manifest.scenarioId
    scenarioManifestPath = $resolvedScenarioManifestPath
    runId = $runId
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    artifactRoot = $artifactRoot
    emuleHarness = [ordered]@{
        profileRoot = $profile.ProfileRoot
        seedFilePath = $emuleHarnessSeedPath
        exportLinkPath = $emuleHarnessLinkPath
        exportAichPath = $emuleHarnessAichPath
    }
    agent = [ordered]@{
        scenarioRoot = $agentScenarioRoot
    }
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runManifestPath

$emuleHarnessSession = $null
$agentSession = $null
$parsedLink = $null
$aichSidecar = $null
$publishSummary = $null
$failedReason = $null

try {
    $agentBootstrapNode = "{0}:{1}" -f $agentP2pBindIp, [UInt16]$manifest.agent.kadPort
    $emuleHarnessSession = Start-EmuleHarnessPrivateEd2kSession `
        -ProfileRoot $profile.ProfileRoot `
        -SeedFilePath $emuleHarnessSeedPath `
        -ExportLinkPath $emuleHarnessLinkPath `
        -ExportAichPath $emuleHarnessAichPath `
        -AgentBootstrapNode $agentBootstrapNode `
        -BuildConfig $EmuleHarnessBuildConfig

    Wait-Path -Path $emuleHarnessLinkPath -TimeoutSeconds $seedExportTimeoutSeconds
    Wait-Path -Path $emuleHarnessAichPath -TimeoutSeconds $seedExportTimeoutSeconds
    $parsedLink = Parse-Ed2kLinkFile -Path $emuleHarnessLinkPath
    $aichSidecar = Get-Content -LiteralPath $emuleHarnessAichPath -Raw | ConvertFrom-Json

    $oracleBootstrapNode = "{0}:{1}" -f [string]$manifest.emuleHarness.bindAddr, [UInt16]$manifest.emuleHarness.udpPort
    $agentSession = Start-AgentPrivateEd2kSession `
        -ScenarioRoot $agentScenarioRoot `
        -EmuleHarnessBootstrapNode $oracleBootstrapNode `
        -ControlPort ([UInt16]$manifest.agent.controlPort) `
        -KadPort ([UInt16]$manifest.agent.kadPort) `
        -Ed2kPort ([UInt16]$manifest.agent.ed2kPort) `
        -P2pBindIp $agentP2pBindIp `
        -KadBootstrapReadyContacts 1 `
        -EnableObfuscation:$effectiveEnableObfuscation
    Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl -TimeoutSeconds 180

    try {
        $publishSummary = Wait-EmuleHarnessPublishReady -EmuleHarnessSession $emuleHarnessSession -TimeoutSeconds ([int]$manifest.timeouts.publishSeconds)
    }
    catch {
        $publishSummary = [pscustomobject]@{
            Ready = $false
            Source = "timeout"
            TraceLineCount = 0
            PublishLineCount = 0
        }
    }

    Post-AgentEnrichDownload `
        -FileHash $parsedLink.FileHash `
        -FileName $parsedLink.FileName `
        -FileSize $parsedLink.FileSize `
        -ControlUrl $agentSession.ControlUrl | Out-Null

    $manifestPath = Join-Path $agentSession.TransferRoot ($parsedLink.FileHash.ToLowerInvariant()) "resume-manifest.json"
    $manifestState = Wait-TransferManifestState -ManifestPath $manifestPath -TimeoutSeconds ([int]$manifest.timeouts.downloadSeconds)
    Collect-AgentEd2kTransfer `
        -TransferRoot $agentSession.TransferRoot `
        -FileHash $parsedLink.FileHash `
        -DestinationRoot $agentArtifactsRoot | Out-Null

    $emuleHarnessTraceSlicePath = Join-Path $emuleHarnessArtifactsRoot "emule-harness-trace-new.log"
    (Get-NewEmuleHarnessTraceLines -EmuleHarnessSession $emuleHarnessSession) | Set-Content -Encoding utf8NoBOM $emuleHarnessTraceSlicePath
    foreach ($path in @(
        $emuleHarnessSession.ExportLinkPath,
        $emuleHarnessSession.ExportAichPath,
        $emuleHarnessSession.TraceLogPath,
        $emuleHarnessSession.VerboseLogPath,
        $emuleHarnessSession.StatusLogPath,
        $emuleHarnessSession.EmuleHarnessUdpDumpPath,
        $emuleHarnessSession.EmuleHarnessEd2kTcpDumpPath
    )) {
        Copy-IfExists -Path $path -DestinationRoot $emuleHarnessArtifactsRoot
    }

    $agentEd2kDumpPath = Get-LatestAgentEd2kDumpPath -LogRoot $agentSession.LogRoot
    $agentUdpDumpPath = Get-LatestAgentUdpDumpPath -LogRoot $agentSession.LogRoot
    Copy-IfExists -Path $agentSession.AgentLogPath -DestinationRoot $agentArtifactsRoot
    Copy-IfExists -Path $agentEd2kDumpPath -DestinationRoot $agentArtifactsRoot
    Copy-IfExists -Path $agentUdpDumpPath -DestinationRoot $agentArtifactsRoot

    $harnessDumpPath = Get-ChildItem -LiteralPath $emuleHarnessArtifactsRoot -Filter "emule-harness-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $harnessDumpPath) {
        throw "Harness ED2K TCP dump was not copied to $emuleHarnessArtifactsRoot"
    }
    $hashsetRequest = Get-Ed2kDumpRecordEvidence -DumpPath $harnessDumpPath -OpcodeName "OP_HASHSETREQUEST2" -Direction "recv"
    $hashsetAnswer = Get-Ed2kDumpRecordEvidence -DumpPath $harnessDumpPath -OpcodeName "OP_HASHSETANSWER2" -Direction "send"
    $compressedTransfer = Test-Ed2kDumpHasOpcode -DumpPath $harnessDumpPath -Direction "send" -OpcodeNames @("OP_COMPRESSEDPART", "OP_COMPRESSEDPART_I64")
    if (-not $compressedTransfer) {
        throw "Harness Kad seeder did not emit compressed part packets"
    }
    $transportModes = @(Get-Ed2kDumpTransportModes -DumpPath $harnessDumpPath)
    if (-not ($transportModes -contains $expectedTransportMode)) {
        throw "Harness Kad dump did not show expected transport mode '$expectedTransportMode' (observed: $($transportModes -join ', '))"
    }

    $runSummary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $manifest.scenarioId
        scenarioManifestPath = $resolvedScenarioManifestPath
        runId = $runId
        completed = [bool]$manifestState.completed
        fileHash = $parsedLink.FileHash
        fileName = $parsedLink.FileName
        fileSize = $parsedLink.FileSize
        transportMode = $expectedTransportMode
        oraclePublishLineCount = $publishSummary.PublishLineCount
        oraclePublishGateReady = [bool]$publishSummary.Ready
        oraclePublishGateSource = [string]$publishSummary.Source
        oracleTraceLineCount = $publishSummary.TraceLineCount
        transferManifestPath = $manifestPath
        exportAichPath = $emuleHarnessAichPath
        exportAich = $aichSidecar
        evidence = [ordered]@{
            exportedLinkHasAich = [bool](-not [string]::IsNullOrWhiteSpace([string]$parsedLink.AichRoot))
            exportAichSidecarPresent = [bool](Test-Path -LiteralPath $emuleHarnessAichPath)
            exportAichHashsetCount = (@($aichSidecar.aichHashset) | Measure-Object).Count
            agentManifestAichAcquired = [bool]$manifestState.aich_hashset_acquired
            harnessHashsetRequestAich = [bool]$hashsetRequest.RequestsAich
            harnessHashsetAnswerAich = [bool]$hashsetAnswer.RequestsAich
            harnessCompressedParts = [bool]$compressedTransfer
            harnessTransportModes = @($transportModes)
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
        if ($emuleHarnessSession) {
            Stop-EmuleHarnessParitySession -SessionDir $emuleHarnessSession.SessionDir | Out-Null
        }
        if ($agentSession) {
            Stop-AgentParitySession -SessionDir $agentSession.SessionDir | Out-Null
            if ($agentSession.ConfigBackupPath -and (Test-Path -LiteralPath $agentSession.ConfigBackupPath)) {
                Copy-Item -LiteralPath $agentSession.ConfigBackupPath -Destination $agentSession.ConfigPath -Force
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
            fileHash = if ($parsedLink) { $parsedLink.FileHash } else { $null }
            fileName = if ($parsedLink) { $parsedLink.FileName } else { $null }
            fileSize = if ($parsedLink) { $parsedLink.FileSize } else { $null }
            failedReason = $failedReason
            finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $failedSummary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    }
}

#Requires -Version 7.6
<#
.SYNOPSIS
Runs a deterministic private large-file ED2K server download from an agent-ingested payload to a fresh eMule harness profile.

.DESCRIPTION
Starts a local goed2k-server and a local-only agent session, ingests one
deterministic large file into the agent's ED2K transfer store, restarts the
agent so the completed file is re-offered through the local server session, and
then verifies that a fresh eMule harness profile downloads the file with modern
`OP_HASHSETREQUEST2` / `OP_HASHSETANSWER2` plus `AICH: OK` evidence on loopback.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\ed2k.server.agent.emule-harness.private.large.v1\manifest.v1.json"),
    [ValidateSet("Debug")]
    [string]$EmuleHarnessBuildConfig = "Debug",
    [switch]$KeepSessionsRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\subsystems\agent\AgentSubsystem.ps1")
. (Join-Path $PSScriptRoot "..\subsystems\emule-harness\EmuleHarnessSubsystem.ps1")
. (Join-Path $PSScriptRoot "..\subsystems\goed2k\Goed2kSubsystem.ps1")

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
            $chunk = [Math]::Min($buffer.Length, [int]($SizeBytes - $written))
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

function Invoke-GoEd2kAdminGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$AdminToken,
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($AdminToken)) {
        $headers["X-Admin-Token"] = $AdminToken
    }
    Invoke-RestMethod -Uri ("{0}{1}" -f $BaseUrl.TrimEnd("/"), $RelativePath) -Headers $headers -TimeoutSec 10
}

function Wait-GoEd2kFileAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$AdminToken,
        [Parameter(Mandatory = $true)]
        [string]$FileHash,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-GoEd2kAdminGet -BaseUrl $BaseUrl -AdminToken $AdminToken -RelativePath ("/api/files/{0}" -f $FileHash.ToUpperInvariant())
            if ($response.ok -and $null -ne $response.data) {
                return $response.data
            }
        }
        catch {
        }
        Start-Sleep -Seconds 2
    }

    throw "goed2k-server did not expose file $FileHash within $TimeoutSeconds seconds"
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
    $bitBuffer = 0
    $bitCount = 0
    foreach ($byte in $Bytes) {
        $bitBuffer = ($bitBuffer -shl 8) -bor $byte
        $bitCount += 8
        while ($bitCount -ge 5) {
            $index = ($bitBuffer -shr ($bitCount - 5)) -band 0x1F
            [void]$builder.Append($alphabet[$index])
            $bitCount -= 5
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

function Add-Ed2kLinkSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Link,
        [Parameter(Mandatory = $true)]
        [string]$SourceIp,
        [Parameter(Mandatory = $true)]
        [UInt16]$SourceTcpPort
    )

    $trimmedLink = $Link.Trim()
    $trimmedLink = $trimmedLink -replace '\|sources,[^|]*\|/$', ''
    if ($trimmedLink -notmatch '\|/$') {
        throw "ED2K link did not end with '|/' as expected: $trimmedLink"
    }

    return ($trimmedLink -replace '\|/$', ('|sources,{0}:{1}|/' -f $SourceIp, $SourceTcpPort))
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

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifest = Get-Content -Raw $ScenarioManifestPath | ConvertFrom-Json
$resolvedScenarioManifestPath = (Resolve-Path $ScenarioManifestPath).Path

if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}

$runId = "{0}-{1}" -f $manifest.scenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\{0}\{1}" -f $manifest.scenarioId, $runId)
$sourceRoot = Join-Path $artifactRoot "source"
$sourceFilePath = Join-Path $sourceRoot $manifest.file.name
$serverScenarioRoot = Join-Path $artifactRoot "goed2k-server"
$agentScenarioRoot = Join-Path $artifactRoot "agent"
$harnessProfileRoot = Join-Path $artifactRoot "emule-harness-profile"
$downloadLinkPath = Join-Path $harnessProfileRoot "download.ed2k"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$agentArtifactsRoot = Join-Path $artifactRoot "agent-artifacts"
$harnessArtifactsRoot = Join-Path $artifactRoot "emule-harness-artifacts"
$serverArtifactsRoot = Join-Path $artifactRoot "server-artifacts"

foreach ($path in @($artifactRoot, $sourceRoot, $agentArtifactsRoot, $harnessArtifactsRoot, $serverArtifactsRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$profileScriptPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"
if (-not (Test-Path -LiteralPath $profileScriptPath)) {
    throw "Required scenario helper not found at $profileScriptPath"
}

$runManifest = [ordered]@{
    schemaVersion = "run-manifest/v1"
    scenarioId = $manifest.scenarioId
    scenarioManifestPath = $resolvedScenarioManifestPath
    runId = $runId
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    artifactRoot = $artifactRoot
    source = [ordered]@{
        filePath = $sourceFilePath
    }
    server = [ordered]@{
        scenarioRoot = $serverScenarioRoot
        tcpPort = [UInt16]$manifest.server.tcpPort
        adminPort = [UInt16]$manifest.server.adminPort
    }
    agent = [ordered]@{
        scenarioRoot = $agentScenarioRoot
    }
    emuleHarness = [ordered]@{
        profileRoot = $harnessProfileRoot
        downloadLinkPath = $downloadLinkPath
    }
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runManifestPath

$serverSession = $null
$agentStage1Session = $null
$agentStage2Session = $null
$harnessSession = $null
$stoppedHarnessSession = $null
$ingestSummary = $null
$publishedFile = $null
$downloadedFile = $null
$failedReason = $null

Build-EmuleHarnessDebug | Out-Null
New-DeterministicBinaryFile -Path $sourceFilePath -SizeBytes ([UInt64]$manifest.file.sizeBytes) -Pattern ([string]$manifest.file.pattern)

try {
    $serverStartParams = @{
        ScenarioRoot = $serverScenarioRoot
        ListenHost = $manifest.server.host
        TcpPort = [UInt16]$manifest.server.tcpPort
        AdminPort = [UInt16]$manifest.server.adminPort
        UDPPortOffset = [int]$manifest.server.udpPortOffset
        AdminToken = [string]$manifest.server.adminToken
        LaunchTimeoutSeconds = 120
    }
    if ($manifest.server.enableObfuscation) {
        $serverStartParams.EnableObfuscation = $true
    }
    $serverSession = Start-Goed2kPrivateSession @serverStartParams

    Remove-Item -LiteralPath (Join-Path $agentScenarioRoot "agent-state") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $agentScenarioRoot "agent-logs") -Recurse -Force -ErrorAction SilentlyContinue

    $agentStage1Session = Start-AgentPrivateEd2kSession `
        -ScenarioRoot $agentScenarioRoot `
        -ControlPort ([UInt16]$manifest.agent.controlPort) `
        -KadPort ([UInt16]$manifest.agent.kadPort) `
        -Ed2kPort ([UInt16]$manifest.agent.ed2kPort) `
        -DisableKad `
        -ServerHost $manifest.server.host `
        -ServerPort ([UInt16]$manifest.server.tcpPort) `
        -ServerConnectTimeoutSeconds 8 `
        -ServerReconnectIntervalSeconds 5 `
        -ServerSessionRotationSeconds 0
    Wait-AgentControlReady -StatsUrl $agentStage1Session.StatsUrl -TimeoutSeconds 180

    $ingestSummary = Post-AgentIngestLocalFile `
        -SourcePath $sourceFilePath `
        -CanonicalName ([string]$manifest.file.name) `
        -ControlUrl $agentStage1Session.ControlUrl
    if ([string]::IsNullOrWhiteSpace([string]$ingestSummary.fileHash)) {
        throw "Agent local ingest did not return a file hash"
    }
    if ([string]::IsNullOrWhiteSpace([string]$ingestSummary.aichRoot)) {
        throw "Agent local ingest did not return an AICH root"
    }

    Stop-AgentParitySession -SessionDir $agentStage1Session.SessionDir | Out-Null
    $agentStage1Session = $null

    $agentStage2Session = Start-AgentPrivateEd2kSession `
        -ScenarioRoot $agentScenarioRoot `
        -ControlPort ([UInt16]$manifest.agent.controlPort) `
        -KadPort ([UInt16]$manifest.agent.kadPort) `
        -Ed2kPort ([UInt16]$manifest.agent.ed2kPort) `
        -DisableKad `
        -ServerHost $manifest.server.host `
        -ServerPort ([UInt16]$manifest.server.tcpPort) `
        -ServerConnectTimeoutSeconds 8 `
        -ServerReconnectIntervalSeconds 5 `
        -ServerSessionRotationSeconds 0
    Wait-AgentControlReady -StatsUrl $agentStage2Session.StatsUrl -TimeoutSeconds 180

    if ([int]$manifest.timeouts.agentRepublishDelaySeconds -gt 0) {
        Start-Sleep -Seconds ([int]$manifest.timeouts.agentRepublishDelaySeconds)
    }

    $publishedFile = Wait-GoEd2kFileAvailable `
        -BaseUrl $serverSession.AdminBaseUrl `
        -AdminToken $serverSession.AdminToken `
        -FileHash ([string]$ingestSummary.fileHash) `
        -TimeoutSeconds ([int]$manifest.timeouts.serverPublishSeconds)

    $profile = & $profileScriptPath `
        -ProfileRoot $harnessProfileRoot `
        -BindAddr $manifest.server.host `
        -TcpPort ([UInt16]$manifest.harnessDownloader.tcpPort) `
        -UdpPort ([UInt16]$manifest.harnessDownloader.udpPort) `
        -ServerUdpPort ([UInt16]$manifest.harnessDownloader.serverUdpPort) `
        -WebPort ([UInt16]$manifest.harnessDownloader.webPort) `
        -KadUdpKey ([UInt32]$manifest.harnessDownloader.kadUdpKey) `
        -EnableKademlia $false `
        -EnableEd2k $true `
        -ResetTransientState

    Write-EmuleHarnessTargetServerMet `
        -ServerIp $manifest.server.host `
        -ServerPort ([int]$manifest.server.tcpPort) `
        -DestinationPath (Join-Path $profile.ProfileRoot "config\server.met") | Out-Null

    $aichBase32 = Convert-AichRootHexToBase32 -Hex ([string]$ingestSummary.aichRoot)
    $baseLink = "ed2k://|file|{0}|{1}|{2}|h={3}|/" -f `
        [string]$manifest.file.name, `
        [UInt64]$ingestSummary.fileSize, `
        ([string]$ingestSummary.fileHash).ToUpperInvariant(), `
        $aichBase32
    $downloadLink = Add-Ed2kLinkSource `
        -Link $baseLink `
        -SourceIp $manifest.server.host `
        -SourceTcpPort ([UInt16]$manifest.agent.ed2kPort)
    [System.IO.File]::WriteAllText(
        $downloadLinkPath,
        $downloadLink + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Wait-Path -Path $downloadLinkPath -TimeoutSeconds 10

    $harnessSession = Start-EmuleHarnessPrivateEd2kSession `
        -ProfileRoot $profile.ProfileRoot `
        -DownloadLinkPath $downloadLinkPath `
        -BuildConfig $EmuleHarnessBuildConfig

    $downloadedFilePath = Join-Path $profile.IncomingRoot $manifest.file.name
    $downloadedFile = Wait-FileCompleted `
        -Path $downloadedFilePath `
        -ExpectedSize ([UInt64]$manifest.file.sizeBytes) `
        -TimeoutSeconds ([int]$manifest.timeouts.harnessDownloadSeconds)

    if (-not $KeepSessionsRunning) {
        $stoppedHarnessSession = Stop-EmuleHarnessParitySession -SessionDir $harnessSession.SessionDir
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

    $harnessTraceLogPath = if ($stoppedHarnessSession) { $stoppedHarnessSession.TraceLogPath } else { $harnessSession.TraceLogPath }
    $harnessVerboseLogPath = if ($stoppedHarnessSession) { $stoppedHarnessSession.VerboseLogPath } else { $harnessSession.VerboseLogPath }
    $harnessStatusLogPath = if ($stoppedHarnessSession) { $stoppedHarnessSession.StatusLogPath } else { $harnessSession.StatusLogPath }
    $harnessUdpDumpPath = if ($stoppedHarnessSession) { $stoppedHarnessSession.EmuleHarnessUdpDumpPath } else { $harnessSession.EmuleHarnessUdpDumpPath }
    $harnessEd2kDumpPath = if ($stoppedHarnessSession) { $stoppedHarnessSession.EmuleHarnessEd2kTcpDumpPath } else { $harnessSession.EmuleHarnessEd2kTcpDumpPath }

    Copy-IfExists -Path $downloadLinkPath -DestinationRoot $harnessArtifactsRoot
    Copy-IfExists -Path $harnessTraceLogPath -DestinationRoot $harnessArtifactsRoot
    Copy-IfExists -Path $harnessVerboseLogPath -DestinationRoot $harnessArtifactsRoot
    Copy-IfExists -Path $harnessStatusLogPath -DestinationRoot $harnessArtifactsRoot
    Copy-IfExists -Path $harnessUdpDumpPath -DestinationRoot $harnessArtifactsRoot
    Copy-IfExists -Path $harnessEd2kDumpPath -DestinationRoot $harnessArtifactsRoot
    Copy-IfExists -Path $downloadedFile.FullName -DestinationRoot $harnessArtifactsRoot

    foreach ($path in @(
        $serverSession.StdoutPath,
        $serverSession.StderrPath,
        $serverSession.ConfigPath,
        $serverSession.CatalogPath
    )) {
        Copy-IfExists -Path $path -DestinationRoot $serverArtifactsRoot
    }

    $harnessDumpPath = Get-ChildItem -LiteralPath $harnessArtifactsRoot -Filter "emule-harness-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $harnessDumpPath) {
        throw "Harness ED2K TCP dump was not copied to $harnessArtifactsRoot"
    }
    $hashsetRequest = Get-Ed2kDumpRecordEvidence -DumpPath $harnessDumpPath -OpcodeName "OP_HASHSETREQUEST2" -Direction "send"
    $hashsetAnswer = Get-Ed2kDumpRecordEvidence -DumpPath $harnessDumpPath -OpcodeName "OP_HASHSETANSWER2" -Direction "recv"
    $verboseLogPath = Get-ChildItem -LiteralPath $harnessArtifactsRoot -Filter "eMule_Verbose.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $verboseLogPath) {
        throw "Harness verbose log was not copied to $harnessArtifactsRoot"
    }
    $verifierAichOk = Select-String -Path $verboseLogPath -Pattern 'MD4: OK - AICH: OK' -Quiet
    if (-not $verifierAichOk) {
        throw "Harness verbose log did not report 'MD4: OK - AICH: OK'"
    }

    $runSummary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $manifest.scenarioId
        scenarioManifestPath = $resolvedScenarioManifestPath
        runId = $runId
        completed = $true
        fileHash = [string]$ingestSummary.fileHash
        fileName = [string]$manifest.file.name
        fileSize = [UInt64]$ingestSummary.fileSize
        agentTransferManifestPath = Join-Path $agentStage2Session.TransferRoot ([string]$ingestSummary.fileHash) "resume-manifest.json"
        harnessDownloadedFilePath = $downloadedFile.FullName
        serverAdminBaseUrl = $serverSession.AdminBaseUrl
        serverPublishedName = $publishedFile.name
        serverPublishedSources = $publishedFile.sources
        ingestSummary = $ingestSummary
        evidence = [ordered]@{
            agentIngestAichRootPresent = [bool](-not [string]::IsNullOrWhiteSpace([string]$ingestSummary.aichRoot))
            serverPublished = [bool]($null -ne $publishedFile)
            harnessHashsetRequestAich = [bool]$hashsetRequest.RequestsAich
            agentHashsetAnswerAich = [bool]$hashsetAnswer.RequestsAich
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
        if ($harnessSession) {
            Stop-EmuleHarnessParitySession -SessionDir $harnessSession.SessionDir | Out-Null
        }
        if ($agentStage2Session) {
            Stop-AgentParitySession -SessionDir $agentStage2Session.SessionDir | Out-Null
        }
        if ($agentStage1Session) {
            Stop-AgentParitySession -SessionDir $agentStage1Session.SessionDir | Out-Null
        }
        if ($serverSession) {
            Stop-Goed2kPrivateSession -SessionDir $serverSession.SessionDir | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $runSummaryPath)) {
        $failedSummary = [ordered]@{
            schemaVersion = "run-summary/v1"
            scenarioId = $manifest.scenarioId
            scenarioManifestPath = $resolvedScenarioManifestPath
            runId = $runId
            completed = $false
            fileHash = if ($ingestSummary) { $ingestSummary.fileHash } else { $null }
            fileName = [string]$manifest.file.name
            fileSize = [UInt64]$manifest.file.sizeBytes
            failedReason = $failedReason
            finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $failedSummary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    }
}

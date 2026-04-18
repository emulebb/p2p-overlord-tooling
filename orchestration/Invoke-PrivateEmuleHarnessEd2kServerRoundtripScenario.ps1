#Requires -Version 7.6
<#
.SYNOPSIS
Runs a deterministic private ED2K server roundtrip between the eMule harness and the agent with a large file.

.DESCRIPTION
Seeds one deterministic large binary from the eMule harness through a local
goed2k-server, downloads it to the agent, restarts the agent so the completed
file is re-offered, and then verifies that a fresh eMule harness profile
downloads the same file back with modern AICH evidence on the loopback path.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\ed2k.server.emule-harness.agent.roundtrip.private.large.v1\manifest.v1.json"),
    [ValidateSet("Debug")]
    [string]$EmuleHarnessBuildConfig = "Debug",
    [int]$ServerPublishTimeoutSeconds = 180,
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

    $tileSize = [Math]::Max($patternBytes.Length, [Math]::Min(1MB, [int][Math]::Min([UInt64]$SizeBytes, [UInt64]1MB)))
    $buffer = New-Object byte[] $tileSize
    for ($offset = 0; $offset -lt $buffer.Length;) {
        $copyLength = [Math]::Min($patternBytes.Length, $buffer.Length - $offset)
        [Array]::Copy($patternBytes, 0, $buffer, $offset, $copyLength)
        $offset += $copyLength
    }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        [UInt64]$remaining = $SizeBytes
        while ($remaining -gt 0) {
            $chunk = if ($remaining -gt [UInt64]$buffer.Length) {
                $buffer.Length
            }
            else {
                [int]$remaining
            }
            $stream.Write($buffer, 0, $chunk)
            $remaining -= [UInt64]$chunk
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

    $fileName = $matches.Name
    $fileSize = [UInt64]$matches.Size
    $fileHash = $matches.Hash.ToLowerInvariant()
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

function Copy-IfSmall {
    param(
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,
        [UInt64]$MaxSizeBytes = 67108864
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        return
    }
    if ([UInt64]$item.Length -gt $MaxSizeBytes) {
        return
    }

    Copy-Item -LiteralPath $Path -Destination (Join-Path $DestinationRoot $item.Name) -Force
}

function Get-HarnessArtifactPath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Session,
        [object]$StoppedSession,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($StoppedSession -and $StoppedSession.PSObject.Properties.Name -contains $PropertyName) {
        $stoppedValue = $StoppedSession.$PropertyName
        if (-not [string]::IsNullOrWhiteSpace([string]$stoppedValue)) {
            return [string]$stoppedValue
        }
    }

    if ($Session -and $Session.PSObject.Properties.Name -contains $PropertyName) {
        $sessionValue = $Session.$PropertyName
        if (-not [string]::IsNullOrWhiteSpace([string]$sessionValue)) {
            return [string]$sessionValue
        }
    }

    return $null
}

function Remove-DirectoryIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
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
        [string]$DumpPath,
        [ValidateSet("send", "recv")]
        [string]$Direction
    )

    $records = Get-Ed2kDumpRecords -DumpPath $DumpPath
    @(
        $records |
            Where-Object {
                ($Direction -eq $null -or $_.direction -eq $Direction) -and
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
$effectiveEnableObfuscation = [bool]($EnableObfuscation -or [bool]$manifest.server.enableObfuscation)
$expectedTransportMode = if ($effectiveEnableObfuscation) { "obfuscated" } else { "plaintext" }
$seedExportTimeoutSeconds = Get-HarnessSeedExportTimeoutSeconds `
    -FileSizeBytes $effectiveFileSizeBytes `
    -BaseTimeoutSeconds ([int]$manifest.timeouts.harnessReadySeconds)

if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}

$runId = "{0}-{1}" -f $manifest.scenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\{0}\{1}" -f $manifest.scenarioId, $runId)
$seederProfileRoot = Join-Path $artifactRoot "seed"
$downloaderProfileRoot = Join-Path $artifactRoot "down"
$seedLinkPath = Join-Path $artifactRoot "seed.ed2k"
$downloadLinkPath = Join-Path $artifactRoot "download.ed2k"
$agentScenarioRoot = Join-Path $artifactRoot "agt"
$serverScenarioRoot = Join-Path $artifactRoot "srv"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$seederArtifactsRoot = Join-Path $artifactRoot "seed-art"
$downloaderArtifactsRoot = Join-Path $artifactRoot "down-art"
$agentStage1ArtifactsRoot = Join-Path $artifactRoot "agt1-art"
$agentStage2ArtifactsRoot = Join-Path $artifactRoot "agt2-art"
$serverArtifactsRoot = Join-Path $artifactRoot "srv-art"

foreach ($path in @(
    $artifactRoot,
    $seederArtifactsRoot,
    $downloaderArtifactsRoot,
    $agentStage1ArtifactsRoot,
    $agentStage2ArtifactsRoot,
    $serverArtifactsRoot
)) {
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
    bindAddr = $manifest.server.host
    server = [ordered]@{
        scenarioRoot = $serverScenarioRoot
        host = $manifest.server.host
        tcpPort = [UInt16]$manifest.server.tcpPort
        adminPort = [UInt16]$manifest.server.adminPort
    }
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runManifestPath

$serverSession = $null
$agentStage1Session = $null
$agentStage2Session = $null
$seederSession = $null
$stoppedSeederSession = $null
$downloaderSession = $null
$stoppedDownloaderSession = $null
$parsedLink = $null
$publishedFile = $null
$agentTransferManifest = $null
$agentTransferSummary = $null
$downloadedFile = $null
$failedReason = $null
$agentDirectDownloadLink = $null
$harnessDirectDownloadLink = $null

Build-EmuleHarnessDebug | Out-Null

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
    if ($effectiveEnableObfuscation) {
        $serverStartParams.EnableObfuscation = $true
    }
    $serverSession = Start-Goed2kPrivateSession @serverStartParams

    $seederProfile = & $profileScriptPath `
        -ProfileRoot $seederProfileRoot `
        -BindAddr $manifest.server.host `
        -TcpPort ([UInt16]$manifest.harnessSeeder.tcpPort) `
        -UdpPort ([UInt16]$manifest.harnessSeeder.udpPort) `
        -ServerUdpPort ([UInt16]$manifest.harnessSeeder.serverUdpPort) `
        -WebPort ([UInt16]$manifest.harnessSeeder.webPort) `
        -KadUdpKey ([UInt32]$manifest.harnessSeeder.kadUdpKey) `
        -EnableKademlia $false `
        -EnableEd2k $true `
        -ResetTransientState

    Write-EmuleHarnessTargetServerMet `
        -ServerIp $manifest.server.host `
        -ServerPort ([int]$manifest.server.tcpPort) `
        -DestinationPath (Join-Path $seederProfile.ProfileRoot "config\server.met") | Out-Null

    Set-EmuleHarnessObfuscationMode -Mode $(if ($effectiveEnableObfuscation) { "ObfuscatedPreferred" } else { "PlaintextOnly" }) -ProfileRoot $seederProfile.ProfileRoot | Out-Null

    $seedFilePath = Join-Path $seederProfile.IncomingRoot $effectiveFileName
    New-DeterministicBinaryFile -Path $seedFilePath -SizeBytes $effectiveFileSizeBytes -Pattern $effectiveFilePattern

    $seederSession = Start-EmuleHarnessPrivateEd2kSession `
        -ProfileRoot $seederProfile.ProfileRoot `
        -SeedFilePath $seedFilePath `
        -ExportLinkPath $seedLinkPath `
        -ExportSourceIp $manifest.server.host `
        -BuildConfig $EmuleHarnessBuildConfig

    Wait-Path -Path $seedLinkPath -TimeoutSeconds $seedExportTimeoutSeconds
    $parsedLink = Parse-Ed2kLinkFile -Path $seedLinkPath
    if ([string]::IsNullOrWhiteSpace([string]$parsedLink.AichRoot)) {
        throw "Seeder export link did not contain an AICH hash"
    }

    $publishedFile = Wait-GoEd2kFileAvailable `
        -BaseUrl $serverSession.AdminBaseUrl `
        -AdminToken $serverSession.AdminToken `
        -FileHash $parsedLink.FileHash `
        -TimeoutSeconds $ServerPublishTimeoutSeconds

    $agentDirectDownloadLink = Add-Ed2kLinkSource `
        -Link $parsedLink.Link `
        -SourceIp $manifest.server.host `
        -SourceTcpPort ([UInt16]$manifest.harnessSeeder.tcpPort)

    Remove-DirectoryIfExists -Path (Join-Path $agentScenarioRoot "agent-state")
    Remove-DirectoryIfExists -Path (Join-Path $agentScenarioRoot "agent-logs")

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
        -ServerSessionRotationSeconds 0 `
        -EnableObfuscation:$effectiveEnableObfuscation
    Wait-AgentControlReady -StatsUrl $agentStage1Session.StatsUrl -TimeoutSeconds 180

    if ([int]$manifest.timeouts.initialPublishDelaySeconds -gt 0) {
        Start-Sleep -Seconds ([int]$manifest.timeouts.initialPublishDelaySeconds)
    }

    Post-AgentEnrichDownload `
        -FileHash $parsedLink.FileHash `
        -FileName $parsedLink.FileName `
        -FileSize $parsedLink.FileSize `
        -SourceIp $manifest.server.host `
        -SourceTcpPort ([UInt16]$manifest.harnessSeeder.tcpPort) `
        -ControlUrl $agentStage1Session.ControlUrl | Out-Null

    $agentTransferManifestPath = Join-Path $agentStage1Session.TransferRoot ($parsedLink.FileHash.ToLowerInvariant()) "resume-manifest.json"
    $agentTransferManifest = Wait-TransferManifestState -ManifestPath $agentTransferManifestPath -TimeoutSeconds ([int]$manifest.timeouts.agentDownloadSeconds)
    $agentTransferSummary = Collect-AgentEd2kTransfer `
        -TransferRoot $agentStage1Session.TransferRoot `
        -FileHash $parsedLink.FileHash `
        -DestinationRoot $agentStage1ArtifactsRoot

    if (-not [bool]$agentTransferManifest.completed) {
        throw "Agent did not complete the local large-file download for $($parsedLink.FileHash)"
    }
    if (-not [bool]$agentTransferManifest.aich_hashset_acquired) {
        throw "Agent transfer manifest did not mark AICH hashset acquired for $($parsedLink.FileHash)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$agentTransferManifest.aich_root)) {
        throw "Agent transfer manifest did not persist an AICH root for $($parsedLink.FileHash)"
    }
    if ((@($agentTransferManifest.aich_hashset) | Measure-Object).Count -eq 0) {
        throw "Agent transfer manifest did not persist AICH part hashes for $($parsedLink.FileHash)"
    }

    if (-not $KeepSessionsRunning) {
        $stoppedSeederSession = Stop-EmuleHarnessParitySession -SessionDir $seederSession.SessionDir
    }

    $agentStage1Ed2kDumpPath = Get-LatestAgentEd2kDumpPath `
        -LogRoot $agentStage1Session.LogRoot
    if (-not $agentStage1Ed2kDumpPath) {
        throw "Agent stage1 ED2K TCP dump was not created under $($agentStage1Session.LogRoot)"
    }

    Copy-IfExists -Path $agentStage1Session.AgentLogPath -DestinationRoot $agentStage1ArtifactsRoot
    Copy-IfExists -Path $agentStage1Ed2kDumpPath -DestinationRoot $agentStage1ArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $seederSession -StoppedSession $stoppedSeederSession -PropertyName "ExportLinkPath") -DestinationRoot $seederArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $seederSession -StoppedSession $stoppedSeederSession -PropertyName "TraceLogPath") -DestinationRoot $seederArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $seederSession -StoppedSession $stoppedSeederSession -PropertyName "VerboseLogPath") -DestinationRoot $seederArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $seederSession -StoppedSession $stoppedSeederSession -PropertyName "StatusLogPath") -DestinationRoot $seederArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $seederSession -StoppedSession $stoppedSeederSession -PropertyName "EmuleHarnessUdpDumpPath") -DestinationRoot $seederArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $seederSession -StoppedSession $stoppedSeederSession -PropertyName "EmuleHarnessEd2kTcpDumpPath") -DestinationRoot $seederArtifactsRoot

    $seederDumpPath = Get-ChildItem -LiteralPath $seederArtifactsRoot -Filter "emule-harness-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace([string]$seederDumpPath) -or -not (Test-Path -LiteralPath $seederDumpPath)) {
        throw "Seeder harness ED2K TCP dump was not copied to $seederArtifactsRoot"
    }
    $stage1HashsetRequest = Get-Ed2kDumpRecordEvidence -DumpPath $seederDumpPath -OpcodeName "OP_HASHSETREQUEST2" -Direction "recv"
    if (-not $stage1HashsetRequest.RequestsAich) {
        throw "Agent stage1 did not request AICH on OP_HASHSETREQUEST2"
    }
    $stage1HashsetAnswer = Get-Ed2kDumpRecordEvidence -DumpPath $seederDumpPath -OpcodeName "OP_HASHSETANSWER2" -Direction "send"
    if (-not $stage1HashsetAnswer.RequestsAich) {
        throw "Seeder harness did not answer OP_HASHSETANSWER2 with AICH"
    }
    $stage1Compressed = Test-Ed2kDumpHasOpcode -DumpPath $seederDumpPath -Direction "send" -OpcodeNames @("OP_COMPRESSEDPART", "OP_COMPRESSEDPART_I64")
    if (-not $stage1Compressed) {
        throw "Seeder harness did not emit compressed part packets on the stage1 transfer"
    }
    $stage1TransportModes = @(Get-Ed2kDumpTransportModes -DumpPath $seederDumpPath)
    if (-not ($stage1TransportModes -contains $expectedTransportMode)) {
        throw "Seeder harness dump did not show expected transport mode '$expectedTransportMode' (observed: $($stage1TransportModes -join ', '))"
    }

    if ($stoppedSeederSession) {
        $seederSession = $null
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
        -ServerSessionRotationSeconds 0 `
        -EnableObfuscation:$effectiveEnableObfuscation
    Wait-AgentControlReady -StatsUrl $agentStage2Session.StatsUrl -TimeoutSeconds 180

    if ([int]$manifest.timeouts.agentRepublishDelaySeconds -gt 0) {
        Start-Sleep -Seconds ([int]$manifest.timeouts.agentRepublishDelaySeconds)
    }

    $downloaderProfile = & $profileScriptPath `
        -ProfileRoot $downloaderProfileRoot `
        -BindAddr $manifest.server.host `
        -TcpPort ([UInt16]$manifest.harnessDownloader.tcpPort) `
        -UdpPort ([UInt16]$manifest.harnessDownloader.udpPort) `
        -ServerUdpPort ([UInt16]$manifest.harnessDownloader.serverUdpPort) `
        -WebPort ([UInt16]$manifest.harnessDownloader.webPort) `
        -KadUdpKey ([UInt32]$manifest.harnessDownloader.kadUdpKey) `
        -EnableKademlia $false `
        -EnableEd2k $true `
        -ResetTransientState
    Set-EmuleHarnessObfuscationMode -Mode $(if ($effectiveEnableObfuscation) { "ObfuscatedPreferred" } else { "PlaintextOnly" }) -ProfileRoot $downloaderProfile.ProfileRoot | Out-Null

    Write-EmuleHarnessTargetServerMet `
        -ServerIp $manifest.server.host `
        -ServerPort ([int]$manifest.server.tcpPort) `
        -DestinationPath (Join-Path $downloaderProfile.ProfileRoot "config\server.met") | Out-Null

    [System.IO.File]::WriteAllText(
        $downloadLinkPath,
        (Add-Ed2kLinkSource `
            -Link $parsedLink.Link `
            -SourceIp $manifest.server.host `
            -SourceTcpPort ([UInt16]$manifest.agent.ed2kPort)) + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false))
    )
    $harnessDirectDownloadLink = (Get-Content -LiteralPath $downloadLinkPath -Raw).Trim()

    $downloaderSession = Start-EmuleHarnessPrivateEd2kSession `
        -ProfileRoot $downloaderProfile.ProfileRoot `
        -DownloadLinkPath $downloadLinkPath `
        -BuildConfig $EmuleHarnessBuildConfig

    $downloadedFilePath = Join-Path $downloaderProfile.IncomingRoot $parsedLink.FileName
    $downloadedFile = Wait-FileCompleted -Path $downloadedFilePath -ExpectedSize $parsedLink.FileSize -TimeoutSeconds ([int]$manifest.timeouts.harnessDownloadSeconds)

    if (-not $KeepSessionsRunning) {
        $stoppedDownloaderSession = Stop-EmuleHarnessParitySession -SessionDir $downloaderSession.SessionDir
    }

    $agentStage2Ed2kDumpPath = Get-LatestAgentEd2kDumpPath `
        -LogRoot $agentStage2Session.LogRoot
    if (-not $agentStage2Ed2kDumpPath) {
        throw "Agent stage2 ED2K TCP dump was not created under $($agentStage2Session.LogRoot)"
    }

    Copy-IfExists -Path $agentStage2Session.AgentLogPath -DestinationRoot $agentStage2ArtifactsRoot
    Copy-IfExists -Path $agentStage2Ed2kDumpPath -DestinationRoot $agentStage2ArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $downloaderSession -StoppedSession $stoppedDownloaderSession -PropertyName "TraceLogPath") -DestinationRoot $downloaderArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $downloaderSession -StoppedSession $stoppedDownloaderSession -PropertyName "VerboseLogPath") -DestinationRoot $downloaderArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $downloaderSession -StoppedSession $stoppedDownloaderSession -PropertyName "StatusLogPath") -DestinationRoot $downloaderArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $downloaderSession -StoppedSession $stoppedDownloaderSession -PropertyName "EmuleHarnessUdpDumpPath") -DestinationRoot $downloaderArtifactsRoot
    Copy-IfExists -Path (Get-HarnessArtifactPath -Session $downloaderSession -StoppedSession $stoppedDownloaderSession -PropertyName "EmuleHarnessEd2kTcpDumpPath") -DestinationRoot $downloaderArtifactsRoot
    Copy-IfSmall -Path $downloadedFile.FullName -DestinationRoot $downloaderArtifactsRoot

    $downloaderDumpPath = Get-ChildItem -LiteralPath $downloaderArtifactsRoot -Filter "emule-harness-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace([string]$downloaderDumpPath) -or -not (Test-Path -LiteralPath $downloaderDumpPath)) {
        throw "Downloader harness ED2K TCP dump was not copied to $downloaderArtifactsRoot"
    }
    $stage2HashsetRequest = Get-Ed2kDumpRecordEvidence -DumpPath $downloaderDumpPath -OpcodeName "OP_HASHSETREQUEST2" -Direction "send"
    if (-not $stage2HashsetRequest.RequestsAich) {
        throw "Harness downloader did not request AICH on OP_HASHSETREQUEST2"
    }
    $stage2HashsetAnswer = Get-Ed2kDumpRecordEvidence -DumpPath $downloaderDumpPath -OpcodeName "OP_HASHSETANSWER2" -Direction "recv"
    if (-not $stage2HashsetAnswer.RequestsAich) {
        throw "Agent stage2 did not answer OP_HASHSETANSWER2 with AICH"
    }
    $stage2Compressed = Test-Ed2kDumpHasOpcode -DumpPath $downloaderDumpPath -Direction "recv" -OpcodeNames @("OP_COMPRESSEDPART", "OP_COMPRESSEDPART_I64")
    if (-not $stage2Compressed) {
        throw "Downloader harness did not receive compressed part packets on the stage2 transfer"
    }
    $stage2TransportModes = @(Get-Ed2kDumpTransportModes -DumpPath $downloaderDumpPath)
    if (-not ($stage2TransportModes -contains $expectedTransportMode)) {
        throw "Downloader harness dump did not show expected transport mode '$expectedTransportMode' (observed: $($stage2TransportModes -join ', '))"
    }

    $downloaderVerboseLogPath = Get-ChildItem -LiteralPath $downloaderArtifactsRoot -Filter "eMule_Verbose.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace([string]$downloaderVerboseLogPath) -or -not (Test-Path -LiteralPath $downloaderVerboseLogPath)) {
        throw "Downloader harness verbose log was not copied to $downloaderArtifactsRoot"
    }
    $verifierAichOk = Select-String -Path $downloaderVerboseLogPath -Pattern 'MD4: OK - AICH: OK' -Quiet
    if (-not $verifierAichOk) {
        throw "Harness downloader verbose log did not report 'MD4: OK - AICH: OK'"
    }

    foreach ($path in @(
        $serverSession.StdoutPath,
        $serverSession.StderrPath,
        $serverSession.ConfigPath,
        $serverSession.CatalogPath
    )) {
        Copy-IfExists -Path $path -DestinationRoot $serverArtifactsRoot
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
        bindAddr = $manifest.server.host
        fileHash = $parsedLink.FileHash
        fileName = $parsedLink.FileName
        fileSize = $parsedLink.FileSize
        serverAdminBaseUrl = $serverSession.AdminBaseUrl
        serverPublishedName = $publishedFile.name
        serverPublishedSources = $publishedFile.sources
        agentTransferManifestPath = $agentTransferManifestPath
        harnessDownloadedFilePath = $downloadedFile.FullName
        transportMode = $expectedTransportMode
        sameHostTransferMode = [ordered]@{
            enabled = $true
            rationale = "local_server_plus_loopback_source_hint"
            agentDownloadLink = $agentDirectDownloadLink
            harnessDownloadLink = $harnessDirectDownloadLink
        }
        evidence = [ordered]@{
            exportedLinkHasAich = [bool](-not [string]::IsNullOrWhiteSpace([string]$parsedLink.AichRoot))
            agentManifestAichAcquired = [bool]$agentTransferManifest.aich_hashset_acquired
            stage1HashsetRequestAich = [bool]$stage1HashsetRequest.RequestsAich
            stage1HashsetAnswerAich = [bool]$stage1HashsetAnswer.RequestsAich
            stage1CompressedParts = [bool]$stage1Compressed
            stage1TransportModes = @($stage1TransportModes)
            stage2HashsetRequestAich = [bool]$stage2HashsetRequest.RequestsAich
            stage2HashsetAnswerAich = [bool]$stage2HashsetAnswer.RequestsAich
            stage2CompressedParts = [bool]$stage2Compressed
            stage2TransportModes = @($stage2TransportModes)
            harnessVerifierAichOk = [bool]$verifierAichOk
            agentStage1Ed2kDumpPresent = [bool](Test-Path -LiteralPath (Join-Path $agentStage1ArtifactsRoot (Split-Path -Leaf $agentStage1Ed2kDumpPath)))
            agentStage2Ed2kDumpPresent = [bool](Test-Path -LiteralPath (Join-Path $agentStage2ArtifactsRoot (Split-Path -Leaf $agentStage2Ed2kDumpPath)))
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
        if ($seederSession) {
            Stop-EmuleHarnessParitySession -SessionDir $seederSession.SessionDir | Out-Null
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
            runId = $runId
            completed = $false
            bindAddr = $manifest.server.host
            fileHash = if ($parsedLink) { $parsedLink.FileHash } else { $null }
            fileName = if ($parsedLink) { $parsedLink.FileName } else { $null }
            fileSize = if ($parsedLink) { $parsedLink.FileSize } else { $null }
            failedReason = $failedReason
            finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $failedSummary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    }
}

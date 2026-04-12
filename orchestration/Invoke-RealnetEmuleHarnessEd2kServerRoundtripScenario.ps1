#Requires -Version 7.6
<#
.SYNOPSIS
Runs a real-network ED2K server roundtrip transfer between the eMule harness and the agent.

.DESCRIPTION
Pins both runtimes to the same reachable live ED2K server, seeds one deterministic
binary from the eMule harness to the agent, restarts the agent so the completed
file is re-offered to the server, then launches a fresh eMule harness profile
which downloads the same file back from the agent.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\ed2k.server.emule-harness.agent.roundtrip.realnet.v1\manifest.v1.json"),
    [ValidateSet("Debug", "Release")]
    [string]$EmuleHarnessBuildConfig = "Debug",
    [string]$ServerMetPath,
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

function Remove-DirectoryIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifest = Get-Content -Raw $ScenarioManifestPath | ConvertFrom-Json

if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}
if (-not $env:OVERLORD_LOG_DIR) {
    throw "OVERLORD_LOG_DIR is not set"
}

$runId = "{0}-{1}" -f $manifest.scenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\{0}\{1}" -f $manifest.scenarioId, $runId)
$seederProfileRoot = Join-Path $artifactRoot "emule-harness-seeder-profile"
$downloaderProfileRoot = Join-Path $artifactRoot "emule-harness-downloader-profile"
$seedLinkPath = Join-Path $artifactRoot "seed.ed2k"
$downloadLinkPath = Join-Path $artifactRoot "download.ed2k"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$seederArtifactsRoot = Join-Path $artifactRoot "harness-seeder-artifacts"
$downloaderArtifactsRoot = Join-Path $artifactRoot "harness-downloader-artifacts"
$agentStage1ArtifactsRoot = Join-Path $artifactRoot "agent-stage1-artifacts"
$agentStage2ArtifactsRoot = Join-Path $artifactRoot "agent-stage2-artifacts"

foreach ($path in @(
    $artifactRoot,
    $seederArtifactsRoot,
    $downloaderArtifactsRoot,
    $agentStage1ArtifactsRoot,
    $agentStage2ArtifactsRoot
)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$networkResolverPath = Join-Path $toolingRoot "subsystems\network\helper-network-resolve-adapter.ps1"
$selectServerHelperPath = Join-Path $toolingRoot "subsystems\ed2k\helper-ed2k-select-live-server.ps1"
$profileScriptPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"
$writeServerMetHelperPath = Join-Path $toolingRoot "subsystems\emule-harness\helper-emule-harness-write-target-server-met.ps1"
$startHarnessHelperPath = Join-Path $toolingRoot "subsystems\emule-harness\helper-emule-harness-start-private-ed2k-session.ps1"
$stopHarnessHelperPath = Join-Path $toolingRoot "subsystems\emule-harness\helper-emule-harness-stop-parity-session.ps1"
$startAgentHelperPath = Join-Path $toolingRoot "subsystems\agent\helper-agent-start-parity-session.ps1"
$stopAgentHelperPath = Join-Path $toolingRoot "subsystems\agent\helper-agent-stop-parity-session.ps1"
$collectTransferHelperPath = Join-Path $toolingRoot "subsystems\agent\helper-agent-collect-ed2k-transfer.ps1"
$enrichDownloadHelperPath = Join-Path $toolingRoot "subsystems\agent\helper-agent-post-enrich-download.ps1"

foreach ($requiredPath in @(
    $networkResolverPath,
    $selectServerHelperPath,
    $profileScriptPath,
    $writeServerMetHelperPath,
    $startHarnessHelperPath,
    $stopHarnessHelperPath,
    $startAgentHelperPath,
    $stopAgentHelperPath,
    $collectTransferHelperPath,
    $enrichDownloadHelperPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required scenario helper not found at $requiredPath"
    }
}

$resolvedAdapter = & $networkResolverPath -PreferredInterfaceAlias $manifest.interfaceAlias
$bindAddr = [string]$resolvedAdapter.IPAddress

$selectedServer = & $selectServerHelperPath `
    -SourcePath $(if ([string]::IsNullOrWhiteSpace($ServerMetPath)) { (Join-Path $toolingRoot ".local\emule-harness-seeds\$($manifest.seedBundleId)\server.met") } else { $ServerMetPath }) `
    -MaxCandidates ([int]$manifest.serverSelection.maxCandidates) `
    -ConnectTimeoutMilliseconds ([int]$manifest.serverSelection.connectTimeoutMilliseconds)

$runManifest = [ordered]@{
    schemaVersion = "run-manifest/v1"
    scenarioId = $manifest.scenarioId
    runId = $runId
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    artifactRoot = $artifactRoot
    interfaceAlias = $resolvedAdapter.InterfaceAlias
    bindAddr = $bindAddr
    selectedServer = $selectedServer
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runManifestPath

$agentStage1Session = $null
$agentStage2Session = $null
$seederSession = $null
$downloaderSession = $null
$parsedLink = $null
$failedReason = $null
$agentDirectDownloadLink = $null
$harnessDirectDownloadLink = $null

try {
    $seederProfile = & $profileScriptPath `
        -ProfileRoot $seederProfileRoot `
        -BindAddr $bindAddr `
        -TcpPort ([UInt16]$manifest.harnessSeeder.tcpPort) `
        -UdpPort ([UInt16]$manifest.harnessSeeder.udpPort) `
        -ServerUdpPort ([UInt16]$manifest.harnessSeeder.serverUdpPort) `
        -WebPort ([UInt16]$manifest.harnessSeeder.webPort) `
        -EnableKademlia $false `
        -EnableEd2k $true `
        -EnableUpnp $true `
        -ResetTransientState
    & $writeServerMetHelperPath `
        -ServerIp $selectedServer.Host `
        -ServerPort ([int]$selectedServer.Port) `
        -UdpFlags ([int]$selectedServer.UdpFlags) `
        -UdpKey ([int]$selectedServer.UdpKey) `
        -UdpKeyIp ([int]$selectedServer.UdpKeyIp) `
        -TcpObfuscationPort ([int]$selectedServer.TcpObfuscationPort) `
        -UdpObfuscationPort ([int]$selectedServer.UdpObfuscationPort) `
        -DestinationPath (Join-Path $seederProfile.ProfileRoot "config\server.met") | Out-Null

    $seedFilePath = Join-Path $seederProfile.IncomingRoot $manifest.file.name
    New-DeterministicBinaryFile -Path $seedFilePath -SizeBytes ([UInt64]$manifest.file.sizeBytes) -Pattern ([string]$manifest.file.pattern)

    $seederSession = & $startHarnessHelperPath `
        -ProfileRoot $seederProfile.ProfileRoot `
        -SeedFilePath $seedFilePath `
        -ExportLinkPath $seedLinkPath `
        -ExportSourceIp $bindAddr `
        -BuildConfig $EmuleHarnessBuildConfig

    Wait-Path -Path $seedLinkPath -TimeoutSeconds ([int]$manifest.timeouts.harnessReadySeconds)
    $parsedLink = Parse-Ed2kLinkFile -Path $seedLinkPath
    $agentDirectDownloadLink = Add-Ed2kLinkSource `
        -Link $parsedLink.Link `
        -SourceIp $bindAddr `
        -SourceTcpPort ([UInt16]$manifest.harnessSeeder.tcpPort)
    Remove-DirectoryIfExists -Path (Join-Path $env:OVERLORD_TMP_DIR ("agent-real-state\overlord-ed2k-transfer\{0}" -f $parsedLink.FileHash.ToLowerInvariant()))

    $agentStage1Session = & $startAgentHelperPath `
        -InterfaceAlias $resolvedAdapter.InterfaceAlias `
        -CapturePort ([int]$manifest.agent.capturePort) `
        -SessionPrefix "$runId-agent-stage1" `
        -ServerIp $selectedServer.Host `
        -ServerPort ([int]$selectedServer.Port) `
        -ServerUdpFlags ([int]$selectedServer.UdpFlags) `
        -ServerUdpKey ([int]$selectedServer.UdpKey) `
        -ServerUdpKeyIp ([int]$selectedServer.UdpKeyIp) `
        -ServerTcpObfuscationPort ([int]$selectedServer.TcpObfuscationPort) `
        -ServerUdpObfuscationPort ([int]$selectedServer.UdpObfuscationPort) `
        -ServerSessionRotationSeconds 0 `
        -ServerConnectTimeoutSeconds 8 `
        -ServerReconnectIntervalSeconds 5
    Wait-AgentControlReady -StatsUrl $agentStage1Session.StatsUrl -TimeoutSeconds 180

    if ([int]$manifest.timeouts.initialPublishDelaySeconds -gt 0) {
        Start-Sleep -Seconds ([int]$manifest.timeouts.initialPublishDelaySeconds)
    }

    & $enrichDownloadHelperPath `
        -FileHash $parsedLink.FileHash `
        -FileName $parsedLink.FileName `
        -FileSize $parsedLink.FileSize `
        -SourceIp $bindAddr `
        -SourceTcpPort ([UInt16]$manifest.harnessSeeder.tcpPort) `
        -ControlUrl $agentStage1Session.ControlUrl | Out-Null

    $agentTransferManifestPath = Join-Path $agentStage1Session.TransferRoot ($parsedLink.FileHash.ToLowerInvariant()) "resume-manifest.json"
    $agentTransferManifest = Wait-TransferManifestState -ManifestPath $agentTransferManifestPath -TimeoutSeconds ([int]$manifest.timeouts.agentDownloadSeconds)
    $agentTransferSummary = & $collectTransferHelperPath `
        -TransferRoot $agentStage1Session.TransferRoot `
        -FileHash $parsedLink.FileHash `
        -DestinationRoot $agentStage1ArtifactsRoot

    Copy-IfExists -Path $agentStage1Session.AgentLogPath -DestinationRoot $agentStage1ArtifactsRoot
    Copy-IfExists -Path $agentStage1Session.PacketDumpPath -DestinationRoot $agentStage1ArtifactsRoot
    Copy-IfExists -Path $seederSession.ExportLinkPath -DestinationRoot $seederArtifactsRoot
    Copy-IfExists -Path $seederSession.TraceLogPath -DestinationRoot $seederArtifactsRoot
    Copy-IfExists -Path $seederSession.VerboseLogPath -DestinationRoot $seederArtifactsRoot
    Copy-IfExists -Path $seederSession.StatusLogPath -DestinationRoot $seederArtifactsRoot
    Copy-IfExists -Path $seederSession.EmuleHarnessUdpDumpPath -DestinationRoot $seederArtifactsRoot
    Copy-IfExists -Path $seederSession.EmuleHarnessEd2kTcpDumpPath -DestinationRoot $seederArtifactsRoot

    if (-not [bool]$agentTransferManifest.completed -or -not [bool]$agentTransferSummary.Completed) {
        throw "Agent did not complete the real-server download for $($parsedLink.FileHash)"
    }

    & $stopHarnessHelperPath -SessionDir $seederSession.SessionDir | Out-Null
    $seederSession = $null

    & $stopAgentHelperPath -SessionDir $agentStage1Session.SessionDir | Out-Null
    $agentStage1Session = $null

    $agentStage2Session = & $startAgentHelperPath `
        -InterfaceAlias $resolvedAdapter.InterfaceAlias `
        -CapturePort ([int]$manifest.agent.capturePort) `
        -SessionPrefix "$runId-agent-stage2" `
        -ServerIp $selectedServer.Host `
        -ServerPort ([int]$selectedServer.Port) `
        -ServerUdpFlags ([int]$selectedServer.UdpFlags) `
        -ServerUdpKey ([int]$selectedServer.UdpKey) `
        -ServerUdpKeyIp ([int]$selectedServer.UdpKeyIp) `
        -ServerTcpObfuscationPort ([int]$selectedServer.TcpObfuscationPort) `
        -ServerUdpObfuscationPort ([int]$selectedServer.UdpObfuscationPort) `
        -ServerSessionRotationSeconds 0 `
        -ServerConnectTimeoutSeconds 8 `
        -ServerReconnectIntervalSeconds 5
    Wait-AgentControlReady -StatsUrl $agentStage2Session.StatsUrl -TimeoutSeconds 180

    if ([int]$manifest.timeouts.agentRepublishDelaySeconds -gt 0) {
        Start-Sleep -Seconds ([int]$manifest.timeouts.agentRepublishDelaySeconds)
    }

    $downloaderProfile = & $profileScriptPath `
        -ProfileRoot $downloaderProfileRoot `
        -BindAddr $bindAddr `
        -TcpPort ([UInt16]$manifest.harnessDownloader.tcpPort) `
        -UdpPort ([UInt16]$manifest.harnessDownloader.udpPort) `
        -ServerUdpPort ([UInt16]$manifest.harnessDownloader.serverUdpPort) `
        -WebPort ([UInt16]$manifest.harnessDownloader.webPort) `
        -EnableKademlia $false `
        -EnableEd2k $true `
        -EnableUpnp $true `
        -ResetTransientState
    & $writeServerMetHelperPath `
        -ServerIp $selectedServer.Host `
        -ServerPort ([int]$selectedServer.Port) `
        -UdpFlags ([int]$selectedServer.UdpFlags) `
        -UdpKey ([int]$selectedServer.UdpKey) `
        -UdpKeyIp ([int]$selectedServer.UdpKeyIp) `
        -TcpObfuscationPort ([int]$selectedServer.TcpObfuscationPort) `
        -UdpObfuscationPort ([int]$selectedServer.UdpObfuscationPort) `
        -DestinationPath (Join-Path $downloaderProfile.ProfileRoot "config\server.met") | Out-Null

    [System.IO.File]::WriteAllText(
        $downloadLinkPath,
        (Add-Ed2kLinkSource `
            -Link $parsedLink.Link `
            -SourceIp $bindAddr `
            -SourceTcpPort ([UInt16]$manifest.agent.ed2kPort)) + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false))
    )
    $harnessDirectDownloadLink = (Get-Content -LiteralPath $downloadLinkPath -Raw).Trim()

    $downloaderSession = & $startHarnessHelperPath `
        -ProfileRoot $downloaderProfile.ProfileRoot `
        -DownloadLinkPath $downloadLinkPath `
        -BuildConfig $EmuleHarnessBuildConfig

    $downloadedFilePath = Join-Path $downloaderProfile.IncomingRoot $parsedLink.FileName
    $downloadedFile = Wait-FileCompleted -Path $downloadedFilePath -ExpectedSize $parsedLink.FileSize -TimeoutSeconds ([int]$manifest.timeouts.harnessDownloadSeconds)

    Copy-IfExists -Path $agentStage2Session.AgentLogPath -DestinationRoot $agentStage2ArtifactsRoot
    Copy-IfExists -Path $agentStage2Session.PacketDumpPath -DestinationRoot $agentStage2ArtifactsRoot
    Copy-IfExists -Path $downloaderSession.TraceLogPath -DestinationRoot $downloaderArtifactsRoot
    Copy-IfExists -Path $downloaderSession.VerboseLogPath -DestinationRoot $downloaderArtifactsRoot
    Copy-IfExists -Path $downloaderSession.StatusLogPath -DestinationRoot $downloaderArtifactsRoot
    Copy-IfExists -Path $downloaderSession.EmuleHarnessUdpDumpPath -DestinationRoot $downloaderArtifactsRoot
    Copy-IfExists -Path $downloaderSession.EmuleHarnessEd2kTcpDumpPath -DestinationRoot $downloaderArtifactsRoot
    Copy-IfExists -Path $downloadedFile.FullName -DestinationRoot $downloaderArtifactsRoot

    $runSummary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $manifest.scenarioId
        runId = $runId
        completed = $true
        bindAddr = $bindAddr
        selectedServer = $selectedServer
        fileHash = $parsedLink.FileHash
        fileName = $parsedLink.FileName
        fileSize = $parsedLink.FileSize
        sameHostTransferMode = [ordered]@{
            enabled = $true
            rationale = "real_server_publish_plus_local_source_hint"
            agentDownloadLink = $agentDirectDownloadLink
            harnessDownloadLink = $harnessDirectDownloadLink
        }
        agentTransferManifestPath = $agentTransferManifestPath
        harnessDownloadedFilePath = $downloadedFile.FullName
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
            & $stopHarnessHelperPath -SessionDir $downloaderSession.SessionDir | Out-Null
        }
        if ($seederSession) {
            & $stopHarnessHelperPath -SessionDir $seederSession.SessionDir | Out-Null
        }
        if ($agentStage2Session) {
            & $stopAgentHelperPath -SessionDir $agentStage2Session.SessionDir | Out-Null
        }
        if ($agentStage1Session) {
            & $stopAgentHelperPath -SessionDir $agentStage1Session.SessionDir | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $runSummaryPath)) {
        $failedSummary = [ordered]@{
            schemaVersion = "run-summary/v1"
            scenarioId = $manifest.scenarioId
            runId = $runId
            completed = $false
            bindAddr = $bindAddr
            selectedServer = $selectedServer
            fileHash = if ($parsedLink) { $parsedLink.FileHash } else { $null }
            fileName = if ($parsedLink) { $parsedLink.FileName } else { $null }
            fileSize = if ($parsedLink) { $parsedLink.FileSize } else { $null }
            failedReason = $failedReason
            finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $failedSummary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    }
}

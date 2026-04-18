#Requires -Version 7.6
<#
.SYNOPSIS
Runs a deterministic private eMule harness-to-agent ED2K download through a local goed2k-server.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\ed2k.server.emule-harness.agent.private.v1\manifest.v1.json"),
    [ValidateSet("Debug")]
    [string]$EmuleHarnessBuildConfig = "Debug",
    [int]$ServerPublishTimeoutSeconds = 180,
    [int]$DownloadTimeoutSeconds = 300,
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

function New-SeedPdfFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [int]$RepeatCount
    )

    $line = "%PDF-1.4`n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj`n2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj`n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>endobj`n4 0 obj<</Length 44>>stream`nBT /F1 12 Tf 72 120 Td (Ubuntu Linux private server) Tj ET`nendstream`nendobj`nxref`n0 5`n0000000000 65535 f `ntrailer<</Size 5/Root 1 0 R>>`nstartxref`n0`n%%EOF`n"
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
$serverScenarioRoot = Join-Path $artifactRoot "goed2k-server"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$emuleHarnessArtifactsRoot = Join-Path $artifactRoot "emule-harness-artifacts"
$agentArtifactsRoot = Join-Path $artifactRoot "agent-artifacts"
$serverArtifactsRoot = Join-Path $artifactRoot "server-artifacts"

foreach ($path in @($artifactRoot, $emuleHarnessArtifactsRoot, $agentArtifactsRoot, $serverArtifactsRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$profileScriptPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"

foreach ($requiredPath in @($profileScriptPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required scenario helper not found at $requiredPath"
    }
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
    -EnableKademlia $false `
    -EnableEd2k $true `
    -ResetTransientState

New-SeedPdfFile -Path $emuleHarnessSeedPath -RepeatCount ([int]$manifest.emuleHarness.seedRepeatCount)

$oracleServerMetPath = Join-Path $profile.ProfileRoot "config\server.met"
$runManifest = [ordered]@{
    schemaVersion = "run-manifest/v1"
    scenarioId = $manifest.scenarioId
    runId = $runId
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    artifactRoot = $artifactRoot
    server = [ordered]@{
        scenarioRoot = $serverScenarioRoot
        tcpPort = [UInt16]$manifest.server.tcpPort
        adminPort = [UInt16]$manifest.server.adminPort
    }
    emuleHarness = [ordered]@{
        profileRoot = $profile.ProfileRoot
        seedFilePath = $emuleHarnessSeedPath
        serverMetPath = $oracleServerMetPath
    }
    agent = [ordered]@{
        scenarioRoot = $agentScenarioRoot
    }
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runManifestPath

$serverSession = $null
$emuleHarnessSession = $null
$agentSession = $null
$parsedLink = $null
$publishedFile = $null
$failedReason = $null

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

    Write-EmuleHarnessTargetServerMet `
        -ServerIp $manifest.server.host `
        -ServerPort ([int]$manifest.server.tcpPort) `
        -DestinationPath $oracleServerMetPath | Out-Null

    $emuleHarnessSession = Start-EmuleHarnessPrivateEd2kSession `
        -ProfileRoot $profile.ProfileRoot `
        -SeedFilePath $emuleHarnessSeedPath `
        -ExportLinkPath $emuleHarnessLinkPath `
        -AgentBootstrapNode "127.0.0.1:1" `
        -BuildConfig $EmuleHarnessBuildConfig

    Wait-Path -Path $emuleHarnessLinkPath -TimeoutSeconds 60
    $parsedLink = Parse-Ed2kLinkFile -Path $emuleHarnessLinkPath
    $publishedFile = Wait-GoEd2kFileAvailable `
        -BaseUrl $serverSession.AdminBaseUrl `
        -AdminToken $serverSession.AdminToken `
        -FileHash $parsedLink.FileHash `
        -TimeoutSeconds $ServerPublishTimeoutSeconds

    $agentSession = Start-AgentPrivateEd2kSession `
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
    Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl -TimeoutSeconds 180

    Post-AgentEnrichDownload `
        -FileHash $parsedLink.FileHash `
        -FileName $parsedLink.FileName `
        -FileSize $parsedLink.FileSize `
        -ControlUrl $agentSession.ControlUrl | Out-Null

    $manifestPath = Join-Path $agentSession.TransferRoot ($parsedLink.FileHash.ToLowerInvariant()) "resume-manifest.json"
    $manifestState = Wait-TransferManifestState -ManifestPath $manifestPath -TimeoutSeconds $DownloadTimeoutSeconds
    $transferSummary = Collect-AgentEd2kTransfer `
        -TransferRoot $agentSession.TransferRoot `
        -FileHash $parsedLink.FileHash `
        -DestinationRoot $agentArtifactsRoot

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

    foreach ($path in @(
        $serverSession.StdoutPath,
        $serverSession.StderrPath,
        $serverSession.ConfigPath,
        $serverSession.CatalogPath
    )) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $serverArtifactsRoot (Split-Path -Leaf $path)) -Force
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
        transferManifestPath = $manifestPath
        agentControlUrl = $agentSession.ControlUrl
        serverAdminBaseUrl = $serverSession.AdminBaseUrl
        serverPublishedName = $publishedFile.name
        serverPublishedSources = $publishedFile.sources
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
        if ($serverSession) {
            Stop-Goed2kPrivateSession -SessionDir $serverSession.SessionDir | Out-Null
        }
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

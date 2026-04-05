<#
.SYNOPSIS
Runs a deterministic private oracle-to-agent ED2K download through a local goed2k-server.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\ed2k.server.oracle.agent.private.v1\manifest.v1.json"),
    [ValidateSet("Debug", "Release")]
    [string]$OracleBuildConfig = "Debug",
    [int]$ServerPublishTimeoutSeconds = 180,
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
$oracleProfileRoot = Join-Path $artifactRoot "oracle-profile"
$oracleSeedPath = Join-Path $oracleProfileRoot "Incoming\$($manifest.oracle.seedFileName)"
$oracleLinkPath = Join-Path $oracleProfileRoot "seed.ed2k"
$agentScenarioRoot = Join-Path $artifactRoot "agent"
$serverScenarioRoot = Join-Path $artifactRoot "goed2k-server"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$oracleArtifactsRoot = Join-Path $artifactRoot "oracle-artifacts"
$agentArtifactsRoot = Join-Path $artifactRoot "agent-artifacts"
$serverArtifactsRoot = Join-Path $artifactRoot "server-artifacts"

foreach ($path in @($artifactRoot, $oracleArtifactsRoot, $agentArtifactsRoot, $serverArtifactsRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$profileScriptPath = Join-Path $toolingRoot "profiles\New-OraclePrivateEd2kProfile.ps1"
$oracleServerMetWriterPath = Join-Path $toolingRoot "helper-oracle-write-target-server-met.ps1"
$oracleStartScriptPath = Join-Path $toolingRoot "helper-oracle-start-private-ed2k-session.ps1"
$oracleStopScriptPath = Join-Path $toolingRoot "helper-oracle-stop-parity-session.ps1"
$agentStartScriptPath = Join-Path $toolingRoot "helper-agent-start-private-ed2k-session.ps1"
$agentStopScriptPath = Join-Path $toolingRoot "helper-agent-stop-parity-session.ps1"
$serverStartScriptPath = Join-Path $toolingRoot "helper-goed2k-start-private-session.ps1"
$serverStopScriptPath = Join-Path $toolingRoot "helper-goed2k-stop-private-session.ps1"
$enrichScriptPath = Join-Path $toolingRoot "helper-agent-post-enrich-download.ps1"
$collectTransferScriptPath = Join-Path $toolingRoot "helper-agent-collect-ed2k-transfer.ps1"

foreach ($requiredPath in @(
    $profileScriptPath,
    $oracleServerMetWriterPath,
    $oracleStartScriptPath,
    $oracleStopScriptPath,
    $agentStartScriptPath,
    $agentStopScriptPath,
    $serverStartScriptPath,
    $serverStopScriptPath,
    $enrichScriptPath,
    $collectTransferScriptPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required scenario helper not found at $requiredPath"
    }
}

$profile = & $profileScriptPath `
    -ProfileRoot $oracleProfileRoot `
    -BindAddr $manifest.oracle.bindAddr `
    -TcpPort ([UInt16]$manifest.oracle.tcpPort) `
    -UdpPort ([UInt16]$manifest.oracle.udpPort) `
    -ServerUdpPort ([UInt16]$manifest.oracle.serverUdpPort) `
    -WebPort ([UInt16]$manifest.oracle.webPort) `
    -KadUdpKey ([UInt32]$manifest.oracle.kadUdpKey) `
    -EnableKademlia $false `
    -EnableEd2k $true `
    -ResetTransientState

New-SeedPdfFile -Path $oracleSeedPath -RepeatCount ([int]$manifest.oracle.seedRepeatCount)

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
    oracle = [ordered]@{
        profileRoot = $profile.ProfileRoot
        seedFilePath = $oracleSeedPath
        serverMetPath = $oracleServerMetPath
    }
    agent = [ordered]@{
        scenarioRoot = $agentScenarioRoot
    }
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runManifestPath

$serverSession = $null
$oracleSession = $null
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
    $serverSession = & $serverStartScriptPath @serverStartParams

    & $oracleServerMetWriterPath `
        -ServerIp $manifest.server.host `
        -ServerPort ([int]$manifest.server.tcpPort) `
        -DestinationPath $oracleServerMetPath | Out-Null

    $oracleSession = & $oracleStartScriptPath `
        -ProfileRoot $profile.ProfileRoot `
        -SeedFilePath $oracleSeedPath `
        -ExportLinkPath $oracleLinkPath `
        -AgentBootstrapNode "127.0.0.1:1" `
        -BuildConfig $OracleBuildConfig

    Wait-Path -Path $oracleLinkPath -TimeoutSeconds 60
    $parsedLink = Parse-Ed2kLinkFile -Path $oracleLinkPath
    $publishedFile = Wait-GoEd2kFileAvailable `
        -BaseUrl $serverSession.AdminBaseUrl `
        -AdminToken $serverSession.AdminToken `
        -FileHash $parsedLink.FileHash `
        -TimeoutSeconds $ServerPublishTimeoutSeconds

    $agentSession = & $agentStartScriptPath `
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

    foreach ($path in @(
        $oracleSession.ExportLinkPath,
        $oracleSession.TraceLogPath,
        $oracleSession.VerboseLogPath,
        $oracleSession.StatusLogPath,
        $oracleSession.OracleUdpDumpPath,
        $oracleSession.OracleEd2kTcpDumpPath
    )) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $oracleArtifactsRoot (Split-Path -Leaf $path)) -Force
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
            & $serverStopScriptPath -SessionDir $serverSession.SessionDir | Out-Null
        }
        if ($oracleSession) {
            & $oracleStopScriptPath -SessionDir $oracleSession.SessionDir | Out-Null
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
            failedReason = $failedReason
            finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $failedSummary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    }
}

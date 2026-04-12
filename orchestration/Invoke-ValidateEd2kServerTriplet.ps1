#Requires -Version 7.6
<#
.SYNOPSIS
Runs focused local validation of the eMule harness + goed2k-server + agent triplet.
#>

[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$EmuleHarnessBuildConfig = "Debug"
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
        [int]$TimeoutSeconds = 90
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
    [System.IO.File]::WriteAllText($Path, $builder.ToString(), (New-Object System.Text.ASCIIEncoding))
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

function Wait-GoEd2kFileState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$AdminToken,
        [Parameter(Mandatory = $true)]
        [string]$FileHash,
        [int]$ExpectedSources = 1,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-GoEd2kAdminGet -BaseUrl $BaseUrl -AdminToken $AdminToken -RelativePath ("/api/files/{0}" -f $FileHash.ToUpperInvariant())
            if ($response.ok -and $null -ne $response.data -and [int]$response.data.sources -ge $ExpectedSources) {
                return $response.data
            }
        }
        catch {
        }
        Start-Sleep -Seconds 2
    }

    throw "goed2k-server did not expose file $FileHash with sources >= $ExpectedSources within $TimeoutSeconds seconds"
}

function Wait-AgentLogPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $LogPath) {
            $match = Select-String -Path $LogPath -Pattern $Pattern -CaseSensitive:$false | Select-Object -Last 1
            if ($match) {
                return $match.Line
            }
        }
        Start-Sleep -Seconds 2
    }

    throw "Agent log $LogPath did not match pattern '$Pattern' within $TimeoutSeconds seconds"
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

function Write-CatalogFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Files
    )

    $catalog = [ordered]@{ files = $Files }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $catalog | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
    $Path
}

function Stop-AgentSessionWithRestore {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Session,
        [Parameter(Mandatory = $true)]
        [scriptblock]$StopOperation
    )

    & $StopOperation -SessionDir $Session.SessionDir | Out-Null
    if ($Session.ConfigBackupPath -and (Test-Path -LiteralPath $Session.ConfigBackupPath)) {
        Copy-Item -LiteralPath $Session.ConfigBackupPath -Destination $Session.ConfigPath -Force
    }
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

function New-EmuleHarnessPrivateProfile {
    param(
        [string]$ProfileScriptPath,
        [string]$ProfileRoot,
        [string]$BindAddr,
        [UInt16]$TcpPort,
        [UInt16]$UdpPort,
        [UInt16]$WebPort,
        [UInt32]$KadUdpKey
    )

    & $ProfileScriptPath `
        -ProfileRoot $ProfileRoot `
        -BindAddr $BindAddr `
        -TcpPort $TcpPort `
        -UdpPort $UdpPort `
        -ServerUdpPort 0 `
        -WebPort $WebPort `
        -KadUdpKey $KadUdpKey `
        -EnableKademlia $false `
        -EnableEd2k $true `
        -ResetTransientState
}

function Start-EmuleHarnessPeer {
    param(
        [string]$ProfileScriptPath,
        [scriptblock]$ServerMetWriterOperation,
        [scriptblock]$StartOperation,
        [string]$ProfileRoot,
        [string]$BindAddr,
        [UInt16]$TcpPort,
        [UInt16]$UdpPort,
        [UInt16]$WebPort,
        [UInt32]$KadUdpKey,
        [string]$SeedFilePath,
        [string]$SeedMarkerText,
        [int]$SeedRepeatCount,
        [string]$ExportLinkPath,
        [string]$ServerHost,
        [UInt16]$ServerPort,
        [string]$EmuleHarnessBuildConfig,
        [switch]$SkipRuntimeCleanup
    )

    $profile = New-EmuleHarnessPrivateProfile `
        -ProfileScriptPath $ProfileScriptPath `
        -ProfileRoot $ProfileRoot `
        -BindAddr $BindAddr `
        -TcpPort $TcpPort `
        -UdpPort $UdpPort `
        -WebPort $WebPort `
        -KadUdpKey $KadUdpKey

    $serverMetPath = Join-Path $profile.ProfileRoot "config\server.met"
    & $ServerMetWriterOperation -ServerIp $ServerHost -ServerPort ([int]$ServerPort) -DestinationPath $serverMetPath | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($SeedMarkerText) -and $SeedRepeatCount -gt 0) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $SeedFilePath) -Force | Out-Null
        New-SeedPdfFile -Path $SeedFilePath -MarkerText $SeedMarkerText -RepeatCount $SeedRepeatCount
    }
    if (-not (Test-Path -LiteralPath $SeedFilePath)) {
        throw "eMule harness seed file was not materialized at $SeedFilePath"
    }

    $session = & $StartOperation `
        -ProfileRoot $profile.ProfileRoot `
        -SeedFilePath $SeedFilePath `
        -ExportLinkPath $ExportLinkPath `
        -AgentBootstrapNode "127.0.0.1:1" `
        -BuildConfig $EmuleHarnessBuildConfig `
        -SkipRuntimeCleanup:$SkipRuntimeCleanup

    Wait-Path -Path $ExportLinkPath -TimeoutSeconds 90
    $link = Parse-Ed2kLinkFile -Path $ExportLinkPath

    [pscustomobject]@{
        Profile = $profile
        Session = $session
        Link = $link
        ServerMetPath = $serverMetPath
    }
}

function Invoke-TestMultiFilePublishSearch {
    param(
        [string]$TestRoot,
        [hashtable]$Paths,
        [string]$EmuleHarnessBuildConfig
    )

    $serverSession = $null
    $agentSession = $null
    $emuleHarnesses = @()
    $probeTerm = "triplet-multi"
    $artifactsRoot = Join-Path $TestRoot "artifacts"
    New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null

    try {
        $catalogPath = Write-CatalogFile -Path (Join-Path $TestRoot "empty-catalog.json") -Files @()
        $serverSession = & $Paths.ServerStart `
            -ScenarioRoot (Join-Path $TestRoot "server") `
            -ListenHost "127.0.0.1" `
            -TcpPort 46161 `
            -AdminPort 46180 `
            -AdminToken "local-goed2k-token" `
            -SourceCatalogPath $catalogPath

        $seedA = Join-Path $TestRoot "emule-harness-a\Incoming\triplet-multi-alpha.pdf"
        $seedB = Join-Path $TestRoot "emule-harness-b\Incoming\triplet-multi-beta.pdf"

        $emuleHarnesses += Start-EmuleHarnessPeer `
            -ProfileScriptPath $Paths.Profile `
            -ServerMetWriterOperation $Paths.ServerMetWriter `
            -StartOperation $Paths.EmuleHarnessStart `
            -ProfileRoot (Join-Path $TestRoot "emule-harness-a") `
            -BindAddr "127.0.0.1" `
            -TcpPort 46062 `
            -UdpPort 46072 `
            -WebPort 48111 `
            -KadUdpKey 4606201 `
            -SeedFilePath $seedA `
            -SeedMarkerText "triplet multi alpha" `
            -SeedRepeatCount 384 `
            -ExportLinkPath (Join-Path $TestRoot "emule-harness-a\seed.ed2k") `
            -ServerHost "127.0.0.1" `
            -ServerPort 46161 `
            -EmuleHarnessBuildConfig $EmuleHarnessBuildConfig `
            -SkipRuntimeCleanup

        $emuleHarnesses += Start-EmuleHarnessPeer `
            -ProfileScriptPath $Paths.Profile `
            -ServerMetWriterOperation $Paths.ServerMetWriter `
            -StartOperation $Paths.EmuleHarnessStart `
            -ProfileRoot (Join-Path $TestRoot "emule-harness-b") `
            -BindAddr "127.0.0.1" `
            -TcpPort 46064 `
            -UdpPort 46074 `
            -WebPort 48112 `
            -KadUdpKey 4606202 `
            -SeedFilePath $seedB `
            -SeedMarkerText "triplet multi beta" `
            -SeedRepeatCount 448 `
            -ExportLinkPath (Join-Path $TestRoot "emule-harness-b\seed.ed2k") `
            -ServerHost "127.0.0.1" `
            -ServerPort 46161 `
            -EmuleHarnessBuildConfig $EmuleHarnessBuildConfig `
            -SkipRuntimeCleanup

        $published = @()
        foreach ($emuleHarness in $emuleHarnesses) {
            $published += Wait-GoEd2kFileState `
                -BaseUrl $serverSession.AdminBaseUrl `
                -AdminToken $serverSession.AdminToken `
                -FileHash $emuleHarness.Link.FileHash `
                -ExpectedSources 1 `
                -TimeoutSeconds 180
        }

        $agentSession = & $Paths.AgentStart `
            -ScenarioRoot (Join-Path $TestRoot "agent") `
            -ControlPort 14311 `
            -KadPort 44130 `
            -Ed2kPort 44131 `
            -DisableKad `
            -ServerHost "127.0.0.1" `
            -ServerPort 46161 `
            -ServerSessionRotationSeconds 0 `
            -ProbeSearchTerm $probeTerm
        Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl -TimeoutSeconds 180

        $searchLine = Wait-AgentLogPattern `
            -LogPath $agentSession.AgentLogPath `
            -Pattern "ED2K search results.*count=2.*triplet-multi" `
            -TimeoutSeconds 90

        foreach ($emuleHarness in $emuleHarnesses) {
            Copy-IfExists -Path $emuleHarness.Session.ExportLinkPath -DestinationRoot $artifactsRoot
            Copy-IfExists -Path $emuleHarness.Session.EmuleHarnessEd2kTcpDumpPath -DestinationRoot $artifactsRoot
            Copy-IfExists -Path $emuleHarness.Session.StatusLogPath -DestinationRoot $artifactsRoot
        }
        Copy-IfExists -Path $agentSession.AgentLogPath -DestinationRoot $artifactsRoot

        [pscustomobject]@{
            name = "multi_file_publish_search"
            passed = $true
            probeTerm = $probeTerm
            publishedHashes = @($emuleHarnesses | ForEach-Object { $_.Link.FileHash })
            publishedNames = @($emuleHarnesses | ForEach-Object { $_.Link.FileName })
            agentSearchLine = $searchLine
        }
    }
    finally {
        if ($agentSession) {
            Stop-AgentSessionWithRestore -Session $agentSession -StopOperation $Paths.AgentStop
        }
        for ($index = $emuleHarnesses.Count - 1; $index -ge 0; $index--) {
            $emuleHarness = $emuleHarnesses[$index]
            if ($emuleHarness -and $emuleHarness.Session) {
                & $Paths.EmuleHarnessStop -SessionDir $emuleHarness.Session.SessionDir | Out-Null
            }
        }
        if ($serverSession) {
            & $Paths.ServerStop -SessionDir $serverSession.SessionDir | Out-Null
        }
    }
}

function Invoke-TestTwoEmuleHarnessSameHash {
    param(
        [string]$TestRoot,
        [hashtable]$Paths,
        [string]$EmuleHarnessBuildConfig
    )

    $serverSession = $null
    $agentSession = $null
    $emuleHarnesses = @()
    $artifactsRoot = Join-Path $TestRoot "artifacts"
    New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null

    try {
        $catalogPath = Write-CatalogFile -Path (Join-Path $TestRoot "empty-catalog.json") -Files @()
        $serverSession = & $Paths.ServerStart `
            -ScenarioRoot (Join-Path $TestRoot "server") `
            -ListenHost "127.0.0.1" `
            -TcpPort 46261 `
            -AdminPort 46280 `
            -AdminToken "local-goed2k-token" `
            -SourceCatalogPath $catalogPath

        $sharedName = "triplet-shared-source.pdf"
        $seedA = Join-Path $TestRoot "emule-harness-a\Incoming\$sharedName"
        $seedB = Join-Path $TestRoot "emule-harness-b\Incoming\$sharedName"

        $emuleHarnesses += Start-EmuleHarnessPeer `
            -ProfileScriptPath $Paths.Profile `
            -ServerMetWriterOperation $Paths.ServerMetWriter `
            -StartOperation $Paths.EmuleHarnessStart `
            -ProfileRoot (Join-Path $TestRoot "emule-harness-a") `
            -BindAddr "127.0.0.1" `
            -TcpPort 46162 `
            -UdpPort 46172 `
            -WebPort 48211 `
            -KadUdpKey 4616201 `
            -SeedFilePath $seedA `
            -SeedMarkerText "triplet shared source" `
            -SeedRepeatCount 512 `
            -ExportLinkPath (Join-Path $TestRoot "emule-harness-a\seed.ed2k") `
            -ServerHost "127.0.0.1" `
            -ServerPort 46261 `
            -EmuleHarnessBuildConfig $EmuleHarnessBuildConfig `
            -SkipRuntimeCleanup

        $emuleHarnesses += Start-EmuleHarnessPeer `
            -ProfileScriptPath $Paths.Profile `
            -ServerMetWriterOperation $Paths.ServerMetWriter `
            -StartOperation $Paths.EmuleHarnessStart `
            -ProfileRoot (Join-Path $TestRoot "emule-harness-b") `
            -BindAddr "127.0.0.1" `
            -TcpPort 46164 `
            -UdpPort 46174 `
            -WebPort 48212 `
            -KadUdpKey 4616202 `
            -SeedFilePath $seedB `
            -SeedMarkerText "triplet shared source" `
            -SeedRepeatCount 512 `
            -ExportLinkPath (Join-Path $TestRoot "emule-harness-b\seed.ed2k") `
            -ServerHost "127.0.0.1" `
            -ServerPort 46261 `
            -EmuleHarnessBuildConfig $EmuleHarnessBuildConfig `
            -SkipRuntimeCleanup

        $sharedLink = $emuleHarnesses[0].Link
        $published = Wait-GoEd2kFileState `
            -BaseUrl $serverSession.AdminBaseUrl `
            -AdminToken $serverSession.AdminToken `
            -FileHash $sharedLink.FileHash `
            -ExpectedSources 2 `
            -TimeoutSeconds 180

        $agentSession = & $Paths.AgentStart `
            -ScenarioRoot (Join-Path $TestRoot "agent") `
            -ControlPort 14321 `
            -KadPort 44140 `
            -Ed2kPort 44141 `
            -DisableKad `
            -ServerHost "127.0.0.1" `
            -ServerPort 46261 `
            -ServerSessionRotationSeconds 0 `
            -ProbeSearchTerm "triplet-shared"
        Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl -TimeoutSeconds 180

        & $Paths.AgentEnrich `
            -FileHash $sharedLink.FileHash `
            -FileName $sharedLink.FileName `
            -FileSize $sharedLink.FileSize `
            -ControlUrl $agentSession.ControlUrl | Out-Null

        $sourceLine = Wait-AgentLogPattern `
            -LogPath $agentSession.AgentLogPath `
            -Pattern "completed ED2K background source search.*source_count=2" `
            -TimeoutSeconds 90

        $manifestPath = Join-Path $agentSession.TransferRoot ($sharedLink.FileHash.ToLowerInvariant()) "resume-manifest.json"
        $manifest = Wait-TransferManifestState -ManifestPath $manifestPath -TimeoutSeconds 300
        $transfer = & $Paths.AgentCollect `
            -TransferRoot $agentSession.TransferRoot `
            -FileHash $sharedLink.FileHash `
            -DestinationRoot $artifactsRoot

        Copy-IfExists -Path $agentSession.AgentLogPath -DestinationRoot $artifactsRoot

        [pscustomobject]@{
            name = "two_oracle_same_hash"
            passed = [bool]$manifest.completed
            fileHash = $sharedLink.FileHash
            fileName = $sharedLink.FileName
            serverPublishedSources = [int]$published.sources
            agentSourceLine = $sourceLine
            transferCollected = [bool]$transfer.Completed
        }
    }
    finally {
        if ($agentSession) {
            Stop-AgentSessionWithRestore -Session $agentSession -StopOperation $Paths.AgentStop
        }
        for ($index = $emuleHarnesses.Count - 1; $index -ge 0; $index--) {
            $emuleHarness = $emuleHarnesses[$index]
            if ($emuleHarness -and $emuleHarness.Session) {
                & $Paths.EmuleHarnessStop -SessionDir $emuleHarness.Session.SessionDir | Out-Null
            }
        }
        if ($serverSession) {
            & $Paths.ServerStop -SessionDir $serverSession.SessionDir | Out-Null
        }
    }
}

function Invoke-TestLowIdCallbackFailure {
    param(
        [string]$TestRoot,
        [hashtable]$Paths
    )

    $serverSession = $null
    $agentSession = $null
    $artifactsRoot = Join-Path $TestRoot "artifacts"
    New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null

    try {
        $fileHash = "11111111111111111111111111111111"
        $fileName = "triplet-callback-only.pdf"
        $fileSize = [UInt64]131072
        $catalogPath = Write-CatalogFile -Path (Join-Path $TestRoot "callback-catalog.json") -Files @(
            [ordered]@{
                hash = $fileHash
                name = $fileName
                size = [int64]$fileSize
                file_type = "Document"
                extension = "pdf"
                sources = 1
                complete_sources = 1
                endpoints = @(
                    [ordered]@{
                        host = "1.2.3.0"
                        port = 4662
                    }
                )
            }
        )

        $serverSession = & $Paths.ServerStart `
            -ScenarioRoot (Join-Path $TestRoot "server") `
            -ListenHost "127.0.0.1" `
            -TcpPort 46361 `
            -AdminPort 46380 `
            -AdminToken "local-goed2k-token" `
            -SourceCatalogPath $catalogPath

        $agentSession = & $Paths.AgentStart `
            -ScenarioRoot (Join-Path $TestRoot "agent") `
            -ControlPort 14331 `
            -KadPort 44150 `
            -Ed2kPort 44151 `
            -DisableKad `
            -ServerHost "127.0.0.1" `
            -ServerPort 46361 `
            -ServerSessionRotationSeconds 0 `
            -ProbeSearchTerm "triplet-callback"
        Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl -TimeoutSeconds 180

        & $Paths.AgentEnrich `
            -FileHash $fileHash `
            -FileName $fileName `
            -FileSize $fileSize `
            -ControlUrl $agentSession.ControlUrl | Out-Null

        $callbackRequestLine = Wait-AgentLogPattern `
            -LogPath $agentSession.AgentLogPath `
            -Pattern "requesting server callback.*$fileHash" `
            -TimeoutSeconds 90
        $callbackFailureLine = Wait-AgentLogPattern `
            -LogPath $agentSession.AgentLogPath `
            -Pattern "server callback request failed.*$fileHash" `
            -TimeoutSeconds 90

        $stats = Invoke-GoEd2kAdminGet -BaseUrl $serverSession.AdminBaseUrl -AdminToken $serverSession.AdminToken -RelativePath "/api/stats"
        Copy-IfExists -Path $agentSession.AgentLogPath -DestinationRoot $artifactsRoot

        [pscustomobject]@{
            name = "low_id_callback_failure"
            passed = ([int64]$stats.data.callback_requests -ge 1)
            fileHash = $fileHash
            callbackRequests = [int64]$stats.data.callback_requests
            callbackRequestLine = $callbackRequestLine
            callbackFailureLine = $callbackFailureLine
            limitation = "Loopback clients always receive HighID from goed2k-server; this validates callback request and failure handling, not a real callback completion"
        }
    }
    finally {
        if ($agentSession) {
            Stop-AgentSessionWithRestore -Session $agentSession -StopOperation $Paths.AgentStop
        }
        if ($serverSession) {
            & $Paths.ServerStop -SessionDir $serverSession.SessionDir | Out-Null
        }
    }
}

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}

$paths = @{
    Profile = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"
    ServerMetWriter = { param($ServerIp, $ServerPort, $DestinationPath) Write-EmuleHarnessTargetServerMet -ServerIp $ServerIp -ServerPort $ServerPort -DestinationPath $DestinationPath }
    EmuleHarnessStart = {
        param(
            $ProfileRoot,
            $SeedFilePath,
            $ExportLinkPath,
            $AgentBootstrapNode,
            $BuildConfig,
            [switch]$SkipRuntimeCleanup
        )
        Start-EmuleHarnessPrivateEd2kSession -ProfileRoot $ProfileRoot -SeedFilePath $SeedFilePath -ExportLinkPath $ExportLinkPath -AgentBootstrapNode $AgentBootstrapNode -BuildConfig $BuildConfig -SkipRuntimeCleanup:$SkipRuntimeCleanup
    }
    EmuleHarnessStop = { param($SessionDir) Stop-EmuleHarnessParitySession -SessionDir $SessionDir }
    AgentStart = {
        param(
            $ScenarioRoot,
            $ControlPort,
            $KadPort,
            $Ed2kPort,
            [switch]$DisableKad,
            $ServerHost,
            $ServerPort,
            $ServerSessionRotationSeconds,
            $ProbeSearchTerm
        )
        Start-AgentPrivateEd2kSession -ScenarioRoot $ScenarioRoot -ControlPort $ControlPort -KadPort $KadPort -Ed2kPort $Ed2kPort -DisableKad:$DisableKad -ServerHost $ServerHost -ServerPort $ServerPort -ServerSessionRotationSeconds $ServerSessionRotationSeconds -ProbeSearchTerm $ProbeSearchTerm
    }
    AgentStop = { param($SessionDir) Stop-AgentParitySession -SessionDir $SessionDir }
    AgentEnrich = { param($FileHash, $FileName, $FileSize, $ControlUrl) Post-AgentEnrichDownload -FileHash $FileHash -FileName $FileName -FileSize $FileSize -ControlUrl $ControlUrl }
    AgentCollect = { param($TransferRoot, $FileHash, $DestinationRoot) Collect-AgentEd2kTransfer -TransferRoot $TransferRoot -FileHash $FileHash -DestinationRoot $DestinationRoot }
    ServerStart = {
        param(
            $ScenarioRoot,
            $ListenHost,
            $TcpPort,
            $AdminPort,
            $AdminToken,
            $SourceCatalogPath
        )
        Start-Goed2kPrivateSession -ScenarioRoot $ScenarioRoot -ListenHost $ListenHost -TcpPort $TcpPort -AdminPort $AdminPort -AdminToken $AdminToken -SourceCatalogPath $SourceCatalogPath
    }
    ServerStop = { param($SessionDir) Stop-Goed2kPrivateSession -SessionDir $SessionDir }
}
foreach ($requiredPath in @($paths.Profile)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required validation helper not found at $requiredPath"
    }
}

$runId = "ed2k-server-triplet-validation-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\ed2k.server.triplet.validation.v1\{0}" -f $runId)
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
$summaryPath = Join-Path $artifactRoot "run-summary.json"

$results = @()
$failed = $null

try {
    $results += Invoke-TestMultiFilePublishSearch -TestRoot (Join-Path $artifactRoot "multi-file") -Paths $paths -EmuleHarnessBuildConfig $EmuleHarnessBuildConfig
    $results += Invoke-TestTwoEmuleHarnessSameHash -TestRoot (Join-Path $artifactRoot "same-hash") -Paths $paths -EmuleHarnessBuildConfig $EmuleHarnessBuildConfig
    $results += Invoke-TestLowIdCallbackFailure -TestRoot (Join-Path $artifactRoot "callback") -Paths $paths
}
catch {
    $failed = $_.Exception.Message
    throw
}
finally {
    $summary = [ordered]@{
        schemaVersion = "triplet-validation-summary/v1"
        runId = $runId
        completed = [bool](-not $failed -and @($results | Where-Object { -not $_.passed }).Count -eq 0)
        failedReason = $failed
        results = $results
        finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM
    $summary
}

#Requires -Version 7.6
<#
.SYNOPSIS
Runs real-network Kad search and download parity passes for the eMule harness and the agent.

.DESCRIPTION
For each transport mode, this orchestration binds both runtimes to the VPN
adapter, enables UPnP, searches Kad for the same keyword, chooses one common
small result, and then drives both downloads so the resulting search and ED2K
transfer traces can be compared.
#>

[CmdletBinding()]
param(
    [string]$Query = "ebook",
    [ValidateSet("Debug", "Release")]
    [string]$EmuleHarnessBuildConfig = "Debug",
    [int]$SearchTimeoutSeconds = 240,
    [int]$DownloadTimeoutSeconds = 900,
    [int]$CandidateAttemptCount = 12,
    [int]$CandidateSourceProbeTimeoutSeconds = 60,
    [int]$SuccessfulDownloadCount = 2,
    [UInt64]$MaxCandidateSizeBytes = 16777216,
    [string]$InterfaceAlias = "hide.me",
    [switch]$KeepSessionsRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Wait-AgentControlReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 180
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

function Get-JsonObjectPropertyValue {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName,
        [Parameter(Mandatory = $false)]
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($PropertyName)) {
        return $Object[$PropertyName]
    }

    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -ne $property) {
        return $property.Value
    }

    return $DefaultValue
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
            $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
            if ([bool](Get-JsonObjectPropertyValue -Object $manifest -PropertyName "completed" -DefaultValue $false)) {
                return $manifest
            }
        }

        Start-Sleep -Seconds 2
    }

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Transfer manifest did not appear at $ManifestPath within $TimeoutSeconds seconds"
    }

    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    $verifiedRanges = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "verified_ranges" -DefaultValue @())
    $sources = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "sources" -DefaultValue @())
    throw "Transfer manifest at $ManifestPath did not complete within $TimeoutSeconds seconds (verified_ranges=$($verifiedRanges.Count) sources=$($sources.Count))"
}

function Wait-TransferManifestProbeState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,
        [int]$TimeoutSeconds = 45
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ManifestPath) {
            $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
            $manifestCompleted = [bool](Get-JsonObjectPropertyValue -Object $manifest -PropertyName "completed" -DefaultValue $false)
            $verifiedRanges = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "verified_ranges" -DefaultValue @())
            $sources = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "sources" -DefaultValue @())
            if ($manifestCompleted -or $verifiedRanges.Count -gt 0 -or $sources.Count -gt 0) {
                return $manifest
            }
        }

        Start-Sleep -Seconds 3
    }

    if (Test-Path -LiteralPath $ManifestPath) {
        return (Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json)
    }

    return $null
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

function Get-HarnessTempPartPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot,
        [Parameter(Mandatory = $true)]
        [string]$FileHash
    )

    $downloadsPath = Join-Path $ProfileRoot "config\\downloads.txt"
    if (-not (Test-Path -LiteralPath $downloadsPath)) {
        return $null
    }

    $normalizedHash = $FileHash.ToUpperInvariant()
    foreach ($line in Get-Content -LiteralPath $downloadsPath) {
        if ($line -notmatch [regex]::Escape($normalizedHash)) {
            continue
        }

        $columns = $line -split "`t", 2
        if ($columns.Count -lt 1 -or [string]::IsNullOrWhiteSpace($columns[0])) {
            continue
        }

        return (Join-Path $ProfileRoot ("Temp\\{0}" -f $columns[0].Trim()))
    }

    return $null
}

function Wait-HarnessDownloadCompleted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot,
        [Parameter(Mandatory = $true)]
        [string]$FileHash,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedName,
        [Parameter(Mandatory = $true)]
        [UInt64]$ExpectedSize,
        [int]$TimeoutSeconds = 300
    )

    $incomingPath = Join-Path $ProfileRoot ("Incoming\\{0}" -f $ExpectedName)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $incomingPath) {
            $incomingItem = Get-Item -LiteralPath $incomingPath
            if ([UInt64]$incomingItem.Length -eq $ExpectedSize) {
                return [pscustomobject]@{
                    Path = $incomingItem.FullName
                    Length = [UInt64]$incomingItem.Length
                    CompletionKind = "incoming"
                }
            }
        }

        $tempPartPath = Get-HarnessTempPartPath -ProfileRoot $ProfileRoot -FileHash $FileHash
        if ($tempPartPath -and (Test-Path -LiteralPath $tempPartPath)) {
            $tempItem = Get-Item -LiteralPath $tempPartPath
            if ([UInt64]$tempItem.Length -eq $ExpectedSize) {
                return [pscustomobject]@{
                    Path = $tempItem.FullName
                    Length = [UInt64]$tempItem.Length
                    CompletionKind = "temp-part"
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "Harness download for $FileHash did not reach size $ExpectedSize in Incoming or Temp within $TimeoutSeconds seconds"
}

function Get-LastHarnessSearchSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $snapshotLine = Get-Content -LiteralPath $Path |
        Where-Object { $_ -match '"event":"results_snapshot"' } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($snapshotLine)) {
        return $null
    }

    return ($snapshotLine | ConvertFrom-Json)
}

function Wait-HarnessSearchSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$MinimumResults = 1,
        [int]$TimeoutSeconds = 240
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $snapshot = Get-LastHarnessSearchSnapshot -Path $Path
        if ($null -ne $snapshot -and [int]$snapshot.result_count -ge $MinimumResults) {
            return $snapshot
        }

        Start-Sleep -Seconds 2
    }

    $lastSnapshot = Get-LastHarnessSearchSnapshot -Path $Path
    if ($null -ne $lastSnapshot) {
        return $lastSnapshot
    }

    throw "Harness search results were not captured at $Path within $TimeoutSeconds seconds"
}

function Get-PreferredExtensionRank {
    param(
        [string]$Name
    )

    $extension = [System.IO.Path]::GetExtension([string]$Name).ToLowerInvariant()
    switch ($extension) {
        ".pdf" { return 5 }
        ".epub" { return 5 }
        ".mobi" { return 5 }
        ".azw" { return 4 }
        ".azw3" { return 4 }
        ".djvu" { return 4 }
        ".txt" { return 3 }
        ".rtf" { return 3 }
        ".doc" { return 3 }
        ".docx" { return 3 }
        ".chm" { return 2 }
        ".lit" { return 2 }
        default { return 0 }
    }
}

function Select-CommonCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$HarnessSnapshot,
        [Parameter(Mandatory = $true)]
        [psobject]$AgentSearchSummary,
        [Parameter(Mandatory = $true)]
        [UInt64]$MaxSizeBytes,
        [int]$MaxCandidates = 5
    )

    $agentByHash = @{}
    foreach ($file in @($AgentSearchSummary.Files)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$file.Hash)) {
            $agentByHash[[string]$file.Hash] = $file
        }
    }

    $candidates = foreach ($result in @($HarnessSnapshot.results)) {
        $hash = ([string]$result.hash).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($hash)) {
            continue
        }
        if (-not $agentByHash.ContainsKey($hash)) {
            continue
        }

        $size = [UInt64]$result.size
        if ($size -eq 0 -or $size -gt $MaxSizeBytes) {
            continue
        }

        $agentFile = $agentByHash[$hash]
        $commonName = $null
        foreach ($agentName in @($agentFile.Names)) {
            if ($agentName -eq [string]$result.name) {
                $commonName = [string]$agentName
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($commonName)) {
            $commonName = if (-not [string]::IsNullOrWhiteSpace([string]$result.name)) {
                [string]$result.name
            } elseif (@($agentFile.Names).Count -gt 0) {
                [string]$agentFile.Names[0]
            } else {
                $null
            }
        }
        if ([string]::IsNullOrWhiteSpace($commonName)) {
            continue
        }

        [pscustomobject]@{
            Hash = $hash
            Name = $commonName
            Size = $size
            HarnessSourceCount = [int]$result.source_count
            HarnessCompleteSourceCount = [int]$result.complete_source_count
            AgentSourceCount = [int]$agentFile.SourceCount
            AgentBatchHits = [int]$agentFile.BatchHits
            ExtensionRank = Get-PreferredExtensionRank -Name $commonName
        }
    }

    $selected = $candidates |
        Sort-Object `
            @{ Expression = "ExtensionRank"; Descending = $true }, `
            @{ Expression = { $_.HarnessSourceCount + $_.AgentSourceCount + $_.AgentBatchHits }; Descending = $true }, `
            @{ Expression = "Size"; Descending = $false }, `
            @{ Expression = "Hash"; Descending = $false } |
        Select-Object -First $MaxCandidates

    if ($null -eq $selected -or @($selected).Count -eq 0) {
        throw "No common Kad search result matched the candidate filters"
    }

    return $selected
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

function Get-UpnpList {
    $miniupnpcPath = "C:\bin\overrides\miniupnpc.exe"
    if (-not (Test-Path -LiteralPath $miniupnpcPath -PathType Leaf)) {
        throw "miniupnpc.exe not found at $miniupnpcPath"
    }

    return (& $miniupnpcPath -l | Out-String)
}

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}
if (-not $env:OVERLORD_LOG_DIR) {
    throw "OVERLORD_LOG_DIR is not set"
}

$networkResolverPath = Join-Path $toolingRoot "helper-network-resolve-adapter.ps1"
$buildHarnessHelperPath = Join-Path $toolingRoot "helper-emule-harness-build-debug.ps1"
$selectServerHelperPath = Join-Path $toolingRoot "helper-ed2k-select-live-server.ps1"
$profileWriterPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"
$writeServerMetHelperPath = Join-Path $toolingRoot "helper-emule-harness-write-target-server-met.ps1"
$setHarnessObfuscationHelperPath = Join-Path $toolingRoot "helper-emule-harness-set-obfuscation-mode.ps1"
$setAgentObfuscationHelperPath = Join-Path $toolingRoot "helper-agent-set-obfuscation-mode.ps1"
$refreshAgentNetworkingHelperPath = Join-Path $toolingRoot "helper-agent-refresh-runtime-networking.ps1"
$startHarnessHelperPath = Join-Path $toolingRoot "helper-emule-harness-start-private-ed2k-session.ps1"
$stopHarnessHelperPath = Join-Path $toolingRoot "helper-emule-harness-stop-parity-session.ps1"
$startAgentHelperPath = Join-Path $toolingRoot "helper-agent-start-parity-session.ps1"
$stopAgentHelperPath = Join-Path $toolingRoot "helper-agent-stop-parity-session.ps1"
$agentSearchHelperPath = Join-Path $toolingRoot "helper-agent-run-kad-search.ps1"
$agentDownloadHelperPath = Join-Path $toolingRoot "helper-agent-post-enrich-download.ps1"
$collectTransferHelperPath = Join-Path $toolingRoot "helper-agent-collect-ed2k-transfer.ps1"
$nodesDatPath = Join-Path $toolingRoot ".local\emule-harness-seeds\canonical\nodes.dat"

foreach ($requiredPath in @(
    $networkResolverPath,
    $buildHarnessHelperPath,
    $selectServerHelperPath,
    $profileWriterPath,
    $writeServerMetHelperPath,
    $setHarnessObfuscationHelperPath,
    $setAgentObfuscationHelperPath,
    $refreshAgentNetworkingHelperPath,
    $startHarnessHelperPath,
    $stopHarnessHelperPath,
    $startAgentHelperPath,
    $stopAgentHelperPath,
    $agentSearchHelperPath,
    $agentDownloadHelperPath,
    $collectTransferHelperPath,
    $nodesDatPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required helper not found at $requiredPath"
    }
}

$resolvedAdapter = & $networkResolverPath -PreferredInterfaceAlias $InterfaceAlias
$selectedServer = & $selectServerHelperPath

& $buildHarnessHelperPath | Out-Null

$scenarioId = "kad.search-download.emule-harness.agent.realnet.v1"
$runId = "{0}-{1}" -f $scenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\{0}\{1}" -f $scenarioId, $runId)
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"

$runManifest = [ordered]@{
    scenarioId = $scenarioId
    runId = $runId
    query = $Query
    interfaceAlias = $resolvedAdapter.InterfaceAlias
    bindIp = $resolvedAdapter.IPAddress
    selectedServer = $selectedServer.Selected
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runManifestPath

$modeResults = [System.Collections.Generic.List[object]]::new()
$modeDefinitions = @(
    [pscustomobject]@{
        Id = "plaintext"
        HarnessMode = "PlaintextOnly"
        AgentKad = "Off"
        AgentEd2k = "Off"
    },
    [pscustomobject]@{
        Id = "obfuscated"
        HarnessMode = "ObfuscatedPreferred"
        AgentKad = "On"
        AgentEd2k = "On"
    }
)

foreach ($mode in $modeDefinitions) {
    $modeRoot = Join-Path $artifactRoot $mode.Id
    $profileRoot = Join-Path $modeRoot "emule-harness-profile"
    $harnessArtifactRoot = Join-Path $modeRoot "harness-artifacts"
    $agentArtifactRoot = Join-Path $modeRoot "agent-artifacts"
    $agentSearchRoot = Join-Path $modeRoot "agent-search"
    $harnessDownloadsRoot = Join-Path $harnessArtifactRoot "downloads"
    $agentDownloadsRoot = Join-Path $agentArtifactRoot "downloads"
    $harnessSearchPath = Join-Path $modeRoot "emule-harness-kad-search.jsonl"
    $harnessSelectedHashPath = Join-Path $modeRoot "selected-hash.txt"
    $candidateAttemptsPath = Join-Path $modeRoot "candidate-attempts.json"
    $upnpBeforePath = Join-Path $modeRoot "miniupnpc-before.txt"
    $upnpAfterPath = Join-Path $modeRoot "miniupnpc-after.txt"
    foreach ($path in @($modeRoot, $harnessArtifactRoot, $agentArtifactRoot, $agentSearchRoot, $harnessDownloadsRoot, $agentDownloadsRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $harnessSession = $null
    $agentSession = $null
    try {
        Get-UpnpList | Set-Content -Encoding utf8NoBOM $upnpBeforePath

        $profile = & $profileWriterPath `
            -ProfileRoot $profileRoot `
            -BindAddr $resolvedAdapter.IPAddress `
            -TcpPort 46671 `
            -UdpPort 46673 `
            -ServerUdpPort 46675 `
            -WebPort 47101 `
            -EnableKademlia $true `
            -EnableEd2k $true `
            -EnableUpnp $true `
            -ResetTransientState

        Copy-Item -LiteralPath $nodesDatPath -Destination (Join-Path $profileRoot "config\nodes.dat") -Force
        & $writeServerMetHelperPath `
            -ServerIp $selectedServer.Host `
            -ServerPort $selectedServer.Port `
            -UdpFlags $selectedServer.UdpFlags `
            -UdpKey $selectedServer.UdpKey `
            -UdpKeyIp $selectedServer.UdpKeyIp `
            -TcpObfuscationPort $selectedServer.TcpObfuscationPort `
            -UdpObfuscationPort $selectedServer.UdpObfuscationPort `
            -DestinationPath (Join-Path $profileRoot "config\server.met") | Out-Null
        & $setHarnessObfuscationHelperPath -Mode $mode.HarnessMode -ProfileRoot $profileRoot | Out-Null

        $agentNetworking = & $refreshAgentNetworkingHelperPath -InterfaceAlias $resolvedAdapter.InterfaceAlias
        & $setAgentObfuscationHelperPath `
            -Kad $mode.AgentKad `
            -Ed2k $mode.AgentEd2k `
            -ConfigPath $agentNetworking.TempConfigPath | Out-Null

        $harnessSession = & $startHarnessHelperPath `
            -ProfileRoot $profileRoot `
            -SearchTerm $Query `
            -SearchResultsPath $harnessSearchPath `
            -SearchDownloadHashPath $harnessSelectedHashPath `
            -BuildConfig $EmuleHarnessBuildConfig

        Get-UpnpList | Set-Content -Encoding utf8NoBOM $upnpAfterPath

        $agentSession = & $startAgentHelperPath `
            -InterfaceAlias $resolvedAdapter.InterfaceAlias `
            -ServerIp $selectedServer.Host `
            -ServerPort $selectedServer.Port `
            -ServerUdpFlags $selectedServer.UdpFlags `
            -ServerUdpKey $selectedServer.UdpKey `
            -ServerUdpKeyIp $selectedServer.UdpKeyIp `
            -ServerTcpObfuscationPort $selectedServer.TcpObfuscationPort `
            -ServerUdpObfuscationPort $selectedServer.UdpObfuscationPort

        Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl | Out-Null

        $agentSearchSummary = & $agentSearchHelperPath `
            -Query $Query `
            -ControlUrl $agentSession.ControlUrl `
            -OutputRoot $agentSearchRoot `
            -TimeoutSeconds $SearchTimeoutSeconds
        $harnessSnapshot = Wait-HarnessSearchSnapshot `
            -Path $harnessSearchPath `
            -MinimumResults 1 `
            -TimeoutSeconds $SearchTimeoutSeconds

        $candidateList = Select-CommonCandidates `
            -HarnessSnapshot $harnessSnapshot `
            -AgentSearchSummary $agentSearchSummary `
            -MaxSizeBytes $MaxCandidateSizeBytes `
            -MaxCandidates $CandidateAttemptCount

        $candidateAttempts = [System.Collections.Generic.List[object]]::new()
        $completedDownloads = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in @($candidateList)) {
            $agentTransferDir = Join-Path $agentSession.TransferRoot $candidate.Hash.ToLowerInvariant()
            if (Test-Path -LiteralPath $agentTransferDir) {
                Remove-Item -LiteralPath $agentTransferDir -Recurse -Force
            }

            & $agentDownloadHelperPath `
                -FileHash $candidate.Hash `
                -FileName $candidate.Name `
                -FileSize ([UInt64]$candidate.Size) `
                -ControlUrl $agentSession.ControlUrl | Out-Null

            $probeManifestPath = Join-Path $agentTransferDir "resume-manifest.json"
            $probeManifest = Wait-TransferManifestProbeState `
                -ManifestPath $probeManifestPath `
                -TimeoutSeconds $CandidateSourceProbeTimeoutSeconds

            $attempt = [pscustomobject]@{
                Hash = $candidate.Hash
                Name = $candidate.Name
                Size = [UInt64]$candidate.Size
                HarnessSourceCount = [int]$candidate.HarnessSourceCount
                HarnessCompleteSourceCount = [int]$candidate.HarnessCompleteSourceCount
                AgentSourceCount = [int]$candidate.AgentSourceCount
                AgentBatchHits = [int]$candidate.AgentBatchHits
                ProbeManifestPath = $probeManifestPath
                ProbeSources = if ($null -ne $probeManifest) { @(Get-JsonObjectPropertyValue -Object $probeManifest -PropertyName "sources" -DefaultValue @()).Count } else { 0 }
                ProbeCompleted = if ($null -ne $probeManifest) { [bool](Get-JsonObjectPropertyValue -Object $probeManifest -PropertyName "completed" -DefaultValue $false) } else { $false }
                ProbeVerifiedRanges = if ($null -ne $probeManifest) { @(Get-JsonObjectPropertyValue -Object $probeManifest -PropertyName "verified_ranges" -DefaultValue @()).Count } else { 0 }
                DownloadSucceeded = $false
                DownloadError = $null
            }

            if ($attempt.ProbeSources -gt 0 -or $attempt.ProbeCompleted -or $attempt.ProbeVerifiedRanges -gt 0) {
                try {
                    Set-Content -LiteralPath $harnessSelectedHashPath -Value $candidate.Hash -Encoding ascii
                    $agentTransferManifest = Wait-TransferManifestState `
                        -ManifestPath $probeManifestPath `
                        -TimeoutSeconds $DownloadTimeoutSeconds

                    $harnessDownloadState = Wait-HarnessDownloadCompleted `
                        -ProfileRoot $profileRoot `
                        -FileHash $candidate.Hash `
                        -ExpectedName $candidate.Name `
                        -ExpectedSize ([UInt64]$candidate.Size) `
                        -TimeoutSeconds $DownloadTimeoutSeconds

                    $candidateAgentArtifactRoot = Join-Path $agentDownloadsRoot $candidate.Hash.ToLowerInvariant()
                    New-Item -ItemType Directory -Path $candidateAgentArtifactRoot -Force | Out-Null
                    $transferCollection = & $collectTransferHelperPath `
                        -TransferRoot $agentSession.TransferRoot `
                        -FileHash $candidate.Hash `
                        -DestinationRoot $candidateAgentArtifactRoot

                    $candidateHarnessArtifactRoot = Join-Path $harnessDownloadsRoot $candidate.Hash.ToLowerInvariant()
                    New-Item -ItemType Directory -Path $candidateHarnessArtifactRoot -Force | Out-Null
                    Copy-Item -LiteralPath $harnessDownloadState.Path -Destination (Join-Path $candidateHarnessArtifactRoot $candidate.Name) -Force

                    $attempt = [pscustomobject]@{
                        Hash = $attempt.Hash
                        Name = $attempt.Name
                        Size = $attempt.Size
                        HarnessSourceCount = $attempt.HarnessSourceCount
                        HarnessCompleteSourceCount = $attempt.HarnessCompleteSourceCount
                        AgentSourceCount = $attempt.AgentSourceCount
                        AgentBatchHits = $attempt.AgentBatchHits
                        ProbeManifestPath = $attempt.ProbeManifestPath
                        ProbeSources = $attempt.ProbeSources
                        ProbeCompleted = $attempt.ProbeCompleted
                        ProbeVerifiedRanges = $attempt.ProbeVerifiedRanges
                        DownloadSucceeded = $true
                        DownloadError = $null
                        HarnessDownloadedPath = $harnessDownloadState.Path
                        HarnessDownloadedSize = [UInt64]$harnessDownloadState.Length
                        HarnessCompletionKind = $harnessDownloadState.CompletionKind
                        AgentTransferManifestPath = $probeManifestPath
                        AgentTransferCompleted = [bool](Get-JsonObjectPropertyValue -Object $agentTransferManifest -PropertyName "completed" -DefaultValue $false)
                        AgentTransferCollectedRoot = $transferCollection.DestinationRoot
                    }

                    $completedDownloads.Add([pscustomobject]@{
                        Hash = $candidate.Hash
                        Name = $candidate.Name
                        Size = [UInt64]$candidate.Size
                        HarnessDownloadedPath = $harnessDownloadState.Path
                        HarnessDownloadedSize = [UInt64]$harnessDownloadState.Length
                        HarnessCompletionKind = $harnessDownloadState.CompletionKind
                        AgentTransferManifestPath = $probeManifestPath
                        AgentTransferCompleted = [bool](Get-JsonObjectPropertyValue -Object $agentTransferManifest -PropertyName "completed" -DefaultValue $false)
                        AgentTransferCollectedRoot = $transferCollection.DestinationRoot
                    }) | Out-Null

                    if ($completedDownloads.Count -ge $SuccessfulDownloadCount) {
                        $candidateAttempts.Add($attempt) | Out-Null
                        break
                    }
                }
                catch {
                    $attempt = [pscustomobject]@{
                        Hash = $attempt.Hash
                        Name = $attempt.Name
                        Size = $attempt.Size
                        HarnessSourceCount = $attempt.HarnessSourceCount
                        HarnessCompleteSourceCount = $attempt.HarnessCompleteSourceCount
                        AgentSourceCount = $attempt.AgentSourceCount
                        AgentBatchHits = $attempt.AgentBatchHits
                        ProbeManifestPath = $attempt.ProbeManifestPath
                        ProbeSources = $attempt.ProbeSources
                        ProbeCompleted = $attempt.ProbeCompleted
                        ProbeVerifiedRanges = $attempt.ProbeVerifiedRanges
                        DownloadSucceeded = $false
                        DownloadError = $_.Exception.Message
                    }
                }
            }

            $candidateAttempts.Add($attempt) | Out-Null
        }
        @($candidateAttempts) | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8NoBOM $candidateAttemptsPath

        if ($completedDownloads.Count -lt $SuccessfulDownloadCount) {
            throw "Only $($completedDownloads.Count) common Kad results completed download in mode '$($mode.Id)' within $CandidateAttemptCount attempts. See $candidateAttemptsPath"
        }

        if (-not $KeepSessionsRunning) {
            if ($harnessSession) {
                & $stopHarnessHelperPath -SessionDir $harnessSession.SessionDir | Out-Null
            }
            if ($agentSession) {
                & $stopAgentHelperPath -SessionDir $agentSession.SessionDir | Out-Null
            }
        }

        foreach ($path in @(
            $harnessSearchPath,
            $harnessSession.TraceLogPath,
            $harnessSession.VerboseLogPath,
            $harnessSession.StatusLogPath,
            $harnessSession.EmuleHarnessUdpDumpPath,
            $harnessSession.EmuleHarnessEd2kTcpDumpPath,
            $upnpBeforePath,
            $upnpAfterPath
        )) {
            Copy-IfExists -Path $path -DestinationRoot $harnessArtifactRoot
        }
        foreach ($path in @(
            $agentSearchSummary.RawResultsPath,
            $agentSearchSummary.RawEventsPath,
            $agentSearchSummary.SummaryPath,
            $agentSession.AgentLogPath,
            $agentSession.PacketDumpPath
        )) {
            Copy-IfExists -Path $path -DestinationRoot $agentArtifactRoot
        }

        $modeResults.Add([pscustomobject]@{
            Mode = $mode.Id
            Success = $true
            Query = $Query
            SuccessfulDownloadCount = $SuccessfulDownloadCount
            CompletedDownloadCount = $completedDownloads.Count
            CompletedDownloads = @($completedDownloads)
            CandidateAttemptsPath = $candidateAttemptsPath
            HarnessReadyState = $harnessSession.EmuleHarnessReadyState
            AgentControlUrl = $agentSession.ControlUrl
            AgentSearchStatus = $agentSearchSummary.Status
            HarnessSearchResultCount = [int]$harnessSnapshot.result_count
            AgentSearchResultCount = [int]$agentSearchSummary.ResultCount
            HarnessArtifactsRoot = $harnessArtifactRoot
            AgentArtifactsRoot = $agentArtifactRoot
        }) | Out-Null
    }
    catch {
        $modeResults.Add([pscustomobject]@{
            Mode = $mode.Id
            Success = $false
            Query = $Query
            Error = $_.Exception.Message
            HarnessSessionDir = if ($harnessSession) { $harnessSession.SessionDir } else { $null }
            AgentSessionDir = if ($agentSession) { $agentSession.SessionDir } else { $null }
            CandidateAttemptsPath = if (Test-Path -LiteralPath $candidateAttemptsPath) { $candidateAttemptsPath } else { $null }
            HarnessArtifactsRoot = $harnessArtifactRoot
            AgentArtifactsRoot = $agentArtifactRoot
        }) | Out-Null
    }
    finally {
        if (-not $KeepSessionsRunning) {
            if ($harnessSession) {
                try {
                    & $stopHarnessHelperPath -SessionDir $harnessSession.SessionDir | Out-Null
                }
                catch {
                }
            }
            if ($agentSession) {
                try {
                    & $stopAgentHelperPath -SessionDir $agentSession.SessionDir | Out-Null
                }
                catch {
                }
            }
        }
    }
}

$summary = [pscustomobject]@{
    ScenarioId = $scenarioId
    RunId = $runId
    Query = $Query
    InterfaceAlias = $resolvedAdapter.InterfaceAlias
    BindIp = $resolvedAdapter.IPAddress
    SelectedServer = $selectedServer
    Modes = @($modeResults)
    StartedAtUtc = $runManifest.startedAtUtc
    CompletedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8NoBOM $runSummaryPath

if (@($modeResults | Where-Object { -not $_.Success }).Count -gt 0) {
    throw "One or more realnet Kad search/download parity modes failed. See $runSummaryPath"
}

$summary

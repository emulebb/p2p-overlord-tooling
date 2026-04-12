#Requires -Version 7.6
<#
.SYNOPSIS
Runs a detached long-run agent soak session and records health samples.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Load-SessionMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Session metadata not found at $Path"
    }

    return Get-Content -Raw $Path | ConvertFrom-Json -AsHashtable
}

function Save-SessionMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [hashtable]$Metadata
    )

    $Metadata | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8NoBOM
}

function Get-AgentProcesses {
    @(Get-Process -Name "overlord-agent-emule" -ErrorAction SilentlyContinue)
}

function Get-CoordinatorProcesses {
    @(
        Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*node_modules\\vite\\bin\\vite.js*' }
    )
}

function Get-UpnpMappingState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BindIp,
        [int]$UdpPort = 41000,
        [int]$TcpPort = 41001
    )

    $miniupnpcPath = "C:\bin\overrides\miniupnpc.exe"
    if (-not (Test-Path $miniupnpcPath)) {
        return [ordered]@{
            available = $false
            command_error = "miniupnpc.exe not found"
            external_ip = $null
            udp_present = $false
            tcp_present = $false
            raw_output = $null
        }
    }

    try {
        $rawOutput = & $miniupnpcPath -l 2>&1 | Out-String
    } catch {
        return [ordered]@{
            available = $true
            command_error = $_.Exception.Message
            external_ip = $null
            udp_present = $false
            tcp_present = $false
            raw_output = $null
        }
    }

    $externalIp = $null
    foreach ($line in ($rawOutput -split "`r?`n")) {
        if ($line -match '^ExternalIPAddress\s*=\s*(.+)$') {
            $externalIp = $Matches[1].Trim()
            break
        }
    }

    $udpPresent = $false
    $tcpPresent = $false
    $escapedBindIp = [regex]::Escape($BindIp)
    $udpPattern = "^\s*\d+\s+udp\s+\d+->${escapedBindIp}:$UdpPort\b"
    $tcpPattern = "^\s*\d+\s+tcp\s+\d+->${escapedBindIp}:$TcpPort\b"
    foreach ($line in ($rawOutput -split "`r?`n")) {
        if (-not $udpPresent -and $line -match $udpPattern) {
            $udpPresent = $true
        }
        if (-not $tcpPresent -and $line -match $tcpPattern) {
            $tcpPresent = $true
        }
    }

    [ordered]@{
        available = $true
        command_error = $null
        external_ip = $externalIp
        udp_present = $udpPresent
        tcp_present = $tcpPresent
        raw_output = $rawOutput.TrimEnd()
    }
}

function Invoke-StatsQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl
    )

    Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
}

function Wait-ForStats {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [Parameter(Mandatory = $true)]
        [datetime]$DeadlineUtc
    )

    while ((Get-Date).ToUniversalTime() -lt $DeadlineUtc) {
        try {
            return Invoke-StatsQuery -StatsUrl $StatsUrl
        } catch {
            Start-Sleep -Seconds 5
        }
    }

    throw "Agent stats endpoint at $StatsUrl did not become reachable before the startup deadline"
}

function New-SampleRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$SampledAtUtc,
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [Parameter(Mandatory = $true)]
        [string]$BindIp
    )

    $stats = $null
    $queryError = $null
    try {
        $stats = Invoke-StatsQuery -StatsUrl $StatsUrl
    } catch {
        $queryError = $_.Exception.Message
    }

    $nat = Get-UpnpMappingState -BindIp $BindIp
    $keywordBatch = $null
    $sourceBatch = $null
    if ($stats) {
        $keywordBatch = $stats.publish_observability.latest_keyword_batch
        $sourceBatch = $stats.publish_observability.latest_source_batch
    }

    [ordered]@{
        sampled_at = $SampledAtUtc.ToString("o")
        stats_reachable = ($null -ne $stats)
        stats_error = $queryError
        uptime_secs = if ($stats) { $stats.uptime_secs } else { $null }
        peers_connected = if ($stats) { $stats.peers_connected } else { $null }
        keyword_seen = if ($stats) { $stats.harvest_observability.keyword_requests.observed_requests } else { $null }
        source_seen = if ($stats) { $stats.harvest_observability.source_requests.observed_requests } else { $null }
        notes_seen = if ($stats) { $stats.harvest_observability.notes_requests.observed_requests } else { $null }
        snoop_queue_depth = if ($stats) { $stats.snoop_queue_depth } else { $null }
        passive_keyword_completed = if ($stats) { $stats.harvest_observability.passive_keyword_replay.completed_cycles } else { $null }
        passive_source_started = if ($stats) { $stats.harvest_observability.passive_source_replay.started_cycles } else { $null }
        passive_source_completed = if ($stats) { $stats.harvest_observability.passive_source_replay.completed_cycles } else { $null }
        passive_source_results = if ($stats) { $stats.harvest_observability.passive_source_replay.emitted_results } else { $null }
        passive_source_batches = if ($stats) { $stats.harvest_observability.passive_source_replay.posted_batches } else { $null }
        source_unique_shapes = if ($stats) { $stats.harvest_observability.source_requests.unique_shapes_observed } else { $null }
        source_queue_depth = if ($stats) { $stats.harvest_observability.source_requests.queued_entries } else { $null }
        keyword_acked = if ($keywordBatch) { $keywordBatch.acked_contacts } else { $null }
        source_acked = if ($sourceBatch) { $sourceBatch.acked_contacts } else { $null }
        nat_external_ip = $nat.external_ip
        nat_udp_41000_present = $nat.udp_present
        nat_tcp_41001_present = $nat.tcp_present
        nat_available = $nat.available
        nat_error = $nat.command_error
        stats = $stats
    }
}

function Append-JsonLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Record
    )

    ($Record | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path $Path -Encoding utf8
}

function Stop-StartedSessionProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Metadata
    )

    if (($Metadata.StartedAgentPids | Measure-Object).Count -gt 0) {
        foreach ($startedAgentPid in @($Metadata.StartedAgentPids)) {
            Stop-Process -Id $startedAgentPid -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($startedCoordinatorPid in @($Metadata.StartedCoordinatorPids)) {
        Stop-Process -Id $startedCoordinatorPid -Force -ErrorAction SilentlyContinue
    }
}

$metadataPath = Join-Path $SessionDir "soak-session.json"
$metadata = Load-SessionMetadata -Path $metadataPath
$refreshScriptPath = Join-Path $PSScriptRoot "helper-agent-refresh-runtime-networking.ps1"
$summaryScriptPath = Join-Path $PSScriptRoot "helper-agent-summarize-soak-session.ps1"
$launchHelperPath = Join-Path $PSScriptRoot "helper-agent-launch-debug.ps1"
$startCoordinatorPath = Join-Path $metadata.ProjectDir "p2p-overlord-be\overlord-be-coordinator\scripts\windows\coordinator_run_start_direct.cmd"
$agentLogPath = Join-Path $metadata.LogDir "overlord-agent-emule.log"

try {
    $metadata.WorkerStatus = "initializing"
    $metadata.AgentLogPath = $agentLogPath
    $metadata.AgentLogLinesBefore = if (Test-Path $agentLogPath) { @(Get-Content $agentLogPath).Count } else { 0 }
    $metadata.PreexistingAgentPids = @(Get-AgentProcesses | ForEach-Object { $_.Id })
    $metadata.PreexistingCoordinatorPids = @(Get-CoordinatorProcesses | ForEach-Object { $_.ProcessId })
    Save-SessionMetadata -Path $metadataPath -Metadata $metadata

    if (-not (Test-Path $refreshScriptPath)) {
        throw "Networking refresh helper not found at $refreshScriptPath"
    }
    $refresh = & $refreshScriptPath
    $metadata.NetworkingRefresh = $refresh
    Save-SessionMetadata -Path $metadataPath -Metadata $metadata

    if (($metadata.PreexistingCoordinatorPids | Measure-Object).Count -eq 0) {
        if (-not (Test-Path $startCoordinatorPath)) {
            throw "Coordinator start script not found at $startCoordinatorPath"
        }

        Start-Process `
            -FilePath "cmd.exe" `
            -ArgumentList "/c", $startCoordinatorPath `
            -WorkingDirectory $metadata.ProjectDir `
            -WindowStyle Hidden | Out-Null

        Start-Sleep -Seconds 5
        $metadata.StartedCoordinatorPids = @(
            Get-CoordinatorProcesses |
                Where-Object { $_.ProcessId -notin $metadata.PreexistingCoordinatorPids } |
                ForEach-Object { $_.ProcessId }
        )
        if (($metadata.StartedCoordinatorPids | Measure-Object).Count -eq 0) {
            throw "Coordinator process did not start — no new node/vite processes found after launch"
        }
        Save-SessionMetadata -Path $metadataPath -Metadata $metadata
    }

    if (($metadata.PreexistingAgentPids | Measure-Object).Count -eq 0) {
        if (-not (Test-Path $launchHelperPath)) {
            throw "Agent launch helper not found at $launchHelperPath"
        }

        $launchResult = & $launchHelperPath
        $agentProcess = Get-Process -Id $launchResult.AgentPid -ErrorAction SilentlyContinue
        if (-not $agentProcess) {
            throw "Agent process overlord-agent-emule.exe (PID $($launchResult.AgentPid)) is not running after launch"
        }
        $metadata.StartedAgentPids = @($launchResult.AgentPid)
        Save-SessionMetadata -Path $metadataPath -Metadata $metadata
    }

    $metadata.WorkerStatus = "sampling"
    Save-SessionMetadata -Path $metadataPath -Metadata $metadata

    $null = Wait-ForStats `
        -StatsUrl $metadata.StatsUrl `
        -DeadlineUtc ((Get-Date).ToUniversalTime().AddMinutes(10))

    $deadlineUtc = (Get-Date).ToUniversalTime().AddMinutes([double]$metadata.DurationMinutes)
    while ((Get-Date).ToUniversalTime() -lt $deadlineUtc) {
        if (Test-Path $metadata.StopRequestPath) {
            $metadata.StopRequested = $true
            if (-not $metadata.StopRequestedAtUtc) {
                $metadata.StopRequestedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            }
            Save-SessionMetadata -Path $metadataPath -Metadata $metadata
            break
        }

        $sampleRecord = New-SampleRecord `
            -SampledAtUtc ((Get-Date).ToUniversalTime()) `
            -StatsUrl $metadata.StatsUrl `
            -BindIp $refresh.ResolvedP2pBindIp
        Append-JsonLine -Path $metadata.StatsSamplesPath -Record $sampleRecord

        [pscustomobject]@{
            sampled_at = $sampleRecord.sampled_at
            uptime_secs = $sampleRecord.uptime_secs
            peers_connected = $sampleRecord.peers_connected
            source_seen = $sampleRecord.source_seen
            passive_source_completed = $sampleRecord.passive_source_completed
            passive_source_results = $sampleRecord.passive_source_results
            source_queue_depth = $sampleRecord.source_queue_depth
            nat_udp_41000_present = $sampleRecord.nat_udp_41000_present
            nat_tcp_41001_present = $sampleRecord.nat_tcp_41001_present
        } | ConvertTo-Json -Compress

        $sleepUntilUtc = (Get-Date).ToUniversalTime().AddSeconds([double]$metadata.SampleIntervalSeconds)
        while ((Get-Date).ToUniversalTime() -lt $sleepUntilUtc) {
            if (Test-Path $metadata.StopRequestPath) {
                $metadata.StopRequested = $true
                if (-not $metadata.StopRequestedAtUtc) {
                    $metadata.StopRequestedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
                }
                Save-SessionMetadata -Path $metadataPath -Metadata $metadata
                break
            }
            Start-Sleep -Seconds 5
        }

        if ($metadata.StopRequested) {
            break
        }
    }

    try {
        $finalStats = Invoke-StatsQuery -StatsUrl $metadata.StatsUrl
        $finalStats | ConvertTo-Json -Depth 10 | Set-Content -Path $metadata.FinalStatsPath -Encoding utf8NoBOM
    } catch {
        [ordered]@{
            captured_at = (Get-Date).ToUniversalTime().ToString("o")
            error = $_.Exception.Message
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $metadata.FinalStatsPath -Encoding utf8NoBOM
    }

    $metadata.WorkerStatus = "completed"
    $metadata.WorkerCompletedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    Save-SessionMetadata -Path $metadataPath -Metadata $metadata

    Stop-StartedSessionProcesses -Metadata $metadata
    if (Test-Path $summaryScriptPath) {
        & $summaryScriptPath -SessionDir $SessionDir | Out-Null
    }
} catch {
    $metadata.WorkerError = $_.Exception.ToString()
    $metadata.WorkerStatus = "failed"
    $metadata.WorkerCompletedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    Save-SessionMetadata -Path $metadataPath -Metadata $metadata

    try {
        Stop-StartedSessionProcesses -Metadata $metadata
    } catch {
    }

    if (Test-Path $summaryScriptPath) {
        try {
            & $summaryScriptPath -SessionDir $SessionDir | Out-Null
        } catch {
        }
    }

    throw
} finally {
    if (-not $metadata.WorkerCompletedAtUtc) {
        $metadata.WorkerCompletedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    Save-SessionMetadata -Path $metadataPath -Metadata $metadata
}

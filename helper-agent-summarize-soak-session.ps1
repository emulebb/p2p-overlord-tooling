<#
.SYNOPSIS
Builds a health summary for a long-run agent soak session.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-OptionalNumberDelta {
    param(
        [object]$Start,
        [object]$End
    )

    if ($null -eq $Start -or $null -eq $End) {
        return $null
    }

    return ([double]$End) - ([double]$Start)
}

function Get-AgentLogIssues {
    param(
        [string]$AgentLogPath,
        [int]$LinesBefore
    )

    if (-not $AgentLogPath -or -not (Test-Path $AgentLogPath)) {
        return [ordered]@{
            unexpected_shutdown = $false
            console_close = $false
            matching_lines = @()
        }
    }

    $newLines = @(Get-Content $AgentLogPath | Select-Object -Skip $LinesBefore)
    $matchingLines = @(
        $newLines |
            Where-Object {
                $_ -match 'shutdown signal received' -or
                $_ -match 'ConsoleClose'
            }
    )

    [ordered]@{
        unexpected_shutdown = (($matchingLines | Measure-Object).Count -gt 0)
        console_close = (($matchingLines | Where-Object { $_ -match 'ConsoleClose' } | Measure-Object).Count -gt 0)
        matching_lines = $matchingLines
    }
}

$metadataPath = Join-Path $SessionDir "soak-session.json"
if (-not (Test-Path $metadataPath)) {
    throw "Session metadata not found at $metadataPath"
}

$metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json -AsHashtable
$sampleRecords = @()
if (Test-Path $metadata.StatsSamplesPath) {
    $sampleRecords = @(
        Get-Content $metadata.StatsSamplesPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
}

$reachableSamples = @($sampleRecords | Where-Object { $_.stats_reachable })
$firstReachable = $reachableSamples | Select-Object -First 1
$lastReachable = $reachableSamples | Select-Object -Last 1
$elapsedMinutes = if ($firstReachable -and $lastReachable) {
    [math]::Round((New-TimeSpan -Start ([datetime]$firstReachable.sampled_at) -End ([datetime]$lastReachable.sampled_at)).TotalMinutes, 2)
} else {
    0
}

$queueSeries = @(
    $reachableSamples |
        Where-Object { $null -ne $_.source_queue_depth } |
        ForEach-Object { [double]$_.source_queue_depth }
)
$queueMonotonicRise = $false
if ($queueSeries.Count -gt 1) {
    $queueMonotonicRise = $true
    for ($i = 1; $i -lt $queueSeries.Count; $i++) {
        if ($queueSeries[$i] -lt $queueSeries[$i - 1]) {
            $queueMonotonicRise = $false
            break
        }
    }
    if ($queueSeries[$queueSeries.Count - 1] -le $queueSeries[0]) {
        $queueMonotonicRise = $false
    }
}

$uptimeReset = $false
$uptimeSeries = @(
    $reachableSamples |
        Where-Object { $null -ne $_.uptime_secs } |
        ForEach-Object { [double]$_.uptime_secs }
)
if ($uptimeSeries.Count -gt 1) {
    for ($i = 1; $i -lt $uptimeSeries.Count; $i++) {
        if ($uptimeSeries[$i] -lt $uptimeSeries[$i - 1]) {
            $uptimeReset = $true
            break
        }
    }
}

$logIssues = Get-AgentLogIssues `
    -AgentLogPath $metadata.AgentLogPath `
    -LinesBefore ([int]$metadata.AgentLogLinesBefore)

$status = "healthy"
$reasons = New-Object System.Collections.Generic.List[string]

if ($metadata.WorkerStatus -eq "failed" -or $metadata.WorkerError) {
    $status = "failed"
    $reasons.Add("worker_failed")
}
if (($sampleRecords | Measure-Object).Count -eq 0) {
    $status = "failed"
    $reasons.Add("no_samples")
}
if (($reachableSamples | Measure-Object).Count -eq 0) {
    $status = "failed"
    $reasons.Add("stats_unreachable")
}
if ($uptimeReset) {
    $status = "failed"
    $reasons.Add("uptime_reset")
}
if ($logIssues.unexpected_shutdown) {
    $status = "failed"
    $reasons.Add("unexpected_shutdown")
}

$sourceSeenDelta = if ($firstReachable -and $lastReachable) {
    Get-OptionalNumberDelta -Start $firstReachable.source_seen -End $lastReachable.source_seen
} else {
    $null
}
$passiveCompletedDelta = if ($firstReachable -and $lastReachable) {
    Get-OptionalNumberDelta -Start $firstReachable.passive_source_completed -End $lastReachable.passive_source_completed
} else {
    $null
}
$passiveResultsDelta = if ($firstReachable -and $lastReachable) {
    Get-OptionalNumberDelta -Start $firstReachable.passive_source_results -End $lastReachable.passive_source_results
} else {
    $null
}

if ($status -ne "failed") {
    if ($queueMonotonicRise -and (($passiveCompletedDelta ?? 0) -le 0) -and (($passiveResultsDelta ?? 0) -le 0)) {
        $status = "degraded"
        $reasons.Add("queue_growth_without_source_progress")
    }
    if ($lastReachable -and (-not $lastReachable.nat_udp_41000_present -or -not $lastReachable.nat_tcp_41001_present)) {
        $status = "degraded"
        $reasons.Add("nat_mapping_missing_at_end")
    }
    if (($sourceSeenDelta ?? 0) -le 0 -and (($passiveCompletedDelta ?? 0) -le 0) -and (($passiveResultsDelta ?? 0) -le 0)) {
        $status = "degraded"
        $reasons.Add("no_harvest_progress")
    }
}

$summary = [ordered]@{
    session_dir = $SessionDir
    session_name = $metadata.SessionName
    status = $status
    reasons = @($reasons)
    started_at_utc = $metadata.StartedAtUtc
    worker_started_at_utc = $metadata.WorkerStartedAtUtc
    worker_completed_at_utc = $metadata.WorkerCompletedAtUtc
    duration_minutes_target = $metadata.DurationMinutes
    sample_interval_seconds = $metadata.SampleIntervalSeconds
    sample_count = ($sampleRecords | Measure-Object).Count
    stats_reachable_samples = ($reachableSamples | Measure-Object).Count
    elapsed_minutes_between_reachable_samples = $elapsedMinutes
    uptime_reset = $uptimeReset
    unexpected_shutdown = $logIssues.unexpected_shutdown
    console_close_shutdown = $logIssues.console_close
    peers_connected = [ordered]@{
        first = if ($firstReachable) { $firstReachable.peers_connected } else { $null }
        last = if ($lastReachable) { $lastReachable.peers_connected } else { $null }
        min = if ($reachableSamples) { ($reachableSamples | Measure-Object -Property peers_connected -Minimum).Minimum } else { $null }
        max = if ($reachableSamples) { ($reachableSamples | Measure-Object -Property peers_connected -Maximum).Maximum } else { $null }
    }
    source_requests = [ordered]@{
        observed_delta = $sourceSeenDelta
        unique_shapes_delta = if ($firstReachable -and $lastReachable) { Get-OptionalNumberDelta -Start $firstReachable.source_unique_shapes -End $lastReachable.source_unique_shapes } else { $null }
        queued_first = if ($firstReachable) { $firstReachable.source_queue_depth } else { $null }
        queued_last = if ($lastReachable) { $lastReachable.source_queue_depth } else { $null }
        queued_max = if ($reachableSamples) { ($reachableSamples | Measure-Object -Property source_queue_depth -Maximum).Maximum } else { $null }
        queued_monotonic_rise = $queueMonotonicRise
    }
    passive_source_replay = [ordered]@{
        started_delta = if ($firstReachable -and $lastReachable) { Get-OptionalNumberDelta -Start $firstReachable.passive_source_started -End $lastReachable.passive_source_started } else { $null }
        completed_delta = $passiveCompletedDelta
        emitted_results_delta = $passiveResultsDelta
        posted_batches_delta = if ($firstReachable -and $lastReachable) { Get-OptionalNumberDelta -Start $firstReachable.passive_source_batches -End $lastReachable.passive_source_batches } else { $null }
    }
    publish = [ordered]@{
        keyword_acked_delta = if ($firstReachable -and $lastReachable) { Get-OptionalNumberDelta -Start $firstReachable.keyword_acked -End $lastReachable.keyword_acked } else { $null }
        source_acked_delta = if ($firstReachable -and $lastReachable) { Get-OptionalNumberDelta -Start $firstReachable.source_acked -End $lastReachable.source_acked } else { $null }
    }
    nat = [ordered]@{
        first_udp_41000_present = if ($firstReachable) { $firstReachable.nat_udp_41000_present } else { $null }
        first_tcp_41001_present = if ($firstReachable) { $firstReachable.nat_tcp_41001_present } else { $null }
        last_udp_41000_present = if ($lastReachable) { $lastReachable.nat_udp_41000_present } else { $null }
        last_tcp_41001_present = if ($lastReachable) { $lastReachable.nat_tcp_41001_present } else { $null }
        external_ip_first = if ($firstReachable) { $firstReachable.nat_external_ip } else { $null }
        external_ip_last = if ($lastReachable) { $lastReachable.nat_external_ip } else { $null }
    }
    log_issues = $logIssues
    worker_status = $metadata.WorkerStatus
    worker_error = $metadata.WorkerError
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $metadata.SummaryPath -Encoding utf8NoBOM
$summary

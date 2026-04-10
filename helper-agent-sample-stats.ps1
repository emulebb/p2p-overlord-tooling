#Requires -Version 7.6
<#
.SYNOPSIS
Samples the live agent stats endpoint repeatedly and stores JSONL snapshots for a session.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir,
    [string]$StatsUrl = "http://127.0.0.1:13301/api/internal/stats",
    [int]$SampleCount = 6,
    [int]$IntervalSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $SessionDir)) {
    throw "Session directory not found at $SessionDir"
}

$outPath = Join-Path $SessionDir "stats-samples.jsonl"
if (Test-Path $outPath) {
    Remove-Item $outPath -Force
}

for ($i = 0; $i -lt $SampleCount; $i++) {
    $sampledAt = (Get-Date).ToUniversalTime().ToString("o")
    $stats = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
    $record = [pscustomobject]@{
        sampled_at = $sampledAt
        stats = $stats
    }
    ($record | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path $outPath -Encoding utf8

    [pscustomobject]@{
        sampled_at = $sampledAt
        uptime_secs = $stats.uptime_secs
        peers_connected = $stats.peers_connected
        keyword_seen = $stats.harvest_observability.keyword_requests.observed_requests
        source_seen = $stats.harvest_observability.source_requests.observed_requests
        notes_seen = $stats.harvest_observability.notes_requests.observed_requests
        snoop_queue_depth = $stats.snoop_queue_depth
        passive_cycles = $stats.harvest_observability.passive_keyword_replay.completed_cycles
        passive_idle = $stats.harvest_observability.passive_keyword_replay.idle_cycles
        passive_source_started = $stats.harvest_observability.passive_source_replay.started_cycles
        passive_source_completed = $stats.harvest_observability.passive_source_replay.completed_cycles
        passive_source_results = $stats.harvest_observability.passive_source_replay.emitted_results
        passive_source_batches = $stats.harvest_observability.passive_source_replay.posted_batches
        source_unique_shapes = $stats.harvest_observability.source_requests.unique_shapes_observed
        source_queue_depth = $stats.harvest_observability.source_requests.queued_entries
        keyword_acked = if ($stats.publish_observability.latest_keyword_batch) {
            $stats.publish_observability.latest_keyword_batch.acked_contacts
        } else {
            $null
        }
        source_acked = if ($stats.publish_observability.latest_source_batch) {
            $stats.publish_observability.latest_source_batch.acked_contacts
        } else {
            $null
        }
    }

    if ($i -lt ($SampleCount - 1)) {
        Start-Sleep -Seconds $IntervalSeconds
    }
}

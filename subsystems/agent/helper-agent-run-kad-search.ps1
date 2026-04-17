#Requires -Version 7.6
<#
.SYNOPSIS
Runs one live agent Kad keyword search and captures callback payloads locally.

.DESCRIPTION
Starts a temporary local callback listener, dispatches one keyword search to the
agent control API, writes raw callback payloads to JSONL files, and emits a
deduplicated summary keyed by ED2K hash for downstream parity comparisons.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Query,
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,
    [string]$ControlUrl = "http://127.0.0.1:13301",
    [int]$ListenPort = 0,
    [int]$KadReadyTimeoutSeconds = 120,
    [int]$MinimumPeerCount = 8,
    [int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Append-Utf8Line {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $lineBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Line + "`n")
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        $stream.Write($lineBytes, 0, $lineBytes.Length)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-FileRecordEd2kHash {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$FileRecord
    )

    foreach ($hash in @($FileRecord.hashes)) {
        if ([string]$hash.kind -eq "ed2k" -and -not [string]::IsNullOrWhiteSpace([string]$hash.value)) {
            return ([string]$hash.value).ToLowerInvariant()
        }
    }

    return $null
}

function Add-UniqueString {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Target,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    if ($Target -notcontains $Value) {
        [void]$Target.Add($Value)
    }
}

function Wait-AgentKadReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 120,
        [int]$MinimumPeerCount = 8
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastState = $null
    $lastPeerCount = 0
    $lastP2pReady = $false

    while ((Get-Date) -lt $deadline) {
        try {
            $stats = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
            if ($null -ne $stats) {
                $lastState = [string]$stats.agent_activity.state
                $lastPeerCount = if ($null -ne $stats.peers_connected) { [int]$stats.peers_connected } else { 0 }
                $lastP2pReady = [bool]$stats.interface_report.p2p.ready
                if ($lastP2pReady -and $lastState -ne "bootstrapping" -and $lastPeerCount -ge $MinimumPeerCount) {
                    return $stats
                }
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }

    throw "Agent Kad readiness wait timed out at $StatsUrl within $TimeoutSeconds seconds (last_state=$lastState last_peers=$lastPeerCount p2p_ready=$lastP2pReady minimum_peers=$MinimumPeerCount)"
}

function Merge-ResultBatch {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$FileMap,
        [Parameter(Mandatory = $true)]
        [psobject]$Batch
    )

    foreach ($file in @($Batch.files)) {
        $hash = Get-FileRecordEd2kHash -FileRecord $file
        if ([string]::IsNullOrWhiteSpace($hash)) {
            continue
        }

        if (-not $FileMap.Contains($hash)) {
            $FileMap[$hash] = [ordered]@{
                hash = $hash
                size = if ($null -ne $file.size) { [UInt64]$file.size } else { $null }
                contentType = if ($null -ne $file.content_type) { [string]$file.content_type } else { $null }
                sourceCount = @($file.sources).Count
                names = [System.Collections.Generic.List[string]]::new()
                batchHits = 0
            }
        }

        $entry = $FileMap[$hash]
        foreach ($name in @($file.names)) {
            Add-UniqueString -Target $entry.names -Value ([string]$name)
        }
        $entry.batchHits = [int]$entry.batchHits + 1
        $entry.sourceCount = [Math]::Max([int]$entry.sourceCount, @($file.sources).Count)
        if ($null -eq $entry.size -and $null -ne $file.size) {
            $entry.size = [UInt64]$file.size
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.contentType) -and $null -ne $file.content_type) {
            $entry.contentType = [string]$file.content_type
        }
    }
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Path $resolvedOutputRoot -Force | Out-Null

if ($ListenPort -le 0) {
    $ListenPort = Get-FreeTcpPort
}

$callbackBaseUrl = "http://127.0.0.1:$ListenPort/"
$searchJobId = [guid]::NewGuid()
$rawResultsPath = Join-Path $resolvedOutputRoot "agent-kad-search-results.jsonl"
$rawEventsPath = Join-Path $resolvedOutputRoot "agent-kad-search-events.jsonl"
$summaryPath = Join-Path $resolvedOutputRoot "agent-kad-search-summary.json"
$requestPath = Join-Path $resolvedOutputRoot "agent-kad-search-request.json"

$payload = [ordered]@{
    job_id = $searchJobId
    protocol = "kad2"
    kind = "keyword"
    query = $Query
    file_hash = $null
    file_size = $null
    callback_url = $callbackBaseUrl
}
$payload | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8NoBOM $requestPath

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($callbackBaseUrl)
$listener.Start()

$fileMap = @{}
$status = "pending"
$resultCount = 0
$batchCount = 0
$eventCount = 0
$startedAtUtc = (Get-Date).ToUniversalTime()
$completedAtUtc = $null
$statsUrl = "{0}/api/internal/stats" -f $ControlUrl.TrimEnd("/")

try {
    Wait-AgentKadReady -StatsUrl $statsUrl -TimeoutSeconds $KadReadyTimeoutSeconds -MinimumPeerCount $MinimumPeerCount | Out-Null

    Invoke-RestMethod `
        -Method Post `
        -Uri ("{0}/api/internal/search" -f $ControlUrl.TrimEnd("/")) `
        -ContentType "application/json" `
        -Body ($payload | ConvertTo-Json -Depth 6) | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $contextTask = $null
    while ((Get-Date) -lt $deadline) {
        if ($null -eq $contextTask) {
            $contextTask = $listener.GetContextAsync()
        }
        if (-not $contextTask.Wait(1000)) {
            if ($status -in @("completed", "failed", "cancelled")) {
                break
            }
            continue
        }

        $context = $contextTask.Result
        $contextTask = $null
        try {
            $reader = [System.IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
            try {
                $body = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }

            $path = [string]$context.Request.Url.AbsolutePath
            switch ($path) {
                "/api/internal/results" {
                    Append-Utf8Line -Path $rawResultsPath -Line $body
                    $batch = $body | ConvertFrom-Json
                    Merge-ResultBatch -FileMap $fileMap -Batch $batch
                    $batchCount++
                    $resultCount = $fileMap.Count
                }
                "/api/internal/search-events" {
                    Append-Utf8Line -Path $rawEventsPath -Line $body
                    $event = $body | ConvertFrom-Json
                    if ([guid]$event.job_id -eq $searchJobId) {
                        $eventCount++
                        $status = [string]$event.status
                        if ($status -in @("completed", "failed", "cancelled")) {
                            $completedAtUtc = (Get-Date).ToUniversalTime()
                        }
                    }
                }
                default {
                }
            }

            $context.Response.StatusCode = 202
            $responseBytes = [System.Text.Encoding]::UTF8.GetBytes("{}")
            $context.Response.ContentType = "application/json"
            $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
            $context.Response.OutputStream.Flush()
        }
        finally {
            $context.Response.Close()
        }

        if ($status -in @("completed", "failed", "cancelled")) {
            break
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}

if ($null -eq $completedAtUtc -and $status -notin @("completed", "failed", "cancelled")) {
    $status = "timed_out"
    $completedAtUtc = (Get-Date).ToUniversalTime()
}

$files = @(
    @(
        foreach ($entry in $fileMap.Values) {
            [pscustomobject]@{
                Hash = [string]$entry.hash
                Size = if ($null -ne $entry.size) { [UInt64]$entry.size } else { $null }
                ContentType = if ([string]::IsNullOrWhiteSpace([string]$entry.contentType)) { $null } else { [string]$entry.contentType }
                SourceCount = [int]$entry.sourceCount
                BatchHits = [int]$entry.batchHits
                Names = @($entry.names | Sort-Object)
            }
        }
    ) | Sort-Object @{ Expression = "SourceCount"; Descending = $true }, @{ Expression = "Size"; Descending = $false }, @{ Expression = "Hash"; Descending = $false }
)

$summary = [pscustomobject]@{
    Query = $Query
    JobId = $searchJobId
    ControlUrl = $ControlUrl
    CallbackBaseUrl = $callbackBaseUrl
    Status = $status
    ResultCount = $files.Count
    BatchCount = $batchCount
    EventCount = $eventCount
    StartedAtUtc = $startedAtUtc.ToString("o")
    CompletedAtUtc = $completedAtUtc.ToString("o")
    RawResultsPath = $rawResultsPath
    RawEventsPath = $rawEventsPath
    RequestPath = $requestPath
    SummaryPath = $summaryPath
    Files = $files
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $summaryPath
$summary

<#
.SYNOPSIS
Starts a detached long-run agent soak session with periodic stats monitoring.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 1440)]
    [int]$DurationMinutes = 60,
    [ValidateRange(5, 3600)]
    [int]$SampleIntervalSeconds = 300,
    [string]$SessionPrefix = "soak-agent"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Save-SessionMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [hashtable]$Metadata
    )

    $Metadata | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding utf8NoBOM
}

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}
$logDir = if ($env:OVERLORD_LOG_DIR) {
    $env:OVERLORD_LOG_DIR
} else {
    throw "OVERLORD_LOG_DIR is not set"
}

$workerScriptPath = Join-Path $PSScriptRoot "helper-agent-run-soak-worker.ps1"
if (-not (Test-Path $workerScriptPath)) {
    throw "Soak worker script not found at $workerScriptPath"
}

$sessionName = "{0}-{1}" -f $SessionPrefix, (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

$metadataPath = Join-Path $sessionDir "soak-session.json"
$workerStdoutPath = Join-Path $sessionDir "worker-stdout.log"
$workerStderrPath = Join-Path $sessionDir "worker-stderr.log"
$stopRequestPath = Join-Path $sessionDir "stop-request.txt"
$statsSamplesPath = Join-Path $sessionDir "stats-samples.jsonl"
$finalStatsPath = Join-Path $sessionDir "final-stats.json"
$summaryPath = Join-Path $sessionDir "summary.json"

$metadata = [ordered]@{
    SessionName = $sessionName
    SessionDir = $sessionDir
    MetadataPath = $metadataPath
    WorkerStdoutPath = $workerStdoutPath
    WorkerStderrPath = $workerStderrPath
    StopRequestPath = $stopRequestPath
    StatsSamplesPath = $statsSamplesPath
    FinalStatsPath = $finalStatsPath
    SummaryPath = $summaryPath
    DurationMinutes = $DurationMinutes
    SampleIntervalSeconds = $SampleIntervalSeconds
    ProjectDir = $projectDir
    LogDir = $logDir
    StatsUrl = "http://127.0.0.1:13301/api/internal/stats"
    StartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    WorkerPid = $null
    WorkerStartedAtUtc = $null
    WorkerCompletedAtUtc = $null
    WorkerError = $null
    WorkerStatus = "starting"
    StopRequested = $false
    StopRequestedAtUtc = $null
    PreexistingAgentPids = @()
    PreexistingCoordinatorPids = @()
    StartedAgentPids = @()
    StartedCoordinatorPids = @()
    AgentLogPath = $null
    AgentLogLinesBefore = 0
    NetworkingRefresh = $null
}
Save-SessionMetadata -Path $metadataPath -Metadata $metadata

$worker = Start-Process `
    -FilePath "pwsh.exe" `
    -ArgumentList @(
        "-NoLogo",
        "-NoProfile",
        "-File",
        $workerScriptPath,
        "-SessionDir",
        $sessionDir
    ) `
    -WorkingDirectory $projectDir `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput $workerStdoutPath `
    -RedirectStandardError $workerStderrPath

$worker.WaitForExit(2000) | Out-Null
if ($worker.HasExited) {
    $stderr = if (Test-Path $workerStderrPath) {
        (Get-Content -Raw $workerStderrPath).Trim()
    } else {
        ""
    }
    throw "Soak worker exited immediately with code $($worker.ExitCode). $stderr"
}

$metadata.WorkerPid = $worker.Id
$metadata.WorkerStartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
$metadata.WorkerStatus = "running"
Save-SessionMetadata -Path $metadataPath -Metadata $metadata

[pscustomobject]@{
    SessionDir = $sessionDir
    MetadataPath = $metadataPath
    WorkerPid = $worker.Id
    DurationMinutes = $DurationMinutes
    SampleIntervalSeconds = $SampleIntervalSeconds
    StatsSamplesPath = $statsSamplesPath
    SummaryPath = $summaryPath
}

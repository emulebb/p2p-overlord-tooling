#Requires -Version 7.6
<#
.SYNOPSIS
Stops the eMule harness parity session processes and waits for trace flush.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir,
    [int]$FlushWaitSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-LatestHarnessDumpPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogsRoot,
        [Parameter(Mandatory = $true)]
        [string]$Filter,
        $StartedAtUtc
    )

    if (-not (Test-Path -LiteralPath $LogsRoot -PathType Container)) {
        return $null
    }

    $candidates = Get-ChildItem -LiteralPath $LogsRoot -Filter $Filter -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    if ($StartedAtUtc) {
        $candidates = $candidates |
            Where-Object { $_.LastWriteTimeUtc -ge $StartedAtUtc.AddSeconds(-5) }
    }

    $match = $candidates | Select-Object -First 1
    if ($match) {
        return $match.FullName
    }

    return $null
}

$metadataPath = Join-Path $SessionDir "emule-harness-session.json"
if (-not (Test-Path $metadataPath)) {
    throw "Session metadata not found at $metadataPath"
}

$metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-emule-harness-clean-runtime.ps1"

if (-not (Test-Path $cleanupHelperPath)) {
    throw "eMule harness cleanup helper not found at $cleanupHelperPath"
}

if ($metadata.PSObject.Properties.Name -contains "CapturePort" -and $metadata.CapturePort) {
    $capturePort = [int]$metadata.CapturePort
} else {
    $capturePort = 0
}

$cleanupArgs = @{
    CapturePort = $capturePort
    WaitTimeoutSeconds = [Math]::Max($FlushWaitSeconds, 5)
}
if ($metadata.PSObject.Properties.Name -contains "EmuleHarnessPid" -and $metadata.EmuleHarnessPid) {
    $cleanupArgs.EmuleHarnessPids = @([int]$metadata.EmuleHarnessPid)
}
if ($metadata.PSObject.Properties.Name -contains "DumpcapPid" -and $metadata.DumpcapPid) {
    $cleanupArgs.DumpcapPids = @([int]$metadata.DumpcapPid)
}

& $cleanupHelperPath @cleanupArgs | Out-Null

$logsRoot = $null
if ($metadata.PSObject.Properties.Name -contains "EmuleHarnessProfileRoot" -and $metadata.EmuleHarnessProfileRoot) {
    $logsRoot = Join-Path ([string]$metadata.EmuleHarnessProfileRoot) "logs"
}
elseif ($metadata.PSObject.Properties.Name -contains "TraceLogPath" -and $metadata.TraceLogPath) {
    $logsRoot = Split-Path -Parent ([string]$metadata.TraceLogPath)
}

$startedAtUtc = $null
if ($metadata.PSObject.Properties.Name -contains "StartedAtUtc" -and $metadata.StartedAtUtc) {
    try {
        $startedAtUtc = (Get-Date ([string]$metadata.StartedAtUtc)).ToUniversalTime()
    }
    catch {
        $startedAtUtc = $null
    }
}

$udpDumpPath = if ($metadata.PSObject.Properties.Name -contains "EmuleHarnessUdpDumpPath" -and $metadata.EmuleHarnessUdpDumpPath) {
    [string]$metadata.EmuleHarnessUdpDumpPath
} elseif ($metadata.PSObject.Properties.Name -contains "PacketDumpPath" -and $metadata.PacketDumpPath) {
    [string]$metadata.PacketDumpPath
} else {
    $null
}
$ed2kDumpPath = if ($metadata.PSObject.Properties.Name -contains "EmuleHarnessEd2kTcpDumpPath" -and $metadata.EmuleHarnessEd2kTcpDumpPath) {
    [string]$metadata.EmuleHarnessEd2kTcpDumpPath
} else {
    $null
}
if ($logsRoot) {
    $resolvedUdpDumpPath = Resolve-LatestHarnessDumpPath `
        -LogsRoot $logsRoot `
        -Filter "emule-harness-udp-dump-*.jsonl" `
        -StartedAtUtc $startedAtUtc
    if ($resolvedUdpDumpPath) {
        $udpDumpPath = $resolvedUdpDumpPath
    }

    $resolvedEd2kDumpPath = Resolve-LatestHarnessDumpPath `
        -LogsRoot $logsRoot `
        -Filter "emule-harness-ed2k-tcp-dump-*.jsonl" `
        -StartedAtUtc $startedAtUtc
    if ($resolvedEd2kDumpPath) {
        $ed2kDumpPath = $resolvedEd2kDumpPath
    }
}

$metadata.PacketDumpPath = $udpDumpPath
if ($metadata.PSObject.Properties.Name -contains "EmuleHarnessUdpDumpPath") {
    $metadata.EmuleHarnessUdpDumpPath = $udpDumpPath
}
if ($metadata.PSObject.Properties.Name -contains "EmuleHarnessEd2kTcpDumpPath") {
    $metadata.EmuleHarnessEd2kTcpDumpPath = $ed2kDumpPath
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8NoBOM $metadataPath

[pscustomobject]@{
    SessionDir = $SessionDir
    CapturePath = $metadata.CapturePath
    TraceLogPath = $metadata.TraceLogPath
    PacketDumpPath = $udpDumpPath
    EmuleHarnessUdpDumpPath = $udpDumpPath
    EmuleHarnessEd2kTcpDumpPath = $ed2kDumpPath
    VerboseLogPath = $metadata.VerboseLogPath
    StatusLogPath = $metadata.StatusLogPath
    StoppedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

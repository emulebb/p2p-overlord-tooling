#Requires -Version 7.6
<#
.SYNOPSIS
Stops the agent parity session and ends packet capture.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir,
    [int]$FlushWaitSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$metadataPath = Join-Path $SessionDir "agent-session.json"
if (-not (Test-Path $metadataPath)) {
    throw "Session metadata not found at $metadataPath"
}

$metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-agent-clean-runtime.ps1"
if (-not (Test-Path $cleanupHelperPath)) {
    throw "Agent cleanup helper not found at $cleanupHelperPath"
}

$resolvedPacketDumpPath = $metadata.PacketDumpPath
if (-not $resolvedPacketDumpPath) {
    $packetDumpDir = if ($env:OVERLORD_LOG_DIR) {
        $env:OVERLORD_LOG_DIR
    } else {
        Join-Path $env:TEMP "p2p-overlord\\logs"
    }
    $startedAtUtc = $null
    if ($metadata.PSObject.Properties.Name -contains "StartedAtUtc" -and $metadata.StartedAtUtc) {
        $startedAtUtc = [DateTime]::Parse($metadata.StartedAtUtc).ToUniversalTime()
    }
    $resolvedPacketDumpPath = Get-ChildItem -Path $packetDumpDir -Filter 'agent-udp-dump-*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object {
            if ($null -eq $startedAtUtc) {
                return $true
            }
            $_.LastWriteTimeUtc -ge $startedAtUtc.AddSeconds(-5)
        } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
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
if ($metadata.PSObject.Properties.Name -contains "AgentPid" -and $metadata.AgentPid) {
    $cleanupArgs.AgentPids = @([int]$metadata.AgentPid)
}
if ($metadata.PSObject.Properties.Name -contains "DumpcapPid" -and $metadata.DumpcapPid) {
    $cleanupArgs.DumpcapPids = @([int]$metadata.DumpcapPid)
}
& $cleanupHelperPath @cleanupArgs | Out-Null

if ($resolvedPacketDumpPath) {
    $metadata.PacketDumpPath = $resolvedPacketDumpPath
    $metadata | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM $metadataPath
}

[pscustomobject]@{
    SessionDir = $SessionDir
    CapturePath = $metadata.CapturePath
    AgentLogPath = $metadata.AgentLogPath
    PacketDumpPath = $resolvedPacketDumpPath
    StoppedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

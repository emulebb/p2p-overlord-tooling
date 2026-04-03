<#
.SYNOPSIS
Stops the oracle parity session processes and waits for trace flush.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir,
    [int]$FlushWaitSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$metadataPath = Join-Path $SessionDir "oracle-session.json"
if (-not (Test-Path $metadataPath)) {
    throw "Session metadata not found at $metadataPath"
}

$metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-oracle-clean-runtime.ps1"

if (-not (Test-Path $cleanupHelperPath)) {
    throw "Oracle cleanup helper not found at $cleanupHelperPath"
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
if ($metadata.PSObject.Properties.Name -contains "OraclePid" -and $metadata.OraclePid) {
    $cleanupArgs.OraclePids = @([int]$metadata.OraclePid)
}
if ($metadata.PSObject.Properties.Name -contains "DumpcapPid" -and $metadata.DumpcapPid) {
    $cleanupArgs.DumpcapPids = @([int]$metadata.DumpcapPid)
}

& $cleanupHelperPath @cleanupArgs | Out-Null

[pscustomobject]@{
    SessionDir = $SessionDir
    CapturePath = $metadata.CapturePath
    TraceLogPath = $metadata.TraceLogPath
    PacketDumpPath = $metadata.PacketDumpPath
    StoppedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

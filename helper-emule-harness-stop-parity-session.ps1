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

[pscustomobject]@{
    SessionDir = $SessionDir
    CapturePath = $metadata.CapturePath
    TraceLogPath = $metadata.TraceLogPath
    PacketDumpPath = $metadata.PacketDumpPath
    StoppedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

<#
.SYNOPSIS
Stops a passive UDP capture session without touching the target process.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir,
    [int]$FlushWaitSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$metadataPath = Join-Path $SessionDir "pcap-session.json"
if (-not (Test-Path $metadataPath)) {
    throw "Session metadata not found at $metadataPath"
}

$metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json

if ($metadata.PSObject.Properties.Name -contains "DumpcapPid" -and $metadata.DumpcapPid) {
    Stop-Process -Id $metadata.DumpcapPid -Force -ErrorAction SilentlyContinue
}

if ($FlushWaitSeconds -gt 0) {
    Start-Sleep -Seconds $FlushWaitSeconds
}

$captureInfo = if (Test-Path $metadata.CapturePath) {
    Get-Item $metadata.CapturePath
} else {
    $null
}

[pscustomobject]@{
    SessionDir = $SessionDir
    CapturePath = $metadata.CapturePath
    CaptureBytes = if ($captureInfo) { $captureInfo.Length } else { 0 }
    StoppedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

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

if ($metadata.PSObject.Properties.Name -contains "DumpcapPid" -and $metadata.DumpcapPid) {
    Stop-Process -Id $metadata.DumpcapPid -Force -ErrorAction SilentlyContinue
}

if ($metadata.PSObject.Properties.Name -contains "OraclePid" -and $metadata.OraclePid) {
    Stop-Process -Id $metadata.OraclePid -Force -ErrorAction SilentlyContinue
}

$processNames = @("eMule_debug_loc", "emule")
foreach ($name in $processNames) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force
}

if ($FlushWaitSeconds -gt 0) {
    Start-Sleep -Seconds $FlushWaitSeconds
}

[pscustomobject]@{
    SessionDir = $SessionDir
    CapturePath = $metadata.CapturePath
    TraceLogPath = $metadata.TraceLogPath
    StoppedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

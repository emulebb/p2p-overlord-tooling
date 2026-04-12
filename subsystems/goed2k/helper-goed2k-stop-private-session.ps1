#Requires -Version 7.6
<#
.SYNOPSIS
Stops one local goed2k-server session started by the private helper.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir,
    [int]$FlushWaitSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$metadataPath = Join-Path $SessionDir "goed2k-session.json"
if (-not (Test-Path -LiteralPath $metadataPath)) {
    throw "Session metadata not found at $metadataPath"
}

$metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
if ($metadata.PSObject.Properties.Name -contains "Pid" -and $metadata.Pid) {
    $process = Get-Process -Id ([int]$metadata.Pid) -ErrorAction SilentlyContinue
    if ($process) {
        Stop-Process -Id $process.Id -Force
        Start-Sleep -Seconds ([Math]::Max($FlushWaitSeconds, 1))
    }
}

[pscustomobject]@{
    SessionDir = $SessionDir
    StdoutPath = $metadata.StdoutPath
    StderrPath = $metadata.StderrPath
    StoppedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

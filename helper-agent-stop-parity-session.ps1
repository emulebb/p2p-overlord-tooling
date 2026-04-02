<#
.SYNOPSIS
Stops the agent parity session via the existing stop script and ends capture.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir,
    [int]$FlushWaitSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

$metadataPath = Join-Path $SessionDir "agent-session.json"
if (-not (Test-Path $metadataPath)) {
    throw "Session metadata not found at $metadataPath"
}

$metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
$stopScriptPath = Join-Path $projectDir "overlord-agents\scripts\windows\agent_stop_direct.cmd"
if (-not (Test-Path $stopScriptPath)) {
    throw "Agent stop script not found at $stopScriptPath"
}

if ($metadata.PSObject.Properties.Name -contains "DumpcapPid" -and $metadata.DumpcapPid) {
    Stop-Process -Id $metadata.DumpcapPid -Force -ErrorAction SilentlyContinue
}

$null = Start-Process `
    -FilePath "cmd.exe" `
    -ArgumentList "/c", $stopScriptPath `
    -WorkingDirectory $projectDir `
    -WindowStyle Hidden `
    -Wait `
    -PassThru

if ($metadata.PSObject.Properties.Name -contains "AgentPid" -and $metadata.AgentPid) {
    Stop-Process -Id $metadata.AgentPid -Force -ErrorAction SilentlyContinue
}

if ($FlushWaitSeconds -gt 0) {
    Start-Sleep -Seconds $FlushWaitSeconds
}

[pscustomobject]@{
    SessionDir = $SessionDir
    CapturePath = $metadata.CapturePath
    AgentLogPath = $metadata.AgentLogPath
    StoppedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

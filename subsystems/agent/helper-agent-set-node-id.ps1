#Requires -Version 7.6
<#
.SYNOPSIS
Sets the persisted Kad node ID used by the local agent runtime.

.DESCRIPTION
Writes a 32-hex-character Kad node ID into the agent runtime state file and
stores the previous value in the same directory with a timestamped backup name.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$NodeIdHex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$runtimeDir = Join-Path $projectDir "p2p-overlord-agents\runtime"
$nodeIdPath = Join-Path $runtimeDir "overlord-kad.node-id"

if ($NodeIdHex -notmatch '^[0-9a-fA-F]{32}$') {
    throw "NodeIdHex must be exactly 32 hexadecimal characters"
}

$normalized = $NodeIdHex.ToLowerInvariant()
$previous = $null
if (Test-Path $nodeIdPath) {
    $previous = (Get-Content -Raw $nodeIdPath).Trim()
    $backupPath = Join-Path $runtimeDir ("overlord-kad.node-id.bak-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Set-Content -Path $backupPath -Value $previous -Encoding utf8NoBOM
}

Set-Content -Path $nodeIdPath -Value $normalized -Encoding utf8NoBOM

[pscustomobject]@{
    NodeIdPath = $nodeIdPath
    PreviousNodeId = $previous
    NewNodeId = $normalized
}

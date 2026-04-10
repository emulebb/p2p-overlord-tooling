#Requires -Version 7.6
<#
.SYNOPSIS
Extracts only the new agent publish-related log slice for a parity session.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$metadataPath = Join-Path $SessionDir "agent-session.json"
if (-not (Test-Path $metadataPath)) {
    throw "Session metadata not found at $metadataPath"
}

$metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
$agentLogPath = $metadata.AgentLogPath
if (-not (Test-Path $agentLogPath)) {
    throw "Agent log not found at $agentLogPath"
}

$startLine = [int]$metadata.LogLinesBefore
$newLines = Get-Content $agentLogPath | Select-Object -Skip $startLine
$allPath = Join-Path $SessionDir "agent-log-new.log"
$publishPath = Join-Path $SessionDir "agent-publish.log"

$newLines | Set-Content -Encoding utf8NoBOM $allPath
$publishLines = $newLines | Where-Object {
    $_ -match "kad publish send|kad publish recv|kad publish progress|kad publish contact|kad publish pending|traversal phase1 done|bootstrap complete"
}
$publishLines | Set-Content -Encoding utf8NoBOM $publishPath

[pscustomobject]@{
    SessionDir = $SessionDir
    AgentLogPath = $agentLogPath
    NewLogPath = $allPath
    PublishLogPath = $publishPath
    NewLineCount = @($newLines).Count
    PublishLineCount = @($publishLines).Count
}

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

$allCurrentLines = @(Get-Content $agentLogPath)
$recordedStartLine = if ($metadata.PSObject.Properties.Name -contains "LogLinesBefore" -and $metadata.LogLinesBefore) {
    [int]$metadata.LogLinesBefore
} else {
    0
}

# If the log rotated or truncated after startup, fall back to the full current file
# instead of silently returning an empty slice.
$startLine = if ($recordedStartLine -gt 0 -and $allCurrentLines.Count -ge $recordedStartLine) {
    $recordedStartLine
} else {
    0
}
$newLines = @($allCurrentLines | Select-Object -Skip $startLine)
$allPath = Join-Path $SessionDir "agent-log-new.log"
$publishPath = Join-Path $SessionDir "agent-publish.log"

$publishLines = @($newLines | Where-Object {
    $_ -match "kad publish send|kad publish recv|kad publish progress|kad publish contact|kad publish pending|traversal phase1 done|bootstrap complete"
})

[System.IO.File]::WriteAllLines(
    $allPath,
    [string[]]$newLines,
    (New-Object System.Text.UTF8Encoding($false))
)
[System.IO.File]::WriteAllLines(
    $publishPath,
    [string[]]$publishLines,
    (New-Object System.Text.UTF8Encoding($false))
)

[pscustomobject]@{
    SessionDir = $SessionDir
    AgentLogPath = $agentLogPath
    NewLogPath = $allPath
    PublishLogPath = $publishPath
    NewLineCount = @($newLines).Count
    PublishLineCount = @($publishLines).Count
}

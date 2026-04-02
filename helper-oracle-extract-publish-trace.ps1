<#
.SYNOPSIS
Extracts only the new oracle trace window and publish-related lines for a session.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$metadataPath = Join-Path $SessionDir "oracle-session.json"
if (-not (Test-Path $metadataPath)) {
    throw "Session metadata not found at $metadataPath"
}

$metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
$traceLogPath = $metadata.TraceLogPath
if (-not (Test-Path $traceLogPath)) {
    throw "Trace log not found at $traceLogPath"
}

$startLine = [int]$metadata.TraceLinesBefore
$newLines = Get-Content $traceLogPath | Select-Object -Skip $startLine
$allPath = Join-Path $SessionDir "oracle-trace-new.log"
$publishPath = Join-Path $SessionDir "oracle-publish-trace.log"
$interestingPath = Join-Path $SessionDir "oracle-interesting-trace.log"

$newLines | Set-Content -Encoding utf8NoBOM $allPath
$publishLines = $newLines | Where-Object {
    $_ -match "publish_send_opcode|publish_send_memfile|publish_res_accept|publish_res_drop|publish_res_options|search_storekeyword_prepare|track_out_add|track_out_lookup"
}
$publishLines | Set-Content -Encoding utf8NoBOM $publishPath
$interestingLines = $newLines | Where-Object {
    $_ -match "publish_send_opcode|publish_send_memfile|publish_res_accept|publish_res_drop|publish_res_options|publish_res_ack_send|search_storekeyword_prepare|track_out_add|track_out_lookup|search_key_req_in|search_source_req_in|search_notes_req_in"
}
$interestingLines | Set-Content -Encoding utf8NoBOM $interestingPath

[pscustomobject]@{
    SessionDir = $SessionDir
    TraceLogPath = $traceLogPath
    NewTracePath = $allPath
    PublishTracePath = $publishPath
    InterestingTracePath = $interestingPath
    NewLineCount = @($newLines).Count
    PublishLineCount = @($publishLines).Count
    InterestingLineCount = @($interestingLines).Count
}

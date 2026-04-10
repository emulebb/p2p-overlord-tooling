#Requires -Version 7.6
<#
.SYNOPSIS
Queues ED2K download requests from recent live-agent search-result log samples.
#>

[CmdletBinding()]
param(
    [string]$LogPath = "C:\tmp\overlord-logs\overlord-agent-emule.log",
    [string]$Needle = "ebook",
    [int]$MaxItems = 8,
    [string]$ControlUrl = "http://127.0.0.1:13301"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$postScriptPath = Join-Path $PSScriptRoot "helper-agent-post-enrich-download.ps1"
if (-not (Test-Path -LiteralPath $postScriptPath)) {
    throw "missing helper script: $postScriptPath"
}

$lines = Get-Content -Path $LogPath | Select-String "ED2K search results from"
$matching = $lines | Where-Object { $_.Line -match [regex]::Escape($Needle) }
if (-not $matching) {
    throw "no ED2K search-result log lines matched '$Needle'"
}

$pattern = [regex]'(?<name>.+?) \[hash=(?<hash>[0-9a-f]{32}) size=(?<size>\d+)\]'
$seen = [System.Collections.Generic.HashSet[string]]::new()
$queued = @()

foreach ($line in ($matching | Sort-Object LineNumber -Descending)) {
    $sampleHits = ($line.Line -replace '^.*sample_hits=', '')
    if ($sampleHits -eq '-') {
        continue
    }
    $parts = $sampleHits -split ' \| '
    foreach ($part in $parts) {
        $match = $pattern.Match($part)
        if (-not $match.Success) {
            continue
        }
        $hash = $match.Groups['hash'].Value.ToLowerInvariant()
        if (-not $seen.Add($hash)) {
            continue
        }
        $queued += [pscustomobject]@{
            FileHash = $hash
            FileName = $match.Groups['name'].Value
            FileSize = [uint64]$match.Groups['size'].Value
        }
        if ($queued.Count -ge $MaxItems) {
            break
        }
    }
    if ($queued.Count -ge $MaxItems) {
        break
    }
}

if (-not $queued) {
    throw "no ED2K sample hits were extracted from '$LogPath'"
}

$results = foreach ($entry in $queued) {
    try {
        & $postScriptPath `
            -FileHash $entry.FileHash `
            -FileName $entry.FileName `
            -FileSize $entry.FileSize `
            -ControlUrl $ControlUrl | Out-Null
        [pscustomobject]@{
            FileHash = $entry.FileHash
            FileName = $entry.FileName
            FileSize = $entry.FileSize
            Status = "queued"
        }
    }
    catch {
        $message = ($_ | Out-String)
        $status = if ($message -like "*already active*") {
            "already_active"
        }
        else {
            throw
        }
        [pscustomobject]@{
            FileHash = $entry.FileHash
            FileName = $entry.FileName
            FileSize = $entry.FileSize
            Status = $status
        }
    }
}

$results

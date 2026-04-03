<#
.SYNOPSIS
Requests a running soak session to stop and waits for its summary.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir,
    [int]$WaitSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Load-SessionMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Session metadata not found at $Path"
    }

    Get-Content -Raw $Path | ConvertFrom-Json -AsHashtable
}

function Save-SessionMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [hashtable]$Metadata
    )

    $Metadata | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8NoBOM
}

$metadataPath = Join-Path $SessionDir "soak-session.json"
$metadata = Load-SessionMetadata -Path $metadataPath
$summaryScriptPath = Join-Path $PSScriptRoot "helper-agent-summarize-soak-session.ps1"

$metadata.StopRequested = $true
$metadata.StopRequestedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
Save-SessionMetadata -Path $metadataPath -Metadata $metadata

Set-Content -Path $metadata.StopRequestPath -Value $metadata.StopRequestedAtUtc -Encoding utf8NoBOM

if ($metadata.WorkerPid) {
    try {
        Wait-Process -Id $metadata.WorkerPid -Timeout $WaitSeconds -ErrorAction Stop
    } catch {
    }
}

if (Test-Path $summaryScriptPath) {
    & $summaryScriptPath -SessionDir $SessionDir | Out-Null
}

[pscustomobject]@{
    SessionDir = $SessionDir
    WorkerPid = $metadata.WorkerPid
    StopRequestedAtUtc = $metadata.StopRequestedAtUtc
    SummaryPath = $metadata.SummaryPath
}

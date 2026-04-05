<#
.SYNOPSIS
Collects one ED2K transfer manifest and payload directory for a scenario run.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TransferRoot,
    [Parameter(Mandatory = $true)]
    [string]$FileHash,
    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$transferDir = Join-Path ([System.IO.Path]::GetFullPath($TransferRoot)) $FileHash.ToLowerInvariant()
if (-not (Test-Path -LiteralPath $transferDir)) {
    throw "Transfer directory not found at $transferDir"
}

$manifestPath = Join-Path $transferDir "resume-manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Transfer manifest not found at $manifestPath"
}

$resolvedDestinationRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
New-Item -ItemType Directory -Path $resolvedDestinationRoot -Force | Out-Null
$destinationTransferDir = Join-Path $resolvedDestinationRoot $FileHash.ToLowerInvariant()
if (Test-Path -LiteralPath $destinationTransferDir) {
    Remove-Item -LiteralPath $destinationTransferDir -Recurse -Force
}
Copy-Item -LiteralPath $transferDir -Destination $destinationTransferDir -Recurse -Force

$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
[pscustomobject]@{
    TransferRoot = $transferDir
    DestinationRoot = $destinationTransferDir
    ManifestPath = $manifestPath
    Completed = [bool]$manifest.completed
    VerifiedRanges = @($manifest.verified_ranges).Count
    FileSize = [UInt64]$manifest.file_size
}

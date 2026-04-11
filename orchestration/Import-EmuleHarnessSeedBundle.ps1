#Requires -Version 7.6
<#
.SYNOPSIS
Imports canonical eMule harness seed files into an untracked local seed bundle.

.DESCRIPTION
Copies the operator-supplied `nodes.dat` and `server.met` into
`overlord-tooling/.local/emule-harness-seeds/<bundle-id>/` and writes a machine-readable
manifest with file hashes. Source paths are intentionally not persisted.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$NodesDatPath,
    [Parameter(Mandatory = $true, Position = 1)]
    [string]$ServerMetPath,
    [string]$BundleId = "canonical"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$seedRoot = Join-Path $repoRoot ".local\emule-harness-seeds\$BundleId"

if (-not (Test-Path $NodesDatPath)) {
    throw "nodes.dat not found at the supplied path"
}
if (-not (Test-Path $ServerMetPath)) {
    throw "server.met not found at the supplied path"
}

New-Item -ItemType Directory -Path $seedRoot -Force | Out-Null

$nodesTargetPath = Join-Path $seedRoot "nodes.dat"
$serverTargetPath = Join-Path $seedRoot "server.met"

Copy-Item -LiteralPath $NodesDatPath -Destination $nodesTargetPath -Force
Copy-Item -LiteralPath $ServerMetPath -Destination $serverTargetPath -Force

$manifest = [ordered]@{
    schemaVersion = "emule-harness-seed-bundle/v1"
    bundleId = $BundleId
    importedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    files = @(
        [ordered]@{
            name = "nodes.dat"
            sha256 = (Get-FileHash -LiteralPath $nodesTargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
            length = (Get-Item -LiteralPath $nodesTargetPath).Length
            relativePath = "nodes.dat"
        }
        [ordered]@{
            name = "server.met"
            sha256 = (Get-FileHash -LiteralPath $serverTargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
            length = (Get-Item -LiteralPath $serverTargetPath).Length
            relativePath = "server.met"
        }
    )
}

$manifestPath = Join-Path $seedRoot "seed-bundle.json"
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8NoBOM $manifestPath

[pscustomobject]@{
    SeedRoot = $seedRoot
    ManifestPath = $manifestPath
    BundleId = $BundleId
    Files = $manifest.files
}

<#
.SYNOPSIS
Reports the bundled oracle server.met used by the debug build.

.DESCRIPTION
The current oracle build reads `server.met` directly from the debug config
directory. This helper resolves that file and reports its size for parity runs.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

$sourcePath = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug\config\server.met"
$destinationPath = $sourcePath

if (-not (Test-Path $sourcePath)) {
    throw "Bundled server.met not found at $sourcePath"
}

[pscustomobject]@{
    SourcePath = $sourcePath
    DestinationPath = $destinationPath
    Bytes = (Get-Item $destinationPath).Length
}

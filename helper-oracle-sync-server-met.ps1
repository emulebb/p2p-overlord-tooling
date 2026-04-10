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

$oracleHarnessDebugDir = & (Join-Path $PSScriptRoot "helper-oracle-resolve-harness-debug-dir.ps1")
$sourcePath = Join-Path $oracleHarnessDebugDir "config\server.met"

if (-not (Test-Path $sourcePath)) {
    throw "Bundled server.met not found at $sourcePath"
}

[pscustomobject]@{
    SourcePath = $sourcePath
    DestinationPath = $sourcePath
    Bytes = (Get-Item $sourcePath).Length
}

#Requires -Version 7.6
<#
.SYNOPSIS
Reports the bundled eMule harness `server.met` used by the debug build.

.DESCRIPTION
The current eMule harness build reads `server.met` directly from the debug
config directory. This helper resolves that file and reports its size for
parity runs.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$emuleHarnessDebugDir = & (Join-Path $PSScriptRoot "helper-emule-harness-resolve-harness-debug-dir.ps1")
$sourcePath = Join-Path $emuleHarnessDebugDir "config\server.met"

if (-not (Test-Path $sourcePath)) {
    throw "Bundled server.met not found at $sourcePath"
}

[pscustomobject]@{
    SourcePath = $sourcePath
    DestinationPath = $sourcePath
    Bytes = (Get-Item $sourcePath).Length
}

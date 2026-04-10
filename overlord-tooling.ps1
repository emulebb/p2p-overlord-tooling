#Requires -Version 7.6
<#
.SYNOPSIS
Stable top-level CLI entrypoint for the Overlord workspace tooling platform.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [object[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$cliScriptPath = Join-Path $PSScriptRoot "cli\Invoke-OverlordTooling.ps1"
if (-not (Test-Path $cliScriptPath)) {
    throw "CLI dispatcher not found at $cliScriptPath"
}

& $cliScriptPath @Arguments

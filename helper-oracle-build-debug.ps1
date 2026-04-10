#Requires -Version 7.6
<#
.SYNOPSIS
Builds the x64 Debug tracing-harness oracle via the workspace's canonical build wrapper.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$oracleHarnessDebugDir = & (Join-Path $PSScriptRoot "helper-oracle-resolve-harness-debug-dir.ps1")
$buildCmd = Join-Path $env:EMULE_WORKSPACE_ROOT "repos\eMule-build\workspace.cmd"
if (-not (Test-Path $buildCmd)) {
    throw "Build wrapper not found at $buildCmd"
}

& $buildCmd "build-app" "-Config" "Debug"
if ($LASTEXITCODE -ne 0) {
    throw "Oracle debug build failed with exit code $LASTEXITCODE"
}

$builtExePath = Join-Path $oracleHarnessDebugDir "emule.exe"
$runtimeExePath = Join-Path $oracleHarnessDebugDir "eMule_v072a_parity.exe"
$builtPdbPath = Join-Path $oracleHarnessDebugDir "emule.pdb"
$runtimePdbPath = Join-Path $oracleHarnessDebugDir "eMule_v072a_parity.pdb"

if (-not (Test-Path $builtExePath)) {
    throw "Built oracle executable not found at $builtExePath"
}

# Keep the distinct parity oracle binary in sync with the latest MSBuild output
# so harness runs never pick up the generic debug executable by accident.
Copy-Item -Path $builtExePath -Destination $runtimeExePath -Force
if (Test-Path $builtPdbPath) {
    Copy-Item -Path $builtPdbPath -Destination $runtimePdbPath -Force
}

[pscustomobject]@{
    BuildScriptPath = $buildCmd
    BuiltExePath    = $builtExePath
    RuntimeExePath  = $runtimeExePath
    RuntimePdbPath  = if (Test-Path $runtimePdbPath) { $runtimePdbPath } else { $null }
}

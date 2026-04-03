<#
.SYNOPSIS
Builds the x64 Debug oracle via the workspace's canonical build wrapper.
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

$buildScriptPath = Join-Path $projectDir "ext-deps\eMule-build\build_MSBuild_eMule_build_debug.cmd"
if (-not (Test-Path $buildScriptPath)) {
    throw "Build script not found at $buildScriptPath"
}

& $buildScriptPath
if ($LASTEXITCODE -ne 0) {
    throw "Oracle debug build failed with exit code $LASTEXITCODE"
}

$debugDir = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug"
$builtExePath = Join-Path $debugDir "emule.exe"
$runtimeExePath = Join-Path $debugDir "eMule_v060_parity.exe"
$builtPdbPath = Join-Path $debugDir "emule.pdb"
$runtimePdbPath = Join-Path $debugDir "eMule_v060_parity.pdb"

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
    BuildScriptPath = $buildScriptPath
    BuiltExePath = $builtExePath
    RuntimeExePath = $runtimeExePath
    RuntimePdbPath = if (Test-Path $runtimePdbPath) { $runtimePdbPath } else { $null }
}

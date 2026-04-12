#Requires -Version 7.6
<#
.SYNOPSIS
Builds the x64 Debug eMule harness runtime executable.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$emuleWorkspaceRoot = if ($env:EMULE_WORKSPACE_ROOT) {
    [System.IO.Path]::GetFullPath($env:EMULE_WORKSPACE_ROOT)
} else {
    throw "EMULE_WORKSPACE_ROOT is not set"
}

$workspaceScriptPath = Join-Path $emuleWorkspaceRoot "repos\eMule-build\workspace.ps1"
if (-not (Test-Path -LiteralPath $workspaceScriptPath -PathType Leaf)) {
    throw "Canonical eMule-build workspace entrypoint not found at $workspaceScriptPath"
}

$harnessDebugDirResolverPath = Join-Path $PSScriptRoot "helper-emule-harness-resolve-harness-debug-dir.ps1"
if (-not (Test-Path -LiteralPath $harnessDebugDirResolverPath -PathType Leaf)) {
    throw "eMule harness debug-dir resolver not found at $harnessDebugDirResolverPath"
}

$buildArguments = @(
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $workspaceScriptPath
    'build-app'
    '-EmuleWorkspaceRoot'
    $emuleWorkspaceRoot
    '-Config'
    'Debug'
    '-Platform'
    'x64'
)

& 'pwsh' @buildArguments
if ($LASTEXITCODE -ne 0) {
    throw "eMule harness debug build failed with exit code $LASTEXITCODE"
}

$harnessDebugDir = & $harnessDebugDirResolverPath
$builtExePath = Join-Path $harnessDebugDir "emule.exe"
$runtimeExePath = Join-Path $harnessDebugDir "eMule_v072a_parity.exe"
$builtPdbPath = Join-Path $harnessDebugDir "emule.pdb"
$runtimePdbPath = Join-Path $harnessDebugDir "eMule_v072a_parity.pdb"

if (-not (Test-Path $builtExePath)) {
    throw "Built eMule harness executable not found at $builtExePath"
}

# Keep the distinct parity harness binary in sync with the latest build output
# so eMule harness runs never pick up the generic debug executable by accident.
Copy-Item -Path $builtExePath -Destination $runtimeExePath -Force
if (Test-Path $builtPdbPath) {
    Copy-Item -Path $builtPdbPath -Destination $runtimePdbPath -Force
}

[pscustomobject]@{
    BuildScriptPath = $workspaceScriptPath
    AppVariant = 'tracing-harness'
    BuiltExePath    = $builtExePath
    RuntimeExePath  = $runtimeExePath
    RuntimePdbPath  = if (Test-Path $runtimePdbPath) { $runtimePdbPath } else { $null }
}

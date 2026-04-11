#Requires -Version 7.6
<#
.SYNOPSIS
Resolves and returns the absolute path to the eMule harness srchybrid\x64\Debug directory.

.DESCRIPTION
Reads EMULE_WORKSPACE_ROOT, derives the workspace name from the canonical
eMule-build manifest, and returns the fully resolved tracing-harness
srchybrid\x64\Debug path. Throws if EMULE_WORKSPACE_ROOT is not set or the
expected eMule harness path does not exist under that workspace root.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$emuleWorkspaceRoot = if ($env:EMULE_WORKSPACE_ROOT) {
    [System.IO.Path]::GetFullPath($env:EMULE_WORKSPACE_ROOT)
} else {
    throw "EMULE_WORKSPACE_ROOT is not set"
}

$buildManifestPath = Join-Path $emuleWorkspaceRoot "repos\eMule-build\deps.psd1"
if (-not (Test-Path -LiteralPath $buildManifestPath -PathType Leaf)) {
    throw "Canonical eMule-build manifest not found at $buildManifestPath"
}

$buildManifest = Import-PowerShellDataFile -LiteralPath $buildManifestPath
$workspaceName = $buildManifest.Workspace.Name
if ([string]::IsNullOrWhiteSpace($workspaceName)) {
    throw "Workspace name was not declared in $buildManifestPath"
}

$harnessDebugDir = [System.IO.Path]::GetFullPath(
    (Join-Path $emuleWorkspaceRoot "workspaces\$workspaceName\app\eMule-v0.72a-tracing-harness\srchybrid\x64\Debug")
)

if (-not (Test-Path -LiteralPath $harnessDebugDir -PathType Container)) {
    throw "eMule harness debug directory not found at $harnessDebugDir"
}

$harnessDebugDir

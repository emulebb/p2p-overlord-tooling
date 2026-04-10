#Requires -Version 7.6
<#
.SYNOPSIS
Resolves and returns the absolute path to the tracing-harness srchybrid\x64\Debug directory.

.DESCRIPTION
Reads EMULE_WORKSPACE_ROOT, derives the workspace name from the eMule-build repo
manifest, locates the tracing-harness variant in the workspace manifest, and
returns the fully resolved srchybrid\x64\Debug path. Throws if EMULE_WORKSPACE_ROOT
is not set or the tracing-harness variant is not declared in the workspace manifest.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$emuleWorkspaceRoot = if ($env:EMULE_WORKSPACE_ROOT) {
    $env:EMULE_WORKSPACE_ROOT
} else {
    throw "EMULE_WORKSPACE_ROOT is not set"
}

$buildManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $emuleWorkspaceRoot "repos\eMule-build\deps.psd1")
$workspaceName = $buildManifest.Workspace.Name

$workspaceManifestPath = Join-Path $emuleWorkspaceRoot "workspaces\$workspaceName\deps.psd1"
$workspaceManifest = Import-PowerShellDataFile -LiteralPath $workspaceManifestPath
$harnessVariant = @($workspaceManifest.Workspace.AppRepo.Variants | Where-Object { $_.Name -eq 'tracing-harness' })[0]
if (-not $harnessVariant) {
    throw "tracing-harness variant not found in workspace manifest at $workspaceManifestPath"
}

[System.IO.Path]::GetFullPath(
    (Join-Path $emuleWorkspaceRoot "workspaces\$workspaceName\$($harnessVariant.Path)\srchybrid\x64\Debug")
)

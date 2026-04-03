<#
.SYNOPSIS
Dispatches stable workspace tooling platform CLI commands.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [string[]]$Args = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Show-ToolingHelp {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        name = "overlord-tooling"
        commands = @(
            [ordered]@{ name = "help"; description = "Show CLI help" }
            [ordered]@{ name = "layout"; description = "Show the platform directory layout" }
            [ordered]@{ name = "paths"; description = "Show canonical workspace and repo paths" }
        )
    }
}

function Get-ToolingLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    @(
        "cli",
        "docs",
        "normalizers",
        "orchestration",
        "profiles",
        "reports",
        "scenarios",
        "schemas",
        "subsystems"
    ) | ForEach-Object {
        $path = Join-Path $RepoRoot $_
        [pscustomobject]@{
            name = $_
            exists = Test-Path $path
            path = $path
        }
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$workspaceRoot = Resolve-Path (Join-Path $repoRoot "..")

switch ($Command.ToLowerInvariant()) {
    "help" {
        Show-ToolingHelp
    }
    "layout" {
        Get-ToolingLayout -RepoRoot $repoRoot
    }
    "paths" {
        [pscustomobject]@{
            workspaceRoot = $workspaceRoot.Path
            toolingRepoRoot = $repoRoot.Path
            docsRoot = (Join-Path $repoRoot "docs")
            schemasRoot = (Join-Path $repoRoot "schemas")
            scenariosRoot = (Join-Path $repoRoot "scenarios")
        }
    }
    default {
        throw "Unknown overlord-tooling command '$Command'. Run '.\\overlord-tooling.ps1 help'."
    }
}

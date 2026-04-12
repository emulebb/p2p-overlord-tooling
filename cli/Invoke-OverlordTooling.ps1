#Requires -Version 7.6
<#
.SYNOPSIS
Dispatches stable workspace tooling platform CLI commands.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [object[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\subsystems\RuntimeContext.ps1")
. (Join-Path $PSScriptRoot "CommandRegistry.ps1")

function Show-ToolingHelp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    Get-ToolingCommandRegistry -RepoRoot $RepoRoot | ForEach-Object {
        [pscustomobject]@{
            name = $_.Name
            kind = $_.Kind
            description = $_.Description
        }
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

function ConvertTo-ScriptInvocationArgs {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Tokens
    )

    $named = @{}
    $positional = @()
    if (-not $Tokens) {
        return [pscustomobject]@{
            Named = $named
            Positional = $positional
        }
    }

    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        $token = [string]$Tokens[$index]
        if ($token.StartsWith("-")) {
            $parameterName = $token.TrimStart("-")
            $nextIsValue = $index + 1 -lt $Tokens.Count -and -not ([string]$Tokens[$index + 1]).StartsWith("-")
            if ($nextIsValue) {
                $named[$parameterName] = $Tokens[$index + 1]
                $index++
            } else {
                $named[$parameterName] = $true
            }
            continue
        }

        $positional += $Tokens[$index]
    }

    [pscustomobject]@{
        Named = $named
        Positional = $positional
    }
}

$repoRoot = Resolve-ToolingRepoRoot -StartPath $PSScriptRoot
$workspaceRoot = Resolve-Path (Join-Path $repoRoot "..")
$command = "help"
$commandArgs = @()
if ($Arguments -and $Arguments.Count -gt 0) {
    $command = [string]$Arguments[0]
    if ($Arguments.Count -gt 1) {
        $commandArgs = @($Arguments[1..($Arguments.Count - 1)])
    }
}

$resolvedCommand = Get-ToolingCommand -RepoRoot $repoRoot -Name $Command.ToLowerInvariant()
switch ($Command.ToLowerInvariant()) {
    "help" {
        Show-ToolingHelp -RepoRoot $repoRoot
    }
    "layout" {
        Get-ToolingLayout -RepoRoot $repoRoot
    }
    "paths" {
        [pscustomobject]@{
            workspaceRoot = $workspaceRoot.Path
            toolingRepoRoot = $repoRoot
            docsRoot = (Join-Path $repoRoot "docs")
            schemasRoot = (Join-Path $repoRoot "schemas")
            scenariosRoot = (Join-Path $repoRoot "scenarios")
        }
    }
    "show-scenario" {
        if ($commandArgs.Count -eq 0) {
            throw "show-scenario requires a scenario id, for example '.\\overlord-tooling.ps1 show-scenario kad.startup.hello.publish.realnet.v1'"
        }

        $scenarioId = $commandArgs[0]
        $manifestPath = Join-Path $repoRoot ("scenarios\{0}\manifest.v1.json" -f $scenarioId)
        if (-not (Test-Path $manifestPath)) {
            throw "Scenario manifest not found at $manifestPath"
        }

        Get-Content -Raw $manifestPath | ConvertFrom-Json
    }
    default {
        if ($null -eq $resolvedCommand) {
            throw "Unknown overlord-tooling command '$Command'. Run '.\\overlord-tooling.ps1 help'."
        }

        if ($resolvedCommand.Kind -ne "script") {
            throw "Command '$Command' is not configured as a script-backed CLI entrypoint"
        }

        $invocationArgs = ConvertTo-ScriptInvocationArgs -Tokens $commandArgs
        Invoke-ToolingScript -ScriptPath $resolvedCommand.ScriptPath -NamedArguments $invocationArgs.Named -PositionalArguments $invocationArgs.Positional
    }
}

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

function Show-ToolingHelp {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        name = "overlord-tooling"
        commands = @(
            [ordered]@{ name = "help"; description = "Show CLI help" }
            [ordered]@{ name = "layout"; description = "Show the platform directory layout" }
            [ordered]@{ name = "paths"; description = "Show canonical workspace and repo paths" }
            [ordered]@{ name = "guard-tracked-files"; description = "Fail when tracked files contain local user-profile paths or configured personal-name filename leaks" }
            [ordered]@{ name = "import-oracle-seeds"; description = "Import local nodes.dat and server.met into the untracked canonical oracle seed bundle" }
            [ordered]@{ name = "show-scenario"; description = "Print a scenario manifest" }
            [ordered]@{ name = "run-kad-startup-hello-publish"; description = "Run the first paired oracle+agent Kad startup, HELLO, and publish scenario" }
            [ordered]@{ name = "run-private-oracle-ed2k-download"; description = "Run a private local oracle Kad source publish plus native ED2K download scenario" }
            [ordered]@{ name = "run-private-oracle-ed2k-server-download"; description = "Run a private local oracle+agent ED2K download through a local goed2k-server" }
            [ordered]@{ name = "validate-ed2k-server-triplet"; description = "Run focused local triplet validation for multi-file, multi-source, and callback-limit ED2K server cases" }
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

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$workspaceRoot = Resolve-Path (Join-Path $repoRoot "..")
$guardScriptPath = Join-Path $repoRoot "orchestration\Invoke-TrackedFilePrivacyGuard.ps1"
$seedImportScriptPath = Join-Path $repoRoot "orchestration\Import-OracleSeedBundle.ps1"
$scenarioRunnerScriptPath = Join-Path $repoRoot "orchestration\Invoke-KadStartupHelloPublishScenario.ps1"
$privateEd2kScenarioRunnerScriptPath = Join-Path $repoRoot "orchestration\Invoke-PrivateOracleEd2kDownloadScenario.ps1"
$privateEd2kServerScenarioRunnerScriptPath = Join-Path $repoRoot "orchestration\Invoke-PrivateOracleEd2kServerDownloadScenario.ps1"
$tripletValidationScriptPath = Join-Path $repoRoot "orchestration\Invoke-ValidateEd2kServerTriplet.ps1"
$command = "help"
$commandArgs = @()
if ($Arguments -and $Arguments.Count -gt 0) {
    $command = [string]$Arguments[0]
    if ($Arguments.Count -gt 1) {
        $commandArgs = @($Arguments[1..($Arguments.Count - 1)])
    }
}

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
    "guard-tracked-files" {
        if (-not (Test-Path $guardScriptPath)) {
            throw "Tracked-file privacy guard not found at $guardScriptPath"
        }

        $invocationArgs = ConvertTo-ScriptInvocationArgs -Tokens $commandArgs
        $namedArgs = $invocationArgs.Named
        $positionalArgs = $invocationArgs.Positional
        & $guardScriptPath -RepoRoot $repoRoot @namedArgs @positionalArgs
    }
    "import-oracle-seeds" {
        if (-not (Test-Path $seedImportScriptPath)) {
            throw "Oracle seed import helper not found at $seedImportScriptPath"
        }

        $invocationArgs = ConvertTo-ScriptInvocationArgs -Tokens $commandArgs
        $namedArgs = $invocationArgs.Named
        $positionalArgs = $invocationArgs.Positional
        & $seedImportScriptPath @namedArgs @positionalArgs
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
    "run-kad-startup-hello-publish" {
        if (-not (Test-Path $scenarioRunnerScriptPath)) {
            throw "Scenario runner not found at $scenarioRunnerScriptPath"
        }

        $invocationArgs = ConvertTo-ScriptInvocationArgs -Tokens $commandArgs
        $namedArgs = $invocationArgs.Named
        $positionalArgs = $invocationArgs.Positional
        & $scenarioRunnerScriptPath @namedArgs @positionalArgs
    }
    "run-private-oracle-ed2k-download" {
        if (-not (Test-Path $privateEd2kScenarioRunnerScriptPath)) {
            throw "Private ED2K scenario runner not found at $privateEd2kScenarioRunnerScriptPath"
        }

        $invocationArgs = ConvertTo-ScriptInvocationArgs -Tokens $commandArgs
        $namedArgs = $invocationArgs.Named
        $positionalArgs = $invocationArgs.Positional
        & $privateEd2kScenarioRunnerScriptPath @namedArgs @positionalArgs
    }
    "run-private-oracle-ed2k-server-download" {
        if (-not (Test-Path $privateEd2kServerScenarioRunnerScriptPath)) {
            throw "Private ED2K server scenario runner not found at $privateEd2kServerScenarioRunnerScriptPath"
        }

        $invocationArgs = ConvertTo-ScriptInvocationArgs -Tokens $commandArgs
        $namedArgs = $invocationArgs.Named
        $positionalArgs = $invocationArgs.Positional
        & $privateEd2kServerScenarioRunnerScriptPath @namedArgs @positionalArgs
    }
    "validate-ed2k-server-triplet" {
        if (-not (Test-Path $tripletValidationScriptPath)) {
            throw "ED2K server triplet validation runner not found at $tripletValidationScriptPath"
        }

        $invocationArgs = ConvertTo-ScriptInvocationArgs -Tokens $commandArgs
        $namedArgs = $invocationArgs.Named
        $positionalArgs = $invocationArgs.Positional
        & $tripletValidationScriptPath @namedArgs @positionalArgs
    }
    default {
        throw "Unknown overlord-tooling command '$Command'. Run '.\\overlord-tooling.ps1 help'."
    }
}

#Requires -Version 7.6

. (Join-Path $PSScriptRoot "..\subsystems\RuntimeContext.ps1")

function Get-ToolingCommandRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    @(
        [pscustomobject]@{ Name = "help"; Description = "Show CLI help"; Kind = "builtin" }
        [pscustomobject]@{ Name = "layout"; Description = "Show the platform directory layout"; Kind = "builtin" }
        [pscustomobject]@{ Name = "paths"; Description = "Show canonical workspace and repo paths"; Kind = "builtin" }
        [pscustomobject]@{ Name = "show-scenario"; Description = "Print a scenario manifest"; Kind = "builtin" }
        [pscustomobject]@{ Name = "guard-tracked-files"; Description = "Fail when tracked files contain local user-profile paths or configured personal-name filename leaks"; Kind = "script"; ScriptPath = (Join-Path $RepoRoot "orchestration\Invoke-TrackedFilePrivacyGuard.ps1") }
        [pscustomobject]@{ Name = "import-emule-harness-seeds"; Description = "Import local nodes.dat and server.met into the untracked canonical eMule harness seed bundle"; Kind = "script"; ScriptPath = (Join-Path $RepoRoot "orchestration\Import-EmuleHarnessSeedBundle.ps1") }
        [pscustomobject]@{ Name = "run-kad-startup-hello-publish"; Description = "Run the first paired eMule harness and agent Kad startup, HELLO, and publish scenario"; Kind = "script"; ScriptPath = (Join-Path $RepoRoot "orchestration\Invoke-KadStartupHelloPublishScenario.ps1") }
        [pscustomobject]@{ Name = "run-private-emule-harness-ed2k-download"; Description = "Run a private local eMule harness Kad source publish plus native ED2K download scenario"; Kind = "script"; ScriptPath = (Join-Path $RepoRoot "orchestration\Invoke-PrivateEmuleHarnessEd2kDownloadScenario.ps1") }
        [pscustomobject]@{ Name = "run-private-emule-harness-ed2k-server-download"; Description = "Run a private local eMule harness and agent ED2K download through a local goed2k-server"; Kind = "script"; ScriptPath = (Join-Path $RepoRoot "orchestration\Invoke-PrivateEmuleHarnessEd2kServerDownloadScenario.ps1") }
        [pscustomobject]@{ Name = "run-realnet-emule-harness-ed2k-server-roundtrip"; Description = "Run a real-network ED2K server roundtrip: eMule harness to agent, then agent back to a fresh eMule harness profile"; Kind = "script"; ScriptPath = (Join-Path $RepoRoot "orchestration\Invoke-RealnetEmuleHarnessEd2kServerRoundtripScenario.ps1") }
        [pscustomobject]@{ Name = "run-private-harness-kad-triplet"; Description = "Run a local Kad cluster with three eMule harness peers plus one agent, including publish and search"; Kind = "script"; ScriptPath = (Join-Path $RepoRoot "orchestration\Invoke-PrivateHarnessKadTripletScenario.ps1") }
        [pscustomobject]@{ Name = "validate-ed2k-server-triplet"; Description = "Run focused local triplet validation for multi-file, multi-source, and callback-limit ED2K server cases"; Kind = "script"; ScriptPath = (Join-Path $RepoRoot "orchestration\Invoke-ValidateEd2kServerTriplet.ps1") }
    )
}

function Get-ToolingCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    @(Get-ToolingCommandRegistry -RepoRoot $RepoRoot | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)[0]
}

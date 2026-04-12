#Requires -Version 7.6

. (Join-Path $PSScriptRoot "..\RuntimeContext.ps1")

function Resolve-NetworkSubsystemPath {
    [CmdletBinding()]
    param()

    $path = Join-Path $PSScriptRoot "helper-network-resolve-adapter.ps1"
    Assert-ToolingPaths -Paths @($path) -Label "Network subsystem script"
    $path
}

function Resolve-OverlordNetworkAdapter {
    [CmdletBinding()]
    param(
        [string]$PreferredInterfaceAlias = "hide.me"
    )

    Invoke-ToolingScript -ScriptPath (Resolve-NetworkSubsystemPath) -NamedArguments $PSBoundParameters
}

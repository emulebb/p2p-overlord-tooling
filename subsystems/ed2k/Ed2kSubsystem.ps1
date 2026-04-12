#Requires -Version 7.6

. (Join-Path $PSScriptRoot "..\RuntimeContext.ps1")

function Resolve-Ed2kSubsystemPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("SelectLiveServer", "SetServerRoundRobin")]
        [string]$Name
    )

    $fileName = switch ($Name) {
        "SelectLiveServer" { "helper-ed2k-select-live-server.ps1" }
        "SetServerRoundRobin" { "helper-ed2k-set-server-round-robin.ps1" }
    }

    $path = Join-Path $PSScriptRoot $fileName
    Assert-ToolingPaths -Paths @($path) -Label "ED2K subsystem script"
    $path
}

function Select-Ed2kLiveServer {
    [CmdletBinding()]
    param(
        [string]$SourcePath,
        [int]$MaxCandidates = 0,
        [int]$ConnectTimeoutMilliseconds = 5000
    )

    Invoke-ToolingScript -ScriptPath (Resolve-Ed2kSubsystemPath -Name "SelectLiveServer") -NamedArguments $PSBoundParameters
}

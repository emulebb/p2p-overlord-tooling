#Requires -Version 7.6

. (Join-Path $PSScriptRoot "..\RuntimeContext.ps1")

function Get-Goed2kSubsystemPathMap {
    [CmdletBinding()]
    param()

    [ordered]@{
        StartPrivateSession = Join-Path $PSScriptRoot "helper-goed2k-start-private-session.ps1"
        StopPrivateSession = Join-Path $PSScriptRoot "helper-goed2k-stop-private-session.ps1"
    }
}

function Resolve-Goed2kSubsystemPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $paths = Get-Goed2kSubsystemPathMap
    if (-not $paths.Contains($Name)) {
        throw "Unknown goed2k subsystem path name '$Name'"
    }

    $path = $paths[$Name]
    Assert-ToolingPaths -Paths @($path) -Label "goed2k subsystem script"
    $path
}

function Start-Goed2kPrivateSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioRoot,
        [string]$ListenHost = "127.0.0.1",
        [UInt16]$TcpPort = 42161,
        [UInt16]$AdminPort = 42180,
        [int]$UDPPortOffset = 4,
        [string]$AdminToken = "local-goed2k-token",
        [string]$SourceCatalogPath,
        [int]$LaunchTimeoutSeconds = 120,
        [switch]$EnableObfuscation
    )

    Invoke-ToolingScript -ScriptPath (Resolve-Goed2kSubsystemPath -Name "StartPrivateSession") -NamedArguments $PSBoundParameters
}

function Stop-Goed2kPrivateSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionDir
    )

    Invoke-ToolingScript -ScriptPath (Resolve-Goed2kSubsystemPath -Name "StopPrivateSession") -NamedArguments $PSBoundParameters
}

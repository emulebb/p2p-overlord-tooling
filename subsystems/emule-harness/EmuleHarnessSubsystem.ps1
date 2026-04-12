#Requires -Version 7.6

. (Join-Path $PSScriptRoot "..\RuntimeContext.ps1")

function Get-EmuleHarnessSubsystemPathMap {
    [CmdletBinding()]
    param()

    [ordered]@{
        BuildDebug = Join-Path $PSScriptRoot "helper-emule-harness-build-debug.ps1"
        CleanRuntime = Join-Path $PSScriptRoot "helper-emule-harness-clean-runtime.ps1"
        ResolveDebugDir = Join-Path $PSScriptRoot "helper-emule-harness-resolve-harness-debug-dir.ps1"
        SetObfuscationMode = Join-Path $PSScriptRoot "helper-emule-harness-set-obfuscation-mode.ps1"
        StartParitySession = Join-Path $PSScriptRoot "helper-emule-harness-start-parity-session.ps1"
        StartPrivateEd2kSession = Join-Path $PSScriptRoot "helper-emule-harness-start-private-ed2k-session.ps1"
        StopParitySession = Join-Path $PSScriptRoot "helper-emule-harness-stop-parity-session.ps1"
        WriteTargetServerMet = Join-Path $PSScriptRoot "helper-emule-harness-write-target-server-met.ps1"
    }
}

function Resolve-EmuleHarnessSubsystemPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $paths = Get-EmuleHarnessSubsystemPathMap
    if (-not $paths.Contains($Name)) {
        throw "Unknown eMule harness subsystem path name '$Name'"
    }

    $path = $paths[$Name]
    Assert-ToolingPaths -Paths @($path) -Label "eMule harness subsystem script"
    $path
}

function Build-EmuleHarnessDebug {
    [CmdletBinding()]
    param()

    Invoke-ToolingScript -ScriptPath (Resolve-EmuleHarnessSubsystemPath -Name "BuildDebug") -NamedArguments $PSBoundParameters
}

function Clean-EmuleHarnessRuntime {
    [CmdletBinding()]
    param(
        [int]$CapturePort = 0,
        [AllowEmptyCollection()]
        [int[]]$EmuleHarnessPids = @(),
        [AllowEmptyCollection()]
        [int[]]$DumpcapPids = @(),
        [int]$WaitTimeoutSeconds = 15
    )

    Invoke-ToolingScript -ScriptPath (Resolve-EmuleHarnessSubsystemPath -Name "CleanRuntime") -NamedArguments $PSBoundParameters
}

function Resolve-EmuleHarnessDebugDir {
    [CmdletBinding()]
    param(
        [switch]$AllowMissing
    )

    Invoke-ToolingScript -ScriptPath (Resolve-EmuleHarnessSubsystemPath -Name "ResolveDebugDir") -NamedArguments $PSBoundParameters
}

function Resolve-EmuleHarnessRuntimeExePath {
    [CmdletBinding()]
    param()

    Join-Path (Resolve-EmuleHarnessDebugDir) "eMule_v072a_parity.exe"
}

function Set-EmuleHarnessObfuscationMode {
    [CmdletBinding()]
    param(
        [ValidateSet("ObfuscatedPreferred", "PlaintextOnly")]
        [string]$Mode = "ObfuscatedPreferred",
        [string]$ProfileRoot
    )

    Invoke-ToolingScript -ScriptPath (Resolve-EmuleHarnessSubsystemPath -Name "SetObfuscationMode") -NamedArguments $PSBoundParameters
}

function Start-EmuleHarnessParitySession {
    [CmdletBinding()]
    param(
        [string]$InterfaceAlias = "hide.me",
        [int]$CapturePort = 0,
        [string]$SessionPrefix = "parity-emule-harness",
        [int]$WaitAfterLaunchSeconds = 0,
        [string]$ProfileRoot
    )

    Invoke-ToolingScript -ScriptPath (Resolve-EmuleHarnessSubsystemPath -Name "StartParitySession") -NamedArguments $PSBoundParameters
}

function Start-EmuleHarnessPrivateEd2kSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot,
        [string]$SeedFilePath,
        [string]$ExportLinkPath,
        [string]$AgentBootstrapNode,
        [string]$ExportSourceIp,
        [string]$DownloadLinkPath,
        [string]$SearchTerm,
        [string]$SearchResultsPath,
        [string]$SearchDownloadHashPath,
        [ValidateSet("Debug", "Release")]
        [string]$BuildConfig = "Debug",
        [switch]$SkipRuntimeCleanup
    )

    Invoke-ToolingScript -ScriptPath (Resolve-EmuleHarnessSubsystemPath -Name "StartPrivateEd2kSession") -NamedArguments $PSBoundParameters
}

function Stop-EmuleHarnessParitySession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionDir,
        [int]$FlushWaitSeconds = 5
    )

    Invoke-ToolingScript -ScriptPath (Resolve-EmuleHarnessSubsystemPath -Name "StopParitySession") -NamedArguments $PSBoundParameters
}

function Write-EmuleHarnessTargetServerMet {
    [CmdletBinding()]
    param(
        [string]$ServerIp = "176.123.2.239",
        [int]$ServerPort = 4232,
        [int]$UdpFlags = 0,
        [int]$UdpKey = 0,
        [int]$UdpKeyIp = 0,
        [int]$TcpObfuscationPort = 0,
        [int]$UdpObfuscationPort = 0,
        [string]$DestinationPath
    )

    Invoke-ToolingScript -ScriptPath (Resolve-EmuleHarnessSubsystemPath -Name "WriteTargetServerMet") -NamedArguments $PSBoundParameters
}

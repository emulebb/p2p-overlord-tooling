#Requires -Version 7.6

. (Join-Path $PSScriptRoot "..\RuntimeContext.ps1")

function Get-AgentSubsystemPathMap {
    [CmdletBinding()]
    param()

    [ordered]@{
        CollectEd2kTransfer = Join-Path $PSScriptRoot "helper-agent-collect-ed2k-transfer.ps1"
        ExtractPublishLog = Join-Path $PSScriptRoot "helper-agent-extract-publish-log.ps1"
        PostEnrichDownload = Join-Path $PSScriptRoot "helper-agent-post-enrich-download.ps1"
        PostSeedPopular = Join-Path $PSScriptRoot "helper-agent-post-seed-popular.ps1"
        RefreshRuntimeNetworking = Join-Path $PSScriptRoot "helper-agent-refresh-runtime-networking.ps1"
        RunKadSearch = Join-Path $PSScriptRoot "helper-agent-run-kad-search.ps1"
        SetObfuscationMode = Join-Path $PSScriptRoot "helper-agent-set-obfuscation-mode.ps1"
        StartParitySession = Join-Path $PSScriptRoot "helper-agent-start-parity-session.ps1"
        StartPrivateEd2kSession = Join-Path $PSScriptRoot "helper-agent-start-private-ed2k-session.ps1"
        StopParitySession = Join-Path $PSScriptRoot "helper-agent-stop-parity-session.ps1"
    }
}

function Resolve-AgentSubsystemPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $paths = Get-AgentSubsystemPathMap
    if (-not $paths.Contains($Name)) {
        throw "Unknown agent subsystem path name '$Name'"
    }

    $path = $paths[$Name]
    Assert-ToolingPaths -Paths @($path) -Label "Agent subsystem script"
    $path
}

function Collect-AgentEd2kTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TransferRoot,
        [Parameter(Mandatory = $true)]
        [string]$FileHash,
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    Invoke-ToolingScript -ScriptPath (Resolve-AgentSubsystemPath -Name "CollectEd2kTransfer") -NamedArguments $PSBoundParameters
}

function Extract-AgentPublishLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionDir
    )

    Invoke-ToolingScript -ScriptPath (Resolve-AgentSubsystemPath -Name "ExtractPublishLog") -NamedArguments $PSBoundParameters
}

function Post-AgentEnrichDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileHash,
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        [Parameter(Mandatory = $true)]
        [UInt64]$FileSize,
        [string]$SourceIp,
        [UInt16]$SourceTcpPort,
        [UInt32]$SourceClientId,
        [string]$SourceUserHash,
        [string]$ControlUrl = "http://127.0.0.1:13301"
    )

    Invoke-ToolingScript -ScriptPath (Resolve-AgentSubsystemPath -Name "PostEnrichDownload") -NamedArguments $PSBoundParameters
}

function Post-AgentSeedPopular {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ed2kHash,
        [Parameter(Mandatory = $true)]
        [string]$CanonicalName,
        [Parameter(Mandatory = $true)]
        [UInt64]$Size,
        [UInt32]$SourceCount = 1,
        [string]$ControlUrl = "http://127.0.0.1:13301"
    )

    Invoke-ToolingScript -ScriptPath (Resolve-AgentSubsystemPath -Name "PostSeedPopular") -NamedArguments $PSBoundParameters
}

function Refresh-AgentRuntimeNetworking {
    [CmdletBinding()]
    param(
        [string]$InterfaceAlias = "hide.me",
        [string]$RuntimeDir,
        [string]$TempConfigPath
    )

    Invoke-ToolingScript -ScriptPath (Resolve-AgentSubsystemPath -Name "RefreshRuntimeNetworking") -NamedArguments $PSBoundParameters
}

function Run-AgentKadSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,
        [string]$ControlUrl = "http://127.0.0.1:13301",
        [int]$ListenPort = 0,
        [int]$KadReadyTimeoutSeconds = 120,
        [int]$MinimumPeerCount = 20,
        [int]$TimeoutSeconds = 180
    )

    Invoke-ToolingScript -ScriptPath (Resolve-AgentSubsystemPath -Name "RunKadSearch") -NamedArguments $PSBoundParameters
}

function Set-AgentObfuscationMode {
    [CmdletBinding()]
    param(
        [ValidateSet("On", "Off")]
        [string]$Kad = "On",
        [ValidateSet("On", "Off")]
        [string]$Ed2k = "On",
        [string]$ConfigPath
    )

    Invoke-ToolingScript -ScriptPath (Resolve-AgentSubsystemPath -Name "SetObfuscationMode") -NamedArguments $PSBoundParameters
}

function Start-AgentParitySession {
    [CmdletBinding()]
    param(
        [int]$InterfaceIndex = 0,
        [string]$InterfaceAlias = "hide.me",
        [int]$CapturePort = 41000,
        [string]$SessionPrefix = "parity-agent",
        [string]$ServerIp,
        [int]$ServerPort = 0,
        [int]$ServerUdpFlags = 0,
        [int]$ServerUdpKey = 0,
        [int]$ServerUdpKeyIp = 0,
        [int]$ServerTcpObfuscationPort = 0,
        [int]$ServerUdpObfuscationPort = 0,
        [int]$ServerSessionRotationSeconds = 0,
        [int]$ServerConnectTimeoutSeconds = 8,
        [int]$ServerReconnectIntervalSeconds = 5
    )

    Invoke-ToolingScript -ScriptPath (Resolve-AgentSubsystemPath -Name "StartParitySession") -NamedArguments $PSBoundParameters
}

function Start-AgentPrivateEd2kSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioRoot,
        [string]$EmuleHarnessBootstrapNode,
        [UInt16]$ControlPort = 13301,
        [UInt16]$KadPort = 41120,
        [UInt16]$Ed2kPort = 41121,
        [string]$P2pBindIp = "127.0.0.1",
        [UInt32]$KadBootstrapReadyContacts = 10,
        [switch]$DisableKad,
        [string]$ServerHost,
        [UInt16]$ServerPort = 0,
        [UInt32]$ServerUdpFlags = 0,
        [UInt32]$ServerUdpKey = 0,
        [UInt32]$ServerUdpKeyIp = 0,
        [UInt16]$ServerObfuscationPortTcp = 0,
        [UInt16]$ServerObfuscationPortUdp = 0,
        [UInt64]$ServerConnectTimeoutSeconds = 8,
        [UInt64]$ServerReconnectIntervalSeconds = 5,
        [UInt64]$ServerSessionRotationSeconds = 45,
        [string]$ProbeSearchTerm = "ubuntu linux",
        [int]$LaunchTimeoutSeconds = 300,
        [switch]$EnableObfuscation,
        [switch]$EnableKadNotesPublish
    )

    Invoke-ToolingScript -ScriptPath (Resolve-AgentSubsystemPath -Name "StartPrivateEd2kSession") -NamedArguments $PSBoundParameters
}

function Stop-AgentParitySession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionDir,
        [int]$FlushWaitSeconds = 5
    )

    Invoke-ToolingScript -ScriptPath (Resolve-AgentSubsystemPath -Name "StopParitySession") -NamedArguments $PSBoundParameters
}

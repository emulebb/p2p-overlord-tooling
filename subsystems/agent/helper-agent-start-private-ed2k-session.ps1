#Requires -Version 7.6
<#
.SYNOPSIS
Starts a private local-only agent session for one eMule harness download scenario.
#>

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

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}

$cleanupHelperPath = Join-Path $PSScriptRoot "helper-agent-clean-runtime.ps1"
$configWriterPath = Join-Path $PSScriptRoot "helper-agent-write-private-local-config.ps1"
$launchHelperPath = Join-Path $PSScriptRoot "helper-agent-launch-debug.ps1"
$sessionMetadataHelperPath = Join-Path $PSScriptRoot "SessionMetadata.ps1"

foreach ($requiredPath in @($cleanupHelperPath, $configWriterPath, $launchHelperPath, $sessionMetadataHelperPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required helper path not found at $requiredPath"
    }
}

. $sessionMetadataHelperPath

& $cleanupHelperPath -CapturePort 0 | Out-Null

$configWriterParams = @{
    ScenarioRoot = $ScenarioRoot
    EmuleHarnessBootstrapNode = $EmuleHarnessBootstrapNode
    ControlPort = $ControlPort
    KadPort = $KadPort
    Ed2kPort = $Ed2kPort
    P2pBindIp = $P2pBindIp
    KadBootstrapReadyContacts = $KadBootstrapReadyContacts
    DisableKad = $DisableKad
    ServerHost = $ServerHost
    ServerPort = $ServerPort
    ServerUdpFlags = $ServerUdpFlags
    ServerUdpKey = $ServerUdpKey
    ServerUdpKeyIp = $ServerUdpKeyIp
    ServerObfuscationPortTcp = $ServerObfuscationPortTcp
    ServerObfuscationPortUdp = $ServerObfuscationPortUdp
    ServerConnectTimeoutSeconds = $ServerConnectTimeoutSeconds
    ServerReconnectIntervalSeconds = $ServerReconnectIntervalSeconds
    ServerSessionRotationSeconds = $ServerSessionRotationSeconds
    ProbeSearchTerm = $ProbeSearchTerm
}
if ($EnableObfuscation) {
    $configWriterParams.EnableObfuscation = $true
}
if ($EnableKadNotesPublish) {
    $configWriterParams.EnableKadNotesPublish = $true
}
$configResult = & $configWriterPath @configWriterParams

$sessionName = "private-agent-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$metadataPath = Join-Path $sessionDir "agent-session.json"
$sessionStartUtc = (Get-Date).ToUniversalTime()
$agentProcess = $null

try {
    $launchResult = & $launchHelperPath -LogRoot $configResult.LogRoot
    $agentProcess = Get-Process -Id $launchResult.AgentPid -ErrorAction SilentlyContinue
    if (-not $agentProcess) {
        throw "Agent process overlord-agent-emule.exe (PID $($launchResult.AgentPid)) is not running after launch"
    }

    $resolvedServerPort = $null
    if ($ServerPort -gt 0) {
        $resolvedServerPort = [UInt16]$ServerPort
    }
    $metadata = New-AgentSessionMetadata `
        -SessionDir $sessionDir `
        -SessionName $sessionName `
        -StateRoot $configResult.StateRoot `
        -LogRoot $configResult.LogRoot `
        -ConfigPath $configResult.ConfigPath `
        -ConfigBackupPath $configResult.BackupPath `
        -CapturePort 0 `
        -ControlPort $ControlPort `
        -KadPort $KadPort `
        -Ed2kPort $Ed2kPort `
        -BindIp $P2pBindIp `
        -KadBootstrapReadyContacts $KadBootstrapReadyContacts `
        -KadDisabled ([bool]$DisableKad) `
        -ServerHost $ServerHost `
        -ServerPort $resolvedServerPort `
        -ProbeSearchTerm $ProbeSearchTerm `
        -AgentPid $agentProcess.Id `
        -StartedAtUtc $sessionStartUtc
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8NoBOM $metadataPath
    $metadata
}
catch {
    if ($agentProcess) {
        & $cleanupHelperPath -CapturePort 0 -AgentPids @($agentProcess.Id) | Out-Null
    } else {
        & $cleanupHelperPath -CapturePort 0 | Out-Null
    }
    throw
}

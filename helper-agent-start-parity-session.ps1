#Requires -Version 7.6
<#
.SYNOPSIS
Starts a fresh agent parity session with UDP capture and log window markers.
#>

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

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}
$logDir = if ($env:OVERLORD_LOG_DIR) {
    $env:OVERLORD_LOG_DIR
} else {
    throw "OVERLORD_LOG_DIR is not set"
}

$agentLogPath = Join-Path $logDir "overlord-agent-emule.log"
$packetDumpDir = $logDir
$launchHelperPath = Join-Path $PSScriptRoot "helper-agent-launch-debug.ps1"
$dumpcapPath = "C:\Program Files\Wireshark\dumpcap.exe"
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-agent-clean-runtime.ps1"
$refreshNetworkingHelperPath = Join-Path $PSScriptRoot "helper-agent-refresh-runtime-networking.ps1"
$setTargetServerHelperPath = Join-Path $PSScriptRoot "helper-agent-set-target-server-entry.ps1"
$networkResolverPath = Join-Path $PSScriptRoot "helper-network-resolve-adapter.ps1"

if (-not (Test-Path $launchHelperPath)) {
    throw "Agent launch helper not found at $launchHelperPath"
}
if (-not (Test-Path $dumpcapPath)) {
    throw "dumpcap.exe not found at $dumpcapPath"
}
if (-not (Test-Path $cleanupHelperPath)) {
    throw "Agent cleanup helper not found at $cleanupHelperPath"
}
if (-not (Test-Path $refreshNetworkingHelperPath)) {
    throw "Agent networking refresh helper not found at $refreshNetworkingHelperPath"
}
if (-not (Test-Path $setTargetServerHelperPath)) {
    throw "Agent target-server helper not found at $setTargetServerHelperPath"
}
if (-not (Test-Path $networkResolverPath)) {
    throw "Network adapter resolver not found at $networkResolverPath"
}

function Resolve-DumpcapInterfaceIndex {
    param(
        [Parameter(Mandatory = $true)]
        [int]$RequestedIndex,
        [Parameter(Mandatory = $true)]
        [string]$AdapterAlias,
        [Parameter(Mandatory = $true)]
        [string]$DumpcapPath
    )

    if ($RequestedIndex -gt 0) {
        return $RequestedIndex
    }

    $adapter = Get-NetAdapter -InterfaceAlias $AdapterAlias -ErrorAction Stop
    $dumpcapDevices = & $DumpcapPath -D
    foreach ($device in $dumpcapDevices) {
        if ($device -match '^(?<Index>\d+)\.\s+.+\((?<Name>.+)\)$') {
            if ($matches.Name -eq $adapter.Name) {
                return [int]$matches.Index
            }
        }
    }

    throw "Could not map interface '$AdapterAlias' to a dumpcap device index"
}

$resolvedAdapter = & $networkResolverPath -PreferredInterfaceAlias $InterfaceAlias
$resolvedInterfaceAlias = [string]$resolvedAdapter.InterfaceAlias
$InterfaceIndex = Resolve-DumpcapInterfaceIndex `
    -RequestedIndex $InterfaceIndex `
    -AdapterAlias $resolvedInterfaceAlias `
    -DumpcapPath $dumpcapPath

$networkingRefresh = & $refreshNetworkingHelperPath -InterfaceAlias $resolvedInterfaceAlias

$targetServerSelection = $null
if (-not [string]::IsNullOrWhiteSpace($ServerIp) -and $ServerPort -gt 0) {
    $targetServerSelection = & $setTargetServerHelperPath `
        -ServerIp $ServerIp `
        -ServerPort $ServerPort `
        -UdpFlags $ServerUdpFlags `
        -UdpKey $ServerUdpKey `
        -UdpKeyIp $ServerUdpKeyIp `
        -TcpObfuscationPort $ServerTcpObfuscationPort `
        -UdpObfuscationPort $ServerUdpObfuscationPort `
        -SessionRotationSeconds $ServerSessionRotationSeconds `
        -ConnectTimeoutSeconds $ServerConnectTimeoutSeconds `
        -ReconnectIntervalSeconds $ServerReconnectIntervalSeconds `
        -ConfigPath $networkingRefresh.TempConfigPath
}

& $cleanupHelperPath -CapturePort $CapturePort | Out-Null

$sessionName = "{0}-{1}" -f $SessionPrefix, (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

$pcapPath = Join-Path $sessionDir ("agent-{0}.pcapng" -f $CapturePort)
$metadataPath = Join-Path $sessionDir "agent-session.json"
$dumpcapStdoutPath = Join-Path $sessionDir "dumpcap-stdout.log"
$dumpcapStderrPath = Join-Path $sessionDir "dumpcap-stderr.log"
$sessionStartUtc = (Get-Date).ToUniversalTime()
$agentProcess = $null
$dumpcap = $null

$logLinesBefore = 0
$logLengthBefore = 0
$logWriteTimeBefore = $null
if (Test-Path $agentLogPath) {
    $logInfo = Get-Item $agentLogPath
    $logLengthBefore = $logInfo.Length
    $logWriteTimeBefore = $logInfo.LastWriteTimeUtc
    $logLinesBefore = @(Get-Content $agentLogPath).Count
}

try {
    $dumpcap = Start-Process `
        -FilePath $dumpcapPath `
        -ArgumentList "-i $InterfaceIndex -f `"udp port $CapturePort`" -w `"$pcapPath`"" `
        -PassThru `
        -RedirectStandardOutput $dumpcapStdoutPath `
        -RedirectStandardError $dumpcapStderrPath `
        -WindowStyle Hidden

    Start-Sleep -Seconds 2
    if ($dumpcap.HasExited) {
        $stderr = if (Test-Path $dumpcapStderrPath) { (Get-Content -Raw $dumpcapStderrPath).Trim() } else { "" }
        throw "dumpcap exited immediately with code $($dumpcap.ExitCode). $stderr"
    }

    $pcapDeadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $pcapDeadline) {
        if (Test-Path $pcapPath) { break }
        if ($dumpcap.HasExited) {
            $stderr = if (Test-Path $dumpcapStderrPath) { (Get-Content -Raw $dumpcapStderrPath).Trim() } else { "" }
            throw "dumpcap exited before creating capture file. $stderr"
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path $pcapPath)) {
        Stop-Process -Id $dumpcap.Id -Force -ErrorAction SilentlyContinue
        throw "dumpcap did not create capture file at $pcapPath within 15 seconds"
    }

    $launchResult = & $launchHelperPath
    $agentProcess = Get-Process -Id $launchResult.AgentPid -ErrorAction SilentlyContinue
    if (-not $agentProcess) {
        throw "Agent process overlord-agent-emule.exe (PID $($launchResult.AgentPid)) is not running after launch"
    }

    $packetDumpPath = Get-ChildItem -Path $packetDumpDir -Filter 'agent-udp-dump-*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $sessionStartUtc.AddSeconds(-5) } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName

    $metadata = [pscustomobject]@{
        SessionDir = $sessionDir
        SessionName = $sessionName
        AgentLogPath = $agentLogPath
        PacketDumpPath = $packetDumpPath
        LogLinesBefore = $logLinesBefore
        LogLengthBefore = $logLengthBefore
        LogWriteTimeBeforeUtc = if ($logWriteTimeBefore) { $logWriteTimeBefore.ToString("o") } else { $null }
        CapturePath = $pcapPath
        CapturePort = $CapturePort
        InterfaceIndex = $InterfaceIndex
        RequestedInterfaceAlias = $InterfaceAlias
        InterfaceAlias = $resolvedInterfaceAlias
        InterfaceFallbackUsed = $resolvedAdapter.UsedFallback
        NetworkingPath = $networkingRefresh.NetworkingPath
        NetworkingBindIp = $networkingRefresh.ResolvedP2pBindIp
        AgentStateRoot = $networkingRefresh.AgentStateRoot
        AgentLogRoot = $networkingRefresh.AgentLogRoot
        TransferRoot = (Join-Path $networkingRefresh.AgentStateRoot "overlord-ed2k-transfer")
        TargetServer = $targetServerSelection
        ControlPort = $networkingRefresh.ControlListenPort
        KadPort = $networkingRefresh.KadListenPort
        Ed2kPort = $networkingRefresh.Ed2kListenPort
        DumpcapPid = $dumpcap.Id
        DumpcapStdoutPath = $dumpcapStdoutPath
        DumpcapStderrPath = $dumpcapStderrPath
        AgentPid = $agentProcess.Id
        ControlUrl = "http://127.0.0.1:$($networkingRefresh.ControlListenPort)"
        StatsUrl = "http://127.0.0.1:$($networkingRefresh.ControlListenPort)/api/internal/stats"
        StartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $metadata | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM $metadataPath
    $metadata
}
catch {
    $cleanupArgs = @{
        CapturePort = $CapturePort
    }
    if ($agentProcess) {
        $cleanupArgs.AgentPids = @($agentProcess.Id)
    }
    if ($dumpcap) {
        $cleanupArgs.DumpcapPids = @($dumpcap.Id)
    }
    & $cleanupHelperPath @cleanupArgs | Out-Null
    throw
}

<#
.SYNOPSIS
Starts a fresh agent parity session with UDP capture and log window markers.
#>

[CmdletBinding()]
param(
    [int]$InterfaceIndex = 0,
    [string]$InterfaceAlias = "hide.me",
    [int]$CapturePort = 41000,
    [string]$SessionPrefix = "parity-agent"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
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
$startScriptPath = Join-Path $projectDir "overlord-agents\scripts\windows\agent_run_debug_direct.cmd"
$dumpcapPath = "C:\Program Files\Wireshark\dumpcap.exe"
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-agent-clean-runtime.ps1"
$refreshNetworkingHelperPath = Join-Path $PSScriptRoot "helper-agent-refresh-runtime-networking.ps1"

if (-not (Test-Path $startScriptPath)) {
    throw "Agent start script not found at $startScriptPath"
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

$InterfaceIndex = Resolve-DumpcapInterfaceIndex `
    -RequestedIndex $InterfaceIndex `
    -AdapterAlias $InterfaceAlias `
    -DumpcapPath $dumpcapPath

$networkingRefresh = & $refreshNetworkingHelperPath -InterfaceAlias $InterfaceAlias

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

    $launcher = Start-Process `
        -FilePath "cmd.exe" `
        -ArgumentList "/c", $startScriptPath `
        -WorkingDirectory $projectDir `
        -PassThru `
        -WindowStyle Hidden

    Start-Sleep -Seconds 2
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        $agentProcess = Get-Process -Name "overlord-agent-emule" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($agentProcess) {
            break
        }
        Start-Sleep -Seconds 1
    }

    if (-not $agentProcess) {
        throw "Agent process overlord-agent-emule.exe did not stay running after launch"
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
        InterfaceAlias = $InterfaceAlias
        NetworkingPath = $networkingRefresh.NetworkingPath
        NetworkingBindIp = $networkingRefresh.ResolvedP2pBindIp
        DumpcapPid = $dumpcap.Id
        DumpcapStdoutPath = $dumpcapStdoutPath
        DumpcapStderrPath = $dumpcapStderrPath
        AgentLauncherPid = $launcher.Id
        AgentPid = $agentProcess.Id
        StatsUrl = "http://127.0.0.1:13301/api/internal/stats"
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

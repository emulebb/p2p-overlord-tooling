<#
.SYNOPSIS
Starts a fresh agent parity session with UDP capture and log window markers.
#>

[CmdletBinding()]
param(
    [int]$InterfaceIndex = 6,
    [int]$CapturePort = 41000,
    [string]$SessionPrefix = "parity-agent"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Stop-DumpcapCapturePort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    # Allow concurrent parity captures for different runtimes by only stopping
    # dumpcap instances that were filtering the exact UDP port this session owns.
    $dumpcaps = Get-CimInstance Win32_Process -Filter "Name = 'dumpcap.exe'" -ErrorAction SilentlyContinue
    foreach ($dumpcap in @($dumpcaps)) {
        if ($null -eq $dumpcap.CommandLine) {
            continue
        }
        if ($dumpcap.CommandLine -notmatch "udp port\s+$Port(\D|$)") {
            continue
        }
        Stop-Process -Id $dumpcap.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

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
$startScriptPath = Join-Path $projectDir "overlord-agents\scripts\windows\agent_run_debug_direct.cmd"
$dumpcapPath = "C:\Program Files\Wireshark\dumpcap.exe"

if (-not (Test-Path $startScriptPath)) {
    throw "Agent start script not found at $startScriptPath"
}
if (-not (Test-Path $dumpcapPath)) {
    throw "dumpcap.exe not found at $dumpcapPath"
}

Get-Process -Name "overlord-agent-emule" -ErrorAction SilentlyContinue | Stop-Process -Force
Stop-DumpcapCapturePort -Port $CapturePort

$sessionName = "{0}-{1}" -f $SessionPrefix, (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

$pcapPath = Join-Path $sessionDir ("agent-{0}.pcapng" -f $CapturePort)
$metadataPath = Join-Path $sessionDir "agent-session.json"
$dumpcapStdoutPath = Join-Path $sessionDir "dumpcap-stdout.log"
$dumpcapStderrPath = Join-Path $sessionDir "dumpcap-stderr.log"

$logLinesBefore = 0
$logLengthBefore = 0
$logWriteTimeBefore = $null
if (Test-Path $agentLogPath) {
    $logInfo = Get-Item $agentLogPath
    $logLengthBefore = $logInfo.Length
    $logWriteTimeBefore = $logInfo.LastWriteTimeUtc
    $logLinesBefore = @(Get-Content $agentLogPath).Count
}

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
$agentProcess = $null
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

$metadata = [pscustomobject]@{
    SessionDir = $sessionDir
    SessionName = $sessionName
    AgentLogPath = $agentLogPath
    LogLinesBefore = $logLinesBefore
    LogLengthBefore = $logLengthBefore
    LogWriteTimeBeforeUtc = if ($logWriteTimeBefore) { $logWriteTimeBefore.ToString("o") } else { $null }
    CapturePath = $pcapPath
    CapturePort = $CapturePort
    InterfaceIndex = $InterfaceIndex
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

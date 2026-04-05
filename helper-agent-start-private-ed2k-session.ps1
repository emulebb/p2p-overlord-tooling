<#
.SYNOPSIS
Starts a private local-only agent session for one oracle download scenario.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenarioRoot,
    [Parameter(Mandatory = $true)]
    [string]$OracleBootstrapNode,
    [UInt16]$ControlPort = 13301,
    [UInt16]$KadPort = 41120,
    [UInt16]$Ed2kPort = 41121,
    [int]$LaunchTimeoutSeconds = 300,
    [switch]$EnableObfuscation
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

$cleanupHelperPath = Join-Path $PSScriptRoot "helper-agent-clean-runtime.ps1"
$configWriterPath = Join-Path $PSScriptRoot "helper-agent-write-private-local-config.ps1"
$startScriptPath = Join-Path $projectDir "overlord-agents\scripts\windows\agent_run_debug_direct.cmd"

foreach ($requiredPath in @($cleanupHelperPath, $configWriterPath, $startScriptPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required helper path not found at $requiredPath"
    }
}

& $cleanupHelperPath -CapturePort 0 | Out-Null

$configWriterParams = @{
    ScenarioRoot = $ScenarioRoot
    OracleBootstrapNode = $OracleBootstrapNode
    ControlPort = $ControlPort
    KadPort = $KadPort
    Ed2kPort = $Ed2kPort
}
if ($EnableObfuscation) {
    $configWriterParams.EnableObfuscation = $true
}
$configResult = & $configWriterPath @configWriterParams

$sessionName = "private-agent-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$metadataPath = Join-Path $sessionDir "agent-session.json"
$sessionStartUtc = (Get-Date).ToUniversalTime()
$agentProcess = $null

try {
    $launcher = Start-Process `
        -FilePath "cmd.exe" `
        -ArgumentList "/c", $startScriptPath `
        -WorkingDirectory $projectDir `
        -PassThru `
        -WindowStyle Hidden

    Start-Sleep -Seconds 2
    $deadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $agentProcess = Get-Process -Name "overlord-agent-emule" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($agentProcess) {
            break
        }
        Start-Sleep -Seconds 1
    }

    if (-not $agentProcess) {
        throw "Agent process overlord-agent-emule.exe did not stay running within $LaunchTimeoutSeconds seconds after launch"
    }

    $metadata = [pscustomobject]@{
        SessionDir = $sessionDir
        SessionName = $sessionName
        StateRoot = $configResult.StateRoot
        LogRoot = $configResult.LogRoot
        ConfigPath = $configResult.ConfigPath
        ConfigBackupPath = $configResult.BackupPath
        CapturePath = $null
        CapturePort = 0
        AgentLogPath = (Join-Path $configResult.LogRoot "overlord-agent-emule.log")
        PacketDumpPath = $null
        ControlUrl = "http://127.0.0.1:$ControlPort"
        StatsUrl = "http://127.0.0.1:$ControlPort/api/internal/stats"
        ControlPort = $ControlPort
        KadPort = $KadPort
        Ed2kPort = $Ed2kPort
        TransferRoot = (Join-Path $configResult.StateRoot "overlord-ed2k-transfer")
        AgentLauncherPid = $launcher.Id
        AgentPid = $agentProcess.Id
        StartedAtUtc = $sessionStartUtc.ToString("o")
    }
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

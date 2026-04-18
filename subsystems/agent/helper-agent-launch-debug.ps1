#Requires -Version 7.6
<#
.SYNOPSIS
Builds and launches the overlord-agent-emule debug binary.

.DESCRIPTION
Invokes cargo build for the overlord-agent-emule binary, then starts the
resulting executable minimized. Returns a result object with the agent PID,
exe path, and config path so callers can track the process without a poll loop.

The config must already exist at $OVERLORD_TMP_DIR\agent-real-miniupnpc.toml
before calling this helper (use helper-agent-write-private-local-config.ps1).
#>

[CmdletBinding()]
param(
    [string]$LogRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$overlordProjectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    throw "OVERLORD_PROJECT_DIR is not set"
}
$overlordTmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}

$agentsWorkspaceDir = Join-Path $overlordProjectDir "p2p-overlord-agents"
$agentExePath = Join-Path $agentsWorkspaceDir "target\debug\overlord-agent-emule.exe"
$configPath = Join-Path $overlordTmpDir "agent-real-miniupnpc.toml"
$resolvedLogRoot = if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    if ([string]::IsNullOrWhiteSpace($env:OVERLORD_LOG_DIR)) {
        $null
    } else {
        [System.IO.Path]::GetFullPath($env:OVERLORD_LOG_DIR)
    }
} else {
    [System.IO.Path]::GetFullPath($LogRoot)
}

if (-not (Test-Path -LiteralPath $agentsWorkspaceDir)) {
    throw "Agent workspace directory not found at $agentsWorkspaceDir"
}
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Agent config not found at $configPath — run helper-agent-write-private-local-config.ps1 first"
}

Push-Location $agentsWorkspaceDir
try {
    & cargo build -p overlord-agent-emule --bin overlord-agent-emule
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $agentExePath)) {
    throw "Agent executable not found at $agentExePath after build"
}

$processEnvironment = @{
    RUST_BACKTRACE = "1"
}
if (-not [string]::IsNullOrWhiteSpace($resolvedLogRoot)) {
    New-Item -ItemType Directory -Path $resolvedLogRoot -Force | Out-Null
    $processEnvironment["OVERLORD_LOG_DIR"] = $resolvedLogRoot
}

$agentProcess = Start-Process `
    -FilePath $agentExePath `
    -ArgumentList "--config", $configPath `
    -WorkingDirectory $agentsWorkspaceDir `
    -Environment $processEnvironment `
    -PassThru `
    -WindowStyle Minimized

[pscustomobject]@{
    AgentExePath = $agentExePath
    AgentPid     = $agentProcess.Id
    ConfigPath   = $configPath
    LogRoot      = $resolvedLogRoot
}

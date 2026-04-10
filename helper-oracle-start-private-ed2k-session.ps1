<#
.SYNOPSIS
Starts one minimized eMule oracle for a private Kad+ED2K run.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileRoot,
    [Parameter(Mandatory = $true)]
    [string]$SeedFilePath,
    [Parameter(Mandatory = $true)]
    [string]$ExportLinkPath,
    [Parameter(Mandatory = $true)]
    [string]$AgentBootstrapNode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}

$oracleHarnessDebugDir = & (Join-Path $PSScriptRoot "helper-oracle-resolve-harness-debug-dir.ps1")
$oracleExePath = Join-Path $oracleHarnessDebugDir "eMule_v072a_parity.exe"
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-oracle-clean-runtime.ps1"

if (-not (Test-Path -LiteralPath $oracleExePath)) {
    throw "Oracle executable not found at $oracleExePath — run helper-oracle-build-debug.ps1 first"
}
if (-not (Test-Path -LiteralPath $cleanupHelperPath)) {
    throw "Oracle cleanup helper not found at $cleanupHelperPath"
}
if (-not (Test-Path -LiteralPath $SeedFilePath)) {
    throw "Seed file not found at $SeedFilePath"
}

$profile = [System.IO.Path]::GetFullPath($ProfileRoot)
$readyFile = Join-Path $profile "harness.ready"
$logsRoot = Join-Path $profile "logs"
$traceLogPath = Join-Path $logsRoot "oracle-kad-trace.log"
$verboseLogPath = Join-Path $logsRoot "eMule_Verbose.log"
$statusLogPath = Join-Path $profile "status.log"

& $cleanupHelperPath -CapturePort 0 | Out-Null

$sessionName = "private-oracle-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$metadataPath = Join-Path $sessionDir "oracle-session.json"
$sessionStartUtc = (Get-Date).ToUniversalTime()

foreach ($path in @($readyFile, $ExportLinkPath, $statusLogPath)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

$traceLinesBefore = if (Test-Path -LiteralPath $traceLogPath) { @(Get-Content $traceLogPath).Count } else { 0 }
$oracleProcess = Start-Process `
    -FilePath $oracleExePath `
    -WorkingDirectory $oracleHarnessDebugDir `
    -ArgumentList @(
        "-AutoStart",
        "-configdir=""$profile""",
        "-bootstrap=""$AgentBootstrapNode""",
        "-readyfile=""$readyFile""",
        "-sharefile=""$SeedFilePath""",
        "-exportlinkfile=""$ExportLinkPath""",
        "-exportsourceip=""127.0.0.1""",
        "-ignoreinstances"
    ) `
    -PassThru `
    -WindowStyle Minimized

$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $readyFile) {
        break
    }
    Start-Sleep -Milliseconds 250
}
if (-not (Test-Path -LiteralPath $readyFile)) {
    & $cleanupHelperPath -CapturePort 0 -OraclePids @($oracleProcess.Id) | Out-Null
    throw "Timed out waiting for oracle readiness marker at $readyFile"
}

$udpDumpPath = Get-ChildItem -LiteralPath $logsRoot -Filter "oracle-udp-dump-*.jsonl" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -ge $sessionStartUtc.AddSeconds(-5) } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1 -ExpandProperty FullName
$ed2kDumpPath = Get-ChildItem -LiteralPath $logsRoot -Filter "oracle-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -ge $sessionStartUtc.AddSeconds(-5) } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1 -ExpandProperty FullName

$metadata = [pscustomobject]@{
    SessionDir = $sessionDir
    SessionName = $sessionName
    OraclePid = $oracleProcess.Id
    OracleExePath = $oracleExePath
    OracleProfileRoot = $profile
    SeedFilePath = $SeedFilePath
    ExportLinkPath = $ExportLinkPath
    ReadyFile = $readyFile
    StatusLogPath = $statusLogPath
    TraceLogPath = $traceLogPath
    TraceLinesBefore = $traceLinesBefore
    VerboseLogPath = $verboseLogPath
    CapturePath = $null
    CapturePort = 0
    PacketDumpPath = $udpDumpPath
    OracleUdpDumpPath = $udpDumpPath
    OracleEd2kTcpDumpPath = $ed2kDumpPath
    AgentBootstrapNode = $AgentBootstrapNode
    StartedAtUtc = $sessionStartUtc.ToString("o")
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8NoBOM $metadataPath
$metadata

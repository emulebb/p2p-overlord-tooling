<#
.SYNOPSIS
Starts one minimized experimental eMule oracle for a private Kad+ED2K run.
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
    [string]$AgentBootstrapNode,
    [ValidateSet("Debug", "Release")]
    [string]$BuildConfig = "Debug",
    [string]$OracleWorkspaceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-OracleWorkspaceRoot {
    param(
        [string]$ExplicitRoot
    )

    if ($ExplicitRoot) {
        return [System.IO.Path]::GetFullPath($ExplicitRoot)
    }

    $workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    return [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot "..\eMule\eMulebb\eMule-build-v0.60"))
}

$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}

$oracleRoot = Resolve-OracleWorkspaceRoot -ExplicitRoot $OracleWorkspaceRoot
$oracleWorkspaceScript = Join-Path $oracleRoot "workspace.ps1"
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-oracle-clean-runtime.ps1"
foreach ($requiredPath in @($oracleWorkspaceScript, $cleanupHelperPath, $SeedFilePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required oracle path not found at $requiredPath"
    }
}

$oracleExePath = Join-Path $oracleRoot ("eMule-v0.60d-experimental-clean\srchybrid\x64\{0}\emule.exe" -f $BuildConfig)
if (-not (Test-Path -LiteralPath $oracleExePath)) {
    & pwsh -NoProfile -File $oracleWorkspaceScript build-experimental -Config $BuildConfig | Out-Null
}
if (-not (Test-Path -LiteralPath $oracleExePath)) {
    throw "Experimental oracle executable not found at $oracleExePath"
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
    -WorkingDirectory (Split-Path -Parent $oracleExePath) `
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

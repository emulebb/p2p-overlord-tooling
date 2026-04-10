#Requires -Version 7.6
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
    [string]$AgentBootstrapNode,
    [ValidateSet("Debug", "Release")]
    [string]$BuildConfig = "Debug"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-DirectoryPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\')
}

$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}

$readyReaderPath = Join-Path $PSScriptRoot "helper-oracle-read-ready-file.ps1"
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-oracle-clean-runtime.ps1"

function Resolve-OracleHarnessDir {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Debug", "Release")]
        [string]$Configuration
    )

    $emuleWorkspaceRoot = if ($env:EMULE_WORKSPACE_ROOT) {
        [System.IO.Path]::GetFullPath($env:EMULE_WORKSPACE_ROOT)
    } else {
        throw "EMULE_WORKSPACE_ROOT is not set"
    }

    $buildManifestPath = Join-Path $emuleWorkspaceRoot "repos\eMule-build\deps.psd1"
    if (-not (Test-Path -LiteralPath $buildManifestPath -PathType Leaf)) {
        throw "Canonical eMule-build manifest not found at $buildManifestPath"
    }

    $buildManifest = Import-PowerShellDataFile -LiteralPath $buildManifestPath
    $workspaceName = $buildManifest.Workspace.Name
    if ([string]::IsNullOrWhiteSpace($workspaceName)) {
        throw "Workspace name was not declared in $buildManifestPath"
    }

    $harnessDir = [System.IO.Path]::GetFullPath(
        (Join-Path $emuleWorkspaceRoot "workspaces\$workspaceName\app\eMule-v0.72a-tracing-harness\srchybrid\x64\$Configuration")
    )
    if (-not (Test-Path -LiteralPath $harnessDir -PathType Container)) {
        throw "eMule harness $Configuration directory not found at $harnessDir"
    }

    return $harnessDir
}

$oracleHarnessDir = Resolve-OracleHarnessDir -Configuration $BuildConfig
$oracleExePath = Join-Path $oracleHarnessDir "eMule_v072a_parity.exe"

if (-not (Test-Path -LiteralPath $oracleExePath)) {
    throw "eMule harness executable not found at $oracleExePath — run helper-oracle-build-debug.ps1 first"
}
if (-not (Test-Path -LiteralPath $cleanupHelperPath)) {
    throw "Oracle cleanup helper not found at $cleanupHelperPath"
}
if (-not (Test-Path -LiteralPath $readyReaderPath -PathType Leaf)) {
    throw "Oracle ready-file reader not found at $readyReaderPath"
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
$readyState = $null

foreach ($path in @($readyFile, $ExportLinkPath, $statusLogPath)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

$traceLinesBefore = if (Test-Path -LiteralPath $traceLogPath) { @(Get-Content $traceLogPath).Count } else { 0 }
$oracleProcess = Start-Process `
    -FilePath $oracleExePath `
    -WorkingDirectory $oracleHarnessDir `
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

$readyState = & $readyReaderPath -Path $readyFile
if ((Normalize-DirectoryPath -Path $readyState.ProfileRoot) -ne (Normalize-DirectoryPath -Path $profile)) {
    & $cleanupHelperPath -CapturePort 0 -OraclePids @($oracleProcess.Id) | Out-Null
    throw "Oracle reported profile root '$($readyState.ProfileRoot)' instead of '$profile'"
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
    OracleReadyState = $readyState
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

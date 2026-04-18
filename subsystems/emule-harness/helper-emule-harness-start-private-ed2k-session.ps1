#Requires -Version 7.6
<#
.SYNOPSIS
Starts one minimized eMule harness for a private Kad+ED2K run.

.DESCRIPTION
Launches the canonical debug tracing-harness parity binary for private and
roundtrip scenarios. The retained `BuildConfig` parameter is debug-only for
operator compatibility; this workspace does not support a separate Release
tracing-harness flow.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileRoot,
    [string]$SeedFilePath,
    [string]$ExportLinkPath,
    [string]$ExportAichPath,
    [string]$AgentBootstrapNode,
    [string]$ExportSourceIp,
    [string]$DownloadLinkPath,
    [string]$SearchTerm,
    [string]$SearchResultsPath,
    [string]$SearchDownloadHashPath,
    [ValidateSet("Debug")]
    [string]$BuildConfig = "Debug",
    [switch]$SkipRuntimeCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}

$readyReaderPath = Join-Path $PSScriptRoot "helper-emule-harness-read-ready-file.ps1"
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-emule-harness-clean-runtime.ps1"
$buildHelperPath = Join-Path $PSScriptRoot "helper-emule-harness-build-debug.ps1"
$debugDirResolverPath = Join-Path $PSScriptRoot "helper-emule-harness-resolve-harness-debug-dir.ps1"
$readyStateHelperPath = Join-Path $PSScriptRoot "EmuleHarnessReadyState.ps1"

foreach ($requiredPath in @($readyReaderPath, $cleanupHelperPath, $buildHelperPath, $debugDirResolverPath, $readyStateHelperPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required helper path not found at $requiredPath"
    }
}

. $readyStateHelperPath
Assert-EmuleHarnessDebugBuildConfig -BuildConfig $BuildConfig -ParameterName "BuildConfig"

if (-not [string]::IsNullOrWhiteSpace($SeedFilePath) -and -not (Test-Path -LiteralPath $SeedFilePath)) {
    throw "Seed file not found at $SeedFilePath"
}

$profile = [System.IO.Path]::GetFullPath($ProfileRoot)
$preferencesPath = Join-Path $profile "config\preferences.ini"
$readyFile = Join-Path $profile "harness.ready"
$parityHookConfigPath = Join-Path $profile "parity-hooks.v1.json"
$logsRoot = Join-Path $profile "logs"
$traceLogPath = Join-Path $logsRoot "emule-harness-kad-trace.log"
$verboseLogPath = Join-Path $logsRoot "eMule_Verbose.log"
$statusLogPath = Join-Path $profile "status.log"
$canonicalHarnessDebugDir = [System.IO.Path]::GetFullPath((& $debugDirResolverPath -AllowMissing))
$emuleHarnessExePath = Join-Path $canonicalHarnessDebugDir "eMule_v072a_parity.exe"

if (-not $SkipRuntimeCleanup) {
    & $cleanupHelperPath -CapturePort 0 | Out-Null
    $buildResult = & $buildHelperPath | Select-Object -Last 1
    if (-not $buildResult.RuntimeExePath) {
        throw "eMule harness build helper did not return a runtime executable path"
    }
    $emuleHarnessExePath = [System.IO.Path]::GetFullPath([string]$buildResult.RuntimeExePath)
}
elseif (-not (Test-Path -LiteralPath $emuleHarnessExePath -PathType Leaf)) {
    $buildResult = & $buildHelperPath | Select-Object -Last 1
    if (-not $buildResult.RuntimeExePath) {
        throw "eMule harness build helper did not return a runtime executable path"
    }
    $emuleHarnessExePath = [System.IO.Path]::GetFullPath([string]$buildResult.RuntimeExePath)
}

if (-not (Test-Path -LiteralPath $emuleHarnessExePath -PathType Leaf)) {
    throw "Canonical eMule harness parity executable not found at $emuleHarnessExePath"
}
if (-not (Test-Path -LiteralPath $preferencesPath -PathType Leaf)) {
    throw "preferences.ini not found at $preferencesPath"
}
$emuleHarnessDir = Split-Path -Parent $emuleHarnessExePath
$expectedReadyState = Get-ExpectedEmuleHarnessReadyState -PreferencesPath $preferencesPath -RuntimeRoot $profile

$sessionName = "private-emule-harness-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$metadataPath = Join-Path $sessionDir "emule-harness-session.json"
$sessionStartUtc = (Get-Date).ToUniversalTime()
$readyState = $null

foreach ($path in @($readyFile, $ExportLinkPath, $ExportAichPath, $statusLogPath)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

$traceLinesBefore = if (Test-Path -LiteralPath $traceLogPath) { @(Get-Content $traceLogPath).Count } else { 0 }
$emuleHarnessArgs = @(
    "-AutoStart",
    "-configdir=""$profile""",
    "-readyfile=""$readyFile""",
    "-ignoreinstances"
)
if (-not [string]::IsNullOrWhiteSpace($AgentBootstrapNode)) {
    $emuleHarnessArgs += ('-bootstrap="{0}"' -f $AgentBootstrapNode)
}
if (-not [string]::IsNullOrWhiteSpace($SeedFilePath)) {
    $emuleHarnessArgs += ('-sharefile="{0}"' -f $SeedFilePath)
}
if (-not [string]::IsNullOrWhiteSpace($ExportLinkPath)) {
    $emuleHarnessArgs += ('-exportlinkfile="{0}"' -f $ExportLinkPath)
}
if (-not [string]::IsNullOrWhiteSpace($ExportAichPath)) {
    $emuleHarnessArgs += ('-exportaichfile="{0}"' -f $ExportAichPath)
}
if (-not [string]::IsNullOrWhiteSpace($ExportSourceIp)) {
    $emuleHarnessArgs += ('-exportsourceip="{0}"' -f $ExportSourceIp)
}
if (-not [string]::IsNullOrWhiteSpace($DownloadLinkPath)) {
    $emuleHarnessArgs += ('-downloadlinkfile="{0}"' -f $DownloadLinkPath)
}
if (-not [string]::IsNullOrWhiteSpace($SearchTerm)) {
    $emuleHarnessArgs += ('-searchterm="{0}"' -f $SearchTerm)
}
if (-not [string]::IsNullOrWhiteSpace($SearchResultsPath)) {
    $emuleHarnessArgs += ('-searchresultsfile="{0}"' -f $SearchResultsPath)
}
if (-not [string]::IsNullOrWhiteSpace($SearchDownloadHashPath)) {
    $emuleHarnessArgs += ('-searchdownloadhashfile="{0}"' -f $SearchDownloadHashPath)
}
if (Test-Path -LiteralPath $parityHookConfigPath -PathType Leaf) {
    $emuleHarnessArgs += ('-hookconfigfile="{0}"' -f $parityHookConfigPath)
}

$emuleHarnessProcess = Start-Process `
    -FilePath $emuleHarnessExePath `
    -WorkingDirectory $emuleHarnessDir `
    -ArgumentList $emuleHarnessArgs `
    -PassThru `
    -WindowStyle Minimized

    Wait-EmuleHarnessReadyFile -ReadyFilePath $readyFile -EmuleHarnessProcess $emuleHarnessProcess
    $readyState = & $readyReaderPath -Path $readyFile
    Assert-EmuleHarnessReadyState `
        -ExpectedState $expectedReadyState `
        -ReadyState $readyState `
        -ExpectedEmuleHarnessPid $emuleHarnessProcess.Id

    $udpDumpPath = Get-ChildItem -LiteralPath $logsRoot -Filter "emule-harness-udp-dump-*.jsonl" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -ge $sessionStartUtc.AddSeconds(-5) } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1 -ExpandProperty FullName
$ed2kDumpPath = Get-ChildItem -LiteralPath $logsRoot -Filter "emule-harness-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -ge $sessionStartUtc.AddSeconds(-5) } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1 -ExpandProperty FullName

$metadata = [pscustomobject]@{
    SessionDir = $sessionDir
    SessionName = $sessionName
    EmuleHarnessPid = $emuleHarnessProcess.Id
    EmuleHarnessExePath = $emuleHarnessExePath
    EmuleHarnessProfileRoot = $profile
    EmuleHarnessReadyState = $readyState
    ParityHookConfigPath = if (Test-Path -LiteralPath $parityHookConfigPath -PathType Leaf) { $parityHookConfigPath } else { $null }
    ParityHookEventLogPath = $readyState.ParityHookEventsFile
    SeedFilePath = $SeedFilePath
    ExportLinkPath = $ExportLinkPath
    ExportAichPath = $ExportAichPath
    DownloadLinkPath = $DownloadLinkPath
    SearchTerm = $SearchTerm
    SearchResultsPath = $SearchResultsPath
    SearchDownloadHashPath = $SearchDownloadHashPath
    ReadyFile = $readyFile
    StatusLogPath = $statusLogPath
    TraceLogPath = $traceLogPath
    TraceLinesBefore = $traceLinesBefore
    VerboseLogPath = $verboseLogPath
    CapturePath = $null
    CapturePort = 0
    PacketDumpPath = $udpDumpPath
    EmuleHarnessUdpDumpPath = $udpDumpPath
    EmuleHarnessEd2kTcpDumpPath = $ed2kDumpPath
    AgentBootstrapNode = $AgentBootstrapNode
    StartedAtUtc = $sessionStartUtc.ToString("o")
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8NoBOM $metadataPath
$metadata

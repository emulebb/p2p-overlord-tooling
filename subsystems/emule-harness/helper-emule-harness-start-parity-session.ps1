#Requires -Version 7.6
<#
.SYNOPSIS
Starts a fresh eMule harness parity session using the rebuilt distinct parity eMule harness executable.
#>

[CmdletBinding()]
param(
    [string]$InterfaceAlias = "hide.me",
    [int]$CapturePort = 0,
    [string]$SessionPrefix = "parity-emule-harness",
    [int]$WaitAfterLaunchSeconds = 0,
    [string]$ProfileRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}
$oracleHarnessDebugDir = & (Join-Path $PSScriptRoot "helper-emule-harness-resolve-harness-debug-dir.ps1")
$readyStateHelperPath = Join-Path $PSScriptRoot "EmuleHarnessReadyState.ps1"
if (-not (Test-Path -LiteralPath $readyStateHelperPath -PathType Leaf)) {
    throw "eMule harness ready-state helper not found at $readyStateHelperPath"
}
. $readyStateHelperPath

function Resolve-DumpcapInterfaceIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdapterAlias,
        [Parameter(Mandatory = $true)]
        [string]$DumpcapPath
    )

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

function Resolve-EmuleHarnessCapturePort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreferencesPath,
        [Parameter(Mandatory = $true)]
        [int]$RequestedCapturePort
    )

    if ($RequestedCapturePort -gt 0) {
        return $RequestedCapturePort
    }

    if (-not (Test-Path $PreferencesPath)) {
        throw "eMule harness preferences not found at $PreferencesPath"
    }

    $configuredPortLine = Get-Content $PreferencesPath |
        Where-Object { $_ -match '^UDPPort=' } |
        Select-Object -First 1
    if (-not $configuredPortLine) {
        throw "Could not find UDPPort in $PreferencesPath"
    }

    $configuredPort = $configuredPortLine -replace '^UDPPort=', ''
    $parsedCapturePort = 0
    if (-not [int]::TryParse($configuredPort, [ref]$parsedCapturePort)) {
        throw "Configured UDPPort '$configuredPort' in $PreferencesPath is not a valid integer"
    }

    return $parsedCapturePort
}

$buildHelperPath = Join-Path $PSScriptRoot "helper-emule-harness-build-debug.ps1"
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-emule-harness-clean-runtime.ps1"
$readyReaderPath = Join-Path $PSScriptRoot "helper-emule-harness-read-ready-file.ps1"
$networkResolverPath = Join-Path $PSScriptRoot "..\network\helper-network-resolve-adapter.ps1"
$runtimeRoot = if ($ProfileRoot) {
    [System.IO.Path]::GetFullPath($ProfileRoot)
} else {
    $oracleHarnessDebugDir
}
$traceLogPath = Join-Path $runtimeRoot "logs\emule-harness-kad-trace.log"
$verboseLogPath = Join-Path $runtimeRoot "logs\eMule_Verbose.log"
$packetDumpDir = Join-Path $runtimeRoot "logs"
$preferencesPath = Join-Path $runtimeRoot "config\preferences.ini"
$readyFilePath = Join-Path $runtimeRoot "harness.ready"
$parityHookConfigPath = Join-Path $runtimeRoot "parity-hooks.v1.json"
$oracleWorkDir = $oracleHarnessDebugDir
$dumpcapPath = "C:\Program Files\Wireshark\dumpcap.exe"

if (-not (Test-Path $buildHelperPath)) {
    throw "eMule harness build helper not found at $buildHelperPath"
}
if (-not (Test-Path $cleanupHelperPath)) {
    throw "eMule harness cleanup helper not found at $cleanupHelperPath"
}
if (-not (Test-Path -LiteralPath $readyReaderPath -PathType Leaf)) {
    throw "eMule harness ready-file reader not found at $readyReaderPath"
}
if (-not (Test-Path -LiteralPath $networkResolverPath -PathType Leaf)) {
    throw "Network adapter resolver not found at $networkResolverPath"
}
if (-not (Test-Path $preferencesPath)) {
    throw "eMule harness preferences not found at $preferencesPath"
}
if (-not (Test-Path $dumpcapPath)) {
    throw "dumpcap.exe not found at $dumpcapPath"
}
$traceLogDir = Split-Path -Parent $traceLogPath
New-Item -ItemType Directory -Path $traceLogDir -Force | Out-Null

$resolvedAdapter = & $networkResolverPath -PreferredInterfaceAlias $InterfaceAlias
$resolvedInterfaceAlias = [string]$resolvedAdapter.InterfaceAlias
$expectedReadyState = Get-ExpectedEmuleHarnessReadyState -PreferencesPath $preferencesPath -RuntimeRoot $runtimeRoot
$CapturePort = Resolve-EmuleHarnessCapturePort -PreferencesPath $preferencesPath -RequestedCapturePort $CapturePort
$dumpcapInterfaceIndex = Resolve-DumpcapInterfaceIndex -AdapterAlias $resolvedInterfaceAlias -DumpcapPath $dumpcapPath

$prelaunchCleanupArgs = @{
    CapturePort = $CapturePort
}
& $cleanupHelperPath @prelaunchCleanupArgs | Out-Null
$buildResult = & $buildHelperPath | Select-Object -Last 1
$emuleHarnessExePath = $buildResult.RuntimeExePath
if (-not $emuleHarnessExePath -or -not (Test-Path $emuleHarnessExePath)) {
    throw "Parity eMule harness executable was not produced by the build helper"
}

$sessionName = "{0}-{1}" -f $SessionPrefix, (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

$pcapPath = Join-Path $sessionDir ("emule-harness-{0}.pcapng" -f $CapturePort)
$metadataPath = Join-Path $sessionDir "emule-harness-session.json"
$dumpcapStdoutPath = Join-Path $sessionDir "dumpcap-stdout.log"
$dumpcapStderrPath = Join-Path $sessionDir "dumpcap-stderr.log"
$sessionStartUtc = (Get-Date).ToUniversalTime()
$emuleHarnessProcess = $null
$dumpcap = $null
$readyState = $null

$traceLinesBefore = 0
$traceLengthBefore = 0
$traceWriteTimeBefore = $null
if (Test-Path $traceLogPath) {
    $traceInfo = Get-Item $traceLogPath
    $traceLengthBefore = $traceInfo.Length
    $traceWriteTimeBefore = $traceInfo.LastWriteTimeUtc
    $traceLinesBefore = @(Get-Content $traceLogPath).Count
}

try {
    if (Test-Path -LiteralPath $readyFilePath) {
        Remove-Item -LiteralPath $readyFilePath -Force -ErrorAction SilentlyContinue
    }

    $dumpcap = Start-Process `
        -FilePath $dumpcapPath `
        -ArgumentList "-i $dumpcapInterfaceIndex -f `"udp port $CapturePort`" -w `"$pcapPath`"" `
        -PassThru `
        -RedirectStandardOutput $dumpcapStdoutPath `
        -RedirectStandardError $dumpcapStderrPath `
        -WindowStyle Hidden

    Start-Sleep -Seconds 2

    if ($dumpcap.HasExited) {
        $stderr = if (Test-Path $dumpcapStderrPath) {
            (Get-Content -Raw $dumpcapStderrPath).Trim()
        } else {
            ""
        }
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

    $emuleHarnessArgs = @(
        "-configdir=""$runtimeRoot""",
        "-readyfile=""$readyFilePath""",
        "-ignoreinstances"
    )
    if (Test-Path -LiteralPath $parityHookConfigPath -PathType Leaf) {
        $emuleHarnessArgs += "-hookconfigfile=""$parityHookConfigPath"""
    }

    $emuleHarnessProcess = Start-Process `
        -FilePath $emuleHarnessExePath `
        -ArgumentList $emuleHarnessArgs `
        -WorkingDirectory $oracleWorkDir `
        -PassThru `
        -WindowStyle Minimized

    Wait-EmuleHarnessReadyFile -ReadyFilePath $readyFilePath -EmuleHarnessProcess $emuleHarnessProcess
    $readyState = & $readyReaderPath -Path $readyFilePath
    Assert-EmuleHarnessReadyState -ExpectedState $expectedReadyState -ReadyState $readyState -ExpectedEmuleHarnessPid $emuleHarnessProcess.Id -ExpectedCapturePort $CapturePort

    if ($WaitAfterLaunchSeconds -gt 0) {
        Start-Sleep -Seconds $WaitAfterLaunchSeconds
    }

    $packetDumpPath = Get-ChildItem -Path $packetDumpDir -Filter 'emule-harness-udp-dump-*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $sessionStartUtc.AddSeconds(-5) } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName

    $metadata = [pscustomobject]@{
        SessionDir = $sessionDir
        SessionName = $sessionName
        TraceLogPath = $traceLogPath
        VerboseLogPath = $verboseLogPath
        PacketDumpPath = $packetDumpPath
        TraceLinesBefore = $traceLinesBefore
        TraceLengthBefore = $traceLengthBefore
        TraceWriteTimeBeforeUtc = if ($traceWriteTimeBefore) { $traceWriteTimeBefore.ToString("o") } else { $null }
        CapturePath = $pcapPath
        CapturePort = $CapturePort
        RequestedInterfaceAlias = $InterfaceAlias
        InterfaceAlias = $resolvedInterfaceAlias
        InterfaceFallbackUsed = $resolvedAdapter.UsedFallback
        DumpcapInterfaceIndex = $dumpcapInterfaceIndex
        DumpcapPid = $dumpcap.Id
        DumpcapStdoutPath = $dumpcapStdoutPath
        DumpcapStderrPath = $dumpcapStderrPath
        EmuleHarnessExePath = $emuleHarnessExePath
        EmuleHarnessProfileRoot = $runtimeRoot
        EmuleHarnessReadyFilePath = $readyFilePath
        EmuleHarnessReadyState = $readyState
        ParityHookConfigPath = if (Test-Path -LiteralPath $parityHookConfigPath -PathType Leaf) { $parityHookConfigPath } else { $null }
        ParityHookEventLogPath = $readyState.ParityHookEventsFile
        EmuleHarnessPid = $emuleHarnessProcess.Id
        StartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $metadata | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM $metadataPath
    $metadata
}
catch {
    $cleanupArgs = @{
        CapturePort = $CapturePort
    }
    if ($emuleHarnessProcess) {
        $cleanupArgs.EmuleHarnessPids = @($emuleHarnessProcess.Id)
    }
    if ($dumpcap) {
        $cleanupArgs.DumpcapPids = @($dumpcap.Id)
    }
    & $cleanupHelperPath @cleanupArgs | Out-Null
    throw
}

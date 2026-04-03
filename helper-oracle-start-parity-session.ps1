<#
.SYNOPSIS
Starts a fresh oracle parity session using the rebuilt distinct parity oracle executable.
#>

[CmdletBinding()]
param(
    [string]$InterfaceAlias = "hide.me",
    [int]$CapturePort = 0,
    [string]$SessionPrefix = "parity-oracle",
    [int]$WaitAfterLaunchSeconds = 0,
    [string]$ProfileRoot
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

function Resolve-OracleCapturePort {
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
        throw "Oracle preferences not found at $PreferencesPath"
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

$buildHelperPath = Join-Path $PSScriptRoot "helper-oracle-build-debug.ps1"
$cleanupHelperPath = Join-Path $PSScriptRoot "helper-oracle-clean-runtime.ps1"
$runtimeRoot = if ($ProfileRoot) {
    [System.IO.Path]::GetFullPath($ProfileRoot)
} else {
    Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug"
}
$traceLogPath = Join-Path $runtimeRoot "logs\oracle-kad-trace.log"
$verboseLogPath = Join-Path $runtimeRoot "logs\eMule_Verbose.log"
$packetDumpDir = Join-Path $runtimeRoot "logs"
$preferencesPath = Join-Path $runtimeRoot "config\preferences.ini"
$oracleWorkDir = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug"
$dumpcapPath = "C:\Program Files\Wireshark\dumpcap.exe"

if (-not (Test-Path $buildHelperPath)) {
    throw "Oracle build helper not found at $buildHelperPath"
}
if (-not (Test-Path $cleanupHelperPath)) {
    throw "Oracle cleanup helper not found at $cleanupHelperPath"
}
if (-not (Test-Path $preferencesPath)) {
    throw "Oracle preferences not found at $preferencesPath"
}
if (-not (Test-Path $dumpcapPath)) {
    throw "dumpcap.exe not found at $dumpcapPath"
}
$traceLogDir = Split-Path -Parent $traceLogPath
New-Item -ItemType Directory -Path $traceLogDir -Force | Out-Null

$CapturePort = Resolve-OracleCapturePort -PreferencesPath $preferencesPath -RequestedCapturePort $CapturePort
$dumpcapInterfaceIndex = Resolve-DumpcapInterfaceIndex -AdapterAlias $InterfaceAlias -DumpcapPath $dumpcapPath

$prelaunchCleanupArgs = @{
    CapturePort = $CapturePort
}
& $cleanupHelperPath @prelaunchCleanupArgs | Out-Null
$buildResult = & $buildHelperPath | Select-Object -Last 1
$oracleExePath = $buildResult.RuntimeExePath
if (-not $oracleExePath -or -not (Test-Path $oracleExePath)) {
    throw "Parity oracle executable was not produced by the build helper"
}

$sessionName = "{0}-{1}" -f $SessionPrefix, (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

$pcapPath = Join-Path $sessionDir ("oracle-{0}.pcapng" -f $CapturePort)
$metadataPath = Join-Path $sessionDir "oracle-session.json"
$dumpcapStdoutPath = Join-Path $sessionDir "dumpcap-stdout.log"
$dumpcapStderrPath = Join-Path $sessionDir "dumpcap-stderr.log"
$sessionStartUtc = (Get-Date).ToUniversalTime()
$oracleProcess = $null
$dumpcap = $null

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

    Start-Process `
        -FilePath $oracleExePath `
        -ArgumentList @(if ($ProfileRoot) { @("-c", $runtimeRoot) } else { @() }) `
        -WorkingDirectory $oracleWorkDir `
        -PassThru `
        -WindowStyle Hidden | Out-Null

    Start-Sleep -Seconds 2
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        $oracleProcess = Get-Process -Name "eMule_v060_parity" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($oracleProcess) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $oracleProcess) {
        throw "Parity oracle process did not stay running after launch"
    }

    if ($WaitAfterLaunchSeconds -gt 0) {
        Start-Sleep -Seconds $WaitAfterLaunchSeconds
    }

    $packetDumpPath = Get-ChildItem -Path $packetDumpDir -Filter 'oracle-udp-dump-*.jsonl' -ErrorAction SilentlyContinue |
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
        InterfaceAlias = $InterfaceAlias
        DumpcapInterfaceIndex = $dumpcapInterfaceIndex
        DumpcapPid = $dumpcap.Id
        DumpcapStdoutPath = $dumpcapStdoutPath
        DumpcapStderrPath = $dumpcapStderrPath
        OracleExePath = $oracleExePath
        OracleProfileRoot = $runtimeRoot
        OraclePid = $oracleProcess.Id
        StartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $metadata | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM $metadataPath
    $metadata
}
catch {
    $cleanupArgs = @{
        CapturePort = $CapturePort
    }
    if ($oracleProcess) {
        $cleanupArgs.OraclePids = @($oracleProcess.Id)
    }
    if ($dumpcap) {
        $cleanupArgs.DumpcapPids = @($dumpcap.Id)
    }
    & $cleanupHelperPath @cleanupArgs | Out-Null
    throw
}

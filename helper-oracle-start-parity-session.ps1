<#
.SYNOPSIS
Starts a fresh oracle parity session using the debug-local oracle executable.
#>

[CmdletBinding()]
param(
    [string]$InterfaceAlias = "hide.me",
    [int]$CapturePort = 0,
    [string]$SessionPrefix = "parity-oracle",
    [int]$WaitAfterLaunchSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Stop-DumpcapCapturePort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    # Keep the agent and oracle captures alive together by only stopping the
    # dumpcap instance that was already filtering this oracle UDP port.
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

$traceLogPath = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug\logs\oracle-kad-trace.log"
$verboseLogPath = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug\logs\eMule_Verbose.log"
$preferencesPath = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug\config\preferences.ini"
$oracleExePath = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug\eMule_debug_loc.exe"
$oracleWorkDir = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug"
$dumpcapPath = "C:\Program Files\Wireshark\dumpcap.exe"

if (-not (Test-Path $oracleExePath)) {
    throw "Oracle debug executable not found at $oracleExePath"
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

Get-Process -Name "eMule_debug_loc", "emule" -ErrorAction SilentlyContinue | Stop-Process -Force
Stop-DumpcapCapturePort -Port $CapturePort

$sessionName = "{0}-{1}" -f $SessionPrefix, (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

$pcapPath = Join-Path $sessionDir ("oracle-{0}.pcapng" -f $CapturePort)
$metadataPath = Join-Path $sessionDir "oracle-session.json"
$dumpcapStdoutPath = Join-Path $sessionDir "dumpcap-stdout.log"
$dumpcapStderrPath = Join-Path $sessionDir "dumpcap-stderr.log"

$traceLinesBefore = 0
$traceLengthBefore = 0
$traceWriteTimeBefore = $null
if (Test-Path $traceLogPath) {
    $traceInfo = Get-Item $traceLogPath
    $traceLengthBefore = $traceInfo.Length
    $traceWriteTimeBefore = $traceInfo.LastWriteTimeUtc
    $traceLinesBefore = @(Get-Content $traceLogPath).Count
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

$oracleCmd = Start-Process `
    -FilePath $oracleExePath `
    -WorkingDirectory $oracleWorkDir `
    -PassThru `
    -WindowStyle Hidden

Start-Sleep -Seconds 2
$oracleProcess = $null
for ($attempt = 0; $attempt -lt 45; $attempt++) {
    $oracleProcess = Get-Process -Name "eMule_debug_loc", "eMule", "emule" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oracleProcess) {
        break
    }
    Start-Sleep -Seconds 1
}
if (-not $oracleProcess) {
    throw "Oracle process did not stay running after launch"
}

if ($WaitAfterLaunchSeconds -gt 0) {
    Start-Sleep -Seconds $WaitAfterLaunchSeconds
}

$metadata = [pscustomobject]@{
    SessionDir = $sessionDir
    SessionName = $sessionName
    TraceLogPath = $traceLogPath
    VerboseLogPath = $verboseLogPath
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
    OraclePid = $oracleProcess.Id
    StartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

$metadata | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM $metadataPath
$metadata

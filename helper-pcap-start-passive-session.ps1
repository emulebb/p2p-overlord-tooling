<#
.SYNOPSIS
Starts a passive UDP capture session without launching or stopping the target process.
#>

[CmdletBinding()]
param(
    [int]$InterfaceIndex = 6,
    [int]$CapturePort = 46663,
    [string]$SessionPrefix = "parity-passive",
    [string]$CaptureLabel = "emule-loc"
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

$dumpcapPath = "C:\Program Files\Wireshark\dumpcap.exe"
if (-not (Test-Path $dumpcapPath)) {
    throw "dumpcap.exe not found at $dumpcapPath"
}

$sessionName = "{0}-{1}" -f $SessionPrefix, (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

$pcapPath = Join-Path $sessionDir ("{0}-{1}.pcapng" -f $CaptureLabel, $CapturePort)
$metadataPath = Join-Path $sessionDir "pcap-session.json"
$dumpcapStdoutPath = Join-Path $sessionDir "dumpcap-stdout.log"
$dumpcapStderrPath = Join-Path $sessionDir "dumpcap-stderr.log"

$dumpcap = Start-Process `
    -FilePath $dumpcapPath `
    -ArgumentList "-i $InterfaceIndex -f `"udp port $CapturePort`" -w `"$pcapPath`"" `
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

$metadata = [pscustomobject]@{
    SessionDir = $sessionDir
    SessionName = $sessionName
    ProjectDir = $projectDir
    CaptureLabel = $CaptureLabel
    CapturePath = $pcapPath
    CapturePort = $CapturePort
    InterfaceIndex = $InterfaceIndex
    DumpcapPid = $dumpcap.Id
    DumpcapStdoutPath = $dumpcapStdoutPath
    DumpcapStderrPath = $dumpcapStderrPath
    StartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

$metadata | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM $metadataPath
$metadata

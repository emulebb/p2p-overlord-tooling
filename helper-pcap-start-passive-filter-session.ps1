<#
.SYNOPSIS
Starts a passive packet capture session with a caller-provided BPF filter.

.DESCRIPTION
This helper never launches or stops the target application. It only starts a
background `dumpcap` session and records enough metadata to stop and analyze
the capture later with the existing passive stop helper.
#>

[CmdletBinding()]
param(
    [string]$InterfaceAlias = "hide.me",
    [int]$InterfaceIndex,
    [Parameter(Mandatory = $true)]
    [string]$CaptureFilter,
    [string]$SessionPrefix = "parity-passive",
    [string]$CaptureLabel = "capture"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-DumpcapInterfaceIndex {
    param(
        [int]$WindowsInterfaceIndex,
        [string]$AdapterAlias,
        [Parameter(Mandatory = $true)]
        [string]$DumpcapPath
    )

    if ($PSBoundParameters.ContainsKey("WindowsInterfaceIndex")) {
        $adapter = Get-NetAdapter -InterfaceIndex $WindowsInterfaceIndex -ErrorAction Stop
    } elseif ($PSBoundParameters.ContainsKey("AdapterAlias")) {
        $adapter = Get-NetAdapter -InterfaceAlias $AdapterAlias -ErrorAction Stop
    } else {
        throw "Either WindowsInterfaceIndex or AdapterAlias must be provided"
    }

    $dumpcapDevices = & $DumpcapPath -D
    foreach ($device in $dumpcapDevices) {
        if ($device -match '^(?<Index>\d+)\.\s+.+\((?<Name>.+)\)$') {
            if ($matches.Name -eq $adapter.Name) {
                return [int]$matches.Index
            }
        }
    }

    throw "Could not map Windows interface '$($adapter.Name)' to a dumpcap device index"
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

$dumpcapPath = "C:\Program Files\Wireshark\dumpcap.exe"
if (-not (Test-Path $dumpcapPath)) {
    throw "dumpcap.exe not found at $dumpcapPath"
}

$dumpcapInterfaceIndex = if ($PSBoundParameters.ContainsKey("InterfaceIndex")) {
    Resolve-DumpcapInterfaceIndex -WindowsInterfaceIndex $InterfaceIndex -DumpcapPath $dumpcapPath
} else {
    Resolve-DumpcapInterfaceIndex -AdapterAlias $InterfaceAlias -DumpcapPath $dumpcapPath
}

$sessionName = "{0}-{1}" -f $SessionPrefix, (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

$pcapPath = Join-Path $sessionDir ("{0}.pcapng" -f $CaptureLabel)
$metadataPath = Join-Path $sessionDir "pcap-session.json"
$dumpcapStdoutPath = Join-Path $sessionDir "dumpcap-stdout.log"
$dumpcapStderrPath = Join-Path $sessionDir "dumpcap-stderr.log"

$dumpcap = Start-Process `
    -FilePath $dumpcapPath `
    -ArgumentList "-i $dumpcapInterfaceIndex -f `"$CaptureFilter`" -w `"$pcapPath`"" `
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
    CaptureFilter = $CaptureFilter
    InterfaceAlias = if ($PSBoundParameters.ContainsKey("InterfaceIndex")) { $null } else { $InterfaceAlias }
    InterfaceIndex = if ($PSBoundParameters.ContainsKey("InterfaceIndex")) { $InterfaceIndex } else { $null }
    DumpcapInterfaceIndex = $dumpcapInterfaceIndex
    DumpcapPid = $dumpcap.Id
    DumpcapStdoutPath = $dumpcapStdoutPath
    DumpcapStderrPath = $dumpcapStderrPath
    StartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

$metadata | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM $metadataPath
$metadata

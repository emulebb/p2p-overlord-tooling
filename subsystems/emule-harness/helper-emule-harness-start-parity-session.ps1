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

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}
$oracleHarnessDebugDir = & (Join-Path $PSScriptRoot "helper-emule-harness-resolve-harness-debug-dir.ps1")

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

function Normalize-DirectoryPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\')
}

function Get-PreferencesValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreferencesPath,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $escapedKey = [regex]::Escape($Key)
    $matchedLine = Get-Content -LiteralPath $PreferencesPath |
        Where-Object { $_ -match "^(?:$escapedKey)=" } |
        Select-Object -First 1
    if (-not $matchedLine) {
        throw "Could not find $Key in $PreferencesPath"
    }

    return ($matchedLine -replace "^(?:$escapedKey)=", "")
}

function Get-ExpectedEmuleHarnessReadyState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreferencesPath,
        [Parameter(Mandatory = $true)]
        [string]$RuntimeRoot
    )

    $runtimeRootPath = [System.IO.Path]::GetFullPath($RuntimeRoot)

    [pscustomobject]@{
        ProfileRoot = Normalize-DirectoryPath -Path $runtimeRootPath
        ConfigDir = Normalize-DirectoryPath -Path (Join-Path $runtimeRootPath "config")
        TcpPort = [int](Get-PreferencesValue -PreferencesPath $PreferencesPath -Key "Port")
        UdpPort = [int](Get-PreferencesValue -PreferencesPath $PreferencesPath -Key "UDPPort")
        ServerUdpPort = [int](Get-PreferencesValue -PreferencesPath $PreferencesPath -Key "ServerUDPPort")
        NetworkEd2k = [int](Get-PreferencesValue -PreferencesPath $PreferencesPath -Key "NetworkED2K")
        NetworkKademlia = [int](Get-PreferencesValue -PreferencesPath $PreferencesPath -Key "NetworkKademlia")
        Autoconnect = [int](Get-PreferencesValue -PreferencesPath $PreferencesPath -Key "Autoconnect")
        BindAddr = [string](Get-PreferencesValue -PreferencesPath $PreferencesPath -Key "BindAddr")
    }
}

function Wait-EmuleHarnessReadyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReadyFilePath,
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$EmuleHarnessProcess,
        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ReadyFilePath -PathType Leaf) {
            return
        }
        if (-not (Get-Process -Id $EmuleHarnessProcess.Id -ErrorAction SilentlyContinue)) {
            throw "Parity eMule harness process (PID $($EmuleHarnessProcess.Id)) exited before writing $ReadyFilePath"
        }
        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for eMule harness readiness marker at $ReadyFilePath"
}

function Assert-EmuleHarnessReadyState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExpectedState,
        [Parameter(Mandatory = $true)]
        [object]$ReadyState,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedEmuleHarnessPid,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedCapturePort
    )

    $mismatches = [System.Collections.Generic.List[string]]::new()

    if ($ReadyState.State -ne "ready") {
        $mismatches.Add("state=$($ReadyState.State)") | Out-Null
    }
    if ($ReadyState.Pid -ne $ExpectedEmuleHarnessPid) {
        $mismatches.Add("pid=$($ReadyState.Pid)") | Out-Null
    }
    if ((Normalize-DirectoryPath -Path $ReadyState.ProfileRoot) -ne $ExpectedState.ProfileRoot) {
        $mismatches.Add("profile_root=$($ReadyState.ProfileRoot)") | Out-Null
    }
    if ((Normalize-DirectoryPath -Path $ReadyState.ConfigDir) -ne $ExpectedState.ConfigDir) {
        $mismatches.Add("config_dir=$($ReadyState.ConfigDir)") | Out-Null
    }
    if ($ReadyState.TcpPort -ne $ExpectedState.TcpPort) {
        $mismatches.Add("tcp_port=$($ReadyState.TcpPort)") | Out-Null
    }
    if ($ReadyState.UdpPort -ne $ExpectedState.UdpPort) {
        $mismatches.Add("udp_port=$($ReadyState.UdpPort)") | Out-Null
    }
    if ($ReadyState.ServerUdpPort -ne $ExpectedState.ServerUdpPort) {
        $mismatches.Add("server_udp_port=$($ReadyState.ServerUdpPort)") | Out-Null
    }
    if ($ReadyState.NetworkEd2k -ne $ExpectedState.NetworkEd2k) {
        $mismatches.Add("network_ed2k=$($ReadyState.NetworkEd2k)") | Out-Null
    }
    if ($ReadyState.NetworkKademlia -ne $ExpectedState.NetworkKademlia) {
        $mismatches.Add("network_kademlia=$($ReadyState.NetworkKademlia)") | Out-Null
    }
    if ($ReadyState.Autoconnect -ne $ExpectedState.Autoconnect) {
        $mismatches.Add("autoconnect=$($ReadyState.Autoconnect)") | Out-Null
    }
    if ([string]$ReadyState.BindAddr -ne [string]$ExpectedState.BindAddr) {
        $mismatches.Add("bind_addr=$($ReadyState.BindAddr)") | Out-Null
    }
    if ($ReadyState.UdpPort -ne $ExpectedCapturePort) {
        $mismatches.Add("capture_port=$ExpectedCapturePort observed_udp_port=$($ReadyState.UdpPort)") | Out-Null
    }
    if ($ReadyState.ParityMode -ne 1) {
        $mismatches.Add("parity_mode=$($ReadyState.ParityMode)") | Out-Null
    }

    if ($mismatches.Count -gt 0) {
        throw "eMule harness readiness validation failed: $($mismatches -join '; ')"
    }
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

    $emuleHarnessProcess = Start-Process `
        -FilePath $emuleHarnessExePath `
        -ArgumentList @(
            "-configdir=""$runtimeRoot""",
            "-readyfile=""$readyFilePath""",
            "-ignoreinstances"
        ) `
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

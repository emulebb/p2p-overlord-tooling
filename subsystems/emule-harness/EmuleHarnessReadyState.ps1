#Requires -Version 7.6

function Assert-EmuleHarnessDebugBuildConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildConfig,
        [string]$ParameterName = "BuildConfig"
    )

    if ($BuildConfig -ine "Debug") {
        throw "Unsupported eMule harness build config '$BuildConfig' for parameter '$ParameterName'. Only Debug is supported for the tracing harness in this workspace."
    }
}

function Normalize-EmuleHarnessDirectoryPath {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\')
}

function Get-EmuleHarnessPreferencesValue {
    [CmdletBinding()]
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreferencesPath,
        [Parameter(Mandatory = $true)]
        [string]$RuntimeRoot
    )

    $runtimeRootPath = [System.IO.Path]::GetFullPath($RuntimeRoot)

    [pscustomobject]@{
        ProfileRoot = Normalize-EmuleHarnessDirectoryPath -Path $runtimeRootPath
        ConfigDir = Normalize-EmuleHarnessDirectoryPath -Path (Join-Path $runtimeRootPath "config")
        TcpPort = [int](Get-EmuleHarnessPreferencesValue -PreferencesPath $PreferencesPath -Key "Port")
        UdpPort = [int](Get-EmuleHarnessPreferencesValue -PreferencesPath $PreferencesPath -Key "UDPPort")
        ServerUdpPort = [int](Get-EmuleHarnessPreferencesValue -PreferencesPath $PreferencesPath -Key "ServerUDPPort")
        NetworkEd2k = [int](Get-EmuleHarnessPreferencesValue -PreferencesPath $PreferencesPath -Key "NetworkED2K")
        NetworkKademlia = [int](Get-EmuleHarnessPreferencesValue -PreferencesPath $PreferencesPath -Key "NetworkKademlia")
        Autoconnect = [int](Get-EmuleHarnessPreferencesValue -PreferencesPath $PreferencesPath -Key "Autoconnect")
        BindAddr = [string](Get-EmuleHarnessPreferencesValue -PreferencesPath $PreferencesPath -Key "BindAddr")
    }
}

function Wait-EmuleHarnessReadyFile {
    [CmdletBinding()]
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
            throw "eMule harness process (PID $($EmuleHarnessProcess.Id)) exited before writing $ReadyFilePath"
        }
        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for eMule harness readiness marker at $ReadyFilePath"
}

function Assert-EmuleHarnessReadyState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExpectedState,
        [Parameter(Mandatory = $true)]
        [object]$ReadyState,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedEmuleHarnessPid,
        [Nullable[int]]$ExpectedCapturePort = $null
    )

    $mismatches = [System.Collections.Generic.List[string]]::new()

    if ($ReadyState.State -ne "ready") {
        $mismatches.Add("state=$($ReadyState.State)") | Out-Null
    }
    if ($ReadyState.Pid -ne $ExpectedEmuleHarnessPid) {
        $mismatches.Add("pid=$($ReadyState.Pid)") | Out-Null
    }
    if ((Normalize-EmuleHarnessDirectoryPath -Path $ReadyState.ProfileRoot) -ne $ExpectedState.ProfileRoot) {
        $mismatches.Add("profile_root=$($ReadyState.ProfileRoot)") | Out-Null
    }
    if ((Normalize-EmuleHarnessDirectoryPath -Path $ReadyState.ConfigDir) -ne $ExpectedState.ConfigDir) {
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
    if ($null -ne $ExpectedCapturePort -and $ExpectedCapturePort.Value -gt 0 -and $ReadyState.UdpPort -ne $ExpectedCapturePort.Value) {
        $mismatches.Add("capture_port=$($ExpectedCapturePort.Value) observed_udp_port=$($ReadyState.UdpPort)") | Out-Null
    }
    if ($ReadyState.ParityMode -ne 1) {
        $mismatches.Add("parity_mode=$($ReadyState.ParityMode)") | Out-Null
    }

    if ($mismatches.Count -gt 0) {
        throw "eMule harness readiness validation failed: $($mismatches -join '; ')"
    }
}

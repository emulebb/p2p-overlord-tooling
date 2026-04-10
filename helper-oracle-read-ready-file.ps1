#Requires -Version 7.6
<#
.SYNOPSIS
Parses an oracle harness readiness marker into structured runtime state.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ReadyValue {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Map,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ($Map.Contains($Key)) {
        return [string]$Map[$Key]
    }

    return $null
}

function Convert-ToNullableInt {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $parsedValue = 0
    if (-not [int]::TryParse($Value, [ref]$parsedValue)) {
        throw "Ready marker value '$Value' is not a valid integer"
    }

    return $parsedValue
}

$readyPath = [System.IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
    throw "Ready marker not found at $readyPath"
}

$values = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $readyPath) {
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    $separatorIndex = $line.IndexOf("=")
    if ($separatorIndex -lt 1) {
        continue
    }

    $key = $line.Substring(0, $separatorIndex).Trim()
    $value = $line.Substring($separatorIndex + 1).Trim()
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        $values[$key] = $value
    }
}

[pscustomobject]@{
    Path = $readyPath
    State = Get-ReadyValue -Map $values -Key "state"
    Pid = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "pid")
    TcpPort = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "tcp_port")
    UdpPort = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "udp_port")
    ServerUdpPort = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "server_udp_port")
    NetworkEd2k = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "network_ed2k")
    NetworkKademlia = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "network_kademlia")
    Autoconnect = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "autoconnect")
    CryptLayerSupported = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "crypt_layer_supported")
    CryptLayerPreferred = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "crypt_layer_preferred")
    CryptLayerRequired = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "crypt_layer_required")
    ParityMode = Convert-ToNullableInt -Value (Get-ReadyValue -Map $values -Key "parity_mode")
    BindAddr = Get-ReadyValue -Map $values -Key "bind_addr"
    Profile = Get-ReadyValue -Map $values -Key "profile"
    ProfileRoot = Get-ReadyValue -Map $values -Key "profile_root"
    ConfigDir = Get-ReadyValue -Map $values -Key "config_dir"
    LogDir = Get-ReadyValue -Map $values -Key "log_dir"
    Raw = [pscustomobject]$values
}

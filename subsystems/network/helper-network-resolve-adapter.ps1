#Requires -Version 7.6
<#
.SYNOPSIS
Resolves a usable IPv4 adapter for parity tooling.

.DESCRIPTION
Prefers the requested interface alias when it has a preferred IPv4 address, but
falls back to another usable adapter when that alias is unavailable. This keeps
VPN-first defaults such as `hide.me` without making them mandatory on every
host.
#>

[CmdletBinding()]
param(
    [string]$PreferredInterfaceAlias = "hide.me"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$candidateAddresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
    Where-Object { $_.AddressState -eq "Preferred" }

$candidates = foreach ($address in $candidateAddresses) {
    $ipAddress = [string]$address.IPAddress
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        continue
    }

    $adapter = Get-NetAdapter -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue
    $adapterAlias = [string]$address.InterfaceAlias
    $adapterName = if ($adapter) { [string]$adapter.Name } else { $adapterAlias }
    $adapterStatus = if ($adapter) { [string]$adapter.Status } else { $null }
    $isPreferredAlias = -not [string]::IsNullOrWhiteSpace($PreferredInterfaceAlias) -and $adapterAlias -eq $PreferredInterfaceAlias
    $isLoopback = $ipAddress.StartsWith("127.", [System.StringComparison]::Ordinal)
    $isLinkLocal = $ipAddress.StartsWith("169.254.", [System.StringComparison]::Ordinal)

    $sortRank = if ($isPreferredAlias) {
        0
    } elseif (-not $isLoopback -and -not $isLinkLocal -and $adapterStatus -eq "Up") {
        1
    } elseif (-not $isLoopback -and -not $isLinkLocal) {
        2
    } elseif (-not $isLoopback -and $adapterStatus -eq "Up") {
        3
    } elseif (-not $isLoopback) {
        4
    } else {
        5
    }

    [pscustomobject]@{
        RequestedInterfaceAlias = if ([string]::IsNullOrWhiteSpace($PreferredInterfaceAlias)) { $null } else { $PreferredInterfaceAlias }
        InterfaceAlias = $adapterAlias
        InterfaceIndex = [int]$address.InterfaceIndex
        AdapterName = $adapterName
        AdapterStatus = $adapterStatus
        IPAddress = $ipAddress
        UsedFallback = -not $isPreferredAlias
        IsPreferredAlias = $isPreferredAlias
        IsLoopback = $isLoopback
        IsLinkLocal = $isLinkLocal
        SortRank = $sortRank
    }
}

if (-not $candidates) {
    throw "No preferred IPv4 adapter is available"
}

$selected = $candidates |
    Sort-Object SortRank, InterfaceAlias, IPAddress |
    Select-Object -First 1

[pscustomobject]@{
    RequestedInterfaceAlias = $selected.RequestedInterfaceAlias
    InterfaceAlias = $selected.InterfaceAlias
    InterfaceIndex = $selected.InterfaceIndex
    AdapterName = $selected.AdapterName
    AdapterStatus = $selected.AdapterStatus
    IPAddress = $selected.IPAddress
    UsedFallback = $selected.UsedFallback
}

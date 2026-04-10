<#
.SYNOPSIS
Updates the oracle preferences BindAddr to the current hide.me VPN IPv4.
#>

[CmdletBinding()]
param(
    [string]$InterfaceAlias = "hide.me"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$oracleHarnessDebugDir = & (Join-Path $PSScriptRoot "helper-oracle-resolve-harness-debug-dir.ps1")
$preferencesPath = Join-Path $oracleHarnessDebugDir "config\preferences.ini"
if (-not (Test-Path $preferencesPath)) {
    throw "preferences.ini not found at $preferencesPath"
}

$vpnIp = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -eq $InterfaceAlias -and $_.AddressState -eq "Preferred" } |
    Select-Object -First 1 -ExpandProperty IPAddress

if (-not $vpnIp) {
    throw "No preferred IPv4 address found on interface '$InterfaceAlias'"
}

$content = Get-Content -Raw $preferencesPath
$updated = if ($content -match '(?m)^BindAddr=') {
    [regex]::Replace($content, '(?m)^BindAddr=.*$', "BindAddr=$vpnIp")
} else {
    $trimmed = $content.TrimEnd("`r", "`n")
    "$trimmed`nBindAddr=$vpnIp`n"
}

[System.IO.File]::WriteAllText(
    $preferencesPath,
    $updated,
    (New-Object System.Text.UTF8Encoding($false))
)

[pscustomobject]@{
    PreferencesPath = $preferencesPath
    BindAddr = $vpnIp
    InterfaceAlias = $InterfaceAlias
}

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

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Resolve-OraclePreferencesPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir
    )

    $preferencesPath = Join-Path $ProjectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug\config\preferences.ini"
    if (Test-Path $preferencesPath) {
        return $preferencesPath
    }

    throw "preferences.ini not found in the oracle debug config directory"
}

$preferencesPath = Resolve-OraclePreferencesPath -ProjectDir $projectDir

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

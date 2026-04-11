#Requires -Version 7.6
<#
.SYNOPSIS
Updates the eMule harness preferences BindAddr to the current preferred IPv4 address.
#>

[CmdletBinding()]
param(
    [string]$InterfaceAlias = "hide.me",
    [string]$ProfileRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$networkResolverPath = Join-Path $PSScriptRoot "helper-network-resolve-adapter.ps1"
$runtimeRoot = if ($ProfileRoot) {
    [System.IO.Path]::GetFullPath($ProfileRoot)
} else {
    & (Join-Path $PSScriptRoot "helper-emule-harness-resolve-harness-debug-dir.ps1")
}
$resolvedAdapter = & $networkResolverPath -PreferredInterfaceAlias $InterfaceAlias
$preferencesPath = Join-Path $runtimeRoot "config\preferences.ini"
if (-not (Test-Path $preferencesPath)) {
    throw "preferences.ini not found at $preferencesPath"
}

$bindIp = [string]$resolvedAdapter.IPAddress

$content = Get-Content -Raw $preferencesPath
$updated = if ($content -match '(?m)^BindAddr=') {
    [regex]::Replace($content, '(?m)^BindAddr=.*$', "BindAddr=$bindIp")
} else {
    $trimmed = $content.TrimEnd("`r", "`n")
    "$trimmed`nBindAddr=$bindIp`n"
}

[System.IO.File]::WriteAllText(
    $preferencesPath,
    $updated,
    (New-Object System.Text.UTF8Encoding($false))
)

[pscustomobject]@{
    PreferencesPath = $preferencesPath
    RuntimeRoot = $runtimeRoot
    BindAddr = $bindIp
    RequestedInterfaceAlias = $InterfaceAlias
    InterfaceAlias = $resolvedAdapter.InterfaceAlias
    InterfaceIndex = $resolvedAdapter.InterfaceIndex
    UsedFallback = $resolvedAdapter.UsedFallback
}

#Requires -Version 7.6
<#
.SYNOPSIS
Sets the oracle debug build's protocol obfuscation preferences.

.DESCRIPTION
This helper updates the runtime-local debug `preferences.ini` used by the oracle
 build so parity runs can switch between the common "obfuscated preferred" mode
 and a fully plaintext mode. The selected crypt flags influence both ED2K TCP
 and Kad UDP behavior in the oracle code paths.
#>

[CmdletBinding()]
param(
    [ValidateSet("ObfuscatedPreferred", "PlaintextOnly")]
    [string]$Mode = "ObfuscatedPreferred",
    [string]$ProfileRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = if ($ProfileRoot) {
    [System.IO.Path]::GetFullPath($ProfileRoot)
} else {
    & (Join-Path $PSScriptRoot "helper-oracle-resolve-harness-debug-dir.ps1")
}
$preferencesPath = Join-Path $runtimeRoot "config\preferences.ini"
if (-not (Test-Path $preferencesPath)) {
    throw "preferences.ini not found at $preferencesPath"
}

$desiredValues = switch ($Mode) {
    "ObfuscatedPreferred" {
        [ordered]@{
            CryptLayerRequested = "1"
            CryptLayerRequired = "0"
            CryptLayerSupported = "1"
        }
    }
    "PlaintextOnly" {
        [ordered]@{
            CryptLayerRequested = "0"
            CryptLayerRequired = "0"
            CryptLayerSupported = "0"
        }
    }
}

$content = Get-Content -Raw $preferencesPath
foreach ($entry in $desiredValues.GetEnumerator()) {
    $key = [regex]::Escape($entry.Key)
    if ($content -match "(?m)^$key=") {
        $content = [regex]::Replace($content, "(?m)^$key=.*$", "$($entry.Key)=$($entry.Value)")
    } else {
        $content = $content.TrimEnd("`r", "`n") + "`n$($entry.Key)=$($entry.Value)`n"
    }
}

[System.IO.File]::WriteAllText(
    $preferencesPath,
    $content,
    (New-Object System.Text.UTF8Encoding($false))
)

[pscustomobject]@{
    PreferencesPath = $preferencesPath
    RuntimeRoot = $runtimeRoot
    Mode = $Mode
    CryptLayerRequested = $desiredValues.CryptLayerRequested
    CryptLayerRequired = $desiredValues.CryptLayerRequired
    CryptLayerSupported = $desiredValues.CryptLayerSupported
}

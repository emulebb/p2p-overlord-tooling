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
    [string]$Mode = "ObfuscatedPreferred"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

$preferencesPath = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug\config\preferences.ini"
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
    Mode = $Mode
    CryptLayerRequested = $desiredValues.CryptLayerRequested
    CryptLayerRequired = $desiredValues.CryptLayerRequired
    CryptLayerSupported = $desiredValues.CryptLayerSupported
}

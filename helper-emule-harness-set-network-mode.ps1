#Requires -Version 7.6
<#
.SYNOPSIS
Sets the eMule harness's ED2K and Kad network mode flags in preferences.ini.

.DESCRIPTION
This helper updates only the runtime-local debug preferences file used by the
eMule harness build. It is intended for parity sessions where ED2K and Kad need to be
enabled or disabled in a repeatable way without editing the file manually.
#>

[CmdletBinding()]
param(
    [ValidateSet("On", "Off")]
    [string]$Ed2k = "On",
    [ValidateSet("On", "Off")]
    [string]$Kad = "On",
    [ValidateSet("On", "Off")]
    [string]$Autoconnect = "On",
    [string]$ProfileRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = if ($ProfileRoot) {
    [System.IO.Path]::GetFullPath($ProfileRoot)
} else {
    & (Join-Path $PSScriptRoot "helper-emule-harness-resolve-harness-debug-dir.ps1")
}
$preferencesPath = Join-Path $runtimeRoot "config\preferences.ini"
if (-not (Test-Path $preferencesPath)) {
    throw "preferences.ini not found at $preferencesPath"
}

$desiredValues = [ordered]@{
    NetworkED2K = if ($Ed2k -eq "On") { "1" } else { "0" }
    NetworkKademlia = if ($Kad -eq "On") { "1" } else { "0" }
    Autoconnect = if ($Autoconnect -eq "On") { "1" } else { "0" }
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
    NetworkED2K = $desiredValues.NetworkED2K
    NetworkKademlia = $desiredValues.NetworkKademlia
    Autoconnect = $desiredValues.Autoconnect
}

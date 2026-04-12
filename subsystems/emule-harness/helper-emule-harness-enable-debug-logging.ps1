#Requires -Version 7.6
<#
.SYNOPSIS
Enables the eMule harness's verbose and debug preference flags that are useful for Kad parity work.
#>

[CmdletBinding()]
param(
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
    Verbose = "1"
    FullVerbose = "1"
    VerboseOptions = "1"
    DebugSourceExchange = "1"
    DebugServerTCP = "2"
    DebugServerUDP = "2"
    DebugServerSources = "2"
    DebugServerSearches = "2"
    DebugClientTCP = "2"
    DebugClientUDP = "2"
    DebugClientKadUDP = "2"
    DebugSearchResultDetailLevel = "1"
    LogBannedClients = "1"
    LogRatingDescReceived = "1"
    LogSecureIdent = "1"
    LogFilteredIPs = "1"
    LogFileSaving = "1"
    LogA4AF = "1"
    LogUlDlEvents = "1"
    SaveLogToDisk = "1"
    SaveDebugToDisk = "1"
    DebugLogLevel = "0"
}

$content = Get-Content -Raw $preferencesPath
foreach ($entry in $desiredValues.GetEnumerator()) {
    $key = [regex]::Escape($entry.Key)
    $value = $entry.Value
    if ($content -match "(?m)^$key=") {
        $content = [regex]::Replace($content, "(?m)^$key=.*$", "$($entry.Key)=$value")
    } else {
        $content = $content.TrimEnd("`r", "`n") + "`n$($entry.Key)=$value`n"
    }
}

[System.IO.File]::WriteAllText(
    $preferencesPath,
    $content,
    (New-Object System.Text.UTF8Encoding($false))
)

$desiredValues.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{
        Key = $_.Key
        Value = $_.Value
    }
}

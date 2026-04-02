<#
.SYNOPSIS
Enables the oracle's verbose and debug preference flags that are useful for Kad parity work.
#>

[CmdletBinding()]
param()

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

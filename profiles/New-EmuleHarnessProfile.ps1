#Requires -Version 7.6
<#
.SYNOPSIS
Materializes a scenario-owned eMule harness profile root from a scenario manifest.

.DESCRIPTION
Creates the profile-root layout expected by the instrumented eMule harness and writes a
minimal `preferences.ini` containing only the manifest-owned seeded keys plus
the allowed per-run overrides.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenarioManifestPath,
    [Parameter(Mandatory = $true)]
    [string]$ProfileRoot,
    [string]$SeedBundleId = "canonical",
    [Parameter(Mandatory = $true)]
    [string]$BindAddr,
    [int]$TcpPort,
    [int]$UdpPort,
    [int]$ServerUdpPort
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-IniString {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Sections
    )

    $builder = New-Object System.Text.StringBuilder
    foreach ($sectionName in $Sections.Keys) {
        [void]$builder.AppendLine("[$sectionName]")
        $entries = $Sections[$sectionName]
        foreach ($entryName in $entries.Keys) {
            [void]$builder.AppendLine(("{0}={1}" -f $entryName, $entries[$entryName]))
        }
        [void]$builder.AppendLine()
    }

    return $builder.ToString()
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifest = Get-Content -Raw $ScenarioManifestPath | ConvertFrom-Json -AsHashtable
$seedRoot = Join-Path $repoRoot ".local\emule-harness-seeds\$SeedBundleId"

if (-not (Test-Path $seedRoot)) {
    throw "Local eMule harness seed bundle '$SeedBundleId' was not found under $seedRoot"
}

$nodesSourcePath = Join-Path $seedRoot "nodes.dat"
$serverSourcePath = Join-Path $seedRoot "server.met"
if (-not (Test-Path $nodesSourcePath)) {
    throw "nodes.dat is missing from seed bundle '$SeedBundleId'"
}
if (-not (Test-Path $serverSourcePath)) {
    throw "server.met is missing from seed bundle '$SeedBundleId'"
}

$resolvedProfileRoot = [System.IO.Path]::GetFullPath($ProfileRoot)
$profileConfigRoot = Join-Path $resolvedProfileRoot "config"
$profileLogsRoot = Join-Path $resolvedProfileRoot "logs"
$profileTempRoot = Join-Path $resolvedProfileRoot "Temp"
$profileIncomingRoot = Join-Path $resolvedProfileRoot "Incoming"
$profileLangRoot = Join-Path $resolvedProfileRoot "lang"
$profileSkinsRoot = Join-Path $resolvedProfileRoot "skins"

foreach ($path in @(
    $resolvedProfileRoot,
    $profileConfigRoot,
    $profileLogsRoot,
    $profileTempRoot,
    $profileIncomingRoot,
    $profileLangRoot,
    $profileSkinsRoot
)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$dynamicOverrides = [ordered]@{
    BindAddr = $BindAddr
}
if ($PSBoundParameters.ContainsKey("TcpPort")) {
    $dynamicOverrides.Port = [string]$TcpPort
}
if ($PSBoundParameters.ContainsKey("UdpPort")) {
    $dynamicOverrides.UDPPort = [string]$UdpPort
}
if ($PSBoundParameters.ContainsKey("ServerUdpPort")) {
    $dynamicOverrides.ServerUDPPort = [string]$ServerUdpPort
}

$preferenceSections = [ordered]@{}
foreach ($sectionName in $manifest.emuleHarness.seededPreferenceDefaults.Keys) {
    $entries = [ordered]@{}
    foreach ($entryName in $manifest.emuleHarness.seededPreferenceDefaults[$sectionName].Keys) {
        $entries[$entryName] = [string]$manifest.emuleHarness.seededPreferenceDefaults[$sectionName][$entryName]
    }
    $preferenceSections[$sectionName] = $entries
}

if (-not $preferenceSections.Contains("eMule")) {
    $preferenceSections["eMule"] = [ordered]@{}
}

$preferenceSections["eMule"]["StartupMinimized"] = "1"
$preferenceSections["eMule"]["MinToTray"] = "1"
$preferenceSections["eMule"]["BringToFront"] = "0"
$preferenceSections["eMule"]["Splashscreen"] = "0"

foreach ($overrideName in $dynamicOverrides.Keys) {
    $targetSection = $manifest.emuleHarness.dynamicPreferenceKeys[$overrideName]
    if (-not $targetSection) {
        throw "Scenario manifest does not declare a target section for dynamic preference '$overrideName'"
    }
    if (-not $preferenceSections.Contains($targetSection)) {
        $preferenceSections[$targetSection] = [ordered]@{}
    }
    $preferenceSections[$targetSection][$overrideName] = [string]$dynamicOverrides[$overrideName]
}

$preferencesPath = Join-Path $profileConfigRoot "preferences.ini"
$preferencesText = ConvertTo-IniString -Sections $preferenceSections
[System.IO.File]::WriteAllText(
    $preferencesPath,
    $preferencesText,
    (New-Object System.Text.UTF8Encoding($false))
)

$parityHookConfigPath = $null
$parityHookEventLogPath = $null
$parityHookConfig = $null
if ($manifest.ContainsKey("parity") -and $null -ne $manifest.parity -and $manifest.parity.ContainsKey("harnessHookConfig")) {
    $parityHookConfig = $manifest.parity.harnessHookConfig
}
elseif ($manifest.ContainsKey("emuleHarness") -and $null -ne $manifest.emuleHarness -and $manifest.emuleHarness.ContainsKey("parityHookConfig")) {
    $parityHookConfig = $manifest.emuleHarness.parityHookConfig
}

if ($null -ne $parityHookConfig) {
    if ($parityHookConfig -isnot [hashtable]) {
        $parityHookConfig = @{} + $parityHookConfig
    }

    $parityHookConfigPath = Join-Path $resolvedProfileRoot "parity-hooks.v1.json"
    $parityHookEventLogPath = Join-Path $profileLogsRoot "parity-hooks.jsonl"
    if (-not $parityHookConfig.Contains("schemaVersion")) {
        $parityHookConfig["schemaVersion"] = "parity-hooks/v1"
    }
    if (-not $parityHookConfig.Contains("eventLogPath")) {
        $parityHookConfig["eventLogPath"] = $parityHookEventLogPath
    }
    if (-not $parityHookConfig.Contains("scenarioId")) {
        $parityHookConfig["scenarioId"] = $manifest.scenarioId
    }

    $parityHookConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $parityHookConfigPath -Encoding utf8NoBOM
}

Copy-Item -LiteralPath $nodesSourcePath -Destination (Join-Path $profileConfigRoot "nodes.dat") -Force
Copy-Item -LiteralPath $serverSourcePath -Destination (Join-Path $profileConfigRoot "server.met") -Force

$profileManifest = [ordered]@{
    schemaVersion = "emule-harness-profile/v1"
    scenarioId = $manifest.scenarioId
    profileRoot = $resolvedProfileRoot
    seedBundleId = $SeedBundleId
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    seededPreferenceSections = $preferenceSections
    preferenceKeys = @(
        foreach ($sectionName in $preferenceSections.Keys) {
            foreach ($entryName in $preferenceSections[$sectionName].Keys) {
                [ordered]@{
                    section = $sectionName
                    key = $entryName
                    value = $preferenceSections[$sectionName][$entryName]
                }
            }
        }
    )
    artifacts = [ordered]@{
        preferencesPath = $preferencesPath
        nodesDatPath = (Join-Path $profileConfigRoot "nodes.dat")
        serverMetPath = (Join-Path $profileConfigRoot "server.met")
        logsRoot = $profileLogsRoot
        tempRoot = $profileTempRoot
        incomingRoot = $profileIncomingRoot
        parityHookConfigPath = $parityHookConfigPath
        parityHookEventLogPath = $parityHookEventLogPath
    }
}

$profileManifestPath = Join-Path $resolvedProfileRoot "emule-harness-profile.json"
$profileManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $profileManifestPath

[pscustomobject]@{
    ProfileRoot = $resolvedProfileRoot
    ProfileManifestPath = $profileManifestPath
    PreferencesPath = $preferencesPath
    NodesDatPath = (Join-Path $profileConfigRoot "nodes.dat")
    ServerMetPath = (Join-Path $profileConfigRoot "server.met")
    ParityHookConfigPath = $parityHookConfigPath
    ParityHookEventLogPath = $parityHookEventLogPath
}

#Requires -Version 7.6
<#
.SYNOPSIS
Writes a local-only goed2k-server config and catalog for one scenario run.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenarioRoot,
    [string]$ListenHost = "127.0.0.1",
    [UInt16]$TcpPort = 42161,
    [UInt16]$AdminPort = 42180,
    [int]$UDPPortOffset = 4,
    [string]$AdminToken = "local-goed2k-token",
    [string]$SourceCatalogPath,
    [switch]$EnableObfuscation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$resolvedScenarioRoot = [System.IO.Path]::GetFullPath($ScenarioRoot)
$runtimeRoot = Join-Path $resolvedScenarioRoot "goed2k-server"
$configPath = Join-Path $runtimeRoot "config.json"
$catalogPath = Join-Path $runtimeRoot "catalog.json"
$logRoot = Join-Path $runtimeRoot "logs"
$defaultCatalogPath = Join-Path $projectDir "ext-deps\goed2k-server\testdata\catalog.json"
$resolvedSourceCatalogPath = if ([string]::IsNullOrWhiteSpace($SourceCatalogPath)) {
    $defaultCatalogPath
} else {
    [System.IO.Path]::GetFullPath($SourceCatalogPath)
}
$serverTcpObfuscationFlag = 0x00000400
$tcpFlags = if ($EnableObfuscation) { $serverTcpObfuscationFlag } else { 0 }
$auxPort = if ($EnableObfuscation) { [int]$TcpPort } else { 0 }

foreach ($path in @($resolvedScenarioRoot, $runtimeRoot, $logRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $resolvedSourceCatalogPath)) {
    throw "goed2k catalog source not found at $resolvedSourceCatalogPath"
}

Copy-Item -LiteralPath $resolvedSourceCatalogPath -Destination $catalogPath -Force

$config = [ordered]@{
    listen_address = "{0}:{1}" -f $ListenHost, $TcpPort
    admin_listen_address = "{0}:{1}" -f $ListenHost, $AdminPort
    admin_token = $AdminToken
    server_name = "overlord-local-goed2k"
    server_description = "Local Overlord ED2K test server"
    message = "Welcome to local goed2k-server"
    storage_backend = "json"
    catalog_path = $catalogPath
    database_dsn = ""
    database_table = "shared_files"
    search_batch_size = 25
    tcp_flags = $tcpFlags
    aux_port = $auxPort
    server_udp = $true
    udp_port_offset = $UDPPortOffset
    soft_files_limit = 5000
    hard_files_limit = 200000
    max_users_advertised = 500000
}

$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

[pscustomobject]@{
    RuntimeRoot = $runtimeRoot
    ConfigPath = $configPath
    CatalogPath = $catalogPath
    LogRoot = $logRoot
    ListenHost = $ListenHost
    TcpPort = $TcpPort
    AdminPort = $AdminPort
    UDPPort = ($TcpPort + $UDPPortOffset)
    UDPPortOffset = $UDPPortOffset
    AdminToken = $AdminToken
    SourceCatalogPath = $resolvedSourceCatalogPath
    ObfuscationEnabled = [bool]$EnableObfuscation
}

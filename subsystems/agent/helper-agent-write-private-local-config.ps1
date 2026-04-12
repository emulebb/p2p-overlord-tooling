#Requires -Version 7.6
<#
.SYNOPSIS
Writes a local-only agent config for a private eMule harness download scenario.

.DESCRIPTION
Overwrites the runtime config consumed by the existing Windows debug launcher so
the agent binds to loopback-only ports, uses only private bootstrap nodes, and
stores all logs and transfer manifests under a scenario-owned root.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenarioRoot,
    [string]$EmuleHarnessBootstrapNode,
    [UInt16]$ControlPort = 13301,
    [UInt16]$KadPort = 41120,
    [UInt16]$Ed2kPort = 41121,
    [string]$P2pBindIp = "127.0.0.1",
    [UInt32]$KadBootstrapReadyContacts = 10,
    [switch]$DisableKad,
    [string]$ServerHost,
    [UInt16]$ServerPort = 0,
    [UInt32]$ServerUdpFlags = 0,
    [UInt32]$ServerUdpKey = 0,
    [UInt32]$ServerUdpKeyIp = 0,
    [UInt16]$ServerObfuscationPortTcp = 0,
    [UInt16]$ServerObfuscationPortUdp = 0,
    [UInt64]$ServerConnectTimeoutSeconds = 8,
    [UInt64]$ServerReconnectIntervalSeconds = 5,
    [UInt64]$ServerSessionRotationSeconds = 45,
    [string]$ProbeSearchTerm = "ubuntu linux",
    [switch]$EnableObfuscation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}

$resolvedScenarioRoot = [System.IO.Path]::GetFullPath($ScenarioRoot)
$stateRoot = Join-Path $resolvedScenarioRoot "agent-state"
$logRoot = Join-Path $resolvedScenarioRoot "agent-logs"
$configPath = Join-Path $env:OVERLORD_TMP_DIR "agent-real-miniupnpc.toml"

foreach ($path in @($resolvedScenarioRoot, $stateRoot, $logRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$backupPath = $null
if (Test-Path -LiteralPath $configPath) {
    $backupPath = Join-Path $resolvedScenarioRoot "agent-real-miniupnpc.backup.toml"
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
}

$obfuscationEnabled = if ($EnableObfuscation) { "true" } else { "false" }
$bootstrapNodesValue = if ($DisableKad -or [string]::IsNullOrWhiteSpace($EmuleHarnessBootstrapNode)) {
    "[]"
} else {
    '["{0}"]' -f $EmuleHarnessBootstrapNode
}
$serverEndpointsValue = "[]"
$serverEntriesValue = "[]"
if (-not [string]::IsNullOrWhiteSpace($ServerHost) -and $ServerPort -gt 0) {
    $serverEndpointsValue = '["{0}:{1}"]' -f $ServerHost, $ServerPort
    $serverEntriesValue = '[{{ host = "{0}", port = {1}, name = "", description = "", udp_flags = {2}, udp_key = {3}, udp_key_ip = {4}, obfuscation_port_tcp = {5}, obfuscation_port_udp = {6} }}]' -f `
        $ServerHost, `
        $ServerPort, `
        $ServerUdpFlags, `
        $ServerUdpKey, `
        $ServerUdpKeyIp, `
        $ServerObfuscationPortTcp, `
        $ServerObfuscationPortUdp
}
$configContent = @"
[coordinator]
url = "http://127.0.0.1:13300"

[agent]
indexer_id_path = "$($stateRoot.Replace('\', '/'))/overlord-agent-emule.indexer-id"
state_dir = "$($stateRoot.Replace('\', '/'))"
hostname = "localhost"
version = "0.1.0"

[control]
bind_iface = ""
bind_ip = "127.0.0.1"
selection_confirmed = true
listen_port = $ControlPort

[p2p]
bind_iface = ""
bind_ip = "$P2pBindIp"
selection_confirmed = true

[p2p.kad]
listen_port = $KadPort
nodes_dat_path = "$($stateRoot.Replace('\', '/'))/overlord-kad.nodes.dat"
bootstrap_nodes = $bootstrapNodesValue
bootstrap_min_routing_contacts = $KadBootstrapReadyContacts
search_timeout_secs = 45
store_timeout_secs = 140
republish_interval_secs = 18000
publish_contact_fanout = 20
routing_refresh_interval_secs = 120
nodes_dat_refresh_interval_secs = 300
udp_firewall_check_enabled = false
udp_firewall_recheck_interval_secs = 300
udp_firewall_check_timeout_secs = 20
udp_firewall_check_contact_count = 2
local_store_enabled = true
local_store_keyword_ttl_secs = 86400
local_store_source_ttl_secs = 21600
local_store_notes_ttl_secs = 86400
local_store_keyword_capacity = 20000
local_store_source_capacity = 20000
local_store_notes_capacity = 5000
max_outbound_pps = 50
search_phase2_fanout = 50
keyword_result_cap = 5000
source_result_cap = 1000
notes_result_cap = 1000
seed_notes_publish_enabled = false
obfuscation_enabled = $obfuscationEnabled
enable_mock_results = false

[p2p.ed2k]
listen_port = $Ed2kPort
server_entries = $serverEntriesValue
server_endpoints = $serverEndpointsValue
obfuscation_enabled = $obfuscationEnabled
probe_search_term = "$($ProbeSearchTerm.Replace('"', ''))"
connect_timeout_secs = $ServerConnectTimeoutSeconds
reconnect_interval_secs = $ServerReconnectIntervalSeconds
keepalive_secs = 60
session_rotation_secs = $ServerSessionRotationSeconds

[p2p.snoop_queue]
dedup_window_secs = 28800
general_max_queries_per_600s = 24
general_drain_cooldown_secs = 900
source_max_queries_per_600s = 60
source_drain_cooldown_secs = 300
source_stop_after_results = 2

[nat.p2p]
enabled = false
backend_order = []
igd_ip = ""
minissdpd_socket = ""
ssdp_local_port = 0
discovery_timeout_secs = 5
lease_duration_secs = 3600
renew_margin_secs = 300
external_ip_override = ""

[log]
level = "info"
dir = "$($logRoot.Replace('\', '/'))"
rotation = "daily"
max_files = 7
"@

[System.IO.File]::WriteAllText(
    $configPath,
    $configContent,
    (New-Object System.Text.UTF8Encoding($false))
)

[pscustomobject]@{
    ConfigPath = $configPath
    BackupPath = $backupPath
    StateRoot = $stateRoot
    LogRoot = $logRoot
    ControlPort = $ControlPort
    KadPort = $KadPort
    Ed2kPort = $Ed2kPort
    P2pBindIp = $P2pBindIp
    KadBootstrapReadyContacts = $KadBootstrapReadyContacts
    EmuleHarnessBootstrapNode = $EmuleHarnessBootstrapNode
    KadDisabled = [bool]$DisableKad
    ServerHost = if ([string]::IsNullOrWhiteSpace($ServerHost)) { $null } else { $ServerHost }
    ServerPort = if ($ServerPort -gt 0) { $ServerPort } else { $null }
    ProbeSearchTerm = $ProbeSearchTerm
}

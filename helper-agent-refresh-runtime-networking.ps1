<#
.SYNOPSIS
Refreshes the agent networking files to the current VPN IPv4.

.DESCRIPTION
Updates the runtime fallback file consumed by the Windows debug launcher when the
temporary TOML omits explicit `[control]`, `[p2p]`, or `[nat]` sections, and also
rewrites the active `%OVERLORD_TMP_DIR%\agent-real-miniupnpc.toml` bind settings
when that parity-launch config is present.
#>

[CmdletBinding()]
param(
    [string]$InterfaceAlias = "hide.me",
    [string]$RuntimeDir,
    [string]$TempConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

if (-not $RuntimeDir) {
    $RuntimeDir = Join-Path $projectDir "overlord-agents\runtime"
}
if (-not $TempConfigPath -and $env:OVERLORD_TMP_DIR) {
    $TempConfigPath = Join-Path $env:OVERLORD_TMP_DIR "agent-real-miniupnpc.toml"
}

function Update-TomlBindValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$SectionName,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $sectionPattern = "(?ms)(^\[$([regex]::Escape($SectionName))\]\r?\n)(.*?)(?=^\[|\z)"
    $sectionMatch = [regex]::Match($Content, $sectionPattern)
    if (-not $sectionMatch.Success) {
        throw "Section [$SectionName] not found while updating $Key in $TempConfigPath"
    }

    $sectionBody = $sectionMatch.Groups[2].Value
    $keyPattern = "(?m)^$([regex]::Escape($Key))\s*=.*$"
    $replacement = "$Key = `"$Value`""
    $updatedBody = if ([regex]::IsMatch($sectionBody, $keyPattern)) {
        [regex]::Replace($sectionBody, $keyPattern, $replacement, 1)
    } else {
        "$replacement`n$sectionBody"
    }

    $Content.Remove($sectionMatch.Groups[2].Index, $sectionMatch.Groups[2].Length).Insert(
        $sectionMatch.Groups[2].Index,
        $updatedBody
    )
}

New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
$networkingPath = Join-Path $RuntimeDir "overlord-agent.networking.json"
$vpnIp = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -eq $InterfaceAlias -and $_.AddressState -eq "Preferred" } |
    Select-Object -First 1 -ExpandProperty IPAddress

if (-not $vpnIp) {
    throw "No preferred IPv4 address found on interface '$InterfaceAlias'"
}

$snapshot = if (Test-Path $networkingPath) {
    Get-Content -Raw $networkingPath | ConvertFrom-Json -AsHashtable
} else {
    @{}
}

if (-not $snapshot.ContainsKey("control")) {
    $snapshot["control"] = @{}
}
if (-not $snapshot.ContainsKey("p2p")) {
    $snapshot["p2p"] = @{}
}
if (-not $snapshot.ContainsKey("nat")) {
    $snapshot["nat"] = @{}
}
if (-not $snapshot["nat"].ContainsKey("p2p")) {
    $snapshot["nat"]["p2p"] = @{}
}
if (-not $snapshot["p2p"].ContainsKey("kad")) {
    $snapshot["p2p"]["kad"] = @{}
}
if (-not $snapshot["p2p"].ContainsKey("ed2k")) {
    $snapshot["p2p"]["ed2k"] = @{}
}

# Keep the control endpoint broadly reachable for the local parity tools.
$snapshot["control"]["bind_iface"] = $null
$snapshot["control"]["bind_ip"] = "0.0.0.0"
$snapshot["control"]["selection_confirmed"] = $true
if (-not $snapshot["control"].ContainsKey("listen_port")) {
    $snapshot["control"]["listen_port"] = 13301
}

# Pin live Kad/ED2K traffic to the VPN interface rather than a transient IPv4 so the
# next hide.me readdressing event does not stale the persisted fallback snapshot again.
$snapshot["p2p"]["bind_iface"] = $InterfaceAlias
$snapshot["p2p"]["bind_ip"] = $null
$snapshot["p2p"]["selection_confirmed"] = $true
if (-not $snapshot["p2p"]["kad"].ContainsKey("listen_port")) {
    $snapshot["p2p"]["kad"]["listen_port"] = 41000
}
if (-not $snapshot["p2p"]["ed2k"].ContainsKey("listen_port")) {
    $snapshot["p2p"]["ed2k"]["listen_port"] = 41001
}

# Live parity runs are expected to keep UPnP enabled on the VPN-facing adapter.
$snapshot["nat"]["p2p"]["enabled"] = $true
if (-not $snapshot["nat"]["p2p"].ContainsKey("backend_order") -or $snapshot["nat"]["p2p"]["backend_order"].Count -eq 0) {
    $snapshot["nat"]["p2p"]["backend_order"] = @("upnp_miniupnpc", "upnp_rupnp")
}
if (-not $snapshot["nat"]["p2p"].ContainsKey("igd_ip")) {
    $snapshot["nat"]["p2p"]["igd_ip"] = $null
}
if (-not $snapshot["nat"]["p2p"].ContainsKey("minissdpd_socket")) {
    $snapshot["nat"]["p2p"]["minissdpd_socket"] = $null
}
if (-not $snapshot["nat"]["p2p"].ContainsKey("ssdp_local_port")) {
    $snapshot["nat"]["p2p"]["ssdp_local_port"] = $null
}
if (-not $snapshot["nat"]["p2p"].ContainsKey("discovery_timeout_secs")) {
    $snapshot["nat"]["p2p"]["discovery_timeout_secs"] = 5
}
if (-not $snapshot["nat"]["p2p"].ContainsKey("lease_duration_secs")) {
    $snapshot["nat"]["p2p"]["lease_duration_secs"] = 3600
}
if (-not $snapshot["nat"]["p2p"].ContainsKey("renew_margin_secs")) {
    $snapshot["nat"]["p2p"]["renew_margin_secs"] = 300
}
if (-not $snapshot["nat"]["p2p"].ContainsKey("external_ip_override")) {
    $snapshot["nat"]["p2p"]["external_ip_override"] = $null
}

$serialized = $snapshot | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText(
    $networkingPath,
    $serialized,
    (New-Object System.Text.UTF8Encoding($false))
)

$updatedTempConfig = $false
if ($TempConfigPath -and (Test-Path $TempConfigPath)) {
    $tempConfigContent = Get-Content -Raw $TempConfigPath
    $tempConfigContent = Update-TomlBindValue `
        -Content $tempConfigContent `
        -SectionName "p2p" `
        -Key "bind_iface" `
        -Value $InterfaceAlias
    $tempConfigContent = Update-TomlBindValue `
        -Content $tempConfigContent `
        -SectionName "p2p" `
        -Key "bind_ip" `
        -Value $vpnIp
    [System.IO.File]::WriteAllText(
        $TempConfigPath,
        $tempConfigContent,
        (New-Object System.Text.UTF8Encoding($false))
    )
    $updatedTempConfig = $true
}

[pscustomobject]@{
    NetworkingPath = $networkingPath
    InterfaceAlias = $InterfaceAlias
    ResolvedP2pBindIp = $vpnIp
    NatEnabled = $snapshot["nat"]["p2p"]["enabled"]
    TempConfigPath = $TempConfigPath
    UpdatedTempConfig = $updatedTempConfig
}

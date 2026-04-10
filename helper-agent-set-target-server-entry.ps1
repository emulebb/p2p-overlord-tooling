#Requires -Version 7.6
<#
.SYNOPSIS
Pins the agent runtime ED2K config to a single metadata-rich server entry.

.DESCRIPTION
This helper is for deterministic parity sessions where the agent must connect to
one known ED2K server and preserve oracle-observed metadata such as UDP flags
and obfuscation ports. It updates both `server_entries` and the legacy
`server_endpoints` array in the live runtime TOML config.
#>

[CmdletBinding()]
param(
    [string]$ServerIp = "176.123.2.239",
    [int]$ServerPort = 4232,
    [int]$UdpFlags = 0,
    [int]$UdpKey = 0,
    [int]$UdpKeyIp = 0,
    [int]$TcpObfuscationPort = 0,
    [int]$UdpObfuscationPort = 0,
    [int]$SessionRotationSeconds = 0,
    [int]$ConnectTimeoutSeconds = 8,
    [int]$ReconnectIntervalSeconds = 5,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $tmpDir "agent-real-miniupnpc.toml"
}

if (-not (Test-Path $ConfigPath)) {
    throw "Agent runtime config not found at $ConfigPath"
}

function ConvertTo-TomlString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Set-TomlKeyInSection {
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

    $sectionPattern = "(?ms)^\[$([regex]::Escape($SectionName))\]\r?\n(?<Body>.*?)(?=^\[|\z)"
    $match = [regex]::Match($Content, $sectionPattern)
    if (-not $match.Success) {
        throw "Section [$SectionName] not found in $ConfigPath"
    }

    $sectionText = $match.Value
    $replacement = "$Key = $Value"
    if ($sectionText -match "(?m)^$([regex]::Escape($Key))\s*=") {
        $updatedSection = [regex]::Replace(
            $sectionText,
            "(?m)^$([regex]::Escape($Key))\s*=.*$",
            $replacement
        )
    } else {
        $updatedSection = $sectionText.TrimEnd("`r", "`n") + "`n$replacement`n"
    }

    return $Content.Substring(0, $match.Index) + $updatedSection + $Content.Substring($match.Index + $match.Length)
}

$endpointText = "{0}:{1}" -f $ServerIp, $ServerPort
$inlineEntry = '{{ host = {0}, port = {1}, name = "", description = "", udp_flags = {2}, udp_key = {3}, udp_key_ip = {4}, obfuscation_port_tcp = {5}, obfuscation_port_udp = {6} }}' -f `
    (ConvertTo-TomlString $ServerIp), `
    $ServerPort, `
    $UdpFlags, `
    $UdpKey, `
    $UdpKeyIp, `
    $TcpObfuscationPort, `
    $UdpObfuscationPort

$content = Get-Content -Raw $ConfigPath
$content = Set-TomlKeyInSection -Content $content -SectionName "p2p.ed2k" -Key "server_entries" -Value "[$inlineEntry]"
$content = Set-TomlKeyInSection -Content $content -SectionName "p2p.ed2k" -Key "server_endpoints" -Value "[$(ConvertTo-TomlString $endpointText)]"
$content = Set-TomlKeyInSection -Content $content -SectionName "p2p.ed2k" -Key "session_rotation_secs" -Value $SessionRotationSeconds
$content = Set-TomlKeyInSection -Content $content -SectionName "p2p.ed2k" -Key "connect_timeout_secs" -Value $ConnectTimeoutSeconds
$content = Set-TomlKeyInSection -Content $content -SectionName "p2p.ed2k" -Key "reconnect_interval_secs" -Value $ReconnectIntervalSeconds

[System.IO.File]::WriteAllText(
    $ConfigPath,
    $content,
    (New-Object System.Text.UTF8Encoding($false))
)

[pscustomobject]@{
    ConfigPath = $ConfigPath
    ServerIp = $ServerIp
    ServerPort = $ServerPort
    UdpFlags = $UdpFlags
    UdpKey = $UdpKey
    UdpKeyIp = $UdpKeyIp
    TcpObfuscationPort = $TcpObfuscationPort
    UdpObfuscationPort = $UdpObfuscationPort
    SessionRotationSeconds = $SessionRotationSeconds
    ConnectTimeoutSeconds = $ConnectTimeoutSeconds
    ReconnectIntervalSeconds = $ReconnectIntervalSeconds
}

#Requires -Version 7.6
<#
.SYNOPSIS
Refreshes the agent networking files to the current preferred IPv4 adapter.

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
$networkResolverPath = Join-Path $PSScriptRoot "helper-network-resolve-adapter.ps1"

function Update-TomlScalarValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$SectionName,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$RawValue
    )

    $replacement = "$Key = $RawValue"
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [regex]::Split($Content, "\r?\n")) {
        $lines.Add($line)
    }

    $currentSection = $null
    $updated = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -match '^\[(?<Name>[^\]]+)\]$') {
            if ($currentSection -eq $SectionName -and -not $updated) {
                $lines.Insert($index, $replacement)
                $updated = $true
                $index++
            }
            $currentSection = $matches.Name
            continue
        }

        if ($currentSection -eq $SectionName -and $line -match "^$([regex]::Escape($Key))\s*=") {
            $lines[$index] = $replacement
            $updated = $true
        }
    }

    if ($currentSection -eq $SectionName -and -not $updated) {
        $lines.Add($replacement)
        $updated = $true
    }

    if (-not $updated) {
        throw "Section [$SectionName] not found while updating $Key in $TempConfigPath"
    }

    return [string]::Join("`n", $lines)
}

New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
$networkingPath = Join-Path $RuntimeDir "overlord-agent.networking.json"
$agentStateRoot = Join-Path $env:OVERLORD_TMP_DIR "agent-real-state"
$agentLogRoot = $env:OVERLORD_LOG_DIR
$resolvedAdapter = & $networkResolverPath -PreferredInterfaceAlias $InterfaceAlias
$resolvedInterfaceAlias = [string]$resolvedAdapter.InterfaceAlias
$resolvedBindIp = [string]$resolvedAdapter.IPAddress

New-Item -ItemType Directory -Path $agentStateRoot -Force | Out-Null
New-Item -ItemType Directory -Path $agentLogRoot -Force | Out-Null

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
$snapshot["control"]["listen_port"] = 13301

# Pin live Kad/ED2K traffic to the selected adapter rather than a transient IPv4 so the
# next interface readdressing event does not stale the persisted fallback snapshot again.
$snapshot["p2p"]["bind_iface"] = $resolvedInterfaceAlias
$snapshot["p2p"]["bind_ip"] = $null
$snapshot["p2p"]["selection_confirmed"] = $true
$snapshot["p2p"]["kad"]["listen_port"] = 41000
$snapshot["p2p"]["ed2k"]["listen_port"] = 41001

# Live parity runs are expected to keep UPnP enabled on the VPN-facing adapter.
$snapshot["nat"]["p2p"]["enabled"] = $true
$snapshot["nat"]["p2p"]["backend_order"] = @("upnp_miniupnpc", "upnp_rupnp")
$snapshot["nat"]["p2p"]["igd_ip"] = $null
$snapshot["nat"]["p2p"]["minissdpd_socket"] = $null
$snapshot["nat"]["p2p"]["ssdp_local_port"] = $null
$snapshot["nat"]["p2p"]["discovery_timeout_secs"] = 5
$snapshot["nat"]["p2p"]["lease_duration_secs"] = 3600
$snapshot["nat"]["p2p"]["renew_margin_secs"] = 300
$snapshot["nat"]["p2p"]["external_ip_override"] = $null

$serialized = $snapshot | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText(
    $networkingPath,
    $serialized,
    (New-Object System.Text.UTF8Encoding($false))
)

$updatedTempConfig = $false
if ($TempConfigPath -and (Test-Path $TempConfigPath)) {
    $tempConfigContent = Get-Content -Raw $TempConfigPath
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "agent" `
        -Key "state_dir" `
        -RawValue ('"{0}"' -f ($agentStateRoot.Replace('\', '/')))
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "agent" `
        -Key "indexer_id_path" `
        -RawValue ('"{0}/overlord-agent-emule.indexer-id"' -f ($agentStateRoot.Replace('\', '/')))
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "control" `
        -Key "bind_iface" `
        -RawValue '""'
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "control" `
        -Key "bind_ip" `
        -RawValue '"0.0.0.0"'
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "control" `
        -Key "selection_confirmed" `
        -RawValue "true"
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "control" `
        -Key "listen_port" `
        -RawValue "13301"
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "p2p" `
        -Key "bind_iface" `
        -RawValue ('"{0}"' -f $resolvedInterfaceAlias)
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "p2p" `
        -Key "bind_ip" `
        -RawValue ('"{0}"' -f $resolvedBindIp)
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "p2p" `
        -Key "selection_confirmed" `
        -RawValue "true"
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "p2p.kad" `
        -Key "listen_port" `
        -RawValue "41000"
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "p2p.kad" `
        -Key "nodes_dat_path" `
        -RawValue ('"{0}/overlord-kad.nodes.dat"' -f ($agentStateRoot.Replace('\', '/')))
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "p2p.ed2k" `
        -Key "listen_port" `
        -RawValue "41001"
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "nat.p2p" `
        -Key "enabled" `
        -RawValue "true"
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "nat.p2p" `
        -Key "backend_order" `
        -RawValue '["upnp_miniupnpc", "upnp_rupnp"]'
    $tempConfigContent = Update-TomlScalarValue `
        -Content $tempConfigContent `
        -SectionName "log" `
        -Key "dir" `
        -RawValue ('"{0}"' -f ($agentLogRoot.Replace('\', '/')))
    [System.IO.File]::WriteAllText(
        $TempConfigPath,
        $tempConfigContent,
        (New-Object System.Text.UTF8Encoding($false))
    )
    $updatedTempConfig = $true
}

[pscustomobject]@{
    NetworkingPath = $networkingPath
    RequestedInterfaceAlias = $InterfaceAlias
    InterfaceAlias = $resolvedInterfaceAlias
    InterfaceIndex = $resolvedAdapter.InterfaceIndex
    ResolvedP2pBindIp = $resolvedBindIp
    UsedFallback = $resolvedAdapter.UsedFallback
    ControlListenPort = 13301
    KadListenPort = 41000
    Ed2kListenPort = 41001
    AgentStateRoot = $agentStateRoot
    AgentLogRoot = $agentLogRoot
    NatEnabled = $snapshot["nat"]["p2p"]["enabled"]
    TempConfigPath = $TempConfigPath
    UpdatedTempConfig = $updatedTempConfig
}

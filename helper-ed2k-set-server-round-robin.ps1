<#
.SYNOPSIS
Loads ED2K server endpoints from a bundled server.met file and applies them to live parity runs.

.DESCRIPTION
This helper parses the classic `server.met` binary format, preserves the
server-side metadata needed for ED2K obfuscation parity, rewrites the local
agent runtime config to use those servers in-order, and optionally mirrors the
same file into the oracle debug profile so both sides round-robin through the
same pool.
#>

[CmdletBinding()]
param(
    [string]$SourcePath,
    [string]$AgentConfigPath,
    [int]$MaxServers = 0,
    [int]$SessionRotationSeconds = 45,
    [int]$ConnectTimeoutSeconds = 8,
    [int]$ReconnectIntervalSeconds = 5,
    [switch]$SkipOracleSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}

if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug\config\server_more.met"
}
if ([string]::IsNullOrWhiteSpace($AgentConfigPath)) {
    $AgentConfigPath = Join-Path $tmpDir "agent-real-miniupnpc.toml"
}

$oracleServerMetPath = Join-Path $projectDir "ext-deps\eMule-build\eMule\srchybrid\x64\Debug\config\server.met"

if (-not (Test-Path $SourcePath)) {
    throw "Source server.met file not found at $SourcePath"
}
if (-not (Test-Path $AgentConfigPath)) {
    throw "Agent runtime config not found at $AgentConfigPath"
}

function Read-BytesExactly {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.BinaryReader]$Reader,
        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    $bytes = $Reader.ReadBytes($Count)
    if ($bytes.Length -ne $Count) {
        throw "Unexpected end of file while reading server.met"
    }
    return $bytes
}

function Read-Ed2kTag {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.BinaryReader]$Reader
    )

    $typeByte = $Reader.ReadByte()
    $baseType = $typeByte -band 0x7F
    $shortName = ($typeByte -band 0x80) -ne 0

    $nameId = 0
    $name = $null
    if ($shortName) {
        $nameId = $Reader.ReadByte()
    } else {
        $nameLen = $Reader.ReadUInt16()
        $nameBytes = Read-BytesExactly -Reader $Reader -Count $nameLen
        $name = [System.Text.Encoding]::UTF8.GetString($nameBytes)
    }

    $value = $null
    switch ($baseType) {
        0x01 { $value = Read-BytesExactly -Reader $Reader -Count 16 }
        0x02 {
            $len = $Reader.ReadUInt16()
            $value = [System.Text.Encoding]::UTF8.GetString((Read-BytesExactly -Reader $Reader -Count $len))
        }
        0x03 { $value = $Reader.ReadUInt32() }
        0x04 { $value = [System.BitConverter]::ToSingle((Read-BytesExactly -Reader $Reader -Count 4), 0) }
        0x05 { $value = [bool]($Reader.ReadByte()) }
        0x06 {
            $bitLen = $Reader.ReadUInt16()
            $byteLen = [Math]::Floor($bitLen / 8) + 1
            $value = Read-BytesExactly -Reader $Reader -Count $byteLen
        }
        0x07 {
            $blobLen = $Reader.ReadUInt32()
            $value = Read-BytesExactly -Reader $Reader -Count $blobLen
        }
        0x08 { $value = $Reader.ReadUInt16() }
        0x09 { $value = $Reader.ReadByte() }
        0x0B { $value = $Reader.ReadUInt64() }
        default {
            if ($baseType -ge 0x11 -and $baseType -le 0x20) {
                $compactLen = $baseType - 0x11 + 1
                $value = [System.Text.Encoding]::UTF8.GetString((Read-BytesExactly -Reader $Reader -Count $compactLen))
            } else {
                throw ("Unsupported ED2K tag type 0x{0:X2} in {1}" -f $baseType, $SourcePath)
            }
        }
    }

    return [pscustomobject]@{
        NameId = $nameId
        Name = $name
        BaseType = $baseType
        Value = $value
    }
}

function Get-Ed2kServerEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        $version = $reader.ReadByte()
        if ($version -ne 0xE0) {
            throw ("Unsupported server.met version 0x{0:X2} in {1}" -f $version, $Path)
        }

        $count = $reader.ReadUInt32()
        $entries = [System.Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $count; $index++) {
            $ipValue = $reader.ReadUInt32()
            $port = $reader.ReadUInt16()
            $tagCount = $reader.ReadUInt32()
            $ip = [System.Net.IPAddress]::new([System.BitConverter]::GetBytes($ipValue)).ToString()
            $entry = [ordered]@{
                host = $ip
                port = [int]$port
                name = $null
                description = $null
                udp_flags = 0
                udp_key = 0
                udp_key_ip = 0
                obfuscation_port_tcp = 0
                obfuscation_port_udp = 0
            }
            for ($tagIndex = 0; $tagIndex -lt $tagCount; $tagIndex++) {
                $tag = Read-Ed2kTag -Reader $reader
                switch ($tag.NameId) {
                    0x01 { if ($tag.Value -is [string]) { $entry.name = $tag.Value } }
                    0x0B { if ($tag.Value -is [string]) { $entry.description = $tag.Value } }
                    0x92 { if ($tag.Value -is [uint32]) { $entry.udp_flags = [int]$tag.Value } }
                    0x95 { if ($tag.Value -is [uint32]) { $entry.udp_key = [int]$tag.Value } }
                    0x96 { if ($tag.Value -is [uint32]) { $entry.udp_key_ip = [int]$tag.Value } }
                    0x97 { if ($tag.Value -is [uint16]) { $entry.obfuscation_port_tcp = [int]$tag.Value } }
                    0x98 { if ($tag.Value -is [uint16]) { $entry.obfuscation_port_udp = [int]$tag.Value } }
                }
            }
            $entries.Add([pscustomobject]$entry)
        }

        return $entries
    } finally {
        $stream.Dispose()
    }
}

function Set-TomlStringArrayKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$SectionName,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string[]]$Values
    )

    $sectionPattern = "(?ms)^\[$([regex]::Escape($SectionName))\]\r?\n(?<Body>.*?)(?=^\[|\z)"
    $match = [regex]::Match($Content, $sectionPattern)
    if (-not $match.Success) {
        throw "Section [$SectionName] not found in $AgentConfigPath"
    }

    $sectionText = $match.Value
    $quotedValues = $Values | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
    $replacement = "$Key = [" + ($quotedValues -join ", ") + "]"
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

function Set-TomlIntegerKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$SectionName,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    $sectionPattern = "(?ms)^\[$([regex]::Escape($SectionName))\]\r?\n(?<Body>.*?)(?=^\[|\z)"
    $match = [regex]::Match($Content, $sectionPattern)
    if (-not $match.Success) {
        throw "Section [$SectionName] not found in $AgentConfigPath"
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

function ConvertTo-TomlString {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Set-TomlInlineTableArrayKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$SectionName,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [object[]]$Entries
    )

    $sectionPattern = "(?ms)^\[$([regex]::Escape($SectionName))\]\r?\n(?<Body>.*?)(?=^\[|\z)"
    $match = [regex]::Match($Content, $sectionPattern)
    if (-not $match.Success) {
        throw "Section [$SectionName] not found in $AgentConfigPath"
    }

    $sectionText = $match.Value
    $encodedEntries = foreach ($entry in $Entries) {
        "{ host = $(ConvertTo-TomlString $entry.host), port = $($entry.port), name = $(ConvertTo-TomlString $entry.name), description = $(ConvertTo-TomlString $entry.description), udp_flags = $($entry.udp_flags), udp_key = $($entry.udp_key), udp_key_ip = $($entry.udp_key_ip), obfuscation_port_tcp = $($entry.obfuscation_port_tcp), obfuscation_port_udp = $($entry.obfuscation_port_udp) }"
    }
    $replacement = "$Key = [" + ($encodedEntries -join ", ") + "]"
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

$allEntries = @(Get-Ed2kServerEntries -Path $SourcePath)
if ($allEntries.Count -eq 0) {
    throw "No ED2K endpoints were parsed from $SourcePath"
}

$selectedEntries = @(
if ($MaxServers -gt 0) {
    @($allEntries | Select-Object -First $MaxServers)
} else {
    $allEntries
}
)
$selectedEndpoints = @($selectedEntries | ForEach-Object { "{0}:{1}" -f $_.host, $_.port })

$content = Get-Content -Raw $AgentConfigPath
$content = Set-TomlInlineTableArrayKey -Content $content -SectionName "p2p.ed2k" -Key "server_entries" -Entries $selectedEntries
$content = Set-TomlStringArrayKey -Content $content -SectionName "p2p.ed2k" -Key "server_endpoints" -Values $selectedEndpoints
$content = Set-TomlIntegerKey -Content $content -SectionName "p2p.ed2k" -Key "session_rotation_secs" -Value $SessionRotationSeconds
$content = Set-TomlIntegerKey -Content $content -SectionName "p2p.ed2k" -Key "connect_timeout_secs" -Value $ConnectTimeoutSeconds
$content = Set-TomlIntegerKey -Content $content -SectionName "p2p.ed2k" -Key "reconnect_interval_secs" -Value $ReconnectIntervalSeconds
[System.IO.File]::WriteAllText(
    $AgentConfigPath,
    $content,
    (New-Object System.Text.UTF8Encoding($false))
)

if (-not $SkipOracleSync) {
    Copy-Item -LiteralPath $SourcePath -Destination $oracleServerMetPath -Force
}

[pscustomobject]@{
    SourcePath = $SourcePath
    AgentConfigPath = $AgentConfigPath
    OracleServerMetPath = if ($SkipOracleSync) { $null } else { $oracleServerMetPath }
    ServerCount = @($selectedEndpoints).Count
    SessionRotationSeconds = $SessionRotationSeconds
    ConnectTimeoutSeconds = $ConnectTimeoutSeconds
    ReconnectIntervalSeconds = $ReconnectIntervalSeconds
    FirstServer = $selectedEndpoints[0]
    LastServer = $selectedEndpoints[@($selectedEndpoints).Count - 1]
    FirstServerEntry = $selectedEntries[0]
    Endpoints = $selectedEndpoints
    Entries = $selectedEntries
}

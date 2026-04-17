#Requires -Version 7.6
<#
.SYNOPSIS
Selects one reachable ED2K server entry from a `server.met` file.

.DESCRIPTION
Parses the classic ED2K `server.met` format, preserves metadata needed for
obfuscation parity, and returns the first TCP-reachable server entry. This is
intended for real-network scenarios which need both the agent and the eMule
harness pinned to the same live server.
#>

[CmdletBinding()]
param(
    [string]$SourcePath,
    [int]$MaxCandidates = 0,
    [int]$ConnectTimeoutMilliseconds = 5000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\RuntimeContext.ps1")

$runtimeContext = Get-ToolingRuntimeContext -SourcePath $PSCommandPath
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path $runtimeContext.ToolingRoot ".local\emule-harness-seeds\canonical\server.met"
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "ED2K server list not found at $SourcePath"
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
        throw "Unexpected end of file while reading $SourcePath"
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
    if ($shortName) {
        $nameId = $Reader.ReadByte()
    } else {
        $nameLen = $Reader.ReadUInt16()
        [void](Read-BytesExactly -Reader $Reader -Count $nameLen)
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
                name = ""
                description = ""
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

function Test-TcpServerReachable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerHost,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutMilliseconds
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync($ServerHost, $Port)
        if (-not $connectTask.Wait($TimeoutMilliseconds)) {
            return $false
        }
        if ($connectTask.IsFaulted) {
            return $false
        }

        return $client.Connected
    } finally {
        $client.Dispose()
    }
}

$entries = @(Get-Ed2kServerEntries -Path $SourcePath)
if ($entries.Count -eq 0) {
    throw "No ED2K servers were parsed from $SourcePath"
}

$candidates = if ($MaxCandidates -gt 0) {
    @($entries | Select-Object -First $MaxCandidates)
} else {
    $entries
}

$attempts = 0
foreach ($entry in $candidates) {
    $attempts++
    if (Test-TcpServerReachable -ServerHost $entry.host -Port $entry.port -TimeoutMilliseconds $ConnectTimeoutMilliseconds) {
        [pscustomobject]@{
            SourcePath = [System.IO.Path]::GetFullPath($SourcePath)
            SelectedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            Attempts = $attempts
            Selected = $entry
            Host = $entry.host
            Port = $entry.port
            Name = $entry.name
            Description = $entry.description
            UdpFlags = $entry.udp_flags
            UdpKey = $entry.udp_key
            UdpKeyIp = $entry.udp_key_ip
            TcpObfuscationPort = $entry.obfuscation_port_tcp
            UdpObfuscationPort = $entry.obfuscation_port_udp
        }
        return
    }
}

throw "Could not find a reachable ED2K server in $SourcePath after $attempts attempt(s)"

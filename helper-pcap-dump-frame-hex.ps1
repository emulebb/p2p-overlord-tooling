<#
.SYNOPSIS
Dumps packet payload hex for selected frames from a pcap.

.DESCRIPTION
This helper is intended for protocol parity work where the first on-wire bytes
matter. It uses `tshark` to extract frame metadata plus the hex payload, which
is useful for quickly comparing plaintext versus obfuscated traffic without
opening Wireshark interactively.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PcapPath,
    [string]$DisplayFilter = "data.data",
    [int]$MaxFrames = 200,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $PcapPath)) {
    throw "pcap not found at $PcapPath"
}

$tsharkPath = "C:\Program Files\Wireshark\tshark.exe"
if (-not (Test-Path $tsharkPath)) {
    throw "tshark.exe not found at $tsharkPath"
}

$tsharkArgs = @(
    "-r", $PcapPath,
    "-Y", $DisplayFilter,
    "-c", $MaxFrames,
    "-T", "fields",
    "-E", "header=y",
    "-E", "separator=`t",
    "-e", "frame.number",
    "-e", "frame.time_epoch",
    "-e", "ip.src",
    "-e", "tcp.srcport",
    "-e", "udp.srcport",
    "-e", "ip.dst",
    "-e", "tcp.dstport",
    "-e", "udp.dstport",
    "-e", "data.data"
)

$rows = & $tsharkPath @tsharkArgs
if ($LASTEXITCODE -ne 0) {
    throw "tshark failed for $PcapPath"
}

if ($OutputPath) {
    $directory = Split-Path -Parent $OutputPath
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $rows | Set-Content -Encoding utf8NoBOM $OutputPath
}

$rows

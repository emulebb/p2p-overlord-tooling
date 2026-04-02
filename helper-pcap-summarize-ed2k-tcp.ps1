<#
.SYNOPSIS
Summarizes ED2K-related TCP streams from a pcap by first payload shape.

.DESCRIPTION
This helper uses `tshark` to extract TCP payload-bearing frames, groups them by
stream, and labels each stream as:
- `listener_inbound` when the first payload targets the local ED2K listen port
- `server_outbound` when either endpoint matches the configured ED2K server
- `other` otherwise

The first payload byte is used as a simple parity heuristic:
- `0xE3`, `0xC5`, `0xD4` => plaintext ED2K/eMule framing
- anything else => obfuscated_or_other
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PcapPath,
    [Parameter(Mandatory = $true)]
    [string]$LocalIp,
    [Parameter(Mandatory = $true)]
    [int]$ListenPort,
    [string]$ServerIp,
    [int]$ServerPort
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
    "-Y", "tcp.len > 0 && ip",
    "-T", "fields",
    "-E", "header=n",
    "-e", "frame.number",
    "-e", "frame.time_epoch",
    "-e", "tcp.stream",
    "-e", "ip.src",
    "-e", "tcp.srcport",
    "-e", "ip.dst",
    "-e", "tcp.dstport",
    "-e", "tcp.len",
    "-e", "data.data"
)

$rows = @(& $tsharkPath @tsharkArgs)

if (-not $rows) {
    return
}

$streamRows = foreach ($line in $rows) {
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    $parts = $line -split "`t", 9
    if ($parts.Count -lt 9) {
        continue
    }

    [pscustomobject]@{
        FrameNumber = [int]$parts[0]
        Epoch = [double]$parts[1]
        StreamId = [int]$parts[2]
        SrcIp = $parts[3]
        SrcPort = [int]$parts[4]
        DstIp = $parts[5]
        DstPort = [int]$parts[6]
        TcpLen = [int]$parts[7]
        PayloadHex = $parts[8]
    }
}

$streamRows |
    Group-Object StreamId |
    ForEach-Object {
        $frames = $_.Group | Sort-Object FrameNumber
        $first = $frames[0]
        $firstByte =
            if ([string]::IsNullOrWhiteSpace($first.PayloadHex) -or $first.PayloadHex.Length -lt 2) {
                $null
            } else {
                $first.PayloadHex.Substring(0, 2).ToUpperInvariant()
            }

        $mode =
            if ($firstByte -in @("E3", "C5", "D4")) {
                "plaintext"
            } else {
                "obfuscated_or_other"
            }

        $role =
            if ($first.DstIp -eq $LocalIp -and $first.DstPort -eq $ListenPort) {
                "listener_inbound"
            } elseif (
                $ServerIp -and $ServerPort -and (
                    ($first.SrcIp -eq $ServerIp -and $first.SrcPort -eq $ServerPort) -or
                    ($first.DstIp -eq $ServerIp -and $first.DstPort -eq $ServerPort)
                )
            ) {
                "server_outbound"
            } else {
                "other"
            }

        [pscustomobject]@{
            StreamId = $_.Name
            Role = $role
            FirstFrame = $first.FrameNumber
            FirstSeenEpoch = $first.Epoch
            Src = "{0}:{1}" -f $first.SrcIp, $first.SrcPort
            Dst = "{0}:{1}" -f $first.DstIp, $first.DstPort
            FirstByte = $firstByte
            Mode = $mode
            FirstPayloadHex = $first.PayloadHex
            PayloadFrames = $frames.Count
        }
    } |
    Sort-Object FirstFrame

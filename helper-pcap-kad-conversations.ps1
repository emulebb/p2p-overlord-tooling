<#
.SYNOPSIS
Summarizes UDP conversations for a local Kad capture port.

.DESCRIPTION
Groups packets by remote endpoint so parity investigations can quickly tell
which peers exchanged traffic with the local Kad socket and in which
direction.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PcapPath,
    [Parameter(Mandatory = $true)]
    [int]$Port,
    [string[]]$RemoteEndpoints = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tsharkPath = "C:\Program Files\Wireshark\tshark.exe"
if (-not (Test-Path $tsharkPath)) {
    throw "tshark.exe not found at $tsharkPath"
}
if (-not (Test-Path $PcapPath)) {
    throw "pcap file not found at $PcapPath"
}

$fields = @(
    "-e", "frame.number",
    "-e", "frame.time_epoch",
    "-e", "ip.src",
    "-e", "udp.srcport",
    "-e", "ip.dst",
    "-e", "udp.dstport",
    "-e", "frame.len"
)

$rows = & $tsharkPath -r $PcapPath -Y "udp.port == $Port" -T fields -E separator=`t @fields 2>$null

$conversationIndex = @{}
foreach ($row in $rows) {
    if (-not $row) {
        continue
    }

    $parts = $row -split "`t"
    if ($parts.Count -lt 7) {
        continue
    }

    $srcIp = $parts[2]
    $srcPort = $parts[3]
    $dstIp = $parts[4]
    $dstPort = $parts[5]
    $frameLen = [int]$parts[6]

    $localMatchesSrc = ($srcPort -eq "$Port")
    $localMatchesDst = ($dstPort -eq "$Port")
    if (-not $localMatchesSrc -and -not $localMatchesDst) {
        continue
    }

    $remoteEndpoint = if ($localMatchesSrc -and -not $localMatchesDst) {
        "{0}:{1}" -f $dstIp, $dstPort
    } elseif ($localMatchesDst -and -not $localMatchesSrc) {
        "{0}:{1}" -f $srcIp, $srcPort
    } elseif ($RemoteEndpoints -contains ("{0}:{1}" -f $dstIp, $dstPort)) {
        "{0}:{1}" -f $dstIp, $dstPort
    } else {
        "{0}:{1}" -f $srcIp, $srcPort
    }

    $isOutbound = ($remoteEndpoint -eq ("{0}:{1}" -f $dstIp, $dstPort))

    if ($RemoteEndpoints.Count -gt 0 -and $RemoteEndpoints -notcontains $remoteEndpoint) {
        continue
    }

    if (-not $conversationIndex.ContainsKey($remoteEndpoint)) {
        $conversationIndex[$remoteEndpoint] = [ordered]@{
            RemoteEndpoint = $remoteEndpoint
            OutboundPackets = 0
            InboundPackets = 0
            OutboundBytes = 0
            InboundBytes = 0
            FirstEpoch = [double]::PositiveInfinity
            LastEpoch = 0.0
        }
    }

    $entry = $conversationIndex[$remoteEndpoint]
    if ($isOutbound) {
        $entry.OutboundPackets += 1
        $entry.OutboundBytes += $frameLen
    } else {
        $entry.InboundPackets += 1
        $entry.InboundBytes += $frameLen
    }

    $epoch = [double]$parts[1]
    if ($epoch -lt $entry.FirstEpoch) {
        $entry.FirstEpoch = $epoch
    }
    if ($epoch -gt $entry.LastEpoch) {
        $entry.LastEpoch = $epoch
    }
}

$conversationIndex.Values |
    Sort-Object @{ Expression = "InboundPackets"; Descending = $true }, @{ Expression = "OutboundPackets"; Descending = $true }, RemoteEndpoint |
    ForEach-Object {
        [pscustomobject]@{
            RemoteEndpoint = $_.RemoteEndpoint
            OutboundPackets = $_.OutboundPackets
            InboundPackets = $_.InboundPackets
            OutboundBytes = $_.OutboundBytes
            InboundBytes = $_.InboundBytes
            FirstSeenUtc = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]([double]$_.FirstEpoch * 1000)).UtcDateTime.ToString("o")
            LastSeenUtc = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]([double]$_.LastEpoch * 1000)).UtcDateTime.ToString("o")
        }
    }

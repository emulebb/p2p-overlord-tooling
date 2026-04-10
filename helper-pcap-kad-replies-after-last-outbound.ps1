#Requires -Version 7.6
<#
.SYNOPSIS
Checks whether remote peers sent any packet after the last outbound packet.

.DESCRIPTION
This is useful when traversal and publish traffic share the same peers. It
distinguishes earlier traversal responses from traffic that arrived after the
final outbound packet, which is often the publish request under investigation.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PcapPath,
    [Parameter(Mandatory = $true)]
    [int]$Port,
    [Parameter(Mandatory = $true)]
    [string[]]$RemoteEndpoints
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
    "-e", "frame.time_epoch",
    "-e", "ip.src",
    "-e", "udp.srcport",
    "-e", "ip.dst",
    "-e", "udp.dstport"
)

$rows = & $tsharkPath -r $PcapPath -Y "udp.port == $Port" -T fields -E separator=`t @fields 2>$null
$eventsByEndpoint = @{}
foreach ($row in $rows) {
    if (-not $row) {
        continue
    }

    $parts = $row -split "`t"
    if ($parts.Count -lt 5) {
        continue
    }

    $srcIp = $parts[1]
    $srcPort = $parts[2]
    $dstIp = $parts[3]
    $dstPort = $parts[4]

    $localMatchesSrc = ($srcPort -eq "$Port")
    $localMatchesDst = ($dstPort -eq "$Port")
    if (-not $localMatchesSrc -and -not $localMatchesDst) {
        continue
    }

    $candidateDst = "{0}:{1}" -f $dstIp, $dstPort
    $candidateSrc = "{0}:{1}" -f $srcIp, $srcPort
    $remoteEndpoint = if ($RemoteEndpoints -contains $candidateDst) {
        $candidateDst
    } elseif ($RemoteEndpoints -contains $candidateSrc) {
        $candidateSrc
    } else {
        continue
    }

    $direction = if ($remoteEndpoint -eq $candidateDst) {
        "outbound"
    } else {
        "inbound"
    }

    if (-not $eventsByEndpoint.ContainsKey($remoteEndpoint)) {
        $eventsByEndpoint[$remoteEndpoint] = New-Object System.Collections.Generic.List[object]
    }

    $eventsByEndpoint[$remoteEndpoint].Add([pscustomobject]@{
        Epoch = [double]$parts[0]
        Direction = $direction
    })
}

foreach ($remoteEndpoint in $RemoteEndpoints) {
    $events = if ($eventsByEndpoint.ContainsKey($remoteEndpoint)) {
        $eventsByEndpoint[$remoteEndpoint] | Sort-Object Epoch
    } else {
        @()
    }

    $lastOutbound = $events | Where-Object { $_.Direction -eq "outbound" } | Select-Object -Last 1
    $inboundAfterLastOutbound = if ($lastOutbound) {
        $events | Where-Object { $_.Direction -eq "inbound" -and $_.Epoch -gt $lastOutbound.Epoch }
    } else {
        @()
    }

    [pscustomobject]@{
        RemoteEndpoint = $remoteEndpoint
        TotalEvents = @($events).Count
        LastOutboundUtc = if ($lastOutbound) {
            [DateTimeOffset]::FromUnixTimeMilliseconds([int64]($lastOutbound.Epoch * 1000)).UtcDateTime.ToString("o")
        } else {
            $null
        }
        InboundAfterLastOutbound = @($inboundAfterLastOutbound).Count
        FirstInboundAfterLastOutboundUtc = if (@($inboundAfterLastOutbound).Count -gt 0) {
            [DateTimeOffset]::FromUnixTimeMilliseconds([int64]($inboundAfterLastOutbound[0].Epoch * 1000)).UtcDateTime.ToString("o")
        } else {
            $null
        }
    }
}

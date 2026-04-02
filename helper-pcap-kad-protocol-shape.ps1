<#
.SYNOPSIS
Summarizes protocol-shape signals for a Kad UDP capture.

.DESCRIPTION
Produces compact parity metrics that are useful when comparing captures from
the Rust agent and the eMule oracle, including length histograms, visible
plaintext Kad prefixes, and simple outbound-to-inbound size pairings.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PcapPath,
    [Parameter(Mandatory = $true)]
    [int]$Port,
    [int]$TopLengths = 12,
    [int]$TopPrefixes = 12,
    [int]$TopPairs = 12,
    [int]$PrefixChars = 8,
    [double]$ReplyWindowSeconds = 5.0
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
    "-e", "udp.dstport",
    "-e", "udp.length",
    "-e", "data.data"
)

$rows = & $tsharkPath -r $PcapPath -Y "udp.port == $Port" -T fields -E separator=`t @fields 2>$null

$events = New-Object System.Collections.Generic.List[object]
$lengthByDirection = @{
    outbound = @{}
    inbound = @{}
}
$plaintextPrefixes = @{}

foreach ($row in $rows) {
    if (-not $row) {
        continue
    }

    $parts = $row -split "`t"
    if ($parts.Count -lt 7) {
        continue
    }

    $srcIp = $parts[1]
    $srcPort = $parts[2]
    $dstIp = $parts[3]
    $dstPort = $parts[4]
    $udpLength = [int]$parts[5]
    $payloadHex = $parts[6]

    $direction = if ($srcPort -eq "$Port" -and $dstPort -ne "$Port") {
        "outbound"
    } elseif ($dstPort -eq "$Port" -and $srcPort -ne "$Port") {
        "inbound"
    } else {
        continue
    }

    $remoteEndpoint = if ($direction -eq "outbound") {
        "{0}:{1}" -f $dstIp, $dstPort
    } else {
        "{0}:{1}" -f $srcIp, $srcPort
    }

    if (-not $lengthByDirection[$direction].ContainsKey($udpLength)) {
        $lengthByDirection[$direction][$udpLength] = 0
    }
    $lengthByDirection[$direction][$udpLength] += 1

    if ($payloadHex -and $payloadHex.StartsWith("e4", [System.StringComparison]::OrdinalIgnoreCase)) {
        $prefixLength = [Math]::Min($PrefixChars, $payloadHex.Length)
        $prefix = $payloadHex.Substring(0, $prefixLength).ToLowerInvariant()
        if (-not $plaintextPrefixes.ContainsKey($prefix)) {
            $plaintextPrefixes[$prefix] = 0
        }
        $plaintextPrefixes[$prefix] += 1
    }

    $events.Add([pscustomobject]@{
        Epoch = [double]$parts[0]
        Direction = $direction
        RemoteEndpoint = $remoteEndpoint
        UdpLength = $udpLength
    })
}

$sortedEvents = $events | Sort-Object Epoch
$firstEpoch = $null
$lastEpoch = $null
if (@($sortedEvents).Count -gt 0) {
    $firstEpoch = [double]$sortedEvents[0].Epoch
    $lastEpoch = [double]$sortedEvents[-1].Epoch
}
$spanSeconds = if ($firstEpoch -ne $null -and $lastEpoch -ne $null) {
    [Math]::Max(0.0, $lastEpoch - $firstEpoch)
} else {
    0.0
}

$pairs = @{}
$lastOutboundByPeer = @{}
foreach ($event in $sortedEvents) {
    if ($event.Direction -eq "outbound") {
        $lastOutboundByPeer[$event.RemoteEndpoint] = $event
        continue
    }

    if (-not $lastOutboundByPeer.ContainsKey($event.RemoteEndpoint)) {
        continue
    }

    $lastOutbound = $lastOutboundByPeer[$event.RemoteEndpoint]
    if (($event.Epoch - $lastOutbound.Epoch) -gt $ReplyWindowSeconds) {
        continue
    }

    $pairKey = "{0}->{1}" -f $lastOutbound.UdpLength, $event.UdpLength
    if (-not $pairs.ContainsKey($pairKey)) {
        $pairs[$pairKey] = 0
    }
    $pairs[$pairKey] += 1
}

function Convert-Histogram {
    param(
        [hashtable]$InputMap,
        [int]$Take
    )

    $InputMap.GetEnumerator() |
        Sort-Object @{ Expression = "Value"; Descending = $true }, @{ Expression = "Key"; Descending = $false } |
        Select-Object -First $Take |
        ForEach-Object {
            [pscustomobject]@{
                Key = "$($_.Key)"
                Count = [int]$_.Value
            }
        }
}

[pscustomobject]@{
    PcapPath = $PcapPath
    Port = $Port
    EventCount = @($sortedEvents).Count
    CaptureSpanSeconds = [Math]::Round($spanSeconds, 3)
    PacketsPerSecond = [Math]::Round((@($sortedEvents).Count / [Math]::Max($spanSeconds, 1.0)), 3)
    OutboundLengthHistogram = @(Convert-Histogram -InputMap $lengthByDirection.outbound -Take $TopLengths)
    InboundLengthHistogram = @(Convert-Histogram -InputMap $lengthByDirection.inbound -Take $TopLengths)
    PlaintextPrefixHistogram = @(Convert-Histogram -InputMap $plaintextPrefixes -Take $TopPrefixes)
    ReplyLengthPairs = @(Convert-Histogram -InputMap $pairs -Take $TopPairs)
}

<#
.SYNOPSIS
Prints the packet timeline for one remote UDP endpoint in a Kad capture.

.DESCRIPTION
Useful during parity work to inspect the exact ordering of outbound and inbound
packets for a contacted peer, including payload length and raw hex prefix.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PcapPath,
    [Parameter(Mandatory = $true)]
    [int]$Port,
    [Parameter(Mandatory = $true)]
    [string]$RemoteEndpoint,
    [int]$HexPrefixChars = 32
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

$remoteParts = $RemoteEndpoint.Split(":", 2)
if ($remoteParts.Count -ne 2) {
    throw "RemoteEndpoint must be in ip:port form"
}

$remoteIp = $remoteParts[0]
$remotePort = $remoteParts[1]
$displayFilter = "udp and ((ip.src == $remoteIp and udp.srcport == $remotePort and udp.dstport == $Port) or (ip.dst == $remoteIp and udp.dstport == $remotePort and udp.srcport == $Port))"
$fields = @(
    "-e", "frame.number",
    "-e", "frame.time_epoch",
    "-e", "ip.src",
    "-e", "udp.srcport",
    "-e", "ip.dst",
    "-e", "udp.dstport",
    "-e", "udp.length",
    "-e", "data.data"
)

$rows = & $tsharkPath -r $PcapPath -Y $displayFilter -T fields -E separator=`t @fields 2>$null
foreach ($row in $rows) {
    if (-not $row) {
        continue
    }

    $parts = $row -split "`t"
    if ($parts.Count -lt 8) {
        continue
    }

    $srcIp = $parts[2]
    $srcPort = $parts[3]
    $dstIp = $parts[4]
    $dstPort = $parts[5]
    $remoteMatchesSrc = ($srcIp -eq $remoteIp -and $srcPort -eq $remotePort)
    $remoteMatchesDst = ($dstIp -eq $remoteIp -and $dstPort -eq $remotePort)
    $direction = if ($remoteMatchesDst -and -not $remoteMatchesSrc) {
        "outbound"
    } elseif ($remoteMatchesSrc -and -not $remoteMatchesDst) {
        "inbound"
    } elseif ($srcIp -eq $remoteIp -and $dstIp -ne $remoteIp) {
        "inbound"
    } else {
        "outbound"
    }
    $payloadHex = $parts[7]
    $payloadPrefix = if ($payloadHex.Length -le $HexPrefixChars) {
        $payloadHex
    } else {
        $payloadHex.Substring(0, $HexPrefixChars)
    }

    [pscustomobject]@{
        Frame = [int]$parts[0]
        TimeUtc = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]([double]$parts[1] * 1000)).UtcDateTime.ToString("o")
        Direction = $direction
        Src = "{0}:{1}" -f $srcIp, $srcPort
        Dst = "{0}:{1}" -f $dstIp, $dstPort
        UdpLength = [int]$parts[6]
        PayloadPrefix = $payloadPrefix
    }
}

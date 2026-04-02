<#
.SYNOPSIS
Summarizes a Kad UDP pcap by packet count and visible plaintext Kad payloads.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PcapPath,
    [Parameter(Mandatory = $true)]
    [int]$Port
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

$payloads = & $tsharkPath -r $PcapPath -Y "udp.port == $Port" -T fields -e data.data 2>$null |
    Where-Object { $_ -and $_.Trim().Length -gt 0 }
$outboundFrames = & $tsharkPath -r $PcapPath -Y "udp.srcport == $Port" -T fields -e frame.number 2>$null
$inboundFrames = & $tsharkPath -r $PcapPath -Y "udp.dstport == $Port" -T fields -e frame.number 2>$null

$totalPackets = @($payloads).Count
$outboundPacketCount = @($outboundFrames | Where-Object { $_ }).Count
$inboundPacketCount = @($inboundFrames | Where-Object { $_ }).Count
$plaintextKad = @($payloads | Where-Object { $_.StartsWith("e4", [System.StringComparison]::OrdinalIgnoreCase) }).Count
$publishKeyReq = @($payloads | Where-Object { $_.StartsWith("e443", [System.StringComparison]::OrdinalIgnoreCase) }).Count
$publishSourceReq = @($payloads | Where-Object { $_.StartsWith("e444", [System.StringComparison]::OrdinalIgnoreCase) }).Count
$publishRes = @($payloads | Where-Object { $_.StartsWith("e44b", [System.StringComparison]::OrdinalIgnoreCase) }).Count
$searchKeyReq = @($payloads | Where-Object { $_.StartsWith("e433", [System.StringComparison]::OrdinalIgnoreCase) }).Count
$searchSourceReq = @($payloads | Where-Object { $_.StartsWith("e435", [System.StringComparison]::OrdinalIgnoreCase) }).Count

[pscustomobject]@{
    PcapPath = $PcapPath
    Port = $Port
    TotalUdpPayloads = $totalPackets
    OutboundUdpFrames = $outboundPacketCount
    InboundUdpFrames = $inboundPacketCount
    PlaintextKadPayloads = $plaintextKad
    PlaintextPublishKeyReq = $publishKeyReq
    PlaintextPublishSourceReq = $publishSourceReq
    PlaintextPublishRes = $publishRes
    PlaintextSearchKeyReq = $searchKeyReq
    PlaintextSearchSourceReq = $searchSourceReq
}

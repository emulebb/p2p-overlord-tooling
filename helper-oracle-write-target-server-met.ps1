#Requires -Version 7.6
<#
.SYNOPSIS
Writes a minimal runtime server.met containing a single ED2K server entry.

.DESCRIPTION
This is useful for deterministic oracle parity sessions where the local eMule
profile should auto-connect to one known server without depending on a larger
rotating server list.
#>

[CmdletBinding()]
param(
    [string]$ServerIp = "176.123.2.239",
    [int]$ServerPort = 4232,
    [int]$UdpFlags = 0,
    [int]$UdpKey = 0,
    [int]$UdpKeyIp = 0,
    [int]$TcpObfuscationPort = 0,
    [int]$UdpObfuscationPort = 0,
    [string]$DestinationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedDestinationPath = if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    $oracleHarnessDebugDir = & (Join-Path $PSScriptRoot "helper-oracle-resolve-harness-debug-dir.ps1")
    Join-Path $oracleHarnessDebugDir "config\server.met"
} else {
    [System.IO.Path]::GetFullPath($DestinationPath)
}
$destinationDir = Split-Path -Parent $resolvedDestinationPath
$destinationPath = $resolvedDestinationPath
New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null

$ipBytes = [System.Net.IPAddress]::Parse($ServerIp).GetAddressBytes()
$ipValue = [System.BitConverter]::ToUInt32($ipBytes, 0)

function Add-ShortUInt32Tag {
    param(
        [System.Collections.Generic.List[byte]]$Buffer,
        [byte]$TagId,
        [uint32]$Value
    )

    $Buffer.Add(0x83)
    $Buffer.Add($TagId)
    $Buffer.AddRange([System.BitConverter]::GetBytes($Value))
}

function Add-ShortUInt16Tag {
    param(
        [System.Collections.Generic.List[byte]]$Buffer,
        [byte]$TagId,
        [uint16]$Value
    )

    $Buffer.Add(0x88)
    $Buffer.Add($TagId)
    $Buffer.AddRange([System.BitConverter]::GetBytes($Value))
}

$buffer = New-Object System.Collections.Generic.List[byte]
$buffer.Add(0xE0)
$buffer.AddRange([System.BitConverter]::GetBytes([uint32]1))
$buffer.AddRange([System.BitConverter]::GetBytes($ipValue))
$buffer.AddRange([System.BitConverter]::GetBytes([uint16]$ServerPort))
$tagCount = 0
if ($UdpFlags -ne 0) { $tagCount++ }
if ($UdpKey -ne 0) { $tagCount++ }
if ($UdpKeyIp -ne 0) { $tagCount++ }
if ($TcpObfuscationPort -ne 0) { $tagCount++ }
if ($UdpObfuscationPort -ne 0) { $tagCount++ }
$buffer.AddRange([System.BitConverter]::GetBytes([uint32]$tagCount))

if ($UdpFlags -ne 0) {
    Add-ShortUInt32Tag -Buffer $buffer -TagId 0x92 -Value ([uint32]$UdpFlags)
}
if ($UdpKey -ne 0) {
    Add-ShortUInt32Tag -Buffer $buffer -TagId 0x95 -Value ([uint32]$UdpKey)
}
if ($UdpKeyIp -ne 0) {
    Add-ShortUInt32Tag -Buffer $buffer -TagId 0x96 -Value ([uint32]$UdpKeyIp)
}
if ($TcpObfuscationPort -ne 0) {
    Add-ShortUInt16Tag -Buffer $buffer -TagId 0x97 -Value ([uint16]$TcpObfuscationPort)
}
if ($UdpObfuscationPort -ne 0) {
    Add-ShortUInt16Tag -Buffer $buffer -TagId 0x98 -Value ([uint16]$UdpObfuscationPort)
}

[System.IO.File]::WriteAllBytes($destinationPath, $buffer.ToArray())

[pscustomobject]@{
    DestinationPath = $destinationPath
    ServerIp = $ServerIp
    ServerPort = $ServerPort
    UdpFlags = $UdpFlags
    UdpKey = $UdpKey
    UdpKeyIp = $UdpKeyIp
    TcpObfuscationPort = $TcpObfuscationPort
    UdpObfuscationPort = $UdpObfuscationPort
    Bytes = (Get-Item $destinationPath).Length
}

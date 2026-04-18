#Requires -Version 7.6
<#
.SYNOPSIS
Posts one native ED2K download request to the live agent control API.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FileHash,
    [string]$FileName,
    [UInt64]$FileSize,
    [string]$SourceIp,
    [UInt16]$SourceTcpPort,
    [UInt32]$SourceClientId,
    [string]$SourceUserHash,
    [byte]$SourceObfuscationOptions,
    [string]$ControlUrl = "http://127.0.0.1:13301"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sources = @()
if (-not [string]::IsNullOrWhiteSpace($SourceIp)) {
    if ($SourceTcpPort -eq 0) {
        throw "SourceTcpPort must be provided when SourceIp is set"
    }

    $source = [ordered]@{
        ip = $SourceIp
        tcpPort = $SourceTcpPort
    }
    if ($PSBoundParameters.ContainsKey("SourceClientId")) {
        $source.clientId = $SourceClientId
    }
    if (-not [string]::IsNullOrWhiteSpace($SourceUserHash)) {
        $source.userHash = $SourceUserHash
    }
    if ($PSBoundParameters.ContainsKey("SourceObfuscationOptions")) {
        $source.obfuscationOptions = [int]$SourceObfuscationOptions
    }

    $sources = @([pscustomobject]$source)
}

$payload = [ordered]@{
    kind = "ed2k_download"
    fileHash = $FileHash.ToLowerInvariant()
    sources = $sources
}
if (-not [string]::IsNullOrWhiteSpace($FileName)) {
    $payload.fileName = $FileName
}
if ($PSBoundParameters.ContainsKey("FileSize") -and $FileSize -ne 0) {
    $payload.fileSize = $FileSize
}

Invoke-RestMethod `
    -Method Post `
    -Uri ("{0}/api/internal/enrich" -f $ControlUrl.TrimEnd("/")) `
    -ContentType "application/json" `
    -Body ([pscustomobject]$payload | ConvertTo-Json -Depth 5)

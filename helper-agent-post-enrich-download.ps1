<#
.SYNOPSIS
Posts one native ED2K download request to the live agent control API.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FileHash,
    [Parameter(Mandatory = $true)]
    [string]$FileName,
    [Parameter(Mandatory = $true)]
    [UInt64]$FileSize,
    [string]$ControlUrl = "http://127.0.0.1:13301"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$payload = [pscustomobject]@{
    kind = "ed2k_download"
    fileHash = $FileHash.ToLowerInvariant()
    fileName = $FileName
    fileSize = $FileSize
    sources = @()
}

Invoke-RestMethod `
    -Method Post `
    -Uri ("{0}/api/internal/enrich" -f $ControlUrl.TrimEnd("/")) `
    -ContentType "application/json" `
    -Body ($payload | ConvertTo-Json -Depth 5)

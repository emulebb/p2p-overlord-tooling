#Requires -Version 7.6
<#
.SYNOPSIS
Posts one deterministic local file-ingest request to the live agent control API.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [Parameter(Mandatory = $true)]
    [string]$CanonicalName,
    [string]$ControlUrl = "http://127.0.0.1:13301"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$payload = [ordered]@{
    sourcePath = [System.IO.Path]::GetFullPath($SourcePath)
    canonicalName = $CanonicalName
}

$response = Invoke-WebRequest `
    -Method Post `
    -Uri ("{0}/api/internal/ingest-local-file" -f $ControlUrl.TrimEnd("/")) `
    -ContentType "application/json" `
    -Body ([pscustomobject]$payload | ConvertTo-Json -Depth 4) `
    -SkipHttpErrorCheck

if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
    $body = [string]$response.Content
    throw "Agent ingest-local-file request failed with HTTP $($response.StatusCode): $body"
}

if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
    return $null
}

$response.Content | ConvertFrom-Json

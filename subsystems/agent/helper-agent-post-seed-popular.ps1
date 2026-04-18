#Requires -Version 7.6
<#
.SYNOPSIS
Posts one or more explicit popular-hash seeds to the live agent internal API.

.DESCRIPTION
Uses the agent's manual `POST /api/internal/seed-popular` endpoint so parity
sessions can trigger a deterministic publish batch without waiting for the
coordinator or the synthetic fallback set.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Ed2kHash,
    [Parameter(Mandatory = $true)]
    [string]$CanonicalName,
    [Parameter(Mandatory = $true)]
    [UInt64]$Size,
    [UInt32]$SourceCount = 1,
    [string]$ControlUrl = "http://127.0.0.1:13301"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$payload = @(
    [pscustomobject]@{
        hash = [pscustomobject]@{
            kind = "ed2k"
            value = $Ed2kHash.ToLowerInvariant()
        }
        canonical_name = $CanonicalName
        size = $Size
        source_count = $SourceCount
    }
)

$uri = "{0}/api/internal/seed-popular" -f $ControlUrl.TrimEnd("/")
$json = $payload | ConvertTo-Json -Depth 5 -AsArray

$response = Invoke-WebRequest `
    -Method Post `
    -Uri $uri `
    -ContentType "application/json" `
    -Body $json `
    -SkipHttpErrorCheck

if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
    $body = [string]$response.Content
    throw "Agent seed-popular request failed with HTTP $($response.StatusCode): $body"
}

if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
    return $null
}

$response.Content | ConvertFrom-Json

<#
.SYNOPSIS
Fetches the live agent internal stats endpoint used during parity sessions.
#>

[CmdletBinding()]
param(
    [string]$StatsUrl = "http://127.0.0.1:13301/api/internal/stats"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10 | ConvertTo-Json -Depth 8

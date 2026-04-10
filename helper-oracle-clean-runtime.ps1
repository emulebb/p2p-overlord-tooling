#Requires -Version 7.6
<#
.SYNOPSIS
Stops oracle parity runtime processes and waits for them to exit.

.DESCRIPTION
Terminates the distinct parity oracle process, legacy local oracle names, and
associated dumpcap capture processes for a given UDP capture port. The helper
verifies that all targeted processes are gone before returning so new runs do
not inherit stale runtime state.
#>

[CmdletBinding()]
param(
    [int]$CapturePort = 0,
    [AllowEmptyCollection()]
    [int[]]$OraclePids = @(),
    [AllowEmptyCollection()]
    [int[]]$DumpcapPids = @(),
    [int]$WaitTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-OracleProcessNames {
    @("eMule_v072a_parity")
}

function Stop-ProcessIds {
    param(
        [int[]]$Ids
    )

    if ($null -eq $Ids -or $Ids.Count -eq 0) {
        return
    }

    foreach ($processId in $Ids | Where-Object { $_ -gt 0 } | Select-Object -Unique) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
}

function Get-ValidProcessIds {
    param(
        [AllowEmptyCollection()]
        [int[]]$Ids
    )

    return ,@($Ids | Where-Object { $_ -gt 0 } | Select-Object -Unique)
}

function Stop-DumpcapCapturePort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $dumpcaps = Get-CimInstance Win32_Process -Filter "Name = 'dumpcap.exe'" -ErrorAction SilentlyContinue
    foreach ($dumpcap in @($dumpcaps)) {
        if ($null -eq $dumpcap.CommandLine) {
            continue
        }
        if ($dumpcap.CommandLine -notmatch "udp port\s+$Port(\D|$)") {
            continue
        }
        Stop-Process -Id $dumpcap.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Test-NoProcessesRemain {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$OracleNames,
        [AllowEmptyCollection()]
        [int[]]$OracleIds,
        [AllowEmptyCollection()]
        [int[]]$CaptureIds
    )

    $resolvedOracleIds = Get-ValidProcessIds -Ids $OracleIds
    $resolvedCaptureIds = Get-ValidProcessIds -Ids $CaptureIds

    foreach ($processId in $resolvedOracleIds) {
        if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
            return $false
        }
    }

    foreach ($processId in $resolvedCaptureIds) {
        if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
            return $false
        }
    }

    # Pre-launch cleanup (no specific PIDs): wait for all name-matched processes to be gone
    if ($resolvedOracleIds.Count -eq 0) {
        if (@(Get-Process -Name $OracleNames -ErrorAction SilentlyContinue).Count -gt 0) {
            return $false
        }
    }

    return $true
}

$oracleProcessNames = Get-OracleProcessNames
Stop-ProcessIds -Ids $DumpcapPids
if ($CapturePort -gt 0) {
    Stop-DumpcapCapturePort -Port $CapturePort
}

Stop-ProcessIds -Ids $OraclePids
# Pre-launch cleanup only: if no PIDs were provided, kill any leftover oracle by name
if ((Get-ValidProcessIds -Ids $OraclePids).Count -eq 0) {
    foreach ($name in $oracleProcessNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force
    }
}

$deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-NoProcessesRemain -OracleNames $oracleProcessNames -OracleIds $OraclePids -CaptureIds $DumpcapPids) {
        break
    }
    Start-Sleep -Milliseconds 250
}

if (-not (Test-NoProcessesRemain -OracleNames $oracleProcessNames -OracleIds $OraclePids -CaptureIds $DumpcapPids)) {
    throw "Oracle runtime cleanup did not fully terminate the targeted processes"
}

[pscustomobject]@{
    CapturePort = $CapturePort
    OraclePids = Get-ValidProcessIds -Ids $OraclePids
    DumpcapPids = Get-ValidProcessIds -Ids $DumpcapPids
    CleanedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

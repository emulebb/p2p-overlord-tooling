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

    $remainingOracleByName = @(Get-Process -Name $OracleNames -ErrorAction SilentlyContinue)
    $remainingOracleById = @()
    foreach ($processId in $OracleIds | Where-Object { $_ -gt 0 } | Select-Object -Unique) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process) {
            $remainingOracleById += $process
        }
    }

    $remainingDumpcaps = @()
    foreach ($processId in $CaptureIds | Where-Object { $_ -gt 0 } | Select-Object -Unique) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process) {
            $remainingDumpcaps += $process
        }
    }

    return ($remainingOracleByName.Count -eq 0 -and $remainingOracleById.Count -eq 0 -and $remainingDumpcaps.Count -eq 0)
}

$oracleProcessNames = Get-OracleProcessNames
Stop-ProcessIds -Ids $DumpcapPids
if ($CapturePort -gt 0) {
    Stop-DumpcapCapturePort -Port $CapturePort
}

Stop-ProcessIds -Ids $OraclePids
foreach ($name in $oracleProcessNames) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force
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
    OraclePids = @($OraclePids | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    DumpcapPids = @($DumpcapPids | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    CleanedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

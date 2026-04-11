#Requires -Version 7.6
<#
.SYNOPSIS
Stops eMule harness parity runtime processes and waits for them to exit.

.DESCRIPTION
Terminates the distinct parity eMule harness process, associated local runtime
names, and dumpcap capture processes for a given UDP capture port. The helper
verifies that all targeted processes are gone before returning so new runs do
not inherit stale runtime state.
#>

[CmdletBinding()]
param(
    [int]$CapturePort = 0,
    [AllowEmptyCollection()]
    [int[]]$EmuleHarnessPids = @(),
    [AllowEmptyCollection()]
    [int[]]$DumpcapPids = @(),
    [int]$WaitTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-EmuleHarnessProcessNames {
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
        [string[]]$EmuleHarnessNames,
        [AllowEmptyCollection()]
        [int[]]$EmuleHarnessIds,
        [AllowEmptyCollection()]
        [int[]]$CaptureIds
    )

    $resolvedEmuleHarnessIds = Get-ValidProcessIds -Ids $EmuleHarnessIds
    $resolvedCaptureIds = Get-ValidProcessIds -Ids $CaptureIds

    foreach ($processId in $resolvedEmuleHarnessIds) {
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
    if ($resolvedEmuleHarnessIds.Count -eq 0) {
        if (@(Get-Process -Name $EmuleHarnessNames -ErrorAction SilentlyContinue).Count -gt 0) {
            return $false
        }
    }

    return $true
}

$emuleHarnessProcessNames = Get-EmuleHarnessProcessNames
Stop-ProcessIds -Ids $DumpcapPids
if ($CapturePort -gt 0) {
    Stop-DumpcapCapturePort -Port $CapturePort
}

Stop-ProcessIds -Ids $EmuleHarnessPids
# Pre-launch cleanup only: if no PIDs were provided, kill any leftover eMule harness by name
if ((Get-ValidProcessIds -Ids $EmuleHarnessPids).Count -eq 0) {
    foreach ($name in $emuleHarnessProcessNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force
    }
}

$deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-NoProcessesRemain -EmuleHarnessNames $emuleHarnessProcessNames -EmuleHarnessIds $EmuleHarnessPids -CaptureIds $DumpcapPids) {
        break
    }
    Start-Sleep -Milliseconds 250
}

if (-not (Test-NoProcessesRemain -EmuleHarnessNames $emuleHarnessProcessNames -EmuleHarnessIds $EmuleHarnessPids -CaptureIds $DumpcapPids)) {
    throw "eMule harness runtime cleanup did not fully terminate the targeted processes"
}

[pscustomobject]@{
    CapturePort = $CapturePort
    EmuleHarnessPids = Get-ValidProcessIds -Ids $EmuleHarnessPids
    DumpcapPids = Get-ValidProcessIds -Ids $DumpcapPids
    CleanedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

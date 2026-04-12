#Requires -Version 7.6
<#
.SYNOPSIS
Stops agent parity runtime processes and waits for them to exit.
#>

[CmdletBinding()]
param(
    [int]$CapturePort = 0,
    [AllowEmptyCollection()]
    [int[]]$AgentPids = @(),
    [AllowEmptyCollection()]
    [int[]]$DumpcapPids = @(),
    [int]$WaitTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
        [AllowEmptyCollection()]
        [int[]]$RuntimeIds,
        [AllowEmptyCollection()]
        [int[]]$CaptureIds
    )

    $resolvedRuntimeIds = Get-ValidProcessIds -Ids $RuntimeIds
    $resolvedCaptureIds = Get-ValidProcessIds -Ids $CaptureIds

    foreach ($processId in $resolvedRuntimeIds) {
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
    if ($resolvedRuntimeIds.Count -eq 0) {
        if (@(Get-Process -Name "overlord-agent-emule" -ErrorAction SilentlyContinue).Count -gt 0) {
            return $false
        }
    }

    return $true
}

Stop-ProcessIds -Ids $DumpcapPids
if ($CapturePort -gt 0) {
    Stop-DumpcapCapturePort -Port $CapturePort
}

Stop-ProcessIds -Ids $AgentPids
# Pre-launch cleanup only: if no PIDs were provided, kill any leftover agent by name
if ((Get-ValidProcessIds -Ids $AgentPids).Count -eq 0) {
    Get-Process -Name "overlord-agent-emule" -ErrorAction SilentlyContinue | Stop-Process -Force
}

$deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-NoProcessesRemain -RuntimeIds $AgentPids -CaptureIds $DumpcapPids) {
        break
    }
    Start-Sleep -Milliseconds 250
}

if (-not (Test-NoProcessesRemain -RuntimeIds $AgentPids -CaptureIds $DumpcapPids)) {
    throw "Agent runtime cleanup did not fully terminate the targeted processes"
}

[pscustomobject]@{
    CapturePort = $CapturePort
    AgentPids = Get-ValidProcessIds -Ids $AgentPids
    DumpcapPids = Get-ValidProcessIds -Ids $DumpcapPids
    CleanedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

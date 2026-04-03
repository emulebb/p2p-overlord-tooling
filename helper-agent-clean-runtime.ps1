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

    $remainingByName = @(Get-Process -Name "overlord-agent-emule" -ErrorAction SilentlyContinue)
    $remainingById = @()
    foreach ($processId in $RuntimeIds | Where-Object { $_ -gt 0 } | Select-Object -Unique) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process) {
            $remainingById += $process
        }
    }

    $remainingDumpcaps = @()
    foreach ($processId in $CaptureIds | Where-Object { $_ -gt 0 } | Select-Object -Unique) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process) {
            $remainingDumpcaps += $process
        }
    }

    return ($remainingByName.Count -eq 0 -and $remainingById.Count -eq 0 -and $remainingDumpcaps.Count -eq 0)
}

Stop-ProcessIds -Ids $DumpcapPids
if ($CapturePort -gt 0) {
    Stop-DumpcapCapturePort -Port $CapturePort
}

Stop-ProcessIds -Ids $AgentPids
Get-Process -Name "overlord-agent-emule" -ErrorAction SilentlyContinue | Stop-Process -Force

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
    AgentPids = @($AgentPids | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    DumpcapPids = @($DumpcapPids | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    CleanedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

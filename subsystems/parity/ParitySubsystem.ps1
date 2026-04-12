#Requires -Version 7.6

. (Join-Path $PSScriptRoot "..\RuntimeContext.ps1")

function Resolve-ParitySubsystemPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("CompareEd2kJsonl", "CompareUdpJsonl")]
        [string]$Name
    )

    $fileName = switch ($Name) {
        "CompareEd2kJsonl" { "helper-parity-compare-ed2k-jsonl.py" }
        "CompareUdpJsonl" { "helper-parity-compare-udp-jsonl.py" }
    }

    $path = Join-Path $PSScriptRoot $fileName
    Assert-ToolingPaths -Paths @($path) -Label "Parity subsystem script"
    $path
}

function Compare-UdpParityJsonl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EmuleHarnessPath,
        [Parameter(Mandatory = $true)]
        [string]$AgentPath,
        [string[]]$Opcodes = @(),
        [string]$OutputPath
    )

    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw "python is not available on PATH"
    }

    $arguments = @(
        (Resolve-ParitySubsystemPath -Name "CompareUdpJsonl")
        "--emule-harness"
        $EmuleHarnessPath
        "--agent"
        $AgentPath
    )
    if ($Opcodes.Count -gt 0) {
        $arguments += "--opcodes"
        $arguments += $Opcodes
    }

    $output = & python @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "UDP parity comparison failed with exit code $LASTEXITCODE"
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $output | Set-Content -Encoding utf8NoBOM $OutputPath
    }

    $output
}

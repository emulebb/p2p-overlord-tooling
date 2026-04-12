#Requires -Version 7.6

. (Join-Path $PSScriptRoot "..\RuntimeContext.ps1")

function Resolve-KadSeedBundleFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolingRoot,
        [Parameter(Mandatory = $true)]
        [string]$SeedBundleId,
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    Join-Path $ToolingRoot ".local\emule-harness-seeds\$SeedBundleId\$FileName"
}

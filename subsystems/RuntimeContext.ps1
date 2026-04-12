#Requires -Version 7.6

function Resolve-ToolingRepoRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartPath
    )

    $current = if (Test-Path -LiteralPath $StartPath -PathType Leaf) {
        Split-Path -Parent ([System.IO.Path]::GetFullPath($StartPath))
    }
    else {
        [System.IO.Path]::GetFullPath($StartPath)
    }

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath (Join-Path $current "overlord-tooling.ps1") -PathType Leaf) {
            return $current
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }

    throw "Could not resolve tooling repo root from $StartPath"
}

function Get-ToolingRuntimeContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $toolingRoot = Resolve-ToolingRepoRoot -StartPath $SourcePath
    $workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $toolingRoot ".."))

    [pscustomobject]@{
        ToolingRoot = $toolingRoot
        WorkspaceRoot = $workspaceRoot
        ProjectDir = if ($env:OVERLORD_PROJECT_DIR) { $env:OVERLORD_PROJECT_DIR } else { $workspaceRoot }
        TmpDir = $env:OVERLORD_TMP_DIR
        LogDir = $env:OVERLORD_LOG_DIR
        EmuleWorkspaceRoot = $env:EMULE_WORKSPACE_ROOT
    }
}

function Assert-ToolingPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths,
        [string]$Label = "Required path"
    )

    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "$Label not found at $path"
        }
    }
}

function Invoke-ToolingScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [hashtable]$NamedArguments,
        [object[]]$PositionalArguments
    )

    Assert-ToolingPaths -Paths @($ScriptPath) -Label "Tooling script"

    if ($NamedArguments -and $PositionalArguments) {
        & $ScriptPath @NamedArguments @PositionalArguments
        return
    }
    if ($NamedArguments) {
        & $ScriptPath @NamedArguments
        return
    }
    if ($PositionalArguments) {
        & $ScriptPath @PositionalArguments
        return
    }

    & $ScriptPath
}

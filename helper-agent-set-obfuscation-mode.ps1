#Requires -Version 7.6
<#
.SYNOPSIS
Sets the local agent's Kad and ED2K obfuscation flags in the runtime TOML config.

.DESCRIPTION
This helper updates the untracked runtime config used for live parity runs so the
agent can be switched between plaintext and obfuscated transport modes without
manual editing. It only touches the requested keys and leaves the rest of the
runtime configuration intact.
#>

[CmdletBinding()]
param(
    [ValidateSet("On", "Off")]
    [string]$Kad = "On",
    [ValidateSet("On", "Off")]
    [string]$Ed2k = "On",
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $tmpDir "agent-real-miniupnpc.toml"
}

if (-not (Test-Path $ConfigPath)) {
    throw "Agent runtime config not found at $ConfigPath"
}

function Set-TomlBooleanKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$SectionName,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [bool]$Value
    )

    $sectionPattern = "(?ms)^\[$([regex]::Escape($SectionName))\]\r?\n(?<Body>.*?)(?=^\[|\z)"
    $match = [regex]::Match($Content, $sectionPattern)
    if (-not $match.Success) {
        throw "Section [$SectionName] not found in $ConfigPath"
    }

    $sectionText = $match.Value
    $replacement = "$Key = " + $Value.ToString().ToLowerInvariant()
    if ($sectionText -match "(?m)^$([regex]::Escape($Key))\s*=") {
        $updatedSection = [regex]::Replace(
            $sectionText,
            "(?m)^$([regex]::Escape($Key))\s*=.*$",
            $replacement
        )
    } else {
        $updatedSection = $sectionText.TrimEnd("`r", "`n") + "`n$replacement`n"
    }

    return $Content.Substring(0, $match.Index) + $updatedSection + $Content.Substring($match.Index + $match.Length)
}

$content = Get-Content -Raw $ConfigPath
$content = Set-TomlBooleanKey -Content $content -SectionName "p2p.kad" -Key "obfuscation_enabled" -Value ($Kad -eq "On")
$content = Set-TomlBooleanKey -Content $content -SectionName "p2p.ed2k" -Key "obfuscation_enabled" -Value ($Ed2k -eq "On")

[System.IO.File]::WriteAllText(
    $ConfigPath,
    $content,
    (New-Object System.Text.UTF8Encoding($false))
)

[pscustomobject]@{
    ConfigPath = $ConfigPath
    KadObfuscationEnabled = ($Kad -eq "On")
    Ed2kObfuscationEnabled = ($Ed2k -eq "On")
}

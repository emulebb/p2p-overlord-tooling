#Requires -Version 7.6
<#
.SYNOPSIS
Materializes a deterministic local eMule harness profile for private Kad+ED2K runs.

.DESCRIPTION
Creates one clean-room experimental eMule profile rooted under a scenario-owned
runtime directory. The profile is isolated from the public network and keeps a
stable local identity across resets by preserving only the identity-bearing
config files.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileRoot,
    [Parameter(Mandatory = $true)]
    [string]$BindAddr,
    [Parameter(Mandatory = $true)]
    [UInt16]$TcpPort,
    [Parameter(Mandatory = $true)]
    [UInt16]$UdpPort,
    [UInt16]$ServerUdpPort = 0,
    [UInt16]$WebPort = 47101,
    [UInt32]$KadUdpKey = 4206201,
    [string]$KadIdHex,
    [bool]$EnableKademlia = $true,
    [bool]$EnableEd2k = $true,
    [switch]$ResetTransientState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-KadIdHexOverride {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot,
        [string]$KadIdHex
    )

    if (-not [string]::IsNullOrWhiteSpace($KadIdHex)) {
        return $KadIdHex
    }

    $mapJson = $env:OVERLORD_EMULE_HARNESS_PRIVATE_KAD_ID_MAP_JSON
    if ([string]::IsNullOrWhiteSpace($mapJson)) {
        return $null
    }

    $map = $mapJson | ConvertFrom-Json -AsHashtable
    $profileName = Split-Path -Leaf $ProfileRoot
    if ($map.ContainsKey($profileName)) {
        return [string]$map[$profileName]
    }

    return $null
}

function Write-PreferencesKadDat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$KadIdHex
    )

    $normalizedHex = ($KadIdHex -replace '\s+', '').ToUpperInvariant()
    if ($normalizedHex.Length -ne 32 -or $normalizedHex -notmatch '^[0-9A-F]{32}$') {
        throw "KadIdHex must be exactly 32 hex characters"
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = [System.IO.BinaryWriter]::new($stream)
        try {
            $writer.Write([UInt32]0)
            $writer.Write([UInt16]0)
            for ($chunkIndex = 0; $chunkIndex -lt 4; $chunkIndex++) {
                $chunkHex = $normalizedHex.Substring($chunkIndex * 8, 8)
                $writer.Write([UInt32]::Parse($chunkHex, [System.Globalization.NumberStyles]::HexNumber))
            }
            $writer.Write([byte]0)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-PreferencesContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BindAddr,
        [Parameter(Mandatory = $true)]
        [UInt16]$TcpPort,
        [Parameter(Mandatory = $true)]
        [UInt16]$UdpPort,
        [Parameter(Mandatory = $true)]
        [UInt16]$ServerUdpPort,
        [Parameter(Mandatory = $true)]
        [UInt16]$WebPort,
        [Parameter(Mandatory = $true)]
        [UInt32]$KadUdpKey,
        [Parameter(Mandatory = $true)]
        [bool]$EnableKademlia,
        [Parameter(Mandatory = $true)]
        [bool]$EnableEd2k
    )

@"
[eMule]
AppVersion=0.72a
Port=$TcpPort
UDPPort=$UdpPort
ServerUDPPort=$ServerUdpPort
BindAddr=$BindAddr
AllowLocalHostIP=1
FilterBadIPs=0
Autoconnect=1
StartupMinimized=1
MinToTray=1
BringToFront=0
Splashscreen=0
SaveLogToDisk=1
SaveDebugToDisk=1
Verbose=1
OnlineSignature=0
AutoTakeED2KLinks=0
AutoConnectStaticOnly=0
Serverlist=0
AddServersFromServer=0
AddServersFromClient=0
NetworkKademlia=$(if ($EnableKademlia) { 1 } else { 0 })
NetworkED2K=$(if ($EnableEd2k) { 1 } else { 0 })
OpenPortsOnStartUp=0
EnableScheduler=0
KadUDPKey=$KadUdpKey
CreateCrashDump=0
Nick=eMule harness
CryptLayerRequested=0
CryptLayerRequired=0
CryptLayerSupported=0

[WebServer]
Enabled=0
Port=$WebPort
WebUseUPnP=0

[UPnP]
EnableUPnP=0
CloseUPnPOnExit=0
"@
}

$resolvedProfileRoot = [System.IO.Path]::GetFullPath($ProfileRoot)
$configRoot = Join-Path $resolvedProfileRoot "config"
$logsRoot = Join-Path $resolvedProfileRoot "logs"
$incomingRoot = Join-Path $resolvedProfileRoot "Incoming"
$tempRoot = Join-Path $resolvedProfileRoot "Temp"

foreach ($path in @($resolvedProfileRoot, $configRoot, $logsRoot, $incomingRoot, $tempRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$preferencesPath = Join-Path $configRoot "preferences.ini"
[string]$resolvedKadIdHex = Resolve-KadIdHexOverride -ProfileRoot $resolvedProfileRoot -KadIdHex $KadIdHex
[System.IO.File]::WriteAllText(
    $preferencesPath,
    (Get-PreferencesContent -BindAddr $BindAddr -TcpPort $TcpPort -UdpPort $UdpPort -ServerUdpPort $ServerUdpPort -WebPort $WebPort -KadUdpKey $KadUdpKey -EnableKademlia $EnableKademlia -EnableEd2k $EnableEd2k),
    (New-Object System.Text.ASCIIEncoding)
)

if (-not [string]::IsNullOrWhiteSpace($resolvedKadIdHex)) {
    Write-PreferencesKadDat -Path (Join-Path $configRoot "preferencesKad.dat") -KadIdHex $resolvedKadIdHex
}

if ($ResetTransientState) {
    foreach ($path in @($logsRoot, $incomingRoot, $tempRoot)) {
        if (Test-Path -LiteralPath $path) {
            Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $keepConfigFiles = @(
        "preferences.ini",
        "preferences.dat",
        "preferencesKad.dat",
        "cryptkey.dat",
        "collectioncryptkey.dat"
    )
    foreach ($item in Get-ChildItem -LiteralPath $configRoot -Force -ErrorAction SilentlyContinue) {
        if ($keepConfigFiles -contains $item.Name) {
            continue
        }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach ($markerName in @("harness.ready", "status.log", "seed.ed2k")) {
        $markerPath = Join-Path $resolvedProfileRoot $markerName
        if (Test-Path -LiteralPath $markerPath) {
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

[pscustomobject]@{
    ProfileRoot = $resolvedProfileRoot
    PreferencesPath = $preferencesPath
    LogsRoot = $logsRoot
    IncomingRoot = $incomingRoot
    TempRoot = $tempRoot
    EnableKademlia = $EnableKademlia
    EnableEd2k = $EnableEd2k
}

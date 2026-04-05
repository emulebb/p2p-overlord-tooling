<#
.SYNOPSIS
Materializes a deterministic local oracle profile for private Kad+ED2K runs.

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
    [switch]$ResetTransientState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
        [UInt32]$KadUdpKey
    )

@"
[eMule]
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
NetworkKademlia=1
NetworkED2K=1
OpenPortsOnStartUp=0
EnableScheduler=0
KadUDPKey=$KadUdpKey
CreateCrashDump=0

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
[System.IO.File]::WriteAllText(
    $preferencesPath,
    (Get-PreferencesContent -BindAddr $BindAddr -TcpPort $TcpPort -UdpPort $UdpPort -ServerUdpPort $ServerUdpPort -WebPort $WebPort -KadUdpKey $KadUdpKey),
    (New-Object System.Text.ASCIIEncoding)
)

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
}

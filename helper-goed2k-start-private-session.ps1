<#
.SYNOPSIS
Builds and starts one local goed2k-server session for a scenario run.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenarioRoot,
    [string]$ListenHost = "127.0.0.1",
    [UInt16]$TcpPort = 42161,
    [UInt16]$AdminPort = 42180,
    [int]$UDPPortOffset = 4,
    [string]$AdminToken = "local-goed2k-token",
    [string]$SourceCatalogPath,
    [int]$LaunchTimeoutSeconds = 120,
    [switch]$EnableObfuscation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Wait-TcpReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ListenHost,
        [Parameter(Mandatory = $true)]
        [UInt16]$Port,
        [Parameter(Mandatory = $true)]
        [datetime]$Deadline
    )

    while ((Get-Date) -lt $Deadline) {
        $client = $null
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $async = $client.ConnectAsync($ListenHost, $Port)
            if ($async.Wait(1000) -and $client.Connected) {
                return
            }
        }
        catch {
        }
        finally {
            if ($null -ne $client) {
                $client.Dispose()
            }
        }
        Start-Sleep -Milliseconds 250
    }

    throw "goed2k-server TCP listener ${ListenHost}:$Port did not become ready within the timeout"
}

function Wait-HealthReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [datetime]$Deadline
    )

    while ((Get-Date) -lt $Deadline) {
        try {
            $response = Invoke-RestMethod -Uri $Url -TimeoutSec 5
            if ($null -ne $response) {
                return
            }
        }
        catch {
        }
        Start-Sleep -Milliseconds 500
    }

    throw "goed2k-server health endpoint $Url did not become ready within the timeout"
}

$projectDir = if ($env:OVERLORD_PROJECT_DIR) {
    $env:OVERLORD_PROJECT_DIR
} else {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
$tmpDir = if ($env:OVERLORD_TMP_DIR) {
    $env:OVERLORD_TMP_DIR
} else {
    throw "OVERLORD_TMP_DIR is not set"
}

$repoRoot = Join-Path $projectDir "ext-deps\goed2k-server"
$configWriterPath = Join-Path $PSScriptRoot "helper-goed2k-write-private-local-config.ps1"

foreach ($requiredPath in @($repoRoot, $configWriterPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required goed2k path not found at $requiredPath"
    }
}

$configResult = & $configWriterPath `
    -ScenarioRoot $ScenarioRoot `
    -ListenHost $ListenHost `
    -TcpPort $TcpPort `
    -AdminPort $AdminPort `
    -UDPPortOffset $UDPPortOffset `
    -AdminToken $AdminToken `
    -SourceCatalogPath $SourceCatalogPath `
    -EnableObfuscation:$EnableObfuscation

$runtimeRoot = $configResult.RuntimeRoot
$binaryPath = Join-Path $runtimeRoot "goed2k-server.exe"
$stdoutPath = Join-Path $configResult.LogRoot "goed2k-server.stdout.log"
$stderrPath = Join-Path $configResult.LogRoot "goed2k-server.stderr.log"

Push-Location $repoRoot
try {
    & go build -o $binaryPath .\cmd\goed2k-server
}
finally {
    Pop-Location
}
if (-not (Test-Path -LiteralPath $binaryPath)) {
    throw "goed2k-server binary was not built at $binaryPath"
}

$sessionName = "private-goed2k-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$sessionDir = Join-Path $tmpDir $sessionName
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$metadataPath = Join-Path $sessionDir "goed2k-session.json"
$sessionStartUtc = (Get-Date).ToUniversalTime()

$process = Start-Process `
    -FilePath $binaryPath `
    -ArgumentList @("-config", $configResult.ConfigPath) `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru

$deadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
Wait-TcpReady -ListenHost $configResult.ListenHost -Port $configResult.TcpPort -Deadline $deadline
Wait-HealthReady -Url ("http://{0}:{1}/healthz" -f $configResult.ListenHost, $configResult.AdminPort) -Deadline $deadline

$metadata = [pscustomobject]@{
    SessionDir = $sessionDir
    SessionName = $sessionName
    RepoRoot = $repoRoot
    RuntimeRoot = $runtimeRoot
    ConfigPath = $configResult.ConfigPath
    CatalogPath = $configResult.CatalogPath
    SourceCatalogPath = $configResult.SourceCatalogPath
    LogRoot = $configResult.LogRoot
    StdoutPath = $stdoutPath
    StderrPath = $stderrPath
    HealthUrl = "http://$($configResult.ListenHost):$($configResult.AdminPort)/healthz"
    AdminBaseUrl = "http://$($configResult.ListenHost):$($configResult.AdminPort)"
    AdminToken = $configResult.AdminToken
    ListenHost = $configResult.ListenHost
    TcpPort = $configResult.TcpPort
    UDPPort = $configResult.UDPPort
    AdminPort = $configResult.AdminPort
    UdpPortOffset = $configResult.UDPPortOffset
    Pid = $process.Id
    StartedAtUtc = $sessionStartUtc.ToString("o")
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metadataPath -Encoding utf8NoBOM
$metadata

function New-AgentSessionMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionDir,
        [Parameter(Mandatory = $true)]
        [string]$SessionName,
        [string]$StateRoot,
        [string]$LogRoot,
        [string]$ConfigPath,
        [string]$ConfigBackupPath,
        [string]$CapturePath,
        [int]$CapturePort = 0,
        [string]$AgentLogPath,
        [string]$PacketDumpPath,
        [UInt16]$ControlPort = 0,
        [UInt16]$KadPort = 0,
        [UInt16]$Ed2kPort = 0,
        [string]$BindIp,
        [string]$RequestedInterfaceAlias,
        [string]$InterfaceAlias,
        [bool]$InterfaceFallbackUsed = $false,
        [string]$NetworkingPath,
        [object]$TargetServer,
        [int]$KadBootstrapReadyContacts = 0,
        [bool]$KadDisabled = $false,
        [string]$ServerHost,
        [Nullable[UInt16]]$ServerPort = $null,
        [string]$ProbeSearchTerm,
        [int]$DumpcapPid = 0,
        [string]$DumpcapStdoutPath,
        [string]$DumpcapStderrPath,
        [int]$AgentPid = 0,
        [Parameter(Mandatory = $true)]
        [datetime]$StartedAtUtc
    )

    $resolvedStateRoot = if ([string]::IsNullOrWhiteSpace($StateRoot)) { $null } else { [System.IO.Path]::GetFullPath($StateRoot) }
    $resolvedLogRoot = if ([string]::IsNullOrWhiteSpace($LogRoot)) { $null } else { [System.IO.Path]::GetFullPath($LogRoot) }
    $resolvedAgentLogPath = if ([string]::IsNullOrWhiteSpace($AgentLogPath)) {
        if ($resolvedLogRoot) {
            Join-Path $resolvedLogRoot "overlord-agent-emule.log"
        }
        else {
            $null
        }
    }
    else {
        [System.IO.Path]::GetFullPath($AgentLogPath)
    }

    $resolvedBindIp = if ([string]::IsNullOrWhiteSpace($BindIp)) { $null } else { $BindIp }
    $controlUrl = if ($ControlPort -gt 0) { "http://127.0.0.1:$ControlPort" } else { $null }
    $statsUrl = if ($ControlPort -gt 0) { "http://127.0.0.1:$ControlPort/api/internal/stats" } else { $null }
    $transferRoot = if ($resolvedStateRoot) { Join-Path $resolvedStateRoot "overlord-ed2k-transfer" } else { $null }

    return [pscustomobject]@{
        SessionDir = $SessionDir
        SessionName = $SessionName
        StateRoot = $resolvedStateRoot
        AgentStateRoot = $resolvedStateRoot
        LogRoot = $resolvedLogRoot
        AgentLogRoot = $resolvedLogRoot
        ConfigPath = $ConfigPath
        ConfigBackupPath = $ConfigBackupPath
        CapturePath = $CapturePath
        CapturePort = $CapturePort
        AgentLogPath = $resolvedAgentLogPath
        PacketDumpPath = $PacketDumpPath
        ControlUrl = $controlUrl
        StatsUrl = $statsUrl
        ControlPort = $ControlPort
        KadPort = $KadPort
        Ed2kPort = $Ed2kPort
        BindIp = $resolvedBindIp
        P2pBindIp = $resolvedBindIp
        NetworkingBindIp = $resolvedBindIp
        RequestedInterfaceAlias = $RequestedInterfaceAlias
        InterfaceAlias = $InterfaceAlias
        InterfaceFallbackUsed = $InterfaceFallbackUsed
        NetworkingPath = $NetworkingPath
        KadBootstrapReadyContacts = $KadBootstrapReadyContacts
        KadDisabled = $KadDisabled
        ServerHost = if ([string]::IsNullOrWhiteSpace($ServerHost)) { $null } else { $ServerHost }
        ServerPort = if ($null -ne $ServerPort -and [UInt16]$ServerPort -gt 0) { [UInt16]$ServerPort } else { $null }
        ProbeSearchTerm = if ([string]::IsNullOrWhiteSpace($ProbeSearchTerm)) { $null } else { $ProbeSearchTerm }
        TransferRoot = $transferRoot
        TargetServer = $TargetServer
        DumpcapPid = if ($DumpcapPid -gt 0) { $DumpcapPid } else { $null }
        DumpcapStdoutPath = $DumpcapStdoutPath
        DumpcapStderrPath = $DumpcapStderrPath
        AgentPid = $AgentPid
        StartedAtUtc = $StartedAtUtc.ToUniversalTime().ToString("o")
    }
}

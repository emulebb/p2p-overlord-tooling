#Requires -Version 7.6
<#
.SYNOPSIS
Runs real-network Kad search and download parity passes for the eMule harness and the agent.

.DESCRIPTION
For each transport mode, this orchestration binds both runtimes to the VPN
adapter, enables UPnP, searches Kad for the same keyword, chooses one common
small result, and then drives both downloads so the resulting search and ED2K
transfer traces can be compared.
#>

[CmdletBinding()]
param(
    [string]$Query = "ebook",
    [ValidateSet("Debug", "Release")]
    [string]$EmuleHarnessBuildConfig = "Debug",
    [ValidateSet("All", "PlaintextOnly", "ObfuscatedOnly")]
    [string]$TransportModes = "All",
    [int]$SearchTimeoutSeconds = 240,
    [int]$DownloadTimeoutSeconds = 900,
    [int]$CandidateAttemptCount = 12,
    [int]$CandidateSourceProbeTimeoutSeconds = 60,
    [int]$AgentTransferProgressProbeTimeoutSeconds = 120,
    [int]$HarnessProgressProbeTimeoutSeconds = 90,
    [int]$SuccessfulDownloadCount = 2,
    [UInt64]$MaxCandidateSizeBytes = 16777216,
    [string]$InterfaceAlias = "hide.me",
    [string[]]$PreferredHashes = @(),
    [string[]]$PinnedCandidateHashes = @(),
    [string]$PinnedCandidatesPath,
    [switch]$KeepSessionsRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\subsystems\agent\AgentSubsystem.ps1")
. (Join-Path $PSScriptRoot "..\subsystems\ed2k\Ed2kSubsystem.ps1")
. (Join-Path $PSScriptRoot "..\subsystems\emule-harness\EmuleHarnessSubsystem.ps1")
. (Join-Path $PSScriptRoot "..\subsystems\kad\KadSubsystem.ps1")
. (Join-Path $PSScriptRoot "..\subsystems\network\NetworkSubsystem.ps1")

function Wait-AgentControlReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
            if ($null -ne $response) {
                return $response
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }

    throw "Agent stats endpoint did not become ready at $StatsUrl within $TimeoutSeconds seconds"
}

function Get-JsonObjectPropertyValue {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName,
        [Parameter(Mandatory = $false)]
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($PropertyName)) {
        return $Object[$PropertyName]
    }

    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -ne $property) {
        return $property.Value
    }

    return $DefaultValue
}

function Wait-TransferManifestState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ManifestPath) {
            $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
            if ([bool](Get-JsonObjectPropertyValue -Object $manifest -PropertyName "completed" -DefaultValue $false)) {
                return $manifest
            }
        }

        Start-Sleep -Seconds 2
    }

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Transfer manifest did not appear at $ManifestPath within $TimeoutSeconds seconds"
    }

    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    $verifiedRanges = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "verified_ranges" -DefaultValue @())
    $sources = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "sources" -DefaultValue @())
    throw "Transfer manifest at $ManifestPath did not complete within $TimeoutSeconds seconds (verified_ranges=$($verifiedRanges.Count) sources=$($sources.Count))"
}

function Wait-TransferManifestProbeState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,
        [int]$TimeoutSeconds = 45
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ManifestPath) {
            $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
            $manifestCompleted = [bool](Get-JsonObjectPropertyValue -Object $manifest -PropertyName "completed" -DefaultValue $false)
            $verifiedRanges = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "verified_ranges" -DefaultValue @())
            $sources = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "sources" -DefaultValue @())
            if ($manifestCompleted -or $verifiedRanges.Count -gt 0 -or $sources.Count -gt 0) {
                return $manifest
            }
        }

        Start-Sleep -Seconds 3
    }

    if (Test-Path -LiteralPath $ManifestPath) {
        return (Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json)
    }

    return $null
}

function Wait-TransferManifestProgressState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,
        [int]$TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastManifest = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ManifestPath) {
            $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
            $lastManifest = $manifest
            $manifestCompleted = [bool](Get-JsonObjectPropertyValue -Object $manifest -PropertyName "completed" -DefaultValue $false)
            $verifiedRanges = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "verified_ranges" -DefaultValue @())
            $pieces = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "pieces" -DefaultValue @())
            $bytesWritten = 0
            foreach ($piece in $pieces) {
                $pieceBytesWritten = Get-JsonObjectPropertyValue -Object $piece -PropertyName "bytes_written" -DefaultValue 0
                if ([int64]$pieceBytesWritten -gt $bytesWritten) {
                    $bytesWritten = [int64]$pieceBytesWritten
                }
            }

            if ($manifestCompleted) {
                return [pscustomobject]@{
                    State = "completed"
                    Manifest = $manifest
                    VerifiedRangeCount = $verifiedRanges.Count
                    BytesWritten = [UInt64][Math]::Max($bytesWritten, 0)
                }
            }

            if ($verifiedRanges.Count -gt 0 -or $bytesWritten -gt 0) {
                return [pscustomobject]@{
                    State = "progress"
                    Manifest = $manifest
                    VerifiedRangeCount = $verifiedRanges.Count
                    BytesWritten = [UInt64][Math]::Max($bytesWritten, 0)
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    if ($null -eq $lastManifest -and (Test-Path -LiteralPath $ManifestPath)) {
        $lastManifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    }

    $verifiedRanges = @()
    $bytesWritten = [UInt64]0
    if ($null -ne $lastManifest) {
        $verifiedRanges = @(Get-JsonObjectPropertyValue -Object $lastManifest -PropertyName "verified_ranges" -DefaultValue @())
        foreach ($piece in @(Get-JsonObjectPropertyValue -Object $lastManifest -PropertyName "pieces" -DefaultValue @())) {
            $pieceBytesWritten = [UInt64](Get-JsonObjectPropertyValue -Object $piece -PropertyName "bytes_written" -DefaultValue 0)
            if ($pieceBytesWritten -gt $bytesWritten) {
                $bytesWritten = $pieceBytesWritten
            }
        }
    }

    return [pscustomobject]@{
        State = "no-progress"
        Manifest = $lastManifest
        VerifiedRangeCount = $verifiedRanges.Count
        BytesWritten = $bytesWritten
    }
}

function Get-TransferManifestSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    $snapshot = [ordered]@{
        TsUtc = (Get-Date).ToUniversalTime().ToString("o")
        ManifestPath = $ManifestPath
        ManifestExists = $false
        Completed = $false
        SourceCount = 0
        VerifiedRangeCount = 0
        BytesWritten = [UInt64]0
        Manifest = $null
    }

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return [pscustomobject]$snapshot
    }

    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    $sources = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "sources" -DefaultValue @())
    $verifiedRanges = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "verified_ranges" -DefaultValue @())
    $pieces = @(Get-JsonObjectPropertyValue -Object $manifest -PropertyName "pieces" -DefaultValue @())
    $bytesWritten = [UInt64]0
    foreach ($piece in $pieces) {
        $pieceBytesWritten = [UInt64](Get-JsonObjectPropertyValue -Object $piece -PropertyName "bytes_written" -DefaultValue 0)
        if ($pieceBytesWritten -gt $bytesWritten) {
            $bytesWritten = $pieceBytesWritten
        }
    }

    $snapshot.ManifestExists = $true
    $snapshot.Completed = [bool](Get-JsonObjectPropertyValue -Object $manifest -PropertyName "completed" -DefaultValue $false)
    $snapshot.SourceCount = $sources.Count
    $snapshot.VerifiedRangeCount = $verifiedRanges.Count
    $snapshot.BytesWritten = $bytesWritten
    $snapshot.Manifest = $manifest

    return [pscustomobject]$snapshot
}

function Wait-TransferManifestProbeTimelineState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,
        [Parameter(Mandatory = $true)]
        [string]$TimelinePath,
        [int]$TimeoutSeconds = 45
    )

    Set-Content -LiteralPath $TimelinePath -Encoding utf8NoBOM -Value ""
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastSnapshot = $null

    while ((Get-Date) -lt $deadline) {
        $snapshot = Get-TransferManifestSnapshot -ManifestPath $ManifestPath
        $lastSnapshot = $snapshot
        Append-Utf8Line -Path $TimelinePath -Line ($snapshot | ConvertTo-Json -Depth 8 -Compress)

        if ($snapshot.ManifestExists -and ($snapshot.Completed -or $snapshot.VerifiedRangeCount -gt 0 -or $snapshot.SourceCount -gt 0)) {
            return [pscustomobject]@{
                State = "ready"
                TimelinePath = $TimelinePath
                FinalSnapshot = $snapshot
                Manifest = $snapshot.Manifest
            }
        }

        Start-Sleep -Seconds 3
    }

    if ($null -eq $lastSnapshot) {
        $lastSnapshot = Get-TransferManifestSnapshot -ManifestPath $ManifestPath
        Append-Utf8Line -Path $TimelinePath -Line ($lastSnapshot | ConvertTo-Json -Depth 8 -Compress)
    }

    return [pscustomobject]@{
        State = "timeout"
        TimelinePath = $TimelinePath
        FinalSnapshot = $lastSnapshot
        Manifest = if ($lastSnapshot.ManifestExists) { $lastSnapshot.Manifest } else { $null }
    }
}

function Wait-FileCompleted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [UInt64]$ExpectedSize,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-Item -LiteralPath $Path
            if ([UInt64]$item.Length -eq $ExpectedSize) {
                return $item
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "File $Path did not reach size $ExpectedSize within $TimeoutSeconds seconds"
}

function Get-HarnessTempPartPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot,
        [Parameter(Mandatory = $true)]
        [string]$FileHash
    )

    $downloadsPath = Join-Path $ProfileRoot "config\\downloads.txt"
    if (-not (Test-Path -LiteralPath $downloadsPath)) {
        return $null
    }

    $normalizedHash = $FileHash.ToUpperInvariant()
    foreach ($line in Get-Content -LiteralPath $downloadsPath) {
        if ($line -notmatch [regex]::Escape($normalizedHash)) {
            continue
        }

        $columns = $line -split "`t", 2
        if ($columns.Count -lt 1 -or [string]::IsNullOrWhiteSpace($columns[0])) {
            continue
        }

        return (Join-Path $ProfileRoot ("Temp\\{0}" -f $columns[0].Trim()))
    }

    return $null
}

function Wait-HarnessDownloadCompleted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot,
        [Parameter(Mandatory = $true)]
        [string]$FileHash,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedName,
        [Parameter(Mandatory = $true)]
        [UInt64]$ExpectedSize,
        [int]$TimeoutSeconds = 300
    )

    $incomingPath = Join-Path $ProfileRoot ("Incoming\\{0}" -f $ExpectedName)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $incomingPath) {
            $incomingItem = Get-Item -LiteralPath $incomingPath
            if ([UInt64]$incomingItem.Length -eq $ExpectedSize) {
                return [pscustomobject]@{
                    Path = $incomingItem.FullName
                    Length = [UInt64]$incomingItem.Length
                    CompletionKind = "incoming"
                }
            }
        }

        $tempPartPath = Get-HarnessTempPartPath -ProfileRoot $ProfileRoot -FileHash $FileHash
        if ($tempPartPath -and (Test-Path -LiteralPath $tempPartPath)) {
            $tempItem = Get-Item -LiteralPath $tempPartPath
            if ([UInt64]$tempItem.Length -eq $ExpectedSize) {
                return [pscustomobject]@{
                    Path = $tempItem.FullName
                    Length = [UInt64]$tempItem.Length
                    CompletionKind = "temp-part"
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "Harness download for $FileHash did not reach size $ExpectedSize in Incoming or Temp within $TimeoutSeconds seconds"
}

function Wait-HarnessDownloadProbeState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot,
        [Parameter(Mandatory = $true)]
        [string]$FileHash,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedName,
        [Parameter(Mandatory = $true)]
        [UInt64]$ExpectedSize,
        [int]$TimeoutSeconds = 90
    )

    $incomingPath = Join-Path $ProfileRoot ("Incoming\\{0}" -f $ExpectedName)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastObservedPath = $null
    $lastObservedLength = [UInt64]0
    $lastObservedKind = $null

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $incomingPath) {
            $incomingItem = Get-Item -LiteralPath $incomingPath
            $lastObservedPath = $incomingItem.FullName
            $lastObservedLength = [UInt64]$incomingItem.Length
            $lastObservedKind = "incoming"
            if ($lastObservedLength -eq $ExpectedSize) {
                return [pscustomobject]@{
                    State = "completed"
                    Path = $incomingItem.FullName
                    Length = [UInt64]$incomingItem.Length
                    CompletionKind = "incoming"
                }
            }
            if ($lastObservedLength -gt 0) {
                return [pscustomobject]@{
                    State = "progress"
                    Path = $incomingItem.FullName
                    Length = [UInt64]$incomingItem.Length
                    CompletionKind = "incoming"
                }
            }
        }

        $tempPartPath = Get-HarnessTempPartPath -ProfileRoot $ProfileRoot -FileHash $FileHash
        if ($tempPartPath -and (Test-Path -LiteralPath $tempPartPath)) {
            $tempItem = Get-Item -LiteralPath $tempPartPath
            $lastObservedPath = $tempItem.FullName
            $lastObservedLength = [UInt64]$tempItem.Length
            $lastObservedKind = "temp-part"
            if ($lastObservedLength -eq $ExpectedSize) {
                return [pscustomobject]@{
                    State = "completed"
                    Path = $tempItem.FullName
                    Length = [UInt64]$tempItem.Length
                    CompletionKind = "temp-part"
                }
            }
            if ($lastObservedLength -gt 0) {
                return [pscustomobject]@{
                    State = "progress"
                    Path = $tempItem.FullName
                    Length = [UInt64]$tempItem.Length
                    CompletionKind = "temp-part"
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    return [pscustomobject]@{
        State = "no-progress"
        Path = $lastObservedPath
        Length = $lastObservedLength
        CompletionKind = $lastObservedKind
    }
}

function Write-ScenarioTraceLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Add-Content -LiteralPath $Path -Encoding utf8NoBOM -Value ("{0}`t{1}" -f ((Get-Date).ToUniversalTime().ToString("o")), $Message)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [object]$InputObject,
        [int]$Depth = 10
    )

    if ($null -eq $InputObject) {
        Set-Content -LiteralPath $Path -Encoding utf8NoBOM -Value "null"
        return
    }

    $InputObject | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Append-Utf8Line {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $lineBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Line + "`n")
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        $stream.Write($lineBytes, 0, $lineBytes.Length)
    }
    finally {
        $stream.Dispose()
    }
}

function Add-UniqueNormalizedHash {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Target,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$Seen,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return
    }

    $normalizedHash = ([string]$Value).Trim().ToLowerInvariant()
    if ($Seen.Add($normalizedHash)) {
        $Target.Add($normalizedHash) | Out-Null
    }
}

function Resolve-PinnedCandidateHashes {
    param(
        [string[]]$PinnedCandidateHashes = @(),
        [string]$PinnedCandidatesPath
    )

    $resolvedHashes = [System.Collections.Generic.List[string]]::new()
    $seenHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $appendHashes = {
        param(
            [object]$InputValue
        )

        if ($null -eq $InputValue) {
            return
        }

        if ($InputValue -is [string]) {
            Add-UniqueNormalizedHash -Target $resolvedHashes -Seen $seenHashes -Value ([string]$InputValue)
            return
        }

        foreach ($item in @($InputValue)) {
            if ($item -is [string]) {
                Add-UniqueNormalizedHash -Target $resolvedHashes -Seen $seenHashes -Value ([string]$item)
                continue
            }

            $hashValue = Get-JsonObjectPropertyValue -Object $item -PropertyName "Hash" -DefaultValue $null
            if ([string]::IsNullOrWhiteSpace([string]$hashValue)) {
                $hashValue = Get-JsonObjectPropertyValue -Object $item -PropertyName "hash" -DefaultValue $null
            }
            Add-UniqueNormalizedHash -Target $resolvedHashes -Seen $seenHashes -Value ([string]$hashValue)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PinnedCandidatesPath)) {
        if (-not (Test-Path -LiteralPath $PinnedCandidatesPath)) {
            throw "Pinned candidates path not found at $PinnedCandidatesPath"
        }

        $resolvedPinnedPath = (Resolve-Path -LiteralPath $PinnedCandidatesPath).ProviderPath
        $parsedPins = Get-Content -Raw -LiteralPath $resolvedPinnedPath | ConvertFrom-Json
        $pathHandled = $false

        foreach ($propertyName in @("CandidateHashes", "Hashes", "PinnedCandidateHashes", "Candidates", "PreferredHashes")) {
            $propertyValue = Get-JsonObjectPropertyValue -Object $parsedPins -PropertyName $propertyName -DefaultValue $null
            if ($null -ne $propertyValue) {
                & $appendHashes $propertyValue
                $pathHandled = $true
            }
        }

        if (-not $pathHandled) {
            & $appendHashes $parsedPins
        }
    }

    & $appendHashes $PinnedCandidateHashes

    return @($resolvedHashes)
}

function Resolve-CandidateName {
    param(
        [Parameter(Mandatory = $false)]
        [object]$HarnessRecord,
        [Parameter(Mandatory = $false)]
        [object]$AgentRecord
    )

    if ($null -eq $HarnessRecord -and $null -eq $AgentRecord) {
        return $null
    }

    $harnessName = if ($null -ne $HarnessRecord) { [string](Get-JsonObjectPropertyValue -Object $HarnessRecord -PropertyName "name" -DefaultValue $null) } else { $null }
    if ($null -ne $AgentRecord) {
        foreach ($agentName in @((Get-JsonObjectPropertyValue -Object $AgentRecord -PropertyName "Names" -DefaultValue @()))) {
            if ($agentName -eq $harnessName -and -not [string]::IsNullOrWhiteSpace([string]$agentName)) {
                return [string]$agentName
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($harnessName)) {
        return $harnessName
    }

    if ($null -ne $AgentRecord) {
        foreach ($agentName in @((Get-JsonObjectPropertyValue -Object $AgentRecord -PropertyName "Names" -DefaultValue @()))) {
            if (-not [string]::IsNullOrWhiteSpace([string]$agentName)) {
                return [string]$agentName
            }
        }
    }

    return $null
}

function New-CandidateRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hash,
        [Parameter(Mandatory = $false)]
        [object]$HarnessRecord,
        [Parameter(Mandatory = $false)]
        [object]$AgentRecord,
        [Parameter(Mandatory = $true)]
        [UInt64]$MaxSizeBytes,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$PreferredHashSet,
        [Parameter(Mandatory = $true)]
        [string]$SelectionKind,
        [int]$SelectionOrder = 0
    )

    $normalizedHash = ([string]$Hash).Trim().ToLowerInvariant()
    $resolvedName = Resolve-CandidateName -HarnessRecord $HarnessRecord -AgentRecord $AgentRecord

    $resolvedSize = [UInt64]0
    if ($null -ne $HarnessRecord -and $null -ne (Get-JsonObjectPropertyValue -Object $HarnessRecord -PropertyName "size" -DefaultValue $null)) {
        $resolvedSize = [UInt64](Get-JsonObjectPropertyValue -Object $HarnessRecord -PropertyName "size" -DefaultValue 0)
    }
    elseif ($null -ne $AgentRecord -and $null -ne (Get-JsonObjectPropertyValue -Object $AgentRecord -PropertyName "Size" -DefaultValue $null)) {
        $resolvedSize = [UInt64](Get-JsonObjectPropertyValue -Object $AgentRecord -PropertyName "Size" -DefaultValue 0)
    }

    $missingReason = $null
    if ($null -eq $HarnessRecord -or $null -eq $AgentRecord) {
        $missingReason = "candidate-missing"
    }
    elseif ($resolvedSize -eq 0) {
        $missingReason = "zero-size"
    }
    elseif ($resolvedSize -gt $MaxSizeBytes) {
        $missingReason = "size-exceeded"
    }
    elseif ([string]::IsNullOrWhiteSpace($resolvedName)) {
        $missingReason = "missing-name"
    }

    [pscustomobject]@{
        Hash = $normalizedHash
        Name = $resolvedName
        Size = $resolvedSize
        HarnessSourceCount = if ($null -ne $HarnessRecord) { [int](Get-JsonObjectPropertyValue -Object $HarnessRecord -PropertyName "source_count" -DefaultValue 0) } else { 0 }
        HarnessCompleteSourceCount = if ($null -ne $HarnessRecord) { [int](Get-JsonObjectPropertyValue -Object $HarnessRecord -PropertyName "complete_source_count" -DefaultValue 0) } else { 0 }
        AgentSourceCount = if ($null -ne $AgentRecord) { [int](Get-JsonObjectPropertyValue -Object $AgentRecord -PropertyName "SourceCount" -DefaultValue 0) } else { 0 }
        AgentBatchHits = if ($null -ne $AgentRecord) { [int](Get-JsonObjectPropertyValue -Object $AgentRecord -PropertyName "BatchHits" -DefaultValue 0) } else { 0 }
        ExtensionRank = Get-PreferredExtensionRank -Name $resolvedName
        PreferredHashRank = if ($PreferredHashSet.Contains($normalizedHash)) { 1 } else { 0 }
        IsCommonCandidate = [string]::IsNullOrWhiteSpace($missingReason)
        MissingReason = $missingReason
        SelectionKind = $SelectionKind
        SelectionOrder = $SelectionOrder
        HarnessSearchRecord = $HarnessRecord
        AgentSearchRecord = $AgentRecord
    }
}

function Get-CandidateOutcome {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Attempt
    )

    if (-not [bool](Get-JsonObjectPropertyValue -Object $Attempt -PropertyName "IsCommonCandidate" -DefaultValue $false)) {
        return "candidate_missing"
    }

    if ([bool](Get-JsonObjectPropertyValue -Object $Attempt -PropertyName "DownloadSucceeded" -DefaultValue $false)) {
        return "completed"
    }

    $sourceSearchCompletionState = [string](Get-JsonObjectPropertyValue -Object $Attempt -PropertyName "SourceSearchCompletionState" -DefaultValue $null)
    $sourceAcquisitionState = [string](Get-JsonObjectPropertyValue -Object $Attempt -PropertyName "SourceAcquisitionState" -DefaultValue $null)
    $harnessProbeState = [string](Get-JsonObjectPropertyValue -Object $Attempt -PropertyName "HarnessProbeState" -DefaultValue $null)
    $agentProgressState = [string](Get-JsonObjectPropertyValue -Object $Attempt -PropertyName "AgentProgressState" -DefaultValue $null)
    $probeSources = [int](Get-JsonObjectPropertyValue -Object $Attempt -PropertyName "ProbeSources" -DefaultValue 0)
    $probeCompleted = [bool](Get-JsonObjectPropertyValue -Object $Attempt -PropertyName "ProbeCompleted" -DefaultValue $false)
    $probeVerifiedRanges = [int](Get-JsonObjectPropertyValue -Object $Attempt -PropertyName "ProbeVerifiedRanges" -DefaultValue 0)

    if (($agentProgressState -eq "progress" -or $agentProgressState -eq "completed") -and $harnessProbeState -eq "no-progress") {
        return "agent_progress_no_harness_progress"
    }

    if ($harnessProbeState -eq "progress" -or $harnessProbeState -eq "completed") {
        return "harness_transfer_started"
    }

    if ($agentProgressState -eq "no-progress") {
        return "agent_no_transfer_progress"
    }

    if ($sourceSearchCompletionState -in @(
            "agent_candidate_selected",
            "agent_source_search_started",
            "agent_source_search_returned_zero",
            "agent_sources_filtered",
            "agent_sources_merged_to_manifest"
        )) {
        return $sourceSearchCompletionState
    }

    if ($sourceAcquisitionState -in @("agent_candidate_selected", "agent_source_search_started", "agent_no_probe_sources", "agent_probe_sources_present")) {
        return $sourceAcquisitionState
    }

    if ($probeSources -le 0 -and -not $probeCompleted -and $probeVerifiedRanges -le 0) {
        return "agent_no_probe_sources"
    }

    return "candidate_missing"
}

function Save-CandidateSearchEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Candidate,
        [Parameter(Mandatory = $true)]
        [string]$EvidenceRoot
    )

    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null

    $searchEvidence = [ordered]@{
        hash = $Candidate.Hash
        name = $Candidate.Name
        size = [UInt64]$Candidate.Size
        selectionKind = $Candidate.SelectionKind
        selectionOrder = [int]$Candidate.SelectionOrder
        isCommonCandidate = [bool]$Candidate.IsCommonCandidate
        missingReason = $Candidate.MissingReason
        harnessSourceCount = [int]$Candidate.HarnessSourceCount
        harnessCompleteSourceCount = [int]$Candidate.HarnessCompleteSourceCount
        agentSourceCount = [int]$Candidate.AgentSourceCount
        agentBatchHits = [int]$Candidate.AgentBatchHits
        harnessSearchRecord = $Candidate.HarnessSearchRecord
        agentSearchRecord = $Candidate.AgentSearchRecord
    }

    Write-JsonFile -Path (Join-Path $EvidenceRoot "candidate-search-evidence.json") -InputObject $searchEvidence -Depth 10
    Write-JsonFile -Path (Join-Path $EvidenceRoot "harness-search-record.json") -InputObject $Candidate.HarnessSearchRecord -Depth 10
    Write-JsonFile -Path (Join-Path $EvidenceRoot "agent-search-record.json") -InputObject $Candidate.AgentSearchRecord -Depth 10
}

function Save-CandidateRuntimeEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot,
        [Parameter(Mandatory = $true)]
        [string]$FileHash,
        [Parameter(Mandatory = $true)]
        [string]$EvidenceRoot,
        [Parameter(Mandatory = $true)]
        [string]$Phase,
        [string]$ProbeManifestPath
    )

    $phaseRoot = Join-Path $EvidenceRoot $Phase
    New-Item -ItemType Directory -Path $phaseRoot -Force | Out-Null

    $downloadsPath = Join-Path $ProfileRoot "config\downloads.txt"
    if (Test-Path -LiteralPath $downloadsPath) {
        Copy-Item -LiteralPath $downloadsPath -Destination (Join-Path $phaseRoot "downloads.txt") -Force
    }

    if ($ProbeManifestPath -and (Test-Path -LiteralPath $ProbeManifestPath)) {
        Copy-Item -LiteralPath $ProbeManifestPath -Destination (Join-Path $phaseRoot "resume-manifest.json") -Force
    }

    $tempPartPath = Get-HarnessTempPartPath -ProfileRoot $ProfileRoot -FileHash $FileHash
    $tempPartMetPath = $null
    $tempPartBakPath = $null
    $tempPartExists = $false
    $tempPartLength = [UInt64]0
    if ($tempPartPath) {
        $tempPartMetPath = "$tempPartPath.met"
        $tempPartBakPath = "$tempPartPath.met.bak"
        if (Test-Path -LiteralPath $tempPartPath) {
            $tempPartExists = $true
            $tempPartLength = [UInt64](Get-Item -LiteralPath $tempPartPath).Length
        }
        if (Test-Path -LiteralPath $tempPartMetPath) {
            Copy-Item -LiteralPath $tempPartMetPath -Destination (Join-Path $phaseRoot (Split-Path -Leaf $tempPartMetPath)) -Force
        }
        if (Test-Path -LiteralPath $tempPartBakPath) {
            Copy-Item -LiteralPath $tempPartBakPath -Destination (Join-Path $phaseRoot (Split-Path -Leaf $tempPartBakPath)) -Force
        }
    }

    $partState = [ordered]@{
        phase = $Phase
        capturedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        tempPartPath = $tempPartPath
        tempPartExists = $tempPartExists
        tempPartSize = $tempPartLength
        tempPartMetPath = $tempPartMetPath
        tempPartMetExists = if ($tempPartMetPath) { Test-Path -LiteralPath $tempPartMetPath } else { $false }
        tempPartMetBakPath = $tempPartBakPath
        tempPartMetBakExists = if ($tempPartBakPath) { Test-Path -LiteralPath $tempPartBakPath } else { $false }
    }
    Write-JsonFile -Path (Join-Path $phaseRoot "harness-part-state.json") -InputObject $partState -Depth 6
}

function Export-Ed2kTraceWindow {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [datetime]$StartUtc,
        [datetime]$EndUtc,
        [int]$PaddingSeconds = 5
    )

    if (-not $SourcePath -or -not (Test-Path -LiteralPath $SourcePath)) {
        return $false
    }

    $windowStart = $StartUtc.AddSeconds(-1 * $PaddingSeconds)
    $windowEnd = $EndUtc.AddSeconds($PaddingSeconds)
    $dateStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $selectedLines = [System.Collections.Generic.List[string]]::new()

    foreach ($line in Get-Content -LiteralPath $SourcePath) {
        if ($line -notmatch '"ts_utc":"([^"]+)"') {
            continue
        }

        try {
            $lineTimestamp = [datetime]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture, $dateStyles)
        }
        catch {
            continue
        }

        if ($lineTimestamp -ge $windowStart -and $lineTimestamp -le $windowEnd) {
            $selectedLines.Add($line) | Out-Null
        }
    }

    if ($selectedLines.Count -gt 0) {
        Set-Content -LiteralPath $DestinationPath -Encoding utf8NoBOM -Value $selectedLines
        return $true
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    return $false
}

function Resolve-AgentEd2kTracePath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$AgentSession
    )

    $existingPath = [string](Get-JsonObjectPropertyValue -Object $AgentSession -PropertyName "Ed2kTcpDumpPath" -DefaultValue $null)
    if (-not [string]::IsNullOrWhiteSpace($existingPath) -and (Test-Path -LiteralPath $existingPath)) {
        return $existingPath
    }

    $logRoot = [string](Get-JsonObjectPropertyValue -Object $AgentSession -PropertyName "LogRoot" -DefaultValue $null)
    if ([string]::IsNullOrWhiteSpace($logRoot) -or -not (Test-Path -LiteralPath $logRoot)) {
        return $null
    }

    $startedAtUtcValue = Get-JsonObjectPropertyValue -Object $AgentSession -PropertyName "StartedAtUtc" -DefaultValue $null
    $startedAtUtc = $null
    if ($startedAtUtcValue) {
        try {
            $startedAtUtc = [datetime]::Parse(
                [string]$startedAtUtcValue,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            )
        }
        catch {
            $startedAtUtc = $null
        }
    }

    return Get-ChildItem -LiteralPath $logRoot -Filter "agent-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
        Where-Object {
            if ($null -eq $startedAtUtc) {
                return $true
            }
            $_.LastWriteTimeUtc -ge $startedAtUtc.AddSeconds(-5)
        } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Get-Ed2kStartupStageCatalog {
    return @(
        "connect_start",
        "connect_ready",
        "hello_sent",
        "hello_received",
        "hello_answer_received",
        "secure_ident_started",
        "secure_ident_state_received",
        "secure_ident_key_exchange",
        "startup_file_request_sent",
        "startup_file_response_received",
        "source_request_sent",
        "source_answer_received",
        "aich_request_sent",
        "aich_answer_received",
        "hashset_request_sent",
        "hashset_answer_received",
        "upload_request_sent",
        "queue_ranking",
        "upload_accepted",
        "part_request_sent",
        "part_data_received",
        "piece_stored",
        "completed"
    )
}

function Get-Ed2kStartupStageIndexMap {
    $indexMap = @{}
    $index = 0
    foreach ($stage in Get-Ed2kStartupStageCatalog) {
        $indexMap[$stage] = $index
        $index += 1
    }
    return $indexMap
}

function Test-IsEd2kDownloadTraceRecord {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record
    )

    $flow = [string](Get-JsonObjectPropertyValue -Object $Record -PropertyName "flow" -DefaultValue "")
    $stateId = [string](Get-JsonObjectPropertyValue -Object $Record -PropertyName "state_id" -DefaultValue "")

    if ($flow -match "download" -or $stateId -match "download") {
        return $true
    }

    return $false
}

function Get-Ed2kStartupStageEvent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record
    )

    if (-not (Test-IsEd2kDownloadTraceRecord -Record $Record)) {
        return $null
    }

    $phase = [string](Get-JsonObjectPropertyValue -Object $Record -PropertyName "phase" -DefaultValue "")
    $direction = [string](Get-JsonObjectPropertyValue -Object $Record -PropertyName "direction" -DefaultValue "")
    $opcodeName = [string](Get-JsonObjectPropertyValue -Object $Record -PropertyName "opcode_name" -DefaultValue "")
    $tsUtc = Convert-ToUtcTimestampString -Value (Get-JsonObjectPropertyValue -Object $Record -PropertyName "ts_utc" -DefaultValue $null)
    $stage = $null
    $terminalState = $null

    switch ($phase) {
        "connect_start" { $stage = "connect_start" }
        "connect_ready" { $stage = "connect_ready" }
        "hello" { if ($direction -eq "send") { $stage = "hello_sent" } }
        "secure_ident_probe" { $stage = "secure_ident_started" }
        "request_filename" { $stage = "startup_file_request_sent" }
        "set_req_file_id" { $stage = "startup_file_request_sent" }
        "request_sources2" { $stage = "source_request_sent" }
        "aich_file_hash_request" { $stage = "aich_request_sent" }
        "hashset_request" { $stage = "hashset_request_sent" }
        "upload_request_hashset_fallback" { $stage = "upload_request_sent" }
        "start_upload" { if ($direction -eq "send") { $stage = "upload_request_sent" } }
        "queue_ranking" { $stage = "queue_ranking" }
        "request_parts" { if ($direction -eq "send") { $stage = "part_request_sent" } }
        "piece_fragment_stored" { $stage = "piece_stored" }
        "compressed_piece_fragment_stored" { $stage = "piece_stored" }
        "complete" {
            $stage = "completed"
            $terminalState = "completed"
        }
        "accepted_incomplete" { $terminalState = "accepted_incomplete" }
        "peer_closed_incomplete" { $terminalState = "peer_closed_incomplete" }
        "peer_shutdown_incomplete" { $terminalState = "peer_shutdown_incomplete" }
        "peer_timeout_incomplete" { $terminalState = "peer_timeout_incomplete" }
        "error" { $terminalState = "error" }
    }

    if (-not $stage) {
        switch ($opcodeName) {
            "OP_HELLO" { if ($direction -eq "recv") { $stage = "hello_received" } }
            "OP_HELLOANSWER" { if ($direction -eq "recv") { $stage = "hello_answer_received" } }
            "OP_SECIDENTSTATE" { if ($direction -eq "recv") { $stage = "secure_ident_state_received" } }
            "OP_PUBLICKEY" { $stage = "secure_ident_key_exchange" }
            "OP_SIGNATURE" { $stage = "secure_ident_key_exchange" }
            "OP_REQFILENAMEANSWER" { $stage = "startup_file_response_received" }
            "OP_FILESTATUS" { $stage = "startup_file_response_received" }
            "OP_ANSWERSOURCES" { $stage = "source_answer_received" }
            "OP_ANSWERSOURCES2" { $stage = "source_answer_received" }
            "OP_AICHFILEHASHANS" { $stage = "aich_answer_received" }
            "OP_HASHSETANSWER" { $stage = "hashset_answer_received" }
            "OP_ACCEPTUPLOADREQ" { $stage = "upload_accepted" }
            "OP_QUEUERANKING" { $stage = "queue_ranking" }
            "OP_SENDINGPART" { $stage = "part_data_received" }
            "OP_SENDINGPART_I64" { $stage = "part_data_received" }
            "OP_COMPRESSEDPART" { $stage = "part_data_received" }
            "OP_COMPRESSEDPART_I64" { $stage = "part_data_received" }
        }
    }

    if (-not $stage -and -not $terminalState) {
        return $null
    }

    return [pscustomobject]@{
        TsUtc = $tsUtc
        Stage = $stage
        TerminalState = $terminalState
        Phase = $phase
        Direction = $direction
        OpcodeName = $opcodeName
        TraceKey = [string](Get-JsonObjectPropertyValue -Object $Record -PropertyName "trace_key" -DefaultValue "")
        RemoteAddr = [string](Get-JsonObjectPropertyValue -Object $Record -PropertyName "remote_addr" -DefaultValue "")
        TransportMode = [string](Get-JsonObjectPropertyValue -Object $Record -PropertyName "transport_mode" -DefaultValue "")
        Note = [string](Get-JsonObjectPropertyValue -Object $Record -PropertyName "note" -DefaultValue "")
    }
}

function Get-Ed2kStartupPhaseSummary {
    param(
        [string]$WindowPath,
        [string]$SourceName
    )

    $stageIndexMap = Get-Ed2kStartupStageIndexMap
    $stageEvents = [System.Collections.Generic.List[object]]::new()
    $observedStages = [System.Collections.Generic.List[string]]::new()
    $seenStages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $traceKeys = [System.Collections.Generic.List[string]]::new()
    $seenTraceKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $observedDownloadTrace = $false
    $maxStageIndex = -1
    $finalStage = $null
    $terminalState = $null

    if ($WindowPath -and (Test-Path -LiteralPath $WindowPath)) {
        foreach ($line in Get-Content -LiteralPath $WindowPath) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $record = $line | ConvertFrom-Json
            }
            catch {
                continue
            }

            if (-not (Test-IsEd2kDownloadTraceRecord -Record $record)) {
                continue
            }

            $observedDownloadTrace = $true
            $traceKey = [string](Get-JsonObjectPropertyValue -Object $record -PropertyName "trace_key" -DefaultValue "")
            if (-not [string]::IsNullOrWhiteSpace($traceKey) -and $seenTraceKeys.Add($traceKey)) {
                $traceKeys.Add($traceKey) | Out-Null
            }

            $event = Get-Ed2kStartupStageEvent -Record $record
            if ($null -eq $event) {
                continue
            }

            $stageEvents.Add($event) | Out-Null

            if (-not [string]::IsNullOrWhiteSpace($event.Stage)) {
                if ($seenStages.Add($event.Stage)) {
                    $observedStages.Add($event.Stage) | Out-Null
                }
                if ($stageIndexMap.ContainsKey($event.Stage)) {
                    $currentIndex = [int]$stageIndexMap[$event.Stage]
                    if ($currentIndex -ge $maxStageIndex) {
                        $maxStageIndex = $currentIndex
                        $finalStage = $event.Stage
                    }
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($event.TerminalState)) {
                $terminalState = $event.TerminalState
            }
        }
    }

    return [pscustomobject]@{
        Source = $SourceName
        WindowPath = $WindowPath
        WindowExists = [bool]($WindowPath -and (Test-Path -LiteralPath $WindowPath))
        ObservedDownloadTrace = $observedDownloadTrace
        ObservedStages = @($observedStages)
        FinalStage = $finalStage
        TerminalState = $terminalState
        MaxStageIndex = $maxStageIndex
        TraceKeys = @($traceKeys)
        StageEventCount = $stageEvents.Count
        StageEvents = @($stageEvents)
    }
}

function Compare-Ed2kStartupPhaseSummaries {
    param(
        [Parameter(Mandatory = $true)]
        [object]$AgentSummary,
        [Parameter(Mandatory = $true)]
        [object]$HarnessSummary
    )

    $stageCatalog = @(Get-Ed2kStartupStageCatalog)
    $firstDivergentStage = $null
    foreach ($stage in $stageCatalog) {
        $agentObserved = @($AgentSummary.ObservedStages) -contains $stage
        $harnessObserved = @($HarnessSummary.ObservedStages) -contains $stage
        if ($agentObserved -ne $harnessObserved) {
            $firstDivergentStage = $stage
            break
        }
    }

    $parityState = if (-not $AgentSummary.ObservedDownloadTrace -and -not $HarnessSummary.ObservedDownloadTrace) {
        "no_download_trace"
    }
    elseif ($firstDivergentStage) {
        if ((@($HarnessSummary.ObservedStages) -contains $firstDivergentStage) -and -not (@($AgentSummary.ObservedStages) -contains $firstDivergentStage)) {
            "agent_missing_stage"
        }
        elseif ((@($AgentSummary.ObservedStages) -contains $firstDivergentStage) -and -not (@($HarnessSummary.ObservedStages) -contains $firstDivergentStage)) {
            "harness_missing_stage"
        }
        else {
            "stage_divergence"
        }
    }
    elseif ($AgentSummary.FinalStage -eq $HarnessSummary.FinalStage -and $AgentSummary.TerminalState -eq $HarnessSummary.TerminalState) {
        "phase_aligned"
    }
    else {
        "terminal_divergence"
    }

    return [pscustomobject]@{
        AgentObservedDownloadTrace = [bool]$AgentSummary.ObservedDownloadTrace
        HarnessObservedDownloadTrace = [bool]$HarnessSummary.ObservedDownloadTrace
        AgentFinalStage = $AgentSummary.FinalStage
        HarnessFinalStage = $HarnessSummary.FinalStage
        AgentTerminalState = $AgentSummary.TerminalState
        HarnessTerminalState = $HarnessSummary.TerminalState
        AgentStageCount = @($AgentSummary.ObservedStages).Count
        HarnessStageCount = @($HarnessSummary.ObservedStages).Count
        FirstDivergentStage = $firstDivergentStage
        ParityState = $parityState
        AgentObservedStages = @($AgentSummary.ObservedStages)
        HarnessObservedStages = @($HarnessSummary.ObservedStages)
    }
}

function Parse-TextLogTimestampUtc {
    param(
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line) -or $Line -notmatch '^(?<Timestamp>\S+)') {
        return $null
    }

    $dateStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    try {
        return [datetime]::Parse($Matches.Timestamp, [System.Globalization.CultureInfo]::InvariantCulture, $dateStyles)
    }
    catch {
        return $null
    }
}

function Convert-ToUtcTimestampString {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString("o")
    }

    $stringValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($stringValue)) {
        return $null
    }

    $dateStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    try {
        return ([datetime]::Parse($stringValue, [System.Globalization.CultureInfo]::InvariantCulture, $dateStyles)).ToUniversalTime().ToString("o")
    }
    catch {
        return $stringValue
    }
}

function Get-UtcTimestampSortKey {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Value
    )

    $normalizedValue = Convert-ToUtcTimestampString -Value $Value
    if ([string]::IsNullOrWhiteSpace($normalizedValue)) {
        return [datetime]::MaxValue
    }

    $dateStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    try {
        return [datetime]::Parse($normalizedValue, [System.Globalization.CultureInfo]::InvariantCulture, $dateStyles)
    }
    catch {
        return [datetime]::MaxValue
    }
}

function Get-NamedRegexIntValue {
    param(
        [string]$Line,
        [string]$Pattern,
        [string]$Name = "Count"
    )

    if ([string]::IsNullOrWhiteSpace($Line) -or [string]::IsNullOrWhiteSpace($Pattern)) {
        return $null
    }

    if ($Line -match $Pattern) {
        return [int]$Matches[$Name]
    }

    return $null
}

function Get-ManifestProbeTimelineSummary {
    param(
        [string]$TimelinePath
    )

    $events = [System.Collections.Generic.List[object]]::new()
    $maxSourceCount = 0
    $maxVerifiedRangeCount = 0
    $maxBytesWritten = [UInt64]0
    $firstManifestSourceAtUtc = $null
    $finalSnapshot = $null

    if ($TimelinePath -and (Test-Path -LiteralPath $TimelinePath)) {
        foreach ($line in Get-Content -LiteralPath $TimelinePath) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $snapshot = $line | ConvertFrom-Json
            }
            catch {
                continue
            }

            $finalSnapshot = $snapshot
            $tsUtc = Convert-ToUtcTimestampString -Value (Get-JsonObjectPropertyValue -Object $snapshot -PropertyName "TsUtc" -DefaultValue $null)
            $completed = [bool](Get-JsonObjectPropertyValue -Object $snapshot -PropertyName "Completed" -DefaultValue $false)
            $sourceCount = [int](Get-JsonObjectPropertyValue -Object $snapshot -PropertyName "SourceCount" -DefaultValue 0)
            $verifiedRangeCount = [int](Get-JsonObjectPropertyValue -Object $snapshot -PropertyName "VerifiedRangeCount" -DefaultValue 0)
            $bytesWritten = [UInt64](Get-JsonObjectPropertyValue -Object $snapshot -PropertyName "BytesWritten" -DefaultValue 0)

            if ($sourceCount -gt $maxSourceCount) {
                $maxSourceCount = $sourceCount
                if ([string]::IsNullOrWhiteSpace($firstManifestSourceAtUtc)) {
                    $firstManifestSourceAtUtc = $tsUtc
                }
            }
            if ($verifiedRangeCount -gt $maxVerifiedRangeCount) {
                $maxVerifiedRangeCount = $verifiedRangeCount
            }
            if ($bytesWritten -gt $maxBytesWritten) {
                $maxBytesWritten = $bytesWritten
            }

            $events.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "manifest_probe"
                    Stage = if ($completed) {
                        "manifest_completed"
                    }
                    elseif ($sourceCount -gt 0) {
                        "manifest_sources_present"
                    }
                    elseif ($verifiedRangeCount -gt 0 -or $bytesWritten -gt 0) {
                        "manifest_progress_present"
                    }
                    else {
                        "manifest_probe"
                    }
                    SourceCount = $sourceCount
                    VerifiedRangeCount = $verifiedRangeCount
                    BytesWritten = $bytesWritten
                    Completed = $completed
                }) | Out-Null
        }
    }

    return [pscustomobject]@{
        MaxSourceCount = $maxSourceCount
        MaxVerifiedRangeCount = $maxVerifiedRangeCount
        MaxBytesWritten = $maxBytesWritten
        FirstManifestSourceAtUtc = $firstManifestSourceAtUtc
        FinalSnapshot = $finalSnapshot
        Events = @($events)
    }
}

function Write-SourceTransitionTimeline {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceAcquisitionSummary,
        [string]$ManifestTimelinePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $manifestSummary = Get-ManifestProbeTimelineSummary -TimelinePath $ManifestTimelinePath
    $combinedEvents = [System.Collections.Generic.List[object]]::new()

    foreach ($event in @(Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "TransitionEvents" -DefaultValue @())) {
        if ($null -ne $event) {
            $combinedEvents.Add($event) | Out-Null
        }
    }
    foreach ($event in @($manifestSummary.Events)) {
        if ($null -ne $event) {
            $combinedEvents.Add($event) | Out-Null
        }
    }

    $sortedEvents = @(
        $combinedEvents |
            Sort-Object `
                @{ Expression = { Get-UtcTimestampSortKey -Value (Get-JsonObjectPropertyValue -Object $_ -PropertyName "TsUtc" -DefaultValue $null) } }, `
                @{ Expression = { [string](Get-JsonObjectPropertyValue -Object $_ -PropertyName "Stage" -DefaultValue "") } }
    )

    Set-Content -LiteralPath $DestinationPath -Encoding utf8NoBOM -Value ""
    foreach ($event in $sortedEvents) {
        Append-Utf8Line -Path $DestinationPath -Line ($event | ConvertTo-Json -Depth 8 -Compress)
    }

    $preFilterSourceCount = [int](Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "PreFilterSourceCount" -DefaultValue 0)
    $postFilterSourceCount = [int](Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "PostFilterSourceCount" -DefaultValue 0)
    $maxReportedSourceCount = [int](Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "MaxReportedSourceCount" -DefaultValue 0)
    $sourceSearchStarted = [bool](Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "SourceSearchStarted" -DefaultValue $false)
    $backgroundSearchCompleted = [bool](Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "BackgroundSearchCompleted" -DefaultValue $false)
    $activeSearchCompleted = [bool](Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "ActiveSearchCompleted" -DefaultValue $false)
    $kadFallbackAttempted = [bool](Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "KadFallbackAttempted" -DefaultValue $false)
    $returnedNoSources = [bool](Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "ReturnedNoSources" -DefaultValue $false)
    $kadFallbackProduced = [bool](Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "KadFallbackProduced" -DefaultValue $false)

    $sourceSearchCompletionState = $null
    if ($manifestSummary.MaxSourceCount -gt 0) {
        $sourceSearchCompletionState = "agent_sources_merged_to_manifest"
    }
    elseif ($preFilterSourceCount -gt 0 -and $postFilterSourceCount -le 0) {
        $sourceSearchCompletionState = "agent_sources_filtered"
    }
    elseif (($backgroundSearchCompleted -or $activeSearchCompleted -or $kadFallbackAttempted -or $returnedNoSources) -and $preFilterSourceCount -le 0 -and $maxReportedSourceCount -le 0 -and -not $kadFallbackProduced) {
        $sourceSearchCompletionState = "agent_source_search_returned_zero"
    }
    elseif (-not $sourceSearchStarted) {
        $sourceSearchCompletionState = "agent_candidate_selected"
    }
    elseif ($preFilterSourceCount -le 0 -and $maxReportedSourceCount -le 0) {
        $sourceSearchCompletionState = "agent_source_search_started"
    }

    return [pscustomobject]@{
        SourceTransitionTimelinePath = $DestinationPath
        SourceSearchCompletionState = $sourceSearchCompletionState
        PreFilterSourceCount = $preFilterSourceCount
        PostFilterSourceCount = $postFilterSourceCount
        CallbackOnlySourceCount = [int](Get-JsonObjectPropertyValue -Object $SourceAcquisitionSummary -PropertyName "CallbackOnlySourceCount" -DefaultValue 0)
        MergedManifestSourceCount = [int]$manifestSummary.MaxSourceCount
        ManifestMaxVerifiedRangeCount = [int]$manifestSummary.MaxVerifiedRangeCount
        ManifestMaxBytesWritten = [UInt64]$manifestSummary.MaxBytesWritten
        FirstManifestSourceAtUtc = $manifestSummary.FirstManifestSourceAtUtc
        TransitionEventCount = $sortedEvents.Count
    }
}

function Export-AgentSourceAcquisitionEvents {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [datetime]$StartUtc,
        [datetime]$EndUtc,
        [string]$FileHash
    )

    $fileHashLower = ([string]$FileHash).ToLowerInvariant()
    $windowStart = $StartUtc.AddSeconds(-3)
    $windowEnd = $EndUtc.AddSeconds(3)
    $selectedLines = [System.Collections.Generic.List[string]]::new()

    if ($SourcePath -and (Test-Path -LiteralPath $SourcePath)) {
        foreach ($line in Get-Content -LiteralPath $SourcePath) {
            $timestamp = Parse-TextLogTimestampUtc -Line $line
            if ($null -eq $timestamp -or $timestamp -lt $windowStart -or $timestamp -gt $windowEnd) {
                continue
            }

            $lineLower = $line.ToLowerInvariant()
            if (
                $lineLower.Contains($fileHashLower) -or
                $lineLower.Contains("native ed2k download") -or
                $lineLower.Contains("background source search") -or
                $lineLower.Contains("source search") -or
                $lineLower.Contains("kad source fallback")
            ) {
                $selectedLines.Add($line) | Out-Null
            }
        }
    }

    Set-Content -LiteralPath $DestinationPath -Encoding utf8NoBOM -Value $selectedLines

    $matchedHashLineCount = 0
    $sourceSearchStarted = $false
    $returnedNoSources = $false
    $searchFailed = $false
    $kadFallbackProduced = $false
    $kadFallbackAttempted = $false
    $maxReportedSourceCount = 0
    $backgroundSearchCompleted = $false
    $activeSearchCompleted = $false
    $backgroundSourceCount = $null
    $activeSourceCount = $null
    $kadFallbackSourceCount = $null
    $aggregatedSourceCount = $null
    $preFilterSourceCount = $null
    $postFilterSourceCount = $null
    $callbackOnlySourceCount = $null
    $failureLines = [System.Collections.Generic.List[string]]::new()
    $transitionEvents = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $selectedLines) {
        $lineLower = $line.ToLowerInvariant()
        $timestamp = Parse-TextLogTimestampUtc -Line $line
        $tsUtc = if ($null -ne $timestamp) { $timestamp.ToUniversalTime().ToString("o") } else { $null }
        if ($lineLower.Contains($fileHashLower)) {
            $matchedHashLineCount++
        }
        if ($lineLower.Contains("source search")) {
            $sourceSearchStarted = $true
        }
        if ($lineLower.Contains("returned no sources")) {
            $returnedNoSources = $true
        }
        if ($lineLower.Contains("source search failed")) {
            $searchFailed = $true
            $failureLines.Add($line) | Out-Null
        }
        if ($lineLower.Contains("kad source fallback produced")) {
            $kadFallbackProduced = $true
            $kadFallbackAttempted = $true
        }

        $reportedCount = Get-NamedRegexIntValue -Line $line -Pattern 'source_count=(?<Count>\d+)'
        if ($null -eq $reportedCount) {
            $reportedCount = Get-NamedRegexIntValue -Line $line -Pattern 'sources=(?<Count>\d+)'
        }
        if ($null -ne $reportedCount -and $reportedCount -gt $maxReportedSourceCount) {
            $maxReportedSourceCount = $reportedCount
        }

        if ($lineLower.Contains("sent ed2k background source search")) {
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "background_source_search_started"
                    FileHash = $FileHash
                    RawLine = $line
                }) | Out-Null
        }
        elseif ($lineLower.Contains("source search attempt=")) {
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "active_source_search_started"
                    FileHash = $FileHash
                    RawLine = $line
                }) | Out-Null
        }

        if ($lineLower.Contains("native ed2k download background source acquisition completed")) {
            $backgroundSearchCompleted = $true
            $backgroundSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'source_count=(?<Count>\d+)'
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "background_source_search_completed"
                    FileHash = $FileHash
                    SourceCount = if ($null -ne $backgroundSourceCount) { $backgroundSourceCount } else { 0 }
                    AggregatedSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'aggregated_source_count=(?<Count>\d+)'
                    RawLine = $line
                }) | Out-Null
            continue
        }

        if ($lineLower.Contains("completed ed2k background source search")) {
            $backgroundSearchCompleted = $true
            $backgroundSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'source_count=(?<Count>\d+)'
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "background_source_search_completed"
                    FileHash = $FileHash
                    SourceCount = if ($null -ne $backgroundSourceCount) { $backgroundSourceCount } else { 0 }
                    RawLine = $line
                }) | Out-Null
            continue
        }

        if ($lineLower.Contains("native ed2k download active source acquisition completed")) {
            $activeSearchCompleted = $true
            $activeSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'source_count=(?<Count>\d+)'
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "active_source_search_completed"
                    FileHash = $FileHash
                    SourceCount = if ($null -ne $activeSourceCount) { $activeSourceCount } else { 0 }
                    AggregatedSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'aggregated_source_count=(?<Count>\d+)'
                    RawLine = $line
                }) | Out-Null
            continue
        }

        if ($lineLower.Contains("completed source search file_hash=")) {
            $activeSearchCompleted = $true
            $activeSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'sources=(?<Count>\d+)'
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "active_source_search_completed"
                    FileHash = $FileHash
                    SourceCount = if ($null -ne $activeSourceCount) { $activeSourceCount } else { 0 }
                    RawLine = $line
                }) | Out-Null
            continue
        }

        if ($lineLower.Contains("native ed2k download kad source fallback produced")) {
            $kadFallbackAttempted = $true
            $kadFallbackProduced = $true
            $kadFallbackSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'source_count=(?<Count>\d+)'
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "kad_source_fallback_completed"
                    FileHash = $FileHash
                    SourceCount = if ($null -ne $kadFallbackSourceCount) { $kadFallbackSourceCount } else { 0 }
                    AggregatedSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'aggregated_source_count=(?<Count>\d+)'
                    RawLine = $line
                }) | Out-Null
            continue
        }

        if ($lineLower.Contains("native ed2k download kad source fallback returned no sources")) {
            $kadFallbackAttempted = $true
            $returnedNoSources = $true
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "kad_source_fallback_returned_zero"
                    FileHash = $FileHash
                    RawLine = $line
                }) | Out-Null
            continue
        }

        if ($lineLower.Contains("native ed2k download source acquisition completed")) {
            $aggregatedSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'aggregated_source_count=(?<Count>\d+)'
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "source_acquisition_completed"
                    FileHash = $FileHash
                    AggregatedSourceCount = if ($null -ne $aggregatedSourceCount) { $aggregatedSourceCount } else { 0 }
                    RawLine = $line
                }) | Out-Null
            continue
        }

        if ($lineLower.Contains("native ed2k download source filtering")) {
            $preFilterSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'pre_filter_source_count=(?<Count>\d+)'
            $postFilterSourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'post_filter_source_count=(?<Count>\d+)'
            $callbackOnlySourceCount = Get-NamedRegexIntValue -Line $line -Pattern 'callback_only_source_count=(?<Count>\d+)'
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "source_filtering_completed"
                    FileHash = $FileHash
                    PreFilterSourceCount = if ($null -ne $preFilterSourceCount) { $preFilterSourceCount } else { 0 }
                    PostFilterSourceCount = if ($null -ne $postFilterSourceCount) { $postFilterSourceCount } else { 0 }
                    CallbackOnlySourceCount = if ($null -ne $callbackOnlySourceCount) { $callbackOnlySourceCount } else { 0 }
                    RawLine = $line
                }) | Out-Null
            continue
        }

        if ($lineLower.Contains("source search failed")) {
            $transitionEvents.Add([pscustomobject]@{
                    TsUtc = $tsUtc
                    EventKind = "agent_log"
                    Stage = "source_search_failed"
                    FileHash = $FileHash
                    RawLine = $line
                }) | Out-Null
            continue
        }
    }

    if ($null -eq $preFilterSourceCount -and $null -ne $aggregatedSourceCount) {
        $preFilterSourceCount = $aggregatedSourceCount
    }

    $sourceAcquisitionState = if ($maxReportedSourceCount -gt 0 -or $kadFallbackProduced) {
        "agent_probe_sources_present"
    }
    elseif ($returnedNoSources -or $searchFailed) {
        "agent_no_probe_sources"
    }
    elseif ($sourceSearchStarted) {
        "agent_source_search_started"
    }
    else {
        "agent_candidate_selected"
    }

    return [pscustomobject]@{
        EventPath = $DestinationPath
        EventCount = $selectedLines.Count
        MatchedHashLineCount = $matchedHashLineCount
        SourceSearchStarted = $sourceSearchStarted
        ReturnedNoSources = $returnedNoSources
        SearchFailed = $searchFailed
        KadFallbackProduced = $kadFallbackProduced
        KadFallbackAttempted = $kadFallbackAttempted
        MaxReportedSourceCount = $maxReportedSourceCount
        BackgroundSearchCompleted = $backgroundSearchCompleted
        ActiveSearchCompleted = $activeSearchCompleted
        BackgroundSourceCount = $backgroundSourceCount
        ActiveSourceCount = $activeSourceCount
        KadFallbackSourceCount = $kadFallbackSourceCount
        AggregatedSourceCount = $aggregatedSourceCount
        PreFilterSourceCount = $preFilterSourceCount
        PostFilterSourceCount = $postFilterSourceCount
        CallbackOnlySourceCount = $callbackOnlySourceCount
        SourceAcquisitionState = $sourceAcquisitionState
        SourceAcquisitionError = if ($failureLines.Count -gt 0) { ($failureLines -join "`n") } else { $null }
        TransitionEvents = @($transitionEvents)
    }
}

function Get-LastHarnessSearchSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $snapshotLine = Get-Content -LiteralPath $Path |
        Where-Object { $_ -match '"event":"results_snapshot"' } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($snapshotLine)) {
        return $null
    }

    return ($snapshotLine | ConvertFrom-Json)
}

function Wait-HarnessSearchSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$MinimumResults = 1,
        [int]$TimeoutSeconds = 240
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $snapshot = Get-LastHarnessSearchSnapshot -Path $Path
        if ($null -ne $snapshot -and [int]$snapshot.result_count -ge $MinimumResults) {
            return $snapshot
        }

        Start-Sleep -Seconds 2
    }

    $lastSnapshot = Get-LastHarnessSearchSnapshot -Path $Path
    if ($null -ne $lastSnapshot) {
        return $lastSnapshot
    }

    throw "Harness search results were not captured at $Path within $TimeoutSeconds seconds"
}

function Get-PreferredExtensionRank {
    param(
        [string]$Name
    )

    $extension = [System.IO.Path]::GetExtension([string]$Name).ToLowerInvariant()
    switch ($extension) {
        ".pdf" { return 5 }
        ".epub" { return 5 }
        ".mobi" { return 5 }
        ".azw" { return 4 }
        ".azw3" { return 4 }
        ".djvu" { return 4 }
        ".txt" { return 3 }
        ".rtf" { return 3 }
        ".doc" { return 3 }
        ".docx" { return 3 }
        ".chm" { return 2 }
        ".lit" { return 2 }
        default { return 0 }
    }
}

function Select-CommonCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$HarnessSnapshot,
        [Parameter(Mandatory = $true)]
        [psobject]$AgentSearchSummary,
        [Parameter(Mandatory = $true)]
        [UInt64]$MaxSizeBytes,
        [string[]]$PreferredHashes = @(),
        [string[]]$PinnedHashes = @(),
        [int]$MaxCandidates = 5
    )

    $preferredHashSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($preferredHash in @($PreferredHashes)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$preferredHash)) {
            $preferredHashSet.Add(([string]$preferredHash).ToLowerInvariant()) | Out-Null
        }
    }

    $harnessByHash = @{}
    foreach ($result in @($HarnessSnapshot.results)) {
        $hash = ([string](Get-JsonObjectPropertyValue -Object $result -PropertyName "hash" -DefaultValue "")).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($hash)) {
            $harnessByHash[$hash] = $result
        }
    }

    $agentByHash = @{}
    foreach ($file in @($AgentSearchSummary.Files)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$file.Hash)) {
            $agentByHash[[string]$file.Hash.ToLowerInvariant()] = $file
        }
    }

    if (@($PinnedHashes).Count -gt 0) {
        $selectedPinnedCandidates = [System.Collections.Generic.List[object]]::new()
        $selectionOrder = 0
        foreach ($pinnedHash in @($PinnedHashes)) {
            $normalizedHash = ([string]$pinnedHash).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($normalizedHash)) {
                continue
            }

            $pinnedHarnessRecord = if ($harnessByHash.ContainsKey($normalizedHash)) { $harnessByHash[$normalizedHash] } else { $null }
            $pinnedAgentRecord = if ($agentByHash.ContainsKey($normalizedHash)) { $agentByHash[$normalizedHash] } else { $null }
            $selectedPinnedCandidates.Add((New-CandidateRecord `
                -Hash $normalizedHash `
                -HarnessRecord $pinnedHarnessRecord `
                -AgentRecord $pinnedAgentRecord `
                -MaxSizeBytes $MaxSizeBytes `
                -PreferredHashSet $preferredHashSet `
                -SelectionKind "pinned" `
                -SelectionOrder $selectionOrder)) | Out-Null
            $selectionOrder++
        }

        if ($selectedPinnedCandidates.Count -eq 0) {
            throw "Pinned candidate selection resolved to zero usable hashes"
        }

        return @($selectedPinnedCandidates)
    }

    $candidates = foreach ($result in @($HarnessSnapshot.results)) {
        $hash = ([string](Get-JsonObjectPropertyValue -Object $result -PropertyName "hash" -DefaultValue "")).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($hash)) {
            continue
        }
        if (-not $agentByHash.ContainsKey($hash)) {
            continue
        }

        $candidate = New-CandidateRecord `
            -Hash $hash `
            -HarnessRecord $result `
            -AgentRecord $agentByHash[$hash] `
            -MaxSizeBytes $MaxSizeBytes `
            -PreferredHashSet $preferredHashSet `
            -SelectionKind "ranked"

        if (-not $candidate.IsCommonCandidate) {
            continue
        }

        $candidate
    }

    $selected = $candidates |
        Sort-Object `
            @{ Expression = "PreferredHashRank"; Descending = $true }, `
            @{ Expression = "ExtensionRank"; Descending = $true }, `
            @{ Expression = { $_.HarnessSourceCount + $_.AgentSourceCount + $_.AgentBatchHits }; Descending = $true }, `
            @{ Expression = "Size"; Descending = $false }, `
            @{ Expression = "Hash"; Descending = $false } |
        Select-Object -First $MaxCandidates

    if ($null -eq $selected -or @($selected).Count -eq 0) {
        throw "No common Kad search result matched the candidate filters"
    }

    $selectionOrder = 0
    return @($selected | ForEach-Object {
        [pscustomobject]@{
            Hash = $_.Hash
            Name = $_.Name
            Size = [UInt64]$_.Size
            HarnessSourceCount = [int]$_.HarnessSourceCount
            HarnessCompleteSourceCount = [int]$_.HarnessCompleteSourceCount
            AgentSourceCount = [int]$_.AgentSourceCount
            AgentBatchHits = [int]$_.AgentBatchHits
            ExtensionRank = [int]$_.ExtensionRank
            PreferredHashRank = [int]$_.PreferredHashRank
            IsCommonCandidate = [bool]$_.IsCommonCandidate
            MissingReason = $_.MissingReason
            SelectionKind = $_.SelectionKind
            SelectionOrder = $selectionOrder++
            HarnessSearchRecord = $_.HarnessSearchRecord
            AgentSearchRecord = $_.AgentSearchRecord
        }
    })
}

function Copy-IfExists {
    param(
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Copy-Item -LiteralPath $Path -Destination (Join-Path $DestinationRoot (Split-Path -Leaf $Path)) -Force
    }
}

function Get-UpnpList {
    $miniupnpcPath = "C:\bin\overrides\miniupnpc.exe"
    if (-not (Test-Path -LiteralPath $miniupnpcPath -PathType Leaf)) {
        throw "miniupnpc.exe not found at $miniupnpcPath"
    }

    return (& $miniupnpcPath -l | Out-String)
}

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}
if (-not $env:OVERLORD_LOG_DIR) {
    throw "OVERLORD_LOG_DIR is not set"
}

$profileWriterPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"
$nodesDatPath = Resolve-KadSeedBundleFilePath -ToolingRoot $toolingRoot -SeedBundleId "canonical" -FileName "nodes.dat"

foreach ($requiredPath in @($profileWriterPath, $nodesDatPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required helper not found at $requiredPath"
    }
}

$resolvedAdapter = Resolve-OverlordNetworkAdapter -PreferredInterfaceAlias $InterfaceAlias
$selectedServer = Select-Ed2kLiveServer
$effectivePinnedCandidateHashes = Resolve-PinnedCandidateHashes -PinnedCandidateHashes $PinnedCandidateHashes -PinnedCandidatesPath $PinnedCandidatesPath

Build-EmuleHarnessDebug | Out-Null

$scenarioId = "kad.search-download.emule-harness.agent.realnet.v1"
$runId = "{0}-{1}" -f $scenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\{0}\{1}" -f $scenarioId, $runId)
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"

$runManifest = [ordered]@{
    scenarioId = $scenarioId
    runId = $runId
    query = $Query
    transportModes = $TransportModes
    interfaceAlias = $resolvedAdapter.InterfaceAlias
    bindIp = $resolvedAdapter.IPAddress
    preferredHashes = @($PreferredHashes)
    pinnedCandidateHashes = @($effectivePinnedCandidateHashes)
    pinnedCandidatesPath = if ([string]::IsNullOrWhiteSpace($PinnedCandidatesPath)) { $null } else { (Resolve-Path -LiteralPath $PinnedCandidatesPath).ProviderPath }
    selectedServer = $selectedServer.Selected
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM $runManifestPath

$modeResults = [System.Collections.Generic.List[object]]::new()
$modeDefinitions = @(
    [pscustomobject]@{
        Id = "plaintext"
        HarnessMode = "PlaintextOnly"
        AgentKad = "Off"
        AgentEd2k = "Off"
    },
    [pscustomobject]@{
        Id = "obfuscated"
        HarnessMode = "ObfuscatedPreferred"
        AgentKad = "On"
        AgentEd2k = "On"
    }
)

switch ($TransportModes) {
    "PlaintextOnly" {
        $modeDefinitions = @($modeDefinitions | Where-Object { $_.Id -eq "plaintext" })
    }
    "ObfuscatedOnly" {
        $modeDefinitions = @($modeDefinitions | Where-Object { $_.Id -eq "obfuscated" })
    }
}

foreach ($mode in $modeDefinitions) {
    $modeRoot = Join-Path $artifactRoot $mode.Id
    $profileRoot = Join-Path $modeRoot "emule-harness-profile"
    $harnessArtifactRoot = Join-Path $modeRoot "harness-artifacts"
    $agentArtifactRoot = Join-Path $modeRoot "agent-artifacts"
    $agentSearchRoot = Join-Path $modeRoot "agent-search"
    $harnessDownloadsRoot = Join-Path $harnessArtifactRoot "downloads"
    $agentDownloadsRoot = Join-Path $agentArtifactRoot "downloads"
    $candidateEvidenceRoot = Join-Path $modeRoot "candidate-evidence"
    $harnessSearchPath = Join-Path $modeRoot "emule-harness-kad-search.jsonl"
    $harnessSelectedHashPath = Join-Path $modeRoot "selected-hash.txt"
    $candidateAttemptsPath = Join-Path $modeRoot "candidate-attempts.json"
    $candidateSelectionPath = Join-Path $modeRoot "candidate-selection.json"
    $candidatePinsPath = Join-Path $modeRoot "candidate-pins.json"
    $modeTracePath = Join-Path $modeRoot "execution-trace.log"
    $upnpBeforePath = Join-Path $modeRoot "miniupnpc-before.txt"
    $upnpAfterPath = Join-Path $modeRoot "miniupnpc-after.txt"
    foreach ($path in @($modeRoot, $harnessArtifactRoot, $agentArtifactRoot, $agentSearchRoot, $harnessDownloadsRoot, $agentDownloadsRoot, $candidateEvidenceRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    Set-Content -LiteralPath $modeTracePath -Encoding utf8NoBOM -Value ""

    $harnessSession = $null
    $agentSession = $null
    try {
        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) setup_start"
        Get-UpnpList | Set-Content -Encoding utf8NoBOM $upnpBeforePath

        $profile = & $profileWriterPath `
            -ProfileRoot $profileRoot `
            -BindAddr $resolvedAdapter.IPAddress `
            -TcpPort 46671 `
            -UdpPort 46673 `
            -ServerUdpPort 46675 `
            -WebPort 47101 `
            -EnableKademlia $true `
            -EnableEd2k $true `
            -EnableUpnp $true `
            -ResetTransientState

        Copy-Item -LiteralPath $nodesDatPath -Destination (Join-Path $profileRoot "config\nodes.dat") -Force
        Write-EmuleHarnessTargetServerMet `
            -ServerIp $selectedServer.Host `
            -ServerPort $selectedServer.Port `
            -UdpFlags $selectedServer.UdpFlags `
            -UdpKey $selectedServer.UdpKey `
            -UdpKeyIp $selectedServer.UdpKeyIp `
            -TcpObfuscationPort $selectedServer.TcpObfuscationPort `
            -UdpObfuscationPort $selectedServer.UdpObfuscationPort `
            -DestinationPath (Join-Path $profileRoot "config\server.met") | Out-Null
        Set-EmuleHarnessObfuscationMode -Mode $mode.HarnessMode -ProfileRoot $profileRoot | Out-Null

        $agentNetworking = Refresh-AgentRuntimeNetworking -InterfaceAlias $resolvedAdapter.InterfaceAlias
        Set-AgentObfuscationMode `
            -Kad $mode.AgentKad `
            -Ed2k $mode.AgentEd2k `
            -ConfigPath $agentNetworking.TempConfigPath | Out-Null

        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) harness_start"
        $harnessSession = Start-EmuleHarnessPrivateEd2kSession `
            -ProfileRoot $profileRoot `
            -SearchTerm $Query `
            -SearchResultsPath $harnessSearchPath `
            -SearchDownloadHashPath $harnessSelectedHashPath `
            -BuildConfig $EmuleHarnessBuildConfig
        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) harness_ready session_dir=$($harnessSession.SessionDir)"

        Get-UpnpList | Set-Content -Encoding utf8NoBOM $upnpAfterPath

        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) agent_start"
        $agentSession = Start-AgentParitySession `
            -InterfaceAlias $resolvedAdapter.InterfaceAlias `
            -ServerIp $selectedServer.Host `
            -ServerPort $selectedServer.Port `
            -ServerUdpFlags $selectedServer.UdpFlags `
            -ServerUdpKey $selectedServer.UdpKey `
            -ServerUdpKeyIp $selectedServer.UdpKeyIp `
            -ServerTcpObfuscationPort $selectedServer.TcpObfuscationPort `
            -ServerUdpObfuscationPort $selectedServer.UdpObfuscationPort

        Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl | Out-Null
        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) agent_ready session_dir=$($agentSession.SessionDir) control_url=$($agentSession.ControlUrl)"

        $agentSearchSummary = Run-AgentKadSearch `
            -Query $Query `
            -ControlUrl $agentSession.ControlUrl `
            -OutputRoot $agentSearchRoot `
            -TimeoutSeconds $SearchTimeoutSeconds
        $harnessSnapshot = Wait-HarnessSearchSnapshot `
            -Path $harnessSearchPath `
            -MinimumResults 1 `
            -TimeoutSeconds $SearchTimeoutSeconds
        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) searches_complete harness_results=$([int]$harnessSnapshot.result_count) agent_results=$([int]$agentSearchSummary.ResultCount)"

        $candidateList = Select-CommonCandidates `
            -HarnessSnapshot $harnessSnapshot `
            -AgentSearchSummary $agentSearchSummary `
            -MaxSizeBytes $MaxCandidateSizeBytes `
            -PreferredHashes $PreferredHashes `
            -PinnedHashes $effectivePinnedCandidateHashes `
            -MaxCandidates $CandidateAttemptCount
        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidates_selected count=$(@($candidateList).Count)"
        Write-JsonFile -Path $candidateSelectionPath -InputObject @($candidateList) -Depth 10
        Write-JsonFile -Path $candidatePinsPath -InputObject ([ordered]@{
            query = $Query
            mode = $mode.Id
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            candidateHashes = @($candidateList | ForEach-Object { $_.Hash })
            candidates = @($candidateList | ForEach-Object {
                [ordered]@{
                    hash = $_.Hash
                    name = $_.Name
                    size = [UInt64]$_.Size
                    isCommonCandidate = [bool]$_.IsCommonCandidate
                    missingReason = $_.MissingReason
                    selectionKind = $_.SelectionKind
                    selectionOrder = [int]$_.SelectionOrder
                }
            })
        }) -Depth 10

        $candidateAttempts = [System.Collections.Generic.List[object]]::new()
        $completedDownloads = [System.Collections.Generic.List[object]]::new()
        $stopAfterCurrentCandidate = $false
        foreach ($candidate in @($candidateList)) {
            $candidateAttemptStartedAtUtc = (Get-Date).ToUniversalTime()
            $candidateEvidencePath = Join-Path $candidateEvidenceRoot $candidate.Hash
            Save-CandidateSearchEvidence -Candidate $candidate -EvidenceRoot $candidateEvidencePath

            Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_start hash=$($candidate.Hash) size=$([UInt64]$candidate.Size) harness_sources=$([int]$candidate.HarnessSourceCount) agent_sources=$([int]$candidate.AgentSourceCount) agent_batch_hits=$([int]$candidate.AgentBatchHits) selection_kind=$($candidate.SelectionKind) is_common=$([bool]$candidate.IsCommonCandidate)"

            $attempt = [pscustomobject]@{
                Hash = $candidate.Hash
                Name = $candidate.Name
                Size = [UInt64]$candidate.Size
                HarnessSourceCount = [int]$candidate.HarnessSourceCount
                HarnessCompleteSourceCount = [int]$candidate.HarnessCompleteSourceCount
                AgentSourceCount = [int]$candidate.AgentSourceCount
                AgentBatchHits = [int]$candidate.AgentBatchHits
                IsCommonCandidate = [bool]$candidate.IsCommonCandidate
                MissingReason = $candidate.MissingReason
                SelectionKind = $candidate.SelectionKind
                SelectionOrder = [int]$candidate.SelectionOrder
                HarnessSearchRecord = $candidate.HarnessSearchRecord
                AgentSearchRecord = $candidate.AgentSearchRecord
                ProbeManifestPath = $null
                ProbeSources = 0
                ProbeCompleted = $false
                ProbeVerifiedRanges = 0
                AgentProgressState = $null
                AgentProgressVerifiedRanges = 0
                AgentProgressBytesWritten = [UInt64]0
                HarnessProbeState = $null
                HarnessProbePath = $null
                HarnessProbeSize = [UInt64]0
                HarnessProbeCompletionKind = $null
                ManifestProbeTimelinePath = $null
                SourceTransitionTimelinePath = $null
                SourceAcquisitionEventPath = $null
                SourceAcquisitionSummaryPath = $null
                AgentEd2kTraceWindowPath = $null
                HarnessEd2kTraceWindowPath = $null
                AgentStartupPhaseSummaryPath = $null
                HarnessStartupPhaseSummaryPath = $null
                StartupPhaseDiffPath = $null
                AgentStartupPhaseState = $null
                HarnessStartupPhaseState = $null
                FirstDivergentStartupPhase = $null
                SourceAcquisitionState = "agent_candidate_selected"
                SourceSearchCompletionState = $null
                SourceAcquisitionStarted = $false
                SourceAcquisitionError = $null
                PreFilterSourceCount = 0
                PostFilterSourceCount = 0
                CallbackOnlySourceCount = 0
                MergedManifestSourceCount = 0
                DownloadSucceeded = $false
                DownloadError = $null
                Outcome = $null
                EvidenceRoot = $candidateEvidencePath
                CandidateTraceWindowPath = $null
                AttemptStartedAtUtc = $candidateAttemptStartedAtUtc.ToString("o")
                AttemptCompletedAtUtc = $null
            }

            if (-not $candidate.IsCommonCandidate) {
                $attempt.DownloadError = "Candidate unavailable for replay: $($candidate.MissingReason)"
                Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_missing hash=$($candidate.Hash) reason=$($candidate.MissingReason)"
            }
            else {
                $agentTransferDir = Join-Path $agentSession.TransferRoot $candidate.Hash.ToLowerInvariant()
                if (Test-Path -LiteralPath $agentTransferDir) {
                    Remove-Item -LiteralPath $agentTransferDir -Recurse -Force
                }

                try {
                    Post-AgentEnrichDownload `
                        -FileHash $candidate.Hash `
                        -FileName $candidate.Name `
                        -FileSize ([UInt64]$candidate.Size) `
                        -ControlUrl $agentSession.ControlUrl | Out-Null

                    $probeManifestPath = Join-Path $agentTransferDir "resume-manifest.json"
                    $attempt.ProbeManifestPath = $probeManifestPath
                    $manifestProbeTimelinePath = Join-Path $candidateEvidencePath "manifest-probe-timeline.jsonl"
                    $attempt.ManifestProbeTimelinePath = $manifestProbeTimelinePath
                    $probeManifestState = Wait-TransferManifestProbeTimelineState `
                        -ManifestPath $probeManifestPath `
                        -TimelinePath $manifestProbeTimelinePath `
                        -TimeoutSeconds $CandidateSourceProbeTimeoutSeconds
                    $probeManifest = $probeManifestState.Manifest

                    $attempt.ProbeSources = if ($null -ne $probeManifest) { @(Get-JsonObjectPropertyValue -Object $probeManifest -PropertyName "sources" -DefaultValue @()).Count } else { 0 }
                    $attempt.ProbeCompleted = if ($null -ne $probeManifest) { [bool](Get-JsonObjectPropertyValue -Object $probeManifest -PropertyName "completed" -DefaultValue $false) } else { $false }
                    $attempt.ProbeVerifiedRanges = if ($null -ne $probeManifest) { @(Get-JsonObjectPropertyValue -Object $probeManifest -PropertyName "verified_ranges" -DefaultValue @()).Count } else { 0 }
                    Save-CandidateRuntimeEvidence -ProfileRoot $profileRoot -FileHash $candidate.Hash -EvidenceRoot $candidateEvidencePath -Phase "before-queue" -ProbeManifestPath $probeManifestPath
                    $sourceEventPath = Join-Path $candidateEvidencePath "agent-source-acquisition.log"
                    $sourceAcquisitionSummary = Export-AgentSourceAcquisitionEvents `
                        -SourcePath $agentSession.AgentLogPath `
                        -DestinationPath $sourceEventPath `
                        -StartUtc $candidateAttemptStartedAtUtc `
                        -EndUtc (Get-Date).ToUniversalTime() `
                        -FileHash $candidate.Hash
                    $sourceTransitionTimelinePath = Join-Path $candidateEvidencePath "source-transition-timeline.jsonl"
                    $sourceTransitionEvidence = Write-SourceTransitionTimeline `
                        -SourceAcquisitionSummary $sourceAcquisitionSummary `
                        -ManifestTimelinePath $manifestProbeTimelinePath `
                        -DestinationPath $sourceTransitionTimelinePath
                    $sourceAcquisitionSummary = $sourceAcquisitionSummary | Select-Object -Property * -ExcludeProperty TransitionEvents
                    $sourceAcquisitionSummary | Add-Member -NotePropertyName "SourceTransitionTimelinePath" -NotePropertyValue $sourceTransitionTimelinePath
                    $sourceAcquisitionSummary | Add-Member -NotePropertyName "SourceSearchCompletionState" -NotePropertyValue $sourceTransitionEvidence.SourceSearchCompletionState
                    $sourceAcquisitionSummary | Add-Member -NotePropertyName "MergedManifestSourceCount" -NotePropertyValue $sourceTransitionEvidence.MergedManifestSourceCount
                    $sourceAcquisitionSummary | Add-Member -NotePropertyName "ManifestMaxVerifiedRangeCount" -NotePropertyValue $sourceTransitionEvidence.ManifestMaxVerifiedRangeCount
                    $sourceAcquisitionSummary | Add-Member -NotePropertyName "ManifestMaxBytesWritten" -NotePropertyValue $sourceTransitionEvidence.ManifestMaxBytesWritten
                    $sourceAcquisitionSummary | Add-Member -NotePropertyName "FirstManifestSourceAtUtc" -NotePropertyValue $sourceTransitionEvidence.FirstManifestSourceAtUtc
                    $sourceAcquisitionSummary | Add-Member -NotePropertyName "TransitionEventCount" -NotePropertyValue $sourceTransitionEvidence.TransitionEventCount
                    $sourceAcquisitionSummaryPath = Join-Path $candidateEvidencePath "agent-source-acquisition-summary.json"
                    Write-JsonFile -Path $sourceAcquisitionSummaryPath -InputObject $sourceAcquisitionSummary -Depth 10
                    $attempt.SourceTransitionTimelinePath = $sourceTransitionTimelinePath
                    $attempt.SourceAcquisitionEventPath = $sourceEventPath
                    $attempt.SourceAcquisitionSummaryPath = $sourceAcquisitionSummaryPath
                    $attempt.SourceAcquisitionState = $sourceAcquisitionSummary.SourceAcquisitionState
                    $attempt.SourceSearchCompletionState = $sourceTransitionEvidence.SourceSearchCompletionState
                    $attempt.SourceAcquisitionStarted = [bool]$sourceAcquisitionSummary.SourceSearchStarted
                    $attempt.SourceAcquisitionError = $sourceAcquisitionSummary.SourceAcquisitionError
                    $attempt.PreFilterSourceCount = [int](Get-JsonObjectPropertyValue -Object $sourceAcquisitionSummary -PropertyName "PreFilterSourceCount" -DefaultValue 0)
                    $attempt.PostFilterSourceCount = [int](Get-JsonObjectPropertyValue -Object $sourceAcquisitionSummary -PropertyName "PostFilterSourceCount" -DefaultValue 0)
                    $attempt.CallbackOnlySourceCount = [int](Get-JsonObjectPropertyValue -Object $sourceAcquisitionSummary -PropertyName "CallbackOnlySourceCount" -DefaultValue 0)
                    $attempt.MergedManifestSourceCount = [int]$sourceTransitionEvidence.MergedManifestSourceCount
                    if (
                        $attempt.ProbeSources -gt 0 -or
                        $attempt.ProbeCompleted -or
                        $attempt.ProbeVerifiedRanges -gt 0 -or
                        $attempt.PostFilterSourceCount -gt 0 -or
                        [int](Get-JsonObjectPropertyValue -Object $sourceAcquisitionSummary -PropertyName "MaxReportedSourceCount" -DefaultValue 0) -gt 0
                    ) {
                        $attempt.SourceAcquisitionState = "agent_probe_sources_present"
                    }
                    Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_probe hash=$($candidate.Hash) agent_probe_sources=$($attempt.ProbeSources) agent_probe_completed=$($attempt.ProbeCompleted) agent_probe_verified_ranges=$($attempt.ProbeVerifiedRanges) pre_filter_sources=$($attempt.PreFilterSourceCount) post_filter_sources=$($attempt.PostFilterSourceCount) merged_manifest_sources=$($attempt.MergedManifestSourceCount)"

                    if ($attempt.ProbeSources -gt 0 -or $attempt.ProbeCompleted -or $attempt.ProbeVerifiedRanges -gt 0) {
                        Set-Content -LiteralPath $harnessSelectedHashPath -Value $candidate.Hash -Encoding ascii
                        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_hash_written hash=$($candidate.Hash)"
                        Save-CandidateRuntimeEvidence -ProfileRoot $profileRoot -FileHash $candidate.Hash -EvidenceRoot $candidateEvidencePath -Phase "after-queue" -ProbeManifestPath $probeManifestPath

                        $agentProgressState = Wait-TransferManifestProgressState `
                            -ManifestPath $probeManifestPath `
                            -TimeoutSeconds $AgentTransferProgressProbeTimeoutSeconds
                        $attempt.AgentProgressState = $agentProgressState.State
                        $attempt.AgentProgressVerifiedRanges = [int]$agentProgressState.VerifiedRangeCount
                        $attempt.AgentProgressBytesWritten = [UInt64]$agentProgressState.BytesWritten
                        Save-CandidateRuntimeEvidence -ProfileRoot $profileRoot -FileHash $candidate.Hash -EvidenceRoot $candidateEvidencePath -Phase "after-agent-progress" -ProbeManifestPath $probeManifestPath
                        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_agent_progress hash=$($candidate.Hash) state=$($agentProgressState.State) verified_ranges=$($agentProgressState.VerifiedRangeCount) bytes_written=$([UInt64]$agentProgressState.BytesWritten)"

                        if ($agentProgressState.State -eq "no-progress") {
                            $attempt.DownloadError = "Agent transfer showed no progress within $AgentTransferProgressProbeTimeoutSeconds seconds after queueing"
                            Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_skip_no_agent_progress hash=$($candidate.Hash)"
                        }
                        else {
                            $agentTransferManifest = if ($agentProgressState.State -eq "completed") {
                                $agentProgressState.Manifest
                            } else {
                                Wait-TransferManifestState `
                                    -ManifestPath $probeManifestPath `
                                    -TimeoutSeconds $DownloadTimeoutSeconds
                            }
                            Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_agent_completed hash=$($candidate.Hash)"

                            $harnessProbeState = Wait-HarnessDownloadProbeState `
                                -ProfileRoot $profileRoot `
                                -FileHash $candidate.Hash `
                                -ExpectedName $candidate.Name `
                                -ExpectedSize ([UInt64]$candidate.Size) `
                                -TimeoutSeconds $HarnessProgressProbeTimeoutSeconds
                            $attempt.HarnessProbeState = $harnessProbeState.State
                            $attempt.HarnessProbePath = $harnessProbeState.Path
                            $attempt.HarnessProbeSize = [UInt64]$harnessProbeState.Length
                            $attempt.HarnessProbeCompletionKind = $harnessProbeState.CompletionKind
                            Save-CandidateRuntimeEvidence -ProfileRoot $profileRoot -FileHash $candidate.Hash -EvidenceRoot $candidateEvidencePath -Phase "after-harness-probe" -ProbeManifestPath $probeManifestPath
                            Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_harness_probe hash=$($candidate.Hash) state=$($harnessProbeState.State) path=$($harnessProbeState.Path) size=$([UInt64]$harnessProbeState.Length)"

                            if ($harnessProbeState.State -eq "no-progress") {
                                $attempt.DownloadError = "Harness download showed no progress within $HarnessProgressProbeTimeoutSeconds seconds after queueing"
                                Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_skip_no_harness_progress hash=$($candidate.Hash)"
                            }
                            else {
                                $harnessDownloadState = Wait-HarnessDownloadCompleted `
                                    -ProfileRoot $profileRoot `
                                    -FileHash $candidate.Hash `
                                    -ExpectedName $candidate.Name `
                                    -ExpectedSize ([UInt64]$candidate.Size) `
                                    -TimeoutSeconds $DownloadTimeoutSeconds

                                $candidateAgentArtifactRoot = Join-Path $agentDownloadsRoot $candidate.Hash.ToLowerInvariant()
                                New-Item -ItemType Directory -Path $candidateAgentArtifactRoot -Force | Out-Null
                                $transferCollection = Collect-AgentEd2kTransfer `
                                    -TransferRoot $agentSession.TransferRoot `
                                    -FileHash $candidate.Hash `
                                    -DestinationRoot $candidateAgentArtifactRoot

                                $candidateHarnessArtifactRoot = Join-Path $harnessDownloadsRoot $candidate.Hash.ToLowerInvariant()
                                New-Item -ItemType Directory -Path $candidateHarnessArtifactRoot -Force | Out-Null
                                Copy-Item -LiteralPath $harnessDownloadState.Path -Destination (Join-Path $candidateHarnessArtifactRoot $candidate.Name) -Force
                                Save-CandidateRuntimeEvidence -ProfileRoot $profileRoot -FileHash $candidate.Hash -EvidenceRoot $candidateEvidencePath -Phase "completed" -ProbeManifestPath $probeManifestPath

                                $attempt.DownloadSucceeded = $true
                                $attempt.HarnessDownloadedPath = $harnessDownloadState.Path
                                $attempt.HarnessDownloadedSize = [UInt64]$harnessDownloadState.Length
                                $attempt.HarnessCompletionKind = $harnessDownloadState.CompletionKind
                                $attempt.AgentTransferManifestPath = $probeManifestPath
                                $attempt.AgentTransferCompleted = [bool](Get-JsonObjectPropertyValue -Object $agentTransferManifest -PropertyName "completed" -DefaultValue $false)
                                $attempt.AgentTransferCollectedRoot = $transferCollection.DestinationRoot

                                $completedDownloads.Add([pscustomobject]@{
                                    Hash = $candidate.Hash
                                    Name = $candidate.Name
                                    Size = [UInt64]$candidate.Size
                                    HarnessDownloadedPath = $harnessDownloadState.Path
                                    HarnessDownloadedSize = [UInt64]$harnessDownloadState.Length
                                    HarnessCompletionKind = $harnessDownloadState.CompletionKind
                                    AgentTransferManifestPath = $probeManifestPath
                                    AgentTransferCompleted = [bool](Get-JsonObjectPropertyValue -Object $agentTransferManifest -PropertyName "completed" -DefaultValue $false)
                                    AgentTransferCollectedRoot = $transferCollection.DestinationRoot
                                    EvidenceRoot = $candidateEvidencePath
                                }) | Out-Null
                                Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_completed hash=$($candidate.Hash) harness_path=$($harnessDownloadState.Path)"

                                if ($completedDownloads.Count -ge $SuccessfulDownloadCount) {
                                    $stopAfterCurrentCandidate = $true
                                }
                            }
                        }
                    }
                    else {
                        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_skip_no_agent_probe hash=$($candidate.Hash)"
                    }
                }
                catch {
                    Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_failed hash=$($candidate.Hash) error=$($_.Exception.Message)"
                    $attempt.DownloadError = $_.Exception.Message
                }
            }

            $candidateAttemptCompletedAtUtc = (Get-Date).ToUniversalTime()
            $attempt.AttemptCompletedAtUtc = $candidateAttemptCompletedAtUtc.ToString("o")
            $attempt.Outcome = Get-CandidateOutcome -Attempt $attempt

            if ($candidate.IsCommonCandidate) {
                $candidateTraceWindowPath = Join-Path $candidateEvidencePath "harness-ed2k-tcp-window.jsonl"
                $traceWindowWritten = Export-Ed2kTraceWindow `
                    -SourcePath $harnessSession.EmuleHarnessEd2kTcpDumpPath `
                    -DestinationPath $candidateTraceWindowPath `
                    -StartUtc $candidateAttemptStartedAtUtc `
                    -EndUtc $candidateAttemptCompletedAtUtc
                if ($traceWindowWritten) {
                    $attempt.CandidateTraceWindowPath = $candidateTraceWindowPath
                    $attempt.HarnessEd2kTraceWindowPath = $candidateTraceWindowPath
                }

                $agentEd2kTraceSourcePath = Resolve-AgentEd2kTracePath -AgentSession $agentSession
                $agentEd2kTraceWindowPath = Join-Path $candidateEvidencePath "agent-ed2k-tcp-window.jsonl"
                $agentTraceWindowWritten = Export-Ed2kTraceWindow `
                    -SourcePath $agentEd2kTraceSourcePath `
                    -DestinationPath $agentEd2kTraceWindowPath `
                    -StartUtc $candidateAttemptStartedAtUtc `
                    -EndUtc $candidateAttemptCompletedAtUtc
                if ($agentTraceWindowWritten) {
                    $attempt.AgentEd2kTraceWindowPath = $agentEd2kTraceWindowPath
                }

                $agentStartupWindowPath = $null
                if ($agentTraceWindowWritten) {
                    $agentStartupWindowPath = $agentEd2kTraceWindowPath
                }
                $harnessStartupWindowPath = $null
                if ($traceWindowWritten) {
                    $harnessStartupWindowPath = $candidateTraceWindowPath
                }
                $agentStartupPhaseSummary = Get-Ed2kStartupPhaseSummary `
                    -WindowPath $agentStartupWindowPath `
                    -SourceName "agent"
                $harnessStartupPhaseSummary = Get-Ed2kStartupPhaseSummary `
                    -WindowPath $harnessStartupWindowPath `
                    -SourceName "emule_harness"
                $startupPhaseDiff = Compare-Ed2kStartupPhaseSummaries `
                    -AgentSummary $agentStartupPhaseSummary `
                    -HarnessSummary $harnessStartupPhaseSummary

                $agentStartupPhaseSummaryPath = Join-Path $candidateEvidencePath "agent-ed2k-startup-phases.json"
                $harnessStartupPhaseSummaryPath = Join-Path $candidateEvidencePath "harness-ed2k-startup-phases.json"
                $startupPhaseDiffPath = Join-Path $candidateEvidencePath "ed2k-startup-phase-diff.json"
                Write-JsonFile -Path $agentStartupPhaseSummaryPath -InputObject $agentStartupPhaseSummary -Depth 10
                Write-JsonFile -Path $harnessStartupPhaseSummaryPath -InputObject $harnessStartupPhaseSummary -Depth 10
                Write-JsonFile -Path $startupPhaseDiffPath -InputObject $startupPhaseDiff -Depth 10

                $attempt.AgentStartupPhaseSummaryPath = $agentStartupPhaseSummaryPath
                $attempt.HarnessStartupPhaseSummaryPath = $harnessStartupPhaseSummaryPath
                $attempt.StartupPhaseDiffPath = $startupPhaseDiffPath
                if ($agentStartupPhaseSummary.FinalStage) {
                    $attempt.AgentStartupPhaseState = $agentStartupPhaseSummary.FinalStage
                }
                elseif ($agentStartupPhaseSummary.TerminalState) {
                    $attempt.AgentStartupPhaseState = $agentStartupPhaseSummary.TerminalState
                }
                elseif (-not $agentStartupPhaseSummary.ObservedDownloadTrace) {
                    $attempt.AgentStartupPhaseState = "no_download_trace"
                }

                if ($harnessStartupPhaseSummary.FinalStage) {
                    $attempt.HarnessStartupPhaseState = $harnessStartupPhaseSummary.FinalStage
                }
                elseif ($harnessStartupPhaseSummary.TerminalState) {
                    $attempt.HarnessStartupPhaseState = $harnessStartupPhaseSummary.TerminalState
                }
                elseif (-not $harnessStartupPhaseSummary.ObservedDownloadTrace) {
                    $attempt.HarnessStartupPhaseState = "no_download_trace"
                }
                $attempt.FirstDivergentStartupPhase = $startupPhaseDiff.FirstDivergentStage
                Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) candidate_startup_phases hash=$($candidate.Hash) agent_final=$($attempt.AgentStartupPhaseState) harness_final=$($attempt.HarnessStartupPhaseState) first_diff=$($attempt.FirstDivergentStartupPhase) parity_state=$($startupPhaseDiff.ParityState)"
            }

            Write-JsonFile -Path (Join-Path $candidateEvidencePath "candidate-attempt-summary.json") -InputObject $attempt -Depth 12
            $candidateAttempts.Add($attempt) | Out-Null

            if ($stopAfterCurrentCandidate) {
                break
            }
        }
        Write-JsonFile -Path $candidateAttemptsPath -InputObject @($candidateAttempts) -Depth 12

        if ($completedDownloads.Count -lt $SuccessfulDownloadCount) {
            Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) insufficient_completions completed=$($completedDownloads.Count) required=$SuccessfulDownloadCount"
            throw "Only $($completedDownloads.Count) common Kad results completed download in mode '$($mode.Id)' within $CandidateAttemptCount attempts. See $candidateAttemptsPath"
        }

        if (-not $KeepSessionsRunning) {
            if ($harnessSession) {
                Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) harness_stop_try session_dir=$($harnessSession.SessionDir)"
                Stop-EmuleHarnessParitySession -SessionDir $harnessSession.SessionDir | Out-Null
            }
            if ($agentSession) {
                Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) agent_stop_try session_dir=$($agentSession.SessionDir)"
                Stop-AgentParitySession -SessionDir $agentSession.SessionDir | Out-Null
            }
        }

        foreach ($path in @(
            $harnessSearchPath,
            $harnessSession.TraceLogPath,
            $harnessSession.VerboseLogPath,
            $harnessSession.StatusLogPath,
            $harnessSession.EmuleHarnessUdpDumpPath,
            $harnessSession.EmuleHarnessEd2kTcpDumpPath,
            $upnpBeforePath,
            $upnpAfterPath
        )) {
            Copy-IfExists -Path $path -DestinationRoot $harnessArtifactRoot
        }
        foreach ($path in @(
            $agentSearchSummary.RawResultsPath,
            $agentSearchSummary.RawEventsPath,
            $agentSearchSummary.SummaryPath,
            $agentSession.AgentLogPath,
            $agentSession.PacketDumpPath,
            (Resolve-AgentEd2kTracePath -AgentSession $agentSession)
        )) {
            Copy-IfExists -Path $path -DestinationRoot $agentArtifactRoot
        }

        $modeResults.Add([pscustomobject]@{
            Mode = $mode.Id
            Success = $true
            Query = $Query
            SuccessfulDownloadCount = $SuccessfulDownloadCount
            CompletedDownloadCount = $completedDownloads.Count
            CompletedDownloads = @($completedDownloads)
            CandidateAttemptsPath = $candidateAttemptsPath
            CandidateSelectionPath = $candidateSelectionPath
            CandidatePinsPath = $candidatePinsPath
            HarnessReadyState = $harnessSession.EmuleHarnessReadyState
            AgentControlUrl = $agentSession.ControlUrl
            AgentSearchStatus = $agentSearchSummary.Status
            HarnessSearchResultCount = [int]$harnessSnapshot.result_count
            AgentSearchResultCount = [int]$agentSearchSummary.ResultCount
            HarnessArtifactsRoot = $harnessArtifactRoot
            AgentArtifactsRoot = $agentArtifactRoot
        }) | Out-Null
        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) success completed_downloads=$($completedDownloads.Count)"
    }
    catch {
        Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) error=$($_.Exception.Message)"
        $modeResults.Add([pscustomobject]@{
            Mode = $mode.Id
            Success = $false
            Query = $Query
            Error = $_.Exception.Message
            HarnessSessionDir = if ($harnessSession) { $harnessSession.SessionDir } else { $null }
            AgentSessionDir = if ($agentSession) { $agentSession.SessionDir } else { $null }
            CandidateAttemptsPath = if (Test-Path -LiteralPath $candidateAttemptsPath) { $candidateAttemptsPath } else { $null }
            CandidateSelectionPath = if (Test-Path -LiteralPath $candidateSelectionPath) { $candidateSelectionPath } else { $null }
            CandidatePinsPath = if (Test-Path -LiteralPath $candidatePinsPath) { $candidatePinsPath } else { $null }
            HarnessArtifactsRoot = $harnessArtifactRoot
            AgentArtifactsRoot = $agentArtifactRoot
        }) | Out-Null
    }
    finally {
        if (-not $KeepSessionsRunning) {
            if ($harnessSession) {
                try {
                    Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) harness_stop_finally session_dir=$($harnessSession.SessionDir)"
                    Stop-EmuleHarnessParitySession -SessionDir $harnessSession.SessionDir | Out-Null
                }
                catch {
                    Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) harness_stop_finally_error error=$($_.Exception.Message)"
                }
            }
            if ($agentSession) {
                try {
                    Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) agent_stop_finally session_dir=$($agentSession.SessionDir)"
                    Stop-AgentParitySession -SessionDir $agentSession.SessionDir | Out-Null
                }
                catch {
                    Write-ScenarioTraceLine -Path $modeTracePath -Message "mode=$($mode.Id) agent_stop_finally_error error=$($_.Exception.Message)"
                }
            }
        }
    }
}

$summary = [pscustomobject]@{
    ScenarioId = $scenarioId
    RunId = $runId
    Query = $Query
    TransportModes = $TransportModes
    InterfaceAlias = $resolvedAdapter.InterfaceAlias
    BindIp = $resolvedAdapter.IPAddress
    PreferredHashes = @($PreferredHashes)
    PinnedCandidateHashes = @($effectivePinnedCandidateHashes)
    PinnedCandidatesPath = if ([string]::IsNullOrWhiteSpace($PinnedCandidatesPath)) { $null } else { (Resolve-Path -LiteralPath $PinnedCandidatesPath).ProviderPath }
    SelectedServer = $selectedServer
    Modes = @($modeResults)
    StartedAtUtc = $runManifest.startedAtUtc
    CompletedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8NoBOM $runSummaryPath

if (@($modeResults | Where-Object { -not $_.Success }).Count -gt 0) {
    throw "One or more realnet Kad search/download parity modes failed. See $runSummaryPath"
}

$summary

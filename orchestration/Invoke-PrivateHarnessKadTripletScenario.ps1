#Requires -Version 7.6
<#
.SYNOPSIS
Runs a local loopback-only Kad cluster with three eMule harness instances and one agent.

.DESCRIPTION
Builds the eMule harness through the canonical eMule-build entrypoint, starts the
coordinator if needed, materializes three isolated harness profiles, boots one
local agent against the cluster, waits for harness publishes, triggers one manual
agent publish, runs a coordinator keyword search for "ubuntu linux", and captures
the resulting artifacts.
#>

[CmdletBinding()]
param(
    [string]$ScenarioManifestPath = (Join-Path $PSScriptRoot "..\scenarios\kad.harness.triplet.local.v1\manifest.v1.json"),
    [ValidateSet("Debug")]
    [string]$HarnessBuildConfig = "Debug",
    [int]$HarnessContactTimeoutSeconds = 240,
    [int]$HarnessPublishSettleSeconds = 120,
    [int]$AgentPublishTimeoutSeconds = 180,
    [int]$SearchTimeoutSeconds = 180,
    [int]$SearchRetryDelaySeconds = 15,
    [switch]$KeepSessionsRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\subsystems\agent\AgentSubsystem.ps1")
. (Join-Path $PSScriptRoot "..\subsystems\emule-harness\EmuleHarnessSubsystem.ps1")

function Wait-AgentControlReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 120
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

function Wait-AgentKadBootstrapReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 180,
        [int]$MinimumPeersConnected = 1
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
            if ($null -ne $response -and [int]$response.peers_connected -ge $MinimumPeersConnected) {
                return $response
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }

    throw "Agent Kad bootstrap did not become ready at $StatsUrl within $TimeoutSeconds seconds"
}

function Wait-CoordinatorReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CoordinatorUrl,
        [int]$TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $CoordinatorUrl.TrimEnd("/") -TimeoutSec 10 -SkipHttpErrorCheck
            if ($null -ne $response -and [int]$response.StatusCode -gt 0) {
                return
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }

    throw "Coordinator did not become ready at $CoordinatorUrl within $TimeoutSeconds seconds"
}

function Get-CoordinatorProcesses {
    @(
        Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*node_modules\\vite\\bin\\vite.js*' }
    )
}

function New-SeedPdfFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$MarkerText,
        [Parameter(Mandatory = $true)]
        [int]$RepeatCount
    )

    $line = "%PDF-1.4`n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj`n2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj`n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>endobj`n4 0 obj<</Length 128>>stream`nBT /F1 12 Tf 32 120 Td ($MarkerText) Tj ET`nendstream`nendobj`nxref`n0 5`n0000000000 65535 f `ntrailer<</Size 5/Root 1 0 R>>`nstartxref`n0`n%%EOF`n"
    $builder = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt $RepeatCount; $index++) {
        [void]$builder.Append($line)
    }

    [System.IO.File]::WriteAllText(
        $Path,
        $builder.ToString(),
        (New-Object System.Text.ASCIIEncoding)
    )
}

function Parse-Ed2kLinkFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $link = (Get-Content -LiteralPath $Path -Raw).Trim()
    $pattern = '^ed2k://\|file\|(?<Name>[^|]+)\|(?<Size>\d+)\|(?<Hash>[0-9A-Fa-f]{32})\|'
    if ($link -notmatch $pattern) {
        throw "ED2K link at $Path is not in the expected format"
    }

    [pscustomobject]@{
        Link = $link
        FileName = [System.Uri]::UnescapeDataString($matches.Name)
        FileSize = [UInt64]$matches.Size
        FileHash = $matches.Hash.ToLowerInvariant()
    }
}

function Resolve-ScenarioSearchTargetRecord {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Manifest,
        [pscustomobject[]]$HarnessLinkRecords = @()
    )

    $targetRefProperty = $Manifest.search.PSObject.Properties["targetRef"]
    $targetRef = if ($null -ne $targetRefProperty -and -not [string]::IsNullOrWhiteSpace([string]$targetRefProperty.Value)) {
        [string]$targetRefProperty.Value
    }
    else {
        "manualPublish"
    }

    if ($targetRef -eq "manualPublish") {
        return [pscustomobject]@{
            TargetRef = $targetRef
            FileHash = [string]$Manifest.agent.manualPublish.hash
            FileSize = [UInt64]$Manifest.agent.manualPublish.size
            FileName = [string]$Manifest.agent.manualPublish.canonicalName
        }
    }

    $harnessRecord = @($HarnessLinkRecords | Where-Object { [string]$_.HarnessId -eq $targetRef } | Select-Object -First 1)[0]
    if ($null -eq $harnessRecord) {
        throw "Search targetRef '$targetRef' did not match any harness link record"
    }

    [pscustomobject]@{
        TargetRef = $targetRef
        FileHash = [string]$harnessRecord.FileHash
        FileSize = [UInt64]$harnessRecord.FileSize
        FileName = [string]$harnessRecord.FileName
    }
}

function Resolve-ScenarioSearchDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Manifest,
        [pscustomobject[]]$HarnessLinkRecords = @()
    )

    $searchKindProperty = $Manifest.search.PSObject.Properties["kind"]
    $searchKind = if ($null -ne $searchKindProperty -and -not [string]::IsNullOrWhiteSpace([string]$searchKindProperty.Value)) {
        [string]$searchKindProperty.Value
    }
    else {
        "keyword"
    }

    $requiredFileNamesProperty = $Manifest.search.PSObject.Properties["requiredFileNames"]
    [string[]]$requiredFileNames = if ($null -ne $requiredFileNamesProperty -and $null -ne $requiredFileNamesProperty.Value) {
        @($requiredFileNamesProperty.Value | ForEach-Object { [string]$_ })
    }
    else {
        @()
    }

    switch ($searchKind) {
        "keyword" {
            $query = [string]$Manifest.search.query
            if ([string]::IsNullOrWhiteSpace($query)) {
                throw "Scenario search.query is required for keyword searches"
            }
            if (@($requiredFileNames).Count -eq 0) {
                $requiredFileNames = @($HarnessLinkRecords | ForEach-Object { [string]$_.FileName })
            }
            return [pscustomobject]@{
                Kind = $searchKind
                Query = $query
                FileHash = $null
                FileSize = $null
                TargetRef = $null
                RequiredFileNames = $requiredFileNames
                Payload = [ordered]@{
                    protocol = "kad2"
                    kind = "keyword"
                    query = $query
                }
            }
        }
        "source" {
            $targetRecord = Resolve-ScenarioSearchTargetRecord -Manifest $Manifest -HarnessLinkRecords $HarnessLinkRecords
            if (@($requiredFileNames).Count -eq 0) {
                $requiredFileNames = @([string]$targetRecord.FileName)
            }
            return [pscustomobject]@{
                Kind = $searchKind
                Query = $null
                FileHash = [string]$targetRecord.FileHash
                FileSize = [UInt64]$targetRecord.FileSize
                TargetRef = [string]$targetRecord.TargetRef
                RequiredFileNames = $requiredFileNames
                Payload = [ordered]@{
                    protocol = "kad2"
                    kind = "source"
                    file_hash = [ordered]@{
                        kind = "ed2k"
                        value = [string]$targetRecord.FileHash
                    }
                    file_size = [UInt64]$targetRecord.FileSize
                }
            }
        }
        "notes" {
            $targetRecord = Resolve-ScenarioSearchTargetRecord -Manifest $Manifest -HarnessLinkRecords $HarnessLinkRecords
            if (@($requiredFileNames).Count -eq 0) {
                $requiredFileNames = @([string]$targetRecord.FileName)
            }
            return [pscustomobject]@{
                Kind = $searchKind
                Query = $null
                FileHash = [string]$targetRecord.FileHash
                FileSize = [UInt64]$targetRecord.FileSize
                TargetRef = [string]$targetRecord.TargetRef
                RequiredFileNames = $requiredFileNames
                Payload = [ordered]@{
                    protocol = "kad2"
                    kind = "notes"
                    file_hash = [ordered]@{
                        kind = "ed2k"
                        value = [string]$targetRecord.FileHash
                    }
                    file_size = [UInt64]$targetRecord.FileSize
                }
            }
        }
        default {
            throw "Unsupported scenario search.kind '$searchKind'"
        }
    }
}

function Wait-Path {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for path $Path"
}

function Get-NewHarnessTraceLines {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HarnessSession
    )

    if (-not (Test-Path -LiteralPath $HarnessSession.TraceLogPath)) {
        return @()
    }

    return @(
        Get-Content -LiteralPath $HarnessSession.TraceLogPath |
            Select-Object -Skip ([int]$HarnessSession.TraceLinesBefore)
    )
}

function Wait-HarnessPublishReady {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HarnessSession,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $tracePattern = 'event=(publish_|search_storefile_prepare|search_storekeyword_prepare|search_storesource_prepare)'
    $verbosePattern = 'eMule harness publish gate ready|eMule harness publish start family='
    while ((Get-Date) -lt $deadline) {
        $lines = @(Get-NewHarnessTraceLines -HarnessSession $HarnessSession)
        $publishLines = @($lines | Where-Object { $_ -match $tracePattern })
        if ($publishLines.Count -gt 0) {
            return [pscustomobject]@{
                Ready = $true
                Source = "trace"
                TraceLineCount = $lines.Count
                PublishLineCount = $publishLines.Count
            }
        }

        if (Test-Path -LiteralPath $HarnessSession.VerboseLogPath) {
            $verboseLines = @(Get-Content -LiteralPath $HarnessSession.VerboseLogPath)
            $verbosePublishLines = @($verboseLines | Where-Object { $_ -match $verbosePattern })
            if ($verbosePublishLines.Count -gt 0) {
                return [pscustomobject]@{
                    Ready = $true
                    Source = "verbose"
                    TraceLineCount = $lines.Count
                    PublishLineCount = $verbosePublishLines.Count
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "Harness session $($HarnessSession.EmuleHarnessProfileRoot) did not emit publish-ready trace markers within $TimeoutSeconds seconds"
}

function Wait-HarnessContactReady {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HarnessSession,
        [int]$TimeoutSeconds = 240
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $contactPattern = 'Updating contact, passed key check'
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $HarnessSession.VerboseLogPath) {
            $match = Select-String -LiteralPath $HarnessSession.VerboseLogPath -Pattern $contactPattern | Select-Object -Last 1
            if ($match) {
                return [pscustomobject]@{
                    Ready = $true
                    MatchedLine = $match.Line
                }
            }

            $loopbackFallback = Get-HarnessLoopbackBootstrapReadyEvidence -HarnessSession $HarnessSession
            if ($null -ne $loopbackFallback) {
                return [pscustomobject]@{
                    Ready = $true
                    MatchedLine = $loopbackFallback.MatchedLine
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    $failure = Get-HarnessKadFailureFingerprint -HarnessSession $HarnessSession
    if ($null -ne $failure) {
        throw ("Harness session {0} did not validate any Kad contact within {1} seconds; first divergence={2}; stage={3}; evidence={4}" -f `
            $HarnessSession.EmuleHarnessProfileRoot, `
            $TimeoutSeconds, `
            $failure.code, `
            $failure.stage, `
            $failure.evidenceLine)
    }

    throw "Harness session $($HarnessSession.EmuleHarnessProfileRoot) did not validate any Kad contact within $TimeoutSeconds seconds"
}

function Get-HarnessLoopbackBootstrapReadyEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HarnessSession
    )

    if (-not (Test-Path -LiteralPath $HarnessSession.VerboseLogPath)) {
        return $null
    }

    $verboseLines = @(Get-Content -LiteralPath $HarnessSession.VerboseLogPath)
    $portLine = $verboseLines |
        Where-Object { $_ -match 'Received possible external Kad Port ' } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($portLine)) {
        return $null
    }

    $bootstrapLine = $verboseLines |
        Where-Object { $_ -match 'Inc Kad2 Bootstrap Packet from ' } |
        Select-Object -Last 1
    if (-not [string]::IsNullOrWhiteSpace($bootstrapLine)) {
        return [pscustomobject]@{
            MatchedLine = $bootstrapLine
        }
    }

    $suppressedAckLine = $verboseLines |
        Where-Object { $_ -match 'Parity harness loopback suppressed HELLO_RES ACK request' } |
        Select-Object -Last 1
    if (-not [string]::IsNullOrWhiteSpace($suppressedAckLine)) {
        return [pscustomobject]@{
            MatchedLine = $suppressedAckLine
        }
    }

    $null
}

function Get-HarnessKadFailureFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HarnessSession
    )

    if (-not (Test-Path -LiteralPath $HarnessSession.VerboseLogPath)) {
        return $null
    }

    $verboseLines = @(Get-Content -LiteralPath $HarnessSession.VerboseLogPath)
    $senderKeyLine = $verboseLines |
        Where-Object { $_ -match "Process_KADEMLIA2_HELLO_RES: Remote clients demands ACK, but didn't send any Senderkey!" } |
        Select-Object -Last 1
    if (-not [string]::IsNullOrWhiteSpace($senderKeyLine)) {
        return [ordered]@{
            code = "hello_res_ack_missing_senderkey"
            stage = "hello_res"
            evidenceLine = $senderKeyLine
        }
    }

    $bootstrapPacketLine = $verboseLines |
        Where-Object { $_ -match 'Inc Kad2 Bootstrap Packet from ' } |
        Select-Object -Last 1
    if (-not [string]::IsNullOrWhiteSpace($bootstrapPacketLine)) {
        return [ordered]@{
            code = "bootstrap_seen_without_contact_validation"
            stage = "bootstrap"
            evidenceLine = $bootstrapPacketLine
        }
    }

    $kadStartLine = $verboseLines |
        Where-Object { $_ -match 'Starting Kademlia' } |
        Select-Object -Last 1
    if (-not [string]::IsNullOrWhiteSpace($kadStartLine)) {
        return [ordered]@{
            code = "kad_started_without_contact_validation"
            stage = "startup"
            evidenceLine = $kadStartLine
        }
    }

    $null
}

function Get-HarnessKadObservations {
    param(
        [pscustomobject[]]$HarnessSessions = @()
    )

    @(
        foreach ($session in @($HarnessSessions)) {
            $fingerprint = Get-HarnessKadFailureFingerprint -HarnessSession $session
            [ordered]@{
                sessionDir = $session.SessionDir
                profileRoot = $session.EmuleHarnessProfileRoot
                firstDivergence = $fingerprint
            }
        }
    )
}

function Select-ScenarioFirstDivergence {
    param(
        [object[]]$HarnessKadObservations = @()
    )

    foreach ($code in @(
        "hello_res_ack_missing_senderkey",
        "bootstrap_seen_without_contact_validation",
        "kad_started_without_contact_validation"
    )) {
        $match = $HarnessKadObservations |
            Where-Object { $null -ne $_.firstDivergence -and [string]$_.firstDivergence.code -eq $code } |
            Select-Object -First 1
        if ($null -ne $match) {
            return [ordered]@{
                code = [string]$match.firstDivergence.code
                stage = [string]$match.firstDivergence.stage
                evidenceLine = [string]$match.firstDivergence.evidenceLine
                sessionDir = [string]$match.sessionDir
                profileRoot = [string]$match.profileRoot
            }
        }
    }

    $null
}

function Invoke-AgentManualPublishWhenReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ControlUrl,
        [Parameter(Mandatory = $true)]
        [string]$Ed2kHash,
        [Parameter(Mandatory = $true)]
        [string]$CanonicalName,
        [Parameter(Mandatory = $true)]
        [UInt64]$Size,
        [UInt32]$SourceCount = 1,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            Post-AgentSeedPopular `
                -Ed2kHash $Ed2kHash `
                -CanonicalName $CanonicalName `
                -Size $Size `
                -SourceCount $SourceCount `
                -ControlUrl $ControlUrl | Out-Null
            return
        }
        catch {
            $lastError = $_
            $message = [string]$_.Exception.Message
            if (
                $message -notmatch 'kad node is not bootstrapped yet' -and
                $message -notmatch '\b501\b'
            ) {
                throw
            }
        }

        Start-Sleep -Seconds 2
    }

    if ($null -ne $lastError) {
        throw $lastError
    }

    throw "Agent manual Kad publish did not become ready within $TimeoutSeconds seconds"
}

function Get-HarnessPublishSummary {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HarnessSession
    )

    $tracePattern = 'event=(publish_|search_storefile_prepare|search_storekeyword_prepare|search_storesource_prepare)'
    $verbosePattern = 'eMule harness publish gate ready|eMule harness publish start family='
    $traceLines = @(Get-NewHarnessTraceLines -HarnessSession $HarnessSession)
    $tracePublishLines = @($traceLines | Where-Object { $_ -match $tracePattern })
    $verbosePublishLines = @()
    if (Test-Path -LiteralPath $HarnessSession.VerboseLogPath) {
        $verbosePublishLines = @(
            Get-Content -LiteralPath $HarnessSession.VerboseLogPath |
                Where-Object { $_ -match $verbosePattern }
        )
    }

    [pscustomobject]@{
        TraceLineCount = $traceLines.Count
        PublishLineCount = $tracePublishLines.Count + $verbosePublishLines.Count
        TracePublishLineCount = $tracePublishLines.Count
        VerbosePublishLineCount = $verbosePublishLines.Count
    }
}

function Wait-AgentManualPublish {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatsUrl,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $stats = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 10
            $observability = $stats.publish_observability
            if (
                $null -ne $observability -and
                $null -ne $observability.last_seed_source -and
                [string]$observability.last_seed_source -eq "manual_api" -and
                $null -ne $observability.latest_keyword_batch -and
                [int]$observability.latest_keyword_batch.attempted_contacts -gt 0
            ) {
                return $stats
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }

    throw "Agent manual Kad publish did not become observable at $StatsUrl within $TimeoutSeconds seconds"
}

function Invoke-CoordinatorSearchJob {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CoordinatorUrl,
        [Parameter(Mandatory = $true)]
        [object]$SearchPayload
    )

    $response = Invoke-WebRequest `
        -Method Post `
        -Uri ("{0}/api/search" -f $CoordinatorUrl.TrimEnd("/")) `
        -ContentType "application/json" `
        -Body ($SearchPayload | ConvertTo-Json -Depth 8) `
        -TimeoutSec 30 `
        -SkipHttpErrorCheck

    $responseBodyText = [string]$response.Content
    $responseBody = $null
    if (-not [string]::IsNullOrWhiteSpace($responseBodyText)) {
        try {
            $responseBody = $responseBodyText | ConvertFrom-Json
        }
        catch {
        }
    }

    if ([int]$response.StatusCode -ge 400) {
        $errorMessage = if ($null -ne $responseBody -and $null -ne $responseBody.error -and -not [string]::IsNullOrWhiteSpace([string]$responseBody.error)) {
            [string]$responseBody.error
        }
        elseif (-not [string]::IsNullOrWhiteSpace($responseBodyText)) {
            $responseBodyText.Trim()
        }
        else {
            "unexpected empty error response"
        }

        throw "Coordinator search creation failed with HTTP $($response.StatusCode): $errorMessage"
    }

    if ($null -ne $responseBody) {
        return $responseBody
    }

    throw "Coordinator search creation returned HTTP $($response.StatusCode) without a JSON body"
}

function Test-TransientCoordinatorSearchCreationFailure {
    param(
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    return (
        $Message -match 'Coordinator search creation failed with HTTP 503:' -or
        $Message -match "Can't reach database server at 127\.0\.0\.1:5432" -or
        $Message -match 'no ready kad2 agents'
    )
}

function Get-CoordinatorSearchJob {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CoordinatorUrl,
        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    Invoke-RestMethod -Uri ("{0}/api/search/{1}" -f $CoordinatorUrl.TrimEnd("/"), $JobId) -TimeoutSec 10
}

function Get-SearchMatchedNames {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$SearchJob
    )

    $names = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($SearchJob.results)) {
        foreach ($name in @($record.names)) {
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [void]$names.Add([string]$name)
            }
        }
    }

    return @($names | Sort-Object)
}

function Test-SearchContainsRequiredFiles {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$SearchJob,
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredFileNames,
        [int]$ExpectedMinimumResults = 0,
        [string]$SearchKind = "keyword",
        [string]$ExpectedFileHash,
        [UInt64]$ExpectedFileSize = 0
    )

    if ([int]$SearchJob.result_count -lt $ExpectedMinimumResults) {
        return $false
    }

    if ($SearchKind -in @("source", "notes") -and -not [string]::IsNullOrWhiteSpace($ExpectedFileHash)) {
        foreach ($record in @($SearchJob.results)) {
            $recordMatchesHash = @($record.hashes) | Where-Object {
                [string]$_.kind -eq "ed2k" -and [string]$_.value -eq $ExpectedFileHash
            } | Select-Object -First 1
            if ($null -eq $recordMatchesHash) {
                continue
            }

            if ($ExpectedFileSize -gt 0 -and [UInt64]$record.size -ne $ExpectedFileSize) {
                continue
            }

            return $true
        }

        return $false
    }

    $matchedNames = Get-SearchMatchedNames -SearchJob $SearchJob
    foreach ($requiredFileName in $RequiredFileNames) {
        if ($requiredFileName -notin $matchedNames) {
            return $false
        }
    }

    return $true
}

function Wait-CoordinatorSearchResultSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CoordinatorUrl,
        [Parameter(Mandatory = $true)]
        [string]$JobId,
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredFileNames,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedMinimumResults,
        [string]$SearchKind = "keyword",
        [string]$ExpectedFileHash,
        [UInt64]$ExpectedFileSize = 0,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastJob = $null
    while ((Get-Date) -lt $deadline) {
        $lastJob = Get-CoordinatorSearchJob -CoordinatorUrl $CoordinatorUrl -JobId $JobId
        if (
            Test-SearchContainsRequiredFiles `
                -SearchJob $lastJob `
                -RequiredFileNames $RequiredFileNames `
                -ExpectedMinimumResults $ExpectedMinimumResults `
                -SearchKind $SearchKind `
                -ExpectedFileHash $ExpectedFileHash `
                -ExpectedFileSize $ExpectedFileSize
        ) {
            return $lastJob
        }

        if (@("failed", "cancelled") -contains [string]$lastJob.status) {
            break
        }

        Start-Sleep -Seconds 2
    }

    if ($null -ne $lastJob) {
        return $lastJob
    }

    throw "Coordinator search job $JobId did not become readable"
}

function Copy-IfExists {
    param(
        [string]$Path,
        [string]$DestinationRoot
    )

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Copy-Item -LiteralPath $Path -Destination (Join-Path $DestinationRoot (Split-Path -Leaf $Path)) -Force
    }
}

$toolingRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifest = Get-Content -Raw $ScenarioManifestPath | ConvertFrom-Json
$agentBootstrapReadyContacts = if ($null -ne $manifest.agent.bootstrapReadyContacts) {
    [int]$manifest.agent.bootstrapReadyContacts
}
else {
    10
}
$seedNotesPublishEnabledProperty = $manifest.agent.PSObject.Properties["seedNotesPublishEnabled"]
$seedNotesPublishEnabled = $null -ne $seedNotesPublishEnabledProperty -and [bool]$seedNotesPublishEnabledProperty.Value

if (-not $env:OVERLORD_TMP_DIR) {
    throw "OVERLORD_TMP_DIR is not set"
}
if (-not $env:OVERLORD_LOG_DIR) {
    throw "OVERLORD_LOG_DIR is not set"
}
if (-not $env:OVERLORD_PROJECT_DIR) {
    throw "OVERLORD_PROJECT_DIR is not set"
}

$runId = "{0}-{1}" -f $manifest.scenarioId, (Get-Date -Format "yyyyMMdd-HHmmss")
$artifactRoot = Join-Path $env:OVERLORD_TMP_DIR ("overlord-tooling\runs\{0}\{1}" -f $manifest.scenarioId, $runId)
$harnessArtifactRoot = Join-Path $artifactRoot "harnesses"
$agentArtifactRoot = Join-Path $artifactRoot "agent"
$coordinatorArtifactRoot = Join-Path $artifactRoot "coordinator"
$runManifestPath = Join-Path $artifactRoot "run-manifest.json"
$runSummaryPath = Join-Path $artifactRoot "run-summary.json"
$searchResultPath = Join-Path $artifactRoot "search-result.json"
$agentStatsPath = Join-Path $artifactRoot "agent-stats.json"

foreach ($path in @($artifactRoot, $harnessArtifactRoot, $agentArtifactRoot, $coordinatorArtifactRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$profileScriptPath = Join-Path $toolingRoot "profiles\New-EmuleHarnessPrivateEd2kProfile.ps1"
$coordinatorStartScriptPath = Join-Path $env:OVERLORD_PROJECT_DIR "p2p-overlord-be\overlord-be-coordinator\scripts\windows\coordinator_run_start_direct.cmd"

foreach ($requiredPath in @($profileScriptPath, $coordinatorStartScriptPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required scenario helper not found at $requiredPath"
    }
}

$buildUsedFallback = $false
$buildFallbackReason = $null
Build-EmuleHarnessDebug | Out-Null

Clean-EmuleHarnessRuntime -CapturePort 0 | Out-Null

$preexistingCoordinatorPids = @(
    Get-CoordinatorProcesses | ForEach-Object { [int]$_.ProcessId }
)
$startedCoordinatorPids = @()
$harnessProfiles = @()
$harnessSessions = @()
$harnessPublishSummaries = @()
$harnessContactSummaries = @()
$harnessLinkRecords = @()
$harnessKadObservations = @()
$agentSession = $null
$agentStats = $null
$searchAttempts = @()
$successfulSearch = $null
$failedReason = $null

$runManifest = [ordered]@{
    schemaVersion = "run-manifest/v1"
    scenarioId = $manifest.scenarioId
    runId = $runId
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    artifactRoot = $artifactRoot
    coordinatorUrl = $manifest.coordinator.url
    searchRequest = $manifest.search
    harnessCount = @($manifest.harnesses).Count
}
$runManifest | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8NoBOM $runManifestPath

try {
    if ($preexistingCoordinatorPids.Count -eq 0) {
        Start-Process `
            -FilePath "cmd.exe" `
            -ArgumentList "/c", $coordinatorStartScriptPath `
            -WorkingDirectory $env:OVERLORD_PROJECT_DIR `
            -WindowStyle Hidden | Out-Null
    }

    Wait-CoordinatorReady -CoordinatorUrl $manifest.coordinator.url -TimeoutSeconds 120
    if ($preexistingCoordinatorPids.Count -eq 0) {
        $startedCoordinatorPids = @(
            Get-CoordinatorProcesses |
                Where-Object { $_.ProcessId -notin $preexistingCoordinatorPids } |
                ForEach-Object { [int]$_.ProcessId }
        )
    }

    foreach ($harness in @($manifest.harnesses)) {
        $profileRoot = Join-Path $artifactRoot $harness.id
        $seedPath = Join-Path $profileRoot ("Incoming\{0}" -f $harness.seedFileName)
        $linkPath = Join-Path $profileRoot "seed.ed2k"

        $profile = & $profileScriptPath `
            -ProfileRoot $profileRoot `
            -BindAddr $harness.bindAddr `
            -TcpPort ([UInt16]$harness.tcpPort) `
            -UdpPort ([UInt16]$harness.udpPort) `
            -ServerUdpPort ([UInt16]$harness.serverUdpPort) `
            -WebPort ([UInt16]$harness.webPort) `
            -KadUdpKey ([UInt32]$harness.kadUdpKey) `
            -KadIdHex $harness.kadIdHex `
            -EnableKademlia $true `
            -EnableEd2k $false `
            -ResetTransientState

        New-SeedPdfFile -Path $seedPath -MarkerText $harness.markerText -RepeatCount ([int]$harness.seedRepeatCount)

        $startParams = @{
            ProfileRoot = $profile.ProfileRoot
            SeedFilePath = $seedPath
            ExportLinkPath = $linkPath
            AgentBootstrapNode = [string]$harness.bootstrapPeers
            BuildConfig = $HarnessBuildConfig
            SkipRuntimeCleanup = $true
        }
        $session = Start-EmuleHarnessPrivateEd2kSession @startParams

        $harnessProfiles += $profile
        $harnessSessions += $session
        Wait-Path -Path $linkPath -TimeoutSeconds 60
        $parsedLinkRecord = Parse-Ed2kLinkFile -Path $linkPath
        $harnessLinkRecords += [pscustomobject]@{
            HarnessId = [string]$harness.id
            Link = [string]$parsedLinkRecord.Link
            FileName = [string]$parsedLinkRecord.FileName
            FileSize = [UInt64]$parsedLinkRecord.FileSize
            FileHash = [string]$parsedLinkRecord.FileHash
        }
    }

    foreach ($session in @($harnessSessions)) {
        $harnessContactSummaries += (Wait-HarnessContactReady -HarnessSession $session -TimeoutSeconds $HarnessContactTimeoutSeconds)
    }

    if ($HarnessPublishSettleSeconds -gt 0) {
        Start-Sleep -Seconds $HarnessPublishSettleSeconds
    }

    $firstHarnessBootstrap = "{0}:{1}" -f $manifest.harnesses[0].bindAddr, [UInt16]$manifest.harnesses[0].udpPort
    $agentSession = Start-AgentPrivateEd2kSession `
        -ScenarioRoot (Join-Path $artifactRoot "agent-runtime") `
        -EmuleHarnessBootstrapNode $firstHarnessBootstrap `
        -ControlPort ([UInt16]$manifest.agent.controlPort) `
        -KadPort ([UInt16]$manifest.agent.kadPort) `
        -Ed2kPort ([UInt16]$manifest.agent.ed2kPort) `
        -P2pBindIp $manifest.agent.p2pBindIp `
        -KadBootstrapReadyContacts ([UInt32]$agentBootstrapReadyContacts) `
        -EnableKadNotesPublish:$seedNotesPublishEnabled

    $agentStats = Wait-AgentControlReady -StatsUrl $agentSession.StatsUrl -TimeoutSeconds 180
    $agentStats = Wait-AgentKadBootstrapReady `
        -StatsUrl $agentSession.StatsUrl `
        -TimeoutSeconds 180 `
        -MinimumPeersConnected $agentBootstrapReadyContacts

    Invoke-AgentManualPublishWhenReady `
        -Ed2kHash $manifest.agent.manualPublish.hash `
        -CanonicalName $manifest.agent.manualPublish.canonicalName `
        -Size ([UInt64]$manifest.agent.manualPublish.size) `
        -SourceCount ([UInt32]$manifest.agent.manualPublish.sourceCount) `
        -ControlUrl $agentSession.ControlUrl `
        -TimeoutSeconds $AgentPublishTimeoutSeconds

    $agentStats = Wait-AgentManualPublish -StatsUrl $agentSession.StatsUrl -TimeoutSeconds $AgentPublishTimeoutSeconds
    $agentStats | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8NoBOM $agentStatsPath

    foreach ($session in @($harnessSessions)) {
        $harnessPublishSummaries += (Get-HarnessPublishSummary -HarnessSession $session)
    }

    $searchDefinition = Resolve-ScenarioSearchDefinition -Manifest $manifest -HarnessLinkRecords $harnessLinkRecords
    [string[]]$requiredFileNames = @(
        @($searchDefinition.RequiredFileNames) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if (@($requiredFileNames).Count -eq 0 -and [string]$searchDefinition.Kind -eq "keyword") {
        $requiredFileNames = @(
            @($harnessLinkRecords) |
                ForEach-Object { [string]$_.FileName } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    if (@($requiredFileNames).Count -eq 0) {
        throw "Scenario search required file list resolved to zero names for kind '$($searchDefinition.Kind)'"
    }
    for ($attempt = 1; $attempt -le [int]$manifest.search.retryCount; $attempt++) {
        $searchJob = $null
        try {
            $searchJob = Invoke-CoordinatorSearchJob `
                -CoordinatorUrl $manifest.coordinator.url `
                -SearchPayload $searchDefinition.Payload
        }
        catch {
            $attemptRecord = [ordered]@{
                attempt = $attempt
                jobId = $null
                status = "create_failed"
                resultCount = 0
                matchedNames = @()
                error = $_.Exception.Message
            }
            $searchAttempts += [pscustomobject]$attemptRecord

            if ($attempt -lt [int]$manifest.search.retryCount -and (Test-TransientCoordinatorSearchCreationFailure -Message $_.Exception.Message)) {
                Start-Sleep -Seconds $SearchRetryDelaySeconds
                continue
            }

            throw
        }

        $finalJob = Wait-CoordinatorSearchResultSet `
            -CoordinatorUrl $manifest.coordinator.url `
            -JobId $searchJob.job_id `
            -RequiredFileNames $requiredFileNames `
            -ExpectedMinimumResults ([int]$manifest.search.expectedMinimumResults) `
            -SearchKind $searchDefinition.Kind `
            -ExpectedFileHash $searchDefinition.FileHash `
            -ExpectedFileSize $(if ($null -ne $searchDefinition.FileSize) { [UInt64]$searchDefinition.FileSize } else { [UInt64]0 }) `
            -TimeoutSeconds $SearchTimeoutSeconds

        $attemptRecord = [ordered]@{
            attempt = $attempt
            jobId = $searchJob.job_id
            status = $finalJob.status
            resultCount = $finalJob.result_count
            matchedNames = @(Get-SearchMatchedNames -SearchJob $finalJob)
            error = $null
        }
        $searchAttempts += [pscustomobject]$attemptRecord

        if (
            Test-SearchContainsRequiredFiles `
                -SearchJob $finalJob `
                -RequiredFileNames $requiredFileNames `
                -ExpectedMinimumResults ([int]$manifest.search.expectedMinimumResults) `
                -SearchKind $searchDefinition.Kind `
                -ExpectedFileHash $searchDefinition.FileHash `
                -ExpectedFileSize $(if ($null -ne $searchDefinition.FileSize) { [UInt64]$searchDefinition.FileSize } else { [UInt64]0 })
        ) {
            $successfulSearch = $finalJob
            break
        }

        if ($attempt -lt [int]$manifest.search.retryCount) {
            Start-Sleep -Seconds $SearchRetryDelaySeconds
        }
    }

    if ($null -eq $successfulSearch) {
        throw "Coordinator $($searchDefinition.Kind) search never returned the expected result set"
    }

    $successfulSearch | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8NoBOM $searchResultPath

    for ($index = 0; $index -lt $harnessSessions.Count; $index++) {
        $session = $harnessSessions[$index]
        $destinationRoot = Join-Path $harnessArtifactRoot ([string]$manifest.harnesses[$index].id)
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null

        $traceSlicePath = Join-Path $destinationRoot "harness-trace-new.log"
        (Get-NewHarnessTraceLines -HarnessSession $session) | Set-Content -Encoding utf8NoBOM $traceSlicePath

        foreach ($path in @(
            $session.ExportLinkPath,
            $session.TraceLogPath,
            $session.VerboseLogPath,
            $session.StatusLogPath,
            $session.EmuleHarnessUdpDumpPath,
            $session.EmuleHarnessEd2kTcpDumpPath
        )) {
            Copy-IfExists -Path $path -DestinationRoot $destinationRoot
        }
    }

    foreach ($path in @(
        (Join-Path $agentSession.LogRoot "overlord-agent-emule.log"),
        (Get-ChildItem -LiteralPath $agentSession.LogRoot -Filter "agent-udp-dump-*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem -LiteralPath $agentSession.LogRoot -Filter "agent-ed2k-tcp-dump-*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1 -ExpandProperty FullName),
        $agentStatsPath,
        $searchResultPath
    )) {
        Copy-IfExists -Path $path -DestinationRoot $agentArtifactRoot
    }

    foreach ($logPath in @(
        (Join-Path $env:OVERLORD_LOG_DIR "coordinator_stdout.log"),
        (Join-Path $env:OVERLORD_LOG_DIR "coordinator_stderr.log"),
        (Join-Path $env:OVERLORD_LOG_DIR "coordinator_server.log")
    )) {
        Copy-IfExists -Path $logPath -DestinationRoot $coordinatorArtifactRoot
    }

    $runSummary = [ordered]@{
        schemaVersion = "run-summary/v1"
        scenarioId = $manifest.scenarioId
        runId = $runId
        completed = $true
        coordinatorStartedByScenario = [bool]($startedCoordinatorPids.Count -gt 0)
        harnessBuildUsedFallback = $buildUsedFallback
        harnessBuildFallbackReason = $buildFallbackReason
        harnessContactLines = @($harnessContactSummaries | ForEach-Object { $_.MatchedLine })
        harnessPublishLineCounts = @($harnessPublishSummaries | ForEach-Object { $_.PublishLineCount })
        harnessFiles = @($harnessLinkRecords | ForEach-Object {
            [ordered]@{
                name = $_.FileName
                hash = $_.FileHash
                size = $_.FileSize
            }
        })
        agentPublish = [ordered]@{
            lastSeedSource = $agentStats.publish_observability.last_seed_source
            keywordPublishedItems = $agentStats.publish_observability.latest_keyword_batch.published_items
            keywordAttemptedContacts = $agentStats.publish_observability.latest_keyword_batch.attempted_contacts
            keywordAckedContacts = $agentStats.publish_observability.latest_keyword_batch.acked_contacts
            sourcePublishedItems = $agentStats.publish_observability.latest_source_batch.published_items
            sourceAttemptedContacts = $agentStats.publish_observability.latest_source_batch.attempted_contacts
            sourceAckedContacts = $agentStats.publish_observability.latest_source_batch.acked_contacts
        }
        search = [ordered]@{
            kind = $searchDefinition.Kind
            query = $searchDefinition.Query
            fileHash = $searchDefinition.FileHash
            fileSize = $searchDefinition.FileSize
            targetRef = $searchDefinition.TargetRef
            attempts = @($searchAttempts)
            finalJobId = $successfulSearch.job_id
            finalStatus = $successfulSearch.status
            finalResultCount = $successfulSearch.result_count
            matchedNames = @(Get-SearchMatchedNames -SearchJob $successfulSearch)
        }
        harnessKadObservations = @($harnessKadObservations)
        firstDivergence = $null
        finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $runSummary | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    $runSummary
}
catch {
    $failedReason = $_.Exception.Message
    throw
}
finally {
    $harnessKadObservations = Get-HarnessKadObservations -HarnessSessions $harnessSessions

    if (-not $KeepSessionsRunning) {
        foreach ($session in @($harnessSessions)) {
            Stop-EmuleHarnessParitySession -SessionDir $session.SessionDir | Out-Null
        }

        if ($agentSession) {
            Stop-AgentParitySession -SessionDir $agentSession.SessionDir | Out-Null
            if ($agentSession.ConfigBackupPath -and (Test-Path -LiteralPath $agentSession.ConfigBackupPath)) {
                Copy-Item -LiteralPath $agentSession.ConfigBackupPath -Destination $agentSession.ConfigPath -Force
            }
        }

        foreach ($coordinatorPid in @($startedCoordinatorPids)) {
            Stop-Process -Id $coordinatorPid -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $runSummaryPath)) {
        $failedSummary = [ordered]@{
            schemaVersion = "run-summary/v1"
            scenarioId = $manifest.scenarioId
            runId = $runId
            completed = $false
            coordinatorStartedByScenario = [bool]($startedCoordinatorPids.Count -gt 0)
            harnessBuildUsedFallback = $buildUsedFallback
            harnessBuildFallbackReason = $buildFallbackReason
            failedReason = $failedReason
            harnessKadObservations = @($harnessKadObservations)
            firstDivergence = (Select-ScenarioFirstDivergence -HarnessKadObservations $harnessKadObservations)
            searchAttempts = @($searchAttempts)
            finishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $failedSummary | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8NoBOM $runSummaryPath
    }
}

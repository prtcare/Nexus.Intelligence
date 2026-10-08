# ProviderHealthReport.ps1 -- DB-M22 health/failover report export.
#
# Produces a deterministic, offline snapshot of provider-health evidence, the
# effective health of the requested routes, circuit states and (optionally) the
# failover decisions computed for them. It never executes a provider/model, never
# opens a network connection, and never invokes a paid AI API. AUTO_EXECUTION
# _ENABLED = FALSE. 0 paid API calls, 0 network calls.
#
# The report is BOM-less UTF-8 when written to disk (the DevBridge result-file
# convention). It is a read-only summary -- it changes nothing.

. (Join-Path $PSScriptRoot "ProviderHealthEngine.ps1")   # health contracts + engine (READ-ONLY)
. (Join-Path $PSScriptRoot "..\failover\FailoverEngine.ps1") # failover contracts + engine (READ-ONLY)

function Export-ProviderHealthReport {
    <#
    .SYNOPSIS
    Export a deterministic ProviderHealthReport v1: evidence inventory, per-route
    effective health + circuit state, and any provided failover decisions. Writes
    BOM-less UTF-8 when a -Path is given; otherwise returns the report object.
    #>
    param(
        [AllowNull()][object[]]$Evidence,
        [AllowNull()][pscustomobject]$Policy,
        $EvaluationTimestampUtc,
        [AllowNull()][object[]]$Routes,          # array of @{ProviderId;GatewayProviderId;UnderlyingModelId}
        [AllowNull()][object[]]$FailoverDecisions,
        [string]$Path,
        [AllowNull()][object[]]$EligibleCandidates,
        [AllowNull()][object[]]$RejectedCandidates
    )
    if ($null -eq $Policy) { $Policy = Get-DefaultProviderHealthPolicy }
    $ts = ConvertTo-DbM22Utc $EvaluationTimestampUtc
    if ($null -eq $ts) { throw "Export-ProviderHealthReport: EvaluationTimestampUtc is required" }

    $routeRows = New-Object System.Collections.ArrayList
    foreach ($r in @($Routes)) {
        if ($null -eq $r) { continue }
        $providerId = [string](Get-ContractProperty $r 'ProviderId' '')
        if (-not $providerId) { continue }
        $gatewayId = [string](Get-ContractProperty $r 'GatewayProviderId' '')
        $h = Get-EffectiveProviderHealth -Evidence $Evidence -Policy $Policy -EvaluationTimestampUtc $ts `
            -ProviderId $providerId -GatewayProviderId $gatewayId
        $avail = Test-ProviderRouteAvailable -Evidence $Evidence -Policy $Policy -EvaluationTimestampUtc $ts `
            -ProviderId $providerId -GatewayProviderId $gatewayId
        $null = $routeRows.Add([pscustomobject]@{
            ProviderId           = $providerId.ToLowerInvariant()
            GatewayProviderId    = $gatewayId.ToLowerInvariant()
            UnderlyingModelId    = [string](Get-ContractProperty $r 'UnderlyingModelId' '')
            RouteId              = $h.RouteId
            HealthState          = $h.HealthState
            CircuitState         = $h.CircuitState
            Available            = [bool]$avail.Available
            RequiresHuman        = [bool]$h.RequiresHuman
            RetryAfterUtc        = $h.RetryAfterUtc
            ReasonCodes          = @($h.ReasonCodes)
            EvidenceIds          = @($h.EvidenceIds)
            Message              = $h.Message
        })
    }
    $routeRows = @($routeRows | Sort-Object ProviderId, GatewayProviderId)

    $evidenceRows = New-Object System.Collections.ArrayList
    foreach ($e in @($Evidence)) {
        if ($null -eq $e) { continue }
        $null = $evidenceRows.Add([pscustomobject]@{
            EvidenceId         = [string](Get-ContractProperty $e 'EvidenceId' '')
            ProviderId         = [string](Get-ContractProperty $e 'ProviderId' '')
            RouteId            = [string](Get-ContractProperty $e 'RouteId' '')
            GatewayProviderId  = [string](Get-ContractProperty $e 'GatewayProviderId' '')
            UnderlyingModelId  = [string](Get-ContractProperty $e 'UnderlyingModelId' '')
            ObservedState      = [string](Get-ContractProperty $e 'ObservedState' '')
            EvidenceType       = [string](Get-ContractProperty $e 'EvidenceType' '')
            ObservedAtUtc      = Get-ContractProperty $e 'ObservedAtUtc' $null
            ExpiresAtUtc       = Get-ContractProperty $e 'ExpiresAtUtc' $null
            FailureCategory    = [string](Get-ContractProperty $e 'FailureCategory' '')
            RetryAfterUtc      = Get-ContractProperty $e 'RetryAfterUtc' $null
            Source             = [string](Get-ContractProperty $e 'Source' '')
            AttemptIdReference = [string](Get-ContractProperty $e 'AttemptIdReference' '')
        })
    }
    $evidenceRows = @($evidenceRows | Sort-Object ObservedAtUtc, EvidenceId)

    $decisionRows = New-Object System.Collections.ArrayList
    foreach ($d in @($FailoverDecisions)) {
        if ($null -eq $d) { continue }
        $null = $decisionRows.Add([pscustomobject]@{
            DecisionId             = [string](Get-ContractProperty $d 'DecisionId' '')
            OriginalProviderId     = [string](Get-ContractProperty $d 'OriginalProviderId' '')
            OriginalRouteId        = [string](Get-ContractProperty $d 'OriginalRouteId' '')
            OriginalHealthState    = [string](Get-ContractProperty $d 'OriginalHealthState' '')
            Action                 = [string](Get-ContractProperty $d 'Action' '')
            RecommendedProviderId  = [string](Get-ContractProperty $d 'RecommendedProviderId' '')
            RecommendedRouteId     = [string](Get-ContractProperty $d 'RecommendedRouteId' '')
            ReasonCodes            = @(Get-ContractProperty $d 'ReasonCodes' @())
            RequiresHuman          = [bool](Get-ContractProperty $d 'RequiresHuman' $false)
            AutoExecutionEnabled   = [bool](Get-ContractProperty $d 'AutoExecutionEnabled' $true)
            GeneratedAtUtc         = Get-ContractProperty $d 'GeneratedAtUtc' $null
        })
    }
    $decisionRows = @($decisionRows | Sort-Object GeneratedAtUtc, DecisionId)

    # NOTE: `@($nullVariable)` yields $null -- not an array -- under StrictMode, so a
    # bare `@($EligibleCandidates).Count` throws when the param is unbound. Normalize
    # with an explicit null guard; an absent list counts as zero.
    $eligibleCandidateCount = 0
    if ($null -ne $EligibleCandidates) { $eligibleCandidateCount = @($EligibleCandidates).Count }
    $rejectedCandidateCount = 0
    if ($null -ne $RejectedCandidates) { $rejectedCandidateCount = @($RejectedCandidates).Count }

    $report = [pscustomobject]@{
        SchemaVersion           = 1
        ReportId                = 'PH-' + (Get-DbM22Sha256Hex "$($ts.ToString('o'))|$(($evidenceRows | ForEach-Object { $_.EvidenceId }) -join ',')").Substring(0, 16)
        PolicyId                = Get-ContractProperty $Policy 'PolicyId' $null
        GeneratedAtUtc          = $ts
        EvidenceCount           = $evidenceRows.Count
        Evidence                = $evidenceRows
        RouteCount              = $routeRows.Count
        Routes                  = $routeRows
        FailoverDecisionCount   = $decisionRows.Count
        FailoverDecisions       = $decisionRows
        EligibleCandidateCount  = $eligibleCandidateCount
        RejectedCandidateCount  = $rejectedCandidateCount
        NetworkCalls            = 0
        PaidApiCalls            = 0
        AutoExecutionEnabled    = $false
        Message                 = 'offline deterministic health/failover snapshot; nothing executed'
    }

    if ($Path) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $json = $report | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $report
}

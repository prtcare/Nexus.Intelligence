# RoutingPerformance.ps1 -- DB-M19 STEP 4 (historical performance evidence).
#
# Performance is NON-BINDING evidence for ranking. This layer builds a DB-M24
# PerformanceQuery v1 filtered to the candidate route (+ task dimensions) and
# reads the DB-M24 ModelPerformanceSummary (VERIFIED_PREFERRED success
# definition -- a self-reported SUCCESS whose independent verification FAILED
# does not count). Confidence INSUFFICIENT gives the evidence little/no ranking
# power (historical component scores are zeroed by the ranker).

. (Join-Path $PSScriptRoot "..\AiRoutingContracts.ps1")   # DB-M14 vocab + helpers (READ-ONLY)
. (Join-Path $PSScriptRoot "RoutingEligibility.ps1")

function Get-DbM19ConfidenceOrder {
    return @{ INSUFFICIENT = 0; LOW = 1; MODERATE = 2; HIGH = 3 }
}

function Get-AiCandidatePerformanceEvidence {
    <#
    .SYNOPSIS
    STEP 4. Historical performance evidence for one eligible model route from the
    DB-M24 engine. Returns the ModelPerformanceSummary plus a deterministic
    evidence reference and a ConfidenceSufficient flag (DB-M24 confidence >= the
    policy's MinimumConfidenceForHistoricalWeight). Cold start (no records) is a
    valid result: HasEvidence=$false, ConfidenceLevel INSUFFICIENT.
    #>
    param(
        [AllowNull()][pscustomobject]$Model,
        [AllowNull()][object]$Requirement,
        [AllowNull()][object]$Classification,
        [AllowNull()][object[]]$PerformanceRecords,
        [string]$ReasoningLevel,
        [string]$MinimumConfidenceForHistoricalWeight = 'LOW',
        [string]$ReportingCurrency = 'INR'
    )
    $providerId = Get-ContractProperty $Model 'ProviderId' ''
    $modelId = Get-ContractProperty $Model 'ModelId' ''
    $underlyingId = Get-ContractProperty $Model 'UnderlyingModelId' $null
    $gatewayId = Get-ContractProperty $Model 'GatewayProviderId' $null

    # task dimensions: preference to the classification, fallback to the requirement
    $taskType = $null
    $complexity = $null
    $risk = $null
    if ($null -ne $Classification) {
        $taskType = Get-ContractProperty $Classification 'TaskType' $null
        $complexity = Get-ContractProperty $Classification 'Complexity' $null
        $risk = Get-ContractProperty $Classification 'Risk' $null
    }
    if (-not $taskType) { $taskType = Get-ContractProperty $Requirement 'TaskType' $null }
    if (-not $complexity) { $complexity = Get-ContractProperty $Requirement 'Complexity' $null }
    if (-not $risk) { $risk = Get-ContractProperty $Requirement 'Risk' $null }

    $routeKey = "$($providerId.ToLowerInvariant())/$($modelId.ToLowerInvariant())"
    $queryId = "PERF-DB-M19-$($routeKey.Replace('/','-'))"

    $query = New-AiPerformanceQuery -QueryId $queryId -ProviderId $providerId -ModelId $modelId `
        -UnderlyingModelId $underlyingId -GatewayProviderId $gatewayId `
        -TaskType $taskType -Complexity $complexity -Risk $risk -ReasoningLevel $ReasoningLevel `
        -ReportingCurrency $ReportingCurrency -SuccessDefinition 'VERIFIED_PREFERRED'

    $summary = $null
    if ($null -ne $PerformanceRecords -and $PerformanceRecords.Count -gt 0) {
        $summaries = @(Get-AiModelPerformance -Records $PerformanceRecords -Query $query)
        if ($summaries.Count -gt 0) { $summary = $summaries[0] }
    }

    $sampleCount = 0
    if ($null -ne $summary) { $sampleCount = [long](Get-ContractProperty $summary 'SampleCount' 0) }
    $hasEvidence = ($null -ne $summary -and $sampleCount -gt 0)

    $confidence = if ($hasEvidence) { [string](Get-ContractProperty $summary 'ConfidenceLevel' 'INSUFFICIENT') } else { 'INSUFFICIENT' }

    $minConf = $MinimumConfidenceForHistoricalWeight
    if (-not $minConf) { $minConf = 'LOW' }
    $minConf = $minConf.Trim().ToUpperInvariant()
    $order = Get-DbM19ConfidenceOrder
    $confIdx = $order[$confidence]
    $minIdx = $order[$minConf]
    if ($null -eq $confIdx) { $confIdx = 0 }
    if ($null -eq $minIdx) { $minIdx = 0 }
    $confidenceSufficient = ($confIdx -ge $minIdx)

    $evidenceRef = "DB-M24/ModelPerformance/$routeKey/tasktype=$(if ($taskType) { $taskType } else { 'ALL' })/complexity=$(if ($complexity) { $complexity } else { 'ALL' })/risk=$(if ($risk) { $risk } else { 'ALL' })/reasoning=$(if ($ReasoningLevel) { $ReasoningLevel } else { 'ALL' })"

    return @{
        HasEvidence                   = $hasEvidence
        Summary                       = $summary
        Query                         = $query
        ConfidenceLevel               = $confidence
        ConfidenceSufficient          = $confidenceSufficient
        MinimumConfidenceForHistoricalWeight = $minConf
        SampleCount                   = $sampleCount
        SuccessRate                   = if ($hasEvidence) { Get-ContractProperty $summary 'SuccessRate' $null } else { $null }
        FirstAttemptSuccessRate       = if ($hasEvidence) { Get-ContractProperty $summary 'FirstAttemptSuccessRate' $null } else { $null }
        AverageCostPerSuccessfulTask  = if ($hasEvidence) { Get-ContractProperty $summary 'AverageCostPerSuccessfulTask' $null } else { $null }
        AverageCostPerAttempt         = if ($hasEvidence) { Get-ContractProperty $summary 'AverageCostPerAttempt' $null } else { $null }
        AverageDurationMs             = if ($hasEvidence) { Get-ContractProperty $summary 'AverageDurationMs' $null } else { $null }
        EscalationRate                = if ($hasEvidence) { Get-ContractProperty $summary 'EscalationRate' $null } else { $null }
        VerifiedSuccessCount          = if ($hasEvidence) { Get-ContractProperty $summary 'VerifiedSuccessCount' 0 } else { 0 }
        ModelReturnedSuccessCount     = if ($hasEvidence) { Get-ContractProperty $summary 'ModelReturnedSuccessCount' 0 } else { 0 }
        ReportingCurrency             = if ($hasEvidence) { Get-ContractProperty $summary 'ReportingCurrency' $ReportingCurrency } else { $ReportingCurrency }
        PerformanceEvidenceReference  = $evidenceRef
    }
}

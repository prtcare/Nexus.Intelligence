# QualityCost.ps1 -- DB-M25 quality-adjusted cost + savings analytics engine.
#
# Answers the brief's question: "what is the real expected cost of obtaining a
# VERIFIED successful result?" -- not "which model is cheapest per attempt?".
# The unit of analysis is the attempt-chain cost per verified success (failed
# attempts + retries + escalation included), never the single attempt price.
#
# Contract + vocabulary ownership lives in AiQualityCostContracts.ps1 (DB-M25).
# The engine recomputes every metric from the AiAttemptRecord v1 (DB-M17)
# records passed in; it reads no database and writes nothing.
#
# Reuse is READ-ONLY:
#   DB-M24 AiPerformanceFoundation/ModelPerformance (chains, confidence, stats)
#   DB-M23 AdapterContracts (price statuses, secret guard)
#   DB-M17 attempt vocabulary (via the DB-M24 foundation)
#   DB-M14 shared helpers (Get-ContractProperty, vocabularies)
# No file owning those contracts is modified.
#
# AUTO_EXECUTION_ENABLED = FALSE. No AI/provider/paid/network calls, no policy
# mutation, no PR/merge, no workbook/Nexus writes. Evidence only for DB-M19.

# $script:PerfConfidenceBands is set by DB-M24 Import-AiPerformanceConfiguration
# when the test harness loads the performance configuration READ-ONLY.

# --- attempt classification -----------------------------------------------------

function Test-DbM25ExecutedAttempt {
    <#
    .SYNOPSIS
    True when the record represents a REAL paid/executed AI attempt. A record
    with cost evidence is executed regardless of its Result. Otherwise only
    Result SUCCESS / FAILED / ESCALATED are executed outcomes. BUDGET_STOPPED /
    BLOCKED / WAITING_HUMAN / PENDING / CANCELLED-without-cost are NOT executed:
    a budget block is never fabricated as an unsuccessful AI attempt, and a
    non-attempt never adds cost.
    #>
    param([AllowNull()][object]$Record)
    if ($null -eq $Record) { return $false }
    if ($null -ne (Get-ContractProperty $Record 'ActualCost' $null)) { return $true }
    if ($null -ne (Get-ContractProperty $Record 'EstimatedCost' $null)) { return $true }
    $res = [string](Get-ContractProperty $Record 'Result' '')
    if ($res -in @('SUCCESS', 'FAILED', 'ESCALATED')) { return $true }
    return $false
}

function Test-DbM25TerminalAttempt {
    <#
    .SYNOPSIS
    True when the record's Result is a terminal state (DB-M17 vocabulary).
    #>
    param([AllowNull()][object]$Record)
    if ($null -eq $Record) { return $false }
    $res = [string](Get-ContractProperty $Record 'Result' '')
    return ($res -in (Get-AiAttemptTerminalStates))
}

# --- cost evidence resolution ------------------------------------------------------

function Resolve-DbM25RecordCost {
    <#
    .SYNOPSIS
    Resolve ONE record's usable cost evidence under DB-M16/M25 semantics.
    ActualCost is preferred; EstimatedCost is used only when the query allows
    estimated-cost fallback; only attempts whose CostCurrency equals the
    reporting currency contribute (historic cost in another currency is NEVER
    re-converted). Non-executed records return Used=$false and never count as
    missing. Returns @{ Used; Amount; Source; ExcludedReason; Executed }.
    #>
    param($Record, [string]$ReportingCurrencyUpper = 'INR', [bool]$AllowEstimatedFallback = $false)
    $res = @{ Used = $false; Amount = 0d; Source = $null; ExcludedReason = $null; Executed = $false }
    $isExecuted = Test-DbM25ExecutedAttempt $Record
    $res.Executed = $isExecuted
    if (-not $isExecuted) { return $res }   # non-attempt: never adds cost, never missing

    $act = Get-ContractProperty $Record 'ActualCost' $null
    $est = Get-ContractProperty $Record 'EstimatedCost' $null
    $cc = Get-PerfString $Record 'CostCurrency'
    $currencyOk = ($cc -and ($cc.ToUpperInvariant() -eq $ReportingCurrencyUpper))

    if ($null -ne $act -and $currencyOk) {
        $res.Used = $true; $res.Amount = [double]$act; $res.Source = 'ACTUAL'
        return $res
    }
    if ($AllowEstimatedFallback -and $null -ne $est -and $currencyOk) {
        $res.Used = $true; $res.Amount = [double]$est; $res.Source = 'ESTIMATED'
        return $res
    }
    if (($null -ne $act -or $null -ne $est) -and -not $currencyOk) {
        $res.ExcludedReason = 'CURRENCY_MISMATCH'
        return $res
    }
    if ($null -ne $est -and -not $AllowEstimatedFallback) {
        $res.ExcludedReason = 'FALLBACK_DISABLED'
        return $res
    }
    $res.ExcludedReason = 'MISSING'
    return $res
}

function Get-DbM25ChainCost {
    <#
    .SYNOPSIS
    Chain cost = sum of usable cost evidence of every EXECUTED attempt in the
    chain. Non-attempts (BUDGET_STOPPED / BLOCKED / WAITING_HUMAN / PENDING)
    never add cost and never inflate the missing counters. The result also
    carries the per-category exclusion counts so the engine can report why
    cost evidence was not used.
    Returns @{ Total; Usable; ActualUsed; EstimatedUsed; Missing;
    CurrencyMismatch; FallbackDisabled }.
    #>
    param([AllowNull()][object[]]$Records, [string]$ReportingCurrencyUpper = 'INR', [bool]$AllowEstimatedFallback = $false)
    $total = 0d
    $usable = $false
    $actualUsed = 0
    $estimatedUsed = 0
    $missing = 0
    $currencyMismatch = 0
    $fallbackDisabled = 0
    foreach ($r in @($Records)) {
        $c = Resolve-DbM25RecordCost -Record $r -ReportingCurrencyUpper $ReportingCurrencyUpper -AllowEstimatedFallback $AllowEstimatedFallback
        if ($c.Used) {
            $total += $c.Amount
            $usable = $true
            if ($c.Source -eq 'ACTUAL') { $actualUsed++ } else { $estimatedUsed++ }
        } elseif ($c.Executed) {
            switch ($c.ExcludedReason) {
                'CURRENCY_MISMATCH' { $currencyMismatch++ }
                'FALLBACK_DISABLED' { $fallbackDisabled++ }
                default             { $missing++ }
            }
        }
    }
    return @{ Total = $total; Usable = $usable; ActualUsed = $actualUsed; EstimatedUsed = $estimatedUsed;
              Missing = $missing; CurrencyMismatch = $currencyMismatch; FallbackDisabled = $fallbackDisabled }
}

# --- dimension filter + group key --------------------------------------------------

function Resolve-DbM25FilteredAttempts {
    <#
    .SYNOPSIS
    Apply the QualityCostQuery time window + dimension filters to a record set.
    Mirrors DB-M24 Resolve-AiFilteredAttempts (READ-ONLY precedent) and adds the
    LocalOrRemote dimension. Attempts without a start time are excluded when a
    window is specified (and included otherwise).
    #>
    param([AllowNull()][object[]]$Records, [AllowNull()][pscustomobject]$Query)
    $records = @($Records)
    $from = ConvertTo-AiPerfUtc (Get-ContractProperty $Query 'FromUtc' $null)
    $to = ConvertTo-AiPerfUtc (Get-ContractProperty $Query 'ToUtc' $null)
    $hasWindow = ($null -ne $from -or $null -ne $to)
    $filtered = New-Object System.Collections.ArrayList
    foreach ($r in $records) {
        if ($null -eq $r) { continue }
        if ($hasWindow) {
            $st = ConvertTo-AiPerfUtc (Get-ContractProperty $r 'StartedAtUtc' $null)
            if ($null -eq $st) { continue }
            if ($from -and $st -lt $from) { continue }
            if ($to -and $st -ge $to) { continue }
        }
        $dims = @(
            @('ProviderId',        (Get-ContractProperty $Query 'ProviderId' $null)),
            @('ModelId',           (Get-ContractProperty $Query 'ModelId' $null)),
            @('UnderlyingModelId', (Get-ContractProperty $Query 'UnderlyingModelId' $null)),
            @('GatewayProviderId', (Get-ContractProperty $Query 'GatewayProviderId' $null)),
            @('TaskType',          (Get-ContractProperty $Query 'TaskType' $null)),
            @('Complexity',        (Get-ContractProperty $Query 'Complexity' $null)),
            @('Risk',              (Get-ContractProperty $Query 'Risk' $null)),
            @('ReasoningLevel',    (Get-ContractProperty $Query 'ReasoningLevel' $null)),
            @('ExecutionMode',     (Get-ContractProperty $Query 'ExecutionMode' $null)),
            @('LocalOrRemote',     (Get-ContractProperty $Query 'LocalOrRemote' $null))
        )
        $match = $true
        foreach ($d in $dims) {
            $field = [string]$d[0]
            $q = $d[1]
            if ($null -eq $q -or [string]$q -eq '') { continue }
            $rv = Get-ContractProperty $r $field $null
            if ($null -eq $rv) { $match = $false; break }
            if ([string]$rv -ine [string]$q) { $match = $false; break }
        }
        if (-not $match) { continue }
        $null = $filtered.Add($r)
    }
    return @($filtered)
}

function Resolve-DbM25GroupKey {
    <#
    .SYNOPSIS
    Aggregation key for a DB-M25 grouping. DB-M24 ModelRoute semantics are
    reused READ-ONLY; LocalOrRemote is a DB-M25-owned extension. Every other
    grouping keys on the single dimension value.
    #>
    param($Record, [string]$GroupBy)
    switch ($GroupBy) {
        'ModelRoute' {
            $p = [string](Get-ContractProperty $Record 'ProviderId' '')
            $m = [string](Get-ContractProperty $Record 'ModelId' '')
            $g = [string](Get-ContractProperty $Record 'GatewayProviderId' '')
            if (-not $p) { $p = '(unknown)' }
            if (-not $m) { $m = '(unknown)' }
            if (-not $g) { $g = '(none)' }
            return ("{0}|{1}|{2}" -f $p, $m, $g)
        }
        'Provider' {
            $v = Get-PerfString $Record 'ProviderId'; if (-not $v) { $v = '(unknown)' }; return $v
        }
        'UnderlyingModel' {
            $v = Get-PerfString $Record 'UnderlyingModelId'; if (-not $v) { $v = '(unknown)' }; return $v
        }
        'Gateway' {
            $v = Get-PerfString $Record 'GatewayProviderId'; if (-not $v) { $v = '(none)' }; return $v
        }
        'TaskType' {
            $v = Get-PerfString $Record 'TaskType'; if (-not $v) { $v = '(unknown)' }; return $v
        }
        'Complexity' {
            $v = Get-PerfString $Record 'Complexity'; if (-not $v) { $v = '(unknown)' }; return $v
        }
        'Risk' {
            $v = Get-PerfString $Record 'Risk'; if (-not $v) { $v = '(unknown)' }; return $v
        }
        'ReasoningLevel' {
            $v = Get-PerfString $Record 'ReasoningLevel'; if (-not $v) { $v = '(unknown)' }; return $v
        }
        'ExecutionMode' {
            $v = Get-PerfString $Record 'ExecutionMode'; if (-not $v) { $v = 'MANUAL' }; return $v
        }
        'LocalOrRemote' {
            $v = Get-PerfString $Record 'LocalOrRemote'; if (-not $v) { $v = 'UNKNOWN' }; return $v
        }
    }
    throw "Unsupported GroupBy '$GroupBy'"
}

# --- chain facts ---------------------------------------------------------------------

function Resolve-DbM25ChainFacts {
    <#
    .SYNOPSIS
    Reconstruct DB-M25 task-level facts for ONE chain:
      - executed attempt count (non-attempts excluded)
      - terminal attempt + verified-success resolution (Resolve-DbM25VerifiedSuccess)
      - outcome SUCCESS / REJECTED / FAILURE / INCOMPLETE
      - first-attempt verified success, escalation, human intervention
      - correction loop (more than one executed attempt before the terminal
        verified success, or human intervention)
      - chain cost (sum of usable cost evidence of executed attempts)
    #>
    param([hashtable]$Chain, [AllowNull()][pscustomobject]$Query)
    $recs = @($Chain.Records)
    $successDefinition = [string](Get-ContractProperty $Query 'SuccessDefinition' 'VERIFIED')
    $requireReview = [bool](Get-ContractProperty $Query 'RequiresClaudeReview' $false)
    $requiredReview = [string](Get-ContractProperty $Query 'RequiredReviewStatus' 'PASS')
    $reportingUpper = ([string](Get-ContractProperty $Query 'ReportingCurrency' 'INR')).ToUpperInvariant()
    $allowEst = [bool](Get-ContractProperty $Query 'AllowEstimatedCostFallback' $false)

    $facts = @{
        Key = $Chain.Key
        Records = $recs
        RecordCount = $recs.Count
        AttemptCount = 0
        ExecutedAttempts = @()
        TerminalAttempt = $null
        Outcome = 'INCOMPLETE'
        Success = $false
        Verified = $false
        ModelReturned = $false
        ReviewRejected = $false
        Contradicted = $false
        ReviewStatus = $null
        FirstAttemptSuccess = $false
        FirstAttemptVerified = $false
        Escalated = $false
        HumanIntervention = $false
        CorrectionLoop = $false
        LastAttemptAtUtc = $null
        ChainCost = 0d
        ChainCostOk = $false
        CostActualUsed = 0
        CostEstimatedUsed = 0
        CostMissing = 0
        CostCurrencyMismatch = 0
        CostFallbackDisabled = 0
    }

    $executed = @()
    foreach ($r in $recs) { if (Test-DbM25ExecutedAttempt $r) { $executed += , $r } }
    $facts.AttemptCount = $executed.Count
    $facts.ExecutedAttempts = $executed

    # escalation / human intervention / last-attempt scan over ALL records
    foreach ($r in $recs) {
        $efa = [string](Get-ContractProperty $r 'EscalatedFromAttemptId' '')
        $eta = [string](Get-ContractProperty $r 'EscalatedToAttemptId' '')
        $rr = [string](Get-ContractProperty $r 'Result' '')
        if ($efa -or $eta -or $rr -eq 'ESCALATED') { $facts.Escalated = $true }
        if ([bool](Get-ContractProperty $r 'HumanIntervention' $false)) { $facts.HumanIntervention = $true }
        $t = ConvertTo-AiPerfUtc (Get-ContractProperty $r 'EndedAtUtc' $null)
        if ($null -eq $t) { $t = ConvertTo-AiPerfUtc (Get-ContractProperty $r 'StartedAtUtc' $null) }
        if ($t -and ($null -eq $facts.LastAttemptAtUtc -or $t -gt $facts.LastAttemptAtUtc)) { $facts.LastAttemptAtUtc = $t }
    }

    # chain cost always computed (abandoned chains still carry real cost)
    $cc = Get-DbM25ChainCost -Records $recs -ReportingCurrencyUpper $reportingUpper -AllowEstimatedFallback $allowEst
    $facts.ChainCost = $cc.Total
    $facts.ChainCostOk = $cc.Usable
    $facts.CostActualUsed = $cc.ActualUsed
    $facts.CostEstimatedUsed = $cc.EstimatedUsed
    $facts.CostMissing = $cc.Missing
    $facts.CostCurrencyMismatch = $cc.CurrencyMismatch
    $facts.CostFallbackDisabled = $cc.FallbackDisabled

    $terminal = $null
    foreach ($r in $recs) { if (Test-DbM25TerminalAttempt $r) { $terminal = $r } }
    if ($null -eq $terminal) { return $facts }   # INCOMPLETE

    $facts.TerminalAttempt = $terminal
    $vs = Resolve-DbM25VerifiedSuccess -Attempt $terminal -SuccessDefinition $successDefinition `
        -RequiresClaudeReview $requireReview -RequiredReviewStatus $requiredReview
    $facts.Success = $vs.Success
    $facts.Verified = $vs.Verified
    $facts.ModelReturned = $vs.ModelReturned
    $facts.ReviewRejected = $vs.ReviewRejected
    $facts.Contradicted = $vs.Contradicted
    $facts.ReviewStatus = $vs.ReviewStatus
    if ($vs.Success) { $facts.Outcome = 'SUCCESS' }
    elseif ([string](Get-ContractProperty $terminal 'Result' '') -eq 'SUCCESS') { $facts.Outcome = 'REJECTED' }
    else { $facts.Outcome = 'FAILURE' }

    # first executed attempt (budget-blocked records that precede a real attempt
    # are not "attempt #1" -- the first real AI attempt decides first-attempt)
    if ($executed.Count -gt 0) {
        $first = $executed[0]
        $fvs = Resolve-DbM25VerifiedSuccess -Attempt $first -SuccessDefinition $successDefinition `
            -RequiresClaudeReview $requireReview -RequiredReviewStatus $requiredReview
        $facts.FirstAttemptSuccess = $fvs.Success
        $facts.FirstAttemptVerified = $fvs.Verified
    }

    $facts.CorrectionLoop = ($facts.AttemptCount -gt 1) -or $facts.HumanIntervention
    return $facts
}

# --- local cost status -----------------------------------------------------------------

function Get-DbM25LocalCostStatus {
    <#
    .SYNOPSIS
    LocalCostStatus for a group (DB-M23 vocabulary, READ-ONLY). A LOCAL route is
    NEVER automatically FREE: an explicit zero provider-token price or absent
    evidence means LOCAL_COST_UNKNOWN (operational cost unknown), not FREE.
    Positive usable cost -> CONFIGURED. DB-M25 never invents electricity /
    hardware / infrastructure cost.
    #>
    param([string]$LocalOrRemote = 'REMOTE', [bool]$HasUsableCost = $false, [double]$UsableCostTotal = 0d)
    if ($LocalOrRemote -eq 'LOCAL') {
        if ($HasUsableCost -and $UsableCostTotal -gt 0) { return 'CONFIGURED' }
        return 'LOCAL_COST_UNKNOWN'
    }
    if (-not $HasUsableCost) { return 'PRICE_UNKNOWN' }
    if ($UsableCostTotal -gt 0) { return 'CONFIGURED' }
    return 'FREE'
}

# --- per-group summary builder -----------------------------------------------------------

function Get-DbM25GroupQualityAdjustedCost {
    <#
    .SYNOPSIS
    Compute the full QualityAdjustedCostResult v1 for ONE group.
    Attempt-level metrics accumulate every executed attempt attributed to the
    group (failed attempts included; non-attempts excluded). Task-level metrics
    accumulate the group's terminal-attributed chains. Verified success is
    authoritative (query SuccessDefinition). Expected cost basis switches to
    OBSERVED_CHAINS only when sample confidence is MODERATE/HIGH, else to the
    labelled COLD_START_SIMPLE estimate (never silent).
    #>
    param(
        [string]$GroupBy,
        [string]$GroupKey,
        [AllowNull()][object[]]$Attempts,
        [AllowNull()][object[]]$TaskFacts,
        [int]$IncompleteCount = 0,
        [AllowNull()][pscustomobject]$Query
    )
    $attempts = @($Attempts)
    $taskFacts = @($TaskFacts)
    $id = Resolve-AiGroupIdentity -GroupBy $GroupBy -Attempts $attempts
    $reportingUpper = ([string](Get-ContractProperty $Query 'ReportingCurrency' 'INR')).ToUpperInvariant()
    $allowEst = [bool](Get-ContractProperty $Query 'AllowEstimatedCostFallback' $false)
    $successDefinition = [string](Get-ContractProperty $Query 'SuccessDefinition' 'VERIFIED')
    $analysisId = [string](Get-ContractProperty $Query 'QueryId' $null)
    if (-not $analysisId) { $analysisId = ('DBM25-' + (New-Guid).ToString('N').Substring(0, 8)) }

    $localOrRemote = Get-PerfString (($attempts | Select-Object -First 1)) 'LocalOrRemote'
    if (-not $localOrRemote) { $localOrRemote = 'UNKNOWN' }
    $id.LocalOrRemote = $localOrRemote

    # ---- attempt-level accumulators --------------------------------------------------
    $costs = New-Object System.Collections.Generic.List[double]
    $usableCostSum = 0d
    $costSampleCount = 0
    $estimatedFallbackUsed = 0
    $missingCost = 0
    $currencyMismatch = 0
    $fallbackDisabled = 0
    $nonExecuted = 0
    $executedAttemptCount = 0
    $failedAttemptCost = 0d
    $escalationCost = 0d
    $providerFailureCost = 0d
    $modelQualityFailureCost = 0d
    $failureCategoryCosts = @{}
    foreach ($cat in (Get-AiAttemptFailureCategories)) { $failureCategoryCosts[$cat] = 0d }
    $failureCategoryCosts['UNKNOWN'] = 0d

    foreach ($r in $attempts) {
        $res = [string](Get-ContractProperty $r 'Result' '')
        $c = Resolve-DbM25RecordCost -Record $r -ReportingCurrencyUpper $reportingUpper -AllowEstimatedFallback $allowEst
        if (-not $c.Executed) { $nonExecuted++; continue }
        $executedAttemptCount++
        if ($c.Used) {
            $costs.Add($c.Amount)
            $usableCostSum += $c.Amount
            $costSampleCount++
            if ($c.Source -eq 'ESTIMATED') { $estimatedFallbackUsed++ }
            # failure-cost buckets (every real failed/spent attempt counts)
            if ($res -ne 'SUCCESS') {
                $failedAttemptCost += $c.Amount
                $fc = Get-PerfString $r 'FailureCategory'
                if (-not $fc) { $fc = 'UNKNOWN' }
                if ($failureCategoryCosts.ContainsKey($fc)) { $failureCategoryCosts[$fc] = [double]$failureCategoryCosts[$fc] + $c.Amount }
                else { $failureCategoryCosts[$fc] = $c.Amount }
                if ($fc -in (Get-AiProviderFailureCategories)) { $providerFailureCost += $c.Amount }
                elseif ($fc -eq 'MODEL_QUALITY') { $modelQualityFailureCost += $c.Amount }
            }
            # escalation cost: any attempt carrying escalation evidence
            $efa = [string](Get-ContractProperty $r 'EscalatedFromAttemptId' '')
            $eta = [string](Get-ContractProperty $r 'EscalatedToAttemptId' '')
            if ($efa -or $eta -or $res -eq 'ESCALATED') { $escalationCost += $c.Amount }
        } else {
            switch ($c.ExcludedReason) {
                'CURRENCY_MISMATCH' { $currencyMismatch++ }
                'FALLBACK_DISABLED' { $fallbackDisabled++ }
                default             { $missingCost++ }
            }
        }
    }

    # ---- task-level accumulators (attributed chains) -----------------------------------
    $sampleCount = $taskFacts.Count
    $verifiedSuccess = 0
    $modelReturnedSuccess = 0
    $failedChain = 0
    $rejectedChain = 0
    $firstAttemptVerified = 0
    $escalatedChains = 0
    $attemptsPerSuccess = New-Object System.Collections.Generic.List[double]
    $costPerSuccess = New-Object System.Collections.Generic.List[double]
    $escalatedChainCostSum = 0d
    $escalatedChainCostOk = $false
    $correctionCosts = New-Object System.Collections.Generic.List[double]
    $evidence = New-Object System.Collections.Generic.List[string]

    foreach ($f in $taskFacts) {
        $evidence.Add([string]$f.Key)
        if ($f.Outcome -eq 'SUCCESS') {
            if ($f.Verified) { $verifiedSuccess++ }
            if ($f.ModelReturned) { $modelReturnedSuccess++ }
            if ($f.AttemptCount -ge 1) { $attemptsPerSuccess.Add([double]$f.AttemptCount) }
            if ($f.ChainCostOk) { $costPerSuccess.Add($f.ChainCost) }
            if ($f.CorrectionLoop -and $f.ChainCostOk) { $correctionCosts.Add($f.ChainCost) }
        } elseif ($f.Outcome -eq 'REJECTED') {
            $rejectedChain++
            $failedChain++
        } else {
            $failedChain++
        }
        if ($f.FirstAttemptVerified) { $firstAttemptVerified++ }
        if ($f.Escalated) {
            $escalatedChains++
            if ($f.ChainCostOk) { $escalatedChainCostSum += $f.ChainCost; $escalatedChainCostOk = $true }
        }
    }

    $confidence = Get-AiConfidenceLevel -SampleCount $sampleCount -Bands $script:PerfConfidenceBands

    $verifiedSuccessRate = if ($sampleCount -gt 0) { [math]::Round($verifiedSuccess / $sampleCount, 4) } else { $null }
    $firstAttemptRate = if ($sampleCount -gt 0) { [math]::Round($firstAttemptVerified / $sampleCount, 4) } else { $null }
    $avgAttemptsPerSuccess = Get-PerfMean $attemptsPerSuccess
    $medianAttemptsPerSuccess = Get-PerfMedian $attemptsPerSuccess
    $avgAttemptCost = if ($costSampleCount -gt 0) { [math]::Round($usableCostSum / $costSampleCount, 4) } else { $null }
    $medianAttemptCost = Get-PerfMedian $costs
    $observedCostPerSuccess = Get-PerfMean $costPerSuccess
    $medianCostPerSuccess = Get-PerfMedian $costPerSuccess
    $totalCostPerSuccess = if ($costPerSuccess.Count -gt 0) { [math]::Round((($costPerSuccess | Measure-Object -Sum).Sum), 4) } else { $null }
    $avgSuccessfulChainCost = $observedCostPerSuccess

    # expected cost per verified success (transparent basis)
    $expectedCost = $null
    $expectedBasis = $null
    if ($null -ne $observedCostPerSuccess -and $confidence -in @('MODERATE', 'HIGH')) {
        $expectedCost = $observedCostPerSuccess
        $expectedBasis = 'OBSERVED_CHAINS'
    } elseif ($null -ne $avgAttemptCost -and $null -ne $verifiedSuccessRate -and $verifiedSuccessRate -gt 0) {
        $expectedCost = [math]::Round($avgAttemptCost / $verifiedSuccessRate, 4)
        $expectedBasis = 'COLD_START_SIMPLE'
    }

    $totalCost = $usableCostSum
    $failedShare = if ($totalCost -gt 0) { [math]::Round($failedAttemptCost / $totalCost, 4) } else { $null }
    $escalationShare = if ($totalCost -gt 0) { [math]::Round($escalationCost / $totalCost, 4) } else { $null }
    $providerShare = if ($totalCost -gt 0) { [math]::Round($providerFailureCost / $totalCost, 4) } else { $null }
    $qualityShare = if ($totalCost -gt 0) { [math]::Round($modelQualityFailureCost / $totalCost, 4) } else { $null }

    $hasUsable = ($costSampleCount -gt 0)
    $costStatus = Get-DbM25LocalCostStatus -LocalOrRemote $localOrRemote -HasUsableCost $hasUsable -UsableCostTotal $totalCost
    $operationalUnknown = ($localOrRemote -eq 'LOCAL')

    $warnings = New-Object System.Collections.Generic.List[string]
    if ($sampleCount -eq 0) { $warnings.Add('No terminal task in this group (cold start); task-level success metrics are empty.') }
    elseif ($confidence -eq 'INSUFFICIENT') { $warnings.Add("Small sample ($sampleCount task(s)); confidence INSUFFICIENT.") }
    elseif ($confidence -eq 'LOW') { $warnings.Add("Small sample ($sampleCount task(s)); confidence LOW.") }
    if ($IncompleteCount -gt 0) { $warnings.Add("$IncompleteCount task(s) had no terminal attempt; their attempts contribute attempt-level cost only.") }
    if ($nonExecuted -gt 0) { $warnings.Add("$nonExecuted non-attempt record(s) (BUDGET_STOPPED/BLOCKED/WAITING_HUMAN/PENDING) excluded from attempt count and cost (no AI call happened).") }
    if ($missingCost -gt 0) { $warnings.Add("$missingCost executed attempt(s) had no cost evidence and were excluded from cost metrics.") }
    if ($currencyMismatch -gt 0) { $warnings.Add("$currencyMismatch attempt(s) had cost evidence in a currency other than $reportingUpper and were excluded (historic evidence is never re-converted).") }
    if ($fallbackDisabled -gt 0) { $warnings.Add("$fallbackDisabled attempt(s) had estimated cost only and were excluded because estimated-cost fallback is disabled for this query.") }
    if ($estimatedFallbackUsed -gt 0) { $warnings.Add("Estimated-cost fallback used for $estimatedFallbackUsed attempt(s).") }
    if ($expectedBasis -eq 'COLD_START_SIMPLE') { $warnings.Add('ExpectedCostPerVerifiedSuccess is a labelled COLD_START_SIMPLE estimate (AverageAttemptCost / VerifiedSuccessRate); treat as tentative.') }
    if ($operationalUnknown) { $warnings.Add('LOCAL route: provider-token cost only; operational cost (infrastructure/electricity/hardware) is UNKNOWN and never invented.') }
    if ($null -eq $observedCostPerSuccess -and $sampleCount -gt 0) { $warnings.Add('No verified-success chain cost available (no verified success in this group).') }

    $fromUtc = Get-ContractProperty $Query 'FromUtc' $null
    $toUtc = Get-ContractProperty $Query 'ToUtc' $null

    return (New-DbM25QualityAdjustedCostResult -Fields @{
        AnalysisId                         = $analysisId
        GroupBy                            = $GroupBy
        GroupKey                           = $GroupKey
        ProviderId                         = $id.ProviderId
        ModelId                            = $id.ModelId
        UnderlyingModelId                  = $id.UnderlyingModelId
        GatewayProviderId                  = $id.GatewayProviderId
        LocalOrRemote                      = $id.LocalOrRemote
        TaskType                           = $id.TaskType
        Complexity                         = $id.Complexity
        Risk                               = $id.Risk
        ReasoningLevel                     = $id.ReasoningLevel
        ExecutionMode                      = $id.ExecutionMode
        SampleCount                        = $sampleCount
        AttemptCount                       = $executedAttemptCount
        VerifiedSuccessCount               = $verifiedSuccess
        ModelReturnedSuccessCount          = $modelReturnedSuccess
        FailedChainCount                   = $failedChain
        IncompleteChainCount               = $IncompleteCount
        FirstAttemptVerifiedSuccessCount   = $firstAttemptVerified
        VerifiedSuccessRate                = $verifiedSuccessRate
        FirstAttemptVerifiedSuccessRate    = $firstAttemptRate
        AverageAttemptsPerVerifiedSuccess  = $avgAttemptsPerSuccess
        MedianAttemptsPerVerifiedSuccess   = $medianAttemptsPerSuccess
        AverageAttemptCost                 = $avgAttemptCost
        MedianAttemptCost                  = $medianAttemptCost
        TotalAttemptCost                   = [math]::Round($totalCost, 4)
        FailedAttemptCost                  = [math]::Round($failedAttemptCost, 4)
        FailedAttemptCostShare             = $failedShare
        EscalationCost                     = [math]::Round($escalationCost, 4)
        EscalationCostShare                = $escalationShare
        EscalatedChainCost                 = if ($escalatedChainCostOk) { [math]::Round($escalatedChainCostSum, 4) } else { $null }
        AverageCorrectionCost              = Get-PerfMean $correctionCosts
        ProviderFailureCost                = [math]::Round($providerFailureCost, 4)
        ProviderFailureCostShare           = $providerShare
        ModelQualityFailureCost            = [math]::Round($modelQualityFailureCost, 4)
        ModelQualityFailureCostShare       = $qualityShare
        FailureCategoryCosts               = $failureCategoryCosts
        TotalCostPerVerifiedSuccess        = $totalCostPerSuccess
        ObservedCostPerVerifiedSuccess     = $observedCostPerSuccess
        MedianCostPerVerifiedSuccess       = $medianCostPerSuccess
        ExpectedCostPerVerifiedSuccess     = $expectedCost
        ExpectedCostBasis                  = $expectedBasis
        AverageSuccessfulChainCost         = $avgSuccessfulChainCost
        LocalCostStatus                    = $costStatus
        OperationalCostUnknown             = $operationalUnknown
        Currency                           = $reportingUpper
        EstimatedCostFallbackUsed          = $estimatedFallbackUsed
        CostExcludedCount                  = ($missingCost + $currencyMismatch + $fallbackDisabled)
        ConfidenceLevel                    = $confidence
        SuccessDefinition                  = $successDefinition
        EvidenceReferences                 = @($evidence)
        WindowStartUtc                     = $fromUtc
        WindowEndUtc                       = $toUtc
        GeneratedAtUtc                     = (Get-Date).ToUniversalTime().ToString('o')
        Warnings                           = @($warnings)
    })
}

# --- core aggregation ---------------------------------------------------------------------

function Get-DbM25QualityAdjustedCost {
    <#
    .SYNOPSIS
    Core DB-M25 aggregation: filter attempts by the QualityCostQuery, reconstruct
    task chains (DB-M24 Resolve-AiTaskChains READ-ONLY), resolve per-chain
    verified-success facts, and produce one QualityAdjustedCostResult v1 per
    group. Chains with a terminal attempt attribute their whole cost to the
    terminal route; incomplete chains contribute attempt-level cost to the route
    each attempt actually used. Returns @() when no attempt satisfies the query.
    #>
    param(
        [AllowNull()][object[]]$Records,
        [AllowNull()][pscustomobject]$Query
    )
    if ($null -eq $Query) { $Query = New-DbM25QualityCostQuery }
    $qv = Test-DbM25QualityCostQuery $Query
    if (-not $qv.Valid) { throw ("Invalid QualityCostQuery: " + ($qv.Errors -join '; ')) }

    $groupBy = [string](Get-ContractProperty $Query 'GroupBy' 'ModelRoute')
    if ($groupBy -notin (Get-DbM25GroupBys)) { throw "GroupBy '$groupBy' is not a supported DB-M25 grouping" }

    $filtered = @(Resolve-DbM25FilteredAttempts -Records $Records -Query $Query)
    if ($filtered.Count -eq 0) { return @() }

    $chains = @(Resolve-AiTaskChains $filtered)

    $groupAttempts = @{}
    $groupFacts = @{}
    $groupIncomplete = @{}

    foreach ($chain in $chains) {
        $facts = Resolve-DbM25ChainFacts -Chain $chain -Query $Query
        if ($null -eq $facts.TerminalAttempt) {
            $seen = @{}
            foreach ($r in $facts.Records) {
                if ($null -eq $r) { continue }
                $gk = Resolve-DbM25GroupKey $r $groupBy
                if (-not $groupAttempts.ContainsKey($gk)) { $groupAttempts[$gk] = New-Object System.Collections.ArrayList }
                $null = $groupAttempts[$gk].Add($r)
                if ($seen.ContainsKey($gk)) { continue }
                $seen[$gk] = $true
                if (-not $groupIncomplete.ContainsKey($gk)) { $groupIncomplete[$gk] = New-Object System.Collections.ArrayList }
                $null = $groupIncomplete[$gk].Add($facts.Key)
            }
            continue
        }
        $gk = Resolve-DbM25GroupKey $facts.TerminalAttempt $groupBy
        foreach ($r in $facts.Records) {
            if ($null -eq $r) { continue }
            if (-not $groupAttempts.ContainsKey($gk)) { $groupAttempts[$gk] = New-Object System.Collections.ArrayList }
            $null = $groupAttempts[$gk].Add($r)
        }
        if (-not $groupFacts.ContainsKey($gk)) { $groupFacts[$gk] = New-Object System.Collections.ArrayList }
        $null = $groupFacts[$gk].Add($facts)
    }

    $keys = @{}
    foreach ($k in @($groupAttempts.Keys)) { $keys[$k] = $true }
    foreach ($k in @($groupFacts.Keys)) { $keys[$k] = $true }

    $results = New-Object System.Collections.ArrayList
    foreach ($gk in @($keys.Keys)) {
        $attempts = @()
        if ($groupAttempts.ContainsKey($gk)) { $attempts = @($groupAttempts[$gk]) }
        $factsList = @()
        if ($groupFacts.ContainsKey($gk)) { $factsList = @($groupFacts[$gk]) }
        $incomplete = 0
        if ($groupIncomplete.ContainsKey($gk)) { $incomplete = @($groupIncomplete[$gk]).Count }
        $s = Get-DbM25GroupQualityAdjustedCost -GroupBy $groupBy -GroupKey $gk `
            -Attempts $attempts -TaskFacts $factsList -IncompleteCount $incomplete -Query $Query
        $null = $results.Add($s)
    }
    return @($results)
}

# --- savings -------------------------------------------------------------------------------

function Get-DbM25SavingsAnalysis {
    <#
    .SYNOPSIS
    Quality-adjusted savings between a candidate route result and an explicit
    baseline result. Savings only on equivalent verified outcomes: AbsoluteSavings
    is computed only when BOTH sides have an ObservedCostPerVerifiedSuccess
    (verified chains). The baseline type is explicit (never silently chosen);
    the basis labels observed vs estimated/counterfactual data. A cheap route
    with no verified success has no cost-per-success and therefore no savings
    number. AvoidedRetryCost is an ESTIMATED/COUNTERFACTUAL figure and is
    reported as such in Warnings.
    #>
    param(
        [AllowNull()][pscustomobject]$CandidateResult,
        [AllowNull()][pscustomobject]$BaselineResult,
        [string]$BaselineType = 'CURRENT_DEFAULT',
        [string]$BaselineLabel = '',
        [string]$BaselineBasis = 'OBSERVED',
        [string]$Scope = '',
        [AllowNull()][hashtable]$ExtraFields = $null
    )
    if ($null -eq $ExtraFields) { $ExtraFields = @{} }
    function Get-Field([string]$Name, $Default = $null) {
        if ($ExtraFields.ContainsKey($Name)) { return $ExtraFields[$Name] }
        return $Default
    }

    $bt = $BaselineType.ToUpperInvariant()
    if (-not (Test-IsValidDbM25BaselineType $bt)) { throw "BaselineType '$bt' invalid" }
    $bb = $BaselineBasis.ToUpperInvariant()
    if (-not (Test-IsValidDbM25BaselineBasis $bb)) { throw "BaselineBasis '$bb' invalid" }
    if ($null -eq $CandidateResult) { throw 'CandidateResult is required' }
    if ($null -eq $BaselineResult) { throw 'BaselineResult is required' }

    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($w in @(Get-ContractProperty $CandidateResult 'Warnings' @())) { $warnings.Add("candidate: $w") }
    foreach ($w in @(Get-ContractProperty $BaselineResult 'Warnings' @())) { $warnings.Add("baseline: $w") }

    # equivalent-scope guard (informational; both sides must target the same scope)
    $cTask = Get-ContractProperty $CandidateResult 'TaskType' $null
    $bTask = Get-ContractProperty $BaselineResult 'TaskType' $null
    if ($cTask -and $bTask -and $cTask -ne $bTask) { $warnings.Add('Candidate and baseline TaskType differ; savings compare equivalent verified outcomes within the SAME scope only.') }
    $cCx = Get-ContractProperty $CandidateResult 'Complexity' $null
    $bCx = Get-ContractProperty $BaselineResult 'Complexity' $null
    if ($cCx -and $bCx -and $cCx -ne $bCx) { $warnings.Add('Candidate and baseline Complexity differ.') }

    $candCost = Get-ContractProperty $CandidateResult 'ObservedCostPerVerifiedSuccess' $null
    $baseCost = Get-ContractProperty $BaselineResult 'ObservedCostPerVerifiedSuccess' $null

    $absolute = $null
    $percent = $null
    if ($null -ne $candCost -and $null -ne $baseCost) {
        $absolute = [math]::Round([double]$baseCost - [double]$candCost, 4)
        if ([double]$baseCost -gt 0) { $percent = [math]::Round([math]::Abs($absolute) / [double]$baseCost * 100, 4) }
    } else {
        $warnings.Add('Savings not computed: both sides need an observed cost-per-verified-success (verified chains). A route with no verified success has no savings number.')
    }
    if ($null -eq $candCost) { $warnings.Add('Candidate has no observed cost-per-verified-success (no verified success).') }
    if ($null -eq $baseCost) { $warnings.Add('Baseline has no observed cost-per-verified-success.'); }

    # avoided retry cost (ESTIMATED/COUNTERFACTUAL)
    $baseAttempts = Get-ContractProperty $BaselineResult 'AverageAttemptsPerVerifiedSuccess' $null
    $candAttempts = Get-ContractProperty $CandidateResult 'AverageAttemptsPerVerifiedSuccess' $null
    $candAvgCost = Get-ContractProperty $CandidateResult 'AverageAttemptCost' $null
    $avoided = $null
    if ($null -ne $baseAttempts -and $null -ne $candAttempts -and $null -ne $candAvgCost) {
        $avoidedValue = ([double]$baseAttempts - [double]$candAttempts) * [double]$candAvgCost
        if ($avoidedValue -gt 0) {
            $avoided = [math]::Round($avoidedValue, 4)
            $warnings.Add('AvoidedRetryCost is an ESTIMATED/COUNTERFACTUAL figure ((baseline attempts/success - candidate attempts/success) x candidate avg attempt cost).')
        }
    }

    # confidence = the lower of the two (DB-M24 order)
    $cConf = [string](Get-ContractProperty $CandidateResult 'ConfidenceLevel' 'INSUFFICIENT')
    $bConf = [string](Get-ContractProperty $BaselineResult 'ConfidenceLevel' 'INSUFFICIENT')
    $order = Get-AiConfidenceOrder
    $confidence = if ([int]$order[$cConf] -le [int]$order[$bConf]) { $cConf } else { $bConf }
    if ($confidence -eq 'INSUFFICIENT') { $warnings.Add('Tentative, small sample: savings confidence INSUFFICIENT.') }

    $evidence = New-Object System.Collections.Generic.List[string]
    foreach ($e in @(Get-ContractProperty $CandidateResult 'EvidenceReferences' @())) { $evidence.Add("candidate: $e") }
    foreach ($e in @(Get-ContractProperty $BaselineResult 'EvidenceReferences' @())) { $evidence.Add("baseline: $e") }

    $baselineDisplay = $baseCost
    if ($null -eq $baselineDisplay) { $baselineDisplay = Get-ContractProperty $BaselineResult 'ExpectedCostPerVerifiedSuccess' $null }
    $candProvider = Get-ContractProperty $CandidateResult 'ProviderId' $null
    $candModel = Get-ContractProperty $CandidateResult 'ModelId' $null
    $candUm = Get-ContractProperty $CandidateResult 'UnderlyingModelId' $null
    $candGw = Get-ContractProperty $CandidateResult 'GatewayProviderId' $null
    $candLr = Get-ContractProperty $CandidateResult 'LocalOrRemote' $null
    $baseProvider = Get-ContractProperty $BaselineResult 'ProviderId' $null
    $baseModel = Get-ContractProperty $BaselineResult 'ModelId' $null
    $baseUm = Get-ContractProperty $BaselineResult 'UnderlyingModelId' $null
    $baseGw = Get-ContractProperty $BaselineResult 'GatewayProviderId' $null
    $baseLr = Get-ContractProperty $BaselineResult 'LocalOrRemote' $null

    return (New-DbM25SavingsAnalysis -Fields @{
        AnalysisId                      = Get-Field 'AnalysisId' ([string](Get-ContractProperty $CandidateResult 'AnalysisId' $null))
        Scope                           = Get-Field 'Scope' $Scope
        TaskType                        = Get-Field 'TaskType' (Get-ContractProperty $CandidateResult 'TaskType' $null)
        Complexity                      = Get-Field 'Complexity' (Get-ContractProperty $CandidateResult 'Complexity' $null)
        Risk                            = Get-Field 'Risk' (Get-ContractProperty $CandidateResult 'Risk' $null)
        CandidateProviderId             = $candProvider
        CandidateModelId                = $candModel
        CandidateUnderlyingModelId      = $candUm
        CandidateGatewayProviderId      = $candGw
        CandidateLocalOrRemote          = $candLr
        CandidateRoute                  = (Get-ContractProperty $CandidateResult 'GroupKey' $null)
        BaselineProviderId              = $baseProvider
        BaselineModelId                 = $baseModel
        BaselineUnderlyingModelId       = $baseUm
        BaselineGatewayProviderId       = $baseGw
        BaselineLocalOrRemote           = $baseLr
        BaselineRoute                   = (Get-ContractProperty $BaselineResult 'GroupKey' $null)
        BaselineType                    = $bt
        BaselineLabel                   = $BaselineLabel
        BaselineBasis                   = $bb
        SampleSize                      = (Get-ContractProperty $CandidateResult 'SampleCount' 0)
        Confidence                      = $confidence
        AverageAttemptCost              = (Get-ContractProperty $CandidateResult 'AverageAttemptCost' $null)
        AttemptsPerVerifiedSuccess      = $candAttempts
        VerifiedSuccessRate             = (Get-ContractProperty $CandidateResult 'VerifiedSuccessRate' $null)
        FirstAttemptSuccessRate         = (Get-ContractProperty $CandidateResult 'FirstAttemptVerifiedSuccessRate' $null)
        ObservedCostPerVerifiedSuccess  = $candCost
        ExpectedCostPerVerifiedSuccess  = (Get-ContractProperty $CandidateResult 'ExpectedCostPerVerifiedSuccess' $null)
        BaselineCostPerVerifiedSuccess  = $baselineDisplay
        AbsoluteSavings                 = $absolute
        SavingsPercent                  = $percent
        AvoidedRetryCost                = $avoided
        EscalationCost                  = (Get-ContractProperty $CandidateResult 'EscalationCost' 0)
        FailureCost                     = (Get-ContractProperty $CandidateResult 'FailedAttemptCost' 0)
        ProviderFailureCost             = (Get-ContractProperty $CandidateResult 'ProviderFailureCost' 0)
        ModelQualityFailureCost         = (Get-ContractProperty $CandidateResult 'ModelQualityFailureCost' 0)
        Currency                        = (Get-ContractProperty $CandidateResult 'Currency' 'INR')
        EvidenceReferences              = @($evidence)
        WindowStartUtc                  = (Get-ContractProperty $CandidateResult 'WindowStartUtc' $null)
        WindowEndUtc                    = (Get-ContractProperty $CandidateResult 'WindowEndUtc' $null)
        GeneratedAtUtc                  = (Get-Date).ToUniversalTime().ToString('o')
        Warnings                        = @($warnings)
    })
}

# --- policy comparison ---------------------------------------------------------------------

function Compare-DbM25Policies {
    <#
    .SYNOPSIS
    Synthetic/historical routing-policy comparison over the computed
    QualityAdjustedCostResult rows. Each policy is a route-selection rule; the
    selected route's cost-per-verified-success, sample size and confidence are
    reported, ranked by cost-per-verified-success (presentation only).
    ANALYSIS ONLY: no live policy is read-for-decision or mutated; PolicyVersion
    stays the immutable '0.0.0'. Rows are labelled COUNTERFACTUAL unless they are
    the actually-observed default route.
    #>
    param(
        [AllowNull()][object[]]$Summaries,
        [string]$AnalysisId,
        [string]$Currency = 'INR',
        [string]$DefaultGroupKey = $null
    )
    $summaries = @($Summaries)
    $eligible = @()
    foreach ($s in $summaries) {
        if ($null -eq $s) { continue }
        if ([int](Get-ContractProperty $s 'SampleCount' 0) -lt 1) { continue }
        $eligible += , $s
    }

    $rows = New-Object System.Collections.ArrayList

    # CHEAPEST_ELIGIBLE: minimum AverageAttemptCost
    if ($eligible.Count -gt 0) {
        $pick = $null
        foreach ($s in $eligible) {
            $c = Get-ContractProperty $s 'AverageAttemptCost' $null
            if ($null -eq $c) { continue }
            if ($null -eq $pick -or [double]$c -lt [double](Get-ContractProperty $pick 'AverageAttemptCost' 0)) { $pick = $s }
        }
        if ($null -ne $pick) { $null = $rows.Add(@{ Policy = 'CHEAPEST_ELIGIBLE'; Summary = $pick }) }
    }

    # CHEAPEST_RELIABLE: minimum cost-per-verified-success among routes with VerifiedSuccessRate >= 0.8
    $reliable = @()
    foreach ($s in $eligible) {
        $rate = Get-ContractProperty $s 'VerifiedSuccessRate' $null
        if ($null -ne $rate -and [double]$rate -ge 0.8) { $reliable += , $s }
    }
    $pick = $null
    foreach ($s in $reliable) {
        $c = Get-ContractProperty $s 'ObservedCostPerVerifiedSuccess' $null
        if ($null -eq $c) { continue }
        if ($null -eq $pick -or [double]$c -lt [double](Get-ContractProperty $pick 'ObservedCostPerVerifiedSuccess' 0)) { $pick = $s }
    }
    if ($null -ne $pick) { $null = $rows.Add(@{ Policy = 'CHEAPEST_RELIABLE'; Summary = $pick }) }

    # BEST_COST_PER_SUCCESS: minimum ObservedCostPerVerifiedSuccess
    $pick = $null
    foreach ($s in $eligible) {
        $c = Get-ContractProperty $s 'ObservedCostPerVerifiedSuccess' $null
        if ($null -eq $c) { continue }
        if ($null -eq $pick -or [double]$c -lt [double](Get-ContractProperty $pick 'ObservedCostPerVerifiedSuccess' 0)) { $pick = $s }
    }
    if ($null -ne $pick) { $null = $rows.Add(@{ Policy = 'BEST_COST_PER_SUCCESS'; Summary = $pick }) }

    # HIGHEST_SUCCESS: maximum VerifiedSuccessRate
    $pick = $null
    foreach ($s in $eligible) {
        $r = Get-ContractProperty $s 'VerifiedSuccessRate' $null
        if ($null -eq $r) { continue }
        if ($null -eq $pick -or [double]$r -gt [double](Get-ContractProperty $pick 'VerifiedSuccessRate' -1)) { $pick = $s }
    }
    if ($null -ne $pick) { $null = $rows.Add(@{ Policy = 'HIGHEST_SUCCESS'; Summary = $pick }) }

    # BALANCED: best composite of normalized cost-per-verified-success and success rate
    $balanced = @()
    foreach ($s in $eligible) {
        $c = Get-ContractProperty $s 'ObservedCostPerVerifiedSuccess' $null
        $r = Get-ContractProperty $s 'VerifiedSuccessRate' $null
        if ($null -ne $c -and $null -ne $r) { $balanced += , $s }
    }
    if ($balanced.Count -gt 0) {
        $maxCost = 0d
        foreach ($s in $balanced) { $cc = [double](Get-ContractProperty $s 'ObservedCostPerVerifiedSuccess' 0); if ($cc -gt $maxCost) { $maxCost = $cc } }
        $pick = $null
        $bestScore = [double]::MaxValue
        foreach ($s in $balanced) {
            $normCost = if ($maxCost -gt 0) { [double](Get-ContractProperty $s 'ObservedCostPerVerifiedSuccess' 0) / $maxCost } else { 1d }
            $score = $normCost + (1 - [double](Get-ContractProperty $s 'VerifiedSuccessRate' 0))
            if ($score -lt $bestScore) { $bestScore = $score; $pick = $s }
        }
        if ($null -ne $pick) { $null = $rows.Add(@{ Policy = 'BALANCED'; Summary = $pick }) }
    }

    $outRows = New-Object System.Collections.ArrayList
    foreach ($entry in @($rows)) {
        $s = $entry.Summary
        $policy = $entry.Policy
        $groupKey = [string](Get-ContractProperty $s 'GroupKey' $null)
        $basis = if ($DefaultGroupKey -and $groupKey -eq $DefaultGroupKey) { 'OBSERVED' } else { 'COUNTERFACTUAL' }
        $null = $outRows.Add([pscustomobject]@{
            Policy                   = $policy
            ProviderId               = (Get-ContractProperty $s 'ProviderId' $null)
            ModelId                  = (Get-ContractProperty $s 'ModelId' $null)
            UnderlyingModelId        = (Get-ContractProperty $s 'UnderlyingModelId' $null)
            GatewayProviderId        = (Get-ContractProperty $s 'GatewayProviderId' $null)
            LocalOrRemote            = (Get-ContractProperty $s 'LocalOrRemote' $null)
            Route                    = $groupKey
            SelectedGroupKey         = $groupKey
            CostPerVerifiedSuccess   = (Get-ContractProperty $s 'ObservedCostPerVerifiedSuccess' $null)
            ExpectedCostPerSuccess   = (Get-ContractProperty $s 'ExpectedCostPerVerifiedSuccess' $null)
            AverageAttemptCost       = (Get-ContractProperty $s 'AverageAttemptCost' $null)
            VerifiedSuccessRate      = (Get-ContractProperty $s 'VerifiedSuccessRate' $null)
            AttemptsPerVerifiedSuccess = (Get-ContractProperty $s 'AverageAttemptsPerVerifiedSuccess' $null)
            SampleSize               = (Get-ContractProperty $s 'SampleCount' 0)
            Confidence               = (Get-ContractProperty $s 'ConfidenceLevel' 'INSUFFICIENT')
            Basis                    = $basis
        })
    }

    # rank by cost-per-verified-success (presentation only)
    $arr = @($outRows)
    if ($arr.Count -gt 1) {
        $arr = @($arr | Sort-Object -Property `
            @{ Expression = { $v = Get-ContractProperty $_ 'CostPerVerifiedSuccess' $null; if ($null -eq $v) { [double]::MaxValue } else { [double]$v } }; Ascending = $true }, `
            @{ Expression = { [string](Get-ContractProperty $_ 'Policy' '') }; Ascending = $true })
    }
    $rank = 1
    foreach ($r in $arr) { $r | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -Force; $rank++ }

    return (New-DbM25PolicyComparison -AnalysisId $AnalysisId -Rows @($arr) -Currency $Currency -PolicyVersion '0.0.0')
}

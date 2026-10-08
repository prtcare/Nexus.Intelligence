# ModelPerformance.ps1 — DB-M24 model performance intelligence engine.
#
# Reads AiAttemptRecord v1 (DB-M17) histories and produces DESCRIPTIVE summaries,
# comparisons, failure distributions, and NON-BINDING recommendations. This is
# evidence generation only: no routing policy is read-for-decision, mutated, or
# written. No database is created — every metric is recomputed from the attempt
# records passed in. No pricing is recalculated: cost values are reused from the
# stored attempt evidence (ActualCost / EstimatedCost / CostCurrency) with strict
# common-currency normalization (see design doc).
#
# Contracts + vocabularies live in AiPerformanceContracts.ps1.
# Schema versions are registered in Get-AiPerformanceSchemaVersions.
#
# ADR-005: no business logic branches on provider/model name. Aggregation is keyed
# by data (vocabulary values, identifiers), never by literal provider names.
#
# No AI API calls, no provider calls, no network, no credentials, no writes.

$script:PerfConfidenceBands = $null   # set by AiPerformanceFoundation on import

# --- small helpers ------------------------------------------------------------------

function Get-PerfString {
    param($Record, [string]$Name)
    $v = [string](Get-ContractProperty $Record $Name '')
    if ($v -eq '') { return $null }
    return $v
}

function Get-PerfMean([System.Collections.Generic.List[double]]$Values) {
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $sum = 0d
    foreach ($v in $Values) { $sum += $v }
    return [math]::Round($sum / $Values.Count, 4)
}

function Get-PerfMedian([System.Collections.Generic.List[double]]$Values) {
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $arr = @($Values | Sort-Object)
    $n = $arr.Count
    if ($n % 2 -eq 1) { return [math]::Round([double]$arr[[int]($n / 2)], 4) }
    return [math]::Round((([double]$arr[$n / 2 - 1] + [double]$arr[$n / 2]) / 2), 4)
}

function Get-PerfPercentile([System.Collections.Generic.List[double]]$Values, [double]$P) {
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $arr = @($Values | Sort-Object)
    $n = $arr.Count
    $idx = [int][math]::Ceiling($P * $n) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -gt $n - 1) { $idx = $n - 1 }
    return [math]::Round([double]$arr[$idx], 4)
}

# --- dimension filter -----------------------------------------------------------------

function Test-PerfDimensionMatch {
    <#
    .SYNOPSIS
    Apply the optional dimension filters of a PerformanceQuery to one attempt.
    An unspecified dimension does not filter; a specified dimension must match the
    attempt's value (case-insensitive). A null attempt value fails the match.
    #>
    param($Record, [AllowNull()][pscustomobject]$Query)
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
        @('VerificationResult',(Get-ContractProperty $Query 'VerificationResult' $null)),
        @('FailureCategory',   (Get-ContractProperty $Query 'FailureCategory' $null))
    )
    foreach ($d in $dims) {
        $field = [string]$d[0]
        $q = $d[1]
        if ($null -eq $q -or [string]$q -eq '') { continue }
        $rv = Get-ContractProperty $Record $field $null
        if ($null -eq $rv) { return $false }
        if ([string]$rv -ine [string]$q) { return $false }
    }
    return $true
}

function Resolve-AiFilteredAttempts {
    <#
    .SYNOPSIS
    Apply the PerformanceQuery time window + dimension filters to a record set.
    The attempt's instant is StartedAtUtc; attempts without a start time are
    excluded when a window is specified (and included otherwise).
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
        if (-not (Test-PerfDimensionMatch -Record $r -Query $Query)) { continue }
        $null = $filtered.Add($r)
    }
    return @($filtered)
}

# --- attempt chains ---------------------------------------------------------------------

function Resolve-AiTaskKey {
    <#
    .SYNOPSIS
    The task identity of an attempt: ChangeId (the work unit) when present, else
    TaskId, else the untracked bucket. DB-M17 groups attempts by change; a task's
    attempt chain is reconstructed from these keys + RetryNumber order.
    #>
    param($Record)
    $change = Get-PerfString $Record 'ChangeId'
    if ($change) { return $change }
    $task = Get-PerfString $Record 'TaskId'
    if ($task) { return $task }
    return '(untracked)'
}

function Resolve-AiTaskChains {
    <#
    .SYNOPSIS
    Group attempts by task key and order each chain by RetryNumber asc, then
    StartedAtUtc asc, then AttemptId asc. Returns @( @{ Key; Records } ).
    #>
    param([AllowNull()][object[]]$Records)
    $byTask = @{}
    foreach ($r in $Records) {
        if ($null -eq $r) { continue }
        $key = Resolve-AiTaskKey $r
        if (-not $byTask.ContainsKey($key)) { $byTask[$key] = New-Object System.Collections.ArrayList }
        $null = $byTask[$key].Add($r)
    }
    $chains = New-Object System.Collections.ArrayList
    foreach ($key in @($byTask.Keys)) {
        $list = $byTask[$key].ToArray()
        $sorted = @($list | Sort-Object -Property `
                @{ Expression = { [int](Get-ContractProperty $_ 'RetryNumber' 0) }; Ascending = $true }, `
                @{ Expression = { $ts = ConvertTo-AiPerfUtc (Get-ContractProperty $_ 'StartedAtUtc' $null); if ($ts) { $ts.Ticks } else { [long]::MaxValue } }; Ascending = $true }, `
                @{ Expression = { [string](Get-ContractProperty $_ 'AttemptId' '') }; Ascending = $true })
        $null = $chains.Add(@{ Key = $key; Records = $sorted })
    }
    return @($chains)
}

function Resolve-AiChainFacts {
    <#
    .SYNOPSIS
    Reconstruct the task-level facts of one attempt chain:
      - terminal attempt (the last record with a terminal Result)
      - outcome SUCCESS/FAILURE/INCOMPLETE under the query's success definition
      - first-attempt success, escalation, human intervention, last-attempt instant
    Success definition (see AiPerformanceContracts):
      VERIFIED           -> Result=SUCCESS AND VerificationResult=VERIFIED
      MODEL_RETURNED     -> Result=SUCCESS regardless of verification
      VERIFIED_PREFERRED -> verification evidence is authoritative when present;
                            otherwise a plain SUCCESS counts (flagged unverified)
    #>
    param([hashtable]$Chain, [string]$SuccessDefinition = 'VERIFIED_PREFERRED')
    $recs = @($Chain.Records)
    $facts = @{
        Key                  = $Chain.Key
        Records              = $recs
        AttemptCount         = $recs.Count
        TerminalAttempt      = $null
        Outcome              = 'INCOMPLETE'
        Success              = $false
        Verified             = $false
        ModelReturned        = $false
        FirstAttemptSuccess  = $false
        Escalated            = $false
        HumanIntervention    = $false
        LastAttemptAtUtc     = $null
    }

    $terminal = $null
    foreach ($r in $recs) {
        $res = [string](Get-ContractProperty $r 'Result' '')
        if ($res -in (Get-AiAttemptTerminalStates)) { $terminal = $r }
    }
    if ($null -eq $terminal) { return $facts }
    $facts.TerminalAttempt = $terminal

    $res = [string](Get-ContractProperty $terminal 'Result' '')
    if ($res -eq 'SUCCESS') {
        $facts.ModelReturned = $true
        $vr = [string](Get-ContractProperty $terminal 'VerificationResult' '')
        if ($vr -eq 'VERIFIED') { $facts.Verified = $true }
        if ($SuccessDefinition -eq 'VERIFIED') {
            $facts.Success = $facts.Verified
        } elseif ($SuccessDefinition -eq 'MODEL_RETURNED') {
            $facts.Success = $true
        } else {
            # VERIFIED_PREFERRED: a FAILED verification result contradicts success
            $facts.Success = if ($vr -eq 'FAILED') { $false } else { $true }
        }
        $facts.Outcome = if ($facts.Success) { 'SUCCESS' } else { 'FAILURE' }
    } else {
        $facts.Outcome = 'FAILURE'
    }

    # first attempt success (attempt #1 in chain order)
    if ($recs.Count -gt 0) {
        $first = $recs[0]
        $firstRes = [string](Get-ContractProperty $first 'Result' '')
        if ($firstRes -eq 'SUCCESS') {
            $fv = [string](Get-ContractProperty $first 'VerificationResult' '')
            if ($SuccessDefinition -eq 'VERIFIED') { $facts.FirstAttemptSuccess = ($fv -eq 'VERIFIED') }
            elseif ($SuccessDefinition -eq 'MODEL_RETURNED') { $facts.FirstAttemptSuccess = $true }
            else { $facts.FirstAttemptSuccess = if ($fv -eq 'FAILED') { $false } else { $true } }
        }
    }

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
    return $facts
}

# --- group keys / identity ---------------------------------------------------------------

function Resolve-AiGroupKey {
    <#
    .SYNOPSIS
    The aggregation key of one attempt for a GroupBy dimension. ModelRoute keys on
    the delivery route (provider | model | gateway); every other grouping keys on
    the single dimension value.
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
    }
    throw "Unsupported GroupBy '$GroupBy'"
}

function Resolve-AiGroupIdentity {
    <#
    .SYNOPSIS
    Populate the identity fields of a summary from the group's first attempt. Every
    dimension field is carried from that attempt regardless of the grouping key, so
    a ModelRoute summary also carries the task-type / complexity / risk / reasoning
    attributes of its representative attempt (the group key itself is derived from
    the grouping dimension; see Resolve-AiGroupKey).
    #>
    param([string]$GroupBy, [AllowNull()][object[]]$Attempts)
    $id = @{ ProviderId = $null; ModelId = $null; UnderlyingModelId = $null; GatewayProviderId = $null; TaskType = $null; Complexity = $null; Risk = $null; ReasoningLevel = $null; ExecutionMode = $null }
    $first = $null
    foreach ($a in @($Attempts)) { $first = $a; break }
    if ($null -eq $first) { return $id }
    $id.ProviderId = Get-PerfString $first 'ProviderId'
    $id.ModelId = Get-PerfString $first 'ModelId'
    $id.UnderlyingModelId = Get-PerfString $first 'UnderlyingModelId'
    $id.GatewayProviderId = Get-PerfString $first 'GatewayProviderId'
    $id.TaskType = Get-PerfString $first 'TaskType'
    $id.Complexity = Get-PerfString $first 'Complexity'
    $id.Risk = Get-PerfString $first 'Risk'
    $id.ReasoningLevel = Get-PerfString $first 'ReasoningLevel'
    $id.ExecutionMode = Get-PerfString $first 'ExecutionMode'
    return $id
}

# --- per-group summary builder ------------------------------------------------------------

function New-AiPerformanceGroupSummary {
    <#
    .SYNOPSIS
    Compute the full ModelPerformanceSummary v1 for ONE group from its attempts
    (attempt-level metrics) and its attributed task facts (task-level metrics).
    Cost normalization: only attempts whose CostCurrency equals the query's
    ReportingCurrency contribute to cost metrics; everything else is excluded with
    a warning. ActualCost is preferred; EstimatedCost is used only when the query
    allows estimated-cost fallback.
    #>
    param(
        [string]$GroupBy,
        [string]$GroupKey,
        [AllowNull()][object[]]$Attempts,
        [AllowNull()][object[]]$TaskFacts,
        [int]$IncompleteCount = 0,
        [string]$SuccessDefinition = 'VERIFIED_PREFERRED',
        [string]$ReportingCurrency = 'INR',
        [bool]$AllowEstimatedFallback = $false
    )
    $attempts = @($Attempts)
    $taskFacts = @($TaskFacts)
    $id = Resolve-AiGroupIdentity -GroupBy $GroupBy -Attempts $attempts
    $reportingUpper = $ReportingCurrency.ToUpperInvariant()

    # ---- attempt-level accumulators ------------------------------------------------
    $durations   = New-Object System.Collections.Generic.List[double]
    $actCosts    = New-Object System.Collections.Generic.List[double]
    $estCosts    = New-Object System.Collections.Generic.List[double]
    $inputTokens = New-Object System.Collections.Generic.List[double]
    $outputTokens = New-Object System.Collections.Generic.List[double]
    $contextTokens = New-Object System.Collections.Generic.List[double]

    $failureCounts = @{}
    foreach ($cat in (Get-AiAttemptFailureCategories)) { $failureCounts[$cat] = 0 }

    $usableCostSum = 0d
    $costSampleCount = 0
    $estimatedFallbackUsed = 0
    $missingCost = 0
    $currencyMismatch = 0
    $fallbackDisabled = 0

    foreach ($r in $attempts) {
        $dur = Get-ContractProperty $r 'DurationMs' $null
        if ($null -ne $dur) { $durations.Add([double]$dur) }

        $in = Get-ContractProperty $r 'InputTokens' $null
        if ($null -ne $in) { $inputTokens.Add([double]$in) }
        $ot = Get-ContractProperty $r 'OutputTokens' $null
        if ($null -ne $ot) { $outputTokens.Add([double]$ot) }
        $ct = Get-ContractProperty $r 'ContextTokens' $null
        if ($null -ne $ct) { $contextTokens.Add([double]$ct) }

        $res = [string](Get-ContractProperty $r 'Result' '')
        $fc = Get-PerfString $r 'FailureCategory'
        if ($res -ne 'SUCCESS') {
            if ($fc) { if ($failureCounts.ContainsKey($fc)) { $failureCounts[$fc] = [int]$failureCounts[$fc] + 1 } }
            else { $failureCounts['UNKNOWN'] = [int]$failureCounts['UNKNOWN'] + 1 }
        }

        # cost evidence (common-currency normalization)
        $act = Get-ContractProperty $r 'ActualCost' $null
        $est = Get-ContractProperty $r 'EstimatedCost' $null
        $cc = Get-PerfString $r 'CostCurrency'
        $currencyOk = ($cc -and ($cc.ToUpperInvariant() -eq $reportingUpper))
        $usable = $false

        if ($null -ne $act -and $currencyOk) {
            $actCosts.Add([double]$act)
            $usableCostSum += [double]$act
            $costSampleCount++
            $usable = $true
        }
        if ($null -ne $est -and $currencyOk) { $estCosts.Add([double]$est) }
        if (-not $usable -and $AllowEstimatedFallback -and $null -ne $est -and $currencyOk) {
            $usableCostSum += [double]$est
            $costSampleCount++
            $estimatedFallbackUsed++
            $usable = $true
        }
        if (-not $usable) {
            if (($null -ne $act -or $null -ne $est) -and -not $currencyOk) { $currencyMismatch++ }
            elseif ($null -ne $est -and -not $AllowEstimatedFallback) { $fallbackDisabled++ }
            else { $missingCost++ }
        }
    }

    # ---- task-level accumulators (attributed chains) ---------------------------------
    $successCount = 0
    $failureCount = 0
    $firstAttemptSuccess = 0
    $escalation = 0
    $humanIntervention = 0
    $verifiedSuccess = 0
    $modelReturnedSuccess = 0
    $attemptsPerSuccess = New-Object System.Collections.Generic.List[double]
    $costPerSuccess = New-Object System.Collections.Generic.List[double]
    $lastAttempt = $null

    foreach ($f in $taskFacts) {
        # chain cost = sum of usable cost evidence across the chain's attempts
        $chainCost = 0d
        $chainCostOk = $false
        foreach ($r in $f.Records) {
            $act = Get-ContractProperty $r 'ActualCost' $null
            $est = Get-ContractProperty $r 'EstimatedCost' $null
            $cc = Get-PerfString $r 'CostCurrency'
            $currencyOk = ($cc -and ($cc.ToUpperInvariant() -eq $reportingUpper))
            if ($null -ne $act -and $currencyOk) { $chainCost += [double]$act; $chainCostOk = $true }
            elseif ($AllowEstimatedFallback -and $null -ne $est -and $currencyOk) { $chainCost += [double]$est; $chainCostOk = $true }
        }
        if ($f.Outcome -eq 'SUCCESS') {
            $successCount++
            if ($f.Verified) { $verifiedSuccess++ }
            if ($f.ModelReturned) { $modelReturnedSuccess++ }
            if ($f.AttemptCount -ge 1) { $attemptsPerSuccess.Add([double]$f.AttemptCount) }
            if ($chainCostOk) { $costPerSuccess.Add($chainCost) }
        } else {
            $failureCount++
        }
        if ($f.FirstAttemptSuccess) { $firstAttemptSuccess++ }
        if ($f.Escalated) { $escalation++ }
        if ($f.HumanIntervention) { $humanIntervention++ }
        if ($f.LastAttemptAtUtc -and ($null -eq $lastAttempt -or $f.LastAttemptAtUtc -gt $lastAttempt)) { $lastAttempt = $f.LastAttemptAtUtc }
    }

    $sampleCount = $taskFacts.Count
    $successRate = if ($sampleCount -gt 0) { [math]::Round($successCount / $sampleCount, 4) } else { $null }
    $firstAttemptSuccessRate = if ($sampleCount -gt 0) { [math]::Round($firstAttemptSuccess / $sampleCount, 4) } else { $null }
    $escalationRate = if ($sampleCount -gt 0) { [math]::Round($escalation / $sampleCount, 4) } else { $null }

    $provFailure = 0
    foreach ($cat in (Get-AiProviderFailureCategories)) { $provFailure += [int]$failureCounts[$cat] }
    $otherFailure = 0
    foreach ($cat in @('TOOL_FAILURE', 'VALIDATION_FAILURE', 'UNKNOWN')) { $otherFailure += [int]$failureCounts[$cat] }

    $confidence = Get-AiConfidenceLevel -SampleCount $sampleCount -Bands $script:PerfConfidenceBands

    $warnings = New-Object System.Collections.Generic.List[string]
    if ($sampleCount -eq 0) { $warnings.Add('No terminal tasks in this group (cold start).') }
    elseif ($confidence -eq 'INSUFFICIENT') { $warnings.Add("Small sample ($sampleCount task(s)); confidence INSUFFICIENT.") }
    elseif ($confidence -eq 'LOW') { $warnings.Add("Small sample ($sampleCount task(s)); confidence LOW.") }
    if ($IncompleteCount -gt 0) { $warnings.Add("$IncompleteCount task(s) had no terminal attempt and were excluded from task-level outcome metrics.") }
    if ($missingCost -gt 0) { $warnings.Add("$missingCost attempt(s) had no cost evidence and were excluded from cost metrics.") }
    if ($currencyMismatch -gt 0) { $warnings.Add("$currencyMismatch attempt(s) had cost evidence in a currency other than $reportingUpper and were excluded from cost metrics (historic evidence is never re-converted).") }
    if ($fallbackDisabled -gt 0) { $warnings.Add("$fallbackDisabled attempt(s) had estimated cost only and were excluded because estimated-cost fallback is disabled for this query.") }
    if ($estimatedFallbackUsed -gt 0) { $warnings.Add("Estimated-cost fallback used for $estimatedFallbackUsed attempt(s).") }

    $lastAttemptStr = if ($lastAttempt) { $lastAttempt.ToString('o') } else { $null }

    return (New-AiModelPerformanceSummary -Fields @{
        ProviderId                        = $id.ProviderId
        ModelId                           = $id.ModelId
        UnderlyingModelId                 = $id.UnderlyingModelId
        GatewayProviderId                 = $id.GatewayProviderId
        TaskType                          = $id.TaskType
        Complexity                        = $id.Complexity
        Risk                              = $id.Risk
        ReasoningLevel                    = $id.ReasoningLevel
        ExecutionMode                     = $id.ExecutionMode
        SampleCount                       = $sampleCount
        AttemptCount                      = $attempts.Count
        SuccessCount                      = $successCount
        FailureCount                      = $failureCount
        IncompleteCount                   = $IncompleteCount
        FirstAttemptSuccessCount          = $firstAttemptSuccess
        EscalationCount                   = $escalation
        HumanInterventionCount            = $humanIntervention
        ModelQualityFailureCount          = [int]$failureCounts['MODEL_QUALITY']
        ProviderFailureCount              = $provFailure
        BuildFailureCount                 = [int]$failureCounts['BUILD_FAILURE']
        TestFailureCount                  = [int]$failureCounts['TEST_FAILURE']
        ContextFailureCount               = [int]$failureCounts['CONTEXT_FAILURE']
        BudgetFailureCount                = [int]$failureCounts['BUDGET_FAILURE']
        OtherFailureCount                 = $otherFailure
        FailureCategoryCounts             = $failureCounts
        AverageAttemptsPerSuccessfulTask  = (Get-PerfMean $attemptsPerSuccess)
        AverageDurationMs                 = (Get-PerfMean $durations)
        MedianDurationMs                  = (Get-PerfMedian $durations)
        P95DurationMs                     = (Get-PerfPercentile $durations 0.95)
        AverageEstimatedCost              = (Get-PerfMean $estCosts)
        AverageActualCost                 = (Get-PerfMean $actCosts)
        AverageCostPerAttempt             = if ($costSampleCount -gt 0) { [math]::Round($usableCostSum / $costSampleCount, 4) } else { $null }
        AverageCostPerSuccessfulTask      = (Get-PerfMean $costPerSuccess)
        AverageInputTokens                = (Get-PerfMean $inputTokens)
        AverageOutputTokens               = (Get-PerfMean $outputTokens)
        AverageContextTokens              = (Get-PerfMean $contextTokens)
        SuccessRate                       = $successRate
        FirstAttemptSuccessRate           = $firstAttemptSuccessRate
        EscalationRate                    = $escalationRate
        VerifiedSuccessCount              = $verifiedSuccess
        ModelReturnedSuccessCount         = $modelReturnedSuccess
        SuccessDefinition                 = $SuccessDefinition
        ReportingCurrency                 = $reportingUpper
        CostSampleCount                   = $costSampleCount
        DurationSampleCount               = $durations.Count
        EstimatedCostFallbackUsed         = $estimatedFallbackUsed
        CostExcludedCount                 = ($missingCost + $currencyMismatch + $fallbackDisabled)
        LastAttemptAtUtc                  = $lastAttemptStr
        ConfidenceLevel                   = $confidence
        Warnings                          = @($warnings)
    })
}

# --- core aggregation ---------------------------------------------------------------------

function Get-AiPerformanceSummaries {
    <#
    .SYNOPSIS
    Core aggregation: filter attempts by the PerformanceQuery, reconstruct task
    chains, and produce one ModelPerformanceSummary per group.
    #>
    param(
        [AllowNull()][object[]]$Records,
        [AllowNull()][pscustomobject]$Query,
        [string]$GroupBy = 'ModelRoute'
    )
    if ($null -eq $Query) { $Query = New-AiPerformanceQuery }
    $qv = Test-AiPerformanceQuery $Query
    if (-not $qv.Valid) { throw ("Invalid PerformanceQuery: " + ($qv.Errors -join '; ')) }
    if ($GroupBy -notin (Get-AiPerformanceGroupBys)) { throw "GroupBy '$GroupBy' is not a supported performance grouping" }

    $successDefinition = [string](Get-ContractProperty $Query 'SuccessDefinition' 'VERIFIED_PREFERRED')
    $reportingCurrency = [string](Get-ContractProperty $Query 'ReportingCurrency' 'INR')
    $allowEstimated = [bool](Get-ContractProperty $Query 'AllowEstimatedCostFallback' $false)

    # @(...) around a call is deliberate: an empty result collapses to $null
    # through the pipeline, and strict-mode callers must still see an array.
    $filtered = @(Resolve-AiFilteredAttempts -Records $Records -Query $Query)
    if ($filtered.Count -eq 0) { return @() }

    $chains = @(Resolve-AiTaskChains $filtered)

    $groupAttempts = @{}
    foreach ($r in $filtered) {
        $gk = Resolve-AiGroupKey $r $GroupBy
        if (-not $groupAttempts.ContainsKey($gk)) { $groupAttempts[$gk] = New-Object System.Collections.ArrayList }
        $null = $groupAttempts[$gk].Add($r)
    }

    $groupFacts = @{}
    $groupIncomplete = @{}
    foreach ($chain in $chains) {
        $facts = Resolve-AiChainFacts -Chain $chain -SuccessDefinition $successDefinition
        if ($null -eq $facts.TerminalAttempt) {
            $seen = @{}
            foreach ($r in $facts.Records) {
                $gk = Resolve-AiGroupKey $r $GroupBy
                if ($seen.ContainsKey($gk)) { continue }
                $seen[$gk] = $true
                if (-not $groupIncomplete.ContainsKey($gk)) { $groupIncomplete[$gk] = New-Object System.Collections.ArrayList }
                $null = $groupIncomplete[$gk].Add($facts.Key)
            }
            continue
        }
        $gk = Resolve-AiGroupKey $facts.TerminalAttempt $GroupBy
        if (-not $groupFacts.ContainsKey($gk)) { $groupFacts[$gk] = New-Object System.Collections.ArrayList }
        $null = $groupFacts[$gk].Add($facts)
    }

    $keys = @{}
    foreach ($k in @($groupAttempts.Keys)) { $keys[$k] = $true }
    foreach ($k in @($groupFacts.Keys)) { $keys[$k] = $true }
    foreach ($k in @($groupIncomplete.Keys)) { $keys[$k] = $true }

    $summaries = New-Object System.Collections.ArrayList
    foreach ($gk in @($keys.Keys)) {
        # @($hashtable[$missingKey]) yields a one-null array, not empty; guard.
        $attempts = @()
        if ($groupAttempts.ContainsKey($gk)) { $attempts = @($groupAttempts[$gk]) }
        $factsList = @()
        if ($groupFacts.ContainsKey($gk)) { $factsList = @($groupFacts[$gk]) }
        $incomplete = 0
        if ($groupIncomplete.ContainsKey($gk)) { $incomplete = @($groupIncomplete[$gk]).Count }
        $s = New-AiPerformanceGroupSummary -GroupBy $GroupBy -GroupKey $gk `
            -Attempts $attempts -TaskFacts $factsList -IncompleteCount $incomplete `
            -SuccessDefinition $successDefinition -ReportingCurrency $reportingCurrency `
            -AllowEstimatedFallback $allowEstimated
        $null = $summaries.Add($s)
    }
    return @($summaries)
}

# --- public operations (conceptually per the milestone brief) ---------------------------------

function Get-AiModelPerformance {
    <#
    .SYNOPSIS
    One ModelPerformanceSummary per model delivery route (provider|model|gateway).
    Answers: which models succeed most often, first-attempt success, retries,
    escalation, duration, cost per attempt, cost per successful task.
    #>
    param([AllowNull()][object[]]$Records, [AllowNull()][pscustomobject]$Query)
    return Get-AiPerformanceSummaries -Records $Records -Query $Query -GroupBy 'ModelRoute'
}

function Get-AiTaskTypePerformance {
    <#
    .SYNOPSIS
    One ModelPerformanceSummary per TaskType. Combine with a ModelId/ProviderId
    dimension on the query to ask e.g. "how does DeepSeek Flash perform on
    CODE_IMPLEMENTATION?" (filter the model, group by task type).
    #>
    param([AllowNull()][object[]]$Records, [AllowNull()][pscustomobject]$Query)
    return Get-AiPerformanceSummaries -Records $Records -Query $Query -GroupBy 'TaskType'
}

function Get-AiFailureDistribution {
    <#
    .SYNOPSIS
    Attempt-level failure-category distribution over the query-filtered attempts,
    with the provider-vs-model-quality separation (a provider outage never lowers
    a model's intellectual-quality count).
    #>
    param([AllowNull()][object[]]$Records, [AllowNull()][pscustomobject]$Query)
    if ($null -eq $Query) { $Query = New-AiPerformanceQuery }
    $filtered = @(Resolve-AiFilteredAttempts -Records $Records -Query $Query)
    $byCategory = @{}
    foreach ($cat in (Get-AiAttemptFailureCategories)) { $byCategory[$cat] = 0 }
    $failed = 0
    foreach ($r in $filtered) {
        $res = [string](Get-ContractProperty $r 'Result' '')
        if ($res -eq 'SUCCESS') { continue }
        $failed++
        $fc = Get-PerfString $r 'FailureCategory'
        if ($fc -and $byCategory.ContainsKey($fc)) { $byCategory[$fc] = [int]$byCategory[$fc] + 1 }
        else { $byCategory['UNKNOWN'] = [int]$byCategory['UNKNOWN'] + 1 }
    }
    $provFailure = 0
    foreach ($cat in (Get-AiProviderFailureCategories)) { $provFailure += [int]$byCategory[$cat] }
    return [pscustomobject]@{
        SchemaVersion       = 1
        TotalAttempts       = $filtered.Count
        FailedAttempts      = $failed
        ByCategory          = $byCategory
        ModelQuality        = [int]$byCategory['MODEL_QUALITY']
        Provider            = $provFailure
        RateLimit           = [int]$byCategory['RATE_LIMIT']
        Build               = [int]$byCategory['BUILD_FAILURE']
        Test                = [int]$byCategory['TEST_FAILURE']
        Context             = [int]$byCategory['CONTEXT_FAILURE']
        Budget              = [int]$byCategory['BUDGET_FAILURE']
        Other               = ([int]$byCategory['TOOL_FAILURE'] + [int]$byCategory['VALIDATION_FAILURE'] + [int]$byCategory['UNKNOWN'])
        Note                = 'Provider = PROVIDER_AVAILABILITY + RATE_LIMIT + AUTHENTICATION (delivery-path failures, kept separate from MODEL_QUALITY).'
    }
}

function Get-AiCostPerSuccessfulTask {
    <#
    .SYNOPSIS
    Cost-focused per-model-route rows. A successful TASK's cost is the sum of the
    usable cost evidence of every attempt in its chain (failed attempts included);
    the task is attributed to the model route of its terminal attempt. Only costs
    already stored in the query's reporting currency are reused.
    #>
    param([AllowNull()][object[]]$Records, [AllowNull()][pscustomobject]$Query)
    $summaries = @(Get-AiModelPerformance -Records $Records -Query $Query)
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $summaries) {
        $null = $out.Add([pscustomobject]@{
            SchemaVersion                   = 1
            ProviderId                      = (Get-ContractProperty $s 'ProviderId' $null)
            ModelId                         = (Get-ContractProperty $s 'ModelId' $null)
            UnderlyingModelId               = (Get-ContractProperty $s 'UnderlyingModelId' $null)
            GatewayProviderId               = (Get-ContractProperty $s 'GatewayProviderId' $null)
            SampleCount                     = (Get-ContractProperty $s 'SampleCount' 0)
            SuccessfulTaskCount             = (Get-ContractProperty $s 'SuccessCount' 0)
            Currency                        = (Get-ContractProperty $s 'ReportingCurrency' $null)
            AverageCostPerAttempt           = (Get-ContractProperty $s 'AverageCostPerAttempt' $null)
            AverageCostPerSuccessfulTask    = (Get-ContractProperty $s 'AverageCostPerSuccessfulTask' $null)
            CostSampleCount                 = (Get-ContractProperty $s 'CostSampleCount' 0)
            EstimatedCostFallbackUsed       = (Get-ContractProperty $s 'EstimatedCostFallbackUsed' 0)
            ConfidenceLevel                 = (Get-ContractProperty $s 'ConfidenceLevel' 'INSUFFICIENT')
            Warnings                        = @(Get-ContractProperty $s 'Warnings' @())
        })
    }
    return @($out)
}

function Get-AiFirstAttemptSuccessRate {
    <#
    .SYNOPSIS
    First-attempt-success rate per model route (task whose attempt #1 succeeded
    under the query's success definition / SampleCount).
    #>
    param([AllowNull()][object[]]$Records, [AllowNull()][pscustomobject]$Query)
    $summaries = @(Get-AiModelPerformance -Records $Records -Query $Query)
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $summaries) {
        $null = $out.Add([pscustomobject]@{
            SchemaVersion             = 1
            ProviderId                = (Get-ContractProperty $s 'ProviderId' $null)
            ModelId                   = (Get-ContractProperty $s 'ModelId' $null)
            UnderlyingModelId         = (Get-ContractProperty $s 'UnderlyingModelId' $null)
            GatewayProviderId         = (Get-ContractProperty $s 'GatewayProviderId' $null)
            SampleCount               = (Get-ContractProperty $s 'SampleCount' 0)
            FirstAttemptSuccessCount  = (Get-ContractProperty $s 'FirstAttemptSuccessCount' 0)
            FirstAttemptSuccessRate   = (Get-ContractProperty $s 'FirstAttemptSuccessRate' $null)
            ConfidenceLevel           = (Get-ContractProperty $s 'ConfidenceLevel' 'INSUFFICIENT')
        })
    }
    return @($out)
}

function Get-AiEscalationRate {
    <#
    .SYNOPSIS
    Escalation rate per model route (tasks whose chain records an escalation link /
    SampleCount). Escalation is a task-chain property; it is analyzed from recorded
    history only and never executed.
    #>
    param([AllowNull()][object[]]$Records, [AllowNull()][pscustomobject]$Query)
    $summaries = @(Get-AiModelPerformance -Records $Records -Query $Query)
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $summaries) {
        $null = $out.Add([pscustomobject]@{
            SchemaVersion     = 1
            ProviderId        = (Get-ContractProperty $s 'ProviderId' $null)
            ModelId           = (Get-ContractProperty $s 'ModelId' $null)
            UnderlyingModelId = (Get-ContractProperty $s 'UnderlyingModelId' $null)
            GatewayProviderId = (Get-ContractProperty $s 'GatewayProviderId' $null)
            SampleCount       = (Get-ContractProperty $s 'SampleCount' 0)
            EscalationCount   = (Get-ContractProperty $s 'EscalationCount' 0)
            EscalationRate    = (Get-ContractProperty $s 'EscalationRate' $null)
            ConfidenceLevel   = (Get-ContractProperty $s 'ConfidenceLevel' 'INSUFFICIENT')
        })
    }
    return @($out)
}

# --- comparison ---------------------------------------------------------------------------

function Compare-AiModelPerformance {
    <#
    .SYNOPSIS
    Ranked, side-by-side ModelComparison v1 of the supplied summaries, sorted by one
    metric. PRESENTATION ONLY — no winner is chosen here (DB-M19 decides with the
    recommendation as non-binding evidence).
    #>
    param(
        [AllowNull()][object[]]$Summaries,
        [string]$SortBy = 'SuccessRate',
        [string]$Direction = 'DESCENDING'
    )
    $validMetrics = @('SuccessRate', 'FirstAttemptSuccessRate', 'EscalationRate',
        'AverageDurationMs', 'MedianDurationMs', 'P95DurationMs',
        'AverageCostPerSuccessfulTask', 'AverageCostPerAttempt', 'SampleCount', 'SuccessCount')
    if ($SortBy -notin $validMetrics) { throw "SortBy '$SortBy' is not a supported comparison metric" }
    $direction = $Direction.ToUpperInvariant()
    if ($direction -notin @('ASCENDING', 'DESCENDING')) { throw "Direction '$direction' invalid" }

    $rows = New-Object System.Collections.ArrayList
    foreach ($s in @($Summaries)) {
        if ($null -eq $s) { continue }
        $null = $rows.Add([pscustomobject]@{
            SchemaVersion                  = 1
            ProviderId                     = (Get-ContractProperty $s 'ProviderId' $null)
            ModelId                        = (Get-ContractProperty $s 'ModelId' $null)
            UnderlyingModelId              = (Get-ContractProperty $s 'UnderlyingModelId' $null)
            GatewayProviderId              = (Get-ContractProperty $s 'GatewayProviderId' $null)
            SampleCount                    = (Get-ContractProperty $s 'SampleCount' 0)
            ConfidenceLevel                = (Get-ContractProperty $s 'ConfidenceLevel' 'INSUFFICIENT')
            SuccessRate                    = (Get-ContractProperty $s 'SuccessRate' $null)
            FirstAttemptSuccessRate        = (Get-ContractProperty $s 'FirstAttemptSuccessRate' $null)
            AverageAttemptsPerSuccessfulTask = (Get-ContractProperty $s 'AverageAttemptsPerSuccessfulTask' $null)
            AverageCostPerSuccessfulTask   = (Get-ContractProperty $s 'AverageCostPerSuccessfulTask' $null)
            AverageDurationMs              = (Get-ContractProperty $s 'AverageDurationMs' $null)
            EscalationRate                 = (Get-ContractProperty $s 'EscalationRate' $null)
            Value                          = (Get-ContractProperty $s $SortBy $null)
        })
    }
    $arr = @($rows)
    if ($arr.Count -gt 1) {
        $tie = @{ Expression = { [string](Get-ContractProperty $_ 'ModelId' '') }; Ascending = $true }
        if ($direction -eq 'ASCENDING') {
            $arr = @($arr | Sort-Object -Property @{ Expression = { [double](Get-ContractProperty $_ 'Value' 0) }; Ascending = $true }, $tie)
        } else {
            $arr = @($arr | Sort-Object -Property @{ Expression = { [double](Get-ContractProperty $_ 'Value' 0) }; Descending = $true }, $tie)
        }
    }
    $rank = 1
    foreach ($r in $arr) {
        $r | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -Force
        $rank++
    }
    return (New-AiModelComparison -SortBy $SortBy -Direction $direction -Rows @($arr) -SourceSummaries @($Summaries))
}

# --- recommendation (evidence only) ---------------------------------------------------------

function Get-AiPerformanceRecommendation {
    <#
    .SYNOPSIS
    Non-binding, evidence-backed recommendation. Requires the summaries of at least
    one model route with a qualifying sample; returns INSUFFICIENT_DATA on cold
    start or when no route meets the type-specific metric requirements. NEVER
    mutates routing policy (PolicyVersion stays the immutable DB-M14 '0.0.0').
    #>
    param(
        [AllowNull()][object[]]$Records,
        [AllowNull()][pscustomobject]$Query,
        [AllowNull()][object[]]$Summaries,
        [string]$RecommendationType = 'BEST_COST_PER_SUCCESS',
        [string]$MinimumConfidenceLevel = 'LOW'
    )
    if ($null -ne $Summaries) { $summaries = @($Summaries) }
    elseif ($null -ne $Records) { $summaries = @(Get-AiModelPerformance -Records $Records -Query $Query) }
    else { throw 'Records/Query or Summaries are required' }

    $type = $RecommendationType.ToUpperInvariant()
    if ($type -notin (Get-AiRecommendationTypes)) { throw "RecommendationType '$type' invalid" }
    if ($type -eq 'INSUFFICIENT_DATA') {
        return (New-AiPerformanceRecommendation -RecommendationType 'INSUFFICIENT_DATA' -Reason 'Caller requested INSUFFICIENT_DATA (no recommendation).')
    }
    $minLevel = $MinimumConfidenceLevel.ToUpperInvariant()
    if ($minLevel -notin (Get-AiConfidenceLevels)) { throw "MinimumConfidenceLevel '$minLevel' invalid" }
    $order = Get-AiConfidenceOrder

    $maxSample = 0
    $candidates = New-Object System.Collections.ArrayList
    foreach ($s in $summaries) {
        $sample = [int](Get-ContractProperty $s 'SampleCount' 0)
        if ($sample -gt $maxSample) { $maxSample = $sample }
        $conf = [string](Get-ContractProperty $s 'ConfidenceLevel' 'INSUFFICIENT')
        if ($sample -lt 1) { continue }
        if ([int]$order[$conf] -lt [int]$order[$minLevel]) { continue }
        $ok = $true
        switch ($type) {
            'HIGHEST_SUCCESS'        { if ($null -eq (Get-ContractProperty $s 'SuccessRate' $null)) { $ok = $false } }
            'FASTEST'                { if ($null -eq (Get-ContractProperty $s 'AverageDurationMs' $null)) { $ok = $false } }
            'CHEAPEST_RELIABLE'      { if ($null -eq (Get-ContractProperty $s 'AverageCostPerSuccessfulTask' $null)) { $ok = $false } }
            'BEST_COST_PER_SUCCESS'  { if ($null -eq (Get-ContractProperty $s 'AverageCostPerSuccessfulTask' $null)) { $ok = $false } }
        }
        if ($ok) { $null = $candidates.Add($s) }
    }

    if ($candidates.Count -eq 0) {
        $warn = New-Object System.Collections.Generic.List[string]
        if ($maxSample -eq 0) { $warn.Add('Cold start: no attempt history satisfies the query.') }
        else { $warn.Add("Insufficient qualifying evidence: no model route meets the $minLevel confidence / metric requirements (max sample observed: $maxSample).") }
        return (New-AiPerformanceRecommendation -RecommendationType 'INSUFFICIENT_DATA' `
            -Reason 'Not enough qualifying history to support a recommendation (cold start or small sample).' `
            -EvidenceSampleCount $maxSample -ConfidenceLevel 'INSUFFICIENT' `
            -Warnings @($warn) -PolicyVersion '0.0.0')
    }

    $winner = $null
    switch ($type) {
        'HIGHEST_SUCCESS' {
            $winner = @($candidates | Sort-Object -Descending -Property @{ Expression = { [double](Get-ContractProperty $_ 'SuccessRate' 0) } }, @{ Expression = { [string](Get-ContractProperty $_ 'ModelId' '') }; Ascending = $true })[0]
        }
        'FASTEST' {
            $winner = @($candidates | Sort-Object -Property @{ Expression = { [double](Get-ContractProperty $_ 'AverageDurationMs' 0) } }, @{ Expression = { [string](Get-ContractProperty $_ 'ModelId' '') }; Ascending = $true })[0]
        }
        'CHEAPEST_RELIABLE' {
            $reliable = @($candidates | Where-Object { [double](Get-ContractProperty $_ 'SuccessRate' 0) -ge 0.8 })
            if ($reliable.Count -eq 0) { $reliable = @($candidates) }
            $winner = @($reliable | Sort-Object -Property @{ Expression = { [double](Get-ContractProperty $_ 'AverageCostPerSuccessfulTask' 0) } }, @{ Expression = { [string](Get-ContractProperty $_ 'ModelId' '') }; Ascending = $true })[0]
        }
        'BEST_COST_PER_SUCCESS' {
            $winner = @($candidates | Sort-Object -Property @{ Expression = { [double](Get-ContractProperty $_ 'AverageCostPerSuccessfulTask' 0) } }, @{ Expression = { [string](Get-ContractProperty $_ 'ModelId' '') }; Ascending = $true })[0]
        }
    }

    $compared = New-Object System.Collections.ArrayList
    foreach ($s in $candidates) {
        $null = $compared.Add([pscustomobject]@{
            ModelId                       = (Get-ContractProperty $s 'ModelId' $null)
            ProviderId                    = (Get-ContractProperty $s 'ProviderId' $null)
            UnderlyingModelId             = (Get-ContractProperty $s 'UnderlyingModelId' $null)
            GatewayProviderId             = (Get-ContractProperty $s 'GatewayProviderId' $null)
            SampleCount                   = (Get-ContractProperty $s 'SampleCount' 0)
            ConfidenceLevel               = (Get-ContractProperty $s 'ConfidenceLevel' 'INSUFFICIENT')
            SuccessRate                   = (Get-ContractProperty $s 'SuccessRate' $null)
            FirstAttemptSuccessRate       = (Get-ContractProperty $s 'FirstAttemptSuccessRate' $null)
            AverageCostPerSuccessfulTask  = (Get-ContractProperty $s 'AverageCostPerSuccessfulTask' $null)
            AverageDurationMs             = (Get-ContractProperty $s 'AverageDurationMs' $null)
            EscalationRate                = (Get-ContractProperty $s 'EscalationRate' $null)
            CostCurrency                  = (Get-ContractProperty $s 'ReportingCurrency' $null)
        })
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    $excluded = $summaries.Count - $candidates.Count
    if ($excluded -gt 0) { $warnings.Add("$excluded model route(s) excluded from comparison (below $minLevel confidence or missing metric data).") }

    return (New-AiPerformanceRecommendation -RecommendationType $type `
        -RecommendedModelId (Get-ContractProperty $winner 'ModelId' $null) `
        -ProviderId (Get-ContractProperty $winner 'ProviderId' $null) `
        -UnderlyingModelId (Get-ContractProperty $winner 'UnderlyingModelId' $null) `
        -GatewayProviderId (Get-ContractProperty $winner 'GatewayProviderId' $null) `
        -Reason 'Evidence-backed, non-binding suggestion from recorded attempt history.' `
        -EvidenceSampleCount ([int](Get-ContractProperty $winner 'SampleCount' 0)) `
        -ConfidenceLevel ([string](Get-ContractProperty $winner 'ConfidenceLevel' 'INSUFFICIENT')) `
        -ComparedModels @($compared) `
        -ExpectedSuccessRate (Get-ContractProperty $winner 'SuccessRate' $null) `
        -ExpectedFirstAttemptSuccess (Get-ContractProperty $winner 'FirstAttemptSuccessRate' $null) `
        -ExpectedCostPerSuccess (Get-ContractProperty $winner 'AverageCostPerSuccessfulTask' $null) `
        -ExpectedDuration (Get-ContractProperty $winner 'AverageDurationMs' $null) `
        -Warnings @($warnings) -PolicyVersion '0.0.0')
}

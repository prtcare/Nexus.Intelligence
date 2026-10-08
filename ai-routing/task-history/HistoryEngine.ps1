# HistoryEngine.ps1 -- DB-M29 task cost / attempt / escalation history engine.
#
# PURE view builder. Takes AiAttemptRecord v1 records (DB-M17), an optional
# DB-M20 EscalationDecision list, an optional DB-M21 FailureFingerprint list and
# an optional DB-M22 ProviderHealthEvidence list, plus a TaskHistoryQuery v1, and
# returns a TaskHistoryView v1. Writes NOTHING; reads no database (the caller
# supplies the records via the DB-M17 query layer).
#
# Reuse READ-ONLY:
#   DB-M17  AiAttemptRecord v1 contracts + attempt vocabulary
#   DB-M20  New-EscalationChain (chain ordering + escalation events + loop-free)
#   DB-M24  Resolve-AiTaskChains / Resolve-AiChainFacts (task facts)
#   DB-M25  Resolve-DbM25VerifiedSuccess (authoritative) / Resolve-DbM25RecordCost
#           (DB-M16 semantics)
#   DB-M21  FailureFingerprint v1 (optional per-node evidence)
# Every number is DB-M16/DB-M17 evidence, never a recomputed cost formula.
#
# AUTO_EXECUTION_ENABLED = FALSE. No AI/provider/paid/network calls, no writes,
# no secrets stored.

. (Join-Path $PSScriptRoot "HistoryContracts.ps1")   # DB-M29 contracts + DB-M14/17/20/21/23/24/25 (READ-ONLY)
. (Join-Path $PSScriptRoot "..\quality-cost\QualityCost.ps1")  # DB-M25 engine: Resolve-DbM25RecordCost / Get-DbM25ChainCost (READ-ONLY)

# --- cost resolution (DB-M16 semantics via DB-M25, READ-ONLY) ---------------------

function Get-DbM29RecordCost {
    <#
    .SYNOPSIS
    Resolve ONE attempt record's usable cost evidence. Delegates to
    Resolve-DbM25RecordCost (DB-M16 authority): ActualCost preferred,
    EstimatedCost only when the query's reporting pass allows the fallback.
    Returns @{ Used; Amount; Source; ExcludedReason; Executed }.
    #>
    param(
        [AllowNull()][object]$Record,
        [string]$Currency = 'INR',
        [bool]$AllowEstimatedFallback = $false
    )
    $c = Resolve-DbM25RecordCost -Record $Record -ReportingCurrencyUpper $Currency.ToUpperInvariant() -AllowEstimatedFallback $AllowEstimatedFallback
    return @{
        Used           = [bool]$c.Used
        Amount         = [double]$c.Amount
        Source         = [string]$c.Source
        Executed       = [bool]$c.Executed
        ExcludedReason = [string]$c.ExcludedReason
    }
}

# --- verification state (DB-M25 authoritative) ---------------------------------------

function Get-DbM29AttemptVerifiedState {
    <#
    .SYNOPSIS
    Map a DB-M25 Resolve-DbM25VerifiedSuccess result onto the DB-M29 verified-state
    label. The underlying truth is ALWAYS DB-M25; this is presentation only.
    #>
    param($Verified)
    if ($null -eq $Verified) { return 'INCOMPLETE' }
    if ([bool]$Verified.Verified) { return 'VERIFIED_SUCCESS' }
    if ([bool]$Verified.Contradicted) { return 'CONTRADICTED' }
    if ([bool]$Verified.ModelReturned) { return 'MODEL_RETURNED' }
    return 'INCOMPLETE'
}

# --- reasoning order ----------------------------------------------------------------

function Get-DbM29ReasoningRank {
    <#
    .SYNOPSIS
    Rank a reasoning level on the deterministic DB-M29 order. Unknown/absent maps
    to -1 so any asserted level outranks it; an asserted level is never ranked
    below an absent one.
    #>
    param([AllowNull()][string]$Level)
    $order = Get-DbM29ReasoningOrder
    if (-not $Level) { return -1 }
    $u = $Level.ToUpperInvariant()
    if ($order.ContainsKey($u)) { return [int]$order[$u] }
    return -1
}

# --- failure count helper ------------------------------------------------------------

function Test-DbM29FailedAttempt {
    <#
    .SYNOPSIS
    True when an attempt is a FAILURE for the task "Failure count" column: a
    FAILED/CANCELLED result OR an independent verification that failed (a model
    self-PASS contradicted by verification is a failure, never success). Budget
    stops / blocks / pending are governance states, NOT counted as failures.
    #>
    param([AllowNull()][object]$Record)
    if ($null -eq $Record) { return $false }
    $res = [string](Get-ContractProperty $Record 'Result' '')
    if ($res -in @('FAILED', 'CANCELLED')) { return $true }
    if ([string](Get-ContractProperty $Record 'VerificationResult' '') -eq 'FAILED') { return $true }
    return $false
}

# --- transition classifier -----------------------------------------------------------

function Get-DbM29Transition {
    <#
    .SYNOPSIS
    Classify the arrow INTO attempt $Next given the previous attempt $Prev, an
    optional matching DB-M20 EscalationDecision and the reasoning order. Rules are
    deterministic and evidence-first:
      1. a FIX_REQUIRED Claude review on $Prev followed by a retry -> correction;
      2. an explicit DB-M20 decision for $Next -> its Action determines the type;
      3. else route evidence: provider change > model change > reasoning escalation
         > plain retry.
    When $Prev is null, the first node's Transition is START.
    Reason codes come ONLY from the DB-M20 vocabulary.
    #>
    param(
        [AllowNull()][object]$Prev,
        [AllowNull()][object]$Next,
        [AllowNull()][object]$Decision = $null
    )
    if ($null -eq $Next) { return $null }
    $nextId = [string](Get-ContractProperty $Next 'AttemptId' '')
    if ($null -eq $Prev) {
        return (New-DbM29TimelineTransition -ToAttemptId $nextId -Type 'START' -Explanation 'First attempt of the task chain.')
    }

    $prevId = [string](Get-ContractProperty $Prev 'AttemptId' '')
    $prevReview = [string](Get-ContractProperty $Prev 'ClaudeReviewStatus' '')
    $reviewFix = ($prevReview -eq 'FIX_REQUIRED')

    $pProv = ([string](Get-ContractProperty $Prev 'ProviderId' '')).Trim().ToLowerInvariant()
    $nProv = ([string](Get-ContractProperty $Next 'ProviderId' '')).Trim().ToLowerInvariant()
    $pModel = ([string](Get-ContractProperty $Prev 'ModelId' '')).Trim().ToLowerInvariant()
    $nModel = ([string](Get-ContractProperty $Next 'ModelId' '')).Trim().ToLowerInvariant()
    $providerChanged = ($pProv -ne $nProv)
    $modelChanged = ($pModel -ne $nModel)
    $reasoningEscalated = (Get-DbM29ReasoningRank (Get-ContractProperty $Next 'ReasoningLevel' '')) -gt (Get-DbM29ReasoningRank (Get-ContractProperty $Prev 'ReasoningLevel' ''))
    $nextReason = [string](Get-ContractProperty $Next 'EscalationReason' '')

    # 1. Claude review fix takes precedence over route evidence: a FIX_REQUIRED
    #    review followed by a retry is a correction, regardless of route.
    if ($reviewFix) {
        return (New-DbM29TimelineTransition -FromAttemptId $prevId -ToAttemptId $nextId -Type 'CORRECTION_CLAUDE_REVIEW_FIX' `
            -Action 'CORRECT_CURRENT_ATTEMPT' `
            -ReasonCodes @('CLAUDE_REVIEW_FIX', 'CORRECT_CURRENT_ATTEMPT') `
            -Explanation 'Previous attempt failed Claude review (FIX_REQUIRED); the follow-up is a review-driven correction.' `
            -RequiresHuman $false)
    }

    # 2. Explicit DB-M20 escalation decision for this attempt.
    if ($null -ne $Decision) {
        $action = [string](Get-ContractProperty $Decision 'Action' '')
        $type = switch ($action) {
            'SWITCH_PROVIDER_ROUTE'            { 'SWITCH_PROVIDER_ROUTE' }
            'SWITCH_MODEL'                     { 'SWITCH_MODEL' }
            'RETRY_SAME_MODEL_HIGHER_REASONING' { 'RETRY_SAME_MODEL_HIGHER_REASONING' }
            'REBUILD_CONTEXT'                  { 'REBUILD_CONTEXT' }
            'CORRECT_CURRENT_ATTEMPT'          { 'CORRECTION' }
            default                            { 'RETRY' }
        }
        $codes = @(Get-ContractProperty $Decision 'ReasonCodes' @())
        if ($nextReason) { $codes = @($codes) + @($nextReason) }
        $explanation = [string](Get-ContractProperty $Decision 'Explanation' '')
        if (-not $explanation -and $nextReason) { $explanation = $nextReason }
        return (New-DbM29TimelineTransition -FromAttemptId $prevId -ToAttemptId $nextId -Type $type `
            -Action $action -ReasonCodes $codes -Explanation $explanation `
            -DecisionId ([string](Get-ContractProperty $Decision 'DecisionId' '')) `
            -RequiresHuman ([bool](Get-ContractProperty $Decision 'RequiresHuman' $false)) `
            -HumanActionType ([string](Get-ContractProperty $Decision 'HumanActionType' '')))
    }

    # 3. A corrective retry: the follow-up is linked to its parent via
    #    ParentAttemptId -> CORRECTION (a correction of the previous attempt).
    $nextParent = [string](Get-ContractProperty $Next 'ParentAttemptId' '')
    if ($nextParent) {
        return (New-DbM29TimelineTransition -FromAttemptId $prevId -ToAttemptId $nextId -Type 'CORRECTION' `
            -Action 'CORRECT_CURRENT_ATTEMPT' `
            -ReasonCodes @('CORRECT_CURRENT_ATTEMPT') `
            -Explanation "This attempt corrects the previous attempt (linked via ParentAttemptId '$nextParent')." `
            -RequiresHuman $false)
    }

    # 4. Route evidence. Reason codes stay inside the DB-M20 vocabulary; a bare
    #    provider change carries no stated cause, so the honest code is the
    #    conservative unknown (never a fabricated availability/rate-limit claim).
    if ($providerChanged) {
        return (New-DbM29TimelineTransition -FromAttemptId $prevId -ToAttemptId $nextId -Type 'SWITCH_PROVIDER_ROUTE' `
            -ReasonCodes @('UNKNOWN_CONSERVATIVE') `
            -Explanation "Provider switched from '$pProv' to '$nProv' after the previous attempt." `
            -RequiresHuman $false)
    }
    if ($modelChanged) {
        return (New-DbM29TimelineTransition -FromAttemptId $prevId -ToAttemptId $nextId -Type 'SWITCH_MODEL' `
            -ReasonCodes @('MODEL_ESCALATION') `
            -Explanation "Model switched from '$pModel' to '$nModel' after the previous attempt." `
            -RequiresHuman $false)
    }
    if ($reasoningEscalated) {
        return (New-DbM29TimelineTransition -FromAttemptId $prevId -ToAttemptId $nextId -Type 'RETRY_SAME_MODEL_HIGHER_REASONING' `
            -ReasonCodes @('REASONING_ESCALATION') `
            -Explanation 'Same route retried with a higher reasoning level.' `
            -RequiresHuman $false)
    }
    return (New-DbM29TimelineTransition -FromAttemptId $prevId -ToAttemptId $nextId -Type 'RETRY' `
        -ReasonCodes @('RETRY_TRANSIENT') `
        -Explanation 'Same route retried (transient failure).' `
        -RequiresHuman $false)
}

# --- terminal marker ----------------------------------------------------------------

function Get-DbM29TerminalMarker {
    <#
    .SYNOPSIS
    The terminal marker for the last attempt of a chain: the honest outcome label
    that answers "WHICH ATTEMPT FINALLY PASSED VERIFICATION?". VERIFIED_SUCCESS is
    only emitted when DB-M25 verified-success resolution says so.
    #>
    param(
        [AllowNull()][object]$Attempt,
        $Verified,
        [AllowNull()][object]$Decision = $null,
        [AllowNull()][object]$Fingerprint = $null
    )
    if ($null -eq $Attempt) { return '' }
    $res = [string](Get-ContractProperty $Attempt 'Result' '')
    if ($res -eq 'BUDGET_STOPPED') { return 'BUDGET_STOP' }
    if ($res -in @('WAITING_HUMAN', 'BLOCKED')) { return 'HUMAN_REVIEW' }
    if ($null -ne $Decision -and [bool](Get-ContractProperty $Decision 'RequiresHuman' $false)) { return 'HUMAN_REVIEW' }
    $codes = @(Get-ContractProperty $Decision 'ReasonCodes' @())
    if ([string](Get-ContractProperty $Decision 'Action' '') -eq 'STOP_GOVERNANCE' -or $codes -contains 'GOVERNANCE_BLOCKED') { return 'GOVERNANCE_STOP' }
    if ($null -ne $Verified -and [bool]$Verified.Verified) { return 'VERIFIED_SUCCESS' }
    return 'FAILED_NO_RETRY'
}

# --- timeline node builder -------------------------------------------------------------

function Get-DbM29TimelineNode {
    <#
    .SYNOPSIS
    Build one AttemptTimelineNode v1 from an AiAttemptRecord v1 + accumulated
    context. Cost is resolved via DB-M16 semantics (Resolve-DbM25RecordCost);
    verification via DB-M25; optional DB-M21 fingerprint + DB-M22 health evidence
    are attached as evidence only.
    #>
    param(
        [AllowNull()][object]$Record,
        [int]$Seq = 0,
        [string]$Currency = 'INR',
        [bool]$AllowEstimatedFallback = $false,
        [string]$SuccessDefinition = 'VERIFIED',
        [AllowNull()][object]$Prev = $null,
        [AllowNull()][object]$Decision = $null,
        [AllowNull()][object]$Fingerprint = $null,
        [AllowNull()][object]$HealthEvidence = $null,
        [AllowNull()][string[]]$Warnings = @()
    )
    if ($null -eq $Record) { return $null }
    $vr = Resolve-DbM25VerifiedSuccess -Attempt $Record -SuccessDefinition $SuccessDefinition
    $cc = Get-DbM29RecordCost -Record $Record -Currency $Currency -AllowEstimatedFallback $AllowEstimatedFallback
    $tran = Get-DbM29Transition -Prev $Prev -Next $Record -Decision $Decision

    $attemptId = [string](Get-ContractProperty $Record 'AttemptId' '')
    $ts = [string](Get-ContractProperty $Record 'StartedAtUtc' '')
    if (-not $ts) { $ts = [string](Get-ContractProperty $Record 'EndedAtUtc' '') }

    # optional DB-M22 provider-failure evidence note (never a health-write)
    if ($null -ne $HealthEvidence) {
        $state = [string](Get-ContractProperty $HealthEvidence 'ObservedState' '')
        if ($state) { $Warnings = @($Warnings) + @("Provider failure evidence: $state" + $(if (Get-ContractProperty $HealthEvidence 'RetryAfterUtc' $null) { " (retry after " + (Get-ContractProperty $HealthEvidence 'RetryAfterUtc' '') + ")" } else { '' })) }
    }

    $node = New-DbM29AttemptTimelineNode `
        -Seq $Seq `
        -AttemptId $attemptId `
        -RetryNumber ([int](Get-ContractProperty $Record 'RetryNumber' 0)) `
        -ParentAttemptId ([string](Get-ContractProperty $Record 'ParentAttemptId' '')) `
        -EscalatedFromAttemptId ([string](Get-ContractProperty $Record 'EscalatedFromAttemptId' '')) `
        -EscalatedToAttemptId ([string](Get-ContractProperty $Record 'EscalatedToAttemptId' '')) `
        -EscalationReason ([string](Get-ContractProperty $Record 'EscalationReason' '')) `
        -ProviderId ([string](Get-ContractProperty $Record 'ProviderId' '')) `
        -ModelId ([string](Get-ContractProperty $Record 'ModelId' '')) `
        -UnderlyingModelId ([string](Get-ContractProperty $Record 'UnderlyingModelId' '')) `
        -GatewayProviderId ([string](Get-ContractProperty $Record 'GatewayProviderId' '')) `
        -ReasoningLevel ([string](Get-ContractProperty $Record 'ReasoningLevel' '')) `
        -Result ([string](Get-ContractProperty $Record 'Result' '')) `
        -FailureCategory ([string](Get-ContractProperty $Record 'FailureCategory' '')) `
        -FailureFingerprintId ([string](Get-ContractProperty $Record 'FailureFingerprintId' '')) `
        -FailureFingerprint $Fingerprint `
        -VerificationResult ([string](Get-ContractProperty $Record 'VerificationResult' '')) `
        -ClaudeReviewStatus ([string](Get-ContractProperty $Record 'ClaudeReviewStatus' '')) `
        -EstimatedCost (Get-ContractProperty $Record 'EstimatedCost' $null) `
        -ActualCost (Get-ContractProperty $Record 'ActualCost' $null) `
        -CostSource $(if ($cc.Used) { $cc.Source } else { $null }) `
        -CostAmount $(if ($cc.Used) { [math]::Round($cc.Amount, 4) } else { $null }) `
        -DurationMs (Get-ContractProperty $Record 'DurationMs' $null) `
        -InputTokens (Get-ContractProperty $Record 'InputTokens' $null) `
        -OutputTokens (Get-ContractProperty $Record 'OutputTokens' $null) `
        -ContextTokens (Get-ContractProperty $Record 'ContextTokens' $null) `
        -HumanIntervention ([bool](Get-ContractProperty $Record 'HumanIntervention' $false)) `
        -TimestampUtc $ts `
        -VerifiedState (Get-DbM29AttemptVerifiedState $vr) `
        -VerifiedReason ([string]$vr.Reason) `
        -Transition $tran `
        -Warnings @($Warnings)
    return $node
}

# --- task row builder -------------------------------------------------------------------

function Get-DbM29TaskRow {
    <#
    .SYNOPSIS
    Build one TaskHistoryRow v1 from a task's ordered attempts + facts. Reuses
    DB-M20 New-EscalationChain for chain facts (ChainId, EscalationEvents,
    LoopFree) and DB-M24 Resolve-AiChainFacts for first-attempt success.
    #>
    param(
        [AllowNull()][object[]]$Attempts,
        [AllowNull()][object]$Facts,
        [AllowNull()][object]$Query,
        [AllowNull()][object]$DecisionMap = $null,
        [AllowNull()][object]$FingerprintMap = $null,
        [AllowNull()][object]$HealthMap = $null,
        [AllowNull()][object[]]$Warnings = @()
    )
    $recs = @($Attempts)
    $query = $Query
    $currency = [string](Get-ContractProperty $query 'Currency' 'INR')
    $allowEst = [bool](Get-ContractProperty $query 'AllowEstimatedCostFallback' $false)
    $sd = [string](Get-ContractProperty $query 'SuccessDefinition' 'VERIFIED')

    if ($recs.Count -eq 0) {
        return (New-DbM29TaskHistoryRow -Mode '(none)' -VerifiedState 'NO_ATTEMPTS' -FirstAttemptSuccess 'UNKNOWN')
    }

    # chain facts (DB-M20)
    $firstRec = $recs[0]
    $taskId = [string](Get-ContractProperty $firstRec 'TaskId' '')
    $nodeId = [string](Get-ContractProperty $firstRec 'NodeId' '')
    $changeId = [string](Get-ContractProperty $firstRec 'ChangeId' '')
    $esc = New-EscalationChain -Attempts $recs -TaskId $taskId -NodeId $nodeId -ChangeId $changeId
    $ordered = @($esc.Attempts)

    # task facts (DB-M24)
    $facts = $Facts
    $terminal = Get-ContractProperty $esc 'TerminalAttempt' $null
    if ($null -eq $terminal -and $null -ne $facts) { $terminal = Get-ContractProperty $facts 'TerminalAttempt' $null }
    if ($null -eq $terminal) { $terminal = $ordered[$ordered.Count - 1] }

    # totals from DB-M16 cost evidence (sum of stored attempt evidence, never a
    # recomputed formula); only matching-currency evidence contributes.
    $totalActual = 0d; $totalEst = 0d
    foreach ($r in $ordered) {
        $cc = [string](Get-ContractProperty $r 'CostCurrency' '')
        $act = Get-ContractProperty $r 'ActualCost' $null
        $est = Get-ContractProperty $r 'EstimatedCost' $null
        if ($cc -and ($cc.ToUpperInvariant() -eq $currency)) {
            if ($null -ne $act) { $totalActual += [double]$act }
            if ($null -ne $est) { $totalEst += [double]$est }
        }
    }
    $totalActual = [math]::Round($totalActual, 4)
    $totalEst = [math]::Round($totalEst, 4)

    # verified-success state (DB-M25 authoritative on the terminal attempt)
    $vrTerm = Resolve-DbM25VerifiedSuccess -Attempt $terminal -SuccessDefinition $sd
    $verifiedState = Get-DbM29AttemptVerifiedState $vrTerm
    if ($null -eq $terminal) { $verifiedState = 'NO_ATTEMPTS' }

    # first-attempt success (DB-M24 facts)
    $firstAttemptSuccess = 'UNKNOWN'
    if ($null -ne $facts) {
        $firstSuccess = [bool](Get-ContractProperty $facts 'FirstAttemptSuccess' $false)
        $firstAttemptSuccess = if ($firstSuccess) { 'YES' } else { 'NO' }
    }
    if ($recs.Count -eq 0) { $firstAttemptSuccess = 'UNKNOWN' }

    # counters
    $failureCount = 0
    foreach ($r in $ordered) { if (Test-DbM29FailedAttempt $r) { $failureCount++ } }
    $correctionsCount = 0
    for ($i = 1; $i -lt $ordered.Count; $i++) {
        if ([string](Get-ContractProperty $ordered[$i] 'ParentAttemptId' '')) { $correctionsCount++; continue }
        if ([string](Get-ContractProperty $ordered[$i - 1] 'ClaudeReviewStatus' '') -eq 'FIX_REQUIRED') { $correctionsCount++ }
    }
    $escalationsCount = [int](Get-ContractProperty $esc 'EscalationEvents' 0)

    # mode (ExecutionMode fallback TaskType)
    $mode = [string](Get-ContractProperty $terminal 'ExecutionMode' '')
    if (-not $mode) { $mode = [string](Get-ContractProperty $terminal 'TaskType' '') }
    if (-not $mode) { $mode = '(none)' }

    # final identity from the terminal attempt
    $finalProvider = [string](Get-ContractProperty $terminal 'ProviderId' '')
    $finalModel = [string](Get-ContractProperty $terminal 'ModelId' '')
    $finalUnder = [string](Get-ContractProperty $terminal 'UnderlyingModelId' '')
    $finalGw = [string](Get-ContractProperty $terminal 'GatewayProviderId' '')
    $finalRl = [string](Get-ContractProperty $terminal 'ReasoningLevel' '')
    $terminalOutcome = [string](Get-ContractProperty $terminal 'Result' '')

    # timeline: ordered nodes with cumulative cost
    $nodes = New-Object System.Collections.ArrayList
    $running = 0d
    $seq = 0
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $seq++
        $r = $ordered[$i]
        $prev = if ($i -gt 0) { $ordered[$i - 1] } else { $null }
        $aid = [string](Get-ContractProperty $r 'AttemptId' '')
        $decision = $null
        if ($null -ne $DecisionMap -and $DecisionMap.ContainsKey($aid)) { $decision = $DecisionMap[$aid] }
        $fp = $null
        $fpid = [string](Get-ContractProperty $r 'FailureFingerprintId' '')
        if ($null -ne $FingerprintMap -and $fpid -and $FingerprintMap.ContainsKey($fpid)) { $fp = $FingerprintMap[$fpid] }
        $health = $null
        if ($null -ne $HealthMap -and $aid -and $HealthMap.ContainsKey($aid)) { $health = $HealthMap[$aid] }

        $node = Get-DbM29TimelineNode -Record $r -Seq $seq -Currency $currency -AllowEstimatedFallback $allowEst `
            -SuccessDefinition $sd -Prev $prev -Decision $decision -Fingerprint $fp -HealthEvidence $health

        $ncost = Get-DbM29RecordCost -Record $r -Currency $currency -AllowEstimatedFallback $allowEst
        if ($ncost.Used) { $running += $ncost.Amount }
        $node.CumulativeCost = [math]::Round($running, 4)
        $node.IsTerminal = ($i -eq $ordered.Count - 1)
        if ($node.IsTerminal) {
            $node.TerminalMarker = Get-DbM29TerminalMarker -Attempt $r -Verified $vrTerm -Decision $decision -Fingerprint $fp
        }
        $null = $nodes.Add($node)
    }

    $verifiedAttemptId = ''
    if ($verifiedState -eq 'VERIFIED_SUCCESS') { $verifiedAttemptId = [string](Get-ContractProperty $terminal 'AttemptId' '') }

    return (New-DbM29TaskHistoryRow `
        -TaskId $taskId -NodeId $nodeId -ChangeId $changeId `
        -ChainId ([string](Get-ContractProperty $esc 'ChainId' '')) `
        -LoopFree ([bool](Get-ContractProperty $esc 'LoopFree' $true)) `
        -LoopReason ([string](Get-ContractProperty $esc 'LoopReason' '')) `
        -Mode $mode -AttemptCount $ordered.Count `
        -TotalActualCost $totalActual -TotalEstimatedCost $totalEst `
        -VerifiedState $verifiedState -VerifiedReason ([string]$vrTerm.Reason) `
        -FirstAttemptSuccess $firstAttemptSuccess `
        -FirstAttemptId ([string](Get-ContractProperty $ordered[0] 'AttemptId' '')) `
        -FinalAttemptId ([string](Get-ContractProperty $terminal 'AttemptId' '')) `
        -VerifiedAttemptId $verifiedAttemptId `
        -FinalProviderId $finalProvider -FinalModelId $finalModel `
        -FinalUnderlyingModelId $finalUnder -FinalGatewayProviderId $finalGw `
        -FinalReasoningLevel $finalRl -TerminalOutcome $terminalOutcome `
        -CorrectionsCount $correctionsCount -EscalationsCount $escalationsCount `
        -FailureCount $failureCount -Timeline @($nodes))
}

# --- main engine ----------------------------------------------------------------------

function Get-DbM29TaskHistoryView {
    <#
    .SYNOPSIS
    Build the TaskHistoryView v1 for the passed query. PURE: takes records,
    optional escalation decisions / failure fingerprints / provider-health
    evidence, and a query; writes nothing. Consumes the DB-M17 query layer
    honestly: an empty record set renders an honest empty state (never an
    invented history).
    #>
    param(
        [AllowNull()][object[]]$Records,
        [AllowNull()][object]$Query,
        [AllowNull()][object[]]$EscalationDecisions = $null,
        [AllowNull()][object[]]$Fingerprints = $null,
        [AllowNull()][object[]]$ProviderHealth = $null
    )
    $records = @($Records)
    if ($null -eq $Query) {
        $Query = New-DbM29TaskHistoryQuery -QueryId 'dbm29-auto' -Currency 'INR' -SuccessDefinition 'VERIFIED'
    }
    $rv = Test-DbM29TaskHistoryQuery $Query
    if (-not $rv.Valid) { throw ("Invalid TaskHistoryQuery: " + ($rv.Errors -join '; ')) }

    $currency = [string](Get-ContractProperty $Query 'Currency' 'INR')
    $sd = [string](Get-ContractProperty $Query 'SuccessDefinition' 'VERIFIED')
    $now = ConvertTo-DbM29Utc (Get-ContractProperty $Query 'NowUtc' $null)
    if ($null -eq $now) { $now = [datetime]::UtcNow }
    $warnings = New-Object System.Collections.Generic.List[string]

    # optional evidence maps (looked up READ-ONLY, keyed by attempt / fingerprint id)
    $decisionMap = @{}
    foreach ($d in @($EscalationDecisions)) {
        $aid = [string](Get-ContractProperty $d 'AttemptId' '')
        if ($aid) { $decisionMap[$aid] = $d }
    }
    $fingerprintMap = @{}
    foreach ($fp in @($Fingerprints)) {
        $fid = [string](Get-ContractProperty $fp 'FingerprintId' '')
        if ($fid) { $fingerprintMap[$fid] = $fp }
    }
    $healthMap = @{}
    foreach ($h in @($ProviderHealth)) {
        $aid = [string](Get-ContractProperty $h 'AttemptIdReference' '')
        if ($aid) { $healthMap[$aid] = $h }
    }

    # filter by the query dimensions
    $taskFilter = [string](Get-ContractProperty $Query 'TaskId' '')
    $provFilter = [string](Get-ContractProperty $Query 'ProviderId' '')
    $modelFilter = [string](Get-ContractProperty $Query 'ModelId' '')
    $filtered = New-Object System.Collections.ArrayList
    foreach ($r in $records) {
        if ($taskFilter -and ([string](Get-ContractProperty $r 'TaskId' '') -ine $taskFilter)) { continue }
        if ($provFilter -and ([string](Get-ContractProperty $r 'ProviderId' '') -ine $provFilter)) { continue }
        if ($modelFilter -and ([string](Get-ContractProperty $r 'ModelId' '') -ine $modelFilter)) { continue }
        $null = $filtered.Add($r)
    }

    if ($filtered.Count -eq 0) {
        $warnings.Add('No attempt history recorded for the current selection.')
        return (New-DbM29TaskHistoryView -RequestId ([string](Get-ContractProperty $Query 'QueryId' 'dbm29-auto')) `
            -QueryId ([string](Get-ContractProperty $Query 'QueryId' '')) `
            -GeneratedAtUtc $now.ToString('o') -NowUtc $now.ToString('o') `
            -Currency $currency -SuccessDefinition $sd -Count 0 -Empty $true `
            -ReadOnlyGuard (New-DbM29ReadOnlyGuard) -Warnings @($warnings))
    }

    # task grouping + facts (DB-M24) and chain facts (DB-M20)
    $chains = @(Resolve-AiTaskChains -Records @($filtered))
    $rows = New-Object System.Collections.ArrayList
    foreach ($ch in $chains) {
        $facts = Resolve-AiChainFacts -Chain $ch -SuccessDefinition $sd
        $row = Get-DbM29TaskRow -Attempts @($ch.Records) -Facts $facts -Query $Query `
            -DecisionMap $decisionMap -FingerprintMap $fingerprintMap -HealthMap $healthMap -Warnings @($warnings)
        $null = $rows.Add($row)
    }

    # sorting (presentation only)
    $sortBy = [string](Get-ContractProperty $Query 'SortBy' 'TASK_ID')
    $desc = ([string](Get-ContractProperty $Query 'SortDirection' 'ASCENDING') -eq 'DESCENDING')
    $sorted = @($rows)
    if ($sortBy -eq 'TOTAL_COST') {
        $sorted = @($rows | Sort-Object -Property @{ Expression = { ([double](Get-ContractProperty $_ 'TotalActualCost' 0)) + ([double](Get-ContractProperty $_ 'TotalEstimatedCost' 0)) }; Descending = $desc },
                                                  @{ Expression = { [string](Get-ContractProperty $_ 'TaskId' '') } })
    } elseif ($sortBy -eq 'ATTEMPT_COUNT') {
        $sorted = @($rows | Sort-Object -Property @{ Expression = { [int](Get-ContractProperty $_ 'AttemptCount' 0) }; Descending = $desc },
                                                  @{ Expression = { [string](Get-ContractProperty $_ 'TaskId' '') } })
    } else {
        $sorted = @($rows | Sort-Object -Property @{ Expression = { [string](Get-ContractProperty $_ 'TaskId' '') }; Descending = $desc })
    }

    return (New-DbM29TaskHistoryView -RequestId ([string](Get-ContractProperty $Query 'QueryId' 'dbm29-auto')) `
        -QueryId ([string](Get-ContractProperty $Query 'QueryId' '')) `
        -GeneratedAtUtc $now.ToString('o') -NowUtc $now.ToString('o') `
        -Currency $currency -SuccessDefinition $sd -Count $sorted.Count -Empty ($sorted.Count -eq 0) `
        -TaskRows $sorted -ReadOnlyGuard (New-DbM29ReadOnlyGuard) -Warnings @($warnings))
}

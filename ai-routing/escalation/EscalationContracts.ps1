# EscalationContracts.ps1 -- DB-M20 decision-engine contracts.
#
# DB-M20 is a DECISION ENGINE (deterministic escalation planner). It never
# executes a provider or model, never makes a paid API call, never touches a
# Nexus workbook or the roadmap. AUTO_EXECUTION_ENABLED = FALSE.
#
# Contracts owned here (all v1, frozen for DB-M20):
#   EscalationInput v1   - the deterministic input to Get-AiEscalationDecision
#   EscalationDecision v1 - the decision output (action + next route + cost +
#                           evidence references + policy provenance)
#   EscalationChain v1   - a preserved, append-only view of every attempt in a
#                           task's escalation chain (nothing is ever erased)
#
# Consumed read-only: DB-M14 vocabularies, DB-M17 attempt records, DB-M19
# RoutingCandidate / RoutingDecisionEvidence, DB-M24 performance evidence,
# DB-M16 cost results. Frozen contracts are never modified.
#
# ADR-005: identifiers are data. No business logic branches on a provider/model
# name.

. (Join-Path $PSScriptRoot "EscalationPolicy.ps1")

# -----------------------------------------------------------------------------
# Claude-review signal vocabulary (DB-M20-owned)
# -----------------------------------------------------------------------------
function Get-DbM20ClaudeReviewStatuses {
    return @('NONE', 'PENDING', 'PASS', 'FIX_REQUIRED')
}

# -----------------------------------------------------------------------------
# EscalationInput v1
# -----------------------------------------------------------------------------
function New-EscalationInput {
    <#
    .SYNOPSIS
    Build an EscalationInput v1. Every field is present; unknown values stay
    null. The current attempt + the prior attempt chain (DB-M17 AiAttemptRecord
    v1 objects) drive the decision; the routing evidence and eligible candidates
    come from the DB-M19 recommendation; MaxAllowedCost is the request-level
    ceiling only (no daily/monthly/org/team budgets).
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$InputId,
        [string]$TaskId,
        [string]$NodeId,
        [string]$ChangeId,
        [AllowNull()][object]$CurrentAttempt,
        [AllowNull()][object[]]$AttemptChain,
        [string]$RecordedFailureCategory,
        [string]$FailureCategory,
        [string]$VerificationResult,
        [string]$VerificationEvidencePath,
        [string]$ClaudeReviewStatus,
        [AllowNull()][object]$RoutingDecision,
        [AllowNull()][object[]]$EligibleCandidates,
        [AllowNull()][object[]]$RejectedCandidates,
        [Nullable[double]]$MaxAllowedCost,
        [Nullable[double]]$CumulativeActualCost,
        [Nullable[double]]$CumulativeEstimatedCost,
        [string]$ExecutionMode = 'MANUAL',
        [bool]$HumanInterventionRequired = $false,
        [AllowNull()]$TimestampUtc,
        [AllowNull()][object]$Requirement,
        [AllowNull()][object]$Configuration,
        [AllowNull()][object]$ContextBudget,
        [AllowNull()][object]$ContextPackage,
        [string]$ProcessingTier = 'STANDARD',
        [string]$TimeBand,
        [double]$CachedInputFraction = 0.0,
        [string]$TargetCurrency = 'INR',
        [AllowNull()][Nullable[decimal]]$ExchangeRate,
        [string]$PricingRecordIdOverride,
        [string]$Notes
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }

    $id = if ($InputObject) { & $g 'InputId' $InputId } else { $InputId }
    $taskId = if ($InputObject) { & $g 'TaskId' $TaskId } else { $TaskId }
    if (-not $id) {
        if (-not $taskId) { throw "New-EscalationInput: TaskId is required (and InputId defaults to it)" }
        $id = "ESC-$taskId"
    }

    $chain = @()
    if ($InputObject) { $chain = @(& $g 'AttemptChain' $AttemptChain) }
    elseif ($AttemptChain) { $chain = @($AttemptChain) }

    $eligible = @()
    if ($InputObject) { $eligible = @(& $g 'EligibleCandidates' $EligibleCandidates) }
    elseif ($EligibleCandidates) { $eligible = @($EligibleCandidates) }

    $rejected = @()
    if ($InputObject) { $rejected = @(& $g 'RejectedCandidates' $RejectedCandidates) }
    elseif ($RejectedCandidates) { $rejected = @($RejectedCandidates) }

    $ts = if ($InputObject) { & $g 'TimestampUtc' $TimestampUtc } else { $TimestampUtc }

    return [pscustomobject]@{
        SchemaVersion            = 1
        InputId                  = $id
        TaskId                   = $taskId
        NodeId                   = if ($InputObject) { & $g 'NodeId' $NodeId } else { $NodeId }
        ChangeId                 = if ($InputObject) { & $g 'ChangeId' $ChangeId } else { $ChangeId }
        CurrentAttempt           = if ($InputObject) { & $g 'CurrentAttempt' $CurrentAttempt } else { $CurrentAttempt }
        AttemptChain             = $chain
        RecordedFailureCategory  = if ($InputObject) { & $g 'RecordedFailureCategory' $RecordedFailureCategory } else { $RecordedFailureCategory }
        FailureCategory          = if ($InputObject) { & $g 'FailureCategory' $FailureCategory } else { $FailureCategory }
        VerificationResult       = if ($InputObject) { & $g 'VerificationResult' $VerificationResult } else { $VerificationResult }
        VerificationEvidencePath = if ($InputObject) { & $g 'VerificationEvidencePath' $VerificationEvidencePath } else { $VerificationEvidencePath }
        ClaudeReviewStatus       = if ($InputObject) { & $g 'ClaudeReviewStatus' $ClaudeReviewStatus } else { $ClaudeReviewStatus }
        RoutingDecision          = if ($InputObject) { & $g 'RoutingDecision' $RoutingDecision } else { $RoutingDecision }
        EligibleCandidates       = $eligible
        RejectedCandidates       = $rejected
        MaxAllowedCost           = if ($InputObject) { & $g 'MaxAllowedCost' $MaxAllowedCost } else { $MaxAllowedCost }
        CumulativeActualCost     = if ($InputObject) { & $g 'CumulativeActualCost' $CumulativeActualCost } else { $CumulativeActualCost }
        CumulativeEstimatedCost  = if ($InputObject) { & $g 'CumulativeEstimatedCost' $CumulativeEstimatedCost } else { $CumulativeEstimatedCost }
        ExecutionMode            = if ($InputObject) { & $g 'ExecutionMode' $ExecutionMode } else { $ExecutionMode }
        HumanInterventionRequired = if ($InputObject) { [bool](& $g 'HumanInterventionRequired' $HumanInterventionRequired) } else { $HumanInterventionRequired }
        TimestampUtc             = $ts
        Requirement              = if ($InputObject) { & $g 'Requirement' $Requirement } else { $Requirement }
        Configuration            = if ($InputObject) { & $g 'Configuration' $Configuration } else { $Configuration }
        ContextBudget            = if ($InputObject) { & $g 'ContextBudget' $ContextBudget } else { $ContextBudget }
        ContextPackage           = if ($InputObject) { & $g 'ContextPackage' $ContextPackage } else { $ContextPackage }
        ProcessingTier           = if ($InputObject) { & $g 'ProcessingTier' $ProcessingTier } else { $ProcessingTier }
        TimeBand                 = if ($InputObject) { & $g 'TimeBand' $TimeBand } else { $TimeBand }
        CachedInputFraction      = if ($InputObject) { & $g 'CachedInputFraction' $CachedInputFraction } else { $CachedInputFraction }
        TargetCurrency           = if ($InputObject) { & $g 'TargetCurrency' $TargetCurrency } else { $TargetCurrency }
        ExchangeRate             = if ($InputObject) { & $g 'ExchangeRate' $ExchangeRate } else { $ExchangeRate }
        PricingRecordIdOverride  = if ($InputObject) { & $g 'PricingRecordIdOverride' $PricingRecordIdOverride } else { $PricingRecordIdOverride }
        Notes                    = if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }
    }
}

function Test-EscalationInput {
    <#
    .SYNOPSIS
    Deterministic structural validation of an EscalationInput v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$InputObject)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $InputObject) { return @{ Valid = $false; Errors = @('Input is null'); Warnings = @() } }
    if ((Get-ContractProperty $InputObject 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $InputObject 'TaskId' '')) { $errors.Add('TaskId is required') }
    $execMode = [string](Get-ContractProperty $InputObject 'ExecutionMode' 'MANUAL')
    if ($execMode -and -not (Test-IsValidExecutionMode $execMode)) { $errors.Add("ExecutionMode '$execMode' invalid") }
    $verif = Get-ContractProperty $InputObject 'VerificationResult' $null
    if ($verif -and $verif -notin @('VERIFIED', 'FAILED', 'PENDING')) { $errors.Add("VerificationResult '$verif' invalid (VERIFIED/FAILED/PENDING)") }
    $claude = Get-ContractProperty $InputObject 'ClaudeReviewStatus' $null
    if ($claude -and $claude -notin (Get-DbM20ClaudeReviewStatuses)) { $errors.Add("ClaudeReviewStatus '$claude' invalid") }
    $ceiling = Get-ContractProperty $InputObject 'MaxAllowedCost' $null
    if ($null -ne $ceiling -and $ceiling -lt 0) { $errors.Add('MaxAllowedCost must be >= 0') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# -----------------------------------------------------------------------------
# EscalationDecision v1
# -----------------------------------------------------------------------------
function New-EscalationDecision {
    <#
    .SYNOPSIS
    Build an EscalationDecision v1 from a field table. The DB-M20 decision is a
    pure recommendation: the engine NEVER executes the recommended next route.
    AUTO_EXECUTION_ENABLED is always FALSE.
    #>
    param(
        [AllowNull()][hashtable]$Fields
    )
    $f = if ($null -eq $Fields) { @{} } else { $Fields }
    function F([string]$n, $d) { if ($f.ContainsKey($n)) { return $f[$n] }; return $d }
    return [pscustomobject]@{
        SchemaVersion                  = 1
        DecisionId                     = F 'DecisionId' $null
        Status                         = F 'Status' $null
        TaskId                         = F 'TaskId' $null
        AttemptId                      = F 'AttemptId' $null
        CurrentAttemptNumber           = F 'CurrentAttemptNumber' $null
        PreviousProviderId             = F 'PreviousProviderId' $null
        PreviousModelId                = F 'PreviousModelId' $null
        PreviousReasoningLevel         = F 'PreviousReasoningLevel' $null
        FailureCategory                = F 'FailureCategory' $null
        Action                         = F 'Action' $null
        NextProviderId                 = F 'NextProviderId' $null
        NextModelId                    = F 'NextModelId' $null
        NextReasoningLevel             = F 'NextReasoningLevel' $null
        ContextAction                  = F 'ContextAction' 'KEEP_CONTEXT'
        RetryNumber                    = F 'RetryNumber' $null
        EstimatedNextAttemptCost       = F 'EstimatedNextAttemptCost' $null
        NextCostCurrency               = F 'NextCostCurrency' $null
        NextCostUnknown                = F 'NextCostUnknown' $null
        CumulativeEstimatedCost        = F 'CumulativeEstimatedCost' $null
        CumulativeActualCost           = F 'CumulativeActualCost' $null
        ReasonCodes                    = @(F 'ReasonCodes' @())
        Explanation                    = F 'Explanation' $null
        RequiresHuman                  = F 'RequiresHuman' $false
        HumanActionType                = F 'HumanActionType' 'NONE'
        AutoExecutionEnabled           = F 'AutoExecutionEnabled' $false
        RoutingEvidenceReference       = F 'RoutingEvidenceReference' $null
        AttemptHistoryReference        = F 'AttemptHistoryReference' $null
        VerificationEvidenceReference  = F 'VerificationEvidenceReference' $null
        PerformanceEvidenceReference   = F 'PerformanceEvidenceReference' $null
        PolicyId                       = F 'PolicyId' $null
        DecisionTimestampUtc           = F 'DecisionTimestampUtc' $null
        Notes                          = F 'Notes' $null
    }
}

function Test-EscalationDecision {
    <#
    .SYNOPSIS
    Deterministic structural validation of an EscalationDecision v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Decision)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Decision) { return @{ Valid = $false; Errors = @('Decision is null'); Warnings = @() } }
    if ((Get-ContractProperty $Decision 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Decision 'TaskId' '')) { $errors.Add('TaskId is required') }
    $status = [string](Get-ContractProperty $Decision 'Status' '')
    if ($status -and $status -notin (Get-DbM20DecisionStatuses)) { $errors.Add("Status '$status' invalid") }
    $action = [string](Get-ContractProperty $Decision 'Action' '')
    if ($action -and $action -notin (Get-DbM20Actions)) { $errors.Add("Action '$action' invalid") }
    $ctx = [string](Get-ContractProperty $Decision 'ContextAction' '')
    if ($ctx -and $ctx -notin (Get-DbM20ContextActions)) { $errors.Add("ContextAction '$ctx' invalid") }
    $humanType = [string](Get-ContractProperty $Decision 'HumanActionType' '')
    if ($humanType -and $humanType -notin (Get-DbM20HumanActionTypes)) { $errors.Add("HumanActionType '$humanType' invalid") }
    foreach ($rc in @(Get-ContractProperty $Decision 'ReasonCodes' @())) {
        if ($rc -notin (Get-DbM20ReasonCodes)) { $errors.Add("ReasonCode '$rc' not in the DB-M20 reason-code vocabulary") }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# -----------------------------------------------------------------------------
# EscalationChain v1
# -----------------------------------------------------------------------------
function New-EscalationChain {
    <#
    .SYNOPSIS
    Build an EscalationChain v1 from the task's attempt records (DB-M17
    AiAttemptRecord v1 objects). The chain is the append-only preserved record
    of every attempt: later successes never erase earlier failures. Attempts are
    ordered by RetryNumber (stable). LoopFree = true only when the chain is
    cycle-free (strictly increasing RetryNumbers, no attempt referenced twice).
    #>
    param(
        [AllowNull()][object[]]$Attempts,
        [string]$TaskId,
        [string]$NodeId,
        [string]$ChangeId,
        [string]$ChainId
    )
    $records = @()
    if ($Attempts) { $records = @($Attempts) }
    $first = $null
    if ($records.Count -gt 0) { $first = $records[0] }
    $taskId = if ($TaskId) { $TaskId } else {
        if ($null -ne $first) { [string](Get-ContractProperty $first 'TaskId' '') } else { '' }
    }
    if (-not $ChainId) { $ChainId = "CHAIN-$taskId" }

    $ordered = @($records | Sort-Object @{ Expression = { [long](Get-ContractProperty $_ 'RetryNumber' 0) } }, @{ Expression = { [string](Get-ContractProperty $_ 'AttemptId' '') } })

    # loop-free check: RetryNumbers must be strictly increasing across the order
    # and no AttemptId may appear twice; an attempt may not reference itself.
    $loopFree = $true
    $loopReason = $null
    $seenIds = @{}
    $prevRetry = -1
    foreach ($rec in $ordered) {
        $attemptId = [string](Get-ContractProperty $rec 'AttemptId' '')
        $retry = [long](Get-ContractProperty $rec 'RetryNumber' 0)
        if ($attemptId) {
            if ($seenIds.ContainsKey($attemptId)) { $loopFree = $false; $loopReason = "attempt '$attemptId' appears more than once"; break }
            $seenIds[$attemptId] = $true
        }
        if ($retry -lt $prevRetry) { $loopFree = $false; $loopReason = "RetryNumber $retry is not strictly increasing"; break }
        $prevRetry = $retry
        $from = [string](Get-ContractProperty $rec 'EscalatedFromAttemptId' '')
        if ($from -and $from -eq $attemptId) { $loopFree = $false; $loopReason = "attempt '$attemptId' escalated from itself"; break }
    }

    # terminal attempt = last ordered record
    $terminal = $null
    if ($ordered.Count -gt 0) { $terminal = $ordered[$ordered.Count - 1] }
    $terminalOutcome = $null
    if ($null -ne $terminal) { $terminalOutcome = [string](Get-ContractProperty $terminal 'Result' '') }

    $escalationEvents = @($ordered | Where-Object {
        ([string](Get-ContractProperty $_ 'EscalatedFromAttemptId' '')) -or
        ([string](Get-ContractProperty $_ 'EscalationReason' '')) -or
        ([long](Get-ContractProperty $_ 'RetryNumber' 0)) -gt 0
    }).Count

    return [pscustomobject]@{
        SchemaVersion     = 1
        ChainId           = $ChainId
        TaskId            = $taskId
        NodeId            = if ($NodeId) { $NodeId } else { Get-ContractProperty $first 'NodeId' $null }
        ChangeId          = if ($ChangeId) { $ChangeId } else { Get-ContractProperty $first 'ChangeId' $null }
        Attempts          = $ordered
        TerminalAttempt   = $terminal
        TerminalOutcome   = $terminalOutcome
        EscalationEvents  = [int]$escalationEvents
        LoopFree          = $loopFree
        LoopReason        = $loopReason
    }
}

function Test-EscalationChain {
    param([AllowNull()][pscustomobject]$Chain)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Chain) { return @{ Valid = $false; Errors = @('Chain is null'); Warnings = @() } }
    if ((Get-ContractProperty $Chain 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Chain 'TaskId' '')) { $errors.Add('TaskId is required') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

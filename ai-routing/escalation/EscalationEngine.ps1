# EscalationEngine.ps1 -- DB-M20 Retry + Automatic Escalation DECISION ENGINE.
#
# DB-M20 is a DECISION ENGINE ONLY. It computes a deterministic retry /
# escalation plan for a failed AI attempt and NEVER executes anything:
#   - no live AI invocation, no paid API call, no network call,
#   - no autonomous Nexus change, no roadmap/workbook modification,
#   - AUTO_EXECUTION_ENABLED = FALSE (AUTO execution mode is refused),
#   - it does not implement Git workflow, and its decisions never bypass a
#     human Git gate (HUMAN_GIT_ACTION_REQUIRED is terminal/waiting),
#   - model escalation only ever considers DB-M19 ELIGIBLE candidates (hard
#     capability filters are never bypassed; a stronger-but-ineligible model is
#     never selected),
#   - non-AI failures (scope / governance / git / PR / merge / architecture)
#     NEVER escalate to a model or a retry,
#   - verification is authoritative: a self-reported SUCCESS whose independent
#     verification FAILED is an outcome FAILURE (verification-driven escalation),
#   - every retry / escalation is bounded (no infinite loops), deterministic,
#     and cost-aware via the DB-M16 engine (incremental + cumulative, never
#     hidden; request-level cost ceiling only),
#   - FIX vs RETRY: focused CORRECT_CURRENT_ATTEMPT preserves verified work and
#     corrects only the failed delta; NEW_FIX_TASK_REQUIRED is represent-only
#     (no roadmap/workbook record is ever created).
#
# Decision pipeline (deterministic, terminal gates first):
#   AUTO -> refused.
#   human-intervention pending -> terminal/waiting.
#   verified success -> STOP_SUCCESS.
#   governance class -> terminal STOP/HUMAN (never model escalation).
#   budget stop -> STOP_BUDGET_LIMIT.
#   attempt limit -> STOP_NO_ELIGIBLE_ESCALATION.
#   policy stop/human lists -> terminal.
#   category action table -> retry / escalate / correct / context / stop,
#   then loop protection + cost ceiling re-check on the chosen next route.

. (Join-Path $PSScriptRoot "EscalationContracts.ps1")
. (Join-Path $PSScriptRoot "FailureClassification.ps1")
. (Join-Path $PSScriptRoot "EscalationRetry.ps1")
. (Join-Path $PSScriptRoot "EscalationCandidates.ps1")
. (Join-Path $PSScriptRoot "EscalationCost.ps1")

# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------
function Get-DbM20ArrayValue {
    param([AllowNull()][object]$Object, [string]$Name)
    $v = Get-ContractProperty $Object $Name $null
    if ($null -eq $v) { return @() }
    return @($v)
}

function Get-DbM20RouteCandidate {
    param(
        [AllowNull()][object[]]$Candidates,
        [string]$ProviderId,
        [string]$ModelId
    )
    foreach ($c in @($Candidates)) {
        if ([string](Get-ContractProperty $c 'ProviderId' '') -eq $ProviderId -and [string](Get-ContractProperty $c 'ModelId' '') -eq $ModelId) { return $c }
    }
    return $null
}

function Get-DbM20ChainCounts {
    <#
    .SYNOPSIS
    Deterministic counters derived from the preserved attempt chain:
      SameModelRetryCount   - attempts on the current model with RetryNumber >= 1
      ReasoningEscalationsUsed - attempts at a reasoning level strictly above the
                                 first attempt's base level
      ModelEscalationsUsed  - distinct models used beyond the first (model switches)
      CorrectionCount       - attempts whose category was a focused-correction
                              family (VERIFICATION_FAILURE / CLAUDE_REVIEW_FIX /
                              INVALID_OUTPUT)
      BaseReasoningLevel    - the first attempt's reasoning level
    #>
    param(
        [AllowNull()][object[]]$ChainRecords,
        [string]$CurrentModelId
    )
    $baseReasoning = $null
    if (@($ChainRecords).Count -gt 0) { $baseReasoning = [string](Get-ContractProperty @($ChainRecords)[0] 'ReasoningLevel' '') }
    $order = Get-AiRoutingReasoningOrder

    $sameModelRetry = 0
    $reasoningEsc = 0
    $correctionCount = 0
    $distinctModels = @{}
    foreach ($r in @($ChainRecords)) {
        $m = [string](Get-ContractProperty $r 'ModelId' '')
        $retry = [long](Get-ContractProperty $r 'RetryNumber' 0)
        $rl = [string](Get-ContractProperty $r 'ReasoningLevel' '')
        if ($CurrentModelId -and $m -eq $CurrentModelId -and $retry -ge 1) { $sameModelRetry++ }
        if ($baseReasoning -and $rl -and $order.ContainsKey($rl) -and $order.ContainsKey($baseReasoning)) {
            if ([int]$order[$rl] -gt [int]$order[$baseReasoning]) { $reasoningEsc++ }
        }
        if ($m) { $distinctModels[$m] = $true }
        $cat = [string](Get-ContractProperty $r 'FailureCategory' '')
        if ($cat -in @('VERIFICATION_FAILURE', 'CLAUDE_REVIEW_FIX', 'INVALID_OUTPUT')) { $correctionCount++ }
    }
    $modelSwitches = @($distinctModels.Keys).Count - 1
    if ($modelSwitches -lt 0) { $modelSwitches = 0 }
    return @{
        SameModelRetryCount       = [int]$sameModelRetry
        ReasoningEscalationsUsed  = [int]$reasoningEsc
        ModelEscalationsUsed      = [int]$modelSwitches
        CorrectionCount           = [int]$correctionCount
        BaseReasoningLevel        = $baseReasoning
    }
}

function Get-DbM20GovernanceAction([string]$Category) {
    <#
    .SYNOPSIS
    Fixed safety table for GOVERNANCE-class failures. These are terminal and
    NEVER escalate to a model, a reasoning level or a retry.
    #>
    switch ($Category) {
        'GOVERNANCE_BLOCKED' {
            return @{
                Status = 'STOP_GOVERNANCE'; Action = 'STOP_GOVERNANCE'
                RequiresHuman = $false; HumanActionType = 'NONE'
                ReasonCodes = @('NO_QUALITY_ESCALATION_FOR_NON_AI', 'GOVERNANCE_BLOCKED')
                Explanation = 'governance block: this is not a model-quality problem; stop and do not spend more AI tokens on stronger models'
            }
        }
        'ARCHITECTURE_CONFLICT' {
            return @{
                Status = 'STOP_GOVERNANCE'; Action = 'STOP_GOVERNANCE'
                RequiresHuman = $false; HumanActionType = 'NONE'
                ReasonCodes = @('NO_QUALITY_ESCALATION_FOR_NON_AI', 'ARCHITECTURE_CONFLICT')
                Explanation = 'architecture conflict: roadmap structure is protected; stop and resolve with governance before any further attempt'
            }
        }
        'SCOPE_CHANGE_REQUIRED' {
            return @{
                Status = 'HUMAN_GOVERNANCE_REQUIRED'; Action = 'HUMAN_GOVERNANCE_REQUIRED'
                RequiresHuman = $true; HumanActionType = 'GOVERNANCE_REVIEW'
                ReasonCodes = @('NO_QUALITY_ESCALATION_FOR_NON_AI', 'SCOPE_CHANGE')
                Explanation = 'scope change required: a governance decision is required; no model escalation is attempted'
            }
        }
        'HUMAN_GIT_GATE' {
            return @{
                Status = 'HUMAN_GIT_ACTION_REQUIRED'; Action = 'HUMAN_GIT_ACTION_REQUIRED'
                RequiresHuman = $true; HumanActionType = 'GIT_ACTION'
                ReasonCodes = @('NO_QUALITY_ESCALATION_FOR_NON_AI', 'GIT_GATE_PENDING')
                Explanation = 'human Git gate is pending; DB-M20 never bypasses a human Git gate and never escalates to a model'
            }
        }
        'PR_PENDING' {
            return @{
                Status = 'HUMAN_GIT_ACTION_REQUIRED'; Action = 'HUMAN_GIT_ACTION_REQUIRED'
                RequiresHuman = $true; HumanActionType = 'GIT_ACTION'
                ReasonCodes = @('NO_QUALITY_ESCALATION_FOR_NON_AI', 'PR_PENDING')
                Explanation = 'pull request is pending a human review; the decision waits and never escalates to a model'
            }
        }
        'MERGE_PENDING' {
            return @{
                Status = 'HUMAN_GIT_ACTION_REQUIRED'; Action = 'HUMAN_GIT_ACTION_REQUIRED'
                RequiresHuman = $true; HumanActionType = 'GIT_ACTION'
                ReasonCodes = @('NO_QUALITY_ESCALATION_FOR_NON_AI', 'MERGE_PENDING')
                Explanation = 'merge is pending a human action; the decision waits and never escalates to a model'
            }
        }
        default {
            return @{
                Status = 'STOP_GOVERNANCE'; Action = 'STOP_GOVERNANCE'
                RequiresHuman = $false; HumanActionType = 'NONE'
                ReasonCodes = @('NO_QUALITY_ESCALATION_FOR_NON_AI')
                Explanation = "governance-class failure '$Category' is terminal; never escalate to a model"
            }
        }
    }
}

function Get-AiEscalationDecision {
    <#
    .SYNOPSIS
    The DB-M20 orchestrator. Given an EscalationInput v1 (the failed attempt +
    the preserved attempt chain + the DB-M19 routing evidence + the request cost
    ceiling) and an EscalationPolicy v1, it computes a deterministic
    retry / escalation decision (EscalationDecision v1). NEVER executes a
    provider or model; AUTO execution mode is refused.
    #>
    param(
        [AllowNull()][pscustomobject]$InputObject,
        [AllowNull()][pscustomobject]$Policy
    )
    if ($null -eq $InputObject) { throw 'Get-AiEscalationDecision: Input is required' }
    $inV = Test-EscalationInput $InputObject
    if (-not $inV.Valid) { throw "Get-AiEscalationDecision: invalid escalation input: $($inV.Errors -join '; ')" }

    $policy = $Policy
    if ($null -eq $policy) { $policy = Get-DefaultEscalationPolicy }
    $polV = Test-EscalationPolicy $policy
    if (-not $polV.Valid) { throw "Get-AiEscalationDecision: invalid escalation policy: $($polV.Errors -join '; ')" }
    if ($policy.Enabled -ne $true) { throw "Get-AiEscalationDecision: escalation policy '$($policy.PolicyId)' is disabled" }

    $taskId = [string](Get-ContractProperty $InputObject 'TaskId' '')
    $execMode = [string](Get-ContractProperty $InputObject 'ExecutionMode' 'MANUAL')
    if (-not $execMode) { $execMode = 'MANUAL' }
    $ts = Get-ContractProperty $InputObject 'TimestampUtc' $null
    if ($null -eq $ts) { $ts = [datetime]::UtcNow }
    $ts = ConvertTo-AiUtc $ts
    $tsString = $ts.ToString('o')
    $decisionId = [string](Get-ContractProperty $InputObject 'InputId' "ESC-$taskId")

    # --- AUTO is prohibited ----------------------------------------------------
    if ($execMode -eq 'AUTO') {
        return New-EscalationDecision @{
            DecisionId = $decisionId; Status = 'AUTO_EXECUTION_PROHIBITED'; TaskId = $taskId
            Action = $null; ReasonCodes = @('AUTO_PROHIBITED')
            Explanation = 'AUTO execution mode is prohibited by DB-M20 (AUTO_EXECUTION_ENABLED = FALSE); the decision is a recommendation only'
            RequiresHuman = $true; HumanActionType = 'NONE'; AutoExecutionEnabled = $false
            PolicyId = $policy.PolicyId; DecisionTimestampUtc = $tsString
            Notes = 'DB-M20 refuses to auto-execute; no retry or escalation is recommended for execution.'
        }
    }

    # --- assemble the preserved chain ------------------------------------------
    $prior = @(Get-ContractProperty $InputObject 'AttemptChain' @())
    $current = Get-ContractProperty $InputObject 'CurrentAttempt' $null
    $chainRecords = @($prior)
    if ($null -ne $current) {
        $curId = [string](Get-ContractProperty $current 'AttemptId' '')
        $dup = $false
        if ($curId) {
            foreach ($r in $prior) { if ([string](Get-ContractProperty $r 'AttemptId' '') -eq $curId) { $dup = $true; break } }
        }
        if (-not $dup) { $chainRecords = @($chainRecords) + @($current) }
    }
    if ($chainRecords.Count -eq 0) { throw 'Get-AiEscalationDecision: no attempt supplied (CurrentAttempt or AttemptChain is required)' }

    $attempt = $current
    if ($null -eq $attempt) { $attempt = $chainRecords[$chainRecords.Count - 1] }

    $prevProvider = [string](Get-ContractProperty $attempt 'ProviderId' '')
    $prevModel = [string](Get-ContractProperty $attempt 'ModelId' '')
    $prevReasoning = [string](Get-ContractProperty $attempt 'ReasoningLevel' '')
    $currentResult = [string](Get-ContractProperty $attempt 'Result' 'PENDING')
    $currentAttemptNumber = $chainRecords.Count
    $nextAttemptNumber = $currentAttemptNumber + 1
    $currentRetry = [long](Get-ContractProperty $attempt 'RetryNumber' 0)

    $cum = Get-DbM20ChainCumulative -Attempts $chainRecords

    $attemptHistoryRef = "DB-M17/AttemptChain/$taskId/attempts=$($chainRecords.Count)"
    $routingRef = $null
    $routingDecision = Get-ContractProperty $InputObject 'RoutingDecision' $null
    if ($null -ne $routingDecision) {
        $rid = Get-ContractProperty $routingDecision 'RoutingRequestId' $null
        if ($rid) { $routingRef = "DB-M19/RoutingDecision/$rid" }
    }
    $verifRef = Get-ContractProperty $InputObject 'VerificationEvidencePath' $null
    if (-not $verifRef) { $verifRef = Get-ContractProperty $attempt 'VerificationEvidencePath' $null }

    $verificationResult = Get-ContractProperty $InputObject 'VerificationResult' $null
    if (-not $verificationResult) { $verificationResult = Get-ContractProperty $attempt 'VerificationResult' $null }
    $claudeStatus = Get-ContractProperty $InputObject 'ClaudeReviewStatus' $null

    # common decision fields
    $common = @{
        TaskId = $taskId; AttemptId = (Get-ContractProperty $attempt 'AttemptId' $null)
        CurrentAttemptNumber = $currentAttemptNumber
        PreviousProviderId = $prevProvider; PreviousModelId = $prevModel; PreviousReasoningLevel = $prevReasoning
        CumulativeEstimatedCost = $cum.CumulativeEstimatedCost; CumulativeActualCost = $cum.CumulativeActualCost
        RetryNumber = $currentRetry + 1
        RoutingEvidenceReference = $routingRef; AttemptHistoryReference = $attemptHistoryRef
        VerificationEvidenceReference = $verifRef
        PolicyId = $policy.PolicyId; DecisionTimestampUtc = $tsString
        AutoExecutionEnabled = $false
    }

    # --- human intervention pending: terminal/waiting, no AI calls --------------
    if ([bool](Get-ContractProperty $InputObject 'HumanInterventionRequired' $false)) {
        return New-EscalationDecision ($common + @{
            DecisionId = $decisionId; Status = 'HUMAN_REVIEW_REQUIRED'; Action = 'HUMAN_REVIEW_REQUIRED'
            ReasonCodes = @('HUMAN_INTERVENTION_PENDING')
            Explanation = 'a human intervention is already pending for this task; the decision waits and recommends no further AI attempt'
            RequiresHuman = $true; HumanActionType = 'REVIEW_FIX'
        })
    }

    # --- effective outcome: verification is authoritative -----------------------
    $selfReportedPassFailedVerification = ($currentResult -eq 'SUCCESS' -and $verificationResult -eq 'FAILED')
    if ($currentResult -eq 'SUCCESS' -and $verificationResult -ne 'FAILED') {
        return New-EscalationDecision ($common + @{
            DecisionId = $decisionId; Status = 'STOP_SUCCESS'; Action = 'STOP_SUCCESS'
            FailureCategory = 'UNKNOWN_FAILURE'
            ReasonCodes = @('SUCCESS_VERIFIED')
            Explanation = 'attempt succeeded (verification not failed); no retry or escalation is needed'
            RequiresHuman = $false; HumanActionType = 'NONE'
        })
    }

    # --- classify the failure ---------------------------------------------------
    $classResult = $null
    if ($selfReportedPassFailedVerification) {
        $classResult = @{
            Category = 'VERIFICATION_FAILURE'; Class = 'QUALITY'; Mapped = $false
            MappedFrom = $null; BudgetStop = $false
            Reason = 'self-reported PASS failed independent verification (verification-driven escalation)'
        }
    } else {
        $classResult = Get-AiFailureCategory -RecordedFailureCategory (Get-ContractProperty $InputObject 'RecordedFailureCategory' $null) `
            -FailureCategory (Get-ContractProperty $InputObject 'FailureCategory' $null) `
            -VerificationResult $verificationResult -ClaudeReviewStatus $claudeStatus
    }
    $failureCategory = [string]$classResult.Category
    $failureClass = [string]$classResult.Class
    $budgetStop = [bool]$classResult.BudgetStop

    $reasonCodes = New-Object System.Collections.Generic.List[string]
    if ($selfReportedPassFailedVerification) { $null = $reasonCodes.Add('SELF_REPORTED_PASS_FAILED_VERIFICATION') }

    # --- GOVERNANCE class: terminal, never model escalation ---------------------
    if ($failureClass -eq 'GOVERNANCE') {
        $gov = Get-DbM20GovernanceAction $failureCategory
        return New-EscalationDecision ($common + @{
            DecisionId = $decisionId; Status = $gov.Status; Action = $gov.Action
            FailureCategory = $failureCategory
            ReasonCodes = @($gov.ReasonCodes)
            Explanation = $gov.Explanation
            RequiresHuman = $gov.RequiresHuman; HumanActionType = $gov.HumanActionType
        })
    }

    # --- budget stop (request-level ceiling) ------------------------------------
    $config = Get-ContractProperty $InputObject 'Configuration' $null
    $requirement = Get-ContractProperty $InputObject 'Requirement' $null
    $contextBudget = Get-ContractProperty $InputObject 'ContextBudget' $null
    $contextPackage = Get-ContractProperty $InputObject 'ContextPackage' $null
    $processingTier = [string](Get-ContractProperty $InputObject 'ProcessingTier' 'STANDARD')
    $timeBand = Get-ContractProperty $InputObject 'TimeBand' $null
    $cachedFraction = [double](Get-ContractProperty $InputObject 'CachedInputFraction' 0.0)
    $targetCurrency = [string](Get-ContractProperty $InputObject 'TargetCurrency' 'INR')
    $exchangeRate = Get-ContractProperty $InputObject 'ExchangeRate' $null
    $pricingOverride = Get-ContractProperty $InputObject 'PricingRecordIdOverride' $null
    $ceiling = Get-ContractProperty $InputObject 'MaxAllowedCost' $null

    function Invoke-DbM20NextCost([string]$p, [string]$m) {
        if (-not $p -or -not $m -or $null -eq $config) {
            return @{ NextAttemptCost = $null; NextCostCurrency = $null; NextCostUnknown = $true; CumulativeEstimatedCost = $cum.CumulativeEstimatedCost; CumulativeActualCost = $cum.CumulativeActualCost; PricingRecordId = $null; Message = 'no configuration supplied; next cost unknown' }
        }
        return Get-AiEscalationCost -ProviderId $p -ModelId $m -Requirement $requirement -Configuration $config `
            -Attempts $chainRecords -RequestTimestampUtc $ts -ProcessingTier $processingTier -TimeBand $timeBand `
            -CachedInputFraction $cachedFraction -TargetCurrency $targetCurrency -ExchangeRate $exchangeRate `
            -PricingRecordIdOverride $pricingOverride -ContextBudget $contextBudget -ContextPackage $contextPackage
    }

    $currentRouteCost = Invoke-DbM20NextCost $prevProvider $prevModel
    $budgetCheck = Test-DbM20BudgetCeiling -CumulativeCost $cum.CumulativeActualCost -NextEstimate $currentRouteCost.NextAttemptCost -Ceiling $ceiling
    if ($budgetStop -or $budgetCheck.Exceeded) {
        $rc = New-Object System.Collections.Generic.List[string]
        $null = $rc.Add('BUDGET_CEILING_REACHED')
        if ($budgetStop) { $null = $rc.Add('BUDGET_FAILURE_RECORDED') }
        return New-EscalationDecision ($common + @{
            DecisionId = $decisionId; Status = 'STOP_BUDGET_LIMIT'; Action = 'STOP_BUDGET_LIMIT'
            FailureCategory = $failureCategory
            EstimatedNextAttemptCost = $currentRouteCost.NextAttemptCost
            NextCostCurrency = $currentRouteCost.NextCostCurrency; NextCostUnknown = $currentRouteCost.NextCostUnknown
            ReasonCodes = @($rc)
            Explanation = $budgetCheck.Reason
            RequiresHuman = $false; HumanActionType = 'NONE'
        })
    }

    # --- attempt limit -----------------------------------------------------------
    if ($currentAttemptNumber -ge [int]$policy.MaxAttemptsPerTask) {
        return New-EscalationDecision ($common + @{
            DecisionId = $decisionId; Status = 'STOP_NO_ELIGIBLE_ESCALATION'; Action = 'STOP_NO_ELIGIBLE_ESCALATION'
            FailureCategory = $failureCategory
            ReasonCodes = @('ATTEMPT_LIMIT_REACHED')
            Explanation = "attempt limit reached ($currentAttemptNumber >= MaxAttemptsPerTask $($policy.MaxAttemptsPerTask)); no further attempt is planned"
            RequiresHuman = $false; HumanActionType = 'NONE'
        })
    }

    # --- policy stop / human lists (additive overrides) --------------------------
    $stopList = @(Get-ContractProperty $policy 'StopFailureCategories' @())
    $humanList = @(Get-ContractProperty $policy 'HumanGateFailureCategories' @())
    if ($failureCategory -in $stopList) {
        return New-EscalationDecision ($common + @{
            DecisionId = $decisionId; Status = 'STOP_GOVERNANCE'; Action = 'STOP_GOVERNANCE'
            FailureCategory = $failureCategory
            ReasonCodes = @('NO_QUALITY_ESCALATION_FOR_NON_AI', 'GOVERNANCE_BLOCKED')
            Explanation = "failure category '$failureCategory' is in the policy StopFailureCategories; the decision stops"
            RequiresHuman = $false; HumanActionType = 'NONE'
        })
    }
    if ($failureCategory -in $humanList) {
        $gitTypes = @('HUMAN_GIT_GATE', 'PR_PENDING', 'MERGE_PENDING')
        $isGit = $failureCategory -in $gitTypes
        $status = if ($isGit) { 'HUMAN_GIT_ACTION_REQUIRED' } elseif ($failureCategory -eq 'SCOPE_CHANGE_REQUIRED') { 'HUMAN_GOVERNANCE_REQUIRED' } else { 'HUMAN_REVIEW_REQUIRED' }
        $humanType = if ($isGit) { 'GIT_ACTION' } elseif ($failureCategory -eq 'SCOPE_CHANGE_REQUIRED') { 'GOVERNANCE_REVIEW' } else { 'REVIEW_FIX' }
        return New-EscalationDecision ($common + @{
            DecisionId = $decisionId; Status = $status; Action = $status
            FailureCategory = $failureCategory
            ReasonCodes = @('NO_QUALITY_ESCALATION_FOR_NON_AI', $failureCategory)
            Explanation = "failure category '$failureCategory' is in the policy HumanGateFailureCategories; a human action is required and no model escalation is attempted"
            RequiresHuman = $true; HumanActionType = $humanType
        })
    }

    # --- category action table ---------------------------------------------------
    $eligible = @(Get-ContractProperty $InputObject 'EligibleCandidates' @())
    $rejected = @(Get-ContractProperty $InputObject 'RejectedCandidates' @())
    $routeCandidate = Get-DbM20RouteCandidate -Candidates $eligible -ProviderId $prevProvider -ModelId $prevModel
    $supportedLevels = @(Get-DbM20ArrayValue $routeCandidate 'ReasoningLevelsSupported')
    $currentWindow = Get-ContractProperty $routeCandidate 'ContextWindow' $null
    $counts = Get-DbM20ChainCounts -ChainRecords $chainRecords -CurrentModelId $prevModel

    # candidate ranking (only DB-M19 ELIGIBLE candidates; current + visited excluded)
    $ranked = Get-AiEscalationCandidates -EligibleCandidates $eligible -RejectedCandidates $rejected `
        -CurrentProviderId $prevProvider -CurrentModelId $prevModel -Attempts $chainRecords -Policy $policy

    function Select-DbM20RouteCandidate {
        <#
        .SYNOPSIS
        Pick the highest-ranked candidate whose exact (provider, model, reasoning)
        combination is not a loop revisit. Returns the ranked row or $null.
        #>
        foreach ($row in @($ranked.Candidates)) {
            $loop = Test-AiEscalationLoop -Attempts $chainRecords -ProposedProvider $row.ProviderId -ProposedModel $row.ModelId -ProposedReasoningLevel $row.SelectedReasoningLevel
            if (-not $loop.Cyclic) { return $row }
        }
        return $null
    }

    # --- finalize a decision from an action spec + chosen next route -------------
    function Complete-DbM20Decision {
        param(
            [hashtable]$Base,
            [string]$DecisionId,
            [string]$FailureCategory,
            [string]$Action,
            [string]$Status,
            [AllowNull()][string]$NextProvider,
            [AllowNull()][string]$NextModel,
            [AllowNull()][string]$NextReasoning,
            [string]$ContextAction,
            [AllowNull()][object]$RouteCost,
            [string[]]$ReasonCodes,
            [string]$Explanation,
            [bool]$RequiresHuman,
            [string]$HumanActionType,
            [string]$PerformanceEvidenceReference
        )
        $cost = $RouteCost
        if ($null -eq $cost) { $cost = @{ NextAttemptCost = $null; NextCostCurrency = $null; NextCostUnknown = $true } }
        return New-EscalationDecision ($Base + @{
            DecisionId = $DecisionId; Status = $Status; Action = $Action
            FailureCategory = $FailureCategory
            NextProviderId = $NextProvider; NextModelId = $NextModel; NextReasoningLevel = $NextReasoning
            ContextAction = $ContextAction
            EstimatedNextAttemptCost = $cost.NextAttemptCost
            NextCostCurrency = $cost.NextCostCurrency; NextCostUnknown = $cost.NextCostUnknown
            ReasonCodes = @($ReasonCodes)
            Explanation = $Explanation
            RequiresHuman = $RequiresHuman; HumanActionType = $HumanActionType
            PerformanceEvidenceReference = $PerformanceEvidenceReference
        })
    }

    # helper to apply the budget ceiling re-check on the chosen next route
    function Test-DbM20NextBudget([object]$RouteCost) {
        if ($null -eq $RouteCost) { return @{ Exceeded = $false; Reason = $null } }
        $check = Test-DbM20BudgetCeiling -CumulativeCost $RouteCost.CumulativeActualCost -NextEstimate $RouteCost.NextAttemptCost -Ceiling $ceiling
        return @{ Exceeded = $check.Exceeded; Reason = $check.Reason }
    }

    $actionSpec = $null
    switch ($failureClass) {
        'AUTHENTICATION' {
            $actionSpec = @{
                Status = 'STOP_NO_ELIGIBLE_ESCALATION'; Action = 'STOP_NO_ELIGIBLE_ESCALATION'
                ReasonCodes = @('AUTH_NOT_MODEL_ISSUE')
                Explanation = "authentication failure is not a model-quality problem; resolve credentials. No retry, reasoning or model escalation is attempted."
                RequiresHuman = $true; HumanActionType = 'AUTH_ACTION'
                NextProvider = $null; NextModel = $null; NextReasoning = $null
            }
        }
        'CONTEXT' {
            if ($failureCategory -eq 'CONTEXT_INSUFFICIENT') {
                $actionSpec = @{
                    Status = 'RECOMMENDED'; Action = 'REQUEST_MISSING_CONTEXT'
                    ContextAction = 'REQUEST_MISSING_CONTEXT'
                    ReasonCodes = @('CONTEXT_INSUFFICIENT')
                    Explanation = 'the provided context is insufficient for the task; request the missing context before the next attempt (mandatory governance context is retained)'
                    RequiresHuman = $true; HumanActionType = 'CONTEXT_PROVISION'
                    NextProvider = $prevProvider; NextModel = $prevModel; NextReasoning = $prevReasoning
                }
            } else {
                # CONTEXT_TOO_LARGE: prefer a larger-context eligible model, else rebuild
                $minWin = $currentWindow
                if ($null -eq $minWin) { $minWin = Get-ContractProperty $requirement 'RequiredContextTokens' $null }
                $contextRanked = Get-AiEscalationCandidates -EligibleCandidates $eligible -RejectedCandidates $rejected `
                    -CurrentProviderId $prevProvider -CurrentModelId $prevModel -Attempts $chainRecords -Policy $policy `
                    -MinimumContextWindow ($minWin)
                $candidate = $null
                foreach ($row in @($contextRanked.Candidates)) {
                    $loop = Test-AiEscalationLoop -Attempts $chainRecords -ProposedProvider $row.ProviderId -ProposedModel $row.ModelId -ProposedReasoningLevel $row.SelectedReasoningLevel
                    if (-not $loop.Cyclic) { $candidate = $row; break }
                }
                if ($null -ne $candidate -and $policy.AllowModelSwitch -eq $true) {
                    $actionSpec = @{
                        Status = 'RECOMMENDED'; Action = 'SWITCH_MODEL'
                        ContextAction = 'KEEP_CONTEXT'
                        ReasonCodes = @('CONTEXT_TOO_LARGE_SWITCH_MODEL')
                        Explanation = "the mandatory context does not fit the current window; switch to an eligible model with a larger context window ($($candidate.ProviderId)/$($candidate.ModelId))"
                        RequiresHuman = $false; HumanActionType = 'NONE'
                        NextProvider = $candidate.ProviderId; NextModel = $candidate.ModelId
                        NextReasoning = if ($candidate.SelectedReasoningLevel) { $candidate.SelectedReasoningLevel } else { $prevReasoning }
                        Candidate = $candidate
                    }
                } elseif ($policy.AllowContextRebuild -eq $true) {
                    $actionSpec = @{
                        Status = 'RECOMMENDED'; Action = 'REBUILD_CONTEXT'
                        ContextAction = 'REBUILD_CONTEXT'
                        ReasonCodes = @('CONTEXT_TOO_LARGE_REBUILD', 'MANDATORY_GOVERNANCE_RETAINED')
                        Explanation = 'context exceeds the current window and no larger-window eligible model is available; rebuild the context package (mandatory governance context is NEVER removed)'
                        RequiresHuman = $false; HumanActionType = 'NONE'
                        NextProvider = $prevProvider; NextModel = $prevModel; NextReasoning = $prevReasoning
                    }
                } else {
                    $actionSpec = @{
                        Status = 'STOP_NO_ELIGIBLE_ESCALATION'; Action = 'STOP_NO_ELIGIBLE_ESCALATION'
                        ContextAction = 'KEEP_CONTEXT'
                        ReasonCodes = @('CONTEXT_TOO_LARGE_REBUILD')
                        Explanation = 'context too large; no larger-window model and context rebuild is disabled; stop'
                        RequiresHuman = $false; HumanActionType = 'NONE'
                        NextProvider = $null; NextModel = $null; NextReasoning = $null
                    }
                }
            }
        }
        'TRANSIENT' {
            switch ($failureCategory) {
                'TIMEOUT' {
                    $retry = Test-AiRetryAllowed -Category $failureCategory -AttemptNumber $nextAttemptNumber -Policy $policy -Attempts $chainRecords -CurrentModelId $prevModel -LoopFree $true
                    if ($retry.Allowed) {
                        $actionSpec = @{ Status='RECOMMENDED'; Action='RETRY_SAME_ROUTE'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('RETRY_TRANSIENT'); Explanation='transient timeout; a same-route retry is justified and within all limits'; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$prevProvider; NextModel=$prevModel; NextReasoning=$prevReasoning }
                    } elseif ($policy.AllowProviderRouteSwitch -eq $true) {
                        $alt = $null
                        foreach ($row in @($ranked.Candidates)) {
                            if ($row.ProviderId.ToLowerInvariant() -ne $prevProvider.ToLowerInvariant()) { $alt = $row; break }
                        }
                        if ($null -ne $alt) {
                            $actionSpec = @{ Status='RECOMMENDED'; Action='SWITCH_PROVIDER_ROUTE'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('RETRY_TRANSIENT','PROVIDER_AVAILABILITY_ROUTE_SWITCH'); Explanation="same-route retry exhausted; switch provider route to $($alt.ProviderId)/$($alt.ModelId)"; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$alt.ProviderId; NextModel=$alt.ModelId; NextReasoning=if ($alt.SelectedReasoningLevel) { $alt.SelectedReasoningLevel } else { $prevReasoning }; Candidate=$alt }
                        } else {
                            $actionSpec = @{ Status='STOP_NO_ELIGIBLE_ESCALATION'; Action='STOP_NO_ELIGIBLE_ESCALATION'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('RETRY_SAME_MODEL_EXHAUSTED','MODEL_ESCALATION_NONE_ELIGIBLE'); Explanation='transient timeout; retry budget exhausted and no alternate provider route; stop'; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
                        }
                    } else {
                        $actionSpec = @{ Status='STOP_NO_ELIGIBLE_ESCALATION'; Action='STOP_NO_ELIGIBLE_ESCALATION'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('RETRY_SAME_MODEL_EXHAUSTED'); Explanation='transient timeout; retry budget exhausted and provider-route switch disabled; stop'; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
                    }
                }
                default {
                    # PROVIDER_AVAILABILITY / RATE_LIMIT / TOOL_FAILURE
                    $isProviderOrRate = ($failureCategory -in @('PROVIDER_AVAILABILITY', 'RATE_LIMIT'))
                    $routeReasonCode = if ($failureCategory -eq 'RATE_LIMIT') { 'RATE_LIMIT_ROUTE_SWITCH' } else { 'PROVIDER_AVAILABILITY_ROUTE_SWITCH' }
                    if ($isProviderOrRate -and $policy.AllowProviderRouteSwitch -eq $true) {
                        $alt = $null
                        foreach ($row in @($ranked.Candidates)) {
                            if ($row.ProviderId.ToLowerInvariant() -ne $prevProvider.ToLowerInvariant()) { $alt = $row; break }
                        }
                        if ($null -ne $alt) {
                            $actionSpec = @{ Status='RECOMMENDED'; Action='SWITCH_PROVIDER_ROUTE'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@($routeReasonCode); Explanation="'$failureCategory' is a provider-route condition; switch provider route to $($alt.ProviderId)/$($alt.ModelId)"; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$alt.ProviderId; NextModel=$alt.ModelId; NextReasoning=if ($alt.SelectedReasoningLevel) { $alt.SelectedReasoningLevel } else { $prevReasoning }; Candidate=$alt }
                            break
                        }
                    }
                    if ($null -eq $actionSpec) {
                        $retry = Test-AiRetryAllowed -Category $failureCategory -AttemptNumber $nextAttemptNumber -Policy $policy -Attempts $chainRecords -CurrentModelId $prevModel -LoopFree $true
                        if ($retry.Allowed) {
                            $actionSpec = @{ Status='RECOMMENDED'; Action='RETRY_SAME_ROUTE'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('RETRY_TRANSIENT'); Explanation="'$failureCategory' is transient; a same-route retry is justified and within all limits"; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$prevProvider; NextModel=$prevModel; NextReasoning=$prevReasoning }
                        } else {
                            $actionSpec = @{ Status='STOP_NO_ELIGIBLE_ESCALATION'; Action='STOP_NO_ELIGIBLE_ESCALATION'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('RETRY_SAME_MODEL_EXHAUSTED'); Explanation="'$failureCategory' retry budget exhausted and no alternate route; stop"; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
                        }
                    }
                }
            }
        }
        'QUALITY' {
            if ($failureCategory -in @('VERIFICATION_FAILURE', 'CLAUDE_REVIEW_FIX', 'INVALID_OUTPUT')) {
                if ($counts.CorrectionCount -eq 0) {
                    $correctionRc = @('CORRECT_CURRENT_ATTEMPT', $failureCategory)
                    if ($selfReportedPassFailedVerification) { $correctionRc = @($correctionRc) + @('SELF_REPORTED_PASS_FAILED_VERIFICATION') }
                    $actionSpec = @{
                        Status = 'RECOMMENDED'; Action = 'CORRECT_CURRENT_ATTEMPT'
                        ContextAction = 'KEEP_CONTEXT'
                        ReasonCodes = $correctionRc
                        Explanation = 'focused correction: preserve the verified work and correct only the failed delta on the same route (FIX over rebuild/retry); self-reported PASS failed independent verification'
                        RequiresHuman = $false; HumanActionType = 'NONE'
                        NextProvider = $prevProvider; NextModel = $prevModel; NextReasoning = $prevReasoning
                    }
                } else {
                    # repeat correction -> escalate reasoning -> model -> fix task
                    $nextReasoning = Get-AiNextReasoningLevel -CurrentLevel $prevReasoning -SupportedLevels $supportedLevels -ReasoningEscalationsUsed $counts.ReasoningEscalationsUsed -Policy $policy
                    if ($nextReasoning.Allowed) {
                        $actionSpec = @{
                            Status = 'RECOMMENDED'; Action = 'RETRY_SAME_MODEL_HIGHER_REASONING'
                            ContextAction = 'KEEP_CONTEXT'
                            ReasonCodes = @('REPEAT_CORRECTION_ESCALATE', 'REASONING_ESCALATION')
                            Explanation = "repeated verification/review failure; escalate reasoning to '$($nextReasoning.NextLevel)' before another correction attempt"
                            RequiresHuman = $false; HumanActionType = 'NONE'
                            NextProvider = $prevProvider; NextModel = $prevModel; NextReasoning = $nextReasoning.NextLevel
                        }
                    } elseif ($policy.AllowModelSwitch -eq $true -and $counts.ModelEscalationsUsed -lt [int]$policy.MaxModelEscalations) {
                        $candidate = Select-DbM20RouteCandidate
                        if ($null -ne $candidate) {
                            $actionSpec = @{
                                Status = 'RECOMMENDED'; Action = 'SWITCH_MODEL'
                                ContextAction = 'KEEP_CONTEXT'
                                ReasonCodes = @('REPEAT_CORRECTION_ESCALATE', 'MODEL_ESCALATION')
                                Explanation = "repeated correction at every allowed reasoning level; switch to eligible model $($candidate.ProviderId)/$($candidate.ModelId)"
                                RequiresHuman = $false; HumanActionType = 'NONE'
                                NextProvider = $candidate.ProviderId; NextModel = $candidate.ModelId
                                NextReasoning = if ($candidate.SelectedReasoningLevel) { $candidate.SelectedReasoningLevel } else { $prevReasoning }
                                Candidate = $candidate
                            }
                        } else {
                            $actionSpec = @{ Status='RECOMMENDED'; Action='NEW_FIX_TASK_REQUIRED'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('NEW_FIX_TASK_REPRESENT_ONLY'); Explanation='repeated verification failure with no eligible escalation; a fix task is required (represent-only -- no roadmap/workbook record is ever created)'; RequiresHuman=$true; HumanActionType='FIX_TASK'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
                        }
                    } else {
                        $actionSpec = @{ Status='RECOMMENDED'; Action='NEW_FIX_TASK_REQUIRED'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('NEW_FIX_TASK_REPRESENT_ONLY'); Explanation='repeated verification failure and model escalation is exhausted; a fix task is required (represent-only -- no roadmap/workbook record is ever created)'; RequiresHuman=$true; HumanActionType='FIX_TASK'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
                    }
                }
            } elseif ($failureCategory -eq 'MODEL_QUALITY') {
                $nextReasoning = Get-AiNextReasoningLevel -CurrentLevel $prevReasoning -SupportedLevels $supportedLevels -ReasoningEscalationsUsed $counts.ReasoningEscalationsUsed -Policy $policy
                if ($nextReasoning.Allowed) {
                    $actionSpec = @{
                        Status = 'RECOMMENDED'; Action = 'RETRY_SAME_MODEL_HIGHER_REASONING'
                        ContextAction = 'KEEP_CONTEXT'
                        ReasonCodes = @('REASONING_ESCALATION')
                        Explanation = "model-quality failure; escalate reasoning to '$($nextReasoning.NextLevel)' (one step, within limits) on the same model"
                        RequiresHuman = $false; HumanActionType = 'NONE'
                        NextProvider = $prevProvider; NextModel = $prevModel; NextReasoning = $nextReasoning.NextLevel
                    }
                } elseif ($policy.AllowModelSwitch -eq $true -and $counts.ModelEscalationsUsed -lt [int]$policy.MaxModelEscalations) {
                    $candidate = Select-DbM20RouteCandidate
                    if ($null -ne $candidate) {
                        $actionSpec = @{
                            Status = 'RECOMMENDED'; Action = 'SWITCH_MODEL'
                            ContextAction = 'KEEP_CONTEXT'
                            ReasonCodes = @('MODEL_ESCALATION')
                            Explanation = "model-quality failure and reasoning escalation exhausted; switch to eligible model $($candidate.ProviderId)/$($candidate.ModelId)"
                            RequiresHuman = $false; HumanActionType = 'NONE'
                            NextProvider = $candidate.ProviderId; NextModel = $candidate.ModelId
                            NextReasoning = if ($candidate.SelectedReasoningLevel) { $candidate.SelectedReasoningLevel } else { $prevReasoning }
                            Candidate = $candidate
                        }
                    } else {
                        $actionSpec = @{ Status='STOP_NO_ELIGIBLE_ESCALATION'; Action='STOP_NO_ELIGIBLE_ESCALATION'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('MODEL_ESCALATION_NONE_ELIGIBLE'); Explanation='no eligible model escalation exists (hard filters were never bypassed); stop'; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
                    }
                } else {
                    $actionSpec = @{ Status='STOP_NO_ELIGIBLE_ESCALATION'; Action='STOP_NO_ELIGIBLE_ESCALATION'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('MODEL_ESCALATION_NONE_ELIGIBLE'); Explanation='model-quality failure but reasoning escalation is blocked and model escalation is exhausted or disabled; stop'; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
                }
            } else {
                # BUILD_FAILURE / TEST_FAILURE: repair retry -> correction -> fix task
                $retry = Test-AiRetryAllowed -Category $failureCategory -AttemptNumber $nextAttemptNumber -Policy $policy -Attempts $chainRecords -CurrentModelId $prevModel -LoopFree $true
                if ($retry.Allowed) {
                    $actionSpec = @{ Status='RECOMMENDED'; Action='RETRY_SAME_ROUTE'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('RETRY_REPAIR'); Explanation="'$failureCategory' is a repair condition; a same-route retry is justified and within all limits"; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$prevProvider; NextModel=$prevModel; NextReasoning=$prevReasoning }
                } elseif ($counts.CorrectionCount -lt 1 -and $currentAttemptNumber -lt [int]$policy.MaxAttemptsPerTask) {
                    $actionSpec = @{ Status='RECOMMENDED'; Action='CORRECT_CURRENT_ATTEMPT'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('CORRECT_CURRENT_ATTEMPT'); Explanation="'$failureCategory' with retry budget exhausted; apply a focused correction of the failed delta"; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$prevProvider; NextModel=$prevModel; NextReasoning=$prevReasoning }
                } else {
                    $actionSpec = @{ Status='RECOMMENDED'; Action='NEW_FIX_TASK_REQUIRED'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('NEW_FIX_TASK_REPRESENT_ONLY'); Explanation="'$failureCategory' persists after retry and correction; a fix task is required (represent-only -- no roadmap/workbook record is ever created)"; RequiresHuman=$true; HumanActionType='FIX_TASK'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
                }
            }
        }
        default {
            # UNKNOWN: conservative -- never escalate an unknown failure to a bigger model
            $actionSpec = @{ Status='STOP_NO_ELIGIBLE_ESCALATION'; Action='STOP_NO_ELIGIBLE_ESCALATION'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('UNKNOWN_CONSERVATIVE'); Explanation='unknown failure; escalation to a stronger model is NOT justified by unknown evidence; stop conservatively'; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
        }
    }

    # --- finalize: loop protection + cost ceiling re-check on the chosen route ----
    # Route-changing escalations (new reasoning level / new model / new provider)
    # get the proposal loop check: an exact (provider, model, reasoning) combination
    # already in the chain is a revisit and is refused. Same-route actions (retry,
    # focused correction, context rebuild, missing-context request) REUSE the current
    # route by design; their loop safety comes from MaxSameModelRetries +
    # MaxAttemptsPerTask + the chain LoopFree validation, so the route check does
    # not apply (the route is the point).
    $routeChangingActions = @('RETRY_SAME_MODEL_HIGHER_REASONING', 'SWITCH_MODEL', 'SWITCH_PROVIDER_ROUTE')
    $sameRouteActions = @('RETRY_SAME_ROUTE', 'CORRECT_CURRENT_ATTEMPT', 'REBUILD_CONTEXT', 'REQUEST_MISSING_CONTEXT')
    $chosenCost = $null
    if ($actionSpec.Action -in $routeChangingActions) {
        $loop = Test-AiEscalationLoop -Attempts $chainRecords -ProposedProvider $actionSpec.NextProvider -ProposedModel $actionSpec.NextModel -ProposedReasoningLevel $actionSpec.NextReasoning
        if ($loop.Cyclic) {
            $actionSpec = @{ Status='STOP_NO_ELIGIBLE_ESCALATION'; Action='STOP_NO_ELIGIBLE_ESCALATION'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('LOOP_PREVENTED'); Explanation="the proposed route/reasoning combination was already attempted ($($loop.Reason)); the escalation loop is prevented"; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
            $chosenCost = $currentRouteCost
        } else {
            $chosenCost = Invoke-DbM20NextCost $actionSpec.NextProvider $actionSpec.NextModel
            $budget = Test-DbM20NextBudget $chosenCost
            if ($budget.Exceeded) {
                $actionSpec = @{ Status='STOP_BUDGET_LIMIT'; Action='STOP_BUDGET_LIMIT'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('BUDGET_CEILING_REACHED'); Explanation=$budget.Reason; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
            }
        }
    } elseif ($actionSpec.Action -in $sameRouteActions) {
        # same route by design: the cost ceiling still applies to the next attempt.
        $chosenCost = $currentRouteCost
        $budget = Test-DbM20NextBudget $chosenCost
        if ($budget.Exceeded) {
            $actionSpec = @{ Status='STOP_BUDGET_LIMIT'; Action='STOP_BUDGET_LIMIT'; ContextAction='KEEP_CONTEXT'; ReasonCodes=@('BUDGET_CEILING_REACHED'); Explanation=$budget.Reason; RequiresHuman=$false; HumanActionType='NONE'; NextProvider=$null; NextModel=$null; NextReasoning=$null }
        }
    }

    # performance evidence reference for the chosen candidate
    $perfRef = $null
    if ($actionSpec.ContainsKey('Candidate') -and $null -ne $actionSpec['Candidate']) {
        $perfRef = $actionSpec['Candidate'].PerformanceEvidenceReference
    }

    $status = if ($actionSpec.Status) { $actionSpec.Status } else { $actionSpec.Action }
    return Complete-DbM20Decision -Base $common -DecisionId $decisionId -FailureCategory $failureCategory `
        -Action $actionSpec.Action -Status $status `
        -NextProvider $actionSpec.NextProvider -NextModel $actionSpec.NextModel -NextReasoning $actionSpec.NextReasoning `
        -ContextAction $actionSpec.ContextAction -RouteCost $chosenCost `
        -ReasonCodes @($actionSpec.ReasonCodes) -Explanation $actionSpec.Explanation `
        -RequiresHuman $actionSpec.RequiresHuman -HumanActionType $actionSpec.HumanActionType `
        -PerformanceEvidenceReference $perfRef
}

# EscalationPolicy.ps1 -- DB-M20 escalation-policy contracts + vocabularies.
#
# DB-M20 is a DECISION ENGINE: it computes a deterministic retry / escalation
# plan for a failed AI attempt and NEVER executes a provider or model. There is
# no live AI invocation, no paid API call, no network call and no autonomous
# Nexus change. AUTO_EXECUTION_ENABLED = FALSE (the engine refuses AUTO mode).
#
# This file owns:
#   - the DB-M20 escalation failure-category vocabulary (a DB-M20-owned superset
#     of the DB-M17 recorded categories; DB-M17 files are consumed read-only),
#   - the failure CLASS mapping (TRANSIENT / QUALITY / CONTEXT / AUTHENTICATION /
#     BUDGET / GOVERNANCE / UNKNOWN), which drives what kinds of escalation are
#     ever legal (GOVERNANCE-class failures NEVER escalate to a model),
#   - the structured action vocabulary (never free text),
#   - the EscalationPolicy v1 configuration data contract,
#   - the default policy object.
#
# EscalationPolicy v1 is PURE CONFIGURATION DATA. The decision engine reads its
# limits and switches; nothing is hard-coded in the engine. ADR-005 applies:
# no business logic branches on a provider/model name.
#
# READ-ONLY consumers: DB-M14 vocabularies (dot-sourced), DB-M17 recorded
# categories (read through AttemptStore.ps1, never modified).

. (Join-Path $PSScriptRoot "..\AiRoutingContracts.ps1")   # DB-M14 vocab + helpers (READ-ONLY)

# -----------------------------------------------------------------------------
# Schema versions (DB-M20-owned; the DB-M14 registry is NOT modified)
# -----------------------------------------------------------------------------
function Get-DbM20SchemaVersions {
    return [pscustomobject]@{
        EscalationPolicyVersion        = 1
        EscalationInputVersion         = 1
        EscalationDecisionVersion      = 1
        EscalationChainVersion         = 1
        EscalationFailureCategoryVersion = 1
    }
}

# -----------------------------------------------------------------------------
# Failure-category vocabulary (DB-M20 escalation-facing superset of DB-M17)
# -----------------------------------------------------------------------------
function Get-DbM20FailureCategories {
    <#
    .SYNOPSIS
    The DB-M20 escalation failure-category vocabulary. It is the authoritative
    vocabulary for escalation decisions and is a SUPERSET of the DB-M17 recorded
    categories: every DB-M17 recorded category maps deterministically into this
    set (see FailureClassification.ps1). DB-M20-specific categories (TIMEOUT,
    CONTEXT_TOO_LARGE/CONTEXT_INSUFFICIENT, INVALID_OUTPUT, VERIFICATION_FAILURE,
    CLAUDE_REVIEW_FIX, SCOPE_CHANGE_REQUIRED, GOVERNANCE_BLOCKED, HUMAN_GIT_GATE,
    PR_PENDING, MERGE_PENDING, ARCHITECTURE_CONFLICT, UNKNOWN_FAILURE) arrive as
    escalation inputs from the attempt's verification / review / governance
    signals, not as DB-M17-recorded values.
    #>
    return @(
        'MODEL_QUALITY', 'PROVIDER_AVAILABILITY', 'RATE_LIMIT', 'AUTHENTICATION',
        'TIMEOUT', 'CONTEXT_TOO_LARGE', 'CONTEXT_INSUFFICIENT', 'INVALID_OUTPUT',
        'TOOL_FAILURE', 'BUILD_FAILURE', 'TEST_FAILURE', 'VERIFICATION_FAILURE',
        'CLAUDE_REVIEW_FIX', 'SCOPE_CHANGE_REQUIRED', 'GOVERNANCE_BLOCKED',
        'HUMAN_GIT_GATE', 'PR_PENDING', 'MERGE_PENDING', 'ARCHITECTURE_CONFLICT',
        'UNKNOWN_FAILURE'
    )
}

function Test-IsValidDbM20FailureCategory([string]$Value) {
    return ($Value -in (Get-DbM20FailureCategories))
}

function Get-DbM20FailureClasses {
    <#
    .SYNOPSIS
    The failure CLASS vocabulary. The class decides which escalation families are
    ever legal. GOVERNANCE-class failures are non-AI: they NEVER escalate to a
    model, a reasoning level or a retry. AUTHENTICATION is never a
    model-quality problem. UNKNOWN is always handled conservatively.
    #>
    return @('TRANSIENT', 'QUALITY', 'CONTEXT', 'AUTHENTICATION', 'BUDGET', 'GOVERNANCE', 'UNKNOWN')
}

function Get-DbM20FailureClassMap {
    <#
    .SYNOPSIS
    Deterministic category -> class map (the single source of truth for the
    decision engine's legality checks).
    #>
    return @{
        'MODEL_QUALITY'        = 'QUALITY'
        'PROVIDER_AVAILABILITY' = 'TRANSIENT'
        'RATE_LIMIT'           = 'TRANSIENT'
        'AUTHENTICATION'       = 'AUTHENTICATION'
        'TIMEOUT'              = 'TRANSIENT'
        'CONTEXT_TOO_LARGE'    = 'CONTEXT'
        'CONTEXT_INSUFFICIENT' = 'CONTEXT'
        'INVALID_OUTPUT'       = 'QUALITY'
        'TOOL_FAILURE'         = 'TRANSIENT'
        'BUILD_FAILURE'        = 'QUALITY'
        'TEST_FAILURE'         = 'QUALITY'
        'VERIFICATION_FAILURE' = 'QUALITY'
        'CLAUDE_REVIEW_FIX'    = 'QUALITY'
        'SCOPE_CHANGE_REQUIRED' = 'GOVERNANCE'
        'GOVERNANCE_BLOCKED'   = 'GOVERNANCE'
        'HUMAN_GIT_GATE'       = 'GOVERNANCE'
        'PR_PENDING'           = 'GOVERNANCE'
        'MERGE_PENDING'        = 'GOVERNANCE'
        'ARCHITECTURE_CONFLICT' = 'GOVERNANCE'
        'UNKNOWN_FAILURE'      = 'UNKNOWN'
    }
}

function Get-DbM20FailureClassForCategory([string]$Category) {
    $map = Get-DbM20FailureClassMap
    if ($map.ContainsKey($Category)) { return $map[$Category] }
    return 'UNKNOWN'
}

# -----------------------------------------------------------------------------
# Action vocabulary (structured, never free text)
# -----------------------------------------------------------------------------
function Get-DbM20Actions {
    <#
    .SYNOPSIS
    The structured action vocabulary of an EscalationDecision v1.
      RETRY_SAME_ROUTE                  - same provider/model route, same reasoning
      RETRY_SAME_MODEL_HIGHER_REASONING - same model, one reasoning level higher
      SWITCH_MODEL                      - different eligible model route
      SWITCH_PROVIDER_ROUTE             - different provider route (no network check)
      REBUILD_CONTEXT                   - rebuild the context package (governance retained)
      CORRECT_CURRENT_ATTEMPT           - preserve verified work; correct only the failed delta
      REQUEST_MISSING_CONTEXT           - ask for missing context; wait for it
      STOP_SUCCESS                      - verified success; stop
      STOP_NO_ELIGIBLE_ESCALATION       - no eligible escalation exists; stop
      STOP_BUDGET_LIMIT                 - request-level cost ceiling reached; stop
      STOP_GOVERNANCE                   - governance/architecture block; stop
      HUMAN_REVIEW_REQUIRED             - a human review is required (waiting)
      HUMAN_GOVERNANCE_REQUIRED         - a governance decision is required (waiting)
      HUMAN_GIT_ACTION_REQUIRED         - a human Git/PR/merge action is required (waiting)
      HUMAN_ARCHITECTURE_DECISION_REQUIRED - an architecture decision is required (waiting)
      NEW_FIX_TASK_REQUIRED             - represent-only: a fix task is required; NO
                                          roadmap/workbook record is ever created
    #>
    return @(
        'RETRY_SAME_ROUTE', 'RETRY_SAME_MODEL_HIGHER_REASONING', 'SWITCH_MODEL',
        'SWITCH_PROVIDER_ROUTE', 'REBUILD_CONTEXT', 'CORRECT_CURRENT_ATTEMPT',
        'REQUEST_MISSING_CONTEXT', 'STOP_SUCCESS', 'STOP_NO_ELIGIBLE_ESCALATION',
        'STOP_BUDGET_LIMIT', 'STOP_GOVERNANCE', 'HUMAN_REVIEW_REQUIRED',
        'HUMAN_GOVERNANCE_REQUIRED', 'HUMAN_GIT_ACTION_REQUIRED',
        'HUMAN_ARCHITECTURE_DECISION_REQUIRED', 'NEW_FIX_TASK_REQUIRED'
    )
}

function Get-DbM20ContextActions {
    <#
    .SYNOPSIS
    Context-handling vocabulary for the ContextAction field. Mandatory
    governance context is NEVER removed by any of these actions.
    #>
    return @('KEEP_CONTEXT', 'EXPAND_CONTEXT', 'REBUILD_CONTEXT', 'REDUCE_NOISE', 'REQUEST_MISSING_CONTEXT')
}

function Get-DbM20HumanActionTypes {
    return @('NONE', 'GIT_ACTION', 'GOVERNANCE_REVIEW', 'REVIEW_FIX', 'ARCHITECTURE_DECISION', 'CONTEXT_PROVISION', 'FIX_TASK', 'AUTH_ACTION')
}

function Get-DbM20DecisionStatuses {
    <#
    .SYNOPSIS
    EscalationDecision v1 status vocabulary. RECOMMENDED means a non-terminal
    next action is recommended (retry / escalate / correct / context). Every
    other status is TERMINAL: no further AI attempt is recommended.
    #>
    return @(
        'RECOMMENDED', 'STOP_SUCCESS', 'STOP_NO_ELIGIBLE_ESCALATION',
        'STOP_BUDGET_LIMIT', 'STOP_GOVERNANCE', 'HUMAN_REVIEW_REQUIRED',
        'HUMAN_GOVERNANCE_REQUIRED', 'HUMAN_GIT_ACTION_REQUIRED',
        'HUMAN_ARCHITECTURE_DECISION_REQUIRED', 'AUTO_EXECUTION_PROHIBITED'
    )
}

function Get-DbM20ReasonCodes {
    <#
    .SYNOPSIS
    Structured reason codes used in EscalationDecision.v1.ReasonCodes. These are
    vocabulary members, never free text; the Explanation field carries the
    human-readable detail.
    #>
    return @(
        'SUCCESS_VERIFIED', 'VERIFICATION_FAILED', 'CLAUDE_REVIEW_FIX',
        'VERIFICATION_FAILURE', 'INVALID_OUTPUT',
        'SELF_REPORTED_PASS_FAILED_VERIFICATION', 'RETRY_TRANSIENT',
        'RETRY_SAME_MODEL_EXHAUSTED', 'ATTEMPT_LIMIT_REACHED',
        'BUDGET_CEILING_REACHED', 'BUDGET_FAILURE_RECORDED',
        'GOVERNANCE_BLOCKED', 'SCOPE_CHANGE', 'GIT_GATE_PENDING',
        'PR_PENDING', 'MERGE_PENDING', 'ARCHITECTURE_CONFLICT',
        'AUTH_NOT_MODEL_ISSUE', 'RATE_LIMIT_ROUTE_SWITCH',
        'PROVIDER_AVAILABILITY_ROUTE_SWITCH', 'CONTEXT_TOO_LARGE_SWITCH_MODEL',
        'CONTEXT_TOO_LARGE_REBUILD', 'CONTEXT_INSUFFICIENT',
        'MANDATORY_GOVERNANCE_RETAINED', 'REASONING_ESCALATION',
        'REASONING_ESCALATION_BLOCKED', 'MODEL_ESCALATION',
        'MODEL_ESCALATION_NONE_ELIGIBLE', 'LOOP_PREVENTED',
        'NO_QUALITY_ESCALATION_FOR_NON_AI', 'UNKNOWN_CONSERVATIVE',
        'AUTO_PROHIBITED', 'CORRECT_CURRENT_ATTEMPT', 'REPEAT_CORRECTION_ESCALATE',
        'MAX_SAME_MODEL_RETRIES', 'MAX_REASONING_ESCALATIONS',
        'MAX_MODEL_ESCALATIONS', 'NEW_FIX_TASK_REPRESENT_ONLY',
        'RETRY_REPAIR', 'HUMAN_INTERVENTION_PENDING'
    )
}

# -----------------------------------------------------------------------------
# EscalationPolicy v1 (pure configuration data)
# -----------------------------------------------------------------------------
function New-EscalationPolicy {
    <#
    .SYNOPSIS
    Build a normalized EscalationPolicy v1. All limits and switches are DATA read
    by the decision engine; missing values normalize to the documented defaults.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$PolicyId,
        [string]$Name,
        [bool]$Enabled = $true,
        [Nullable[int]]$MaxAttemptsPerTask,
        [Nullable[int]]$MaxSameModelRetries,
        [Nullable[int]]$MaxReasoningEscalations,
        [Nullable[int]]$MaxModelEscalations,
        [Nullable[bool]]$AllowProviderRouteSwitch,
        [Nullable[bool]]$AllowReasoningIncrease,
        [Nullable[bool]]$AllowModelSwitch,
        [Nullable[bool]]$AllowContextRebuild,
        [string[]]$HumanGateFailureCategories,
        [string[]]$StopFailureCategories,
        [string]$MinimumVerificationEvidence,
        [string[]]$TieBreaker,
        [string]$Notes
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }

    $id = if ($InputObject) { & $g 'PolicyId' $PolicyId } else { $PolicyId }
    if (-not $id) { throw "New-EscalationPolicy: PolicyId is required" }
    $id = $id.Trim()

    $name = if ($InputObject) { & $g 'Name' $Name } else { $Name }
    if (-not $name) { $name = $id }

    $enabled = if ($InputObject) { [bool](& $g 'Enabled' $Enabled) } else { $Enabled }

    function Norm-Int([object]$Raw, [int]$Fallback) {
        if ($null -eq $Raw) { return $Fallback }
        return [int]$Raw
    }
    $maxAttempts       = Norm-Int $(if ($InputObject) { & $g 'MaxAttemptsPerTask' $MaxAttemptsPerTask } else { $MaxAttemptsPerTask }) 5
    $maxSameRetries    = Norm-Int $(if ($InputObject) { & $g 'MaxSameModelRetries' $MaxSameModelRetries } else { $MaxSameModelRetries }) 2
    $maxReasoning      = Norm-Int $(if ($InputObject) { & $g 'MaxReasoningEscalations' $MaxReasoningEscalations } else { $MaxReasoningEscalations }) 2
    $maxModelEscal     = Norm-Int $(if ($InputObject) { & $g 'MaxModelEscalations' $MaxModelEscalations } else { $MaxModelEscalations }) 1

    function Norm-Bool([object]$Raw, [bool]$Fallback) {
        if ($null -eq $Raw) { return $Fallback }
        return [bool]$Raw
    }
    $allowRoute  = Norm-Bool $(if ($InputObject) { & $g 'AllowProviderRouteSwitch' $AllowProviderRouteSwitch } else { $AllowProviderRouteSwitch }) $true
    $allowReason = Norm-Bool $(if ($InputObject) { & $g 'AllowReasoningIncrease' $AllowReasoningIncrease } else { $AllowReasoningIncrease }) $true
    $allowModel  = Norm-Bool $(if ($InputObject) { & $g 'AllowModelSwitch' $AllowModelSwitch } else { $AllowModelSwitch }) $true
    $allowCtx    = Norm-Bool $(if ($InputObject) { & $g 'AllowContextRebuild' $AllowContextRebuild } else { $AllowContextRebuild }) $true

    $humanGate = @()
    if ($InputObject) { $humanGate = @(& $g 'HumanGateFailureCategories' $HumanGateFailureCategories) }
    elseif ($HumanGateFailureCategories) { $humanGate = @($HumanGateFailureCategories) }

    $stopList = @()
    if ($InputObject) { $stopList = @(& $g 'StopFailureCategories' $StopFailureCategories) }
    elseif ($StopFailureCategories) { $stopList = @($StopFailureCategories) }

    $minVerif = if ($InputObject) { & $g 'MinimumVerificationEvidence' $MinimumVerificationEvidence } else { $MinimumVerificationEvidence }
    if (-not $minVerif) { $minVerif = 'VERIFIED' }
    $minVerif = $minVerif.Trim().ToUpperInvariant()

    $tie = @()
    if ($InputObject) { $tie = @(& $g 'TieBreaker' $TieBreaker) }
    elseif ($TieBreaker) { $tie = @($TieBreaker) }
    if ($tie.Count -eq 0) { $tie = @('PerformanceConfidence', 'SuccessRate', 'EstimatedCost', 'ModelId') }

    $notes = if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }

    return [pscustomobject]@{
        SchemaVersion               = 1
        PolicyId                    = $id
        Name                        = $name
        Enabled                     = $enabled
        MaxAttemptsPerTask          = $maxAttempts
        MaxSameModelRetries         = $maxSameRetries
        MaxReasoningEscalations     = $maxReasoning
        MaxModelEscalations         = $maxModelEscal
        AllowProviderRouteSwitch    = $allowRoute
        AllowReasoningIncrease      = $allowReason
        AllowModelSwitch            = $allowModel
        AllowContextRebuild         = $allowCtx
        HumanGateFailureCategories  = @($humanGate)
        StopFailureCategories       = @($stopList)
        MinimumVerificationEvidence = $minVerif
        TieBreaker                  = @($tie)
        Notes                       = $notes
    }
}

function Test-EscalationPolicy {
    <#
    .SYNOPSIS
    Deterministic structural validation of an EscalationPolicy v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Policy)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Policy) { return @{ Valid = $false; Errors = @('Policy is null'); Warnings = @() } }
    if ((Get-ContractProperty $Policy 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Policy 'PolicyId' '')) { $errors.Add('PolicyId is required') }

    $intFields = @('MaxAttemptsPerTask', 'MaxSameModelRetries', 'MaxReasoningEscalations', 'MaxModelEscalations')
    foreach ($fn in $intFields) {
        $v = Get-ContractProperty $Policy $fn $null
        if ($null -ne $v -and $v -lt 1) { $errors.Add("$fn must be >= 1 (found $v)") }
    }

    $mv = [string](Get-ContractProperty $Policy 'MinimumVerificationEvidence' '')
    if ($mv -and $mv -notin @('VERIFIED', 'PENDING', 'NONE')) { $errors.Add("MinimumVerificationEvidence '$mv' invalid (VERIFIED/PENDING/NONE)") }

    foreach ($cat in @(Get-ContractProperty $Policy 'StopFailureCategories' @())) {
        if (-not (Test-IsValidDbM20FailureCategory ([string]$cat))) { $errors.Add("StopFailureCategories entry '$cat' is not a DB-M20 failure category") }
    }
    foreach ($cat in @(Get-ContractProperty $Policy 'HumanGateFailureCategories' @())) {
        if (-not (Test-IsValidDbM20FailureCategory ([string]$cat))) { $errors.Add("HumanGateFailureCategories entry '$cat' is not a DB-M20 failure category") }
    }

    $knownTie = @('PerformanceConfidence', 'SuccessRate', 'EstimatedCost', 'ModelId', 'ContextWindow', 'SampleCount')
    foreach ($tb in @(Get-ContractProperty $Policy 'TieBreaker' @())) {
        if ($tb -notin $knownTie) { $errors.Add("TieBreaker entry '$tb' not supported (supported: $($knownTie -join ', '))") }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# -----------------------------------------------------------------------------
# Default escalation policy
# -----------------------------------------------------------------------------
function Get-DefaultEscalationPolicy {
    <#
    .SYNOPSIS
    The default DB-M20 escalation policy. Conservative by design:
      - bounded attempts and retries (no infinite loops),
      - reasoning escalation LOW -> MEDIUM -> HIGH, never an automatic jump to MAX,
      - model escalation only to DB-M19 eligible candidates, never ineligible routes,
      - governance / architecture / git / scope failures are ALWAYS terminal
        (the engine's fixed safety table; the policy lists are additive data),
      - request-level budget ceiling honored; no daily/monthly/org/team budgets,
      - deterministic tie-breakers for candidate ranking.
    #>
    return New-EscalationPolicy -PolicyId 'escalation-policy-default-v1' -Name 'DEFAULT' -Enabled $true `
        -MaxAttemptsPerTask 5 -MaxSameModelRetries 2 -MaxReasoningEscalations 2 -MaxModelEscalations 1 `
        -AllowProviderRouteSwitch $true -AllowReasoningIncrease $true -AllowModelSwitch $true -AllowContextRebuild $true `
        -HumanGateFailureCategories @('HUMAN_GIT_GATE', 'PR_PENDING', 'MERGE_PENDING', 'SCOPE_CHANGE_REQUIRED') `
        -StopFailureCategories @('GOVERNANCE_BLOCKED', 'ARCHITECTURE_CONFLICT') `
        -MinimumVerificationEvidence 'VERIFIED' `
        -TieBreaker @('PerformanceConfidence', 'SuccessRate', 'EstimatedCost', 'ModelId') `
        -Notes 'DB-M20 default. Bounded retries; reasoning escalation one step at a time; model escalation only to eligible candidates; governance/git/scope/architecture failures never escalate to a model; request-level budget ceiling only.'
}

# FailoverEngine.ps1 -- DB-M22 failover decision engine.
#
# Determines, for an unhealthy route, whether another eligible route can be
# recommended. Eligibility comes from DB-M19 (hard filters are never bypassed);
# budget permission comes from DB-M21 (a route over budget is never recommended
# for execution); known-failure suppression comes from DB-M21 fingerprints.
# DB-M22 is a DECISION ONLY: it never executes a provider/model, never switches
# the active workflow, never opens a network connection. AUTO_EXECUTION_ENABLED
# = FALSE. 0 paid API calls, 0 network calls.

. (Join-Path $PSScriptRoot "FailoverContracts.ps1")                 # DB-M22 failover contracts
. (Join-Path $PSScriptRoot "..\provider-health\ProviderHealthEngine.ps1") # DB-M22 health engine (READ-ONLY)
. (Join-Path $PSScriptRoot "..\budget\BudgetEngine.ps1")            # DB-M21 budget (READ-ONLY)
. (Join-Path $PSScriptRoot "..\failure-fingerprints\FingerprintEngine.ps1") # DB-M21 fingerprints (READ-ONLY)

# -----------------------------------------------------------------------------
# Eligible failover routes
# -----------------------------------------------------------------------------
function Get-EligibleFailoverRoutes {
    <#
    .SYNOPSIS
    Filter a set of DB-M19 ELIGIBLE candidates down to those whose route is
    currently usable (Test-ProviderRouteAvailable). Only candidates already
    declared ELIGIBLE by the router are considered -- a REJECTED candidate is
    never re-admitted here. Returns @{ Routes; RejectedByHealth; RejectedByRouter }.
    #>
    param(
        [AllowNull()][object[]]$EligibleCandidates,
        [AllowNull()][object[]]$RejectedCandidates,
        [AllowNull()][object[]]$HealthEvidence,
        [AllowNull()][pscustomobject]$HealthPolicy,
        $EvaluationTimestampUtc,
        [bool]$IsHighRisk = $true
    )
    if ($null -eq $HealthPolicy) { $HealthPolicy = Get-DefaultProviderHealthPolicy }
    $ts = ConvertTo-DbM22Utc $EvaluationTimestampUtc

    $rejectedByRouter = @()
    foreach ($c in @($RejectedCandidates)) {
        if ($null -eq $c) { continue }
        $modelId = Get-ContractProperty $c 'ModelId' ''
        $rejectedByRouter += "$(Get-ContractProperty $c 'ProviderId' '')/$modelId"
    }

    $healthy = New-Object System.Collections.ArrayList
    $rejectedByHealth = New-Object System.Collections.ArrayList
    foreach ($c in @($EligibleCandidates)) {
        if ($null -eq $c) { continue }
        $status = [string](Get-ContractProperty $c 'Status' '')
        if ($status -ne 'ELIGIBLE') {
            $modelId = Get-ContractProperty $c 'ModelId' ''
            $rejectedByRouter += "$(Get-ContractProperty $c 'ProviderId' '')/$modelId"
            continue
        }
        $providerId = Get-ContractProperty $c 'ProviderId' ''
        $gatewayId = Get-ContractProperty $c 'GatewayProviderId' ''
        $avail = Test-ProviderRouteAvailable -Evidence $HealthEvidence -Policy $HealthPolicy `
            -EvaluationTimestampUtc $ts -ProviderId $providerId -GatewayProviderId $gatewayId -IsHighRisk $IsHighRisk
        if ($avail.Available) {
            $null = $healthy.Add([pscustomobject]@{
                ProviderId = $providerId
                ModelId = Get-ContractProperty $c 'ModelId' ''
                UnderlyingModelId = Get-ContractProperty $c 'UnderlyingModelId' ''
                GatewayProviderId = $gatewayId
                RouteId = Get-DbM22RouteKey -ProviderId $providerId -GatewayProviderId $gatewayId
                HealthState = $avail.HealthState
                CircuitState = $avail.CircuitState
                HealthReasons = @($avail.Reasons)
                EstimatedCost = Get-ContractProperty $c 'EstimatedCost' $null
                CostCurrency = Get-ContractProperty $c 'CostCurrency' $null
                CostUnknown = Get-ContractProperty $c 'CostUnknown' $null
            })
        } else {
            $null = $rejectedByHealth.Add([pscustomobject]@{
                ProviderId = $providerId
                ModelId = Get-ContractProperty $c 'ModelId' ''
                UnderlyingModelId = Get-ContractProperty $c 'UnderlyingModelId' ''
                GatewayProviderId = $gatewayId
                HealthState = $avail.HealthState
                CircuitState = $avail.CircuitState
                Reasons = @($avail.Reasons)
            })
        }
    }

    # deterministic order (same input -> same output)
    $healthy = @($healthy | Sort-Object ProviderId, ModelId, GatewayProviderId)
    $rejectedByHealth = @($rejectedByHealth | Sort-Object ProviderId, ModelId, GatewayProviderId)

    return @{
        Routes = $healthy
        RejectedByHealth = $rejectedByHealth
        RejectedByRouter = @($rejectedByRouter | Sort-Object -Unique)
    }
}

# -----------------------------------------------------------------------------
# Failover decision
# -----------------------------------------------------------------------------
function Get-ProviderFailoverDecision {
    <#
    .SYNOPSIS
    The deterministic failover decision for an unhealthy route. Consumes:
      - DB-M22 health evidence -> effective original health
      - DB-M19 candidates (ELIGIBLE only) -> alternate routes
      - DB-M21 budget (Test-AiBudget) for an alternate route that would incur an
        AI call
      - DB-M21 fingerprints (Test-AiRepeatAttemptAllowed) to avoid a known
        identical provider-failure repeat
    Returns a ProviderFailoverDecision v1. Nothing is executed.
    #>
    param(
        [AllowNull()][object[]]$HealthEvidence,
        [AllowNull()][pscustomobject]$HealthPolicy,
        $EvaluationTimestampUtc,
        [string]$OriginalProviderId,
        [string]$OriginalModelId,
        [string]$OriginalGatewayProviderId,
        [AllowNull()][object[]]$EligibleCandidates,
        [AllowNull()][object[]]$RejectedCandidates,
        [AllowNull()][object]$BudgetEvaluation,          # DB-M21 BudgetEvaluation for the ORIGINAL route (nullable)
        [AllowNull()][object]$BudgetPolicy,              # DB-M21 BudgetPolicy (nullable)
        [AllowNull()][object]$KnownFingerprints,         # DB-M21 known fingerprint history (nullable)
        [AllowNull()][object]$M20Decision,               # DB-M20 EscalationDecision (nullable, read-only)
        [string]$TaskId,
        [string]$AttemptId,
        [bool]$IsHighRisk = $true,
        [string]$BudgetOverrideReference,
        [string]$BudgetOverrideReason,
        [string]$AttemptContextHash
    )
    if ($null -eq $HealthPolicy) { $HealthPolicy = Get-DefaultProviderHealthPolicy }
    $ts = ConvertTo-DbM22Utc $EvaluationTimestampUtc
    if ($null -eq $ts) { throw "Get-ProviderFailoverDecision: EvaluationTimestampUtc is required" }
    if (-not $OriginalProviderId) { throw "Get-ProviderFailoverDecision: OriginalProviderId is required" }

    $origKey = Get-DbM22RouteKey -ProviderId $OriginalProviderId -GatewayProviderId $OriginalGatewayProviderId

    # ---- 1. original route effective health ----
    $orig = Get-EffectiveProviderHealth -Evidence $HealthEvidence -Policy $HealthPolicy `
        -EvaluationTimestampUtc $ts -ProviderId $OriginalProviderId -GatewayProviderId $OriginalGatewayProviderId -IsHighRisk $IsHighRisk
    $origState = [string]$orig.HealthState

    # ---- 2. eligible alternate routes (health-filtered, DB-M19-respecting) ----
    $alt = Get-EligibleFailoverRoutes -EligibleCandidates $EligibleCandidates -RejectedCandidates $RejectedCandidates `
        -HealthEvidence $HealthEvidence -HealthPolicy $HealthPolicy -EvaluationTimestampUtc $ts -IsHighRisk $IsHighRisk
    $healthyRoutes = @($alt.Routes)

    # ---- 3. known-failure suppression (DB-M21 fingerprints) ----
    # Only an IDENTICAL repeat is suppressed (same provider, same failure category,
    # same context). A changed context is a meaningful change and is allowed
    # (DB-M21 Test-AiRepeatAttemptAllowed decides). Suppression -> the route must
    # not be retried on its own; a human provider decision is required.
    $suppressedRepeat = $false
    $suppressOutcome = ''
    if ($null -ne $KnownFingerprints) {
        $fp = New-FailureFingerprint @{
            TaskType = 'IMPLEMENTATION'; FailureCategory = 'PROVIDER_AVAILABILITY'
            NormalizedFailureCodes = @('provider-unavailable'); ToolCategory = 'PROVIDER'
            ProviderId = $OriginalProviderId; ModelId = $OriginalModelId
            GatewayProviderId = $OriginalGatewayProviderId; ContextHash = $AttemptContextHash
        }
        $ev = Get-AiKnownFailureEvidence -Fingerprint $fp -KnownFingerprints @($KnownFingerprints) -Result 'FAIL'
        $repeat = Test-AiRepeatAttemptAllowed -Evidence $ev -ProposedProviderId $OriginalProviderId `
            -ProposedModelId $OriginalModelId -ProposedReasoningLevel 'MEDIUM' `
            -ProposedContextHash $AttemptContextHash
        $suppressedRepeat = -not [bool](Get-ContractProperty $repeat 'Allowed' $true)
        $suppressOutcome = [string](Get-ContractProperty $repeat 'Outcome' '')
    }

    $reasons = New-Object System.Collections.ArrayList

    # ---- 4. choose the action ----
    # helper to build the decision
    function New-Dbm22FailDecision {
        param([string]$Action, [string[]]$ReasonCodes, [object]$Recommend, [bool]$ReqHuman, [string]$HumanType, [string]$Msg)
        $recommendedProvider = ''; $recommendedModel = ''; $recommendedRoute = ''
        if ($null -ne $Recommend) {
            $recommendedProvider = [string](Get-ContractProperty $Recommend 'ProviderId' '')
            $recommendedModel = [string](Get-ContractProperty $Recommend 'ModelId' '')
            $recommendedRoute = [string](Get-ContractProperty $Recommend 'RouteId' '')
        }
        $underlying = $null
        if ($null -ne $Recommend) { $underlying = Get-ContractProperty $Recommend 'UnderlyingModelId' $null }
        return New-ProviderFailoverDecision @{
            DecisionId = "FD-$origKey-$($ts.ToString('yyyyMMddHHmmss'))"
            TaskId = $TaskId; AttemptId = $AttemptId
            OriginalProviderId = $OriginalProviderId; OriginalModelId = $OriginalModelId
            OriginalRouteId = $origKey; OriginalHealthState = $origState
            Action = $Action
            RecommendedProviderId = $recommendedProvider; RecommendedModelId = $recommendedModel
            RecommendedRouteId = $recommendedRoute; UnderlyingModelId = $(if ($underlying) { $underlying } else { '' })
            HealthEvidenceReferences = @($orig.EvidenceIds)
            RoutingEvidenceReference = ''; BudgetEvidenceReference = ''; EscalationEvidenceReference = ''
            ReasonCodes = $ReasonCodes
            RetryAfterUtc = $orig.RetryAfterUtc
            RequiresHuman = $ReqHuman; HumanActionType = $HumanType
            PolicyId = Get-ContractProperty $HealthPolicy 'PolicyId' ''
            GeneratedAtUtc = $ts
            Message = $Msg
        }
    }

    # a suppressed known-failure repeat is a hard stop for THIS route
    if ($suppressedRepeat) {
        return New-Dbm22FailDecision -Action 'HUMAN_PROVIDER_CONFIGURATION_REQUIRED' `
            -ReasonCodes @('KNOWN_FAILURE_SUPPRESSED', 'REPEAT_PROHIBITED') -Recommend $null `
            -ReqHuman $true -HumanType 'PROVIDER_CONFIGURATION' `
            -Msg "a known identical provider-failure repeat is suppressed (DB-M21, $suppressOutcome); human provider configuration is required, not a retry"
    }

    # Git / governance / Claude-review gates are NOT provider failures -- if the
    # M20 decision is a human Git gate or a governance/Claude-review stop, we must
    # NOT turn it into a failover. We only read the status; we never route around it.
    if ($null -ne $M20Decision) {
        $m20Status = [string](Get-ContractProperty $M20Decision 'Status' '')
        $m20Action = [string](Get-ContractProperty $M20Decision 'Action' '')
        $gitGates = @('HUMAN_GIT_ACTION_REQUIRED', 'HUMAN_REVIEW_REQUIRED', 'HUMAN_GOVERNANCE_REQUIRED', 'HUMAN_ARCHITECTURE_DECISION_REQUIRED')
        if ($m20Status -like 'HUMAN_*' -or $m20Action -in $gitGates) {
            return New-Dbm22FailDecision -Action 'USE_CURRENT_ROUTE' `
                -ReasonCodes @('HUMAN_GIT_GATE_NOT_PROVIDER_FAILURE') -Recommend $null `
                -ReqHuman $true -HumanType 'GIT' `
                -Msg "a human Git/governance/review gate is pending (M20 $m20Status / $m20Action); this is NOT a provider failure and is never routed around"
        }
        if ($m20Status -notin @('', 'RECOMMENDED')) {
            # any other terminal/human M20 status stops provider-based routing here
            return New-Dbm22FailDecision -Action 'ROUTING_REPLAN_REQUIRED' `
                -ReasonCodes @('GOVERNANCE_BLOCK_NOT_FAILOVER') -Recommend $null `
                -ReqHuman $false -HumanType 'NONE' `
                -Msg "DB-M20 status '$m20Status' is not RECOMMENDED; provider health does not override it (governance block is not a failover)"
        }
    }

    # healthy original route -> use it. UNKNOWN stays with the UNKNOWN branch
    # below so a permissive/low-risk allowance emits UNKNOWN_HEALTH_LOW_RISK_ALLOWED
    # (the health-reason is precise); it is never silently folded into HEALTHY_ROUTE.
    if ($origState -in @('AVAILABLE', 'DEGRADED')) {
        return New-Dbm22FailDecision -Action 'USE_CURRENT_ROUTE' `
            -ReasonCodes @('HEALTHY_ROUTE') -Recommend $null `
            -ReqHuman $false -HumanType 'NONE' `
            -Msg "original route health is $origState; use the current route"
    }

    # DISABLED provider -> never re-enabled, never failed over to itself
    if ($origState -eq 'DISABLED') {
        $altForSame = @($healthyRoutes | Where-Object { (Get-ContractProperty $_ 'ProviderId' '') -eq $OriginalProviderId })
        if ($altForSame.Count -gt 0) {
            return New-Dbm22FailDecision -Action 'SWITCH_ROUTE' `
                -ReasonCodes @('PROVIDER_DISABLED', 'HEALTHY_ALTERNATE_FOUND') -Recommend $altForSame[0] `
                -ReqHuman $false -HumanType 'NONE' `
                -Msg "original route is DISABLED; a healthy alternate route exists"
        }
        return New-Dbm22FailDecision -Action 'STOP_PROVIDER_UNAVAILABLE' `
            -ReasonCodes @('PROVIDER_DISABLED', 'NO_HEALTHY_ALTERNATE') -Recommend $null `
            -ReqHuman $true -HumanType 'PROVIDER_CONFIGURATION' `
            -Msg "original provider is DISABLED and no healthy alternate exists; stop -- never auto re-enable"
    }

    # AUTH_ERROR -> human configuration (or an eligible alternate if it exists)
    if ($origState -eq 'AUTH_ERROR') {
        # never model-escalate on auth failure
        $alternate = $null
        if ($healthyRoutes.Count -gt 0) {
            # budget check on the alternate before recommending execution
            $budgetOk = Test-DbM22AlternateBudget -Candidate $healthyRoutes[0] -BudgetEvaluation $BudgetEvaluation `
                -BudgetPolicy $BudgetPolicy -EligibleCandidates $EligibleCandidates -TaskId $TaskId `
                -AttemptId $AttemptId -Ts $ts -OverrideReference $BudgetOverrideReference -OverrideReason $BudgetOverrideReason
            if ($budgetOk.Ok) {
                $alternate = $healthyRoutes[0]
            }
        }
        if ($null -ne $alternate) {
            return New-Dbm22FailDecision -Action 'SWITCH_ROUTE' `
                -ReasonCodes @('AUTH_REQUIRES_HUMAN', 'HEALTHY_ALTERNATE_FOUND', 'AUTH_NEVER_MODEL_ESCALATES', 'ALTERNATE_BUDGET_OK') `
                -Recommend $alternate -ReqHuman $true -HumanType 'PROVIDER_CONFIGURATION' `
                -Msg "original route has AUTH_ERROR (human config still required); a healthy, budget-ok alternate route exists"
        }
        return New-Dbm22FailDecision -Action 'HUMAN_PROVIDER_CONFIGURATION_REQUIRED' `
            -ReasonCodes @('AUTH_REQUIRES_HUMAN', 'AUTH_NEVER_MODEL_ESCALATES') -Recommend $null `
            -ReqHuman $true -HumanType 'PROVIDER_CONFIGURATION' `
            -Msg "AUTH_ERROR on the original route; human provider configuration is required (never model-escalate on auth failure)"
    }

    # RATE_LIMITED -> honor retry-after; switch if an alternate exists
    if ($origState -eq 'RATE_LIMITED') {
        $retryAfter = ConvertTo-DbM22Utc $orig.RetryAfterUtc
        if ($null -ne $retryAfter -and $retryAfter -gt $ts) {
            if ($healthyRoutes.Count -gt 0) {
                $budgetOk = Test-DbM22AlternateBudget -Candidate $healthyRoutes[0] -BudgetEvaluation $BudgetEvaluation `
                    -BudgetPolicy $BudgetPolicy -EligibleCandidates $EligibleCandidates -TaskId $TaskId `
                    -AttemptId $AttemptId -Ts $ts -OverrideReference $BudgetOverrideReference -OverrideReason $BudgetOverrideReason
                if ($budgetOk.Ok) {
                    return New-Dbm22FailDecision -Action 'SWITCH_ROUTE' `
                        -ReasonCodes @('RETRY_AFTER_PENDING', 'HEALTHY_ALTERNATE_FOUND', 'ALTERNATE_BUDGET_OK') `
                        -Recommend $healthyRoutes[0] -ReqHuman $false -HumanType 'NONE' `
                        -Msg "original route is RATE_LIMITED until $($retryAfter.ToString('o')); a healthy, budget-ok alternate exists"
                }
                return New-Dbm22FailDecision -Action 'ROUTING_REPLAN_REQUIRED' `
                    -ReasonCodes @('RETRY_AFTER_PENDING', 'HEALTHY_ALTERNATE_FOUND', 'ALTERNATE_OVER_BUDGET') `
                    -Recommend $null -ReqHuman $false -HumanType 'NONE' `
                    -Msg "alternate route is over budget (DB-M21); do NOT fail over -- replan"
            }
            return New-Dbm22FailDecision -Action 'WAIT_RETRY_AFTER' `
                -ReasonCodes @('RETRY_AFTER_PENDING', 'NO_HEALTHY_ALTERNATE') -Recommend $null `
                -ReqHuman $false -HumanType 'NONE' `
                -Msg "original route is RATE_LIMITED until $($retryAfter.ToString('o')); no healthy alternate; wait for retry-after"
        }
        # cooldown-limited without retry-after
        if ($healthyRoutes.Count -gt 0) {
            $budgetOk = Test-DbM22AlternateBudget -Candidate $healthyRoutes[0] -BudgetEvaluation $BudgetEvaluation `
                -BudgetPolicy $BudgetPolicy -EligibleCandidates $EligibleCandidates -TaskId $TaskId `
                -AttemptId $AttemptId -Ts $ts -OverrideReference $BudgetOverrideReference -OverrideReason $BudgetOverrideReason
            if ($budgetOk.Ok) {
                return New-Dbm22FailDecision -Action 'SWITCH_ROUTE' `
                    -ReasonCodes @('COOLDOWN_PENDING', 'HEALTHY_ALTERNATE_FOUND', 'ALTERNATE_BUDGET_OK') `
                    -Recommend $healthyRoutes[0] -ReqHuman $false -HumanType 'NONE' `
                    -Msg "original route is RATE_LIMITED (cooldown); a healthy, budget-ok alternate exists"
            }
        }
        return New-Dbm22FailDecision -Action 'WAIT_COOLDOWN' `
            -ReasonCodes @('COOLDOWN_PENDING', 'NO_HEALTHY_ALTERNATE') -Recommend $null `
            -ReqHuman $false -HumanType 'NONE' `
            -Msg "original route is RATE_LIMITED (cooldown); no healthy budget-ok alternate; wait"
    }

    # UNAVAILABLE / DEGRADED -> switch to a healthy alternate or report none
    if ($origState -in @('UNAVAILABLE', 'DEGRADED')) {
        if ($healthyRoutes.Count -gt 0) {
            $budgetOk = Test-DbM22AlternateBudget -Candidate $healthyRoutes[0] -BudgetEvaluation $BudgetEvaluation `
                -BudgetPolicy $BudgetPolicy -EligibleCandidates $EligibleCandidates -TaskId $TaskId `
                -AttemptId $AttemptId -Ts $ts -OverrideReference $BudgetOverrideReference -OverrideReason $BudgetOverrideReason
            if ($budgetOk.Ok) {
                return New-Dbm22FailDecision -Action 'SWITCH_ROUTE' `
                    -ReasonCodes @('ROUTE_UNHEALTHY', 'HEALTHY_ALTERNATE_FOUND', 'ALTERNATE_BUDGET_OK') `
                    -Recommend $healthyRoutes[0] -ReqHuman $false -HumanType 'NONE' `
                    -Msg "original route is $origState; a healthy, budget-ok alternate route exists"
            }
            return New-Dbm22FailDecision -Action 'ROUTING_REPLAN_REQUIRED' `
                -ReasonCodes @('ROUTE_UNHEALTHY', 'HEALTHY_ALTERNATE_FOUND', 'ALTERNATE_OVER_BUDGET') `
                -Recommend $null -ReqHuman $false -HumanType 'NONE' `
                -Msg "original route is $origState but the alternate is over budget (DB-M21); do NOT fail over -- replan"
        }
        # A circuit-OPEN original means DB-M22 (or the caller) has already counted
        # enough recent failures to open the breaker; with no healthy alternate the
        # only correct move is to wait out the cooldown -- the design doc's step 8
        # "Circuit OPEN before cooldown -> WAIT_COOLDOWN". Declaring NO_HEALTHY_ROUTE
        # would make the router feel obligated to retry the tripped route.
        if ($orig.CircuitState -eq 'OPEN') {
            return New-Dbm22FailDecision -Action 'WAIT_COOLDOWN' `
                -ReasonCodes @('COOLDOWN_PENDING', 'CIRCUIT_OPEN', 'NO_HEALTHY_ALTERNATE') -Recommend $null `
                -ReqHuman $false -HumanType 'NONE' `
                -Msg "original route circuit is OPEN (breaker tripped) and no healthy eligible alternate exists; wait for the cooldown"
        }
        return New-Dbm22FailDecision -Action 'NO_HEALTHY_ROUTE' `
            -ReasonCodes @('ROUTE_UNHEALTHY', 'NO_HEALTHY_ALTERNATE') -Recommend $null `
            -ReqHuman $false -HumanType 'NONE' `
            -Msg "original route is $origState and no healthy eligible alternate exists"
    }

    # UNKNOWN health -> policy decides
    if ($origState -eq 'UNKNOWN') {
        if ([bool]$orig.UnknownUsable) {
            return New-Dbm22FailDecision -Action 'USE_CURRENT_ROUTE' `
                -ReasonCodes @('UNKNOWN_HEALTH_LOW_RISK_ALLOWED') -Recommend $null `
                -ReqHuman $false -HumanType 'NONE' `
                -Msg "original health is UNKNOWN but usable under this policy (low-risk/manual); use the current route"
        }
        if ($healthyRoutes.Count -gt 0) {
            $budgetOk = Test-DbM22AlternateBudget -Candidate $healthyRoutes[0] -BudgetEvaluation $BudgetEvaluation `
                -BudgetPolicy $BudgetPolicy -EligibleCandidates $EligibleCandidates -TaskId $TaskId `
                -AttemptId $AttemptId -Ts $ts -OverrideReference $BudgetOverrideReference -OverrideReason $BudgetOverrideReason
            if ($budgetOk.Ok) {
                return New-Dbm22FailDecision -Action 'SWITCH_ROUTE' `
                    -ReasonCodes @('UNKNOWN_HEALTH_HIGH_RISK_DENIED', 'HEALTHY_ALTERNATE_FOUND', 'ALTERNATE_BUDGET_OK') `
                    -Recommend $healthyRoutes[0] -ReqHuman $false -HumanType 'NONE' `
                    -Msg "original health is UNKNOWN (not usable for high-risk); a healthy alternate exists"
            }
            return New-Dbm22FailDecision -Action 'ROUTING_REPLAN_REQUIRED' `
                -ReasonCodes @('UNKNOWN_HEALTH_HIGH_RISK_DENIED', 'HEALTHY_ALTERNATE_FOUND', 'ALTERNATE_OVER_BUDGET') `
                -Recommend $null -ReqHuman $false -HumanType 'NONE' `
                -Msg "original health is UNKNOWN; the alternate is over budget (DB-M21); do NOT fail over -- replan"
        }
        return New-Dbm22FailDecision -Action 'HUMAN_PROVIDER_DECISION_REQUIRED' `
            -ReasonCodes @('UNKNOWN_HEALTH_HIGH_RISK_DENIED', 'NO_HEALTHY_ALTERNATE') -Recommend $null `
            -ReqHuman $true -HumanType 'PROVIDER_DECISION' `
            -Msg "original health is UNKNOWN and not usable; no healthy eligible alternate; a human provider decision is required"
    }

    # fallback (should be unreachable): report the route as unhealthy with no action
    return New-Dbm22FailDecision -Action 'ROUTING_REPLAN_REQUIRED' `
        -ReasonCodes @('ROUTE_UNHEALTHY', 'HEALTH_UNKNOWN') -Recommend $null `
        -ReqHuman $false -HumanType 'NONE' `
        -Msg "original route health $origState is not usable; replan"
}

function Test-DbM22AlternateBudget {
    <#
    .SYNOPSIS
    Consult DB-M21 Test-AiBudget for an alternate route that would incur an AI
    call. Returns @{ Ok; Decision; ReasonCodes }.
    #>
    param(
        [AllowNull()][object]$Candidate,
        [AllowNull()][object]$BudgetEvaluation,
        [AllowNull()][object]$BudgetPolicy,
        [AllowNull()][object[]]$EligibleCandidates,
        [string]$TaskId,
        [string]$AttemptId,
        $Ts,
        [string]$OverrideReference,
        [string]$OverrideReason
    )
    if ($null -eq $BudgetPolicy) {
        # no budget policy configured -> budget is not a constraint here
        return @{ Ok = $true; Decision = $null; ReasonCodes = @() }
    }
    if ($null -eq $Candidate) { return @{ Ok = $false; Decision = $null; ReasonCodes = @('NO_HEALTHY_ALTERNATE') } }

    $proposedCost = Get-ContractProperty $Candidate 'EstimatedCost' $null
    $proposedCurrency = Get-ContractProperty $Candidate 'CostCurrency' $null
    $proposedUnknown = [bool](Get-ContractProperty $Candidate 'CostUnknown' $false)
    $eval = Test-AiBudget -Policy $BudgetPolicy -EvaluationTimestampUtc $Ts `
        -Attempts @() -TaskId $TaskId `
        -ProposedAttemptCost $proposedCost -ProposedCostCurrency $proposedCurrency `
        -ProposedCostUnknown $proposedUnknown
    $dec = [string](Get-ContractProperty $eval 'Decision' '')
    if ($dec -in @('BLOCK_BUDGET_EXCEEDED', 'BLOCK_COST_UNKNOWN')) {
        return @{ Ok = $false; Decision = $eval; ReasonCodes = @('ALTERNATE_OVER_BUDGET') }
    }
    if ($dec -eq 'REQUIRE_HUMAN_OVERRIDE') {
        # an explicit budget override may proceed
        if ($OverrideReference -and $OverrideReason) {
            return @{ Ok = $true; Decision = $eval; ReasonCodes = @('BUDGET_REQUIRES_OVERRIDE', 'HUMAN_OVERRIDE_GRANTED') }
        }
        return @{ Ok = $false; Decision = $eval; ReasonCodes = @('BUDGET_REQUIRES_OVERRIDE') }
    }
    return @{ Ok = $true; Decision = $eval; ReasonCodes = @('ALTERNATE_BUDGET_OK') }
}

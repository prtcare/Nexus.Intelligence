# Router.ps1 -- DB-M19 capability-based model router (orchestrator + request/decision).
#
# DB-M19 SELECTS / RECOMMENDS a model and NEVER executes it. No provider API call,
# no automatic DeepSeek/Claude/ChatGPT invocation, no automatic workflow advance.
# Execution modes:
#   MANUAL   -- the router displays eligible choices; it never overrides the human
#              selection (manual override is the only path and it must still pass
#              the hard constraints).
#   ASSISTED -- the router produces a policy-driven recommendation (model, minimum
#              reasoning level, estimated cost, reason, evidence) and never runs it.
#   AUTO     -- PROHIBITED (refused with AUTO_EXECUTION_PROHIBITED).
#
# Pipeline (all deterministic, zero network, zero paid calls):
#   STEP 1  hard capability/provider/price eligibility (Get-EligibleAiModels)
#   STEP 2  context fit (mandatory + output/reasoning reserve)
#   STEP 3  cost estimation via the DB-M16 engine (Get-AiCandidateCostEstimate)
#   STEP 4  historical performance evidence via DB-M24 (Get-AiCandidatePerformanceEvidence)
#   STEP 5  policy-weighted ranking (Rank-AiRoutingCandidates)
#   =>      DB-M14 RoutingDecision v1 + DB-M19 RoutingDecisionEvidence v1
#
# ADR-005: no provider/model NAME branching anywhere in the router.

. (Join-Path $PSScriptRoot "..\AiRoutingCostFoundation.ps1")     # DB-M14 + DB-M15 + DB-M16 (read-only)
. (Join-Path $PSScriptRoot "..\performance\AiPerformanceFoundation.ps1")  # DB-M17 + DB-M24 (read-only)
. (Join-Path $PSScriptRoot "RoutingPolicy.ps1")
. (Join-Path $PSScriptRoot "RoutingCandidate.ps1")
. (Join-Path $PSScriptRoot "RoutingEligibility.ps1")
. (Join-Path $PSScriptRoot "RoutingCost.ps1")
. (Join-Path $PSScriptRoot "RoutingPerformance.ps1")
. (Join-Path $PSScriptRoot "RoutingRank.ps1")

# -----------------------------------------------------------------------------
# Schema registry (DB-M19-owned)
# -----------------------------------------------------------------------------
function Get-DbM19SchemaVersions {
    return [pscustomobject]@{
        RoutingPolicyVersion         = 1
        RoutingCandidateVersion      = 1
        RoutingDecisionEvidenceVersion = 1
        RoutingRequestVersion        = 1
        RoutingDecision              = 'DB-M14 v1 (unchanged)'
    }
}

# -----------------------------------------------------------------------------
# RoutingRequest v1
# -----------------------------------------------------------------------------
function New-RoutingRequest {
    <#
    .SYNOPSIS
    Build a RoutingRequest v1. The requirement is a DB-M14 CapabilityRequirement v1
    (from DB-M18 New-CapabilityRequirement or DB-M14 New-AiCapabilityRequirement);
    classification/context-budget/context-package are the DB-M18 inputs. Unknown
    values stay null -- the router never invents a missing classification value.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$RoutingRequestId,
        [string]$TaskId,
        [string]$NodeId,
        [string]$ChangeId,
        [AllowNull()][object]$Requirement,
        [AllowNull()][object]$Classification,
        [AllowNull()][object]$ContextBudget,
        [AllowNull()][object]$ContextPackage,
        [Nullable[double]]$MaxAllowedCost,
        [string]$ProcessingTier = 'STANDARD',
        [string]$TimeBand,
        [AllowNull()]$RequestTimestampUtc,
        [double]$CachedInputFraction = 0.0,
        [string]$TargetCurrency = 'INR',
        [AllowNull()][Nullable[decimal]]$ExchangeRate,
        [string]$ExecutionMode = 'MANUAL',
        [AllowNull()][object]$ManualOverrideRequest,
        [string]$Notes
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }
    $routingRequestId = if ($InputObject) { & $g 'RoutingRequestId' $RoutingRequestId } else { $RoutingRequestId }
    $taskId = if ($InputObject) { & $g 'TaskId' $TaskId } else { $TaskId }
    if (-not $routingRequestId) { $routingRequestId = "RREQ-$taskId" }
    return [pscustomobject]@{
        SchemaVersion       = 1
        RoutingRequestId    = $routingRequestId
        TaskId              = if ($InputObject) { & $g 'TaskId' $TaskId } else { $TaskId }
        NodeId              = if ($InputObject) { & $g 'NodeId' $NodeId } else { $NodeId }
        ChangeId            = if ($InputObject) { & $g 'ChangeId' $ChangeId } else { $ChangeId }
        Requirement         = if ($InputObject) { & $g 'Requirement' $Requirement } else { $Requirement }
        Classification      = if ($InputObject) { & $g 'Classification' $Classification } else { $Classification }
        ContextBudget       = if ($InputObject) { & $g 'ContextBudget' $ContextBudget } else { $ContextBudget }
        ContextPackage      = if ($InputObject) { & $g 'ContextPackage' $ContextPackage } else { $ContextPackage }
        MaxAllowedCost      = if ($InputObject) { & $g 'MaxAllowedCost' $MaxAllowedCost } else { $MaxAllowedCost }
        ProcessingTier      = if ($InputObject) { & $g 'ProcessingTier' $ProcessingTier } else { $ProcessingTier }
        TimeBand            = if ($InputObject) { & $g 'TimeBand' $TimeBand } else { $TimeBand }
        RequestTimestampUtc = if ($InputObject) { & $g 'RequestTimestampUtc' $RequestTimestampUtc } else { $RequestTimestampUtc }
        CachedInputFraction = if ($InputObject) { & $g 'CachedInputFraction' $CachedInputFraction } else { $CachedInputFraction }
        TargetCurrency      = if ($InputObject) { & $g 'TargetCurrency' $TargetCurrency } else { $TargetCurrency }
        ExchangeRate        = if ($InputObject) { & $g 'ExchangeRate' $ExchangeRate } else { $ExchangeRate }
        ExecutionMode       = if ($InputObject) { & $g 'ExecutionMode' $ExecutionMode } else { $ExecutionMode }
        ManualOverrideRequest = if ($InputObject) { & $g 'ManualOverrideRequest' $ManualOverrideRequest } else { $ManualOverrideRequest }
        Notes               = if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }
    }
}

function Test-RoutingRequest {
    <#
    .SYNOPSIS
    Deterministic validation of a RoutingRequest v1. Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Request)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Request) { return @{ Valid = $false; Errors = @('Request is null'); Warnings = @() } }
    if ((Get-ContractProperty $Request 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Request 'TaskId' '')) { $errors.Add('TaskId is required') }
    $requirement = Get-ContractProperty $Request 'Requirement' $null
    if ($null -eq $requirement) { $errors.Add('Requirement is required (DB-M14 CapabilityRequirement v1)') }
    else {
        $rv = Test-AiCapabilityRequirement $requirement
        foreach ($e in @($rv.Errors)) { $errors.Add("Requirement: $e") }
    }
    $execMode = [string](Get-ContractProperty $Request 'ExecutionMode' 'MANUAL')
    if (-not (Test-IsValidExecutionMode $execMode)) { $errors.Add("ExecutionMode '$execMode' invalid") }
    $tier = [string](Get-ContractProperty $Request 'ProcessingTier' 'STANDARD')
    if ($tier -and -not (Test-IsValidProcessingTier $tier)) { $errors.Add("ProcessingTier '$tier' invalid") }
    $band = Get-ContractProperty $Request 'TimeBand' $null
    if ($band -and -not (Test-IsValidTimeBand $band)) { $errors.Add("TimeBand '$band' invalid") }
    $fraction = Get-ContractProperty $Request 'CachedInputFraction' 0.0
    if ($fraction -lt 0 -or $fraction -gt 1) { $errors.Add("CachedInputFraction must be within 0..1 (found $fraction)") }
    $currency = [string](Get-ContractProperty $Request 'TargetCurrency' 'INR')
    if ($currency -and $currency -notmatch '^[A-Z]{3}$') { $errors.Add("TargetCurrency '$currency' must be ISO-4217") }
    $maxAllowed = Get-ContractProperty $Request 'MaxAllowedCost' $null
    if ($null -ne $maxAllowed -and $maxAllowed -lt 0) { $errors.Add('MaxAllowedCost must be >= 0') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @($warnings.ToArray()) }
}

# -----------------------------------------------------------------------------
# Manual override gate
# -----------------------------------------------------------------------------
function Test-AiManualOverride {
    <#
    .SYNOPSIS
    Validate a human override request against the eligible candidates and the hard
    constraints. An override is accepted ONLY when the requested route is eligible
    (already passes the STEP-1 hard constraints) and the requested reasoning level
    is supported by the requested model and satisfies the requirement. Rejected
    overrides return Accepted=$false with an explanation (the recommendation then
    proceeds with the recommended model).
    #>
    param(
        [AllowNull()][object]$OverrideRequest,
        [AllowNull()][object[]]$EligibleCandidates,
        [AllowNull()][pscustomobject]$Requirement,
        [AllowNull()][pscustomobject]$Policy,
        [AllowNull()][object]$Recommended
    )
    $reqProvider = Get-ContractProperty $OverrideRequest 'RequestedProviderId' $null
    $reqModel = Get-ContractProperty $OverrideRequest 'RequestedModelId' $null
    $reqReasoning = Get-ContractProperty $OverrideRequest 'RequestedReasoningLevel' $null
    $reason = Get-ContractProperty $OverrideRequest 'Reason' $null

    $result = @{
        Valid = $false
        Accepted = $false
        Reason = $null
        Requested = [pscustomobject]@{ RequestedProviderId = $reqProvider; RequestedModelId = $reqModel; RequestedReasoningLevel = $reqReasoning; Reason = $reason }
        Recommended = $Recommended
        MatchedCandidate = $null
    }
    if ($null -eq $OverrideRequest) { $result.Reason = 'no override request present'; return $result }
    if (-not $reqProvider -or -not $reqModel) {
        $result.Reason = 'override requires both RequestedProviderId and RequestedModelId'
        return $result
    }
    if ($reqReasoning -and -not (Test-IsValidReasoningLevel $reqReasoning)) {
        $result.Reason = "requested reasoning level '$reqReasoning' is not a valid ReasoningLevels member"
        return $result
    }

    # the requested route must be one of the eligible candidates (hard constraints already applied)
    $matched = $null
    foreach ($candidate in @($EligibleCandidates)) {
        if ($candidate.ProviderId -eq $reqProvider -and $candidate.ModelId -eq $reqModel) { $matched = $candidate; break }
    }
    if ($null -eq $matched) {
        $result.Reason = "requested route '$reqProvider/$reqModel' is not among the eligible candidates (it failed the hard constraints or was excluded); override rejected"
        return $result
    }

    # requested reasoning level must satisfy the requirement and be supported by the model
    if ($reqReasoning) {
        $minReasoning = Get-ContractProperty $Requirement 'MinimumReasoningLevel' $null
        if ($minReasoning) {
            $order = Get-AiRoutingReasoningOrder
            if ([int]$order[$reqReasoning] -lt [int]$order[$minReasoning]) {
                $result.Reason = "requested reasoning level '$reqReasoning' is below the requirement MinimumReasoningLevel '$minReasoning'"
                return $result
            }
        }
        $supported = @(Get-DbM19ArrayValue $matched 'ReasoningLevelsSupported')
        if ($supported.Count -gt 0 -and $reqReasoning -notin $supported) {
            $result.Reason = "requested reasoning level '$reqReasoning' is not supported by '$reqModel' (supports: $($supported -join '/'))"
            return $result
        }
    }

    $result.Valid = $true
    $result.Accepted = $true
    $result.Reason = if ($reason) { $reason } else { 'human override accepted (manual workflow)' }
    $result.MatchedCandidate = $matched
    return $result
}

# -----------------------------------------------------------------------------
# Recommendation orchestrator
# -----------------------------------------------------------------------------
function Get-AiRoutingRecommendation {
    <#
    .SYNOPSIS
    The DB-M19 orchestrator. Chains STEP 1 (eligibility) -> STEP 2 (context fit) ->
    STEP 3 (cost via DB-M16) -> STEP 4 (performance evidence via DB-M24) ->
    STEP 5 (policy ranking) and returns a recommendation plus the DB-M14 RoutingDecision
    v1 and the DB-M19 RoutingDecisionEvidence v1. AUTO execution mode is refused.
    Never executes a provider or model.
    #>
    param(
        [AllowNull()][pscustomobject]$Request,
        [AllowNull()][object]$Configuration,
        [AllowNull()][System.Collections.IDictionary]$ProviderHealth,
        [AllowNull()][object[]]$PerformanceRecords,
        [AllowNull()][pscustomobject]$Policy
    )
    if ($null -eq $Request) { throw 'Get-AiRoutingRecommendation: Request is required' }
    $reqV = Test-RoutingRequest $Request
    if (-not $reqV.Valid) { throw "Get-AiRoutingRecommendation: invalid routing request: $($reqV.Errors -join '; ')" }

    $policy = $Policy
    if ($null -eq $policy) { $policy = Get-DefaultRoutingPolicy }
    $polV = Test-RoutingPolicy $policy
    if (-not $polV.Valid) { throw "Get-AiRoutingRecommendation: invalid routing policy: $($polV.Errors -join '; ')" }
    if ($policy.Enabled -ne $true) { throw "Get-AiRoutingRecommendation: routing policy '$($policy.PolicyId)' is disabled" }

    $configuration = $Configuration
    if ($null -eq $configuration) {
        $root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $configuration = Import-AiCostConfiguration -Root $root
    }

    $requirement = Get-ContractProperty $Request 'Requirement' $null
    $taskId = [string](Get-ContractProperty $Request 'TaskId' '')
    $routingRequestId = [string](Get-ContractProperty $Request 'RoutingRequestId' "RREQ-$taskId")
    $execMode = [string](Get-ContractProperty $Request 'ExecutionMode' 'MANUAL')
    $processingTier = [string](Get-ContractProperty $Request 'ProcessingTier' 'STANDARD')
    $timeBand = Get-ContractProperty $Request 'TimeBand' $null
    $cachedFraction = [double](Get-ContractProperty $Request 'CachedInputFraction' 0.0)
    $targetCurrency = [string](Get-ContractProperty $Request 'TargetCurrency' 'INR')
    $exchangeRate = Get-ContractProperty $Request 'ExchangeRate' $null
    $maxAllowedCost = Get-ContractProperty $Request 'MaxAllowedCost' $null
    $contextBudget = Get-ContractProperty $Request 'ContextBudget' $null
    $contextPackage = Get-ContractProperty $Request 'ContextPackage' $null
    $classification = Get-ContractProperty $Request 'Classification' $null
    $requestTs = Get-ContractProperty $Request 'RequestTimestampUtc' $null
    if ($null -eq $requestTs) { $requestTs = [datetime]::UtcNow }
    $requestTs = ConvertTo-AiUtc $requestTs

    # --- Work Universe (role-scope) carried on the DB-M18 inputs, echoed additively --
    # Lane G: the routing evidence echoes the Work Universe the caller attached to the
    # Classification/ContextPackage. Foundation is the Forge default; Products is a
    # recognized cross-scope role. This is an additive echo -- the router never
    # re-derives or guesses a scope from a bare id (SP1-M14: bare ids are never an
    # address; identical ids may exist in both roles).
    $workUniverse = Get-ContractProperty $classification 'WorkUniverse' $null
    if (-not $workUniverse) { $workUniverse = Get-ContractProperty $contextPackage 'WorkUniverse' $null }
    if (-not $workUniverse) { $workUniverse = 'Foundation' }
    $evidenceNodeAddress = Get-ContractProperty $classification 'NodeAddress' $null
    if (-not $evidenceNodeAddress) { $evidenceNodeAddress = Get-ContractProperty $contextPackage 'NodeAddress' $null }

    $noWinner = [pscustomobject]@{ ProviderId = $null; ModelId = $null; ReasoningLevel = $null }

    # --- AUTO prohibited --------------------------------------------------------
    if ($execMode -eq 'AUTO') {
        $decision = New-AiRoutingDecision -RoutingRequestId $routingRequestId -TaskId $taskId `
            -PolicyVersion '1.0.0' -ManualOverride $false `
            -RoutingReason 'AUTO execution mode is prohibited by DB-M19; routing is MANUAL/ASSISTED only' `
            -DecisionTimestamp ($requestTs.ToString('o'))
        $evidence = New-RoutingDecisionEvidence @{
            RoutingRequestId = $routingRequestId; TaskId = $taskId; Status = 'AUTO_EXECUTION_PROHIBITED'
            Policy = $policy.PolicyId; RecommendationReason = 'AUTO execution mode is prohibited by DB-M19'
            DecisionTimestampUtc = $requestTs.ToString('o'); Mode = $execMode
            TargetCurrency = $targetCurrency; ProcessingTier = $processingTier; TimeBand = $timeBand
            WorkUniverse = $workUniverse; NodeAddress = $evidenceNodeAddress
            Notes = 'DB-M19 refuses to auto-execute; no model is selected or invoked.'
        }
        return @{
            Status = 'AUTO_EXECUTION_PROHIBITED'
            Policy = $policy
            ExecutionMode = $execMode
            Winner = $null
            WinnerEligible = $false
            EligibleCandidates = @()
            RejectedCandidates = @()
            Decision = $decision
            Evidence = $evidence
            RecommendationReason = 'AUTO execution mode is prohibited by DB-M19 (MANUAL/ASSISTED only)'
            ContextPackageId = $null
            ContextPackageHash = $null
            PricingRecordId = $null
            PerformanceEvidenceReference = $null
        }
    }

    # --- STEP 1: eligible model set ----------------------------------------------
    $step1 = Get-EligibleAiModels -Catalogue $configuration.Models -Providers $configuration.Providers `
        -Requirement $requirement -Pricing $configuration.Pricing -ProviderHealth $ProviderHealth `
        -Policy $policy -ProcessingTier $processingTier -TimestampUtc $requestTs

    $rejected = New-Object System.Collections.Generic.List[object]
    foreach ($row in @($step1.Rejected)) {
        $null = $rejected.Add((New-RoutingCandidate @{
            Status = 'REJECTED'; ProviderId = $row.ProviderId; ModelId = $row.ModelId
            GatewayProviderId = $row.GatewayProviderId; UnderlyingModelId = $row.UnderlyingModelId
            RejectionReasons = @($row.RejectionReasons)
        }))
    }
    $stageEliminated = New-Object System.Collections.Generic.List[string]

    if ($step1.EligibleCount -eq 0) {
        # classify: when EVERY rejected route was eliminated for context fit
        # alone (mandatory context exceeds every window -- STEP-1 raw window or
        # STEP-2 usable-context reserve), report the context-specific outcome.
        # OUTPUT_LIMIT_TOO_SMALL is a distinct STEP-1 hard gate, so an
        # output-only elimination keeps the generic NO_ELIGIBLE_MODEL status.
        $status = 'NO_ELIGIBLE_MODEL'
        $firstReasons = @($rejected | ForEach-Object {
            $reasons = @(Get-ContractProperty $_ 'RejectionReasons' @())
            if ($reasons.Count -gt 0) { $reasons[0].Reason }
        })
        $distinctReasons = @($firstReasons | Select-Object -Unique)
        if ($distinctReasons.Count -gt 0) {
            $contextOnly = $true
            foreach ($reason in $distinctReasons) {
                if ($reason -ne 'CONTEXT_TOO_SMALL') { $contextOnly = $false; break }
            }
            if ($contextOnly) { $status = 'NO_ELIGIBLE_MODEL_CONTEXT' }
        }
        return New-DbM19RecommendationResult -Request $Request -Policy $policy -ExecMode $execMode `
            -TaskId $taskId -RoutingRequestId $routingRequestId -RequestTs $requestTs `
            -Status $status `
            -Eligible @() -Rejected $rejected -Requirement $requirement -MaxAllowedCost $maxAllowedCost `
            -TargetCurrency $targetCurrency -ProcessingTier $processingTier -TimeBand $timeBand `
            -ContextBudget $contextBudget -ContextPackage $contextPackage
    }

    # --- STEP 2 + 3 + 4 per eligible model -----------------------------------------
    $eligible = New-Object System.Collections.Generic.List[object]
    foreach ($model in @($step1.Eligible)) {
        $providerId = Get-ContractProperty $model 'ProviderId' ''
        $providerObj = $null
        $provKey = $providerId.Trim().ToLowerInvariant()
        if ($null -ne $configuration.Providers -and $configuration.Providers.Contains($provKey)) {
            $providerObj = $configuration.Providers[$provKey]
        }
        $fit = Test-AiModelCapabilityFit -Model $model -Provider $providerObj -Requirement $requirement `
            -Pricing $configuration.Pricing -ProviderHealth $ProviderHealth -Policy $policy `
            -ProcessingTier $processingTier -TimestampUtc $requestTs

        $contextFit = Test-AiRoutingContextFit -Model $model -Requirement $requirement `
            -ContextBudget $contextBudget -ContextPackage $contextPackage -Policy $policy
        if (-not $contextFit.Fits) {
            $stageEliminated.Add('CONTEXT')
            $null = $rejected.Add((New-RoutingCandidate @{
                Status = 'REJECTED'; ProviderId = $providerId; ModelId = (Get-ContractProperty $model 'ModelId' '')
                GatewayProviderId = (Get-ContractProperty $model 'GatewayProviderId' $null)
                UnderlyingModelId = (Get-ContractProperty $model 'UnderlyingModelId' $null)
                SelectedReasoningLevel = $fit.SelectedReasoningLevel
                RejectionReasons = @([pscustomobject]@{ Reason = 'CONTEXT_TOO_SMALL'; Detail = $contextFit.Detail })
            }))
            continue
        }

        $cost = Get-AiCandidateCostEstimate -Model $model -Requirement $requirement -Configuration $configuration `
            -ContextBudget $contextBudget -ContextPackage $contextPackage -RequestTimestampUtc $requestTs `
            -ProcessingTier $processingTier -TimeBand $timeBand -CachedInputFraction $cachedFraction `
            -TargetCurrency $targetCurrency -ExchangeRate $exchangeRate

        $budgetExceeded = $false
        if ($null -ne $maxAllowedCost -and -not $cost.CostUnknown -and $null -ne $cost.EstimatedCost) {
            if ([double]$cost.EstimatedCost -gt [double]$maxAllowedCost) { $budgetExceeded = $true }
        }
        if ($budgetExceeded) {
            $stageEliminated.Add('BUDGET')
            $null = $rejected.Add((New-RoutingCandidate @{
                Status = 'REJECTED'; ProviderId = $providerId; ModelId = (Get-ContractProperty $model 'ModelId' '')
                GatewayProviderId = (Get-ContractProperty $model 'GatewayProviderId' $null)
                UnderlyingModelId = (Get-ContractProperty $model 'UnderlyingModelId' $null)
                SelectedReasoningLevel = $fit.SelectedReasoningLevel
                CostEstimate = $cost
                RejectionReasons = @([pscustomobject]@{ Reason = 'BUDGET_EXCEEDED'; Detail = "estimated cost $($cost.EstimatedCost) $($cost.CostCurrency) exceeds request MaxAllowedCost $maxAllowedCost $targetCurrency" })
            }))
            continue
        }

        $allowUnknown = $true
        $thresholds = Get-ContractProperty $policy 'Thresholds' $null
        if ($null -ne $thresholds) { $allowUnknown = [bool](Get-ContractProperty $thresholds 'allowCostUnknown' $true) }
        if ($cost.CostUnknown -and -not $allowUnknown) {
            $stageEliminated.Add('PRICE')
            $null = $rejected.Add((New-RoutingCandidate @{
                Status = 'REJECTED'; ProviderId = $providerId; ModelId = (Get-ContractProperty $model 'ModelId' '')
                GatewayProviderId = (Get-ContractProperty $model 'GatewayProviderId' $null)
                UnderlyingModelId = (Get-ContractProperty $model 'UnderlyingModelId' $null)
                SelectedReasoningLevel = $fit.SelectedReasoningLevel
                CostEstimate = $cost
                RejectionReasons = @([pscustomobject]@{ Reason = 'PRICE_UNAVAILABLE'; Detail = $cost.Message })
            }))
            continue
        }

        $perf = Get-AiCandidatePerformanceEvidence -Model $model -Requirement $requirement `
            -Classification $classification -PerformanceRecords $PerformanceRecords `
            -ReasoningLevel $fit.SelectedReasoningLevel `
            -MinimumConfidenceForHistoricalWeight $policy.MinimumConfidenceForHistoricalWeight `
            -ReportingCurrency $targetCurrency

        $null = $eligible.Add((New-RoutingCandidate @{
            Status = 'ELIGIBLE'
            ProviderId = $providerId
            ModelId = (Get-ContractProperty $model 'ModelId' '')
            UnderlyingModelId = (Get-ContractProperty $model 'UnderlyingModelId' $null)
            GatewayProviderId = (Get-ContractProperty $model 'GatewayProviderId' $null)
            DisplayName = (Get-ContractProperty $model 'DisplayName' $null)
            LocalOrRemote = (Get-ContractProperty $model 'LocalOrRemote' $null)
            RelativeSpeed = (Get-ContractProperty $model 'RelativeSpeed' $null)
            ReliabilityClass = (Get-ContractProperty $model 'ReliabilityClass' $null)
            ReasoningLevelsSupported = @(Get-DbM19ArrayValue $model 'ReasoningLevelsSupported')
            ContextWindow = (Get-ContractProperty $model 'ContextWindow' $null)
            MaxOutputTokens = (Get-ContractProperty $model 'MaxOutputTokens' $null)
            SelectedReasoningLevel = $fit.SelectedReasoningLevel
            ContextFit = $contextFit
            CostEstimate = $cost
            EstimatedCost = $cost.EstimatedCost
            CostCurrency = $cost.CostCurrency
            CostUnknown = $cost.CostUnknown
            PricingRecordId = $cost.PricingRecordId
            PerformanceEvidence = $perf
            PerformanceEvidenceReference = $perf.PerformanceEvidenceReference
        }))
    }

    if ($eligible.Count -eq 0) {
        $status = 'NO_ELIGIBLE_MODEL'
        if ($stageEliminated.Count -gt 0) {
            $distinct = @($stageEliminated | Select-Object -Unique)
            if ($distinct.Count -eq 1) {
                switch ($distinct[0]) {
                    'CONTEXT' { $status = 'NO_ELIGIBLE_MODEL_CONTEXT' }
                    'BUDGET'  { $status = 'NO_ELIGIBLE_MODEL_BUDGET' }
                    'PRICE'   { $status = 'NO_ELIGIBLE_MODEL_PRICE' }
                }
            }
        }
        return New-DbM19RecommendationResult -Request $Request -Policy $policy -ExecMode $execMode `
            -TaskId $taskId -RoutingRequestId $routingRequestId -RequestTs $requestTs `
            -Status $status `
            -Eligible @() -Rejected $rejected -Requirement $requirement -MaxAllowedCost $maxAllowedCost `
            -TargetCurrency $targetCurrency -ProcessingTier $processingTier -TimeBand $timeBand `
            -ContextBudget $contextBudget -ContextPackage $contextPackage
    }

    # --- STEP 5: ranking ----------------------------------------------------------
    $rank = Rank-AiRoutingCandidates -Candidates $eligible.ToArray() -Policy $policy

    # --- mode / status -------------------------------------------------------------
    $manualPolicy = ($policy.Objective -eq 'MANUAL')
    $winner = $rank.Winner
    if ($execMode -eq 'MANUAL' -or $manualPolicy) { $winner = $null }
    $status = if ($execMode -eq 'MANUAL') { 'MANUAL_MODE' }
             elseif ($manualPolicy) { 'MANUAL_POLICY' }
             elseif ($null -ne $winner) { 'RECOMMENDED' }
             else { 'NO_WINNER' }

    # --- manual override -------------------------------------------------------------
    $override = $null
    $overrideRequest = Get-ContractProperty $Request 'ManualOverrideRequest' $null
    if ($null -ne $overrideRequest) {
        $override = Test-AiManualOverride -OverrideRequest $overrideRequest -EligibleCandidates $eligible.ToArray() `
            -Requirement $requirement -Policy $policy -Recommended $winner
        if ($override.Accepted -eq $true) { $winner = $override.MatchedCandidate }
    }

    # --- recommendation reason --------------------------------------------------------
    $recommendationReason = New-DbM19RecommendationReason -Status $status -Policy $policy `
        -Winner $winner -Rank $rank -Eligible $eligible.ToArray() -Rejected $rejected.ToArray() `
        -ExecMode $execMode -Override $override -TargetCurrency $targetCurrency

    $estimatedContext = $null
    $estimatedOutput = $null
    if ($null -ne $winner) {
        $ctx = Get-ContractProperty $winner 'ContextFit' $null
        if ($null -ne $ctx) { $estimatedContext = $ctx.MandatoryContextTokens }
        $costEst = Get-ContractProperty $winner 'CostEstimate' $null
        if ($null -ne $costEst) { $estimatedOutput = $costEst.OutputTokens }
    }

    $manualOverride = ($null -ne $override -and $override.Accepted -eq $true)
    $selectedProvider = $null; $selectedModel = $null; $selectedUnderlying = $null; $selectedGateway = $null
    $selectedReasoning = $null; $estimatedCost = $null
    if ($null -ne $winner) {
        $selectedProvider = $winner.ProviderId
        $selectedModel = $winner.ModelId
        $selectedUnderlying = $winner.UnderlyingModelId
        $selectedGateway = $winner.GatewayProviderId
        $selectedReasoning = $winner.SelectedReasoningLevel
        $estimatedCost = $winner.EstimatedCost
    }

    $decision = New-AiRoutingDecision -RoutingRequestId $routingRequestId -TaskId $taskId `
        -SelectedProviderId $selectedProvider -SelectedModelId $selectedModel `
        -UnderlyingModelId $selectedUnderlying -GatewayProviderId $selectedGateway `
        -ReasoningLevel $selectedReasoning `
        -EligibleCandidateIds @($eligible | ForEach-Object { $_.ModelId }) `
        -RejectedCandidateIds @($rejected | ForEach-Object { $_.ModelId }) `
        -RoutingReason $recommendationReason `
        -EstimatedContextTokens $estimatedContext -EstimatedOutputTokens $estimatedOutput `
        -EstimatedCost $estimatedCost -PolicyVersion '1.0.0' -ManualOverride $manualOverride `
        -DecisionTimestamp ($requestTs.ToString('o'))

    $overrideRecord = $null
    if ($null -ne $override) {
        $overrideRecord = [pscustomobject]@{
            Accepted = ($override.Accepted -eq $true)
            Reason = $override.Reason
            Requested = $override.Requested
            Recommended = $override.Recommended
        }
    }

    $contextPackageId = $null; $contextPackageHash = $null
    if ($null -ne $contextPackage) {
        $contextPackageId = Get-ContractProperty $contextPackage 'PackageId' $null
        $contextPackageHash = Get-ContractProperty $contextPackage 'PackageHash' $null
    } elseif ($null -ne $contextBudget) {
        $contextPackageId = Get-ContractProperty $contextBudget 'BudgetId' $null
    }

    $evidence = New-RoutingDecisionEvidence @{
        RoutingRequestId = $routingRequestId; TaskId = $taskId; Status = $status
        Policy = $policy.PolicyId
        EligibleCandidates = $eligible.ToArray()
        RejectedCandidates = $rejected.ToArray()
        RecommendationReason = $recommendationReason
        ManualOverride = $overrideRecord
        DecisionTimestampUtc = $requestTs.ToString('o')
        ContextPackageId = $contextPackageId
        ContextPackageHash = $contextPackageHash
        PricingRecordId = if ($null -ne $winner) { $winner.PricingRecordId } else { $null }
        PerformanceEvidenceReference = if ($null -ne $winner) { $winner.PerformanceEvidenceReference } else { $null }
        Mode = $execMode
        TargetCurrency = $targetCurrency
        ProcessingTier = $processingTier
        TimeBand = $timeBand
        WorkUniverse = $workUniverse; NodeAddress = $evidenceNodeAddress
        Notes = 'DB-M19 recommendation-only router: nothing was executed, invoked, or auto-advanced.'
    }

    return @{
        Status = $status
        Policy = $policy
        ExecutionMode = $execMode
        Winner = $winner
        WinnerEligible = ($null -ne $winner)
        EligibleCandidates = $eligible.ToArray()
        RejectedCandidates = $rejected.ToArray()
        Decision = $decision
        Evidence = $evidence
        RecommendationReason = $recommendationReason
        ContextPackageId = $contextPackageId
        ContextPackageHash = $contextPackageHash
        PricingRecordId = if ($null -ne $winner) { $winner.PricingRecordId } else { $null }
        PerformanceEvidenceReference = if ($null -ne $winner) { $winner.PerformanceEvidenceReference } else { $null }
    }
}

# -----------------------------------------------------------------------------
# Internal helpers for Get-AiRoutingRecommendation
# -----------------------------------------------------------------------------
function New-DbM19RecommendationResult {
    param(
        [AllowNull()][object]$Request,
        [AllowNull()][pscustomobject]$Policy,
        [string]$ExecMode,
        [string]$TaskId,
        [string]$RoutingRequestId,
        [AllowNull()]$RequestTs,
        [string]$Status,
        [AllowNull()][object[]]$Eligible,
        [AllowNull()][object[]]$Rejected,
        [AllowNull()][pscustomobject]$Requirement,
        [AllowNull()][object]$MaxAllowedCost,
        [string]$TargetCurrency,
        [string]$ProcessingTier,
        [AllowNull()][string]$TimeBand,
        [AllowNull()][object]$ContextBudget,
        [AllowNull()][object]$ContextPackage
    )
    $reason = $null
    switch ($Status) {
        'NO_ELIGIBLE_MODEL'          { $reason = "no model passed the hard eligibility constraints (see RejectedCandidates for the structured reasons)" }
        'NO_ELIGIBLE_MODEL_CONTEXT'  { $reason = 'no eligible model fits the mandatory context + output/reasoning reserve; mandatory governance was NOT truncated' }
        'NO_ELIGIBLE_MODEL_BUDGET'   { $reason = "every eligible model exceeds the request MaxAllowedCost $(if ($null -ne $MaxAllowedCost) { $MaxAllowedCost } else { 'UNKNOWN' }) $TargetCurrency" }
        'NO_ELIGIBLE_MODEL_PRICE'    { $reason = 'every context-fitting candidate has an unknown price and the policy does not allow cost-unknown candidates' }
        default                     { $reason = [string]$Status }
    }
    $decision = New-AiRoutingDecision -RoutingRequestId $RoutingRequestId -TaskId $TaskId `
        -EligibleCandidateIds @() -RejectedCandidateIds @(@($Rejected) | ForEach-Object { $_.ModelId }) `
        -RoutingReason $reason -PolicyVersion '1.0.0' -ManualOverride $false `
        -DecisionTimestamp ($RequestTs.ToString('o'))
    $contextPackageId = $null; $contextPackageHash = $null
    $wu = 'Foundation'; $wuNodeAddress = $null
    if ($null -ne $ContextPackage) {
        $contextPackageId = Get-ContractProperty $ContextPackage 'PackageId' $null
        $contextPackageHash = Get-ContractProperty $ContextPackage 'PackageHash' $null
        $wu = Get-ContractProperty $ContextPackage 'WorkUniverse' $null
        if (-not $wu) { $wu = 'Foundation' }
        $wuNodeAddress = Get-ContractProperty $ContextPackage 'NodeAddress' $null
    } elseif ($null -ne $ContextBudget) {
        $contextPackageId = Get-ContractProperty $ContextBudget 'BudgetId' $null
    }
    $evidence = New-RoutingDecisionEvidence @{
        RoutingRequestId = $RoutingRequestId; TaskId = $TaskId; Status = $Status
        Policy = $Policy.PolicyId
        EligibleCandidates = @($Eligible)
        RejectedCandidates = @($Rejected)
        RecommendationReason = $reason
        DecisionTimestampUtc = $RequestTs.ToString('o')
        ContextPackageId = $contextPackageId
        ContextPackageHash = $contextPackageHash
        Mode = $ExecMode
        TargetCurrency = $TargetCurrency
        ProcessingTier = $ProcessingTier
        TimeBand = $TimeBand
        WorkUniverse = $wu; NodeAddress = $wuNodeAddress
        Notes = 'DB-M19 recommendation-only router: nothing was executed, invoked, or auto-advanced.'
    }
    return @{
        Status = $Status
        Policy = $Policy
        ExecutionMode = $ExecMode
        Winner = $null
        WinnerEligible = $false
        EligibleCandidates = @($Eligible)
        RejectedCandidates = @($Rejected)
        Decision = $decision
        Evidence = $evidence
        RecommendationReason = $reason
        ContextPackageId = $contextPackageId
        ContextPackageHash = $contextPackageHash
        PricingRecordId = $null
        PerformanceEvidenceReference = $null
    }
}

function New-DbM19RecommendationReason {
    <#
    .SYNOPSIS
    Build the transparent, explainable recommendation reason: why the winner was
    selected, why others ranked below (with the first rejection/elimination reason),
    the estimated attempt cost, the reasoning level, the evidence used and its
    confidence. Never an opaque score.
    #>
    param(
        [string]$Status,
        [AllowNull()][pscustomobject]$Policy,
        [AllowNull()][object]$Winner,
        [AllowNull()][object]$Rank,
        [AllowNull()][object[]]$Eligible,
        [AllowNull()][object[]]$Rejected,
        [string]$ExecMode,
        [AllowNull()][object]$Override,
        [string]$TargetCurrency
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Policy: $($Policy.PolicyId) (objective $($Policy.Objective)); ExecutionMode: $ExecMode; Status: $Status")

    if ($null -eq $Winner) {
        $lines.Add('No model was selected (recommendation only).')
        foreach ($rejectedCandidate in @($Rejected)) {
            $first = $null
            $reasons = @(Get-ContractProperty $rejectedCandidate 'RejectionReasons' @())
            if ($reasons.Count -gt 0) {
                $r = $reasons[0]
                $first = "$($r.Reason): $($r.Detail)"
            }
            $lines.Add("Rejected $($rejectedCandidate.ProviderId)/$($rejectedCandidate.ModelId): $(if ($first) { $first } else { 'no eligible/selectable candidate' })")
        }
        return ($lines -join "`n")
    }

    $winnerComponents = Get-ContractProperty $Winner 'ComponentScores' $null
    $componentText = ''
    if ($null -ne $winnerComponents) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($wn in Get-RoutingPolicyWeightNames) {
            $val = Get-ContractProperty $winnerComponents $wn $null
            if ($null -ne $val) { $parts.Add("$wn=$([math]::Round([double]$val, 3))") }
        }
        $componentText = ' (' + ($parts -join ', ') + ')'
    }

    $costText = $null
    $costUnknown = Get-ContractProperty $Winner 'CostUnknown' $false
    $estCost = Get-ContractProperty $Winner 'EstimatedCost' $null
    if ($costUnknown) { $costText = "estimated cost UNKNOWN (labeled COST_UNKNOWN; price lookup/calculation did not yield a usable number)" }
    elseif ($null -ne $estCost) { $costText = "estimated attempt cost $estCost $TargetCurrency" }
    else { $costText = 'estimated cost not available' }

    $evidenceText = 'no historical evidence (cold start; confidence INSUFFICIENT)'
    $evidence = Get-ContractProperty $Winner 'PerformanceEvidence' $null
    if ($null -ne $evidence) {
        $conf = Get-ContractProperty $evidence 'ConfidenceLevel' 'INSUFFICIENT'
        $succ = Get-ContractProperty $evidence 'SuccessRate' $null
        $cps = Get-ContractProperty $evidence 'AverageCostPerSuccessfulTask' $null
        $sample = Get-ContractProperty $evidence 'SampleCount' 0
        $evidenceText = "evidence confidence $conf (sample $sample); verified success rate $(if ($null -ne $succ) { ('{0}%' -f [math]::Round([double]$succ * 100, 1)) } else { 'n/a' }); verified cost-per-success $(if ($null -ne $cps) { $cps } else { 'n/a' }) $TargetCurrency"
    }

    $lines.Add("Selected: $($Winner.ProviderId)/$($Winner.ModelId) at reasoning level $($Winner.SelectedReasoningLevel)")
    $lines.Add("PolicyScore $([math]::Round([double]$Winner.PolicyScore, 4))$componentText")
    $lines.Add($costText)
    $lines.Add($evidenceText)
    $lines.Add("Evidence reference: $($Winner.PerformanceEvidenceReference)")

    foreach ($otherCandidate in @($Eligible)) {
        if ($otherCandidate.ModelId -eq $Winner.ModelId -and $otherCandidate.ProviderId -eq $Winner.ProviderId) { continue }
        $otherCost = if ($otherCandidate.CostUnknown) { 'COST_UNKNOWN' } elseif ($null -ne $otherCandidate.EstimatedCost) { "$($otherCandidate.EstimatedCost)" } else { 'n/a' }
        $otherScore = if ($null -ne $otherCandidate.PolicyScore) { [math]::Round([double]$otherCandidate.PolicyScore, 4) } else { 'n/a' }
        $lines.Add("Not selected: $($otherCandidate.ProviderId)/$($otherCandidate.ModelId) -- PolicyScore $otherScore, estimated cost $otherCost, selectable $($otherCandidate.Selectable)")
    }
    if ($null -ne $Override) {
        if ($Override.Accepted -eq $true) { $lines.Add("Manual override ACCEPTED: $($Override.Reason)") }
        else { $lines.Add("Manual override REJECTED: $($Override.Reason)") }
    }
    return ($lines -join "`n")
}

# -----------------------------------------------------------------------------
# Recommendation export (markdown)
# -----------------------------------------------------------------------------
function Export-AiRoutingRecommendation {
    <#
    .SYNOPSIS
    Write the routing recommendation as markdown. The default path matches the
    DB-M19 brief (tasks\ROUTING_RECOMMENDATION.md); the milestone/test generation
    always passes an explicit -OutputPath under DB-M19-owned storage so live task
    handoff/prompt artifacts are never altered (CHATGPT_HANDOFF.md /
    DEEPSEEK_PROMPT.md / CLAUDE_REVIEW_PROMPT.md are never touched).
    #>
    param(
        [AllowNull()][object]$Recommendation,
        [string]$OutputPath,
        [AllowNull()][object]$Request
    )
    if ($null -eq $Recommendation) { throw 'Export-AiRoutingRecommendation: Recommendation is required' }
    if (-not $OutputPath) {
        $root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $OutputPath = Join-Path $root "tasks\ROUTING_RECOMMENDATION.md"
    }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('# Routing Recommendation')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('**DB-M19 Capability-Based Model Router -- recommendation only. Nothing was executed, invoked, or auto-advanced.**')
    $null = $sb.AppendLine('')

    $decision = Get-ContractProperty $Recommendation 'Decision' $null
    $evidence = Get-ContractProperty $Recommendation 'Evidence' $null
    $status = Get-ContractProperty $Recommendation 'Status' ''

    $null = $sb.AppendLine('## Request')
    $null = $sb.AppendLine('')
    $taskId = if ($null -ne $Request) { Get-ContractProperty $Request 'TaskId' '' } else { Get-ContractProperty $decision 'TaskId' '' }
    $policyId = ''
    $policyObj = Get-ContractProperty $Recommendation 'Policy' $null
    if ($null -ne $policyObj) { $policyId = Get-ContractProperty $policyObj 'PolicyId' '' }
    $null = $sb.AppendLine("- TaskId: $taskId")
    $null = $sb.AppendLine("- RoutingRequestId: $(Get-ContractProperty $decision 'RoutingRequestId' '')")
    $null = $sb.AppendLine("- Policy: $policyId")
    $null = $sb.AppendLine("- ExecutionMode: $(Get-ContractProperty $Recommendation 'ExecutionMode' '')")
    $null = $sb.AppendLine("- Status: $status")
    $null = $sb.AppendLine('')

    $winner = Get-ContractProperty $Recommendation 'Winner' $null
    $null = $sb.AppendLine('## Recommendation')
    $null = $sb.AppendLine('')
    if ($null -eq $winner) {
        $null = $sb.AppendLine('**No model selected** (recommendation only).')
    } else {
        $null = $sb.AppendLine("| Field | Value |")
        $null = $sb.AppendLine("|---|---|")
        $null = $sb.AppendLine("| Provider | $(Get-ContractProperty $winner 'ProviderId' '') |")
        $null = $sb.AppendLine("| Model | $(Get-ContractProperty $winner 'ModelId' '') |")
        $null = $sb.AppendLine("| Reasoning level | $(Get-ContractProperty $winner 'SelectedReasoningLevel' '') |")
        $null = $sb.AppendLine("| Estimated cost | $(if ($winner.CostUnknown) { 'COST_UNKNOWN' } else { "$($winner.EstimatedCost) $($winner.CostCurrency)" }) |")
        $null = $sb.AppendLine("| PolicyScore | $(if ($null -ne $winner.PolicyScore) { [math]::Round([double]$winner.PolicyScore, 4) } else { 'n/a' }) |")
    }
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('## Why')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine((Get-ContractProperty $Recommendation 'RecommendationReason' ''))

    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('## Candidates')
    $null = $sb.AppendLine('')
    $eligible = @(Get-ContractProperty $Recommendation 'EligibleCandidates' @())
    $rejected = @(Get-ContractProperty $Recommendation 'RejectedCandidates' @())
    if ($eligible.Count -gt 0) {
        $null = $sb.AppendLine('### Eligible')
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('| Provider | Model | Reasoning | Est. cost | Cost unknown | Selectable | Rank |')
        $null = $sb.AppendLine('|---|---|---|---|---|---|---|')
        foreach ($candidate in $eligible) {
            $null = $sb.AppendLine("| $(Get-ContractProperty $candidate 'ProviderId' '') | $(Get-ContractProperty $candidate 'ModelId' '') | $(Get-ContractProperty $candidate 'SelectedReasoningLevel' '') | $(if ($candidate.CostUnknown) { 'COST_UNKNOWN' } elseif ($null -ne $candidate.EstimatedCost) { $candidate.EstimatedCost } else { 'n/a' }) | $($candidate.CostUnknown) | $($candidate.Selectable) | $(if ($null -ne $candidate.Rank) { $candidate.Rank } else { '--' }) |")
        }
        $null = $sb.AppendLine('')
    }
    if ($rejected.Count -gt 0) {
        $null = $sb.AppendLine('### Rejected (structured reasons)')
        $null = $sb.AppendLine('')
        foreach ($candidate in $rejected) {
            $reasons = @(Get-ContractProperty $candidate 'RejectionReasons' @())
            $reasonText = if ($reasons.Count -gt 0) { ($reasons | ForEach-Object { "$($_.Reason): $($_.Detail)" }) -join '; ' } else { 'n/a' }
            $null = $sb.AppendLine("- **$(Get-ContractProperty $candidate 'ProviderId' '')/$(Get-ContractProperty $candidate 'ModelId' '')** -- $reasonText")
        }
        $null = $sb.AppendLine('')
    }

    $null = $sb.AppendLine('## Evidence & governance')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("- ContextPackageId: $(Get-ContractProperty $Recommendation 'ContextPackageId' '')")
    $null = $sb.AppendLine("- ContextPackageHash: $(Get-ContractProperty $Recommendation 'ContextPackageHash' '')")
    $null = $sb.AppendLine("- PricingRecordId: $(Get-ContractProperty $Recommendation 'PricingRecordId' '')")
    $null = $sb.AppendLine("- PerformanceEvidenceReference: $(Get-ContractProperty $Recommendation 'PerformanceEvidenceReference' '')")
    $null = $sb.AppendLine("- Manual override: $(if ($null -ne (Get-ContractProperty $evidence 'ManualOverride' $null)) { ($evidence.ManualOverride | ConvertTo-Json -Compress) } else { 'none' })")
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('---')
    $null = $sb.AppendLine('*Generated by DB-M19 (recommendation-only router). No provider/model was executed; the manual DevBridge -> ChatGPT -> DeepSeek -> DevBridge verification -> Claude loop is unchanged unless a human acts on this recommendation.*')

    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $content = $sb.ToString()
    Set-Content -Path $OutputPath -Value $content -Encoding UTF8
    return @{ Written = $true; Path = $OutputPath; Length = $content.Length }
}

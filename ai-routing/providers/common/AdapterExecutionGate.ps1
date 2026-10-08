# AdapterExecutionGate.ps1 -- DB-M23 execution boundary / dry-run gate.
#
#   - Get-ProviderRoutePriceStatus : classify a route's price status from the DB-M15
#     catalogue (READ-ONLY via Get-AiPriceAt). CONFIGURED / FREE /
#     LOCAL_COST_UNKNOWN / PRICE_UNKNOWN. NEVER invents a cost. A LOCAL route with
#     no effective record is LOCAL_COST_UNKNOWN with OperationalCostUnknown=true:
#     zero provider token price is a PROVIDER-level default only, LOCAL != FREE.
#   - Test-ProviderAdapterExecutionAllowed : the gate. Consumes the PRE-COMPUTED
#     routing decision (DB-M19), budget evaluation (DB-M21) and health view (DB-M22)
#     READ-ONLY. Refuses on AUTO execution, non-eligible routing, budget block or
#     unhealthy route. AUTO_EXECUTION_ENABLED is FALSE by construction.
#   - New-ProviderDryRunResult : DRY_RUN_READY result. Nothing is sent.
#
# The adapter NEVER rewrites a routing decision, NEVER bypasses a budget block and
# NEVER bypasses an unhealthy route. Fallback (DB-M22), retry/escalation (DB-M20)
# and budget approval (DB-M21) are not decided here.

. (Join-Path $PSScriptRoot "AdapterContracts.ps1")                     # DB-M23 common
. (Join-Path $PSScriptRoot "..\..\AiRoutingPricingFoundation.ps1")     # DB-M15 (READ-ONLY)
. (Join-Path $PSScriptRoot "..\..\budget\BudgetPolicy.ps1")            # DB-M21 vocab (READ-ONLY)
. (Join-Path $PSScriptRoot "..\..\provider-health\ProviderHealthEngine.ps1")  # DB-M22 (READ-ONLY)

function Get-DbM23AllowedBudgetDecisions {
    <#
    .SYNOPSIS
    The DB-M21 budget decisions under which an adapter may proceed. Derived from the
    DB-M21 vocabulary (READ-ONLY), never hard-coded copies of DB-M21 logic.
    #>
    $all = @(Get-DbM21BudgetDecisions)
    return @('ALLOW', 'ALLOW_WITH_WARNING', 'NO_APPLICABLE_BUDGET') | Where-Object { $_ -in $all }
}

function Get-ProviderRoutePriceStatus {
    <#
    .SYNOPSIS
    Classify a route's price status using the DB-M15 pricing catalogue (READ-ONLY).
    Returns { PriceStatus, ProviderTokenPrice, OperationalCostUnknown, LookupState,
    PricingRecordId }.
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$LocalOrRemote = 'UNKNOWN',
        $TimestampUtc = $null,
        [bool]$HasConfiguredOperationalCostBasis = $false
    )
    $lookup = Get-AiPriceAt -Catalogue $Catalogue -ProviderId $ProviderId -ModelId $ModelId -TimestampUtc $TimestampUtc
    $state = (Get-ContractProperty $lookup 'LookupState' 'NOT_FOUND')
    $record = (Get-ContractProperty $lookup 'Record' $null)
    $recordId = $null
    if ($null -ne $record) { $recordId = (Get-ContractProperty $record 'PricingRecordId' $null) }

    $isLocal = ($LocalOrRemote -eq 'LOCAL')
    if ($state -eq 'FOUND' -and $null -ne $record) {
        $inPrice = (Get-ContractProperty $record 'InputPricePerMillion' $null)
        $outPrice = (Get-ContractProperty $record 'OutputPricePerMillion' $null)
        $zeroIn = ($null -ne $inPrice -and $inPrice -eq 0)
        $zeroOut = ($null -ne $outPrice -and $outPrice -eq 0)
        if ($zeroIn -and $zeroOut) {
            return @{
                PriceStatus = 'FREE'
                ProviderTokenPrice = 0
                OperationalCostUnknown = ($isLocal -and -not $HasConfiguredOperationalCostBasis)
                LookupState = $state
                PricingRecordId = $recordId
            }
        }
        return @{
            PriceStatus = 'CONFIGURED'
            ProviderTokenPrice = $inPrice   # provider token price per M input tokens
            OperationalCostUnknown = ($isLocal -and -not $HasConfiguredOperationalCostBasis)
            LookupState = $state
            PricingRecordId = $recordId
        }
    }

    if ($isLocal) {
        return @{
            PriceStatus = 'LOCAL_COST_UNKNOWN'
            ProviderTokenPrice = 0            # provider-level default only
            OperationalCostUnknown = $true
            LookupState = $state
            PricingRecordId = $null
        }
    }
    return @{
        PriceStatus = 'PRICE_UNKNOWN'
        ProviderTokenPrice = $null            # never invented
        OperationalCostUnknown = $true
        LookupState = $state
        PricingRecordId = $null
    }
}

function Test-ProviderAdapterExecutionAllowed {
    <#
    .SYNOPSIS
    The DB-M23 execution gate. All decision inputs are PRE-COMPUTED and consumed
    READ-ONLY: ExecutionMode (DB-M14), RoutingDecision (DB-M19), BudgetEvaluation
    (DB-M21), health evidence + policy (DB-M22). Returns { Allowed, ReasonCodes }.
    AUTO_EXECUTION_ENABLED = FALSE, NetworkCalls = 0, PaidApiCalls = 0.
    #>
    param(
        [string]$ExecutionMode = 'MANUAL',
        [AllowNull()][object]$RoutingDecision,
        [AllowNull()][object]$BudgetEvaluation,
        [AllowNull()][object[]]$HealthEvidence,
        [AllowNull()][pscustomobject]$HealthPolicy,
        $EvaluationTimestampUtc = $null,
        [string]$ProviderId,
        [string]$GatewayProviderId = '',
        [bool]$IsHighRisk = $true
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    $allowed = $true
    $evalUtc = if ($null -eq $EvaluationTimestampUtc) { [datetime]::UtcNow } else { $EvaluationTimestampUtc }

    # 1. AUTO execution is prohibited by construction.
    if ($ExecutionMode -eq 'AUTO') {
        $reasons.Add('AUTO_EXECUTION_PROHIBITED')
        $allowed = $false
    }

    # 2. Routing eligibility (DB-M19 result consumed read-only).
    if ($allowed) {
        $eligibles = @()
        if ($null -ne $RoutingDecision) {
            $eligibles = @(Get-ContractProperty $RoutingDecision 'EligibleCandidates' @())
        }
        if ($eligibles.Count -eq 0) {
            $reasons.Add('ROUTING_NOT_ELIGIBLE')
            $allowed = $false
        }
    }

    # 3. Budget decision (DB-M21 result consumed read-only).
    if ($allowed) {
        $decision = $null
        if ($null -ne $BudgetEvaluation) { $decision = (Get-ContractProperty $BudgetEvaluation 'Decision' $null) }
        $allowedDecisions = Get-DbM23AllowedBudgetDecisions
        if ($null -eq $decision -or $decision -notin $allowedDecisions) {
            $reasons.Add('BUDGET_BLOCK')
            $allowed = $false
        }
    }

    # 4. Route availability (DB-M22 view consumed read-only). Test-ProviderRouteAvailable
    # returns @{ Available; HealthState; CircuitState; Reasons; Message }.
    if ($allowed) {
        $avail = Test-ProviderRouteAvailable -Evidence $HealthEvidence -Policy $HealthPolicy `
            -EvaluationTimestampUtc $evalUtc -ProviderId $ProviderId -GatewayProviderId $GatewayProviderId `
            -IsHighRisk $IsHighRisk
        if (-not [bool](Get-ContractProperty $avail 'Available' $false)) {
            $reasons.Add('HEALTH_BLOCK')
            $allowed = $false
        }
    }

    return @{
        Allowed = $allowed
        ReasonCodes = @($reasons)
        AutoExecutionEnabled = $false
        NetworkCalls = 0
        PaidApiCalls = 0
    }
}

function New-ProviderDryRunResult {
    <#
    .SYNOPSIS
    Build the DRY_RUN_READY result for a generated provider-native request. No
    request is ever sent; the native shape is present for inspection only.
    #>
    param(
        [AllowNull()][object]$NativeRequest,
        [string]$RequestId,
        [string]$RoutingDecisionId,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$UnderlyingModelId,
        [string]$GatewayProviderId = ''
    )
    return [pscustomobject]@{
        PSCustomVersion       = 'AdapterDryRunResult v1'
        Status                = 'DRY_RUN_READY'
        RequestId             = $RequestId
        RoutingDecisionId     = $RoutingDecisionId
        ProviderId            = $ProviderId
        ModelId               = $ModelId
        UnderlyingModelId     = $UnderlyingModelId
        GatewayProviderId     = $GatewayProviderId
        NativeRequest         = $NativeRequest
        NoSend                = $true
        DryRun                = $true
        NetworkCalls          = 0
        PaidApiCalls          = 0
        AutoExecutionEnabled  = $false
        ReasonCodes           = @()
    }
}

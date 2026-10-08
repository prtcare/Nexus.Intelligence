# EscalationCost.ps1 -- DB-M20 cost-aware escalation (via the DB-M16 engine).
#
# DB-M20 is a DECISION ENGINE: this layer only ESTIMATES what a future attempt
# would cost. Nothing is executed. No paid API calls. No autonomous Nexus
# changes. AUTO_EXECUTION_ENABLED = FALSE.
#
# The cost math is NEVER duplicated here. Get-AiEscalationCost delegates to the
# DB-M19 STEP 3 estimator (Get-AiCandidateCostEstimate), which itself delegates
# to the DB-M16 engine (Calculate-AiAttemptCost) against the DB-M15 pricing
# catalogue and DB-M16 FX. An unknown price is surfaced as NextCostUnknown with
# a label -- never an invented price.
#
# DB-M20 understands a REQUEST-LEVEL cost ceiling only. It does NOT implement
# daily / monthly / organization / retry-pool / team budgets (DB-M21 territory).
# Incremental (next attempt) and cumulative costs are always present on the
# decision -- never hidden.

. (Join-Path $PSScriptRoot "..\AiRoutingCostFoundation.ps1")    # DB-M14 + DB-M15 + DB-M16 cost engine (READ-ONLY)
. (Join-Path $PSScriptRoot "..\router\RoutingCost.ps1")          # DB-M19 STEP 3 estimator (READ-ONLY)

function Get-DbM20ChainCumulative {
    <#
    .SYNOPSIS
    Cumulative cost across an attempt chain from recorded costs only: actual
    preferred, else estimated. No configuration or price lookup is needed, so
    terminal decisions can always report the cumulative cost honestly.
    Returns @{ CumulativeActualCost; CumulativeEstimatedCost }.
    #>
    param(
        [AllowNull()][object[]]$Attempts
    )
    $cumActual = 0.0
    $cumEstimated = 0.0
    $hadKnown = $false
    foreach ($rec in @($Attempts)) {
        $actual = Get-ContractProperty $rec 'ActualCost' $null
        $estimated = Get-ContractProperty $rec 'EstimatedCost' $null
        if ($null -ne $actual) { $cumActual += [double]$actual }
        $known = if ($null -ne $actual) { [double]$actual } elseif ($null -ne $estimated) { [double]$estimated } else { $null }
        if ($null -ne $known) { $cumEstimated += $known; $hadKnown = $true }
    }
    return @{
        CumulativeActualCost    = $cumActual
        CumulativeEstimatedCost = if ($hadKnown) { $cumEstimated } else { $null }
    }
}

function Get-AiEscalationCost {
    <#
    .SYNOPSIS
    Estimate the next attempt's cost for a proposed route and compute the
    cumulative cost across the attempt chain.
      - NextAttemptCost   : the estimated cost of ONE more attempt on the route
                            (via the DB-M16 engine), or null when unknown.
      - CumulativeActualCost     : sum of actual costs recorded in the chain.
      - CumulativeEstimatedCost  : sum of best-known costs across the chain
                                  (actual preferred, else estimated) plus the
                                  next-attempt estimate when known.
    Returns @{ NextAttemptCost; NextCostCurrency; NextCostUnknown; PricingRecordId;
               CumulativeEstimatedCost; CumulativeActualCost; Message }.
    #>
    param(
        [string]$ProviderId,
        [string]$ModelId,
        [AllowNull()][object]$Requirement,
        [AllowNull()][object]$Configuration,
        [AllowNull()][object[]]$Attempts,
        [AllowNull()]$RequestTimestampUtc,
        [string]$ProcessingTier = 'STANDARD',
        [string]$TimeBand,
        [double]$CachedInputFraction = 0.0,
        [string]$TargetCurrency = 'INR',
        [AllowNull()][Nullable[decimal]]$ExchangeRate,
        [string]$PricingRecordIdOverride,
        [AllowNull()][object]$ContextBudget,
        [AllowNull()][object]$ContextPackage
    )
    if (-not $ProviderId -or -not $ModelId) { throw "Get-AiEscalationCost: ProviderId and ModelId are required" }

    # minimal model stub carrying the route identity the DB-M19 estimator needs
    $modelStub = [pscustomobject]@{ ProviderId = $ProviderId; ModelId = $ModelId }

    $est = Get-AiCandidateCostEstimate -Model $modelStub -Requirement $Requirement -Configuration $Configuration `
        -ContextBudget $ContextBudget -ContextPackage $ContextPackage `
        -RequestTimestampUtc $RequestTimestampUtc -ProcessingTier $ProcessingTier -TimeBand $TimeBand `
        -CachedInputFraction $CachedInputFraction -TargetCurrency $TargetCurrency `
        -ExchangeRate $ExchangeRate -PricingRecordIdOverride $PricingRecordIdOverride

    $nextCost = $est.EstimatedCost
    $nextCurrency = $est.CostCurrency
    $nextUnknown = [bool]$est.CostUnknown
    $pricingRecordId = $est.PricingRecordId

    $cum = Get-DbM20ChainCumulative -Attempts $Attempts
    $cumActual = $cum.CumulativeActualCost
    $cumEstimated = $cum.CumulativeEstimatedCost
    $hadKnown = ($null -ne $cumEstimated)
    if ($null -ne $nextCost) { $cumEstimated = if ($null -eq $cumEstimated) { 0.0 } else { [double]$cumEstimated }; $cumEstimated += [double]$nextCost; $hadKnown = $true }
    if (-not $hadKnown) { $cumEstimated = $null }

    $message = if ($nextUnknown) {
        "next attempt cost unknown (via DB-M16: price lookup / calculation); cumulative estimated $cumEstimated $TargetCurrency"
    } else {
        "next attempt estimated $nextCost $nextCurrency; cumulative estimated $cumEstimated $TargetCurrency"
    }

    return @{
        NextAttemptCost        = $nextCost
        NextCostCurrency       = if ($nextUnknown) { $null } else { $nextCurrency }
        NextCostUnknown        = $nextUnknown
        PricingRecordId        = $pricingRecordId
        CumulativeEstimatedCost = $cumEstimated
        CumulativeActualCost   = $cumActual
        Message                = $message
    }
}

function Test-DbM20BudgetCeiling {
    <#
    .SYNOPSIS
    Request-level budget gate. A next attempt is refused when the sum of the
    already-accumulated cost and the next attempt's estimate exceeds the
    request MaxAllowedCost ceiling. Returns @{ Exceeded; Reason }.
    #>
    param(
        [AllowNull()]$CumulativeCost,
        [AllowNull()]$NextEstimate,
        [AllowNull()]$Ceiling
    )
    if ($null -eq $Ceiling) { return @{ Exceeded = $false; Reason = 'no request cost ceiling supplied' } }
    if ($null -eq $CumulativeCost -and $null -eq $NextEstimate) { return @{ Exceeded = $false; Reason = 'no costs known; cannot judge the ceiling' } }

    $total = 0.0
    if ($null -ne $CumulativeCost) { $total += [double]$CumulativeCost }
    if ($null -ne $NextEstimate) { $total += [double]$NextEstimate }

    if ($total -gt [double]$Ceiling) {
        return @{ Exceeded = $true; Reason = "next attempt would push total cost $total above the request ceiling $Ceiling (STOP_BUDGET_LIMIT)" }
    }
    return @{ Exceeded = $false; Reason = "total projected cost $total is within the request ceiling $Ceiling" }
}

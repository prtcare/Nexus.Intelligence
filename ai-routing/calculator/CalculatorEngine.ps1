# CalculatorEngine.ps1 -- DB-M27 AI Cost Calculator UI view-model builder.
#
# Pure, deterministic estimator. Given a CalculatorRequest v1 and an injected
# configuration, returns a CalculatorView v1. The calculator never executes a
# provider/model, never makes a paid API call, never makes a network call, and
# never modifies budget/routing/pricing/health/workbook/source.
#
# Every token->cost number is computed by the DB-M16 authoritative engine
# (Calculate-AiAttemptCost). DB-M15 pricing status and DB-M23 price status
# (LOCAL != FREE) are read-only inputs. DB-M25 quality-adjusted cost, DB-M24
# performance confidence, and DB-M21 budget context are informational views.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB27_*).
# ASCII-only source (PS 5.1 + BOM-safe). No secrets.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "CalculatorContracts.ps1")

# --- internal helpers -----------------------------------------------------------------

function Resolve-DbM27BillingIdentity {
    <#
    .SYNOPSIS
    Resolve the pricing/billing identity for a scenario. DIRECT and LOCAL routes
    bill the selected provider/model. GATEWAY routes bill the UNDERLYING model:
    the provider/gateway (e.g. OpenRouter) and the underlying model are never
    collapsed into one identity.
    #>
    param(
        [AllowNull()][object]$Configuration,
        [AllowNull()][object]$Request,
        [AllowNull()][object]$Model
    )
    $route = [string](Get-ContractProperty $Request 'RouteType' '')
    $modelId = [string](Get-ContractProperty $Request 'ModelId' '')
    $underlying = [string](Get-ContractProperty $Request 'UnderlyingModelId' '')
    $providerId = [string](Get-ContractProperty $Request 'ProviderId' '')

    $billingProvider = $providerId
    $billingModel = $modelId
    $billingUnderlying = $modelId
    $gatewayProviderId = ''
    $gatewayNote = ''

    if ($route -eq 'GATEWAY') {
        $gatewayProviderId = $providerId
        if ($underlying) { $billingUnderlying = $underlying }
        $billingModel = $billingUnderlying
        # Bill the UNDERLYING model's own catalogue entry for pricing (e.g.
        # anthropic/claude-sonnet-5 for an OpenRouter route to claude-sonnet-5).
        # Find-AiModelByUnderlyingModel returns ALL routes (direct + gateway), so
        # prefer the direct key lookup, then the first non-gateway match.
        $found = $null
        if ($Configuration -and $Configuration.Models) {
            $key = $billingUnderlying.Trim().ToLowerInvariant()
            if ($Configuration.Models -is [System.Collections.IDictionary] -and $Configuration.Models.ContainsKey($key)) {
                $found = $Configuration.Models[$key]
            } else {
                foreach ($m in @(Find-AiModelByUnderlyingModel -Catalogue $Configuration.Models -UnderlyingModelId $billingUnderlying)) {
                    if ([string](Get-ContractProperty $m 'GatewayProviderId' '') -eq '' -and $null -eq $found) { $found = $m }
                }
            }
        }
        if ($null -ne $found) {
            $billingProvider = [string](Get-ContractProperty $found 'ProviderId' $providerId)
            $gatewayNote = "priced by underlying model identity (provider=$billingProvider model=$billingUnderlying)"
        } else {
            $gatewayNote = 'underlying model not in catalogue; priced under gateway identity (expected PRICE_NOT_FOUND unless a matching record exists)'
        }
    } elseif ($route -eq 'LOCAL') {
        $billingProvider = $providerId
        $billingModel = $modelId
        $billingUnderlying = $modelId
        $gatewayNote = 'local route: billed under the local provider/model identity; LOCAL is never assumed FREE'
    } else {
        # DIRECT (or route unset -> derived by the caller)
        $billingProvider = $providerId
        $billingModel = $modelId
        $billingUnderlying = $modelId
        $gatewayNote = 'direct route: provider/model billed directly'
    }
    return [pscustomobject]@{
        ProviderId       = $billingProvider
        ModelId          = $billingModel
        UnderlyingModelId = $billingUnderlying
        GatewayProviderId = $gatewayProviderId
        GatewayNote      = $gatewayNote
    }
}

# --- main entry point ------------------------------------------------------------------

function Invoke-DbM27Calculator {
    <#
    .SYNOPSIS
    Build the CalculatorView v1 for a CalculatorRequest v1. Pure and deterministic
    (NowUtc is injected in the request). AttemptRecords (DB-M17) and BudgetPolicy
    (DB-M21) are OPTIONAL read-only inputs that only power the informational
    quality/performance/budget panels; they never alter the estimate.
    #>
    param(
        [AllowNull()][object]$Configuration,
        [AllowNull()][object]$Request,
        [AllowNull()][object[]]$AttemptRecords = $null,
        [AllowNull()][object]$BudgetPolicy = $null
    )
    $warnings = New-Object System.Collections.Generic.List[string]
    $validation = Test-DbM27CalculatorRequest -Request $Request
    foreach ($e in @($validation.Errors)) { $warnings.Add("REQUEST: $e") }
    foreach ($w in @($validation.Warnings)) { $warnings.Add($w) }
    $nowUtc = [string](Get-ContractProperty $Request 'NowUtc' '2026-08-31T00:00:00Z')

    # Confidence bands (DB-M24/M25) are loaded once, READ-ONLY, so the quality
    # panel can resolve confidence levels under Set-StrictMode (null bands would
    # otherwise break Get-AiConfidenceLevel's strict-mode Count guard).
    if ($null -eq $script:PerfConfidenceBands) {
        $null = Import-AiPerformanceConfiguration
    }

    $providers = @{}
    $models = @{}
    $pricing = @{}
    if ($Configuration) {
        if ($Configuration.Providers) { $providers = $Configuration.Providers }
        if ($Configuration.Models) { $models = $Configuration.Models }
        if ($Configuration.Pricing) { $pricing = $Configuration.Pricing }
    }

    $providerId = [string](Get-ContractProperty $Request 'ProviderId' '')
    $modelId = [string](Get-ContractProperty $Request 'ModelId' '')
    $routeType = [string](Get-ContractProperty $Request 'RouteType' '')

    # ---- scenario --------------------------------------------------------------------
    $provider = $null
    if ($providerId -and $providers.ContainsKey($providerId.ToLowerInvariant())) {
        $provider = $providers[$providerId.ToLowerInvariant()]
    } elseif ($providerId) {
        foreach ($k in @($providers.Keys)) {
            if ([string]$k -eq $providerId -or [string]$k -ieq $providerId) { $provider = $providers[$k]; break }
        }
    }
    if (-not $routeType) {
        if ($provider) { $routeType = [string](Get-ContractProperty $provider 'ProviderType' 'DIRECT') }
        elseif ($routeType -notin (Get-DbM27RouteTypes)) { $routeType = 'DIRECT' }
    }
    if ($routeType -notin (Get-DbM27RouteTypes)) { $routeType = 'DIRECT' }

    $model = $null
    if ($modelId -and $models.ContainsKey($modelId.ToLowerInvariant())) {
        $model = $models[$modelId.ToLowerInvariant()]
    } elseif ($modelId) {
        foreach ($k in @($models.Keys)) {
            if ([string]$k -ieq $modelId) { $model = $models[$k]; break }
        }
    }
    $modelLookupState = 'NOT_FOUND'
    if ($model) {
        $modelProviderOk = [string](Get-ContractProperty $model 'ProviderId' '') -ieq $providerId
        if ($routeType -eq 'GATEWAY') {
            $gw = [string](Get-ContractProperty $model 'GatewayProviderId' '')
            $modelLookupState = if ($gw -or $modelProviderOk) { 'FOUND' } else { 'INVALID_ROUTE' }
        } elseif ($modelProviderOk) {
            $modelLookupState = 'FOUND'
        } else {
            $modelLookupState = 'INVALID_ROUTE'
        }
    } elseif (-not $provider) {
        $modelLookupState = 'PROVIDER_UNKNOWN'
    }

    $localDefault = 'REMOTE'
    if ($routeType -eq 'LOCAL') { $localDefault = 'LOCAL' }
    $localOrRemote = [string](Get-ContractProperty $model 'LocalOrRemote' $localDefault)
    $reasoningSupported = @(Get-ContractProperty $model 'ReasoningLevelsSupported' @())

    $scenario = [pscustomobject]@{
        ProviderId            = $providerId
        ProviderFound         = ($null -ne $provider)
        ProviderDisplayName   = [string](Get-ContractProperty $provider 'DisplayName' $providerId)
        ProviderType          = [string](Get-ContractProperty $provider 'ProviderType' $routeType)
        RouteType             = $routeType
        ModelId               = $modelId
        ModelFound            = ($null -ne $model)
        ModelLookupState      = $modelLookupState
        ModelDisplayName      = [string](Get-ContractProperty $model 'DisplayName' $modelId)
        UnderlyingModelId     = [string](Get-ContractProperty $model 'UnderlyingModelId' $modelId)
        GatewayProviderId     = [string](Get-ContractProperty $model 'GatewayProviderId' '')
        LocalOrRemote         = $localOrRemote
        ReasoningLevelsSupported = $reasoningSupported
        ReasoningLevel        = [string](Get-ContractProperty $Request 'ReasoningLevel' '')
        Enabled               = [bool](Get-ContractProperty $model 'Enabled' $false)
        ProviderEnabled       = [bool](Get-ContractProperty $provider 'Enabled' $false)
        Note                  = 'pre-execution estimate: provider/model are NOT executed by the calculator'
    }

    # ---- pricing / price status ---------------------------------------------------------
    $billing = Resolve-DbM27BillingIdentity -Configuration $Configuration -Request $Request -Model $model
    $bProv = $billing.ProviderId
    $bModel = $billing.ModelId

    $priceLookup = $null
    $priceLookupState = 'NOT_FOUND'
    $priceLookupMessage = ''
    $overrideId = [string](Get-ContractProperty $Request 'PricingRecordId' '')
    if ($overrideId -and $pricing.ContainsKey($overrideId)) {
        $priceLookup = $pricing[$overrideId]
        $priceLookupState = 'FOUND'
        $priceLookupMessage = "override record '$overrideId' (authorized by DB-M16 PricingRecordIdOverride)"
    } elseif ($overrideId) {
        $priceLookupState = 'NOT_FOUND'
        $priceLookupMessage = "override record '$overrideId' is not in the pricing catalogue"
    } elseif ($pricing.Count -gt 0) {
        $lk = Get-AiPriceAt -Catalogue $pricing -ProviderId $bProv -ModelId $bModel -AsOfUtc $nowUtc
        $priceLookup = if ($lk.Record) { $lk.Record } else { $null }
        $priceLookupState = [string]$lk.LookupState
        $priceLookupMessage = [string]$lk.Message
    } else {
        $priceLookupMessage = 'pricing catalogue is empty'
    }

    $recordStatus = $null
    if ($priceLookup) {
        $recordStatus = Get-AiPricingRecordStatus -Record $priceLookup -AsOfUtc $nowUtc
    }
    $routePriceStatus = $null
    try {
        $routePriceStatus = Get-ProviderRoutePriceStatus -Catalogue $pricing -ProviderId $bProv -ModelId $bModel `
            -LocalOrRemote $localOrRemote -TimestampUtc $nowUtc
    } catch {
        $routePriceStatus = $null
    }
    $priceStatus = 'PRICE_UNKNOWN'
    $operationalCostUnknown = $true
    $providerTokenPrice = $null
    if ($routePriceStatus) {
        $priceStatus = [string]$routePriceStatus.PriceStatus
        $operationalCostUnknown = [bool]$routePriceStatus.OperationalCostUnknown
        $providerTokenPrice = $routePriceStatus.ProviderTokenPrice
    }

    $pricingBlock = [pscustomobject]@{
        PricingRecordId      = if ($priceLookup) { [string](Get-ContractProperty $priceLookup 'PricingRecordId' '') } else { $null }
        PricingRecordStatus  = if ($recordStatus) { [string]$recordStatus.Status } else { 'NONE' }
        PricingRecordReason  = if ($recordStatus) { [string]$recordStatus.Reason } else { 'no pricing record resolved' }
        PriceLookupState     = $priceLookupState
        PriceLookupMessage   = $priceLookupMessage
        PriceStatus          = $priceStatus
        OperationalCostUnknown = $operationalCostUnknown
        ProviderTokenPrice   = $providerTokenPrice
        PricingCurrency      = if ($priceLookup) { [string](Get-ContractProperty $priceLookup 'Currency' 'USD') } else { 'USD' }
        EffectiveFromUtc     = if ($priceLookup) { [string](Get-ContractProperty $priceLookup 'EffectiveFromUtc' '') } else { '' }
        EffectiveToUtc       = if ($priceLookup) { [string](Get-ContractProperty $priceLookup 'EffectiveToUtc' '') } else { '' }
        Source               = if ($priceLookup) { [string](Get-ContractProperty $priceLookup 'Source' '') } else { '' }
        VerifiedAtUtc        = if ($priceLookup) { [string](Get-ContractProperty $priceLookup 'VerifiedAtUtc' '') } else { '' }
        ManualOverride       = if ($priceLookup) { [bool](Get-ContractProperty $priceLookup 'ManualOverride' $false) } else { $false }
        BillingProviderId    = $bProv
        BillingModelId       = $bModel
        BillingNote          = $billing.GatewayNote
    }

    # ---- estimate (DB-M16 authoritative engine) ------------------------------------------
    $estimate = $null
    $costInput = New-AiCostCalculationInput -ProviderId $bProv -ModelId $bModel -RequestTimestampUtc $nowUtc `
        -EstimatedInputTokens ([long](Get-ContractProperty $Request 'InputTokens' 0)) `
        -EstimatedCachedInputTokens ([long](Get-ContractProperty $Request 'CachedInputTokens' 0)) `
        -EstimatedOutputTokens ([long](Get-ContractProperty $Request 'OutputTokens' 0)) `
        -CacheWrite5mTokens ([long](Get-ContractProperty $Request 'CacheWriteTokens' 0)) `
        -CurrencyTarget ([string](Get-ContractProperty $Request 'CurrencyTarget' 'USD')) `
        -PricingRecordIdOverride $overrideId `
        -UsageSource 'ESTIMATED'

    if ($Configuration) {
        $res = Calculate-AiAttemptCost -Configuration $Configuration -CostInput $costInput
        $attemptCount = [long](Get-ContractProperty $Request 'AttemptCount' 1)
        $corrections = [long](Get-ContractProperty $Request 'ExpectedCorrectionAttempts' 0)
        $attemptsTotal = $attemptCount + $corrections
        $perAttempt = $res.ConvertedTotal
        $total = if ($null -ne $perAttempt) { $perAttempt * $attemptsTotal } else { $null }
        $estimate = [pscustomobject]@{
            CalculationStatus        = [string]$res.CalculationStatus
            PriceLookupStatus        = [string]$res.PriceLookupStatus
            EstimatedOrActual        = 'ESTIMATED'
            UsageSource              = 'ESTIMATED'
            InputCost                = $res.InputCost
            OutputCost               = $res.OutputCost
            CachedInputCost          = $res.CachedInputCost
            CacheWrite5mCost         = $res.CacheWrite5mCost
            CacheWrite1hCost         = $res.CacheWrite1hCost
            Subtotal                 = $res.Subtotal
            ProviderCurrencyTotal    = $res.ProviderCurrencyTotal
            ConvertedTotal           = $perAttempt
            PricingCurrency          = [string]$res.PricingCurrency
            CostCurrency             = [string]$res.CostCurrency
            ExchangeRate             = $res.ExchangeRate
            ExchangeRateId           = [string]$res.ExchangeRateId
            TargetCurrency           = [string](Get-ContractProperty $Request 'CurrencyTarget' 'USD')
            EstimatedCost            = $res.EstimatedCost
            ActualCost               = $res.ActualCost
            PerAttemptCost           = $perAttempt
            AttemptCount             = $attemptCount
            ExpectedCorrectionAttempts = $corrections
            AttemptsTotal            = $attemptsTotal
            TotalMultiAttemptCost    = $total
            CacheWriteBillingNote    = 'DB-M16 bills cache-write (CacheWrite5m/1h) only on ACTUAL usage; this ESTIMATE cannot charge cache-write, so it is never shown as a fabricated zero.'
            Message                  = [string](Get-ContractProperty $res 'Message' '')
            Note                     = 'ESTIMATED COST only: nothing was executed, so no ACTUAL cost exists'
        }
    } else {
        $estimate = [pscustomobject]@{
            CalculationStatus = 'INVALID_USAGE'
            PriceLookupStatus = 'NONE'
            EstimatedOrActual = 'ESTIMATED'
            UsageSource       = 'ESTIMATED'
            Message           = 'no configuration supplied'
            Note              = 'ESTIMATED COST only: nothing was executed, so no ACTUAL cost exists'
        }
    }

    # ---- quality / performance panel (DB-M25 + DB-M24, informational, optional) -----------
    $quality = $null
    # Normalize: a null-valued [object[]] parameter can collapse to $null under
    # @() in PS 5.1, so build the record list with an explicit null guard.
    $records = New-Object System.Collections.Generic.List[object]
    if ($null -ne $AttemptRecords) {
        foreach ($a in $AttemptRecords) { if ($null -ne $a) { $records.Add($a) } }
    }
    if ($records.Count -gt 0) {
        try {
            $reporting = [string](Get-ContractProperty $Request 'CurrencyTarget' 'USD')
            $m25Query = New-DbM25QualityCostQuery -QueryId ('db27-qc-' + $bModel) -PresetWindow 'ALL_TIME' -NowUtc $nowUtc `
                -ProviderId $bProv -ModelId $bModel -UnderlyingModelId $billing.UnderlyingModelId `
                -GatewayProviderId $billing.GatewayProviderId -LocalOrRemote $localOrRemote `
                -ReportingCurrency $reporting -SuccessDefinition 'VERIFIED' -GroupBy 'ModelRoute'
            $m25Results = @(Get-DbM25QualityAdjustedCost -Records $records -Query $m25Query)
            $m25 = if ($m25Results.Count -gt 0) { $m25Results[0] } else { $null }
            $perfQuery = New-AiPerformanceQuery -QueryId ('db27-perf-' + $bModel) -PresetWindow 'ALL_TIME' -NowUtc $nowUtc `
                -ProviderId $bProv -ModelId $bModel -UnderlyingModelId $billing.UnderlyingModelId `
                -GatewayProviderId $billing.GatewayProviderId -ReportingCurrency $reporting `
                -SuccessDefinition 'VERIFIED_PREFERRED'
            $perfResults = @(Get-AiModelPerformance -Records $records -Query $perfQuery)
            $perf = if ($perfResults.Count -gt 0) { $perfResults[0] } else { $null }

            $sample = if ($m25) { [long]$m25.SampleCount } elseif ($perf) { [long]$perf.SampleCount } else { 0 }
            $confidence = if ($m25) { [string]$m25.ConfidenceLevel } elseif ($perf) { [string]$perf.ConfidenceLevel } else { 'INSUFFICIENT' }
            $quality = [pscustomobject]@{
                HasEvidence                      = ($sample -gt 0)
                SampleCount                      = $sample
                AttemptCount                     = if ($m25) { [long]$m25.AttemptCount } else { 0 }
                VerifiedSuccessCount             = if ($m25) { [long]$m25.VerifiedSuccessCount } else { 0 }
                VerifiedSuccessRate              = if ($m25) { $m25.VerifiedSuccessRate } else { $null }
                FirstAttemptSuccessRate          = if ($m25) { $m25.FirstAttemptVerifiedSuccessRate } elseif ($perf) { $perf.FirstAttemptSuccessRate } else { $null }
                AverageAttemptsPerVerifiedSuccess = if ($m25) { $m25.AverageAttemptsPerVerifiedSuccess } else { $null }
                ObservedCostPerVerifiedSuccess   = if ($m25) { $m25.ObservedCostPerVerifiedSuccess } else { $null }
                ExpectedCostPerVerifiedSuccess   = if ($m25) { $m25.ExpectedCostPerVerifiedSuccess } else { $null }
                ExpectedCostBasis                = if ($m25) { [string]$m25.ExpectedCostBasis } else { '' }
                AverageCostPerSuccessfulTask     = if ($perf) { $perf.AverageCostPerSuccessfulTask } else { $null }
                ConfidenceLevel                  = $confidence
                LocalCostStatus                  = if ($m25) { [string]$m25.LocalCostStatus } else { $priceStatus }
                EvidenceNote                     = if ($sample -gt 0) {
                    "observed on $sample sample(s); confidence '$confidence'. Never treated as statistically reliable below MODERATE."
                } else {
                    'no historical evidence for this identity; the estimate is engine-only and NOT statistically supported.'
                }
            }
        } catch {
            $quality = [pscustomobject]@{
                HasEvidence = $false
                SampleCount = 0
                ConfidenceLevel = 'INSUFFICIENT'
                EvidenceNote = 'quality panel unavailable for this identity (no resolvable evidence).'
            }
        }
    } else {
        $quality = [pscustomobject]@{
            HasEvidence        = $false
            SampleCount        = 0
            ConfidenceLevel    = 'INSUFFICIENT'
            LocalCostStatus    = $priceStatus
            EvidenceNote       = 'no historical evidence supplied; the estimate is engine-only and NOT statistically supported.'
        }
    }

    # ---- escalation chain (cost simulation only; routing policy never touched) --------------
    $escSteps = New-Object System.Collections.Generic.List[object]
    $cumulative = $null
    $escOk = $true
    $path = @(Get-ContractProperty $Request 'EscalationPath' @())
    foreach ($s in $path) {
        $stepProv = [string](Get-ContractProperty $s 'ProviderId' '')
        $stepModel = [string](Get-ContractProperty $s 'ModelId' '')
        $stepAttempts = [long](Get-ContractProperty $s 'AttemptCount' 1)
        $stepOverride = [string](Get-ContractProperty $s 'PricingRecordId' '')
        $stepInput = New-AiCostCalculationInput -ProviderId $stepProv -ModelId $stepModel -RequestTimestampUtc $nowUtc `
            -EstimatedInputTokens ([long](Get-ContractProperty $Request 'InputTokens' 0)) `
            -EstimatedCachedInputTokens ([long](Get-ContractProperty $Request 'CachedInputTokens' 0)) `
            -EstimatedOutputTokens ([long](Get-ContractProperty $Request 'OutputTokens' 0)) `
            -CacheWrite5mTokens ([long](Get-ContractProperty $Request 'CacheWriteTokens' 0)) `
            -CurrencyTarget ([string](Get-ContractProperty $Request 'CurrencyTarget' 'USD')) `
            -PricingRecordIdOverride $stepOverride `
            -UsageSource 'ESTIMATED'
        $stepRes = $null
        if ($Configuration) { $stepRes = Calculate-AiAttemptCost -Configuration $Configuration -CostInput $stepInput }
        $stepPer = if ($stepRes) { $stepRes.ConvertedTotal } else { $null }
        $stepTotal = if ($null -ne $stepPer) { $stepPer * $stepAttempts } else { $null }
        if ($null -ne $stepTotal) {
            if ($null -eq $cumulative) { $cumulative = $stepTotal } else { $cumulative = $cumulative + $stepTotal }
        } else { $escOk = $false }
        $escSteps.Add([pscustomobject]@{
            Step             = [long](Get-ContractProperty $s 'Step' ($escSteps.Count + 1))
            ProviderId       = $stepProv
            ModelId          = $stepModel
            AttemptCount     = $stepAttempts
            PerAttemptCost   = $stepPer
            StepTotal        = $stepTotal
            CumulativeCost   = $cumulative
            CalculationStatus = if ($stepRes) { [string]$stepRes.CalculationStatus } else { 'INVALID_USAGE' }
            PricingRecordId  = if ($stepRes) { [string]$stepRes.PricingRecordId } else { $null }
            Currency         = if ($stepRes) { [string]$stepRes.CostCurrency } else { '' }
        })
    }
    $escalationTotal = [pscustomobject]@{
        HasPath            = ($path.Count -gt 0)
        StepCount          = $escSteps.Count
        CumulativeCost     = $cumulative
        Currency           = if ($escSteps.Count -gt 0) { [string]$escSteps[0].Currency } else { '' }
        SimulationOnly     = $true
        RoutingPolicyUnmodified = $true
        Note               = 'read-only cost simulation: the escalation path never modifies routing policy.'
    }

    # ---- budget context (DB-M21, informational only) -----------------------------------------
    $budget = $null
    if ($BudgetPolicy) {
        try {
            $proposedCost = if ($estimate) { $estimate.PerAttemptCost } else { $null }
            $proposedUnknown = ($null -eq $proposedCost)
            $eval = Test-AiBudget -Policy $BudgetPolicy -EvaluationTimestampUtc $nowUtc -Attempts $records `
                -TaskId 'DB-M27-calculator' -ChangeId '' -SessionId 'DB-M27-calculator' `
                -ProposedAttemptCost $proposedCost -ProposedCostCurrency ([string](Get-ContractProperty $Request 'CurrencyTarget' 'USD')) `
                -ProposedCostUnknown $proposedUnknown -Purpose 'AI_ATTEMPT' `
                -Configuration $Configuration -ExchangeRate $null
            $limits = New-Object System.Collections.Generic.List[object]
            foreach ($l in @($(if ($null -ne $eval.ApplicableLimits) { $eval.ApplicableLimits } else { @() }))) {
                $limit = Get-ContractProperty $l 'Limit' $null
                $proj = Get-ContractProperty $l 'ProjectedSpend' $null
                $pct = if ($null -ne $limit -and [double]$limit -gt 0 -and $null -ne $proj) { ([double]$proj / [double]$limit) * 100.0 } else { $null }
                $limits.Add([pscustomobject]@{
                    Scope                  = [string](Get-ContractProperty $l 'Scope' '')
                    ScopeKey               = [string](Get-ContractProperty $l 'ScopeKey' '')
                    Limit                  = $limit
                    CurrentActualSpend     = Get-ContractProperty $l 'CurrentActualSpend' $null
                    ProjectedSpend         = $proj
                    EstimatedPercentConsumed = $pct
                    Decision               = [string](Get-ContractProperty $l 'Decision' '')
                    ReasonCodes            = @(Get-ContractProperty $l 'ReasonCodes' @())
                })
            }
            $budget = [pscustomobject]@{
                HasPolicy          = $true
                PolicyId           = [string](Get-ContractProperty $BudgetPolicy 'PolicyId' '')
                Currency           = [string](Get-ContractProperty $BudgetPolicy 'Currency' 'INR')
                Decision           = [string]$eval.Decision
                ReasonCodes        = @($eval.ReasonCodes)
                ApplicableLimits   = @($limits.ToArray())
                WarningThresholds  = @($eval.WarningThresholds)
                ProposedAttemptCost = $proposedCost
                ProposedCostUnknown = $proposedUnknown
                InformationalOnly  = $true
                OverrideAllowed    = $false
                Note               = 'INFORMATIONAL budget context only: the calculator never grants, modifies, or overrides a budget, and never executes an attempt.'
            }
        } catch {
            $budget = [pscustomobject]@{
                HasPolicy = $false
                InformationalOnly = $true
                OverrideAllowed = $false
                Note = 'budget context unavailable; the calculator never grants, modifies, or overrides a budget.'
            }
        }
    } else {
        $budget = [pscustomobject]@{
            HasPolicy     = $false
            InformationalOnly = $true
            OverrideAllowed = $false
            Note          = 'no budget policy supplied; budget context is informational only and the calculator never grants or overrides a budget.'
        }
    }

    $selectorData = New-DbM27SelectorData -Configuration $Configuration -NowUtc $nowUtc
    $guard = New-DbM27ReadOnlyGuard

    return New-DbM27CalculatorView -Request $Request -Scenario $scenario -Pricing $pricingBlock -Estimate $estimate `
        -Quality $quality -EscalationSteps @($escSteps.ToArray()) -EscalationTotal $escalationTotal `
        -Budget $budget -Guard $guard -SelectorData $selectorData -Warnings @($warnings.ToArray())
}

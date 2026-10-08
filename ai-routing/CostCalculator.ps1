# CostCalculator.ps1 — DB-M16 deterministic cost calculation engine.
#
# Calculates estimated and actual AI-attempt costs from a resolved DB-M15
# PricingRecord v1, then converts to the requested currency using effective-dated
# ExchangeRateRecord v1 evidence.
#
# RULES (hard):
#   - ALL price values come through the DB-M15 pricing catalogue. No rate is
#     embedded in this file.
#   - Time-band resolution is REUSED from DB-M15 (Resolve-AiPricingTimeBand via
#     Get-AiPriceAt). No time-band logic lives here.
#   - No provider-name branching. Provider semantics (reasoning billing) come
#     from the pricing record's resolved dimensions + DB-M16 calculator config,
#     never from a provider-name branch.
#   - Historic converted costs are reproducible: the same pricing record + the
#     same exchange-rate record yield the same historic cost. Later rate/price
#     changes never rewrite it.
#   - Does NOT execute an AI provider. No AI calls, no paid calls, no FX/network.
#
# Dot-source AiRoutingPricingFoundation.ps1 (DB-M14 + DB-M15),
# AiCostContracts.ps1, AiExchangeRates.ps1 first.

function ConvertTo-AiTokenCost {
    <#
    .SYNOPSIS
    Decimal-safe per-million-token cost: tokens / 1,000,000 * pricePerMillion.
    Returns $null when either input is unknown; 0 for an explicit zero token
    count. Uses [decimal] arithmetic (no floating-point drift).
    #>
    param($Tokens, $PricePerMillion)
    if ($null -eq $Tokens -or $null -eq $PricePerMillion) { return $null }
    $t = [decimal]$Tokens
    $p = [decimal]$PricePerMillion
    if ($t -le 0d) { return 0d }
    return ($t / 1000000d) * $p
}

function Get-AiPriceForCost {
    <#
    .SYNOPSIS
    Resolve the price record for a cost calculation using DB-M15 Get-AiPriceAt.
    - Explicit -PricingRecordIdOverride (authorized) uses that exact record, and
      verifies it matches the requested provider/model.
    - Otherwise the lookup is keyed on provider/model/timestamp/tier/band and
      resolves exactly one effective-dated record.
    Returns @{ PriceLookupStatus; Record; Message; TimeBand }.
    Only FOUND is usable for cost; NOT_FOUND/AMBIGUOUS/EXPIRED all mean "no
    effective record at this timestamp" for cost purposes.
    #>
    param(
        [AllowNull()][object]$Configuration,
        [string]$ProviderId,
        [string]$ModelId,
        $RequestTimestampUtc,
        [string]$ProcessingTier,
        [string]$TimeBand,
        [string]$PricingRecordIdOverride
    )
    $pricing = Get-ContractProperty $Configuration 'Pricing' $null
    $provId = $ProviderId.Trim().ToLowerInvariant()
    $mid = $ModelId.Trim().ToLowerInvariant()
    $tier = $ProcessingTier.Trim().ToUpperInvariant()
    $ts = ConvertTo-AiUtc $RequestTimestampUtc

    if ($PricingRecordIdOverride) {
        $rec = Get-AiPricingRecord -Catalogue $pricing -PricingRecordId $PricingRecordIdOverride
        if (-not $rec) {
            return @{ PriceLookupStatus = 'NOT_FOUND'; Record = $null; Message = "PricingRecordIdOverride '$PricingRecordIdOverride' not in the pricing catalogue"; TimeBand = $TimeBand }
        }
        if ($rec.ProviderId -ne $provId -or $rec.ModelId -ne $mid) {
            return @{ PriceLookupStatus = 'NOT_FOUND'; Record = $null; Message = "PricingRecordIdOverride '$PricingRecordIdOverride' does not match requested provider/model ($provId/$mid)"; TimeBand = $TimeBand }
        }
        $band = $TimeBand
        if (-not $band) { $band = Resolve-AiPricingTimeBand -ProviderId $provId -TimestampUtc $ts }
        return @{ PriceLookupStatus = 'FOUND'; Record = $rec; Message = "override record '$PricingRecordIdOverride' (authorized)"; TimeBand = $band }
    }

    $lookup = Get-AiPriceAt -Catalogue $pricing -ProviderId $provId -ModelId $mid `
        -TimestampUtc $ts -ProcessingTier $tier -TimeBand $TimeBand
    if ($null -eq $lookup) {
        return @{ PriceLookupStatus = 'NOT_FOUND'; Record = $null; Message = 'no price lookup result (catalogue empty?)'; TimeBand = $TimeBand }
    }
    return @{ PriceLookupStatus = $lookup.LookupState; Record = $lookup.Record; Message = $lookup.Message; TimeBand = $lookup.TimeBand }
}

function New-AiCostCalculationResult {
    <#
    .SYNOPSIS
    Build the CostCalculationResult v1 response. Single source of truth for the
    frozen output contract.
    #>
    param(
        [string]$ProviderId,
        [string]$ModelId,
        [string]$PricingRecordId,
        [string]$PricingCurrency,
        [string]$TimeBand,
        [string]$ProcessingTier,
        $RequestTimestampUtc,
        $InputTokens,
        $CachedInputTokens,
        $UncachedInputTokens,
        $CacheWrite5mTokens,
        $CacheWrite1hTokens,
        $OutputTokens,
        $ReasoningTokens,
        $ToolCalls,
        $InputCost,
        $CachedInputCost,
        $CacheWrite5mCost,
        $CacheWrite1hCost,
        $OutputCost,
        $ReasoningCost,
        $ToolCallCost,
        $OtherCost,
        $Subtotal,
        $ProviderCurrencyTotal,
        [string]$TargetCurrency,
        $ExchangeRate,
        [string]$ExchangeRateId,
        $ConvertedTotal,
        [string]$EstimatedOrActual,
        [string]$PriceLookupStatus,
        [string]$CalculationStatus,
        [string[]]$Warnings,
        $CalculatedAtUtc,
        $EstimatedCost,
        $ActualCost,
        [string]$CostCurrency
    )
    return [pscustomobject]@{
        SchemaVersion          = 1
        ProviderId             = $ProviderId
        ModelId                = $ModelId
        PricingRecordId        = $PricingRecordId
        PricingCurrency        = $PricingCurrency
        TimeBand               = $TimeBand
        ProcessingTier         = $ProcessingTier
        RequestTimestampUtc    = $RequestTimestampUtc
        InputTokens            = $InputTokens
        CachedInputTokens      = $CachedInputTokens
        UncachedInputTokens    = $UncachedInputTokens
        CacheWrite5mTokens     = $CacheWrite5mTokens
        CacheWrite1hTokens     = $CacheWrite1hTokens
        OutputTokens           = $OutputTokens
        ReasoningTokens        = $ReasoningTokens
        ToolCalls              = $ToolCalls
        InputCost              = $InputCost
        CachedInputCost        = $CachedInputCost
        CacheWrite5mCost       = $CacheWrite5mCost
        CacheWrite1hCost       = $CacheWrite1hCost
        OutputCost             = $OutputCost
        ReasoningCost          = $ReasoningCost
        ToolCallCost           = $ToolCallCost
        OtherCost              = $OtherCost
        Subtotal               = $Subtotal
        ProviderCurrencyTotal  = $ProviderCurrencyTotal
        TargetCurrency         = $TargetCurrency
        ExchangeRate           = $ExchangeRate
        ExchangeRateId         = $ExchangeRateId
        ConvertedTotal         = $ConvertedTotal
        EstimatedOrActual      = $EstimatedOrActual
        PriceLookupStatus      = $PriceLookupStatus
        CalculationStatus      = $CalculationStatus
        Warnings               = @($Warnings)
        CalculatedAtUtc        = $CalculatedAtUtc
        EstimatedCost          = $EstimatedCost
        ActualCost             = $ActualCost
        CostCurrency           = $CostCurrency
    }
}

function Calculate-AiAttemptCost {
    <#
    .SYNOPSIS
    Deterministic cost calculation for an AI attempt. Consumes a
    CostCalculationInput v1 against a Configuration (Pricing = DB-M15 catalogue,
    ExchangeRates = DB-M16 FX catalogue, CostConfig = DB-M16 calculator config).

    Estimated or actual is driven by UsageSource: PROVIDER_REPORTED -> ACTUAL,
    anything else -> ESTIMATED. Unknown usage never produces a fake cost
    (USAGE_INCOMPLETE). Statuses: COMPLETE / PARTIAL / PRICE_NOT_FOUND /
    PRICE_AMBIGUOUS / USAGE_INCOMPLETE / CURRENCY_CONVERSION_UNAVAILABLE /
    INVALID_USAGE.
    #>
    param(
        [AllowNull()][object]$Configuration,
        [AllowNull()][object]$CostInput
    )
    $now = [datetime]::UtcNow
    $warnings = New-Object System.Collections.Generic.List[string]

    # --- 1. input presence + validity --------------------------------------------
    if ($null -eq $CostInput) {
        return New-AiCostCalculationResult -ProviderId $null -ModelId $null -PricingRecordId $null `
            -PricingCurrency $null -TimeBand $null -ProcessingTier $null -RequestTimestampUtc $null `
            -EstimatedOrActual $null -PriceLookupStatus 'NONE' -CalculationStatus 'INVALID_USAGE' `
            -Warnings @('CostCalculationInput is missing') -CalculatedAtUtc $now
    }
    $tv = Test-AiCostCalculationInput $CostInput
    if (-not $tv.Valid) {
        return New-AiCostCalculationResult -ProviderId (Get-ContractProperty $CostInput 'ProviderId' $null) `
            -ModelId (Get-ContractProperty $CostInput 'ModelId' $null) -PricingRecordId $null `
            -PricingCurrency $null -TimeBand (Get-ContractProperty $CostInput 'TimeBand' $null) `
            -ProcessingTier (Get-ContractProperty $CostInput 'ProcessingTier' $null) `
            -RequestTimestampUtc (Get-ContractProperty $CostInput 'RequestTimestampUtc' $null) `
            -EstimatedOrActual $null -PriceLookupStatus 'NONE' -CalculationStatus 'INVALID_USAGE' `
            -Warnings @($tv.Errors) -CalculatedAtUtc $now
    }

    $providerId = Get-ContractProperty $CostInput 'ProviderId' ''
    $modelId = Get-ContractProperty $CostInput 'ModelId' ''
    $ts = ConvertTo-AiUtc (Get-ContractProperty $CostInput 'RequestTimestampUtc' $null)
    $tier = Get-ContractProperty $CostInput 'ProcessingTier' 'STANDARD'
    $explicitBand = Get-ContractProperty $CostInput 'TimeBand' $null
    $usageSource = Get-ContractProperty $CostInput 'UsageSource' $null
    $isActual = ($usageSource -eq 'PROVIDER_REPORTED')
    $mode = if ($isActual) { 'ACTUAL' } else { 'ESTIMATED' }

    # --- 2. price resolution (DB-M15) --------------------------------------------
    $priceRes = Get-AiPriceForCost -Configuration $Configuration -ProviderId $providerId -ModelId $modelId `
        -RequestTimestampUtc $ts -ProcessingTier $tier -TimeBand $explicitBand `
        -PricingRecordIdOverride (Get-ContractProperty $CostInput 'PricingRecordIdOverride' $null)
    $lookupStatus = $priceRes.PriceLookupStatus
    $bandUsed = $priceRes.TimeBand
    $rec = $priceRes.Record

    if ($lookupStatus -ne 'FOUND') {
        $st = if ($lookupStatus -eq 'AMBIGUOUS') { 'PRICE_AMBIGUOUS' } else { 'PRICE_NOT_FOUND' }
        return New-AiCostCalculationResult -ProviderId $providerId -ModelId $modelId -PricingRecordId $null `
            -PricingCurrency $null -TimeBand $bandUsed -ProcessingTier $tier -RequestTimestampUtc $ts `
            -EstimatedOrActual $mode -PriceLookupStatus $lookupStatus -CalculationStatus $st `
            -Warnings @($priceRes.Message) -CalculatedAtUtc $now
    }
    $pricingCurrency = $rec.Currency

    # --- 3. usage selection (estimated vs actual) ---------------------------------
    $u = @{ Input = $null; Cached = $null; Uncached = $null; Cw5 = $null; Cw1 = $null;
            Output = $null; Reasoning = $null; ToolCalls = $null; Images = $null; Audio = $null; Storage = $null }
    if ($isActual) {
        $u.Input      = Get-ContractProperty $CostInput 'InputTokens' $null
        $u.Cached     = Get-ContractProperty $CostInput 'CachedInputTokens' $null
        $u.Uncached   = Get-ContractProperty $CostInput 'UncachedInputTokens' $null
        $u.Cw5        = Get-ContractProperty $CostInput 'CacheWrite5mTokens' $null
        $u.Cw1        = Get-ContractProperty $CostInput 'CacheWrite1hTokens' $null
        $u.Output     = Get-ContractProperty $CostInput 'OutputTokens' $null
        $u.Reasoning  = Get-ContractProperty $CostInput 'ReasoningTokens' $null
        $u.ToolCalls  = Get-ContractProperty $CostInput 'ToolCalls' $null
        $u.Images     = Get-ContractProperty $CostInput 'Images' $null
        $u.Audio      = Get-ContractProperty $CostInput 'AudioUnits' $null
        $u.Storage    = Get-ContractProperty $CostInput 'StorageUnits' $null
    } else {
        $u.Input     = Get-ContractProperty $CostInput 'EstimatedInputTokens' $null
        $u.Cached    = Get-ContractProperty $CostInput 'EstimatedCachedInputTokens' $null
        $u.Output    = Get-ContractProperty $CostInput 'EstimatedOutputTokens' $null
    }

    $hasUsage = $false
    foreach ($k in $u.Keys) { if ($null -ne $u[$k]) { $hasUsage = $true; break } }
    if (-not $hasUsage) {
        return New-AiCostCalculationResult -ProviderId $providerId -ModelId $modelId `
            -PricingRecordId $rec.PricingRecordId -PricingCurrency $pricingCurrency -TimeBand $bandUsed `
            -ProcessingTier $tier -RequestTimestampUtc $ts -EstimatedOrActual $mode `
            -PriceLookupStatus $lookupStatus -CalculationStatus 'USAGE_INCOMPLETE' `
            -Warnings @("no usage dimensions provided for $mode cost") -CalculatedAtUtc $now
    }

    # --- 4. cached vs uncached split ---------------------------------------------
    $uncached = $u.Uncached
    if ($null -eq $uncached) {
        if ($null -ne $u.Input) {
            $uncached = if ($null -ne $u.Cached) { $u.Input - $u.Cached } else { $u.Input }
        }
    }
    # (CachedInputTokens <= InputTokens was validated by Test-AiCostCalculationInput)

    # --- 5. dimension costs (decimal, provider currency) --------------------------
    $partial = $false
    $inputCost  = ConvertTo-AiTokenCost $uncached $rec.InputPricePerMillion
    $cachedCost = ConvertTo-AiTokenCost $u.Cached $rec.CachedInputPricePerMillion
    $cw5Cost    = ConvertTo-AiTokenCost $u.Cw5 $rec.CacheWrite5mPricePerMillion
    $cw1Cost    = ConvertTo-AiTokenCost $u.Cw1 $rec.CacheWrite1hPricePerMillion

    $costConfig = Get-ContractProperty $Configuration 'CostConfig' $null
    $reasoningBilling = Get-ContractProperty $costConfig 'ReasoningTokenBilling' 'INCLUDED_IN_OUTPUT'
    $reasoningCost = $null
    if ($reasoningBilling -eq 'SEPARATE' -and $rec.ReasoningTokenPricePerMillion -ne $null) {
        $reasoningCost = ConvertTo-AiTokenCost $u.Reasoning $rec.ReasoningTokenPricePerMillion
    }
    $outputCost = ConvertTo-AiTokenCost $u.Output $rec.OutputPricePerMillion

    $toolCost = $null
    if ($u.ToolCalls -ne $null -and $rec.ToolCallPrice -ne $null) {
        $toolCost = [decimal]$u.ToolCalls * [decimal]$rec.ToolCallPrice
    }
    $otherCost = 0d
    if ($u.Images -ne $null -and $rec.ImagePrice -ne $null)   { $otherCost += [decimal]$u.Images * [decimal]$rec.ImagePrice }
    if ($u.Audio  -ne $null -and $rec.AudioPrice -ne $null)   { $otherCost += [decimal]$u.Audio  * [decimal]$rec.AudioPrice }
    if ($u.Storage -ne $null -and $rec.StoragePrice -ne $null) { $otherCost += [decimal]$u.Storage * [decimal]$rec.StoragePrice }

    # PARTIAL: a billable dimension is reported but its rate is null -> never silently zero
    $partialDims = @(
        @{ Usage = $uncached;  Price = $rec.InputPricePerMillion;        Dim = 'InputTokens(uncached)' }
        @{ Usage = $u.Cached;  Price = $rec.CachedInputPricePerMillion;  Dim = 'CachedInputTokens' }
        @{ Usage = $u.Cw5;     Price = $rec.CacheWrite5mPricePerMillion; Dim = 'CacheWrite5mTokens' }
        @{ Usage = $u.Cw1;     Price = $rec.CacheWrite1hPricePerMillion; Dim = 'CacheWrite1hTokens' }
        @{ Usage = $u.Output;  Price = $rec.OutputPricePerMillion;       Dim = 'OutputTokens' }
    )
    if ($reasoningBilling -eq 'SEPARATE') {
        $partialDims += @{ Usage = $u.Reasoning; Price = $rec.ReasoningTokenPricePerMillion; Dim = 'ReasoningTokens' }
    }
    $partialDims += @(
        @{ Usage = $u.ToolCalls; Price = $rec.ToolCallPrice; Dim = 'ToolCalls' }
        @{ Usage = $u.Images;    Price = $rec.ImagePrice;    Dim = 'Images' }
        @{ Usage = $u.Audio;     Price = $rec.AudioPrice;    Dim = 'AudioUnits' }
        @{ Usage = $u.Storage;   Price = $rec.StoragePrice;  Dim = 'StorageUnits' }
    )
    $partial = $false
    foreach ($pd in $partialDims) {
        if ($null -ne $pd.Usage -and $pd.Usage -gt 0 -and $null -eq $pd.Price) {
            $partial = $true
            $warnings.Add("usage dimension '$($pd.Dim)' ($($pd.Usage)) reported but no price in the resolved pricing record; cost not computed for it")
        }
    }

    $subtotal = 0d
    foreach ($c in @($inputCost, $cachedCost, $cw5Cost, $cw1Cost, $outputCost, $reasoningCost, $toolCost, $otherCost)) {
        if ($null -ne $c) { $subtotal += [decimal]$c }
    }

    # --- 6. provider-currency total (AdditionalMultiplier + MinimumCharge) --------
    $mult = $rec.AdditionalMultiplier; if ($null -eq $mult) { $mult = 1d }
    $minCharge = $rec.MinimumCharge; if ($null -eq $minCharge) { $minCharge = 0d }
    $providerTotal = [decimal]$subtotal * [decimal]$mult
    if ($providerTotal -lt [decimal]$minCharge) {
        $providerTotal = [decimal]$minCharge
        $warnings.Add("provider-currency total floored to MinimumCharge $minCharge")
    }

    # --- 7. currency conversion ---------------------------------------------------
    $target = Get-ContractProperty $CostInput 'CurrencyTarget' $null
    $callerRate = Get-ContractProperty $CostInput 'ExchangeRate' $null
    $fxUsed = $null; $fxId = $null; $converted = $null; $currencyUnavailable = $false
    $costCurrency = $pricingCurrency
    if ($target) {
        if ($target -eq $pricingCurrency) {
            $converted = $providerTotal
            $fxUsed = 1d
            $costCurrency = $target
        } else {
            if ($null -ne $callerRate -and $callerRate -gt 0) {
                $fxUsed = [decimal]$callerRate
            } else {
                $fx = Get-ContractProperty $Configuration 'ExchangeRates' $null
                $rateRec = Get-AiExchangeRateAt -Catalogue $fx -BaseCurrency $pricingCurrency -QuoteCurrency $target -TimestampUtc $ts
                if ($rateRec) { $fxUsed = [decimal]$rateRec.Rate; $fxId = $rateRec.ExchangeRateId }
            }
            if ($null -ne $fxUsed) {
                $converted = $providerTotal * $fxUsed
                $costCurrency = $target
            } else {
                $currencyUnavailable = $true
                $warnings.Add("currency conversion unavailable: no exchange-rate evidence for $pricingCurrency -> $target at request timestamp")
            }
        }
    } else {
        $converted = $providerTotal
    }

    # --- 8. calculation status precedence -----------------------------------------
    $status = 'COMPLETE'
    if ($partial) { $status = 'PARTIAL' }
    if ($currencyUnavailable) {
        if ($status -ne 'PARTIAL') { $status = 'CURRENCY_CONVERSION_UNAVAILABLE' }
        else { $warnings.Add('currency conversion unavailable; provider-currency cost is PARTIAL') }
    }

    # --- 9. reported totals for DB-M17 integration --------------------------------
    $reportedTotal = if ($null -ne $converted) { $converted } else { $providerTotal }
    $est = $null; $act = $null
    if ($mode -eq 'ESTIMATED') { $est = $reportedTotal } else { $act = $reportedTotal }

    return New-AiCostCalculationResult -ProviderId $providerId -ModelId $modelId `
        -PricingRecordId $rec.PricingRecordId -PricingCurrency $pricingCurrency -TimeBand $bandUsed `
        -ProcessingTier $tier -RequestTimestampUtc $ts `
        -InputTokens $u.Input -CachedInputTokens $u.Cached -UncachedInputTokens $uncached `
        -CacheWrite5mTokens $u.Cw5 -CacheWrite1hTokens $u.Cw1 -OutputTokens $u.Output `
        -ReasoningTokens $u.Reasoning -ToolCalls $u.ToolCalls `
        -InputCost $inputCost -CachedInputCost $cachedCost -CacheWrite5mCost $cw5Cost -CacheWrite1hCost $cw1Cost `
        -OutputCost $outputCost -ReasoningCost $reasoningCost -ToolCallCost $toolCost -OtherCost $otherCost `
        -Subtotal $subtotal -ProviderCurrencyTotal $providerTotal `
        -TargetCurrency $target -ExchangeRate $fxUsed -ExchangeRateId $fxId -ConvertedTotal $converted `
        -EstimatedOrActual $mode -PriceLookupStatus $lookupStatus -CalculationStatus $status `
        -Warnings @($warnings) -CalculatedAtUtc $now `
        -EstimatedCost $est -ActualCost $act -CostCurrency $costCurrency
}

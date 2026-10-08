# AiCostContracts.ps1 — DB-M16 cost + currency contracts.
#
# Deterministic cost calculation for future AI attempts (DB-M16), built on the
# DB-M15 pricing catalogue. DB-M16 NEVER executes a provider, never makes an AI
# call, never makes a paid call, and never makes an FX/network call.
#
# Contracts (all frozen v1):
#   - CostCalculationInput v1     (cost-calculation request)
#   - CostCalculationResult v1    (cost-calculation response)
#   - ExchangeRateRecord v1       (effective-dated FX evidence)
#   - CostVariance v1             (estimated vs actual variance)
#
# All price values come THROUGH the DB-M15 pricing catalogue. No rate is
# embedded here. Currency conversion supports USD->INR first and is generic
# enough for any base/quote pair. Historic converted costs are reproducible:
# same pricing record + same exchange-rate record = same historic cost.
#
# Dot-source AiRoutingPricingFoundation.ps1 (DB-M14 + DB-M15) first.

function Get-AiCostSchemaVersions {
    <#
    .SYNOPSIS
    Frozen schema versions for DB-M16 v1 contracts. Future incompatible changes
    introduce v2; v1 semantics are never silently mutated.

    Registered here (NOT in DB-M14/DB-M15 registries) so DB-M14/DB-M15 files
    stay byte-identical under parallel safety.
    #>
    return @{
        CostCalculationInputVersion  = 1
        CostCalculationResultVersion = 1
        ExchangeRateRecordVersion    = 1
        CostVarianceVersion          = 1
    }
}

function Get-AiCostStatuses {
    return @('COMPLETE', 'PARTIAL', 'PRICE_NOT_FOUND', 'PRICE_AMBIGUOUS', 'USAGE_INCOMPLETE', 'CURRENCY_CONVERSION_UNAVAILABLE', 'INVALID_USAGE')
}

function Get-AiUsageSources {
    return @('ESTIMATED', 'PROVIDER_REPORTED')
}

function Get-AiExchangeRateSources {
    return @('MANUAL_VERIFIED', 'CONFIGURED', 'FUTURE_PROVIDER_SYNC')
}

function Get-AiEstimatedOrActualValues {
    return @('ESTIMATED', 'ACTUAL')
}

function Test-IsValidCostStatus([string]$Value)          { $Value -in (Get-AiCostStatuses) }
function Test-IsValidUsageSource([string]$Value)         { $Value -in (Get-AiUsageSources) }
function Test-IsValidExchangeRateSource([string]$Value)  { $Value -in (Get-AiExchangeRateSources) }

# --- secret-value guard (DB-M16) ---------------------------------------------------

function Test-AiCostSecretValueLeak {
    <#
    .SYNOPSIS
    DB-M16 secret-value leak guard. Wraps the DB-M14 guard and additionally
    exempts cost/FX fields that legitimately hold identifiers, numeric rates, or
    reference metadata. Cost/FX configs hold RATES and NAMES, never credentials.
    #>
    param(
        [AllowNull()][object]$Target
    )
    $costExempt = @(
        'TaskId', 'AttemptId', 'ProviderId', 'ModelId', 'CurrencyTarget',
        'ExchangeRate', 'PricingRecordIdOverride', 'ExchangeRateId', 'BaseCurrency',
        'QuoteCurrency', 'Source', 'VerifiedAtUtc', 'EffectiveAtUtc', 'EffectiveToUtc',
        'RequestTimestampUtc', 'ProcessingTier', 'TimeBand', 'Notes',
        'PricingRecordId', 'PricingCurrency', 'TargetCurrency', 'CalculatedAtUtc',
        'SchemaVersion', 'UsageSource', 'EstimatedOrActual', 'CalculationStatus',
        'PriceLookupStatus', 'Warnings', 'CostCurrency', 'ExchangeRateIdUsed',
        'ReasoningTokenBilling'
    )
    $base = Test-AiRoutingSecretValueLeak $Target
    if (-not $base.Leak) { return @{ Leak = $false; Fields = @() } }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($base.Fields)) {
        $name = ($entry -split ' = ')[0]
        if ($name -in $costExempt) { continue }
        $kept.Add($entry)
    }
    return @{ Leak = ($kept.Count -gt 0); Fields = @($kept) }
}

# --- CostCalculationInput v1 -------------------------------------------------------

function New-AiCostCalculationInput {
    <#
    .SYNOPSIS
    Build a normalized cost-calculation input (schemaVersion 1).

    Actual usage dimensions: InputTokens, CachedInputTokens, UncachedInputTokens,
    CacheWrite5mTokens, CacheWrite1hTokens, OutputTokens, ReasoningTokens,
    ToolCalls, Images, AudioUnits, StorageUnits.
    Estimated usage dimensions (estimation path): EstimatedInputTokens,
    EstimatedCachedInputTokens, EstimatedOutputTokens.

    All token/unit fields are NULLABLE — unknown stays null. Unknown is never
    treated as zero unless the calculation semantics explicitly require it.

    UsageSource drives EstimatedOrActual: 'PROVIDER_REPORTED' -> ACTUAL;
    anything else -> ESTIMATED.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$TaskId,
        [string]$AttemptId,
        [string]$ProviderId,
        [string]$ModelId,
        $RequestTimestampUtc = $null,
        [string]$ProcessingTier = 'STANDARD',
        [string]$TimeBand,
        [Nullable[long]]$InputTokens,
        [Nullable[long]]$CachedInputTokens,
        [Nullable[long]]$UncachedInputTokens,
        [Nullable[long]]$CacheWrite5mTokens,
        [Nullable[long]]$CacheWrite1hTokens,
        [Nullable[long]]$OutputTokens,
        [Nullable[long]]$ReasoningTokens,
        [Nullable[long]]$ToolCalls,
        [Nullable[long]]$Images,
        [Nullable[long]]$AudioUnits,
        [Nullable[long]]$StorageUnits,
        [Nullable[long]]$EstimatedInputTokens,
        [Nullable[long]]$EstimatedCachedInputTokens,
        [Nullable[long]]$EstimatedOutputTokens,
        [string]$CurrencyTarget,
        [Nullable[decimal]]$ExchangeRate,
        [string]$PricingRecordIdOverride,
        [string]$UsageSource
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }

    $providerId = if ($InputObject) { & $g 'ProviderId' $ProviderId } else { $ProviderId }
    $modelId    = if ($InputObject) { & $g 'ModelId' $ModelId } else { $ModelId }
    if (-not $providerId) { throw "New-AiCostCalculationInput: ProviderId is required" }
    if (-not $modelId) { throw "New-AiCostCalculationInput: ModelId is required" }
    $providerId = $providerId.Trim().ToLowerInvariant()
    $modelId = $modelId.Trim().ToLowerInvariant()

    $ts = if ($InputObject) { & $g 'RequestTimestampUtc' $RequestTimestampUtc } else { $RequestTimestampUtc }
    if (-not $ts) { throw "New-AiCostCalculationInput: RequestTimestampUtc is required" }

    $tier = if ($InputObject) { & $g 'ProcessingTier' $ProcessingTier } else { $ProcessingTier }
    if (-not $tier) { $tier = 'STANDARD' }
    $tier = $tier.Trim().ToUpperInvariant()
    $band = if ($InputObject) { & $g 'TimeBand' $TimeBand } else { $TimeBand }
    if ($band) { $band = $band.Trim().ToUpperInvariant() }

    $currencyTarget = if ($InputObject) { & $g 'CurrencyTarget' $CurrencyTarget } else { $CurrencyTarget }
    if ($currencyTarget) { $currencyTarget = $currencyTarget.Trim().ToUpperInvariant() }

    $usageSource = if ($InputObject) { & $g 'UsageSource' $UsageSource } else { $UsageSource }
    if ($usageSource) { $usageSource = $usageSource.Trim().ToUpperInvariant() }

    return [pscustomobject]@{
        SchemaVersion          = 1
        TaskId                 = if ($InputObject) { & $g 'TaskId' $TaskId } else { $TaskId }
        AttemptId              = if ($InputObject) { & $g 'AttemptId' $AttemptId } else { $AttemptId }
        ProviderId             = $providerId
        ModelId                = $modelId
        RequestTimestampUtc    = $ts
        ProcessingTier         = $tier
        TimeBand               = $band
        InputTokens            = if ($InputObject) { & $g 'InputTokens' $InputTokens } else { $InputTokens }
        CachedInputTokens      = if ($InputObject) { & $g 'CachedInputTokens' $CachedInputTokens } else { $CachedInputTokens }
        UncachedInputTokens    = if ($InputObject) { & $g 'UncachedInputTokens' $UncachedInputTokens } else { $UncachedInputTokens }
        CacheWrite5mTokens     = if ($InputObject) { & $g 'CacheWrite5mTokens' $CacheWrite5mTokens } else { $CacheWrite5mTokens }
        CacheWrite1hTokens     = if ($InputObject) { & $g 'CacheWrite1hTokens' $CacheWrite1hTokens } else { $CacheWrite1hTokens }
        OutputTokens           = if ($InputObject) { & $g 'OutputTokens' $OutputTokens } else { $OutputTokens }
        ReasoningTokens        = if ($InputObject) { & $g 'ReasoningTokens' $ReasoningTokens } else { $ReasoningTokens }
        ToolCalls              = if ($InputObject) { & $g 'ToolCalls' $ToolCalls } else { $ToolCalls }
        Images                 = if ($InputObject) { & $g 'Images' $Images } else { $Images }
        AudioUnits             = if ($InputObject) { & $g 'AudioUnits' $AudioUnits } else { $AudioUnits }
        StorageUnits           = if ($InputObject) { & $g 'StorageUnits' $StorageUnits } else { $StorageUnits }
        EstimatedInputTokens   = if ($InputObject) { & $g 'EstimatedInputTokens' $EstimatedInputTokens } else { $EstimatedInputTokens }
        EstimatedCachedInputTokens = if ($InputObject) { & $g 'EstimatedCachedInputTokens' $EstimatedCachedInputTokens } else { $EstimatedCachedInputTokens }
        EstimatedOutputTokens  = if ($InputObject) { & $g 'EstimatedOutputTokens' $EstimatedOutputTokens } else { $EstimatedOutputTokens }
        CurrencyTarget         = $currencyTarget
        ExchangeRate           = if ($InputObject) { & $g 'ExchangeRate' $ExchangeRate } else { $ExchangeRate }
        PricingRecordIdOverride = if ($InputObject) { & $g 'PricingRecordIdOverride' $PricingRecordIdOverride } else { $PricingRecordIdOverride }
        UsageSource            = $usageSource
    }
}

function Test-AiCostCalculationInput {
    <#
    .SYNOPSIS
    Deterministically validate a CostCalculationInput v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][object]$CostInput)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $CostInput) { return @{ Valid = $false; Errors = @('input is null'); Warnings = @() } }
    if ((Get-ContractProperty $CostInput 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    $providerId = Get-ContractProperty $CostInput 'ProviderId' ''
    if (-not $providerId) { $errors.Add('ProviderId required') }
    $modelId = Get-ContractProperty $CostInput 'ModelId' ''
    if (-not $modelId) { $errors.Add('ModelId required') }

    $ts = Get-ContractProperty $CostInput 'RequestTimestampUtc' $null
    if (-not $ts) { $errors.Add('RequestTimestampUtc required') }
    else {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$ts, [ref]$d)) { $errors.Add("RequestTimestampUtc '$ts' not a parseable date") }
    }

    $tier = Get-ContractProperty $CostInput 'ProcessingTier' 'STANDARD'
    if ($tier -and -not (Test-IsValidProcessingTier $tier)) { $errors.Add("ProcessingTier '$tier' invalid") }
    $band = Get-ContractProperty $CostInput 'TimeBand' $null
    if ($band -and -not (Test-IsValidTimeBand $band)) { $errors.Add("TimeBand '$band' invalid") }

    $currencyTarget = Get-ContractProperty $CostInput 'CurrencyTarget' $null
    if ($currencyTarget -and $currencyTarget -notmatch '^[A-Z]{3}$') { $errors.Add("CurrencyTarget '$currencyTarget' must be ISO-4217 (3 uppercase letters)") }

    # negative usage / units rejected
    $longDims = @(
        'InputTokens', 'CachedInputTokens', 'UncachedInputTokens', 'CacheWrite5mTokens',
        'CacheWrite1hTokens', 'OutputTokens', 'ReasoningTokens', 'ToolCalls',
        'Images', 'AudioUnits', 'StorageUnits',
        'EstimatedInputTokens', 'EstimatedCachedInputTokens', 'EstimatedOutputTokens'
    )
    foreach ($d in $longDims) {
        $v = Get-ContractProperty $CostInput $d $null
        if ($null -ne $v -and $v -lt 0) { $errors.Add("$d must be >= 0 (found $v)") }
    }

    # cached input must be a subset of total input (where both known)
    $inTot = Get-ContractProperty $CostInput 'InputTokens' $null
    $inCached = Get-ContractProperty $CostInput 'CachedInputTokens' $null
    if ($null -ne $inTot -and $null -ne $inCached -and $inCached -gt $inTot) {
        $errors.Add("CachedInputTokens ($inCached) exceeds InputTokens ($inTot)")
    }

    $fxRate = Get-ContractProperty $CostInput 'ExchangeRate' $null
    if ($null -ne $fxRate -and $fxRate -le 0) { $errors.Add("ExchangeRate must be > 0 (found $fxRate)") }

    $override = Get-ContractProperty $CostInput 'PricingRecordIdOverride' $null
    if ($override -and $override -notmatch '^[A-Za-z0-9._\-]{1,120}$') { $errors.Add("PricingRecordIdOverride '$override' invalid") }

    $usageSource = Get-ContractProperty $CostInput 'UsageSource' $null
    if ($usageSource -and -not (Test-IsValidUsageSource $usageSource)) {
        $warnings.Add("UsageSource '$usageSource' not in vocabulary ($((Get-AiUsageSources) -join ', ')); treated as ESTIMATED")
    }

    $leak = Test-AiCostSecretValueLeak $CostInput
    if ($leak.Leak) { $errors.Add("secret value detected in cost input: $($leak.Fields -join '; ')") }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @($warnings) }
}

# --- ExchangeRateRecord v1 ---------------------------------------------------------

function New-AiExchangeRateRecord {
    <#
    .SYNOPSIS
    Build a normalized effective-dated exchange-rate record (schemaVersion 1).
    Window semantics match pricing: [EffectiveAtUtc, EffectiveToUtc) — from
    inclusive, to exclusive, null to = open-ended. Historic converted costs stay
    reproducible because the rate used at the attempt timestamp is recorded and
    later rate changes never rewrite it.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$ExchangeRateId,
        [string]$BaseCurrency,
        [string]$QuoteCurrency,
        [Nullable[decimal]]$Rate,
        $EffectiveAtUtc = $null,
        $EffectiveToUtc = $null,
        [string]$Source = 'CONFIGURED',
        [string]$VerifiedAtUtc,
        [bool]$ManualOverride = $false,
        [string]$Notes
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }

    $id = if ($InputObject) { & $g 'ExchangeRateId' $ExchangeRateId } else { $ExchangeRateId }
    if (-not $id) { throw "New-AiExchangeRateRecord: ExchangeRateId is required" }
    $id = $id.Trim()

    $base = if ($InputObject) { & $g 'BaseCurrency' $BaseCurrency } else { $BaseCurrency }
    $quote = if ($InputObject) { & $g 'QuoteCurrency' $QuoteCurrency } else { $QuoteCurrency }
    if (-not $base -or -not $quote) { throw "New-AiExchangeRateRecord: BaseCurrency and QuoteCurrency are required" }
    $base = $base.Trim().ToUpperInvariant()
    $quote = $quote.Trim().ToUpperInvariant()

    $rate = if ($InputObject) { & $g 'Rate' $Rate } else { $Rate }
    if ($null -eq $rate) { throw "New-AiExchangeRateRecord: Rate is required" }

    $effAt = if ($InputObject) { & $g 'EffectiveAtUtc' $EffectiveAtUtc } else { $EffectiveAtUtc }
    if (-not $effAt) { throw "New-AiExchangeRateRecord: EffectiveAtUtc is required" }
    $effTo = if ($InputObject) { & $g 'EffectiveToUtc' $EffectiveToUtc } else { $EffectiveToUtc }
    if ($effTo -is [string] -and [string]::IsNullOrWhiteSpace($effTo)) { $effTo = $null }

    $src = if ($InputObject) { & $g 'Source' $Source } else { $Source }
    if (-not $src) { $src = 'CONFIGURED' }

    return [pscustomobject]@{
        SchemaVersion   = 1
        ExchangeRateId  = $id
        BaseCurrency    = $base
        QuoteCurrency   = $quote
        Rate            = $rate
        EffectiveAtUtc  = $effAt
        EffectiveToUtc  = $effTo
        Source          = $src
        VerifiedAtUtc   = if ($InputObject) { & $g 'VerifiedAtUtc' $VerifiedAtUtc } else { $VerifiedAtUtc }
        ManualOverride  = if ($InputObject) { [bool](& $g 'ManualOverride' $ManualOverride) } else { $ManualOverride }
        Notes           = if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }
    }
}

function Test-AiExchangeRateRecord {
    <#
    .SYNOPSIS
    Deterministically validate one ExchangeRateRecord v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([pscustomobject]$Record)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Record) { return @{ Valid = $false; Errors = @('Record is null'); Warnings = @() } }

    $id = Get-ContractProperty $Record 'ExchangeRateId' ''
    if (-not $id) { $errors.Add('ExchangeRateId required') }
    elseif ($id -notmatch '^[A-Za-z0-9._\-]{1,120}$') { $errors.Add("ExchangeRateId '$id' invalid") }
    if ((Get-ContractProperty $Record 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    $base = Get-ContractProperty $Record 'BaseCurrency' ''
    $quote = Get-ContractProperty $Record 'QuoteCurrency' ''
    if (-not $base -or $base -notmatch '^[A-Z]{3}$') { $errors.Add("BaseCurrency '$base' must be ISO-4217 (3 uppercase letters)") }
    if (-not $quote -or $quote -notmatch '^[A-Z]{3}$') { $errors.Add("QuoteCurrency '$quote' must be ISO-4217 (3 uppercase letters)") }
    if ($base -and $quote -and $base -eq $quote) { $errors.Add("BaseCurrency and QuoteCurrency must differ (base=$base quote=$quote)") }

    $rate = Get-ContractProperty $Record 'Rate' $null
    if ($null -eq $rate) { $errors.Add('Rate required') }
    elseif ($rate -le 0) { $errors.Add("Rate must be > 0 (found $rate)") }

    $dAt = [datetime]::MinValue; $dTo = [datetime]::MaxValue
    $effAt = Get-ContractProperty $Record 'EffectiveAtUtc' ''
    $effTo = Get-ContractProperty $Record 'EffectiveToUtc' $null
    $atOk = $false; $toOk = $false
    if (-not $effAt) { $errors.Add('EffectiveAtUtc required') }
    elseif (-not [datetime]::TryParse([string]$effAt, [ref]$dAt)) { $errors.Add("EffectiveAtUtc '$effAt' not a parseable date") }
    else { $atOk = $true }
    if ($effTo) {
        if (-not [datetime]::TryParse([string]$effTo, [ref]$dTo)) { $errors.Add("EffectiveToUtc '$effTo' not a parseable date") }
        else { $toOk = $true }
    }
    if ($atOk -and $toOk -and (ConvertTo-AiUtc $effAt) -ge (ConvertTo-AiUtc $effTo)) {
        $errors.Add('EffectiveAtUtc must be < EffectiveToUtc')
    }

    $src = Get-ContractProperty $Record 'Source' 'CONFIGURED'
    if ($src -and -not (Test-IsValidExchangeRateSource $src)) {
        $warnings.Add("Source '$src' not in vocabulary ($((Get-AiExchangeRateSources) -join ', '))")
    }

    $leak = Test-AiCostSecretValueLeak $Record
    if ($leak.Leak) { $errors.Add("secret value detected in exchange-rate record: $($leak.Fields -join '; ')") }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @($warnings) }
}

# --- CostVariance v1 ---------------------------------------------------------------

function New-AiCostVariance {
    <#
    .SYNOPSIS
    Build a CostVariance v1 comparing an estimated and an actual cost.
      AbsoluteVariance   = |Actual - Estimated|
      PercentageVariance = (Actual - Estimated) / Estimated * 100   (signed, %)
    A zero or missing estimate leaves PercentageVariance null (division by zero
    is never produced). Missing actual/estimate leaves variance null.
    #>
    param(
        [Nullable[decimal]]$EstimatedCost,
        [Nullable[decimal]]$ActualCost,
        [string]$Notes
    )
    $abs = $null; $pct = $null
    if ($null -ne $EstimatedCost -and $null -ne $ActualCost) {
        $abs = [Math]::Abs([decimal]$ActualCost - [decimal]$EstimatedCost)
        if ([decimal]$EstimatedCost -ne 0d) {
            $pct = ([decimal]$ActualCost - [decimal]$EstimatedCost) / [decimal]$EstimatedCost * 100d
        }
    }
    return [pscustomobject]@{
        SchemaVersion     = 1
        EstimatedCost     = $EstimatedCost
        ActualCost        = $ActualCost
        AbsoluteVariance  = $abs
        PercentageVariance = $pct
        Notes             = $Notes
    }
}

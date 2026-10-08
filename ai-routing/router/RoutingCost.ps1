# RoutingCost.ps1 -- DB-M19 STEP 3 (cost estimation via the DB-M16 engine).
#
# This layer NEVER re-implements pricing math. It builds a DB-M16
# CostCalculationInput v1 from the requirement/context/assumptions and delegates
# to Calculate-AiAttemptCost (DB-M16) against the DB-M16 Configuration (pricing
# catalogue = DB-M15, FX = DB-M16, CostConfig = DB-M16). An unknown price is
# surfaced as COST_UNKNOWN with a label -- never an invented price.

. (Join-Path $PSScriptRoot "..\AiRoutingContracts.ps1")   # DB-M14 vocab + helpers (READ-ONLY)
. (Join-Path $PSScriptRoot "..\AiCostContracts.ps1")      # DB-M16 input contract (READ-ONLY)
. (Join-Path $PSScriptRoot "RoutingEligibility.ps1")

function Get-AiCandidateCostEstimate {
    <#
    .SYNOPSIS
    STEP 3. Estimate the current attempt cost for one eligible model route using
    the DB-M16 engine (Calculate-AiAttemptCost). Estimation inputs are derived
    from the requirement's mandatory context and expected output, the assumed
    cached-input fraction, the processing tier, time band and timestamp; currency
    target defaults to INR (converted via the DB-M16 FX catalogue).
    Returns @{ Result; EstimatedCost; CostCurrency; CostUnknown; PricingRecordId;
               PriceLookupStatus; CalculationStatus; PriceStatus; MandatoryContextTokens;
               CachedInputTokens; UncachedInputTokens; OutputTokens; Message }.
    #>
    param(
        [AllowNull()][pscustomobject]$Model,
        [AllowNull()][object]$Requirement,
        [AllowNull()][object]$Configuration,
        [AllowNull()][object]$ContextBudget,
        [AllowNull()][object]$ContextPackage,
        [AllowNull()]$RequestTimestampUtc,
        [string]$ProcessingTier = 'STANDARD',
        [string]$TimeBand,
        [double]$CachedInputFraction = 0.0,
        [string]$TargetCurrency = 'INR',
        [AllowNull()][Nullable[decimal]]$ExchangeRate,
        [string]$PricingRecordIdOverride
    )
    $ts = $RequestTimestampUtc
    if ($null -eq $ts) { $ts = [datetime]::UtcNow }
    $ts = ConvertTo-AiUtc $ts
    # DB-M16 validates the stored timestamp by stringifying it with the HOST
    # culture; a DateTime would render as 'MM/dd/yyyy HH:mm:ss' and can fail
    # TryParse on dd/MM/yyyy cultures. Hand it the culture-independent ISO-8601
    # UTC round-trip string so the price lookup is deterministic on any host.
    $tsString = if ($ts -is [datetime]) {
        $ts.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    } else {
        [string]$ts
    }

    $inputTokens = Get-DbM19MandatoryContextTokens -Requirement $Requirement -ContextBudget $ContextBudget -ContextPackage $ContextPackage
    $outputTokens = Get-ContractProperty $Requirement 'ExpectedOutputTokens' $null

    $warning = $null
    if ($null -eq $inputTokens -and $null -eq $outputTokens) {
        return @{
            Result = $null
            EstimatedCost = $null
            CostCurrency = $null
            CostUnknown = $true
            PricingRecordId = $null
            PriceLookupStatus = 'NONE'
            CalculationStatus = 'USAGE_INCOMPLETE'
            PriceStatus = $null
            MandatoryContextTokens = $null
            CachedInputTokens = $null
            UncachedInputTokens = $null
            OutputTokens = $null
            Message = 'no usage dimensions to estimate (mandatory context and expected output both unknown)'
        }
    }

    $cached = $null
    $uncached = $null
    if ($null -ne $inputTokens) {
        $fraction = [double]$CachedInputFraction
        if ($fraction -lt 0) { $fraction = 0 }
        if ($fraction -gt 1) { $fraction = 1 }
        $cached = [long][math]::Round([double]$inputTokens * $fraction)
        if ($cached -gt [long]$inputTokens) { $cached = [long]$inputTokens }
        $uncached = [long]$inputTokens - $cached
    }

    $providerId = Get-ContractProperty $Model 'ProviderId' ''
    $modelId = Get-ContractProperty $Model 'ModelId' ''

    $costInput = New-AiCostCalculationInput -ProviderId $providerId -ModelId $modelId `
        -RequestTimestampUtc $tsString -ProcessingTier $ProcessingTier -TimeBand $TimeBand `
        -EstimatedInputTokens $inputTokens -EstimatedCachedInputTokens $cached `
        -EstimatedOutputTokens $outputTokens -CurrencyTarget $TargetCurrency `
        -ExchangeRate $ExchangeRate -PricingRecordIdOverride $PricingRecordIdOverride `
        -UsageSource 'ESTIMATED'

    $result = Calculate-AiAttemptCost -Configuration $Configuration -CostInput $costInput

    $lookupStatus = Get-ContractProperty $result 'PriceLookupStatus' $null
    $calcStatus = Get-ContractProperty $result 'CalculationStatus' $null
    $est = Get-ContractProperty $result 'EstimatedCost' $null
    $currency = Get-ContractProperty $result 'CostCurrency' $null
    $pricingRecordId = Get-ContractProperty $result 'PricingRecordId' $null

    $costUnknown = $false
    if ($lookupStatus -ne 'FOUND' -or $null -eq $est) { $costUnknown = $true }
    if ($calcStatus -in @('PRICE_NOT_FOUND','PRICE_AMBIGUOUS','USAGE_INCOMPLETE','CURRENCY_CONVERSION_UNAVAILABLE','INVALID_USAGE')) { $costUnknown = $true }

    # price record status (DB-M15 CURRENT/NEEDS_REVIEW/...): informational label
    $priceStatus = $null
    if (-not $costUnknown -and $pricingRecordId) {
        $pricing = Get-ContractProperty $Configuration 'Pricing' $null
        $rec = Get-AiPricingRecord -Catalogue $pricing -PricingRecordId $pricingRecordId
        if ($rec) {
            $st = Get-AiPricingRecordStatus -Record $rec -AsOfUtc $ts
            $priceStatus = $st.Status
        }
    }

    $warnings = @(Get-ContractProperty $result 'Warnings' @())
    $message = $null
    if ($costUnknown) {
        $message = "cost unknown: price lookup '$lookupStatus' / calculation '$calcStatus'"
    } else {
        $message = "estimated attempt cost $est $currency (price status $priceStatus)"
    }
    if ($warnings.Count -gt 0) { $message += '; warnings: ' + ($warnings -join ' | ') }

    return @{
        Result                = $result
        EstimatedCost         = if ($costUnknown) { $null } else { $est }
        CostCurrency          = if ($costUnknown) { $null } else { $currency }
        CostUnknown           = $costUnknown
        PricingRecordId       = $pricingRecordId
        PriceLookupStatus     = $lookupStatus
        CalculationStatus     = $calcStatus
        PriceStatus           = $priceStatus
        MandatoryContextTokens = $inputTokens
        CachedInputTokens     = $cached
        UncachedInputTokens   = $uncached
        OutputTokens          = $outputTokens
        Message               = $message
    }
}

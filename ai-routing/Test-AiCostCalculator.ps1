# Test-AiCostCalculator.ps1 — DB-M16 self-contained assertion suite.
#
# Proves the deterministic cost calculator + currency conversion WITHOUT any
# paid API call, network access, FX/API call, or credential use. All fixtures
# are in-memory (DB-M15 local catalogue loaded from config, plus hand-built
# pricing/FX records for versioning and defence cases).
#
# Coverage: schema v1, input/record validation, token-cost matrix (14 scenarios
# across DeepSeek / Claude / OpenAI / Gemini), effective-dated pricing (historic
# OLD rate, NEW rate after change, future version never rewrites old cost),
# DeepSeek time-band boundaries (6 points, reusing the DB-M15 resolver),
# cached/uncached split without double billing, cache write (5m/1h), reasoning
# billing (INCLUDED vs SEPARATE), tool/media/storage other-cost, estimated vs
# actual, USAGE_INCOMPLETE, PRICE_NOT_FOUND / PRICE_AMBIGUOUS / EXPIRED defence,
# PricingRecordIdOverride, FX (decimal exactness, historic reproducibility,
# missing rate -> CURRENCY_CONVERSION_UNAVAILABLE, later rate never mutates
# historic evidence), CostVariance v1, partial-cost -> PARTIAL with warning,
# foundation validation, and a no-network/no-credential scan of the cost libs.
#
# Run: powershell -NoProfile -File ai-routing\Test-AiCostCalculator.ps1
# Exit code: 0 all pass, 1 any failure.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "AiRoutingCostFoundation.ps1")

$script:Results = @()
$script:Fails = New-Object System.Collections.Generic.List[string]

function Assert-True([string]$label, [bool]$cond, [string]$detail) {
    $row = New-Object PSCustomObject
    $row | Add-Member NoteProperty -Name Scenario -Value $label
    $row | Add-Member NoteProperty -Name Pass -Value $cond
    $row | Add-Member NoteProperty -Name Detail -Value $detail
    $script:Results += $row
    if (-not $cond) {
        $script:Fails.Add(("{0}: {1}" -f $label, $detail))
        Write-Output ("  [FAIL] {0} - {1}" -f $label, $detail)
    } else {
        Write-Output ("  [PASS] {0} - {1}" -f $label, $detail)
    }
}

function Assert-Near([string]$label, [object]$actual, [object]$expected, [double]$tolerance, [string]$detail) {
    if ($null -eq $actual) { Assert-True $label $false "actual is null (expected ~$expected) $detail"; return }
    $d = [Math]::Abs([double]$actual - [double]$expected)
    Assert-True $label ($d -le $tolerance) "$detail (actual=$actual expected~$expected)"
}

Write-Output "== DB-M16 Cost Calculator + Currency Conversion test suite =="

# --- loaded configuration (DB-M15 local catalogue + DB-M16 configs) -----------------
$cfg = Import-AiCostConfiguration

# --- A. schema + contract validation ------------------------------------------------
$sv = Get-AiCostSchemaVersions
Assert-True "schema versions all v1" ($sv.CostCalculationInputVersion -eq 1 -and $sv.CostCalculationResultVersion -eq 1 -and $sv.ExchangeRateRecordVersion -eq 1 -and $sv.CostVarianceVersion -eq 1) "CostCalculationInput/Result, ExchangeRateRecord, CostVariance all 1"
Assert-True "status vocabulary" ((Get-AiCostStatuses).Count -eq 7 -and 'COMPLETE' -in (Get-AiCostStatuses) -and 'CURRENCY_CONVERSION_UNAVAILABLE' -in (Get-AiCostStatuses) -and 'INVALID_USAGE' -in (Get-AiCostStatuses)) "7 statuses incl. COMPLETE/PARTIAL/CURRENCY_CONVERSION_UNAVAILABLE/INVALID_USAGE"

$tvNeg = Test-AiCostCalculationInput ([pscustomobject]@{ SchemaVersion=1; ProviderId='deepseek'; ModelId='deepseek-v4-flash'; RequestTimestampUtc='2026-08-31T00:30:00Z'; InputTokens=-5; OutputTokens=100 })
Assert-True "input validation: negative tokens rejected" (-not $tvNeg.Valid -and ($tvNeg.Errors -match 'InputTokens must be >= 0')) "Errors: $($tvNeg.Errors -join '; ')"

$tvCache = Test-AiCostCalculationInput ([pscustomobject]@{ SchemaVersion=1; ProviderId='deepseek'; ModelId='deepseek-v4-flash'; RequestTimestampUtc='2026-08-31T00:30:00Z'; InputTokens=100; CachedInputTokens=500 })
Assert-True "input validation: cached > input rejected" (-not $tvCache.Valid -and ($tvCache.Errors -match 'CachedInputTokens')) "Errors: $($tvCache.Errors -join '; ')"

$tvProv = Test-AiCostCalculationInput ([pscustomobject]@{ SchemaVersion=1; ModelId='deepseek-v4-flash'; RequestTimestampUtc='2026-08-31T00:30:00Z' })
Assert-True "input validation: missing ProviderId rejected" (-not $tvProv.Valid -and ($tvProv.Errors -match 'ProviderId')) "Errors: $($tvProv.Errors -join '; ')"

$tvTs = Test-AiCostCalculationInput ([pscustomobject]@{ SchemaVersion=1; ProviderId='deepseek'; ModelId='deepseek-v4-flash'; RequestTimestampUtc='not-a-date' })
Assert-True "input validation: invalid timestamp rejected" (-not $tvTs.Valid -and ($tvTs.Errors -match 'RequestTimestampUtc')) "Errors: $($tvTs.Errors -join '; ')"

$tvFx = Test-AiExchangeRateRecord ([pscustomobject]@{ SchemaVersion=1; ExchangeRateId='bad'; BaseCurrency='USD'; QuoteCurrency='USD'; Rate=1.0; EffectiveAtUtc='2026-01-01T00:00:00Z' })
Assert-True "fx record: base==quote rejected" (-not $tvFx.Valid -and ($tvFx.Errors -match 'must differ')) "Errors: $($tvFx.Errors -join '; ')"

$tvFxNeg = Test-AiExchangeRateRecord ([pscustomobject]@{ SchemaVersion=1; ExchangeRateId='bad2'; BaseCurrency='USD'; QuoteCurrency='INR'; Rate=-1.0; EffectiveAtUtc='2026-01-01T00:00:00Z' })
Assert-True "fx record: negative rate rejected" (-not $tvFxNeg.Valid -and ($tvFxNeg.Errors -match 'Rate must be > 0')) "Errors: $($tvFxNeg.Errors -join '; ')"

# --- B. exchange-rate catalogue (loaded fixtures) -----------------------------------
$fv = Validate-AiExchangeRateCatalogue -Catalogue $cfg.ExchangeRates
Assert-True "loaded FX catalogue valid" ($fv.Valid -and $fv.Overlaps.Count -eq 0 -and $fv.Gaps.Count -eq 0) "Errors: $($fv.Errors -join '; '), Gaps: $($fv.Gaps.Count)"

$fxHist = Get-AiExchangeRateAt -Catalogue $cfg.ExchangeRates -BaseCurrency 'USD' -QuoteCurrency 'INR' -TimestampUtc '2026-03-15T12:00:00Z'
Assert-True "FX historic window resolves v1" ($fxHist.ExchangeRateId -eq 'fx-usdinr-dev-v1' -and [decimal]$fxHist.Rate -eq 75.0d) "id=$($fxHist.ExchangeRateId) rate=$($fxHist.Rate)"

$fxCur = Get-AiExchangeRateAt -Catalogue $cfg.ExchangeRates -BaseCurrency 'USD' -QuoteCurrency 'INR' -TimestampUtc '2026-06-15T12:00:00Z'
Assert-True "FX current window resolves v2" ($fxCur.ExchangeRateId -eq 'fx-usdinr-dev-v2' -and [decimal]$fxCur.Rate -eq 83.5d) "id=$($fxCur.ExchangeRateId) rate=$($fxCur.Rate)"

$fxBound = Get-AiExchangeRateAt -Catalogue $cfg.ExchangeRates -BaseCurrency 'USD' -QuoteCurrency 'INR' -TimestampUtc '2026-06-01T00:00:00Z'
Assert-True "FX boundary [start,end) switches at exactly 2026-06-01" ($fxBound.ExchangeRateId -eq 'fx-usdinr-dev-v2') "id=$($fxBound.ExchangeRateId)"

$fxNone = Get-AiExchangeRateAt -Catalogue $cfg.ExchangeRates -BaseCurrency 'USD' -QuoteCurrency 'GBP' -TimestampUtc '2026-08-31T00:30:00Z'
$fxNoneDetail = if ($fxNone) { $fxNone.ExchangeRateId } else { 'null' }
Assert-True "FX missing pair resolves none" ($null -eq $fxNone) "expected null, got $fxNoneDetail"

# overlap detection (unvalidated catalogue must be reported, never silently resolved)
$fxOv = @{}
Add-AiExchangeRate -Catalogue $fxOv -Record (New-AiExchangeRateRecord -ExchangeRateId 'ov-1' -BaseCurrency 'USD' -QuoteCurrency 'EUR' -Rate 0.9 -EffectiveAtUtc '2026-01-01T00:00:00Z' -Source 'CONFIGURED') | Out-Null
Add-AiExchangeRate -Catalogue $fxOv -Record (New-AiExchangeRateRecord -ExchangeRateId 'ov-2' -BaseCurrency 'USD' -QuoteCurrency 'EUR' -Rate 0.8 -EffectiveAtUtc '2026-03-01T00:00:00Z' -Source 'CONFIGURED') | Out-Null
$fxOvV = Validate-AiExchangeRateCatalogue -Catalogue $fxOv
Assert-True "FX overlapping windows flagged as errors" (-not $fxOvV.Valid -and $fxOvV.Overlaps.Count -eq 1 -and $fxOvV.Errors -match 'Overlap') "Errors: $($fxOvV.Errors -join '; ')"
$fxAmb = Get-AiExchangeRateAt -Catalogue $fxOv -BaseCurrency 'USD' -QuoteCurrency 'EUR' -TimestampUtc '2026-04-01T00:00:00Z'
Assert-True "FX ambiguous lookup fails safe (never silently picks)" ($null -eq $fxAmb) "expected null on ambiguity"

# --- C. token-cost matrix (14 scenarios, seed catalogue, actual usage) --------------
# Assert-only helper: emits assertions to stdout, returns nothing (so callers never
# capture the assertion stream into a variable).
function Assert-CostScenario {
    param(
        [string]$Label,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$Ts,
        [double]$ExpProviderTotal,
        [string]$ExpBand,
        [string]$ExpRecordId,
        [hashtable]$Usage = @{},
        [string]$Tier = 'STANDARD',
        [hashtable]$ExpDims = @{},
        [hashtable]$ExpFields = @{},
        [string[]]$ExpNullFields = @(),
        [string]$Detail = ''
    )
    $inArgs = @{
        ProviderId = $ProviderId; ModelId = $ModelId; RequestTimestampUtc = $Ts
        ProcessingTier = $Tier; UsageSource = 'PROVIDER_REPORTED'
    }
    foreach ($k in $Usage.Keys) { $inArgs[$k] = $Usage[$k] }
    $in = New-AiCostCalculationInput @inArgs
    $r = Calculate-AiAttemptCost -Configuration $cfg -CostInput $in
    Assert-True "cost $Label : status COMPLETE" ($r.CalculationStatus -eq 'COMPLETE') "got $($r.CalculationStatus), warnings: $($r.Warnings -join '; ')"
    Assert-Near "cost $Label : provider total" $r.ProviderCurrencyTotal $ExpProviderTotal 0.0000001d "got $($r.ProviderCurrencyTotal)"
    Assert-True "cost $Label : time band $ExpBand" ($r.TimeBand -eq $ExpBand) "got $($r.TimeBand)"
    Assert-True "cost $Label : pricing record $ExpRecordId" ($r.PricingRecordId -eq $ExpRecordId) "got $($r.PricingRecordId)"
    foreach ($k in $ExpDims.Keys) {
        Assert-Near "cost $Label : $k" $r.$k $ExpDims[$k] 0.0000001d "got $($r.$k)"
    }
    foreach ($k in $ExpFields.Keys) {
        Assert-True "cost $Label : $k == $($ExpFields[$k])" ($r.$k -eq $ExpFields[$k]) "got $($r.$k)"
    }
    foreach ($k in $ExpNullFields) {
        Assert-True "cost $Label : $k null" ($null -eq $r.$k) "got $($r.$k)"
    }
}

# 1. DeepSeek v4 Flash OFF_PEAK
Assert-CostScenario 'flash OFF_PEAK' 'deepseek' 'deepseek-v4-flash' '2026-08-31T00:30:00Z' 0.198 'OFF_PEAK' 'ds-v4flash-offpeak-20260830' @{ InputTokens = 600000; OutputTokens = 100000 } -ExpDims @{ InputCost = 0.132; OutputCost = 0.066 }

# 2. DeepSeek v4 Flash PEAK
Assert-CostScenario 'flash PEAK' 'deepseek' 'deepseek-v4-flash' '2026-08-31T08:00:00Z' 0.396 'PEAK' 'ds-v4flash-peak-20260830' @{ InputTokens = 600000; OutputTokens = 100000 } -ExpDims @{ InputCost = 0.264; OutputCost = 0.132 }

# 3. DeepSeek v4 Flash cached input (1M input / 400K cached -> 600K uncached + 400K cached)
Assert-CostScenario 'flash cached input' 'deepseek' 'deepseek-v4-flash' '2026-08-31T00:30:00Z' 0.2008 'OFF_PEAK' 'ds-v4flash-offpeak-20260830' @{ InputTokens = 1000000; CachedInputTokens = 400000; OutputTokens = 100000 } -ExpDims @{ InputCost = 0.132; CachedInputCost = 0.0028; Subtotal = 0.2008 } -ExpFields @{ UncachedInputTokens = 600000 }

# 4. DeepSeek v4 Flash output only
Assert-CostScenario 'flash output only' 'deepseek' 'deepseek-v4-flash' '2026-08-31T00:30:00Z' 0.066 'OFF_PEAK' 'ds-v4flash-offpeak-20260830' @{ OutputTokens = 100000 } -ExpNullFields @('InputTokens')

# 5. DeepSeek v4 Pro OFF_PEAK
Assert-CostScenario 'pro OFF_PEAK' 'deepseek' 'deepseek-v4-pro' '2026-08-31T00:30:00Z' 0.165 'OFF_PEAK' 'ds-v4pro-offpeak-20260830' @{ InputTokens = 100000; OutputTokens = 50000 }

# 6. DeepSeek v4 Pro PEAK
Assert-CostScenario 'pro PEAK' 'deepseek' 'deepseek-v4-pro' '2026-08-31T08:00:00Z' 0.33 'PEAK' 'ds-v4pro-peak-20260830' @{ InputTokens = 100000; OutputTokens = 50000 }

# 7. Claude Sonnet 5 standard (normal)
Assert-CostScenario 'claude normal' 'anthropic' 'claude-sonnet-5' '2026-08-31T12:00:00Z' 1.2 'DEFAULT' 'anthropic-claude-sonnet-5-standard-20260830' @{ InputTokens = 100000; OutputTokens = 100000 }

# 8. Claude cache read
Assert-CostScenario 'claude cache read' 'anthropic' 'claude-sonnet-5' '2026-08-31T12:00:00Z' 1.38 'DEFAULT' 'anthropic-claude-sonnet-5-standard-20260830' @{ InputTokens = 1000000; CachedInputTokens = 900000; OutputTokens = 100000 } -ExpDims @{ CachedInputCost = 0.18 }

# 9. Claude 5m cache write
Assert-CostScenario 'claude 5m write' 'anthropic' 'claude-sonnet-5' '2026-08-31T12:00:00Z' 1.7 'DEFAULT' 'anthropic-claude-sonnet-5-standard-20260830' @{ InputTokens = 100000; CacheWrite5mTokens = 200000; OutputTokens = 100000 } -ExpDims @{ CacheWrite5mCost = 0.5 }

# 10. Claude 1h cache write
Assert-CostScenario 'claude 1h write' 'anthropic' 'claude-sonnet-5' '2026-08-31T12:00:00Z' 2.0 'DEFAULT' 'anthropic-claude-sonnet-5-standard-20260830' @{ InputTokens = 100000; CacheWrite1hTokens = 200000; OutputTokens = 100000 } -ExpDims @{ CacheWrite1hCost = 0.8 }

# 11. OpenAI gpt-5.4 input+output
Assert-CostScenario 'openai input/output' 'openai' 'gpt-5.4' '2026-08-31T12:00:00Z' 1.75 'DEFAULT' 'openai-gpt-5.4-standard-20260830' @{ InputTokens = 100000; OutputTokens = 100000 }

# 12. OpenAI gpt-5.4 cached input
Assert-CostScenario 'openai cached' 'openai' 'gpt-5.4' '2026-08-31T12:00:00Z' 2.875 'DEFAULT' 'openai-gpt-5.4-standard-20260830' @{ InputTokens = 1000000; CachedInputTokens = 500000; OutputTokens = 100000 }

# 13. OpenAI output only
Assert-CostScenario 'openai output only' 'openai' 'gpt-5.4' '2026-08-31T12:00:00Z' 1.5 'DEFAULT' 'openai-gpt-5.4-standard-20260830' @{ OutputTokens = 100000 }

# 14. Gemini economical profile (FLEX processing tier, effective through 2026-12-31)
Assert-CostScenario 'gemini FLEX profile' 'gemini' 'gemini-economical' '2026-08-31T12:00:00Z' 0.225 'DEFAULT' 'gemini-economical-flex-20260830' @{ InputTokens = 100000; OutputTokens = 100000 } -Tier 'FLEX'

# --- D. time-band boundaries (DeepSeek, reusing DB-M15 resolver) ---------------------
foreach ($point in @(
    @{ Ts = '2026-08-31T01:00:00Z';  Band = 'PEAK' },
    @{ Ts = '2026-08-31T03:59:59Z'; Band = 'PEAK' },
    @{ Ts = '2026-08-31T04:00:00Z'; Band = 'OFF_PEAK' },
    @{ Ts = '2026-08-31T06:00:00Z'; Band = 'PEAK' },
    @{ Ts = '2026-08-31T09:59:59Z'; Band = 'PEAK' },
    @{ Ts = '2026-08-31T10:00:00Z'; Band = 'OFF_PEAK' }
)) {
    $inTb = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc $point.Ts -InputTokens 100000 -OutputTokens 100000 -UsageSource 'PROVIDER_REPORTED'
    $rTb = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inTb
    Assert-True "time band $($point.Ts) -> $($point.Band)" ($rTb.TimeBand -eq $point.Band) "got $($rTb.TimeBand)"
    $expRec = if ($point.Band -eq 'PEAK') { 'ds-v4flash-peak-20260830' } else { 'ds-v4flash-offpeak-20260830' }
    Assert-True "time band $($point.Ts) record" ($rTb.PricingRecordId -eq $expRec) "got $($rTb.PricingRecordId)"
}

# --- E. effective-dated pricing (in-memory versioned catalogue) ----------------------
$pEff = @{}
$v1 = New-AiPricingRecord -PricingRecordId 'eff-v1' -ProviderId 'acme' -ModelId 'm1' -EffectiveFromUtc '2026-08-01T00:00:00Z' -EffectiveToUtc $null -TimeBand 'DEFAULT' -InputPricePerMillion 0.10 -OutputPricePerMillion 0.30 -Source 'reference'
Add-AiPricingRecord -Catalogue $pEff -Record $v1 | Out-Null
$cfgEff = @{ Pricing = $pEff; ExchangeRates = $null; CostConfig = $null }

function Invoke-EffCost([string]$ts) {
    $in = New-AiCostCalculationInput -ProviderId 'acme' -ModelId 'm1' -RequestTimestampUtc $ts -InputTokens 100000 -OutputTokens 100000 -UsageSource 'PROVIDER_REPORTED'
    return (Calculate-AiAttemptCost -Configuration $cfgEff -CostInput $in)
}
$rEff1 = Invoke-EffCost '2026-08-15T12:00:00Z'
Assert-Near "effective dating: historic OLD rate" $rEff1.ProviderCurrencyTotal 0.04 0.0000001d "got $($rEff1.ProviderCurrencyTotal)"
Assert-True "effective dating: historic record v1" ($rEff1.PricingRecordId -eq 'eff-v1') "got $($rEff1.PricingRecordId)"

$v2 = New-AiPricingRecord -PricingRecordId 'eff-v2' -ProviderId 'acme' -ModelId 'm1' -EffectiveFromUtc '2026-09-01T00:00:00Z' -TimeBand 'DEFAULT' -InputPricePerMillion 0.20 -OutputPricePerMillion 0.60 -Source 'reference'
Add-AiPriceVersion -Catalogue $pEff -Record $v2 -ClosePredecessor | Out-Null

$rEff2 = Invoke-EffCost '2026-09-15T12:00:00Z'
Assert-Near "effective dating: NEW rate after change" $rEff2.ProviderCurrencyTotal 0.08 0.0000001d "got $($rEff2.ProviderCurrencyTotal)"
Assert-True "effective dating: post-change record v2" ($rEff2.PricingRecordId -eq 'eff-v2') "got $($rEff2.PricingRecordId)"

# historic untouched by v2's addition
$rEff1b = Invoke-EffCost '2026-08-15T12:00:00Z'
Assert-Near "effective dating: historic still OLD after v2" $rEff1b.ProviderCurrencyTotal 0.04 0.0000001d "got $($rEff1b.ProviderCurrencyTotal)"

$v3 = New-AiPricingRecord -PricingRecordId 'eff-v3' -ProviderId 'acme' -ModelId 'm1' -EffectiveFromUtc '2026-10-01T00:00:00Z' -TimeBand 'DEFAULT' -InputPricePerMillion 0.30 -OutputPricePerMillion 0.90 -Source 'reference'
Add-AiPriceVersion -Catalogue $pEff -Record $v3 -ClosePredecessor | Out-Null

$rEff3 = Invoke-EffCost '2026-11-15T12:00:00Z'
Assert-Near "effective dating: newest rate" $rEff3.ProviderCurrencyTotal 0.12 0.0000001d "got $($rEff3.ProviderCurrencyTotal)"
$rEff1c = Invoke-EffCost '2026-08-15T12:00:00Z'
$rEff2c = Invoke-EffCost '2026-09-15T12:00:00Z'
Assert-Near "effective dating: future version never changes old cost (v1)" $rEff1c.ProviderCurrencyTotal 0.04 0.0000001d "got $($rEff1c.ProviderCurrencyTotal)"
Assert-Near "effective dating: future version never changes old cost (v2)" $rEff2c.ProviderCurrencyTotal 0.08 0.0000001d "got $($rEff2c.ProviderCurrencyTotal)"

# --- F. price lookup defence --------------------------------------------------------
$inFut = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-01-01T00:00:00Z' -InputTokens 100 -OutputTokens 100 -UsageSource 'PROVIDER_REPORTED'
$rFut = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inFut
Assert-True "price lookup: future-only timestamp -> PRICE_NOT_FOUND" ($rFut.CalculationStatus -eq 'PRICE_NOT_FOUND') "got $($rFut.CalculationStatus)"

$inExp = New-AiCostCalculationInput -ProviderId 'gemini' -ModelId 'gemini-economical' -RequestTimestampUtc '2028-06-01T12:00:00Z' -ProcessingTier 'FLEX' -InputTokens 100 -OutputTokens 100 -UsageSource 'PROVIDER_REPORTED'
$rExp = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inExp
Assert-True "price lookup: lapsed window -> EXPIRED maps to PRICE_NOT_FOUND" ($rExp.CalculationStatus -eq 'PRICE_NOT_FOUND' -and $rExp.PriceLookupStatus -eq 'EXPIRED') "status=$($rExp.CalculationStatus) lookup=$($rExp.PriceLookupStatus)"

# AMBIGUOUS: two overlapping effective records injected directly (invalid catalogue)
$pAmb = @{}
Add-AiPricingRecord -Catalogue $pAmb -Record (New-AiPricingRecord -PricingRecordId 'amb-1' -ProviderId 'acme' -ModelId 'm1' -EffectiveFromUtc '2026-01-01T00:00:00Z' -TimeBand 'DEFAULT' -InputPricePerMillion 1.0 -OutputPricePerMillion 4.0 -Source 'reference') | Out-Null
$pAmb['amb-2'] = New-AiPricingRecord -PricingRecordId 'amb-2' -ProviderId 'acme' -ModelId 'm1' -EffectiveFromUtc '2026-06-01T00:00:00Z' -TimeBand 'DEFAULT' -InputPricePerMillion 2.0 -OutputPricePerMillion 8.0 -Source 'reference'
$cfgAmb = @{ Pricing = $pAmb; ExchangeRates = $null; CostConfig = $null }
$inAmb = New-AiCostCalculationInput -ProviderId 'acme' -ModelId 'm1' -RequestTimestampUtc '2026-09-01T12:00:00Z' -InputTokens 100 -OutputTokens 100 -UsageSource 'PROVIDER_REPORTED'
$rAmb = Calculate-AiAttemptCost -Configuration $cfgAmb -CostInput $inAmb
Assert-True "price lookup: AMBIGUOUS never silently chosen" ($rAmb.CalculationStatus -eq 'PRICE_AMBIGUOUS') "got $($rAmb.CalculationStatus), lookup=$($rAmb.PriceLookupStatus)"

# --- G. PricingRecordIdOverride -----------------------------------------------------
$inOv = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-08-31T00:30:00Z' -InputTokens 100000 -OutputTokens 100000 -UsageSource 'PROVIDER_REPORTED' -PricingRecordIdOverride 'ds-v4flash-peak-20260830'
$rOv = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inOv
Assert-True "override: uses exact record at OFF_PEAK time" ($rOv.PricingRecordId -eq 'ds-v4flash-peak-20260830' -and [Math]::Abs([double]$rOv.InputCost - 0.044) -le 0.0000001) "record=$($rOv.PricingRecordId) inputCost=$($rOv.InputCost)"

$inOvBad = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-08-31T00:30:00Z' -InputTokens 100 -OutputTokens 100 -UsageSource 'PROVIDER_REPORTED' -PricingRecordIdOverride 'anthropic-claude-sonnet-5-standard-20260830'
$rOvBad = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inOvBad
Assert-True "override: mismatched provider/model -> PRICE_NOT_FOUND" ($rOvBad.CalculationStatus -eq 'PRICE_NOT_FOUND') "got $($rOvBad.CalculationStatus)"

# --- H. estimated vs actual ---------------------------------------------------------
$inEst = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-08-31T00:30:00Z' -EstimatedInputTokens 600000 -EstimatedOutputTokens 100000 -UsageSource 'ESTIMATED'
$rEst = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inEst
Assert-True "estimate: labeled ESTIMATED" ($rEst.EstimatedOrActual -eq 'ESTIMATED') "got $($rEst.EstimatedOrActual)"
Assert-Near "estimate: estimated cost populated" $rEst.EstimatedCost 0.198 0.0000001d "got $($rEst.EstimatedCost)"
Assert-True "estimate: actual cost null" ($null -eq $rEst.ActualCost) "got $($rEst.ActualCost)"

$inAct = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-08-31T00:30:00Z' -InputTokens 600000 -OutputTokens 100000 -UsageSource 'PROVIDER_REPORTED'
$rAct = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inAct
Assert-True "actual: labeled ACTUAL" ($rAct.EstimatedOrActual -eq 'ACTUAL') "got $($rAct.EstimatedOrActual)"
Assert-Near "actual: actual cost populated" $rAct.ActualCost 0.198 0.0000001d "got $($rAct.ActualCost)"
Assert-True "actual: estimated cost null" ($null -eq $rAct.EstimatedCost) "got $($rAct.EstimatedCost)"

# --- I. reasoning billing -----------------------------------------------------------
# INCLUDED_IN_OUTPUT (default config): reasoning is covered by output, never double-charged
$inReas = New-AiCostCalculationInput -ProviderId 'anthropic' -ModelId 'claude-sonnet-5' -RequestTimestampUtc '2026-08-31T12:00:00Z' -InputTokens 100000 -OutputTokens 100000 -ReasoningTokens 20000 -UsageSource 'PROVIDER_REPORTED'
$rReas = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inReas
Assert-True "reasoning INCLUDED: no separate reasoning charge" ($null -eq $rReas.ReasoningCost) "got $($rReas.ReasoningCost)"
Assert-Near "reasoning INCLUDED: output cost covers reasoning" $rReas.OutputCost 1.0 0.0000001d "got $($rReas.OutputCost)"
Assert-True "reasoning INCLUDED: status COMPLETE" ($rReas.CalculationStatus -eq 'COMPLETE') "got $($rReas.CalculationStatus)"

# SEPARATE config (in-memory record with a reasoning price)
$pSep = @{}
Add-AiPricingRecord -Catalogue $pSep -Record (New-AiPricingRecord -PricingRecordId 'cl-reas' -ProviderId 'anthropic' -ModelId 'claude-sonnet-5' -EffectiveFromUtc '2026-08-30T00:00:00Z' -TimeBand 'DEFAULT' -InputPricePerMillion 2.0 -CachedInputPricePerMillion 0.2 -OutputPricePerMillion 10.0 -ReasoningTokenPricePerMillion 1.5 -Source 'reference') | Out-Null
$cfgSep = @{ Pricing = $pSep; ExchangeRates = $null; CostConfig = [pscustomobject]@{ schemaVersion = 1; ReasoningTokenBilling = 'SEPARATE' } }
$rSep = Calculate-AiAttemptCost -Configuration $cfgSep -CostInput $inReas
Assert-Near "reasoning SEPARATE: reasoning cost charged" $rSep.ReasoningCost 0.03 0.0000001d "got $($rSep.ReasoningCost)"
Assert-Near "reasoning SEPARATE: subtotal includes reasoning" $rSep.Subtotal 1.23 0.0000001d "got $($rSep.Subtotal)"
Assert-True "reasoning SEPARATE: status COMPLETE" ($rSep.CalculationStatus -eq 'COMPLETE') "got $($rSep.CalculationStatus)"

# --- J. tool/media/storage other-cost + PARTIAL -------------------------------------
$inTool = New-AiCostCalculationInput -ProviderId 'openai' -ModelId 'gpt-5.4' -RequestTimestampUtc '2026-08-31T12:00:00Z' -InputTokens 100000 -OutputTokens 100000 -ToolCalls 5 -UsageSource 'PROVIDER_REPORTED'
$rTool = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inTool
Assert-True "partial: tool usage with null rate -> PARTIAL" ($rTool.CalculationStatus -eq 'PARTIAL') "got $($rTool.CalculationStatus)"
Assert-True "partial: warning names the missing dimension" (($rTool.Warnings -join ' ') -match 'ToolCalls') "warnings: $($rTool.Warnings -join '; ')"
Assert-True "partial: tool cost not silently zeroed" ($null -eq $rTool.ToolCallCost) "got $($rTool.ToolCallCost)"
Assert-Near "partial: priced dims still computed" $rTool.Subtotal 1.75 0.0000001d "got $($rTool.Subtotal)"

# non-token charges when priced (in-memory record with ToolCallPrice + ImagePrice)
$pMedia = @{}
Add-AiPricingRecord -Catalogue $pMedia -Record (New-AiPricingRecord -PricingRecordId 'media-1' -ProviderId 'acme' -ModelId 'm1' -EffectiveFromUtc '2026-01-01T00:00:00Z' -TimeBand 'DEFAULT' -InputPricePerMillion 1.0 -OutputPricePerMillion 4.0 -ToolCallPrice 0.005 -ImagePrice 0.01 -Source 'reference') | Out-Null
$cfgMedia = @{ Pricing = $pMedia; ExchangeRates = $null; CostConfig = $null }
$inMedia = New-AiCostCalculationInput -ProviderId 'acme' -ModelId 'm1' -RequestTimestampUtc '2026-08-31T12:00:00Z' -InputTokens 100000 -OutputTokens 100000 -ToolCalls 3 -Images 2 -UsageSource 'PROVIDER_REPORTED'
$rMedia = Calculate-AiAttemptCost -Configuration $cfgMedia -CostInput $inMedia
Assert-Near "non-token: tool call cost" $rMedia.ToolCallCost 0.015 0.0000001d "got $($rMedia.ToolCallCost)"
Assert-Near "non-token: image cost" $rMedia.OtherCost 0.02 0.0000001d "got $($rMedia.OtherCost)"
Assert-Near "non-token: subtotal includes other cost" $rMedia.Subtotal 0.535 0.0000001d "got $($rMedia.Subtotal)"
Assert-True "non-token: status COMPLETE" ($rMedia.CalculationStatus -eq 'COMPLETE') "got $($rMedia.CalculationStatus)"

# --- K. USAGE_INCOMPLETE ------------------------------------------------------------
$inNoUsage = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-08-31T00:30:00Z' -UsageSource 'PROVIDER_REPORTED'
$rNoUsage = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inNoUsage
Assert-True "unknown usage: no actual dims -> USAGE_INCOMPLETE" ($rNoUsage.CalculationStatus -eq 'USAGE_INCOMPLETE') "got $($rNoUsage.CalculationStatus)"

$inNoEst = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-08-31T00:30:00Z' -UsageSource 'ESTIMATED'
$rNoEst = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inNoEst
Assert-True "unknown usage: no estimated dims -> USAGE_INCOMPLETE" ($rNoEst.CalculationStatus -eq 'USAGE_INCOMPLETE') "got $($rNoEst.CalculationStatus)"

# --- L. currency conversion ---------------------------------------------------------
# exact decimal result: 0.198 USD x 83.5 = 16.533 INR (v2, current window)
$inFx = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-08-31T00:30:00Z' -InputTokens 600000 -OutputTokens 100000 -UsageSource 'PROVIDER_REPORTED' -CurrencyTarget 'INR'
$rFx = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inFx
Assert-True "fx: conversion COMPLETE" ($rFx.CalculationStatus -eq 'COMPLETE') "got $($rFx.CalculationStatus)"
Assert-True "fx: decimal exact result 16.533" ([decimal]$rFx.ConvertedTotal -eq 16.533d) "got $($rFx.ConvertedTotal)"
Assert-True "fx: rate 83.5 used from v2" ([decimal]$rFx.ExchangeRate -eq 83.5d -and $rFx.ExchangeRateId -eq 'fx-usdinr-dev-v2') "rate=$($rFx.ExchangeRate) id=$($rFx.ExchangeRateId)"
Assert-True "fx: cost currency INR" ($rFx.CostCurrency -eq 'INR') "got $($rFx.CostCurrency)"
Assert-True "fx: pricing currency USD preserved" ($rFx.PricingCurrency -eq 'USD') "got $($rFx.PricingCurrency)"

# historic reproducibility: same record + same rate record = same historic cost.
# Seed pricing starts 2026-08-30, so the historic window needs an in-memory pricing
# record effective from 2026-01-01 (covering the FX v1 window [2026-01-01, 2026-06-01)).
$pFx = @{}
Add-AiPricingRecord -Catalogue $pFx -Record (New-AiPricingRecord -PricingRecordId 'pfx-1' -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -EffectiveFromUtc '2026-01-01T00:00:00Z' -TimeBand 'DEFAULT' -InputPricePerMillion 0.22 -OutputPricePerMillion 0.66 -Source 'reference') | Out-Null
$cfgFx = @{ Pricing = $pFx; ExchangeRates = $cfg.ExchangeRates; CostConfig = $null }
$inFxHist = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-03-15T12:00:00Z' -InputTokens 600000 -OutputTokens 100000 -UsageSource 'PROVIDER_REPORTED' -CurrencyTarget 'INR'
$rFxHist = Calculate-AiAttemptCost -Configuration $cfgFx -CostInput $inFxHist
Assert-True "fx historic: v1 rate 75.0 used" ([decimal]$rFxHist.ExchangeRate -eq 75.0d -and $rFxHist.ExchangeRateId -eq 'fx-usdinr-dev-v1') "rate=$($rFxHist.ExchangeRate) id=$($rFxHist.ExchangeRateId)"
Assert-True "fx historic: decimal 14.85" ([decimal]$rFxHist.ConvertedTotal -eq 14.85d) "got $($rFxHist.ConvertedTotal)"

# missing rate -> provider-currency cost still valid, conversion unavailable
$inFxMiss = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-08-31T00:30:00Z' -InputTokens 600000 -OutputTokens 100000 -UsageSource 'PROVIDER_REPORTED' -CurrencyTarget 'GBP'
$rFxMiss = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inFxMiss
Assert-True "fx missing: CURRENCY_CONVERSION_UNAVAILABLE" ($rFxMiss.CalculationStatus -eq 'CURRENCY_CONVERSION_UNAVAILABLE') "got $($rFxMiss.CalculationStatus)"
Assert-Near "fx missing: provider-currency cost still valid" $rFxMiss.ProviderCurrencyTotal 0.198 0.0000001d "got $($rFxMiss.ProviderCurrencyTotal)"
Assert-True "fx missing: no invented rate" ($null -eq $rFxMiss.ConvertedTotal -and $null -eq $rFxMiss.ExchangeRate) "converted=$($rFxMiss.ConvertedTotal)"

# caller-supplied ExchangeRate override is authorized
$inFxOv = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-08-31T00:30:00Z' -InputTokens 600000 -OutputTokens 100000 -UsageSource 'PROVIDER_REPORTED' -CurrencyTarget 'INR' -ExchangeRate 74.5
$rFxOv = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inFxOv
Assert-True "fx override: caller rate 74.5 honored" ([decimal]$rFxOv.ExchangeRate -eq 74.5d -and [decimal]$rFxOv.ConvertedTotal -eq 14.751d) "rate=$($rFxOv.ExchangeRate) converted=$($rFxOv.ConvertedTotal)"

# target == pricing currency -> identity conversion
$inFxUsd = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc '2026-08-31T00:30:00Z' -InputTokens 600000 -OutputTokens 100000 -UsageSource 'PROVIDER_REPORTED' -CurrencyTarget 'USD'
$rFxUsd = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inFxUsd
Assert-True "fx identity: USD->USD 1.0" ([decimal]$rFxUsd.ExchangeRate -eq 1.0d -and [decimal]$rFxUsd.ConvertedTotal -eq 0.198d) "rate=$($rFxUsd.ExchangeRate) converted=$($rFxUsd.ConvertedTotal)"

# later rate change never mutates historic evidence (in-memory FX catalogue)
$fxMut = @{}
Add-AiExchangeRate -Catalogue $fxMut -Record (New-AiExchangeRateRecord -ExchangeRateId 'fx-mut-1' -BaseCurrency 'USD' -QuoteCurrency 'INR' -Rate 75.0 -EffectiveAtUtc '2026-01-01T00:00:00Z' -EffectiveToUtc '2026-06-01T00:00:00Z' -Source 'CONFIGURED') | Out-Null
Add-AiExchangeRate -Catalogue $fxMut -Record (New-AiExchangeRateRecord -ExchangeRateId 'fx-mut-2' -BaseCurrency 'USD' -QuoteCurrency 'INR' -Rate 83.5 -EffectiveAtUtc '2026-06-01T00:00:00Z' -EffectiveToUtc '2026-09-01T00:00:00Z' -Source 'CONFIGURED') | Out-Null
$cfgMut = @{ Pricing = $pFx; ExchangeRates = $fxMut; CostConfig = $null }
function Invoke-FxCost([string]$ts, [hashtable]$fxCfg) {
    $in = New-AiCostCalculationInput -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -RequestTimestampUtc $ts -InputTokens 600000 -OutputTokens 100000 -UsageSource 'PROVIDER_REPORTED' -CurrencyTarget 'INR'
    return (Calculate-AiAttemptCost -Configuration $fxCfg -CostInput $in)
}
$rMutA = Invoke-FxCost '2026-03-15T12:00:00Z' $cfgMut
$rMutB = Invoke-FxCost '2026-06-15T12:00:00Z' $cfgMut
Assert-True "fx non-mutation: baseline historic 75.0 / 83.5" ([decimal]$rMutA.ConvertedTotal -eq 14.85d -and [decimal]$rMutB.ConvertedTotal -eq 16.533d) "A=$($rMutA.ConvertedTotal) B=$($rMutB.ConvertedTotal)"

# close v2 at 2026-09-01, add v3 at 90.0
$fxMut['fx-mut-2'].EffectiveToUtc = '2026-09-01T00:00:00Z'
Add-AiExchangeRate -Catalogue $fxMut -Record (New-AiExchangeRateRecord -ExchangeRateId 'fx-mut-3' -BaseCurrency 'USD' -QuoteCurrency 'INR' -Rate 90.0 -EffectiveAtUtc '2026-09-01T00:00:00Z' -EffectiveToUtc $null -Source 'CONFIGURED') | Out-Null

$rMutA2 = Invoke-FxCost '2026-03-15T12:00:00Z' $cfgMut
$rMutB2 = Invoke-FxCost '2026-06-15T12:00:00Z' $cfgMut
$rMutC = Invoke-FxCost '2026-09-15T12:00:00Z' $cfgMut
Assert-True "fx non-mutation: historic unchanged after v3" ([decimal]$rMutA2.ConvertedTotal -eq 14.85d -and $rMutA2.ExchangeRateId -eq 'fx-mut-1' -and [decimal]$rMutB2.ConvertedTotal -eq 16.533d -and $rMutB2.ExchangeRateId -eq 'fx-mut-2') "A=$($rMutA2.ConvertedTotal)($($rMutA2.ExchangeRateId)) B=$($rMutB2.ConvertedTotal)($($rMutB2.ExchangeRateId))"
Assert-True "fx non-mutation: v3 applies only after its boundary" ([decimal]$rMutC.ConvertedTotal -eq 17.82d -and $rMutC.ExchangeRateId -eq 'fx-mut-3') "C=$($rMutC.ConvertedTotal)($($rMutC.ExchangeRateId))"
Assert-True "fx non-mutation: closed v2 rate evidence preserved" ([decimal]$fxMut['fx-mut-2'].Rate -eq 83.5d) "got $($fxMut['fx-mut-2'].Rate)"

# --- M. CostVariance v1 -------------------------------------------------------------
$vVar1 = New-AiCostVariance -EstimatedCost 1.00 -ActualCost 1.20
Assert-True "variance: abs 0.20" ([decimal]$vVar1.AbsoluteVariance -eq 0.20d) "got $($vVar1.AbsoluteVariance)"
Assert-Near "variance: pct +20%" $vVar1.PercentageVariance 20.0 0.001 "got $($vVar1.PercentageVariance)"

$vVar2 = New-AiCostVariance -EstimatedCost 1.20 -ActualCost 1.00
Assert-True "variance below: abs 0.20" ([decimal]$vVar2.AbsoluteVariance -eq 0.20d) "got $($vVar2.AbsoluteVariance)"
Assert-Near "variance below: pct negative" $vVar2.PercentageVariance -16.666667 0.001 "got $($vVar2.PercentageVariance)"

$vVar3 = New-AiCostVariance -EstimatedCost 0.00 -ActualCost 1.20
Assert-True "variance zero estimate: abs 1.20, pct null" ([decimal]$vVar3.AbsoluteVariance -eq 1.20d -and $null -eq $vVar3.PercentageVariance) "abs=$($vVar3.AbsoluteVariance) pct=$($vVar3.PercentageVariance)"

$vVar4 = New-AiCostVariance -EstimatedCost 1.00 -ActualCost $null
Assert-True "variance missing actual: both null" ($null -eq $vVar4.AbsoluteVariance -and $null -eq $vVar4.PercentageVariance) "abs=$($vVar4.AbsoluteVariance) pct=$($vVar4.PercentageVariance)"

# --- N. INVALID_USAGE via calculator -------------------------------------------------
$rawNeg = [pscustomobject]@{ SchemaVersion=1; ProviderId='deepseek'; ModelId='deepseek-v4-flash'; RequestTimestampUtc='2026-08-31T00:30:00Z'; InputTokens=-5; OutputTokens=100 }
$rBad = Calculate-AiAttemptCost -Configuration $cfg -CostInput $rawNeg
Assert-True "calculator: negative tokens -> INVALID_USAGE" ($rBad.CalculationStatus -eq 'INVALID_USAGE') "got $($rBad.CalculationStatus)"
Assert-True "calculator: missing input -> INVALID_USAGE" ((Calculate-AiAttemptCost -Configuration $cfg -CostInput $null).CalculationStatus -eq 'INVALID_USAGE') "got $( (Calculate-AiAttemptCost -Configuration $cfg -CostInput $null).CalculationStatus )"

# --- O. foundation validation + CostCalculationResult v1 shape -----------------------
$found = Validate-AiCostFoundation -Configuration $cfg
Assert-True "foundation: valid" $found.Valid "Errors: $($found.Errors -join '; ')"
Assert-True "foundation: FX catalogues exposed" ($null -ne $found.ExchangeRates -and $found.ExchangeRates.Count -eq 2) "count=$($found.ExchangeRates.Count)"

$rShape = Calculate-AiAttemptCost -Configuration $cfg -CostInput $inAct
Assert-True "result schema v1" ($rShape.SchemaVersion -eq 1) "got $($rShape.SchemaVersion)"
Assert-True "result carries pricing-record identity" ($rShape.PricingRecordId -eq 'ds-v4flash-offpeak-20260830') "got $($rShape.PricingRecordId)"
Assert-True "result calculated timestamp set" ($null -ne $rShape.CalculatedAtUtc) "got $($rShape.CalculatedAtUtc)"

# --- P. no-network / no-credential scan of the cost libraries ------------------------
$netPatterns = 'Invoke-RestMethod|Invoke-WebRequest|HttpClient|WebClient|System\.Net|Net\.Http'
$credPatterns = 'sk-[A-Za-z0-9]|AIza[0-9A-Za-z]|ghp_[A-Za-z0-9]'
foreach ($f in @('AiCostContracts.ps1', 'AiExchangeRates.ps1', 'CostCalculator.ps1', 'AiRoutingCostFoundation.ps1')) {
    $content = Get-Content (Join-Path $PSScriptRoot $f) -Raw
    Assert-True "no-network scan: $f" (-not ($content -match $netPatterns)) "network verbs/APIs found in $f"
    Assert-True "no-credential scan: $f" (-not ($content -match $credPatterns)) "credential patterns found in $f"
}

# --- summary -------------------------------------------------------------------------
Write-Output ""
$passed = $script:Results.Count - $script:Fails.Count
$failed = $script:Fails.Count
Write-Output ("DB-M16 TEST SUMMARY: {0} passed, {1} failed" -f $passed, $failed)
Write-Output "DB-M16 Paid API calls: 0 | FX/network calls: 0"
if ($failed -gt 0) { exit 1 } else { exit 0 }

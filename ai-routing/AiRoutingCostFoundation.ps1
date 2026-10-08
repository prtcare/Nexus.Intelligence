# AiRoutingCostFoundation.ps1 — DB-M16 entry point for the cost foundation.
#
# Dot-sources the DB-M15 pricing foundation (DB-M14 contracts/provider/model,
# read-only) plus the DB-M16 cost/FX libraries, then exposes:
#   Import-AiCostConfiguration  - load + normalize config/ai-routing.json,
#                                 config/providers.json, config/models.json,
#                                 config/pricing/pricing-catalogue.json,
#                                 config/currency/exchange-rates.json, and
#                                 config/cost/cost-calculator.json
#   Validate-AiCostFoundation   - deterministic validation of the cost foundation
#                                 (DB-M14 catalogues + DB-M15 pricing + DB-M16 FX
#                                 catalogue + cost config)
#
# No AI API calls, no provider calls, no paid calls, no network, no secrets.
# All price values come from the DB-M15 pricing catalogue; all FX evidence comes
# from the DB-M16 exchange-rate catalogue. No rates are embedded in code.

. (Join-Path $PSScriptRoot "AiRoutingPricingFoundation.ps1")   # DB-M14 + DB-M15
. (Join-Path $PSScriptRoot "AiCostContracts.ps1")
. (Join-Path $PSScriptRoot "AiExchangeRates.ps1")
. (Join-Path $PSScriptRoot "CostCalculator.ps1")

function Import-AiCostConfiguration {
    <#
    .SYNOPSIS
    Load and normalize the full cost foundation: DB-M14 routing/provider/model
    catalogues, the DB-M15 pricing catalogue, the DB-M16 exchange-rate catalogue,
    and the DB-M16 calculator config.
    Returns @{ Routing; Providers; Models; Pricing; ExchangeRates; CostConfig; Raw }.
    #>
    param([string]$Root = (Resolve-AiRoutingRoot))
    $foundation = Import-AiPricingConfiguration -Root $Root

    $fx = @{}
    $fxFile = Join-Path $Root "config\currency\exchange-rates.json"
    if (Test-Path $fxFile) {
        $fxJson = Get-Content $fxFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($fxJson.records)) {
            $rec = New-AiExchangeRateRecord -InputObject $r
            $fx[$rec.ExchangeRateId] = $rec
        }
    }

    $costConfig = $null
    $costFile = Join-Path $Root "config\cost\cost-calculator.json"
    if (Test-Path $costFile) {
        $costConfig = (Get-Content $costFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    }

    return @{
        Routing       = $foundation.Routing
        Providers     = $foundation.Providers
        Models        = $foundation.Models
        Pricing       = $foundation.Pricing
        ExchangeRates = $fx
        CostConfig    = $costConfig
        Raw           = $null
    }
}

function Validate-AiCostFoundation {
    <#
    .SYNOPSIS
    Deterministically validate the loaded cost foundation. Returns a summary
    object with Valid, Errors, Warnings, and the catalogues.
    #>
    param(
        [string]$Root = (Resolve-AiRoutingRoot),
        [AllowNull()][object]$Configuration
    )
    if (-not $Configuration) { $Configuration = Import-AiCostConfiguration -Root $Root }

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    # DB-M14 foundation + DB-M15 pricing catalogue
    $p = Validate-AiPricingFoundation -Configuration $Configuration
    foreach ($e in $p.Errors) { $errors.Add($e) }
    foreach ($w in $p.Warnings) { $warnings.Add($w) }

    # DB-M16 exchange-rate catalogue
    $xv = Validate-AiExchangeRateCatalogue -Catalogue $Configuration.ExchangeRates
    foreach ($e in $xv.Errors) { $errors.Add("fx: $e") }
    foreach ($w in $xv.Warnings) { $warnings.Add("fx: $w") }

    # DB-M16 calculator config shape
    $cc = $Configuration.CostConfig
    if ($null -eq $cc) {
        $warnings.Add('cost: config/cost/cost-calculator.json not loaded; defaults apply (ReasoningTokenBilling=INCLUDED_IN_OUTPUT)')
    } else {
        if ($cc.schemaVersion -ne 1) { $errors.Add("cost: cost-calculator schemaVersion must be 1, got '$($cc.schemaVersion)'") }
        $rb = Get-ContractProperty $cc 'ReasoningTokenBilling' 'INCLUDED_IN_OUTPUT'
        if ($rb -notin @('INCLUDED_IN_OUTPUT', 'SEPARATE')) {
            $errors.Add("cost: ReasoningTokenBilling must be INCLUDED_IN_OUTPUT or SEPARATE, got '$rb'")
        }
    }

    return [pscustomobject]@{
        Valid        = ($errors.Count -eq 0)
        Errors       = @($errors)
        Warnings     = @($warnings)
        Pricing      = $Configuration.Pricing
        Providers    = $Configuration.Providers
        Models       = $Configuration.Models
        ExchangeRates = $Configuration.ExchangeRates
        CostConfig   = $Configuration.CostConfig
        StatusCounts = $p.StatusCounts
        PricingGaps  = $p.PricingGaps
        FxGaps       = $xv.Gaps
        FxOverlaps   = $xv.Overlaps
    }
}

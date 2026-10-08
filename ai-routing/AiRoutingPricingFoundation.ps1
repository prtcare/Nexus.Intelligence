# AiRoutingPricingFoundation.ps1 — DB-M15 entry point for the pricing foundation.
#
# Dot-sources the DB-M14 foundation (contracts/provider/model - read-only) plus the
# DB-M15 pricing libraries, then exposes:
#   Import-AiPricingConfiguration  - load + normalize config/ai-routing.json,
#                                    config/providers.json, config/models.json, and
#                                    config/pricing/pricing-catalogue.json
#   Validate-AiPricingFoundation   - deterministic validation of the loaded pricing
#                                    foundation (DB-M14 catalogues + pricing catalogue)
#
# No AI API calls, no provider calls, no network, no secrets read, no cost
# calculation (that is DB-M16), no paid calls.

. (Join-Path $PSScriptRoot "AiRoutingFoundation.ps1")        # DB-M14 (read-only)
. (Join-Path $PSScriptRoot "AiPricingContracts.ps1")
. (Join-Path $PSScriptRoot "AiPricingTimeBands.ps1")
. (Join-Path $PSScriptRoot "PricingCatalogue.ps1")

function Import-AiPricingConfiguration {
    <#
    .SYNOPSIS
    Load and normalize the DB-M14 foundation + the DB-M15 pricing catalogue.
    Returns @{ Routing; Providers; Models; Pricing (hashtable keyed by
    PricingRecordId); Raw }.
    #>
    param([string]$Root = (Resolve-AiRoutingRoot))
    $foundation = Import-AiRoutingConfiguration -Root $Root

    $pricing = @{}
    $pricingFile = Join-Path $Root "config\pricing\pricing-catalogue.json"
    if (Test-Path $pricingFile) {
        $pjson = Get-Content $pricingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($pjson.records)) {
            $rec = New-AiPricingRecord -InputObject $r
            if ($foundation.Providers.ContainsKey($rec.ProviderId)) { $rec.ProviderResolved = $true } else { $rec.ProviderResolved = $false }
            if ($foundation.Models.ContainsKey($rec.ModelId)) { $rec.ModelResolved = $true } else { $rec.ModelResolved = $false }
            $pricing[$rec.PricingRecordId] = $rec
        }
    }

    return @{
        Routing   = $foundation.Routing
        Providers = $foundation.Providers
        Models    = $foundation.Models
        Pricing   = $pricing
        Raw       = $null
    }
}

function Validate-AiPricingFoundation {
    <#
    .SYNOPSIS
    Deterministically validate the loaded pricing foundation. Returns a summary
    object with Valid, Errors, Warnings, StatusCounts, and the catalogues.
    #>
    param(
        [string]$Root = (Resolve-AiRoutingRoot),
        [AllowNull()][object]$Configuration
    )
    if (-not $Configuration) { $Configuration = Import-AiPricingConfiguration -Root $Root }

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    # DB-M14 foundation (execution mode gate, provider + model catalogues)
    $f = Validate-AiRoutingFoundation -Configuration $Configuration
    foreach ($e in $f.Errors) { $errors.Add($e) }
    foreach ($w in $f.Warnings) { $warnings.Add($w) }

    # DB-M15 pricing catalogue (cross-checked against provider + model catalogues)
    $pv = Validate-AiPricingCatalogue -Catalogue $Configuration.Pricing `
        -Providers $Configuration.Providers -Models $Configuration.Models
    foreach ($e in $pv.Errors) { $errors.Add("pricing: $e") }
    foreach ($w in $pv.Warnings) { $warnings.Add("pricing: $w") }

    return [pscustomobject]@{
        Valid        = ($errors.Count -eq 0)
        Errors       = @($errors)
        Warnings     = @($warnings)
        Pricing      = $Configuration.Pricing
        Providers    = $Configuration.Providers
        Models       = $Configuration.Models
        StatusCounts = $pv.StatusCounts
        PricingGaps  = $pv.Gaps
    }
}

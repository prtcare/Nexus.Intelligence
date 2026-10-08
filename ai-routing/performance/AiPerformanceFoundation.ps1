# AiPerformanceFoundation.ps1 — DB-M24 entry point for the model performance
# intelligence foundation.
#
# Dot-sources the DB-M17 attempt store (DB-M14 contracts/vocabularies, READ-ONLY;
# DB-M17 history is consumed read-only, never modified) plus the DB-M24 contract
# library and the DB-M24 aggregation engine, then exposes:
#   Resolve-AiPerformanceRoot       - locate the DevBridge repository root
#   Import-AiPerformanceConfiguration - load config/performance/confidence-bands.json
#   Validate-AiPerformanceFoundation - deterministic validation of the loaded
#                                      confidence configuration + engine wiring
#
# DB-M24 is EVIDENCE ONLY: summaries, comparisons, failure distributions, and
# recommendations are computed from recorded attempt history. No routing policy is
# read-for-decision or mutated. No database is created — metrics are always derived
# from the attempt records passed in.
#
# No AI API calls, no provider calls, no paid calls, no network, no credentials.

. (Join-Path $PSScriptRoot "..\AttemptStore.ps1")        # DB-M14 + DB-M17 vocab (read-only)
. (Join-Path $PSScriptRoot "AiPerformanceContracts.ps1") # DB-M24 contracts + vocabularies
. (Join-Path $PSScriptRoot "ModelPerformance.ps1")       # DB-M24 aggregation engine

function Resolve-AiPerformanceRoot {
    <#
    .SYNOPSIS
    The DevBridge repository root: the parent of the scripts/ directory that holds
    this file (ai-routing/performance/ -> root).
    #>
    $root = (Resolve-Path (Join-Path $PSScriptRoot "..\.."))
    return $root.Path
}

function Import-AiPerformanceConfiguration {
    <#
    .SYNOPSIS
    Load config/performance/confidence-bands.json. The bands decide how a sample
    size maps to a confidence level; they are configurable (see the default file)
    and never hard-coded in the aggregation engine. Sets $script:PerfConfidenceBands
    for the engine.
    Returns @{ Valid; Errors; Warnings; Bands; Source; Raw }.
    #>
    param([string]$Root = (Resolve-AiPerformanceRoot))
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $bands = @()
    $source = $null

    $file = Join-Path $Root "config\performance\confidence-bands.json"
    if (-not (Test-Path $file)) {
        $errors.Add("performance: config/performance/confidence-bands.json not found; default bands apply")
        $bands = @(Get-AiDefaultConfidenceBands)
        $source = 'default'
    } else {
        $raw = (Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json)
        $source = $file
        if ($raw.schemaVersion -ne 1) { $errors.Add("performance: confidence-bands schemaVersion must be 1, got '$($raw.schemaVersion)'") }
        foreach ($b in @($raw.bands)) {
            $min = $b.Min
            $max = $b.Max
            $level = [string]$b.Level
            if ($null -eq $min -or $min -lt 0) { $errors.Add("performance: band with invalid Min '$min'") }
            if ($null -ne $max -and $max -lt 0) { $errors.Add("performance: band with invalid Max '$max'") }
            if ($level -notin (Get-AiConfidenceLevels)) { $errors.Add("performance: band Level '$level' invalid") }
            $bands += [pscustomobject]@{ Min = $min; Max = $max; Level = $level }
        }
        # overlap / ordering check: bands must be sorted by Min and non-overlapping
        $prev = -1
        foreach ($b in $bands) {
            if ([int]$b.Min -le $prev) { $errors.Add("performance: confidence bands overlap or are unsorted (Min $($b.Min) after max $prev)") }
            $prev = $b.Max
        }
        if ($bands.Count -eq 0) {
            $errors.Add('performance: confidence-bands file declares no bands')
            $bands = @(Get-AiDefaultConfidenceBands)
        }
    }

    if ($errors.Count -eq 0) { $script:PerfConfidenceBands = $bands }

    return @{
        Valid    = ($errors.Count -eq 0)
        Errors   = @($errors)
        Warnings = @($warnings)
        Bands    = $bands
        Source   = $source
        Raw      = $null
    }
}

function Validate-AiPerformanceFoundation {
    <#
    .SYNOPSIS
    Deterministically validate the DB-M24 performance foundation: confidence-bands
    configuration, engine wiring, and the schema-version registration. Returns
    @{ Valid; Errors; Warnings; ConfidenceBands; ... }.
    #>
    param(
        [string]$Root = (Resolve-AiPerformanceRoot),
        [AllowNull()][object]$Configuration
    )
    if (-not $Configuration) { $Configuration = Import-AiPerformanceConfiguration -Root $Root }

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Configuration.Errors) { $errors.Add($e) }
    foreach ($w in $Configuration.Warnings) { $warnings.Add($w) }

    if (-not (Get-Command Get-AiPerformanceSummaries -ErrorAction SilentlyContinue)) {
        $errors.Add('performance: engine Get-AiPerformanceSummaries not loaded')
    }
    foreach ($fn in @('Get-AiModelPerformance', 'Compare-AiModelPerformance', 'Get-AiTaskTypePerformance',
            'Get-AiFailureDistribution', 'Get-AiCostPerSuccessfulTask', 'Get-AiFirstAttemptSuccessRate',
            'Get-AiEscalationRate', 'Get-AiPerformanceRecommendation')) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { $errors.Add("performance: operation '$fn' not loaded") }
    }

    $sv = Get-AiPerformanceSchemaVersions
    if ($sv.ModelPerformanceSummaryVersion -ne 1 -or $sv.ModelComparisonVersion -ne 1 -or
        $sv.PerformanceRecommendationVersion -ne 1 -or $sv.PerformanceQueryVersion -ne 1) {
        $errors.Add('performance: schema versions must all be 1 (frozen v1)')
    }

    # confidence bands must be loadable and non-overlapping (validated above)
    if ($Configuration.Valid -and $Configuration.Bands.Count -gt 0) {
        $warnings.Add('performance: confidence bands loaded from ' + $Configuration.Source)
    }

    return [pscustomobject]@{
        Valid           = ($errors.Count -eq 0)
        Errors          = @($errors)
        Warnings        = @($warnings)
        ConfidenceBands = $Configuration.Bands
        BandsSource     = $Configuration.Source
        SchemaVersions  = $sv
    }
}

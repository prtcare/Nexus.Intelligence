# AiPerformanceContracts.ps1 — DB-M24 performance-intelligence contracts.
#
# Model Performance Intelligence Foundation (Lane B1). This file owns the frozen
# v1 contracts and vocabularies consumed by the DB-M24 aggregation engine
# (ModelPerformance.ps1) and its foundation aggregator
# (AiPerformanceFoundation.ps1):
#
#   ModelPerformanceSummary v1     - one group's historical performance snapshot
#   ModelComparison v1             - side-by-side model-route comparison (ranked)
#   PerformanceRecommendation v1   - non-binding, evidence-backed suggestion
#   PerformanceQuery v1            - read-only aggregation request
#
# DB-M24 is DESCRIPTIVE then RECOMMENDATION ONLY. Nothing here and nothing in the
# engine mutates routing policy, the pricing catalogue, the attempt store, or any
# configuration that drives routing. There is no database and no automatic policy
# learning. DB-M24 produces evidence and recommendations; DB-M19 decides.
#
# Success semantics, failure classification, attempt chains, cost normalization,
# and confidence bands are documented in design/ai-routing/DB-M24_MODEL_PERFORMANCE.md
# and DB-M24_RECOMMENDATION_EVIDENCE.md.
#
# No AI API calls, no provider calls, no network, no credentials, no writes.
# All cost values are reused from stored attempt evidence (DB-M17 records); no
# pricing is recalculated (that is DB-M16 territory).

# --- schema versions (DB-M24-owned) ---------------------------------------------

function Get-AiPerformanceSchemaVersions {
    <#
    .SYNOPSIS
    Frozen DB-M24 schema versions. Incompatible changes must introduce v2 with
    their own validators; v1 semantics are never silently mutated.
    #>
    return @{
        ModelPerformanceSummaryVersion = 1
        ModelComparisonVersion         = 1
        PerformanceRecommendationVersion = 1
        PerformanceQueryVersion        = 1
    }
}

# --- vocabularies -----------------------------------------------------------------

function Get-AiConfidenceLevels {
    # Sample-confidence vocabulary. Bands are configurable (see
    # config/performance/confidence-bands.json); the DEFAULT thresholds are
    # INSUFFICIENT < 5 tasks, LOW 5-19, MODERATE 20-49, HIGH 50+.
    return @('INSUFFICIENT', 'LOW', 'MODERATE', 'HIGH')
}

function Get-AiSuccessDefinitions {
    # How a task counts as "successful" (see design doc for the full rule):
    #   VERIFIED           - Result=SUCCESS AND VerificationResult=VERIFIED
    #   MODEL_RETURNED     - Result=SUCCESS regardless of verification evidence
    #   VERIFIED_PREFERRED - default: verification evidence is authoritative when
    #                        present (VERIFIED counts, FAILED contradicts success);
    #                        a success with no verification result counts as a
    #                        model-returned success (flagged, not hidden)
    return @('VERIFIED', 'MODEL_RETURNED', 'VERIFIED_PREFERRED')
}

function Get-AiPresetWindows {
    return @('ALL_TIME', 'LAST_7_DAYS', 'LAST_30_DAYS', 'LAST_90_DAYS', 'CUSTOM')
}

function Get-AiRecommendationTypes {
    # Non-binding recommendation strategies. INSUFFICIENT_DATA is the cold-start
    # answer: no recommendation is fabricated from no/too-little history.
    return @('CHEAPEST_RELIABLE', 'HIGHEST_SUCCESS', 'FASTEST', 'BEST_COST_PER_SUCCESS', 'INSUFFICIENT_DATA')
}

function Get-AiOutlierHandlings {
    # Explicit outlier policy. DB-M24 never silently deletes outliers; the only
    # supported mode today is NONE (mean/median/P95 all reported from the full
    # sample). Future filtering (e.g. EXCLUDE_ABOVE_P95) must be an explicit,
    # documented opt-in and must never be the default.
    return @('NONE')
}

function Get-AiPerformanceGroupBys {
    # Supported aggregation dimensions. VerificationResult and FailureCategory are
    # supported as FILTER dimensions (see PerformanceQuery) but not as group-by
    # keys: a model summary grouped by verification result or failure category
    # would conflate outcome with identity.
    return @('ModelRoute', 'Provider', 'UnderlyingModel', 'Gateway', 'TaskType', 'Complexity', 'Risk', 'ReasoningLevel', 'ExecutionMode')
}

function Get-AiProviderFailureCategories {
    # Provider-side failure grouping: attempts that failed because of the delivery
    # path, NOT the model's intellectual quality. Kept as a dedicated vocabulary so
    # ModelQualityFailureCount vs ProviderFailureCount are never conflated
    # (DB-M17 taxonomy: "a provider outage must not reduce the model's
    # intellectual-quality score in the same way as repeated test failures").
    return @('PROVIDER_AVAILABILITY', 'RATE_LIMIT', 'AUTHENTICATION')
}

function Get-AiConfidenceOrder {
    return @{ 'INSUFFICIENT' = 0; 'LOW' = 1; 'MODERATE' = 2; 'HIGH' = 3 }
}

function Test-IsValidConfidenceLevel([string]$Value)   { $Value -in (Get-AiConfidenceLevels) }
function Test-IsValidSuccessDefinition([string]$Value) { $Value -in (Get-AiSuccessDefinitions) }
function Test-IsValidPresetWindow([string]$Value)      { $Value -in (Get-AiPresetWindows) }
function Test-IsValidRecommendationType([string]$Value){ $Value -in (Get-AiRecommendationTypes) }
function Test-IsValidOutlierHandling([string]$Value)   { $Value -in (Get-AiOutlierHandlings) }

# --- UTC normalization (isolated, DB-M24 copy) -------------------------------------
#
# Same instant-based semantics as DB-M15's ConvertTo-AiUtc, kept local so the
# performance layer does not depend on the pricing libraries. A string WITHOUT a
# zone designator is assumed to denote a UTC clock time; a string WITH Z (or an
# offset) is converted to the equivalent UTC instant. Host timezone never matters.

function ConvertTo-AiPerfUtc {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Utc) { return $dt }
        if ($dt.Kind -eq [System.DateTimeKind]::Local) { return $dt.ToUniversalTime() }
        return [System.DateTime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
    }
    # A [string] parameter default of $null coerces to '' in PowerShell; both
    # must mean "no instant".
    $s = [string]$Value
    if ($s.Trim() -eq '') { return $null }
    return [System.DateTime]::Parse(
        $s,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}

# --- confidence bands ---------------------------------------------------------------

function Get-AiDefaultConfidenceBands {
    <#
    .SYNOPSIS
    Default sample-confidence thresholds. Configurable via
    config/performance/confidence-bands.json; these defaults apply only when no
    configuration is loaded. Bands are [Min, Max] inclusive; null Max = open-ended.
    #>
    return @(
        [pscustomobject]@{ Min = 0;  Max = 4;  Level = 'INSUFFICIENT' }
        [pscustomobject]@{ Min = 5;  Max = 19; Level = 'LOW' }
        [pscustomobject]@{ Min = 20; Max = 49; Level = 'MODERATE' }
        [pscustomobject]@{ Min = 50; Max = $null; Level = 'HIGH' }
    )
}

function Get-AiConfidenceLevel {
    <#
    .SYNOPSIS
    Map a sample count (number of tasks) to a confidence level using the supplied
    bands (or the defaults). Pure and deterministic.
    #>
    param([int]$SampleCount, [AllowNull()][object[]]$Bands)
    $bands = @($Bands)
    if ($bands.Count -eq 0) { $bands = @(Get-AiDefaultConfidenceBands) }
    $n = $SampleCount
    foreach ($b in $bands) {
        $min = [int](Get-ContractProperty $b 'Min' 0)
        $max = Get-ContractProperty $b 'Max' $null
        if ($n -ge $min -and ($null -eq $max -or $n -le [int]$max)) {
            return [string](Get-ContractProperty $b 'Level' 'INSUFFICIENT')
        }
    }
    return 'INSUFFICIENT'
}

# --- PerformanceQuery v1 --------------------------------------------------------------

function New-AiPerformanceQuery {
    <#
    .SYNOPSIS
    Construct a read-only PerformanceQuery v1. Time windows: a preset
    (ALL_TIME | LAST_7_DAYS | LAST_30_DAYS | LAST_90_DAYS) is resolved against the
    NowUtc reference (default: UtcNow); CUSTOM uses the explicit FromUtc/ToUtc
    (either may be null = open). Every dimension is optional; an unspecified
    dimension does not filter. Dimension values are normalized to the DB-M14
    conventions (provider/model ids lower-case; vocab fields upper-case).
    #>
    param(
        [string]$QueryId,
        [string]$PresetWindow = 'ALL_TIME',
        [string]$FromUtc,
        [string]$ToUtc,
        [string]$NowUtc,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$UnderlyingModelId,
        [string]$GatewayProviderId,
        [string]$TaskType,
        [string]$Complexity,
        [string]$Risk,
        [string]$ReasoningLevel,
        [string]$ExecutionMode,
        [string]$VerificationResult,
        [string]$FailureCategory,
        [string]$ReportingCurrency = 'INR',
        [bool]$AllowEstimatedCostFallback = $false,
        [string]$SuccessDefinition = 'VERIFIED_PREFERRED',
        [string]$OutlierHandling = 'NONE'
    )
    $preset = $PresetWindow.ToUpperInvariant()
    $now = ConvertTo-AiPerfUtc $NowUtc
    if ($null -eq $now) { $now = [datetime]::UtcNow }

    $from = $null; $to = $null
    switch ($preset) {
        'LAST_7_DAYS'  { $from = $now.AddDays(-7);  $to = $now }
        'LAST_30_DAYS' { $from = $now.AddDays(-30); $to = $now }
        'LAST_90_DAYS' { $from = $now.AddDays(-90); $to = $now }
        'CUSTOM'       { $from = ConvertTo-AiPerfUtc $FromUtc; $to = ConvertTo-AiPerfUtc $ToUtc }
        default        { }   # ALL_TIME: open window
    }

    return [pscustomobject]@{
        SchemaVersion             = 1
        QueryId                   = $QueryId
        PresetWindow              = $preset
        FromUtc                   = $(if ($from) { $from.ToString('o') } else { $null })
        ToUtc                     = $(if ($to) { $to.ToString('o') } else { $null })
        ProviderId                = $(if ($ProviderId) { $ProviderId.Trim().ToLowerInvariant() } else { $null })
        ModelId                   = $(if ($ModelId) { $ModelId.Trim().ToLowerInvariant() } else { $null })
        UnderlyingModelId         = $(if ($UnderlyingModelId) { $UnderlyingModelId.Trim().ToLowerInvariant() } else { $null })
        GatewayProviderId         = $(if ($GatewayProviderId) { $GatewayProviderId.Trim().ToLowerInvariant() } else { $null })
        TaskType                  = $(if ($TaskType) { $TaskType.ToUpperInvariant() } else { $null })
        Complexity                = $(if ($Complexity) { $Complexity.ToUpperInvariant() } else { $null })
        Risk                      = $(if ($Risk) { $Risk.ToUpperInvariant() } else { $null })
        ReasoningLevel            = $(if ($ReasoningLevel) { $ReasoningLevel.ToUpperInvariant() } else { $null })
        ExecutionMode             = $(if ($ExecutionMode) { $ExecutionMode.ToUpperInvariant() } else { $null })
        VerificationResult        = $(if ($VerificationResult) { $VerificationResult.ToUpperInvariant() } else { $null })
        FailureCategory           = $(if ($FailureCategory) { $FailureCategory.ToUpperInvariant() } else { $null })
        ReportingCurrency         = $ReportingCurrency.Trim().ToUpperInvariant()
        AllowEstimatedCostFallback = [bool]$AllowEstimatedCostFallback
        SuccessDefinition         = $SuccessDefinition.ToUpperInvariant()
        OutlierHandling           = $OutlierHandling.ToUpperInvariant()
    }
}

function Test-AiPerformanceQuery {
    <#
    .SYNOPSIS
    Deterministic structural validation of a PerformanceQuery v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Query)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Query) { return @{ Valid = $false; Errors = @('Query is null'); Warnings = @() } }
    if ((Get-ContractProperty $Query 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    $preset = [string](Get-ContractProperty $Query 'PresetWindow' '')
    if ($preset -and -not (Test-IsValidPresetWindow $preset)) { $errors.Add("PresetWindow '$preset' invalid") }
    $sd = [string](Get-ContractProperty $Query 'SuccessDefinition' '')
    if ($sd -and -not (Test-IsValidSuccessDefinition $sd)) { $errors.Add("SuccessDefinition '$sd' invalid") }
    $oh = [string](Get-ContractProperty $Query 'OutlierHandling' '')
    if ($oh -and -not (Test-IsValidOutlierHandling $oh)) { $errors.Add("OutlierHandling '$oh' invalid") }

    $cur = [string](Get-ContractProperty $Query 'ReportingCurrency' '')
    if ($cur -and $cur -notmatch '^[A-Z]{3}$') { $errors.Add("ReportingCurrency '$cur' must be a 3-letter ISO-4217 code") }

    $from = ConvertTo-AiPerfUtc (Get-ContractProperty $Query 'FromUtc' $null)
    $to = ConvertTo-AiPerfUtc (Get-ContractProperty $Query 'ToUtc' $null)
    if ($from -and $to -and $from -gt $to) { $errors.Add('FromUtc must be <= ToUtc') }

    # dimension vocabularies when present
    $tt = [string](Get-ContractProperty $Query 'TaskType' '')
    if ($tt -and -not (Test-IsValidTaskType $tt)) { $errors.Add("TaskType '$tt' invalid") }
    $cx = [string](Get-ContractProperty $Query 'Complexity' '')
    if ($cx -and $cx -notin @('LOW', 'MEDIUM', 'HIGH')) { $errors.Add("Complexity '$cx' invalid") }
    $rk = [string](Get-ContractProperty $Query 'Risk' '')
    if ($rk -and $rk -notin @('LOW', 'MEDIUM', 'HIGH')) { $errors.Add("Risk '$rk' invalid") }
    $rl = [string](Get-ContractProperty $Query 'ReasoningLevel' '')
    if ($rl -and -not (Test-IsValidReasoningLevel $rl)) { $errors.Add("ReasoningLevel '$rl' invalid") }
    $em = [string](Get-ContractProperty $Query 'ExecutionMode' '')
    if ($em -and -not (Test-IsValidExecutionMode $em)) { $errors.Add("ExecutionMode '$em' invalid") }
    $vr = [string](Get-ContractProperty $Query 'VerificationResult' '')
    if ($vr -and $vr -notin @('VERIFIED', 'FAILED', 'PENDING')) { $errors.Add("VerificationResult '$vr' invalid") }
    $fc = [string](Get-ContractProperty $Query 'FailureCategory' '')
    if ($fc -and -not (Test-IsValidFailureCategory $fc)) { $errors.Add("FailureCategory '$fc' invalid") }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @() }
}

# --- ModelPerformanceSummary v1 --------------------------------------------------------

function New-AiModelPerformanceSummary {
    <#
    .SYNOPSIS
    Construct a ModelPerformanceSummary v1 from a hashtable of computed fields.
    SchemaVersion is stamped here; unknown/absent fields stay null. The engine
    (ModelPerformance.ps1) computes the aggregates; this constructor is also used
    directly by tests to build fixture summaries.
    #>
    param([AllowNull()][hashtable]$Fields)
    if ($null -eq $Fields) { $Fields = @{} }
    function Get-Field([string]$Name, $Default = $null) {
        if ($Fields.ContainsKey($Name)) { return $Fields[$Name] }
        return $Default
    }
    return [pscustomobject]@{
        SchemaVersion                     = 1
        ProviderId                        = Get-Field 'ProviderId'
        ModelId                           = Get-Field 'ModelId'
        UnderlyingModelId                 = Get-Field 'UnderlyingModelId'
        GatewayProviderId                 = Get-Field 'GatewayProviderId'
        TaskType                          = Get-Field 'TaskType'
        Complexity                        = Get-Field 'Complexity'
        Risk                              = Get-Field 'Risk'
        ReasoningLevel                    = Get-Field 'ReasoningLevel'
        ExecutionMode                     = Get-Field 'ExecutionMode'
        SampleCount                       = Get-Field 'SampleCount' 0
        AttemptCount                      = Get-Field 'AttemptCount' 0
        SuccessCount                      = Get-Field 'SuccessCount' 0
        FailureCount                      = Get-Field 'FailureCount' 0
        IncompleteCount                   = Get-Field 'IncompleteCount' 0
        FirstAttemptSuccessCount          = Get-Field 'FirstAttemptSuccessCount' 0
        EscalationCount                   = Get-Field 'EscalationCount' 0
        HumanInterventionCount            = Get-Field 'HumanInterventionCount' 0
        ModelQualityFailureCount          = Get-Field 'ModelQualityFailureCount' 0
        ProviderFailureCount              = Get-Field 'ProviderFailureCount' 0
        BuildFailureCount                 = Get-Field 'BuildFailureCount' 0
        TestFailureCount                  = Get-Field 'TestFailureCount' 0
        ContextFailureCount               = Get-Field 'ContextFailureCount' 0
        BudgetFailureCount                = Get-Field 'BudgetFailureCount' 0
        OtherFailureCount                 = Get-Field 'OtherFailureCount' 0
        FailureCategoryCounts             = Get-Field 'FailureCategoryCounts' @{}
        AverageAttemptsPerSuccessfulTask  = Get-Field 'AverageAttemptsPerSuccessfulTask'
        AverageDurationMs                 = Get-Field 'AverageDurationMs'
        MedianDurationMs                  = Get-Field 'MedianDurationMs'
        P95DurationMs                     = Get-Field 'P95DurationMs'
        AverageEstimatedCost              = Get-Field 'AverageEstimatedCost'
        AverageActualCost                 = Get-Field 'AverageActualCost'
        AverageCostPerAttempt             = Get-Field 'AverageCostPerAttempt'
        AverageCostPerSuccessfulTask      = Get-Field 'AverageCostPerSuccessfulTask'
        AverageInputTokens                = Get-Field 'AverageInputTokens'
        AverageOutputTokens               = Get-Field 'AverageOutputTokens'
        AverageContextTokens              = Get-Field 'AverageContextTokens'
        SuccessRate                       = Get-Field 'SuccessRate'
        FirstAttemptSuccessRate           = Get-Field 'FirstAttemptSuccessRate'
        EscalationRate                    = Get-Field 'EscalationRate'
        VerifiedSuccessCount              = Get-Field 'VerifiedSuccessCount' 0
        ModelReturnedSuccessCount         = Get-Field 'ModelReturnedSuccessCount' 0
        SuccessDefinition                 = Get-Field 'SuccessDefinition' 'VERIFIED_PREFERRED'
        ReportingCurrency                 = Get-Field 'ReportingCurrency' 'INR'
        CostSampleCount                   = Get-Field 'CostSampleCount' 0
        DurationSampleCount               = Get-Field 'DurationSampleCount' 0
        EstimatedCostFallbackUsed         = Get-Field 'EstimatedCostFallbackUsed' 0
        CostExcludedCount                 = Get-Field 'CostExcludedCount' 0
        LastAttemptAtUtc                  = Get-Field 'LastAttemptAtUtc'
        ConfidenceLevel                   = Get-Field 'ConfidenceLevel' 'INSUFFICIENT'
        Warnings                          = @(Get-Field 'Warnings' @())
    }
}

function Test-AiModelPerformanceSummary {
    <#
    .SYNOPSIS
    Deterministic structural validation of a ModelPerformanceSummary v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Summary)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Summary) { return @{ Valid = $false; Errors = @('Summary is null'); Warnings = @() } }
    if ((Get-ContractProperty $Summary 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    $sample = Get-ContractProperty $Summary 'SampleCount' $null
    if ($null -eq $sample -or $sample -lt 0) { $errors.Add('SampleCount must be a non-negative integer') }
    foreach ($cnt in @('AttemptCount', 'SuccessCount', 'FailureCount', 'FirstAttemptSuccessCount', 'EscalationCount', 'HumanInterventionCount')) {
        $v = Get-ContractProperty $Summary $cnt $null
        if ($null -ne $v -and $v -lt 0) { $errors.Add("$cnt must be >= 0") }
    }
    foreach ($rate in @('SuccessRate', 'FirstAttemptSuccessRate', 'EscalationRate')) {
        $v = Get-ContractProperty $Summary $rate $null
        if ($null -ne $v -and ($v -lt 0 -or $v -gt 1)) { $errors.Add("$rate must be within 0..1") }
    }
    $conf = [string](Get-ContractProperty $Summary 'ConfidenceLevel' '')
    if ($conf -and -not (Test-IsValidConfidenceLevel $conf)) { $errors.Add("ConfidenceLevel '$conf' invalid") }
    $sd = [string](Get-ContractProperty $Summary 'SuccessDefinition' '')
    if ($sd -and -not (Test-IsValidSuccessDefinition $sd)) { $errors.Add("SuccessDefinition '$sd' invalid") }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @() }
}

# --- ModelComparison v1 -----------------------------------------------------------------

function New-AiModelComparison {
    <#
    .SYNOPSIS
    Construct a ModelComparison v1: ranked, side-by-side model-route rows sorted by
    one metric. NEVER selects a winner — ranking is presentation; the decision is
    DB-M19's, informed by (not dictated by) this comparison and recommendations.
    #>
    param(
        [string]$SortBy = 'SuccessRate',
        [string]$Direction = 'DESCENDING',
        [AllowNull()][object[]]$Rows = @(),
        [AllowNull()][object[]]$SourceSummaries = @()
    )
    return [pscustomobject]@{
        SchemaVersion    = 1
        SortBy           = $SortBy
        Direction        = $Direction
        ComparedCount    = @($Rows).Count
        Rows             = @($Rows)
        Warnings         = @()
        GeneratedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Test-AiModelComparison {
    param([AllowNull()][pscustomobject]$Comparison)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Comparison) { return @{ Valid = $false; Errors = @('Comparison is null'); Warnings = @() } }
    if ((Get-ContractProperty $Comparison 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if ((Get-ContractProperty $Comparison 'ComparedCount' -1) -lt 0) { $errors.Add('ComparedCount must be >= 0') }
    $rows = @(Get-ContractProperty $Comparison 'Rows' @())
    foreach ($r in $rows) {
        if ((Get-ContractProperty $r 'SchemaVersion' -1) -ne 1) { $errors.Add('Comparison row SchemaVersion must be 1') }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @() }
}

# --- PerformanceRecommendation v1 ----------------------------------------------------------

function New-AiPerformanceRecommendation {
    <#
    .SYNOPSIS
    Construct a PerformanceRecommendation v1. The recommendation is EVIDENCE ONLY —
    it never mutates routing policy. PolicyVersion stays the immutable DB-M14
    routing policy version ('0.0.0'); recommending a model does not change it.
    #>
    param(
        [string]$RecommendationType = 'INSUFFICIENT_DATA',
        [string]$RecommendedModelId,
        [string]$ProviderId,
        [string]$UnderlyingModelId,
        [string]$GatewayProviderId,
        [string]$Reason,
        [int]$EvidenceSampleCount = 0,
        [string]$ConfidenceLevel = 'INSUFFICIENT',
        [AllowNull()][object[]]$ComparedModels = @(),
        $ExpectedSuccessRate = $null,
        $ExpectedFirstAttemptSuccess = $null,
        $ExpectedCostPerSuccess = $null,
        $ExpectedDuration = $null,
        [AllowNull()][string[]]$Warnings = @(),
        [string]$PolicyVersion = '0.0.0'
    )
    return [pscustomobject]@{
        SchemaVersion               = 1
        RecommendationType          = $RecommendationType
        RecommendedModelId          = $RecommendedModelId
        ProviderId                  = $ProviderId
        UnderlyingModelId           = $UnderlyingModelId
        GatewayProviderId           = $GatewayProviderId
        Reason                      = $Reason
        EvidenceSampleCount         = $EvidenceSampleCount
        ConfidenceLevel             = $ConfidenceLevel
        ComparedModels              = @($ComparedModels)
        ExpectedSuccessRate         = $ExpectedSuccessRate
        ExpectedFirstAttemptSuccess = $ExpectedFirstAttemptSuccess
        ExpectedCostPerSuccess      = $ExpectedCostPerSuccess
        ExpectedDuration            = $ExpectedDuration
        PolicyVersion               = $PolicyVersion
        Warnings                    = @($Warnings)
        GeneratedAtUtc              = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Test-AiPerformanceRecommendation {
    param([AllowNull()][pscustomobject]$Recommendation)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Recommendation) { return @{ Valid = $false; Errors = @('Recommendation is null'); Warnings = @() } }
    if ((Get-ContractProperty $Recommendation 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    $type = [string](Get-ContractProperty $Recommendation 'RecommendationType' '')
    if ($type -and -not (Test-IsValidRecommendationType $type)) { $errors.Add("RecommendationType '$type' invalid") }
    $conf = [string](Get-ContractProperty $Recommendation 'ConfidenceLevel' '')
    if ($conf -and -not (Test-IsValidConfidenceLevel $conf)) { $errors.Add("ConfidenceLevel '$conf' invalid") }
    $sample = Get-ContractProperty $Recommendation 'EvidenceSampleCount' $null
    if ($null -ne $sample -and $sample -lt 0) { $errors.Add('EvidenceSampleCount must be >= 0') }
    $compared = @(Get-ContractProperty $Recommendation 'ComparedModels' @())
    foreach ($m in $compared) {
        if (-not [string](Get-ContractProperty $m 'ModelId' '')) { $errors.Add('ComparedModels rows must carry a ModelId') }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @() }
}

# AiQualityCostContracts.ps1 -- DB-M25 quality-adjusted cost + savings contracts.
#
# Quality-Adjusted Cost + Savings Analytics (Lane B). This file owns the frozen
# v1 contracts and vocabularies consumed by the DB-M25 engine (QualityCost.ps1):
#
#   QualityCostQuery v1              - read-only analytics request
#   QualityAdjustedCostResult v1     - one group's cost-quality snapshot
#   SavingsAnalysis v1               - explicit-baseline savings comparison
#   PolicyComparison v1              - synthetic/historical policy comparison
#
# Core principle (the brief): cheap attempt cost does NOT necessarily mean cheap
# successful development. The unit of analysis is the real expected cost of
# obtaining a VERIFIED successful result -- the attempt-chain cost (failed
# attempts + retry/escalation included) per verified success -- never the single
# attempt price.
#
# Verified success is authoritative: VerificationResult = VERIFIED (independent
# DB-M06 verification evidence) plus an accepted Claude review state where review
# is required, over model self-reported success. A model saying PASS is not
# sufficient if verification later failed; a rejected implementation is never
# counted as successful merely because the model finished.
#
# Reuse is READ-ONLY: DB-M24 performance foundation (chains, confidence, stats,
# vocabularies), DB-M23 adapter contracts (price statuses, secret-leak guard),
# DB-M17 attempt vocabulary, DB-M14 shared helpers. No file that owns those
# contracts is modified. No AI/provider/paid/network calls, no secrets stored.
#
# AUTO_EXECUTION_ENABLED = FALSE. MANUAL display only; ASSISTED may support
# recommendation evidence; AUTO executes nothing.

. (Join-Path $PSScriptRoot "..\performance\AiPerformanceFoundation.ps1")  # DB-M24 (READ-ONLY)
. (Join-Path $PSScriptRoot "..\providers\common\AdapterContracts.ps1")    # DB-M23 common (READ-ONLY)

# --- schema versions (DB-M25-owned) ----------------------------------------------

function Get-DbM25SchemaVersions {
    <#
    .SYNOPSIS
    Frozen DB-M25 schema versions. Incompatible changes must introduce v2 with
    their own validators; v1 semantics are never silently mutated.
    #>
    return @{
        QualityCostQueryVersion          = 1
        QualityAdjustedCostResultVersion = 1
        SavingsAnalysisVersion           = 1
        PolicyComparisonVersion          = 1
    }
}

# --- vocabularies -------------------------------------------------------------------

function Get-DbM25BaselineTypes {
    # Explicit baseline concepts for savings comparisons. Every savings result
    # must state its baseline; DB-M25 never silently chooses a favourable one.
    return @('CURRENT_DEFAULT', 'MANUAL_BASELINE', 'CHEAPEST_ELIGIBLE', 'HISTORICAL_ROUTE',
             'SPECIFIC_MODEL_ROUTE', 'SPECIFIC_POLICY')
}

function Get-DbM25BaselineBasis {
    # OBSERVED = from observed verified chains. ESTIMATED/COUNTERFACTUAL = a
    # synthetic or hypothetical comparison, never presented as observed fact.
    return @('OBSERVED', 'ESTIMATED', 'COUNTERFACTUAL')
}

function Get-DbM25ExpectedCostBasis {
    # OBSERVED_CHAINS = observed verified-success chain cost (sample confidence
    # sufficient). COLD_START_SIMPLE = labelled simple estimate
    # (AverageAttemptCost / VerifiedSuccessRate) for low/insufficient samples.
    return @('OBSERVED_CHAINS', 'COLD_START_SIMPLE')
}

function Get-DbM25PolicyTypes {
    # Synthetic/historical routing-policy comparison vocabulary. Analysis only:
    # DB-M19 owns live policy; PolicyVersion stays the immutable '0.0.0'.
    return @('CHEAPEST_ELIGIBLE', 'CHEAPEST_RELIABLE', 'BEST_COST_PER_SUCCESS', 'HIGHEST_SUCCESS', 'BALANCED')
}

function Get-DbM25GroupBys {
    # DB-M24 group-bys extended with LocalOrRemote (Local / Remote / UNKNOWN).
    return @('ModelRoute', 'Provider', 'UnderlyingModel', 'Gateway', 'TaskType',
             'Complexity', 'Risk', 'ReasoningLevel', 'ExecutionMode', 'LocalOrRemote')
}

function Get-DbM25ClaudeReviewStatuses {
    # Mirrors the DB-M20 ClaudeReviewStatus vocabulary (READ-ONLY reuse; DB-M20
    # is never modified). 'PASS' is the accepted review state.
    return @('NONE', 'PENDING', 'PASS', 'FIX_REQUIRED')
}

function Test-IsValidDbM25BaselineType([string]$Value)       { $Value -in (Get-DbM25BaselineTypes) }
function Test-IsValidDbM25BaselineBasis([string]$Value)      { $Value -in (Get-DbM25BaselineBasis) }
function Test-IsValidDbM25ExpectedCostBasis([string]$Value)  { $Value -in (Get-DbM25ExpectedCostBasis) }
function Test-IsValidDbM25PolicyType([string]$Value)         { $Value -in (Get-DbM25PolicyTypes) }
function Test-IsValidDbM25GroupBy([string]$Value)            { $Value -in (Get-DbM25GroupBys) }

# --- secret-value guard (DB-M25 wrapper) ---------------------------------------------

function Test-DbM25SecretLeak {
    <#
    .SYNOPSIS
    Scan a DB-M25 analysis object for API-key-like VALUES. Wraps the DB-M23 guard
    and additionally exempts DB-M25-owned identifiers/references/scope fields;
    free-text fields (Warnings, BaselineLabel) ARE scanned. Never stores secrets.
    #>
    param([AllowNull()][object]$Target)
    $extraExempt = @(
        'AnalysisId', 'QueryId', 'GroupKey', 'CandidateRoute', 'BaselineRoute',
        'BaselineType', 'BaselineLabel', 'BaselineBasis', 'ExpectedCostBasis',
        'LocalCostStatus', 'OperationalCostUnknown', 'EvidenceReferences',
        'WindowStartUtc', 'WindowEndUtc', 'GeneratedAtUtc', 'Scope',
        'SuccessDefinition', 'RequiresClaudeReview', 'RequiredReviewStatus',
        'ConfidenceLevel', 'Currency', 'VerifiedSuccessCount', 'ModelReturnedSuccessCount',
        'FailedChainCount', 'IncompleteChainCount', 'FirstAttemptVerifiedSuccessCount',
        'VerifiedSuccessRate', 'FirstAttemptVerifiedSuccessRate', 'AttemptCount',
        'SampleCount', 'AverageAttemptsPerVerifiedSuccess', 'MedianAttemptsPerVerifiedSuccess',
        'AverageAttemptCost', 'MedianAttemptCost', 'TotalAttemptCost', 'FailedAttemptCost',
        'FailedAttemptCostShare', 'EscalationCost', 'EscalationCostShare', 'EscalatedChainCost',
        'AverageCorrectionCost', 'ProviderFailureCost', 'ProviderFailureCostShare',
        'ModelQualityFailureCost', 'ModelQualityFailureCostShare', 'TotalCostPerVerifiedSuccess',
        'ObservedCostPerVerifiedSuccess', 'MedianCostPerVerifiedSuccess',
        'ExpectedCostPerVerifiedSuccess', 'AverageSuccessfulChainCost',
        'AbsoluteSavings', 'SavingsPercent', 'AvoidedRetryCost', 'FailureCost',
        'BaselineCostPerVerifiedSuccess', 'Policy', 'PolicyVersion', 'SelectedModelId'
    )
    $base = Test-DbM23SecretLeak $Target
    if (-not $base.Leak) { return @{ Leak = $false; Fields = @() } }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($base.Fields)) {
        $name = ($entry -split ' = ')[0]
        if ($name -in $extraExempt) { continue }
        $kept.Add($entry)
    }
    return @{ Leak = ($kept.Count -gt 0); Fields = @($kept) }
}

# --- UTC normalization (DB-M24 ConvertTo-AiPerfUtc reused READ-ONLY) -----------------

# --- QualityCostQuery v1 ---------------------------------------------------------------

function New-DbM25QualityCostQuery {
    <#
    .SYNOPSIS
    Construct a read-only QualityCostQuery v1. Time windows: a preset
    (ALL_TIME | LAST_7_DAYS | LAST_30_DAYS | LAST_90_DAYS) resolved against the
    NowUtc reference (default UtcNow); CUSTOM uses explicit FromUtc/ToUtc (either
    may be null = open). Every dimension is optional; unspecified dimensions do
    not filter. Default SuccessDefinition is VERIFIED (verified success is
    authoritative). RequiresClaudeReview gates success on an accepted review
    status (DB-M20 vocabulary). GroupBy defaults to ModelRoute.
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
        [string]$LocalOrRemote,
        [string]$ReportingCurrency = 'INR',
        [bool]$AllowEstimatedCostFallback = $false,
        [string]$SuccessDefinition = 'VERIFIED',
        [bool]$RequiresClaudeReview = $false,
        [string]$RequiredReviewStatus = 'PASS',
        [string]$GroupBy = 'ModelRoute'
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

    $norm = { param([AllowNull()][string]$v, [string]$case) if ([string]::IsNullOrWhiteSpace($v)) { $null } elseif ($case -eq 'LOWER') { $v.Trim().ToLowerInvariant() } else { $v.Trim().ToUpperInvariant() } }

    return [pscustomobject]@{
        SchemaVersion               = 1
        QueryId                     = $QueryId
        PresetWindow                = $preset
        FromUtc                     = $(if ($from) { $from.ToString('o') } else { $null })
        ToUtc                       = $(if ($to) { $to.ToString('o') } else { $null })
        ProviderId                  = & $norm $ProviderId 'LOWER'
        ModelId                     = & $norm $ModelId 'LOWER'
        UnderlyingModelId           = & $norm $UnderlyingModelId 'LOWER'
        GatewayProviderId           = & $norm $GatewayProviderId 'LOWER'
        TaskType                    = & $norm $TaskType 'UPPER'
        Complexity                  = & $norm $Complexity 'UPPER'
        Risk                        = & $norm $Risk 'UPPER'
        ReasoningLevel              = & $norm $ReasoningLevel 'UPPER'
        ExecutionMode               = & $norm $ExecutionMode 'UPPER'
        LocalOrRemote               = & $norm $LocalOrRemote 'UPPER'
        ReportingCurrency           = $ReportingCurrency.Trim().ToUpperInvariant()
        AllowEstimatedCostFallback  = [bool]$AllowEstimatedCostFallback
        SuccessDefinition           = $SuccessDefinition.ToUpperInvariant()
        RequiresClaudeReview        = [bool]$RequiresClaudeReview
        RequiredReviewStatus        = $RequiredReviewStatus.ToUpperInvariant()
        GroupBy                     = $GroupBy
    }
}

function Test-DbM25QualityCostQuery {
    <#
    .SYNOPSIS
    Deterministic structural validation of a QualityCostQuery v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][object]$Query)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Query) { return @{ Valid = $false; Errors = @('Query is null'); Warnings = @() } }
    if ((Get-ContractProperty $Query 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    $preset = [string](Get-ContractProperty $Query 'PresetWindow' '')
    if ($preset -and -not (Test-IsValidPresetWindow $preset)) { $errors.Add("PresetWindow '$preset' invalid") }
    $sd = [string](Get-ContractProperty $Query 'SuccessDefinition' '')
    if ($sd -and -not (Test-IsValidSuccessDefinition $sd)) { $errors.Add("SuccessDefinition '$sd' invalid") }
    $gb = [string](Get-ContractProperty $Query 'GroupBy' '')
    if ($gb -and -not (Test-IsValidDbM25GroupBy $gb)) { $errors.Add("GroupBy '$gb' invalid") }

    $cur = [string](Get-ContractProperty $Query 'ReportingCurrency' '')
    if ($cur -and $cur -notmatch '^[A-Z]{3}$') { $errors.Add("ReportingCurrency '$cur' must be a 3-letter ISO-4217 code") }

    $from = ConvertTo-AiPerfUtc (Get-ContractProperty $Query 'FromUtc' $null)
    $to = ConvertTo-AiPerfUtc (Get-ContractProperty $Query 'ToUtc' $null)
    if ($from -and $to -and $from -gt $to) { $errors.Add('FromUtc must be <= ToUtc') }

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
    $lr = [string](Get-ContractProperty $Query 'LocalOrRemote' '')
    if ($lr -and $lr -notin (Get-AiRoutingLocalOrRemote)) { $errors.Add("LocalOrRemote '$lr' invalid") }

    $rr = [string](Get-ContractProperty $Query 'RequiredReviewStatus' 'PASS')
    if ($rr -and $rr -notin (Get-DbM25ClaudeReviewStatuses)) { $errors.Add("RequiredReviewStatus '$rr' invalid") }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @() }
}

# --- verified-success resolution (DB-M25 owned) ----------------------------------------

function Resolve-DbM25VerifiedSuccess {
    <#
    .SYNOPSIS
    Resolve whether an attempt's result is a VERIFIED success under the DB-M25
    semantics. Verified success is authoritative:
      - Result must be SUCCESS.
      - Review gate first (when the query requires an accepted Claude review):
        the review status must equal the required accepted status, else
        REVIEW_REJECTED (never a success, never verified).
      - Verification gate: VerificationResult=VERIFIED -> verified;
        FAILED -> Contradicted (a model self-PASS contradicted by independent
        verification is never success); PENDING/absent -> verified only under
        VERIFIED_PREFERRED (flagged model-returned, never verified).
    SuccessDefinition (DB-M24 vocabulary): VERIFIED (authoritative default) /
    VERIFIED_PREFERRED / MODEL_RETURNED.
    Returns @{ Success; Verified; ModelReturned; ReviewRejected; Contradicted;
    ReviewStatus; Reason }.
    #>
    param(
        [AllowNull()][object]$Attempt,
        [string]$SuccessDefinition = 'VERIFIED',
        [bool]$RequiresClaudeReview = $false,
        [string]$RequiredReviewStatus = 'PASS'
    )
    $res = @{ Success = $false; Verified = $false; ModelReturned = $false
              ReviewRejected = $false; Contradicted = $false; ReviewStatus = $null
              Reason = 'NOT_SUCCESS' }
    if ($null -eq $Attempt) { return $res }

    $result = [string](Get-ContractProperty $Attempt 'Result' '')
    if ($result -ne 'SUCCESS') { $res.Reason = 'NOT_SUCCESS'; return $res }

    # review gate (applies to any success claim)
    $reviewStatus = Get-ContractProperty $Attempt 'ClaudeReviewStatus' $null
    if ($null -ne $reviewStatus) { $res.ReviewStatus = [string]$reviewStatus }
    if ($RequiresClaudeReview) {
        if ([string]$res.ReviewStatus -ne $RequiredReviewStatus) {
            $res.ReviewRejected = $true
            $res.Reason = 'REVIEW_REJECTED'
            return $res
        }
    }

    $vr = [string](Get-ContractProperty $Attempt 'VerificationResult' '')
    $verified = ($vr -eq 'VERIFIED')
    $contradicted = ($vr -eq 'FAILED')
    $success = $false
    switch ($SuccessDefinition) {
        'MODEL_RETURNED'     { $success = $true }
        'VERIFIED_PREFERRED' { $success = (-not $contradicted) }
        default              { $success = $verified }   # 'VERIFIED' (authoritative)
    }
    if ($contradicted) { $res.Reason = 'VERIFICATION_CONTRADICTED' }
    elseif ($success -and $verified) { $res.Reason = 'VERIFIED' }
    elseif ($success) { $res.Reason = 'MODEL_RETURNED' }
    else { $res.Reason = 'NOT_VERIFIED' }
    $res.Success = $success
    $res.Verified = $verified
    $res.ModelReturned = ($success -and -not $verified)
    $res.Contradicted = $contradicted
    return $res
}

# --- QualityAdjustedCostResult v1 --------------------------------------------------------

function New-DbM25QualityAdjustedCostResult {
    <#
    .SYNOPSIS
    Construct a QualityAdjustedCostResult v1 from a hashtable of computed fields.
    SchemaVersion is stamped here; unknown/absent fields stay null. The engine
    (QualityCost.ps1) computes the aggregates; this constructor is also used
    directly by tests to build fixture results.
    #>
    param([AllowNull()][hashtable]$Fields)
    if ($null -eq $Fields) { $Fields = @{} }
    function Get-Field([string]$Name, $Default = $null) {
        if ($Fields.ContainsKey($Name)) { return $Fields[$Name] }
        return $Default
    }
    return [pscustomobject]@{
        SchemaVersion                      = 1
        AnalysisId                         = Get-Field 'AnalysisId'
        GroupBy                            = Get-Field 'GroupBy'
        GroupKey                           = Get-Field 'GroupKey'
        ProviderId                         = Get-Field 'ProviderId'
        ModelId                            = Get-Field 'ModelId'
        UnderlyingModelId                  = Get-Field 'UnderlyingModelId'
        GatewayProviderId                  = Get-Field 'GatewayProviderId'
        LocalOrRemote                      = Get-Field 'LocalOrRemote'
        TaskType                           = Get-Field 'TaskType'
        Complexity                         = Get-Field 'Complexity'
        Risk                               = Get-Field 'Risk'
        ReasoningLevel                     = Get-Field 'ReasoningLevel'
        ExecutionMode                      = Get-Field 'ExecutionMode'
        SampleCount                        = Get-Field 'SampleCount' 0
        AttemptCount                       = Get-Field 'AttemptCount' 0
        VerifiedSuccessCount               = Get-Field 'VerifiedSuccessCount' 0
        ModelReturnedSuccessCount          = Get-Field 'ModelReturnedSuccessCount' 0
        FailedChainCount                   = Get-Field 'FailedChainCount' 0
        IncompleteChainCount               = Get-Field 'IncompleteChainCount' 0
        FirstAttemptVerifiedSuccessCount   = Get-Field 'FirstAttemptVerifiedSuccessCount' 0
        VerifiedSuccessRate                = Get-Field 'VerifiedSuccessRate'
        FirstAttemptVerifiedSuccessRate    = Get-Field 'FirstAttemptVerifiedSuccessRate'
        AverageAttemptsPerVerifiedSuccess  = Get-Field 'AverageAttemptsPerVerifiedSuccess'
        MedianAttemptsPerVerifiedSuccess   = Get-Field 'MedianAttemptsPerVerifiedSuccess'
        AverageAttemptCost                 = Get-Field 'AverageAttemptCost'
        MedianAttemptCost                  = Get-Field 'MedianAttemptCost'
        TotalAttemptCost                   = Get-Field 'TotalAttemptCost' 0
        FailedAttemptCost                  = Get-Field 'FailedAttemptCost' 0
        FailedAttemptCostShare             = Get-Field 'FailedAttemptCostShare'
        EscalationCost                     = Get-Field 'EscalationCost' 0
        EscalationCostShare                = Get-Field 'EscalationCostShare'
        EscalatedChainCost                 = Get-Field 'EscalatedChainCost'
        AverageCorrectionCost              = Get-Field 'AverageCorrectionCost'
        ProviderFailureCost                = Get-Field 'ProviderFailureCost' 0
        ProviderFailureCostShare           = Get-Field 'ProviderFailureCostShare'
        ModelQualityFailureCost            = Get-Field 'ModelQualityFailureCost' 0
        ModelQualityFailureCostShare       = Get-Field 'ModelQualityFailureCostShare'
        FailureCategoryCosts               = Get-Field 'FailureCategoryCosts' @{}
        TotalCostPerVerifiedSuccess        = Get-Field 'TotalCostPerVerifiedSuccess'
        ObservedCostPerVerifiedSuccess     = Get-Field 'ObservedCostPerVerifiedSuccess'
        MedianCostPerVerifiedSuccess       = Get-Field 'MedianCostPerVerifiedSuccess'
        ExpectedCostPerVerifiedSuccess     = Get-Field 'ExpectedCostPerVerifiedSuccess'
        ExpectedCostBasis                  = Get-Field 'ExpectedCostBasis'
        AverageSuccessfulChainCost         = Get-Field 'AverageSuccessfulChainCost'
        LocalCostStatus                    = Get-Field 'LocalCostStatus'
        OperationalCostUnknown             = Get-Field 'OperationalCostUnknown' $false
        Currency                           = Get-Field 'Currency' 'INR'
        EstimatedCostFallbackUsed          = Get-Field 'EstimatedCostFallbackUsed' 0
        CostExcludedCount                  = Get-Field 'CostExcludedCount' 0
        ConfidenceLevel                    = Get-Field 'ConfidenceLevel' 'INSUFFICIENT'
        SuccessDefinition                  = Get-Field 'SuccessDefinition' 'VERIFIED'
        EvidenceReferences                 = @(Get-Field 'EvidenceReferences' @())
        WindowStartUtc                     = Get-Field 'WindowStartUtc'
        WindowEndUtc                       = Get-Field 'WindowEndUtc'
        GeneratedAtUtc                     = Get-Field 'GeneratedAtUtc'
        Warnings                           = @(Get-Field 'Warnings' @())
    }
}

function Test-DbM25QualityAdjustedCostResult {
    <#
    .SYNOPSIS
    Deterministic structural validation of a QualityAdjustedCostResult v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][object]$Result)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Result) { return @{ Valid = $false; Errors = @('Result is null'); Warnings = @() } }
    if ((Get-ContractProperty $Result 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    $sample = Get-ContractProperty $Result 'SampleCount' $null
    if ($null -eq $sample -or $sample -lt 0) { $errors.Add('SampleCount must be a non-negative integer') }
    $att = Get-ContractProperty $Result 'AttemptCount' $null
    if ($null -ne $att -and $att -lt 0) { $errors.Add('AttemptCount must be >= 0') }
    foreach ($cnt in @('VerifiedSuccessCount', 'ModelReturnedSuccessCount', 'FailedChainCount',
                       'IncompleteChainCount', 'FirstAttemptVerifiedSuccessCount')) {
        $v = Get-ContractProperty $Result $cnt $null
        if ($null -ne $v -and $v -lt 0) { $errors.Add("$cnt must be >= 0") }
    }
    foreach ($rate in @('VerifiedSuccessRate', 'FirstAttemptVerifiedSuccessRate')) {
        $v = Get-ContractProperty $Result $rate $null
        if ($null -ne $v -and ($v -lt 0 -or $v -gt 1)) { $errors.Add("$rate must be within 0..1") }
    }
    foreach ($share in @('FailedAttemptCostShare', 'EscalationCostShare', 'ProviderFailureCostShare',
                         'ModelQualityFailureCostShare')) {
        $v = Get-ContractProperty $Result $share $null
        if ($null -ne $v -and ($v -lt 0 -or $v -gt 1)) { $errors.Add("$share must be within 0..1") }
    }
    $conf = [string](Get-ContractProperty $Result 'ConfidenceLevel' '')
    if ($conf -and -not (Test-IsValidConfidenceLevel $conf)) { $errors.Add("ConfidenceLevel '$conf' invalid") }
    $sd = [string](Get-ContractProperty $Result 'SuccessDefinition' '')
    if ($sd -and -not (Test-IsValidSuccessDefinition $sd)) { $errors.Add("SuccessDefinition '$sd' invalid") }
    $cs = [string](Get-ContractProperty $Result 'LocalCostStatus' '')
    if ($cs -and -not (Test-IsValidDbM23PriceStatus $cs)) { $errors.Add("LocalCostStatus '$cs' invalid") }
    $basis = [string](Get-ContractProperty $Result 'ExpectedCostBasis' '')
    if ($basis -and -not (Test-IsValidDbM25ExpectedCostBasis $basis)) { $errors.Add("ExpectedCostBasis '$basis' invalid") }

    $leak = Test-DbM25SecretLeak $Result
    if ($leak.Leak) { $errors.Add("secret-like value detected in result: $($leak.Fields -join '; ')") }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @() }
}

# --- SavingsAnalysis v1 -------------------------------------------------------------------

function New-DbM25SavingsAnalysis {
    <#
    .SYNOPSIS
    Construct a SavingsAnalysis v1 from a field table. Savings compare equivalent
    verified outcomes (both candidate and baseline cost-per-verified-success come
    from verified successes); the baseline type is explicit; the basis labels
    observed vs estimated/counterfactual data.
    #>
    param([AllowNull()][hashtable]$Fields)
    if ($null -eq $Fields) { $Fields = @{} }
    function Get-Field([string]$Name, $Default = $null) {
        if ($Fields.ContainsKey($Name)) { return $Fields[$Name] }
        return $Default
    }
    return [pscustomobject]@{
        SchemaVersion                   = 1
        AnalysisId                      = Get-Field 'AnalysisId'
        Scope                           = Get-Field 'Scope'
        TaskType                        = Get-Field 'TaskType'
        Complexity                      = Get-Field 'Complexity'
        Risk                            = Get-Field 'Risk'
        CandidateProviderId             = Get-Field 'CandidateProviderId'
        CandidateModelId                = Get-Field 'CandidateModelId'
        CandidateUnderlyingModelId      = Get-Field 'CandidateUnderlyingModelId'
        CandidateGatewayProviderId      = Get-Field 'CandidateGatewayProviderId'
        CandidateLocalOrRemote          = Get-Field 'CandidateLocalOrRemote'
        CandidateRoute                  = Get-Field 'CandidateRoute'
        BaselineProviderId              = Get-Field 'BaselineProviderId'
        BaselineModelId                 = Get-Field 'BaselineModelId'
        BaselineUnderlyingModelId       = Get-Field 'BaselineUnderlyingModelId'
        BaselineGatewayProviderId       = Get-Field 'BaselineGatewayProviderId'
        BaselineLocalOrRemote           = Get-Field 'BaselineLocalOrRemote'
        BaselineRoute                   = Get-Field 'BaselineRoute'
        BaselineType                    = Get-Field 'BaselineType'
        BaselineLabel                   = Get-Field 'BaselineLabel'
        BaselineBasis                   = Get-Field 'BaselineBasis' 'OBSERVED'
        SampleSize                      = Get-Field 'SampleSize' 0
        Confidence                      = Get-Field 'Confidence' 'INSUFFICIENT'
        AverageAttemptCost              = Get-Field 'AverageAttemptCost'
        AttemptsPerVerifiedSuccess      = Get-Field 'AttemptsPerVerifiedSuccess'
        VerifiedSuccessRate             = Get-Field 'VerifiedSuccessRate'
        FirstAttemptSuccessRate         = Get-Field 'FirstAttemptSuccessRate'
        ObservedCostPerVerifiedSuccess  = Get-Field 'ObservedCostPerVerifiedSuccess'
        ExpectedCostPerVerifiedSuccess  = Get-Field 'ExpectedCostPerVerifiedSuccess'
        BaselineCostPerVerifiedSuccess  = Get-Field 'BaselineCostPerVerifiedSuccess'
        AbsoluteSavings                 = Get-Field 'AbsoluteSavings'
        SavingsPercent                  = Get-Field 'SavingsPercent'
        AvoidedRetryCost                = Get-Field 'AvoidedRetryCost'
        EscalationCost                  = Get-Field 'EscalationCost' 0
        FailureCost                     = Get-Field 'FailureCost' 0
        ProviderFailureCost             = Get-Field 'ProviderFailureCost' 0
        ModelQualityFailureCost         = Get-Field 'ModelQualityFailureCost' 0
        Currency                        = Get-Field 'Currency' 'INR'
        EvidenceReferences              = @(Get-Field 'EvidenceReferences' @())
        WindowStartUtc                  = Get-Field 'WindowStartUtc'
        WindowEndUtc                    = Get-Field 'WindowEndUtc'
        GeneratedAtUtc                  = Get-Field 'GeneratedAtUtc'
        Warnings                        = @(Get-Field 'Warnings' @())
    }
}

function Test-DbM25SavingsAnalysis {
    <#
    .SYNOPSIS
    Deterministic structural validation of a SavingsAnalysis v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][object]$Analysis)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Analysis) { return @{ Valid = $false; Errors = @('Analysis is null'); Warnings = @() } }
    if ((Get-ContractProperty $Analysis 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    $bt = [string](Get-ContractProperty $Analysis 'BaselineType' '')
    if ($bt -and -not (Test-IsValidDbM25BaselineType $bt)) { $errors.Add("BaselineType '$bt' invalid") }
    $bb = [string](Get-ContractProperty $Analysis 'BaselineBasis' '')
    if ($bb -and -not (Test-IsValidDbM25BaselineBasis $bb)) { $errors.Add("BaselineBasis '$bb' invalid") }
    $conf = [string](Get-ContractProperty $Analysis 'Confidence' '')
    if ($conf -and -not (Test-IsValidConfidenceLevel $conf)) { $errors.Add("Confidence '$conf' invalid") }

    $abs = Get-ContractProperty $Analysis 'AbsoluteSavings' $null
    $pct = Get-ContractProperty $Analysis 'SavingsPercent' $null
    $baseline = Get-ContractProperty $Analysis 'BaselineCostPerVerifiedSuccess' $null
    if ($null -ne $abs -and $null -eq $baseline) { $errors.Add('AbsoluteSavings present but BaselineCostPerVerifiedSuccess is null (savings need both sides)') }
    if ($null -ne $pct -and $null -eq $abs) { $errors.Add('SavingsPercent present but AbsoluteSavings is null') }

    $leak = Test-DbM25SecretLeak $Analysis
    if ($leak.Leak) { $errors.Add("secret-like value detected in savings analysis: $($leak.Fields -join '; ')") }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @() }
}

# --- PolicyComparison v1 ------------------------------------------------------------------

function New-DbM25PolicyComparison {
    <#
    .SYNOPSIS
    Construct a PolicyComparison v1. Rows are ranked by cost-per-verified-success
    (presentation only). PolicyVersion stays the immutable '0.0.0'; DB-M25 never
    alters live policy. Each row carries its basis (OBSERVED when it is the
    actually-used default, otherwise COUNTERFACTUAL).
    #>
    param(
        [string]$AnalysisId,
        [AllowNull()][object[]]$Rows = @(),
        [string]$Currency = 'INR',
        [string]$PolicyVersion = '0.0.0'
    )
    return [pscustomobject]@{
        SchemaVersion   = 1
        AnalysisId      = $AnalysisId
        ComparedCount   = @($Rows).Count
        Rows            = @($Rows)
        Currency        = $Currency
        PolicyVersion   = $PolicyVersion
        GeneratedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Test-DbM25PolicyComparison {
    param([AllowNull()][object]$Comparison)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Comparison) { return @{ Valid = $false; Errors = @('Comparison is null'); Warnings = @() } }
    if ((Get-ContractProperty $Comparison 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if ((Get-ContractProperty $Comparison 'ComparedCount' -1) -lt 0) { $errors.Add('ComparedCount must be >= 0') }
    $rows = @(Get-ContractProperty $Comparison 'Rows' @())
    foreach ($r in $rows) {
        $policy = [string](Get-ContractProperty $r 'Policy' '')
        if ($policy -and -not (Test-IsValidDbM25PolicyType $policy)) { $errors.Add("Policy '$policy' invalid") }
        $basis = [string](Get-ContractProperty $r 'Basis' '')
        if ($basis -and -not (Test-IsValidDbM25BaselineBasis $basis)) { $errors.Add("Basis '$basis' invalid") }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @() }
}

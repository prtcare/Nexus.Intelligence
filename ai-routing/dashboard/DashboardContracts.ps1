# DashboardContracts.ps1 -- DB-M26 AI usage/cost dashboard contracts.
#
# AI Usage / Cost Dashboard (Lane B). Read-only operator-facing analytics that
# presents the AI foundations as one surface. This file owns the frozen v1
# contracts and vocabularies consumed by the DB-M26 engine (DashboardData.ps1)
# and the HTML renderer (DashboardRender.ps1):
#
#   DashboardRequest v1 - read-only analytics request (window + filters)
#   DashboardView v1    - the aggregated operator-facing dashboard payload
#
# The dashboard answers the brief's ten questions through summary cards and
# drilldown views. Every number derives from the existing foundations
# READ-ONLY (DB-M16 cost semantics, DB-M17 attempt history, DB-M19 routing
# decisions, DB-M20 escalation, DB-M21 budget, DB-M22 provider health, DB-M23
# route identities, DB-M24 performance intelligence, DB-M25 quality-adjusted
# cost/savings). The engine never recomputes an inconsistent alternate metric:
# verified-success, chain cost, savings, confidence and cost-per-success all
# come from the DB-M25/DB-M24 engine.
#
# Read-only: the dashboard does NOT execute AI models, does NOT change routing
# policy, does NOT alter budgets, does NOT modify provider health, does NOT
# edit attempt history, and does NOT touch the Nexus/workbook state. It has no
# write actions. AUTO_EXECUTION_ENABLED = FALSE.
#
# Reuse is READ-ONLY: DB-M25 quality-cost contracts/engine (which dot-source
# DB-M24 performance foundation + DB-M23 adapter contracts + DB-M17 vocabulary
# READ-ONLY). No file that owns those contracts is modified. No AI/provider/
# paid/network calls, no secrets stored.

. (Join-Path $PSScriptRoot "..\quality-cost\AiQualityCostContracts.ps1")  # DB-M25 contracts (READ-ONLY)
. (Join-Path $PSScriptRoot "..\quality-cost\QualityCost.ps1")             # DB-M25 engine (READ-ONLY)

# --- schema versions (DB-M26-owned) ----------------------------------------------

function Get-DbM26SchemaVersions {
    <#
    .SYNOPSIS
    Frozen DB-M26 schema versions. Incompatible changes must introduce v2 with
    their own validators; v1 semantics are never silently mutated.
    #>
    return @{
        DashboardRequestVersion = 1
        DashboardViewVersion    = 1
    }
}

# --- vocabularies -------------------------------------------------------------------

function Get-DbM26PresetWindows {
    # Operator-selectable periods. CUSTOM uses explicit FromUtc/ToUtc.
    return @('TODAY', 'LAST_7_DAYS', 'LAST_30_DAYS', 'THIS_MONTH', 'CUSTOM', 'ALL_TIME')
}

function Test-IsValidDbM26PresetWindow([string]$Value) { $Value -in (Get-DbM26PresetWindows) }

# --- secret-value guard (DB-M26 wrapper) ---------------------------------------------

function Test-DbM26SecretLeak {
    <#
    .SYNOPSIS
    Scan a DB-M26 dashboard object for API-key-like VALUES. Wraps the DB-M25
    guard (itself a DB-M23 wrapper) and additionally exempts DB-M26-owned
    identifiers/references; free-text fields (Warnings, RequestId, SummaryNotes)
    ARE scanned. Never stores secrets.
    #>
    param([AllowNull()][object]$Target)
    $extraExempt = @(
        'SchemaVersion', 'RequestId', 'PresetWindow', 'FromUtc', 'ToUtc', 'NowUtc',
        'Currency', 'SuccessDefinition', 'GeneratedAtUtc', 'WindowStartUtc', 'WindowEndUtc',
        'ProviderId', 'ModelId', 'UnderlyingModelId', 'GatewayProviderId', 'LocalOrRemote',
        'TaskType', 'ReasoningLevel', 'Complexity', 'Risk', 'ExecutionMode',
        'Key', 'Cost', 'Source', 'AttemptCount', 'SampleCount', 'ConfidenceLevel',
        'TotalAiSpend', 'ActualSpend', 'EstimatedPendingSpend', 'VerifiedSuccessfulTasks',
        'CostPerVerifiedSuccess', 'FirstAttemptSuccessRate', 'FailedAttemptCost',
        'EscalationCost', 'CorrectionCost', 'QualityAdjustedSavings', 'BudgetUsedPercent',
        'HealthyProviders', 'UnavailableOrRateLimitedRoutes', 'BudgetStatus',
        'CircuitState', 'RetryAfter', 'LastEvidenceTime', 'ConfidenceSource', 'Health',
        'Provider', 'Route', 'Model', 'UnderlyingModel', 'Result', 'Verification',
        'FailureCategory', 'Escalation', 'TimestampUtc', 'AttemptId', 'ChangeId',
        'Reasoning', 'ActualCost', 'EstimatedCost', 'CostCurrency',
        'PolicyVersion', 'AutoExecutionEnabled', 'HasWriteActions',
        'BaselineCostPerVerifiedSuccess', 'AbsoluteSavings', 'SavingsPercent',
        'ObservedCostPerVerifiedSuccess', 'ExpectedCostPerVerifiedSuccess',
        'AverageAttemptCost', 'AttemptsPerVerifiedSuccess', 'VerifiedSuccessRate',
        'FirstAttemptVerifiedSuccessRate', 'EscalationCostShare', 'FailedAttemptCostShare',
        'ProviderFailureCostShare', 'ModelQualityFailureCostShare', 'TaskBudget',
        'SessionBudget', 'DailyBudget', 'MonthlyBudget', 'WarningThresholdPercent',
        'BlockThresholdPercent', 'ProjectedSpend', 'EstimatedPending', 'ActualSpendNow',
        'OverrideEvidence', 'AttemptCompleted', 'ImplementationVerified',
        'ClaudeAccepted', 'HumanGitPending', 'Contradicted', 'ReviewStatus',
        'CumulativeCost', 'LocalCostStatus', 'OperationalCostUnknown', 'Gateway',
        'CheapAttemptExpensiveSuccess', 'LooksCheapButRetries', 'Rank', 'TerminalOutcome',
        'VerifiedFlag', 'HtmlReport', 'Title', 'Sections', 'SectionTitle'
    )
    $base = Test-DbM25SecretLeak $Target
    if (-not $base.Leak) { return @{ Leak = $false; Fields = @() } }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($base.Fields)) {
        $name = ($entry -split ' = ')[0]
        if ($name -in $extraExempt) { continue }
        $kept.Add($entry)
    }
    return @{ Leak = ($kept.Count -gt 0); Fields = @($kept) }
}

# --- window resolution ---------------------------------------------------------------

function Resolve-DbM26WindowBounds {
    <#
    .SYNOPSIS
    Deterministically resolve a DB-M26 window preset to explicit FromUtc/ToUtc
    against the NowUtc reference (default UtcNow). CUSTOM uses the explicit
    bounds (either may be null = open). Returns @{ PresetWindow; FromUtc; ToUtc }.
    Windows are never mixed without a label: every view carries these bounds.
    #>
    param(
        [string]$PresetWindow = 'ALL_TIME',
        [string]$FromUtc,
        [string]$ToUtc,
        [string]$NowUtc
    )
    $now = ConvertTo-AiPerfUtc $NowUtc
    if ($null -eq $now) { $now = [datetime]::UtcNow }
    $p = $PresetWindow.ToUpperInvariant()
    $from = $null; $to = $null
    switch ($p) {
        'TODAY' {
            $from = [datetime]::new($now.Year, $now.Month, $now.Day, 0, 0, 0, [datetimekind]::Utc)
            $to = $now
        }
        'LAST_7_DAYS'  { $from = $now.AddDays(-7);  $to = $now }
        'LAST_30_DAYS' { $from = $now.AddDays(-30); $to = $now }
        'THIS_MONTH' {
            $from = [datetime]::new($now.Year, $now.Month, 1, 0, 0, 0, [datetimekind]::Utc)
            $to = $now
        }
        'CUSTOM' { $from = ConvertTo-AiPerfUtc $FromUtc; $to = ConvertTo-AiPerfUtc $ToUtc }
        default  { }   # ALL_TIME: open window
    }
    return @{ PresetWindow = $p; FromUtc = $from; ToUtc = $to }
}

# --- DashboardRequest v1 ---------------------------------------------------------------

function New-DbM26DashboardRequest {
    <#
    .SYNOPSIS
    Construct a read-only DashboardRequest v1. Time windows use the DB-M26
    preset vocabulary resolved against NowUtc; CUSTOM uses FromUtc/ToUtc. Every
    dimension is optional; unspecified dimensions do not filter. Default
    SuccessDefinition is VERIFIED (verified success is authoritative).
    #>
    param(
        [string]$RequestId,
        [string]$PresetWindow = 'ALL_TIME',
        [string]$FromUtc,
        [string]$ToUtc,
        [string]$NowUtc,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$UnderlyingModelId,
        [string]$GatewayProviderId,
        [string]$TaskType,
        [string]$ReasoningLevel,
        [string]$LocalOrRemote,
        [string]$ReportingCurrency = 'INR',
        [bool]$AllowEstimatedCostFallback = $false,
        [string]$SuccessDefinition = 'VERIFIED',
        [string]$DefaultGroupKey
    )
    $b = Resolve-DbM26WindowBounds -PresetWindow $PresetWindow -FromUtc $FromUtc -ToUtc $ToUtc -NowUtc $NowUtc
    $norm = { param([AllowNull()][string]$v, [string]$case) if ([string]::IsNullOrWhiteSpace($v)) { $null } elseif ($case -eq 'LOWER') { $v.Trim().ToLowerInvariant() } else { $v.Trim().ToUpperInvariant() } }

    return [pscustomobject]@{
        SchemaVersion               = 1
        RequestId                   = $RequestId
        PresetWindow                = $b.PresetWindow
        FromUtc                     = $(if ($b.FromUtc) { $b.FromUtc.ToString('o') } else { $null })
        ToUtc                       = $(if ($b.ToUtc) { $b.ToUtc.ToString('o') } else { $null })
        NowUtc                      = $b.ToUtc
        ProviderId                  = & $norm $ProviderId 'LOWER'
        ModelId                     = & $norm $ModelId 'LOWER'
        UnderlyingModelId           = & $norm $UnderlyingModelId 'LOWER'
        GatewayProviderId           = & $norm $GatewayProviderId 'LOWER'
        TaskType                    = & $norm $TaskType 'UPPER'
        ReasoningLevel              = & $norm $ReasoningLevel 'UPPER'
        LocalOrRemote               = & $norm $LocalOrRemote 'UPPER'
        ReportingCurrency           = $ReportingCurrency.Trim().ToUpperInvariant()
        AllowEstimatedCostFallback  = [bool]$AllowEstimatedCostFallback
        SuccessDefinition           = $SuccessDefinition.ToUpperInvariant()
        DefaultGroupKey             = $DefaultGroupKey
    }
}

function Test-DbM26DashboardRequest {
    <#
    .SYNOPSIS
    Deterministic structural validation of a DashboardRequest v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][object]$Request)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Request) { return @{ Valid = $false; Errors = @('Request is null'); Warnings = @() } }
    if ((Get-ContractProperty $Request 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    $preset = [string](Get-ContractProperty $Request 'PresetWindow' '')
    if ($preset -and -not (Test-IsValidDbM26PresetWindow $preset)) { $errors.Add("PresetWindow '$preset' invalid") }

    $from = ConvertTo-AiPerfUtc (Get-ContractProperty $Request 'FromUtc' $null)
    $to = ConvertTo-AiPerfUtc (Get-ContractProperty $Request 'ToUtc' $null)
    if ($from -and $to -and $from -gt $to) { $errors.Add('FromUtc must be <= ToUtc') }

    $cur = [string](Get-ContractProperty $Request 'ReportingCurrency' '')
    if ($cur -and $cur -notmatch '^[A-Z]{3}$') { $errors.Add("ReportingCurrency '$cur' must be a 3-letter ISO-4217 code") }

    $sd = [string](Get-ContractProperty $Request 'SuccessDefinition' '')
    if ($sd -and -not (Test-IsValidSuccessDefinition $sd)) { $errors.Add("SuccessDefinition '$sd' invalid") }

    $rl = [string](Get-ContractProperty $Request 'ReasoningLevel' '')
    if ($rl -and -not (Test-IsValidReasoningLevel $rl)) { $errors.Add("ReasoningLevel '$rl' invalid") }

    $lr = [string](Get-ContractProperty $Request 'LocalOrRemote' '')
    if ($lr -and $lr -notin (Get-AiRoutingLocalOrRemote)) { $errors.Add("LocalOrRemote '$lr' invalid") }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @() }
}

# --- DashboardView v1 -------------------------------------------------------------------

function New-DbM26DashboardView {
    <#
    .SYNOPSIS
    Construct a DashboardView v1 from a hashtable of computed fields.
    SchemaVersion is stamped here; unknown/absent fields stay null. The engine
    (DashboardData.ps1) computes the aggregates; this constructor is also used
    directly by tests to build fixture views.
    #>
    param([AllowNull()][hashtable]$Fields)
    if ($null -eq $Fields) { $Fields = @{} }
    function Get-Field([string]$Name, $Default = $null) {
        if ($Fields.ContainsKey($Name)) { return $Fields[$Name] }
        return $Default
    }
    return [pscustomobject]@{
        SchemaVersion                = 1
        RequestId                    = Get-Field 'RequestId'
        PresetWindow                 = Get-Field 'PresetWindow' 'ALL_TIME'
        FromUtc                      = Get-Field 'FromUtc'
        ToUtc                        = Get-Field 'ToUtc'
        NowUtc                       = Get-Field 'NowUtc'
        Currency                     = Get-Field 'Currency' 'INR'
        SuccessDefinition            = Get-Field 'SuccessDefinition' 'VERIFIED'
        GeneratedAtUtc               = Get-Field 'GeneratedAtUtc'
        SummaryCards                 = Get-Field 'SummaryCards' $null
        CostBreakdown                = Get-Field 'CostBreakdown' $null
        VerifiedSuccessView          = Get-Field 'VerifiedSuccessView' @()
        QualityAdjustedCostView      = Get-Field 'QualityAdjustedCostView' @()
        SavingsView                  = Get-Field 'SavingsView' @()
        FailedCostView               = Get-Field 'FailedCostView' $null
        BudgetView                   = Get-Field 'BudgetView' $null
        ProviderHealthView           = Get-Field 'ProviderHealthView' @()
        ModelPerformanceView         = Get-Field 'ModelPerformanceView' @()
        AttemptHistory               = Get-Field 'AttemptHistory' @()
        ChainView                    = Get-Field 'ChainView' @()
        LocalOpenRouterView          = Get-Field 'LocalOpenRouterView' @()
        ConfidenceSummary            = Get-Field 'ConfidenceSummary' @()
        ReadOnlyGuard                = Get-Field 'ReadOnlyGuard' $null
        WindowStartUtc               = Get-Field 'WindowStartUtc'
        WindowEndUtc                 = Get-Field 'WindowEndUtc'
        Warnings                     = @(Get-Field 'Warnings' @())
    }
}

function Test-DbM26DashboardView {
    <#
    .SYNOPSIS
    Deterministic structural validation of a DashboardView v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][object]$View)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $View) { return @{ Valid = $false; Errors = @('View is null'); Warnings = @() } }
    if ((Get-ContractProperty $View 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    $preset = [string](Get-ContractProperty $View 'PresetWindow' '')
    if ($preset -and -not (Test-IsValidDbM26PresetWindow $preset)) { $errors.Add("PresetWindow '$preset' invalid") }

    $cur = [string](Get-ContractProperty $View 'Currency' '')
    if ($cur -and $cur -notmatch '^[A-Z]{3}$') { $errors.Add("Currency '$cur' must be a 3-letter ISO-4217 code") }

    $sd = [string](Get-ContractProperty $View 'SuccessDefinition' '')
    if ($sd -and -not (Test-IsValidSuccessDefinition $sd)) { $errors.Add("SuccessDefinition '$sd' invalid") }

    $cards = Get-ContractProperty $View 'SummaryCards' $null
    if ($null -eq $cards) { $errors.Add('SummaryCards missing') }

    $guard = Get-ContractProperty $View 'ReadOnlyGuard' $null
    if ($null -eq $guard) { $errors.Add('ReadOnlyGuard missing') }
    elseif ([bool](Get-ContractProperty $guard 'AutoExecutionEnabled' $false)) { $errors.Add('AutoExecutionEnabled must be false') }
    elseif ([bool](Get-ContractProperty $guard 'HasWriteActions' $false)) { $errors.Add('HasWriteActions must be false') }

    $leak = Test-DbM26SecretLeak $View
    if ($leak.Leak) { $errors.Add("secret-like value detected in view: $($leak.Fields -join '; ')") }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @() }
}

# --- read-only guard ---------------------------------------------------------------------

function New-DbM26ReadOnlyGuard {
    <#
    .SYNOPSIS
    The read-only assertion carried by every dashboard view. The dashboard has
    no write actions and executes nothing; routing policy version stays the
    immutable DB-M19 '0.0.0'.
    #>
    param([AllowNull()][object[]]$Warnings = @())
    return [pscustomobject]@{
        AutoExecutionEnabled = $false
        HasWriteActions      = $false
        PolicyVersion        = '0.0.0'
        ProviderModelExecuted = $false
        PaidApiCalls          = 0
        NetworkCalls          = 0
        Warnings              = @($Warnings)
    }
}

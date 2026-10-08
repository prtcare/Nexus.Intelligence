# BudgetEngine.ps1 -- DB-M21 Part A budget decision engine.
#
# DB-M21 is a CONTROL / DECISION FOUNDATION. It consumes cost evidence from the
# DB-M16 engine / DB-M17 attempt history / DB-M20 escalation decision and
# decides whether a proposed AI attempt is allowed under a BudgetPolicy v1.
# It NEVER calculates model prices, NEVER executes a provider/model, makes no
# paid API call and no network call. AUTO_EXECUTION_ENABLED = FALSE.
#
# The cost math is NOT duplicated here. Spend comes from DB-M17 records
# (ActualCost preferred, EstimatedCost only when no actual); the proposed
# attempt cost comes from the caller (DB-M20 decision / DB-M19 estimate).
# Currency conversion reuses the DB-M16 exchange-rate catalogue -- no invented
# rates; an unavailable conversion is surfaced as controlled uncertainty.
#
# Budget is for AI/provider execution, not elapsed workflow time. Human Git /
# governance gates consume NO AI budget (Purpose != AI_ATTEMPT -> ALLOW).

. (Join-Path $PSScriptRoot "BudgetPolicy.ps1")
. (Join-Path $PSScriptRoot "..\AiRoutingCostFoundation.ps1")   # DB-M14 + DB-M15 + DB-M16 cost engine (READ-ONLY)

# -----------------------------------------------------------------------------
# Deterministic day/month windows (injected timestamp, never machine-local now)
# -----------------------------------------------------------------------------
function Get-DbM21DayWindow {
    <#
    .SYNOPSIS
    The accounting day [start, end) containing the injected evaluation
    timestamp, in UTC + AccountingUtcOffsetHours. Deterministic: derived from the
    timestamp parameter, never from the machine clock.
    #>
    param($TimestampUtc, [double]$OffsetHours = 0)
    $ts = ConvertTo-AiUtc $TimestampUtc
    $shifted = $ts.AddHours($OffsetHours)
    $dayStartLocal = $shifted.Date
    $startUtc = $dayStartLocal.AddHours(-$OffsetHours)
    return @{ StartUtc = $startUtc; EndUtc = $startUtc.AddDays(1); Label = "day=$($dayStartLocal.ToString('yyyy-MM-dd'))" }
}

function Get-DbM21MonthWindow {
    param($TimestampUtc, [double]$OffsetHours = 0)
    $ts = ConvertTo-AiUtc $TimestampUtc
    $shifted = $ts.AddHours($OffsetHours)
    $monthStartLocal = (New-Object datetime($shifted.Year, $shifted.Month, 1))
    $startUtc = $monthStartLocal.AddHours(-$OffsetHours)
    return @{ StartUtc = $startUtc; EndUtc = $startUtc.AddMonths(1); Label = "month=$($monthStartLocal.ToString('yyyy-MM'))" }
}

# -----------------------------------------------------------------------------
# Currency conversion (DB-M16 evidence only, never an invented rate)
# -----------------------------------------------------------------------------
function Convert-DbM21ToPolicyCurrency {
    <#
    .SYNOPSIS
    Convert an amount into the target currency using an applicable DB-M16
    exchange-rate record. An explicit ExchangeRate wins; otherwise the catalogue
    is consulted at the given timestamp. Returns @{ Amount; Rate; ExchangeRateId;
    Converted; ConversionUnavailable; SourceCurrency }.
    #>
    param(
        [AllowNull()]$Amount,
        [AllowNull()][string]$AmountCurrency,
        [string]$TargetCurrency,
        $TimestampUtc,
        [AllowNull()][object]$Configuration,
        [AllowNull()][Nullable[decimal]]$ExchangeRate
    )
    if ($null -eq $Amount) { return @{ Amount = $null; Rate = $null; ExchangeRateId = $null; Converted = $false; ConversionUnavailable = $false; SourceCurrency = $AmountCurrency } }
    $target = $TargetCurrency.Trim().ToUpperInvariant()
    $src = if ($AmountCurrency) { $AmountCurrency.Trim().ToUpperInvariant() } else { '' }
    if (-not $src) { return @{ Amount = $null; Rate = $null; ExchangeRateId = $null; Converted = $false; ConversionUnavailable = $true; SourceCurrency = $null } }
    if ($src -eq $target) {
        return @{ Amount = [double]$Amount; Rate = 1.0; ExchangeRateId = $null; Converted = $true; ConversionUnavailable = $false; SourceCurrency = $src }
    }
    $rate = $null
    $rateId = $null
    if ($null -ne $ExchangeRate -and $ExchangeRate -gt 0) {
        $rate = [double]$ExchangeRate
    } else {
        $fx = Get-ContractProperty $Configuration 'ExchangeRates' $null
        $rec = Get-AiExchangeRateAt -Catalogue $fx -BaseCurrency $src -QuoteCurrency $target -TimestampUtc $TimestampUtc
        if ($null -ne $rec) { $rate = [double]$rec.Rate; $rateId = [string]$rec.ExchangeRateId }
    }
    if ($null -eq $rate) {
        return @{ Amount = $null; Rate = $null; ExchangeRateId = $null; Converted = $false; ConversionUnavailable = $true; SourceCurrency = $src }
    }
    return @{ Amount = [double]$Amount * [double]$rate; Rate = $rate; ExchangeRateId = $rateId; Converted = $true; ConversionUnavailable = $false; SourceCurrency = $src }
}

# -----------------------------------------------------------------------------
# Budget usage (DB-M17 records consumed read-only)
# -----------------------------------------------------------------------------
function Get-AiBudgetUsage {
    <#
    .SYNOPSIS
    Compute the spend for one budget scope from DB-M17 attempt records.
    Actual cost is preferred; an attempt with only an estimate contributes to
    CurrentEstimatedPendingSpend. An attempt with BOTH never double counts.
    Currency conversion is via the DB-M16 FX evidence; an unavailable conversion
    marks CurrencyUncertain and excludes that amount (never an invented rate).
    Returns @{ Scope; ScopeKey; AttemptCount; CurrentActualSpend;
               CurrentEstimatedPendingSpend; IncurredSpend; CurrencyUncertain;
               Currency; Message }.
    #>
    param(
        [AllowNull()][object[]]$Attempts,
        [string]$Scope = 'TASK',
        [string]$ScopeKey,
        [AllowNull()]$WindowStartUtc,
        [AllowNull()]$WindowEndUtc,
        [string]$Currency = 'INR',
        [AllowNull()][object]$Configuration,
        [AllowNull()][Nullable[decimal]]$ExchangeRate,
        $EvaluationTimestampUtc
    )
    $records = @($Attempts)
    $scope = $Scope.Trim().ToUpperInvariant()
    $filtered = New-Object System.Collections.ArrayList
    foreach ($rec in $records) {
        $keep = $false
        if ($scope -eq 'TASK') {
            $keep = ([string](Get-ContractProperty $rec 'TaskId' '')) -eq $ScopeKey
        } elseif ($scope -eq 'CHANGE') {
            $keep = ([string](Get-ContractProperty $rec 'ChangeId' '')) -eq $ScopeKey
        } elseif ($scope -in @('SESSION','DAILY','MONTHLY')) {
            $st = Get-ContractProperty $rec 'StartedAtUtc' $null
            if ($st -and $WindowStartUtc -and $WindowEndUtc) {
                $sdt = ConvertTo-AiUtc $st
                $w0 = ConvertTo-AiUtc $WindowStartUtc
                $w1 = ConvertTo-AiUtc $WindowEndUtc
                $keep = ($sdt -ge $w0 -and $sdt -lt $w1)
            }
        } elseif ($scope -eq 'TEAM') {
            $keep = $true
        }
        if ($keep) { $null = $filtered.Add($rec) }
    }

    $actualSum = 0.0
    $estSum = 0.0
    $uncertain = $false
    foreach ($rec in @($filtered)) {
        $actual = Get-ContractProperty $rec 'ActualCost' $null
        $est = Get-ContractProperty $rec 'EstimatedCost' $null
        $cc = Get-ContractProperty $rec 'CostCurrency' $null
        $value = $null
        $isActual = $false
        if ($null -ne $actual) { $value = $actual; $isActual = $true }
        elseif ($null -ne $est) { $value = $est }
        if ($null -eq $value) { continue }
        $converted = Convert-DbM21ToPolicyCurrency -Amount $value -AmountCurrency $cc `
            -TargetCurrency $Currency -TimestampUtc $EvaluationTimestampUtc `
            -Configuration $Configuration -ExchangeRate $ExchangeRate
        if ($converted.ConversionUnavailable) {
            $uncertain = $true
            continue
        }
        if ($isActual) { $actualSum += [double]$converted.Amount }
        else { $estSum += [double]$converted.Amount }
    }

    $message = "scope $scope ($ScopeKey): $($filtered.Count) attempt(s), actual $actualSum, estimated-pending $estSum $Currency"
    if ($uncertain) { $message += " [currency uncertainty: some amounts unconvertible]" }
    return @{
        Scope                     = $scope
        ScopeKey                  = if ($ScopeKey) { $ScopeKey } else { $null }
        AttemptCount              = $filtered.Count
        CurrentActualSpend        = $actualSum
        CurrentEstimatedPendingSpend = $estSum
        IncurredSpend             = ($actualSum + $estSum)
        CurrencyUncertain         = $uncertain
        Currency                  = $Currency
        Message                   = $message
    }
}

# -----------------------------------------------------------------------------
# Projected spend (actual incurred + estimated pending + proposed)
# -----------------------------------------------------------------------------
function Get-AiProjectedSpend {
    <#
    .SYNOPSIS
    Project the total spend for an upcoming attempt: CurrentActualSpend (incurred)
    + CurrentEstimatedPendingSpend (pending estimates) + the proposed attempt
    estimate, per IncludeEstimatedPendingCost. Estimated vs actual are always
    distinguished -- an estimate is never presented as actual spend.
    Returns @{ CurrentActualSpend; CurrentEstimatedPendingSpend;
               ProposedAttemptEstimatedCost; ProjectedSpend; Currency; CostUnknown;
               CurrencyUncertain; Message }.
    #>
    param(
        [AllowNull()][object]$Usage,
        [AllowNull()]$ProposedAttemptCost,
        [AllowNull()][string]$ProposedCostCurrency,
        [bool]$IncludeEstimatedPendingCost = $true,
        [AllowNull()][object]$Configuration,
        [AllowNull()][Nullable[decimal]]$ExchangeRate,
        $EvaluationTimestampUtc
    )
    $currency = if ($null -ne $Usage -and (Get-ContractProperty $Usage 'Currency' '')) { [string](Get-ContractProperty $Usage 'Currency' '') } else { 'INR' }
    $actual = 0.0
    $pendingEst = 0.0
    $uncertain = $false
    if ($null -ne $Usage) {
        $actual = [double](Get-ContractProperty $Usage 'CurrentActualSpend' 0)
        $pendingEst = [double](Get-ContractProperty $Usage 'CurrentEstimatedPendingSpend' 0)
        $uncertain = [bool](Get-ContractProperty $Usage 'CurrencyUncertain' $false)
    }

    $proposedConverted = $null
    $proposedUnknown = $false
    if ($null -ne $ProposedAttemptCost) {
        $conv = Convert-DbM21ToPolicyCurrency -Amount $ProposedAttemptCost -AmountCurrency $ProposedCostCurrency `
            -TargetCurrency $currency -TimestampUtc $EvaluationTimestampUtc `
            -Configuration $Configuration -ExchangeRate $ExchangeRate
        if ($conv.ConversionUnavailable) { $proposedUnknown = $true; $uncertain = $true }
        else { $proposedConverted = [double]$conv.Amount }
    }

    $pendingTotal = $pendingEst
    if ($IncludeEstimatedPendingCost -and $null -ne $proposedConverted) { $pendingTotal += $proposedConverted }
    $projected = $actual + $pendingTotal

    $costUnknown = $proposedUnknown
    $message = "actual $actual + pending $pendingTotal = projected $projected $currency"
    if ($costUnknown) { $message += " [proposed cost unknown/unconvertible -- not treated as zero]" }
    return @{
        CurrentActualSpend           = $actual
        CurrentEstimatedPendingSpend = $pendingTotal
        ProposedAttemptEstimatedCost = $proposedConverted
        ProjectedSpend               = $projected
        Currency                     = $currency
        CostUnknown                  = $costUnknown
        CurrencyUncertain            = $uncertain
        Message                      = $message
    }
}

# -----------------------------------------------------------------------------
# BudgetEvaluation v1
# -----------------------------------------------------------------------------
function New-BudgetEvaluation {
    <#
    .SYNOPSIS
    Build a BudgetEvaluation v1 from a field table. The decision is a pure
    recommendation -- nothing is executed.
    #>
    param([AllowNull()][hashtable]$Fields)
    $f = if ($null -eq $Fields) { @{} } else { $Fields }
    function F([string]$n, $d) { if ($f.ContainsKey($n)) { return $f[$n] }; return $d }
    return [pscustomobject]@{
        SchemaVersion                 = 1
        EvaluationId                  = F 'EvaluationId' $null
        TaskId                        = F 'TaskId' $null
        ChangeId                      = F 'ChangeId' $null
        SessionId                     = F 'SessionId' $null
        PolicyId                      = F 'PolicyId' $null
        Currency                      = F 'Currency' 'INR'
        Purpose                       = F 'Purpose' 'AI_ATTEMPT'
        CurrentActualSpend            = F 'CurrentActualSpend' 0.0
        CurrentEstimatedPendingSpend  = F 'CurrentEstimatedPendingSpend' 0.0
        ProposedAttemptEstimatedCost  = F 'ProposedAttemptEstimatedCost' $null
        ProposedCostUnknown           = F 'ProposedCostUnknown' $false
        ProjectedSpend                = F 'ProjectedSpend' 0.0
        ApplicableLimits              = @(F 'ApplicableLimits' @())
        WarningThresholds             = @(F 'WarningThresholds' @())
        Decision                      = F 'Decision' $null
        ReasonCodes                   = @(F 'ReasonCodes' @())
        RequiresHumanOverride         = F 'RequiresHumanOverride' $false
        OverrideAllowed               = F 'OverrideAllowed' $false
        CurrencyUncertain             = F 'CurrencyUncertain' $false
        GeneratedAtUtc                = F 'GeneratedAtUtc' $null
        Message                       = F 'Message' $null
    }
}

function Test-BudgetEvaluation {
    <#
    .SYNOPSIS
    Deterministic structural validation of a BudgetEvaluation v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Evaluation)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Evaluation) { return @{ Valid = $false; Errors = @('Evaluation is null'); Warnings = @() } }
    if ((Get-ContractProperty $Evaluation 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Evaluation 'EvaluationId' '')) { $errors.Add('EvaluationId is required') }
    $dec = [string](Get-ContractProperty $Evaluation 'Decision' '')
    if ($dec -and $dec -notin (Get-DbM21BudgetDecisions)) { $errors.Add("Decision '$dec' invalid") }
    foreach ($rc in @(Get-ContractProperty $Evaluation 'ReasonCodes' @())) {
        if ($rc -notin (Get-DbM21BudgetReasonCodes)) { $errors.Add("ReasonCode '$rc' not in the DB-M21 budget reason-code vocabulary") }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# -----------------------------------------------------------------------------
# Test-AiBudget -- the full deterministic budget decision
# -----------------------------------------------------------------------------
function Test-AiBudget {
    <#
    .SYNOPSIS
    Answer "is the proposed AI attempt allowed under the configured budget
    policy?" Evaluates every applicable scope limit (TASK / CHANGE / SESSION /
    DAILY / MONTHLY / TEAM), and the strictest result wins. The evaluation
    timestamp is injected -- day/month windows are derived from it, never from
    the machine clock. A non-AI purpose (HUMAN_GATE / GOVERNANCE_WAIT) consumes
    zero AI budget.
    Returns a BudgetEvaluation v1. Nothing is executed.
    #>
    param(
        [AllowNull()][pscustomobject]$Policy,
        $EvaluationTimestampUtc,
        [AllowNull()][object[]]$Attempts,
        [string]$TaskId,
        [string]$ChangeId,
        [string]$SessionId,
        [AllowNull()]$SessionWindowStartUtc,
        [AllowNull()]$SessionWindowEndUtc,
        [AllowNull()]$ProposedAttemptCost,
        [AllowNull()][string]$ProposedCostCurrency,
        [bool]$ProposedCostUnknown = $false,
        [string]$Purpose = 'AI_ATTEMPT',
        [AllowNull()][object]$Configuration,
        [AllowNull()][Nullable[decimal]]$ExchangeRate
    )
    if ($null -eq $Policy) { throw "Test-AiBudget: Policy is required" }
    $pv = Test-BudgetPolicy $Policy
    if (-not $pv.Valid) { throw ("Test-AiBudget: invalid BudgetPolicy: " + ($pv.Errors -join '; ')) }
    if (-not (Get-ContractProperty $Policy 'Enabled' $true)) { throw "Test-AiBudget: BudgetPolicy '$((Get-ContractProperty $Policy 'PolicyId' ''))' is disabled" }

    $policyId = [string](Get-ContractProperty $Policy 'PolicyId' '')
    $currency = [string](Get-ContractProperty $Policy 'Currency' 'INR')
    $warnPct = [double](Get-ContractProperty $Policy 'WarnAtPercent' 80)
    $blockPct = [double](Get-ContractProperty $Policy 'BlockAtPercent' 100)
    $includeEst = [bool](Get-ContractProperty $Policy 'IncludeEstimatedPendingCost' $true)
    $unkPolicy = [string](Get-ContractProperty $Policy 'UnknownCostPolicy' 'BLOCK')
    $allowOverride = [bool](Get-ContractProperty $Policy 'AllowManualOverride' $true)
    $offset = [double](Get-ContractProperty $Policy 'AccountingUtcOffsetHours' 0)
    $ts = ConvertTo-AiUtc $EvaluationTimestampUtc

    $evalId = "BE-$(if ($TaskId) { $TaskId } else { 'NA' })-$(if ($ChangeId) { $ChangeId } else { 'NA' })-$(if ($SessionId) { $SessionId } else { 'NA' })"

    # --- non-AI purposes consume zero AI budget ------------------------------
    if ($Purpose -ne 'AI_ATTEMPT') {
        $zeroReason = if ($Purpose -eq 'HUMAN_GATE') { 'HUMAN_GATE_ZERO_COST' } else { 'GOVERNANCE_ZERO_COST' }
        return New-BudgetEvaluation @{
            EvaluationId = $evalId; TaskId = $TaskId; ChangeId = $ChangeId; SessionId = $SessionId
            PolicyId = $policyId; Currency = $currency; Purpose = $Purpose
            CurrentActualSpend = 0.0; CurrentEstimatedPendingSpend = 0.0
            ProposedAttemptEstimatedCost = $null; ProposedCostUnknown = $false
            ProjectedSpend = 0.0; ApplicableLimits = @(); WarningThresholds = @()
            Decision = 'ALLOW'; ReasonCodes = @('PURPOSE_NOT_AI_ATTEMPT', $zeroReason)
            RequiresHumanOverride = $false; OverrideAllowed = $false
            CurrencyUncertain = $false; GeneratedAtUtc = $ts
            Message = "purpose $Purpose is not an AI attempt; it consumes no AI budget"
        }
    }

    # --- assemble the applicable scope limits --------------------------------
    $limits = New-Object System.Collections.ArrayList   # @{Scope;Key;Limit;WindowStart;WindowEnd}
    function Add-Limit([string]$scope, [string]$key, [object]$limit, $w0, $w1) {
        if ($null -ne $limit) {
            $null = $limits.Add(@{ Scope = $scope; Key = $key; Limit = [double]$limit; W0 = $w0; W1 = $w1 })
        }
    }
    if ($TaskId) { Add-Limit 'TASK' $TaskId $(Get-ContractProperty $Policy 'TaskLimit' $null) $null $null }
    if ($ChangeId) { Add-Limit 'CHANGE' $ChangeId $(Get-ContractProperty $Policy 'ChangeLimit' $null) $null $null }
    if ($SessionId -and $SessionWindowStartUtc -and $SessionWindowEndUtc) {
        Add-Limit 'SESSION' $SessionId $(Get-ContractProperty $Policy 'SessionLimit' $null) $SessionWindowStartUtc $SessionWindowEndUtc
    }
    $day = Get-DbM21DayWindow -TimestampUtc $ts -OffsetHours $offset
    $month = Get-DbM21MonthWindow -TimestampUtc $ts -OffsetHours $offset
    Add-Limit 'DAILY' ($day.Label) $(Get-ContractProperty $Policy 'DailyLimit' $null) $day.StartUtc $day.EndUtc
    Add-Limit 'MONTHLY' ($month.Label) $(Get-ContractProperty $Policy 'MonthlyLimit' $null) $month.StartUtc $month.EndUtc
    Add-Limit 'TEAM' $null $(Get-ContractProperty $Policy 'TeamLimit' $null) $null $null

    $records = @($Attempts)
    $limitRows = New-Object System.Collections.ArrayList
    $thresholdRows = New-Object System.Collections.ArrayList
    $allReasons = New-Object System.Collections.ArrayList
    $overallActual = 0.0
    $overallPending = 0.0
    $overallUncertain = $false
    $blockedDecision = $null
    $blockedReason = $null
    $warned = $false

    foreach ($lim in @($limits)) {
        $usage = Get-AiBudgetUsage -Attempts $records -Scope $lim.Scope -ScopeKey $lim.Key `
            -WindowStartUtc $lim.W0 -WindowEndUtc $lim.W1 -Currency $currency `
            -Configuration $Configuration -ExchangeRate $ExchangeRate -EvaluationTimestampUtc $ts

        # proposed cost conversion
        $proposedConv = $null
        $unknown = $ProposedCostUnknown
        if (-not $ProposedCostUnknown -and $null -ne $ProposedAttemptCost) {
            $conv = Convert-DbM21ToPolicyCurrency -Amount $ProposedAttemptCost -AmountCurrency $ProposedCostCurrency `
                -TargetCurrency $currency -TimestampUtc $ts -Configuration $Configuration -ExchangeRate $ExchangeRate
            if ($conv.ConversionUnavailable) { $unknown = $true }
            else { $proposedConv = [double]$conv.Amount }
        }
        $thisUncertain = ([bool]$usage.CurrencyUncertain) -or $unknown
        if ($thisUncertain) { $overallUncertain = $true }
        $overallActual += [double]$usage.CurrentActualSpend
        $overallPending += [double]$usage.CurrentEstimatedPendingSpend

        $limitAmount = [double]$lim.Limit
        $warnAmount = $limitAmount * $warnPct / 100.0
        $blockAmount = $limitAmount * $blockPct / 100.0
        $null = $thresholdRows.Add(@{ Scope = $lim.Scope; Limit = $limitAmount; WarnAtPercent = $warnPct; BlockAtPercent = $blockPct; WarnAmount = $warnAmount; BlockAmount = $blockAmount })

        # per-limit decision
        $perDecision = $null
        $perReasons = New-Object System.Collections.ArrayList
        if ($unknown -and -not ([double]$usage.IncurredSpend -ge $blockAmount)) {
            # known spend alone does not breach the block threshold
            if ($unkPolicy -eq 'ALLOW') { $perDecision = 'ALLOW'; $null = $perReasons.Add('COST_UNKNOWN_ALLOWED') }
            elseif ($unkPolicy -eq 'WARN') { $perDecision = 'ALLOW_WITH_WARNING'; $null = $perReasons.Add('COST_UNKNOWN_WARN') }
            else { $perDecision = 'BLOCK_COST_UNKNOWN'; $null = $perReasons.Add('COST_UNKNOWN_BLOCKED') }
        } else {
            $proj = [double]$usage.IncurredSpend + $(if ($includeEst) { if ($null -eq $proposedConv) { 0.0 } else { [double]$proposedConv } } else { 0.0 })
            if ($proj -ge $blockAmount) {
                $perDecision = 'BLOCK_BUDGET_EXCEEDED'
                $null = $perReasons.Add(("$($lim.Scope)_LIMIT_EXCEEDED"))
            } elseif ($proj -ge $warnAmount) {
                $perDecision = 'ALLOW_WITH_WARNING'
                $null = $perReasons.Add('WARNING_THRESHOLD_REACHED')
            } else {
                $perDecision = 'ALLOW'
                $null = $perReasons.Add('UNDER_LIMIT')
            }
        }
        if ($thisUncertain) { $null = $perReasons.Add('CURRENCY_UNAVAILABLE') }
        $projSpend = [double]$usage.IncurredSpend + $(if ($includeEst) { if ($null -eq $proposedConv) { 0.0 } else { [double]$proposedConv } } else { 0.0 })

        $null = $limitRows.Add(@{
            Scope = $lim.Scope; ScopeKey = $lim.Key; Limit = $limitAmount
            CurrentActualSpend = [double]$usage.CurrentActualSpend
            CurrentEstimatedPendingSpend = [double]$usage.CurrentEstimatedPendingSpend
            ProjectedSpend = $projSpend
            Decision = $perDecision; ReasonCodes = @($perReasons)
            CostUnknown = $thisUncertain
        })

        if ($perDecision -eq 'BLOCK_BUDGET_EXCEEDED' -or $perDecision -eq 'BLOCK_COST_UNKNOWN') {
            if ($null -eq $blockedDecision) { $blockedDecision = $perDecision; $blockedReason = @($perReasons) }
            foreach ($rc in @($perReasons)) { if ($rc -notin $allReasons) { $null = $allReasons.Add($rc) } }
        } elseif ($perDecision -eq 'ALLOW_WITH_WARNING') { $warned = $true }
        foreach ($rc in @($perReasons)) { if ($rc -notin $allReasons) { $null = $allReasons.Add($rc) } }
    }

    # --- combine: strictest wins ---------------------------------------------
    $decision = $null
    $reasons = @()
    $requiresOverride = $false
    if ($null -ne $blockedDecision) {
        if ($allowOverride) {
            $decision = 'REQUIRE_HUMAN_OVERRIDE'
            $requiresOverride = $true
            $reasons = @($blockedReason + @('BLOCKED_STRICTEST_LIMIT', 'HUMAN_OVERRIDE_REQUIRED'))
        } else {
            $decision = $blockedDecision
            $reasons = @($blockedReason + @('BLOCKED_STRICTEST_LIMIT'))
        }
    } elseif ($warned) {
        $decision = 'ALLOW_WITH_WARNING'
        $reasons = @('WARNING_THRESHOLD_REACHED')
    } elseif ($limits.Count -eq 0) {
        $decision = 'NO_APPLICABLE_BUDGET'
        $reasons = @('NO_APPLICABLE_LIMIT')
    } else {
        $decision = 'ALLOW'
        $reasons = @('UNDER_LIMIT')
    }

    $uniqueReasons = @($allReasons | Where-Object { $_ -notin $reasons })
    $reasons = @($reasons + $uniqueReasons)

    $message = "budget decision $decision for purpose $Purpose (projected $($overallActual + $overallPending) $currency across $($limits.Count) applicable limit(s))"

    return New-BudgetEvaluation @{
        EvaluationId = $evalId; TaskId = $TaskId; ChangeId = $ChangeId; SessionId = $SessionId
        PolicyId = $policyId; Currency = $currency; Purpose = $Purpose
        CurrentActualSpend = $overallActual
        CurrentEstimatedPendingSpend = $overallPending
        ProposedAttemptEstimatedCost = $ProposedAttemptCost
        ProposedCostUnknown = $ProposedCostUnknown
        ProjectedSpend = ($overallActual + $overallPending)
        ApplicableLimits = @($limitRows)
        WarningThresholds = @($thresholdRows)
        Decision = $decision
        ReasonCodes = @($reasons)
        RequiresHumanOverride = $requiresOverride
        OverrideAllowed = $allowOverride
        CurrencyUncertain = $overallUncertain
        GeneratedAtUtc = $ts
        Message = $message
    }
}

# -----------------------------------------------------------------------------
# Test-AiBudgetOverride -- explicit human override only
# -----------------------------------------------------------------------------
function Test-AiBudgetOverride {
    <#
    .SYNOPSIS
    Process an EXPLICIT human budget override. DB-M21 never infers human
    approval -- only supplied OverrideReference / OverrideReason / timestamp
    evidence counts. Grants an override only when the policy permits and (when
    required) a reason is provided. Returns @{ Granted; Decision; ReasonCodes;
    OverrideReference; OverrideReason; OverrideTimestampUtc; OverrideScope;
    OverrideAmount; Message }.
    #>
    param(
        [AllowNull()][pscustomobject]$Policy,
        [AllowNull()][pscustomobject]$Evaluation,
        [string]$OverrideReference,
        [string]$OverrideReason,
        [AllowNull()]$OverrideTimestampUtc,
        [string]$OverrideScope,
        [AllowNull()]$OverrideAmount
    )
    if ($null -eq $Policy) { throw "Test-AiBudgetOverride: Policy is required" }
    if ($null -eq $Evaluation) { throw "Test-AiBudgetOverride: Evaluation is required" }
    $current = [string](Get-ContractProperty $Evaluation 'Decision' '')
    $blocked = ($current -in @('BLOCK_BUDGET_EXCEEDED', 'BLOCK_COST_UNKNOWN', 'REQUIRE_HUMAN_OVERRIDE'))
    if (-not $blocked) {
        return @{ Granted = $false; Decision = $current; ReasonCodes = @('NO_OVERRIDE_NEEDED')
                  OverrideReference = $null; OverrideReason = $null; OverrideTimestampUtc = $null
                  OverrideScope = $null; OverrideAmount = $null; Message = "nothing to override (decision '$current')" }
    }

    $allow = [bool](Get-ContractProperty $Policy 'AllowManualOverride' $true)
    $requireReason = [bool](Get-ContractProperty $Policy 'RequireReasonForOverride' $true)

    if (-not $allow) {
        return @{ Granted = $false; Decision = $current; ReasonCodes = @('OVERRIDE_PROHIBITED')
                  OverrideReference = $null; OverrideReason = $null; OverrideTimestampUtc = $null
                  OverrideScope = $null; OverrideAmount = $null; Message = 'budget override is prohibited by policy' }
    }
    if ($requireReason -and -not $OverrideReason) {
        return @{ Granted = $false; Decision = 'REQUIRE_HUMAN_OVERRIDE'; ReasonCodes = @('OVERRIDE_REASON_REQUIRED')
                  OverrideReference = $null; OverrideReason = $null; OverrideTimestampUtc = $null
                  OverrideScope = $null; OverrideAmount = $null; Message = 'an override reason is required by policy' }
    }

    return @{ Granted = $true; Decision = 'ALLOW'; ReasonCodes = @('HUMAN_OVERRIDE_GRANTED')
              OverrideReference = $OverrideReference; OverrideReason = $OverrideReason
              OverrideTimestampUtc = $OverrideTimestampUtc
              OverrideScope = $OverrideScope; OverrideAmount = $OverrideAmount
              Message = "explicit human override granted on '$OverrideReference'" }
}

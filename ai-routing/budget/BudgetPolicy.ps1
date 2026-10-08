# BudgetPolicy.ps1 -- DB-M21 Part A budget-policy contracts + vocabularies.
#
# DB-M21 is a CONTROL / DECISION FOUNDATION. It answers "is the proposed AI
# attempt allowed under the configured budget policy?" and NEVER executes a
# provider or model. No paid API calls, no network calls, no autonomous Nexus
# changes. AUTO_EXECUTION_ENABLED = FALSE.
#
# BudgetPolicy v1 is PURE CONFIGURATION DATA. The budget engine reads every
# limit and switch from the policy object -- no budget is hard-coded in engine
# logic. Nullable limits mean a scope is NOT configured (never an infinite
# numeric sentinel).
#
# Human Git / governance gates consume NO AI budget: budget is for AI/provider
# execution, not elapsed workflow time.
#
# ADR-005: identifiers are data. No business logic branches on a provider/model
# name.

. (Join-Path $PSScriptRoot "..\AiRoutingContracts.ps1")   # DB-M14 vocab + helpers (READ-ONLY)

# -----------------------------------------------------------------------------
# Schema versions (DB-M21-owned)
# -----------------------------------------------------------------------------
function Get-DbM21SchemaVersions {
    return [pscustomobject]@{
        BudgetPolicyVersion     = 1
        BudgetEvaluationVersion = 1
    }
}

# -----------------------------------------------------------------------------
# Vocabularies
# -----------------------------------------------------------------------------
function Get-DbM21BudgetScopes {
    <#
    .SYNOPSIS
    Generic budget scope keys. TEAM is the generic "team / workspace" scope --
    DB-M21 prefers a generic scope key over Nexus-specific concepts.
    #>
    return @('TASK', 'CHANGE', 'SESSION', 'DAILY', 'MONTHLY', 'TEAM')
}

function Get-DbM21BudgetDecisions {
    <#
    .SYNOPSIS
    Structured budget decisions -- never free text.
      ALLOW                    - the attempt is within budget
      ALLOW_WITH_WARNING       - projected spend is at/above the warning threshold
      BLOCK_BUDGET_EXCEEDED    - projected spend breaches a configured limit
      BLOCK_COST_UNKNOWN       - the proposed cost is unknown/unconvertible and the
                                 policy blocks unknown costs
      REQUIRE_HUMAN_OVERRIDE   - blocked, but an explicit human override may proceed
      NO_APPLICABLE_BUDGET     - no configured limit applies
    #>
    return @('ALLOW', 'ALLOW_WITH_WARNING', 'BLOCK_BUDGET_EXCEEDED', 'BLOCK_COST_UNKNOWN',
             'REQUIRE_HUMAN_OVERRIDE', 'NO_APPLICABLE_BUDGET')
}

function Get-DbM21UnknownCostPolicies {
    return @('ALLOW', 'WARN', 'BLOCK')
}

function Get-DbM21BudgetPurposes {
    <#
    .SYNOPSIS
    The purpose of the proposed operation. Only AI_ATTEMPT consumes AI budget.
    Human Git / governance waits cost nothing.
    #>
    return @('AI_ATTEMPT', 'HUMAN_GATE', 'GOVERNANCE_WAIT')
}

function Get-DbM21BudgetReasonCodes {
    <#
    .SYNOPSIS
    Closed reason-code vocabulary for BudgetEvaluation v1. Vocabulary members,
    never free text.
    #>
    return @(
        'NO_APPLICABLE_LIMIT', 'UNDER_LIMIT', 'WARNING_THRESHOLD_REACHED',
        'TASK_LIMIT_EXCEEDED', 'CHANGE_LIMIT_EXCEEDED', 'SESSION_LIMIT_EXCEEDED',
        'DAILY_LIMIT_EXCEEDED', 'MONTHLY_LIMIT_EXCEEDED', 'TEAM_LIMIT_EXCEEDED',
        'BLOCKED_STRICTEST_LIMIT', 'COST_UNKNOWN_ALLOWED', 'COST_UNKNOWN_WARN',
        'COST_UNKNOWN_BLOCKED', 'CURRENCY_CONVERTED', 'CURRENCY_UNAVAILABLE',
        'ACTUAL_PREFERRED', 'ESTIMATED_PENDING_INCLUDED', 'HUMAN_GATE_ZERO_COST',
        'GOVERNANCE_ZERO_COST', 'HUMAN_OVERRIDE_GRANTED', 'HUMAN_OVERRIDE_REQUIRED',
        'OVERRIDE_REASON_REQUIRED', 'OVERRIDE_PROHIBITED', 'NO_OVERRIDE_NEEDED',
        'DETERMINISTIC_WINDOW', 'PURPOSE_NOT_AI_ATTEMPT'
    )
}

# -----------------------------------------------------------------------------
# BudgetPolicy v1
# -----------------------------------------------------------------------------
function New-BudgetPolicy {
    <#
    .SYNOPSIS
    Build a normalized BudgetPolicy v1. All limits are Nullable[double]: a null
    limit means that scope is NOT configured (never an infinite sentinel). All
    switches are DATA read by the budget engine.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$PolicyId,
        [string]$Name,
        [bool]$Enabled = $true,
        [string]$Currency = 'INR',
        [Nullable[double]]$TaskLimit,
        [Nullable[double]]$ChangeLimit,
        [Nullable[double]]$SessionLimit,
        [Nullable[double]]$DailyLimit,
        [Nullable[double]]$MonthlyLimit,
        [Nullable[double]]$TeamLimit,
        [Nullable[double]]$WarnAtPercent,
        [Nullable[double]]$BlockAtPercent,
        [Nullable[bool]]$IncludeEstimatedPendingCost,
        [string]$UnknownCostPolicy,
        [Nullable[bool]]$AllowManualOverride,
        [Nullable[bool]]$RequireReasonForOverride,
        [Nullable[double]]$AccountingUtcOffsetHours,
        [string]$Notes
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }

    $id = if ($InputObject) { & $g 'PolicyId' $PolicyId } else { $PolicyId }
    if (-not $id) { throw "New-BudgetPolicy: PolicyId is required" }
    $id = $id.Trim()

    $name = if ($InputObject) { & $g 'Name' $Name } else { $Name }
    if (-not $name) { $name = $id }

    $enabled = if ($InputObject) { [bool](& $g 'Enabled' $Enabled) } else { $Enabled }
    $currency = if ($InputObject) { & $g 'Currency' $Currency } else { $Currency }
    if (-not $currency) { $currency = 'INR' }
    $currency = $currency.Trim().ToUpperInvariant()

    function Norm-Lim([object]$Raw) {
        # null stays null (scope not configured); a number stays a number
        if ($null -eq $Raw) { return $null }
        return [double]$Raw
    }
    $taskLim    = Norm-Lim $(if ($InputObject) { & $g 'TaskLimit' $TaskLimit } else { $TaskLimit })
    $changeLim  = Norm-Lim $(if ($InputObject) { & $g 'ChangeLimit' $ChangeLimit } else { $ChangeLimit })
    $sessLim    = Norm-Lim $(if ($InputObject) { & $g 'SessionLimit' $SessionLimit } else { $SessionLimit })
    $dailyLim   = Norm-Lim $(if ($InputObject) { & $g 'DailyLimit' $DailyLimit } else { $DailyLimit })
    $monthlyLim = Norm-Lim $(if ($InputObject) { & $g 'MonthlyLimit' $MonthlyLimit } else { $MonthlyLimit })
    $teamLim    = Norm-Lim $(if ($InputObject) { & $g 'TeamLimit' $TeamLimit } else { $TeamLimit })

    # a negative limit is invalid configuration -- fail fast at construction
    foreach ($limPair in @(@('TaskLimit', $taskLim), @('ChangeLimit', $changeLim), @('SessionLimit', $sessLim),
                           @('DailyLimit', $dailyLim), @('MonthlyLimit', $monthlyLim), @('TeamLimit', $teamLim))) {
        if ($null -ne $limPair[1] -and [double]$limPair[1] -lt 0) { throw "New-BudgetPolicy: $($limPair[0]) must be >= 0 (found $($limPair[1]))" }
    }

    function Norm-Pct([object]$Raw, [double]$Fallback) {
        if ($null -eq $Raw) { return $Fallback }
        return [double]$Raw
    }
    $warnPct = Norm-Pct $(if ($InputObject) { & $g 'WarnAtPercent' $WarnAtPercent } else { $WarnAtPercent }) 80
    $blockPct = Norm-Pct $(if ($InputObject) { & $g 'BlockAtPercent' $BlockAtPercent } else { $BlockAtPercent }) 100
    if ($warnPct -lt 0 -or $warnPct -gt 100) { throw "New-BudgetPolicy: WarnAtPercent must be within 0..100 (found $warnPct)" }
    if ($blockPct -lt 0 -or $blockPct -gt 100) { throw "New-BudgetPolicy: BlockAtPercent must be within 0..100 (found $blockPct)" }
    if ($warnPct -gt $blockPct) { throw "New-BudgetPolicy: WarnAtPercent ($warnPct) must be <= BlockAtPercent ($blockPct)" }

    $includeEst = if ($InputObject) { [bool](& $g 'IncludeEstimatedPendingCost' $IncludeEstimatedPendingCost) } else { $IncludeEstimatedPendingCost }
    if ($null -eq $includeEst) { $includeEst = $true }

    $unk = if ($InputObject) { & $g 'UnknownCostPolicy' $UnknownCostPolicy } else { $UnknownCostPolicy }
    if (-not $unk) { $unk = 'BLOCK' }
    $unk = $unk.Trim().ToUpperInvariant()
    if ($unk -notin (Get-DbM21UnknownCostPolicies)) { throw "New-BudgetPolicy: UnknownCostPolicy '$unk' invalid (ALLOW/WARN/BLOCK)" }

    $allowOverride = if ($InputObject) { [bool](& $g 'AllowManualOverride' $AllowManualOverride) } else { $AllowManualOverride }
    if ($null -eq $allowOverride) { $allowOverride = $true }
    $requireReason = if ($InputObject) { [bool](& $g 'RequireReasonForOverride' $RequireReasonForOverride) } else { $RequireReasonForOverride }
    if ($null -eq $requireReason) { $requireReason = $true }

    $offset = if ($InputObject) { & $g 'AccountingUtcOffsetHours' $AccountingUtcOffsetHours } else { $AccountingUtcOffsetHours }
    if ($null -eq $offset) { $offset = 0.0 }
    $offset = [double]$offset

    $notes = if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }

    return [pscustomobject]@{
        SchemaVersion                 = 1
        PolicyId                      = $id
        Name                          = $name
        Enabled                       = $enabled
        Currency                      = $currency
        TaskLimit                     = $taskLim
        ChangeLimit                   = $changeLim
        SessionLimit                  = $sessLim
        DailyLimit                    = $dailyLim
        MonthlyLimit                  = $monthlyLim
        TeamLimit                     = $teamLim
        WarnAtPercent                 = $warnPct
        BlockAtPercent                = $blockPct
        IncludeEstimatedPendingCost   = $includeEst
        UnknownCostPolicy             = $unk
        AllowManualOverride           = $allowOverride
        RequireReasonForOverride      = $requireReason
        AccountingUtcOffsetHours      = $offset
        Notes                         = $notes
    }
}

function Test-BudgetPolicy {
    <#
    .SYNOPSIS
    Deterministic structural validation of a BudgetPolicy v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Policy)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Policy) { return @{ Valid = $false; Errors = @('Policy is null'); Warnings = @() } }
    if ((Get-ContractProperty $Policy 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Policy 'PolicyId' '')) { $errors.Add('PolicyId is required') }
    if ((Get-ContractProperty $Policy 'Enabled' $true) -ne $true -and (Get-ContractProperty $Policy 'Enabled' $true) -ne $false) { $errors.Add('Enabled must be a boolean') }
    $cur = [string](Get-ContractProperty $Policy 'Currency' '')
    if (-not $cur) { $errors.Add('Currency is required') }

    foreach ($fn in @('TaskLimit','ChangeLimit','SessionLimit','DailyLimit','MonthlyLimit','TeamLimit')) {
        $v = Get-ContractProperty $Policy $fn $null
        if ($null -ne $v -and $v -lt 0) { $errors.Add("$fn must be >= 0 (found $v)") }
    }
    $wp = Get-ContractProperty $Policy 'WarnAtPercent' $null
    $bp = Get-ContractProperty $Policy 'BlockAtPercent' $null
    if ($null -ne $wp -and ($wp -lt 0 -or $wp -gt 100)) { $errors.Add("WarnAtPercent must be within 0..100 (found $wp)") }
    if ($null -ne $bp -and ($bp -lt 0 -or $bp -gt 100)) { $errors.Add("BlockAtPercent must be within 0..100 (found $bp)") }
    if ($null -ne $wp -and $null -ne $bp -and $wp -gt $bp) { $errors.Add('WarnAtPercent must be <= BlockAtPercent') }

    $unk = [string](Get-ContractProperty $Policy 'UnknownCostPolicy' '')
    if ($unk -and $unk -notin (Get-DbM21UnknownCostPolicies)) { $errors.Add("UnknownCostPolicy '$unk' invalid (ALLOW/WARN/BLOCK)") }

    $offset = Get-ContractProperty $Policy 'AccountingUtcOffsetHours' 0
    if ($null -eq $offset -or $offset -lt -14 -or $offset -gt 14) { $errors.Add("AccountingUtcOffsetHours must be within -14..14 (found '$offset')") }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# -----------------------------------------------------------------------------
# Default budget policy
# -----------------------------------------------------------------------------
function Get-DefaultBudgetPolicy {
    <#
    .SYNOPSIS
    The default DB-M21 budget policy. Conservative by design: INR accounting,
    no scope limits configured (NO_APPLICABLE_BUDGET until a limit is set),
    unknown costs BLOCKED, explicit human override with a required reason,
    deterministic UTC day/month windows.
    #>
    return New-BudgetPolicy -PolicyId 'budget-policy-default-v1' -Name 'DEFAULT' -Enabled $true `
        -Currency 'INR' -WarnAtPercent 80 -BlockAtPercent 100 `
        -IncludeEstimatedPendingCost $true -UnknownCostPolicy 'BLOCK' `
        -AllowManualOverride $true -RequireReasonForOverride $true `
        -AccountingUtcOffsetHours 0 `
        -Notes 'DB-M21 default. INR accounting; no scope limit configured -> NO_APPLICABLE_BUDGET until set. Unknown costs block; override requires an explicit reason.'
}

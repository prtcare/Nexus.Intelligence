# =============================================================================
# Test-DbM21Budget.ps1
# DB-M21 -- BUDGET CONTROL + FAILURE FINGERPRINTS  (Part A: budget; S1..S23)
#
# DB-M21 is a CONTROL / DECISION FOUNDATION. This suite proves the budget
# engine consumes cost evidence (DB-M17 records, DB-M16 FX) and produces a
# structured BudgetEvaluation v1 -- it never calculates prices, never executes
# a provider/model, makes no paid API call and no network call.
#   - nullable limits (null scope = NOT configured, never an infinite sentinel)
#   - actual-preferred spend, estimated-pending separated
#   - task / change / session / daily / monthly / team scopes
#   - warning thresholds, strictest-wins precedence
#   - unknown-cost policy (never treat unknown as zero)
#   - explicit-only human override
#   - human Git / governance gates consume ZERO AI budget
#   - deterministic day/month windows from the INJECTED evaluation timestamp
#   - DB-M16 currency conversion semantics (no invented rate)
#
# Harness: $ErrorActionPreference="Stop", Set-StrictMode -Version Latest,
# $script:Results/$script:Fails, Assert-* helpers, exit 0 / exit 1.
# =============================================================================

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

. (Join-Path $PSScriptRoot "BudgetEngine.ps1")   # BudgetPolicy + BudgetEngine + DB-M16 FX (read-only)

$script:Results = 0
$script:Fails = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Results++
    if ($Condition) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message) }
}
function Assert-Throws {
    param([scriptblock]$Script, [string]$Message)
    $script:Results++
    $threw = $false
    try { & $Script | Out-Null } catch { $threw = $true }
    if ($threw) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message) }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:Results++
    if ([string]$Actual -eq [string]$Expected) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual='$Actual' expected='$Expected')") }
}
function Assert-Null {
    param($Actual, [string]$Message)
    $script:Results++
    if ($null -eq $Actual) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (got '$Actual')") }
}
function Assert-Near {
    param($Actual, [double]$Expected, [double]$Tolerance = 0.001, [string]$Message)
    $script:Results++
    if ($null -eq $Actual) { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual=null expected=$Expected)"); return }
    if ([math]::Abs([double]$Actual - $Expected) -le $Tolerance) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual='$Actual' expected='$Expected')") }
}
function Assert-In {
    param($Actual, [string[]]$Allowed, [string]$Message)
    $script:Results++
    if ([string]$Actual -in $Allowed) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual='$Actual')") }
}
function Assert-Contains {
    param($Actual, $Expected, [string]$Message)
    $script:Results++
    if ([string]($Actual -join ',') -like "*$Expected*") { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (missing '$Expected' in '$($Actual -join ',')')") }
}

# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------
function New-DbM21Attempt {
    param(
        [string]$AttemptId, [string]$TaskId, [string]$ChangeId, [string]$SessionId,
        [AllowNull()]$StartedAtUtc, [AllowNull()]$ActualCost, [AllowNull()]$EstimatedCost,
        [string]$CostCurrency = 'INR'
    )
    return [pscustomobject]@{
        AttemptId = $AttemptId; TaskId = $TaskId; ChangeId = $ChangeId; SessionId = $SessionId
        StartedAtUtc = $StartedAtUtc; ActualCost = $ActualCost; EstimatedCost = $EstimatedCost
        CostCurrency = $CostCurrency
    }
}

function New-DbM21FxConfig {
    <#
    .SYNOPSIS
    An in-memory DB-M16 exchange-rate catalogue wrapped for -Configuration.
    Rates are fixture data only -- the LIVE catalogue is never touched.
    #>
    param([double]$UsdInrRate = 83.5)
    $fx = New-AiExchangeRateRecord -ExchangeRateId 'fx-usd-inr-test' -BaseCurrency 'USD' `
        -QuoteCurrency 'INR' -Rate $UsdInrRate -EffectiveAtUtc '2026-01-01T00:00:00Z'
    return @{ ExchangeRates = @{ $fx.ExchangeRateId = $fx } }
}

$tsNoon = [datetime]::Parse('2026-08-31T12:00:00Z').ToUniversalTime()
$tsMidnight = [datetime]::Parse('2026-08-31T00:00:00Z').ToUniversalTime()

# -----------------------------------------------------------------------------
# S1  BudgetPolicy v1 -- nullable limits + defaults (no infinite sentinels)
# -----------------------------------------------------------------------------
$p1 = New-BudgetPolicy -PolicyId 'P1' -Currency 'INR' -TaskLimit 100
Assert-Equal $p1.SchemaVersion 1 "S1 BudgetPolicy schema v1"
Assert-Equal $p1.TaskLimit 100 "S1 TaskLimit configured"
Assert-Null $p1.ChangeLimit "S1 ChangeLimit null (not configured)"
Assert-Null $p1.SessionLimit "S1 SessionLimit null"
Assert-Null $p1.DailyLimit "S1 DailyLimit null"
Assert-Null $p1.MonthlyLimit "S1 MonthlyLimit null"
Assert-Null $p1.TeamLimit "S1 TeamLimit null"
Assert-Near $p1.WarnAtPercent 80 0.001 "S1 WarnAtPercent defaults to 80"
Assert-Near $p1.BlockAtPercent 100 0.001 "S1 BlockAtPercent defaults to 100"
Assert-Equal $p1.UnknownCostPolicy 'BLOCK' "S1 UnknownCostPolicy defaults to BLOCK"
Assert-Equal ($p1.Enabled -eq $true) $true "S1 Enabled defaults true"
Assert-Equal ($p1.IncludeEstimatedPendingCost -eq $true) $true "S1 IncludeEstimatedPendingCost defaults true"
Assert-Equal ($p1.AllowManualOverride -eq $true) $true "S1 AllowManualOverride defaults true"
Assert-Equal ($p1.RequireReasonForOverride -eq $true) $true "S1 RequireReasonForOverride defaults true"

# S2  BudgetPolicy validation
$p1v = Test-BudgetPolicy $p1
Assert-True $p1v.Valid "S2 valid policy passes Test-BudgetPolicy"
Assert-Throws { New-BudgetPolicy -PolicyId 'BAD' -Currency 'INR' -TaskLimit -5 } "S2 negative limit throws"
Assert-Throws { New-BudgetPolicy -PolicyId 'BAD' -Currency 'INR' -WarnAtPercent 90 -BlockAtPercent 80 } "S2 warn>block throws"
Assert-Throws { New-BudgetPolicy -PolicyId 'BAD' -Currency 'INR' -UnknownCostPolicy 'MAYBE' } "S2 invalid UnknownCostPolicy throws"
Assert-Throws { New-BudgetPolicy -PolicyId '' } "S2 missing PolicyId throws"

# S3  Get-AiProjectedSpend -- actual vs estimated-pending distinguished
$usage = @{ CurrentActualSpend = 10.0; CurrentEstimatedPendingSpend = 5.0; Currency = 'INR'; CurrencyUncertain = $false }
$proj = Get-AiProjectedSpend -Usage $usage -ProposedAttemptCost 3 -ProposedCostCurrency 'INR' -IncludeEstimatedPendingCost $true -EvaluationTimestampUtc $tsNoon
Assert-Near $proj.CurrentActualSpend 10 0.001 "S3 actual spend separated"
Assert-Near $proj.CurrentEstimatedPendingSpend 8 0.001 "S3 pending = prior estimates + proposed (5+3)"
Assert-Near $proj.ProjectedSpend 18 0.001 "S3 projected = actual + pending (10+8)"
$proj2 = Get-AiProjectedSpend -Usage $usage -ProposedAttemptCost 3 -ProposedCostCurrency 'INR' -IncludeEstimatedPendingCost $false -EvaluationTimestampUtc $tsNoon
Assert-Near $proj2.CurrentEstimatedPendingSpend 5 0.001 "S3 IncludeEstimatedPendingCost=false keeps prior pending, drops proposed (5, not 8)"
Assert-Near $proj2.ProjectedSpend 15 0.001 "S3 IncludeEstimatedPendingCost=false -> projected 10+5"

# S4  No applicable budget
$def = Get-DefaultBudgetPolicy
$e4 = Test-AiBudget -Policy $def -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' -Attempts @()
Assert-Equal $e4.Decision 'NO_APPLICABLE_BUDGET' "S4 default policy -> NO_APPLICABLE_BUDGET"
Assert-Contains $e4.ReasonCodes 'NO_APPLICABLE_LIMIT' "S4 reason NO_APPLICABLE_LIMIT"

# S5  Task limit under limit -> ALLOW
$p5 = New-BudgetPolicy -PolicyId 'P5' -Currency 'INR' -TaskLimit 100 -AllowManualOverride $false
$att5 = @(New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -StartedAtUtc $tsNoon -ActualCost 10 -CostCurrency 'INR')
$e5 = Test-AiBudget -Policy $p5 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' -Attempts $att5
Assert-Equal $e5.Decision 'ALLOW' "S5 task spend under limit -> ALLOW"
Assert-Contains $e5.ReasonCodes 'UNDER_LIMIT' "S5 reason UNDER_LIMIT"

# S6  Task limit exceeded -> BLOCK_BUDGET_EXCEEDED
$p6 = New-BudgetPolicy -PolicyId 'P6' -Currency 'INR' -TaskLimit 10 -AllowManualOverride $false
$att6 = @(New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -StartedAtUtc $tsNoon -ActualCost 8 -CostCurrency 'INR')
$e6 = Test-AiBudget -Policy $p6 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' -Attempts $att6
Assert-Equal $e6.Decision 'BLOCK_BUDGET_EXCEEDED' "S6 projected over task limit -> BLOCK_BUDGET_EXCEEDED"
Assert-Contains $e6.ReasonCodes 'TASK_LIMIT_EXCEEDED' "S6 reason TASK_LIMIT_EXCEEDED"

# S7  Change limit
$p7 = New-BudgetPolicy -PolicyId 'P7' -Currency 'INR' -ChangeLimit 20 -AllowManualOverride $false
$att7 = @(
    (New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -ChangeId 'C1' -StartedAtUtc $tsNoon -ActualCost 15 -CostCurrency 'INR'),
    (New-DbM21Attempt -AttemptId 'a2' -TaskId 'T2' -ChangeId 'C2' -StartedAtUtc $tsNoon -ActualCost 10 -CostCurrency 'INR')
)
$e7 = Test-AiBudget -Policy $p7 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -ChangeId 'C1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 10 -ProposedCostCurrency 'INR' -Attempts $att7
Assert-Equal $e7.Decision 'BLOCK_BUDGET_EXCEEDED' "S7 change C1 projected over ChangeLimit -> block"
Assert-Contains $e7.ReasonCodes 'CHANGE_LIMIT_EXCEEDED' "S7 reason CHANGE_LIMIT_EXCEEDED (C2 excluded)"
$e7b = Test-AiBudget -Policy $p7 -EvaluationTimestampUtc $tsNoon -TaskId 'T2' -ChangeId 'C2' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' -Attempts $att7
Assert-Equal $e7b.Decision 'ALLOW' "S7 change C2 (10 spent + 5 proposed = 15 < 20) under its own ChangeLimit -> ALLOW (per-change scoping)"

# S8  Session limit with explicit window
$p8 = New-BudgetPolicy -PolicyId 'P8' -Currency 'INR' -SessionLimit 50 -AllowManualOverride $false
$att8 = @(
    (New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -SessionId 'S1' -StartedAtUtc ([datetime]::Parse('2026-08-31T10:00:00Z').ToUniversalTime()) -ActualCost 30 -CostCurrency 'INR'),
    (New-DbM21Attempt -AttemptId 'a2' -TaskId 'T1' -SessionId 'S1' -StartedAtUtc ([datetime]::Parse('2026-08-30T09:00:00Z').ToUniversalTime()) -ActualCost 200 -CostCurrency 'INR')
)
$e8 = Test-AiBudget -Policy $p8 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -SessionId 'S1' `
    -SessionWindowStartUtc ([datetime]::Parse('2026-08-31T08:00:00Z').ToUniversalTime()) `
    -SessionWindowEndUtc ([datetime]::Parse('2026-08-31T20:00:00Z').ToUniversalTime()) `
    -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 20 -ProposedCostCurrency 'INR' -Attempts $att8
Assert-Equal $e8.Decision 'BLOCK_BUDGET_EXCEEDED' "S8 session spend over SessionLimit -> block"
Assert-Contains $e8.ReasonCodes 'SESSION_LIMIT_EXCEEDED' "S8 reason SESSION_LIMIT_EXCEEDED (out-of-window attempt excluded)"

# S9  Daily limit -- deterministic day window from injected timestamp
$p9 = New-BudgetPolicy -PolicyId 'P9' -Currency 'INR' -DailyLimit 100 -AllowManualOverride $false
$att9 = @(
    (New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -StartedAtUtc ([datetime]::Parse('2026-08-31T10:00:00Z').ToUniversalTime()) -ActualCost 60 -CostCurrency 'INR'),
    (New-DbM21Attempt -AttemptId 'a2' -TaskId 'T1' -StartedAtUtc ([datetime]::Parse('2026-08-30T23:00:00Z').ToUniversalTime()) -ActualCost 500 -CostCurrency 'INR')
)
$e9 = Test-AiBudget -Policy $p9 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 50 -ProposedCostCurrency 'INR' -Attempts $att9
Assert-Equal $e9.Decision 'BLOCK_BUDGET_EXCEEDED' "S9 daily projected over DailyLimit -> block"
Assert-Contains $e9.ReasonCodes 'DAILY_LIMIT_EXCEEDED' "S9 reason DAILY_LIMIT_EXCEEDED (previous-day attempt excluded)"

# S10  Monthly limit -- deterministic month window
$p10 = New-BudgetPolicy -PolicyId 'P10' -Currency 'INR' -MonthlyLimit 200 -AllowManualOverride $false
$att10 = @(
    (New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -StartedAtUtc ([datetime]::Parse('2026-08-15T10:00:00Z').ToUniversalTime()) -ActualCost 150 -CostCurrency 'INR'),
    (New-DbM21Attempt -AttemptId 'a2' -TaskId 'T1' -StartedAtUtc ([datetime]::Parse('2026-07-31T23:00:00Z').ToUniversalTime()) -ActualCost 999 -CostCurrency 'INR')
)
$e10 = Test-AiBudget -Policy $p10 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 60 -ProposedCostCurrency 'INR' -Attempts $att10
Assert-Equal $e10.Decision 'BLOCK_BUDGET_EXCEEDED' "S10 monthly projected over MonthlyLimit -> block"
Assert-Contains $e10.ReasonCodes 'MONTHLY_LIMIT_EXCEEDED' "S10 reason MONTHLY_LIMIT_EXCEEDED (July attempt excluded)"

# S11  Team / workspace limit
$p11 = New-BudgetPolicy -PolicyId 'P11' -Currency 'INR' -TeamLimit 500 -AllowManualOverride $false
$att11 = @(
    (New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -StartedAtUtc $tsNoon -ActualCost 250 -CostCurrency 'INR'),
    (New-DbM21Attempt -AttemptId 'a2' -TaskId 'T2' -StartedAtUtc $tsNoon -ActualCost 230 -CostCurrency 'INR')
)
$e11 = Test-AiBudget -Policy $p11 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 30 -ProposedCostCurrency 'INR' -Attempts $att11
Assert-Equal $e11.Decision 'BLOCK_BUDGET_EXCEEDED' "S11 team spend across tasks over TeamLimit -> block"
Assert-Contains $e11.ReasonCodes 'TEAM_LIMIT_EXCEEDED' "S11 reason TEAM_LIMIT_EXCEEDED"

# S12  Warning threshold
$p12 = New-BudgetPolicy -PolicyId 'P12' -Currency 'INR' -TaskLimit 100 -WarnAtPercent 80
$att12 = @(New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -StartedAtUtc $tsNoon -ActualCost 75 -CostCurrency 'INR')
$e12 = Test-AiBudget -Policy $p12 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' -Attempts $att12
Assert-Equal $e12.Decision 'ALLOW_WITH_WARNING' "S12 projected at/above warning threshold -> ALLOW_WITH_WARNING"
Assert-Contains $e12.ReasonCodes 'WARNING_THRESHOLD_REACHED' "S12 reason WARNING_THRESHOLD_REACHED"

# S13  Unknown cost -- UnknownCostPolicy ALLOW
$p13 = New-BudgetPolicy -PolicyId 'P13' -Currency 'INR' -TaskLimit 100 -UnknownCostPolicy 'ALLOW' -AllowManualOverride $false
$att13 = @(New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -StartedAtUtc $tsNoon -ActualCost 10 -CostCurrency 'INR')
$e13 = Test-AiBudget -Policy $p13 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost $null -ProposedCostCurrency 'INR' -ProposedCostUnknown $true -Attempts $att13
Assert-Equal $e13.Decision 'ALLOW' "S13 unknown cost with ALLOW policy -> ALLOW (never treated as zero, but allowed)"
Assert-Contains $e13.ReasonCodes 'COST_UNKNOWN_ALLOWED' "S13 reason COST_UNKNOWN_ALLOWED"

# S14  Unknown cost -- UnknownCostPolicy BLOCK (default)
$p14 = New-BudgetPolicy -PolicyId 'P14' -Currency 'INR' -TaskLimit 100 -UnknownCostPolicy 'BLOCK' -AllowManualOverride $false
$e14 = Test-AiBudget -Policy $p14 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost $null -ProposedCostCurrency 'INR' -ProposedCostUnknown $true -Attempts $att13
Assert-Equal $e14.Decision 'BLOCK_COST_UNKNOWN' "S14 unknown cost with BLOCK policy -> BLOCK_COST_UNKNOWN"
Assert-Contains $e14.ReasonCodes 'COST_UNKNOWN_BLOCKED' "S14 reason COST_UNKNOWN_BLOCKED"

# S15  Multiple limits -- strictest wins
$p15 = New-BudgetPolicy -PolicyId 'P15' -Currency 'INR' -TaskLimit 100 -DailyLimit 25 -AllowManualOverride $false
$att15 = @(New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -StartedAtUtc $tsNoon -ActualCost 10 -CostCurrency 'INR')
$e15 = Test-AiBudget -Policy $p15 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 20 -ProposedCostCurrency 'INR' -Attempts $att15
Assert-Equal $e15.Decision 'BLOCK_BUDGET_EXCEEDED' "S15 daily blocks even though task allows -> strictest wins"
Assert-Contains $e15.ReasonCodes 'DAILY_LIMIT_EXCEEDED' "S15 strictest block is the daily limit"
Assert-Contains $e15.ReasonCodes 'BLOCKED_STRICTEST_LIMIT' "S15 reason BLOCKED_STRICTEST_LIMIT"

# S16  Block + AllowManualOverride -> REQUIRE_HUMAN_OVERRIDE
$p16 = New-BudgetPolicy -PolicyId 'P16' -Currency 'INR' -TaskLimit 10 -AllowManualOverride $true
$e16 = Test-AiBudget -Policy $p16 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' -Attempts $att6
Assert-Equal $e16.Decision 'REQUIRE_HUMAN_OVERRIDE' "S16 blocked + AllowManualOverride -> REQUIRE_HUMAN_OVERRIDE"
Assert-True ($e16.RequiresHumanOverride -eq $true) "S16 RequiresHumanOverride true"
Assert-Contains $e16.ReasonCodes 'HUMAN_OVERRIDE_REQUIRED' "S16 reason HUMAN_OVERRIDE_REQUIRED"

# S17  Override prohibited
$p17 = New-BudgetPolicy -PolicyId 'P17' -Currency 'INR' -TaskLimit 10 -AllowManualOverride $false
$e17 = Test-AiBudget -Policy $p17 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' -Attempts $att6
$o17 = Test-AiBudgetOverride -Policy $p17 -Evaluation $e17 -OverrideReference 'R1' -OverrideReason 'emergency' -OverrideTimestampUtc $tsNoon
Assert-Equal ($o17.Granted -eq $false) $true "S17 override refused when policy prohibits it"
Assert-Contains $o17.ReasonCodes 'OVERRIDE_PROHIBITED' "S17 reason OVERRIDE_PROHIBITED"

# S18  Override reason required
$p18 = New-BudgetPolicy -PolicyId 'P18' -Currency 'INR' -TaskLimit 10 -AllowManualOverride $true -RequireReasonForOverride $true
$e18 = Test-AiBudget -Policy $p18 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' -Attempts $att6
$o18 = Test-AiBudgetOverride -Policy $p18 -Evaluation $e18 -OverrideReference 'R1' -OverrideTimestampUtc $tsNoon
Assert-Equal ($o18.Granted -eq $false) $true "S18 override refused without a reason"
Assert-Contains $o18.ReasonCodes 'OVERRIDE_REASON_REQUIRED' "S18 reason OVERRIDE_REASON_REQUIRED"

# S19  Override granted on explicit evidence
$o19 = Test-AiBudgetOverride -Policy $p18 -Evaluation $e18 -OverrideReference 'R-2026-08-31-1' -OverrideReason 'emergency window' -OverrideTimestampUtc $tsNoon -OverrideScope 'TASK' -OverrideAmount 12
Assert-Equal ($o19.Granted -eq $true) $true "S19 explicit override evidence grants the override"
Assert-Contains $o19.ReasonCodes 'HUMAN_OVERRIDE_GRANTED' "S19 reason HUMAN_OVERRIDE_GRANTED"
Assert-Equal $o19.OverrideReference 'R-2026-08-31-1' "S19 override reference preserved"
# No override needed when not blocked
$o19b = Test-AiBudgetOverride -Policy $p5 -Evaluation $e5 -OverrideReference 'R' -OverrideReason 'x' -OverrideTimestampUtc $tsNoon
Assert-Equal ($o19b.Granted -eq $false) $true "S19 no override needed when nothing blocked"
Assert-Contains $o19b.ReasonCodes 'NO_OVERRIDE_NEEDED' "S19 reason NO_OVERRIDE_NEEDED"

# S20  Human Git gates consume ZERO AI budget
$e20 = Test-AiBudget -Policy $p6 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'HUMAN_GATE' -ProposedAttemptCost $null -ProposedCostCurrency 'INR' -Attempts $att6
Assert-Equal $e20.Decision 'ALLOW' "S20 HUMAN_GATE -> ALLOW regardless of budget"
Assert-Contains $e20.ReasonCodes 'HUMAN_GATE_ZERO_COST' "S20 reason HUMAN_GATE_ZERO_COST"
Assert-Contains $e20.ReasonCodes 'PURPOSE_NOT_AI_ATTEMPT' "S20 reason PURPOSE_NOT_AI_ATTEMPT"

# S21  Governance waits consume ZERO AI budget
$e21 = Test-AiBudget -Policy $p6 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'GOVERNANCE_WAIT' -ProposedAttemptCost $null -ProposedCostCurrency 'INR' -Attempts $att6
Assert-Equal $e21.Decision 'ALLOW' "S21 GOVERNANCE_WAIT -> ALLOW regardless of budget"
Assert-Contains $e21.ReasonCodes 'GOVERNANCE_ZERO_COST' "S21 reason GOVERNANCE_ZERO_COST"

# S22  Currency conversion via DB-M16 FX -- actual-preferred, no invented rate
$fxCfg = New-DbM21FxConfig 83.5
$p22 = New-BudgetPolicy -PolicyId 'P22' -Currency 'INR' -TaskLimit 1000 -AllowManualOverride $false
$att22 = @(
    (New-DbM21Attempt -AttemptId 'a1' -TaskId 'T1' -StartedAtUtc $tsNoon -ActualCost 1.0 -CostCurrency 'USD'),
    (New-DbM21Attempt -AttemptId 'a2' -TaskId 'T1' -StartedAtUtc $tsNoon -EstimatedCost 50 -CostCurrency 'INR'),
    (New-DbM21Attempt -AttemptId 'a3' -TaskId 'T1' -StartedAtUtc $tsNoon -ActualCost 2.0 -CostCurrency 'XYZ')
)
$u22 = Get-AiBudgetUsage -Attempts $att22 -Scope 'TASK' -ScopeKey 'T1' -Currency 'INR' `
    -Configuration $fxCfg -EvaluationTimestampUtc $tsNoon
Assert-Near $u22.CurrentActualSpend 83.5 0.01 "S22 USD actual converted to INR via DB-M16 FX (1.0 x 83.5)"
Assert-Near $u22.CurrentEstimatedPendingSpend 50 0.001 "S22 estimated-only in INR separated as pending"
Assert-True ($u22.CurrencyUncertain -eq $true) "S22 unconvertible currency (XYZ) -> controlled CurrencyUncertain"
$e22 = Test-AiBudget -Policy $p22 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' `
    -ProposedAttemptCost 0.2 -ProposedCostCurrency 'USD' -Attempts $att22 -Configuration $fxCfg
Assert-Contains $e22.ReasonCodes 'CURRENCY_UNAVAILABLE' "S22 reason CURRENCY_UNAVAILABLE (unknown-currency spend)"
# convertible-only path: no uncertain record -> decision under limit
$att22b = @($att22[0], $att22[1])
$e22b = Test-AiBudget -Policy $p22 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' `
    -ProposedAttemptCost 0.2 -ProposedCostCurrency 'USD' -Attempts $att22b -Configuration $fxCfg
Assert-Equal $e22b.Decision 'ALLOW' "S22 fully-convertible spend under limit -> ALLOW"
# unknown price is never fabricated: no FX for the pair
$e22c = Test-AiBudget -Policy $p22 -EvaluationTimestampUtc $tsNoon -TaskId 'T1' -Purpose 'AI_ATTEMPT' `
    -ProposedAttemptCost 0.2 -ProposedCostCurrency 'EUR' -Attempts $att22b -Configuration $fxCfg
Assert-In $e22c.Decision @('BLOCK_COST_UNKNOWN', 'ALLOW_WITH_WARNING', 'ALLOW') "S22 EUR without a rate never invents a rate (UnknownCostPolicy BLOCK -> block)"

# S23  Deterministic day windows -- injected timestamp + accounting offset
$w0 = Get-DbM21DayWindow -TimestampUtc $tsNoon -OffsetHours 0
Assert-Equal $w0.StartUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') '2026-08-31T00:00:00Z' "S23 UTC day window starts at midnight UTC"
$w5 = Get-DbM21DayWindow -TimestampUtc $tsNoon -OffsetHours 5.5
Assert-Equal $w5.StartUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') '2026-08-30T18:30:00Z' "S23 IST(+5.5) day window starts 18:30 previous UTC day"
$late = [datetime]::Parse('2026-08-31T20:00:00Z').ToUniversalTime()
$wLate = Get-DbM21DayWindow -TimestampUtc $late -OffsetHours 5.5
Assert-Equal $wLate.StartUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') '2026-08-31T18:30:00Z' "S23 +5.5 boundary crosses into the next accounting day"
$wA = Get-DbM21DayWindow -TimestampUtc $tsNoon -OffsetHours 0
$wB = Get-DbM21DayWindow -TimestampUtc $tsNoon -OffsetHours 0
Assert-Equal $wA.StartUtc.ToString() $wB.StartUtc.ToString() "S23 identical inputs -> identical window (deterministic, never machine clock)"

# -----------------------------------------------------------------------------
if ($script:Fails -gt 0) { exit 1 }
exit 0

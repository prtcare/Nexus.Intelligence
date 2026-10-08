# Test-DbM29TaskHistory.ps1 -- DB-M29 TASK COST, ATTEMPT & ESCALATION HISTORY UI test suite (55 scenarios, S1-S55).
#
# Objective (the brief): an operator-facing UI showing the COMPLETE AI execution
# history of a task across attempts, retries, corrections, escalations, provider
# failures, model-quality failures, budget decisions, verification outcomes. It
# answers WHAT WAS TRIED? WHY DID IT FAIL? WHY RETRY OR ESCALATE? HOW MUCH PER
# ATTEMPT? TOTAL COST? WHICH ATTEMPT FINALLY PASSED VERIFICATION?
#
# DB-M29 is PURE presentation. It reuses DB-M14..M28 READ-ONLY (SHA-256 verified
# byte-identical before/after the run) and creates NO second attempt-history
# database. AUTO_EXECUTION_ENABLED = FALSE. Provider/model executed: NO. Paid
# calls: 0. Network calls: 0.
#
# Every scenario runs deterministically against the real DB-M14..M28
# implementations consumed READ-ONLY plus deterministic synthetic fixtures
# (clone of the real New-AiAttemptRecord v1 signature with DB-M20/25 extended
# fields added via Add-Member -- the same pattern the DB-M25/M26 harnesses use).
# The live DB-M17 attempt store is read once for an HONEST empty-state proof.
#
# Exit code: 0 = all 55 scenarios + all regressions passed; 1 = any failure.
# Prints "DB-M29 TEST SUMMARY: <passed> passed, <failed> failed".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "HistoryEngine.ps1")   # engine (dot-sources contracts + DB-M25 QualityCost)
. (Join-Path $PSScriptRoot "HistoryRender.ps1")   # renderer (dot-sources contracts; emits the artifact)
. (Join-Path $PSScriptRoot "..\escalation\EscalationPolicy.ps1")  # DB-M20 vocab (READ-ONLY): Get-DbM20ReasonCodes / Get-DbM20FailureCategories
. (Join-Path $PSScriptRoot "..\provider-health\ProviderHealthContracts.ps1")  # DB-M22 evidence fixture builder (READ-ONLY)

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# --- Forge host root ----------------------------------------------------------------------
# W6/LaneA moved the AI material out of Forge into this repository. Some assertions here
# are still ABOUT Forge: that this suite did not mutate the operator console, that the
# Forge solution still builds, that the Forge-owned DB-M18.1 lineage suite is still green.
# Those subjects did not move, so the root that reaches them is resolved separately and
# EXPLICITLY (see ai-routing\AiHostRoot.ps1). When it is not declared, the cross-tree
# assertions report SKIPs rather than passing on a guessed path.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'AiHostRoot.ps1')
# Child-suite size is DERIVED from the child's own declaration, never pinned to a literal.
# See ai-routing\SuiteInventory.ps1 for why: this file used to assert `DBM26 still 381 passed`.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'SuiteInventory.ps1')
$script:ForgeRoot = Resolve-ForgeHostRoot
$script:HostSkips = New-Object System.Collections.Generic.List[string]

$script:NowUtc = '2026-09-01T08:00:00Z'   # deterministic reference
$script:FixtureFiles = @(
    'ai-routing\task-history\HistoryContracts.ps1',
    'ai-routing\task-history\HistoryEngine.ps1',
    'ai-routing\task-history\HistoryRender.ps1'
)
# The RUNTIME library (the task-history UI itself), scanned by the no-mutation /
# no-execution / no-secret / no-cost-formula / no-second-database proofs. The
# test harness is deliberately excluded: its own assertion needles are the
# forbidden tokens, and the harness is never part of the runtime -- the proof is
# about what the UI LIBRARY can do.
$script:LibraryFiles = @(
    'ai-routing\task-history\HistoryContracts.ps1',
    'ai-routing\task-history\HistoryEngine.ps1',
    'ai-routing\task-history\HistoryRender.ps1'
)

# Failure-category display vocabulary = union of the DB-M17 recorded categories and
# the DB-M20 superset (READ-ONLY authorities). A node's FailureCategory must be a
# member -- the UI never invents a category.
$script:FailureVocab = @(@(Get-AiAttemptFailureCategories) + @(Get-DbM20FailureCategories) | Sort-Object -Unique)

# --- assertion helpers (must return nothing) -----------------------------------------

$script:TestCount = 0
$script:TestFails = New-Object System.Collections.Generic.List[string]
$script:ScenarioFails = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:TestCount++
    if (-not $Condition) { $script:TestFails.Add($Message) }
}
function Assert-Null {
    param($Actual, [string]$Message)
    $script:TestCount++
    if ($null -ne $Actual) { $script:TestFails.Add("$Message (expected null, got '$Actual')") }
}
function Assert-NotNull {
    param($Actual, [string]$Message)
    $script:TestCount++
    if ($null -eq $Actual) { $script:TestFails.Add("$Message (expected non-null, got null)") }
}
function Assert-Near {
    param($Actual, $Expected, [double]$Tolerance = 0.0001, [string]$Message = '')
    $script:TestCount++
    if ($null -eq $Actual -or $null -eq $Expected) {
        if ($null -ne $Actual -or $null -ne $Expected) { $script:TestFails.Add("$Message (null mismatch: actual=$Actual expected=$Expected)") }
        return
    }
    if ([math]::Abs([double]$Actual - [double]$Expected) -gt $Tolerance) {
        $script:TestFails.Add("$Message (actual=$Actual expected=$Expected)")
    }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:TestCount++
    if ("$Actual" -ne "$Expected") { $script:TestFails.Add("$Message (actual='$Actual' expected='$Expected')") }
}
function Assert-In {
    param($Actual, [AllowNull()][string[]]$Allowed, [string]$Message)
    $script:TestCount++
    if ("$Actual" -notin $Allowed) { $script:TestFails.Add("$Message (actual='$Actual' not in [$($Allowed -join ',')])") }
}
function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Message)
    $script:TestCount++
    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $script:TestFails.Add("$Message (missing '$Needle')")
    }
}
function Assert-NotContains {
    param([string]$Text, [string]$Needle, [string]$Message)
    $script:TestCount++
    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $script:TestFails.Add("$Message (unexpected '$Needle' present)")
    }
}

# --- fixture helpers -------------------------------------------------------------------

function New-Att {
    <#
    .SYNOPSIS
    Build a deterministic synthetic AiAttemptRecord v1 (DB-M17) for one scenario.
    Never writes to disk. ClaudeReviewStatus and FailureFingerprintId are EXTENDED
    fields (DB-M20/25/26 read them defensively; the DB-M17 record shape is
    untouched and they are attached via Add-Member -- the same pattern as the
    DB-M25/DB-M26 harnesses). Empty strings are normalized to null by the
    constructor.
    #>
    param(
        [string]$TaskId, [string]$NodeId, [string]$ChangeId, [string]$AttemptId,
        [string]$ParentAttemptId, [int]$RetryNumber = 0,
        [string]$Result = 'SUCCESS', [string]$VerificationResult = '',
        [string]$FailureCategory, [Nullable[double]]$ActualCost, [Nullable[double]]$EstimatedCost,
        [string]$CostCurrency = 'INR', [string]$ProviderId = 'prov-a', [string]$ModelId = 'model-a',
        [string]$UnderlyingModelId = 'um-a', [string]$GatewayProviderId,
        [string]$ReasoningLevel = 'MEDIUM', [string]$TaskType = 'IMPLEMENTATION',
        [string]$Complexity = 'MEDIUM', [string]$Risk = 'LOW', [string]$ExecutionMode = 'ASSISTED',
        [Nullable[long]]$DurationMs, [Nullable[long]]$InputTokens, [Nullable[long]]$OutputTokens,
        [Nullable[long]]$ContextTokens,
        [string]$StartedAtUtc = '2026-08-31T10:00:00Z', [string]$EndedAtUtc = '2026-08-31T10:00:30Z',
        [string]$EscalatedFromAttemptId, [string]$EscalatedToAttemptId, [string]$EscalationReason,
        [string]$FailureFingerprintId, [string]$ClaudeReviewStatus
    )
    $rec = New-AiAttemptRecord -TaskId $TaskId -NodeId $NodeId -ChangeId $ChangeId -AttemptId $AttemptId `
        -ParentAttemptId $ParentAttemptId -RetryNumber $RetryNumber `
        -Result $Result -VerificationResult $VerificationResult -FailureCategory $FailureCategory `
        -ActualCost $ActualCost -EstimatedCost $EstimatedCost -CostCurrency $CostCurrency `
        -ProviderId $ProviderId -ModelId $ModelId -UnderlyingModelId $UnderlyingModelId `
        -GatewayProviderId $GatewayProviderId -ReasoningLevel $ReasoningLevel -TaskType $TaskType `
        -Complexity $Complexity -Risk $Risk -ExecutionMode $ExecutionMode `
        -DurationMs $DurationMs -InputTokens $InputTokens -OutputTokens $OutputTokens -ContextTokens $ContextTokens `
        -StartedAtUtc $StartedAtUtc -EndedAtUtc $EndedAtUtc `
        -EscalatedFromAttemptId $EscalatedFromAttemptId -EscalatedToAttemptId $EscalatedToAttemptId `
        -EscalationReason $EscalationReason
    if ($FailureFingerprintId) { $rec | Add-Member -NotePropertyName 'FailureFingerprintId' -NotePropertyValue $FailureFingerprintId -Force }
    if ($ClaudeReviewStatus) { $rec | Add-Member -NotePropertyName 'ClaudeReviewStatus' -NotePropertyValue $ClaudeReviewStatus -Force }
    return $rec
}

function New-Dec {
    <#
    .SYNOPSIS
    Build an EscalationDecision v1 (DB-M20) from a field table. AutoExecutionEnabled
    is always FALSE by the constructor.
    #>
    param([AllowNull()][hashtable]$Fields = $null)
    return New-EscalationDecision -Fields $Fields
}

function New-Fp {
    <#
    .SYNOPSIS
    Build a FailureFingerprint v1 (DB-M21). The FingerprintId is generated from the
    failure identity; callers attach a record's FailureFingerprintId to the
    fingerprint's real id so the engine's fingerprint map resolves it.
    #>
    param(
        [string]$TaskType = 'IMPLEMENTATION',
        [string]$FailureCategory = 'MODEL_QUALITY',
        [string[]]$NormalizedFailureCodes = @('COMPILE_ERROR'),
        [int]$OccurrenceCount = 1,
        [string]$TaskId = '', [string]$ChangeId = '', [string]$ModelId = ''
    )
    return New-FailureFingerprint @{
        TaskType = $TaskType; FailureCategory = $FailureCategory
        NormalizedFailureCodes = $NormalizedFailureCodes; OccurrenceCount = $OccurrenceCount
        TaskId = $TaskId; ChangeId = $ChangeId; ModelId = $ModelId
    }
}

function New-Health {
    <#
    .SYNOPSIS
    Build a ProviderHealthEvidence v1 (DB-M22) attached to one attempt.
    #>
    param(
        [string]$ProviderId, [string]$AttemptIdReference, [string]$ObservedState = 'UNAVAILABLE',
        [string]$RetryAfterUtc = $null
    )
    $fields = @{
        ProviderId = $ProviderId; ObservedState = $ObservedState
        EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = '2026-08-31T11:00:00Z'
        AttemptIdReference = $AttemptIdReference
    }
    if ($RetryAfterUtc) { $fields.RetryAfterUtc = $RetryAfterUtc }
    return New-ProviderHealthEvidence -Fields $fields
}

function Get-View {
    <#
    .SYNOPSIS
    Convenience: run the DB-M29 view engine with explicit (nullable) inputs.
    #>
    param(
        [AllowNull()][object[]]$Records,
        [AllowNull()][object]$Query = $null,
        [AllowNull()][object[]]$EscalationDecisions = $null,
        [AllowNull()][object[]]$Fingerprints = $null,
        [AllowNull()][object[]]$ProviderHealth = $null
    )
    return Get-DbM29TaskHistoryView -Records $Records -Query $Query `
        -EscalationDecisions $EscalationDecisions -Fingerprints $Fingerprints -ProviderHealth $ProviderHealth
}

function Get-Query {
    <#
    .SYNOPSIS
    A deterministic TaskHistoryQuery v1 with the common defaults.
    #>
    param(
        [string]$TaskId, [string]$ProviderId, [string]$ModelId,
        [string]$SortBy = 'TASK_ID', [string]$SortDirection = 'ASCENDING',
        [string]$SuccessDefinition = 'VERIFIED', [bool]$AllowEstimatedCostFallback = $false,
        [string]$Currency = 'INR'
    )
    return New-DbM29TaskHistoryQuery -NowUtc $script:NowUtc -TaskId $TaskId -ProviderId $ProviderId `
        -ModelId $ModelId -SortBy $SortBy -SortDirection $SortDirection `
        -SuccessDefinition $SuccessDefinition -AllowEstimatedCostFallback $AllowEstimatedCostFallback `
        -Currency $Currency
}

function Get-BriefRecords {
    <#
    .SYNOPSIS
    The brief's ATTEMPT TIMELINE example as records:
      A1 DeepSeek Medium  ₹1.25 IMPLEMENTATION_FAILED (fingerprint)      -> retry
      A2 DeepSeek High    ₹2.00 VERIFICATION_FAILURE (M06 failed)        -> escalation
      A3 Claude (OR)      ₹3.00 SUCCESS/VERIFIED + ClaudeReview FIX_REQ  -> correction
      A4 Claude (OR)      ₹1.00 SUCCESS/VERIFIED (parent = A3)           -> VERIFIED_SUCCESS
    #>
    $fp = New-Fp -TaskId 'T-BRIEF' -FailureCategory 'MODEL_QUALITY' -OccurrenceCount 3
    return @(
        (New-Att -TaskId 'T-BRIEF' -NodeId 'N-BRIEF' -ChangeId 'CHG-BRIEF' -AttemptId 'ATT-BRIEF-1' -RetryNumber 0 `
            -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -UnderlyingModelId 'deepseek-v4-flash' `
            -ReasoningLevel 'MEDIUM' -TaskType 'IMPLEMENTATION' -ExecutionMode 'ASSISTED' `
            -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' `
            -ActualCost 1.25 -EstimatedCost 1.25 -FailureFingerprintId $fp.FingerprintId `
            -StartedAtUtc '2026-08-31T10:00:00Z' -EndedAtUtc '2026-08-31T10:00:20Z' -DurationMs 20000 -InputTokens 4000 -OutputTokens 1200),
        (New-Att -TaskId 'T-BRIEF' -NodeId 'N-BRIEF' -ChangeId 'CHG-BRIEF' -AttemptId 'ATT-BRIEF-2' -RetryNumber 1 `
            -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -UnderlyingModelId 'deepseek-v4-flash' `
            -ReasoningLevel 'HIGH' -TaskType 'IMPLEMENTATION' -ExecutionMode 'ASSISTED' `
            -Result 'FAILED' -FailureCategory 'VERIFICATION_FAILURE' `
            -ActualCost 2 -EstimatedCost 2 `
            -StartedAtUtc '2026-08-31T10:01:00Z' -EndedAtUtc '2026-08-31T10:01:40Z' -DurationMs 40000 -InputTokens 6000 -OutputTokens 2000),
        (New-Att -TaskId 'T-BRIEF' -NodeId 'N-BRIEF' -ChangeId 'CHG-BRIEF' -AttemptId 'ATT-BRIEF-3' -RetryNumber 2 `
            -ProviderId 'claude' -ModelId 'claude-sonnet-5' -UnderlyingModelId 'claude-sonnet-5' -GatewayProviderId 'openrouter' `
            -ReasoningLevel 'HIGH' -TaskType 'IMPLEMENTATION' -ExecutionMode 'ASSISTED' `
            -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 3 -EstimatedCost 3 `
            -ClaudeReviewStatus 'FIX_REQUIRED' `
            -StartedAtUtc '2026-08-31T10:03:00Z' -EndedAtUtc '2026-08-31T10:04:00Z' -DurationMs 60000 -InputTokens 8000 -OutputTokens 3000),
        (New-Att -TaskId 'T-BRIEF' -NodeId 'N-BRIEF' -ChangeId 'CHG-BRIEF' -AttemptId 'ATT-BRIEF-4' -ParentAttemptId 'ATT-BRIEF-3' -RetryNumber 3 `
            -ProviderId 'claude' -ModelId 'claude-sonnet-5' -UnderlyingModelId 'claude-sonnet-5' -GatewayProviderId 'openrouter' `
            -ReasoningLevel 'HIGH' -TaskType 'IMPLEMENTATION' -ExecutionMode 'ASSISTED' `
            -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1 -EstimatedCost 1 `
            -StartedAtUtc '2026-08-31T10:05:00Z' -EndedAtUtc '2026-08-31T10:05:10Z' -DurationMs 10000 -InputTokens 1000 -OutputTokens 400)
    ), $fp
}

# --- SHA / frozen-file infrastructure ---------------------------------------------------

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead((Resolve-Path $Path))
    try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
    return ([BitConverter]::ToString($hash) -replace '-', '')
}

# DB-M29 must NOT modify the DB-M14..M28 chain (frozen read-only inputs), its own
# library files, or the DB-M28 suite. The list mirrors the DB-M28 harness scope.
$script:FrozenFiles = @(
    'ai-routing\AiRoutingFoundation.ps1',
    'ai-routing\ModelCatalogue.ps1',
    'ai-routing\AiRoutingPricingFoundation.ps1',
    'ai-routing\AiPricingContracts.ps1',
    'ai-routing\PricingCatalogue.ps1',
    'ai-routing\AiRoutingCostFoundation.ps1',
    'ai-routing\AiCostContracts.ps1',
    'ai-routing\AiExchangeRates.ps1',
    'ai-routing\CostCalculator.ps1',
    'ai-routing\AttemptStore.ps1',
    'ai-routing\providers\common\AdapterContracts.ps1',
    'ai-routing\providers\common\AdapterExecutionGate.ps1',
    'ai-routing\budget\BudgetPolicy.ps1',
    'ai-routing\budget\BudgetEngine.ps1',
    'ai-routing\quality-cost\AiQualityCostContracts.ps1',
    'ai-routing\quality-cost\QualityCost.ps1',
    'ai-routing\performance\AiPerformanceContracts.ps1',
    'ai-routing\performance\AiPerformanceFoundation.ps1',
    'ai-routing\performance\ModelPerformance.ps1',
    'ai-routing\dashboard\DashboardContracts.ps1',
    'ai-routing\dashboard\DashboardData.ps1',
    'ai-routing\dashboard\DashboardRender.ps1',
    'ai-routing\escalation\EscalationContracts.ps1',
    'ai-routing\escalation\EscalationPolicy.ps1',
    'ai-routing\failure-fingerprints\FingerprintContracts.ps1',
    'ai-routing\failure-fingerprints\FingerprintEngine.ps1',
    'ai-routing\failure-fingerprints\AttemptPermission.ps1',
    'ai-routing\provider-health\ProviderHealthContracts.ps1',
    'ai-routing\model-config\ModelConfigContracts.ps1',
    'ai-routing\model-config\ModelConfigEngine.ps1',
    'ai-routing\model-config\ModelConfigRender.ps1'
)
# DB-M18.1 dependency lineage is Forge development-lifecycle logic and stayed in
# Forge; it is not reachable from the AI material root. Kept as a no-mutation guard
# against the DECLARED host root, so the protection survives the move instead of
# being dropped.
$script:ForgeFrozenFiles = @(
    'scripts\ai-routing\DependencyLineage.ps1',
    'scripts\ai-routing\Test-DbM181DependencyLineage.ps1'
)
$script:ShaBefore = @{}
foreach ($rel in $script:FrozenFiles) { $script:ShaBefore[$rel] = Get-Sha256 (Join-Path $script:Root $rel) }
foreach ($rel in $script:FixtureFiles) { $script:ShaBefore[$rel] = Get-Sha256 (Join-Path $script:Root $rel) }
if ($script:ForgeRoot) {
    foreach ($rel in $script:ForgeFrozenFiles) { $script:ShaBefore[$rel] = Get-Sha256 (Join-Path $script:ForgeRoot $rel) }
    $script:ForgeFrozenBefore = $true
} else {
    $script:ForgeFrozenBefore = $false
    $script:HostSkips.Add('S55 Forge DB-M18.1 frozen-file guard: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT)')
}

# Live config files. DB-M29 never writes these; the run must leave them byte-identical.
$script:ConfigFiles = @(
    'config\providers.json',
    'config\models.json',
    'config\ai-routing.json',
    'config\pricing\pricing-catalogue.json',
    'config\currency\exchange-rates.json',
    'config\cost\cost-calculator.json',
    'config\performance\confidence-bands.json'
)
$script:CfgShaBefore = @{}
foreach ($rel in $script:ConfigFiles) { $script:CfgShaBefore[$rel] = Get-Sha256 (Join-Path $script:Root $rel) }

$script:WorkbookPath = 'C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx'
$script:WorkbookShaBefore = Get-Sha256 $script:WorkbookPath

$script:UiFiles = @()
if ($script:ForgeRoot) {
    $uiDir = Join-Path $script:ForgeRoot 'src\DevBridge.UI'
    if (Test-Path -LiteralPath $uiDir) {
        $script:UiFiles = @(Get-ChildItem $uiDir -Recurse -File -Include *.xaml,*.cs -ErrorAction SilentlyContinue)
    }
}
$script:UiShaBefore = @{}
foreach ($f in $script:UiFiles) { $script:UiShaBefore[$f.FullName] = Get-Sha256 $f.FullName }

# --- regression suites (child processes; read-only over the DB-M29 scope) ----------------

function Invoke-RegressionSuite {
    <#
    .SYNOPSIS
    Run a frozen dependency suite as a CHILD process (read-only over the DB-M29
    scope) and parse its outcome. Child suites use varied summary formats, so the
    parser accepts, in order: 'TEST SUMMARY: N passed, M failed' (LAST match),
    'N assertions, N failed/failures', 'PASSED: N' + 'FAILED: N', 'N checks,
    A passed, B failed', and falls back to counting PASS:/FAIL: lines.
    #>
    param([string]$Name, [string]$Path, [string]$Root)
    $base = if ($Root) { $Root } else { $script:Root }
    $full = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $base $Path }
    $log = Join-Path $env:TEMP ("db29-reg-" + $Name + '.log')
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $full > $log 2>&1
    $exit = $LASTEXITCODE
    $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
    $passed = -1
    $failed = -1
    $all = [regex]::Matches($text, 'TEST SUMMARY:\s*(\d+)\s+passed,\s*(\d+)\s+failed')
    if ($all.Count -gt 0) { $last = $all[$all.Count - 1]; $passed = [int]$last.Groups[1].Value; $failed = [int]$last.Groups[2].Value }
    if ($passed -lt 0) {
        $all = [regex]::Matches($text, '(\d+)\s+assertions?,\s*(\d+)\s+(?:failed|failures)')
        if ($all.Count -gt 0) { $last = $all[$all.Count - 1]; $passed = [int]$last.Groups[1].Value; $failed = [int]$last.Groups[2].Value }
    }
    if ($passed -lt 0) {
        $mPass = [regex]::Match($text, '(?m)^PASSED:\s*(\d+)\s*$')
        $mFail = [regex]::Match($text, '(?m)^FAILED:\s*(\d+)\s*$')
        if ($mPass.Success) { $passed = [int]$mPass.Groups[1].Value; $failed = if ($mFail.Success) { [int]$mFail.Groups[1].Value } else { 0 } }
    }
    if ($passed -lt 0) {
        $all = [regex]::Matches($text, '(\d+)\s+checks?,\s*(\d+)\s+passed,\s*(\d+)\s+failed')
        if ($all.Count -gt 0) { $last = $all[$all.Count - 1]; $passed = [int]$last.Groups[2].Value; $failed = [int]$last.Groups[3].Value }
    }
    if ($passed -lt 0) {
        $passed = ([regex]::Matches($text, '(?m)^\s*(PASS:|\[PASS\])')).Count
        $failed = ([regex]::Matches($text, '(?m)^\s*(FAIL:|\[FAIL\])')).Count
    }
    return @{ Name = $Name; Passed = $passed; Failed = $failed; ExitCode = $exit; Log = $text }
}

$script:RegressionResults = New-Object System.Collections.Generic.List[object]
$script:ExternalDrift = New-Object System.Collections.Generic.List[string]

function Invoke-DbM29RegressionSuites {
    <#
    .SYNOPSIS
    Run the DB-M29 child-suite regressions (DB-M17/20/21/26/28). Every suite runs
    as a child process and must stay green (or preserve its known external-drift
    signature). Results are recorded for the final report.
    #>
    $r17 = Invoke-RegressionSuite -Name 'DBM17' -Path 'ai-routing\Test-AttemptStore.ps1'
    $script:RegressionResults.Add($r17)
    Assert-True ($r17.ExitCode -eq 0) "REGRESSION DBM17: exit 0 (got $($r17.ExitCode))"
    Assert-True ($r17.Passed -gt 0) "REGRESSION DBM17: assertions ran (got $($r17.Passed))"
    Assert-True ($r17.Failed -eq 0) "REGRESSION DBM17: 0 failures (got $($r17.Failed))"

    $r20 = Invoke-RegressionSuite -Name 'DBM20' -Path 'ai-routing\escalation\Test-DbM20Escalation.ps1'
    $script:RegressionResults.Add($r20)
    Assert-True ($r20.ExitCode -eq 0) "REGRESSION DBM20: exit 0 (got $($r20.ExitCode))"
    Assert-True ($r20.Passed -gt 0) "REGRESSION DBM20: assertions ran (got $($r20.Passed))"
    Assert-True ($r20.Failed -eq 0) "REGRESSION DBM20: 0 failures (got $($r20.Failed))"

    $r21 = Invoke-RegressionSuite -Name 'DBM21' -Path 'ai-routing\failure-fingerprints\Test-DbM21Fingerprints.ps1'
    $script:RegressionResults.Add($r21)
    Assert-True ($r21.ExitCode -eq 0) "REGRESSION DBM21: exit 0 (got $($r21.ExitCode))"
    Assert-True ($r21.Passed -gt 0) "REGRESSION DBM21: assertions ran (got $($r21.Passed))"
    Assert-True ($r21.Failed -eq 0) "REGRESSION DBM21: 0 failures (got $($r21.Failed))"

    # DB-M26 preserves its known external S41 drift (recorded F520060C workbook
    # authority hash vs the live post-DB-M12.4 workbook 6D42C3BF).
    $r26 = Invoke-RegressionSuite -Name 'DBM26' -Path 'ai-routing\dashboard\Test-DbM26Dashboard.ps1'
    $script:RegressionResults.Add($r26)
    # DERIVED, not pinned. This used to read `Assert-Equal $r26.Passed 381`. 381 was the
    # pre-migration size and has been wrong since the AI Head migration; a pinned count also
    # reports a size and never a cause, so "DB-M26 changed size" and "DB-M26 broke" were
    # indistinguishable here. What matters is that DB-M26 ran the inventory it declares.
    $m26Suite = Join-Path $script:Root 'ai-routing\dashboard\Test-DbM26Dashboard.ps1'
    $m26Declared = @(Get-ChildSuiteDeclaration -Path $m26Suite -Kind 'ScenarioList').Count
    $m26Reported = Get-ChildSuiteReportedCount -Log $r26.Log -Pattern 'DB-M26 SCENARIOS:\s*(\d+)\s+scenarios' -SuiteName 'DBM26'
    Assert-True ($m26Reported -eq $m26Declared) "REGRESSION DBM26: ran the inventory it declares (declares $m26Declared scenarios, reported $m26Reported)"
    Assert-True (($r26.Passed + $r26.Failed) -ge $m26Declared) "REGRESSION DBM26: at least one assertion per declared scenario (declares $m26Declared, ran $($r26.Passed + $r26.Failed))"
    Assert-Equal $r26.Failed 1 'REGRESSION DBM26: still exactly 1 failed (external S41)'
    Assert-Contains $r26.Log 'S41' 'REGRESSION DBM26: the single failure is S41'
    Assert-Contains $r26.Log 'F520060C' 'REGRESSION DBM26: S41 names the recorded authority hash'
    $script:ExternalDrift.Add('M26 S41 workbook-authority drift (suite records F520060C; live workbook is 6D42C3BF after DB-M12.4 closure)')

    $r28 = Invoke-RegressionSuite -Name 'DBM28' -Path 'ai-routing\model-config\Test-DbM28ModelConfig.ps1'
    $script:RegressionResults.Add($r28)
    Assert-True ($r28.ExitCode -eq 0) "REGRESSION DBM28: exit 0 (got $($r28.ExitCode))"
    Assert-True ($r28.Failed -eq 0) "REGRESSION DBM28: 0 failures (got $($r28.Failed))"
    Assert-True ($r28.Passed -gt 0) "REGRESSION DBM28: assertions ran (got $($r28.Passed))"
}

# --- scenarios --------------------------------------------------------------------------

# S1 UI opens (renderer emits a self-contained HTML page; export writes the artifact)
function Test-S1-UiOpens {
    $recs, $fp = Get-BriefRecords
    $view = Get-View -Records $recs -Query (Get-Query)
    $html = ConvertTo-DbM29Html -View $view
    Assert-True (-not [string]::IsNullOrWhiteSpace($html)) 'S1: HTML is non-empty'
    Assert-True ($html.Length -gt 4000) 'S1: HTML is substantial'
    Assert-Contains $html '<!doctype html>' 'S1: doctype present'
    Assert-Contains $html 'DevBridge Task Cost · Attempt &amp; Escalation History' 'S1: page title present'
    Assert-Contains $html 'AUTO AI EXECUTION DISABLED' 'S1: no-execution badge present'
    Assert-Contains $html 'read-only' 'S1: read-only footer present'
    Assert-Contains $html 'Attempt-history database: NONE' 'S1: no-second-database marker present'
    Assert-Contains $html 'Secret values displayed: NO' 'S1: no-secret marker present'
    $tmp = Join-Path $env:TEMP 'db29-task-history.html'
    Export-DbM29TaskHistoryHtml -View $view -OutputPath $tmp
    Assert-True ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 4000)) 'S1: exported artifact written and non-empty'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# S2 task list renders (real DB-M17 store consumed READ-ONLY -> honest view)
function Test-S2-TaskListRenders {
    $live = @(Get-AiAttemptsAll -Root $script:Root)
    $view = Get-View -Records $live -Query (Get-Query)
    Assert-Equal $view.Count @($live).Count 'S2: view count mirrors the live store'
    Assert-Equal $view.Empty ($live.Count -eq 0) 'S2: empty flag mirrors the live store'
    Assert-NotNull $view.ReadOnlyGuard 'S2: read-only guard present'
    Assert-Equal $view.ReadOnlyGuard.AutoExecutionEnabled $false 'S2: auto execution disabled'
    $html = ConvertTo-DbM29Html -View $view
    Assert-Contains $html 'AUTO AI EXECUTION DISABLED' 'S2: HTML badge present'
    Assert-Contains $html 'Attempt-history database: NONE' 'S2: no-second-database marker present'
}

# S3 empty store honesty (pure-empty engine path -> honest empty state)
function Test-S3-EmptyStoreHonesty {
    $view = Get-View -Records @() -Query (Get-Query)
    Assert-Equal $view.Count 0 'S3: count is 0'
    Assert-True $view.Empty 'S3: empty flag is true'
    Assert-Equal (@($view.TaskRows).Count) 0 'S3: no task rows'
    Assert-Contains ($view.Warnings -join ' | ') 'No attempt history recorded' 'S3: honest warning'
    $html = ConvertTo-DbM29Html -View $view
    Assert-Contains $html 'No attempt history recorded.' 'S3: HTML empty-state marker present'
}

# S4 task row fields (13 brief fields present on a fixture task row)
function Test-S4-TaskRowFields {
    $recs, $fp = Get-BriefRecords
    $view = Get-View -Records $recs -Query (Get-Query)
    Assert-Equal (@($view.TaskRows).Count) 1 'S4: one task row'
    $row = @($view.TaskRows)[0]
    Assert-Equal $row.TaskId 'T-BRIEF' 'S4: Task ID'
    Assert-Equal $row.ChangeId 'CHG-BRIEF' 'S4: Change ID'
    Assert-Equal $row.Mode 'ASSISTED' 'S4: Mode'
    Assert-Equal $row.AttemptCount 4 'S4: Attempt count'
    Assert-Near $row.TotalActualCost 7.25 -Message 'S4: Total actual cost'
    Assert-Near $row.TotalEstimatedCost 7.25 -Message 'S4: Total estimated cost'
    Assert-Equal $row.VerifiedState 'VERIFIED_SUCCESS' 'S4: Verified-success state'
    Assert-Equal $row.FirstAttemptSuccess 'NO' 'S4: First-attempt success'
    Assert-Equal $row.FinalModelId 'claude-sonnet-5' 'S4: Final model'
    Assert-Equal $row.FinalProviderId 'claude' 'S4: Final provider'
    Assert-Equal $row.CorrectionsCount 1 'S4: Corrections count'
    Assert-Equal $row.EscalationsCount 3 'S4: Escalations count'
    Assert-Equal $row.FailureCount 2 'S4: Failure count'
}

# S5 attempt count (row.AttemptCount = ordered record count)
function Test-S5-AttemptCount {
    $recs, $fp = Get-BriefRecords
    $view = Get-View -Records $recs -Query (Get-Query)
    Assert-Equal (@($view.TaskRows)[0].AttemptCount) 4 'S5: attempt count equals record count'
    $one = @(New-Att -TaskId 'T-ONE' -AttemptId 'A-1' -Result 'SUCCESS' -VerificationResult 'VERIFIED')
    $v2 = Get-View -Records $one -Query (Get-Query)
    Assert-Equal (@($v2.TaskRows)[0].AttemptCount) 1 'S5: single-attempt count'
}

# S6 total actual cost (sum of ActualCost, DB-M16 evidence, never recalculated)
function Test-S6-TotalActualCost {
    $recs, $fp = Get-BriefRecords
    $view = Get-View -Records $recs -Query (Get-Query)
    Assert-Near (@($view.TaskRows)[0].TotalActualCost) 7.25 -Message 'S6: total actual = 1.25+2+3+1'
    $mixture = @(
        (New-Att -TaskId 'T-C' -AttemptId 'C-1' -Result 'FAILED' -ActualCost 0.5),
        (New-Att -TaskId 'T-C' -AttemptId 'C-2' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 4.75)
    )
    Assert-Near (@(Get-View -Records $mixture -Query (Get-Query)).TaskRows)[0].TotalActualCost 5.25 -Message 'S6: mixed chain total actual'
}

# S7 total estimated cost (sum of EstimatedCost; fallback only affects node cost)
function Test-S7-TotalEstimatedCost {
    $est = @(
        (New-Att -TaskId 'T-E' -AttemptId 'E-1' -Result 'FAILED' -EstimatedCost 1.5 -ActualCost $null),
        (New-Att -TaskId 'T-E' -AttemptId 'E-2' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -EstimatedCost 2.5 -ActualCost $null)
    )
    $view = Get-View -Records $est -Query (Get-Query -AllowEstimatedCostFallback $true)
    $row = @($view.TaskRows)[0]
    Assert-Near $row.TotalEstimatedCost 4.0 -Message 'S7: total estimated = 1.5+2.5'
    # node cost uses ESTIMATED only because the query allows the fallback
    Assert-Equal $row.Timeline[0].CostSource 'ESTIMATED' 'S7: node cost source ESTIMATED under fallback'
    Assert-Near $row.Timeline[0].CostAmount 1.5 -Message 'S7: node cost amount estimated'
}

# S8 verified-success state (terminal VERIFIED -> VERIFIED_SUCCESS, DB-M25 authoritative)
function Test-S8-VerifiedSuccessState {
    $recs, $fp = Get-BriefRecords
    $view = Get-View -Records $recs -Query (Get-Query)
    Assert-Equal (@($view.TaskRows)[0].VerifiedState) 'VERIFIED_SUCCESS' 'S8: terminal verified -> VERIFIED_SUCCESS'
    Assert-Equal (@($view.TaskRows)[0].VerifiedAttemptId) 'ATT-BRIEF-4' 'S8: verified attempt is the terminal'
}

# S9 contradicted success (model self-PASS contradicted by independent verification)
function Test-S9-ContradictedSuccess {
    $contradicted = @(New-Att -TaskId 'T-9' -AttemptId '9-1' -Result 'SUCCESS' -VerificationResult 'FAILED' -FailureCategory 'VERIFICATION_FAILURE' -ActualCost 1)
    $view = Get-View -Records $contradicted -Query (Get-Query)
    Assert-Equal (@($view.TaskRows)[0].VerifiedState) 'CONTRADICTED' 'S9: self-PASS + FAILED verification -> CONTRADICTED'
    Assert-Equal (@($view.TaskRows)[0].FirstAttemptSuccess) 'NO' 'S9: a contradicted first attempt is not first-attempt success'
}

# S10 model-returned (SUCCESS + no verification evidence under VERIFIED -> never verified)
function Test-S10-ModelReturned {
    $mr = @(New-Att -TaskId 'T-10' -AttemptId '10-1' -Result 'SUCCESS' -VerificationResult $null -ActualCost 1)
    $view = Get-View -Records $mr -Query (Get-Query)   # SuccessDefinition=VERIFIED (authoritative)
    Assert-Equal (@($view.TaskRows)[0].VerifiedState) 'INCOMPLETE' 'S10: SUCCESS without verification is never VERIFIED_SUCCESS'
    Assert-Equal (@($view.TaskRows)[0].VerifiedAttemptId) '' 'S10: no verified attempt id'
    $vMd = Get-View -Records $mr -Query (Get-Query -SuccessDefinition 'MODEL_RETURNED')
    Assert-Equal (@($vMd.TaskRows)[0].VerifiedState) 'MODEL_RETURNED' 'S10: under MODEL_RETURNED the state flags model-returned'
}

# S11 first-attempt success YES (first ordered attempt resolves verified success)
function Test-S11-FirstAttemptSuccessYes {
    $all = @(
        (New-Att -TaskId 'T-11' -AttemptId '11-1' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1),
        (New-Att -TaskId 'T-11' -AttemptId '11-2' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 2)
    )
    $view = Get-View -Records $all -Query (Get-Query)
    Assert-Equal (@($view.TaskRows)[0].FirstAttemptSuccess) 'YES' 'S11: first attempt verified -> YES'
}

# S12 first-attempt success NO (first attempt failed, later attempt passed)
function Test-S12-FirstAttemptSuccessNo {
    $recs, $fp = Get-BriefRecords
    $view = Get-View -Records $recs -Query (Get-Query)
    Assert-Equal (@($view.TaskRows)[0].FirstAttemptSuccess) 'NO' 'S12: first attempt failed -> NO'
}

# S13 first-attempt UNKNOWN (no attempts)
function Test-S13-FirstAttemptUnknown {
    $row = Get-DbM29TaskRow -Attempts @() -Facts $null -Query (Get-Query)
    Assert-Equal $row.FirstAttemptSuccess 'UNKNOWN' 'S13: no attempts -> UNKNOWN'
    Assert-Equal $row.VerifiedState 'NO_ATTEMPTS' 'S13: no attempts -> NO_ATTEMPTS state'
    Assert-Equal $row.Mode '(none)' 'S13: no attempts -> (none) mode'
}

# S14 final model/provider (terminal attempt identity)
function Test-S14-FinalModelProvider {
    $recs, $fp = Get-BriefRecords
    $view = Get-View -Records $recs -Query (Get-Query)
    $row = @($view.TaskRows)[0]
    Assert-Equal $row.FinalAttemptId 'ATT-BRIEF-4' 'S14: final attempt id'
    Assert-Equal $row.FinalModelId 'claude-sonnet-5' 'S14: final model'
    Assert-Equal $row.FinalProviderId 'claude' 'S14: final provider'
    Assert-Equal $row.FinalReasoningLevel 'HIGH' 'S14: final reasoning level'
    Assert-Equal $row.TerminalOutcome 'SUCCESS' 'S14: terminal outcome'
}

# S15 corrections count (ParentAttemptId / FIX_REQUIRED-then-retry counting)
function Test-S15-CorrectionsCount {
    $recs, $fp = Get-BriefRecords
    Assert-Equal (@(Get-View -Records $recs -Query (Get-Query)).TaskRows)[0].CorrectionsCount 1 'S15: parent-linked correction counted'
    $fixOnly = @(
        (New-Att -TaskId 'T-15' -AttemptId '15-1' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1 -ClaudeReviewStatus 'FIX_REQUIRED'),
        (New-Att -TaskId 'T-15' -AttemptId '15-2' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    Assert-Equal (@(Get-View -Records $fixOnly -Query (Get-Query)).TaskRows)[0].CorrectionsCount 1 'S15: FIX_REQUIRED-then-retry counted'
    $none = @(
        (New-Att -TaskId 'T-15' -AttemptId '15-1' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-15' -AttemptId '15-2' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    Assert-Equal (@(Get-View -Records $none -Query (Get-Query)).TaskRows)[0].CorrectionsCount 0 'S15: plain retry is not a correction'
}

# S16 escalations count (chain.EscalationEvents, DB-M20)
function Test-S16-EscalationsCount {
    $recs, $fp = Get-BriefRecords
    Assert-Equal (@(Get-View -Records $recs -Query (Get-Query)).TaskRows)[0].EscalationsCount 3 'S16: brief chain has 3 retry markers'
    $explicit = @(
        (New-Att -TaskId 'T-16' -AttemptId '16-1' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-16' -AttemptId '16-2' -RetryNumber 1 -EscalatedFromAttemptId '16-1' -EscalationReason 'PROVIDER_AVAILABILITY_ROUTE_SWITCH' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 2)
    )
    Assert-Equal (@(Get-View -Records $explicit -Query (Get-Query)).TaskRows)[0].EscalationsCount 1 'S16: explicit escalation marker counted once'
}

# S17 failure count (FAILED/CANCELLED + verification-failed records)
function Test-S17-FailureCount {
    $recs, $fp = Get-BriefRecords
    Assert-Equal (@(Get-View -Records $recs -Query (Get-Query)).TaskRows)[0].FailureCount 2 'S17: two failed attempts'
    $vf = @(New-Att -TaskId 'T-17' -AttemptId '17-1' -Result 'SUCCESS' -VerificationResult 'FAILED' -ActualCost 1)
    Assert-Equal (@(Get-View -Records $vf -Query (Get-Query)).TaskRows)[0].FailureCount 1 'S17: verification-failed counted as failure'
    $budget = @(New-Att -TaskId 'T-17' -AttemptId '17-2' -Result 'BUDGET_STOPPED')
    Assert-Equal (@(Get-View -Records $budget -Query (Get-Query)).TaskRows)[0].FailureCount 0 'S17: budget stop is a governance state, not a failure'
}

# S18 mode (ExecutionMode fallback TaskType)
function Test-S18-Mode {
    $recs, $fp = Get-BriefRecords
    Assert-Equal (@(Get-View -Records $recs -Query (Get-Query)).TaskRows)[0].Mode 'ASSISTED' 'S18: ExecutionMode used'
    $fallback = @(New-Att -TaskId 'T-18' -AttemptId '18-1' -ExecutionMode '' -TaskType 'IMPLEMENTATION' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    Assert-Equal (@(Get-View -Records $fallback -Query (Get-Query)).TaskRows)[0].Mode 'IMPLEMENTATION' 'S18: TaskType fallback when ExecutionMode absent'
}

# S19 timeline ordering (ordered by RetryNumber then AttemptId, DB-M20 chain)
function Test-S19-TimelineOrdering {
    $out = @(
        (New-Att -TaskId 'T-19' -AttemptId 'A-30' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 3),
        (New-Att -TaskId 'T-19' -AttemptId 'A-20' -RetryNumber 1 -Result 'FAILED' -ActualCost 2),
        (New-Att -TaskId 'T-19' -AttemptId 'A-10' -RetryNumber 0 -Result 'FAILED' -ActualCost 1)
    )
    $row = @(Get-View -Records $out -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[0].AttemptId 'A-10' 'S19: retry 0 first'
    Assert-Equal $row.Timeline[1].AttemptId 'A-20' 'S19: retry 1 second'
    Assert-Equal $row.Timeline[2].AttemptId 'A-30' 'S19: retry 2 third'
    $stable = @(
        (New-Att -TaskId 'T-19' -AttemptId 'A-22' -RetryNumber 1 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-19' -AttemptId 'A-11' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1),
        (New-Att -TaskId 'T-19' -AttemptId 'A-21' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    $row2 = @(Get-View -Records $stable -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row2.Timeline[0].AttemptId 'A-11' 'S19: retry 0 first (stable)'
    Assert-Equal $row2.Timeline[1].AttemptId 'A-21' 'S19: same retry ordered by AttemptId'
    Assert-Equal $row2.Timeline[2].AttemptId 'A-22' 'S19: later retry after stable group'
}

# S20 timeline node fields (all node fields carried from the record)
function Test-S20-TimelineNodeFields {
    $recs, $fp = Get-BriefRecords
    $row = @(Get-View -Records $recs -Query (Get-Query)).TaskRows[0]
    $n = $row.Timeline[0]
    Assert-Equal $n.Seq 1 'S20: sequence'
    Assert-Equal $n.AttemptId 'ATT-BRIEF-1' 'S20: attempt id'
    Assert-Equal $n.RetryNumber 0 'S20: retry number'
    Assert-Equal $n.ProviderId 'deepseek' 'S20: provider'
    Assert-Equal $n.ModelId 'deepseek-v4-flash' 'S20: model'
    Assert-Equal $n.ReasoningLevel 'MEDIUM' 'S20: reasoning level'
    Assert-Equal $n.Result 'FAILED' 'S20: result'
    Assert-Equal $n.FailureCategory 'MODEL_QUALITY' 'S20: failure category'
    Assert-Equal $n.VerificationResult '' 'S20: verification result (none)'
    Assert-Near $n.ActualCost 1.25 -Message 'S20: actual cost'
    Assert-Near $n.EstimatedCost 1.25 -Message 'S20: estimated cost'
    Assert-Equal $n.CostSource 'ACTUAL' 'S20: cost source'
    Assert-Near $n.CostAmount 1.25 -Message 'S20: cost amount'
    Assert-Equal $n.DurationMs 20000 'S20: duration ms'
    Assert-Equal $n.InputTokens 4000 'S20: input tokens'
    Assert-Equal $n.OutputTokens 1200 'S20: output tokens'
    Assert-Equal $n.TimestampUtc '2026-08-31T10:00:00Z' 'S20: timestamp'
    Assert-True (-not $n.IsTerminal) 'S20: first node not terminal'
    Assert-Equal $n.TerminalMarker '' 'S20: first node has no terminal marker'
}

# S21 per-attempt cost (actual preferred; estimated labelled under fallback)
function Test-S21-PerAttemptCost {
    $recs, $fp = Get-BriefRecords
    $row = @(Get-View -Records $recs -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[1].CostSource 'ACTUAL' 'S21: actual preferred over estimated'
    Assert-Near $row.Timeline[1].CostAmount 2.0 -Message 'S21: node cost actual value'
    $est = @(
        (New-Att -TaskId 'T-21' -AttemptId '21-1' -Result 'FAILED' -EstimatedCost 3 -ActualCost $null),
        (New-Att -TaskId 'T-21' -AttemptId '21-2' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -EstimatedCost 4 -ActualCost $null)
    )
    $row2 = @(Get-View -Records $est -Query (Get-Query -AllowEstimatedCostFallback $true)).TaskRows[0]
    Assert-Equal $row2.Timeline[0].CostSource 'ESTIMATED' 'S21: estimated only under fallback'
    Assert-Near $row2.Timeline[0].CostAmount 3.0 -Message 'S21: estimated value used'
}

# S22 cumulative cost (running sum across the chain)
function Test-S22-CumulativeCost {
    $recs, $fp = Get-BriefRecords
    $row = @(Get-View -Records $recs -Query (Get-Query)).TaskRows[0]
    Assert-Near $row.Timeline[0].CumulativeCost 1.25 -Message 'S22: cumulative after 1'
    Assert-Near $row.Timeline[1].CumulativeCost 3.25 -Message 'S22: cumulative after 2'
    Assert-Near $row.Timeline[2].CumulativeCost 6.25 -Message 'S22: cumulative after 3'
    Assert-Near $row.Timeline[3].CumulativeCost 7.25 -Message 'S22: cumulative after 4 = total actual'
}

# S23 first transition START
function Test-S23-FirstTransitionStart {
    $recs, $fp = Get-BriefRecords
    $row = @(Get-View -Records $recs -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[0].Transition.Type 'START' 'S23: first node transition is START'
    Assert-Null $row.Timeline[0].Transition.FromAttemptId 'S23: START has no from-attempt'
    Assert-Equal $row.Timeline[0].Transition.ToAttemptId 'ATT-BRIEF-1' 'S23: START points at the first attempt'
}

# S24 plain retry (same provider/model/reasoning -> RETRY)
function Test-S24-PlainRetry {
    $pr = @(
        (New-Att -TaskId 'T-24' -AttemptId '24-1' -RetryNumber 0 -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -ReasoningLevel 'MEDIUM' -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-24' -AttemptId '24-2' -RetryNumber 1 -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -ReasoningLevel 'MEDIUM' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    $row = @(Get-View -Records $pr -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[1].Transition.Type 'RETRY' 'S24: plain retry'
    Assert-In ([string]$row.Timeline[1].Transition.ReasonCodes[0]) @(Get-DbM20ReasonCodes) 'S24: retry reason code is DB-M20 vocabulary'
}

# S25 reasoning escalation (same model higher reasoning -> RETRY_SAME_MODEL_HIGHER_REASONING)
function Test-S25-ReasoningEscalation {
    $re = @(
        (New-Att -TaskId 'T-25' -AttemptId '25-1' -RetryNumber 0 -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -ReasoningLevel 'MEDIUM' -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-25' -AttemptId '25-2' -RetryNumber 1 -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -ReasoningLevel 'HIGH' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    $row = @(Get-View -Records $re -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[1].Transition.Type 'RETRY_SAME_MODEL_HIGHER_REASONING' 'S25: reasoning escalation'
    Assert-Contains ($row.Timeline[1].Transition.ReasonCodes -join ',') 'REASONING_ESCALATION' 'S25: reasoning code'
}

# S26 model switch (model changed same provider -> SWITCH_MODEL)
function Test-S26-ModelSwitch {
    $ms = @(
        (New-Att -TaskId 'T-26' -AttemptId '26-1' -RetryNumber 0 -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -ReasoningLevel 'MEDIUM' -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-26' -AttemptId '26-2' -RetryNumber 1 -ProviderId 'deepseek' -ModelId 'deepseek-r1' -ReasoningLevel 'MEDIUM' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    $row = @(Get-View -Records $ms -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[1].Transition.Type 'SWITCH_MODEL' 'S26: model switch'
    Assert-Contains ($row.Timeline[1].Transition.ReasonCodes -join ',') 'MODEL_ESCALATION' 'S26: model escalation code'
}

# S27 provider switch (provider changed -> SWITCH_PROVIDER_ROUTE)
function Test-S27-ProviderSwitch {
    $ps = @(
        (New-Att -TaskId 'T-27' -AttemptId '27-1' -RetryNumber 0 -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -ReasoningLevel 'MEDIUM' -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-27' -AttemptId '27-2' -RetryNumber 1 -ProviderId 'claude' -ModelId 'claude-sonnet-5' -ReasoningLevel 'MEDIUM' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    $row = @(Get-View -Records $ps -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[1].Transition.Type 'SWITCH_PROVIDER_ROUTE' 'S27: provider switch'
    Assert-In ([string]$row.Timeline[1].Transition.ReasonCodes[0]) @(Get-DbM20ReasonCodes) 'S27: provider-switch code is DB-M20 vocabulary'
}

# S28 rebuild context (REBUILD_CONTEXT decision -> REBUILD_CONTEXT transition)
function Test-S28-RebuildContext {
    $d = New-Dec @{ DecisionId = 'DEC-RC'; TaskId = 'T-28'; AttemptId = '28-2'; Action = 'REBUILD_CONTEXT'; ReasonCodes = @('CONTEXT_TOO_LARGE_REBUILD'); Status = 'RECOMMENDED' }
    $rc = @(
        (New-Att -TaskId 'T-28' -AttemptId '28-1' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-28' -AttemptId '28-2' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    $row = @(Get-View -Records $rc -Query (Get-Query) -EscalationDecisions @($d)).TaskRows[0]
    Assert-Equal $row.Timeline[1].Transition.Type 'REBUILD_CONTEXT' 'S28: rebuild-context transition'
}

# S29 correction (CORRECT_CURRENT_ATTEMPT decision / ParentAttemptId -> CORRECTION)
function Test-S29-Correction {
    $d = New-Dec @{ DecisionId = 'DEC-CORR'; TaskId = 'T-29'; AttemptId = '29-2'; Action = 'CORRECT_CURRENT_ATTEMPT'; ReasonCodes = @('CORRECT_CURRENT_ATTEMPT'); Status = 'RECOMMENDED' }
    $corr = @(
        (New-Att -TaskId 'T-29' -AttemptId '29-1' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-29' -AttemptId '29-2' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    $row = @(Get-View -Records $corr -Query (Get-Query) -EscalationDecisions @($d)).TaskRows[0]
    Assert-Equal $row.Timeline[1].Transition.Type 'CORRECTION' 'S29: decision-driven correction'
    $parent = @(
        (New-Att -TaskId 'T-29' -AttemptId '29-3' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-29' -AttemptId '29-4' -ParentAttemptId '29-3' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    $row2 = @(Get-View -Records $parent -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row2.Timeline[1].Transition.Type 'CORRECTION' 'S29: ParentAttemptId correction'
}

# S30 Claude review fix (prev FIX_REQUIRED -> CORRECTION_CLAUDE_REVIEW_FIX, reason CLAUDE_REVIEW_FIX)
function Test-S30-ClaudeReviewFix {
    $recs, $fp = Get-BriefRecords
    $row = @(Get-View -Records $recs -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[3].Transition.Type 'CORRECTION_CLAUDE_REVIEW_FIX' 'S30: FIX_REQUIRED predecessor -> review-fix correction'
    Assert-Contains ($row.Timeline[3].Transition.ReasonCodes -join ',') 'CLAUDE_REVIEW_FIX' 'S30: CLAUDE_REVIEW_FIX reason'
    Assert-Equal $row.Timeline[3].Transition.Action 'CORRECT_CURRENT_ATTEMPT' 'S30: correction action'
}

# S31 escalation decision carried (DecisionId + Action + ReasonCodes + RequiresHuman on the transition)
function Test-S31-EscalationDecisionCarried {
    $d = New-Dec @{ DecisionId = 'DEC-31'; TaskId = 'T-31'; AttemptId = '31-2'; Action = 'SWITCH_MODEL'; ReasonCodes = @('MODEL_ESCALATION', 'MAX_MODEL_ESCALATIONS'); Explanation = 'Model route exhausted; switching.'; RequiresHuman = $false; Status = 'RECOMMENDED' }
    $ch = @(
        (New-Att -TaskId 'T-31' -AttemptId '31-1' -RetryNumber 0 -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-31' -AttemptId '31-2' -RetryNumber 1 -ProviderId 'deepseek' -ModelId 'deepseek-r1' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    $row = @(Get-View -Records $ch -Query (Get-Query) -EscalationDecisions @($d)).TaskRows[0]
    $t = $row.Timeline[1].Transition
    Assert-Equal $t.DecisionId 'DEC-31' 'S31: decision id carried'
    Assert-Equal $t.Type 'SWITCH_MODEL' 'S31: decision action drives type'
    Assert-Equal $t.Action 'SWITCH_MODEL' 'S31: decision action carried'
    Assert-Contains ($t.ReasonCodes -join ',') 'MODEL_ESCALATION' 'S31: decision reason codes carried'
    Assert-Contains ($t.ReasonCodes -join ',') 'MAX_MODEL_ESCALATIONS' 'S31: both reason codes carried'
    Assert-Equal $t.RequiresHuman $false 'S31: requires-human carried'
    Assert-Equal $t.Explanation 'Model route exhausted; switching.' 'S31: decision explanation carried'
    # RequiresHuman=true variant
    $dh = New-Dec @{ DecisionId = 'DEC-31H'; TaskId = 'T-31'; AttemptId = '31-3'; Action = 'HUMAN_REVIEW_REQUIRED'; ReasonCodes = @('VERIFICATION_FAILED'); RequiresHuman = $true; HumanActionType = 'REVIEW_FIX'; Status = 'HUMAN_REVIEW_REQUIRED' }
    $ch2 = @(
        (New-Att -TaskId 'T-31' -AttemptId '31-1' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-31' -AttemptId '31-3' -RetryNumber 1 -Result 'FAILED' -ActualCost 1)
    )
    $row2 = @(Get-View -Records $ch2 -Query (Get-Query) -EscalationDecisions @($dh)).TaskRows[0]
    Assert-Equal $row2.Timeline[1].Transition.RequiresHuman $true 'S31: requires-human true variant'
    Assert-Equal $row2.Timeline[1].Transition.HumanActionType 'REVIEW_FIX' 'S31: human action type carried'
}

# S32 budget stop terminal (Result=BUDGET_STOPPED -> BUDGET_STOP marker)
function Test-S32-BudgetStopTerminal {
    $bs = @(
        (New-Att -TaskId 'T-32' -AttemptId '32-1' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-32' -AttemptId '32-2' -RetryNumber 1 -Result 'BUDGET_STOPPED')
    )
    $row = @(Get-View -Records $bs -Query (Get-Query)).TaskRows[0]
    $n = $row.Timeline[1]
    Assert-True $n.IsTerminal 'S32: budget-stop node is terminal'
    Assert-Equal $n.TerminalMarker 'BUDGET_STOP' 'S32: budget-stop marker'
    Assert-In 'BUDGET_STOP' @(Get-DbM29TransitionTypes) 'S32: marker in transition vocabulary'
    Assert-Equal $row.VerifiedState 'INCOMPLETE' 'S32: budget stop is not verified success'
}

# S33 human review terminal (WAITING_HUMAN / RequiresHuman -> HUMAN_REVIEW)
function Test-S33-HumanReviewTerminal {
    $wh = @(
        (New-Att -TaskId 'T-33' -AttemptId '33-1' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-33' -AttemptId '33-2' -RetryNumber 1 -Result 'WAITING_HUMAN')
    )
    $row = @(Get-View -Records $wh -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[1].TerminalMarker 'HUMAN_REVIEW' 'S33: WAITING_HUMAN marker'
    $dh = New-Dec @{ DecisionId = 'DEC-33H'; TaskId = 'T-33'; AttemptId = '33-4'; Action = 'HUMAN_REVIEW_REQUIRED'; ReasonCodes = @('VERIFICATION_FAILED'); RequiresHuman = $true; Status = 'HUMAN_REVIEW_REQUIRED' }
    $hr = @(
        (New-Att -TaskId 'T-33' -AttemptId '33-3' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-33' -AttemptId '33-4' -RetryNumber 1 -Result 'FAILED' -ActualCost 1)
    )
    $row2 = @(Get-View -Records $hr -Query (Get-Query) -EscalationDecisions @($dh)).TaskRows[0]
    Assert-Equal $row2.Timeline[1].TerminalMarker 'HUMAN_REVIEW' 'S33: RequiresHuman decision marker'
}

# S34 governance stop terminal (STOP_GOVERNANCE / GOVERNANCE_BLOCKED -> GOVERNANCE_STOP)
function Test-S34-GovernanceStopTerminal {
    $dg = New-Dec @{ DecisionId = 'DEC-34G'; TaskId = 'T-34'; AttemptId = '34-2'; Action = 'STOP_GOVERNANCE'; ReasonCodes = @('GOVERNANCE_BLOCKED'); Explanation = 'Governance block.'; Status = 'STOP_GOVERNANCE' }
    $gs = @(
        (New-Att -TaskId 'T-34' -AttemptId '34-1' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-34' -AttemptId '34-2' -RetryNumber 1 -Result 'FAILED' -ActualCost 1)
    )
    $row = @(Get-View -Records $gs -Query (Get-Query) -EscalationDecisions @($dg)).TaskRows[0]
    Assert-Equal $row.Timeline[1].TerminalMarker 'GOVERNANCE_STOP' 'S34: governance-stop marker'
    Assert-In 'GOVERNANCE_STOP' @(Get-DbM29TransitionTypes) 'S34: marker in transition vocabulary'
}

# S35 verified-success terminal (terminal VERIFIED -> VERIFIED_SUCCESS highlighted)
function Test-S35-VerifiedSuccessTerminal {
    $recs, $fp = Get-BriefRecords
    $row = @(Get-View -Records $recs -Query (Get-Query)).TaskRows[0]
    $n = $row.Timeline[3]
    Assert-True $n.IsTerminal 'S35: verified node is terminal'
    Assert-Equal $n.TerminalMarker 'VERIFIED_SUCCESS' 'S35: verified-success marker'
    Assert-Equal $n.VerifiedState 'VERIFIED_SUCCESS' 'S35: node verified state'
}

# S36 failed-no-retry terminal (failed chain end -> FAILED_NO_RETRY)
function Test-S36-FailedNoRetryTerminal {
    $single = @(New-Att -TaskId 'T-36' -AttemptId '36-1' -RetryNumber 0 -Result 'FAILED' -ActualCost 1)
    $row = @(Get-View -Records $single -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[0].TerminalMarker 'FAILED_NO_RETRY' 'S36: single failed attempt marker'
    $chain = @(
        (New-Att -TaskId 'T-36' -AttemptId '36-2' -RetryNumber 0 -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-36' -AttemptId '36-3' -RetryNumber 1 -Result 'FAILED' -ActualCost 1)
    )
    $row2 = @(Get-View -Records $chain -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row2.Timeline[1].TerminalMarker 'FAILED_NO_RETRY' 'S36: failed chain end marker'
}

# S37 failure category display (DB-M17/DB-M20 vocab category per failed node)
function Test-S37-FailureCategoryDisplay {
    $recs, $fp = Get-BriefRecords
    $row = @(Get-View -Records $recs -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.Timeline[0].FailureCategory 'MODEL_QUALITY' 'S37: node failure category 1'
    Assert-Equal $row.Timeline[1].FailureCategory 'VERIFICATION_FAILURE' 'S37: node failure category 2'
    # the recorded category is carried verbatim and must be a DB-M17/DB-M20 vocab member
    Assert-In $row.Timeline[0].FailureCategory $script:FailureVocab 'S37: category 1 in DB-M17/DB-M20 vocabulary'
    Assert-In $row.Timeline[1].FailureCategory $script:FailureVocab 'S37: category 2 in DB-M17/DB-M20 vocabulary'
    $html = ConvertTo-DbM29Html -View (Get-View -Records $recs -Query (Get-Query))
    Assert-Contains $html 'VERIFICATION_FAILURE' 'S37: category rendered in HTML'
}

# S38 failure fingerprint display (FailureFingerprintId + signature prefix + recurrence)
function Test-S38-FailureFingerprintDisplay {
    $recs, $fp = Get-BriefRecords
    $view = Get-View -Records $recs -Query (Get-Query) -Fingerprints @($fp)
    $row = @($view.TaskRows)[0]
    $n = $row.Timeline[0]
    Assert-Equal $n.FailureFingerprintId $fp.FingerprintId 'S38: node fingerprint id'
    Assert-NotNull $n.FailureFingerprint 'S38: fingerprint object attached'
    Assert-Equal $n.FailureFingerprint.FingerprintId $fp.FingerprintId 'S38: attached fingerprint id matches'
    Assert-True ($fp.Signature.Length -gt 16) 'S38: signature present'
    $html = ConvertTo-DbM29Html -View $view
    Assert-Contains $html $fp.Signature.Substring(0, 12) 'S38: signature prefix rendered'
    Assert-Contains $html '3' 'S38: occurrence count context rendered'
}

# S39 provider failure evidence (optional ProviderHealthEvidence note, never a health-write)
function Test-S39-ProviderFailureEvidence {
    $recs, $fp = Get-BriefRecords
    $health = New-Health -ProviderId 'deepseek' -AttemptIdReference 'ATT-BRIEF-1' -RetryAfterUtc '2026-08-31T12:00:00Z'
    $row = @(Get-View -Records $recs -Query (Get-Query) -ProviderHealth @($health)).TaskRows[0]
    $warn = $row.Timeline[0].Warnings -join ' | '
    Assert-Contains $warn 'Provider failure evidence: UNAVAILABLE' 'S39: health note attached'
    Assert-Contains $warn 'retry after' 'S39: retry-after carried'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Set-ProviderHealth' "S39: no health write ($rel)"
        Assert-NotContains $text 'Update-ProviderCircuitState' "S39: no circuit write ($rel)"
    }
}

# S40 route identity preserved (UnderlyingModelId + GatewayProviderId never collapsed)
function Test-S40-RouteIdentityPreserved {
    $recs, $fp = Get-BriefRecords
    $row = @(Get-View -Records $recs -Query (Get-Query)).TaskRows[0]
    Assert-Equal $row.FinalUnderlyingModelId 'claude-sonnet-5' 'S40: underlying model preserved'
    Assert-Equal $row.FinalGatewayProviderId 'openrouter' 'S40: gateway provider preserved'
    Assert-Equal $row.Timeline[2].UnderlyingModelId 'claude-sonnet-5' 'S40: node underlying model'
    Assert-Equal $row.Timeline[2].GatewayProviderId 'openrouter' 'S40: node gateway provider'
}

# S41 task filtering (TaskId / ProviderId / ModelId filters narrow the rows)
function Test-S41-TaskFiltering {
    $multi = @(
        (New-Att -TaskId 'T-A' -AttemptId 'A-1' -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1),
        (New-Att -TaskId 'T-B' -AttemptId 'B-1' -ProviderId 'claude' -ModelId 'claude-sonnet-5' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1),
        (New-Att -TaskId 'T-C' -AttemptId 'C-1' -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -Result 'FAILED' -ActualCost 1),
        (New-Att -TaskId 'T-C' -AttemptId 'C-2' -RetryNumber 1 -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1)
    )
    $all = Get-View -Records $multi -Query (Get-Query)
    Assert-Equal $all.Count 3 'S41: three tasks unfiltered'
    $tA = Get-View -Records $multi -Query (Get-Query -TaskId 'T-A')
    Assert-Equal $tA.Count 1 'S41: TaskId filter -> 1 row'
    Assert-Equal (@($tA.TaskRows)[0].TaskId) 'T-A' 'S41: TaskId filter matches'
    $prov = Get-View -Records $multi -Query (Get-Query -ProviderId 'deepseek')
    Assert-Equal $prov.Count 2 'S41: ProviderId filter -> 2 tasks'
    $mdl = Get-View -Records $multi -Query (Get-Query -ModelId 'claude-sonnet-5')
    Assert-Equal $mdl.Count 1 'S41: ModelId filter -> 1 task'
}

# S42 sorting (SortBy TASK_ID / TOTAL_COST / ATTEMPT_COUNT)
function Test-S42-Sorting {
    $multi = @(
        (New-Att -TaskId 'T-Z' -AttemptId 'Z-1' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 1),
        (New-Att -TaskId 'T-A' -AttemptId 'A-1' -Result 'FAILED' -ActualCost 5),
        (New-Att -TaskId 'T-A' -AttemptId 'A-2' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 5),
        (New-Att -TaskId 'T-M' -AttemptId 'M-1' -Result 'FAILED' -ActualCost 2),
        (New-Att -TaskId 'T-M' -AttemptId 'M-2' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 2),
        (New-Att -TaskId 'T-M' -AttemptId 'M-3' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 2)
    )
    $byId = Get-View -Records $multi -Query (Get-Query -SortBy 'TASK_ID' -SortDirection 'ASCENDING')
    Assert-Equal (@($byId.TaskRows)[0].TaskId) 'T-A' 'S42: TASK_ID asc first'
    Assert-Equal (@($byId.TaskRows)[2].TaskId) 'T-Z' 'S42: TASK_ID asc last'
    $byCost = Get-View -Records $multi -Query (Get-Query -SortBy 'TOTAL_COST' -SortDirection 'DESCENDING')
    Assert-Equal (@($byCost.TaskRows)[0].TaskId) 'T-A' 'S42: highest cost first'
    Assert-Near (@($byCost.TaskRows)[0].TotalActualCost) 10.0 -Message 'S42: T-A total cost 5+5'
    $byCount = Get-View -Records $multi -Query (Get-Query -SortBy 'ATTEMPT_COUNT' -SortDirection 'DESCENDING')
    Assert-Equal (@($byCount.TaskRows)[0].TaskId) 'T-M' 'S42: most attempts first'
}

# S43 cost authority (engine never re-implements a cost formula)
function Test-S43-CostAuthority {
    $view = Get-View -Records @() -Query (Get-Query)
    $libText = ''
    foreach ($rel in $script:LibraryFiles) { $libText += (Get-Content (Join-Path $script:Root $rel) -Raw) }
    Assert-Contains $libText 'Resolve-DbM25RecordCost' 'S43: library delegates to DB-M25 cost resolution'
    Assert-NotContains $libText 'Calculate-AiAttemptCost' 'S43: never re-implements the cost formula'
    Assert-NotContains $libText 'InputPricePerMillion' 'S43: never reads raw pricing math'
    Assert-NotContains $libText 'PricePerMillion' 'S43: no raw price token'
}

# S44 no second attempt-history database (no write token; store READ-ONLY)
function Test-S44-NoSecondAttemptHistoryDb {
    $engineText = ''
    foreach ($rel in @('ai-routing\task-history\HistoryEngine.ps1', 'ai-routing\task-history\HistoryContracts.ps1')) {
        $engineText += (Get-Content (Join-Path $script:Root $rel) -Raw)
    }
    Assert-NotContains $engineText 'WriteAllText' 'S44: engine never writes'
    Assert-NotContains $engineText 'Set-Content' 'S44: engine never writes content'
    Assert-NotContains $engineText 'New-AiAttemptRecord' 'S44: engine never constructs attempt records'
    Assert-NotContains $engineText 'Save-AiAttemptRecord' 'S44: no record save'
    Assert-NotContains $engineText 'Save-AiAttemptHistory' 'S44: no history save'
    Assert-NotContains $engineText 'Sync-AiAttemptStateIndex' 'S44: no state index write'
    Assert-NotContains $engineText 'Start-AiAttempt' 'S44: no attempt start'
    Assert-NotContains $engineText 'Set-AiAttempt' 'S44: no attempt setter'
    Assert-NotContains $engineText 'New-AiAttemptId' 'S44: no attempt id minting'
    $renderText = Get-Content (Join-Path $script:Root 'ai-routing\task-history\HistoryRender.ps1') -Raw
    # count only actual write CALLS (the header comment mentions WriteAllText too)
    $writeCount = ([regex]::Matches($renderText, '::WriteAllText\(')).Count
    Assert-Equal $writeCount 1 'S44: the ONLY write in the library is the single artifact export'
    Assert-NotContains $renderText 'Set-Content' 'S44: renderer never writes content'
    Assert-NotContains $renderText 'Save-AiAttemptRecord' 'S44: renderer never writes records'
}

# S45 secrets never rendered (HTML passes the leak guard; env-var NAMES only)
function Test-S45-SecretsNeverRendered {
    $recs, $fp = Get-BriefRecords
    $view = Get-View -Records $recs -Query (Get-Query)
    $html = ConvertTo-DbM29Html -View $view
    $lv = Test-DbM29SecretLeak $html
    Assert-True (-not $lv.Leak) 'S45: rendered HTML has no secret-like value'
    Assert-Contains $html 'Secret values displayed: NO' 'S45: no-secret marker'
    Assert-NotContains $html 'api[_-]?key' 'S45: no key literal'
}

# S46 secrets never logged (view JSON passes the leak guard; no secret write path)
function Test-S46-SecretsNeverLogged {
    $recs, $fp = Get-BriefRecords
    $view = Get-View -Records $recs -Query (Get-Query)
    $json = ConvertTo-Json -InputObject $view -Depth 12
    $lv = Test-DbM29SecretLeak $json
    Assert-True (-not $lv.Leak) 'S46: view JSON has no secret-like value'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Add-Member.*Secret' "S46: no secret materialization ($rel)"
    }
}

# S47 no AI execution (AUTO_EXECUTION_ENABLED = FALSE)
function Test-S47-NoAiExecution {
    $view = Get-View -Records @() -Query (Get-Query)
    Assert-Equal $view.ReadOnlyGuard.AutoExecutionEnabled $false 'S47: auto execution disabled'
    Assert-Equal $view.ReadOnlyGuard.PaidApiCalls 0 'S47: zero paid calls in guard'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Invoke-Provider' "S47: no provider invoke ($rel)"
        Assert-NotContains $text 'Send-ProviderRequest' "S47: no provider send ($rel)"
        Assert-NotContains $text 'Invoke-AiModel' "S47: no model invoke ($rel)"
    }
}

# S48 paid API calls = 0
function Test-S48-PaidCallsZero {
    $view = Get-View -Records @() -Query (Get-Query)
    Assert-Equal $view.ReadOnlyGuard.PaidApiCalls 0 'S48: guard paid calls zero'
    Assert-Equal $view.ReadOnlyGuard.NetworkCalls 0 'S48: guard network calls zero'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Invoke-WebRequest' "S48: no web request ($rel)"
        Assert-NotContains $text 'Invoke-RestMethod' "S48: no rest call ($rel)"
        Assert-NotContains $text 'HttpClient' "S48: no http client ($rel)"
    }
}

# S49 network calls = 0
function Test-S49-NetworkZero {
    $view = Get-View -Records @() -Query (Get-Query)
    Assert-Equal $view.ReadOnlyGuard.NetworkCalls 0 'S49: guard network zero'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'System.Net.WebClient' "S49: no webclient ($rel)"
        Assert-NotContains $text 'Start-Process' "S49: no process spawn ($rel)"
        Assert-NotContains $text 'Invoke-Expression' "S49: no dynamic invocation ($rel)"
    }
}

# S50 escalation store untouched (no decision write token)
function Test-S50-EscalationStoreUntouched {
    $view = Get-View -Records @() -Query (Get-Query)
    Assert-Equal $view.ReadOnlyGuard.EscalationDecisionsModified 'NO' 'S50: escalation decisions unmodified'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'New-EscalationDecision' "S50: no decision creation ($rel)"
        Assert-NotContains $text 'Export-AiEscalationDecision' "S50: no decision export ($rel)"
        Assert-NotContains $text 'Save-AiEscalationDecision' "S50: no decision save ($rel)"
    }
}

# S51 budget untouched (no budget write; budget evidence display-only)
function Test-S51-BudgetUntouched {
    $view = Get-View -Records @() -Query (Get-Query)
    Assert-Equal $view.ReadOnlyGuard.BudgetPolicyModified 'NO' 'S51: budget policy unmodified'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Test-AiBudgetOverride' "S51: no budget override ($rel)"
        Assert-NotContains $text 'Set-AiBudgetLimit' "S51: no budget limit write ($rel)"
        Assert-NotContains $text 'New-AiBudgetDecision' "S51: no budget decision ($rel)"
    }
}

# S52 canonical workbook unchanged (byte-identical, no governance mutation)
function Test-S52-WorkbookUnchanged {
    Assert-NotNull $script:WorkbookShaBefore 'S52: workbook reachable for verification'
    $now = Get-Sha256 $script:WorkbookPath
    Assert-True ($now -eq $script:WorkbookShaBefore) 'S52: canonical Nexus workbook byte-identical'
    # The recorded post-DB-M12.4 hash pins a MOMENT in the governed workbook's life.
    # Governed work legitimately advances it (the 2026-09-05 transition to M-12-0.4 moved
    # the authoritative workbook 6D42C3BF -> 8AA73778), so a superseded hash is recorded
    # as environment drift rather than failed here -- the same disposition DB-M30 D30
    # already applies to this pin. What must never drift is the invariant asserted above:
    # this suite does not modify the authoritative workbook.
    if ($now -notmatch '6D42C3BF') {
        $nowLabel = if ($now) { ([string]$now).Substring(0, 8) } else { '<unreadable>' }
        $script:ExternalDrift.Add('S52 workbook-authority drift (suite records 6D42C3BF post-DB-M12.4; live authoritative workbook is ' + $nowLabel + ')')
    }
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'NEXUS_DEVELOPMENT_CONTROL.xlsx' "S52: no workbook path in library ($rel)"
        Assert-NotContains $text 'PreDevBridgeBaseline' "S52: no Nexus baseline mutation ($rel)"
    }
}

# S53 Lane C UI unchanged (byte-identical)
function Test-S53-LaneCUiUnchanged {
    if (-not $script:ForgeRoot) {
        $script:HostSkips.Add('S53 M12.x console byte-identity: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT); the console stayed in Forge at W6/LaneA')
        return
    }
    Assert-True ($script:UiFiles.Count -gt 0) 'S53: M12.x UI source files enumerated'
    foreach ($f in $script:UiFiles) {
        $now = Get-Sha256 $f.FullName
        Assert-True ($now -eq $script:UiShaBefore[$f.FullName]) "S53: M12.x UI file unchanged: $($f.Name)"
    }
}

# S54 solution build 0 errors
function Test-S54-Build {
    if (-not $script:ForgeRoot) {
        $script:HostSkips.Add('S54 Forge solution build: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT); the solution stayed in Forge at W6/LaneA')
        return
    }
    $sln = Join-Path $script:ForgeRoot 'src\DevBridge.slnx'
    Assert-True (Test-Path $sln) 'S54: solution present'
    if (-not (Test-Path $sln)) { return }
    $log = Join-Path $env:TEMP 'db29-build.log'
    & dotnet build $sln --nologo > $log 2>&1
    $exit = $LASTEXITCODE
    $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
    Assert-True ($exit -eq 0) "S54: dotnet build exit 0 (got $exit)"
    $errTokens = ([regex]::Matches($text, 'error\s+CS\d+')).Count
    Assert-True ($errTokens -eq 0) "S54: build has 0 error CS tokens (got $errTokens)"
    Assert-Contains $text '0 Error' 'S54: build summary shows 0 errors'
}

# S55 frozen files re-verification (DB-M14..M28 owned + DB-M29 library + live config unchanged)
function Test-S55-FrozenFilesUnchanged {
    foreach ($rel in $script:FrozenFiles) {
        Assert-NotNull $script:ShaBefore[$rel] "S55: frozen file reachable: $rel"
        $after = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($after -eq $script:ShaBefore[$rel]) "S55: frozen file unchanged: $rel"
    }
    foreach ($rel in $script:FixtureFiles) {
        Assert-NotNull $script:ShaBefore[$rel] "S55: DB-M29 library reachable: $rel"
        $after = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($after -eq $script:ShaBefore[$rel]) "S55: DB-M29 library file unchanged: $rel"
    }
    foreach ($rel in $script:ConfigFiles) {
        Assert-NotNull $script:CfgShaBefore[$rel] "S55: live config reachable: $rel"
        $after = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($after -eq $script:CfgShaBefore[$rel]) "S55: live config unchanged: $rel"
    }
    # The DB-M18.1 lineage implementation is Forge development-lifecycle logic and
    # stayed in Forge. The no-mutation guard travels with it to the DECLARED host
    # root, so the protection survives the move instead of being dropped.
    if ($script:ForgeFrozenBefore) {
        foreach ($rel in $script:ForgeFrozenFiles) {
            $after = Get-Sha256 (Join-Path $script:ForgeRoot $rel)
            Assert-True ($after -eq $script:ShaBefore[$rel]) "S55: Forge DB-M18.1 file unchanged: $rel"
        }
    }
}

# --- scenario registry + runner -----------------------------------------------------------

$script:Scenarios = @(
    'Test-S1-UiOpens', 'Test-S2-TaskListRenders', 'Test-S3-EmptyStoreHonesty',
    'Test-S4-TaskRowFields', 'Test-S5-AttemptCount', 'Test-S6-TotalActualCost',
    'Test-S7-TotalEstimatedCost', 'Test-S8-VerifiedSuccessState', 'Test-S9-ContradictedSuccess',
    'Test-S10-ModelReturned', 'Test-S11-FirstAttemptSuccessYes', 'Test-S12-FirstAttemptSuccessNo',
    'Test-S13-FirstAttemptUnknown', 'Test-S14-FinalModelProvider', 'Test-S15-CorrectionsCount',
    'Test-S16-EscalationsCount', 'Test-S17-FailureCount', 'Test-S18-Mode',
    'Test-S19-TimelineOrdering', 'Test-S20-TimelineNodeFields', 'Test-S21-PerAttemptCost',
    'Test-S22-CumulativeCost', 'Test-S23-FirstTransitionStart', 'Test-S24-PlainRetry',
    'Test-S25-ReasoningEscalation', 'Test-S26-ModelSwitch', 'Test-S27-ProviderSwitch',
    'Test-S28-RebuildContext', 'Test-S29-Correction', 'Test-S30-ClaudeReviewFix',
    'Test-S31-EscalationDecisionCarried', 'Test-S32-BudgetStopTerminal',
    'Test-S33-HumanReviewTerminal', 'Test-S34-GovernanceStopTerminal',
    'Test-S35-VerifiedSuccessTerminal', 'Test-S36-FailedNoRetryTerminal',
    'Test-S37-FailureCategoryDisplay', 'Test-S38-FailureFingerprintDisplay',
    'Test-S39-ProviderFailureEvidence', 'Test-S40-RouteIdentityPreserved',
    'Test-S41-TaskFiltering', 'Test-S42-Sorting', 'Test-S43-CostAuthority',
    'Test-S44-NoSecondAttemptHistoryDb', 'Test-S45-SecretsNeverRendered',
    'Test-S46-SecretsNeverLogged', 'Test-S47-NoAiExecution', 'Test-S48-PaidCallsZero',
    'Test-S49-NetworkZero', 'Test-S50-EscalationStoreUntouched', 'Test-S51-BudgetUntouched',
    'Test-S52-WorkbookUnchanged', 'Test-S53-LaneCUiUnchanged', 'Test-S54-Build',
    'Test-S55-FrozenFilesUnchanged'
)

foreach ($scenario in $script:Scenarios) {
    try { & $scenario } catch { $script:ScenarioFails.Add("${scenario} threw: $($_.Exception.Message)") }
}

# Child-suite regressions (DB-M17/20/21/26/28) -- reported separately from the 55 scenarios.
Invoke-DbM29RegressionSuites

$script:Passed = $script:TestCount - $script:TestFails.Count
Write-Host "DB-M29 TEST SUMMARY: $($script:Passed) passed, $($script:TestFails.Count) failed"
Write-Host "DB-M29 SCENARIOS: $($script:Scenarios.Count) scenarios"
foreach ($r in $script:RegressionResults) {
    Write-Host ("DB-M29 REGRESSION {0}: {1} passed, {2} failed, exit {3}" -f $r.Name, $r.Passed, $r.Failed, $r.ExitCode)
}
foreach ($d in $script:ExternalDrift) { Write-Host "DB-M29 EXTERNAL DRIFT: $d" }
foreach ($f in $script:TestFails) { Write-Host "  FAIL: $f" }
foreach ($f in $script:ScenarioFails) { Write-Host "  SCENARIO FAIL: $f" }
# Cross-tree assertions that could not run are reported, never silently dropped: a
# run that skipped them is not the same evidence as a run that executed them.
Write-Host "DB-M29 HOST SKIPS: $($script:HostSkips.Count)"
foreach ($s in $script:HostSkips) { Write-Host "  [SKIP] $s" }

if ($script:TestFails.Count -eq 0 -and $script:ScenarioFails.Count -eq 0) {
    exit 0
}
exit 1

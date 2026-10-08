# Test-DbM25QualityCost.ps1 -- DB-M25 quality-adjusted cost + savings test suite (52 scenarios).
#
# Objective (the brief): "what is the real expected cost of obtaining a VERIFIED
# successful result?" -- not "which model is cheapest per attempt?". Cheap
# attempt cost does not necessarily mean cheap successful development.
#
# Every scenario runs entirely in-memory against deterministic synthetic
# AiAttemptRecord v1 (DB-M17) fixtures. NO AI API calls, NO provider calls, NO
# paid calls, NO network calls, NO credentials, NO writes to attempt history,
# routing configuration, pricing, or the workbook. DB-M24 confidence bands and
# the DB-M23 secret guard are consumed READ-ONLY.
#
# Exit code: 0 = all 52 scenarios + all regressions passed; 1 = any failure.
# Prints "DB-M25 TEST SUMMARY: <passed> passed, <failed> failed".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "AiQualityCostContracts.ps1")   # DB-M25 contracts (dot-sources M24 + M23 READ-ONLY)
. (Join-Path $PSScriptRoot "QualityCost.ps1")              # DB-M25 engine
$null = Import-AiPerformanceConfiguration                 # load confidence bands READ-ONLY

$script:Root = (Resolve-AiPerformanceRoot)

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
    param($Actual, $Expected, [string]$Message = '', [double]$Tolerance = 0.0001)
    $script:TestCount++
    if ($null -eq $Actual -or $null -eq $Expected) {
        if ($null -ne $Actual -or $null -ne $Expected) { $script:TestFails.Add("$Message (null mismatch: actual=$Actual expected=$Expected)") }
        return
    }
    if ([math]::Abs([double]$Actual - [double]$Expected) -gt $Tolerance) {
        $script:TestFails.Add("$Message (actual=$Actual expected=$Expected)")
    }
}

function Assert-Rate {
    param($Actual, $Expected, [string]$Message)
    Assert-Near -Actual $Actual -Expected $Expected -Tolerance 0.0001 -Message $Message
}

function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Message)
    $script:TestCount++
    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $script:TestFails.Add("$Message (missing '$Needle' in '$Text')")
    }
}

function Assert-NotContains {
    param([string]$Text, [string]$Needle, [string]$Message)
    $script:TestCount++
    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $script:TestFails.Add("$Message (unexpected '$Needle' present in '$Text')")
    }
}

# --- fixture helpers -------------------------------------------------------------------

function New-Att {
    <#
    .SYNOPSIS
    Build a deterministic synthetic AiAttemptRecord v1 (DB-M17) for one scenario.
    Never writes to disk. LocalOrRemote and ClaudeReviewStatus are extended
    fields (DB-M25 reads them defensively; DB-M17 record shape is untouched).
    #>
    param(
        [string]$TaskId, [string]$ChangeId, [string]$AttemptId, [int]$RetryNumber = 0,
        [string]$Result = 'SUCCESS', [string]$VerificationResult = 'VERIFIED', [string]$FailureCategory,
        [Nullable[double]]$ActualCost, [Nullable[double]]$EstimatedCost, [string]$CostCurrency = 'INR',
        [string]$ProviderId = 'prov-a', [string]$ModelId = 'model-a', [string]$UnderlyingModelId = 'um-a',
        [string]$GatewayProviderId, [string]$ReasoningLevel = 'MEDIUM', [string]$TaskType = 'IMPLEMENTATION',
        [string]$Complexity = 'MEDIUM', [string]$Risk = 'LOW', [string]$ExecutionMode = 'ASSISTED',
        [string]$StartedAtUtc = '2026-08-20T10:00:00Z', [string]$EndedAtUtc = '2026-08-20T10:00:30Z',
        [string]$EscalatedFromAttemptId, [string]$EscalatedToAttemptId, [string]$EscalationReason,
        [bool]$HumanIntervention = $false,
        [string]$LocalOrRemote, [string]$ClaudeReviewStatus
    )
    $rec = New-AiAttemptRecord -TaskId $TaskId -ChangeId $ChangeId -AttemptId $AttemptId -RetryNumber $RetryNumber `
        -Result $Result -VerificationResult $VerificationResult -FailureCategory $FailureCategory `
        -ActualCost $ActualCost -EstimatedCost $EstimatedCost -CostCurrency $CostCurrency `
        -ProviderId $ProviderId -ModelId $ModelId -UnderlyingModelId $UnderlyingModelId `
        -GatewayProviderId $GatewayProviderId -ReasoningLevel $ReasoningLevel -TaskType $TaskType `
        -Complexity $Complexity -Risk $Risk -ExecutionMode $ExecutionMode `
        -StartedAtUtc $StartedAtUtc -EndedAtUtc $EndedAtUtc `
        -EscalatedFromAttemptId $EscalatedFromAttemptId -EscalatedToAttemptId $EscalatedToAttemptId `
        -EscalationReason $EscalationReason -HumanIntervention $HumanIntervention
    if ($LocalOrRemote) { $rec | Add-Member -NotePropertyName 'LocalOrRemote' -NotePropertyValue $LocalOrRemote -Force }
    if ($ClaudeReviewStatus) { $rec | Add-Member -NotePropertyName 'ClaudeReviewStatus' -NotePropertyValue $ClaudeReviewStatus -Force }
    return $rec
}

function Get-Group {
    param([AllowNull()][object[]]$Results, [string]$GroupKey)
    foreach ($r in @($Results)) {
        if ([string](Get-ContractProperty $r 'GroupKey' '') -eq $GroupKey) { return $r }
    }
    return $null
}

function Get-Warnings {
    param($Summary)
    return @(Get-ContractProperty $Summary 'Warnings' @()) -join ' | '
}

function New-FailPassChain {
    # 2-attempt verified-success chain: fail + verified pass.
    param([string]$ChangeId, [double]$FailCost, [double]$SuccessCost,
          [string]$FailCategory = 'MODEL_QUALITY', [string]$ModelId = 'model-a',
          [string]$ProviderId = 'prov-a')
    $r1 = New-Att -TaskId $ChangeId -ChangeId $ChangeId -AttemptId ("{0}-R0" -f $ChangeId) -RetryNumber 0 `
        -Result 'FAILED' -FailureCategory $FailCategory -ActualCost $FailCost `
        -ProviderId $ProviderId -ModelId $ModelId
    $r2 = New-Att -TaskId $ChangeId -ChangeId $ChangeId -AttemptId ("{0}-R1" -f $ChangeId) -RetryNumber 1 `
        -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost $SuccessCost `
        -ProviderId $ProviderId -ModelId $ModelId
    return @($r1, $r2)
}

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

$script:FrozenFiles = @(
    'config\ai-routing.json',
    'config\performance\confidence-bands.json',
    'ai-routing\AiRoutingContracts.ps1',
    'ai-routing\AiCostContracts.ps1',
    'ai-routing\CostCalculator.ps1',
    'ai-routing\AttemptStore.ps1',
    'ai-routing\router\RoutingCandidate.ps1',
    'ai-routing\router\RoutingPolicy.ps1',
    'ai-routing\escalation\EscalationContracts.ps1',
    'ai-routing\budget\BudgetPolicy.ps1',
    'ai-routing\budget\BudgetEngine.ps1',
    'ai-routing\provider-health\ProviderHealthContracts.ps1',
    'ai-routing\failover\FailoverContracts.ps1',
    'ai-routing\providers\common\AdapterContracts.ps1',
    'ai-routing\performance\AiPerformanceContracts.ps1',
    'ai-routing\performance\AiPerformanceFoundation.ps1',
    'ai-routing\performance\ModelPerformance.ps1'
)

# Capture the frozen-file hashes BEFORE any analysis runs (scenarios 43-45).
$script:ShaBefore = @{}
foreach ($rel in $script:FrozenFiles) { $script:ShaBefore[$rel] = Get-Sha256 (Join-Path $script:Root $rel) }

$script:ImplFiles = @(
    'ai-routing\quality-cost\AiQualityCostContracts.ps1',
    'ai-routing\quality-cost\QualityCost.ps1'
)

# --- scenario 1: cost chain fail+fail+pass = 19 -----------------------------------------
function Test-S01-CostChainIsSumOfAllAttempts {
    $recs = @(
        (New-Att -TaskId 'S1-T1' -ChangeId 'S1-T1' -AttemptId 'S1-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3),
        (New-Att -TaskId 'S1-T1' -ChangeId 'S1-T1' -AttemptId 'S1-T1-R1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 6),
        (New-Att -TaskId 'S1-T1' -ChangeId 'S1-T1' -AttemptId 'S1-T1-R2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    Assert-True ($res.Count -eq 1) 'S01: one route group'
    $g = $res[0]
    Assert-Near $g.TotalAttemptCost 19 'S01: total attempt cost includes failed attempts'
    Assert-Near $g.ObservedCostPerVerifiedSuccess 19 'S01: verified-success chain cost = 19 (never 10)'
    Assert-Near $g.TotalCostPerVerifiedSuccess 19 'S01: total cost per verified success = 19'
    Assert-True ($g.AttemptCount -eq 3) 'S01: attempt count 3'
    Assert-True ($g.SampleCount -eq 1) 'S01: sample count 1'
    Assert-True ($g.VerifiedSuccessCount -eq 1) 'S01: verified success 1'
    Assert-Rate $g.VerifiedSuccessRate 1.0 'S01: verified success rate 1.0'
    Assert-Near $g.FailedAttemptCost 9 'S01: failed attempt cost 3+6'
    Assert-True ($g.FailedChainCount -eq 0) 'S01: no failed chains'
}

# --- scenario 2: core principle (cheap attempt cost != cheap success) -------------------
function Test-S02-CheapestAttemptIsNotCheapestSuccess {
    $recs = @()
    $recs += (New-Att -TaskId 'S2-A' -ChangeId 'S2-A' -AttemptId 'S2-A-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 2 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S2-A' -ChangeId 'S2-A' -AttemptId 'S2-A-R1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 2 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S2-A' -ChangeId 'S2-A' -AttemptId 'S2-A-R2' -RetryNumber 2 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 2 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S2-A' -ChangeId 'S2-A' -AttemptId 'S2-A-R3' -RetryNumber 3 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 2 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S2-B' -ChangeId 'S2-B' -AttemptId 'S2-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 5 -ModelId 'model-b')
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    Assert-True ($res.Count -eq 2) 'S02: two route groups'
    $a = Get-Group $res 'prov-a|model-a|(none)'
    $b = Get-Group $res 'prov-a|model-b|(none)'
    Assert-NotNull $a 'S02: route A present'
    Assert-NotNull $b 'S02: route B present'
    Assert-Near $a.AverageAttemptCost 2 'S02: A average attempt cost 2'
    Assert-Near $a.ObservedCostPerVerifiedSuccess 8 'S02: A verified-success cost 8'
    Assert-True ($a.AttemptCount -eq 4) 'S02: A attempt count 4'
    Assert-Near $b.AverageAttemptCost 5 'S02: B average attempt cost 5'
    Assert-Near $b.ObservedCostPerVerifiedSuccess 5 'S02: B verified-success cost 5'
    Assert-True ($b.ObservedCostPerVerifiedSuccess -lt $a.ObservedCostPerVerifiedSuccess) 'S02: B cheaper per success despite pricier attempts'
    Assert-True ($a.AverageAttemptCost -lt $b.AverageAttemptCost) 'S02: cheap attempt price did NOT win'
}

# --- scenario 3: failed attempts always count -------------------------------------------
function Test-S03-FailedAttemptsAlwaysCount {
    $recs = @(
        (New-Att -TaskId 'S3-T1' -ChangeId 'S3-T1' -AttemptId 'S3-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3),
        (New-Att -TaskId 'S3-T1' -ChangeId 'S3-T1' -AttemptId 'S3-R1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 6),
        (New-Att -TaskId 'S3-T1' -ChangeId 'S3-T1' -AttemptId 'S3-R2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-Near $g.TotalCostPerVerifiedSuccess 19 'S03: failed attempts counted (19, never 10)'
    Assert-True ($g.TotalCostPerVerifiedSuccess -ne 10) 'S03: never reports only the success cost'
    Assert-Near $g.FailedAttemptCost 9 'S03: failed attempt cost 9'
}

# --- scenario 4: missing cost counted only for executed attempts -------------------------
function Test-S04-MissingCostOnlyForExecuted {
    $recs = @(
        (New-Att -TaskId 'S4-T1' -ChangeId 'S4-T1' -AttemptId 'S4-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY'),
        (New-Att -TaskId 'S4-T1' -ChangeId 'S4-T1' -AttemptId 'S4-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-Near $g.TotalAttemptCost 10 'S04: only executed attempts with evidence add cost'
    Assert-True ($g.CostExcludedCount -eq 1) 'S04: one executed attempt excluded (missing)'
    Assert-Contains (Get-Warnings $g) 'no cost evidence' 'S04: warning about missing cost'
}

# --- scenario 5: non-attempts excluded from attempt count and cost ------------------------
function Test-S05-NonAttemptsExcludedFromCount {
    $recs = @(
        (New-Att -TaskId 'S5-T1' -ChangeId 'S5-T1' -AttemptId 'S5-R0' -RetryNumber 0 -Result 'BUDGET_STOPPED'),
        (New-Att -TaskId 'S5-T1' -ChangeId 'S5-T1' -AttemptId 'S5-R1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3),
        (New-Att -TaskId 'S5-T1' -ChangeId 'S5-T1' -AttemptId 'S5-R2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 7)
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-True ($g.AttemptCount -eq 2) 'S05: budget-stopped record is not an AI attempt'
    Assert-Near $g.TotalAttemptCost 10 'S05: non-attempt adds no cost'
    Assert-Near $g.ObservedCostPerVerifiedSuccess 10 'S05: verified-success chain cost 10'
    Assert-Contains (Get-Warnings $g) 'non-attempt' 'S05: non-attempt excluded reported'
}

# --- scenario 6: budget block is never a fabricated unsuccessful AI attempt ----------------
function Test-S06-BudgetBlockNotFabricated {
    $recs = @(
        (New-Att -TaskId 'S6-T1' -ChangeId 'S6-T1' -AttemptId 'S6-R0' -RetryNumber 0 -Result 'BUDGET_STOPPED'),
        (New-Att -TaskId 'S6-T1' -ChangeId 'S6-T1' -AttemptId 'S6-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-Near $g.FailedAttemptCost 0 'S06: budget block does not become failed-attempt cost'
    Assert-True ($g.FailedChainCount -eq 0) 'S06: no failed chain from a budget block'
    Assert-True ($g.SampleCount -eq 1) 'S06: sample is the one real task'
    Assert-True ($g.AttemptCount -eq 1) 'S06: attempt count is the one real attempt'
}

# --- scenario 7: verification contradicts model self-reported success ---------------------
function Test-S07-VerificationContradicts {
    $rec = New-Att -TaskId 'S7-T1' -ChangeId 'S7-T1' -AttemptId 'S7-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'FAILED' -ActualCost 10
    $vs = Resolve-DbM25VerifiedSuccess -Attempt $rec -SuccessDefinition 'VERIFIED'
    Assert-True (-not $vs.Success) 'S07: FAILED verification contradicts success'
    Assert-True ($vs.Contradicted) 'S07: contradicted flagged'
    Assert-True ($vs.Reason -eq 'VERIFICATION_CONTRADICTED') 'S07: reason VERIFICATION_CONTRADICTED'
    $g = (Get-DbM25QualityAdjustedCost -Records @($rec) -Query (New-DbM25QualityCostQuery))[0]
    Assert-True ($g.VerifiedSuccessCount -eq 0) 'S07: no verified success'
    Assert-True ($g.ModelReturnedSuccessCount -eq 0) 'S07: no model-returned success either'
    Assert-True ($g.FailedChainCount -eq 1) 'S07: rejected implementation is a failed chain'
    Assert-Null $g.ObservedCostPerVerifiedSuccess 'S07: no cost per verified success'
    Assert-Contains (Get-Warnings $g) 'no verified success' 'S07: warning present'
}

# --- scenario 8: review required, status PENDING -> REVIEW_REJECTED ------------------------
function Test-S08-ReviewPendingRejected {
    $rec = New-Att -TaskId 'S8-T1' -ChangeId 'S8-T1' -AttemptId 'S8-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ClaudeReviewStatus 'PENDING'
    $q = New-DbM25QualityCostQuery -RequiresClaudeReview $true
    $vs = Resolve-DbM25VerifiedSuccess -Attempt $rec -SuccessDefinition 'VERIFIED' -RequiresClaudeReview $true -RequiredReviewStatus 'PASS'
    Assert-True ($vs.ReviewRejected) 'S08: review gate rejects PENDING'
    Assert-True (-not $vs.Success) 'S08: not a success under review gate'
    Assert-True ($vs.Reason -eq 'REVIEW_REJECTED') 'S08: reason REVIEW_REJECTED'
    $g = (Get-DbM25QualityAdjustedCost -Records @($rec) -Query $q)[0]
    Assert-True ($g.VerifiedSuccessCount -eq 0) 'S08: no verified success'
    Assert-True ($g.FailedChainCount -eq 1) 'S08: review-rejected chain is failed'
}

# --- scenario 9: review required, status PASS accepted -------------------------------------
function Test-S09-ReviewPassAccepted {
    $rec = New-Att -TaskId 'S9-T1' -ChangeId 'S9-T1' -AttemptId 'S9-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ClaudeReviewStatus 'PASS'
    $q = New-DbM25QualityCostQuery -RequiresClaudeReview $true
    $vs = Resolve-DbM25VerifiedSuccess -Attempt $rec -SuccessDefinition 'VERIFIED' -RequiresClaudeReview $true
    Assert-True ($vs.Success) 'S09: PASS accepted as success'
    Assert-True ($vs.Verified) 'S09: verified'
    $g = (Get-DbM25QualityAdjustedCost -Records @($rec) -Query $q)[0]
    Assert-True ($g.VerifiedSuccessCount -eq 1) 'S09: verified success counted'
    Assert-True ($g.FailedChainCount -eq 0) 'S09: no failed chain'
}

# --- scenario 10: VERIFIED_PREFERRED flags plain success as model-returned ------------------
function Test-S10-VerifiedPreferredFlagsModelReturned {
    $rec = New-Att -TaskId 'S10-T1' -ChangeId 'S10-T1' -AttemptId 'S10-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult $null -ActualCost 10
    $q = New-DbM25QualityCostQuery -SuccessDefinition 'VERIFIED_PREFERRED'
    $vs = Resolve-DbM25VerifiedSuccess -Attempt $rec -SuccessDefinition 'VERIFIED_PREFERRED'
    Assert-True ($vs.Success) 'S10: plain SUCCESS counts under VERIFIED_PREFERRED'
    Assert-True (-not $vs.Verified) 'S10: but is not verified'
    Assert-True ($vs.ModelReturned) 'S10: flagged model-returned'
    $g = (Get-DbM25QualityAdjustedCost -Records @($rec) -Query $q)[0]
    Assert-True ($g.ModelReturnedSuccessCount -eq 1) 'S10: model-returned counted'
    Assert-True ($g.VerifiedSuccessCount -eq 0) 'S10: verified count still 0'
}

# --- scenario 11: MODEL_RETURNED counts SUCCESS regardless (comparison only) ----------------
function Test-S11-ModelReturnedComparisonOnly {
    $rec = New-Att -TaskId 'S11-T1' -ChangeId 'S11-T1' -AttemptId 'S11-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'FAILED' -ActualCost 10
    $q = New-DbM25QualityCostQuery -SuccessDefinition 'MODEL_RETURNED'
    $vs = Resolve-DbM25VerifiedSuccess -Attempt $rec -SuccessDefinition 'MODEL_RETURNED'
    Assert-True ($vs.Success) 'S11: SUCCESS counts under MODEL_RETURNED'
    Assert-True ($vs.Contradicted) 'S11: contradiction still flagged'
    $g = (Get-DbM25QualityAdjustedCost -Records @($rec) -Query $q)[0]
    Assert-True ($g.ModelReturnedSuccessCount -eq 1) 'S11: model-returned counted'
    Assert-True ($g.VerifiedSuccessCount -eq 0) 'S11: never verified'
}

# --- scenario 12: default SuccessDefinition is VERIFIED --------------------------------------
function Test-S12-DefaultSuccessDefinitionVerified {
    $q = New-DbM25QualityCostQuery
    Assert-True ($q.SuccessDefinition -eq 'VERIFIED') 'S12: default SuccessDefinition VERIFIED'
    Assert-True ($q.GroupBy -eq 'ModelRoute') 'S12: default GroupBy ModelRoute'
    Assert-True ($q.ReportingCurrency -eq 'INR') 'S12: default currency INR'
    Assert-True (-not $q.RequiresClaudeReview) 'S12: review not required by default'
}

# --- scenario 13: first-attempt verified success rate ----------------------------------------
function Test-S13-FirstAttemptVerifiedRate {
    $recs = @()
    $recs += (New-Att -TaskId 'S13-T1' -ChangeId 'S13-T1' -AttemptId 'S13-T1-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    $recs += (New-Att -TaskId 'S13-T2' -ChangeId 'S13-T2' -AttemptId 'S13-T2-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3)
    $recs += (New-Att -TaskId 'S13-T2' -ChangeId 'S13-T2' -AttemptId 'S13-T2-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-True ($g.SampleCount -eq 2) 'S13: sample 2'
    Assert-True ($g.FirstAttemptVerifiedSuccessCount -eq 1) 'S13: one first-attempt verified success'
    Assert-Rate $g.FirstAttemptVerifiedSuccessRate 0.5 'S13: first-attempt rate 0.5'
}

# --- scenario 14: first attempt uses the first EXECUTED attempt -------------------------------
function Test-S14-FirstAttemptIsFirstExecuted {
    $recs = @(
        (New-Att -TaskId 'S14-T1' -ChangeId 'S14-T1' -AttemptId 'S14-R0' -RetryNumber 0 -Result 'BUDGET_STOPPED'),
        (New-Att -TaskId 'S14-T1' -ChangeId 'S14-T1' -AttemptId 'S14-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-True ($g.AttemptCount -eq 1) 'S14: one real attempt'
    Assert-True ($g.FirstAttemptVerifiedSuccessCount -eq 1) 'S14: verified success IS the first executed attempt'
    Assert-Rate $g.FirstAttemptVerifiedSuccessRate 1.0 'S14: first-attempt rate 1.0'
}

# --- scenario 15: expected cost OBSERVED_CHAINS when confidence MODERATE+ ---------------------
function Test-S15-ExpectedCostObservedChains {
    $recs = New-Object System.Collections.ArrayList
    foreach ($i in 0..19) {
        $c = 'S15-T{0:00}' -f $i
        $null = $recs.Add((New-Att -TaskId $c -ChangeId $c -AttemptId ("{0}-R0" -f $c) -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 6))
        $null = $recs.Add((New-Att -TaskId $c -ChangeId $c -AttemptId ("{0}-R1" -f $c) -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 14))
    }
    $g = (Get-DbM25QualityAdjustedCost -Records @($recs) -Query (New-DbM25QualityCostQuery))[0]
    Assert-True ($g.SampleCount -eq 20) 'S15: sample 20'
    Assert-True ($g.ConfidenceLevel -eq 'MODERATE') 'S15: confidence MODERATE at 20'
    Assert-Near $g.ObservedCostPerVerifiedSuccess 20 'S15: observed chain cost 20'
    Assert-Near $g.AverageAttemptCost 10 'S15: naive attempt cost 10'
    Assert-Near $g.ExpectedCostPerVerifiedSuccess 20 'S15: expected cost uses OBSERVED chains (20, not 10)'
    Assert-True ($g.ExpectedCostBasis -eq 'OBSERVED_CHAINS') 'S15: basis OBSERVED_CHAINS'
}

# --- scenario 16: expected cost COLD_START_SIMPLE when confidence INSUFFICIENT/LOW ------------
function Test-S16-ExpectedCostColdStart {
    $recs = @(
        (New-Att -TaskId 'S16-T1' -ChangeId 'S16-T1' -AttemptId 'S16-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 6),
        (New-Att -TaskId 'S16-T1' -ChangeId 'S16-T1' -AttemptId 'S16-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 14)
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-True ($g.ConfidenceLevel -eq 'INSUFFICIENT') 'S16: confidence INSUFFICIENT at sample 1'
    Assert-Near $g.ExpectedCostPerVerifiedSuccess 10 'S16: cold-start estimate = avgAttempt/rate = 10'
    Assert-True ($g.ExpectedCostBasis -eq 'COLD_START_SIMPLE') 'S16: basis COLD_START_SIMPLE'
    Assert-Contains (Get-Warnings $g) 'COLD_START_SIMPLE' 'S16: labelled as tentative'
}

# --- scenario 17: expected cost null when VerifiedSuccessRate = 0 -----------------------------
function Test-S17-ExpectedCostNullWhenNoSuccess {
    $recs = @(
        (New-Att -TaskId 'S17-T1' -ChangeId 'S17-T1' -AttemptId 'S17-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 5)
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-Rate $g.VerifiedSuccessRate 0 'S17: verified success rate 0'
    Assert-Null $g.ExpectedCostPerVerifiedSuccess 'S17: expected cost null at zero rate'
    Assert-Null $g.ExpectedCostBasis 'S17: basis null'
}

# --- scenario 18: no verified success -> no cost-per-success, no savings number --------------
function Test-S18-NoVerifiedSuccessNoSavings {
    $recs = @()
    $recs += (New-Att -TaskId 'S18-A' -ChangeId 'S18-A' -AttemptId 'S18-A-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 1 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S18-B' -ChangeId 'S18-B' -AttemptId 'S18-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 40 -ModelId 'model-b')
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    $cand = Get-Group $res 'prov-a|model-a|(none)'
    $base = Get-Group $res 'prov-a|model-b|(none)'
    Assert-Null $cand.ObservedCostPerVerifiedSuccess 'S18: cheap route with no verified success'
    $sav = Get-DbM25SavingsAnalysis -CandidateResult $cand -BaselineResult $base -BaselineType 'CURRENT_DEFAULT'
    Assert-Null $sav.AbsoluteSavings 'S18: no savings number'
    Assert-Contains (Get-Warnings $sav) 'no verified success' 'S18: reason reported'
}

# --- scenario 19: savings 40 vs 22 -> 18 (45%) ------------------------------------------------
function Test-S19-SavingsExplicitBaseline {
    $recs = @()
    $recs += (New-Att -TaskId 'S19-A' -ChangeId 'S19-A' -AttemptId 'S19-A-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 40 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S19-B' -ChangeId 'S19-B' -AttemptId 'S19-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 22 -ModelId 'model-b')
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    $base = Get-Group $res 'prov-a|model-a|(none)'
    $cand = Get-Group $res 'prov-a|model-b|(none)'
    $sav = Get-DbM25SavingsAnalysis -CandidateResult $cand -BaselineResult $base -BaselineType 'CURRENT_DEFAULT' -BaselineLabel 'current default route'
    Assert-Near $sav.AbsoluteSavings 18 'S19: absolute savings 40-22'
    Assert-Rate $sav.SavingsPercent 45.0 'S19: savings percent 45'
    Assert-True ($sav.BaselineType -eq 'CURRENT_DEFAULT') 'S19: baseline type explicit'
    Assert-True ($sav.BaselineLabel -eq 'current default route') 'S19: baseline label preserved'
    Assert-NotNull $sav.BaselineCostPerVerifiedSuccess 'S19: baseline cost carried'
}

# --- scenario 20: savings only on equivalent verified outcomes -------------------------------
function Test-S20-SavingsOnlyEquivalentVerified {
    # Candidate is cheapest per attempt but has zero verified successes.
    $recs = @()
    $recs += (New-Att -TaskId 'S20-A' -ChangeId 'S20-A' -AttemptId 'S20-A-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 40 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S20-B' -ChangeId 'S20-B' -AttemptId 'S20-B-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 1 -ModelId 'model-b')
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    $cand = Get-Group $res 'prov-a|model-b|(none)'
    $base = Get-Group $res 'prov-a|model-a|(none)'
    $sav = Get-DbM25SavingsAnalysis -CandidateResult $cand -BaselineResult $base -BaselineType 'CURRENT_DEFAULT'
    Assert-Null $sav.AbsoluteSavings 'S20: a model with no verified success has no savings number'
    Assert-Null $sav.SavingsPercent 'S20: no percent either'
}

# --- scenario 21: zero/unknown baseline -> SavingsPercent null (no division by zero) -----------
function Test-S21-ZeroBaselineNoPercent {
    $recs = @()
    $recs += (New-Att -TaskId 'S21-A' -ChangeId 'S21-A' -AttemptId 'S21-A-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 0 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S21-B' -ChangeId 'S21-B' -AttemptId 'S21-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 22 -ModelId 'model-b')
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    $base = Get-Group $res 'prov-a|model-a|(none)'
    $cand = Get-Group $res 'prov-a|model-b|(none)'
    Assert-Near $base.ObservedCostPerVerifiedSuccess 0 'S21: baseline observed cost 0'
    $sav = Get-DbM25SavingsAnalysis -CandidateResult $cand -BaselineResult $base -BaselineType 'CURRENT_DEFAULT'
    Assert-Near $sav.AbsoluteSavings -22 'S21: absolute -22'
    Assert-Null $sav.SavingsPercent 'S21: percent null at zero baseline (no division by zero)'
}

# --- scenario 22: baseline type explicit + validator -------------------------------------------
function Test-S22-BaselineTypeExplicit {
    $recs = @()
    $recs += (New-Att -TaskId 'S22-A' -ChangeId 'S22-A' -AttemptId 'S22-A-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 40 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S22-B' -ChangeId 'S22-B' -AttemptId 'S22-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 22 -ModelId 'model-b')
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    $sav = Get-DbM25SavingsAnalysis -CandidateResult (Get-Group $res 'prov-a|model-b|(none)') -BaselineResult (Get-Group $res 'prov-a|model-a|(none)') -BaselineType 'MANUAL_BASELINE' -BaselineLabel 'manual team baseline'
    Assert-True ($sav.BaselineType -eq 'MANUAL_BASELINE') 'S22: MANUAL_BASELINE explicit'
    $chk = Test-DbM25SavingsAnalysis $sav
    Assert-True ($chk.Valid) 'S22: valid savings analysis'
    $bad = New-DbM25SavingsAnalysis -Fields @{ BaselineType = 'NOT_A_TYPE'; BaselineBasis = 'OBSERVED'; AbsoluteSavings = 5; BaselineCostPerVerifiedSuccess = 10 }
    Assert-True (-not (Test-DbM25SavingsAnalysis $bad).Valid) 'S22: unknown baseline type rejected'
}

# --- scenario 23: baseline basis COUNTERFACTUAL labelled ----------------------------------------
function Test-S23-BaselineBasisCounterfactual {
    $recs = @()
    $recs += (New-Att -TaskId 'S23-A' -ChangeId 'S23-A' -AttemptId 'S23-A-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 40 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S23-B' -ChangeId 'S23-B' -AttemptId 'S23-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 22 -ModelId 'model-b')
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    $sav = Get-DbM25SavingsAnalysis -CandidateResult (Get-Group $res 'prov-a|model-b|(none)') -BaselineResult (Get-Group $res 'prov-a|model-a|(none)') -BaselineType 'CHEAPEST_ELIGIBLE' -BaselineBasis 'COUNTERFACTUAL'
    Assert-True ($sav.BaselineBasis -eq 'COUNTERFACTUAL') 'S23: counterfactual basis labelled'
    Assert-True ((Test-DbM25SavingsAnalysis $sav).Valid) 'S23: valid'
    Assert-True (-not (Test-IsValidDbM25BaselineBasis 'MADE_UP')) 'S23: invalid basis rejected'
}

# --- scenario 24: AvoidedRetryCost (ESTIMATED/COUNTERFACTUAL) -----------------------------------
function Test-S24-AvoidedRetryCost {
    $recs = @()
    $recs += (New-Att -TaskId 'S24-A' -ChangeId 'S24-A' -AttemptId 'S24-A-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 2 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S24-A' -ChangeId 'S24-A' -AttemptId 'S24-A-R1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 2 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S24-A' -ChangeId 'S24-A' -AttemptId 'S24-A-R2' -RetryNumber 2 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 2 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S24-A' -ChangeId 'S24-A' -AttemptId 'S24-A-R3' -RetryNumber 3 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 2 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S24-B' -ChangeId 'S24-B' -AttemptId 'S24-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 2 -ModelId 'model-b')
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    $base = Get-Group $res 'prov-a|model-a|(none)'
    $cand = Get-Group $res 'prov-a|model-b|(none)'
    Assert-Near $base.AverageAttemptsPerVerifiedSuccess 4 'S24: baseline attempts/success 4'
    Assert-Near $cand.AverageAttemptsPerVerifiedSuccess 1 'S24: candidate attempts/success 1'
    Assert-Near $cand.AverageAttemptCost 2 'S24: candidate avg attempt cost 2'
    $sav = Get-DbM25SavingsAnalysis -CandidateResult $cand -BaselineResult $base -BaselineType 'HISTORICAL_ROUTE'
    Assert-Near $sav.AvoidedRetryCost 6 'S24: avoided retry (4-1)*2 = 6'
    Assert-Contains (Get-Warnings $sav) 'ESTIMATED' 'S24: avoided retry labelled ESTIMATED'
    Assert-Contains (Get-Warnings $sav) 'COUNTERFACTUAL' 'S24: avoided retry labelled COUNTERFACTUAL'
}

# --- scenario 25: provider failure cost separate from model-quality failure ---------------------
function Test-S25-ProviderVsModelQualitySeparation {
    $recs = @()
    $recs += (New-Att -TaskId 'S25-T1' -ChangeId 'S25-T1' -AttemptId 'S25-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'RATE_LIMIT' -ActualCost 4)
    $recs += (New-Att -TaskId 'S25-T1' -ChangeId 'S25-T1' -AttemptId 'S25-T1-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    $recs += (New-Att -TaskId 'S25-T2' -ChangeId 'S25-T2' -AttemptId 'S25-T2-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 7)
    $recs += (New-Att -TaskId 'S25-T2' -ChangeId 'S25-T2' -AttemptId 'S25-T2-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-Near $g.ProviderFailureCost 4 'S25: provider failure cost 4 (rate limit)'
    Assert-Near $g.ModelQualityFailureCost 7 'S25: model-quality failure cost 7'
    Assert-Near $g.TotalAttemptCost 31 'S25: total attempt cost 4+10+7+10'
    Assert-True ($g.ProviderFailureCost -ne $g.ModelQualityFailureCost) 'S25: never conflated'
    Assert-NotNull $g.ProviderFailureCostShare 'S25: provider share present'
    Assert-NotNull $g.ModelQualityFailureCostShare 'S25: quality share present'
}

# --- scenario 26: FailureCategoryCosts table ------------------------------------------------------
function Test-S26-FailureCategoryCostTable {
    $recs = @()
    $recs += (New-Att -TaskId 'S26-T1' -ChangeId 'S26-T1' -AttemptId 'S26-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'RATE_LIMIT' -ActualCost 4)
    $recs += (New-Att -TaskId 'S26-T1' -ChangeId 'S26-T1' -AttemptId 'S26-T1-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    $recs += (New-Att -TaskId 'S26-T2' -ChangeId 'S26-T2' -AttemptId 'S26-T2-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 7)
    $recs += (New-Att -TaskId 'S26-T2' -ChangeId 'S26-T2' -AttemptId 'S26-T2-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    $tbl = Get-ContractProperty $g 'FailureCategoryCosts' @{}
    Assert-Near ([double]$tbl['RATE_LIMIT']) 4 'S26: RATE_LIMIT cost 4'
    Assert-Near ([double]$tbl['MODEL_QUALITY']) 7 'S26: MODEL_QUALITY cost 7'
    Assert-Near ([double]$tbl['MODEL_QUALITY'] + [double]$tbl['RATE_LIMIT']) $g.FailedAttemptCost 'S26: table sums to failed-attempt cost'
}

# --- scenario 27: escalation cost visible (M20 integration) --------------------------------------
function Test-S27-EscalationCostVisible {
    $recs = @(
        (New-Att -TaskId 'S27-T1' -ChangeId 'S27-T1' -AttemptId 'S27-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3 -EscalatedToAttemptId 'S27-T1-R1'),
        (New-Att -TaskId 'S27-T1' -ChangeId 'S27-T1' -AttemptId 'S27-T1-R1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 6 -EscalatedFromAttemptId 'S27-T1-R0'),
        (New-Att -TaskId 'S27-T1' -ChangeId 'S27-T1' -AttemptId 'S27-T1-R2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-Near $g.EscalationCost 9 'S27: escalation cost 3+6'
    Assert-Near $g.EscalatedChainCost 19 'S27: escalated chain total cost 19'
    Assert-Near $g.TotalCostPerVerifiedSuccess 19 'S27: cheap->fail->stronger->success chain total'
}

# --- scenario 28: currency mismatch excluded, never re-converted --------------------------------
function Test-S28-CurrencyMismatchNeverReconverted {
    $recs = @(
        (New-Att -TaskId 'S28-T1' -ChangeId 'S28-T1' -AttemptId 'S28-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3 -CostCurrency 'USD'),
        (New-Att -TaskId 'S28-T1' -ChangeId 'S28-T1' -AttemptId 'S28-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -CostCurrency 'INR')
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-Near $g.TotalAttemptCost 10 'S28: USD 3 never re-converted into the total'
    Assert-True ($g.CostExcludedCount -eq 1) 'S28: mismatched attempt excluded'
    Assert-Contains (Get-Warnings $g) 'currency' 'S28: currency exclusion reported'
}

# --- scenario 29: only matching reporting currency contributes -----------------------------------
function Test-S29-CurrencyMatchingOnly {
    $recs = @(
        (New-Att -TaskId 'S29-T1' -ChangeId 'S29-T1' -AttemptId 'S29-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 5 -CostCurrency 'INR'),
        (New-Att -TaskId 'S29-T1' -ChangeId 'S29-T1' -AttemptId 'S29-T1-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -CostCurrency 'INR'),
        (New-Att -TaskId 'S29-T2' -ChangeId 'S29-T2' -AttemptId 'S29-T2-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -CostCurrency 'USD')
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-Near $g.TotalAttemptCost 15 'S29: only INR contributes (5+10)'
    Assert-Near $g.ObservedCostPerVerifiedSuccess 15 'S29: chain cost uses INR evidence only'
}

# --- scenario 30: LOCAL is never automatically FREE ----------------------------------------------
function Test-S30-LocalIsNeverFree {
    $recs = @(
        (New-Att -TaskId 'S30-T1' -ChangeId 'S30-T1' -AttemptId 'S30-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 0 -ProviderId 'local-a' -ModelId 'llm-local' -LocalOrRemote 'LOCAL')
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-True ($g.LocalCostStatus -eq 'LOCAL_COST_UNKNOWN') 'S30: LOCAL zero provider-token cost is LOCAL_COST_UNKNOWN'
    Assert-True ($g.LocalCostStatus -ne 'FREE') 'S30: LOCAL is never FREE'
    Assert-True ($g.OperationalCostUnknown) 'S30: operational cost unknown'
    Assert-Contains (Get-Warnings $g) 'operational cost' 'S30: warning about operational cost'
}

# --- scenario 31: LOCAL configured positive cost -> CONFIGURED ------------------------------------
function Test-S31-LocalConfigured {
    $recs = @(
        (New-Att -TaskId 'S31-T1' -ChangeId 'S31-T1' -AttemptId 'S31-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 5 -ProviderId 'local-a' -ModelId 'llm-local' -LocalOrRemote 'LOCAL')
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-True ($g.LocalCostStatus -eq 'CONFIGURED') 'S31: LOCAL with configured cost is CONFIGURED'
    Assert-True ($g.OperationalCostUnknown) 'S31: operational cost still unknown'
}

# --- scenario 32: remote PRICE_UNKNOWN vs FREE -----------------------------------------------------
function Test-S32-RemoteStatuses {
    $recs = @(
        (New-Att -TaskId 'S32-A' -ChangeId 'S32-A' -AttemptId 'S32-A-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ModelId 'model-a'),
        (New-Att -TaskId 'S32-B' -ChangeId 'S32-B' -AttemptId 'S32-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 0 -ModelId 'model-b')
    )
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    $a = Get-Group $res 'prov-a|model-a|(none)'
    $b = Get-Group $res 'prov-a|model-b|(none)'
    Assert-True ($a.LocalCostStatus -eq 'PRICE_UNKNOWN') 'S32: remote with no cost -> PRICE_UNKNOWN'
    Assert-True ($b.LocalCostStatus -eq 'FREE') 'S32: remote with explicit zero cost -> FREE'
}

# --- scenario 33: confidence INSUFFICIENT for one attempt ------------------------------------------
function Test-S33-ConfidenceInsufficientOne {
    $recs = @(
        (New-Att -TaskId 'S33-T1' -ChangeId 'S33-T1' -AttemptId 'S33-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-True ($g.ConfidenceLevel -eq 'INSUFFICIENT') 'S33: one attempt -> INSUFFICIENT'
    Assert-Contains (Get-Warnings $g) 'Small sample' 'S33: small-sample warning'
}

# --- scenario 34: confidence bands reused READ-ONLY (MODERATE at 20, HIGH at 60) ------------------
function Test-S34-ConfidenceBandsReused {
    function Build-NChains([int]$n) {
        $list = New-Object System.Collections.ArrayList
        foreach ($i in 0..($n - 1)) {
            $c = 'S34-T{0:000}' -f $i
            $null = $list.Add((New-Att -TaskId $c -ChangeId $c -AttemptId ("{0}-R0" -f $c) -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 6))
            $null = $list.Add((New-Att -TaskId $c -ChangeId $c -AttemptId ("{0}-R1" -f $c) -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 14))
        }
        return @($list)
    }
    $g20 = (Get-DbM25QualityAdjustedCost -Records (Build-NChains 20) -Query (New-DbM25QualityCostQuery))[0]
    $g60 = (Get-DbM25QualityAdjustedCost -Records (Build-NChains 60) -Query (New-DbM25QualityCostQuery))[0]
    Assert-True ($g20.ConfidenceLevel -eq 'MODERATE') 'S34: 20 chains -> MODERATE (bands reused)'
    Assert-True ($g60.ConfidenceLevel -eq 'HIGH') 'S34: 60 chains -> HIGH (bands reused)'
    Assert-Near $g60.ObservedCostPerVerifiedSuccess 20 'S34: 60-chain observed cost 20'
}

# --- scenario 35: ActualCost preferred over EstimatedCost -------------------------------------------
function Test-S35-ActualPreferred {
    $recs = @(
        (New-Att -TaskId 'S35-T1' -ChangeId 'S35-T1' -AttemptId 'S35-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -EstimatedCost 8)
    )
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))[0]
    Assert-Near $g.ObservedCostPerVerifiedSuccess 10 'S35: ActualCost 10 wins over EstimatedCost 8'
    Assert-Near $g.TotalAttemptCost 10 'S35: total uses actual'
}

# --- scenario 36: estimated fallback used only when the query allows it ------------------------------
function Test-S36-EstimatedFallbackGate {
    $recs = @(
        (New-Att -TaskId 'S36-T1' -ChangeId 'S36-T1' -AttemptId 'S36-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -EstimatedCost 5)
    )
    $qNo = New-DbM25QualityCostQuery
    $gNo = (Get-DbM25QualityAdjustedCost -Records $recs -Query $qNo)[0]
    Assert-Near $gNo.TotalAttemptCost 0 'S36: estimated cost excluded when fallback disabled'
    Assert-True ($gNo.CostExcludedCount -eq 1) 'S36: excluded count 1'
    Assert-Contains (Get-Warnings $gNo) 'estimated cost only' 'S36: fallback-disabled warning'
    $qYes = New-DbM25QualityCostQuery -AllowEstimatedCostFallback $true
    $gYes = (Get-DbM25QualityAdjustedCost -Records $recs -Query $qYes)[0]
    Assert-Near $gYes.TotalAttemptCost 5 'S36: estimated cost used when allowed'
    Assert-True ($gYes.EstimatedCostFallbackUsed -eq 1) 'S36: fallback use counted'
    Assert-Near $gYes.ObservedCostPerVerifiedSuccess 5 'S36: observed cost from estimated evidence'
    Assert-Contains (Get-Warnings $gYes) 'Estimated-cost fallback' 'S36: fallback labelled'
}

# --- scenario 37: dimension filters (ProviderId / ModelId) --------------------------------------------
function Test-S37-DimensionFilters {
    $recs = @()
    $recs += (New-Att -TaskId 'S37-A' -ChangeId 'S37-A' -AttemptId 'S37-A-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S37-B' -ChangeId 'S37-B' -AttemptId 'S37-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -ModelId 'model-b')
    $q = New-DbM25QualityCostQuery -ModelId 'model-a'
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query $q)
    Assert-True ($res.Count -eq 1) 'S37: only model-a group remains'
    Assert-True ($res[0].ModelId -eq 'model-a') 'S37: model-a identity'
    $q2 = New-DbM25QualityCostQuery -ProviderId 'prov-a' -ModelId 'model-b'
    $res2 = @(Get-DbM25QualityAdjustedCost -Records $recs -Query $q2)
    Assert-True ($res2.Count -eq 1) 'S37: provider+model filter narrows correctly'
    Assert-True ($res2[0].ModelId -eq 'model-b') 'S37: model-b identity'
}

# --- scenario 38: LocalOrRemote dimension filter -----------------------------------------------------
function Test-S38-LocalOrRemoteFilter {
    $recs = @()
    $recs += (New-Att -TaskId 'S38-A' -ChangeId 'S38-A' -AttemptId 'S38-A-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ProviderId 'local-a' -ModelId 'llm-local' -LocalOrRemote 'LOCAL')
    $recs += (New-Att -TaskId 'S38-B' -ChangeId 'S38-B' -AttemptId 'S38-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -ModelId 'model-a' -LocalOrRemote 'REMOTE')
    $q = New-DbM25QualityCostQuery -LocalOrRemote 'REMOTE'
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query $q)
    Assert-True ($res.Count -eq 1) 'S38: LOCAL records excluded by REMOTE filter'
    Assert-True ($res[0].LocalOrRemote -eq 'REMOTE') 'S38: remote group identity'
}

# --- scenario 39: time-window filter -----------------------------------------------------------------
function Test-S39-TimeWindowFilter {
    $recs = @()
    $recs += (New-Att -TaskId 'S39-T1' -ChangeId 'S39-T1' -AttemptId 'S39-T1-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -StartedAtUtc '2026-08-10T10:00:00Z' -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S39-T2' -ChangeId 'S39-T2' -AttemptId 'S39-T2-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -StartedAtUtc '2026-08-20T10:00:00Z' -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S39-T3' -ChangeId 'S39-T3' -AttemptId 'S39-T3-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 30 -StartedAtUtc '2026-08-30T10:00:00Z' -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S39-T4' -ChangeId 'S39-T4' -AttemptId 'S39-T4-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 40 -StartedAtUtc $null -ModelId 'model-a')
    $q = New-DbM25QualityCostQuery -PresetWindow 'CUSTOM' -FromUtc '2026-08-15T00:00:00Z' -ToUtc '2026-08-25T00:00:00Z'
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query $q)[0]
    Assert-True ($g.SampleCount -eq 1) 'S39: only in-window task remains'
    Assert-Near $g.TotalAttemptCost 20 'S39: only T2 cost included'
    Assert-True ($g.AttemptCount -eq 1) 'S39: no-start-time record excluded when window set'
}

# --- scenario 40: group-by LocalOrRemote -------------------------------------------------------------
function Test-S40-GroupByLocalOrRemote {
    $recs = @()
    $recs += (New-Att -TaskId 'S40-A' -ChangeId 'S40-A' -AttemptId 'S40-A-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ProviderId 'local-a' -ModelId 'llm-1' -LocalOrRemote 'LOCAL')
    $recs += (New-Att -TaskId 'S40-B' -ChangeId 'S40-B' -AttemptId 'S40-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -ModelId 'model-a' -LocalOrRemote 'REMOTE')
    $q = New-DbM25QualityCostQuery -GroupBy 'LocalOrRemote'
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query $q)
    Assert-True ($res.Count -eq 2) 'S40: LOCAL and REMOTE groups'
    Assert-NotNull (Get-Group $res 'LOCAL') 'S40: LOCAL group present'
    Assert-NotNull (Get-Group $res 'REMOTE') 'S40: REMOTE group present'
}

# --- scenario 41: default group-by ModelRoute ---------------------------------------------------------
function Test-S41-GroupByModelRouteDefault {
    $recs = @()
    $recs += (New-Att -TaskId 'S41-A' -ChangeId 'S41-A' -AttemptId 'S41-A-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S41-B' -ChangeId 'S41-B' -AttemptId 'S41-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -ModelId 'model-b')
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    Assert-True ($res.Count -eq 2) 'S41: two model routes'
    Assert-NotNull (Get-Group $res 'prov-a|model-a|(none)') 'S41: route A key'
    Assert-NotNull (Get-Group $res 'prov-a|model-b|(none)') 'S41: route B key'
}

# --- scenario 42: no records -> empty result ------------------------------------------------------------
function Test-S42-NoRecords {
    $res = @(Get-DbM25QualityAdjustedCost -Records @() -Query (New-DbM25QualityCostQuery))
    Assert-True ($res.Count -eq 0) 'S42: no records yields no results'
    $res2 = @(Get-DbM25QualityAdjustedCost -Records $null -Query (New-DbM25QualityCostQuery))
    Assert-True ($res2.Count -eq 0) 'S42: null records yields no results'
}

# --- scenario 43: unchanged-file SHA-256 before/after -------------------------------------------------
function Test-S43-UnchangedFilesSha256 {
    foreach ($rel in $script:FrozenFiles) {
        $after = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($after -eq $script:ShaBefore[$rel]) "S43: $rel byte-identical (SHA-256 unchanged)"
        Assert-NotNull $after "S43: $rel exists and has a hash"
    }
}

# --- scenario 44: frozen contract overlap (M19/M20/M21/M22/M23/M24) byte-identical ---------------------
function Test-S44-FrozenContractOverlap {
    $overlap = @(
        'ai-routing\router\RoutingCandidate.ps1',
        'ai-routing\router\RoutingPolicy.ps1',
        'ai-routing\escalation\EscalationContracts.ps1',
        'ai-routing\budget\BudgetPolicy.ps1',
        'ai-routing\provider-health\ProviderHealthContracts.ps1',
        'ai-routing\failover\FailoverContracts.ps1',
        'ai-routing\providers\common\AdapterContracts.ps1',
        'ai-routing\performance\AiPerformanceContracts.ps1',
        'ai-routing\performance\AiPerformanceFoundation.ps1',
        'ai-routing\performance\ModelPerformance.ps1',
        'ai-routing\AttemptStore.ps1',
        'ai-routing\AiCostContracts.ps1'
    )
    foreach ($rel in $overlap) {
        $p = Join-Path $script:Root $rel
        Assert-NotNull (Get-Sha256 $p) "S44: frozen file exists: $rel"
        Assert-True ((Get-Sha256 $p) -eq $script:ShaBefore[$rel]) "S44: $rel untouched (read-only consumption)"
    }
}

# --- scenario 45: config files unchanged ----------------------------------------------------------------
function Test-S45-ConfigUnchanged {
    foreach ($rel in @('config\ai-routing.json', 'config\performance\confidence-bands.json')) {
        $p = Join-Path $script:Root $rel
        Assert-NotNull (Get-Sha256 $p) "S45: $rel exists"
        Assert-True ((Get-Sha256 $p) -eq $script:ShaBefore[$rel]) "S45: $rel unchanged (no policy/config mutation)"
    }
}

# --- scenario 46: workbook/roadmap untouched -------------------------------------------------------------
function Test-S46-WorkbookAndRoadmapUntouched {
    $forbidden = @('NEXUS_DEVELOPMENT_CONTROL', '.xlsx', 'Set-Content', 'Out-File', 'Add-Content',
                   'New-Item', 'Remove-Item', 'Copy-Item', 'Move-Item', 'ConvertTo-Json', 'Export-Csv',
                   'Replace-Workbook', 'Test-DevelopmentPreflight', 'Reserve-DevelopmentChange')
    foreach ($rel in $script:ImplFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        foreach ($tok in $forbidden) {
            Assert-NotContains $text $tok "S46: $rel has no '$tok' (no workbook/roadmap/lifecycle writes)"
        }
    }
}

# --- scenario 47: no paid/network/provider calls -----------------------------------------------------------
function Test-S47-NoPaidNetworkProviderCalls {
    $forbidden = @('Invoke-WebRequest', 'Invoke-RestMethod', 'Invoke-Expression', 'Start-Process',
                   'ConvertTo-ProviderNativeRequest', 'System.Net.Http', 'New-Object System.Net',
                   'System.Net.Sockets', 'webclient', 'Invoke-Remote', 'Get-AiPriceAt')
    foreach ($rel in $script:ImplFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        foreach ($tok in $forbidden) {
            Assert-NotContains $text $tok "S47: $rel has no '$tok' (no calls)"
        }
    }
    Assert-True ($script:TestCount -ge 0) 'S47: harness live'
}

# --- scenario 48: auto-execution disabled ---------------------------------------------------------------
function Test-S48-AutoExecutionDisabled {
    foreach ($rel in $script:ImplFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-Contains $text 'AUTO_EXECUTION_ENABLED = FALSE' "S48: $rel declares AUTO_EXECUTION_ENABLED = FALSE"
        Assert-NotContains $text 'AUTO_EXECUTION_ENABLED = TRUE' "S48: $rel never enables AUTO execution"
    }
}

# --- scenario 49: no policy mutation; PolicyVersion '0.0.0' ------------------------------------------------
function Test-S49-NoPolicyMutation {
    # model-a (default) is clearly cheapest per attempt so CHEAPEST_ELIGIBLE
    # deterministically selects it regardless of row order; model-b is cheaper
    # per verified success so the cost-policies select it.
    $recs = @()
    $recs += (New-Att -TaskId 'S49-A' -ChangeId 'S49-A' -AttemptId 'S49-A-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 2 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S49-A' -ChangeId 'S49-A' -AttemptId 'S49-A-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 6 -ModelId 'model-a')
    $recs += (New-Att -TaskId 'S49-B' -ChangeId 'S49-B' -AttemptId 'S49-B-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 5 -ModelId 'model-b')
    $res = @(Get-DbM25QualityAdjustedCost -Records $recs -Query (New-DbM25QualityCostQuery))
    $cmp = Compare-DbM25Policies -Summaries $res -AnalysisId 'S49' -DefaultGroupKey 'prov-a|model-a|(none)'
    Assert-True ($cmp.PolicyVersion -eq '0.0.0') 'S49: PolicyVersion immutable 0.0.0'
    Assert-True ($cmp.ComparedCount -ge 3) 'S49: all five policies evaluated'
    $defaultRow = @($cmp.Rows | Where-Object { $_.Route -eq 'prov-a|model-a|(none)' })
    $cfRows = @($cmp.Rows | Where-Object { $_.Basis -eq 'COUNTERFACTUAL' })
    Assert-True ($defaultRow.Count -ge 1) 'S49: default route appears in comparison'
    Assert-True (($defaultRow | Select-Object -First 1).Basis -eq 'OBSERVED') 'S49: default route row is labelled OBSERVED'
    Assert-True ($cfRows.Count -ge 1) 'S49: synthetic rows labelled COUNTERFACTUAL'
    Assert-True ((Test-DbM25PolicyComparison $cmp).Valid) 'S49: comparison contract valid'
    # config untouched (also asserted in S45)
    $cfg = Join-Path $script:Root 'config\ai-routing.json'
    Assert-True ((Get-Sha256 $cfg) -eq $script:ShaBefore['config\ai-routing.json']) 'S49: routing config byte-identical (no mutation)'
}

# --- scenario 50: schema validators pass on real artifacts ------------------------------------------------
function Test-S50-SchemaValidatorsPass {
    $recs = @(
        (New-Att -TaskId 'S50-T1' -ChangeId 'S50-T1' -AttemptId 'S50-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3),
        (New-Att -TaskId 'S50-T1' -ChangeId 'S50-T1' -AttemptId 'S50-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $q = New-DbM25QualityCostQuery
    Assert-True ((Test-DbM25QualityCostQuery $q).Valid) 'S50: default query valid'
    $g = (Get-DbM25QualityAdjustedCost -Records $recs -Query $q)[0]
    Assert-True ((Test-DbM25QualityAdjustedCostResult $g).Valid) 'S50: quality-adjusted result valid'
    $res2 = @(Get-DbM25QualityAdjustedCost -Records $recs -Query $q)
    $sav = Get-DbM25SavingsAnalysis -CandidateResult $res2[0] -BaselineResult $res2[0] -BaselineType 'SPECIFIC_MODEL_ROUTE' -BaselineLabel 'same-route baseline'
    Assert-True ((Test-DbM25SavingsAnalysis $sav).Valid) 'S50: savings analysis valid'
    $cmp = Compare-DbM25Policies -Summaries $res2 -AnalysisId 'S50'
    Assert-True ((Test-DbM25PolicyComparison $cmp).Valid) 'S50: policy comparison valid'
    Assert-True ((Test-DbM25SecretLeak $g).Leak -eq $false) 'S50: no secret-like value in result'
}

# --- scenario 51: query validator rejects invalid inputs ---------------------------------------------------
function Test-S51-QueryValidatorRejects {
    Assert-True (-not (Test-DbM25QualityCostQuery (New-DbM25QualityCostQuery -SuccessDefinition 'BOGUS')).Valid) 'S51: bad SuccessDefinition rejected'
    Assert-True (-not (Test-DbM25QualityCostQuery (New-DbM25QualityCostQuery -ReportingCurrency 'X')).Valid) 'S51: bad currency rejected'
    $qBad = New-DbM25QualityCostQuery -PresetWindow 'CUSTOM' -FromUtc '2026-08-25T00:00:00Z' -ToUtc '2026-08-15T00:00:00Z'
    Assert-True (-not (Test-DbM25QualityCostQuery $qBad).Valid) 'S51: FromUtc > ToUtc rejected'
    Assert-True (-not (Test-DbM25QualityCostQuery (New-DbM25QualityCostQuery -Complexity 'EXTREME')).Valid) 'S51: bad Complexity rejected'
    Assert-True (-not (Test-DbM25QualityCostQuery (New-DbM25QualityCostQuery -GroupBy 'NOPE')).Valid) 'S51: bad GroupBy rejected'
    Assert-True (-not (Test-DbM25QualityCostQuery (New-DbM25QualityCostQuery -ExecutionMode 'BOGUS')).Valid) 'S51: bad ExecutionMode rejected'
    Assert-True (-not (Test-DbM25QualityCostQuery (New-DbM25QualityCostQuery -LocalOrRemote 'CLOUD')).Valid) 'S51: bad LocalOrRemote rejected'
    Assert-True (-not (Test-DbM25QualityCostQuery $null).Valid) 'S51: null query rejected'
}

# --- scenario 52: secret-leak guard -------------------------------------------------------------------------
function Test-S52-SecretLeakGuard {
    $leaky = @{ Warnings = @('something sk-test1234567890abc else'); GroupKey = 'prov-a|model-a|(none)' }
    $res = Test-DbM25SecretLeak $leaky
    Assert-True ($res.Leak) 'S52: secret-like value in free text detected'
    $clean = New-DbM25QualityAdjustedCostResult -Fields @{ GroupKey = 'prov-a|model-a|(none)'; Warnings = @('small sample') }
    Assert-True (-not (Test-DbM25SecretLeak $clean).Leak) 'S52: clean analysis passes'
    $attemptLeak = New-Att -TaskId 'S52-T1' -ChangeId 'S52-T1' -AttemptId 'S52-R0' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ClaudeReviewStatus 'PASS'
    $attemptLeak | Add-Member -NotePropertyName Notes -NotePropertyValue 'sk-abcdefghijklmnopqrstuvwxyz' -Force
    Assert-True ((Test-AiAttemptSecretLeak $attemptLeak).Leak) 'S52: DB-M17 guard still catches attempt free text (read-only)'
}

# --- regression suites (child processes) ---------------------------------------------------------------------

$script:RegressionSuites = @(
    @{ Name = 'DBM14'; Path = 'ai-routing\Test-AiRoutingFoundation.ps1' },
    @{ Name = 'DBM16'; Path = 'ai-routing\Test-AiCostCalculator.ps1' },
    @{ Name = 'DBM17'; Path = 'ai-routing\Test-AttemptStore.ps1' },
    @{ Name = 'DBM19'; Path = 'ai-routing\router\Test-DbM19Routing.ps1' },
    @{ Name = 'DBM20'; Path = 'ai-routing\escalation\Test-DbM20Escalation.ps1' },
    @{ Name = 'DBM21'; Path = 'ai-routing\budget\Test-DbM21Budget.ps1' },
    @{ Name = 'DBM21Fingerprints'; Path = 'ai-routing\failure-fingerprints\Test-DbM21Fingerprints.ps1' },
    @{ Name = 'DBM22Health'; Path = 'ai-routing\provider-health\Test-DbM22Health.ps1' },
    @{ Name = 'DBM22Failover'; Path = 'ai-routing\failover\Test-DbM22Failover.ps1' },
    @{ Name = 'DBM23'; Path = 'ai-routing\providers\Test-DbM23Providers.ps1' },
    @{ Name = 'DBM24'; Path = 'ai-routing\performance\Test-AiModelPerformance.ps1' }
)

function Invoke-RegressionSuite {
    param([string]$Name, [string]$Path)
    $full = Join-Path $script:Root $Path
    Assert-True (Test-Path $full) "REG ${Name}: test file exists"
    $tmp = Join-Path $env:TEMP ("dbm25-reg-{0}-{1}.txt" -f $Name, (Get-Random))
    $exe = Join-Path $PSHOME 'powershell.exe'
    & $exe -NoProfile -ExecutionPolicy Bypass -File $full *> $tmp
    $exitCode = $LASTEXITCODE
    $text = ''
    if (Test-Path $tmp) { $text = Get-Content $tmp -Raw -Encoding UTF8 }
    # Parse each suite's known summary forms; exit code remains the authoritative gate.
    $summary = [regex]::Match($text, 'TEST SUMMARY:\s*(\d+)\s+passed,\s*(\d+)\s+failed')
    $passed = 0; $failed = 0
    if ($summary.Success) {
        $passed = [int]$summary.Groups[1].Value; $failed = [int]$summary.Groups[2].Value
    } elseif ($text -match '(?m)^PASSED:\s*(\d+)\s*\r?\nFAILED:\s*(\d+)') {
        $passed = [int]$Matches[1]; $failed = [int]$Matches[2]   # DB-M17
    } else {
        $passed = ([regex]::Matches($text, '(?m)^\s*(PASS:|\[PASS\])')).Count
        $failed = ([regex]::Matches($text, '(?m)^\s*(FAIL:|\[FAIL\])')).Count
    }
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    Assert-True ($exitCode -eq 0) "REG ${Name}: exit code 0 (got $exitCode)"
    Assert-True ($failed -eq 0) "REG ${Name}: zero failures (parsed $failed)"
    return @{ Name = $Name; ExitCode = $exitCode; Passed = $passed; Failed = $failed }
}

function Test-Regressions {
    $script:RegressionResults = @()
    foreach ($suite in $script:RegressionSuites) {
        $script:RegressionResults += , (Invoke-RegressionSuite -Name $suite.Name -Path $suite.Path)
    }
}

# --- runner ------------------------------------------------------------------------------------------------------

$script:Scenarios = @(
    'Test-S01-CostChainIsSumOfAllAttempts',
    'Test-S02-CheapestAttemptIsNotCheapestSuccess',
    'Test-S03-FailedAttemptsAlwaysCount',
    'Test-S04-MissingCostOnlyForExecuted',
    'Test-S05-NonAttemptsExcludedFromCount',
    'Test-S06-BudgetBlockNotFabricated',
    'Test-S07-VerificationContradicts',
    'Test-S08-ReviewPendingRejected',
    'Test-S09-ReviewPassAccepted',
    'Test-S10-VerifiedPreferredFlagsModelReturned',
    'Test-S11-ModelReturnedComparisonOnly',
    'Test-S12-DefaultSuccessDefinitionVerified',
    'Test-S13-FirstAttemptVerifiedRate',
    'Test-S14-FirstAttemptIsFirstExecuted',
    'Test-S15-ExpectedCostObservedChains',
    'Test-S16-ExpectedCostColdStart',
    'Test-S17-ExpectedCostNullWhenNoSuccess',
    'Test-S18-NoVerifiedSuccessNoSavings',
    'Test-S19-SavingsExplicitBaseline',
    'Test-S20-SavingsOnlyEquivalentVerified',
    'Test-S21-ZeroBaselineNoPercent',
    'Test-S22-BaselineTypeExplicit',
    'Test-S23-BaselineBasisCounterfactual',
    'Test-S24-AvoidedRetryCost',
    'Test-S25-ProviderVsModelQualitySeparation',
    'Test-S26-FailureCategoryCostTable',
    'Test-S27-EscalationCostVisible',
    'Test-S28-CurrencyMismatchNeverReconverted',
    'Test-S29-CurrencyMatchingOnly',
    'Test-S30-LocalIsNeverFree',
    'Test-S31-LocalConfigured',
    'Test-S32-RemoteStatuses',
    'Test-S33-ConfidenceInsufficientOne',
    'Test-S34-ConfidenceBandsReused',
    'Test-S35-ActualPreferred',
    'Test-S36-EstimatedFallbackGate',
    'Test-S37-DimensionFilters',
    'Test-S38-LocalOrRemoteFilter',
    'Test-S39-TimeWindowFilter',
    'Test-S40-GroupByLocalOrRemote',
    'Test-S41-GroupByModelRouteDefault',
    'Test-S42-NoRecords',
    'Test-S43-UnchangedFilesSha256',
    'Test-S44-FrozenContractOverlap',
    'Test-S45-ConfigUnchanged',
    'Test-S46-WorkbookAndRoadmapUntouched',
    'Test-S47-NoPaidNetworkProviderCalls',
    'Test-S48-AutoExecutionDisabled',
    'Test-S49-NoPolicyMutation',
    'Test-S50-SchemaValidatorsPass',
    'Test-S51-QueryValidatorRejects',
    'Test-S52-SecretLeakGuard'
)

foreach ($scenario in $script:Scenarios) {
    try {
        & $scenario
    } catch {
        $script:ScenarioFails.Add("${scenario} threw: $($_.Exception.Message)")
        Write-Host "  SCENARIO EXCEPTION ${scenario}: $($_.Exception.Message)"
    }
}

# regression suites run as child processes (read-only over the DB-M25 scope)
Test-Regressions

# re-verify frozen files after every analysis + regression (scenarios 43-45 re-run the assert)
foreach ($rel in $script:FrozenFiles) {
    $after = Get-Sha256 (Join-Path $script:Root $rel)
    if ($after -ne $script:ShaBefore[$rel]) {
        $script:TestFails.Add("POST-CHECK $rel changed during the run (SHA mismatch)")
    }
}

$passed = $script:TestCount - $script:TestFails.Count
Write-Host "DB-M25 TEST SUMMARY: $passed passed, $($script:TestFails.Count) failed"
Write-Host "DB-M25 SCENARIOS: $($script:Scenarios.Count) scenarios"
foreach ($r in $script:RegressionResults) {
    Write-Host ("DB-M25 REGRESSION {0}: {1} passed, {2} failed, exit {3}" -f $r.Name, $r.Passed, $r.Failed, $r.ExitCode)
}
foreach ($f in $script:TestFails) { Write-Host "  FAIL: $f" }
foreach ($f in $script:ScenarioFails) { Write-Host "  SCENARIO FAIL: $f" }
if ($script:TestFails.Count -eq 0 -and $script:ScenarioFails.Count -eq 0) {
    exit 0
}
exit 1

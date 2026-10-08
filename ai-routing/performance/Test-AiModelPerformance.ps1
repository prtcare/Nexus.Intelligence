# Test-AiModelPerformance.ps1 — DB-M24 performance intelligence test suite (34 scenarios).
#
# Every scenario runs entirely in-memory against deterministic synthetic attempt
# fixtures. NO AI API calls, NO provider calls, NO paid calls, NO network, NO
# credentials, NO writes to attempt history or routing configuration.
#
# Exit code: 0 = all scenarios + assertions passed; 1 = any failure.
# Prints "DB-M24 TEST SUMMARY: <passed> passed, <failed> failed".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "AiPerformanceFoundation.ps1")
$null = Import-AiPerformanceConfiguration

# --- assertion helpers (must return nothing) -----------------------------------------

$script:TestCount = 0
$script:TestFails = New-Object System.Collections.Generic.List[string]

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

function Assert-Near {
    # Message precedes Tolerance so 3-positional calls (actual, expected, message)
    # bind the message, not the numeric tolerance.
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

# --- fixture helpers -------------------------------------------------------------------

function New-Att {
    <#
    .SYNOPSIS
    Build a deterministic synthetic AiAttemptRecord v1 (DB-M17) for one scenario.
    Never writes to disk.
    #>
    param(
        [string]$TaskId, [string]$ChangeId, [string]$AttemptId, [int]$RetryNumber = 0,
        [string]$Result = 'SUCCESS', [string]$VerificationResult = 'VERIFIED', [string]$FailureCategory,
        [Nullable[double]]$ActualCost, [Nullable[double]]$EstimatedCost, [string]$CostCurrency = 'INR',
        [Nullable[long]]$DurationMs, [Nullable[long]]$InputTokens, [Nullable[long]]$OutputTokens,
        [Nullable[long]]$ContextTokens,
        [string]$ProviderId = 'prov-a', [string]$ModelId = 'model-a', [string]$UnderlyingModelId = 'um-a',
        [string]$GatewayProviderId, [string]$ReasoningLevel = 'MEDIUM', [string]$TaskType = 'IMPLEMENTATION',
        [string]$Complexity = 'MEDIUM', [string]$Risk = 'LOW', [string]$ExecutionMode = 'MANUAL',
        [string]$StartedAtUtc = '2026-08-20T10:00:00Z', [string]$EndedAtUtc = '2026-08-20T10:00:30Z',
        [string]$EscalatedFromAttemptId, [string]$EscalatedToAttemptId, [string]$EscalationReason,
        [bool]$HumanIntervention = $false
    )
    New-AiAttemptRecord -TaskId $TaskId -ChangeId $ChangeId -AttemptId $AttemptId -RetryNumber $RetryNumber `
        -Result $Result -VerificationResult $VerificationResult -FailureCategory $FailureCategory `
        -ActualCost $ActualCost -EstimatedCost $EstimatedCost -CostCurrency $CostCurrency -DurationMs $DurationMs `
        -InputTokens $InputTokens -OutputTokens $OutputTokens -ContextTokens $ContextTokens `
        -ProviderId $ProviderId -ModelId $ModelId -UnderlyingModelId $UnderlyingModelId `
        -GatewayProviderId $GatewayProviderId -ReasoningLevel $ReasoningLevel -TaskType $TaskType `
        -Complexity $Complexity -Risk $Risk -ExecutionMode $ExecutionMode `
        -StartedAtUtc $StartedAtUtc -EndedAtUtc $EndedAtUtc `
        -EscalatedFromAttemptId $EscalatedFromAttemptId -EscalatedToAttemptId $EscalatedToAttemptId `
        -EscalationReason $EscalationReason -HumanIntervention $HumanIntervention
}

function Get-RouteSummary {
    param([AllowNull()][object[]]$Summaries, [string]$ProviderId, [string]$ModelId)
    foreach ($s in @($Summaries)) {
        if ([string](Get-ContractProperty $s 'ProviderId' '') -eq $ProviderId -and
            [string](Get-ContractProperty $s 'ModelId' '') -eq $ModelId) { return $s }
    }
    return $null
}

function Get-SummaryWarnings {
    param($Summary)
    return @(Get-ContractProperty $Summary 'Warnings' @()) -join ' | '
}

# --- 34 scenarios ------------------------------------------------------------------------

# 1. Zero attempts -> no summaries; recommendation is INSUFFICIENT_DATA (cold start).
function Test-S01-ZeroAttempts {
    $q = New-AiPerformanceQuery -ReportingCurrency 'INR'
    $summaries = @(Get-AiModelPerformance -Records @() -Query $q)
    Assert-True ($summaries.Count -eq 0) 'S01: zero attempts yields no summaries'
    $r = Get-AiPerformanceRecommendation -Summaries $summaries -RecommendationType 'BEST_COST_PER_SUCCESS'
    Assert-True ($r.RecommendationType -eq 'INSUFFICIENT_DATA') 'S01: cold start recommendation is INSUFFICIENT_DATA'
    Assert-True ([string]::IsNullOrEmpty($r.RecommendedModelId)) 'S01: no recommended model on cold start'
}

# 2. One success -> sample 1, success 1, rate 1.0, first-attempt success.
function Test-S02-OneSuccess {
    $rec = New-Att -TaskId 'T1' -ChangeId 'C1' -AttemptId 'ATT-1' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 4 -DurationMs 500
    $s = (Get-AiModelPerformance -Records @($rec) -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.SampleCount -eq 1) 'S02: sample count 1'
    Assert-True ($s.SuccessCount -eq 1) 'S02: success count 1'
    Assert-Rate $s.SuccessRate 1.0 'S02: success rate 1.0'
    Assert-True ($s.FirstAttemptSuccessCount -eq 1) 'S02: first-attempt success 1'
    Assert-Rate $s.FirstAttemptSuccessRate 1.0 'S02: first-attempt success rate 1.0'
    Assert-True ($s.ConfidenceLevel -eq 'INSUFFICIENT') 'S02: sample 1 confidence INSUFFICIENT'
}

# 3. One failure -> success 0, failure 1, rate 0.0.
function Test-S03-OneFailure {
    $rec = New-Att -TaskId 'T1' -ChangeId 'C1' -AttemptId 'ATT-1' -Result 'FAILED' -FailureCategory 'MODEL_QUALITY'
    $s = (Get-AiModelPerformance -Records @($rec) -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.SampleCount -eq 1) 'S03: sample count 1'
    Assert-True ($s.FailureCount -eq 1) 'S03: failure count 1'
    Assert-True ($s.SuccessCount -eq 0) 'S03: success count 0'
    Assert-Rate $s.SuccessRate 0.0 'S03: success rate 0.0'
    Assert-True ($s.ModelQualityFailureCount -eq 1) 'S03: model-quality failure counted'
}

# 4. 100-attempt mixed history -> 60 tasks / 100 attempts, aggregated metrics exact.
function Test-S04-HundredAttemptsMixed {
    $recs = New-Object System.Collections.ArrayList
    # 40 single-attempt successes
    for ($i = 1; $i -le 40; $i++) {
        $null = $recs.Add((New-Att -TaskId "M$i" -ChangeId "CM$i" -AttemptId "ATT-M$i-0" -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -DurationMs 1000))
    }
    # 20 chains: FAIL(2000) + FAIL(2000) + SUCCESS(1000)
    for ($j = 1; $j -le 20; $j++) {
        $chg = "CMX$j"
        $null = $recs.Add((New-Att -TaskId "MX$j" -ChangeId $chg -AttemptId "ATT-X$j-1" -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -DurationMs 2000))
        $null = $recs.Add((New-Att -TaskId "MX$j" -ChangeId $chg -AttemptId "ATT-X$j-2" -RetryNumber 2 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -DurationMs 2000))
        $null = $recs.Add((New-Att -TaskId "MX$j" -ChangeId $chg -AttemptId "ATT-X$j-3" -RetryNumber 3 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -DurationMs 1000))
    }
    $s = (Get-AiModelPerformance -Records @($recs) -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.AttemptCount -eq 100) 'S04: 100 attempts counted'
    Assert-True ($s.SampleCount -eq 60) 'S04: 60 tasks sampled'
    Assert-True ($s.SuccessCount -eq 60) 'S04: 60 successes'
    Assert-True ($s.FirstAttemptSuccessCount -eq 40) 'S04: 40 first-attempt successes'
    Assert-Rate $s.SuccessRate 1.0 'S04: success rate 1.0'
    Assert-Near $s.AverageAttemptsPerSuccessfulTask 1.6667 'S04: avg attempts per successful task'
    Assert-Near $s.AverageDurationMs 1400.0 'S04: average duration over 100 attempts'
    Assert-True ($s.ConfidenceLevel -eq 'HIGH') 'S04: 60 tasks confidence HIGH'
}

# 5. First-attempt success rate: two routes, one 100% first-attempt, one 0%.
function Test-S05-FirstAttemptSuccess {
    $recs = @(
        (New-Att -TaskId 'FA1' -ChangeId 'CFA1' -AttemptId 'ATT-FA1' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ModelId 'm-fast'),
        (New-Att -TaskId 'FA2' -ChangeId 'CFA2' -AttemptId 'ATT-FA2' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ModelId 'm-fast'),
        (New-Att -TaskId 'RT1' -ChangeId 'CRT1' -AttemptId 'ATT-RT1-1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ModelId 'm-slow'),
        (New-Att -TaskId 'RT1' -ChangeId 'CRT1' -AttemptId 'ATT-RT1-2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ModelId 'm-slow')
    )
    $summaries = @(Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))
    $fast = Get-RouteSummary $summaries 'prov-a' 'm-fast'
    $slow = Get-RouteSummary $summaries 'prov-a' 'm-slow'
    Assert-Rate $fast.FirstAttemptSuccessRate 1.0 'S05: fast route first-attempt 1.0'
    Assert-Rate $slow.FirstAttemptSuccessRate 0.0 'S05: retry route first-attempt 0.0'
    $fa = Get-AiFirstAttemptSuccessRate -Records $recs -Query (New-AiPerformanceQuery)
    Assert-True ($fa.Count -eq 2) 'S05: first-attempt op returns both routes'
}

# 6. Retry then success -> 2 attempts, first-attempt 0, avg attempts 2.
function Test-S06-RetryThenSuccess {
    $recs = @(
        (New-Att -TaskId 'RT' -ChangeId 'CRT' -AttemptId 'ATT-1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 1),
        (New-Att -TaskId 'RT' -ChangeId 'CRT' -AttemptId 'ATT-2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 4)
    )
    $s = (Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.AttemptCount -eq 2) 'S06: two attempts'
    Assert-True ($s.SampleCount -eq 1) 'S06: one task'
    Assert-True ($s.SuccessCount -eq 1) 'S06: one success'
    Assert-True ($s.FirstAttemptSuccessCount -eq 0) 'S06: not first-attempt success'
    Assert-Near $s.AverageAttemptsPerSuccessfulTask 2.0 'S06: avg attempts per success 2'
}

# 7. Multiple retries then success -> 4 attempts, first-attempt 0.
function Test-S07-MultipleRetriesThenSuccess {
    $recs = @(
        (New-Att -TaskId 'MR' -ChangeId 'CMR' -AttemptId 'ATT-1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'TEST_FAILURE'),
        (New-Att -TaskId 'MR' -ChangeId 'CMR' -AttemptId 'ATT-2' -RetryNumber 2 -Result 'FAILED' -FailureCategory 'TEST_FAILURE'),
        (New-Att -TaskId 'MR' -ChangeId 'CMR' -AttemptId 'ATT-3' -RetryNumber 3 -Result 'FAILED' -FailureCategory 'TEST_FAILURE'),
        (New-Att -TaskId 'MR' -ChangeId 'CMR' -AttemptId 'ATT-4' -RetryNumber 4 -Result 'SUCCESS' -VerificationResult 'VERIFIED')
    )
    $s = (Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.AttemptCount -eq 4) 'S07: four attempts'
    Assert-True ($s.FirstAttemptSuccessCount -eq 0) 'S07: not first-attempt success'
    Assert-Near $s.AverageAttemptsPerSuccessfulTask 4.0 'S07: avg attempts 4'
    Assert-True ($s.TestFailureCount -eq 3) 'S07: 3 test failures'
}

# 8. Model escalation -> escalation link recorded and analyzed (never executed).
function Test-S08-ModelEscalation {
    $recs = @(
        (New-Att -TaskId 'ME' -ChangeId 'CME' -AttemptId 'ATT-ME-1' -RetryNumber 1 -Result 'ESCALATED' -EscalatedToAttemptId 'ATT-ME-2' -EscalationReason 'MODEL_QUALITY'),
        (New-Att -TaskId 'ME' -ChangeId 'CME' -AttemptId 'ATT-ME-2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -EscalatedFromAttemptId 'ATT-ME-1' -ModelId 'model-premium')
    )
    $summaries = @(Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))
    $base = Get-RouteSummary $summaries 'prov-a' 'model-a'
    $prem = Get-RouteSummary $summaries 'prov-a' 'model-premium'
    Assert-True ($prem.SampleCount -eq 1) 'S08: task attributed to escalated-to route'
    Assert-True ($prem.EscalationCount -eq 1) 'S08: escalation counted on terminal route'
    Assert-True ($prem.SuccessCount -eq 1) 'S08: escalated-to route gets the success'
    Assert-True ($base.SampleCount -eq 0) 'S08: escalated-from route has no terminal task'
    $er = Get-AiEscalationRate -Records $recs -Query (New-AiPerformanceQuery)
    $premEr = Get-RouteSummary @($er) 'prov-a' 'model-premium'
    Assert-Rate $premEr.EscalationRate 1.0 'S08: escalation rate 1.0 on terminal route'
}

# 9. Provider failover -> same underlying model via two providers, terminal route wins.
function Test-S09-ProviderFailover {
    $recs = @(
        (New-Att -TaskId 'PF' -ChangeId 'CPF' -AttemptId 'ATT-PF-1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'PROVIDER_AVAILABILITY' -ProviderId 'prov-a' -ModelId 'model-a' -EscalatedToAttemptId 'ATT-PF-2' -EscalationReason 'PROVIDER_FAILOVER'),
        (New-Att -TaskId 'PF' -ChangeId 'CPF' -AttemptId 'ATT-PF-2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ProviderId 'prov-b' -ModelId 'model-a' -UnderlyingModelId 'um-a' -EscalatedFromAttemptId 'ATT-PF-1')
    )
    $summaries = @(Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))
    $pa = Get-RouteSummary $summaries 'prov-a' 'model-a'
    $pb = Get-RouteSummary $summaries 'prov-b' 'model-a'
    Assert-True ($pb.SampleCount -eq 1) 'S09: failover route owns the task'
    Assert-True ($pb.SuccessCount -eq 1) 'S09: failover route success'
    Assert-True ($pb.EscalationCount -eq 1) 'S09: failover counted as escalation'
    Assert-True ($pa.SampleCount -eq 0) 'S09: source provider no terminal task'
    Assert-True ($pa.ProviderFailureCount -eq 1) 'S09: source provider outage counted on its own route'
}

# 10. Human intervention -> HumanInterventionCount recorded, no policy change.
function Test-S10-HumanIntervention {
    $rec = New-Att -TaskId 'HI' -ChangeId 'CHI' -AttemptId 'ATT-HI' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -HumanIntervention $true
    $s = (Get-AiModelPerformance -Records @($rec) -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.HumanInterventionCount -eq 1) 'S10: human intervention counted'
    Assert-True ($s.SampleCount -eq 1) 'S10: intervention task still sampled'
}

# 11. Model-quality failure -> MODEL_QUALITY kept separate from provider counts.
function Test-S11-ModelQualityFailure {
    $rec = New-Att -TaskId 'MQ' -ChangeId 'CMQ' -AttemptId 'ATT-MQ' -Result 'FAILED' -FailureCategory 'MODEL_QUALITY'
    $s = (Get-AiModelPerformance -Records @($rec) -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.ModelQualityFailureCount -eq 1) 'S11: model-quality failure 1'
    Assert-True ($s.ProviderFailureCount -eq 0) 'S11: provider failure 0'
    $fd = Get-AiFailureDistribution -Records @($rec) -Query (New-AiPerformanceQuery)
    Assert-True ($fd.ModelQuality -eq 1) 'S11: distribution model-quality 1'
    Assert-True ($fd.Provider -eq 0) 'S11: distribution provider 0'
}

# 12. Provider outage -> PROVIDER_AVAILABILITY is a provider failure, not a model defect.
function Test-S12-ProviderOutage {
    $rec = New-Att -TaskId 'PO' -ChangeId 'CPO' -AttemptId 'ATT-PO' -Result 'FAILED' -FailureCategory 'PROVIDER_AVAILABILITY'
    $s = (Get-AiModelPerformance -Records @($rec) -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.ProviderFailureCount -eq 1) 'S12: provider failure 1'
    Assert-True ($s.ModelQualityFailureCount -eq 0) 'S12: model-quality failure 0'
}

# 13. Rate limit -> RATE_LIMIT grouped with provider-side failures.
function Test-S13-RateLimit {
    $rec = New-Att -TaskId 'RL' -ChangeId 'CRL' -AttemptId 'ATT-RL' -Result 'FAILED' -FailureCategory 'RATE_LIMIT'
    $s = (Get-AiModelPerformance -Records @($rec) -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.ProviderFailureCount -eq 1) 'S13: rate limit is a provider failure'
    $fd = Get-AiFailureDistribution -Records @($rec) -Query (New-AiPerformanceQuery)
    Assert-True ($fd.RateLimit -eq 1) 'S13: distribution rate-limit 1'
}

# 14. Build failure -> BUILD_FAILURE counted, not a provider failure.
function Test-S14-BuildFailure {
    $rec = New-Att -TaskId 'BF' -ChangeId 'CBF' -AttemptId 'ATT-BF' -Result 'FAILED' -FailureCategory 'BUILD_FAILURE'
    $s = (Get-AiModelPerformance -Records @($rec) -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.BuildFailureCount -eq 1) 'S14: build failure 1'
    Assert-True ($s.ProviderFailureCount -eq 0) 'S14: build failure not provider'
    Assert-True ($s.ModelQualityFailureCount -eq 0) 'S14: build failure not model quality'
}

# 15. Test failure -> TEST_FAILURE counted.
function Test-S15-TestFailure {
    $rec = New-Att -TaskId 'TF' -ChangeId 'CTF' -AttemptId 'ATT-TF' -Result 'FAILED' -FailureCategory 'TEST_FAILURE'
    $s = (Get-AiModelPerformance -Records @($rec) -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.TestFailureCount -eq 1) 'S15: test failure 1'
    $fd = Get-AiFailureDistribution -Records @($rec) -Query (New-AiPerformanceQuery)
    Assert-True ($fd.Test -eq 1) 'S15: distribution test 1'
}

# 16. Cost per successful task includes failed attempts (1+1+4 = 6, not 4).
function Test-S16-CostPerSuccessIncludesFailed {
    $recs = @(
        (New-Att -TaskId 'A' -ChangeId 'CA' -AttemptId 'ATT-A-1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 1),
        (New-Att -TaskId 'A' -ChangeId 'CA' -AttemptId 'ATT-A-2' -RetryNumber 2 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 1),
        (New-Att -TaskId 'A' -ChangeId 'CA' -AttemptId 'ATT-A-3' -RetryNumber 3 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 4)
    )
    $s = (Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))[0]
    Assert-Near $s.AverageCostPerSuccessfulTask 6.0 'S16: cost per successful task is 6 not 4'
    Assert-Near $s.AverageCostPerAttempt 2.0 'S16: average cost per attempt (1+1+4)/3'
    $cp = Get-AiCostPerSuccessfulTask -Records $recs -Query (New-AiPerformanceQuery)
    Assert-Near $cp[0].AverageCostPerSuccessfulTask 6.0 'S16: cost op reports 6'
    Assert-True ($cp[0].Currency -eq 'INR') 'S16: cost op reports INR'
}

# 17. Actual cost preferred over estimated cost when both present.
function Test-S17-ActualCostPreferred {
    $rec = New-Att -TaskId 'AC' -ChangeId 'CAC' -AttemptId 'ATT-AC' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -EstimatedCost 8
    $s = (Get-AiModelPerformance -Records @($rec) -Query (New-AiPerformanceQuery))[0]
    Assert-Near $s.AverageCostPerSuccessfulTask 10.0 'S17: actual cost 10 used'
    Assert-Near $s.AverageActualCost 10.0 'S17: average actual cost 10'
    Assert-Near $s.AverageEstimatedCost 8.0 'S17: average estimated cost 8 (reported separately)'
    Assert-True ($s.EstimatedCostFallbackUsed -eq 0) 'S17: no fallback needed'
}

# 18. Estimated-cost fallback is explicitly allowed and clearly labeled.
function Test-S18-EstimatedFallbackLabeled {
    $rec = New-Att -TaskId 'EF' -ChangeId 'CEF' -AttemptId 'ATT-EF' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -EstimatedCost 7
    # fallback enabled
    $qOn = New-AiPerformanceQuery -AllowEstimatedCostFallback $true
    $sOn = (Get-AiModelPerformance -Records @($rec) -Query $qOn)[0]
    Assert-Near $sOn.AverageCostPerSuccessfulTask 7.0 'S18: estimated cost used when allowed'
    Assert-True ($sOn.EstimatedCostFallbackUsed -eq 1) 'S18: fallback flag set'
    Assert-True ((Get-SummaryWarnings $sOn) -match 'estimated') 'S18: warning labels the fallback'
    # fallback disabled
    $qOff = New-AiPerformanceQuery -AllowEstimatedCostFallback $false
    $sOff = (Get-AiModelPerformance -Records @($rec) -Query $qOff)[0]
    Assert-Null $sOff.AverageCostPerSuccessfulTask 'S18: no cost when fallback disabled'
    Assert-True ($sOff.CostSampleCount -eq 0) 'S18: no cost samples when fallback disabled'
    Assert-True ((Get-SummaryWarnings $sOff) -match 'disabled') 'S18: warning explains fallback disabled'
}

# 19. Missing cost evidence excluded with a warning.
function Test-S19-MissingCostExcluded {
    $rec = New-Att -TaskId 'MC' -ChangeId 'CMC' -AttemptId 'ATT-MC' -Result 'SUCCESS' -VerificationResult 'VERIFIED'
    $s = (Get-AiModelPerformance -Records @($rec) -Query (New-AiPerformanceQuery))[0]
    Assert-Null $s.AverageCostPerSuccessfulTask 'S19: no cost metric without evidence'
    Assert-True ($s.CostSampleCount -eq 0) 'S19: zero cost samples'
    Assert-True ($s.CostExcludedCount -ge 1) 'S19: excluded count recorded'
    Assert-True ((Get-SummaryWarnings $s) -match 'excluded') 'S19: warning mentions exclusion'
}

# 20. Average duration across attempts.
function Test-S20-AverageDuration {
    $recs = @()
    for ($i = 1; $i -le 10; $i++) {
        $recs += New-Att -TaskId "D$i" -ChangeId "CD$i" -AttemptId "ATT-D$i" -DurationMs ($i * 1000)
    }
    $s = (Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))[0]
    Assert-Near $s.AverageDurationMs 5500.0 'S20: average duration 5500ms'
    Assert-True ($s.DurationSampleCount -eq 10) 'S20: duration sample count 10'
}

# 21. Median duration (even count -> midpoint of two middle values).
function Test-S21-MedianDuration {
    $recs = @()
    for ($i = 1; $i -le 10; $i++) {
        $recs += New-Att -TaskId "D$i" -ChangeId "CD$i" -AttemptId "ATT-D$i" -DurationMs ($i * 1000)
    }
    $s = (Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))[0]
    Assert-Near $s.MedianDurationMs 5500.0 'S21: median duration 5500ms'
}

# 22. P95 duration via nearest-rank percentile (ceil(0.95*10)-1 -> max of 1..10).
function Test-S22-P95Duration {
    $recs = @()
    for ($i = 1; $i -le 10; $i++) {
        $recs += New-Att -TaskId "D$i" -ChangeId "CD$i" -AttemptId "ATT-D$i" -DurationMs ($i * 1000)
    }
    $s = (Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))[0]
    Assert-Near $s.P95DurationMs 10000.0 'S22: P95 duration 10000ms'
    # outliers are never silently deleted: the max remains in the sample
    Assert-True ($s.DurationSampleCount -eq 10) 'S22: no outliers deleted'
}

# 23. Task-type filter.
function Test-S23-TaskTypeFilter {
    $recs = @(
        (New-Att -TaskId 'I1' -ChangeId 'CI1' -AttemptId 'ATT-I1' -TaskType 'IMPLEMENTATION'),
        (New-Att -TaskId 'A1' -ChangeId 'CA1' -AttemptId 'ATT-A1' -TaskType 'ARCHITECTURE'),
        (New-Att -TaskId 'I2' -ChangeId 'CI2' -AttemptId 'ATT-I2' -TaskType 'IMPLEMENTATION')
    )
    $q = New-AiPerformanceQuery -TaskType 'IMPLEMENTATION'
    $s = (Get-AiModelPerformance -Records $recs -Query $q)[0]
    Assert-True ($s.SampleCount -eq 2) 'S23: only implementation tasks sampled'
    $tt = @(Get-AiTaskTypePerformance -Records $recs -Query $q)
    Assert-True ($tt.Count -eq 1) 'S23: one task-type group'
    Assert-True ($tt[0].TaskType -eq 'IMPLEMENTATION') 'S23: group is IMPLEMENTATION'
}

# 24. Complexity filter.
function Test-S24-ComplexityFilter {
    $recs = @(
        (New-Att -TaskId 'L1' -ChangeId 'CL1' -AttemptId 'ATT-L1' -Complexity 'LOW'),
        (New-Att -TaskId 'H1' -ChangeId 'CH1' -AttemptId 'ATT-H1' -Complexity 'HIGH'),
        (New-Att -TaskId 'L2' -ChangeId 'CL2' -AttemptId 'ATT-L2' -Complexity 'LOW')
    )
    $q = New-AiPerformanceQuery -Complexity 'LOW'
    $s = (Get-AiModelPerformance -Records $recs -Query $q)[0]
    Assert-True ($s.SampleCount -eq 2) 'S24: only LOW complexity tasks sampled'
    $g = Get-AiPerformanceSummaries -Records $recs -Query $q -GroupBy 'Complexity'
    Assert-True ($g[0].Complexity -eq 'LOW') 'S24: group identity is LOW'
}

# 25. Risk filter.
function Test-S25-RiskFilter {
    $recs = @(
        (New-Att -TaskId 'R1' -ChangeId 'CR1' -AttemptId 'ATT-R1' -Risk 'LOW'),
        (New-Att -TaskId 'R2' -ChangeId 'CR2' -AttemptId 'ATT-R2' -Risk 'HIGH')
    )
    $q = New-AiPerformanceQuery -Risk 'HIGH'
    $s = (Get-AiModelPerformance -Records $recs -Query $q)[0]
    Assert-True ($s.SampleCount -eq 1) 'S25: only HIGH risk sampled'
    Assert-True ($s.Risk -eq 'HIGH') 'S25: risk identity HIGH'
}

# 26. Reasoning-level filter and analytics.
function Test-S26-ReasoningLevelFilter {
    $recs = @(
        (New-Att -TaskId 'K1' -ChangeId 'CK1' -AttemptId 'ATT-K1' -ReasoningLevel 'LOW'),
        (New-Att -TaskId 'K2' -ChangeId 'CK2' -AttemptId 'ATT-K2' -ReasoningLevel 'HIGH'),
        (New-Att -TaskId 'K3' -ChangeId 'CK3' -AttemptId 'ATT-K3' -ReasoningLevel 'HIGH')
    )
    $q = New-AiPerformanceQuery -ReasoningLevel 'HIGH'
    $s = (Get-AiModelPerformance -Records $recs -Query $q)[0]
    Assert-True ($s.SampleCount -eq 2) 'S26: only HIGH reasoning sampled'
    $g = @(Get-AiPerformanceSummaries -Records $recs -Query $q -GroupBy 'ReasoningLevel')
    Assert-True ($g.Count -eq 1) 'S26: one reasoning-level group'
    Assert-True ($g[0].ReasoningLevel -eq 'HIGH') 'S26: reasoning identity HIGH'
}

# 27. Last 7 days window (fixed reference instant).
function Test-S27-SevenDayRange {
    $now = '2026-08-30T00:00:00Z'
    $recs = @(
        (New-Att -TaskId 'D7' -ChangeId 'CD7' -AttemptId 'ATT-D7' -StartedAtUtc '2026-08-25T00:00:00Z'),
        (New-Att -TaskId 'D30' -ChangeId 'CD30' -AttemptId 'ATT-D30' -StartedAtUtc '2026-08-01T00:00:00Z'),
        (New-Att -TaskId 'DOLD' -ChangeId 'CDOLD' -AttemptId 'ATT-DOLD' -StartedAtUtc '2026-05-01T00:00:00Z')
    )
    $q = New-AiPerformanceQuery -PresetWindow 'LAST_7_DAYS' -NowUtc $now
    $s = (Get-AiModelPerformance -Records $recs -Query $q)[0]
    Assert-True ($s.SampleCount -eq 1) 'S27: only the 7-day task sampled'
    Assert-True ($s.SuccessCount -eq 1) 'S27: 7-day task succeeds'
}

# 28. Last 30 days window.
function Test-S28-ThirtyDayRange {
    $now = '2026-08-30T00:00:00Z'
    $recs = @(
        (New-Att -TaskId 'D7' -ChangeId 'CD7' -AttemptId 'ATT-D7' -StartedAtUtc '2026-08-25T00:00:00Z'),
        (New-Att -TaskId 'D30' -ChangeId 'CD30' -AttemptId 'ATT-D30' -StartedAtUtc '2026-08-01T00:00:00Z'),
        (New-Att -TaskId 'DOLD' -ChangeId 'CDOLD' -AttemptId 'ATT-DOLD' -StartedAtUtc '2026-05-01T00:00:00Z')
    )
    $q = New-AiPerformanceQuery -PresetWindow 'LAST_30_DAYS' -NowUtc $now
    $s = (Get-AiModelPerformance -Records $recs -Query $q)[0]
    Assert-True ($s.SampleCount -eq 2) 'S28: two tasks within 30 days'
}

# 29. Custom UTC range [FromUtc, ToUtc).
function Test-S29-CustomRange {
    $recs = @(
        (New-Att -TaskId 'D7' -ChangeId 'CD7' -AttemptId 'ATT-D7' -StartedAtUtc '2026-08-25T00:00:00Z'),
        (New-Att -TaskId 'D30' -ChangeId 'CD30' -AttemptId 'ATT-D30' -StartedAtUtc '2026-08-01T00:00:00Z'),
        (New-Att -TaskId 'DOLD' -ChangeId 'CDOLD' -AttemptId 'ATT-DOLD' -StartedAtUtc '2026-05-01T00:00:00Z')
    )
    $q = New-AiPerformanceQuery -PresetWindow 'CUSTOM' -FromUtc '2026-07-15T00:00:00Z' -ToUtc '2026-08-26T00:00:00Z'
    $s = (Get-AiModelPerformance -Records $recs -Query $q)[0]
    Assert-True ($s.SampleCount -eq 2) 'S29: two tasks in custom window'
    # invalid range is rejected
    $bad = New-AiPerformanceQuery -PresetWindow 'CUSTOM' -FromUtc '2026-08-26T00:00:00Z' -ToUtc '2026-07-15T00:00:00Z'
    $v = Test-AiPerformanceQuery $bad
    Assert-True (-not $v.Valid) 'S29: inverted range rejected by query validation'
}

# 30. Low confidence: 6 tasks -> LOW, warning recorded, no overstatement.
function Test-S30-LowConfidence {
    $recs = @()
    for ($i = 1; $i -le 6; $i++) { $recs += New-Att -TaskId "L$i" -ChangeId "CL$i" -AttemptId "ATT-L$i" }
    $s = (Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.SampleCount -eq 6) 'S30: six tasks'
    Assert-True ($s.ConfidenceLevel -eq 'LOW') 'S30: confidence LOW'
    Assert-True ((Get-SummaryWarnings $s) -match 'LOW') 'S30: warning flags small sample'
}

# 31. High confidence: 50 tasks -> HIGH.
function Test-S31-HighConfidence {
    $recs = @()
    for ($i = 1; $i -le 50; $i++) { $recs += New-Att -TaskId "H$i" -ChangeId "CH$i" -AttemptId "ATT-H$i" }
    $s = (Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))[0]
    Assert-True ($s.ConfidenceLevel -eq 'HIGH') 'S31: confidence HIGH at 50+'
}

# 32. Same underlying model via two providers -> two route summaries, one underlying group.
function Test-S32-UnderlyingViaTwoProviders {
    $recs = @(
        (New-Att -TaskId 'U1' -ChangeId 'CU1' -AttemptId 'ATT-U1' -ProviderId 'prov-a' -ModelId 'model-a' -UnderlyingModelId 'um-x' -ActualCost 3),
        (New-Att -TaskId 'U2' -ChangeId 'CU2' -AttemptId 'ATT-U2' -ProviderId 'prov-b' -ModelId 'model-b' -UnderlyingModelId 'um-x' -GatewayProviderId 'gw-b' -ActualCost 5)
    )
    $routes = @(Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))
    Assert-True ($routes.Count -eq 2) 'S32: two route summaries'
    $pa = Get-RouteSummary $routes 'prov-a' 'model-a'
    $pb = Get-RouteSummary $routes 'prov-b' 'model-b'
    Assert-True ($pa.SampleCount -eq 1 -and $pb.SampleCount -eq 1) 'S32: one task per route'
    Assert-True ($pb.GatewayProviderId -eq 'gw-b') 'S32: gateway identity preserved'
    $under = @(Get-AiPerformanceSummaries -Records $recs -Query (New-AiPerformanceQuery) -GroupBy 'UnderlyingModel')
    Assert-True ($under.Count -eq 1) 'S32: one underlying-model group'
    Assert-True ($under[0].SampleCount -eq 2) 'S32: underlying group samples both routes'
    Assert-Near $under[0].AverageCostPerSuccessfulTask 4.0 'S32: underlying cost averages both routes'
}

# 33. Recommendation never mutates routing policy (config hash unchanged; PolicyVersion immutable).
function Test-S33-NoAutomaticPolicyMutation {
    $root = Resolve-AiPerformanceRoot
    $policyFile = Join-Path $root 'config\ai-routing.json'
    Assert-True (Test-Path $policyFile) 'S33: routing config present for hash check'
    $before = (Get-FileHash $policyFile -Algorithm SHA256).Hash

    $recs = @()
    for ($i = 1; $i -le 6; $i++) { $recs += New-Att -TaskId "P$i" -ChangeId "CP$i" -AttemptId "ATT-P$i" -ModelId 'm-rec' -ProviderId 'prov-rec' -ActualCost 2 }
    $summaries = @(Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))
    $r = Get-AiPerformanceRecommendation -Summaries $summaries -RecommendationType 'BEST_COST_PER_SUCCESS'
    Assert-True ($r.RecommendationType -eq 'BEST_COST_PER_SUCCESS') 'S33: recommendation produced'
    Assert-True ($r.RecommendedModelId -eq 'm-rec') 'S33: recommended model is the only qualifying route'
    Assert-True ($r.PolicyVersion -eq '0.0.0') 'S33: PolicyVersion immutable (no policy change)'

    $after = (Get-FileHash $policyFile -Algorithm SHA256).Hash
    Assert-True ($before -eq $after) 'S33: routing config hash unchanged after recommendation'
    Assert-True ($r.ComparedModels.Count -ge 1) 'S33: compared-models evidence present'
}

# 34. Schema v1 round-trip for all four frozen contracts.
function Test-S34-SchemaV1RoundTrip {
    # 5 tasks per route -> both routes reach LOW confidence so a recommendation
    # (which requires >= MinimumConfidenceLevel=LOW) is actually produced.
    $recs = @()
    for ($i = 1; $i -le 5; $i++) { $recs += New-Att -TaskId "RTa$i" -ChangeId "CRTa$i" -AttemptId "ATT-RTa$i" -ModelId 'm-a' -ActualCost 4 }
    for ($i = 1; $i -le 5; $i++) { $recs += New-Att -TaskId "RTb$i" -ChangeId "CRTb$i" -AttemptId "ATT-RTb$i" -ModelId 'm-b' -ActualCost 9 }
    $summaries = @(Get-AiModelPerformance -Records $recs -Query (New-AiPerformanceQuery))

    # ModelPerformanceSummary v1
    $t1 = Test-AiModelPerformanceSummary $summaries[0]
    Assert-True $t1.Valid 'S34: summary v1 valid in memory'
    $js = $summaries[0] | ConvertTo-Json -Depth 20
    $back = $js | ConvertFrom-Json
    $t2 = Test-AiModelPerformanceSummary $back
    Assert-True $t2.Valid 'S34: summary v1 survives JSON round-trip'
    Assert-True ($back.SchemaVersion -eq 1) 'S34: summary SchemaVersion 1 preserved'
    Assert-True ($back.SampleCount -eq 5) 'S34: summary SampleCount preserved'
    Assert-True ($back.SuccessRate -eq 1) 'S34: summary SuccessRate preserved'

    # ModelComparison v1
    $cmp = Compare-AiModelPerformance -Summaries $summaries -SortBy 'AverageCostPerSuccessfulTask' -Direction 'ASCENDING'
    $vc = Test-AiModelComparison $cmp
    Assert-True $vc.Valid 'S34: comparison v1 valid'
    Assert-True ($cmp.Rows.Count -eq 2) 'S34: comparison ranks two rows'
    Assert-True ($cmp.Rows[0].Rank -eq 1) 'S34: cheapest row ranks first'
    $cmpBack = ($cmp | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    Assert-True (Test-AiModelComparison $cmpBack).Valid 'S34: comparison survives round-trip'

    # PerformanceRecommendation v1
    $rec = Get-AiPerformanceRecommendation -Summaries $summaries -RecommendationType 'CHEAPEST_RELIABLE'
    $vr = Test-AiPerformanceRecommendation $rec
    Assert-True $vr.Valid 'S34: recommendation v1 valid'
    Assert-True ($rec.RecommendedModelId -eq 'm-a') 'S34: cheapest reliable is m-a'
    $recBack = ($rec | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    Assert-True (Test-AiPerformanceRecommendation $recBack).Valid 'S34: recommendation survives round-trip'

    # PerformanceQuery v1
    $q = New-AiPerformanceQuery -PresetWindow 'LAST_30_DAYS' -ModelId 'm-a'
    $vq = Test-AiPerformanceQuery $q
    Assert-True $vq.Valid 'S34: query v1 valid'
    $qBack = ($q | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    Assert-True (Test-AiPerformanceQuery $qBack).Valid 'S34: query survives round-trip'
}

# --- safety scan: no network, no credentials, no writes -----------------------------------
function Test-SafetyScan {
    $scanPaths = @(
        (Join-Path $PSScriptRoot 'AiPerformanceContracts.ps1'),
        (Join-Path $PSScriptRoot 'ModelPerformance.ps1'),
        (Join-Path $PSScriptRoot 'AiPerformanceFoundation.ps1'),
        (Join-Path $PSScriptRoot 'Test-AiModelPerformance.ps1')
    )
    # Every token string is constructed piece-wise so the scan never matches its
    # own literals in this test file.
    $forbidden = New-Object System.Collections.ArrayList
    $null = $forbidden.Add(('Invoke-' + 'RestMethod'))
    $null = $forbidden.Add(('Invoke-' + 'WebRequest'))
    $null = $forbidden.Add(('Http' + 'Client'))
    $null = $forbidden.Add(('System' + '.Net'))
    $null = $forbidden.Add(('cu' + 'rl'))
    $null = $forbidden.Add(('w' + 'get'))
    $null = $forbidden.Add(('api' + '_key'))
    $null = $forbidden.Add(('Api' + 'Key'))
    $null = $forbidden.Add(('api' + 'key'))
    $null = $forbidden.Add(('Bearer' + ' '))
    $null = $forbidden.Add(('Author' + 'ization'))
    $null = $forbidden.Add(('secre' + 't'))
    $null = $forbidden.Add(('cli' + 'ent_' + 'secre' + 't'))
    $null = $forbidden.Add(('to' + 'ken ='))
    $hit = $null
    foreach ($p in $scanPaths) {
        $content = Get-Content $p -Raw
        foreach ($tok in $forbidden) {
            if ($content -match [regex]::Escape($tok)) { $hit = "$tok in $p" }
        }
    }
    Assert-Null $hit 'SAFETY: no network / credential tokens in DB-M24 scripts'
}

# --- runner -------------------------------------------------------------------------------

$scenarios = @(
    'Test-S01-ZeroAttempts', 'Test-S02-OneSuccess', 'Test-S03-OneFailure',
    'Test-S04-HundredAttemptsMixed', 'Test-S05-FirstAttemptSuccess', 'Test-S06-RetryThenSuccess',
    'Test-S07-MultipleRetriesThenSuccess', 'Test-S08-ModelEscalation', 'Test-S09-ProviderFailover',
    'Test-S10-HumanIntervention', 'Test-S11-ModelQualityFailure', 'Test-S12-ProviderOutage',
    'Test-S13-RateLimit', 'Test-S14-BuildFailure', 'Test-S15-TestFailure',
    'Test-S16-CostPerSuccessIncludesFailed', 'Test-S17-ActualCostPreferred',
    'Test-S18-EstimatedFallbackLabeled', 'Test-S19-MissingCostExcluded',
    'Test-S20-AverageDuration', 'Test-S21-MedianDuration', 'Test-S22-P95Duration',
    'Test-S23-TaskTypeFilter', 'Test-S24-ComplexityFilter', 'Test-S25-RiskFilter',
    'Test-S26-ReasoningLevelFilter', 'Test-S27-SevenDayRange', 'Test-S28-ThirtyDayRange',
    'Test-S29-CustomRange', 'Test-S30-LowConfidence', 'Test-S31-HighConfidence',
    'Test-S32-UnderlyingViaTwoProviders', 'Test-S33-NoAutomaticPolicyMutation',
    'Test-S34-SchemaV1RoundTrip'
)

$scenarioFails = New-Object System.Collections.Generic.List[string]
foreach ($name in $scenarios) {
    try { & $name } catch { $scenarioFails.Add("$name threw: $($_.Exception.Message)") }
}
Test-SafetyScan

$passed = $script:TestCount - $script:TestFails.Count
Write-Host "DB-M24 TEST SUMMARY: $passed passed, $($script:TestFails.Count) failed"
foreach ($f in $script:TestFails) { Write-Host "  FAIL: $f" }
foreach ($f in $scenarioFails) { Write-Host "  SCENARIO FAIL: $f" }
if ($script:TestFails.Count -eq 0 -and $scenarioFails.Count -eq 0) {
    Write-Host "DB-M24 SCENARIOS: $($scenarios.Count)/$($scenarios.Count) scenarios complete"
    exit 0
}
exit 1

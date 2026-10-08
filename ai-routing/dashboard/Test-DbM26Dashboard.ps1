# Test-DbM26Dashboard.ps1 -- DB-M26 AI usage/cost dashboard test suite (45 scenarios).
#
# Objective (the brief): one read-only operator-facing dashboard that answers the
# ten questions (spend, on what, verified results, cheap-but-retry routes,
# failure cost, escalation cost, true cost per verified success, savings,
# budgets approaching limits, provider failures driving waste), with every
# summary metric drillable to evidence and every recommendation-like analytic
# exposing its confidence + sample size.
#
# Every scenario runs entirely in-memory against deterministic synthetic
# AiAttemptRecord v1 (DB-M17) fixtures passed as parameters to the pure engine.
# NO AI API calls, NO provider calls, NO paid calls, NO network calls, NO
# credentials, NO writes to attempt history, routing configuration, pricing,
# budgets, provider health, the workbook, or the M12.x lifecycle UI. DB-M14/16/
# 17/19/20/21/22/23/24/25 implementations are consumed READ-ONLY and SHA-256
# verified byte-identical before/after the run.
#
# AUTO_EXECUTION_ENABLED = FALSE. Paid calls: 0. Network calls: 0.
#
# Exit code: 0 = all 45 scenarios + all regressions passed; 1 = any failure.
# Prints "DB-M26 TEST SUMMARY: <passed> passed, <failed> failed".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "DashboardData.ps1")    # engine (dot-sources contracts -> M25 -> M24/17/23/14 READ-ONLY; loads confidence bands)
. (Join-Path $PSScriptRoot "DashboardRender.ps1")  # HTML renderer (no writes except Export-DbM26DashboardHtml)

$script:Root = (Resolve-AiPerformanceRoot)

# The M12.x operator console stayed in Forge at W6/LaneA (src\DevBridge.UI is a Forge
# artifact, not AI implementation). Assertions about it are CROSS-TREE and the host
# root is resolved explicitly -- see ai-routing\AiHostRoot.ps1. When it is not
# declared those assertions report a SKIP instead of resolving a guessed path.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'AiHostRoot.ps1')
$script:ForgeRoot = Resolve-ForgeHostRoot
$script:HostSkips = New-Object System.Collections.Generic.List[string]

$script:NowUtc = '2026-08-30T12:00:00Z'   # deterministic reference for every window
$script:DashFiles = @(
    'ai-routing\dashboard\DashboardContracts.ps1',
    'ai-routing\dashboard\DashboardData.ps1',
    'ai-routing\dashboard\DashboardRender.ps1'
)

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
    fields read defensively by DB-M25/DB-M26; the DB-M17 record shape is untouched.
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

function New-DefReq {
    <#
    .SYNOPSIS
    A default ALL_TIME DashboardRequest v1 pinned to the deterministic NowUtc.
    #>
    param([string]$PresetWindow = 'ALL_TIME')
    return New-DbM26DashboardRequest -PresetWindow $PresetWindow -NowUtc $script:NowUtc
}

function Get-Dash {
    <#
    .SYNOPSIS
    Build a DashboardView v1 from fixture inputs. Everything is passed as
    parameters (pure engine; nothing is loaded from or written to any store).
    #>
    param(
        [AllowNull()][object[]]$Records = @(),
        [AllowNull()][object]$Request,
        [string]$NowUtc = $script:NowUtc,
        [AllowNull()][object]$BudgetPolicy,
        [AllowNull()][object[]]$ProviderHealthState,
        [string]$BudgetOverrideEvidence,
        [string]$BaselineProviderId,
        [string]$BaselineModelId,
        [string]$BaselineGatewayProviderId,
        [string]$BaselineType = 'CURRENT_DEFAULT',
        [string]$BaselineLabel,
        [string]$BaselineBasis = 'OBSERVED'
    )
    $prm = @{ Records = @($Records); NowUtc = $NowUtc; BaselineType = $BaselineType; BaselineBasis = $BaselineBasis }
    if ($null -ne $Request) { $prm.Request = $Request }
    if ($null -ne $BudgetPolicy) { $prm.BudgetPolicy = $BudgetPolicy }
    if ($null -ne $ProviderHealthState) { $prm.ProviderHealthState = @($ProviderHealthState) }
    if ($BudgetOverrideEvidence) { $prm.BudgetOverrideEvidence = $BudgetOverrideEvidence }
    if ($BaselineProviderId) { $prm.BaselineProviderId = $BaselineProviderId }
    if ($BaselineModelId) { $prm.BaselineModelId = $BaselineModelId }
    if ($BaselineGatewayProviderId) { $prm.BaselineGatewayProviderId = $BaselineGatewayProviderId }
    if ($BaselineLabel) { $prm.BaselineLabel = $BaselineLabel }
    return Get-DbM26DashboardView @prm
}

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

function New-FailPass {
    # 2-attempt chain: fail + verified pass. Returns records.
    param([string]$Tag, [double]$FailCost, [double]$SuccessCost,
          [string]$FailCategory = 'MODEL_QUALITY', [string]$ModelId = 'model-a',
          [string]$ProviderId = 'prov-a')
    $r1 = New-Att -TaskId $Tag -ChangeId $Tag -AttemptId ("$Tag-R0") -RetryNumber 0 `
        -Result 'FAILED' -FailureCategory $FailCategory -ActualCost $FailCost `
        -ProviderId $ProviderId -ModelId $ModelId
    $r2 = New-Att -TaskId $Tag -ChangeId $Tag -AttemptId ("$Tag-R1") -RetryNumber 1 `
        -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost $SuccessCost `
        -ProviderId $ProviderId -ModelId $ModelId
    return @($r1, $r2)
}

# --- frozen-file + workbook + M12.x UI evidence (captured BEFORE anything runs) ----------

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
    'ai-routing\performance\ModelPerformance.ps1',
    'ai-routing\quality-cost\AiQualityCostContracts.ps1',
    'ai-routing\quality-cost\QualityCost.ps1'
)

$script:ShaBefore = @{}
foreach ($rel in $script:FrozenFiles) { $script:ShaBefore[$rel] = Get-Sha256 (Join-Path $script:Root $rel) }

# Canonical Nexus workbook (outside the DevBridge project) -- DB-M26 performs ZERO writes.
$script:WorkbookPath = 'C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx'
$script:WorkbookShaBefore = Get-Sha256 $script:WorkbookPath

# M12.x-owned lifecycle UI source files (source only; obj/bin are build artifacts).
# The console is a Forge artifact and is reachable only through the declared host
# root. Before W6/LaneA this resolved inside $script:Root; after the move $script:Root
# is the AI material root, which has no console to enumerate.
$script:UiFiles = @()
if ($script:ForgeRoot) {
    $uiDir = Join-Path $script:ForgeRoot 'src\DevBridge.UI'
    if (Test-Path -LiteralPath $uiDir) {
        $script:UiFiles = @(Get-ChildItem $uiDir -Recurse -File -Include *.xaml,*.cs |
            Where-Object { $_.FullName -notmatch '\\obj\\|\\bin\\' } | ForEach-Object { $_.FullName } | Sort-Object)
    }
}
$script:UiShaBefore = @{}
foreach ($f in $script:UiFiles) { $script:UiShaBefore[$f] = Get-Sha256 $f }

# --- regression suites (child processes; read-only over the DB-M26 scope) -----------------

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
    $tmp = Join-Path $env:TEMP ("dbm26-reg-{0}-{1}.txt" -f $Name, (Get-Random))
    $exe = Join-Path $PSHOME 'powershell.exe'
    & $exe -NoProfile -ExecutionPolicy Bypass -File $full *> $tmp
    $exitCode = $LASTEXITCODE
    $text = ''
    if (Test-Path $tmp) { $text = Get-Content $tmp -Raw -Encoding UTF8 }
    $summary = [regex]::Match($text, 'TEST SUMMARY:\s*(\d+)\s+passed,\s*(\d+)\s+failed')
    $passed = 0; $failed = 0
    if ($summary.Success) {
        $passed = [int]$summary.Groups[1].Value; $failed = [int]$summary.Groups[2].Value
    } elseif ($text -match '(?m)^PASSED:\s*(\d+)\s*\r?\nFAILED:\s*(\d+)') {
        $passed = [int]$Matches[1]; $failed = [int]$Matches[2]
    } else {
        $passed = ([regex]::Matches($text, '(?m)^\s*(PASS:|\[PASS\])')).Count
        $failed = ([regex]::Matches($text, '(?m)^\s*(FAIL:|\[FAIL\])')).Count
    }
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    Assert-True ($exitCode -eq 0) "REG ${Name}: exit code 0 (got $exitCode)"
    Assert-True ($failed -eq 0) "REG ${Name}: zero failures (parsed $failed)"
    return @{ Name = $Name; ExitCode = $exitCode; Passed = $passed; Failed = $failed }
}

$script:RegressionResults = New-Object System.Collections.Generic.List[object]

# =====================================================================================
# S01 dashboard loads (view valid + HTML non-empty)
# =====================================================================================
function Test-S01-DashboardLoads {
    $recs = @(
        (New-Att -TaskId 'S1-T1' -ChangeId 'S1-T1' -AttemptId 'S1-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3),
        (New-Att -TaskId 'S1-T1' -ChangeId 'S1-T1' -AttemptId 'S1-T1-R1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 6),
        (New-Att -TaskId 'S1-T1' -ChangeId 'S1-T1' -AttemptId 'S1-T1-R2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $view = Get-Dash -Records $recs
    $vr = Test-DbM26DashboardView $view
    Assert-True $vr.Valid ("S01: view valid (" + ($vr.Errors -join '; ') + ")")
    $html = ConvertTo-DbM26Html -View $view
    Assert-NotNull $html 'S01: html non-null'
    Assert-True ($html.Length -gt 1000) 'S01: html substantial'
    Assert-Contains $html 'Total AI Spend' 'S01: html contains spend card'
    Assert-Contains $html 'READ-ONLY ANALYTICS' 'S01: html marks read-only analytics'
}

# =====================================================================================
# S02 empty data state
# =====================================================================================
function Test-S02-EmptyData {
    $view = Get-Dash -Records @()
    Assert-NotNull $view 'S02: view built from empty records'
    Assert-True ((Test-DbM26DashboardView $view).Valid) 'S02: empty view structurally valid'
    Assert-Near $view.SummaryCards.TotalAiSpend 0 'S02: zero total spend'
    Assert-True ($view.SummaryCards.VerifiedSuccessfulTasks -eq 0) 'S02: zero verified tasks'
    Assert-Near $view.SummaryCards.FailedAttemptCost 0 'S02: zero failed cost'
    Assert-True (@($view.AttemptHistory).Count -eq 0) 'S02: no history rows'
    Assert-True (@($view.ChainView).Count -eq 0) 'S02: no chains'
    Assert-Contains (($view.Warnings -join ' ')) 'No attempts match' 'S02: warning labels empty state'
    $html = ConvertTo-DbM26Html -View $view
    Assert-True ($html.Length -gt 500) 'S02: empty dashboard still renders'
}

# =====================================================================================
# S03 one attempt
# =====================================================================================
function Test-S03-OneAttempt {
    $recs = @( (New-Att -TaskId 'S3-T1' -ChangeId 'S3-T1' -AttemptId 'S3-T1-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10) )
    $view = Get-Dash -Records $recs
    Assert-Near $view.SummaryCards.TotalAiSpend 10 'S03: total spend 10'
    Assert-Near $view.SummaryCards.ActualSpend 10 'S03: actual spend 10'
    Assert-Near $view.SummaryCards.CostPerVerifiedSuccess 10 'S03: cost per verified success 10'
    Assert-True ($view.SummaryCards.VerifiedSuccessfulTasks -eq 1) 'S03: one verified task'
    Assert-True (@($view.AttemptHistory).Count -eq 1) 'S03: one history row'
}

# =====================================================================================
# S04 fail + pass chain
# =====================================================================================
function Test-S04-FailPassChain {
    $recs = New-FailPass -Tag 'S4-T1' -FailCost 3 -SuccessCost 10
    $view = Get-Dash -Records $recs
    Assert-Near $view.SummaryCards.TotalAiSpend 13 'S04: total 3+10'
    Assert-True ($view.SummaryCards.VerifiedSuccessfulTasks -eq 1) 'S04: one verified task'
    Assert-Near $view.SummaryCards.FailedAttemptCost 3 'S04: failed cost 3'
    Assert-True (@($view.ChainView).Count -eq 1) 'S04: one chain'
    $g = @($view.QualityAdjustedCostView)[0]
    Assert-Near $g.ObservedCostPerVerifiedSuccess 13 'S04: chain cost per success = 13 (never 10)'
}

# =====================================================================================
# S05 cumulative cost correct (fail + fail + pass = 19)
# =====================================================================================
function Test-S05-CumulativeCost {
    $recs = @(
        (New-Att -TaskId 'S5-T1' -ChangeId 'S5-T1' -AttemptId 'S5-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3),
        (New-Att -TaskId 'S5-T1' -ChangeId 'S5-T1' -AttemptId 'S5-T1-R1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 6),
        (New-Att -TaskId 'S5-T1' -ChangeId 'S5-T1' -AttemptId 'S5-T1-R2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $view = Get-Dash -Records $recs
    $ch = @($view.ChainView)[0]
    Assert-Near $ch.TotalCost 19 'S05: chain total 19'
    $att = @($ch.Attempts)
    Assert-True ($att.Count -eq 3) 'S05: three attempt rows'
    Assert-Near $att[0].CumulativeCost 3 'S05: running 3'
    Assert-Near $att[1].CumulativeCost 9 'S05: running 9'
    Assert-Near $att[2].CumulativeCost 19 'S05: running 19'
    Assert-Near $att[2].Cost 10 'S05: final attempt cost 10'
    Assert-Near $view.SummaryCards.TotalAiSpend 19 'S05: total spend 19'
}

# =====================================================================================
# S06 actual vs estimated spend displayed correctly
# =====================================================================================
function Test-S06-ActualVsEstimated {
    $recs = @(
        (New-Att -TaskId 'S6-T1' -ChangeId 'S6-T1' -AttemptId 'S6-T1-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10),
        (New-Att -TaskId 'S6-T2' -ChangeId 'S6-T2' -AttemptId 'S6-T2-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -EstimatedCost 5)
    )
    $view = Get-Dash -Records $recs
    Assert-Near $view.SummaryCards.TotalAiSpend 15 'S06: total = actual + estimated pending'
    Assert-Near $view.SummaryCards.ActualSpend 10 'S06: actual 10'
    Assert-Near $view.SummaryCards.EstimatedPendingSpend 5 'S06: estimated pending 5'
    Assert-Contains (($view.Warnings -join ' ')) 'Estimated-pending' 'S06: estimated pending labelled'
    # verified-success cost excludes estimated (fallback off): only the actual chain contributes
    $g = @($view.QualityAdjustedCostView)[0]
    Assert-Near $g.ObservedCostPerVerifiedSuccess 10 'S06: verified-success cost from actual evidence only'
    $h = @($view.AttemptHistory | Where-Object { $_.Cost -eq 5 })
    Assert-True ($h.Count -eq 1) 'S06: estimated attempt still in history'
}

# =====================================================================================
# S07 verified success semantics respected (contradicted never success)
# =====================================================================================
function Test-S07-VerifiedSuccessSemantics {
    $recs = @( (New-Att -TaskId 'S7-T1' -ChangeId 'S7-T1' -AttemptId 'S7-T1-R0' -Result 'SUCCESS' -VerificationResult 'FAILED' -ActualCost 10) )
    $view = Get-Dash -Records $recs
    Assert-True ($view.SummaryCards.VerifiedSuccessfulTasks -eq 0) 'S07: contradicted model PASS is not success'
    Assert-Null $view.SummaryCards.CostPerVerifiedSuccess 'S07: no cost-per-success without verified success'
    $vs = @($view.VerifiedSuccessView)[0]
    Assert-True (-not $vs.ImplementationVerified) 'S07: implementation not verified'
    Assert-Contains ($vs.Outcome) 'CONTRADICTED' 'S07: outcome labelled contradicted'
    $g = @($view.QualityAdjustedCostView)[0]
    Assert-True ($g.SampleCount -ge 1) 'S07: chain still in sample'
    Assert-True ($g.ObservedCostPerVerifiedSuccess -eq $null) 'S07: observed cost-per-success null (no verified success)'
}

# =====================================================================================
# S08 failed attempt cost shown
# =====================================================================================
function Test-S08-FailedAttemptCost {
    $recs = New-FailPass -Tag 'S8-T1' -FailCost 3 -SuccessCost 10
    $view = Get-Dash -Records $recs
    Assert-Near $view.SummaryCards.FailedAttemptCost 3 'S08: failed cost card 3'
    Assert-Near $view.FailedCostView.ModelQuality 3 'S08: failed-cost view buckets model-quality 3'
    Assert-Near $view.SummaryCards.TotalAiSpend 13 'S08: failed + success total 13'
}

# =====================================================================================
# S09 provider failure separated
# =====================================================================================
function Test-S09-ProviderFailureSeparated {
    $recs = @(
        (New-Att -TaskId 'S9-T1' -ChangeId 'S9-T1' -AttemptId 'S9-T1-R0' -Result 'FAILED' -FailureCategory 'PROVIDER_AVAILABILITY' -ActualCost 5),
        (New-Att -TaskId 'S9-T1' -ChangeId 'S9-T1' -AttemptId 'S9-T1-R1' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $view = Get-Dash -Records $recs
    Assert-Near $view.FailedCostView.ProviderFailures 5 'S09: provider-failure bucket 5'
    Assert-Near $view.FailedCostView.ModelQuality 0 'S09: model-quality bucket 0'
    Assert-Near $view.SummaryCards.FailedAttemptCost 5 'S09: failed cost card 5'
}

# =====================================================================================
# S10 model-quality failure separated
# =====================================================================================
function Test-S10-ModelQualityFailureSeparated {
    $recs = @(
        (New-Att -TaskId 'S10-T1' -ChangeId 'S10-T1' -AttemptId 'S10-T1-R0' -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 4),
        (New-Att -TaskId 'S10-T1' -ChangeId 'S10-T1' -AttemptId 'S10-T1-R1' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $view = Get-Dash -Records $recs
    Assert-Near $view.FailedCostView.ModelQuality 4 'S10: model-quality bucket 4'
    Assert-Near $view.FailedCostView.ProviderFailures 0 'S10: provider-failure bucket 0'
    Assert-Near $view.FailedCostView.RateLimit 0 'S10: rate-limit bucket 0'
    Assert-True (($view.FailedCostView.ModelQuality + $view.FailedCostView.ProviderFailures + $view.FailedCostView.RateLimit + $view.FailedCostView.Authentication + $view.FailedCostView.ToolFailure + $view.FailedCostView.BuildTest + $view.FailedCostView.ContextFailure + $view.FailedCostView.BudgetFailure + $view.FailedCostView.ValidationFailure + $view.FailedCostView.Verification + $view.FailedCostView.ClaudeFixReview + $view.FailedCostView.Other) -eq 4) 'S10: failed-cost buckets sum to the failed spend'
}

# =====================================================================================
# S11 escalation cost shown
# =====================================================================================
function Test-S11-EscalationCost {
    $recs = @(
        (New-Att -TaskId 'S11-T1' -ChangeId 'S11-T1' -AttemptId 'S11-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3 -EscalatedToAttemptId 'S11-T1-R1'),
        (New-Att -TaskId 'S11-T1' -ChangeId 'S11-T1' -AttemptId 'S11-T1-R1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 6 -EscalatedFromAttemptId 'S11-T1-R0'),
        (New-Att -TaskId 'S11-T1' -ChangeId 'S11-T1' -AttemptId 'S11-T1-R2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $view = Get-Dash -Records $recs
    Assert-Near $view.SummaryCards.EscalationCost 9 'S11: escalation cost card 3+6'
    Assert-Near $view.SummaryCards.TotalAiSpend 19 'S11: escalated chain total 19'
    # drilldown: the two escalated attempts carry their escalation evidence in the chain
    $escRows = @(@($view.ChainView)[0].Attempts | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Escalation) })
    Assert-True ($escRows.Count -eq 2) 'S11: both escalated attempts show evidence in the chain drilldown'
}

# =====================================================================================
# S12 correction cost shown
# =====================================================================================
function Test-S12-CorrectionCost {
    $recs = @(
        (New-Att -TaskId 'S12-T1' -ChangeId 'S12-T1' -AttemptId 'S12-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3),
        (New-Att -TaskId 'S12-T1' -ChangeId 'S12-T1' -AttemptId 'S12-T1-R1' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 6),
        (New-Att -TaskId 'S12-T1' -ChangeId 'S12-T1' -AttemptId 'S12-T1-R2' -RetryNumber 2 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $view = Get-Dash -Records $recs
    Assert-Near $view.SummaryCards.CorrectionCost 19 'S12: correction cost = full multi-attempt chain 19'
    # single-attempt success has no correction cost
    $recs2 = @( (New-Att -TaskId 'S12-T2' -ChangeId 'S12-T2' -AttemptId 'S12-T2-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 7) )
    $view2 = Get-Dash -Records $recs2
    Assert-Near $view2.SummaryCards.CorrectionCost 0 'S12: single-attempt chain correction cost 0'
}

# =====================================================================================
# S13 first-attempt success shown
# =====================================================================================
function Test-S13-FirstAttemptSuccess {
    $recs = @()
    $recs += (New-Att -TaskId 'S13-A' -ChangeId 'S13-A' -AttemptId 'S13-A-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 5)
    $recs += (New-FailPass -Tag 'S13-B' -FailCost 3 -SuccessCost 10)
    $view = Get-Dash -Records $recs
    Assert-Rate $view.SummaryCards.FirstAttemptSuccessRate 0.5 'S13: first-attempt success rate 0.5 (one of two first-attempt verified)'
    $mp = @($view.ModelPerformanceView)[0]
    Assert-Rate $mp.FirstAttemptSuccessRate 0.5 'S13: model performance first-attempt rate 0.5'
    $g = @($view.QualityAdjustedCostView)[0]
    Assert-True ($g.SampleCount -eq 2) 'S13: sample 2'
}

# =====================================================================================
# S14 cost per verified success shown
# =====================================================================================
function Test-S14-CostPerVerifiedSuccess {
    $recs = New-FailPass -Tag 'S14-T1' -FailCost 3 -SuccessCost 10
    $view = Get-Dash -Records $recs
    Assert-Near $view.SummaryCards.CostPerVerifiedSuccess 13 'S14: cost per verified success 13 (3+10)'
    $g = @($view.QualityAdjustedCostView)[0]
    Assert-Near $g.ObservedCostPerVerifiedSuccess 13 'S14: group observed cost per success 13'
}

# =====================================================================================
# S15 savings baseline shown (never a savings % without the baseline)
# =====================================================================================
function Test-S15-SavingsBaselineShown {
    # baseline route model-b: fail 3 + pass 10 -> cost per success 13
    # candidate route model-a: pass 5          -> cost per success 5
    $recs = @()
    $recs += (New-FailPass -Tag 'S15-BASE' -FailCost 3 -SuccessCost 10 -ModelId 'model-b')
    $recs += (New-Att -TaskId 'S15-CAND' -ChangeId 'S15-CAND' -AttemptId 'S15-CAND-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 5 -ModelId 'model-a')
    $view = Get-Dash -Records $recs -BaselineProviderId 'prov-a' -BaselineModelId 'model-b' -BaselineType 'SPECIFIC_MODEL_ROUTE' -BaselineLabel 'model-b current default' -BaselineBasis 'OBSERVED'
    $sav = @($view.SavingsView | Where-Object { $_.CandidateRoute -eq 'prov-a|model-a|(none)' } | Select-Object -First 1)
    Assert-True ($sav.Count -eq 1) 'S15: savings row present for candidate route'
    $row = $sav[0]
    Assert-NotNull $row 'S15: savings row non-null'
    Assert-True ($row.BaselineRoute -eq 'prov-a|model-b|(none)') 'S15: baseline route shown'
    Assert-True ($row.BaselineType -eq 'SPECIFIC_MODEL_ROUTE') 'S15: baseline type shown'
    Assert-True ($row.BaselineBasis -eq 'OBSERVED') 'S15: baseline basis shown'
    Assert-Near $row.BaselineCostPerVerifiedSuccess 13 'S15: baseline cost per success 13'
    Assert-Near $row.ObservedCostPerVerifiedSuccess 5 'S15: candidate cost per success 5'
    Assert-Near $row.AbsoluteSavings 8 'S15: absolute savings 13-5'
    Assert-Rate $row.SavingsPercent 61.5385 'S15: savings percent 8/13'
    Assert-True ($row.SampleSize -ge 1) 'S15: sample size present'
    Assert-Contains ($row.Warnings -join ' ') 'baseline' 'S15: baseline provenance in warnings'
}

# =====================================================================================
# S16 savings confidence shown
# =====================================================================================
function Test-S16-SavingsConfidence {
    # same fixture as S15: baseline 2 samples / candidate 1 sample -> confidence INSUFFICIENT (lower of both)
    $recs = @()
    $recs += (New-FailPass -Tag 'S16-BASE' -FailCost 3 -SuccessCost 10 -ModelId 'model-b')
    $recs += (New-Att -TaskId 'S16-CAND' -ChangeId 'S16-CAND' -AttemptId 'S16-CAND-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 5 -ModelId 'model-a')
    $view = Get-Dash -Records $recs -BaselineProviderId 'prov-a' -BaselineModelId 'model-b' -BaselineType 'SPECIFIC_MODEL_ROUTE' -BaselineLabel 'model-b' -BaselineBasis 'OBSERVED'
    $row = @($view.SavingsView | Select-Object -First 1)
    Assert-True ($row.Count -eq 1) 'S16: savings row present'
    $conf = [string]$row[0].Confidence
    Assert-True ($conf -in @('INSUFFICIENT', 'LOW', 'MODERATE', 'HIGH')) "S16: confidence is a valid DB-M24 level (got '$conf')"
    Assert-True ([int]$row[0].SampleSize -ge 1) 'S16: savings sample size present'
    $cs = @($view.ConfidenceSummary | Where-Object { $_.Analytic -like 'Savings:*' })
    Assert-True ($cs.Count -eq 1) 'S16: savings confidence surfaced in confidence summary'
    Assert-True ([string]$cs[0].ConfidenceLevel -in @('INSUFFICIENT', 'LOW', 'MODERATE', 'HIGH')) 'S16: summary confidence valid'
}

# =====================================================================================
# S17 insufficient evidence labelled
# =====================================================================================
function Test-S17-InsufficientEvidenceLabelled {
    $recs = @( (New-Att -TaskId 'S17-T1' -ChangeId 'S17-T1' -AttemptId 'S17-T1-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10) )
    $view = Get-Dash -Records $recs
    $g = @($view.QualityAdjustedCostView)[0]
    Assert-True ($g.ConfidenceLevel -eq 'INSUFFICIENT') 'S17: single-sample group confidence INSUFFICIENT'
    Assert-True ($g.SampleCount -eq 1) 'S17: sample size 1 shown'
    $mp = @($view.ModelPerformanceView)[0]
    Assert-True ($mp.Confidence -eq 'INSUFFICIENT') 'S17: model performance confidence INSUFFICIENT'
    Assert-True ($mp.Sample -eq 1) 'S17: model performance sample 1'
    $cs = @($view.ConfidenceSummary)
    Assert-True ($cs.Count -ge 1) 'S17: confidence summary populated'
    Assert-True ([string]$cs[0].ConfidenceLevel -eq 'INSUFFICIENT') 'S17: confidence summary labels INSUFFICIENT'
    $html = ConvertTo-DbM26Html -View $view
    Assert-Contains $html 'INSUFFICIENT' 'S17: html shows the INSUFFICIENT badge'
}

# =====================================================================================
# S18 task-type filter
# =====================================================================================
function Test-S18-TaskTypeFilter {
    $recs = @(
        (New-Att -TaskId 'S18-A' -ChangeId 'S18-A' -AttemptId 'S18-A-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -TaskType 'IMPLEMENTATION'),
        (New-Att -TaskId 'S18-B' -ChangeId 'S18-B' -AttemptId 'S18-B-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -TaskType 'REVIEW')
    )
    $req = New-DbM26DashboardRequest -PresetWindow 'ALL_TIME' -NowUtc $script:NowUtc -TaskType 'IMPLEMENTATION'
    $view = Get-Dash -Records $recs -Request $req
    Assert-Near $view.SummaryCards.TotalAiSpend 10 'S18: task-type filter isolates implementation spend'
    Assert-True (@($view.AttemptHistory).Count -eq 1) 'S18: one attempt in filtered history'
    Assert-Near $view.SummaryCards.ActualSpend 10 'S18: filtered actual spend 10'
}

# =====================================================================================
# S19 provider filter
# =====================================================================================
function Test-S19-ProviderFilter {
    $recs = @(
        (New-Att -TaskId 'S19-A' -ChangeId 'S19-A' -AttemptId 'S19-A-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ProviderId 'prov-a'),
        (New-Att -TaskId 'S19-B' -ChangeId 'S19-B' -AttemptId 'S19-B-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -ProviderId 'prov-b')
    )
    $req = New-DbM26DashboardRequest -PresetWindow 'ALL_TIME' -NowUtc $script:NowUtc -ProviderId 'prov-b'
    $view = Get-Dash -Records $recs -Request $req
    Assert-Near $view.SummaryCards.TotalAiSpend 20 'S19: provider filter isolates prov-b spend'
    Assert-True (@($view.AttemptHistory).Count -eq 1) 'S19: one attempt in filtered history'
}

# =====================================================================================
# S20 model filter
# =====================================================================================
function Test-S20-ModelFilter {
    $recs = @(
        (New-Att -TaskId 'S20-A' -ChangeId 'S20-A' -AttemptId 'S20-A-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ModelId 'model-a'),
        (New-Att -TaskId 'S20-B' -ChangeId 'S20-B' -AttemptId 'S20-B-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -ModelId 'model-b')
    )
    $req = New-DbM26DashboardRequest -PresetWindow 'ALL_TIME' -NowUtc $script:NowUtc -ModelId 'model-b'
    $view = Get-Dash -Records $recs -Request $req
    Assert-Near $view.SummaryCards.TotalAiSpend 20 'S20: model filter isolates model-b spend'
}

# =====================================================================================
# S21 reasoning filter
# =====================================================================================
function Test-S21-ReasoningFilter {
    $recs = @(
        (New-Att -TaskId 'S21-A' -ChangeId 'S21-A' -AttemptId 'S21-A-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ReasoningLevel 'MEDIUM'),
        (New-Att -TaskId 'S21-B' -ChangeId 'S21-B' -AttemptId 'S21-B-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -ReasoningLevel 'HIGH')
    )
    $req = New-DbM26DashboardRequest -PresetWindow 'ALL_TIME' -NowUtc $script:NowUtc -ReasoningLevel 'HIGH'
    $view = Get-Dash -Records $recs -Request $req
    Assert-Near $view.SummaryCards.TotalAiSpend 20 'S21: reasoning filter isolates HIGH spend'
}

# =====================================================================================
# S22 date filter (deterministic CUSTOM window)
# =====================================================================================
function Test-S22-DateFilter {
    $recs = @(
        (New-Att -TaskId 'S22-A' -ChangeId 'S22-A' -AttemptId 'S22-A-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -StartedAtUtc '2026-08-25T10:00:00Z' -EndedAtUtc '2026-08-25T10:00:30Z'),
        (New-Att -TaskId 'S22-B' -ChangeId 'S22-B' -AttemptId 'S22-B-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 20 -StartedAtUtc '2026-08-10T10:00:00Z' -EndedAtUtc '2026-08-10T10:00:30Z')
    )
    $req = New-DbM26DashboardRequest -PresetWindow 'CUSTOM' -FromUtc '2026-08-20T00:00:00Z' -ToUtc '2026-08-30T00:00:00Z' -NowUtc $script:NowUtc
    $view = Get-Dash -Records $recs -Request $req
    Assert-Near $view.SummaryCards.TotalAiSpend 10 'S22: date window keeps only the in-window attempt'
    Assert-True (@($view.AttemptHistory).Count -eq 1) 'S22: one attempt in windowed history'
    Assert-True ($view.PresetWindow -eq 'CUSTOM') 'S22: preset labelled CUSTOM'
}

# =====================================================================================
# S23 direct vs gateway separated (same model, different route identity)
# =====================================================================================
function Test-S23-DirectVsGatewaySeparated {
    $recs = @(
        (New-Att -TaskId 'S23-A' -ChangeId 'S23-A' -AttemptId 'S23-A-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ProviderId 'prov-a' -ModelId 'model-a' -UnderlyingModelId 'um-a'),
        (New-Att -TaskId 'S23-B' -ChangeId 'S23-B' -AttemptId 'S23-B-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 12 -ProviderId 'prov-a' -ModelId 'model-a' -UnderlyingModelId 'um-a' -GatewayProviderId 'openrouter')
    )
    $view = Get-Dash -Records $recs
    $keys = @($view.QualityAdjustedCostView | ForEach-Object { $_.GroupKey })
    Assert-True ($keys.Count -eq 2) 'S23: direct and gateway kept as separate groups'
    Assert-Contains ($keys -join '|') 'prov-a|model-a|(none)' 'S23: direct route identity present'
    Assert-Contains ($keys -join '|') 'prov-a|model-a|openrouter' 'S23: gateway route identity present'
    $local = @($view.LocalOpenRouterView)
    Assert-True ($local.Count -eq 2) 'S23: local/openrouter view keeps both rows'
}

# =====================================================================================
# S24 underlying model preserved (direct vs OpenRouter share the underlying model)
# =====================================================================================
function Test-S24-UnderlyingModelPreserved {
    $recs = @(
        (New-Att -TaskId 'S24-A' -ChangeId 'S24-A' -AttemptId 'S24-A-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10 -ProviderId 'prov-a' -ModelId 'model-a' -UnderlyingModelId 'claude-opus' -GatewayProviderId 'openrouter'),
        (New-Att -TaskId 'S24-B' -ChangeId 'S24-B' -AttemptId 'S24-B-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 11 -ProviderId 'prov-a' -ModelId 'model-a' -UnderlyingModelId 'claude-opus')
    )
    $view = Get-Dash -Records $recs
    $local = @($view.LocalOpenRouterView)
    Assert-True ($local.Count -eq 2) 'S24: two route rows'
    foreach ($row in $local) { Assert-True ($row.UnderlyingModel -eq 'claude-opus') 'S24: underlying model preserved on every row' }
    $gw = @($local | Where-Object { $_.Gateway -eq 'openrouter' })
    $direct = @($local | Where-Object { $_.Gateway -eq '(none)' })
    Assert-True ($gw.Count -eq 1 -and $direct.Count -eq 1) 'S24: one direct + one gateway row for the same underlying model'
}

# =====================================================================================
# S25 local cost unknown handled (LOCAL is never invented as FREE)
# =====================================================================================
function Test-S25-LocalCostUnknown {
    $recs = @(
        (New-Att -TaskId 'S25-T1' -ChangeId 'S25-T1' -AttemptId 'S25-T1-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ProviderId 'local-prov' -ModelId 'local-model' -UnderlyingModelId 'llama' -LocalOrRemote 'LOCAL')
    )
    $view = Get-Dash -Records $recs
    $row = @($view.LocalOpenRouterView | Where-Object { $_.LocalOrRemote -eq 'LOCAL' } | Select-Object -First 1)
    Assert-True ($row.Count -eq 1) 'S25: local route row present'
    Assert-True ($row[0].LocalCostStatus -eq 'LOCAL_COST_UNKNOWN') 'S25: local cost status is LOCAL_COST_UNKNOWN (never FREE)'
    Assert-True ($row[0].TotalCost -eq 0) 'S25: no invented cost'
    Assert-Near $view.SummaryCards.TotalAiSpend 0 'S25: no invented cost on the cards'
    $html = ConvertTo-DbM26Html -View $view
    Assert-Contains $html 'LOCAL_COST_UNKNOWN' 'S25: html labels the local route LOCAL_COST_UNKNOWN (never FREE)'
}

# =====================================================================================
# S26 budget warning displayed
# =====================================================================================
function Test-S26-BudgetWarning {
    $policy = New-BudgetPolicy -PolicyId 'dbm26-budget-warning' -Name 'WARNING-POLICY' -Enabled $true -Currency 'INR' `
        -MonthlyLimit 100 -WarnAtPercent 80 -BlockAtPercent 100 -IncludeEstimatedPendingCost $true `
        -UnknownCostPolicy 'BLOCK' -AllowManualOverride $false -RequireReasonForOverride $true -AccountingUtcOffsetHours 0
    $recs = @( (New-Att -TaskId 'S26-T1' -ChangeId 'S26-T1' -AttemptId 'S26-T1-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 90) )
    $req = New-DbM26DashboardRequest -PresetWindow 'THIS_MONTH' -NowUtc $script:NowUtc
    $view = Get-Dash -Records $recs -Request $req -BudgetPolicy $policy
    Assert-True ($view.BudgetView.Status -eq 'WARNING') 'S26: budget status WARNING at 90/100 >= 80%'
    Assert-True ($view.SummaryCards.BudgetUsedPercent -gt 80) 'S26: budget used % card reflects warning'
    $html = ConvertTo-DbM26Html -View $view
    Assert-Contains $html 'WARNING' 'S26: html shows the budget warning badge'
}

# =====================================================================================
# S27 budget blocked displayed
# =====================================================================================
function Test-S27-BudgetBlocked {
    $policy = New-BudgetPolicy -PolicyId 'dbm26-budget-block' -Name 'BLOCK-POLICY' -Enabled $true -Currency 'INR' `
        -MonthlyLimit 100 -WarnAtPercent 80 -BlockAtPercent 100 -IncludeEstimatedPendingCost $true `
        -UnknownCostPolicy 'BLOCK' -AllowManualOverride $false -RequireReasonForOverride $true -AccountingUtcOffsetHours 0
    $recs = @( (New-Att -TaskId 'S27-T1' -ChangeId 'S27-T1' -AttemptId 'S27-T1-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 120) )
    $req = New-DbM26DashboardRequest -PresetWindow 'THIS_MONTH' -NowUtc $script:NowUtc
    $view = Get-Dash -Records $recs -Request $req -BudgetPolicy $policy
    Assert-True ($view.BudgetView.Status -eq 'BLOCKED') 'S27: budget status BLOCKED at 120/100 >= 100%'
    Assert-True ($view.SummaryCards.BudgetUsedPercent -ge 100) 'S27: budget used % card >= 100'
    $html = ConvertTo-DbM26Html -View $view
    Assert-Contains $html 'BLOCKED' 'S27: html shows the budget blocked badge'
}

# =====================================================================================
# S28 provider health displayed
# =====================================================================================
function Test-S28-ProviderHealthDisplayed {
    $health = @(
        [pscustomobject]@{ ProviderId = 'prov-a'; RouteId = 'prov-a|model-a'; HealthState = 'AVAILABLE'; CircuitState = 'CLOSED'; ObservedAtUtc = '2026-08-30T10:00:00Z'; FreshEvidenceCount = 3; StaleEvidenceCount = 0; PolicyId = 'pol-1' },
        [pscustomobject]@{ ProviderId = 'prov-b'; RouteId = 'prov-b|model-b'; HealthState = 'UNAVAILABLE'; CircuitState = 'OPEN'; RetryAfterUtc = '2026-08-30T11:00:00Z'; ObservedAtUtc = '2026-08-30T09:00:00Z'; FreshEvidenceCount = 1; StaleEvidenceCount = 2; PolicyId = 'pol-1' }
    )
    $view = Get-Dash -Records @() -ProviderHealthState $health
    $rows = @($view.ProviderHealthView)
    Assert-True ($rows.Count -eq 2) 'S28: two provider-health rows'
    Assert-True ($rows[0].Health -eq 'AVAILABLE') 'S28: healthy provider health shown'
    Assert-True ($rows[1].Health -eq 'UNAVAILABLE') 'S28: unhealthy provider health shown'
    Assert-True ($view.SummaryCards.HealthyProviders -eq 1) 'S28: one healthy provider counted'
    Assert-True ($view.SummaryCards.UnavailableOrRateLimitedRoutes -eq 1) 'S28: one unavailable/rate-limited route counted'
    $html = ConvertTo-DbM26Html -View $view
    Assert-Contains $html 'UNAVAILABLE' 'S28: html renders provider health'
}

# =====================================================================================
# S29 circuit state displayed
# =====================================================================================
function Test-S29-CircuitStateDisplayed {
    $health = @(
        [pscustomobject]@{ ProviderId = 'prov-a'; RouteId = 'prov-a|model-a'; HealthState = 'AVAILABLE'; CircuitState = 'CLOSED'; ObservedAtUtc = '2026-08-30T10:00:00Z'; FreshEvidenceCount = 3; StaleEvidenceCount = 0 },
        [pscustomobject]@{ ProviderId = 'prov-b'; RouteId = 'prov-b|model-b'; HealthState = 'RATE_LIMITED'; CircuitState = 'HALF_OPEN'; RetryAfterUtc = '2026-08-30T11:00:00Z'; ObservedAtUtc = '2026-08-30T09:00:00Z'; FreshEvidenceCount = 1; StaleEvidenceCount = 2 }
    )
    $view = Get-Dash -Records @() -ProviderHealthState $health
    $rows = @($view.ProviderHealthView)
    Assert-True ($rows[0].CircuitState -eq 'CLOSED') 'S29: closed circuit shown'
    Assert-True ($rows[1].CircuitState -eq 'HALF_OPEN') 'S29: half-open circuit shown'
    Assert-True ($rows[1].RetryAfter -ne '') 'S29: retry-after evidence shown'
    Assert-True ($view.SummaryCards.UnavailableOrRateLimitedRoutes -eq 1) 'S29: RATE_LIMITED + HALF_OPEN counted unavailable'
    $html = ConvertTo-DbM26Html -View $view
    Assert-Contains $html 'HALF_OPEN' 'S29: html renders circuit state'
}

# =====================================================================================
# S30 attempt history preserved
# =====================================================================================
function Test-S30-AttemptHistoryPreserved {
    $recs = @(
        (New-Att -TaskId 'S30-T1' -ChangeId 'S30-T1' -AttemptId 'S30-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3),
        (New-Att -TaskId 'S30-T1' -ChangeId 'S30-T1' -AttemptId 'S30-T1-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $view = Get-Dash -Records $recs
    $h = @($view.AttemptHistory)
    Assert-True ($h.Count -eq 2) 'S30: both attempts in history'
    Assert-Contains ($h[0].AttemptId + '|' + $h[0].Result) 'FAILED' 'S30: failed attempt row preserved'
    Assert-True ($h[1].AttemptId -eq 'S30-T1-R1') 'S30: success attempt row present'
    Assert-True ($h[0].TimestampUtc -ne '') 'S30: timestamps present'
}

# =====================================================================================
# S31 chain drilldown works
# =====================================================================================
function Test-S31-ChainDrilldown {
    $recs = @(
        (New-Att -TaskId 'S31-T1' -ChangeId 'S31-T1' -AttemptId 'S31-T1-R0' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3),
        (New-Att -TaskId 'S31-T1' -ChangeId 'S31-T1' -AttemptId 'S31-T1-R1' -RetryNumber 1 -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $view = Get-Dash -Records $recs
    $ch = @($view.ChainView)[0]
    Assert-True ($ch.ChangeId -eq 'S31-T1') 'S31: chain keyed by change'
    Assert-True ($ch.AttemptCount -eq 2) 'S31: chain attempt count 2'
    Assert-True ($ch.TerminalOutcome -eq 'SUCCESS') 'S31: terminal outcome SUCCESS'
    Assert-True (@($ch.Attempts).Count -eq 2) 'S31: per-attempt drilldown rows'
    Assert-Near $ch.TotalCost 13 'S31: chain total 13'
    $html = ConvertTo-DbM26Html -View $view
    Assert-Contains $html 'Chains' 'S31: html has a chains section'
}

# =====================================================================================
# S32 failed attempts not hidden after later success
# =====================================================================================
function Test-S32-FailedAttemptsNotHidden {
    $recs = New-FailPass -Tag 'S32-T1' -FailCost 6 -SuccessCost 10
    $view = Get-Dash -Records $recs
    $h = @($view.AttemptHistory | Where-Object { $_.Result -eq 'FAILED' })
    Assert-True ($h.Count -eq 1) 'S32: failed attempt still visible after success'
    Assert-Near $h[0].Cost 6 'S32: failed attempt cost shown'
    # the drilldown chain view also carries the failed attempt
    $att = @(@($view.ChainView)[0].Attempts | Where-Object { $_.Result -eq 'FAILED' })
    Assert-True ($att.Count -eq 1) 'S32: failed attempt visible in chain drilldown'
}

# =====================================================================================
# S33 no write actions exist
# =====================================================================================
function Test-S33-NoWriteActions {
    $forbidden = @('Set-Content', 'Out-File', 'Add-Content', 'New-Item', 'Remove-Item',
                   'Copy-Item', 'Move-Item', 'ConvertTo-Json', 'Export-Csv',
                   'NEXUS_DEVELOPMENT_CONTROL', '.xlsx')
    foreach ($rel in $script:DashFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        foreach ($tok in $forbidden) {
            Assert-NotContains $text $tok "S33: $rel has no '$tok' (no store writes)"
        }
    }
    $recs = @( (New-Att -TaskId 'S33-T1' -ChangeId 'S33-T1' -AttemptId 'S33-T1-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10) )
    $view = Get-Dash -Records $recs
    Assert-True (-not $view.ReadOnlyGuard.HasWriteActions) 'S33: view declares HasWriteActions=false'
    Assert-True (-not $view.ReadOnlyGuard.AutoExecutionEnabled) 'S33: view declares AutoExecutionEnabled=false'
    $html = ConvertTo-DbM26Html -View $view
    Assert-NotContains $html '<form' 'S33: html has no forms (no submission actions)'
    Assert-NotContains $html 'input type="submit"' 'S33: html has no submit controls'
}

# =====================================================================================
# S34 no provider execution
# =====================================================================================
function Test-S34-NoProviderExecution {
    $forbidden = @('Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Process', 'Invoke-Expression',
                   'ConvertTo-ProviderNativeRequest', 'System.Net.Http', 'New-Object System.Net',
                   'System.Net.Sockets', 'webclient', 'Invoke-Remote', 'Get-AiPriceAt')
    foreach ($rel in $script:DashFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        foreach ($tok in $forbidden) { Assert-NotContains $text $tok "S34: $rel has no '$tok' (no provider/model execution)" }
    }
}

# =====================================================================================
# S35 no pricing mutation
# =====================================================================================
function Test-S35-NoPricingMutation {
    $forbidden = @('New-AiPrice', 'Update-AiPrice', 'Set-AiPrice', 'Remove-AiPrice', 'Import-AiPricingCatalogue')
    foreach ($rel in $script:DashFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        foreach ($tok in $forbidden) { Assert-NotContains $text $tok "S35: $rel has no '$tok' (no pricing mutation)" }
    }
    $adapter = Join-Path $script:Root 'ai-routing\providers\common\AdapterContracts.ps1'
    Assert-True ((Get-Sha256 $adapter) -eq $script:ShaBefore['ai-routing\providers\common\AdapterContracts.ps1']) 'S35: pricing/adaptor contract byte-identical'
}

# =====================================================================================
# S36 no router-policy mutation
# =====================================================================================
function Test-S36-NoRouterPolicyMutation {
    foreach ($rel in $script:DashFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'RoutingPolicy' "S36: $rel does not invoke router policy mutation"
        Assert-NotContains $text 'Update-Routing' "S36: $rel has no routing mutation verb"
    }
    $cfg = Join-Path $script:Root 'config\ai-routing.json'
    Assert-True ((Get-Sha256 $cfg) -eq $script:ShaBefore['config\ai-routing.json']) 'S36: routing config byte-identical (no policy mutation)'
}

# =====================================================================================
# S37 no budget override
# =====================================================================================
function Test-S37-NoBudgetOverride {
    foreach ($rel in $script:DashFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Override-Budget' "S37: $rel has no budget-override verb"
        Assert-NotContains $text 'AllowManualOverride' "S37: $rel never flips override policy"
    }
    # even with an override-evidence string, the dashboard only DISPLAYS it
    $policy = New-BudgetPolicy -PolicyId 'dbm26-budget-s37' -Name 'S37' -Enabled $true -Currency 'INR' `
        -MonthlyLimit 100 -WarnAtPercent 80 -BlockAtPercent 100 -UnknownCostPolicy 'BLOCK'
    $recs = @( (New-Att -TaskId 'S37-T1' -ChangeId 'S37-T1' -AttemptId 'S37-T1-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 90) )
    $req = New-DbM26DashboardRequest -PresetWindow 'THIS_MONTH' -NowUtc $script:NowUtc
    $view = Get-Dash -Records $recs -Request $req -BudgetPolicy $policy -BudgetOverrideEvidence 'human-approved ref GOV-37 (display only)'
    Assert-True ($view.BudgetView.OverrideEvidence -eq 'human-approved ref GOV-37 (display only)') 'S37: override evidence displayed'
    Assert-True ($view.BudgetView.Status -eq 'WARNING') 'S37: displayed override does NOT lift the budget status'
    $html = ConvertTo-DbM26Html -View $view
    Assert-Contains $html 'never grants budget overrides' 'S37: html states the dashboard never grants overrides'
}

# =====================================================================================
# S38 no provider-health mutation
# =====================================================================================
function Test-S38-NoProviderHealthMutation {
    foreach ($rel in $script:DashFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Record-Health' "S38: $rel has no health-record verb"
        Assert-NotContains $text 'Set-Circuit' "S38: $rel has no circuit-mutation verb"
        Assert-NotContains $text 'Failover-' "S38: $rel does not invoke failover policy"
    }
    $health = @( [pscustomobject]@{ ProviderId = 'prov-a'; RouteId = 'prov-a|model-a'; HealthState = 'DEGRADED'; CircuitState = 'CLOSED'; ObservedAtUtc = '2026-08-30T10:00:00Z'; FreshEvidenceCount = 2; StaleEvidenceCount = 0 } )
    $view = Get-Dash -Records @() -ProviderHealthState $health
    Assert-True (@($view.ProviderHealthView).Count -eq 1) 'S38: health evidence displayed read-only'
}

# =====================================================================================
# S39 zero network calls
# =====================================================================================
function Test-S39-ZeroNetworkCalls {
    $forbidden = @('Invoke-WebRequest', 'Invoke-RestMethod', 'System.Net.Http', 'System.Net.Sockets',
                   'webclient', 'Net.WebClient', 'System.Net.WebClient')
    foreach ($rel in $script:DashFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        foreach ($tok in $forbidden) { Assert-NotContains $text $tok "S39: $rel has no '$tok' (no network)" }
    }
    $recs = @( (New-Att -TaskId 'S39-T1' -ChangeId 'S39-T1' -AttemptId 'S39-T1-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10) )
    $view = Get-Dash -Records $recs
    Assert-True ($view.ReadOnlyGuard.NetworkCalls -eq 0) 'S39: guard records zero network calls'
}

# =====================================================================================
# S40 zero paid calls
# =====================================================================================
function Test-S40-ZeroPaidCalls {
    $recs = @( (New-Att -TaskId 'S40-T1' -ChangeId 'S40-T1' -AttemptId 'S40-T1-R0' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10) )
    $view = Get-Dash -Records $recs
    Assert-True ($view.ReadOnlyGuard.PaidApiCalls -eq 0) 'S40: guard records zero paid API calls'
    Assert-True (-not $view.ReadOnlyGuard.ProviderModelExecuted) 'S40: guard records no provider/model execution'
    Assert-True ($view.ReadOnlyGuard.PolicyVersion -eq '0.0.0') 'S40: router policy version immutable 0.0.0'
    $html = ConvertTo-DbM26Html -View $view
    Assert-Contains $html 'Paid calls: <strong>0</strong>' 'S40: html reports zero paid calls'
    Assert-Contains $html 'Network calls: <strong>0</strong>' 'S40: html reports zero network calls'
    Assert-Contains $html 'Auto execution: <strong>false</strong>' 'S40: html reports auto-execution disabled'
    Assert-Contains $html 'Write actions: <strong>false</strong>' 'S40: html reports no write actions'
}

# =====================================================================================
# S41 no Nexus/workbook mutation
# =====================================================================================
function Test-S41-NoNexusWorkbookMutation {
    foreach ($rel in $script:DashFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'NEXUS_DEVELOPMENT_CONTROL' "S41: $rel has no workbook reference"
        Assert-NotContains $text '.xlsx' "S41: $rel has no workbook path"
        Assert-NotContains $text 'PreDevBridgeBaseline' "S41: $rel has no Nexus baseline mutation"
    }
    if ($null -ne $script:WorkbookShaBefore) {
        $now = Get-Sha256 $script:WorkbookPath
        Assert-True ($now -eq $script:WorkbookShaBefore) 'S41: canonical Nexus workbook byte-identical (not modified)'
        Assert-True ($now -eq 'F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884') 'S41: workbook SHA matches the recorded authority hash F520060C'
    } else {
        Assert-True $false 'S41: canonical workbook file not reachable for verification'
    }
}

# =====================================================================================
# S42 M12.3 lifecycle UI files untouched
# =====================================================================================
function Test-S42-M123UiFilesUntouched {
    if (-not $script:ForgeRoot) {
        $script:HostSkips.Add('S42 M12.x console byte-identity: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT); the console stayed in Forge at W6/LaneA')
        return
    }
    Assert-True ($script:UiFiles.Count -gt 0) 'S42: M12.x UI source files enumerated'
    foreach ($f in $script:UiFiles) {
        $now = Get-Sha256 $f
        Assert-True ($now -eq $script:UiShaBefore[$f]) "S42: M12.x UI file unchanged: $f"
    }
    # dashboard library never references the UI namespace
    foreach ($rel in $script:DashFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'DevBridge.UI' "S42: $rel has no UI namespace reference"
    }
}

# =====================================================================================
# S43 DB-M25 regression remains green
# =====================================================================================
function Test-S43-Dbm25Regression {
    $r = Invoke-RegressionSuite -Name 'DBM25' -Path 'ai-routing\quality-cost\Test-DbM25QualityCost.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.Failed -eq 0) 'S43: DB-M25 regression zero failures'
    Assert-True ($r.ExitCode -eq 0) 'S43: DB-M25 regression exit 0'
    Assert-True ($r.Passed -ge 300) 'S43: DB-M25 regression substantial pass count'
}

# =====================================================================================
# S44 relevant AI regressions remain green (DB-M14..DB-M24)
# =====================================================================================
function Test-S44-RelevantAiRegressions {
    foreach ($suite in $script:RegressionSuites) {
        $r = Invoke-RegressionSuite -Name $suite.Name -Path $suite.Path
        $script:RegressionResults.Add($r)
        Assert-True ($r.ExitCode -eq 0) "S44: regression $($suite.Name) exit 0"
        Assert-True ($r.Failed -eq 0) "S44: regression $($suite.Name) zero failures"
    }
}

# =====================================================================================
# S45 build passes (dot-source + full engine run + render)
# =====================================================================================
function Test-S45-BuildPasses {
    # fresh parse of the DB-M26-owned scripts (already dot-sourced at top; re-source proves they parse cleanly)
    foreach ($rel in $script:DashFiles) {
        $full = Join-Path $script:Root $rel
        $null = Get-Content $full -Raw
        Assert-True (Test-Path $full) "S45: source file present: $rel"
    }
    $recs = @(
        (New-Att -TaskId 'S45-T1' -ChangeId 'S45-T1' -AttemptId 'S45-T1-R0' -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 3),
        (New-Att -TaskId 'S45-T1' -ChangeId 'S45-T1' -AttemptId 'S45-T1-R1' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 10)
    )
    $view = Get-Dash -Records $recs
    Assert-NotNull $view 'S45: engine produced a view'
    Assert-True ((Test-DbM26DashboardView $view).Valid) 'S45: view contract valid'
    $html = ConvertTo-DbM26Html -View $view -Title 'DB-M26 build check'
    Assert-NotNull $html 'S45: renderer produced html'
    # the operator-requested artifact can be written once (explicit render call)
    $out = Join-Path $env:TEMP ("dbm26-build-check-{0}.html" -f (Get-Random))
    $written = Export-DbM26DashboardHtml -View $view -OutputPath $out -Title 'DB-M26 build check'
    Assert-True (Test-Path $written) 'S45: explicit artifact export wrote the file'
    if (Test-Path $out) { Remove-Item $out -Force }
    # contract + request validators pass on real artifacts
    Assert-True ((Test-DbM26DashboardRequest (New-DefReq)).Valid) 'S45: request validator passes'
}

# --- runner ------------------------------------------------------------------------------------------------------

$script:Scenarios = @(
    'Test-S01-DashboardLoads',
    'Test-S02-EmptyData',
    'Test-S03-OneAttempt',
    'Test-S04-FailPassChain',
    'Test-S05-CumulativeCost',
    'Test-S06-ActualVsEstimated',
    'Test-S07-VerifiedSuccessSemantics',
    'Test-S08-FailedAttemptCost',
    'Test-S09-ProviderFailureSeparated',
    'Test-S10-ModelQualityFailureSeparated',
    'Test-S11-EscalationCost',
    'Test-S12-CorrectionCost',
    'Test-S13-FirstAttemptSuccess',
    'Test-S14-CostPerVerifiedSuccess',
    'Test-S15-SavingsBaselineShown',
    'Test-S16-SavingsConfidence',
    'Test-S17-InsufficientEvidenceLabelled',
    'Test-S18-TaskTypeFilter',
    'Test-S19-ProviderFilter',
    'Test-S20-ModelFilter',
    'Test-S21-ReasoningFilter',
    'Test-S22-DateFilter',
    'Test-S23-DirectVsGatewaySeparated',
    'Test-S24-UnderlyingModelPreserved',
    'Test-S25-LocalCostUnknown',
    'Test-S26-BudgetWarning',
    'Test-S27-BudgetBlocked',
    'Test-S28-ProviderHealthDisplayed',
    'Test-S29-CircuitStateDisplayed',
    'Test-S30-AttemptHistoryPreserved',
    'Test-S31-ChainDrilldown',
    'Test-S32-FailedAttemptsNotHidden',
    'Test-S33-NoWriteActions',
    'Test-S34-NoProviderExecution',
    'Test-S35-NoPricingMutation',
    'Test-S36-NoRouterPolicyMutation',
    'Test-S37-NoBudgetOverride',
    'Test-S38-NoProviderHealthMutation',
    'Test-S39-ZeroNetworkCalls',
    'Test-S40-ZeroPaidCalls',
    'Test-S41-NoNexusWorkbookMutation',
    'Test-S42-M123UiFilesUntouched',
    'Test-S43-Dbm25Regression',
    'Test-S44-RelevantAiRegressions',
    'Test-S45-BuildPasses'
)

foreach ($scenario in $script:Scenarios) {
    try {
        & $scenario
    } catch {
        $script:ScenarioFails.Add("${scenario} threw: $($_.Exception.Message)")
        Write-Host "  SCENARIO EXCEPTION ${scenario}: $($_.Exception.Message)"
    }
}

# re-verify frozen files after every scenario + regression
foreach ($rel in $script:FrozenFiles) {
    $after = Get-Sha256 (Join-Path $script:Root $rel)
    if ($after -ne $script:ShaBefore[$rel]) {
        $script:TestFails.Add("POST-CHECK $rel changed during the run (SHA mismatch)")
    }
}

$passed = $script:TestCount - $script:TestFails.Count
Write-Host "DB-M26 TEST SUMMARY: $passed passed, $($script:TestFails.Count) failed"
Write-Host "DB-M26 SCENARIOS: $($script:Scenarios.Count) scenarios"
foreach ($r in $script:RegressionResults) {
    Write-Host ("DB-M26 REGRESSION {0}: {1} passed, {2} failed, exit {3}" -f $r.Name, $r.Passed, $r.Failed, $r.ExitCode)
}
foreach ($f in $script:TestFails) { Write-Host "  FAIL: $f" }
foreach ($f in $script:ScenarioFails) { Write-Host "  SCENARIO FAIL: $f" }
# Cross-tree assertions that could not run are reported, never silently dropped: a
# run that skipped them is not the same evidence as a run that executed them.
Write-Host "DB-M26 HOST SKIPS: $($script:HostSkips.Count)"
foreach ($s in $script:HostSkips) { Write-Host "  [SKIP] $s" }
if ($script:TestFails.Count -eq 0 -and $script:ScenarioFails.Count -eq 0) {
    exit 0
}
exit 1

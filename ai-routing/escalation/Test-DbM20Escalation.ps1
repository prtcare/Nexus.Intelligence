# =============================================================================
# Test-DbM20Escalation.ps1
# DB-M20 -- Retry + Automatic Escalation DECISION ENGINE (Lane B, AI Routing)
#
# DB-M20 is a DECISION ENGINE ONLY. This suite proves the engine computes a
# deterministic retry / escalation PLAN and never executes anything:
#   - AUTO_EXECUTION_ENABLED = FALSE (AUTO mode is refused),
#   - no live AI invocation / paid API call / network call,
#   - no Nexus roadmap / workbook modification, no future Nexus reuse,
#   - non-AI failures (scope / governance / git / PR / merge / architecture)
#     NEVER escalate to a model or a retry,
#   - model escalation only via DB-M19 ELIGIBLE candidates (hard capability
#     filters are never bypassed),
#   - verification is authoritative (self-reported PASS != success),
#   - bounded retries / reasoning escalation / model escalation (no infinite
#     loops), loop protection on the preserved escalation chain,
#   - cost-aware escalation via the DB-M16 engine (incremental + cumulative,
#     never hidden; request-level ceiling only),
#   - FIX over REBUILD (focused CORRECT_CURRENT_ATTEMPT; NEW_FIX_TASK_REQUIRED
#     is represent-only and never creates a roadmap/workbook record),
#   - Temporary DevBridge boundary: exports only to DB-M20-owned DevBridge
#     paths and refuse every Nexus-owned / live-handoff / outside-root target.
#
# Scenarios S1..S26 map to the 26 required DB-M20 test scenarios. The harness
# matches the DB-M19 convention: $ErrorActionPreference="Stop",
# Set-StrictMode -Version Latest, $script:Results/$script:Fails, Assert-*
# helpers, exit 0 on all-pass / 1 on any failure.
# =============================================================================

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

. (Join-Path $PSScriptRoot "EscalationEngine.ps1")   # pulls in all DB-M20 layers + DB-M14/16/17/19/M24 (read-only)
. (Join-Path $PSScriptRoot "EscalationExport.ps1")

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
function Assert-Null {
    param($Actual, [string]$Message)
    $script:Results++
    if ($null -eq $Actual) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (got '$Actual')") }
}
function Assert-Not-Null {
    param($Actual, [string]$Message)
    $script:Results++
    if ($null -ne $Actual) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (got null)") }
}
function Assert-NullOrEmpty {
    param($Actual, [string]$Message)
    $script:Results++
    if ($null -eq $Actual -or [string]$Actual -eq '') { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (got '$Actual')") }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:Results++
    if ([string]$Actual -eq [string]$Expected) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual='$Actual' expected='$Expected')") }
}
function Assert-Near {
    param($Actual, [double]$Expected, [double]$Tolerance = 0.001, [string]$Message)
    $script:Results++
    if ($null -eq $Actual) { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual=null expected=$Expected)"); return }
    $diff = [math]::Abs([double]$Actual - $Expected)
    if ($diff -le $Tolerance) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual='$Actual' expected='$Expected' diff=$diff)") }
}
function Assert-In {
    param($Actual, [string[]]$Allowed, [string]$Message)
    $script:Results++
    if ([string]$Actual -in $Allowed) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual='$Actual' allowed='$($Allowed -join ',')')") }
}

# -----------------------------------------------------------------------------
# Fixture builders (in-memory only; never writes to the live catalogue)
# -----------------------------------------------------------------------------
function New-TestProvider {
    param([string]$ProviderId, [string]$DisplayName = $ProviderId, [bool]$Enabled = $true)
    return New-AiProvider -ProviderId $ProviderId -DisplayName $DisplayName -Enabled $Enabled `
        -Configured $true -ProviderType 'DIRECT'
}

function New-TestModel {
    param(
        [string]$ModelId, [string]$ProviderId, [long]$ContextWindow = 200000,
        [string[]]$ReasoningLevelsSupported = @('LOW','MEDIUM','HIGH')
    )
    return New-AiModel -ModelId $ModelId -ProviderId $ProviderId -UnderlyingModelId $ModelId `
        -GatewayProviderId $null -DisplayName "Model $ModelId" -Enabled $true -LocalOrRemote 'REMOTE' `
        -SupportsCoding $true -SupportsReasoning $true -SupportsVision $null -SupportsToolUse $null `
        -SupportsStructuredOutput $true -ContextWindow $ContextWindow -MaxOutputTokens 16384 `
        -ReasoningLevelsSupported $ReasoningLevelsSupported -RelativeSpeed 'NORMAL' -ReliabilityClass 'HIGH'
}

function New-TestPricingRecord {
    param(
        [string]$PricingRecordId, [string]$ProviderId, [string]$ModelId,
        [Nullable[double]]$InputPricePerMillion = 1.0, [Nullable[double]]$CachedInputPricePerMillion = 0.1,
        [Nullable[double]]$OutputPricePerMillion = 3.0
    )
    return New-AiPricingRecord -PricingRecordId $PricingRecordId -ProviderId $ProviderId -ModelId $ModelId `
        -Currency 'USD' -EffectiveFromUtc '2026-06-01T00:00:00Z' -ProcessingTier 'STANDARD' -TimeBand 'DEFAULT' `
        -InputPricePerMillion $InputPricePerMillion -CachedInputPricePerMillion $CachedInputPricePerMillion `
        -OutputPricePerMillion $OutputPricePerMillion -Source 'test-fixture'
}

function New-TestFx {
    param([string]$RateId = 'fx-usd-inr-test', [double]$Rate = 83.5)
    return New-AiExchangeRateRecord -ExchangeRateId $RateId -BaseCurrency 'USD' -QuoteCurrency 'INR' `
        -Rate $Rate -EffectiveAtUtc '2026-06-01T00:00:00Z'
}

function New-TestConfiguration {
    param(
        [AllowNull()][object]$Providers = $null, [AllowNull()][object]$Models = $null,
        [AllowNull()][object]$Pricing = $null, [AllowNull()][object]$ExchangeRates = $null
    )
    if ($null -eq $Providers) { $Providers = @{} }
    if ($null -eq $Models) { $Models = @{} }
    if ($null -eq $Pricing) { $Pricing = @{} }
    if ($null -eq $ExchangeRates) {
        $fx = @{}
        $rate = New-TestFx
        $fx[$rate.ExchangeRateId] = $rate
        $ExchangeRates = $fx
    }
    $costConfig = [pscustomobject]@{ schemaVersion = 1; ReasoningTokenBilling = 'INCLUDED_IN_OUTPUT' }
    return @{
        Routing = $null; Providers = $Providers; Models = $Models; Pricing = $Pricing;
        ExchangeRates = $ExchangeRates; CostConfig = $costConfig
    }
}

function New-TestRequirement {
    param(
        [string]$TaskId = 'T-1', [string]$TaskType = 'IMPLEMENTATION', [string]$Complexity = 'MEDIUM',
        [string]$Risk = 'LOW', [Nullable[bool]]$RequiresCoding = $true,
        [Nullable[bool]]$RequiresReasoning = $true, [string]$MinimumReasoningLevel = 'LOW',
        [Nullable[bool]]$RequiresStructuredOutput = $true, [Nullable[long]]$RequiredContextTokens = 32000,
        [Nullable[long]]$ExpectedOutputTokens = 2048, [string]$RequiredReliability = 'HIGH',
        [string]$ExecutionMode = 'ASSISTED'
    )
    return New-AiCapabilityRequirement -TaskId $TaskId -TaskType $TaskType -Complexity $Complexity -Risk $Risk `
        -RequiresCoding $RequiresCoding -RequiresReasoning $RequiresReasoning `
        -MinimumReasoningLevel $MinimumReasoningLevel -RequiresStructuredOutput $RequiresStructuredOutput `
        -RequiredContextTokens $RequiredContextTokens -ExpectedOutputTokens $ExpectedOutputTokens `
        -RequiredReliability $RequiredReliability -ExecutionMode $ExecutionMode
}

# Standard catalogue: two models on two providers (route switch is possible).
function New-StandardCatalogue {
    $providers = @{}
    $providers['prov-a'] = New-TestProvider -ProviderId 'prov-a' -DisplayName 'Provider A'
    $providers['prov-b'] = New-TestProvider -ProviderId 'prov-b' -DisplayName 'Provider B'

    $models = @{}
    $models['sonnet'] = New-TestModel -ModelId 'sonnet' -ProviderId 'prov-a'
    $models['opus']   = New-TestModel -ModelId 'opus'   -ProviderId 'prov-b'

    $pricing = @{}
    $pSonnet = New-TestPricingRecord -PricingRecordId 'pr-sonnet' -ProviderId 'prov-a' -ModelId 'sonnet' `
        -InputPricePerMillion 0.5 -CachedInputPricePerMillion 0.05 -OutputPricePerMillion 1.5
    $pOpus = New-TestPricingRecord -PricingRecordId 'pr-opus' -ProviderId 'prov-b' -ModelId 'opus' `
        -InputPricePerMillion 2.0 -CachedInputPricePerMillion 0.2 -OutputPricePerMillion 6.0
    $pricing[$pSonnet.PricingRecordId] = $pSonnet
    $pricing[$pOpus.PricingRecordId] = $pOpus

    return New-TestConfiguration -Providers $providers -Models $models -Pricing $pricing
}

function New-TestAttempt {
    <#
    .SYNOPSIS
    A DB-M17 AiAttemptRecord v1 fixture. FailureCategory must be a DB-M17
    recorded category (or null); DB-M20 escalation categories (governance etc.)
    are passed to the escalation input as -FailureCategory, never recorded here.
    #>
    param(
        [string]$TaskId = 'T-1', [string]$AttemptId, [string]$ChangeId = 'C-T-1',
        [string]$ProviderId = 'prov-a', [string]$ModelId = 'sonnet',
        [string]$ReasoningLevel = 'LOW', [string]$Result = 'FAILED',
        [string]$VerificationResult = 'PENDING', [string]$FailureCategory,
        [int]$RetryNumber = 0,
        [Nullable[double]]$ActualCost,
        [Nullable[double]]$EstimatedCost,
        [string]$VerificationEvidencePath,
        [string]$EscalatedFromAttemptId,
        [string]$EscalationReason
    )
    return New-AiAttemptRecord -TaskId $TaskId -ChangeId $ChangeId -AttemptId $AttemptId `
        -RetryNumber $RetryNumber -Result $Result -VerificationResult $VerificationResult `
        -FailureCategory $FailureCategory -ActualCost $ActualCost -EstimatedCost $EstimatedCost `
        -CostCurrency 'INR' -DurationMs 1000 -ProviderId $ProviderId -ModelId $ModelId `
        -UnderlyingModelId $ModelId -GatewayProviderId $null -ReasoningLevel $ReasoningLevel `
        -TaskType 'IMPLEMENTATION' -Complexity 'MEDIUM' -Risk 'LOW' -ExecutionMode 'MANUAL' `
        -VerificationEvidencePath $VerificationEvidencePath `
        -EscalatedFromAttemptId $EscalatedFromAttemptId -EscalationReason $EscalationReason `
        -StartedAtUtc '2026-08-20T10:00:00Z' -EndedAtUtc '2026-08-20T10:00:30Z'
}

function New-TestCandidate {
    <#
    .SYNOPSIS
    A DB-M19 RoutingCandidate v1 fixture. Defaults to ELIGIBLE.
    #>
    param(
        [string]$ProviderId, [string]$ModelId, [string]$Status = 'ELIGIBLE',
        [object[]]$RejectionReasons = @(),
        [long]$ContextWindow = 200000,
        [string[]]$ReasoningLevelsSupported = @('LOW','MEDIUM','HIGH'),
        [string]$SelectedReasoningLevel = 'MEDIUM',
        [Nullable[double]]$EstimatedCost,
        [bool]$CostUnknown = $false,
        [object]$PerformanceEvidence,
        [string]$PerformanceEvidenceReference
    )
    return New-RoutingCandidate @{
        ProviderId = $ProviderId; ModelId = $ModelId; Status = $Status
        RejectionReasons = $RejectionReasons; ContextWindow = $ContextWindow
        ReasoningLevelsSupported = $ReasoningLevelsSupported
        SelectedReasoningLevel = $SelectedReasoningLevel
        EstimatedCost = $EstimatedCost; CostUnknown = $CostUnknown
        PerformanceEvidence = $PerformanceEvidence
        PerformanceEvidenceReference = $PerformanceEvidenceReference
    }
}

function New-TestInput {
    <#
    .SYNOPSIS
    Wrap an EscalationInput v1 with DB-M20 test defaults.
    #>
    param(
        [string]$InputId = 'T-IN', [string]$TaskId = 'T-1',
        [object]$CurrentAttempt, [object[]]$AttemptChain = @(),
        [string]$RecordedFailureCategory,
        [string]$FailureCategory,
        [string]$VerificationResult,
        [string]$ClaudeReviewStatus,
        [object[]]$EligibleCandidates = @(),
        [object[]]$RejectedCandidates = @(),
        [Nullable[double]]$MaxAllowedCost,
        [string]$ExecutionMode = 'MANUAL',
        [bool]$HumanInterventionRequired = $false,
        [object]$Requirement,
        [object]$Configuration,
        [string]$RequestTimestampUtc = '2026-08-30T12:00:00Z'
    )
    return New-EscalationInput -InputId $InputId -TaskId $TaskId `
        -CurrentAttempt $CurrentAttempt -AttemptChain $AttemptChain `
        -RecordedFailureCategory $RecordedFailureCategory -FailureCategory $FailureCategory `
        -VerificationResult $VerificationResult -ClaudeReviewStatus $ClaudeReviewStatus `
        -EligibleCandidates $EligibleCandidates -RejectedCandidates $RejectedCandidates `
        -MaxAllowedCost $MaxAllowedCost -ExecutionMode $ExecutionMode `
        -HumanInterventionRequired $HumanInterventionRequired `
        -Requirement $Requirement -Configuration $Configuration `
        -TimestampUtc $RequestTimestampUtc
}

function Get-TestDecision {
    param([object]$DecisionInput, [AllowNull()][object]$Policy)
    return Get-AiEscalationDecision -Input $DecisionInput -Policy $Policy
}

# -----------------------------------------------------------------------------
# S1 -- AUTO execution mode is refused (AUTO_EXECUTION_ENABLED = FALSE)
# -----------------------------------------------------------------------------
Write-Output "== S1: AUTO mode refused =="
$att1 = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY'
$inp = New-TestInput -CurrentAttempt $att1 -RecordedFailureCategory 'MODEL_QUALITY' -ExecutionMode 'AUTO'
$d = Get-TestDecision $inp
Assert-Equal $d.Status 'AUTO_EXECUTION_PROHIBITED' 'S1a: AUTO mode -> Status AUTO_EXECUTION_PROHIBITED'
Assert-True ($null -eq $d.Action) 'S1b: AUTO mode -> no Action is recommended'
Assert-Equal $d.AutoExecutionEnabled $false 'S1c: AUTO mode -> AutoExecutionEnabled is always FALSE'
Assert-Equal $d.RequiresHuman $true 'S1d: AUTO mode -> RequiresHuman is true'
Assert-True ('AUTO_PROHIBITED' -in $d.ReasonCodes) 'S1e: AUTO mode -> reason code AUTO_PROHIBITED'
$propFound = $false
foreach ($p in $d.PSObject.Properties) { if ($p.Name -match 'Command|Execute|Invoke') { $propFound = $true } }
Assert-True (-not $propFound) 'S1f: decision exposes no execution command/execute/invoke property (recommendation only)'

# -----------------------------------------------------------------------------
# S2 -- Verified success stops (no retry)
# -----------------------------------------------------------------------------
Write-Output "== S2: verified success =="
$ok = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'VERIFIED'
$d = Get-TestDecision (New-TestInput -CurrentAttempt $ok -VerificationResult 'VERIFIED')
Assert-Equal $d.Status 'STOP_SUCCESS' 'S2a: verified success -> STOP_SUCCESS'
Assert-Equal $d.Action 'STOP_SUCCESS' 'S2b: verified success -> action STOP_SUCCESS'
Assert-Equal $d.RequiresHuman $false 'S2c: verified success -> no human required'
Assert-True ('SUCCESS_VERIFIED' -in $d.ReasonCodes) 'S2d: verified success -> SUCCESS_VERIFIED'
Assert-NullOrEmpty $d.NextModelId 'S2e: no next model is planned'

# -----------------------------------------------------------------------------
# S3 -- Verification-driven escalation: self-reported PASS but DB-M06 FAILED
# -----------------------------------------------------------------------------
Write-Output "== S3: self-reported PASS, verification FAILED =="
$selfPass = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'SUCCESS' -VerificationResult 'FAILED'
$inp = New-TestInput -CurrentAttempt $selfPass -VerificationResult 'FAILED'
$d = Get-TestDecision $inp
$f = Get-AiFailureCategory -VerificationResult 'FAILED'
Assert-Equal $f.Category 'VERIFICATION_FAILURE' 'S3a: verification-driven classification -> VERIFICATION_FAILURE'
Assert-Equal $d.FailureCategory 'VERIFICATION_FAILURE' 'S3b: engine FailureCategory = VERIFICATION_FAILURE (self-reported PASS != success)'
Assert-Equal $d.Action 'CORRECT_CURRENT_ATTEMPT' 'S3c: first verification failure -> focused correction (FIX over rebuild/retry)'
Assert-True ('SELF_REPORTED_PASS_FAILED_VERIFICATION' -in $d.ReasonCodes) 'S3d: reason code SELF_REPORTED_PASS_FAILED_VERIFICATION present'
Assert-Equal $d.NextModelId 'sonnet' 'S3e: correction stays on the same route'

# -----------------------------------------------------------------------------
# S4 -- Claude review FIX_REQUIRED -> CLAUDE_REVIEW_FIX -> correction
# -----------------------------------------------------------------------------
Write-Output "== S4: Claude review requires a fix =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'VALIDATION_FAILURE' -VerificationResult 'VERIFIED'
$inp = New-TestInput -CurrentAttempt $att -RecordedFailureCategory 'VALIDATION_FAILURE' -VerificationResult 'VERIFIED' -ClaudeReviewStatus 'FIX_REQUIRED'
$f = Get-AiFailureCategory -RecordedFailureCategory 'VALIDATION_FAILURE' -ClaudeReviewStatus 'FIX_REQUIRED'
Assert-Equal $f.Category 'CLAUDE_REVIEW_FIX' 'S4a: FIX_REQUIRED signal -> CLAUDE_REVIEW_FIX'
$d = Get-TestDecision $inp
Assert-Equal $d.FailureCategory 'CLAUDE_REVIEW_FIX' 'S4b: engine FailureCategory = CLAUDE_REVIEW_FIX'
Assert-Equal $d.Action 'CORRECT_CURRENT_ATTEMPT' 'S4c: review fix -> focused correction'
Assert-Equal $d.RequiresHuman $false 'S4d: a review-fix correction is an AI-side correction (not a human gate)'

# -----------------------------------------------------------------------------
# S5 -- GOVERNANCE_BLOCKED: terminal, never model escalation
# -----------------------------------------------------------------------------
Write-Output "== S5: governance block =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED'
$inp = New-TestInput -CurrentAttempt $att -FailureCategory 'GOVERNANCE_BLOCKED' `
    -EligibleCandidates @(New-TestCandidate -ProviderId 'prov-b' -ModelId 'opus')
$d = Get-TestDecision $inp
Assert-Equal $d.Status 'STOP_GOVERNANCE' 'S5a: GOVERNANCE_BLOCKED -> STOP_GOVERNANCE'
Assert-Equal $d.Action 'STOP_GOVERNANCE' 'S5b: action STOP_GOVERNANCE'
Assert-NullOrEmpty $d.NextModelId 'S5c: governance failures NEVER escalate to a model'
Assert-NullOrEmpty $d.NextProviderId 'S5d: governance failures NEVER escalate to a provider'
Assert-True ('NO_QUALITY_ESCALATION_FOR_NON_AI' -in $d.ReasonCodes) 'S5e: non-AI failures never spend AI tokens on stronger models'
Assert-Equal $d.AutoExecutionEnabled $false 'S5f: never auto-executed'

# -----------------------------------------------------------------------------
# S6 -- SCOPE_CHANGE_REQUIRED: governance decision required
# -----------------------------------------------------------------------------
Write-Output "== S6: scope change required =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED'
$d = Get-TestDecision (New-TestInput -CurrentAttempt $att -FailureCategory 'SCOPE_CHANGE_REQUIRED')
Assert-Equal $d.Status 'HUMAN_GOVERNANCE_REQUIRED' 'S6a: SCOPE_CHANGE_REQUIRED -> HUMAN_GOVERNANCE_REQUIRED'
Assert-Equal $d.RequiresHuman $true 'S6b: requires a human governance decision'
Assert-Equal $d.HumanActionType 'GOVERNANCE_REVIEW' 'S6c: human action type = GOVERNANCE_REVIEW'
Assert-NullOrEmpty $d.NextModelId 'S6d: no model escalation for a scope change'

# -----------------------------------------------------------------------------
# S7 -- Human Git gates: never bypassed, never escalated to a model
# -----------------------------------------------------------------------------
Write-Output "== S7: human Git gates =="
foreach ($gitCat in @('HUMAN_GIT_GATE', 'PR_PENDING', 'MERGE_PENDING')) {
    $att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED'
    $d = Get-TestDecision (New-TestInput -CurrentAttempt $att -FailureCategory $gitCat `
        -EligibleCandidates @(New-TestCandidate -ProviderId 'prov-b' -ModelId 'opus'))
    Assert-Equal $d.Status 'HUMAN_GIT_ACTION_REQUIRED' "S7a ($gitCat): -> HUMAN_GIT_ACTION_REQUIRED"
    Assert-Equal $d.RequiresHuman $true "S7b ($gitCat): requires a human Git action"
    Assert-Equal $d.HumanActionType 'GIT_ACTION' "S7c ($gitCat): human action type = GIT_ACTION"
    Assert-NullOrEmpty $d.NextModelId "S7d ($gitCat): DB-M20 never bypasses a human Git gate with a model escalation"
    Assert-True ('NO_QUALITY_ESCALATION_FOR_NON_AI' -in $d.ReasonCodes) "S7e ($gitCat): non-AI reason code present"
}

# -----------------------------------------------------------------------------
# S8 -- ARCHITECTURE_CONFLICT: roadmap structure is protected
# -----------------------------------------------------------------------------
Write-Output "== S8: architecture conflict =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED'
$d = Get-TestDecision (New-TestInput -CurrentAttempt $att -FailureCategory 'ARCHITECTURE_CONFLICT')
Assert-Equal $d.Status 'STOP_GOVERNANCE' 'S8a: ARCHITECTURE_CONFLICT -> STOP_GOVERNANCE'
Assert-Equal $d.Action 'STOP_GOVERNANCE' 'S8b: action STOP_GOVERNANCE'
Assert-True ('ARCHITECTURE_CONFLICT' -in $d.ReasonCodes) 'S8c: architecture reason code present'
Assert-NullOrEmpty $d.NextModelId 'S8d: never a model escalation for an architecture conflict'

# -----------------------------------------------------------------------------
# S9 -- BUDGET_FAILURE recorded -> STOP_BUDGET_LIMIT (never a model escalation)
# -----------------------------------------------------------------------------
Write-Output "== S9: recorded budget failure =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'BUDGET_FAILURE'
$d = Get-TestDecision (New-TestInput -CurrentAttempt $att -RecordedFailureCategory 'BUDGET_FAILURE')
$f = Get-AiFailureCategory -RecordedFailureCategory 'BUDGET_FAILURE'
Assert-Equal $f.BudgetStop $true 'S9a: BUDGET_FAILURE maps to a BudgetStop condition'
Assert-Equal $d.Status 'STOP_BUDGET_LIMIT' 'S9b: budget failure -> STOP_BUDGET_LIMIT'
Assert-Equal $d.Action 'STOP_BUDGET_LIMIT' 'S9c: action STOP_BUDGET_LIMIT'
Assert-True ('BUDGET_FAILURE_RECORDED' -in $d.ReasonCodes) 'S9d: BUDGET_FAILURE_RECORDED reason code present'
Assert-NullOrEmpty $d.NextModelId 'S9e: never escalate to a model on a budget failure'

# -----------------------------------------------------------------------------
# S10 -- Request cost ceiling exceeded -> STOP_BUDGET_LIMIT
# -----------------------------------------------------------------------------
Write-Output "== S10: request ceiling =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -ActualCost 1.0
$inp = New-TestInput -CurrentAttempt $att -FailureCategory 'TIMEOUT' -MaxAllowedCost 0.5
$d = Get-TestDecision $inp
Assert-Equal $d.Status 'STOP_BUDGET_LIMIT' 'S10a: accumulated cost above the request ceiling -> STOP_BUDGET_LIMIT'
Assert-True ('BUDGET_CEILING_REACHED' -in $d.ReasonCodes) 'S10b: BUDGET_CEILING_REACHED reason code present'
Assert-Near $d.CumulativeActualCost 1.0 0.0001 'S10c: cumulative actual cost is reported (never hidden)'

# unit-level ceiling checks
$c1 = Test-DbM20BudgetCeiling -CumulativeCost 1.0 -NextEstimate 0.1 -Ceiling 0.5
Assert-Equal $c1.Exceeded $true 'S10d: ceiling exceeded when cum+next > ceiling'
$c2 = Test-DbM20BudgetCeiling -CumulativeCost 0.2 -NextEstimate 0.1 -Ceiling 1.0
Assert-Equal $c2.Exceeded $false 'S10e: ceiling not exceeded when within limit'

# -----------------------------------------------------------------------------
# S11 -- Attempt limit reached -> no further attempt (no infinite loops)
# -----------------------------------------------------------------------------
Write-Output "== S11: attempt limit =="
$chain = @()
for ($i = 0; $i -lt 5; $i++) {
    $chain += New-TestAttempt -AttemptId "A$($i+1)" -RetryNumber $i -Result 'FAILED'
}
$current = $chain[4]
$inp = New-TestInput -CurrentAttempt $current -AttemptChain @($chain[0..3]) -FailureCategory 'TIMEOUT'
$d = Get-TestDecision $inp
Assert-Equal $d.Status 'STOP_NO_ELIGIBLE_ESCALATION' 'S11a: attempt limit reached -> STOP_NO_ELIGIBLE_ESCALATION'
Assert-True ('ATTEMPT_LIMIT_REACHED' -in $d.ReasonCodes) 'S11b: ATTEMPT_LIMIT_REACHED reason code present'
Assert-NullOrEmpty $d.NextModelId 'S11c: no further attempt is planned'

# -----------------------------------------------------------------------------
# S12 -- Same-route transient retry is allowed within limits
# -----------------------------------------------------------------------------
Write-Output "== S12: transient same-route retry =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED'
$r = Test-AiRetryAllowed -Category 'TIMEOUT' -AttemptNumber 2 -Policy (Get-DefaultEscalationPolicy) `
    -Attempts @($att) -CurrentModelId 'sonnet' -LoopFree $true
Assert-Equal $r.Allowed $true 'S12a: Test-AiRetryAllowed allows a transient retry'
$d = Get-TestDecision (New-TestInput -CurrentAttempt $att -FailureCategory 'TIMEOUT')
Assert-Equal $d.Action 'RETRY_SAME_ROUTE' 'S12b: TIMEOUT -> RETRY_SAME_ROUTE'
Assert-Equal $d.NextModelId 'sonnet' 'S12c: retry stays on the same model'
Assert-Equal $d.NextProviderId 'prov-a' 'S12d: retry stays on the same provider'
Assert-True ('RETRY_TRANSIENT' -in $d.ReasonCodes) 'S12e: RETRY_TRANSIENT reason code present'

# -----------------------------------------------------------------------------
# S13 -- Same-model retries are bounded (no infinite same-model retry loops)
# -----------------------------------------------------------------------------
Write-Output "== S13: same-model retry bound =="
$chain = @(
    (New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED'),
    (New-TestAttempt -AttemptId 'A2' -RetryNumber 1 -Result 'FAILED'),
    (New-TestAttempt -AttemptId 'A3' -RetryNumber 2 -Result 'FAILED')
)
$r = Test-AiRetryAllowed -Category 'TIMEOUT' -AttemptNumber 4 -Policy (Get-DefaultEscalationPolicy) `
    -Attempts $chain -CurrentModelId 'sonnet' -LoopFree $true
Assert-Equal $r.Allowed $false 'S13a: MaxSameModelRetries exhausted -> retry NOT allowed'
Assert-True ($r.Reason -match 'same-model retry budget exhausted') 'S13b: same-model exhaustion reason reported'
# engine: provider-route switch is the bounded alternative, never an unbounded retry
$inp = New-TestInput -CurrentAttempt $chain[2] -AttemptChain @($chain[0..1]) -FailureCategory 'TIMEOUT' `
    -EligibleCandidates @(New-TestCandidate -ProviderId 'prov-b' -ModelId 'opus')
$d = Get-TestDecision $inp
Assert-Equal $d.Action 'SWITCH_PROVIDER_ROUTE' 'S13c: exhausted retries -> SWITCH_PROVIDER_ROUTE (never an infinite retry loop)'
Assert-Equal $d.NextProviderId 'prov-b' 'S13d: next provider is the alternate route'

# -----------------------------------------------------------------------------
# S14 -- Reasoning escalation is one step (never a jump)
# -----------------------------------------------------------------------------
Write-Output "== S14: reasoning escalation one step =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY'
$currentCandidate = New-TestCandidate -ProviderId 'prov-a' -ModelId 'sonnet' `
    -ReasoningLevelsSupported @('LOW','MEDIUM','HIGH') -SelectedReasoningLevel 'LOW'
$inp = New-TestInput -CurrentAttempt $att -RecordedFailureCategory 'MODEL_QUALITY' `
    -EligibleCandidates @($currentCandidate, (New-TestCandidate -ProviderId 'prov-b' -ModelId 'opus'))
$d = Get-TestDecision $inp
Assert-Equal $d.Action 'RETRY_SAME_MODEL_HIGHER_REASONING' 'S14a: MODEL_QUALITY -> RETRY_SAME_MODEL_HIGHER_REASONING'
Assert-Equal $d.NextReasoningLevel 'MEDIUM' 'S14b: reasoning escalated exactly one step (LOW -> MEDIUM)'
Assert-Equal $d.NextModelId 'sonnet' 'S14c: reasoning escalation stays on the same model'
Assert-True ('REASONING_ESCALATION' -in $d.ReasonCodes) 'S14d: REASONING_ESCALATION reason code present'

# -----------------------------------------------------------------------------
# S15 -- Never jump straight to MAX reasoning
# -----------------------------------------------------------------------------
Write-Output "== S15: no jump to MAX =="
$pol = Get-DefaultEscalationPolicy
$g1 = Get-AiNextReasoningLevel -CurrentLevel 'LOW' -SupportedLevels @('LOW','MEDIUM','HIGH','MAX') `
    -ReasoningEscalationsUsed 0 -Policy $pol
Assert-Equal $g1.NextLevel 'MEDIUM' 'S15a: LOW with MAX supported still escalates to MEDIUM (one step, not MAX)'
$g2 = Get-AiNextReasoningLevel -CurrentLevel 'HIGH' -SupportedLevels @('HIGH','MAX') `
    -ReasoningEscalationsUsed 0 -Policy $pol
Assert-Equal $g2.NextLevel 'MAX' 'S15b: HIGH -> MAX is allowed (one step from HIGH)'
$g3 = Get-AiNextReasoningLevel -CurrentLevel 'LOW' -SupportedLevels @('LOW','MEDIUM','HIGH') `
    -ReasoningEscalationsUsed 2 -Policy $pol
Assert-Equal $g3.Allowed $false 'S15c: reasoning-escalation budget exhausted -> escalation blocked'
$g4 = Get-AiNextReasoningLevel -CurrentLevel 'MEDIUM' -SupportedLevels @('MEDIUM') `
    -ReasoningEscalationsUsed 0 -Policy $pol
Assert-Equal $g4.Allowed $false 'S15d: no supported higher level -> escalation blocked'

# -----------------------------------------------------------------------------
# S16 -- Model escalation only to an eligible candidate
# -----------------------------------------------------------------------------
Write-Output "== S16: model escalation to an eligible candidate =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY'
$currentCandidate = New-TestCandidate -ProviderId 'prov-a' -ModelId 'sonnet' `
    -ReasoningLevelsSupported @('LOW') -SelectedReasoningLevel 'LOW'
$opus = New-TestCandidate -ProviderId 'prov-b' -ModelId 'opus' -SelectedReasoningLevel 'HIGH'
$inp = New-TestInput -CurrentAttempt $att -RecordedFailureCategory 'MODEL_QUALITY' `
    -EligibleCandidates @($currentCandidate, $opus)
$d = Get-TestDecision $inp
Assert-Equal $d.Action 'SWITCH_MODEL' 'S16a: reasoning exhausted -> SWITCH_MODEL'
Assert-Equal $d.NextModelId 'opus' 'S16b: next model is the eligible candidate'
Assert-Equal $d.NextProviderId 'prov-b' 'S16c: next provider matches the candidate route'
Assert-True ('MODEL_ESCALATION' -in $d.ReasonCodes) 'S16d: MODEL_ESCALATION reason code present'

# -----------------------------------------------------------------------------
# S17 -- Hard capability filters are never bypassed (rejected candidate refused)
# -----------------------------------------------------------------------------
Write-Output "== S17: hard filters never bypassed =="
$rejectedOpus = New-TestCandidate -ProviderId 'prov-b' -ModelId 'opus' -Status 'REJECTED' `
    -RejectionReasons @([pscustomobject]@{ Code = 'CAPABILITY_GAP'; Reason = 'missing required capability' })
$ranked = Get-AiEscalationCandidates -EligibleCandidates @() -RejectedCandidates @($rejectedOpus) `
    -CurrentProviderId 'prov-a' -CurrentModelId 'sonnet' -Attempts @()
Assert-Equal $ranked.Candidates.Count 0 'S17a: a rejected candidate is never ranked (hard filters are never bypassed)'
# engine: even if the rejected model is 'stronger', it is not selected
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY'
$currentCandidate = New-TestCandidate -ProviderId 'prov-a' -ModelId 'sonnet' -ReasoningLevelsSupported @('LOW') -SelectedReasoningLevel 'LOW'
$inp = New-TestInput -CurrentAttempt $att -RecordedFailureCategory 'MODEL_QUALITY' `
    -EligibleCandidates @($currentCandidate) -RejectedCandidates @($rejectedOpus)
$d = Get-TestDecision $inp
Assert-Equal $d.Status 'STOP_NO_ELIGIBLE_ESCALATION' 'S17b: no eligible model -> STOP_NO_ELIGIBLE_ESCALATION'
Assert-True ('MODEL_ESCALATION_NONE_ELIGIBLE' -in $d.ReasonCodes) 'S17c: MODEL_ESCALATION_NONE_ELIGIBLE reason code present'
Assert-NullOrEmpty $d.NextModelId 'S17d: a stronger-but-ineligible model is never selected'

# -----------------------------------------------------------------------------
# S18 -- No eligible model -> conservative stop
# -----------------------------------------------------------------------------
Write-Output "== S18: no eligible model =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY'
$currentCandidate = New-TestCandidate -ProviderId 'prov-a' -ModelId 'sonnet' -ReasoningLevelsSupported @('LOW') -SelectedReasoningLevel 'LOW'
$inp = New-TestInput -CurrentAttempt $att -RecordedFailureCategory 'MODEL_QUALITY' `
    -EligibleCandidates @($currentCandidate)
$d = Get-TestDecision $inp
Assert-Equal $d.Action 'STOP_NO_ELIGIBLE_ESCALATION' 'S18a: no eligible candidate -> stop'
Assert-Equal $d.RequiresHuman $false 'S18b: conservative stop, no forced human gate'
Assert-NullOrEmpty $d.NextModelId 'S18c: no next model'

# -----------------------------------------------------------------------------
# S19 -- Provider availability / rate limit -> provider-route switch
# -----------------------------------------------------------------------------
Write-Output "== S19: provider route switch =="
foreach ($cat in @('RATE_LIMIT', 'PROVIDER_AVAILABILITY')) {
    $att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory $cat
    $inp = New-TestInput -CurrentAttempt $att -RecordedFailureCategory $cat `
        -EligibleCandidates @(New-TestCandidate -ProviderId 'prov-b' -ModelId 'opus')
    $d = Get-TestDecision $inp
    Assert-Equal $d.Action 'SWITCH_PROVIDER_ROUTE' "S19a ($cat): -> SWITCH_PROVIDER_ROUTE"
    Assert-Equal $d.NextProviderId 'prov-b' "S19b ($cat): next provider differs"
    Assert-True ($d.NextProviderId -ne $att.ProviderId) "S19c ($cat): route switched away from the failed provider"
}

# -----------------------------------------------------------------------------
# S20 -- Loop protection on the preserved escalation chain
# -----------------------------------------------------------------------------
Write-Output "== S20: escalation loop prevention =="
$chain = @(
    (New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ReasoningLevel 'LOW'),
    (New-TestAttempt -AttemptId 'A2' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ReasoningLevel 'MEDIUM'),
    (New-TestAttempt -AttemptId 'A3' -RetryNumber 2 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ReasoningLevel 'HIGH')
)
# The chain already contains (sonnet/MEDIUM); a fresh proposal of that exact
# combination is a revisit and must be refused.
$l1 = Test-AiEscalationLoop -Attempts $chain -ProposedProvider 'prov-a' -ProposedModel 'sonnet' -ProposedReasoningLevel 'MEDIUM'
Assert-Equal $l1.Cyclic $true 'S20a: exact (provider/model/reasoning) revisit -> cyclic'
# A never-tried combination is not cyclic.
$l2 = Test-AiEscalationLoop -Attempts $chain -ProposedProvider 'prov-b' -ProposedModel 'opus' -ProposedReasoningLevel 'HIGH'
Assert-Equal $l2.Cyclic $false 'S20b: a fresh combination is not cyclic'
# Engine integration: the chain contains a reasoning downgrade (A1 sonnet/MEDIUM,
# A2 sonnet/LOW). The one-step escalation from LOW proposes sonnet/MEDIUM, which
# was ALREADY attempted -- the finalize loop check refuses the revisit and emits
# LOOP_PREVENTED instead of looping forever.
$downgrade = @(
    (New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ReasoningLevel 'MEDIUM'),
    (New-TestAttempt -AttemptId 'A2' -RetryNumber 1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ReasoningLevel 'LOW')
)
$custom = New-EscalationPolicy -PolicyId 'escalation-test-loophigh' -MaxReasoningEscalations 3
$currentCandidate = New-TestCandidate -ProviderId 'prov-a' -ModelId 'sonnet' `
    -ReasoningLevelsSupported @('LOW','MEDIUM','HIGH') -SelectedReasoningLevel 'LOW'
$inp = New-TestInput -CurrentAttempt $downgrade[1] -AttemptChain @($downgrade[0]) `
    -RecordedFailureCategory 'MODEL_QUALITY' -EligibleCandidates @($currentCandidate)
$d = Get-TestDecision $inp -Policy $custom
Assert-Equal $d.Status 'STOP_NO_ELIGIBLE_ESCALATION' 'S20c: escalating to an already-attempted combination -> STOP_NO_ELIGIBLE_ESCALATION'
Assert-True ('LOOP_PREVENTED' -in $d.ReasonCodes) 'S20d: LOOP_PREVENTED reason code present'
Assert-NullOrEmpty $d.NextModelId 'S20e: no next route for a prevented loop'

# -----------------------------------------------------------------------------
# S21 -- Test-AiEscalationLoop: chain-level validation (no proposal)
# -----------------------------------------------------------------------------
Write-Output "== S21: chain loop-free validation =="
$clean = New-EscalationChain -Attempts @(
    (New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED'),
    (New-TestAttempt -AttemptId 'A2' -RetryNumber 1 -Result 'FAILED')
) -TaskId 'T-1'
Assert-Equal $clean.LoopFree $true 'S21a: strictly increasing retry chain is loop-free'
$dup = New-EscalationChain -Attempts @(
    (New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED'),
    (New-TestAttempt -AttemptId 'A1' -RetryNumber 1 -Result 'FAILED')
) -TaskId 'T-1'
Assert-Equal $dup.LoopFree $false 'S21b: duplicate AttemptId -> loop detected'
$back = New-EscalationChain -Attempts @(
    (New-TestAttempt -AttemptId 'A1' -RetryNumber 1 -Result 'FAILED'),
    (New-TestAttempt -AttemptId 'A2' -RetryNumber 0 -Result 'FAILED')
) -TaskId 'T-1'
Assert-Equal $back.LoopFree $true 'S21c: attempts are deterministically re-ordered (non-increasing input order is normalized; the chain stays loop-free)'
Assert-Equal $back.Attempts[0].AttemptId 'A2' 'S21d: the normalized chain is ordered by RetryNumber ascending'
Assert-Equal $back.Attempts[1].AttemptId 'A1' 'S21e: the normalized chain keeps a stable tie-break order'
$self = New-EscalationChain -Attempts @(
    (New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -EscalatedFromAttemptId 'A1')
) -TaskId 'T-1'
Assert-Equal $self.LoopFree $false 'S21f: self-escalation -> loop detected'

# -----------------------------------------------------------------------------
# S22 -- Cost-aware escalation via the DB-M16 engine (incremental + cumulative)
# -----------------------------------------------------------------------------
Write-Output "== S22: cost-aware escalation =="
$config = New-StandardCatalogue
$req = New-TestRequirement
$chain = @(
    New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 0.10 -EstimatedCost 0.10
)
$cost = Get-AiEscalationCost -ProviderId 'prov-a' -ModelId 'sonnet' -Requirement $req -Configuration $config `
    -Attempts $chain -RequestTimestampUtc '2026-08-30T12:00:00Z' -TimeBand 'DEFAULT' -TargetCurrency 'INR'
Assert-Not-Null $cost.NextAttemptCost 'S22a: a next-attempt cost is estimated (never invented)'
Assert-True ($cost.NextAttemptCost -gt 0) 'S22b: the next-attempt estimate is positive'
Assert-Equal $cost.NextCostCurrency 'INR' 'S22c: next cost is reported in INR (DB-M16 FX)'
Assert-Near $cost.CumulativeActualCost 0.10 0.0001 'S22d: cumulative actual cost sums the preserved chain'
Assert-True ($cost.CumulativeEstimatedCost -ge $cost.CumulativeActualCost) 'S22e: cumulative estimated >= cumulative actual (next attempt included)'
Assert-Equal $cost.NextCostUnknown $false 'S22f: cost is known, not unknown'
# unknown-price path is surfaced honestly, never invented
$costUnknown = Get-AiEscalationCost -ProviderId 'prov-a' -ModelId 'sonnet' `
    -Requirement $req -Configuration $null -Attempts $chain -RequestTimestampUtc '2026-08-30T12:00:00Z'
Assert-Equal $costUnknown.NextCostUnknown $true 'S22g: no configuration -> next cost unknown (no invented price)'
Assert-Null $costUnknown.NextAttemptCost 'S22h: no invented price when cost is unknown'
# engine decision surfaces the cost when a configuration is available (uses the
# costed chain attempt, so the cumulative actual cost is a real recorded value)
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -ActualCost 0.10 -EstimatedCost 0.10
$currentCandidate = New-TestCandidate -ProviderId 'prov-a' -ModelId 'sonnet' -ReasoningLevelsSupported @('LOW') -SelectedReasoningLevel 'LOW'
$inp = New-TestInput -CurrentAttempt $att -RecordedFailureCategory 'MODEL_QUALITY' `
    -EligibleCandidates @($currentCandidate, (New-TestCandidate -ProviderId 'prov-b' -ModelId 'opus')) `
    -Requirement $req -Configuration $config
$d = Get-TestDecision $inp
Assert-Not-Null $d.EstimatedNextAttemptCost 'S22i: a recommended decision carries the next-attempt cost (incremental, never hidden)'
Assert-Equal $d.NextCostCurrency 'INR' 'S22j: next cost currency is surfaced'
Assert-Near $d.CumulativeActualCost 0.10 0.0001 'S22k: cumulative actual cost is present on the decision (never hidden)'

# -----------------------------------------------------------------------------
# S23 -- Get-AiFailureCategory: deterministic classification
# -----------------------------------------------------------------------------
Write-Output "== S23: failure classification =="
$c1 = Get-AiFailureCategory -RecordedFailureCategory 'MODEL_QUALITY'
Assert-Equal $c1.Category 'MODEL_QUALITY' 'S23a: recorded MODEL_QUALITY stays MODEL_QUALITY'
Assert-Equal $c1.Class 'QUALITY' 'S23b: MODEL_QUALITY class = QUALITY'
$c2 = Get-AiFailureCategory -RecordedFailureCategory 'CONTEXT_FAILURE'
Assert-Equal $c2.Category 'CONTEXT_TOO_LARGE' 'S23c: CONTEXT_FAILURE maps to CONTEXT_TOO_LARGE'
$c3 = Get-AiFailureCategory -RecordedFailureCategory 'VALIDATION_FAILURE'
Assert-Equal $c3.Category 'VERIFICATION_FAILURE' 'S23d: VALIDATION_FAILURE maps to VERIFICATION_FAILURE'
$c4 = Get-AiFailureCategory -RecordedFailureCategory 'AUTHENTICATION'
Assert-Equal $c4.Category 'AUTHENTICATION' 'S23e: AUTHENTICATION stays AUTHENTICATION'
Assert-Equal $c4.Class 'AUTHENTICATION' 'S23f: authentication class is protected (never overridden by quality signals)'
$c5 = Get-AiFailureCategory -FailureCategory 'GOVERNANCE_BLOCKED'
Assert-Equal $c5.Class 'GOVERNANCE' 'S23g: explicit governance category is authoritative'
Assert-Equal $c5.Category 'GOVERNANCE_BLOCKED' 'S23h: explicit governance category preserved'
$c6 = Get-AiFailureCategory -RecordedFailureCategory 'MODEL_QUALITY' -VerificationResult 'FAILED'
Assert-Equal $c6.Category 'VERIFICATION_FAILURE' 'S23i: FAILED verification overrides a quality category (verification authoritative)'
$c7 = Get-AiFailureCategory -ClaudeReviewStatus 'FIX_REQUIRED'
Assert-Equal $c7.Category 'CLAUDE_REVIEW_FIX' 'S23j: FIX_REQUIRED review signal -> CLAUDE_REVIEW_FIX'
Assert-Throws { Get-AiFailureCategory -RecordedFailureCategory 'NOT_A_CATEGORY' } 'S23k: an unknown recorded category is never guessed (throws)'

# -----------------------------------------------------------------------------
# S24 -- Test-AiRetryAllowed: bounded, deterministic retry gates
# -----------------------------------------------------------------------------
Write-Output "== S24: retry gates =="
$pol = Get-DefaultEscalationPolicy
$r1 = Test-AiRetryAllowed -Category 'GOVERNANCE_BLOCKED' -AttemptNumber 2 -Policy $pol -Attempts @() -CurrentModelId 'sonnet' -LoopFree $true
Assert-Equal $r1.Allowed $false 'S24a: a governance failure is never retryable'
$r2 = Test-AiRetryAllowed -Category 'TIMEOUT' -AttemptNumber 6 -Policy $pol -Attempts @() -CurrentModelId 'sonnet' -LoopFree $true
Assert-Equal $r2.Allowed $false 'S24b: attempt number above MaxAttemptsPerTask -> not allowed'
$r3 = Test-AiRetryAllowed -Category 'TIMEOUT' -AttemptNumber 2 -Policy $pol -Attempts @() -CurrentModelId 'sonnet' -LoopFree $false
Assert-Equal $r3.Allowed $false 'S24c: a non-loop-free chain -> not allowed'
$r4 = Test-AiRetryAllowed -Category 'UNKNOWN_FAILURE' -AttemptNumber 2 -Policy $pol -Attempts @() -CurrentModelId 'sonnet' -LoopFree $true
Assert-Equal $r4.Allowed $false 'S24d: an unknown failure is never blindly retried'
$r5 = Test-AiRetryAllowed -Category 'TIMEOUT' -AttemptNumber 2 -Policy $pol -Attempts @() -CurrentModelId 'sonnet' -LoopFree $true
Assert-Equal $r5.Allowed $true 'S24e: a transient retry within limits is allowed'

# -----------------------------------------------------------------------------
# S25 -- Get-AiNextReasoningLevel: one-step, bounded, policy-respecting
# -----------------------------------------------------------------------------
Write-Output "== S25: reasoning level rules =="
$pol = Get-DefaultEscalationPolicy
$g1 = Get-AiNextReasoningLevel -CurrentLevel 'LOW' -SupportedLevels @('LOW','MEDIUM','HIGH') -ReasoningEscalationsUsed 0 -Policy $pol
Assert-Equal $g1.NextLevel 'MEDIUM' 'S25a: one step LOW -> MEDIUM'
$g2 = Get-AiNextReasoningLevel -CurrentLevel 'MEDIUM' -SupportedLevels @('LOW','MEDIUM','HIGH') -ReasoningEscalationsUsed 0 -Policy $pol
Assert-Equal $g2.NextLevel 'HIGH' 'S25b: one step MEDIUM -> HIGH'
$g3 = Get-AiNextReasoningLevel -CurrentLevel 'LOW' -SupportedLevels @('LOW','HIGH') -ReasoningEscalationsUsed 0 -Policy $pol
Assert-Equal $g3.NextLevel 'HIGH' 'S25c: LOW -> HIGH when MEDIUM is unsupported (still one logical step)'
$polNoIncrease = New-EscalationPolicy -PolicyId 'escalation-test-noreason' -AllowReasoningIncrease $false
$g4 = Get-AiNextReasoningLevel -CurrentLevel 'LOW' -SupportedLevels @('LOW','MEDIUM','HIGH') -ReasoningEscalationsUsed 0 -Policy $polNoIncrease
Assert-Equal $g4.Allowed $false 'S25d: reasoning increase disabled by policy -> blocked'

# -----------------------------------------------------------------------------
# S26 -- Export + Temporary DevBridge boundary
# -----------------------------------------------------------------------------
Write-Output "== S26: export + Temporary DevBridge boundary =="
$att = New-TestAttempt -AttemptId 'A1' -RetryNumber 0 -Result 'FAILED'
$d = Get-TestDecision (New-TestInput -CurrentAttempt $att -FailureCategory 'TIMEOUT')
$exportDir = Join-Path (Join-Path $script:Root 'state') 'ai-routing-escalation-decisions'
$exportPath = Join-Path $exportDir 'dbm20-test-export.json'
if (Test-Path -LiteralPath $exportPath) { Remove-Item -LiteralPath $exportPath -Force }
$exp = Export-AiEscalationDecision -Decision $d -OutputPath $exportPath
Assert-Equal $exp.Exported $true 'S26a: decision exports to a DB-M20-owned path'
Assert-True (Test-Path -LiteralPath $exp.Path) 'S26b: the exported file exists'
$json = Get-Content -LiteralPath $exp.Path -Raw | ConvertFrom-Json
Assert-Equal $json.Status $d.Status 'S26c: exported JSON round-trips the decision status'

# Temporary DevBridge boundary: refuses every non-DevBridge / protected target.
Assert-Throws { Export-AiEscalationDecision -Decision $d -OutputPath 'C:\Personal\Nexus.Developer\anything.json' -Force } `
    'S26d: a Nexus-owned path is refused (no Nexus files are ever written)'
Assert-Throws { Export-AiEscalationDecision -Decision $d -OutputPath 'C:\Personal\OtherProject\out.json' -Force } `
    'S26e: a path outside the DevBridge root is refused'
Assert-Throws { Export-AiEscalationDecision -Decision $d -OutputPath (Join-Path $script:Root 'tasks\ROUTING_RECOMMENDATION.md') -Force } `
    'S26f: a live handoff artifact is refused (live handoff files are never modified)'
Assert-Throws { Export-AiEscalationDecision -Decision $d -OutputPath (Join-Path $script:Root 'state\db-m20-result.json') -Force } `
    'S26g: the milestone result file is refused for a decision export'
$checkOk = Test-DbM20ExportPathAllowed (Join-Path (Join-Path $script:Root 'state') 'ai-routing-escalation-decisions\ok.json')
Assert-Equal $checkOk.Allowed $true 'S26h: a DB-M20-owned state path is allowed'

# No Nexus assembly / architectural coupling in the DB-M20 LIBRARY sources.
# (The test file is excluded: it legitimately carries the literal
# 'Nexus.Developer' as a refusal test input and the EscalationExport comment
# documents the refusal -- neither is a coupling. The boundary is enforced, not
# imported.)
$dbM20Libs = @(
    (Join-Path $PSScriptRoot 'EscalationPolicy.ps1'),
    (Join-Path $PSScriptRoot 'EscalationContracts.ps1'),
    (Join-Path $PSScriptRoot 'FailureClassification.ps1'),
    (Join-Path $PSScriptRoot 'EscalationRetry.ps1'),
    (Join-Path $PSScriptRoot 'EscalationCandidates.ps1'),
    (Join-Path $PSScriptRoot 'EscalationCost.ps1'),
    (Join-Path $PSScriptRoot 'EscalationEngine.ps1'),
    (Join-Path $PSScriptRoot 'EscalationExport.ps1')
)
# Coupling tokens: loading an assembly (Add-Type), an assembly-qualified
# [Nexus.*] type reference, a Nexus namespace import, or static Nexus:: access.
$hasNexusAssembly = $false
foreach ($src in $dbM20Libs) {
    $text = Get-Content -LiteralPath $src -Raw
    if ($text -match 'Add-Type' -or $text -match '\[Nexus\.' -or $text -match 'using\s+namespace\s+Nexus' -or $text -match 'Nexus::') { $hasNexusAssembly = $true }
}
Assert-True (-not $hasNexusAssembly) 'S26i: DB-M20 library sources carry no Nexus assembly coupling (no Add-Type, no [Nexus.* type, no Nexus namespace import / static access)'
# Execution levers that could invoke/reuse an external component at run time
# (no future Nexus reuse by sub-process / reflection / expression).
$hasExecLever = $false
foreach ($src in $dbM20Libs) {
    if ((Get-Content -LiteralPath $src -Raw) -match 'Invoke-Expression|Start-Process|Start-Job|Invoke-Command|System\.Reflection') { $hasExecLever = $true }
}
Assert-True (-not $hasExecLever) 'S26j: DB-M20 library sources expose no execution lever (no Invoke-Expression / Start-Process / Start-Job / Invoke-Command / reflection -> no future Nexus reuse via runtime execution)'

# Export refuses overwriting an existing file without -Force (append-only default).
$expAgain = Export-AiEscalationDecision -Decision $d -OutputPath $exportPath -Force
Assert-Equal $expAgain.Exported $true 'S26k: -Force allows re-export to the same DB-M20-owned path'
Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Output ("DB-M20 ESCALATION RESULT: {0} assertions, {1} failures" -f $script:Results, $script:Fails)
if ($script:Fails -gt 0) { exit 1 }
exit 0

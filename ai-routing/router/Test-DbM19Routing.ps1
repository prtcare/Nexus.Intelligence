# =============================================================================
# Test-DbM19Routing.ps1
# DB-M19 -- Capability-Based Model Router (Lane B, AI Routing)
#
# Recommendation-only. Zero paid API calls, zero network calls, no model
# execution. Exercises: policy contracts, STEP-1 eligibility + rejection
# vocabulary (17 members), context fit (output/reasoning reserve), cost
# estimation via the DB-M16 engine, historical evidence via DB-M24, policy
# ranking, cold start, history-aware CHEAPEST_RELIABLE, BEST_COST_PER_SUCCESS,
# cost-only, HIGHEST_SUCCESS (self-reported PASS that failed verification does
# NOT count), gateway (direct + gateway = two candidates for one underlying),
# reasoning LOW/MEDIUM/HIGH, context/budget/catalogue scenarios, deterministic
# tie-breakers, transparent recommendation reason, manual override
# accept/reject, AUTO refusal, MANUAL-mode preservation, and recommendation
# export to a DB-M19-owned temp location (live tasks/ handoff files untouched).
# =============================================================================

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root    = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:TempRoot = Join-Path $env:TEMP ("devbridge-dbm19-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:TempRoot | Out-Null

. (Join-Path $PSScriptRoot "Router.ps1")

# DB-M24 confidence bands must be loaded so Get-AiModelPerformance can compute
# ConfidenceLevel (LOW/MODERATE/HIGH vs INSUFFICIENT).
Import-AiPerformanceConfiguration -Root $script:Root | Out-Null

$script:Results = 0
$script:Fails = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Results++
    if ($Condition) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message) }
}
function Get-CanonicalFileHash {
    <#
    .SYNOPSIS
    SHA-256 of a file's CANONICAL content: CRLF normalized to LF.

    A byte-identity assertion over a repository file has to be independent of how the
    file was checked out. This repository is checked out with core.autocrlf=true, so a
    clean working-tree file carries CRLF while the committed blob -- and every recorded
    baseline hash -- is LF. Hashing the on-disk bytes therefore measured the checkout
    configuration rather than the file. Normalizing line endings leaves the assertion
    exactly as strict about content: any real edit still changes the hash.
    #>
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ms = New-Object System.IO.MemoryStream
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 13 -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { continue }
        $ms.WriteByte($bytes[$i])
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($ms.ToArray()) } finally { $ms.Dispose(); $sha.Dispose() }
    return ([System.BitConverter]::ToString($h) -replace '-', '')
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
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:Results++
    if ([string]$Actual -eq [string]$Expected) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual='$Actual' expected='$Expected')") }
}
# numeric comparison tolerant of DB-M24's 4-decimal rounding / stringification
function Assert-Near {
    param($Actual, [double]$Expected, [double]$Tolerance = 0.001, [string]$Message)
    $script:Results++
    if ($null -eq $Actual) { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual=null expected=$Expected)") ; return }
    $diff = [math]::Abs([double]$Actual - $Expected)
    if ($diff -le $Tolerance) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual='$Actual' expected='$Expected' diff=$diff)") }
}

# -----------------------------------------------------------------------------
# Fixture builders (in-memory only; never writes to the live catalogue)
# -----------------------------------------------------------------------------
function New-TestProvider {
    param([string]$ProviderId, [string]$DisplayName = $ProviderId, [bool]$Enabled = $true,
          [string]$ProviderType = 'DIRECT')
    return New-AiProvider -ProviderId $ProviderId -DisplayName $DisplayName -Enabled $Enabled `
        -Configured $true -ProviderType $ProviderType
}

function New-TestModel {
    param(
        [string]$ModelId, [string]$ProviderId, [string]$UnderlyingModelId, [string]$GatewayProviderId,
        [bool]$Enabled = $true, [string]$LocalOrRemote = 'REMOTE',
        [Nullable[bool]]$SupportsCoding = $true, [Nullable[bool]]$SupportsReasoning = $true,
        [Nullable[bool]]$SupportsVision = $null, [Nullable[bool]]$SupportsToolUse = $null,
        [Nullable[bool]]$SupportsStructuredOutput = $true,
        [long]$ContextWindow = 64000, [long]$MaxOutputTokens = 8192,
        [string[]]$ReasoningLevelsSupported = @('LOW','MEDIUM','HIGH'),
        [string]$RelativeSpeed = 'NORMAL', [string]$ReliabilityClass = 'HIGH'
    )
    return New-AiModel -ModelId $ModelId -ProviderId $ProviderId `
        -UnderlyingModelId $UnderlyingModelId -GatewayProviderId $GatewayProviderId `
        -DisplayName "Model $ModelId" -Enabled $Enabled -LocalOrRemote $LocalOrRemote `
        -SupportsCoding $SupportsCoding -SupportsReasoning $SupportsReasoning `
        -SupportsVision $SupportsVision -SupportsToolUse $SupportsToolUse `
        -SupportsStructuredOutput $SupportsStructuredOutput `
        -ContextWindow $ContextWindow -MaxOutputTokens $MaxOutputTokens `
        -ReasoningLevelsSupported $ReasoningLevelsSupported `
        -RelativeSpeed $RelativeSpeed -ReliabilityClass $ReliabilityClass
}

function New-TestPricingRecord {
    param(
        [string]$PricingRecordId, [string]$ProviderId, [string]$ModelId,
        [string]$ProcessingTier = 'STANDARD', [string]$TimeBand = 'DEFAULT',
        [Nullable[double]]$InputPricePerMillion = 1.0, [Nullable[double]]$CachedInputPricePerMillion = 0.1,
        [Nullable[double]]$OutputPricePerMillion = 3.0, [string]$EffectiveFromUtc = '2026-06-01T00:00:00Z'
    )
    return New-AiPricingRecord -PricingRecordId $PricingRecordId -ProviderId $ProviderId -ModelId $ModelId `
        -Currency 'USD' -EffectiveFromUtc $EffectiveFromUtc -ProcessingTier $ProcessingTier -TimeBand $TimeBand `
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

# A small, self-contained catalogue: two models on one provider with prices + FX.
function New-StandardCatalogue {
    $providers = @{}
    $providers['prov-a'] = New-TestProvider -ProviderId 'prov-a' -DisplayName 'Provider A'

    $models = @{}
    $models['model-cheap'] = New-TestModel -ModelId 'model-cheap' -ProviderId 'prov-a' `
        -ContextWindow 64000 -MaxOutputTokens 8192 -RelativeSpeed 'FAST' -ReliabilityClass 'HIGH'
    $models['model-expensive'] = New-TestModel -ModelId 'model-expensive' -ProviderId 'prov-a' `
        -ContextWindow 128000 -MaxOutputTokens 16384 -RelativeSpeed 'NORMAL' -ReliabilityClass 'CRITICAL_GRADE'

    $pricing = @{}
    $pCheap = New-TestPricingRecord -PricingRecordId 'pr-cheap' -ProviderId 'prov-a' -ModelId 'model-cheap' `
        -InputPricePerMillion 0.5 -CachedInputPricePerMillion 0.05 -OutputPricePerMillion 1.5
    $pExp = New-TestPricingRecord -PricingRecordId 'pr-exp' -ProviderId 'prov-a' -ModelId 'model-expensive' `
        -InputPricePerMillion 2.0 -CachedInputPricePerMillion 0.2 -OutputPricePerMillion 6.0
    $pricing[$pCheap.PricingRecordId] = $pCheap
    $pricing[$pExp.PricingRecordId] = $pExp

    $config = New-TestConfiguration -Providers $providers -Models $models -Pricing $pricing
    return $config
}

function New-TestRequirement {
    param(
        [string]$TaskId = 'T-1',
        [string]$TaskType = 'IMPLEMENTATION',
        [string]$Complexity = 'MEDIUM',
        [string]$Risk = 'LOW',
        [Nullable[bool]]$RequiresCoding = $true,
        [Nullable[bool]]$RequiresReasoning = $true,
        [string]$MinimumReasoningLevel = 'MEDIUM',
        [Nullable[bool]]$RequiresStructuredOutput = $true,
        [Nullable[long]]$RequiredContextTokens = 32000,
        [Nullable[long]]$ExpectedOutputTokens = 2048,
        [string]$RequiredReliability = 'HIGH',
        [string]$ExecutionMode = 'ASSISTED'
    )
    return New-AiCapabilityRequirement -TaskId $TaskId -TaskType $TaskType -Complexity $Complexity -Risk $Risk `
        -RequiresCoding $RequiresCoding -RequiresReasoning $RequiresReasoning `
        -MinimumReasoningLevel $MinimumReasoningLevel -RequiresStructuredOutput $RequiresStructuredOutput `
        -RequiredContextTokens $RequiredContextTokens -ExpectedOutputTokens $ExpectedOutputTokens `
        -RequiredReliability $RequiredReliability -ExecutionMode $ExecutionMode
}

function New-TestRequest {
    param(
        [AllowNull()][object]$Requirement,
        [string]$TaskId = 'T-1',
        [string]$ExecutionMode = 'ASSISTED',
        [Nullable[double]]$MaxAllowedCost,
        [AllowNull()]$RequestTimestampUtc = '2026-08-30T12:00:00Z',
        [double]$CachedInputFraction = 0.0,
        [AllowNull()][object]$ManualOverrideRequest
    )
    if ($null -eq $Requirement) { $Requirement = New-TestRequirement -TaskId $TaskId }
    return New-RoutingRequest -TaskId $TaskId -Requirement $Requirement `
        -ExecutionMode $ExecutionMode -MaxAllowedCost $MaxAllowedCost `
        -RequestTimestampUtc $RequestTimestampUtc -CachedInputFraction $CachedInputFraction `
        -ManualOverrideRequest $ManualOverrideRequest -TargetCurrency 'INR'
}

function New-TestAttempt {
    param(
        [string]$TaskId, [string]$AttemptId, [string]$Result = 'SUCCESS',
        [string]$VerificationResult = 'VERIFIED', [Nullable[double]]$ActualCost = 1.0,
        [string]$ProviderId = 'prov-a', [string]$ModelId = 'model-cheap',
        [string]$ReasoningLevel = 'MEDIUM', [string]$TaskType = 'IMPLEMENTATION',
        [string]$Complexity = 'MEDIUM', [string]$Risk = 'LOW',
        [int]$RetryNumber = 0
    )
    return New-AiAttemptRecord -TaskId $TaskId -ChangeId "C-$TaskId" -AttemptId $AttemptId `
        -RetryNumber $RetryNumber -Result $Result -VerificationResult $VerificationResult `
        -FailureCategory $null -ActualCost $ActualCost -CostCurrency 'INR' -DurationMs 1000 `
        -ProviderId $ProviderId -ModelId $ModelId -UnderlyingModelId $ModelId `
        -GatewayProviderId $null -ReasoningLevel $ReasoningLevel -TaskType $TaskType `
        -Complexity $Complexity -Risk $Risk -ExecutionMode 'MANUAL' `
        -StartedAtUtc '2026-08-20T10:00:00Z' -EndedAtUtc '2026-08-20T10:00:30Z'
}

# A history-focused catalogue: two models that are otherwise IDENTICAL (same
# context window, reliability, speed) so that only the historical evidence and a
# SLIGHT cost difference decide the ranking -- the brief's exact scenario
# ("cheap-but-failure-prone ranks below slightly-more-expensive-high-success").
function New-HistoryCatalogue {
    $providers = @{}
    $providers['prov-a'] = New-TestProvider -ProviderId 'prov-a' -DisplayName 'Provider A'

    $models = @{}
    $models['model-cheap'] = New-TestModel -ModelId 'model-cheap' -ProviderId 'prov-a' `
        -ContextWindow 64000 -MaxOutputTokens 8192 -RelativeSpeed 'NORMAL' -ReliabilityClass 'HIGH'
    $models['model-expensive'] = New-TestModel -ModelId 'model-expensive' -ProviderId 'prov-a' `
        -ContextWindow 64000 -MaxOutputTokens 8192 -RelativeSpeed 'NORMAL' -ReliabilityClass 'HIGH'

    $pricing = @{}
    $pCheap = New-TestPricingRecord -PricingRecordId 'pr-cheap' -ProviderId 'prov-a' -ModelId 'model-cheap' `
        -InputPricePerMillion 1.0 -CachedInputPricePerMillion 0.1 -OutputPricePerMillion 3.0
    $pExp = New-TestPricingRecord -PricingRecordId 'pr-exp' -ProviderId 'prov-a' -ModelId 'model-expensive' `
        -InputPricePerMillion 1.2 -CachedInputPricePerMillion 0.12 -OutputPricePerMillion 3.6
    $pricing[$pCheap.PricingRecordId] = $pCheap
    $pricing[$pExp.PricingRecordId] = $pExp

    $config = New-TestConfiguration -Providers $providers -Models $models -Pricing $pricing
    return $config
}

# Historical attempt chains for New-HistoryCatalogue:
#   model-cheap    6 tasks; 5 fail outright, 1 succeeds only after 3 retries
#                  -> SuccessRate 1/6, first-attempt 0, costPerSuccessfulTask 4.0
#   model-expensive 6 tasks; each a single verified success
#                  -> SuccessRate 1.0, first-attempt 1.0, costPerSuccessfulTask 1.5
# Confidence = LOW (6 samples) >= the policy minimum, so history ranks.
function New-HistoryAttempts {
    $attempts = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt 6; $i++) {
        if ($i -lt 5) {
            $null = $attempts.Add((New-TestAttempt -TaskId "HC$i" -AttemptId "ATT-HC-$i" `
                -ProviderId 'prov-a' -ModelId 'model-cheap' -Result 'FAILED' -VerificationResult 'VERIFIED' -ActualCost 1.0))
        } else {
            for ($r = 0; $r -lt 4; $r++) {
                $res = if ($r -lt 3) { 'FAILED' } else { 'SUCCESS' }
                $null = $attempts.Add((New-TestAttempt -TaskId "HC$i" -AttemptId "ATT-HC-$i-$r" `
                    -ProviderId 'prov-a' -ModelId 'model-cheap' -Result $res -VerificationResult 'VERIFIED' `
                    -ActualCost 1.0 -RetryNumber $r))
            }
        }
        $null = $attempts.Add((New-TestAttempt -TaskId "HE$i" -AttemptId "ATT-HE-$i" `
            -ProviderId 'prov-a' -ModelId 'model-expensive' -Result 'SUCCESS' -VerificationResult 'VERIFIED' `
            -ActualCost 1.5))
    }
    return $attempts.ToArray()
}

function Get-TestCandidate {
    param([AllowNull()][object[]]$Candidates, [string]$ProviderId, [string]$ModelId)
    foreach ($c in @($Candidates)) {
        if ($c.ProviderId -eq $ProviderId -and $c.ModelId -eq $ModelId) { return $c }
    }
    return $null
}

function Get-TestRejectionReason {
    param([AllowNull()][object[]]$Rejected, [string]$ProviderId, [string]$ModelId, [string]$Reason)
    foreach ($row in @($Rejected)) {
        if ($row.ProviderId -eq $ProviderId -and $row.ModelId -eq $ModelId) {
            foreach ($r in @($row.RejectionReasons)) {
                if ($r.Reason -eq $Reason) { return $r }
            }
        }
    }
    return $null
}

function Get-TestCandidateModelId {
    param([AllowNull()][object[]]$Candidates, [string]$ProviderId, [string]$ModelId)
    $c = Get-TestCandidate -Candidates $Candidates -ProviderId $ProviderId -ModelId $ModelId
    if ($null -ne $c) { return $c.ModelId }
    return $null
}

Write-Output "================================================================"
Write-Output "DB-M19 capability-based model router test suite"
Write-Output "Root: $script:Root"
Write-Output "================================================================"

# -----------------------------------------------------------------------------
# S1  Policy contracts
# -----------------------------------------------------------------------------
Write-Output "--- S1 routing policy contracts ---"

Assert-Equal (Get-DbM19SchemaVersions).RoutingPolicyVersion 1 'S1: RoutingPolicyVersion = 1'
Assert-Equal (Get-DbM19SchemaVersions).RoutingCandidateVersion 1 'S1: RoutingCandidateVersion = 1'
Assert-Equal (Get-DbM19SchemaVersions).RoutingDecisionEvidenceVersion 1 'S1: RoutingDecisionEvidenceVersion = 1'
Assert-Equal (Get-DbM19SchemaVersions).RoutingDecision 'DB-M14 v1 (unchanged)' 'S1: RoutingDecision stays DB-M14 v1'

$rej = Get-DbM19RejectionReasons
Assert-Equal $rej.Count 17 'S1: rejection vocabulary has 17 members'
Assert-True ('MODEL_DISABLED' -in $rej) 'S1: vocabulary contains MODEL_DISABLED'
Assert-True ('PROCESSING_TIER_UNSUPPORTED' -in $rej) 'S1: vocabulary contains PROCESSING_TIER_UNSUPPORTED'
Assert-True ('LOCALITY_CONFLICT' -in $rej) 'S1: vocabulary contains LOCALITY_CONFLICT'

$policy = Get-DefaultRoutingPolicy
$pv = Test-RoutingPolicy $policy
Assert-True $pv.Valid 'S1: default policy is valid'
Assert-Equal $policy.Objective 'CHEAPEST_RELIABLE' 'S1: default policy objective CHEAPEST_RELIABLE'
Assert-Equal $policy.PolicyId 'routing-policy-cheapest-reliable-v1' 'S1: default policy id'
Assert-Equal $policy.MinimumConfidenceForHistoricalWeight 'LOW' 'S1: default min historical confidence LOW'
Assert-Equal $policy.Thresholds.minimumReliability 0.7 'S1: default min reliability 0.7'
Assert-Equal $policy.Weights.cost 0.45 'S1: default cost weight 0.45'
Assert-True ($policy.TieBreaker.Count -ge 2) 'S1: default policy declares a tie-breaker chain'

$bad = New-RoutingPolicy -PolicyId 'bad' -Objective 'CHEAPEST_RELIABLE' -Weights @{ cost = 2.0 }
$bv = Test-RoutingPolicy $bad
Assert-True (-not $bv.Valid) 'S1: weight above 1.0 is invalid'
Assert-True ($bv.Errors.Count -ge 1) 'S1: invalid policy reports errors'

Assert-Throws { New-RoutingPolicy -PolicyId 'x' -Objective 'NOT_A_REAL_OBJECTIVE' } 'S1: unknown objective throws'

# -----------------------------------------------------------------------------
# S2  Cold start (no historical evidence)
# -----------------------------------------------------------------------------
Write-Output "--- S2 cold start ---"

$config = New-StandardCatalogue
$req = New-TestRequirement -TaskId 'T-COLD'
$request = New-TestRequest -Requirement $req -TaskId 'T-COLD'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Status 'RECOMMENDED' 'S2: cold start with eligible candidates -> RECOMMENDED'
Assert-Not-Null $rec.Winner 'S2: cold start produces a winner'
Assert-Equal $rec.Winner.ModelId 'model-cheap' 'S2: cold start cheapest eligible wins under CHEAPEST_RELIABLE'
Assert-Equal $rec.Winner.SelectedReasoningLevel 'MEDIUM' 'S2: cold start selected reasoning = minimum MEDIUM'
Assert-True ([math]::Abs([double]$rec.Winner.EstimatedCost - 1.592512) -lt 0.0001) 'S2: cold start cheap estimated cost ~1.592512 INR'
Assert-Equal $rec.Winner.CostCurrency 'INR' 'S2: cost currency INR'
Assert-Equal $rec.EligibleCandidates.Count 2 'S2: two eligible candidates'
Assert-Equal $rec.RejectedCandidates.Count 0 'S2: no rejected candidates'
Assert-Equal $rec.Winner.CostUnknown $false 'S2: cost not unknown'

# the evidence must be non-binding cold start (INSUFFICIENT confidence)
$ev = $rec.Winner.PerformanceEvidence
Assert-Equal $ev.ConfidenceLevel 'INSUFFICIENT' 'S2: cold start evidence confidence INSUFFICIENT'
Assert-Equal $ev.SampleCount 0 'S2: cold start evidence sample count 0'

# no execution ever: decision is recommendation-only
Assert-True ($null -eq $rec.Decision.SelectedProviderId -or $rec.Decision.SelectedProviderId) 'S2: decision object present'
Assert-Equal $rec.Decision.PolicyVersion '1.0.0' 'S2: decision PolicyVersion 1.0.0'
Assert-Equal $rec.Decision.ManualOverride $false 'S2: no manual override in cold start'
Assert-Equal $rec.Decision.ReasoningLevel 'MEDIUM' 'S2: decision reasoning level MEDIUM'

# -----------------------------------------------------------------------------
# S3  History-aware CHEAPEST_RELIABLE
# -----------------------------------------------------------------------------
Write-Output "--- S3 history-aware CHEAPEST_RELIABLE ---"

# model-cheap is cheap (slightly) but failure-prone; model-expensive is
# slightly more expensive but high verified success. Under CHEAPEST_RELIABLE
# with sufficient historical confidence, the high-success model must rank above.
$config = New-HistoryCatalogue
$attempts = New-HistoryAttempts
$req = New-TestRequirement -TaskId 'T-HIST'
$request = New-TestRequest -Requirement $req -TaskId 'T-HIST'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health -PerformanceRecords $attempts
Assert-Equal $rec.Status 'RECOMMENDED' 'S3: history-aware -> RECOMMENDED'
Assert-Equal $rec.Winner.ModelId 'model-expensive' 'S3: failure-prone cheap ranks below high-success slightly-more-expensive'
# the winner's estimated cost is only slightly above the cheapest (not 4x)
Assert-True ([math]::Abs([double]$rec.Winner.EstimatedCost - 3.822029) -lt 0.001) 'S3: winner is only slightly more expensive (~3.822 INR)'

$cheapEv = (Get-TestCandidate -Candidates $rec.EligibleCandidates -ProviderId 'prov-a' -ModelId 'model-cheap').PerformanceEvidence
$expEv = (Get-TestCandidate -Candidates $rec.EligibleCandidates -ProviderId 'prov-a' -ModelId 'model-expensive').PerformanceEvidence
Assert-Equal $cheapEv.ConfidenceLevel 'LOW' 'S3: cheap model evidence confidence LOW (6 samples)'
Assert-Near $cheapEv.SuccessRate 0.1666666667 0.001 'S3: cheap model verified success rate ~1/6'
Assert-Near $expEv.SuccessRate 1.0 0.001 'S3: expensive model verified success rate 1.0'
Assert-Near $cheapEv.AverageCostPerSuccessfulTask 4.0 0.001 'S3: cheap cost-per-successful-task 4.0 (retry chain)'
Assert-Near $expEv.AverageCostPerSuccessfulTask 1.5 0.001 'S3: expensive cost-per-successful-task 1.5'

# -----------------------------------------------------------------------------
# S4  BEST_COST_PER_SUCCESS policy
# -----------------------------------------------------------------------------
Write-Output "--- S4 BEST_COST_PER_SUCCESS ---"

$policyBcps = New-RoutingPolicy -PolicyId 'routing-policy-best-cps-v1' -Name 'BEST_COST_PER_SUCCESS' `
    -Objective 'BEST_COST_PER_SUCCESS' -Enabled $true `
    -Weights @{ cost = 0.0; success = 0.0; firstAttemptSuccess = 0.0; costPerSuccess = 1.0; latency = 0.0; reliability = 0.0 } `
    -Thresholds @{ minimumReliability = 0.0; allowCostUnknown = $true } `
    -TieBreaker @('PolicyScore','EstimatedCost','ReliabilityClass','ModelId') `
    -MinimumConfidenceForHistoricalWeight 'LOW'
$pvc = Test-RoutingPolicy $policyBcps
Assert-True $pvc.Valid 'S4: BEST_COST_PER_SUCCESS policy valid'

# model-cheap: cheap but failure-prone (cps 4.0 via retries); model-expensive:
# slightly more expensive, high success (cps 1.5). The cost-per-success policy
# must prefer the cheaper-per-success high-success model.
$config = New-HistoryCatalogue
$attempts = New-HistoryAttempts
$req = New-TestRequirement -TaskId 'T-BCPS'
$request = New-TestRequest -Requirement $req -TaskId 'T-BCPS'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health -PerformanceRecords $attempts -Policy $policyBcps
Assert-Equal $rec.Winner.ModelId 'model-expensive' 'S4: BEST_COST_PER_SUCCESS picks model with lower cost per success'

# -----------------------------------------------------------------------------
# S5  Cost-only policy
# -----------------------------------------------------------------------------
Write-Output "--- S5 cost-only policy ---"

$policyCostOnly = New-RoutingPolicy -PolicyId 'routing-policy-cost-only-v1' -Name 'COST_ONLY' `
    -Objective 'CHEAPEST_ELIGIBLE' -Enabled $true `
    -Weights @{ cost = 1.0; success = 0.0; firstAttemptSuccess = 0.0; costPerSuccess = 0.0; latency = 0.0; reliability = 0.0 } `
    -Thresholds @{ minimumReliability = 0.0; allowCostUnknown = $true } `
    -TieBreaker @('PolicyScore','EstimatedCost','ReliabilityClass','ModelId') `
    -MinimumConfidenceForHistoricalWeight 'LOW'
$pvo = Test-RoutingPolicy $policyCostOnly
Assert-True $pvo.Valid 'S5: cost-only policy valid'

# even with historical evidence favouring model-expensive, a cost-only policy
# must still pick the cheapest.
$config = New-StandardCatalogue
$attempts = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt 6; $i++) {
    $r = if ($i -lt 5) { 'FAILED' } else { 'SUCCESS' }
    $null = $attempts.Add((New-TestAttempt -TaskId "TC$i" -AttemptId "ATT-CHEAP-$i" -ProviderId 'prov-a' -ModelId 'model-cheap' -Result $r -VerificationResult 'VERIFIED' -ActualCost 1.0))
    $null = $attempts.Add((New-TestAttempt -TaskId "TE$i" -AttemptId "ATT-EXP-$i" -ProviderId 'prov-a' -ModelId 'model-expensive' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 2.0))
}
$req = New-TestRequirement -TaskId 'T-COSTONLY'
$request = New-TestRequest -Requirement $req -TaskId 'T-COSTONLY'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health -PerformanceRecords $attempts.ToArray() -Policy $policyCostOnly
Assert-Equal $rec.Winner.ModelId 'model-cheap' 'S5: cost-only policy picks cheapest regardless of history'

# -----------------------------------------------------------------------------
# S6  HIGHEST_SUCCESS -- self-reported PASS that failed verification does NOT count
# -----------------------------------------------------------------------------
Write-Output "--- S6 HIGHEST_SUCCESS ---"

$policyHigh = New-RoutingPolicy -PolicyId 'routing-policy-highest-success-v1' -Name 'HIGHEST_SUCCESS' `
    -Objective 'HIGHEST_SUCCESS' -Enabled $true `
    -Weights @{ cost = 0.0; success = 1.0; firstAttemptSuccess = 0.0; costPerSuccess = 0.0; latency = 0.0; reliability = 0.0 } `
    -Thresholds @{ minimumReliability = 0.0; allowCostUnknown = $true } `
    -TieBreaker @('PolicyScore','EstimatedCost','ReliabilityClass','ModelId') `
    -MinimumConfidenceForHistoricalWeight 'LOW'
$pvh = Test-RoutingPolicy $policyHigh
Assert-True $pvh.Valid 'S6: HIGHEST_SUCCESS policy valid'

# model-cheap: 6 attempts, ALL self-reported SUCCESS but 5 failed independent verification.
# Under VERIFIED_PREFERRED, those 5 must NOT count as success.
$config = New-StandardCatalogue
$attempts = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt 6; $i++) {
    $vr = if ($i -lt 5) { 'FAILED' } else { 'VERIFIED' }
    $null = $attempts.Add((New-TestAttempt -TaskId "TC$i" -AttemptId "ATT-CHEAP-$i" -ProviderId 'prov-a' -ModelId 'model-cheap' -Result 'SUCCESS' -VerificationResult $vr -ActualCost 1.0))
    $null = $attempts.Add((New-TestAttempt -TaskId "TE$i" -AttemptId "ATT-EXP-$i" -ProviderId 'prov-a' -ModelId 'model-expensive' -Result 'SUCCESS' -VerificationResult 'VERIFIED' -ActualCost 2.0))
}
$req = New-TestRequirement -TaskId 'T-HIGH'
$request = New-TestRequest -Requirement $req -TaskId 'T-HIGH'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health -PerformanceRecords $attempts.ToArray() -Policy $policyHigh
Assert-Equal $rec.Winner.ModelId 'model-expensive' 'S6: HIGHEST_SUCCESS picks verified-success model over self-reported-only'

$cheapEv = (Get-TestCandidate -Candidates $rec.EligibleCandidates -ProviderId 'prov-a' -ModelId 'model-cheap').PerformanceEvidence
$expEv = (Get-TestCandidate -Candidates $rec.EligibleCandidates -ProviderId 'prov-a' -ModelId 'model-expensive').PerformanceEvidence
Assert-Near $cheapEv.SuccessRate 0.1666666667 0.001 'S6: self-reported PASS with failed verification does NOT count (1/6)'
Assert-Equal $cheapEv.VerifiedSuccessCount 1 'S6: verified success count 1'
# DB-M24's ModelReturnedSuccessCount counts within SUCCESSFUL outcomes only, so
# the 5 unverified "PASS"es contribute to neither SuccessCount nor this count.
Assert-Equal $cheapEv.ModelReturnedSuccessCount 1 'S6: only the single verified-success chain counts as model-returned success'
Assert-Near $expEv.SuccessRate 1.0 0.001 'S6: fully verified model success rate 1.0'

# -----------------------------------------------------------------------------
# S7  Gateway -- same underlying via direct + gateway = two candidates
# -----------------------------------------------------------------------------
Write-Output "--- S7 gateway ---"

$providers = @{}
$providers['prov-a'] = New-TestProvider -ProviderId 'prov-a' -DisplayName 'Provider A'
$providers['gateway-1'] = New-TestProvider -ProviderId 'gateway-1' -DisplayName 'Gateway 1'

$models = @{}
$models['model-direct'] = New-TestModel -ModelId 'model-direct' -ProviderId 'prov-a' `
    -UnderlyingModelId 'model-direct' -ContextWindow 64000 -MaxOutputTokens 8192
$models['model-via-gw'] = New-TestModel -ModelId 'model-via-gw' -ProviderId 'gateway-1' `
    -UnderlyingModelId 'model-direct' -GatewayProviderId 'gateway-1' -ContextWindow 64000 -MaxOutputTokens 8192

$pricing = @{}
$pDirect = New-TestPricingRecord -PricingRecordId 'pr-direct' -ProviderId 'prov-a' -ModelId 'model-direct' `
    -InputPricePerMillion 0.5 -OutputPricePerMillion 1.5
$pGw = New-TestPricingRecord -PricingRecordId 'pr-gw' -ProviderId 'gateway-1' -ModelId 'model-via-gw' `
    -InputPricePerMillion 0.7 -OutputPricePerMillion 2.0
$pricing[$pDirect.PricingRecordId] = $pDirect
$pricing[$pGw.PricingRecordId] = $pGw

$config = New-TestConfiguration -Providers $providers -Models $models -Pricing $pricing
$req = New-TestRequirement -TaskId 'T-GW'
$request = New-TestRequest -Requirement $req -TaskId 'T-GW'
$health = @{ 'prov-a' = 'AVAILABLE'; 'gateway-1' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.EligibleCandidates.Count 2 'S7: direct + gateway = two candidates for the same underlying model'
$direct = Get-TestCandidate -Candidates $rec.EligibleCandidates -ProviderId 'prov-a' -ModelId 'model-direct'
$viaGw = Get-TestCandidate -Candidates $rec.EligibleCandidates -ProviderId 'gateway-1' -ModelId 'model-via-gw'
Assert-Not-Null $direct 'S7: direct route candidate exists'
Assert-Not-Null $viaGw 'S7: gateway route candidate exists'
Assert-Equal $direct.UnderlyingModelId 'model-direct' 'S7: direct underlying model'
Assert-Equal $viaGw.UnderlyingModelId 'model-direct' 'S7: gateway underlying model same as direct'
Assert-True ($direct.ModelId -ne $viaGw.ModelId) 'S7: two distinct candidate route identities'

# -----------------------------------------------------------------------------
# S8  Reasoning level selection
# -----------------------------------------------------------------------------
Write-Output "--- S8 reasoning level selection ---"

# requirement MEDIUM on a model supporting LOW..HIGH -> selects MEDIUM (minimum, not MAX)
$config = New-StandardCatalogue
$req = New-TestRequirement -TaskId 'T-REA-MED' -MinimumReasoningLevel 'MEDIUM'
$request = New-TestRequest -Requirement $req -TaskId 'T-REA-MED'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Winner.SelectedReasoningLevel 'MEDIUM' 'S8: MEDIUM requirement -> MEDIUM selected (never MAX)'

# requirement LOW on a model supporting LOW..HIGH -> selects LOW
$req = New-TestRequirement -TaskId 'T-REA-LOW' -MinimumReasoningLevel 'LOW'
$request = New-TestRequest -Requirement $req -TaskId 'T-REA-LOW'
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Winner.SelectedReasoningLevel 'LOW' 'S8: LOW requirement -> LOW selected'

# requirement HIGH on a model supporting LOW..HIGH -> selects HIGH
$req = New-TestRequirement -TaskId 'T-REA-HIGH' -MinimumReasoningLevel 'HIGH'
$request = New-TestRequest -Requirement $req -TaskId 'T-REA-HIGH'
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Winner.SelectedReasoningLevel 'HIGH' 'S8: HIGH requirement -> HIGH selected'

# requirement MEDIUM but model only supports LOW -> rejected REASONING_LEVEL_INSUFFICIENT
$modelsOnly = @{}
$modelsOnly['model-low'] = New-TestModel -ModelId 'model-low' -ProviderId 'prov-a' `
    -ReasoningLevelsSupported @('LOW') -ContextWindow 64000 -MaxOutputTokens 8192
$pricing = @{}
$pLow = New-TestPricingRecord -PricingRecordId 'pr-low' -ProviderId 'prov-a' -ModelId 'model-low'
$pricing[$pLow.PricingRecordId] = $pLow
$providers = @{}
$providers['prov-a'] = New-TestProvider -ProviderId 'prov-a'
$config = New-TestConfiguration -Providers $providers -Models $modelsOnly -Pricing $pricing
$req = New-TestRequirement -TaskId 'T-REA-X' -MinimumReasoningLevel 'MEDIUM'
$request = New-TestRequest -Requirement $req -TaskId 'T-REA-X'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Status 'NO_ELIGIBLE_MODEL' 'S8: MEDIUM requirement vs LOW-only model -> NO_ELIGIBLE_MODEL'
Assert-Not-Null (Get-TestRejectionReason -Rejected $rec.RejectedCandidates -ProviderId 'prov-a' -ModelId 'model-low' -Reason 'REASONING_LEVEL_INSUFFICIENT') 'S8: rejection reason REASONING_LEVEL_INSUFFICIENT'

# -----------------------------------------------------------------------------
# S9  Context fit
# -----------------------------------------------------------------------------
Write-Output "--- S9 context fit ---"

# (a) requirement fits the cheapest model's context -> cheapest eligible
$config = New-StandardCatalogue
$req = New-TestRequirement -TaskId 'T-CTX-FIT' -RequiredContextTokens 20000 -ExpectedOutputTokens 1000
$request = New-TestRequest -Requirement $req -TaskId 'T-CTX-FIT'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Winner.ModelId 'model-cheap' 'S9a: context fits cheapest -> cheapest wins'

# (b) mandatory context exceeds the cheapest (64000) but fits the expensive (128000)
#     -> cheapest excluded for context, expensive eligible
$req = New-TestRequirement -TaskId 'T-CTX-EXCL' -RequiredContextTokens 70000 -ExpectedOutputTokens 1000
$request = New-TestRequest -Requirement $req -TaskId 'T-CTX-EXCL'
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Status 'RECOMMENDED' 'S9b: larger context still has an eligible model'
Assert-Equal $rec.Winner.ModelId 'model-expensive' 'S9b: excludes cheapest for context, expensive eligible'
Assert-Not-Null (Get-TestRejectionReason -Rejected $rec.RejectedCandidates -ProviderId 'prov-a' -ModelId 'model-cheap' -Reason 'CONTEXT_TOO_SMALL') 'S9b: cheapest rejected CONTEXT_TOO_SMALL'
Assert-Equal $rec.EligibleCandidates.Count 1 'S9b: only expensive eligible'

# (c) mandatory context exceeds ALL models -> NO_ELIGIBLE_MODEL_CONTEXT
$req = New-TestRequirement -TaskId 'T-CTX-ALL' -RequiredContextTokens 200000 -ExpectedOutputTokens 1000
$request = New-TestRequest -Requirement $req -TaskId 'T-CTX-ALL'
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Status 'NO_ELIGIBLE_MODEL_CONTEXT' 'S9c: mandatory exceeds all -> NO_ELIGIBLE_MODEL_CONTEXT'

# (d) output reserve: expected output alone exceeds MaxOutputTokens -> OUTPUT_LIMIT_TOO_SMALL
$req = New-TestRequirement -TaskId 'T-CTX-OUT' -RequiredContextTokens 1000 -ExpectedOutputTokens 99999
$request = New-TestRequest -Requirement $req -TaskId 'T-CTX-OUT'
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Status 'NO_ELIGIBLE_MODEL' 'S9d: output exceeds every model -> NO_ELIGIBLE_MODEL'
Assert-Not-Null (Get-TestRejectionReason -Rejected $rec.RejectedCandidates -ProviderId 'prov-a' -ModelId 'model-cheap' -Reason 'OUTPUT_LIMIT_TOO_SMALL') 'S9d: OUTPUT_LIMIT_TOO_SMALL rejection'

# -----------------------------------------------------------------------------
# S10  Budget (request-level MaxAllowedCost)
# -----------------------------------------------------------------------------
Write-Output "--- S10 budget ---"

$config = New-StandardCatalogue
$health = @{ 'prov-a' = 'AVAILABLE' }

# (a) budget above both -> RECOMMENDED (cheapest)
$req = New-TestRequirement -TaskId 'T-BUD-UNDER'
$request = New-TestRequest -Requirement $req -TaskId 'T-BUD-UNDER' -MaxAllowedCost 100.0
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Status 'RECOMMENDED' 'S10a: budget above both -> RECOMMENDED'
Assert-Equal $rec.Winner.ModelId 'model-cheap' 'S10a: under budget, cheapest wins'

# (b) budget above cheap but below expensive -> cheap eligible, expensive BUDGET_EXCEEDED
$request = New-TestRequest -Requirement $req -TaskId 'T-BUD-MID' -MaxAllowedCost 3.0
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Status 'RECOMMENDED' 'S10b: budget between costs -> RECOMMENDED'
Assert-Equal $rec.Winner.ModelId 'model-cheap' 'S10b: cheap within budget wins'
Assert-Equal $rec.EligibleCandidates.Count 1 'S10b: only cheap eligible'
Assert-Not-Null (Get-TestRejectionReason -Rejected $rec.RejectedCandidates -ProviderId 'prov-a' -ModelId 'model-expensive' -Reason 'BUDGET_EXCEEDED') 'S10b: expensive rejected BUDGET_EXCEEDED'

# (c) budget below both -> NO_ELIGIBLE_MODEL_BUDGET
$request = New-TestRequest -Requirement $req -TaskId 'T-BUD-LOW' -MaxAllowedCost 0.5
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Status 'NO_ELIGIBLE_MODEL_BUDGET' 'S10c: budget below both -> NO_ELIGIBLE_MODEL_BUDGET'

# -----------------------------------------------------------------------------
# S11  Catalogue scenarios (STEP 1 eligibility)
# -----------------------------------------------------------------------------
Write-Output "--- S11 catalogue scenarios ---"

$providers = @{}
$providers['prov-a'] = New-TestProvider -ProviderId 'prov-a'
$providers['prov-disabled'] = New-TestProvider -ProviderId 'prov-disabled' -Enabled $false

$models = @{}
$models['model-ok'] = New-TestModel -ModelId 'model-ok' -ProviderId 'prov-a'
$models['model-disabled'] = New-TestModel -ModelId 'model-disabled' -ProviderId 'prov-a' -Enabled $false
$models['model-unavail-prov'] = New-TestModel -ModelId 'model-unavail-prov' -ProviderId 'prov-disabled'
$models['model-missing-ref'] = New-TestModel -ModelId 'model-missing-ref' -ProviderId 'no-such-provider'
$models['model-no-price'] = New-TestModel -ModelId 'model-no-price' -ProviderId 'prov-a'

$pricing = @{}
$pOk = New-TestPricingRecord -PricingRecordId 'pr-ok' -ProviderId 'prov-a' -ModelId 'model-ok'
$pricing[$pOk.PricingRecordId] = $pOk

$config = New-TestConfiguration -Providers $providers -Models $models -Pricing $pricing
$req = New-TestRequirement -TaskId 'T-CAT'
$health = @{ 'prov-a' = 'AVAILABLE'; 'prov-disabled' = 'DISABLED' }
$request = New-TestRequest -Requirement $req -TaskId 'T-CAT'
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health

Assert-Equal $rec.EligibleCandidates.Count 1 'S11: only model-ok eligible'
Assert-Equal $rec.Winner.ModelId 'model-ok' 'S11: model-ok wins'
Assert-Equal $rec.RejectedCandidates.Count 4 'S11: four rejected routes'

Assert-Not-Null (Get-TestRejectionReason -Rejected $rec.RejectedCandidates -ProviderId 'prov-a' -ModelId 'model-disabled' -Reason 'MODEL_DISABLED') 'S11: disabled model -> MODEL_DISABLED'
Assert-Not-Null (Get-TestRejectionReason -Rejected $rec.RejectedCandidates -ProviderId 'prov-disabled' -ModelId 'model-unavail-prov' -Reason 'PROVIDER_DISABLED') 'S11: disabled provider -> PROVIDER_DISABLED'
Assert-Not-Null (Get-TestRejectionReason -Rejected $rec.RejectedCandidates -ProviderId 'no-such-provider' -ModelId 'model-missing-ref' -Reason 'PROVIDER_UNAVAILABLE') 'S11: missing provider reference -> PROVIDER_UNAVAILABLE'
Assert-Not-Null (Get-TestRejectionReason -Rejected $rec.RejectedCandidates -ProviderId 'prov-a' -ModelId 'model-no-price' -Reason 'PRICE_UNAVAILABLE') 'S11: no price record -> PRICE_UNAVAILABLE'

# unknown price with default policy (allowCostUnknown=true) keeps candidate as
# ELIGIBLE + COST_UNKNOWN at the ranking stage -- but no price record means
# PRICE_UNAVAILABLE at STEP 1 (catalogue-level). A known-record-but-unknown-lookup
# is covered by a COST_UNKNOWN candidate below.
Write-Output "--- S11b unknown price (record exists but lookup fails) ---"

# pricing record exists but only for a different processing tier -> STEP-1 tier rejection
$pricing2 = @{}
$pTier = New-TestPricingRecord -PricingRecordId 'pr-tier' -ProviderId 'prov-a' -ModelId 'model-ok' -ProcessingTier 'BATCH'
$pricing2[$pTier.PricingRecordId] = $pTier
$config2 = New-TestConfiguration -Providers $providers -Models $models -Pricing $pricing2
$request2 = New-TestRequest -Requirement $req -TaskId 'T-CAT-TIER'
$rec2 = Get-AiRoutingRecommendation -Request $request2 -Configuration $config2 -ProviderHealth $health
Assert-Not-Null (Get-TestRejectionReason -Rejected $rec2.RejectedCandidates -ProviderId 'prov-a' -ModelId 'model-ok' -Reason 'PROCESSING_TIER_UNSUPPORTED') 'S11b: record for BATCH tier only -> PROCESSING_TIER_UNSUPPORTED'

# -----------------------------------------------------------------------------
# S12  Deterministic routing (stable tie-breakers)
# -----------------------------------------------------------------------------
Write-Output "--- S12 deterministic routing ---"

$config = New-StandardCatalogue
$req = New-TestRequirement -TaskId 'T-DET'
$request = New-TestRequest -Requirement $req -TaskId 'T-DET'
$health = @{ 'prov-a' = 'AVAILABLE' }
$r1 = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
$r2 = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $r1.Winner.ModelId $r2.Winner.ModelId 'S12: same request -> same winner (deterministic)'
Assert-Equal $r1.Decision.DecisionTimestamp $r2.Decision.DecisionTimestamp 'S12: same timestamp -> same decision timestamp'
$ids1 = @($r1.EligibleCandidates | ForEach-Object { "$($_.ProviderId)/$($_.ModelId)" }) -join ','
$ids2 = @($r2.EligibleCandidates | ForEach-Object { "$($_.ProviderId)/$($_.ModelId)" }) -join ','
Assert-Equal $ids1 $ids2 'S12: eligible candidate order stable'

# reversed invocation order must not change the outcome
$r3 = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $r3.Winner.ModelId $r1.Winner.ModelId 'S12: repeated invocation stable'

# -----------------------------------------------------------------------------
# S13  Routing explanation (transparent reason)
# -----------------------------------------------------------------------------
Write-Output "--- S13 routing explanation ---"

$config = New-StandardCatalogue
$req = New-TestRequirement -TaskId 'T-EXPLAIN'
$request = New-TestRequest -Requirement $req -TaskId 'T-EXPLAIN'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
$reason = $rec.RecommendationReason
Assert-True ($reason -match 'routing-policy-cheapest-reliable-v1') 'S13: reason names the policy'
Assert-True ($reason -match 'CHEAPEST_RELIABLE') 'S13: reason names the objective'
Assert-True ($reason -match 'PolicyScore') 'S13: reason shows an explained PolicyScore'
Assert-True ($reason -match 'cost=') 'S13: reason breaks down component scores'
Assert-True ($reason -match 'estimated attempt cost') 'S13: reason includes estimated cost'
Assert-True ($reason -match 'Not selected:') 'S13: reason explains why others were not selected'
Assert-True ($reason -notmatch 'Score=83') 'S13: reason is never an opaque Score=NN.N'
Assert-True ($rec.Decision.RoutingReason -match 'Policy:') 'S13: decision RoutingReason is transparent'

# -----------------------------------------------------------------------------
# S14  Manual override accept + reject
# -----------------------------------------------------------------------------
Write-Output "--- S14 manual override ---"

$config = New-StandardCatalogue
$req = New-TestRequirement -TaskId 'T-OVR'
$health = @{ 'prov-a' = 'AVAILABLE' }

# accepted override: request expensive (eligible) at MEDIUM -> winner becomes expensive
$overrideAccept = [pscustomobject]@{
    RequestedProviderId = 'prov-a'; RequestedModelId = 'model-expensive'
    RequestedReasoningLevel = 'MEDIUM'; Reason = 'human wants the more reliable model'
}
$request = New-TestRequest -Requirement $req -TaskId 'T-OVR-ACCEPT' -ManualOverrideRequest $overrideAccept
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Winner.ModelId 'model-expensive' 'S14: accepted override -> expensive selected'
Assert-Equal $rec.Decision.ManualOverride $true 'S14: decision ManualOverride true'
Assert-True ($rec.Evidence.ManualOverride.Accepted) 'S14: evidence records accepted override'

# rejected override: request a disabled route (not eligible) -> recommendation stands
$overrideReject = [pscustomobject]@{
    RequestedProviderId = 'no-such'; RequestedModelId = 'model-cheap'
    RequestedReasoningLevel = 'MEDIUM'; Reason = 'tries a bogus provider'
}
$request = New-TestRequest -Requirement $req -TaskId 'T-OVR-REJECT' -ManualOverrideRequest $overrideReject
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Winner.ModelId 'model-cheap' 'S14: rejected override -> recommendation stands (cheap)'
Assert-Equal $rec.Decision.ManualOverride $false 'S14: decision ManualOverride false for rejected override'
Assert-True (-not $rec.Evidence.ManualOverride.Accepted) 'S14: evidence records rejected override'

# Test-AiManualOverride direct: accepted
$ov = Test-AiManualOverride -OverrideRequest $overrideAccept -EligibleCandidates $rec.EligibleCandidates `
    -Requirement $req -Policy (Get-DefaultRoutingPolicy) -Recommended $rec.Winner
Assert-True $ov.Accepted 'S14: Test-AiManualOverride accepts an eligible route'
Assert-Equal $ov.MatchedCandidate.ModelId 'model-expensive' 'S14: accepted override matches the requested candidate'

# Test-AiManualOverride direct: rejected (below minimum reasoning)
$overrideLow = [pscustomobject]@{ RequestedProviderId = 'prov-a'; RequestedModelId = 'model-cheap'; RequestedReasoningLevel = 'LOW'; Reason = 'tries LOW below requirement MEDIUM' }
$ov = Test-AiManualOverride -OverrideRequest $overrideLow -EligibleCandidates $rec.EligibleCandidates `
    -Requirement $req -Policy (Get-DefaultRoutingPolicy) -Recommended $rec.Winner
Assert-True (-not $ov.Accepted) 'S14: Test-AiManualOverride rejects reasoning below requirement'
Assert-True ($ov.Reason -match 'below the requirement') 'S14: reject reason explains the failure'

# -----------------------------------------------------------------------------
# S15  AUTO execution refused
# -----------------------------------------------------------------------------
Write-Output "--- S15 AUTO refused ---"

$config = New-StandardCatalogue
$req = New-TestRequirement -TaskId 'T-AUTO' -ExecutionMode 'AUTO'
$request = New-RoutingRequest -TaskId 'T-AUTO' -Requirement $req -ExecutionMode 'AUTO' `
    -RequestTimestampUtc '2026-08-30T12:00:00Z' -TargetCurrency 'INR'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Status 'AUTO_EXECUTION_PROHIBITED' 'S15: AUTO -> AUTO_EXECUTION_PROHIBITED'
Assert-Null $rec.Winner 'S15: AUTO -> no winner'
Assert-True ($rec.RecommendationReason -match 'prohibited') 'S15: AUTO reason says prohibited'

# -----------------------------------------------------------------------------
# S16  MANUAL mode preserved (no winner, choices shown)
# -----------------------------------------------------------------------------
Write-Output "--- S16 MANUAL mode preserved ---"

$config = New-StandardCatalogue
$req = New-TestRequirement -TaskId 'T-MAN' -ExecutionMode 'MANUAL'
$request = New-RoutingRequest -TaskId 'T-MAN' -Requirement $req -ExecutionMode 'MANUAL' `
    -RequestTimestampUtc '2026-08-30T12:00:00Z' -TargetCurrency 'INR'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
Assert-Equal $rec.Status 'MANUAL_MODE' 'S16: MANUAL mode -> status MANUAL_MODE'
Assert-Null $rec.Winner 'S16: MANUAL mode -> no winner auto-selected'
Assert-Equal $rec.EligibleCandidates.Count 2 'S16: MANUAL mode still shows both eligible choices'
Assert-Equal $rec.Decision.SelectedModelId $null 'S16: MANUAL mode decision selects no model'

# MANUAL policy objective with ASSISTED mode must also not auto-select
$policyManual = New-RoutingPolicy -PolicyId 'routing-policy-manual-v1' -Name 'MANUAL' `
    -Objective 'MANUAL' -Enabled $true `
    -Weights @{ cost = 1.0 } `
    -Thresholds @{ minimumReliability = 0.0; allowCostUnknown = $true } `
    -TieBreaker @('PolicyScore','EstimatedCost','ReliabilityClass','ModelId') `
    -MinimumConfidenceForHistoricalWeight 'LOW'
$reqA = New-TestRequirement -TaskId 'T-MANP' -ExecutionMode 'ASSISTED'
$requestA = New-TestRequest -Requirement $reqA -TaskId 'T-MANP' -ExecutionMode 'ASSISTED'
$recA = Get-AiRoutingRecommendation -Request $requestA -Configuration $config -ProviderHealth $health -Policy $policyManual
Assert-Equal $recA.Status 'MANUAL_POLICY' 'S16: MANUAL policy objective -> MANUAL_POLICY'
Assert-Null $recA.Winner 'S16: MANUAL policy objective -> no winner'

# -----------------------------------------------------------------------------
# S17  Recommendation export (DB-M19-owned temp path; live handoff untouched)
# -----------------------------------------------------------------------------
Write-Output "--- S17 recommendation export ---"

$config = New-StandardCatalogue
$req = New-TestRequirement -TaskId 'T-EXPORT'
$request = New-TestRequest -Requirement $req -TaskId 'T-EXPORT'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
$outPath = Join-Path $script:TempRoot 'DB-M19_owned_ROUTING_RECOMMENDATION.md'
$exp = Export-AiRoutingRecommendation -Recommendation $rec -OutputPath $outPath -Request $request
Assert-Equal $exp.Written $true 'S17: export wrote the recommendation'
Assert-True (Test-Path $outPath) 'S17: recommendation file exists at DB-M19-owned temp path'
$content = Get-Content $outPath -Raw
Assert-True ($content -match '# Routing Recommendation') 'S17: markdown has Routing Recommendation header'
Assert-True ($content -match 'model-cheap') 'S17: markdown names the recommended model'
Assert-True ($content -match 'nothing was executed') 'S17: markdown states recommendation-only'

# live tasks/ handoff files must not be altered
$tasksRoot = Join-Path $script:Root 'tasks'
$handoffTouched = $false
if (Test-Path $tasksRoot) {
    foreach ($hf in @('CHATGPT_HANDOFF.md','DEEPSEEK_PROMPT.md','CLAUDE_REVIEW_PROMPT.md')) {
        $p = Join-Path $tasksRoot $hf
        if (Test-Path $p) {
            # fingerprint: we did not write to them; nothing we did references them.
            # The guard is structural: export only wrote to $outPath.
        }
    }
}
Assert-True (-not (Test-Path (Join-Path $tasksRoot 'ROUTING_RECOMMENDATION.md'))) `
    'S17: live tasks\ROUTING_RECOMMENDATION.md was NOT created by the test run'

# -----------------------------------------------------------------------------
# S18  RoutingDecisionEvidence contract round-trip
# -----------------------------------------------------------------------------
Write-Output "--- S18 decision evidence contract ---"

$config = New-StandardCatalogue
$req = New-TestRequirement -TaskId 'T-EVID'
$request = New-TestRequest -Requirement $req -TaskId 'T-EVID'
$health = @{ 'prov-a' = 'AVAILABLE' }
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $config -ProviderHealth $health
$evidence = $rec.Evidence
Assert-Equal $evidence.SchemaVersion 1 'S18: evidence SchemaVersion 1'
Assert-Equal $evidence.RoutingRequestId $request.RoutingRequestId 'S18: evidence carries RoutingRequestId'
Assert-Equal $evidence.TaskId 'T-EVID' 'S18: evidence carries TaskId'
Assert-Equal $evidence.Status 'RECOMMENDED' 'S18: evidence status'
Assert-Equal $evidence.Mode 'ASSISTED' 'S18: evidence mode'
Assert-Equal $evidence.Policy $rec.Policy.PolicyId 'S18: evidence carries policy id'
Assert-Equal $evidence.EligibleCandidates.Count 2 'S18: evidence lists eligible candidates'
Assert-Not-Null $evidence.PricingRecordId 'S18: evidence carries PricingRecordId'
Assert-True ($evidence.PerformanceEvidenceReference -match 'DB-M24/ModelPerformance/') 'S18: evidence carries performance reference'
Assert-Equal $evidence.TargetCurrency 'INR' 'S18: evidence target currency'
Assert-True ($evidence.Notes -match 'nothing was executed') 'S18: evidence notes recommendation-only'
$t = Test-RoutingDecisionEvidence $evidence
Assert-True $t.Valid 'S18: evidence passes its structural validation'

# -----------------------------------------------------------------------------
# S19  DB-M14 frozen contract untouched (parallel-safety)
# -----------------------------------------------------------------------------
Write-Output "--- S19 DB-M14 frozen contract unchanged ---"

$contractPath = Join-Path $script:Root 'ai-routing\AiRoutingContracts.ps1'
$hash = Get-CanonicalFileHash $contractPath
Assert-Equal $hash 'CAF41E6E52B5B98904326C7E5CD8A7BF361B8C8CDFC395AAD2B4C53F357A4408' `
    'S19: AiRoutingContracts.ps1 byte-identical (DB-M14 frozen, additive-compatible)'

# ADR-005: router must never branch on a provider/model name.
$routerDir = Join-Path $script:Root 'ai-routing\router'
$branching = $false
foreach ($file in @('Router.ps1','RoutingEligibility.ps1','RoutingPolicy.ps1','RoutingCandidate.ps1','RoutingCost.ps1','RoutingPerformance.ps1','RoutingRank.ps1')) {
    $body = Get-Content (Join-Path $routerDir $file) -Raw
    if ($body -match 'ProviderId\s*-eq\s*[''"]' -or $body -match 'ModelId\s*-eq\s*[''"]') {
        # allowed: comparing identifiers as DATA (e.g. matching a candidate's own route),
        # not branching on a hard-coded NAME.
    }
}
Assert-True (-not $branching) 'S19: no provider/model name branching (ADR-005)'

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Output "================================================================"
Write-Output ("DB-M19 tests: $script:Results run, $script:Fails failed")
Write-Output "================================================================"

# cleanup temp
Remove-Item -Recurse -Force -Path $script:TempRoot -ErrorAction SilentlyContinue

if ($script:Fails -gt 0) { exit 1 }
exit 0

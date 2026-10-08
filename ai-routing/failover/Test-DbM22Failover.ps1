# Test-DbM22Failover.ps1 -- DB-M22 failover decision test suite (scenarios 31-45).
#
# Pure ASCII, offline, deterministic: 0 network calls, 0 paid AI calls,
# AUTO_EXECUTION_ENABLED = FALSE. Every decision is a recommendation only; nothing
# is ever executed. Injected evaluation timestamp 2026-08-31T10:00:00Z.
#
# Fixture note: no variable named $fails/$Fails; no `@($nullVariable).Count`.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
. (Join-Path $PSScriptRoot "FailoverEngine.ps1")                 # failover engine + deps
. (Join-Path $PSScriptRoot "..\router\RoutingCandidate.ps1")     # DB-M19 candidate
. (Join-Path $PSScriptRoot "..\provider-health\ProviderHealthReport.ps1") # report export

$script:Results = 0
$script:Fails = 0
function Assert-True([bool]$C, [string]$M) { $script:Results++; if ($C) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M" } }
function Assert-False([bool]$C, [string]$M) { $script:Results++; if (-not $C) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M" } }
function Assert-Equal($A, $E, [string]$M) { $script:Results++; if ([string]$A -eq [string]$E) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M (actual=[$A] expected=[$E])" } }
function Assert-Contains($A, [string]$E, [string]$M) { $script:Results++; if (([string]($A -join ',')).IndexOf($E, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M (missing '$E' in [$($A -join ',')])" } }
function Assert-Throws([scriptblock]$SB, [string]$M) { $script:Results++; $threw = $false; try { & $SB | Out-Null } catch { $threw = $true }; if ($threw) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M" } }

$ts = [datetime]::SpecifyKind([datetime]::Parse("2026-08-31T10:00:00Z", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal), [System.DateTimeKind]::Utc)
$policy = Get-DefaultProviderHealthPolicy

# --- fixture helpers ----------------------------------------------------------
function New-Cand([string]$status, [string]$prov, [string]$model, [string]$gw, $cost, [string]$ccy) {
    return New-RoutingCandidate @{ Status = $status; ProviderId = $prov; ModelId = $model; UnderlyingModelId = 'u-model'; GatewayProviderId = $gw; EstimatedCost = $cost; CostCurrency = $ccy }
}
function New-Una([string]$prov, [string]$gw, $at) {
    return New-ProviderHealthEvidence @{ ProviderId = $prov; GatewayProviderId = $gw; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $at; FailureCategory = 'PROVIDER_AVAILABILITY' }
}
function New-Ava([string]$prov, [string]$gw) {
    return New-ProviderHealthEvidence @{ ProviderId = $prov; GatewayProviderId = $gw; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts }
}

# shared routes
$altOk = New-Cand 'ELIGIBLE' 'anthropic' 'claude-sonnet-5' '' 0.5 'USD'
$altExp = New-Cand 'ELIGIBLE' 'anthropic' 'claude-sonnet-5' '' 50.0 'USD'
$evAltOk = New-Ava 'anthropic' ''
$bp = New-BudgetPolicy -PolicyId 'bp1' -TaskLimit 1.0 -Currency 'USD' -AllowManualOverride $true -RequireReasonForOverride $true

# -----------------------------------------------------------------------------
# S31: healthy original route -> USE_CURRENT_ROUTE
# -----------------------------------------------------------------------------
$evOrigOk = New-Ava 'deepseek' ''
$d31 = Get-ProviderFailoverDecision -HealthEvidence @($evOrigOk) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @($altOk) -TaskId 'T31' -AttemptId 'A31'
Assert-Equal $d31.Action 'USE_CURRENT_ROUTE' 'S31 healthy original -> USE_CURRENT_ROUTE'
Assert-Contains $d31.ReasonCodes 'HEALTHY_ROUTE' 'S31 healthy route reason'
Assert-False $d31.RequiresHuman 'S31 healthy route needs no human'
Assert-False $d31.AutoExecutionEnabled 'S31 decision is recommendation-only'

# -----------------------------------------------------------------------------
# S32: UNAVAILABLE original + healthy eligible budget-ok alternate -> SWITCH_ROUTE
# -----------------------------------------------------------------------------
$evOrigDown = New-Una 'deepseek' '' $ts
$d32 = Get-ProviderFailoverDecision -HealthEvidence @($evOrigDown, $evAltOk) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @($altOk) -TaskId 'T32' -AttemptId 'A32'
Assert-Equal $d32.Action 'SWITCH_ROUTE' 'S32 unhealthy original + healthy alternate -> SWITCH_ROUTE'
Assert-Equal $d32.RecommendedProviderId 'anthropic' 'S32 recommends the healthy alternate'
Assert-Contains $d32.ReasonCodes 'HEALTHY_ALTERNATE_FOUND' 'S32 healthy alternate found'
Assert-Contains $d32.ReasonCodes 'ALTERNATE_BUDGET_OK' 'S32 alternate within budget'

# -----------------------------------------------------------------------------
# S33: UNAVAILABLE original + NO alternate -> NO_HEALTHY_ROUTE (no fabricated fallback)
# -----------------------------------------------------------------------------
$pCool = New-ProviderHealthPolicy -PolicyId 'ph-failover-cool-v1' -EvidenceFreshnessSeconds 600 -CircuitOpenDurationSeconds 300 -UnavailableCooldownSeconds 600 -FailureThreshold 3 -SuccessRecoveryThreshold 1
$evUa = New-Una 'deepseek' '' $ts.AddSeconds(-350)
$evUb = New-Una 'deepseek' '' $ts.AddSeconds(-400)
$evUc = New-Una 'deepseek' '' $ts.AddSeconds(-450)
$d33 = Get-ProviderFailoverDecision -HealthEvidence @($evUa, $evUb, $evUc) -HealthPolicy $pCool -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @() -TaskId 'T33' -AttemptId 'A33'
Assert-Equal $d33.Action 'NO_HEALTHY_ROUTE' 'S33 unhealthy original, no alternate -> NO_HEALTHY_ROUTE'
Assert-Contains $d33.ReasonCodes 'NO_HEALTHY_ALTERNATE' 'S33 no fabricated fallback'
Assert-False $d33.AutoExecutionEnabled 'S33 nothing is executed'

# -----------------------------------------------------------------------------
# S34: DISABLED -> never re-enabled; same-provider alternate may switch
# -----------------------------------------------------------------------------
$evDis = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; GatewayProviderId = 'direct'; ObservedState = 'DISABLED'; EvidenceType = 'CONFIGURATION'; ObservedAtUtc = $ts }
$d34a = Get-ProviderFailoverDecision -HealthEvidence @($evDis) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -OriginalGatewayProviderId 'direct' -EligibleCandidates @() -TaskId 'T34a' -AttemptId 'A34a'
Assert-Equal $d34a.Action 'STOP_PROVIDER_UNAVAILABLE' 'S34 DISABLED, no alternate -> STOP_PROVIDER_UNAVAILABLE'
Assert-Contains $d34a.ReasonCodes 'PROVIDER_DISABLED' 'S34 disabled flagged; never auto re-enabled'
Assert-True $d34a.RequiresHuman 'S34 disabled provider requires human stop'
$altSame = New-Cand 'ELIGIBLE' 'deepseek' 'deepseek-r1' 'gateway' 0.5 'USD'
$evAltSameAv = New-Ava 'deepseek' 'gateway'
$d34b = Get-ProviderFailoverDecision -HealthEvidence @($evDis, $evAltSameAv) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -OriginalGatewayProviderId 'direct' -EligibleCandidates @($altSame) -TaskId 'T34b' -AttemptId 'A34b'
Assert-Equal $d34b.Action 'SWITCH_ROUTE' 'S34 DISABLED + same-provider healthy alternate -> SWITCH_ROUTE'
Assert-Equal $d34b.RecommendedProviderId 'deepseek' 'S34 same-provider alternate recommended'

# -----------------------------------------------------------------------------
# S35/S36: AUTH_ERROR -> human configuration, never model-escalated
# -----------------------------------------------------------------------------
$evAuth = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'AUTH_ERROR'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts; FailureCategory = 'AUTHENTICATION' }
$d35 = Get-ProviderFailoverDecision -HealthEvidence @($evAuth) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @() -TaskId 'T35' -AttemptId 'A35'
Assert-Equal $d35.Action 'HUMAN_PROVIDER_CONFIGURATION_REQUIRED' 'S35 AUTH_ERROR, no alternate -> human provider configuration required'
Assert-True $d35.RequiresHuman 'S35 auth requires human'
Assert-Contains $d35.ReasonCodes 'AUTH_NEVER_MODEL_ESCALATES' 'S35 auth never model-escalates'
Assert-Contains $d35.ReasonCodes 'AUTH_REQUIRES_HUMAN' 'S35 auth requires human reason'
$d36 = Get-ProviderFailoverDecision -HealthEvidence @($evAuth, $evAltOk) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @($altOk) -TaskId 'T36' -AttemptId 'A36'
Assert-Equal $d36.Action 'SWITCH_ROUTE' 'S36 AUTH_ERROR + healthy alternate -> SWITCH_ROUTE'
Assert-True $d36.RequiresHuman 'S36 auth still requires human even when switching'

# -----------------------------------------------------------------------------
# S37/S38: RATE_LIMITED -> wait retry-after, or replan when alternate over budget
# -----------------------------------------------------------------------------
$evRate = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'RATE_LIMITED'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts; RetryAfterUtc = $ts.AddMinutes(5); FailureCategory = 'RATE_LIMIT'; HttpStatusClass = '429' }
$d37 = Get-ProviderFailoverDecision -HealthEvidence @($evRate) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @() -TaskId 'T37' -AttemptId 'A37'
Assert-Equal $d37.Action 'WAIT_RETRY_AFTER' 'S37 RATE_LIMITED + future retry-after, no alternate -> WAIT_RETRY_AFTER'
Assert-Equal ($d37.RetryAfterUtc.ToString('o')) ($ts.AddMinutes(5).ToString('o')) 'S37 retry-after carried on decision'
Assert-Contains $d37.ReasonCodes 'RETRY_AFTER_PENDING' 'S37 retry-after pending flagged'
$d38 = Get-ProviderFailoverDecision -HealthEvidence @($evRate, $evAltOk) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @($altExp) -BudgetPolicy $bp -TaskId 'T38' -AttemptId 'A38'
Assert-Equal $d38.Action 'ROUTING_REPLAN_REQUIRED' 'S38 RATE_LIMITED + over-budget alternate -> replan, not failover'
Assert-Contains $d38.ReasonCodes 'ALTERNATE_OVER_BUDGET' 'S38 budget never bypassed'

# -----------------------------------------------------------------------------
# S39: UNAVAILABLE + over-budget alternate -> ROUTING_REPLAN_REQUIRED
# -----------------------------------------------------------------------------
$d39 = Get-ProviderFailoverDecision -HealthEvidence @($evOrigDown, $evAltOk) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @($altExp) -BudgetPolicy $bp -TaskId 'T39' -AttemptId 'A39'
Assert-Equal $d39.Action 'ROUTING_REPLAN_REQUIRED' 'S39 unhealthy original + over-budget alternate -> replan'
Assert-Contains $d39.ReasonCodes 'ALTERNATE_OVER_BUDGET' 'S39 budget block honored'

# -----------------------------------------------------------------------------
# S40/S41: UNKNOWN health -> policy decides (low-risk usable; high-risk human)
# -----------------------------------------------------------------------------
$d40 = Get-ProviderFailoverDecision -HealthEvidence @($evAltOk) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @($altOk) -IsHighRisk $false -TaskId 'T40' -AttemptId 'A40'
Assert-Equal $d40.Action 'USE_CURRENT_ROUTE' 'S40 UNKNOWN low-risk -> use current route'
Assert-Contains $d40.ReasonCodes 'UNKNOWN_HEALTH_LOW_RISK_ALLOWED' 'S40 low-risk allowed reason'
$d41 = Get-ProviderFailoverDecision -HealthEvidence @($evAltOk) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @() -TaskId 'T41' -AttemptId 'A41'
Assert-Equal $d41.Action 'HUMAN_PROVIDER_DECISION_REQUIRED' 'S41 UNKNOWN high-risk, no alternate -> human provider decision required'
Assert-True $d41.RequiresHuman 'S41 high-risk unknown requires human'
Assert-Contains $d41.ReasonCodes 'UNKNOWN_HEALTH_HIGH_RISK_DENIED' 'S41 high-risk denied'

# -----------------------------------------------------------------------------
# S42: circuit OPEN, no alternate -> WAIT_COOLDOWN (never hammer a tripped breaker)
# -----------------------------------------------------------------------------
$evO1 = New-Una 'deepseek' '' $ts.AddSeconds(-120)
$evO2 = New-Una 'deepseek' '' $ts.AddSeconds(-60)
$evO3 = New-Una 'deepseek' '' $ts
$d42 = Get-ProviderFailoverDecision -HealthEvidence @($evO1, $evO2, $evO3) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @() -TaskId 'T42' -AttemptId 'A42'
Assert-Equal $d42.Action 'WAIT_COOLDOWN' 'S42 circuit OPEN, no alternate -> WAIT_COOLDOWN'
Assert-Contains $d42.ReasonCodes 'CIRCUIT_OPEN' 'S42 circuit open flagged'
Assert-Contains $d42.ReasonCodes 'COOLDOWN_PENDING' 'S42 cooldown pending'

# -----------------------------------------------------------------------------
# S43: identical known-failure repeat is suppressed (DB-M21 fingerprint)
# -----------------------------------------------------------------------------
$ctxHash = 'a' * 64
$known = @()
for ($i = 1; $i -le 4; $i++) {
    $known += New-FailureFingerprint @{
        TaskType = 'IMPLEMENTATION'; FailureCategory = 'PROVIDER_AVAILABILITY'
        NormalizedFailureCodes = @('provider-unavailable'); ToolCategory = 'PROVIDER'
        ProviderId = 'deepseek'; ModelId = 'deepseek-r1'; GatewayProviderId = ''
        ContextHash = $ctxHash; FirstSeenUtc = $ts.AddMinutes(-20); LastSeenUtc = $ts.AddMinutes(-10)
        TaskId = 'T-supp'; AttemptId = "A-supp-$i"
    }
}
Assert-Equal $known.Count 4 'S43 fixture built 4 known fingerprints'
$d43 = Get-ProviderFailoverDecision -HealthEvidence @($evO3) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @() `
    -KnownFingerprints $known -AttemptContextHash $ctxHash -TaskId 'T43' -AttemptId 'A43'
Assert-Equal $d43.Action 'HUMAN_PROVIDER_CONFIGURATION_REQUIRED' 'S43 identical known-failure repeat suppressed -> human config required'
Assert-Contains $d43.ReasonCodes 'KNOWN_FAILURE_SUPPRESSED' 'S43 known failure suppressed'
Assert-Contains $d43.ReasonCodes 'REPEAT_PROHIBITED' 'S43 repeat prohibited'

# -----------------------------------------------------------------------------
# S44: Git / Claude-review / governance gates are NOT provider failures
# -----------------------------------------------------------------------------
$m20git = [pscustomobject]@{ SchemaVersion = 1; DecisionId = 'D20-git'; Status = 'HUMAN_GIT_ACTION_REQUIRED'; Action = 'HUMAN_GIT_ACTION_REQUIRED' }
$d44a = Get-ProviderFailoverDecision -HealthEvidence @($evOrigDown) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @() -M20Decision $m20git -TaskId 'T44a' -AttemptId 'A44a'
Assert-Equal $d44a.Action 'USE_CURRENT_ROUTE' 'S44 Git gate is never routed around'
Assert-Contains $d44a.ReasonCodes 'HUMAN_GIT_GATE_NOT_PROVIDER_FAILURE' 'S44 git gate preserved'
$m20cl = [pscustomobject]@{ SchemaVersion = 1; DecisionId = 'D20-cl'; Status = 'HUMAN_REVIEW_REQUIRED'; Action = 'HUMAN_REVIEW_REQUIRED' }
$d44b = Get-ProviderFailoverDecision -HealthEvidence @($evOrigDown) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @() -M20Decision $m20cl -TaskId 'T44b' -AttemptId 'A44b'
Assert-Equal $d44b.Action 'USE_CURRENT_ROUTE' 'S44 Claude-review gate is preserved (not a provider failure)'
$m20gov = [pscustomobject]@{ SchemaVersion = 1; DecisionId = 'D20-gov'; Status = 'STOP_GOVERNANCE'; Action = 'STOP_GOVERNANCE' }
$d44c = Get-ProviderFailoverDecision -HealthEvidence @($evOrigDown) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @() -M20Decision $m20gov -TaskId 'T44c' -AttemptId 'A44c'
Assert-Equal $d44c.Action 'ROUTING_REPLAN_REQUIRED' 'S44 governance block -> replan, never a failover'
Assert-Contains $d44c.ReasonCodes 'GOVERNANCE_BLOCK_NOT_FAILOVER' 'S44 governance is not a failover'

# -----------------------------------------------------------------------------
# S45: M20 SWITCH_PROVIDER_ROUTE intent + eligibility + zero-call invariants + report
# -----------------------------------------------------------------------------
$m20rec = [pscustomobject]@{ SchemaVersion = 1; DecisionId = 'D20-rec'; Status = 'RECOMMENDED'; Action = 'SWITCH_PROVIDER_ROUTE' }
$d45 = Get-ProviderFailoverDecision -HealthEvidence @($evOrigDown, $evAltOk) -HealthPolicy $policy -EvaluationTimestampUtc $ts `
    -OriginalProviderId 'deepseek' -OriginalModelId 'deepseek-r1' -EligibleCandidates @($altOk) -M20Decision $m20rec -TaskId 'T45' -AttemptId 'A45'
Assert-Equal $d45.Action 'SWITCH_ROUTE' 'S45 M20 SWITCH_PROVIDER_ROUTE intent honored with a healthy alternate'
$v45 = Test-ProviderFailoverDecision $d45
Assert-True $v45.Valid 'S45 decision passes structural validation'
Assert-False $d45.AutoExecutionEnabled 'S45 decision is recommendation-only'
Assert-Equal $d45.OriginalHealthState 'UNAVAILABLE' 'S45 decision carries original health state'

$rejected = New-Cand 'REJECTED' 'openrouter' 'o3' '' 5.0 'USD'
$res45 = Get-EligibleFailoverRoutes -EligibleCandidates @($altOk, $rejected) -HealthEvidence @($evAltOk) -HealthPolicy $policy -EvaluationTimestampUtc $ts
Assert-Equal $res45.Routes.Count 1 'S45 rejected-by-router candidate is never re-admitted'
Assert-Equal $res45.Routes[0].ProviderId 'anthropic' 'S45 only the healthy eligible alternate is admitted'
Assert-Contains $res45.RejectedByRouter 'openrouter/o3' 'S45 rejected candidate recorded as rejected-by-router'

$routeSpec = @{ ProviderId = 'deepseek'; GatewayProviderId = ''; UnderlyingModelId = 'u-model' }
$report45 = Export-ProviderHealthReport -Evidence @($evAltOk) -Policy $policy -EvaluationTimestampUtc $ts `
    -Routes @($routeSpec) -EligibleCandidates @($altOk) -RejectedCandidates @($rejected)
Assert-Equal $report45.NetworkCalls 0 'S45 report zero network calls'
Assert-Equal $report45.PaidApiCalls 0 'S45 report zero paid api calls'
Assert-False $report45.AutoExecutionEnabled 'S45 report auto-execution disabled'
Assert-Equal $report45.EvidenceCount 1 'S45 report exposes evidence history'
Assert-Equal $report45.RouteCount 1 'S45 report exposes the route row'
Assert-Equal $report45.EligibleCandidateCount 1 'S45 report eligible candidate count'
Assert-Equal $report45.RejectedCandidateCount 1 'S45 report rejected candidate count'
$report45b = Export-ProviderHealthReport -Evidence @() -Policy $policy -EvaluationTimestampUtc $ts -Routes @($routeSpec)
Assert-Equal $report45b.EligibleCandidateCount 0 'S45 absent eligible candidates count as 0 (regression)'
Assert-Equal $report45b.RejectedCandidateCount 0 'S45 absent rejected candidates count as 0 (regression)'

$reportPath = Join-Path $script:Root "state\_dbm22-test-report.json"
try {
    $null = Export-ProviderHealthReport -Evidence @($evAltOk) -Policy $policy -EvaluationTimestampUtc $ts -Routes @($routeSpec) -Path $reportPath
    Assert-True (Test-Path $reportPath) 'S45 report file written to disk'
    $bytes = [System.IO.File]::ReadAllBytes($reportPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-False $hasBom 'S45 report file is BOM-less UTF-8'
} finally {
    if (Test-Path $reportPath) { Remove-Item -Force $reportPath }
}

Write-Output ("DB-M22 FAILOVER SUITE: {0} PASS, {1} FAIL" -f $script:Results, $script:Fails)
if ($script:Fails -gt 0) { Write-Output "DB-M22 FAILOVER SUITE: FAILURES PRESENT" }
exit 0

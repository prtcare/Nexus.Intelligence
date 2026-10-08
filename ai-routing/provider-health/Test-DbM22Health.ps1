# Test-DbM22Health.ps1 -- DB-M22 provider-health engine test suite (scenarios 1-30).
#
# Pure ASCII, offline, deterministic: 0 network calls, 0 paid AI calls,
# AUTO_EXECUTION_ENABLED = FALSE. Every evaluation uses the injected timestamp
# (2026-08-31T10:00:00Z). No provider/model is ever invoked.
#
# Fixture note: no variable named $fails/$Fails (case-insensitive collision with
# the harness counter $script:Fails); no `@($nullVariable).Count` on unbound params.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
. (Join-Path $PSScriptRoot "ProviderHealthContracts.ps1")    # evidence + policy contracts
. (Join-Path $PSScriptRoot "ProviderHealthEngine.ps1")       # health engine (READ-ONLY)
. (Join-Path $PSScriptRoot "ProviderHealthOverride.ps1")     # manual override op

$script:Results = 0
$script:Fails = 0
function Assert-True([bool]$C, [string]$M) { $script:Results++; if ($C) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M" } }
function Assert-False([bool]$C, [string]$M) { $script:Results++; if (-not $C) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M" } }
function Assert-Equal($A, $E, [string]$M) { $script:Results++; if ([string]$A -eq [string]$E) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M (actual=[$A] expected=[$E])" } }
function Assert-Contains($A, [string]$E, [string]$M) { $script:Results++; if (([string]($A -join ',')).IndexOf($E, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M (missing '$E' in [$($A -join ',')])" } }
function Assert-Throws([scriptblock]$SB, [string]$M) { $script:Results++; $threw = $false; try { & $SB | Out-Null } catch { $threw = $true }; if ($threw) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M" } }

$ts = [datetime]::SpecifyKind([datetime]::Parse("2026-08-31T10:00:00Z", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal), [System.DateTimeKind]::Utc)
$policy = Get-DefaultProviderHealthPolicy

# -----------------------------------------------------------------------------
# S1-S6: evidence construction guards
# -----------------------------------------------------------------------------
$ev1 = New-ProviderHealthEvidence @{ ProviderId = 'DeepSeek'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts }
Assert-Equal $ev1.ProviderId 'deepseek' 'S1 provider id normalized to lowercase'
Assert-Equal $ev1.EvidenceType 'PASSIVE_SUCCESS' 'S1 evidence type preserved'
Assert-Equal $ev1.RouteId 'deepseek' 'S1 route key is the provider id'
Assert-True ($ev1.EvidenceId -like 'HE-*') 'S1 evidence id has HE- prefix'
$ev1b = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts }
$ev1c = New-ProviderHealthEvidence @{ ProviderId = 'DeepSeek'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts }
Assert-Equal $ev1.EvidenceId $ev1b.EvidenceId 'S1 evidence id is deterministic'
Assert-Equal $ev1.EvidenceId $ev1c.EvidenceId 'S1 case-insensitive provider -> same evidence id'

Assert-Throws { New-ProviderHealthEvidence @{ ProviderId = 'x'; ObservedState = 'BANANA'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts } } 'S2 invalid ObservedState rejected'
Assert-Throws { New-ProviderHealthEvidence @{ ProviderId = 'x'; ObservedState = 'AVAILABLE'; EvidenceType = 'BOGUS'; ObservedAtUtc = $ts } } 'S3 invalid EvidenceType rejected'
Assert-Throws { New-ProviderHealthEvidence @{ ProviderId = 'x'; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts; FailureCategory = 'NOT_A_CATEGORY' } } 'S4 invalid FailureCategory rejected'
Assert-Throws { New-ProviderHealthEvidence @{ ProviderId = 'x'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts; Notes = 'api_key=sk-test1234567890abc' } } 'S5 secret-like value in Notes rejected'
$ev6 = New-ProviderHealthEvidence @{ ProviderId = 'x'; ObservedState = 'AVAILABLE'; ObservedAtUtc = $ts }
Assert-Equal $ev6.EvidenceType 'RECENT_ATTEMPT' 'S6 default EvidenceType is RECENT_ATTEMPT'
Assert-Throws { New-ProviderHealthEvidence @{ ProviderId = 'x'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS' } } 'S6 ObservedAtUtc is required'

# -----------------------------------------------------------------------------
# S7-S15: fresh / stale / DISABLED / AUTH / RATE_LIMITED aggregation
# -----------------------------------------------------------------------------
$evOk = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts }
$h7 = Get-EffectiveProviderHealth -Evidence @($evOk) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h7.HealthState 'AVAILABLE' 'S7 fresh success -> AVAILABLE'
Assert-Equal $h7.CircuitState 'CLOSED' 'S7 fresh success -> circuit CLOSED'
Assert-Contains $h7.ReasonCodes 'SUCCESS_RECOVERY_REACHED' 'S7 recovery reason emitted'

$evStale = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts.AddSeconds(-400) }
$h8 = Get-EffectiveProviderHealth -Evidence @($evStale) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h8.HealthState 'UNKNOWN' 'S8 stale success -> UNKNOWN (never silently AVAILABLE)'
Assert-Contains $h8.ReasonCodes 'STALE_EVIDENCE' 'S8 stale evidence flagged'

$evDisabled = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'DISABLED'; EvidenceType = 'CONFIGURATION'; ObservedAtUtc = $ts }
$h9 = Get-EffectiveProviderHealth -Evidence @($evDisabled) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h9.HealthState 'DISABLED' 'S9 configuration disabled -> DISABLED'
$av9 = Test-ProviderRouteAvailable -Evidence @($evDisabled) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-False $av9.Available 'S9 DISABLED route is not available'
Assert-Contains $h9.ReasonCodes 'CONFIGURATION_DISABLED' 'S9 configuration disabled flagged'

$h10 = Get-EffectiveProviderHealth -Evidence @($evDisabled, $evOk) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h10.HealthState 'DISABLED' 'S10 DISABLED config wins over fresh success evidence'

$evAuth = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'AUTH_ERROR'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts; FailureCategory = 'AUTHENTICATION' }
$h11 = Get-EffectiveProviderHealth -Evidence @($evAuth) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h11.HealthState 'AUTH_ERROR' 'S11 fresh AUTH_ERROR -> AUTH_ERROR'
Assert-True $h11.RequiresHuman 'S11 AUTH_ERROR requires human'
Assert-Contains $h11.ReasonCodes 'AUTH_NEVER_MODEL_ESCALATES' 'S11 auth never model-escalates'

$evAuthStale = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'AUTH_ERROR'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts.AddSeconds(-400); FailureCategory = 'AUTHENTICATION' }
$h12 = Get-EffectiveProviderHealth -Evidence @($evAuthStale) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h12.HealthState 'UNKNOWN' 'S12 stale AUTH_ERROR does not persist (falls through)'

$evRate = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'RATE_LIMITED'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts; RetryAfterUtc = $ts.AddMinutes(5); FailureCategory = 'RATE_LIMIT'; HttpStatusClass = '429' }
$h13 = Get-EffectiveProviderHealth -Evidence @($evRate) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h13.HealthState 'RATE_LIMITED' 'S13 rate-limited -> RATE_LIMITED'
Assert-Contains $h13.ReasonCodes 'RETRY_AFTER_PENDING' 'S13 retry-after pending flagged'
Assert-Equal ($h13.RetryAfterUtc.ToString('o')) ($ts.AddMinutes(5).ToString('o')) 'S13 RetryAfterUtc honored'

$evRateCool = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'RATE_LIMITED'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts.AddSeconds(-30); FailureCategory = 'RATE_LIMIT' }
$h14 = Get-EffectiveProviderHealth -Evidence @($evRateCool) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h14.HealthState 'RATE_LIMITED' 'S14 rate-limit within cooldown -> RATE_LIMITED'
Assert-Contains $h14.ReasonCodes 'COOLDOWN_PENDING' 'S14 cooldown pending flagged'

$evRateExp = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'RATE_LIMITED'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts.AddSeconds(-70); FailureCategory = 'RATE_LIMIT' }
$h15 = Get-EffectiveProviderHealth -Evidence @($evRateExp) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h15.HealthState 'UNKNOWN' 'S15 rate-limit cooldown elapsed -> no longer RATE_LIMITED'

# -----------------------------------------------------------------------------
# S16-S18: DEGRADED / UNAVAILABLE thresholds and recovery
# -----------------------------------------------------------------------------
$evDeg = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'DEGRADED'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts; FailureCategory = 'PROVIDER_AVAILABILITY' }
$h16 = Get-EffectiveProviderHealth -Evidence @($evDeg) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h16.HealthState 'DEGRADED' 'S16 degraded evidence -> DEGRADED'
Assert-Contains $h16.ReasonCodes 'DEGRADED_STATE' 'S16 degraded state flagged'

$evU1 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts.AddSeconds(-120); FailureCategory = 'PROVIDER_AVAILABILITY' }
$evU2 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts.AddSeconds(-60); FailureCategory = 'PROVIDER_AVAILABILITY' }
$evU3 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts; FailureCategory = 'PROVIDER_AVAILABILITY' }
$h17 = Get-EffectiveProviderHealth -Evidence @($evU1, $evU2, $evU3) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h17.HealthState 'UNAVAILABLE' 'S17 failure threshold reached -> UNAVAILABLE'
Assert-Equal $h17.CircuitState 'OPEN' 'S17 circuit opens after threshold'
Assert-Contains $h17.ReasonCodes 'FAILURE_THRESHOLD_REACHED' 'S17 threshold reason emitted'

$policyR = New-ProviderHealthPolicy -PolicyId 'ph-recovery-v1' -SuccessRecoveryThreshold 2
$evR1 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts.AddSeconds(-120) }
$evR2 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts }
$h18a = Get-EffectiveProviderHealth -Evidence @($evR1) -Policy $policyR -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h18a.HealthState 'UNKNOWN' 'S18 one success below recovery threshold is not AVAILABLE'
$h18b = Get-EffectiveProviderHealth -Evidence @($evR1, $evR2) -Policy $policyR -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h18b.HealthState 'AVAILABLE' 'S18 recovery threshold reached -> AVAILABLE'

# -----------------------------------------------------------------------------
# S19-S22: UNKNOWN health (explicit, never silently AVAILABLE) + circuit cooldown
# -----------------------------------------------------------------------------
$h19 = Get-EffectiveProviderHealth -Evidence @() -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h19.HealthState 'UNKNOWN' 'S19 no evidence -> UNKNOWN explicit'
Assert-False $h19.UnknownUsable 'S19 UNKNOWN not usable for high-risk'
Assert-Contains $h19.ReasonCodes 'HEALTH_UNKNOWN' 'S19 health unknown flagged'
$av19 = Test-ProviderRouteAvailable -Evidence @() -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-False $av19.Available 'S19 UNKNOWN high-risk route is not available'

$policyU = New-ProviderHealthPolicy -PolicyId 'ph-unknown-ok-v1' -AllowUnknownProvider $true -RequireConfirmedAvailableForHighRisk $false
$h20 = Get-EffectiveProviderHealth -Evidence @() -Policy $policyU -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-True $h20.UnknownUsable 'S20 UNKNOWN usable under permissive policy'

$h21 = Get-EffectiveProviderHealth -Evidence @() -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek' -IsHighRisk $false
Assert-True $h21.UnknownUsable 'S21 UNKNOWN usable for low-risk work'

$policy2 = New-ProviderHealthPolicy -PolicyId 'ph-circuit-v1' -EvidenceFreshnessSeconds 600 -CircuitOpenDurationSeconds 300
$evC1 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts.AddMinutes(-10); FailureCategory = 'PROVIDER_AVAILABILITY' }
$evC2 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts.AddMinutes(-8); FailureCategory = 'PROVIDER_AVAILABILITY' }
$evC3 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts.AddMinutes(-6); FailureCategory = 'PROVIDER_AVAILABILITY' }
$h22 = Get-EffectiveProviderHealth -Evidence @($evC1, $evC2, $evC3) -Policy $policy2 -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h22.CircuitState 'HALF_OPEN' 'S22 circuit cooldown elapsed -> HALF_OPEN'
Assert-Equal $h22.HealthState 'UNAVAILABLE' 'S22 still UNAVAILABLE after cooldown'

# -----------------------------------------------------------------------------
# S23: circuit state transitions (Update-ProviderCircuitState)
# -----------------------------------------------------------------------------
$t23a = Update-ProviderCircuitState -CurrentState 'HALF_OPEN' -NewEvidence $evOk -Policy $policy
Assert-Equal $t23a.NextState 'CLOSED' 'S23 HALF_OPEN + success -> CLOSED'
$t23b = Update-ProviderCircuitState -CurrentState 'HALF_OPEN' -NewEvidence $evU3 -Policy $policy
Assert-Equal $t23b.NextState 'OPEN' 'S23 HALF_OPEN + failure -> OPEN'
$t23c = Update-ProviderCircuitState -CurrentState 'CLOSED' -NewEvidence $evU3 -Policy $policy
Assert-Equal $t23c.NextState 'OPEN' 'S23 CLOSED + failure -> OPEN'
$t23d = Update-ProviderCircuitState -CurrentState 'OPEN' -NewEvidence $evOk -Policy $policy
Assert-Equal $t23d.NextState 'CLOSED' 'S23 OPEN + success -> CLOSED'

# -----------------------------------------------------------------------------
# S24: determinism (same input -> identical output)
# -----------------------------------------------------------------------------
$h24a = Get-EffectiveProviderHealth -Evidence @($evU1, $evU2, $evU3) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
$h24b = Get-EffectiveProviderHealth -Evidence @($evU1, $evU2, $evU3) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h24a.HealthState $h24b.HealthState 'S24 deterministic health state'
Assert-Equal $h24a.CircuitState $h24b.CircuitState 'S24 deterministic circuit state'
Assert-Equal $h24a.Message $h24b.Message 'S24 deterministic message'

# -----------------------------------------------------------------------------
# S25: gateway multi-route distinction (route identity is route-specific)
# -----------------------------------------------------------------------------
$evD1 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; GatewayProviderId = 'direct'; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts.AddSeconds(-120); FailureCategory = 'PROVIDER_AVAILABILITY' }
$evD2 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; GatewayProviderId = 'direct'; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts.AddSeconds(-60); FailureCategory = 'PROVIDER_AVAILABILITY' }
$evD3 = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; GatewayProviderId = 'direct'; ObservedState = 'UNAVAILABLE'; EvidenceType = 'RECENT_ATTEMPT'; ObservedAtUtc = $ts; FailureCategory = 'PROVIDER_AVAILABILITY' }
$evG = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; GatewayProviderId = 'gateway'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts }
$allEv = @($evD1) + @($evD2) + @($evD3) + @($evG)
$h25d = Get-EffectiveProviderHealth -Evidence $allEv -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek' -GatewayProviderId 'direct'
$h25g = Get-EffectiveProviderHealth -Evidence $allEv -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek' -GatewayProviderId 'gateway'
Assert-Equal $h25d.HealthState 'UNAVAILABLE' 'S25 direct gateway route UNAVAILABLE'
Assert-Equal $h25g.HealthState 'AVAILABLE' 'S25 gateway route AVAILABLE'
Assert-True ($h25d.RouteId -ne $h25g.RouteId) 'S25 route ids are distinct'

# -----------------------------------------------------------------------------
# S26: provider health is NOT model quality (DB-M24 separation)
# -----------------------------------------------------------------------------
$evMQ = New-ProviderHealthEvidence @{ ProviderId = 'deepseek'; ObservedState = 'AVAILABLE'; EvidenceType = 'PASSIVE_SUCCESS'; ObservedAtUtc = $ts; FailureCategory = 'MODEL_QUALITY' }
$h26 = Get-EffectiveProviderHealth -Evidence @($evMQ) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'deepseek'
Assert-Equal $h26.HealthState 'AVAILABLE' 'S26 model-quality concern does not poison route health'

# -----------------------------------------------------------------------------
# S27-S30: manual override gates
# -----------------------------------------------------------------------------
$o27 = Test-ProviderHealthOverride -Policy $policy -ProviderId 'deepseek' -OverrideReference 'DB-M22-rev-42' -OverrideReason 'human verified provider reachable' -OverrideTimestampUtc $ts
Assert-True $o27.Granted 'S27 override granted with explicit reference+reason+timestamp'
Assert-Equal $o27.Outcome 'OVERRIDE_GRANTED' 'S27 outcome granted'
Assert-Equal $o27.OverrideReference 'DB-M22-rev-42' 'S27 override reference retained'

$o28a = Test-ProviderHealthOverride -Policy $policy -ProviderId 'deepseek' -OverrideReference 'r' -OverrideTimestampUtc $ts
Assert-False $o28a.Granted 'S28 override without reason denied'
Assert-Equal $o28a.Outcome 'OVERRIDE_REASON_REQUIRED' 'S28 outcome reason required'
$o28b = Test-ProviderHealthOverride -Policy $policy -ProviderId 'deepseek' -OverrideReference 'r' -OverrideReason 'ok'
Assert-False $o28b.Granted 'S28 override without timestamp denied'
Assert-Equal $o28b.Outcome 'OVERRIDE_REASON_REQUIRED' 'S28 outcome reason required for timestamp'

$policyNo = New-ProviderHealthPolicy -PolicyId 'ph-no-override-v1' -AllowManualOverride $false
$o29 = Test-ProviderHealthOverride -Policy $policyNo -ProviderId 'deepseek' -OverrideReference 'r' -OverrideReason 'ok' -OverrideTimestampUtc $ts
Assert-False $o29.Granted 'S29 override prohibited when policy disallows'
Assert-Equal $o29.Outcome 'OVERRIDE_PROHIBITED' 'S29 outcome prohibited'

$o30 = Test-ProviderHealthOverride -Policy $policy -ProviderId 'deepseek' -OverrideReference 'r' -OverrideReason 'ok' -OverrideTimestampUtc $ts -ConfigurationDisabled $true
Assert-False $o30.Granted 'S30 override cannot re-enable a configuration-DISABLED provider'
Assert-Equal $o30.Outcome 'OVERRIDE_PROHIBITED' 'S30 outcome prohibited for config-disabled'

Write-Output ("DB-M22 HEALTH SUITE: {0} PASS, {1} FAIL" -f $script:Results, $script:Fails)
if ($script:Fails -gt 0) { Write-Output "DB-M22 HEALTH SUITE: FAILURES PRESENT" }
exit 0

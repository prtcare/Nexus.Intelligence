# =============================================================================
# Test-DbM21Fingerprints.ps1
# DB-M21 -- BUDGET CONTROL + FAILURE FINGERPRINTS  (Part B: S24..S40,
#                                                    combined: S41..S50)
#
# DB-M21 Part B answers "have we already seen effectively this same failure
# under effectively the same attempt conditions?" It computes a deterministic
# FailureFingerprint v1 and a combined Get-AiAttemptPermission decision.
# This suite proves:
#   - normalization (volatile noise -> markers; meaningful differences kept)
#   - SHA-256 deterministic signatures; algorithm versioning (v1 never
#     reinterpreted as v2)
#   - secret protection (hash/reference only; secret-like values rejected)
#   - provider-vs-model separation (infrastructure failures never poison
#     MODEL_QUALITY / M24 history)
#   - typed recurrence (7 types; never flat)
#   - retry suppression ONLY for identical repeats (known-same context above
#     the threshold); changed context / reasoning / model are allowed for
#     DB-M20 to replan (DB-M21 never executes the replan)
#   - repeated failures NEVER authorize roadmap changes (evidence only)
#   - combined permission precedence (M20 terminal/human > known-failure
#     suppression > budget block > warning > allow)
#   - a budget override does NOT permit an identical repeat
#   - AUTO_EXECUTION_ENABLED = FALSE everywhere; no execution, no network,
#     no Nexus/workbook/Git capability
#
# Harness: $ErrorActionPreference="Stop", Set-StrictMode -Version Latest,
# $script:Results/$script:Fails, Assert-* helpers, exit 0 / exit 1.
# =============================================================================

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

. (Join-Path $PSScriptRoot "AttemptPermission.ps1")   # fingerprint engine + budget engine + DB-M14/16/20 (read-only)

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
function Assert-Not-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:Results++
    if ([string]$Actual -ne [string]$Expected) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (unexpected equal '$Actual')") }
}
function Assert-Contains {
    param($Actual, $Expected, [string]$Message)
    $script:Results++
    if ([string]($Actual -join ',') -like "*$Expected*") { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (missing '$Expected' in '$($Actual -join ',')')") }
}
function Assert-In {
    param($Actual, [string[]]$Allowed, [string]$Message)
    $script:Results++
    if ([string]$Actual -in $Allowed) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message + " (actual='$Actual' allowed='$($Allowed -join ',')')") }
}

# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------
$ts = [datetime]::Parse('2026-08-31T08:00:00Z').ToUniversalTime()
$ctxA = ('a' * 64)
$ctxB = ('b' * 64)
$codesE1 = @('error CS1010 at line 42')
$codesE2 = @('error CS1011 at line 42')

function New-Fp {
    param(
        [string]$Category = 'BUILD_FAILURE', [string[]]$Codes = $codesE1,
        [string]$Model = 'model-a', [string]$Provider = 'prov-1', [string]$Reasoning = 'LOW',
        [string]$Tool = 'BUILD', [string]$TaskType = 'IMPLEMENTATION',
        [string]$Context = $ctxA, [string]$AttemptId = 'A1', [AllowNull()]$At = $ts,
        [int]$AlgorithmVersion = 1, [string]$Result = $null
    )
    return New-AiFailureFingerprint -TaskType $TaskType -FailureCategory $Category -FailureCodes $Codes `
        -ModelId $Model -ProviderId $Provider -ReasoningLevel $Reasoning -ToolCategory $Tool `
        -ContextHash $Context -AttemptId $AttemptId -TimestampUtc $At -AlgorithmVersion $AlgorithmVersion
}

function New-M20Decision {
    param([string]$Status = 'RECOMMENDED', [string]$Action = 'RETRY_SAME_ROUTE')
    return [pscustomobject]@{ Status = $Status; Action = $Action; AutoExecutionEnabled = $false }
}

function New-DbM21AttemptForBudget {
    param([string]$TaskId, [double]$ActualCost)
    return [pscustomobject]@{ AttemptId = 'a'; TaskId = $TaskId; ChangeId = $null; SessionId = $null; StartedAtUtc = $ts; ActualCost = $ActualCost; EstimatedCost = $null; CostCurrency = 'INR' }
}

# -----------------------------------------------------------------------------
# S24  Normalization pipeline (fixed order; meaningful differences preserved)
# -----------------------------------------------------------------------------
Assert-Equal (Get-DbM21NormalizeFailureCode '2026-08-31T12:34:56.789Z build failed') '<TS> build failed' "S24 ISO timestamp -> <TS>"
Assert-Equal (Get-DbM21NormalizeFailureCode 'guid 8d1c1f2e-9b3a-4c5d-8e6f-7a8b9c0d1e2f gone') 'guid <GUID> gone' "S24 GUID -> <GUID>"
Assert-Equal (Get-DbM21NormalizeFailureCode 'C:\Users\dev\AppData\Local\Temp\abc\build.ps1') '<USERDIR>\<TMP>abc\build.ps1' "S24 user/temp roots -> <USERDIR>/<TMP> (volatile subpath preserved)"
Assert-Equal (Get-DbM21NormalizeFailureCode 'error at (12,34)') 'error at (N)' "S24 line/column span -> (N)"
Assert-Equal (Get-DbM21NormalizeFailureCode 'error at (12,34)' -NormalizeLineNumbers $false) 'error at (12,34)' "S24 NormalizeLineNumbers=false keeps line spans"
Assert-Equal (Get-DbM21NormalizeFailureCode 'retry #2') 'retry N' "S24 retry counter -> N"
Assert-Not-Equal (Get-DbM21NormalizeFailureCode 'error CS1010') (Get-DbM21NormalizeFailureCode 'error CS1011') "S24 meaningful error-code difference preserved"
Assert-Equal ((Get-DbM21NormalizedFailureCodes -Codes @('Z', 'a', 'Z', 'b')) -join ' ') 'a b Z' "S24 codes sorted+deduped canonically (case-insensitive)"

# S25  SHA-256 house pattern
$h1 = Get-DbM21Sha256Hex 'stable input'
$h2 = Get-DbM21Sha256Hex 'stable input'
Assert-True ($h1 -match '^[0-9a-f]{64}$') "S25 SHA-256 is 64-hex"
Assert-Equal $h1 $h2 "S25 SHA-256 deterministic for identical input"
Assert-Not-Equal (Get-DbM21Sha256Hex 'a') (Get-DbM21Sha256Hex 'b') "S25 SHA-256 differs for different input"

# S26  New-AiFailureFingerprint -- canonical + deterministic identity
$f26 = New-Fp -Codes @('MSB3061', 'error CS1010 at line 7', 'MSB3061')
Assert-Equal ($f26.NormalizedFailureCodes -join ';') 'error CS1010 at line N;MSB3061' "S26 codes normalized to canonical sorted set"
Assert-True ($f26.FingerprintId -match '^FP-1-[0-9a-f]{16}$') "S26 FingerprintId FP-1-<16 hex>"
$f26b = New-Fp -Codes @('MSB3061', 'error CS1010 at line 7')
Assert-Equal $f26.FingerprintId $f26b.FingerprintId "S26 same failure -> same FingerprintId (deterministic)"
$f26c = New-Fp -Codes @('error CS1010 at line 7')
Assert-Not-Equal $f26.FingerprintId $f26c.FingerprintId "S26 different failure identity -> different FingerprintId"

# S27  Secret protection (hash/reference only; secrets rejected)
Assert-Throws { New-Fp -Codes @('sk-abcdefghijklmnop1234567890') } "S27 secret-like failure code rejected"
Assert-Throws { New-Fp -Context ('not-a-hash') } "S27 non-64-hex ContextHash rejected"
$f27 = New-Fp -Context $ctxA
Assert-True ($null -ne $f27) "S27 non-secret fingerprint builds"

# S28  Algorithm versioning -- v1 never reinterpreted as v2
$f28v1 = New-Fp -Codes $codesE1 -AlgorithmVersion 1
$f28v2 = New-Fp -Codes $codesE1 -AlgorithmVersion 2
Assert-Not-Equal $f28v1.Signature $f28v2.Signature "S28 same content at different AlgorithmVersion -> different signature"
$c28 = Compare-AiFailureFingerprint -NewFingerprint $f28v2 -KnownFingerprints @($f28v1) -Result 'FAILURE'
Assert-Equal $c28.RecurrenceType 'FIRST_OCCURRENCE' "S28 v2 never matches a v1 fingerprint"

# S29  Provider-vs-model separation -- infrastructure failures never match quality
$q = New-Fp -Category 'MODEL_QUALITY' -Codes $codesE1 -Tool 'CODING'
$rt = New-Fp -Category 'RATE_LIMIT' -Codes $codesE1 -Tool 'PROVIDER'
$auth = New-Fp -Category 'AUTHENTICATION' -Codes $codesE1 -Tool 'PROVIDER'
$avail = New-Fp -Category 'PROVIDER_AVAILABILITY' -Codes $codesE1 -Tool 'PROVIDER'
Assert-Equal (Compare-AiFailureFingerprint -NewFingerprint $rt -KnownFingerprints @($q) -Result 'FAILURE').RecurrenceType 'FIRST_OCCURRENCE' "S29 RATE_LIMIT never matches MODEL_QUALITY"
Assert-Equal (Compare-AiFailureFingerprint -NewFingerprint $auth -KnownFingerprints @($q) -Result 'FAILURE').RecurrenceType 'FIRST_OCCURRENCE' "S29 AUTHENTICATION never matches MODEL_QUALITY"
Assert-Equal (Compare-AiFailureFingerprint -NewFingerprint $avail -KnownFingerprints @($q) -Result 'FAILURE').RecurrenceType 'FIRST_OCCURRENCE' "S29 PROVIDER_AVAILABILITY never matches MODEL_QUALITY"
$q2 = New-Fp -Category 'MODEL_QUALITY' -Codes $codesE2 -Tool 'CODING'
Assert-Equal (Compare-AiFailureFingerprint -NewFingerprint $q2 -KnownFingerprints @($q) -Result 'FAILURE').RecurrenceType 'FIRST_OCCURRENCE' "S29 same category, different code -> no match (M24 stays meaningful)"

# S30  FIRST_OCCURRENCE
$c30 = Compare-AiFailureFingerprint -NewFingerprint (New-Fp -AttemptId 'A30') -KnownFingerprints @() -Result 'FAILURE'
Assert-Equal $c30.RecurrenceType 'FIRST_OCCURRENCE' "S30 first occurrence typed"

# S31  REPEATED_SAME_ROUTE
$p31 = New-Fp -AttemptId 'A31a' -At $ts
$n31 = New-Fp -AttemptId 'A31b' -At $ts.AddHours(1)
$c31 = Compare-AiFailureFingerprint -NewFingerprint $n31 -KnownFingerprints @($p31) -Result 'FAILURE'
Assert-Equal $c31.RecurrenceType 'REPEATED_SAME_ROUTE' "S31 same provider/model/reasoning -> REPEATED_SAME_ROUTE"
Assert-True ($c31.SameContext -eq $true) "S31 same context confirmed"

# S32  REPEATED_SAME_MODEL (reasoning changed, not escalated)
$p32 = New-Fp -AttemptId 'A32a' -Reasoning 'MEDIUM'
$n32 = New-Fp -AttemptId 'A32b' -Reasoning 'LOW'
$c32 = Compare-AiFailureFingerprint -NewFingerprint $n32 -KnownFingerprints @($p32) -Result 'FAILURE'
Assert-Equal $c32.RecurrenceType 'REPEATED_SAME_MODEL' "S32 same model, reasoning changed (not higher) -> REPEATED_SAME_MODEL"

# S33  REPEATED_AFTER_REASONING_ESCALATION
$p33 = New-Fp -AttemptId 'A33a' -Reasoning 'LOW'
$n33 = New-Fp -AttemptId 'A33b' -Reasoning 'MEDIUM'
$c33 = Compare-AiFailureFingerprint -NewFingerprint $n33 -KnownFingerprints @($p33) -Result 'FAILURE'
Assert-Equal $c33.RecurrenceType 'REPEATED_AFTER_REASONING_ESCALATION' "S33 same model, reasoning higher -> REPEATED_AFTER_REASONING_ESCALATION"
Assert-True ($c33.ReasoningEscalated -eq $true) "S33 ReasoningEscalated flag true"

# S34  REPEATED_AFTER_MODEL_SWITCH
$p34 = New-Fp -AttemptId 'A34a' -Model 'model-a'
$n34 = New-Fp -AttemptId 'A34b' -Model 'model-b'
$c34 = Compare-AiFailureFingerprint -NewFingerprint $n34 -KnownFingerprints @($p34) -Result 'FAILURE'
Assert-Equal $c34.RecurrenceType 'REPEATED_AFTER_MODEL_SWITCH' "S34 different model -> REPEATED_AFTER_MODEL_SWITCH"

# S35  KNOWN_FAILURE_RESOLVED (success now)
$p35 = New-Fp -AttemptId 'A35a'
$n35 = New-Fp -AttemptId 'A35b' -At $ts.AddHours(1)
$c35 = Compare-AiFailureFingerprint -NewFingerprint $n35 -KnownFingerprints @($p35) -Result 'SUCCESS'
Assert-Equal $c35.RecurrenceType 'KNOWN_FAILURE_RESOLVED' "S35 recurring failure now succeeded -> KNOWN_FAILURE_RESOLVED"

# S36  Retry suppression -- identical repeat above threshold
$priors36 = @()
for ($i = 1; $i -le 4; $i++) { $priors36 += New-Fp -AttemptId "A36$i" -At $ts.AddHours($i) }
$n36 = New-Fp -AttemptId 'A36x' -At $ts.AddHours(5)
$ev36 = Get-AiKnownFailureEvidence -Fingerprint $n36 -KnownFingerprints $priors36 -Result 'FAILURE'
$rp36 = Test-AiRepeatAttemptAllowed -Evidence $ev36 -ProposedModelId 'model-a' -ProposedReasoningLevel 'LOW' -ProposedContextHash $ctxA -MaxRepeatsBeforeSuppress 3
Assert-Equal $rp36.Outcome 'RETRY_SUPPRESSED_KNOWN_FAILURE' "S36 identical repeat (5th) over threshold 3 -> RETRY_SUPPRESSED_KNOWN_FAILURE"
Assert-Equal ($rp36.Allowed -eq $false) $true "S36 suppressed -> not allowed"

# S37  Within threshold -> allowed
$rp37 = Test-AiRepeatAttemptAllowed -Evidence $ev36 -ProposedModelId 'model-a' -ProposedReasoningLevel 'LOW' -ProposedContextHash $ctxA -MaxRepeatsBeforeSuppress 6
Assert-Equal $rp37.Outcome 'RETRY_ALLOWED_REPEAT_WITHIN_THRESHOLD' "S37 identical repeat within threshold 6 -> allowed"

# S38  Context change -> allowed (meaningful change, DB-M20 replans)
$rp38 = Test-AiRepeatAttemptAllowed -Evidence $ev36 -ProposedModelId 'model-a' -ProposedReasoningLevel 'LOW' -ProposedContextHash $ctxB -MaxRepeatsBeforeSuppress 3
Assert-Equal $rp38.Outcome 'RETRY_ALLOWED_CONTEXT_CHANGED' "S38 changed context -> RETRY_ALLOWED_CONTEXT_CHANGED"
$rp38b = Test-AiRepeatAttemptAllowed -Evidence $ev36 -ProposedModelId 'model-b' -ProposedReasoningLevel 'LOW' -ProposedContextHash $ctxA -MaxRepeatsBeforeSuppress 3
Assert-Equal $rp38b.Outcome 'RETRY_ALLOWED_MODEL_SWITCH' "S38 proposed model switch -> RETRY_ALLOWED_MODEL_SWITCH"
$rp38c = Test-AiRepeatAttemptAllowed -Evidence $ev36 -ProposedModelId 'model-a' -ProposedReasoningLevel 'HIGH' -ProposedContextHash $ctxA -MaxRepeatsBeforeSuppress 3
Assert-Equal $rp38c.Outcome 'RETRY_ALLOWED_REASONING_ESCALATED' "S38 proposed reasoning escalation -> RETRY_ALLOWED_REASONING_ESCALATED"

# S39  Get-AiKnownFailureEvidence -- full evidence bundle
$ev39 = Get-AiKnownFailureEvidence -Fingerprint $n36 -KnownFingerprints $priors36 -Result 'FAILURE'
Assert-Equal $ev39.MatchedCount 4 "S39 evidence matched 4 prior fingerprints"
Assert-Equal $ev39.OccurrenceCount 5 "S39 evidence occurrence count 5"
Assert-Equal ($ev39.AttemptIds.Count) 5 "S39 evidence carries all attempt ids"
Assert-True ($ev39.SameContext -eq $true) "S39 evidence SameContext true (both present and equal)"
Assert-Equal ($ev39.MatchedFingerprints.Count) 4 "S39 evidence carries matched priors"
Assert-Equal $ev39.MatchedModelId 'model-a' "S39 evidence matched route reference exposed"

# S40  Recurrence types are DISTINCT (never flat); persistent failures are evidence-only
$types = Get-DbM21RecurrenceTypes
Assert-Equal $types.Count 7 "S40 exactly 7 recurrence types"
Assert-Equal (@($types | Sort-Object -Unique).Count) 7 "S40 recurrence types are distinct (not all identical)"
$implPrior = New-Fp -AttemptId 'A40a' -Category 'VERIFICATION_FAILURE' -Codes @('assert E400') -Tool 'VERIFICATION'
$implNew = New-Fp -AttemptId 'A40b' -Category 'VERIFICATION_FAILURE' -Codes @('assert E400') -Tool 'VERIFICATION' -At $ts.AddHours(1)
$ev40 = Get-AiKnownFailureEvidence -Fingerprint $implNew -KnownFingerprints @($implPrior) -Result 'FAILURE'
Assert-In $ev40.RecurrenceType @('REPEATED_SAME_ROUTE', 'REPEATED_SAME_FAILURE', 'REPEATED_SAME_MODEL') "S40 persistent implementation failure -> REPEATED_* evidence"
# evidence carries NO roadmap / fix-task authority (represent-only lives in DB-M20)
$ev40HasRoadmapField = ($null -ne (Get-ContractProperty $ev40 'NewFixTask' $null)) -or ($null -ne (Get-ContractProperty $ev40 'RoadmapAction' $null))
Assert-Equal ($ev40HasRoadmapField -eq $true) $false "S40 failure evidence has no roadmap/fix-task field (evidence signal only)"

# -----------------------------------------------------------------------------
# COMBINED ATTEMPT PERMISSION (S41..S50)
# -----------------------------------------------------------------------------
$budgetAllow = Test-AiBudget -Policy (New-BudgetPolicy -PolicyId 'BP-ALLOW' -Currency 'INR' -TaskLimit 1000 -AllowManualOverride $false) `
    -EvaluationTimestampUtc $ts -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' -Attempts @()
$budgetWarn = Test-AiBudget -Policy (New-BudgetPolicy -PolicyId 'BP-WARN' -Currency 'INR' -TaskLimit 100 -WarnAtPercent 80 -AllowManualOverride $false) `
    -EvaluationTimestampUtc $ts -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 85 -ProposedCostCurrency 'INR' -Attempts @()
$budgetBlock = Test-AiBudget -Policy (New-BudgetPolicy -PolicyId 'BP-BLOCK' -Currency 'INR' -TaskLimit 10 -AllowManualOverride $false) `
    -EvaluationTimestampUtc $ts -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' `
    -Attempts @((New-DbM21AttemptForBudget -TaskId 'T1' -ActualCost 8))
$budgetReqOverride = Test-AiBudget -Policy (New-BudgetPolicy -PolicyId 'BP-ORIDE' -Currency 'INR' -TaskLimit 10 -AllowManualOverride $true) `
    -EvaluationTimestampUtc $ts -TaskId 'T1' -Purpose 'AI_ATTEMPT' -ProposedAttemptCost 5 -ProposedCostCurrency 'INR' `
    -Attempts @((New-DbM21AttemptForBudget -TaskId 'T1' -ActualCost 8))

# S41  all clear -> ALLOW_ATTEMPT
$p41 = Get-AiAttemptPermission -BudgetEvaluation $budgetAllow -EscalationDecision (New-M20Decision) -Purpose 'AI_ATTEMPT'
Assert-Equal $p41.Outcome 'ALLOW_ATTEMPT' "S41 all clear -> ALLOW_ATTEMPT"

# S42  budget warning -> ALLOW_WITH_BUDGET_WARNING
$p42 = Get-AiAttemptPermission -BudgetEvaluation $budgetWarn -EscalationDecision (New-M20Decision) -Purpose 'AI_ATTEMPT'
Assert-Equal $p42.Outcome 'ALLOW_WITH_BUDGET_WARNING' "S42 budget warning -> ALLOW_WITH_BUDGET_WARNING"
Assert-Contains $p42.ReasonCodes 'BUDGET_WARNING' "S42 reason BUDGET_WARNING"

# S43  budget block -> BLOCK_BUDGET
$p43 = Get-AiAttemptPermission -BudgetEvaluation $budgetBlock -EscalationDecision (New-M20Decision) -Purpose 'AI_ATTEMPT'
Assert-Equal $p43.Outcome 'BLOCK_BUDGET' "S43 budget block -> BLOCK_BUDGET"
Assert-Contains $p43.ReasonCodes 'BUDGET_BLOCKED' "S43 reason BUDGET_BLOCKED"

# S44  budget requires override -> REQUIRE_HUMAN_OVERRIDE
$p44 = Get-AiAttemptPermission -BudgetEvaluation $budgetReqOverride -EscalationDecision (New-M20Decision) -Purpose 'AI_ATTEMPT'
Assert-Equal $p44.Outcome 'REQUIRE_HUMAN_OVERRIDE' "S44 budget REQUIRE_HUMAN_OVERRIDE -> REQUIRE_HUMAN_OVERRIDE"
Assert-Contains $p44.ReasonCodes 'BUDGET_REQUIRES_OVERRIDE' "S44 reason BUDGET_REQUIRES_OVERRIDE"

# S45  known-failure suppression + DB-M20 about to repeat identical route -> BLOCK_KNOWN_FAILURE_REPEAT
$priors45 = @()
for ($i = 1; $i -le 4; $i++) { $priors45 += New-Fp -AttemptId "A45$i" -At $ts.AddHours($i) }
$n45 = New-Fp -AttemptId 'A45x' -At $ts.AddHours(5)
$ev45 = Get-AiKnownFailureEvidence -Fingerprint $n45 -KnownFingerprints $priors45 -Result 'FAILURE'
$ra45 = Test-AiRepeatAttemptAllowed -Evidence $ev45 -ProposedModelId 'model-a' -ProposedReasoningLevel 'LOW' -ProposedContextHash $ctxA -MaxRepeatsBeforeSuppress 3
$p45 = Get-AiAttemptPermission -BudgetEvaluation $budgetAllow -RepeatEvidence $ev45 -RepeatAllowed $ra45 `
    -EscalationDecision (New-M20Decision -Action 'RETRY_SAME_ROUTE') -Purpose 'AI_ATTEMPT'
Assert-Equal $p45.Outcome 'BLOCK_KNOWN_FAILURE_REPEAT' "S45 suppressed identical repeat + M20 RETRY_SAME_ROUTE -> BLOCK_KNOWN_FAILURE_REPEAT"
Assert-Contains $p45.ReasonCodes 'KNOWN_FAILURE_SUPPRESSED' "S45 reason KNOWN_FAILURE_SUPPRESSED"

# S46  DB-M20 terminal -> REQUIRE_ESCALATION_REPLAN (never a retry)
$p46 = Get-AiAttemptPermission -BudgetEvaluation $budgetAllow -EscalationDecision (New-M20Decision -Status 'STOP_GOVERNANCE' -Action 'STOP_GOVERNANCE') -Purpose 'AI_ATTEMPT'
Assert-Equal $p46.Outcome 'REQUIRE_ESCALATION_REPLAN' "S46 M20 STOP_GOVERNANCE -> REQUIRE_ESCALATION_REPLAN"

# S47  Git human gates are NOT AI failures -- never retried, zero budget
$p47 = Get-AiAttemptPermission -BudgetEvaluation $budgetAllow -EscalationDecision (New-M20Decision -Status 'HUMAN_GIT_ACTION_REQUIRED' -Action 'HUMAN_GIT_ACTION_REQUIRED') -Purpose 'AI_ATTEMPT'
Assert-Equal $p47.Outcome 'REQUIRE_ESCALATION_REPLAN' "S47 M20 HUMAN_GIT_ACTION_REQUIRED -> REQUIRE_ESCALATION_REPLAN (never a retry)"
Assert-Contains $p47.ReasonCodes 'M20_HUMAN_GATE' "S47 reason M20_HUMAN_GATE"
$p47b = Get-AiAttemptPermission -BudgetEvaluation $budgetBlock -Purpose 'HUMAN_GATE'
Assert-Equal $p47b.Outcome 'ALLOW_ATTEMPT' "S47 a human gate consumes zero budget regardless of a budget block"

# S48  a budget override does NOT permit an identical repeat
$override = Test-AiBudgetOverride -Policy (New-BudgetPolicy -PolicyId 'BP-ORIDE' -Currency 'INR' -TaskLimit 10) `
    -Evaluation $budgetReqOverride -OverrideReference 'R-1' -OverrideReason 'emergency' -OverrideTimestampUtc $ts
$p48 = Get-AiAttemptPermission -BudgetEvaluation $budgetReqOverride -BudgetOverride $override `
    -RepeatEvidence $ev45 -RepeatAllowed $ra45 -EscalationDecision (New-M20Decision -Action 'RETRY_SAME_ROUTE') -Purpose 'AI_ATTEMPT'
Assert-Equal $p48.Outcome 'BLOCK_KNOWN_FAILURE_REPEAT' "S48 explicit budget override still does not permit the identical repeat -> BLOCK_KNOWN_FAILURE_REPEAT"

# S49  AUTO execution prohibited
$p49 = Get-AiAttemptPermission -BudgetEvaluation $budgetAllow -AutoExecutionEnabled $true -Purpose 'AI_ATTEMPT'
Assert-Equal $p49.Outcome 'REQUIRE_ESCALATION_REPLAN' "S49 AUTO_EXECUTION_ENABLED=true -> REQUIRE_ESCALATION_REPLAN"
Assert-Contains $p49.ReasonCodes 'AUTO_EXECUTION_PROHIBITED' "S49 reason AUTO_EXECUTION_PROHIBITED"
$p49b = Get-AiAttemptPermission -BudgetEvaluation $budgetAllow -EscalationDecision ([pscustomobject]@{ Status = 'RECOMMENDED'; Action = 'RETRY_SAME_ROUTE'; AutoExecutionEnabled = $true }) -Purpose 'AI_ATTEMPT'
Assert-Equal $p49b.Outcome 'REQUIRE_ESCALATION_REPLAN' "S49 DB-M20 decision AutoExecutionEnabled=true -> REQUIRE_ESCALATION_REPLAN"

# S50  Temporary DevBridge boundary -- no execution / network / Nexus / Git / roadmap
$libFiles = @(
    (Join-Path $script:Root 'ai-routing\budget\BudgetPolicy.ps1'),
    (Join-Path $script:Root 'ai-routing\budget\BudgetEngine.ps1'),
    (Join-Path $script:Root 'ai-routing\failure-fingerprints\FingerprintContracts.ps1'),
    (Join-Path $script:Root 'ai-routing\failure-fingerprints\FingerprintEngine.ps1'),
    (Join-Path $script:Root 'ai-routing\failure-fingerprints\AttemptPermission.ps1')
)
$forbidden = @('Invoke-AiModel', 'Invoke-RestMethod', 'Invoke-WebRequest', 'System.Net.Http', 'HttpClient', 'WebRequest', 'git merge', 'git push', 'git commit', 'New-Nexus', 'Nexus.Developer', 'C:\Personal\Nexus', '.xlsx', 'current-task.json')
$boundaryOk = $true
foreach ($f in $libFiles) {
    Assert-True (Test-Path $f) "S50 library file exists: $(Split-Path $f -Leaf)"
    $content = Get-Content $f -Raw
    foreach ($tok in $forbidden) {
        if ($content -like "*$tok*") { $boundaryOk = $false; Write-Output ("FAIL: $tok present in $(Split-Path $f -Leaf)") }
    }
}
Assert-True $boundaryOk "S50 no execution/network/Nexus/Git/workbook token in any DB-M21 library file"
Assert-Equal (Get-DbM21PermissionOutcomes).Count 6 "S50 exactly 6 combined permission outcomes"
Assert-Equal ((Get-Command Get-AiAttemptPermission).ScriptBlock.File) $libFiles[4] "S50 Get-AiAttemptPermission defined in DevBridge-owned AttemptPermission.ps1"
$p50 = Get-AiAttemptPermission -BudgetEvaluation $budgetAllow -EscalationDecision (New-M20Decision) -Purpose 'AI_ATTEMPT'
Assert-Equal ($p50.AutoExecutionEnabled -eq $false) $true "S50 every permission record reports AutoExecutionEnabled FALSE"

# -----------------------------------------------------------------------------
if ($script:Fails -gt 0) { exit 1 }
exit 0

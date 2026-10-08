# Test-AttemptStore.ps1 — DB-M17 self-contained assertion suite.
#
# Proves the attempt/usage history foundation WITHOUT any paid API call, network
# access, or credential use. All fixtures are in-memory or temp files under
# $env:TEMP - nothing under the real logs/ or state/ is touched. The real
# config/providers.json + config/models.json are READ (not written) for reference
# validation. ZERO paid API calls. Matches the DevBridge Assert-True convention
# (see Test-AiRoutingFoundation.ps1).
#
# Run: powershell -NoProfile -File ai-routing\Test-AttemptStore.ps1
# Exit code: 0 all pass, 1 any failure.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "AttemptStore.ps1")

$script:Results = @()
$script:Fails = New-Object System.Collections.Generic.List[string]

function Assert-True([string]$label, [bool]$cond, [string]$detail) {
    $row = New-Object PSCustomObject
    $row | Add-Member NoteProperty -Name Scenario -Value $label
    $row | Add-Member NoteProperty -Name Pass -Value $cond
    $row | Add-Member NoteProperty -Name Detail -Value $detail
    $script:Results += $row
    if (-not $cond) {
        $script:Fails.Add(("{0}: {1}" -f $label, $detail))
        Write-Output ("  [FAIL] {0} - {1}" -f $label, $detail)
    } else {
        Write-Output ("  [PASS] {0} - {1}" -f $label, $detail)
    }
}

# --- isolated temp fixture root ---------------------------------------------------
$script:TempRoot = Join-Path $env:TEMP ("devbridge-dbm17-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:TempRoot | Out-Null

$fixtureNode = 'WI-07-0.2.4'
$fixtureChange = 'CHG-20260901-001'
$fixtureTask = 'WI-07-0.2.4'
$fixtureMilestone = 'M-07-0.2'

# Reference catalogues are read from the REAL project config (read-only).
$ref = Get-AiAttemptReferenceCatalogues -Root $script:Root

try {
    # --- scenario 1: single successful attempt --------------------------------------
    Write-Output ""
    Write-Output "== Scenario 1 - single successful attempt =="
    $a1 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask `
        -MilestoneId $fixtureMilestone -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' `
        -ReasoningLevel 'MEDIUM' -TaskType 'IMPLEMENTATION' -Complexity 'MEDIUM' -Risk 'LOW'
    Assert-True 'S1 attempt created with AttemptId ATT-CHG-20260901-001-001' ($a1.AttemptId -eq 'ATT-CHG-20260901-001-001') "got '$($a1.AttemptId)'"
    Assert-True 'S1 schemaVersion is 1' ($a1.SchemaVersion -eq 1) "got $($a1.SchemaVersion)"
    Assert-True 'S1 initial Result is PENDING' ($a1.Result -eq 'PENDING') "got '$($a1.Result)'"
    Assert-True 'S1 StartedAtUtc is set' (-not [string]::IsNullOrWhiteSpace([string]$a1.StartedAtUtc)) "got '$($a1.StartedAtUtc)'"
    $v1 = Test-AiAttemptRecord $a1
    Assert-True 'S1 record validates' $v1.Valid ($v1.Errors -join '; ')
    $end1 = (Get-Date).ToUniversalTime().ToString('o')
    $a1b = Set-AiAttemptOutcome -Root $script:TempRoot -Record $a1 -Result 'SUCCESS' -EndedAtUtc $end1 -FilesChanged 2 -TestsPassed 5
    Assert-True 'S1 outcome SUCCESS recorded' ($a1b.Result -eq 'SUCCESS') "got '$($a1b.Result)'"
    Assert-True 'S1 EndedAtUtc recorded' (-not [string]::IsNullOrWhiteSpace([string]$a1b.EndedAtUtc)) "got '$($a1b.EndedAtUtc)'"
    Assert-True 'S1 DurationMs computed non-negative' ($null -ne $a1b.DurationMs -and $a1b.DurationMs -ge 0) "got '$($a1b.DurationMs)'"
    Assert-True 'S1 evidence counts stored' ($a1b.FilesChanged -eq 2 -and $a1b.TestsPassed -eq 5) "got Files=$($a1b.FilesChanged) Tests=$($a1b.TestsPassed)"
    $r1 = Read-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -AttemptId 'ATT-CHG-20260901-001-001'
    Assert-True 'S1 record persisted and re-readable' ($null -ne $r1 -and $r1.Result -eq 'SUCCESS') "read result '$($r1.Result)'"

    # --- scenario 2: failed attempt ------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 2 - failed attempt =="
    $a2 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask `
        -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -TaskType 'IMPLEMENTATION'
    $a2b = Set-AiAttemptOutcome -Root $script:TempRoot -Record $a2 -Result 'FAILED' -FailureCategory 'TEST_FAILURE' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    Assert-True 'S2 Result FAILED recorded' ($a2b.Result -eq 'FAILED') "got '$($a2b.Result)'"
    Assert-True 'S2 FailureCategory TEST_FAILURE recorded' ($a2b.FailureCategory -eq 'TEST_FAILURE') "got '$($a2b.FailureCategory)'"
    $v2 = Test-AiAttemptRecord $a2b
    Assert-True 'S2 failed record validates' $v2.Valid ($v2.Errors -join '; ')

    # --- scenario 3: three attempts ending in success ------------------------------
    Write-Output ""
    Write-Output "== Scenario 3 - three attempts ending in success =="
    $t3 = New-Object System.Collections.Generic.List[object]
    $t3Start = (Get-Date).ToUniversalTime()
    for ($i = 0; $i -lt 3; $i++) {
        $att = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask `
            -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -TaskType 'IMPLEMENTATION'
        $t3.Add($att)
    }
    $resultState = @('FAILED', 'FAILED', 'SUCCESS')
    $failCat = @('MODEL_QUALITY', 'RATE_LIMIT', $null)
    for ($i = 0; $i -lt 3; $i++) {
        $end = $t3Start.AddSeconds(5 + $i).ToUniversalTime().ToString('o')
        $out = @{ Record = $t3[$i]; Result = $resultState[$i]; EndedAtUtc = $end; Root = $script:TempRoot }
        if ($failCat[$i]) { $out.FailureCategory = $failCat[$i] }
        $null = Set-AiAttemptOutcome @out
    }
    $ids3 = @($t3 | ForEach-Object { $_.AttemptId })
    Assert-True 'S3 attempt ids sequence 003,004,005 (after S1=001, S2=002)' ($ids3 -join ',' -eq 'ATT-CHG-20260901-001-003,ATT-CHG-20260901-001-004,ATT-CHG-20260901-001-005') "got '$($ids3 -join ',')'"
    $hist3 = Read-AiAttemptHistory -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange
    $all = @(Get-AiAttemptsForChange -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange)
    $results3 = @($all | Where-Object { $_.AttemptId -in $ids3 } | ForEach-Object { $_.Result })
    Assert-True 'S3 three outcomes recorded' ($results3 -join ',' -eq 'FAILED,FAILED,SUCCESS') "got '$($results3 -join ',')'"
    Assert-True 'S3 history schemaVersion is 1' ($hist3.SchemaVersion -eq 1) "got $($hist3.SchemaVersion)"

    # --- scenario 4: failed attempts remain after later success ---------------------
    Write-Output ""
    Write-Output "== Scenario 4 - append-oriented history =="
    $rem = @($all | Where-Object { $_.AttemptId -in $ids3 })
    $remResults = @($rem | ForEach-Object { $_.Result })
    Assert-True 'S4 all three attempts remain queryable' ($rem.Count -eq 3 -and $remResults -contains 'FAILED') "got count=$($rem.Count) results=$($remResults -join ',')"
    Assert-True 'S4 earlier failed attempts still FAILED after later success' (@($rem | Where-Object { $_.Result -eq 'FAILED' }).Count -eq 2) "expected 2 failed"
    $agg4 = Get-AiAttemptAggregates -Records $rem
    Assert-True 'S4 aggregate success/failure split correct' ($agg4.SuccessCount -eq 1 -and $agg4.FailureCount -eq 2) "got success=$($agg4.SuccessCount) failure=$($agg4.FailureCount)"
    Assert-True 'S4 history attemptIds preserves all and no duplicates' (($hist3.AttemptIds.Count -eq (Get-AiAttemptsAll -Root $script:TempRoot).Count) -and (@($hist3.AttemptIds | Select-Object -Unique).Count -eq $hist3.AttemptIds.Count)) "got $($hist3.AttemptIds.Count) ids"

    # --- scenario 5: cancelled ------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 5 - cancelled =="
    $a5 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask
    $a5b = Set-AiAttemptOutcome -Root $script:TempRoot -Record $a5 -Result 'CANCELLED' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    Assert-True 'S5 Result CANCELLED recorded' ($a5b.Result -eq 'CANCELLED') "got '$($a5b.Result)'"
    $v5 = Test-AiAttemptRecord $a5b
    Assert-True 'S5 cancelled record validates' $v5.Valid ($v5.Errors -join '; ')

    # --- scenario 6: blocked ---------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 6 - blocked =="
    $a6 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask
    $a6b = Set-AiAttemptOutcome -Root $script:TempRoot -Record $a6 -Result 'BLOCKED' -FailureCategory 'PROVIDER_AVAILABILITY' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    Assert-True 'S6 Result BLOCKED recorded' ($a6b.Result -eq 'BLOCKED') "got '$($a6b.Result)'"
    Assert-True 'S6 provider availability failure category' ($a6b.FailureCategory -eq 'PROVIDER_AVAILABILITY') "got '$($a6b.FailureCategory)'"

    # --- scenario 7: waiting human ----------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 7 - waiting human =="
    $a7 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask
    $a7b = Set-AiAttemptHumanIntervention -Root $script:TempRoot -Record $a7 -Notes 'Human review required before proceeding'
    $a7c = Set-AiAttemptOutcome -Root $script:TempRoot -Record $a7b -Result 'WAITING_HUMAN'
    Assert-True 'S7 Result WAITING_HUMAN recorded' ($a7c.Result -eq 'WAITING_HUMAN') "got '$($a7c.Result)'"
    Assert-True 'S7 HumanIntervention flagged true' ($a7c.HumanIntervention -eq $true) "got '$($a7c.HumanIntervention)'"
    Assert-True 'S7 human note recorded' ([string]$a7c.Notes -match 'Human review') "notes '$($a7c.Notes)'"
    $v7 = Test-AiAttemptRecord $a7c
    Assert-True 'S7 waiting-human record validates (transitional, no end time needed)' $v7.Valid ($v7.Errors -join '; ')

    # --- scenario 8: budget stopped ----------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 8 - budget stopped =="
    $a8 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask
    $a8b = Set-AiAttemptOutcome -Root $script:TempRoot -Record $a8 -Result 'BUDGET_STOPPED' -FailureCategory 'BUDGET_FAILURE' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    Assert-True 'S8 Result BUDGET_STOPPED recorded' ($a8b.Result -eq 'BUDGET_STOPPED') "got '$($a8b.Result)'"
    Assert-True 'S8 budget failure category' ($a8b.FailureCategory -eq 'BUDGET_FAILURE') "got '$($a8b.FailureCategory)'"

    # --- scenario 9: escalated attempt links -------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 9 - escalated attempt links =="
    $e1 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask `
        -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -ReasoningLevel 'MEDIUM'
    $null = Set-AiAttemptOutcome -Root $script:TempRoot -Record $e1 -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    $e2 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask `
        -ProviderId 'anthropic' -ModelId 'claude-opus-5' -ReasoningLevel 'HIGH' -ParentAttemptId $e1.AttemptId
    $e2b = Set-AiAttemptEscalation -Root $script:TempRoot -Record $e2 -EscalatedFromAttemptId $e1.AttemptId -EscalationReason 'model quality insufficient; escalate to premium'
    $null = Set-AiAttemptOutcome -Root $script:TempRoot -Record $e2b -Result 'SUCCESS' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    $e1b = Set-AiAttemptEscalation -Root $script:TempRoot -Record $e1 -EscalatedToAttemptId $e2.AttemptId -EscalationReason 'model quality insufficient; escalate to premium'
    Assert-True 'S9 child records EscalatedFromAttemptId' ($e2b.EscalatedFromAttemptId -eq $e1.AttemptId) "got '$($e2b.EscalatedFromAttemptId)'"
    Assert-True 'S9 parent records EscalatedToAttemptId' ($e1b.EscalatedToAttemptId -eq $e2.AttemptId) "got '$($e1b.EscalatedToAttemptId)'"
    Assert-True 'S9 escalation reason recorded' (-not [string]::IsNullOrWhiteSpace([string]$e2b.EscalationReason)) "got '$($e2b.EscalationReason)'"
    Assert-True 'S9 escalation link persisted on disk' ((Read-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -AttemptId $e2.AttemptId).EscalatedFromAttemptId -eq $e1.AttemptId) "not found"

    # --- scenario 10: retry numbering ----------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 10 - retry numbering =="
    Assert-True 'S10 parentless attempt RetryNumber 0' ($e1.RetryNumber -eq 0) "got '$($e1.RetryNumber)'"
    Assert-True 'S10 parent-chained attempt RetryNumber = parent + 1' ($e2.RetryNumber -eq 1) "got '$($e2.RetryNumber)'"

    # --- scenario 11/12/13: failure categories --------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 11-13 - failure categories =="
    $f11 = New-AiAttemptRecord -AttemptId 'FAIL-011' -ChangeId $fixtureChange -Result 'FAILED' -FailureCategory 'PROVIDER_AVAILABILITY' -StartedAtUtc '2026-08-30T00:00:00Z' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    $f12 = New-AiAttemptRecord -AttemptId 'FAIL-012' -ChangeId $fixtureChange -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' -StartedAtUtc '2026-08-30T00:00:00Z' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    $f13 = New-AiAttemptRecord -AttemptId 'FAIL-013' -ChangeId $fixtureChange -Result 'FAILED' -FailureCategory 'AUTHENTICATION' -StartedAtUtc '2026-08-30T00:00:00Z' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    Assert-True 'S11 provider availability category valid' ((Test-AiAttemptRecord $f11).Valid -and $f11.FailureCategory -eq 'PROVIDER_AVAILABILITY') 'S11 failed'
    Assert-True 'S12 model quality category valid and distinct' ((Test-AiAttemptRecord $f12).Valid -and $f12.FailureCategory -eq 'MODEL_QUALITY') 'S12 failed'
    Assert-True 'S13 authentication category valid' ((Test-AiAttemptRecord $f13).Valid -and $f13.FailureCategory -eq 'AUTHENTICATION') 'S13 failed'
    Assert-True 'S11/12 provider-availability is not conflated with model quality' ($f11.FailureCategory -ne $f12.FailureCategory) 'categories conflated'

    # --- scenario 14: missing token usage ------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 14 - missing token usage =="
    $a14 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask
    $a14b = Set-AiAttemptOutcome -Root $script:TempRoot -Record $a14 -Result 'SUCCESS' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    Assert-True 'S14 usage source stays UNKNOWN when no usage returned' ($a14b.UsageSource -eq 'UNKNOWN') "got '$($a14b.UsageSource)'"
    Assert-True 'S14 token fields stay null when usage unknown' ($null -eq $a14b.InputTokens -and $null -eq $a14b.OutputTokens) "got in=$($a14b.InputTokens) out=$($a14b.OutputTokens)"
    $bad14 = New-AiAttemptRecord -AttemptId 'BAD-014' -ChangeId $fixtureChange -Result 'SUCCESS' -StartedAtUtc '2026-08-30T00:00:00Z' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o') -UsageSource 'UNKNOWN' -InputTokens 100
    Assert-True 'S14 UNKNOWN usage carrying counts is rejected' (-not (Test-AiAttemptRecord $bad14).Valid) 'UNKNOWN usage with tokens must be rejected'

    # --- scenario 15: actual token usage stored ---------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 15 - actual token usage stored =="
    $a15 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask
    $a15b = Set-AiAttemptUsage -Root $script:TempRoot -Record $a15 -UsageSource 'ACTUAL' -InputTokens 1200 -CachedInputTokens 300 -CacheWriteTokens 0 -OutputTokens 800 -ReasoningTokens 200 -ToolCalls 5
    Assert-True 'S15 actual usage stored verbatim' ($a15b.InputTokens -eq 1200 -and $a15b.OutputTokens -eq 800 -and $a15b.ReasoningTokens -eq 200 -and $a15b.ToolCalls -eq 5) "got in=$($a15b.InputTokens) out=$($a15b.OutputTokens)"
    Assert-True 'S15 usage source marked ACTUAL' ($a15b.UsageSource -eq 'ACTUAL') "got '$($a15b.UsageSource)'"
    Assert-True 'S15 cached/cache-write tokens preserved' ($a15b.CachedInputTokens -eq 300 -and $a15b.CacheWriteTokens -eq 0) "got cached=$($a15b.CachedInputTokens) write=$($a15b.CacheWriteTokens)"

    # --- scenario 16: estimated vs actual distinction -----------------------------------------
    Write-Output ""
    Write-Output "== Scenario 16 - estimated vs actual distinction =="
    $a16e = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask
    $a16e = Set-AiAttemptUsage -Root $script:TempRoot -Record $a16e -UsageSource 'ESTIMATED' -InputTokens 1000 -OutputTokens 700
    $a16a = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask
    $a16a = Set-AiAttemptUsage -Root $script:TempRoot -Record $a16a -UsageSource 'ACTUAL' -InputTokens 987 -OutputTokens 654
    Assert-True 'S16 estimated record stays ESTIMATED' ($a16e.UsageSource -eq 'ESTIMATED' -and $a16e.InputTokens -eq 1000) "got $($a16e.UsageSource)/$($a16e.InputTokens)"
    Assert-True 'S16 actual record stays ACTUAL' ($a16a.UsageSource -eq 'ACTUAL' -and $a16a.InputTokens -eq 987) "got $($a16a.UsageSource)/$($a16a.InputTokens)"
    Assert-True 'S16 estimates are not relabeled as actual' ($a16e.UsageSource -ne $a16a.UsageSource) 'sources conflated'

    # --- scenario 17/18: human intervention / manual override --------------------------------
    Write-Output ""
    Write-Output "== Scenario 17-18 - human intervention / manual override =="
    $a17 = New-AiAttemptRecord -AttemptId 'HUM-017' -ChangeId $fixtureChange -Result 'SUCCESS' -StartedAtUtc '2026-08-30T00:00:00Z' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o') -HumanIntervention $true -ManualOverride $true
    Assert-True 'S17 HumanIntervention flag stored' ($a17.HumanIntervention -eq $true) "got '$($a17.HumanIntervention)'"
    Assert-True 'S18 ManualOverride flag stored' ($a17.ManualOverride -eq $true) "got '$($a17.ManualOverride)'"
    Assert-True 'S17/18 flags do not break validation' (Test-AiAttemptRecord $a17).Valid 'validation failed'

    # --- scenario 19: provider/model lookup ---------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 19 - provider/model lookup =="
    $good = New-AiAttemptRecord -AttemptId 'REF-019' -ChangeId $fixtureChange -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -UnderlyingModelId 'deepseek-v4-flash'
    $gv = Test-AiAttemptRecordReferences -Record $good -Providers $ref.Providers -Models $ref.Models -UnderlyingModelIds $ref.UnderlyingModelIds
    Assert-True 'S19 valid provider/model references accepted' $gv.Valid ($gv.Errors -join '; ')
    $badProv = New-AiAttemptRecord -AttemptId 'REF-019B' -ChangeId $fixtureChange -ProviderId 'not-a-provider' -ModelId 'deepseek-v4-flash'
    $bp = Test-AiAttemptRecordReferences -Record $badProv -Providers $ref.Providers -Models $ref.Models -UnderlyingModelIds $ref.UnderlyingModelIds
    Assert-True 'S19 unknown provider rejected' (-not $bp.Valid) ($bp.Errors -join '; ')
    $badModel = New-AiAttemptRecord -AttemptId 'REF-019C' -ChangeId $fixtureChange -ProviderId 'deepseek' -ModelId 'not-a-model'
    $bm = Test-AiAttemptRecordReferences -Record $badModel -Providers $ref.Providers -Models $ref.Models -UnderlyingModelIds $ref.UnderlyingModelIds
    Assert-True 'S19 unknown model rejected' (-not $bm.Valid) ($bm.Errors -join '; ')
    $badUm = New-AiAttemptRecord -AttemptId 'REF-019D' -ChangeId $fixtureChange -ProviderId 'anthropic' -ModelId 'claude-opus-5' -UnderlyingModelId 'not-an-underlying'
    $bu = Test-AiAttemptRecordReferences -Record $badUm -Providers $ref.Providers -Models $ref.Models -UnderlyingModelIds $ref.UnderlyingModelIds
    Assert-True 'S19 unknown underlying model rejected' (-not $bu.Valid) ($bu.Errors -join '; ')

    # --- scenario 20: history by task -----------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 20 - history by task =="
    $changeB = 'CHG-20260901-002'
    $b1 = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $changeB -TaskId $fixtureTask -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash'
    $null = Set-AiAttemptOutcome -Root $script:TempRoot -Record $b1 -Result 'SUCCESS' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    $taskRecs = @(Get-AiAttemptsForTask -Root $script:TempRoot -NodeId $fixtureNode)
    $changeSet = @($taskRecs | ForEach-Object { $_.ChangeId } | Sort-Object -Unique)
    Assert-True 'S20 task query spans multiple changes' ($changeSet -contains $fixtureChange -and $changeSet -contains $changeB) "changes: $($changeSet -join ',')"
    Assert-True 'S20 task query returns attempts from both changes' ($taskRecs.Count -ge 4) "got $($taskRecs.Count)"

    # --- scenario 21: history by change -------------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 21 - history by change =="
    $chgRecs = @(Get-AiAttemptsForChange -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $changeB)
    Assert-True 'S21 change query scoped to one change' (@($chgRecs | ForEach-Object { $_.ChangeId } | Sort-Object -Unique) -join ',' -eq $changeB) 'wrong scope'
    Assert-True 'S21 change query returns exact attempt set' ($chgRecs.Count -eq 1) "got $($chgRecs.Count)"

    # --- scenario 22: history by model ----------------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 22 - history by model =="
    $opus = @(Get-AiAttemptsByModel -Root $script:TempRoot -ModelId 'claude-opus-5' -NodeId $fixtureNode)
    $ds = @(Get-AiAttemptsByModel -Root $script:TempRoot -ModelId 'deepseek-v4-flash' -NodeId $fixtureNode)
    Assert-True 'S22 by-model query filters correctly' (@($opus | ForEach-Object { $_.ModelId } | Sort-Object -Unique) -join ',' -eq 'claude-opus-5' -and $opus.Count -ge 1) "opus got $($opus.Count)"
    Assert-True 'S22 deepseek model found in history' ($ds.Count -ge 1) "ds got $($ds.Count)"

    # --- scenario 23: schema v1 round-trip -----------------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 23 - schema v1 round-trip =="
    $rt = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask `
        -ProviderId 'anthropic' -ModelId 'claude-sonnet-5' -ReasoningLevel 'HIGH' -TaskType 'VERIFICATION' -Complexity 'HIGH' -Risk 'MEDIUM'
    $rt = Set-AiAttemptUsage -Root $script:TempRoot -Record $rt -UsageSource 'ACTUAL' -InputTokens 5000 -OutputTokens 1200
    $rt = Set-AiAttemptVerification -Root $script:TempRoot -Record $rt -VerificationResult 'VERIFIED' -VerificationEvidencePath 'logs/tasks/WI-07-0.2.4/CHG-20260901-001/verification.json'
    $rt = Set-AiAttemptOutcome -Root $script:TempRoot -Record $rt -Result 'SUCCESS' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o') -FilesChanged 3 -TestsPassed 8 -TestsFailed 0 -TestsSkipped 1
    $rtFile = Get-AiAttemptRecordPath -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -AttemptId $rt.AttemptId
    $raw = Get-Content $rtFile -Raw -Encoding UTF8
    Assert-True 'S23 persisted file carries schemaVersion 1' ($raw -match '"SchemaVersion"\s*:\s*1') 'schemaVersion not 1 on disk'
    $rtBack = Read-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -AttemptId $rt.AttemptId
    Assert-True 'S23 round-trip preserves schemaVersion' ($rtBack.SchemaVersion -eq 1) "got $($rtBack.SchemaVersion)"
    Assert-True 'S23 round-trip preserves identity and outcome fields' ($rtBack.AttemptId -eq $rt.AttemptId -and $rtBack.Result -eq 'SUCCESS' -and $rtBack.VerificationResult -eq 'VERIFIED') "mismatch"
    Assert-True 'S23 round-trip preserves usage fields' ($rtBack.InputTokens -eq 5000 -and $rtBack.OutputTokens -eq 1200 -and $rtBack.UsageSource -eq 'ACTUAL') "mismatch"
    Assert-True 'S23 round-trip preserves optional evidence nulls' ($null -eq $rtBack.GatewayProviderId -and $null -eq $rtBack.ContextTokens) "nulls not preserved"
    Assert-True 'S23 round-trip preserves verification link' ($rtBack.VerificationEvidencePath -match 'verification.json') "got '$($rtBack.VerificationEvidencePath)'"
    Assert-True 'S23 round-trip preserves ManualOverride default false' ($rtBack.ManualOverride -eq $false) "got '$($rtBack.ManualOverride)'"

    # --- scenario 24: duplicate AttemptId rejected --------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 24 - duplicate AttemptId rejected =="
    $dupThrown = $false
    try {
        $null = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask -AttemptId 'ATT-CHG-20260901-001-001'
    } catch { $dupThrown = $true }
    Assert-True 'S24 explicit duplicate AttemptId rejected' $dupThrown "Start-AiAttempt must throw on duplicate AttemptId"
    $next = New-AiAttemptId -ChangeId $fixtureChange -ExistingAttemptIds @('ATT-CHG-20260901-001-999', 'ATT-CHG-20260901-001-999')
    Assert-True 'S24 numbering advances past existing ids' ($next -eq 'ATT-CHG-20260901-001-1000') "got '$next'"
    $attempt = Start-AiAttempt -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange -TaskId $fixtureTask -AttemptId $next
    Assert-True 'S24 generated id is accepted for a fresh attempt' ($attempt.AttemptId -eq $next) "got '$($attempt.AttemptId)'"

    # --- scenario 25: secret leakage rejected ---------------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 25 - secret leakage rejected =="
    $leaky = New-AiAttemptRecord -AttemptId 'LEAK-025' -ChangeId $fixtureChange -Result 'FAILED' -FailureCategory 'AUTHENTICATION' -Notes 'sk-abcdefghijklmnop123456'
    $leak = Test-AiAttemptSecretLeak $leaky
    Assert-True 'S25 secret-like value in Notes detected' $leak.Leak ($leak.Fields -join '; ')
    Assert-True 'S25 record carrying a secret value fails validation' (-not (Test-AiAttemptRecord $leaky).Valid) 'leaky record must be rejected'
    $leakEscalation = New-AiAttemptRecord -AttemptId 'LEAK-025B' -ChangeId $fixtureChange -Result 'FAILED' -FailureCategory 'AUTHENTICATION' -EscalationReason 'ghp_abcdefghijklmnopqrstuvwxyz123456'
    Assert-True 'S25 free-text escalation reason is scanned too' (Test-AiAttemptSecretLeak $leakEscalation).Leak 'escalation reason not scanned'
    $hashed = New-AiAttemptRecord -AttemptId 'HASH-025' -ChangeId $fixtureChange -Result 'SUCCESS' -StartedAtUtc '2026-08-30T00:00:00Z' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o') -PromptHash ('a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90') -ContextHash ('f0e1d2c3b4a59687786a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e')
    $hl = Test-AiAttemptSecretLeak $hashed
    Assert-True 'S25 legitimate prompt/context hashes are not flagged' (-not $hl.Leak) ($hl.Fields -join '; ')
    Assert-True 'S25 hashed record validates' (Test-AiAttemptRecord $hashed).Valid 'hash record rejected'
    $badHash = New-AiAttemptRecord -AttemptId 'HASH-025B' -ChangeId $fixtureChange -Result 'SUCCESS' -StartedAtUtc '2026-08-30T00:00:00Z' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o') -PromptHash 'not-a-real-hash'
    Assert-True 'S25 malformed prompt hash rejected' (-not (Test-AiAttemptRecord $badHash).Valid) 'bad hash must be rejected'

    # --- additional validation scenarios ---------------------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 26 - validation rules =="
    $badSelf = New-AiAttemptRecord -AttemptId 'SELF-026' -ChangeId $fixtureChange -EscalatedFromAttemptId 'SELF-026'
    Assert-True 'S26 EscalatedFrom self-reference rejected' (-not (Test-AiAttemptRecord $badSelf).Valid) 'self ref allowed'
    $badParent = New-AiAttemptRecord -AttemptId 'PAR-026' -ChangeId $fixtureChange -ParentAttemptId 'PAR-026'
    Assert-True 'S26 ParentAttemptId self-reference rejected' (-not (Test-AiAttemptRecord $badParent).Valid) 'parent self ref allowed'
    $badTiming = New-AiAttemptRecord -AttemptId 'TIME-026' -ChangeId $fixtureChange -StartedAtUtc '2026-08-30T12:00:00Z' -EndedAtUtc '2026-08-30T11:00:00Z'
    Assert-True 'S26 StartedAt after EndedAt rejected' (-not (Test-AiAttemptRecord $badTiming).Valid) 'timing accepted'
    $badNeg = New-AiAttemptRecord -AttemptId 'NEG-026' -ChangeId $fixtureChange -DurationMs -5
    Assert-True 'S26 negative DurationMs rejected' (-not (Test-AiAttemptRecord $badNeg).Valid) 'negative duration accepted'
    $badTok = New-AiAttemptRecord -AttemptId 'TOK-026' -ChangeId $fixtureChange -Result 'SUCCESS' -StartedAtUtc '2026-08-30T00:00:00Z' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o') -UsageSource 'ACTUAL' -InputTokens -10
    Assert-True 'S26 negative token count rejected' (-not (Test-AiAttemptRecord $badTok).Valid) 'negative tokens accepted'
    $badRetry = New-AiAttemptRecord -AttemptId 'RET-026' -ChangeId $fixtureChange -RetryNumber -1
    Assert-True 'S26 negative RetryNumber rejected' (-not (Test-AiAttemptRecord $badRetry).Valid) 'negative retry accepted'
    $contradictory = New-AiAttemptRecord -AttemptId 'SUCC-026' -ChangeId $fixtureChange -Result 'SUCCESS' -FailureCategory 'RATE_LIMIT' -StartedAtUtc '2026-08-30T00:00:00Z' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    Assert-True 'S26 SUCCESS with blocking failure category without evidence rejected' (-not (Test-AiAttemptRecord $contradictory).Valid) 'contradictory state accepted'
    $evidenced = New-AiAttemptRecord -AttemptId 'SUCC-026B' -ChangeId $fixtureChange -Result 'SUCCESS' -FailureCategory 'RATE_LIMIT' -StartedAtUtc '2026-08-30T00:00:00Z' -EndedAtUtc (Get-Date).ToUniversalTime().ToString('o') -ContradictoryStateEvidence 'rate limit observed once on a retried request but the final call succeeded'
    Assert-True 'S26 SUCCESS with blocking failure category plus explicit evidence accepted' (Test-AiAttemptRecord $evidenced).Valid 'evidence ignored'

    # --- scenario 27: state mirror / discovery ------------------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 27 - state discovery mirror =="
    $sp = Get-AiAttemptStateIndexPath -Root $script:TempRoot -ChangeId $fixtureChange
    Assert-True 'S27 state mirror index exists' (Test-Path $sp) "missing $sp"
    $sidx = Get-Content $sp -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True 'S27 state mirror schemaVersion 1 and has history path' ($sidx.SchemaVersion -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$sidx.HistoryPath)) "got $($sidx.SchemaVersion)"
    $chgCount = @(Get-AiAttemptsForChange -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $fixtureChange).Count
    Assert-True 'S27 state mirror records per-change attempt count' ($sidx.AttemptCount -eq $chgCount) "got mirror=$($sidx.AttemptCount) actual=$chgCount"

    # --- scenario 28: no-network / no-pricing / no-execution scan ---------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 28 - no network / no pricing / no execution scan =="
    $lib = Get-Content (Join-Path $PSScriptRoot 'AttemptStore.ps1') -Raw -Encoding UTF8
    $netPatterns = @('Invoke-RestMethod', 'Invoke-WebRequest', 'http://', 'https://', 'System.Net', 'HttpClient', 'api\.openai', 'api\.anthropic', 'api\.deepseek')
    $netHits = @($netPatterns | Where-Object { $lib -match $_ })
    Assert-True 'S28 attempt store library makes no network/provider calls' ($netHits.Count -eq 0) "suspicious tokens: $($netHits -join ',')"
    $pricingHits = @(@('Get-AiPrice', 'CostCalculator', 'ConvertTo-Currency', 'perToken', 'PricePerToken', 'price\s*\*', '\*\s*price') | Where-Object { $lib -match $_ })
    Assert-True 'S28 attempt store performs no pricing calculation' ($pricingHits.Count -eq 0) "pricing tokens: $($pricingHits -join ',')"

    # --- final aggregate sanity -------------------------------------------------------------------------------------
    Write-Output ""
    Write-Output "== Scenario 29 - aggregate foundation =="
    $allRecs = @(Get-AiAttemptsAll -Root $script:TempRoot)
    $agg = Get-AiAttemptAggregates -Records $allRecs
    Assert-True 'S29 aggregate total matches store count' ($agg.TotalAttempts -eq $allRecs.Count) "got $($agg.TotalAttempts)"
    Assert-True 'S29 aggregate ByModel populated' ($agg.ByModel['deepseek-v4-flash'] -ge 1) 'ByModel empty'
    Assert-True 'S29 aggregate ByResult has SUCCESS and FAILED' ($agg.ByResult['SUCCESS'] -ge 1 -and $agg.ByResult['FAILED'] -ge 1) 'ByResult missing states'
    Assert-True 'S29 aggregate first-attempt success counted' ($agg.FirstAttemptSuccessCount -ge 1) "got $($agg.FirstAttemptSuccessCount)"
    Assert-True 'S29 aggregate escalation count includes escalated chain' ($agg.EscalationCount -ge 1) "got $($agg.EscalationCount)"
    Assert-True 'S29 aggregate average duration is non-negative where sampled' ($null -eq $agg.AverageDurationMs -or $agg.AverageDurationMs -ge 0) "got '$($agg.AverageDurationMs)'"

    # --- scenario 30: state mirror for a second change (parallel safety of layout) --------------------------------
    Write-Output ""
    Write-Output "== Scenario 30 - per-change isolation =="
    $spB = Get-AiAttemptStateIndexPath -Root $script:TempRoot -ChangeId $changeB
    Assert-True 'S30 second change has its own state mirror' (Test-Path $spB) "missing $spB"
    $chgB = @(Get-AiAttemptsForChange -Root $script:TempRoot -NodeId $fixtureNode -ChangeId $changeB)
    Assert-True 'S30 changes do not bleed into each other' ($chgB.Count -eq 1) "changeB has $($chgB.Count) records"

} finally {
    if (Test-Path $script:TempRoot) {
        Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
    }
}

# --- summary --------------------------------------------------------------------------------------------------------
Write-Output ""
Write-Output ("PASSED: {0}" -f @($script:Results | Where-Object { $_.Pass }).Count)
Write-Output ("FAILED: {0}" -f @($script:Results | Where-Object { -not $_.Pass }).Count)
Write-Output "PAID API CALLS: 0"

if ($script:Fails.Count -gt 0) {
    Write-Output ""
    Write-Output "Failures:"
    foreach ($f in $script:Fails) { Write-Output "  - $f" }
    exit 1
}
exit 0

# AttemptPermission.ps1 -- DB-M21 combined attempt permission.
#
# Get-AiAttemptPermission combines the DB-M21 budget decision (Part A), the
# failure-fingerprint repeat decision (Part B) and the DB-M20 escalation
# recommendation into ONE structured outcome. It is a DECISION ONLY -- no model
# or provider is executed, no retry is started, no replan is executed.
# AUTO_EXECUTION_ENABLED = FALSE.
#
# Precedence (deterministic):
#   1. DB-M20 terminal / human / AUTO   -> REQUIRE_ESCALATION_REPLAN
#   2. known-failure suppression        -> BLOCK_KNOWN_FAILURE_REPEAT (identical
#                                          route repeat) else REQUIRE_ESCALATION_REPLAN
#   3. budget block                     -> BLOCK_BUDGET / REQUIRE_HUMAN_OVERRIDE
#   4. budget warning                   -> ALLOW_WITH_BUDGET_WARNING
#   5. else                             -> ALLOW_ATTEMPT
#
# A Git human gate (HUMAN_GIT_ACTION_REQUIRED / PR_PENDING / MERGE_PENDING) is
# NOT an AI failure and never budget-evaluates into a retry. A budget override
# (explicit human evidence) does NOT permit an identical repeat.

. (Join-Path $PSScriptRoot "FingerprintEngine.ps1")
. (Join-Path $PSScriptRoot "..\budget\BudgetEngine.ps1")   # DB-M21 Part A (READ-ONLY consume)

function Get-DbM21PermissionOutcomes {
    return @(
        'ALLOW_ATTEMPT', 'ALLOW_WITH_BUDGET_WARNING', 'BLOCK_BUDGET',
        'BLOCK_KNOWN_FAILURE_REPEAT', 'REQUIRE_HUMAN_OVERRIDE', 'REQUIRE_ESCALATION_REPLAN'
    )
}

function Get-DbM21PermissionReasonCodes {
    return @(
        'AUTO_EXECUTION_PROHIBITED', 'M20_TERMINAL_DECISION', 'M20_HUMAN_GATE',
        'KNOWN_FAILURE_SUPPRESSED', 'M20_IDENTICAL_ROUTE_REPEAT', 'M20_REPLAN_REQUIRED',
        'BUDGET_BLOCKED', 'BUDGET_OVERRIDE_GRANTED', 'BUDGET_WARNING', 'BUDGET_UNDER_LIMIT',
        'PURPOSE_NOT_AI_ATTEMPT', 'ALLOWED', 'NO_BUDGET_EVALUATION', 'NO_M20_DECISION',
        'BUDGET_REQUIRES_OVERRIDE'
    )
}

function Get-AiAttemptPermission {
    <#
    .SYNOPSIS
    The combined attempt permission: may the routing layer make the proposed AI
    attempt now? Combines the DB-M20 escalation decision, the known-failure
    repeat decision and the budget decision with deterministic precedence.
    Returns a decision record -- nothing is executed.
    #>
    param(
        [AllowNull()][pscustomobject]$BudgetEvaluation,
        [AllowNull()][object]$BudgetOverride,          # result of Test-AiBudgetOverride (explicit human evidence)
        [AllowNull()][object]$RepeatEvidence,          # result of Get-AiKnownFailureEvidence
        [AllowNull()][object]$RepeatAllowed,           # result of Test-AiRepeatAttemptAllowed
        [AllowNull()][pscustomobject]$EscalationDecision, # DB-M20 EscalationDecision v1 (read-only)
        [bool]$AutoExecutionEnabled = $false,
        [string]$Purpose = 'AI_ATTEMPT'
    )
    $reasons = New-Object System.Collections.ArrayList
    $outcome = $null

    # 0. non-AI purposes are not AI attempts -- never blocked by this gate
    if ($Purpose -ne 'AI_ATTEMPT') {
        return @{ Outcome = 'ALLOW_ATTEMPT'; ReasonCodes = @('PURPOSE_NOT_AI_ATTEMPT')
                  BudgetEvaluationId = $(if ($BudgetEvaluation) { Get-ContractProperty $BudgetEvaluation 'EvaluationId' $null } else { $null })
                  EscalationStatus = $(if ($EscalationDecision) { Get-ContractProperty $EscalationDecision 'Status' $null } else { $null })
                  AutoExecutionEnabled = $false
                  Message = "purpose '$Purpose' is not an AI attempt; it consumes no AI budget and is not a retry" }
    }

    # 1. AUTO execution is prohibited
    $m20Auto = if ($EscalationDecision) { [bool](Get-ContractProperty $EscalationDecision 'AutoExecutionEnabled' $false) } else { $false }
    if ($AutoExecutionEnabled -or $m20Auto) {
        return @{ Outcome = 'REQUIRE_ESCALATION_REPLAN'; ReasonCodes = @('AUTO_EXECUTION_PROHIBITED')
                  BudgetEvaluationId = $(if ($BudgetEvaluation) { Get-ContractProperty $BudgetEvaluation 'EvaluationId' $null } else { $null })
                  EscalationStatus = $(if ($EscalationDecision) { Get-ContractProperty $EscalationDecision 'Status' $null } else { $null })
                  AutoExecutionEnabled = $true
                  Message = 'automatic execution is prohibited; the routing layer must not execute an AI attempt on its own' }
    }

    # 2. DB-M20 terminal / human decisions -> replan, never a retry
    if ($EscalationDecision) {
        $status = [string](Get-ContractProperty $EscalationDecision 'Status' '')
        if ($status -and $status -ne 'RECOMMENDED') {
            $human = ($status -like 'HUMAN_*')
            $rc = if ($human) { @('M20_HUMAN_GATE', 'M20_TERMINAL_DECISION') } else { @('M20_TERMINAL_DECISION') }
            return @{ Outcome = 'REQUIRE_ESCALATION_REPLAN'; ReasonCodes = $rc
                      BudgetEvaluationId = $(if ($BudgetEvaluation) { Get-ContractProperty $BudgetEvaluation 'EvaluationId' $null } else { $null })
                      EscalationStatus = $status
                      AutoExecutionEnabled = $false
                      Message = "DB-M20 status '$status' is terminal/human; no AI attempt is recommended (a human Git gate is not an AI failure)" }
        }
    }

    # 3. known-failure suppression (checked BEFORE budget -- a budget override
    #    does NOT permit an identical repeat)
    if ($RepeatAllowed) {
        $allowed = [bool](Get-ContractProperty $RepeatAllowed 'Allowed' $true)
        $outcomeRc = [string](Get-ContractProperty $RepeatAllowed 'Outcome' '')
        if (-not $allowed) {
            $m20Action = if ($EscalationDecision) { [string](Get-ContractProperty $EscalationDecision 'Action' '') } else { '' }
            $retryActions = @('RETRY_SAME_ROUTE', 'RETRY_SAME_MODEL_HIGHER_REASONING', 'SWITCH_MODEL', 'SWITCH_PROVIDER_ROUTE')
            if ($m20Action -in $retryActions) {
                return @{ Outcome = 'BLOCK_KNOWN_FAILURE_REPEAT'; ReasonCodes = @('KNOWN_FAILURE_SUPPRESSED', 'M20_IDENTICAL_ROUTE_REPEAT')
                          BudgetEvaluationId = $(if ($BudgetEvaluation) { Get-ContractProperty $BudgetEvaluation 'EvaluationId' $null } else { $null })
                          EscalationStatus = $(if ($EscalationDecision) { Get-ContractProperty $EscalationDecision 'Status' $null } else { $null })
                          AutoExecutionEnabled = $false
                          Message = "identical repeat suppressed ($outcomeRc); DB-M20 was about to '$m20Action' -- blocked" }
            }
            return @{ Outcome = 'REQUIRE_ESCALATION_REPLAN'; ReasonCodes = @('KNOWN_FAILURE_SUPPRESSED', 'M20_REPLAN_REQUIRED')
                      BudgetEvaluationId = $(if ($BudgetEvaluation) { Get-ContractProperty $BudgetEvaluation 'EvaluationId' $null } else { $null })
                      EscalationStatus = $(if ($EscalationDecision) { Get-ContractProperty $EscalationDecision 'Status' $null } else { $null })
                      AutoExecutionEnabled = $false
                      Message = "identical repeat suppressed ($outcomeRc); a replan is required -- DB-M21 does not execute it" }
        }
    }

    # 4. budget decision
    $budgetOverrideGranted = ($null -ne $BudgetOverride -and [bool](Get-ContractProperty $BudgetOverride 'Granted' $false))
    if ($BudgetEvaluation -and -not $budgetOverrideGranted) {
        $dec = [string](Get-ContractProperty $BudgetEvaluation 'Decision' '')
        if ($dec -in @('BLOCK_BUDGET_EXCEEDED', 'BLOCK_COST_UNKNOWN')) {
            return @{ Outcome = 'BLOCK_BUDGET'; ReasonCodes = @('BUDGET_BLOCKED')
                      BudgetEvaluationId = Get-ContractProperty $BudgetEvaluation 'EvaluationId' $null
                      EscalationStatus = $(if ($EscalationDecision) { Get-ContractProperty $EscalationDecision 'Status' $null } else { $null })
                      AutoExecutionEnabled = $false
                      Message = "budget decision '$dec' blocks the attempt" }
        }
        if ($dec -eq 'REQUIRE_HUMAN_OVERRIDE') {
            return @{ Outcome = 'REQUIRE_HUMAN_OVERRIDE'; ReasonCodes = @('BUDGET_REQUIRES_OVERRIDE')
                      BudgetEvaluationId = Get-ContractProperty $BudgetEvaluation 'EvaluationId' $null
                      EscalationStatus = $(if ($EscalationDecision) { Get-ContractProperty $EscalationDecision 'Status' $null } else { $null })
                      AutoExecutionEnabled = $false
                      Message = 'budget requires an explicit human override before the attempt' }
        }
        if ($dec -eq 'ALLOW_WITH_WARNING') {
            $null = $reasons.Add('BUDGET_WARNING')
        } else {
            $null = $reasons.Add('BUDGET_UNDER_LIMIT')
        }
    } elseif ($budgetOverrideGranted) {
        $null = $reasons.Add('BUDGET_OVERRIDE_GRANTED')
    } else {
        $null = $reasons.Add('NO_BUDGET_EVALUATION')
    }

    # 5. allow
    $outcome = 'ALLOW_ATTEMPT'
    if ($reasons -contains 'BUDGET_WARNING') { $outcome = 'ALLOW_WITH_BUDGET_WARNING' }
    $null = $reasons.Add('ALLOWED')

    return @{ Outcome = $outcome; ReasonCodes = @($reasons)
              BudgetEvaluationId = $(if ($BudgetEvaluation) { Get-ContractProperty $BudgetEvaluation 'EvaluationId' $null } else { $null })
              EscalationStatus = $(if ($EscalationDecision) { Get-ContractProperty $EscalationDecision 'Status' $null } else { $null })
              AutoExecutionEnabled = $false
              Message = "combined permission: $outcome" }
}

# FailoverContracts.ps1 -- DB-M22 failover contracts + vocabularies.
#
# DB-M22 failover answers "if the current route is not usable, is there another
# eligible route that can be recommended?" It is a DECISION ONLY: no provider is
# invoked, no workflow is switched, no fallback is executed. AUTO_EXECUTION
# _ENABLED = FALSE. 0 paid API calls, 0 network calls.
#
# Failover never bypasses DB-M19 hard eligibility and never bypasses DB-M21
# budget permission. A route REJECTED by the router is never re-admitted.

. (Join-Path $PSScriptRoot "..\provider-health\ProviderHealthContracts.ps1")  # health contracts (READ-ONLY)

function Get-DbM22FailoverActions {
    <#
    .SYNOPSIS
    Structured failover action vocabulary -- never free text.
    #>
    return @(
        'USE_CURRENT_ROUTE', 'SWITCH_ROUTE', 'WAIT_RETRY_AFTER', 'WAIT_COOLDOWN',
        'NO_HEALTHY_ROUTE', 'HUMAN_PROVIDER_CONFIGURATION_REQUIRED',
        'HUMAN_PROVIDER_DECISION_REQUIRED', 'STOP_PROVIDER_UNAVAILABLE',
        'ROUTING_REPLAN_REQUIRED'
    )
}

function Get-DbM22FailoverReasonCodes {
    <#
    .SYNOPSIS
    Closed reason-code vocabulary for ProviderFailoverDecision v1. This is the
    authoritative DB-M22 failover vocabulary (subset of the health codes plus the
    failover-specific codes).
    #>
    return @(
        'HEALTHY_ROUTE', 'ROUTE_UNHEALTHY', 'NO_HEALTHY_ALTERNATE', 'HEALTHY_ALTERNATE_FOUND',
        'ALTERNATE_REJECTED_BY_ROUTER', 'ALTERNATE_OVER_BUDGET', 'ALTERNATE_BUDGET_OK',
        'ALTERNATE_BUDGET_UNKNOWN', 'BUDGET_REQUIRES_OVERRIDE', 'KNOWN_FAILURE_SUPPRESSED',
        'REPEAT_PROHIBITED', 'RETRY_AFTER_PENDING', 'COOLDOWN_PENDING', 'COOLDOWN_ELAPSED',
        'AUTH_REQUIRES_HUMAN', 'AUTH_NEVER_MODEL_ESCALATES', 'PROVIDER_DISABLED',
        'UNKNOWN_HEALTH_LOW_RISK_ALLOWED', 'UNKNOWN_HEALTH_HIGH_RISK_DENIED',
        'MODEL_QUALITY_NOT_A_HEALTH_SIGNAL', 'TRANSPORT_OK_QUALITY_POOR',
        'HUMAN_GIT_GATE_NOT_PROVIDER_FAILURE', 'CLAUDE_REVIEW_GATE_PRESERVED',
        'GOVERNANCE_BLOCK_NOT_FAILOVER', 'DETERMINISTIC', 'MANUAL_MODE_PRESERVED',
        'ASSISTED_RECOMMENDATION', 'AUTO_EXECUTION_PROHIBITED', 'STALE_EVIDENCE',
        'EVIDENCE_FRESH', 'SECRET_REJECTED', 'HUMAN_OVERRIDE_GRANTED',
        'HUMAN_OVERRIDE_PROHIBITED', 'HUMAN_OVERRIDE_REASON_REQUIRED', 'NO_OVERRIDE_NEEDED',
        'CONFIGURATION_DISABLED', 'CIRCUIT_CLOSED', 'CIRCUIT_OPEN', 'CIRCUIT_HALF_OPEN',
        'FAILURE_THRESHOLD_REACHED', 'SUCCESS_RECOVERY_REACHED', 'DEGRADED_STATE',
        'HEALTH_UNKNOWN', 'UNDERLYING_MODEL_PRESERVED'
    )
}

# -----------------------------------------------------------------------------
# ProviderFailoverDecision v1
# -----------------------------------------------------------------------------
function New-ProviderFailoverDecision {
    <#
    .SYNOPSIS
    Build a normalized ProviderFailoverDecision v1 from a field table. Action
    must be in the failover action vocabulary; every decision carries
    AutoExecutionEnabled = FALSE.
    #>
    param([AllowNull()][hashtable]$Fields)
    $f = if ($null -eq $Fields) { @{} } else { $Fields }
    function F([string]$n, $d) { if ($f.ContainsKey($n)) { return $f[$n] }; return $d }

    $action = [string](F 'Action' '')
    if ($action -and $action -notin (Get-DbM22FailoverActions)) {
        throw "New-ProviderFailoverDecision: Action '$action' invalid"
    }
    $decisionId = [string](F 'DecisionId' '')
    if (-not $decisionId) { $decisionId = 'FD-' + (Get-DbM22Sha256Hex (Get-Random).ToString()).Substring(0, 8) }

    $decision = [pscustomobject]@{
        SchemaVersion                = 1
        DecisionId                   = $decisionId
        TaskId                       = [string](F 'TaskId' '')
        AttemptId                    = [string](F 'AttemptId' '')
        OriginalProviderId           = [string](F 'OriginalProviderId' '')
        OriginalModelId              = [string](F 'OriginalModelId' '')
        OriginalRouteId              = [string](F 'OriginalRouteId' '')
        OriginalHealthState          = [string](F 'OriginalHealthState' '')
        Action                       = $action
        RecommendedProviderId        = [string](F 'RecommendedProviderId' '')
        RecommendedModelId           = [string](F 'RecommendedModelId' '')
        RecommendedRouteId           = [string](F 'RecommendedRouteId' '')
        UnderlyingModelId            = [string](F 'UnderlyingModelId' '')
        HealthEvidenceReferences     = @(F 'HealthEvidenceReferences' @())
        RoutingEvidenceReference     = [string](F 'RoutingEvidenceReference' '')
        BudgetEvidenceReference      = [string](F 'BudgetEvidenceReference' '')
        EscalationEvidenceReference  = [string](F 'EscalationEvidenceReference' '')
        ReasonCodes                  = @(F 'ReasonCodes' @())
        RetryAfterUtc                = ConvertTo-DbM22Utc (F 'RetryAfterUtc' $null)
        RequiresHuman                = [bool](F 'RequiresHuman' $false)
        HumanActionType              = [string](F 'HumanActionType' 'NONE')
        PolicyId                     = [string](F 'PolicyId' '')
        GeneratedAtUtc               = ConvertTo-DbM22Utc (F 'GeneratedAtUtc' $null)
        Message                      = [string](F 'Message' '')
        AutoExecutionEnabled         = $false
    }
    return $decision
}

function Test-ProviderFailoverDecision {
    <#
    .SYNOPSIS
    Deterministic structural validation of a ProviderFailoverDecision v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Decision)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Decision) { return @{ Valid = $false; Errors = @('Decision is null'); Warnings = @() } }
    if ((Get-ContractProperty $Decision 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Decision 'DecisionId' '')) { $errors.Add('DecisionId is required') }
    $action = [string](Get-ContractProperty $Decision 'Action' '')
    if ($action -and $action -notin (Get-DbM22FailoverActions)) { $errors.Add("Action '$action' invalid") }
    $auto = Get-ContractProperty $Decision 'AutoExecutionEnabled' $true
    if ($auto -ne $false) { $errors.Add('AutoExecutionEnabled must be FALSE') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

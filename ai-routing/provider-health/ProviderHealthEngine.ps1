# ProviderHealthEngine.ps1 -- DB-M22 effective-health aggregation + circuit breaker.
#
# Turns recent ProviderHealthEvidence v1 records into a deterministic effective
# provider/route health state (DB-M14 vocabulary) and a circuit-breaker state
# (CLOSED / OPEN / HALF_OPEN). The evaluation timestamp is INJECTED -- freshness
# and cooldown windows are derived from it, never from the machine clock. No
# provider/model is executed; no network call; no paid call. AUTO_EXECUTION
# _ENABLED = FALSE.
#
# Provider health is NOT model quality. This engine only ever reports route
# availability; it never writes into a model's quality score.

. (Join-Path $PSScriptRoot "ProviderHealthContracts.ps1")   # DB-M14 + DB-M20 vocab (READ-ONLY)

function Get-DbM22EvidenceForRoute {
    <#
    .SYNOPSIS
    Select the evidence records that describe a route. Provider-level evidence
    (no gateway) applies to every route of that provider; route-specific evidence
    (with a matching GatewayProviderId) applies only to that route. When the
    caller asks for the provider-level aggregate (no gateway), route evidence is
    included.
    #>
    param(
        [AllowNull()][object[]]$Evidence,
        [string]$ProviderId,
        [string]$GatewayProviderId
    )
    $providerKey = $ProviderId.Trim().ToLowerInvariant()
    $gatewayKey = if ($GatewayProviderId) { $GatewayProviderId.Trim().ToLowerInvariant() } else { '' }
    $out = New-Object System.Collections.ArrayList
    foreach ($e in @($Evidence)) {
        if ($null -eq $e) { continue }
        $eProvider = [string](Get-ContractProperty $e 'ProviderId' '')
        if ($eProvider.Trim().ToLowerInvariant() -ne $providerKey) { continue }
        $eGateway = [string](Get-ContractProperty $e 'GatewayProviderId' '')
        if ($gatewayKey) {
            # asking for a specific route: route-specific evidence must match; provider-level evidence applies
            if ($eGateway -and $eGateway.Trim().ToLowerInvariant() -ne $gatewayKey) { continue }
        } else {
            # asking for the provider aggregate: everything for this provider applies
        }
        $null = $out.Add($e)
    }
    return @($out)
}

function Get-DbM22FreshSplit {
    <#
    .SYNOPSIS
    Split evidence into fresh vs stale against the policy freshness window and
    each record's ExpiresAtUtc. Returns @{ Fresh; Stale }.
    #>
    param(
        [AllowNull()][object[]]$Evidence,
        [AllowNull()][pscustomobject]$Policy,
        $TimestampUtc
    )
    $freshSecs = [int](Get-ContractProperty $Policy 'EvidenceFreshnessSeconds' 300)
    $ts = ConvertTo-DbM22Utc $TimestampUtc
    $fresh = New-Object System.Collections.ArrayList
    $stale = New-Object System.Collections.ArrayList
    foreach ($e in @($Evidence)) {
        $obs = ConvertTo-DbM22Utc (Get-ContractProperty $e 'ObservedAtUtc' $null)
        $exp = ConvertTo-DbM22Utc (Get-ContractProperty $e 'ExpiresAtUtc' $null)
        $isStale = $false
        if ($null -ne $obs -and (($ts - $obs).TotalSeconds) -gt $freshSecs) { $isStale = $true }
        if ($null -ne $exp -and $exp -lt $ts) { $isStale = $true }
        if ($isStale) { $null = $stale.Add($e) } else { $null = $fresh.Add($e) }
    }
    return @{ Fresh = @($fresh); Stale = @($stale) }
}

function Get-DbM22LastInstant {
    param([object[]]$Evidence)
    $latest = $null
    foreach ($e in @($Evidence)) {
        $t = ConvertTo-DbM22Utc (Get-ContractProperty $e 'ObservedAtUtc' $null)
        if ($null -ne $t -and ($null -eq $latest -or $t -gt $latest)) { $latest = $t }
    }
    return $latest
}

function Get-DbM22HealthAggregation {
    <#
    .SYNOPSIS
    Aggregate the fresh evidence for a route into a single effective health state
    (DB-M14 vocabulary). Priority: DISABLED(config) > AUTH_ERROR > RATE_LIMITED >
    UNAVAILABLE > DEGRADED > AVAILABLE. Returns a hashtable with HealthState,
    RetryAfterUtc, RequiresHuman, UnknownUsable, Reasons, Message, Fresh/Stale.
    #>
    param(
        [AllowNull()][object[]]$Evidence,
        [AllowNull()][pscustomobject]$Policy,
        $TimestampUtc,
        [string]$ProviderId,
        [string]$GatewayProviderId,
        [bool]$IsHighRisk = $true
    )
    if ($null -eq $Policy) { $Policy = Get-DefaultProviderHealthPolicy }
    $ts = ConvertTo-DbM22Utc $TimestampUtc
    $freshSecs = [int](Get-ContractProperty $Policy 'EvidenceFreshnessSeconds' 300)
    $failTh = [int](Get-ContractProperty $Policy 'FailureThreshold' 3)
    $succTh = [int](Get-ContractProperty $Policy 'SuccessRecoveryThreshold' 1)
    $rlCool = [int](Get-ContractProperty $Policy 'RateLimitCooldownSeconds' 60)
    $unCool = [int](Get-ContractProperty $Policy 'UnavailableCooldownSeconds' 300)
    $degTh = [int](Get-ContractProperty $Policy 'DegradedFailureThreshold' 1)
    $authHuman = [bool](Get-ContractProperty $Policy 'AuthErrorRequiresHuman' $true)
    $allowUnknown = [bool](Get-ContractProperty $Policy 'AllowUnknownProvider' $false)
    $reqConfirmed = [bool](Get-ContractProperty $Policy 'RequireConfirmedAvailableForHighRisk' $true)

    $route = Get-DbM22EvidenceForRoute -Evidence $Evidence -ProviderId $ProviderId -GatewayProviderId $GatewayProviderId
    $split = Get-DbM22FreshSplit -Evidence $route -Policy $Policy -TimestampUtc $ts
    $fresh = $split.Fresh
    $stale = $split.Stale

    # 1. DISABLED configuration always wins
    $disabledCfg = @($fresh + $stale | Where-Object {
        [string](Get-ContractProperty $_ 'ObservedState' '') -eq 'DISABLED' -and
        [string](Get-ContractProperty $_ 'EvidenceType' '') -eq 'CONFIGURATION'
    })
    if ($disabledCfg.Count -gt 0) {
        return @{ HealthState = 'DISABLED'; RetryAfterUtc = $null; RequiresHuman = $false; UnknownUsable = $false
                  Reasons = @('CONFIGURATION_DISABLED', 'PROVIDER_DISABLED'); Fresh = $fresh; Stale = $stale
                  Message = 'configuration marks this provider DISABLED; no health logic re-enables it' }
    }

    if ($fresh.Count -eq 0) {
        $usable = if ($IsHighRisk) { $allowUnknown -and (-not $reqConfirmed) } else { $true }
        $r = @('HEALTH_UNKNOWN')
        if ($stale.Count -gt 0) { $r += 'STALE_EVIDENCE' }
        return @{ HealthState = 'UNKNOWN'; RetryAfterUtc = $null; RequiresHuman = $false; UnknownUsable = $usable
                  Reasons = $r; Fresh = $fresh; Stale = $stale
                  Message = "no fresh evidence (stale=$($stale.Count)); health is UNKNOWN" }
    }

    $authFresh = @($fresh | Where-Object { [string](Get-ContractProperty $_ 'ObservedState' '') -eq 'AUTH_ERROR' })
    $rateFresh = @($fresh | Where-Object { [string](Get-ContractProperty $_ 'ObservedState' '') -eq 'RATE_LIMITED' })
    $unavailFresh = @($fresh | Where-Object { [string](Get-ContractProperty $_ 'ObservedState' '') -eq 'UNAVAILABLE' })
    $degradedFresh = @($fresh | Where-Object { [string](Get-ContractProperty $_ 'ObservedState' '') -eq 'DEGRADED' })
    $successFresh = @($fresh | Where-Object {
        [string](Get-ContractProperty $_ 'ObservedState' '') -eq 'AVAILABLE' -or
        [string](Get-ContractProperty $_ 'EvidenceType' '') -eq 'PASSIVE_SUCCESS'
    })

    # 2. AUTH_ERROR
    if ($authFresh.Count -gt 0) {
        $r = @('AUTH_REQUIRES_HUMAN', 'AUTH_NEVER_MODEL_ESCALATES')
        return @{ HealthState = 'AUTH_ERROR'; RetryAfterUtc = $null; RequiresHuman = $authHuman; UnknownUsable = $false
                  Reasons = $r; Fresh = $fresh; Stale = $stale
                  Message = "AUTH_ERROR (fresh=$($authFresh.Count)); $(if ($authHuman) { 'human provider configuration required' } else { 'recorded' })" }
    }

    # 3. RATE_LIMITED (holds while RetryAfter is future, or within the policy cooldown)
    $retryAfter = $null
    foreach ($r in $rateFresh) {
        $ra = ConvertTo-DbM22Utc (Get-ContractProperty $r 'RetryAfterUtc' $null)
        if ($null -ne $ra -and ($null -eq $retryAfter -or $ra -gt $retryAfter)) { $retryAfter = $ra }
    }
    $lastRate = Get-DbM22LastInstant $rateFresh
    $stillLimited = $false
    if ($null -ne $retryAfter -and $retryAfter -gt $ts) { $stillLimited = $true }
    elseif ($null -ne $lastRate -and (($ts - $lastRate).TotalSeconds) -le $rlCool) { $stillLimited = $true }
    if ($stillLimited) {
        $r = if ($null -ne $retryAfter -and $retryAfter -gt $ts) { @('RETRY_AFTER_PENDING') } else { @('COOLDOWN_PENDING') }
        return @{ HealthState = 'RATE_LIMITED'; RetryAfterUtc = $retryAfter; RequiresHuman = $false; UnknownUsable = $false
                  Reasons = $r; Fresh = $fresh; Stale = $stale
                  Message = "RATE_LIMITED; $(if ($null -ne $retryAfter -and $retryAfter -gt $ts) { 'retry-after pending' } else { 'cooldown pending' })" }
    }

    # 4. UNAVAILABLE (threshold reached, or within the cooldown of a failure)
    $lastUnavail = Get-DbM22LastInstant $unavailFresh
    if ($unavailFresh.Count -ge $failTh) {
        return @{ HealthState = 'UNAVAILABLE'; RetryAfterUtc = $null; RequiresHuman = $false; UnknownUsable = $false
                  Reasons = @('FAILURE_THRESHOLD_REACHED'); Fresh = $fresh; Stale = $stale
                  Message = "UNAVAILABLE (fresh failures=$($unavailFresh.Count) >= threshold=$failTh)" }
    }
    if ($unavailFresh.Count -gt 0 -and $null -ne $lastUnavail -and (($ts - $lastUnavail).TotalSeconds) -le $unCool) {
        return @{ HealthState = 'UNAVAILABLE'; RetryAfterUtc = $null; RequiresHuman = $false; UnknownUsable = $false
                  Reasons = @('COOLDOWN_PENDING'); Fresh = $fresh; Stale = $stale
                  Message = "UNAVAILABLE (within UnavailableCooldownSeconds of a failure)" }
    }

    # 5. DEGRADED
    if ($degradedFresh.Count -ge $degTh) {
        return @{ HealthState = 'DEGRADED'; RetryAfterUtc = $null; RequiresHuman = $false; UnknownUsable = $false
                  Reasons = @('DEGRADED_STATE'); Fresh = $fresh; Stale = $stale
                  Message = "DEGRADED (fresh degraded=$($degradedFresh.Count) >= threshold=$degTh)" }
    }

    # 6. AVAILABLE (success recovery reached, no blocking state)
    if ($successFresh.Count -ge $succTh) {
        return @{ HealthState = 'AVAILABLE'; RetryAfterUtc = $null; RequiresHuman = $false; UnknownUsable = $false
                  Reasons = @('SUCCESS_RECOVERY_REACHED'); Fresh = $fresh; Stale = $stale
                  Message = "AVAILABLE (fresh successes=$($successFresh.Count) >= recovery=$succTh)" }
    }

    # fallback: fresh but indecisive
    $usable = if ($IsHighRisk) { $allowUnknown -and (-not $reqConfirmed) } else { $true }
    return @{ HealthState = 'UNKNOWN'; RetryAfterUtc = $null; RequiresHuman = $false; UnknownUsable = $usable
              Reasons = @('HEALTH_UNKNOWN'); Fresh = $fresh; Stale = $stale
              Message = 'fresh evidence exists but is not decisive; health is UNKNOWN' }
}

# -----------------------------------------------------------------------------
# Effective health + circuit state
# -----------------------------------------------------------------------------
function Get-EffectiveProviderHealth {
    <#
    .SYNOPSIS
    The public health view of a route: effective health state (DB-M14) + circuit
    state (CLOSED/OPEN/HALF_OPEN) + availability. Deterministic: pure function of
    (evidence, policy, injected timestamp, route identity).
    #>
    param(
        [AllowNull()][object[]]$Evidence,
        [AllowNull()][pscustomobject]$Policy,
        $EvaluationTimestampUtc,
        [string]$ProviderId,
        [string]$GatewayProviderId,
        [bool]$IsHighRisk = $true
    )
    if ($null -eq $Policy) { $Policy = Get-DefaultProviderHealthPolicy }
    $pv = Test-ProviderHealthPolicy $Policy
    if (-not $pv.Valid) { throw ("Get-EffectiveProviderHealth: invalid policy: " + ($pv.Errors -join '; ')) }
    if (-not (Get-ContractProperty $Policy 'Enabled' $true)) { throw "Get-EffectiveProviderHealth: policy '$((Get-ContractProperty $Policy 'PolicyId' ''))' is disabled" }
    if (-not $ProviderId) { throw "Get-EffectiveProviderHealth: ProviderId is required" }

    $ts = ConvertTo-DbM22Utc $EvaluationTimestampUtc
    if ($null -eq $ts) { throw "Get-EffectiveProviderHealth: EvaluationTimestampUtc is required" }

    $agg = Get-DbM22HealthAggregation -Evidence $Evidence -Policy $Policy -TimestampUtc $ts `
        -ProviderId $ProviderId -GatewayProviderId $GatewayProviderId -IsHighRisk $IsHighRisk
    $circuit = Get-DbM22CircuitForAggregation -Aggregation $agg -Policy $Policy -TimestampUtc $ts `
        -ProviderId $ProviderId -GatewayProviderId $GatewayProviderId

    $providerKey = $ProviderId.Trim().ToLowerInvariant()
    $gatewayKey = if ($GatewayProviderId) { $GatewayProviderId.Trim().ToLowerInvariant() } else { '' }
    $allRouteEvidence = Get-DbM22EvidenceForRoute -Evidence $Evidence -ProviderId $providerKey -GatewayProviderId $gatewayKey

    return [pscustomobject]@{
        SchemaVersion          = 1
        ProviderId             = $providerKey
        GatewayProviderId      = $gatewayKey
        RouteId                = Get-DbM22RouteKey -ProviderId $providerKey -GatewayProviderId $gatewayKey
        HealthState            = $agg.HealthState
        CircuitState           = $circuit.CircuitState
        ReasonCodes            = @($agg.Reasons)
        RetryAfterUtc          = ConvertTo-DbM22Utc $agg.RetryAfterUtc
        RequiresHuman          = [bool]$agg.RequiresHuman
        UnknownUsable          = [bool]$agg.UnknownUsable
        FreshEvidenceCount     = @($agg.Fresh).Count
        StaleEvidenceCount     = @($agg.Stale).Count
        EvidenceIds            = @($allRouteEvidence | ForEach-Object { Get-ContractProperty $_ 'EvidenceId' $null })
        PolicyId               = Get-ContractProperty $Policy 'PolicyId' $null
        EvaluationTimestampUtc = $ts
        Message                = $agg.Message
        AutoExecutionEnabled   = $false
    }
}

function Get-DbM22CircuitForAggregation {
    <#
    .SYNOPSIS
    Derive the circuit state from the effective health aggregation + evidence.
    Uses the same fresh/stale split so HALF_OPEN (cooldown elapsed while the
    failures are still fresh enough to count) is observable deterministically.
    #>
    param(
        [AllowNull()][object]$Aggregation,
        [AllowNull()][pscustomobject]$Policy,
        $TimestampUtc,
        [string]$ProviderId,
        [string]$GatewayProviderId
    )
    $ts = ConvertTo-DbM22Utc $TimestampUtc
    $failTh = [int](Get-ContractProperty $Policy 'FailureThreshold' 3)
    $succTh = [int](Get-ContractProperty $Policy 'SuccessRecoveryThreshold' 1)
    $circDur = [int](Get-ContractProperty $Policy 'CircuitOpenDurationSeconds' 300)

    $fresh = @($Aggregation.Fresh)
    $stale = @($Aggregation.Stale)
    $all = @($fresh + $stale)

    $failures = @($fresh | Where-Object { [string](Get-ContractProperty $_ 'ObservedState' '') -in @('UNAVAILABLE','AUTH_ERROR','RATE_LIMITED') })
    $successes = @($fresh | Where-Object {
        [string](Get-ContractProperty $_ 'ObservedState' '') -eq 'AVAILABLE' -or
        [string](Get-ContractProperty $_ 'EvidenceType' '') -eq 'PASSIVE_SUCCESS'
    })
    $lastFail = Get-DbM22LastInstant $failures

    if ($failures.Count -ge $failTh) {
        if ($null -ne $lastFail -and (($ts - $lastFail).TotalSeconds) -ge $circDur) {
            return [pscustomobject]@{ CircuitState = 'HALF_OPEN'; ReasonCodes = @('COOLDOWN_ELAPSED'); Message = 'failures reached threshold and cooldown elapsed; HALF_OPEN (probe eligibility)' }
        }
        return [pscustomobject]@{ CircuitState = 'OPEN'; ReasonCodes = @('FAILURE_THRESHOLD_REACHED'); Message = 'failures reached threshold; OPEN (route suppressed)' }
    }
    if ($successes.Count -ge $succTh) {
        return [pscustomobject]@{ CircuitState = 'CLOSED'; ReasonCodes = @('SUCCESS_RECOVERY_REACHED'); Message = 'success recovery reached; CLOSED' }
    }
    if ($Aggregation.HealthState -in @('DISABLED','AUTH_ERROR','RATE_LIMITED','UNAVAILABLE')) {
        # a current blocking state with failures below the open threshold keeps the
        # circuit closed-but-unavailable semantics: report OPEN when suppressed
        if ($failures.Count -gt 0) {
            return [pscustomobject]@{ CircuitState = 'OPEN'; ReasonCodes = @('FAILURE_THRESHOLD_REACHED'); Message = 'current blocking health state; circuit OPEN' }
        }
        return [pscustomobject]@{ CircuitState = 'CLOSED'; ReasonCodes = @('CIRCUIT_CLOSED'); Message = 'no failure threshold breach; circuit CLOSED' }
    }
    return [pscustomobject]@{ CircuitState = 'CLOSED'; ReasonCodes = @('CIRCUIT_CLOSED'); Message = 'no failure threshold breach; circuit CLOSED' }
}

# -----------------------------------------------------------------------------
# Route availability test
# -----------------------------------------------------------------------------
function Test-ProviderRouteAvailable {
    <#
    .SYNOPSIS
    Deterministic yes/no on whether a route is currently usable. A route is
    unavailable when its effective health is DISABLED / UNAVAILABLE / AUTH_ERROR /
    RATE_LIMITED, or its circuit is OPEN. UNKNOWN health is usable only when the
    policy allows (AllowUnknownProvider) or the work is low-risk.
    #>
    param(
        [AllowNull()][object[]]$Evidence,
        [AllowNull()][pscustomobject]$Policy,
        $EvaluationTimestampUtc,
        [string]$ProviderId,
        [string]$GatewayProviderId,
        [bool]$IsHighRisk = $true
    )
    $h = Get-EffectiveProviderHealth -Evidence $Evidence -Policy $Policy -EvaluationTimestampUtc $EvaluationTimestampUtc `
        -ProviderId $ProviderId -GatewayProviderId $GatewayProviderId -IsHighRisk $IsHighRisk
    $state = [string]$h.HealthState
    $circuit = [string]$h.CircuitState
    if ($circuit -eq 'OPEN') {
        return @{ Available = $false; HealthState = $state; CircuitState = $circuit; Reasons = @($h.ReasonCodes); Message = "circuit OPEN; route suppressed ($($h.Message))" }
    }
    if ($state -in @('DISABLED', 'UNAVAILABLE', 'AUTH_ERROR', 'RATE_LIMITED')) {
        return @{ Available = $false; HealthState = $state; CircuitState = $circuit; Reasons = @($h.ReasonCodes); Message = $h.Message }
    }
    if ($state -eq 'UNKNOWN') {
        if (-not [bool]$h.UnknownUsable) {
            return @{ Available = $false; HealthState = $state; CircuitState = $circuit; Reasons = @('HEALTH_UNKNOWN'); Message = 'UNKNOWN health is not usable under this policy' }
        }
        return @{ Available = $true; HealthState = $state; CircuitState = $circuit; Reasons = @('HEALTH_UNKNOWN'); Message = 'UNKNOWN health usable (policy allows low-risk/manual work)' }
    }
    return @{ Available = $true; HealthState = $state; CircuitState = $circuit; Reasons = @($h.ReasonCodes); Message = $h.Message }
}

# -----------------------------------------------------------------------------
# Circuit breaker public ops
# -----------------------------------------------------------------------------
function Get-ProviderCircuitState {
    <#
    .SYNOPSIS
    The current circuit state for a route (CLOSED / OPEN / HALF_OPEN) derived
    deterministically from evidence + policy + injected timestamp.
    #>
    param(
        [AllowNull()][object[]]$Evidence,
        [AllowNull()][pscustomobject]$Policy,
        $EvaluationTimestampUtc,
        [string]$ProviderId,
        [string]$GatewayProviderId
    )
    $h = Get-EffectiveProviderHealth -Evidence $Evidence -Policy $Policy -EvaluationTimestampUtc $EvaluationTimestampUtc `
        -ProviderId $ProviderId -GatewayProviderId $GatewayProviderId
    return [pscustomobject]@{
        CircuitState       = $h.CircuitState
        HealthState        = $h.HealthState
        RouteId            = $h.RouteId
        ReasonCodes        = @($h.ReasonCodes)
        EvaluationTimestampUtc = $h.EvaluationTimestampUtc
        Message            = $h.Message
    }
}

function Update-ProviderCircuitState {
    <#
    .SYNOPSIS
    The pure next-state transition: "if this new evidence lands, what does the
    circuit become?" Deterministic. Used to reason about whether a route may be
    probed/retried. This is a DECISION -- no probe is executed.
    #>
    param(
        [string]$CurrentState,
        [AllowNull()][pscustomobject]$NewEvidence,
        [AllowNull()][pscustomobject]$Policy,
        $EvaluationTimestampUtc
    )
    if ($CurrentState -notin (Get-DbM22CircuitStates)) { throw "Update-ProviderCircuitState: CurrentState '$CurrentState' invalid" }
    if ($null -eq $Policy) { $Policy = Get-DefaultProviderHealthPolicy }
    if ($null -eq $NewEvidence) {
        return [pscustomobject]@{ NextState = $CurrentState; Transition = 'NO_EVIDENCE'; Message = 'no new evidence; no change' }
    }

    $state = [string](Get-ContractProperty $NewEvidence 'ObservedState' '')
    $etype = [string](Get-ContractProperty $NewEvidence 'EvidenceType' '')
    $isFailure = ($state -in @('UNAVAILABLE', 'RATE_LIMITED', 'AUTH_ERROR'))
    $isSuccess = ($state -eq 'AVAILABLE' -or $etype -eq 'PASSIVE_SUCCESS')

    switch ($CurrentState) {
        'CLOSED' {
            if ($isFailure) {
                return [pscustomobject]@{ NextState = 'OPEN'; Transition = 'FAILURE_OPENS'; Message = 'a provider failure opens the circuit (closed -> open)' }
            }
            return [pscustomobject]@{ NextState = 'CLOSED'; Transition = 'STAY_CLOSED'; Message = 'no failure; stays closed' }
        }
        'OPEN' {
            if ($isSuccess) {
                return [pscustomobject]@{ NextState = 'CLOSED'; Transition = 'SUCCESS_CLOSES'; Message = 'positive evidence closes the circuit (open -> closed)' }
            }
            return [pscustomobject]@{ NextState = 'OPEN'; Transition = 'STAY_OPEN'; Message = 'no success evidence; stays open (cooldown governs probe eligibility)' }
        }
        'HALF_OPEN' {
            if ($isFailure) {
                return [pscustomobject]@{ NextState = 'OPEN'; Transition = 'HALF_OPEN_FAILURE'; Message = 'a failure while half-open re-opens the circuit (half-open -> open)' }
            }
            if ($isSuccess) {
                return [pscustomobject]@{ NextState = 'CLOSED'; Transition = 'HALF_OPEN_SUCCESS'; Message = 'positive evidence closes the circuit (half-open -> closed)' }
            }
            return [pscustomobject]@{ NextState = 'HALF_OPEN'; Transition = 'STAY_HALF_OPEN'; Message = 'no decisive evidence; stays half-open' }
        }
    }
    return [pscustomobject]@{ NextState = $CurrentState; Transition = 'NO_CHANGE'; Message = 'no change' }
}

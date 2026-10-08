# ProviderHealthContracts.ps1 -- DB-M22 provider-health contracts + vocabularies.
#
# DB-M22 is a DETERMINISTIC PROVIDER-HEALTH / ROUTE-FAILOVER FOUNDATION. It
# answers "is this configured route currently suitable?" and "if not, is there
# another eligible route that can be recommended?". It NEVER executes a provider
# or model, makes no paid API call and no network call. AUTO_EXECUTION_ENABLED
# = FALSE. Recommendation/decision only.
#
# ProviderHealthEvidence v1 + ProviderHealthPolicy v1 are DB-M22-owned schemas.
# Health states reuse the DB-M14 vocabulary (AVAILABLE / RATE_LIMITED / DEGRADED
# / AUTH_ERROR / UNAVAILABLE / DISABLED / UNKNOWN) -- no invented aliases.
# Provider health is NOT model quality; this module never writes into a model's
# quality score.
#
# ADR-005: identifiers are data. No business logic branches on a provider/model
# name.

. (Join-Path $PSScriptRoot "..\AiRoutingContracts.ps1")        # DB-M14 vocab + helpers (READ-ONLY)
. (Join-Path $PSScriptRoot "..\escalation\EscalationPolicy.ps1") # DB-M20 category vocab (READ-ONLY)

# -----------------------------------------------------------------------------
# UTC normalization (DB-M22-owned copy of the house pattern)
# -----------------------------------------------------------------------------
function ConvertTo-DbM22Utc {
    <#
    .SYNOPSIS
    Normalize a datetime (object or string) to Kind=Utc so comparisons are
    INSTANT-based, never wall-clock. A string WITHOUT a zone designator is
    assumed to denote a UTC clock time; a string WITH Z (or offset) is converted
    to the equivalent UTC instant. Null returns null.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Utc) { return $dt }
        if ($dt.Kind -eq [System.DateTimeKind]::Local) { return $dt.ToUniversalTime() }
        return [System.DateTime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
    }
    $s = [string]$Value
    if ($s.Trim() -eq '') { return $null }
    return [System.DateTime]::Parse(
        $s,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}

# -----------------------------------------------------------------------------
# SHA-256 house pattern
# -----------------------------------------------------------------------------
function Get-DbM22Sha256Hex {
    <#
    .SYNOPSIS
    SHA-256 of a string as lowercase hex (same house pattern as DB-M18/DB-M21).
    #>
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
    }
}

# -----------------------------------------------------------------------------
# Schema versions (DB-M22-owned)
# -----------------------------------------------------------------------------
function Get-DbM22SchemaVersions {
    return [pscustomobject]@{
        ProviderHealthEvidenceVersion = 1
        ProviderHealthPolicyVersion   = 1
        ProviderFailoverDecisionVersion = 1
    }
}

# -----------------------------------------------------------------------------
# Vocabularies
# -----------------------------------------------------------------------------
function Get-DbM22HealthSources {
    <#
    .SYNOPSIS
    Where health evidence comes from. DB-M22 prefers deterministic/offline
    fixtures; no real paid provider is invoked.
    #>
    return @('CONFIGURATION', 'RECENT_ATTEMPT', 'PASSIVE_FAILURE', 'PASSIVE_SUCCESS',
             'MANUAL_OPERATOR_STATUS', 'SYNTHETIC_TEST', 'FUTURE_HEALTH_PROBE')
}

function Get-DbM22CircuitStates {
    <#
    .SYNOPSIS
    Deterministic circuit-breaker states: CLOSED = usable; OPEN = suppressed
    (recent provider failures reached the threshold); HALF_OPEN = limited/probe
    eligibility when the cooldown expires. No uncontrolled network probing.
    #>
    return @('CLOSED', 'OPEN', 'HALF_OPEN')
}

function Get-DbM22ManualOverrideOutcomes {
    return @('OVERRIDE_GRANTED', 'OVERRIDE_PROHIBITED', 'OVERRIDE_REASON_REQUIRED', 'NO_OVERRIDE_NEEDED')
}

function Get-DbM22HealthReasonCodes {
    <#
    .SYNOPSIS
    Closed reason-code vocabulary for DB-M22 health/failover evidence.
    Vocabulary members, never free text.
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
        'HEALTH_UNKNOWN'
    )
}

# -----------------------------------------------------------------------------
# Secret protection (DB-M22-owned guard)
# -----------------------------------------------------------------------------
function Test-DbM22SecretLeak {
    <#
    .SYNOPSIS
    Scan a ProviderHealthEvidence v1 (or any object) for secret-like VALUES.
    Field names that are references/identifiers by design are exempt
    (EvidenceId, ProviderId, RouteId, UnderlyingModelId, GatewayProviderId,
    Source, AttemptIdReference, Notes, ReasonCodes). Returns @{ Leak; Fields }.
    #>
    param(
        [AllowNull()][object]$Target
    )
    $exempt = @(
        'SchemaVersion', 'EvidenceId', 'ProviderId', 'RouteId', 'UnderlyingModelId',
        'GatewayProviderId', 'Source', 'AttemptIdReference', 'ReasonCodes',
        'EvidenceType', 'FailureCategory', 'HttpStatusClass', 'ObservedState',
        'Confidence', 'PolicyId', 'Name', 'PolicyVersion', 'DecisionId',
        'OriginalProviderId', 'OriginalModelId', 'OriginalRouteId',
        'RecommendedProviderId', 'RecommendedModelId', 'RecommendedRouteId',
        'OriginalHealthState', 'Action', 'HumanActionType', 'RoutingEvidenceReference',
        'BudgetEvidenceReference', 'EscalationEvidenceReference', 'TaskId', 'AttemptId'
    )
    # Notes is intentionally NOT exempt: it is free text, and a secret-like value
    # (API key, credential assignment) in Notes is rejected like any other stored
    # field. "Do not store secrets."
    $patterns = @(
        '^sk-[A-Za-z0-9_-]{8,}$',                 # OpenAI-style
        '^AIza[0-9A-Za-z_-]{10,}$',               # Google-style
        '^gh[pousr]_[A-Za-z0-9]{20,}$',           # GitHub tokens
        '^[A-Za-z0-9+/=_\-]{32,}$',               # generic high-entropy token
        '^-----BEGIN'                             # PEM block
    )
    $leaks = New-Object System.Collections.Generic.List[string]

    function Test-LeakValue([string]$fieldName, [object]$value) {
        if ($null -eq $value) { return }
        if ($fieldName -in $exempt) { return }
        $s = [string]$value
        if ($s.Length -lt 8) { return }
        foreach ($p in $patterns) {
            if ($s -match $p) {
                $leaks.Add("$fieldName = <redacted> matches $p")
                return
            }
        }
        if ($s -match '(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*\S') {
            $leaks.Add("$fieldName contains inline credential assignment")
        }
    }

    function Test-LeakObject([string]$path, [object]$obj) {
        if ($null -eq $obj) { return }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($k in $obj.Keys) {
                $v = $obj[$k]
                $name = if ($path) { "$path.$k" } else { [string]$k }
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) {
                    Test-LeakObject $name $v
                } elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) {
                        if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-LeakObject $name $item }
                        else { Test-LeakValue ([string]$k) $item }
                    }
                } else {
                    Test-LeakValue ([string]$k) $v
                }
            }
            return
        }
        if ($obj -is [PSCustomObject]) {
            foreach ($prop in $obj.PSObject.Properties) {
                $name = if ($path) { "$path.$($prop.Name)" } else { $prop.Name }
                $v = $prop.Value
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) {
                    Test-LeakObject $name $v
                } elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) {
                        if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-LeakObject $name $item }
                        else { Test-LeakValue $prop.Name $item }
                    }
                } else {
                    Test-LeakValue $prop.Name $v
                }
            }
            return
        }
        Test-LeakValue 'value' $obj
    }

    Test-LeakObject '' $Target
    return @{ Leak = ($leaks.Count -gt 0); Fields = @($leaks) }
}

# -----------------------------------------------------------------------------
# Route key (deterministic route identity)
# -----------------------------------------------------------------------------
function Get-DbM22RouteKey {
    <#
    .SYNOPSIS
    Deterministic route identity key. Provider-level health is keyed by
    lowercased ProviderId (the same key DB-M19's ProviderHealth dictionary uses);
    route-specific health additionally carries the GatewayProviderId. A route key
    is a string; never an opaque object.
    #>
    param(
        [string]$ProviderId,
        [string]$GatewayProviderId
    )
    $p = ($ProviderId.Trim().ToLowerInvariant())
    if ($GatewayProviderId) { return ($p + '|' + $GatewayProviderId.Trim().ToLowerInvariant()) }
    return $p
}

# -----------------------------------------------------------------------------
# ProviderHealthEvidence v1
# -----------------------------------------------------------------------------
function New-ProviderHealthEvidence {
    <#
    .SYNOPSIS
    Build a normalized ProviderHealthEvidence v1 from a field table. ObservedState
    must be a DB-M14 health state; EvidenceType must be a DB-M22 health source.
    A secret-like value in a stored field rejects the evidence. Route identity is
    derived from ProviderId / GatewayProviderId / UnderlyingModelId.
    #>
    param(
        [AllowNull()][hashtable]$Fields
    )
    $f = if ($null -eq $Fields) { @{} } else { $Fields }
    function F([string]$n, $d) { if ($f.ContainsKey($n)) { return $f[$n] }; return $d }

    $providerId = [string](F 'ProviderId' '')
    if (-not $providerId) { throw "New-ProviderHealthEvidence: ProviderId is required" }
    $providerId = $providerId.Trim().ToLowerInvariant()

    $gateway = [string](F 'GatewayProviderId' '')
    if ($gateway) { $gateway = $gateway.Trim().ToLowerInvariant() }
    $underlying = [string](F 'UnderlyingModelId' '')
    if ($underlying) { $underlying = $underlying.Trim().ToLowerInvariant() }

    $state = [string](F 'ObservedState' '')
    if (-not (Test-IsValidHealthState $state)) { throw "New-ProviderHealthEvidence: ObservedState '$state' invalid (must be a DB-M14 health state)" }

    $etype = [string](F 'EvidenceType' '')
    if ($etype -and $etype -notin (Get-DbM22HealthSources)) { throw "New-ProviderHealthEvidence: EvidenceType '$etype' invalid" }
    if (-not $etype) { $etype = 'RECENT_ATTEMPT' }

    $failureCat = [string](F 'FailureCategory' '')
    if ($failureCat -and -not (Test-IsValidDbM20FailureCategory $failureCat)) {
        throw "New-ProviderHealthEvidence: FailureCategory '$failureCat' invalid (must be a DB-M20 failure category)"
    }

    $observedAt = ConvertTo-DbM22Utc (F 'ObservedAtUtc' $null)
    if ($null -eq $observedAt) { throw "New-ProviderHealthEvidence: ObservedAtUtc is required" }

    $httpClass = [string](F 'HttpStatusClass' '')
    if ($httpClass -and $httpClass -notmatch '^(1|2|3|4|5)[0-9][0-9]|^[1-5]xx$') {
        throw "New-ProviderHealthEvidence: HttpStatusClass '$httpClass' invalid (expected like '429' or '5xx')"
    }

    $routeId = Get-DbM22RouteKey -ProviderId $providerId -GatewayProviderId $gateway
    $sigInput = "he|$providerId|$gateway|$state|$etype|$observedAt.ToString('o')"
    $evidenceId = 'HE-' + (Get-DbM22Sha256Hex $sigInput).Substring(0, 16)

    $evidence = [pscustomobject]@{
        SchemaVersion       = 1
        EvidenceId          = $evidenceId
        ProviderId          = $providerId
        RouteId             = $routeId
        UnderlyingModelId   = $underlying
        GatewayProviderId   = $gateway
        ObservedState       = $state
        EvidenceType        = $etype
        ObservedAtUtc       = $observedAt
        ExpiresAtUtc        = ConvertTo-DbM22Utc (F 'ExpiresAtUtc' $null)
        FailureCategory     = $failureCat
        HttpStatusClass     = $httpClass
        RetryAfterUtc       = ConvertTo-DbM22Utc (F 'RetryAfterUtc' $null)
        LatencyMs           = F 'LatencyMs' $null
        Source              = [string](F 'Source' '')
        Confidence          = F 'Confidence' $null
        AttemptIdReference  = [string](F 'AttemptIdReference' '')
        Notes               = [string](F 'Notes' '')
        ReasonCodes         = @(F 'ReasonCodes' @())
    }

    $lv = Test-DbM22SecretLeak $evidence
    if ($lv.Leak) { throw ("New-ProviderHealthEvidence: secret-like value rejected: " + ($lv.Fields -join '; ')) }
    return $evidence
}

function Test-ProviderHealthEvidence {
    <#
    .SYNOPSIS
    Deterministic structural validation of a ProviderHealthEvidence v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Evidence)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Evidence) { return @{ Valid = $false; Errors = @('Evidence is null'); Warnings = @() } }
    if ((Get-ContractProperty $Evidence 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    $pid = [string](Get-ContractProperty $Evidence 'ProviderId' '')
    if (-not $pid) { $errors.Add('ProviderId is required') }
    $state = [string](Get-ContractProperty $Evidence 'ObservedState' '')
    if (-not (Test-IsValidHealthState $state)) { $errors.Add("ObservedState '$state' invalid") }
    $etype = [string](Get-ContractProperty $Evidence 'EvidenceType' '')
    if ($etype -and $etype -notin (Get-DbM22HealthSources)) { $errors.Add("EvidenceType '$etype' invalid") }
    if ($null -eq (ConvertTo-DbM22Utc (Get-ContractProperty $Evidence 'ObservedAtUtc' $null))) { $errors.Add('ObservedAtUtc is required') }
    $lv = Test-DbM22SecretLeak $Evidence
    if ($lv.Leak) { $errors.Add('secret-like value present: ' + ($lv.Fields -join '; ')) }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# -----------------------------------------------------------------------------
# ProviderHealthPolicy v1
# -----------------------------------------------------------------------------
function New-ProviderHealthPolicy {
    <#
    .SYNOPSIS
    Build a normalized ProviderHealthPolicy v1. Every threshold and switch is
    DATA read by the health engine -- no thresholds are hard-coded in engine
    logic. Nulls stay null (never invented numeric sentinels).
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$PolicyId,
        [string]$Name,
        [bool]$Enabled = $true,
        [Nullable[int]]$EvidenceFreshnessSeconds,
        [Nullable[int]]$FailureThreshold,
        [Nullable[int]]$SuccessRecoveryThreshold,
        [Nullable[int]]$RateLimitCooldownSeconds,
        [Nullable[int]]$UnavailableCooldownSeconds,
        [Nullable[bool]]$AuthErrorRequiresHuman,
        [Nullable[int]]$DegradedFailureThreshold,
        [Nullable[bool]]$AllowUnknownProvider,
        [Nullable[bool]]$RequireConfirmedAvailableForHighRisk,
        [Nullable[int]]$CircuitOpenDurationSeconds,
        [Nullable[bool]]$AllowManualOverride,
        [Nullable[bool]]$RequireReasonForOverride,
        [string]$Notes
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }

    $id = if ($InputObject) { & $g 'PolicyId' $PolicyId } else { $PolicyId }
    if (-not $id) { throw "New-ProviderHealthPolicy: PolicyId is required" }
    $id = $id.Trim()

    $name = if ($InputObject) { & $g 'Name' $Name } else { $Name }
    if (-not $name) { $name = $id }

    $enabled = if ($InputObject) { [bool](& $g 'Enabled' $Enabled) } else { $Enabled }

    function Norm-Int([object]$Raw, $Fallback) {
        if ($null -eq $Raw) { return $Fallback }
        return [int]$Raw
    }
    $fresh   = Norm-Int $(if ($InputObject) { & $g 'EvidenceFreshnessSeconds' $EvidenceFreshnessSeconds } else { $EvidenceFreshnessSeconds }) 300
    $failTh  = Norm-Int $(if ($InputObject) { & $g 'FailureThreshold' $FailureThreshold } else { $FailureThreshold }) 3
    $succTh  = Norm-Int $(if ($InputObject) { & $g 'SuccessRecoveryThreshold' $SuccessRecoveryThreshold } else { $SuccessRecoveryThreshold }) 1
    $rlCool  = Norm-Int $(if ($InputObject) { & $g 'RateLimitCooldownSeconds' $RateLimitCooldownSeconds } else { $RateLimitCooldownSeconds }) 60
    $unCool  = Norm-Int $(if ($InputObject) { & $g 'UnavailableCooldownSeconds' $UnavailableCooldownSeconds } else { $UnavailableCooldownSeconds }) 300
    $degTh   = Norm-Int $(if ($InputObject) { & $g 'DegradedFailureThreshold' $DegradedFailureThreshold } else { $DegradedFailureThreshold }) 1
    $circDur = Norm-Int $(if ($InputObject) { & $g 'CircuitOpenDurationSeconds' $CircuitOpenDurationSeconds } else { $CircuitOpenDurationSeconds }) 300

    # validation: thresholds/cooldowns must be positive; a failure threshold of 0
    # would open the circuit on the very first failure -- invalid configuration
    foreach ($pair in @(@('EvidenceFreshnessSeconds', $fresh), @('FailureThreshold', $failTh),
                        @('SuccessRecoveryThreshold', $succTh), @('RateLimitCooldownSeconds', $rlCool),
                        @('UnavailableCooldownSeconds', $unCool), @('DegradedFailureThreshold', $degTh),
                        @('CircuitOpenDurationSeconds', $circDur))) {
        if ($pair[1] -lt 1) { throw "New-ProviderHealthPolicy: $($pair[0]) must be >= 1 (found $($pair[1]))" }
    }
    if ($degTh -gt $failTh) { throw "New-ProviderHealthPolicy: DegradedFailureThreshold ($degTh) must be <= FailureThreshold ($failTh)" }

    $authHuman = if ($InputObject) { [bool](& $g 'AuthErrorRequiresHuman' $AuthErrorRequiresHuman) } else { $AuthErrorRequiresHuman }
    if ($null -eq $authHuman) { $authHuman = $true }
    $allowUnknown = if ($InputObject) { [bool](& $g 'AllowUnknownProvider' $AllowUnknownProvider) } else { $AllowUnknownProvider }
    if ($null -eq $allowUnknown) { $allowUnknown = $false }
    $reqConfirmed = if ($InputObject) { [bool](& $g 'RequireConfirmedAvailableForHighRisk' $RequireConfirmedAvailableForHighRisk) } else { $RequireConfirmedAvailableForHighRisk }
    if ($null -eq $reqConfirmed) { $reqConfirmed = $true }
    $allowOverride = if ($InputObject) { [bool](& $g 'AllowManualOverride' $AllowManualOverride) } else { $AllowManualOverride }
    if ($null -eq $allowOverride) { $allowOverride = $true }
    $requireReason = if ($InputObject) { [bool](& $g 'RequireReasonForOverride' $RequireReasonForOverride) } else { $RequireReasonForOverride }
    if ($null -eq $requireReason) { $requireReason = $true }

    $notes = if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }

    return [pscustomobject]@{
        SchemaVersion                    = 1
        PolicyId                         = $id
        Name                             = $name
        Enabled                          = $enabled
        EvidenceFreshnessSeconds         = $fresh
        FailureThreshold                 = $failTh
        SuccessRecoveryThreshold         = $succTh
        RateLimitCooldownSeconds         = $rlCool
        UnavailableCooldownSeconds       = $unCool
        AuthErrorRequiresHuman           = $authHuman
        DegradedFailureThreshold         = $degTh
        AllowUnknownProvider             = $allowUnknown
        RequireConfirmedAvailableForHighRisk = $reqConfirmed
        CircuitOpenDurationSeconds       = $circDur
        AllowManualOverride              = $allowOverride
        RequireReasonForOverride         = $requireReason
        Notes                            = $notes
    }
}

function Test-ProviderHealthPolicy {
    <#
    .SYNOPSIS
    Deterministic structural validation of a ProviderHealthPolicy v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Policy)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Policy) { return @{ Valid = $false; Errors = @('Policy is null'); Warnings = @() } }
    if ((Get-ContractProperty $Policy 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Policy 'PolicyId' '')) { $errors.Add('PolicyId is required') }
    foreach ($fn in @('EvidenceFreshnessSeconds','FailureThreshold','SuccessRecoveryThreshold',
                      'RateLimitCooldownSeconds','UnavailableCooldownSeconds',
                      'DegradedFailureThreshold','CircuitOpenDurationSeconds')) {
        $v = Get-ContractProperty $Policy $fn $null
        if ($null -ne $v -and $v -lt 1) { $errors.Add("$fn must be >= 1 (found $v)") }
    }
    $deg = Get-ContractProperty $Policy 'DegradedFailureThreshold' $null
    $fail = Get-ContractProperty $Policy 'FailureThreshold' $null
    if ($null -ne $deg -and $null -ne $fail -and $deg -gt $fail) { $errors.Add('DegradedFailureThreshold must be <= FailureThreshold') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# -----------------------------------------------------------------------------
# Default provider-health policy
# -----------------------------------------------------------------------------
function Get-DefaultProviderHealthPolicy {
    <#
    .SYNOPSIS
    The default DB-M22 health policy. Conservative by design: 300s freshness,
    circuit opens after 3 provider failures, AUTH_ERROR requires human action,
    UNKNOWN is not silently usable for high-risk work, manual override allowed
    with a required reason, circuit open 300s.
    #>
    return New-ProviderHealthPolicy -PolicyId 'provider-health-default-v1' -Name 'DEFAULT' -Enabled $true `
        -EvidenceFreshnessSeconds 300 -FailureThreshold 3 -SuccessRecoveryThreshold 1 `
        -RateLimitCooldownSeconds 60 -UnavailableCooldownSeconds 300 `
        -AuthErrorRequiresHuman $true -DegradedFailureThreshold 1 `
        -AllowUnknownProvider $false -RequireConfirmedAvailableForHighRisk $true `
        -CircuitOpenDurationSeconds 300 -AllowManualOverride $true -RequireReasonForOverride $true `
        -Notes 'DB-M22 default health policy. Conservative: 300s freshness; circuit opens after 3 provider failures; AUTH_ERROR requires human action; UNKNOWN not silently usable for high-risk work.'
}

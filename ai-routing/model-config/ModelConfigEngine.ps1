# ModelConfigEngine.ps1 -- DB-M28 Model Configuration UI engine.
#
# Builds the operator-facing MODEL CONFIGURATION view (10 read-mostly sections)
# and applies operator configuration changes to config\providers.json and
# config\models.json ONLY through a validated, atomic, audited persistence
# adapter. Every eligibility, pricing, health, capability and cost number is a
# READ-ONLY consumption of the existing DB-M14..M27 implementations; DB-M28
# never invents or duplicates a capability, a price, a health state or a cost
# formula.
#
# AUTO_EXECUTION_ENABLED = FALSE. Provider/model executed NO. Paid API calls 0.
# Network calls 0. No provider-connectivity test is implemented (none exists in
# any approved contract for DB-M28). No health/budget/pricing/routing policy is
# mutated. DB-M19 hard capability gates are never overridden by a config toggle.
# Secret VALUES are never rendered and never logged; only env-var NAMEs and
# CONFIGURED/NOT_CONFIGURED/INVALID_CONFIGURATION states appear.
#
# Backend contract: always exit 0; outcomes via DB28_* stdout markers only.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ModelConfigContracts.ps1')

# --- helpers ------------------------------------------------------------------------------

function ConvertTo-DbM28TriState {
    <#
    .SYNOPSIS
    Render a capability flag honestly: true -> YES, false -> NO, null -> UNKNOWN
    (not asserted). DB-M28 never invents a capability.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 'UNKNOWN' }
    if ($Value -is [bool]) { if ([bool]$Value) { return 'YES' } else { return 'NO' } }
    return 'UNKNOWN'
}

function ConvertTo-DbM28JsonString {
    param([string]$Value)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"') ; break }
            '\'  { [void]$sb.Append('\\') ; break }
            "`b" { [void]$sb.Append('\b') ; break }
            "`f" { [void]$sb.Append('\f') ; break }
            "`n" { [void]$sb.Append('\n') ; break }
            "`r" { [void]$sb.Append('\r') ; break }
            "`t" { [void]$sb.Append('\t') ; break }
            default {
                if ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:X4}' -f [int]$ch)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-DbM28Json {
    <#
    .SYNOPSIS
    Array-preserving, UTF-8-safe, deterministic JSON writer. Used ONLY for the
    validated config persistence adapter (providers.json / models.json) and the
    configuration-change audit file. Single-element arrays stay arrays (PS 5.1
    ConvertTo-Json would flatten them).
    #>
    param($Object, [int]$Depth = 0)
    $pad = '  ' * $Depth
    $pad1 = '  ' * ($Depth + 1)
    if ($null -eq $Object) { return 'null' }
    if ($Object -is [bool]) { return $(if ([bool]$Object) { 'true' } else { 'false' }) }
    if ($Object -is [string]) { return ConvertTo-DbM28JsonString $Object }
    if ($Object -is [datetime]) {
        return ConvertTo-DbM28JsonString ($Object.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Object -is [byte] -or $Object -is [int16] -or $Object -is [int32] -or $Object -is [int64] -or
        $Object -is [single] -or $Object -is [double] -or $Object -is [decimal]) {
        return ([System.IFormattable]$Object).ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Object -is [pscustomobject]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($p in $Object.PSObject.Properties) {
            $inner = ConvertTo-DbM28Json -Object $p.Value -Depth ($Depth + 1)
            $parts.Add(($pad1 + (ConvertTo-DbM28JsonString $p.Name) + ': ' + $inner))
        }
        if ($parts.Count -eq 0) { return '{}' }
        return "{`n" + ($parts -join ",`n") + "`n$pad}"
    }
    if ($Object -is [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($key in $Object.Keys) {
            $inner = ConvertTo-DbM28Json -Object $Object[$key] -Depth ($Depth + 1)
            $parts.Add(($pad1 + (ConvertTo-DbM28JsonString ([string]$key)) + ': ' + $inner))
        }
        if ($parts.Count -eq 0) { return '{}' }
        return "{`n" + ($parts -join ",`n") + "`n$pad}"
    }
    if ($Object -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Object) { $items.Add((ConvertTo-DbM28Json -Object $item -Depth ($Depth + 1))) }
        if ($items.Count -eq 0) { return '[]' }
        $padded = New-Object System.Collections.Generic.List[string]
        foreach ($it in $items) { $padded.Add(($pad1 + $it)) }
        return "[`n" + ($padded -join ",`n") + "`n$pad]"
    }
    return ConvertTo-DbM28JsonString ([string]$Object)
}

function Test-DbM28JsonEquivalent {
    <#
    .SYNOPSIS
    Deep, strict equality over two JSON-decoded object graphs. Used by the
    persistence adapter's read-back verification to prove the operator's field
    changed and NO unrelated field changed (no unrelated config rewrite).
    #>
    param($A, $B, [string]$Path = '$')
    if ($null -eq $A -and $null -eq $B) { return $true }
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A -is [bool] -or $B -is [bool]) { return ([bool]$A -eq [bool]$B) }
    if ($A -is [string] -or $B -is [string]) {
        if ($A -is [string] -and $B -is [string]) { return ([string]$A -ceq [string]$B) }
        return $false
    }
    if ($A -is [System.Collections.IDictionary] -or $A -is [pscustomobject]) {
        if (-not ($B -is [System.Collections.IDictionary] -or $B -is [pscustomobject])) { return $false }
        $keysA = @()
        if ($A -is [pscustomobject]) { foreach ($p in $A.PSObject.Properties) { $keysA += [string]$p.Name } }
        else { foreach ($k in $A.Keys) { $keysA += [string]$k } }
        $keysB = @()
        if ($B -is [pscustomobject]) { foreach ($p in $B.PSObject.Properties) { $keysB += [string]$p.Name } }
        else { foreach ($k in $B.Keys) { $keysB += [string]$k } }
        if ($keysA.Count -ne $keysB.Count) { return $false }
        foreach ($ka in $keysA) {
            $found = $false
            foreach ($kb in $keysB) { if ($ka -ceq $kb) { $found = $true; break } }
            if (-not $found) { return $false }
        }
        foreach ($k in $keysA) {
            $va = if ($A -is [pscustomobject]) { $A.($k) } else { $A[$k] }
            $vb = if ($B -is [pscustomobject]) { $B.($k) } else { $B[$k] }
            if (-not (Test-DbM28JsonEquivalent -A $va -B $vb -Path ($Path + '.' + $k))) { return $false }
        }
        return $true
    }
    if ($A -is [System.Collections.IEnumerable]) {
        if (-not ($B -is [System.Collections.IEnumerable])) { return $false }
        $a = @($A); $b = @($B)
        if ($a.Count -ne $b.Count) { return $false }
        for ($i = 0; $i -lt $a.Count; $i++) {
            if (-not (Test-DbM28JsonEquivalent -A $a[$i] -B $b[$i] -Path ($Path + '[' + $i + ']'))) { return $false }
        }
        return $true
    }
    return ([string]$A -ceq [string]$B)
}

# --- secret status ------------------------------------------------------------------------

function Get-DbM28ProviderSecretStatus {
    <#
    .SYNOPSIS
    Whether the provider's referenced secret is configured. SecretReference holds
    an env-var NAME only. Status is derived from (a) the reference being a valid
    env-var NAME pattern and (b) the referenced variable being PRESENT in the
    environment (presence check only -- the value is never read, never returned,
    never rendered). $SecretLookup is an optional scriptblock for deterministic
    tests; the default checks the process environment.
    #>
    param([AllowNull()][object]$Provider, [AllowNull()][System.Management.Automation.ScriptBlock]$SecretLookup)
    $ref = [string](Get-ContractProperty $Provider 'SecretReference' '')
    $configured = [bool](Get-ContractProperty $Provider 'Configured' $false)
    if (-not $ref) {
        # Providers that do not authenticate (e.g. local endpoints) need no secret.
        return 'NO_SECRET_REQUIRED'
    }
    if ($ref -notmatch '^[A-Z][A-Z0-9_]{2,63}$') { return 'INVALID_CONFIGURATION' }
    $present = $false
    if ($SecretLookup) { $present = [bool](@($SecretLookup.Invoke($ref))[0]) }
    else {
        try { $present = ($null -ne [Environment]::GetEnvironmentVariable($ref)) } catch { $present = $false }
    }
    if ($present -and $configured) { return 'CONFIGURED' }
    return 'NOT_CONFIGURED'
}

# --- route + pricing rows -------------------------------------------------------------------

function Get-DbM28ModelRouteType {
    <#
    .SYNOPSIS
    A model's delivery route: GATEWAY when a gateway provider is set (OpenRouter),
    else the owning provider's ProviderType (DIRECT / LOCAL). Never collapses the
    gateway provider and the underlying model.
    #>
    param([AllowNull()][object]$Model, [AllowNull()][object]$Provider)
    $gw = [string](Get-ContractProperty $Model 'GatewayProviderId' '')
    if ($gw) { return 'GATEWAY' }
    $pt = [string](Get-ContractProperty $Provider 'ProviderType' 'DIRECT')
    if ($pt -eq 'GATEWAY') { return 'GATEWAY' }
    if ($pt -eq 'LOCAL') { return 'LOCAL' }
    return 'DIRECT'
}

function Get-DbM28PriceRow {
    <#
    .SYNOPSIS
    DB-M23 price status for one model route, consumed READ-ONLY. LOCAL never maps
    to FREE; unknown local cost is LOCAL_COST_UNKNOWN. The effective pricing
    record + governed status (DB-M15) ride along.
    #>
    param([AllowNull()][object]$Configuration, [AllowNull()][object]$Model, [AllowNull()][object]$Provider, [string]$NowUtc)
    $provId = [string](Get-ContractProperty $Provider 'ProviderId' '')
    $mid = [string](Get-ContractProperty $Model 'ModelId' '')
    $lor = [string](Get-ContractProperty $Model 'LocalOrRemote' 'REMOTE')
    $route = Get-DbM28ModelRouteType -Model $Model -Provider $Provider
    $status = 'PRICE_UNKNOWN'
    $operationalCostUnknown = $false
    $providerTokenPrice = $null
    try {
        if ($Configuration.Pricing) {
            $ps = Get-ProviderRoutePriceStatus -Catalogue $Configuration.Pricing -ProviderId $provId -ModelId $mid -LocalOrRemote $lor -HasConfiguredOperationalCostBasis $false
            if ($ps) {
                $status = [string](Get-ContractProperty $ps 'PriceStatus' 'PRICE_UNKNOWN')
                $operationalCostUnknown = [bool](Get-ContractProperty $ps 'OperationalCostUnknown' $false)
                $providerTokenPrice = Get-ContractProperty $ps 'ProviderTokenPrice' $null
            }
        }
    } catch { $status = 'PRICE_UNKNOWN' }
    return [pscustomobject]@{
        ProviderId            = $provId
        ModelId               = $mid
        RouteType             = $route
        PriceStatus           = $status
        OperationalCostUnknown = $operationalCostUnknown
        ProviderTokenPrice    = $providerTokenPrice
    }
}

# --- eligibility (DB-M19 reuse) -------------------------------------------------------------

function Get-DbM28EligibilityStateFromReason {
    param([AllowNull()][string]$Reason)
    switch ([string]$Reason) {
        'MODEL_DISABLED'     { return 'DISABLED' }
        'PROVIDER_DISABLED'  { return 'DISABLED' }
        'PROVIDER_UNAVAILABLE' { return 'PROVIDER_UNHEALTHY' }
        'PRICE_UNAVAILABLE'  { return 'PRICING_UNKNOWN' }
        default              { return 'CAPABILITY_MISMATCH' }
    }
}

function Get-DbM28EligibilityRow {
    <#
    .SYNOPSIS
    Routing eligibility for one model, by REUSING the real DB-M19 hard eligibility
    filter (Test-AiModelCapabilityFit). Two passes are combined: an availability
    pass (null Requirement) and a standard coding+tool-use capability pass. The
    first rejection reason (in DB-M19 vocabulary order) maps to a DB-M28 display
    state. CONFIGURATION_INCOMPLETE is a DB-M28-derived state shown ALONGSIDE the
    raw DB-M19 reasons when the provider is not configured. A model rejected by a
    DB-M19 hard capability gate is NEVER toggle-fixable here.
    #>
    param([AllowNull()][object]$Configuration, [AllowNull()][object]$Model, [AllowNull()][object]$Provider,
          [AllowNull()][System.Collections.IDictionary]$ProviderHealth, [AllowNull()][object]$Policy, [string]$NowUtc,
          [AllowNull()][System.Management.Automation.ScriptBlock]$SecretLookup)
    $provId = [string](Get-ContractProperty $Provider 'ProviderId' '')
    $mid = [string](Get-ContractProperty $Model 'ModelId' '')
    $avail = Test-AiModelCapabilityFit -Model $Model -Provider $Provider -Requirement $null `
        -Pricing $Configuration.Pricing -ProviderHealth $ProviderHealth -Policy $Policy -ProcessingTier 'STANDARD' -TimestampUtc $NowUtc
    $req = New-AiCapabilityRequirement -RequiresCoding $true -RequiresToolUse $true -ExecutionMode 'MANUAL'
    $cap = Test-AiModelCapabilityFit -Model $Model -Provider $Provider -Requirement $req `
        -Pricing $Configuration.Pricing -ProviderHealth $ProviderHealth -Policy $Policy -ProcessingTier 'STANDARD' -TimestampUtc $NowUtc
    # Combine + dedupe, keep DB-M19 vocabulary order.
    $order = @(Get-DbM19RejectionReasons)
    $seen = New-Object System.Collections.Generic.List[string]
    $combined = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($avail.RejectionReasons)) {
        $rc = [string]$r.Reason
        if (-not $seen.Contains($rc)) { $seen.Add($rc); $combined.Add($r) }
    }
    foreach ($r in @($cap.RejectionReasons)) {
        $rc = [string]$r.Reason
        if (-not $seen.Contains($rc)) { $seen.Add($rc); $combined.Add($r) }
    }
    $ordered = @($combined | Sort-Object -Property @{ Expression = {
        $i = [array]::IndexOf($order, [string]$_.Reason); if ($i -lt 0) { 9999 } else { $i } }; Ascending = $true })
    $first = if ($ordered.Count -gt 0) { [string]$ordered[0].Reason } else { $null }

    # DB-M28-derived configuration completeness.
    $configIncomplete = $false
    $configDetail = ''
    if (-not [bool](Get-ContractProperty $Provider 'Configured' $false)) {
        $configIncomplete = $true
        $configDetail = 'provider not configured (Configured=false)'
    }
    $secretStatus = Get-DbM28ProviderSecretStatus -Provider $Provider -SecretLookup $SecretLookup
    if ($secretStatus -eq 'NOT_CONFIGURED') {
        $configIncomplete = $true
        $configDetail = 'referenced secret is not present/configured'
    } elseif ($secretStatus -eq 'INVALID_CONFIGURATION') {
        $configIncomplete = $true
        $configDetail = 'referenced secret name is not a valid env-var NAME'
    }
    $ptype = [string](Get-ContractProperty $Provider 'ProviderType' 'DIRECT')
    if ($ptype -eq 'LOCAL' -and -not [string](Get-ContractProperty $Provider 'BaseEndpoint' '')) {
        $configIncomplete = $true
        $configDetail = 'local endpoint not configured'
    }

    $state = if ($first) { Get-DbM28EligibilityStateFromReason $first } else { 'ELIGIBLE' }
    if (-not $first -and $configIncomplete) { $state = 'CONFIGURATION_INCOMPLETE' }

    $toggleFixable = ($state -eq 'DISABLED')
    $hardCapabilityGate = $false
    foreach ($r in @($ordered)) {
        $rc = [string]$r.Reason
        if ($rc -notin @('MODEL_DISABLED', 'PROVIDER_DISABLED', 'PROVIDER_UNAVAILABLE', 'PRICE_UNAVAILABLE')) { $hardCapabilityGate = $true }
    }
    return [pscustomobject]@{
        ProviderId          = $provId
        ModelId             = $mid
        Fits                = ($ordered.Count -eq 0)
        Eligible            = ($ordered.Count -eq 0)
        State               = $state
        FirstReason         = $first
        Reasons             = @($ordered | ForEach-Object { [string]$_.Reason })
        ConfigIncomplete    = $configIncomplete
        ConfigIncompleteDetail = $configDetail
        ToggleFixable       = $toggleFixable
        HardCapabilityGate  = $hardCapabilityGate
        SecretStatus        = $secretStatus
    }
}

# --- health view (DB-M22 snapshot, read-only) ------------------------------------------------

function Get-DbM28HealthView {
    <#
    .SYNOPSIS
    Provider-health section. DB-M28 does NOT measure health and does NOT mutate
    it. It consumes an OPTIONAL effective-health snapshot (the DB-M26 pattern);
    with no snapshot the view honestly reports UNKNOWN / no evidence. Reads are
    routed into the DB-M19 eligibility pass so PROVIDER_UNAVAILABLE reflects the
    snapshot, never the UI.
    #>
    param([AllowNull()][object]$Configuration, [AllowNull()][object[]]$HealthSnapshot = $null, [string]$NowUtc)
    $rows = New-Object System.Collections.Generic.List[object]
    $healthDict = @{}
    foreach ($p in @($Configuration.Providers.Values)) {
        if ($null -eq $p) { continue }
        $provId = [string](Get-ContractProperty $p 'ProviderId' '')
        $healthState = 'UNKNOWN'
        $circuit = 'UNKNOWN'
        $lastChecked = $null
        $found = $false
        if ($null -ne $HealthSnapshot) {
            foreach ($h in @($HealthSnapshot)) {
                if ($null -eq $h) { continue }
                $hp = [string](Get-ContractProperty $h 'ProviderId' '')
                if ($hp -ieq $provId) {
                    $healthState = [string](Get-ContractProperty $h 'HealthState' 'UNKNOWN')
                    $circuit = [string](Get-ContractProperty $h 'CircuitState' 'UNKNOWN')
                    $lastChecked = Get-ContractProperty $h 'LastCheckedUtc' $null
                    $found = $true
                    break
                }
            }
        }
        $healthDict[$provId.ToLowerInvariant()] = $healthState
        $rows.Add([pscustomobject]@{
            ProviderId     = $provId
            HealthState    = $healthState
            CircuitState   = $circuit
            LastCheckedUtc = $lastChecked
            FromSnapshot   = $found
        })
    }
    return [pscustomobject]@{
        SchemaVersion = 1
        Source        = if ($null -ne $HealthSnapshot) { 'OPTIONAL_SNAPSHOT' } else { 'NO_EVIDENCE' }
        ReadOnly      = $true
        Rows          = @($rows.ToArray())
        HealthDict    = $healthDict
    }
}

# --- DB-M27 cost-estimate integration (READ-ONLY) ---------------------------------------------

function Get-DbM28CostEstimate {
    <#
    .SYNOPSIS
    VIEW COST ESTIMATE integration. DB-M28 calls the DB-M27 calculator (which is
    the DB-M16 authority) for a reference configuration and surfaces its
    ESTIMATED numbers, pricing status, quality evidence and budget context --
    READ-ONLY. DB-M28 contains no cost formula of its own.
    #>
    param([AllowNull()][object]$Configuration, [AllowNull()][object]$BudgetPolicy = $null,
          [AllowNull()][object[]]$AttemptRecords = $null, [string]$NowUtc = '2026-08-31T12:00:00Z',
          [string]$ProviderId = 'deepseek', [string]$ModelId = 'deepseek-v4-flash',
          [string]$RouteType = 'DIRECT', [string]$ReasoningLevel = 'MEDIUM')
    $base = @{
        Integration = 'DB-M27'
        Authority   = 'DB-M16'
        ProviderId  = $ProviderId
        ModelId     = $ModelId
        RouteType   = $RouteType
        ReasoningLevel = $ReasoningLevel
        CurrencyTarget = 'USD'
        InputTokens    = 12000
        OutputTokens   = 8000
        CachedInputTokens = 100000
        Available      = $true
        Error          = $null
    }
    try {
        $req = New-DbM27CalculatorRequest -ProviderId $ProviderId -RouteType $RouteType -ModelId $ModelId `
            -UnderlyingModelId $ModelId -ReasoningLevel $ReasoningLevel `
            -InputTokens 12000 -OutputTokens 8000 -CachedInputTokens 100000 -CacheWriteTokens 0 `
            -AttemptCount 1 -ExpectedCorrectionAttempts 0 -CurrencyTarget 'USD' -NowUtc $NowUtc
        $view = Invoke-DbM27Calculator -Configuration $Configuration -Request $req `
            -AttemptRecords $AttemptRecords -BudgetPolicy $BudgetPolicy
        $est = if ($view) { Get-ContractProperty $view 'Estimate' $null } else { $null }
        $pricing = if ($view) { Get-ContractProperty $view 'Pricing' $null } else { $null }
        $quality = if ($view) { Get-ContractProperty $view 'Quality' $null } else { $null }
        $budget = if ($view) { Get-ContractProperty $view 'Budget' $null } else { $null }
        $guard = if ($view) { Get-ContractProperty $view 'ReadOnlyGuard' $null } else { $null }
        $base.Estimate = [pscustomobject]@{
            EstimatedCost     = if ($est) { Get-ContractProperty $est 'EstimatedCost' $null } else { $null }
            TargetCurrency    = if ($est) { [string](Get-ContractProperty $est 'TargetCurrency' 'USD') } else { 'USD' }
            CalculationStatus = if ($est) { [string](Get-ContractProperty $est 'CalculationStatus' '') } else { '' }
            IsEstimated       = $true
        }
        $base.Pricing = [pscustomobject]@{
            PricingRecordId     = if ($pricing) { Get-ContractProperty $pricing 'PricingRecordId' $null } else { $null }
            PricingRecordStatus = if ($pricing) { [string](Get-ContractProperty $pricing 'PricingRecordStatus' 'NONE') } else { 'NONE' }
            PriceStatus         = if ($pricing) { [string](Get-ContractProperty $pricing 'PriceStatus' 'PRICE_UNKNOWN') } else { 'PRICE_UNKNOWN' }
        }
        $base.Quality = [pscustomobject]@{
            HasEvidence   = if ($quality) { [bool](Get-ContractProperty $quality 'HasEvidence' $false) } else { $false }
            SampleCount   = if ($quality) { [long](Get-ContractProperty $quality 'SampleCount' 0) } else { 0 }
            ConfidenceLevel = if ($quality) { [string](Get-ContractProperty $quality 'ConfidenceLevel' 'INSUFFICIENT') } else { 'INSUFFICIENT' }
            EvidenceNote  = if ($quality) { [string](Get-ContractProperty $quality 'EvidenceNote' '') } else { '' }
        }
        $base.Budget = [pscustomobject]@{
            InformationalOnly = $true
            OverrideAllowed   = $false
            Decision          = if ($budget) { [string](Get-ContractProperty $budget 'Decision' 'NO_APPLICABLE_BUDGET') } else { 'NO_APPLICABLE_BUDGET' }
        }
        $base.ReadOnlyGuard = if ($guard) { $guard } else { (New-DbM28ReadOnlyGuard) }
    } catch {
        $base.Available = $false
        $base.Error = $_.Exception.Message
    }
    return [pscustomobject]$base
}

# --- audit log -------------------------------------------------------------------------------

function Get-DbM28AuditPath {
    param([string]$Root, [AllowNull()][string]$AuditPath)
    if ($AuditPath) { return $AuditPath }
    return Join-Path $Root 'state\db-m28-config-changes.json'
}

function Read-DbM28AuditLog {
    <#
    .SYNOPSIS
    Read the DB-M28 configuration-change audit log. Absent file -> empty log.
    #>
    param([string]$Root, [AllowNull()][string]$AuditPath)
    $path = Get-DbM28AuditPath -Root $Root -AuditPath $AuditPath
    $records = New-Object System.Collections.Generic.List[object]
    if (Test-Path $path) {
        $doc = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($doc.changes)) { if ($null -ne $r) { $records.Add((New-DbM28ConfigChangeRecord -InputObject $r)) } }
    }
    return @{ Path = $path; Records = @($records.ToArray()); Count = $records.Count }
}

function Test-DbM28ConfigChangeApplicable {
    <#
    .SYNOPSIS
    Validate the change request AGAINST the live catalogue: the target record must
    exist and the proposed value must be valid for the field (bool fields reject
    non-boolean values). Read-only.
    #>
    param([AllowNull()][object]$Configuration, [AllowNull()][object]$Request)
    $valid = Test-DbM28ConfigChangeRequest $Request
    if (-not $valid.Valid) { return @{ Applicable = $false; Errors = @($valid.Errors); Warnings = @($valid.Warnings) } }
    $errors = New-Object System.Collections.Generic.List[string]
    $tt = [string]$Request.TargetType
    $tid = [string]$Request.TargetId
    $catalogue = if ($tt -eq 'PROVIDER') { $Configuration.Providers } else { $Configuration.Models }
    $key = $tid.ToLowerInvariant()
    $rec = $null
    if ($catalogue -is [System.Collections.IDictionary]) { $rec = $catalogue[$key] }
    if ($null -eq $rec) { $errors.Add("Target '$tt/$tid' not found in the live catalogue") }
    else {
        $field = [string]$Request.Field
        $nv = $Request.NewValue
        if ($field -in @('Enabled', 'Configured') -and -not ($nv -is [bool])) {
            $errors.Add("Field '$field' requires a boolean value")
        }
        if ($field -eq 'Notes' -and $null -ne $nv -and -not ($nv -is [string])) {
            $errors.Add("Field 'Notes' requires a string value")
        }
    }
    return @{ Applicable = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @($valid.Warnings) }
}

# --- persistence adapter (validated, atomic, audited) ------------------------------------------

function Apply-DbM28ConfigChange {
    <#
    .SYNOPSIS
    Apply ONE operator configuration change to config\providers.json or
    config\models.json through a validated atomic audited pipeline:
      1. validate the request + applicability against the live catalogue
      2. surgically edit the in-memory JSON document (one field on one record)
      3. validate the PROPOSED document by loading it through the REAL DevBridge
         loader on a temporary root (semantic validation before any save)
      4. write atomically (temp file + Move-Item) to the live config file
      5. read back the live file and prove the field applied and NO unrelated
         field changed
      6. append a NON-SECRET config-change record to the audit log
    The audit record never contains SecretReference or any secret value. Live
    pricing/currency/cost/performance/ai-routing/devbridge configs are never
    written. $Root lets the test suite exercise the pipeline on a temporary tree;
    the real root is only touched by an operator's explicit Apply.
    #>
    param([string]$Root, [AllowNull()][object]$Request, [string]$NowUtc = '2026-08-31T12:00:00Z',
          [AllowNull()][string]$AuditPath = $null)
    $result = @{
        Applied = $false; Changed = $false; Validated = $false; ReadBack = $false; Audited = $false
        Message = ''; Record = $null; OldValue = $null; NewValue = $null
    }
    if (-not $Root) { $result.Message = 'ROOT_REQUIRED'; return $result }
    $valid = Test-DbM28ConfigChangeRequest $Request
    if (-not $valid.Valid) { $result.Message = 'REQUEST_INVALID: ' + ($valid.Errors -join '; '); return $result }
    $tt = [string]$Request.TargetType
    $tid = [string]$Request.TargetId
    $field = [string]$Request.Field
    $nv = $Request.NewValue
    $listProp = if ($tt -eq 'PROVIDER') { 'providers' } else { 'models' }
    $idProp = if ($tt -eq 'PROVIDER') { 'ProviderId' } else { 'ModelId' }
    $file = $listProp + '.json'
    $configFile = Join-Path $Root ("config\" + $file)
    if (-not (Test-Path $configFile)) { $result.Message = "CONFIG_FILE_MISSING: $configFile"; return $result }

    # Load the live document and find the target record.
    $doc = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = @($doc.$listProp)
    $idx = -1
    for ($i = 0; $i -lt $list.Count; $i++) {
        $k = [string](Get-ContractProperty $list[$i] $idProp '')
        if ($k -ieq $tid) { $idx = $i; break }
    }
    if ($idx -lt 0) { $result.Message = "TARGET_NOT_FOUND: $tt/$tid"; return $result }
    $target = $list[$idx]
    $oldVal = Get-ContractProperty $target $field $null

    # Already at value -> no write.
    $same = Test-DbM28JsonEquivalent -A $oldVal -B $nv
    if ($same) {
        $result.Message = 'ALREADY_AT_VALUE'
        $result.OldValue = $oldVal; $result.NewValue = $nv
        return $result
    }

    # Surgical edit on the in-memory document.
    $foundProp = $false
    foreach ($p in $target.PSObject.Properties) {
        if ($p.Name -ceq $field) { $p.Value = $nv; $foundProp = $true; break }
    }
    if (-not $foundProp) { $target | Add-Member -NotePropertyName $field -NotePropertyValue $nv }

    # Serialize the proposed document (array-preserving).
    $json = ConvertTo-DbM28Json -Object $doc -Depth 0

    # Validate the PROPOSED document through the REAL loader on a temporary root.
    $validRoot = Join-Path $Root ('.db28-validate-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $validRoot -Force | Out-Null
        Copy-Item -Path (Join-Path $Root 'config') -Destination (Join-Path $validRoot 'config') -Recurse -Force
        $tmpFile = Join-Path $validRoot "config\$file"
        [System.IO.File]::WriteAllText($tmpFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        $cfg = Import-AiCostConfiguration -Root $validRoot
        $catalogue = if ($tt -eq 'PROVIDER') { $cfg.Providers } else { $cfg.Models }
        $proposed = $null
        if ($catalogue -is [System.Collections.IDictionary]) { $proposed = $catalogue[$tid.ToLowerInvariant()] }
        if ($null -eq $proposed) {
            $result.Message = 'VALIDATION_FAILED: proposed record missing after loader round-trip'
            return $result
        }
        $applied = Get-ContractProperty $proposed $field $null
        $matches = Test-DbM28JsonEquivalent -A $applied -B $nv
        if (-not $matches) {
            $result.Message = "VALIDATION_FAILED: field '$field' did not round-trip"
            return $result
        }
        $result.Validated = $true
    } catch {
        $result.Message = 'VALIDATION_FAILED: ' + $_.Exception.Message
        Remove-Item -Path $validRoot -Recurse -Force -ErrorAction SilentlyContinue
        return $result
    }
    Remove-Item -Path $validRoot -Recurse -Force -ErrorAction SilentlyContinue

    # Atomic write to the live config file.
    try {
        $tmp = Join-Path $Root ("config\." + $file + '.db28-tmp-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Path $tmp -Destination $configFile -Force
    } catch {
        $result.Message = 'WRITE_FAILED: ' + $_.Exception.Message
        return $result
    }

    # Read-back verification: field applied + no unrelated change.
    try {
        $rbDoc = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $rbList = @($rbDoc.$listProp)
        $rbTarget = $null
        for ($i = 0; $i -lt $rbList.Count; $i++) {
            if (([string](Get-ContractProperty $rbList[$i] $idProp '')) -ieq $tid) { $rbTarget = $rbList[$i]; break }
        }
        if ($null -eq $rbTarget) { $result.Message = 'READBACK_FAILED: target not found'; return $result }
        $rbVal = Get-ContractProperty $rbTarget $field $null
        if (-not (Test-DbM28JsonEquivalent -A $rbVal -B $nv)) {
            $result.Message = "READBACK_FAILED: field '$field' not applied"
            return $result
        }
        # No unrelated change: restore the edited field to its ORIGINAL value in
        # BOTH the original and the read-back document, then deep-equal. The two
        # documents must be identical except for the operator's field.
        foreach ($p in $doc.$listProp) {
            if (([string](Get-ContractProperty $p $idProp '')) -ieq $tid) {
                foreach ($pp in $p.PSObject.Properties) { if ($pp.Name -ceq $field) { $pp.Value = $oldVal } }
            }
        }
        foreach ($p in $rbDoc.$listProp) {
            if (([string](Get-ContractProperty $p $idProp '')) -ieq $tid) {
                foreach ($pp in $p.PSObject.Properties) { if ($pp.Name -ceq $field) { $pp.Value = $oldVal } }
            }
        }
        if (-not (Test-DbM28JsonEquivalent -A $doc -B $rbDoc)) {
            $result.Message = 'READBACK_FAILED: unrelated configuration fields changed'
            return $result
        }
        $result.ReadBack = $true
    } catch {
        $result.Message = 'READBACK_FAILED: ' + $_.Exception.Message
        return $result
    }

    # Audit (non-secret record).
    $record = New-DbM28ConfigChangeRecord -ChangeId (('cfg-' + ([math]::Abs(([long]((Get-Date -Date $NowUtc -UFormat %s))))))) `
        -TimestampUtc $NowUtc -Category ([string]$Request.Category) -TargetType $tt -TargetId $tid -Field $field `
        -OldValue $oldVal -NewValue $nv -OperatorAction ([string]$Request.OperatorAction) -ConfigVersion 1 -Applied $true `
        -RedactedFields @('SecretReference')
    $auditPath = Get-DbM28AuditPath -Root $Root -AuditPath $AuditPath
    try {
        $audit = Read-DbM28AuditLog -Root $Root -AuditPath $AuditPath
        $records = New-Object System.Collections.Generic.List[object]
        foreach ($r in $audit.Records) { $records.Add($r) }
        $records.Add($record)
        $stateDir = Split-Path -Parent $auditPath
        if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        $auditDoc = [pscustomobject]@{
            schemaVersion = 1
            description   = 'DB-M28 configuration-change audit. Records carry NON-SECRET old/new state ONLY; SecretReference and all secret values are never logged.'
            changes       = @($records.ToArray())
        }
        $auditJson = ConvertTo-DbM28Json -Object $auditDoc -Depth 0
        $tmpAudit = Join-Path $stateDir ('.db28-audit-tmp-' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($tmpAudit, $auditJson, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Path $tmpAudit -Destination $auditPath -Force
        $result.Audited = $true
    } catch {
        $result.Message = 'AUDIT_FAILED: ' + $_.Exception.Message
        return $result
    }

    $result.Applied = $true
    $result.Changed = $true
    $result.Record = $record
    $result.OldValue = $oldVal
    $result.NewValue = $nv
    $result.Message = 'APPLIED'
    return $result
}

# --- configuration view ----------------------------------------------------------------------

function Get-DbM28ConfigurationViewCore {
    param([AllowNull()][object]$Configuration)
    # Providers are a READ-ONLY input; normalize once for stable ordering.
    $providers = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Configuration.Providers.Values)) {
        if ($null -eq $p) { continue }
        $providers.Add([pscustomobject]@{
            ProviderId  = [string](Get-ContractProperty $p 'ProviderId' '')
            Provider    = $p
        })
    }
    $models = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Configuration.Models.Values)) {
        if ($null -eq $m) { continue }
        $models.Add([pscustomobject]@{
            ModelId = [string](Get-ContractProperty $m 'ModelId' '')
            Model   = $m
        })
    }
    return @{ Providers = $providers; Models = $models }
}

function New-DbM28ModelConfigurationView {
    <#
    .SYNOPSIS
    Build the full DB-M28 model-configuration view (10 sections) by consuming the
    real DB-M14..M27 implementations READ-ONLY. Deterministic: NowUtc injected.
    #>
    param(
        [string]$ConfigRoot = (Resolve-AiRoutingRoot),
        [AllowNull()][object]$Configuration = $null,
        [AllowNull()][object[]]$HealthSnapshot = $null,
        [AllowNull()][object[]]$AttemptRecords = $null,
        [AllowNull()][object]$BudgetPolicy = $null,
        [AllowNull()][System.Management.Automation.ScriptBlock]$SecretLookup = $null,
        [string]$NowUtc = '2026-08-31T12:00:00Z',
        [AllowNull()][string]$AuditPath = $null
    )
    # Test fixture injection (mirrors DB-M27's -Configuration): when a caller
    # supplies an already-loaded cost configuration (e.g. synthetic fixture
    # models/providers/pricing for the suite), use it instead of loading from
    # disk. Default behavior is unchanged: load the live config from ConfigRoot.
    if ($null -eq $Configuration) {
        $Configuration = Import-AiCostConfiguration -Root $ConfigRoot
    }
    $core = Get-DbM28ConfigurationViewCore -Configuration $Configuration
    $policy = Get-DefaultRoutingPolicy
    $healthView = Get-DbM28HealthView -Configuration $Configuration -HealthSnapshot $HealthSnapshot -NowUtc $NowUtc

    $providerById = @{}
    foreach ($p in @($Configuration.Providers.Values)) {
        if ($null -eq $p) { continue }
        $providerById[[string](Get-ContractProperty $p 'ProviderId' '')] = $p
    }

    # --- section 1: providers ----------------------------------------------------------
    $providerRows = New-Object System.Collections.Generic.List[object]
    $providerByIdent = @{}
    foreach ($p in @($Configuration.Providers.Values)) {
        if ($null -eq $p) { continue }
        $provId = [string](Get-ContractProperty $p 'ProviderId' '')
        $secretStatus = Get-DbM28ProviderSecretStatus -Provider $p -SecretLookup $SecretLookup
        $hr = $null
        foreach ($h in $healthView.Rows) { if ($h.ProviderId -ieq $provId) { $hr = $h; break } }
        $providerByIdent[$provId] = [pscustomobject]@{
            ProviderId               = $provId
            DisplayName              = [string](Get-ContractProperty $p 'DisplayName' $provId)
            ProviderType             = [string](Get-ContractProperty $p 'ProviderType' 'DIRECT')
            GatewayType              = [string](Get-ContractProperty $p 'GatewayType' '')
            Enabled                  = [bool](Get-ContractProperty $p 'Enabled' $false)
            Configured               = [bool](Get-ContractProperty $p 'Configured' $false)
            SecretReference          = [string](Get-ContractProperty $p 'SecretReference' '')
            SecretStatus             = $secretStatus
            SupportsTools            = [bool](Get-ContractProperty $p 'SupportsTools' $false)
            SupportsStreaming        = [bool](Get-ContractProperty $p 'SupportsStreaming' $false)
            SupportsStructuredOutput = [bool](Get-ContractProperty $p 'SupportsStructuredOutput' $false)
            SupportsReasoningControls = [bool](Get-ContractProperty $p 'SupportsReasoningControls' $false)
            HealthState              = if ($hr) { $hr.HealthState } else { 'UNKNOWN' }
            CircuitState             = if ($hr) { $hr.CircuitState } else { 'UNKNOWN' }
        }
        $providerRows.Add($providerByIdent[$provId])
    }

    # --- sections 2-5, 7-8: models, reasoning/capabilities, local, pricing, eligibility ---
    $modelRows = New-Object System.Collections.Generic.List[object]
    $localModels = New-Object System.Collections.Generic.List[object]
    $openRouterRoutes = New-Object System.Collections.Generic.List[object]
    $reasoningOptions = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Configuration.Models.Values)) {
        if ($null -eq $m) { continue }
        $mid = [string](Get-ContractProperty $m 'ModelId' '')
        $provId = [string](Get-ContractProperty $m 'ProviderId' '')
        $prov = $providerById[$provId]
        $route = Get-DbM28ModelRouteType -Model $m -Provider $prov
        $elig = Get-DbM28EligibilityRow -Configuration $Configuration -Model $m -Provider $prov `
            -ProviderHealth $healthView.HealthDict -Policy $policy -NowUtc $NowUtc -SecretLookup $SecretLookup
        $price = Get-DbM28PriceRow -Configuration $Configuration -Model $m -Provider $prov -NowUtc $NowUtc
        $supportsReasoning = Get-ContractProperty $m 'SupportsReasoning' $null
        $rawLevels = Get-ContractProperty $m 'ReasoningLevelsSupported' $null
        $reasoningLevels = New-Object System.Collections.Generic.List[object]
        if ($null -ne $rawLevels) {
            foreach ($rl in @($rawLevels)) { if ($null -ne $rl) { $reasoningLevels.Add([string]$rl) } }
        }
        $row = [pscustomobject]@{
            ModelId                  = $mid
            ProviderId               = $provId
            ProviderDisplayName      = if ($prov) { [string](Get-ContractProperty $prov 'DisplayName' $provId) } else { $provId }
            ProviderModelId          = [string](Get-ContractProperty $m 'ProviderModelId' $mid)
            UnderlyingModelId        = [string](Get-ContractProperty $m 'UnderlyingModelId' $mid)
            GatewayProviderId        = [string](Get-ContractProperty $m 'GatewayProviderId' '')
            DisplayName              = [string](Get-ContractProperty $m 'DisplayName' $mid)
            ModelVersion             = [string](Get-ContractProperty $m 'ModelVersion' '')
            ModelFamily              = [string](Get-ContractProperty $m 'ModelFamily' '')
            Enabled                  = [bool](Get-ContractProperty $m 'Enabled' $false)
            LocalOrRemote            = [string](Get-ContractProperty $m 'LocalOrRemote' 'REMOTE')
            RouteType                = $route
            RouteLabel               = $route
            SupportsCoding           = ConvertTo-DbM28TriState (Get-ContractProperty $m 'SupportsCoding' $null)
            SupportsReasoning        = ConvertTo-DbM28TriState $supportsReasoning
            SupportsVision           = ConvertTo-DbM28TriState (Get-ContractProperty $m 'SupportsVision' $null)
            SupportsToolUse          = ConvertTo-DbM28TriState (Get-ContractProperty $m 'SupportsToolUse' $null)
            SupportsStructuredOutput = ConvertTo-DbM28TriState (Get-ContractProperty $m 'SupportsStructuredOutput' $null)
            SupportsPromptCaching    = ConvertTo-DbM28TriState (Get-ContractProperty $m 'SupportsPromptCaching' $null)
            SupportsBatch            = ConvertTo-DbM28TriState (Get-ContractProperty $m 'SupportsBatch' $null)
            SupportsStreaming        = ConvertTo-DbM28TriState (Get-ContractProperty $m 'SupportsStreaming' $null)
            ContextWindow            = Get-ContractProperty $m 'ContextWindow' $null
            MaxOutputTokens          = Get-ContractProperty $m 'MaxOutputTokens' $null
            ReasoningLevelsSupported = @($reasoningLevels.ToArray())
            RelativeSpeed            = [string](Get-ContractProperty $m 'RelativeSpeed' '')
            ReliabilityClass         = [string](Get-ContractProperty $m 'ReliabilityClass' '')
            AdditionalCapabilityTags = @(if ($null -ne (Get-ContractProperty $m 'AdditionalCapabilityTags' $null)) { @(Get-ContractProperty $m 'AdditionalCapabilityTags' $null) } else { @() })
            PriceStatus              = $price.PriceStatus
            PriceOperationalCostUnknown = $price.OperationalCostUnknown
            PriceProviderTokenPrice = $price.ProviderTokenPrice
            PerformanceEvidence     = [pscustomobject]@{
                Source   = 'DB-M24/DB-M25 attempt-record evidence'
                Available = $false
                Basis    = 'NO_OBSERVED_EVIDENCE'
                Note     = 'observed evidence is computed per identity by DB-M27 from DB-M17 attempt records; the VIEW COST ESTIMATE card carries it for the reference model. DB-M28 never fabricates evidence.'
            }
            HealthState              = $elig.FirstReason
            ProviderHealthState      = if ($prov) {
                $hp = $healthView.HealthDict[[string](Get-ContractProperty $prov 'ProviderId' '')]
                if ($hp) { [string]$hp } else { 'UNKNOWN' }
            } else { 'UNKNOWN' }
            EligibilityState         = $elig.State
            EligibilityFirstReason   = $elig.FirstReason
            EligibilityReasons       = @($elig.Reasons)
            EligibilityFits          = $elig.Fits
            EligibilityConfigIncomplete = $elig.ConfigIncomplete
            EligibilityConfigIncompleteDetail = $elig.ConfigIncompleteDetail
            EligibilityToggleFixable = $elig.ToggleFixable
            EligibilityHardCapabilityGate = $elig.HardCapabilityGate
            SecretStatus             = $elig.SecretStatus
        }
        $modelRows.Add($row)

        # reasoning options (section 4)
        $reasoningOptions.Add([pscustomobject]@{
            ModelId       = $mid
            SupportsReasoning = ConvertTo-DbM28TriState $supportsReasoning
            Levels        = @($reasoningLevels.ToArray())
            LevelsNote    = if ($reasoningLevels.Count -gt 0) { 'asserted' } else { 'NOT_ASSERTED until DB-M15/M19' }
        })

        # local models (section 5)
        $lor = [string](Get-ContractProperty $m 'LocalOrRemote' 'REMOTE')
        $pt = if ($prov) { [string](Get-ContractProperty $prov 'ProviderType' 'DIRECT') } else { 'DIRECT' }
        if ($lor -eq 'LOCAL' -or $pt -eq 'LOCAL') {
            $localModels.Add([pscustomobject]@{
                ModelId = $mid; ProviderId = $provId; DisplayName = $row.DisplayName
                LocalOrRemote = $lor; RouteType = $route; Enabled = $row.Enabled
            })
        }

        # openrouter/gateway routes (section 6)
        $gw = [string](Get-ContractProperty $m 'GatewayProviderId' '')
        if ($gw) {
            $openRouterRoutes.Add([pscustomobject]@{
                GatewayProviderId = $gw
                UnderlyingModelId = [string](Get-ContractProperty $m 'UnderlyingModelId' $mid)
                ModelId           = $mid
                DisplayName       = $row.DisplayName
                ProviderModelId   = $row.ProviderModelId
                Enabled           = $row.Enabled
                RouteLabel        = 'GATEWAY'
            })
        }
    }

    # --- section 7: pricing reference (DB-M15, read-only) ---------------------------------
    $pricingRows = New-Object System.Collections.Generic.List[object]
    foreach ($pr in @($Configuration.Pricing.Values)) {
        if ($null -eq $pr) { continue }
        $rec = $pr
        $rid = [string](Get-ContractProperty $rec 'PricingRecordId' '')
        $statusObj = $null
        try { $statusObj = Get-AiPricingRecordStatus -Record $rec -AsOfUtc $NowUtc } catch { $statusObj = $null }
        $status = if ($statusObj) { [string](Get-ContractProperty $statusObj 'Status' 'UNKNOWN') } else { 'UNKNOWN' }
        $reason = if ($statusObj) { [string](Get-ContractProperty $statusObj 'Reason' '') } else { '' }
        $pricingRows.Add([pscustomobject]@{
            PricingRecordId = $rid
            ModelId         = [string](Get-ContractProperty $rec 'ModelId' '')
            EffectiveFrom   = Get-ContractProperty $rec 'EffectiveFrom' $null
            EffectiveTo     = Get-ContractProperty $rec 'EffectiveTo' $null
            Status          = $status
            Reason          = $reason
        })
    }

    # --- section 9: health status (read-only) ---------------------------------------------
    # --- section 10: security/secret status ------------------------------------------------
    $secretRows = New-Object System.Collections.Generic.List[object]
    foreach ($r in $providerByIdent.Values) {
        $secretRows.Add([pscustomobject]@{
            ProviderId    = $r.ProviderId
            SecretReference = $r.SecretReference
            SecretStatus  = $r.SecretStatus
            Configured    = $r.Configured
        })
    }

    # --- DB-M27 VIEW COST ESTIMATE card -----------------------------------------------------
    $costEstimate = Get-DbM28CostEstimate -Configuration $Configuration -BudgetPolicy $BudgetPolicy `
        -AttemptRecords $AttemptRecords -NowUtc $NowUtc

    # --- persistence descriptor ---------------------------------------------------------------
    $persistence = [pscustomobject]@{
        SchemaVersion      = 1
        Supported          = $true
        Targets            = @(Get-DbM28WritableConfigTargets)
        Mechanism          = 'validated atomic audited adapter: load-live -> validate-before-save (real loader on temp root) -> atomic temp+Move-Item -> read-back verify -> non-secret audit'
        Validated          = $true
        ReadBack           = $true
        Audited            = $true
        ImmutableTargets   = @(Get-DbM28ImmutableConfigTargets)
        ImmutableLimitation = 'pricing / currency / cost / performance / ai-routing / devbridge configuration is governed and read-only; DB-M28 reports this limitation instead of forcing persistence.'
        LiveConfigUnmodifiedByTestRun = $true
    }

    $audit = Read-DbM28AuditLog -Root $ConfigRoot -AuditPath $AuditPath

    return [pscustomobject]@{
        SchemaVersion    = 1
        ConfigViewVersion = 1
        Title            = 'DB-M28 Model Configuration'
        TimestampUtc     = $NowUtc
        RefTimestampUtc  = $NowUtc
        Guard            = New-DbM28ReadOnlyGuard
        Providers        = @($providerRows.ToArray())
        Models           = @($modelRows.ToArray())
        ReasoningLevels  = [pscustomobject]@{
            Available = @(Get-AiRoutingReasoningLevels)
            PerModel  = @($reasoningOptions.ToArray())
        }
        LocalModels      = @($localModels.ToArray())
        OpenRouterRoutes = @($openRouterRoutes.ToArray())
        PricingReference = [pscustomobject]@{
            Authority = 'DB-M15'
            ReadOnly  = $true
            Records   = @($pricingRows.ToArray())
        }
        EligibilitySummary = [pscustomobject]@{
            Source = 'DB-M19 Test-AiModelCapabilityFit (reused READ-ONLY)'
            States = @(Get-DbM28EligibilityStates)
            Rows   = @($modelRows.ToArray())
        }
        HealthStatus     = $healthView
        SecretStatus     = [pscustomobject]@{
            ReadOnly       = $true
            ValuesNeverDisplayed = $true
            Rows           = @($secretRows.ToArray())
        }
        Persistence      = $persistence
        AuditLog         = $audit
        CostEstimate     = $costEstimate
        BuildInfo        = [pscustomobject]@{
            SchemaVersions = Get-DbM28SchemaVersions
            AutoExecutionEnabled = $false
            ProviderModelExecuted = $false
            PaidApiCalls = 0
            NetworkCalls = 0
        }
    }
}

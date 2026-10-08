# RoutingPolicy.ps1 -- DB-M19 routing-policy contracts + default assisted policy.
#
# DB-M19 is RECOMMENDATION ONLY: the router computes a transparent model
# recommendation (model, reasoning level, estimated cost, reason, evidence) and
# NEVER executes a provider or model. RoutingPolicy v1 is frozen here.
#
# A RoutingPolicy is pure CONFIGURATION data. Its weights, thresholds and
# tie-breaker chain are read by the ranking engine; no policy weight is
# hard-coded in routing logic. Objectives:
#   CHEAPEST_ELIGIBLE   - lowest estimated attempt cost among eligible
#   CHEAPEST_RELIABLE   - conservative: satisfy hard requirements + minimum
#                         reliability; prefer sufficient historical confidence;
#                         compare estimated current attempt cost; consider
#                         verified cost-per-success when reliable (default)
#   BEST_COST_PER_SUCCESS - minimize verified cost-per-success (reliable evidence)
#   HIGHEST_SUCCESS     - highest verified success rate (self-reported PASS that
#                         failed independent verification does NOT count)
#   FASTEST_RELIABLE    - fastest among reliable candidates
#   BALANCED            - weighted multi-objective combination
#   MANUAL              - present candidates, never auto-select
#
# ADR-005: no provider/model NAME branching. All identifiers are data.
#
# Dot-source AiRoutingContracts.ps1 (DB-M14, read-only) first.

. (Join-Path $PSScriptRoot "..\AiRoutingContracts.ps1")   # DB-M14 vocab + helpers (READ-ONLY)

# -----------------------------------------------------------------------------
# Vocabularies
# -----------------------------------------------------------------------------
function Get-RoutingPolicyObjectives {
    return @('CHEAPEST_ELIGIBLE', 'CHEAPEST_RELIABLE', 'BEST_COST_PER_SUCCESS',
             'HIGHEST_SUCCESS', 'FASTEST_RELIABLE', 'BALANCED', 'MANUAL')
}

function Get-DbM19RejectionReasons {
    <#
    .SYNOPSIS
    The structured rejection-reason vocabulary for the STEP-1 hard eligibility
    filter (and the STEP-3 budget/price gates). Reasons are vocabulary members,
    never free text; a human-readable detail accompanies every reason.
    #>
    return @(
        'MODEL_DISABLED', 'PROVIDER_DISABLED', 'PROVIDER_UNAVAILABLE',
        'CAPABILITY_CODING_MISSING', 'CAPABILITY_VISION_MISSING',
        'CAPABILITY_TOOL_USE_MISSING', 'STRUCTURED_OUTPUT_MISSING',
        'REASONING_LEVEL_INSUFFICIENT', 'CONTEXT_TOO_SMALL',
        'OUTPUT_LIMIT_TOO_SMALL', 'RELIABILITY_TOO_LOW',
        'PROVIDER_DISALLOWED', 'MODEL_DISALLOWED', 'LOCALITY_CONFLICT',
        'BUDGET_EXCEEDED', 'PRICE_UNAVAILABLE', 'PROCESSING_TIER_UNSUPPORTED'
    )
}

function Get-RoutingPolicyWeightNames {
    return @('cost', 'success', 'firstAttemptSuccess', 'costPerSuccess', 'latency', 'reliability')
}

function Get-RoutingPolicyThresholdNames {
    return @('minimumReliability', 'reasoningReserveTokens', 'allowCostUnknown', 'requireConfirmedProviderHealth')
}

# -----------------------------------------------------------------------------
# Schema versions (DB-M19-owned; DB-M14 registry NOT modified)
# -----------------------------------------------------------------------------
function Get-DbM19RoutingPolicySchemaVersions {
    return [pscustomobject]@{
        RoutingPolicyVersion          = 1
        RoutingCandidateVersion       = 1
        RoutingDecisionEvidenceVersion = 1
        RoutingRequestVersion         = 1
    }
}

# -----------------------------------------------------------------------------
# RoutingPolicy v1 construction
# -----------------------------------------------------------------------------
function New-RoutingPolicy {
    <#
    .SYNOPSIS
    Build a normalized RoutingPolicy v1. Weights and Thresholds are required
    configuration data (the ranking engine reads them; nothing is hard-coded).
    Missing weight keys normalize to null (= not part of the objective score);
    missing threshold keys normalize to documented defaults.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$PolicyId,
        [string]$Name,
        [string]$Objective,
        [bool]$Enabled = $true,
        [AllowNull()][object]$Weights,
        [AllowNull()][object]$Thresholds,
        [string[]]$TieBreaker,
        [string]$MinimumConfidenceForHistoricalWeight,
        [string]$Notes
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }

    $id = if ($InputObject) { & $g 'PolicyId' $PolicyId } else { $PolicyId }
    if (-not $id) { throw "New-RoutingPolicy: PolicyId is required" }
    $id = $id.Trim()

    $name = if ($InputObject) { & $g 'Name' $Name } else { $Name }
    if (-not $name) { $name = $id }

    $objective = if ($InputObject) { & $g 'Objective' $Objective } else { $Objective }
    if (-not $objective) { throw "New-RoutingPolicy: Objective is required" }
    $objective = $objective.Trim().ToUpperInvariant()
    if ($objective -notin (Get-RoutingPolicyObjectives)) {
        throw "New-RoutingPolicy: Objective '$objective' not in $((Get-RoutingPolicyObjectives) -join ', ')"
    }

    $enabled = if ($InputObject) { [bool](& $g 'Enabled' $Enabled) } else { $Enabled }

    # --- normalize Weights (data, not code): missing keys -> null -------------
    $w = [pscustomobject]@{
        cost                  = $null
        success               = $null
        firstAttemptSuccess   = $null
        costPerSuccess        = $null
        latency               = $null
        reliability           = $null
    }
    $srcW = if ($InputObject) { & $g 'Weights' $Weights } else { $Weights }
    if ($null -ne $srcW) {
        foreach ($wn in Get-RoutingPolicyWeightNames) {
            $v = Get-ContractProperty $srcW $wn $null
            if ($null -ne $v) { $w.$wn = [double]$v }
        }
    }

    # --- normalize Thresholds -------------------------------------------------
    $t = [pscustomobject]@{
        minimumReliability            = $null
        reasoningReserveTokens        = 0L
        allowCostUnknown              = $true
        requireConfirmedProviderHealth = $false
    }
    $srcT = if ($InputObject) { & $g 'Thresholds' $Thresholds } else { $Thresholds }
    if ($null -ne $srcT) {
        $mr = Get-ContractProperty $srcT 'minimumReliability' $null
        if ($null -ne $mr) { $t.minimumReliability = [double]$mr }
        $rr = Get-ContractProperty $srcT 'reasoningReserveTokens' $null
        if ($null -ne $rr) { $t.reasoningReserveTokens = [long]$rr }
        $acu = Get-ContractProperty $srcT 'allowCostUnknown' $null
        if ($null -ne $acu) { $t.allowCostUnknown = [bool]$acu }
        $rch = Get-ContractProperty $srcT 'requireConfirmedProviderHealth' $null
        if ($null -ne $rch) { $t.requireConfirmedProviderHealth = [bool]$rch }
    }

    $tie = @()
    if ($InputObject) { $tie = @(& $g 'TieBreaker' $TieBreaker) }
    elseif ($TieBreaker) { $tie = @($TieBreaker) }

    $minConf = if ($InputObject) { & $g 'MinimumConfidenceForHistoricalWeight' $MinimumConfidenceForHistoricalWeight } else { $MinimumConfidenceForHistoricalWeight }
    if (-not $minConf) { $minConf = 'INSUFFICIENT' }
    $minConf = $minConf.Trim().ToUpperInvariant()

    $notes = if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }

    $policy = [pscustomobject]@{
        SchemaVersion                     = 1
        PolicyId                          = $id
        Name                              = $name
        Objective                         = $objective
        Enabled                           = $enabled
        Weights                           = $w
        Thresholds                        = $t
        TieBreaker                        = @($tie)
        MinimumConfidenceForHistoricalWeight = $minConf
        Notes                             = $notes
    }
    return $policy
}

function Test-RoutingPolicy {
    <#
    .SYNOPSIS
    Deterministic structural validation of a RoutingPolicy v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Policy)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Policy) { return @{ Valid = $false; Errors = @('Policy is null'); Warnings = @() } }
    if ((Get-ContractProperty $Policy 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Policy 'PolicyId' '')) { $errors.Add('PolicyId is required') }
    $objective = [string](Get-ContractProperty $Policy 'Objective' '')
    if (-not $objective) { $errors.Add('Objective is required') }
    elseif ($objective -notin (Get-RoutingPolicyObjectives)) { $errors.Add("Objective '$objective' invalid") }

    $w = Get-ContractProperty $Policy 'Weights' $null
    if ($null -eq $w) { $errors.Add('Weights are required (the ranking engine reads them; nothing is hard-coded)') }
    else {
        $any = $false
        foreach ($wn in Get-RoutingPolicyWeightNames) {
            $v = Get-ContractProperty $w $wn $null
            if ($null -ne $v) {
                if ($v -lt 0 -or $v -gt 1) { $errors.Add("Weight '$wn' must be within 0..1 (found $v)") }
                if ($v -gt 0) { $any = $true }
            }
        }
        if (-not $any) { $errors.Add('Weights must include at least one non-zero weight') }
    }

    $t = Get-ContractProperty $Policy 'Thresholds' $null
    if ($null -ne $t) {
        $mr = Get-ContractProperty $t 'minimumReliability' $null
        if ($null -ne $mr -and ($mr -lt 0 -or $mr -gt 1)) { $errors.Add("Thresholds.minimumReliability must be within 0..1 (found $mr)") }
        $rr = Get-ContractProperty $t 'reasoningReserveTokens' $null
        if ($null -ne $rr -and $rr -lt 0) { $errors.Add('Thresholds.reasoningReserveTokens must be >= 0') }
    }

    $mc = [string](Get-ContractProperty $Policy 'MinimumConfidenceForHistoricalWeight' '')
    if ($mc -and $mc -notin @('INSUFFICIENT','LOW','MODERATE','HIGH')) {
        # confidence vocabulary is DB-M24-owned; keep the router decoupled but honest
        $errors.Add("MinimumConfidenceForHistoricalWeight '$mc' invalid (DB-M24 confidence vocabulary: INSUFFICIENT/LOW/MODERATE/HIGH)")
    }
    $tie = @(Get-ContractProperty $Policy 'TieBreaker' @())
    if ($tie.Count -eq 0) { $errors.Add('TieBreaker must declare a deterministic tie-break chain (non-empty)') }
    $known = @('PolicyScore','EstimatedCost','ReliabilityClass','ModelId','SampleCount')
    foreach ($tb in $tie) {
        if ($tb -notin $known) { $errors.Add("TieBreaker entry '$tb' not supported (supported: $($known -join ', '))") }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# -----------------------------------------------------------------------------
# Default assisted policy -- CHEAPEST_RELIABLE (the DB-M19 default)
# -----------------------------------------------------------------------------
function Get-DefaultRoutingPolicy {
    <#
    .SYNOPSIS
    The default ASSISTED routing policy. Conservative by design:
      - satisfies the hard capability/context/output/budget constraints,
      - prefers candidates with sufficient historical confidence,
      - compares estimated current attempt cost,
      - considers verified cost-per-success when that evidence is reliable,
      - deterministic tie-breakers; never just the absolute cheapest.
    All weights/thresholds are DATA in this policy object, read by the ranker.
    #>
    return New-RoutingPolicy -PolicyId 'routing-policy-cheapest-reliable-v1' -Name 'CHEAPEST_RELIABLE' `
        -Objective 'CHEAPEST_RELIABLE' -Enabled $true `
        -Weights @{ cost = 0.45; success = 0.10; firstAttemptSuccess = 0.05; costPerSuccess = 0.30; latency = 0.0; reliability = 0.10 } `
        -Thresholds @{ minimumReliability = 0.7; reasoningReserveTokens = 0; allowCostUnknown = $true; requireConfirmedProviderHealth = $false } `
        -TieBreaker @('PolicyScore', 'EstimatedCost', 'ReliabilityClass', 'ModelId') `
        -MinimumConfidenceForHistoricalWeight 'LOW' `
        -Notes 'DB-M19 default assisted policy. Conservative: minimum reliability 0.70, historical confidence LOW+, cost and cost-per-success weighted, deterministic tie-breakers.'
}

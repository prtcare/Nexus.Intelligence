# RoutingEligibility.ps1 -- DB-M19 STEP 1 (hard capability/provider/price filter)
# and STEP 2 (context fit).
#
# STEP 1  Get-EligibleAiModels / Test-AiModelCapabilityFit
#   Hard eligibility against the CapabilityRequirement: model + provider enabled,
#   provider available (configured health state -- NO network checks), capability
#   flags, minimum reasoning level, context/output limits, reliability, locality,
#   allowed/disallowed lists, and pricing-coverage (any record / tier record).
#   Every rejection carries a STRUCTURED reason from the DB-M19 vocabulary plus a
#   human-readable detail -- never a bare boolean.
#
# STEP 2  Test-AiRoutingContextFit
#   Usable context vs mandatory context + output/reasoning reserve. If no model
#   fits, the router reports NO_ELIGIBLE_MODEL_CONTEXT -- mandatory governance is
#   never truncated to fit a model.
#
# ADR-005: identifiers are data -- nothing here compares a ProviderId/ModelId to a
# provider/model literal.

. (Join-Path $PSScriptRoot "..\AiRoutingContracts.ps1")   # DB-M14 vocab + helpers (READ-ONLY)
. (Join-Path $PSScriptRoot "RoutingPolicy.ps1")
. (Join-Path $PSScriptRoot "RoutingCandidate.ps1")

# -----------------------------------------------------------------------------
# Defensive array reader (DB-M14 Get-ContractProperty unrolls 1-element arrays).
# Returns a single comma-wrapped array object so the caller can @() it safely.
# -----------------------------------------------------------------------------
function Get-DbM19ArrayValue {
    param(
        [AllowNull()][object]$Object,
        [string]$Name
    )
    $raw = Get-ContractProperty $Object $Name $null
    if ($null -eq $raw) { return @() }
    return @($raw)
}

function Get-DbM19MandatoryContextTokens {
    <#
    .SYNOPSIS
    The mandatory context a candidate must fit: the ContextBudget's mandatory
    section sum when a budget is present, else the requirement's
    RequiredContextTokens. Never falls back to a made-up number; if nothing is
    known, mandatory is $null (no context assertion).
    #>
    param(
        [AllowNull()][object]$Requirement,
        [AllowNull()][object]$ContextBudget,
        [AllowNull()][object]$ContextPackage
    )
    $budget = $ContextBudget
    if ($null -eq $budget) { $budget = $ContextPackage }
    if ($null -ne $budget) {
        $sections = @(Get-ContractProperty $budget 'Sections' @())
        if ($sections.Count -gt 0) {
            $sum = 0L
            $any = $false
            foreach ($section in $sections) {
                $action = [string](Get-ContractProperty $section 'Action' '')
                $tokens = Get-ContractProperty $section 'Tokens' $null
                if ($action -eq 'INCLUDE' -and $null -ne $tokens) { $sum += [long]$tokens; $any = $true }
            }
            if ($any) { return $sum }
            $selected = Get-ContractProperty $budget 'SelectedContextTokens' $null
            if ($null -ne $selected) { return [long]$selected }
        }
        $pkgSelected = Get-ContractProperty $budget 'SelectedContextTokens' $null
        if ($null -ne $pkgSelected) { return [long]$pkgSelected }
    }
    if ($null -ne $Requirement) {
        $req = Get-ContractProperty $Requirement 'RequiredContextTokens' $null
        if ($null -ne $req) { return [long]$req }
    }
    return $null
}

# -----------------------------------------------------------------------------
# STEP 2 -- context fit
# -----------------------------------------------------------------------------
function Test-AiRoutingContextFit {
    <#
    .SYNOPSIS
    STEP 2. Does the model's usable context cover the mandatory context plus the
    output/reasoning reserve? UsableContext = ContextWindow - output reserve.
    Reserve = ExpectedOutputTokens (from the requirement) + policy
    Thresholds.ReasoningReserveTokens. A model that cannot fit is REJECTED for
    context (the router then reports NO_ELIGIBLE_MODEL_CONTEXT rather than
    truncating mandatory governance).
    Returns @{ Fits; UsableContext; MandatoryContextTokens; OutputReserve;
               ContextWindow; Detail }.
    #>
    param(
        [AllowNull()][pscustomobject]$Model,
        [AllowNull()][object]$Requirement,
        [AllowNull()][object]$ContextBudget,
        [AllowNull()][object]$ContextPackage,
        [AllowNull()][pscustomobject]$Policy
    )
    $window = Get-ContractProperty $Model 'ContextWindow' $null
    $expectedOutput = Get-ContractProperty $Requirement 'ExpectedOutputTokens' $null
    $policy = $Policy
    if ($null -eq $policy) { $policy = Get-DefaultRoutingPolicy }
    $thresholds = Get-ContractProperty $policy 'Thresholds' $null
    $reasoningReserve = 0L
    if ($null -ne $thresholds) {
        $rr = Get-ContractProperty $thresholds 'reasoningReserveTokens' $null
        if ($null -ne $rr) { $reasoningReserve = [long]$rr }
    }
    $outputReserve = 0L
    if ($null -ne $expectedOutput) { $outputReserve += [long]$expectedOutput }
    $outputReserve += $reasoningReserve

    $mandatory = Get-DbM19MandatoryContextTokens -Requirement $Requirement -ContextBudget $ContextBudget -ContextPackage $ContextPackage

    $usable = $null
    if ($null -ne $window) { $usable = [long]$window - $outputReserve }
    if ($null -ne $usable -and $usable -lt 0) { $usable = 0 }

    $detail = "usable context = $(if ($null -ne $usable) { $usable } else { 'UNKNOWN' }) tokens (ContextWindow $(if ($null -ne $window) { $window } else { 'UNKNOWN' })) - output/reasoning reserve $outputReserve; mandatory context = $(if ($null -ne $mandatory) { $mandatory } else { 'UNKNOWN' }) tokens"

    $fits = $true
    if ($null -ne $mandatory -and $null -ne $usable -and $mandatory -gt $usable) { $fits = $false }

    return @{
        Fits                  = $fits
        UsableContext         = $usable
        MandatoryContextTokens = $mandatory
        OutputReserve         = $outputReserve
        ContextWindow         = $window
        Detail                = $detail
    }
}

# -----------------------------------------------------------------------------
# STEP 1 -- price coverage helper
# -----------------------------------------------------------------------------
function Get-DbM19PriceCoverage {
    <#
    .SYNOPSIS
    Raw pricing-catalogue coverage for a provider/model route and processing tier.
    Deterministic; reads the effective pricing catalogue only (never the network).
    Returns @{ HasAnyRecord; HasTierRecord; AnyRecordCount; TierRecordCount;
               Tier; Message }.
    #>
    param(
        [AllowNull()][System.Collections.IDictionary]$Pricing,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$ProcessingTier = 'STANDARD'
    )
    $none = @{ HasAnyRecord = $false; HasTierRecord = $false; AnyRecordCount = 0; TierRecordCount = 0; Tier = $ProcessingTier; Message = 'no pricing catalogue' }
    if ($null -eq $Pricing -or $Pricing.Count -eq 0) { return $none }
    $provLower = $ProviderId.Trim().ToLowerInvariant()
    $midLower = $ModelId.Trim().ToLowerInvariant()
    $tier = $ProcessingTier.Trim().ToUpperInvariant()

    $anyRecords = @($Pricing.Values | Where-Object {
        $_.ProviderId -eq $provLower -and $_.ModelId -eq $midLower
    })
    if ($anyRecords.Count -eq 0) {
        return @{ HasAnyRecord = $false; HasTierRecord = $false; AnyRecordCount = 0; TierRecordCount = 0; Tier = $tier; Message = "no price records exist for provider/model route ($provLower/$midLower)" }
    }
    $tierRecords = @($anyRecords | Where-Object { $_.ProcessingTier -eq $tier })
    if ($tierRecords.Count -eq 0) {
        return @{ HasAnyRecord = $true; HasTierRecord = $false; AnyRecordCount = $anyRecords.Count; TierRecordCount = 0; Tier = $tier; Message = "price records exist for the route but none for processing tier '$tier'" }
    }
    return @{ HasAnyRecord = $true; HasTierRecord = $true; AnyRecordCount = $anyRecords.Count; TierRecordCount = $tierRecords.Count; Tier = $tier; Message = "price records exist for the route and tier '$tier'" }
}

# -----------------------------------------------------------------------------
# STEP 1 -- single-model capability fit
# -----------------------------------------------------------------------------
function Test-AiModelCapabilityFit {
    <#
    .SYNOPSIS
    STEP 1 hard eligibility for ONE model route against the CapabilityRequirement.
    Consumes configured/current provider health only (NO network checks). Every
    failing check appends a structured RejectionReason (vocabulary member) with a
    human-readable detail. A passing model also reports the minimum normalized
    reasoning level it would be selected at.
    Returns @{ Fits; Eligible; Model; Provider; ProviderId; ModelId;
               GatewayProviderId; UnderlyingModelId; SelectedReasoningLevel;
               RejectionReasons; FirstReason; Warnings }.
    #>
    param(
        [AllowNull()][pscustomobject]$Model,
        [AllowNull()][pscustomobject]$Provider,
        [AllowNull()][object]$Requirement,
        [AllowNull()][System.Collections.IDictionary]$Pricing,
        [AllowNull()][System.Collections.IDictionary]$ProviderHealth,
        [AllowNull()][pscustomobject]$Policy,
        [string]$ProcessingTier = 'STANDARD',
        [AllowNull()]$TimestampUtc
    )
    $req = $Requirement
    $policy = $Policy
    if ($null -eq $policy) { $policy = Get-DefaultRoutingPolicy }
    $thresholds = Get-ContractProperty $policy 'Thresholds' $null
    $reqHealth = $false
    if ($null -ne $thresholds) {
        $reqHealth = [bool](Get-ContractProperty $thresholds 'requireConfirmedProviderHealth' $false)
    }

    $reasons = New-Object System.Collections.Generic.List[object]

    $modelId = Get-ContractProperty $Model 'ModelId' ''
    $providerId = Get-ContractProperty $Model 'ProviderId' ''
    $underlyingId = Get-ContractProperty $Model 'UnderlyingModelId' $null
    $gatewayId = Get-ContractProperty $Model 'GatewayProviderId' $null

    # ---- provider resolution --------------------------------------------------
    $prov = $Provider
    if ($null -eq $prov) {
        $reasons.Add([pscustomobject]@{ Reason = 'PROVIDER_UNAVAILABLE'; Detail = "provider '$providerId' is not in the providers catalogue (missing provider reference)" })
    } else {
        $provEnabled = Get-ContractProperty $prov 'Enabled' $false
        if ($provEnabled -ne $true) {
            $reasons.Add([pscustomobject]@{ Reason = 'PROVIDER_DISABLED'; Detail = "provider '$providerId' is disabled" })
        }
    }

    # ---- model enabled ----------------------------------------------------------
    $modelEnabled = Get-ContractProperty $Model 'Enabled' $false
    if ($modelEnabled -ne $true) {
        $reasons.Add([pscustomobject]@{ Reason = 'MODEL_DISABLED'; Detail = "model '$modelId' (provider '$providerId') is disabled" })
    }

    # ---- provider health (configured state only; no network) --------------------
    $healthKey = $providerId.Trim().ToLowerInvariant()
    $health = $null
    if ($null -ne $ProviderHealth -and $ProviderHealth.Contains($healthKey)) {
        $health = [string]$ProviderHealth[$healthKey]
    } else {
        $health = 'UNKNOWN'
    }
    if ($health -in @('UNAVAILABLE', 'DISABLED', 'AUTH_ERROR')) {
        $reasons.Add([pscustomobject]@{ Reason = 'PROVIDER_UNAVAILABLE'; Detail = "provider '$providerId' health is $health (unavailable for routing)" })
    } elseif ($reqHealth) {
        if ($health -ne 'AVAILABLE') {
            $reasons.Add([pscustomobject]@{ Reason = 'PROVIDER_UNAVAILABLE'; Detail = "policy requires confirmed provider availability; provider '$providerId' health is $health" })
        }
    }

    # ---- locality --------------------------------------------------------------
    $localOrRemote = [string](Get-ContractProperty $Model 'LocalOrRemote' '')
    $localAllowed = Get-ContractProperty $req 'LocalAllowed' $null
    $remoteAllowed = Get-ContractProperty $req 'RemoteAllowed' $null
    if ($localAllowed -eq $false -and $localOrRemote -eq 'LOCAL') {
        $reasons.Add([pscustomobject]@{ Reason = 'LOCALITY_CONFLICT'; Detail = "local models are not allowed (LocalAllowed=false) and '$modelId' is LOCAL" })
    }
    if ($remoteAllowed -eq $false -and $localOrRemote -eq 'REMOTE') {
        $reasons.Add([pscustomobject]@{ Reason = 'LOCALITY_CONFLICT'; Detail = "remote models are not allowed (RemoteAllowed=false) and '$modelId' is REMOTE" })
    }

    # ---- allowed / disallowed lists ---------------------------------------------
    $allowedModels = @(Get-DbM19ArrayValue $req 'AllowedModels')
    $disallowedModels = @(Get-DbM19ArrayValue $req 'DisallowedModels')
    $allowedProviders = @(Get-DbM19ArrayValue $req 'AllowedProviders')
    $disallowedProviders = @(Get-DbM19ArrayValue $req 'DisallowedProviders')

    $modelIdsToCheck = @($modelId)
    if ($underlyingId) { $modelIdsToCheck += $underlyingId }
    if ($disallowedProviders.Count -gt 0 -and $providerId -in $disallowedProviders) {
        $reasons.Add([pscustomobject]@{ Reason = 'PROVIDER_DISALLOWED'; Detail = "provider '$providerId' is in DisallowedProviders" })
    }
    if ($allowedProviders.Count -gt 0 -and $providerId -notin $allowedProviders) {
        $reasons.Add([pscustomobject]@{ Reason = 'PROVIDER_DISALLOWED'; Detail = "provider '$providerId' is not in AllowedProviders" })
    }
    foreach ($mid in $modelIdsToCheck) {
        if ($disallowedModels.Count -gt 0 -and $mid -in $disallowedModels) {
            $reasons.Add([pscustomobject]@{ Reason = 'MODEL_DISALLOWED'; Detail = "model '$mid' is in DisallowedModels" })
            break
        }
    }
    if ($allowedModels.Count -gt 0) {
        $found = $false
        foreach ($mid in $modelIdsToCheck) { if ($mid -in $allowedModels) { $found = $true; break } }
        if (-not $found) {
            $reasons.Add([pscustomobject]@{ Reason = 'MODEL_DISALLOWED'; Detail = "model '$modelId' (and underlying) not in AllowedModels" })
        }
    }

    # ---- capability flags ----------------------------------------------------------
    if ((Get-ContractProperty $req 'RequiresCoding' $null) -eq $true) {
        if ((Get-ContractProperty $Model 'SupportsCoding' $null) -ne $true) {
            $reasons.Add([pscustomobject]@{ Reason = 'CAPABILITY_CODING_MISSING'; Detail = "requirement RequiresCoding but model '$modelId' does not support coding" })
        }
    }
    if ((Get-ContractProperty $req 'RequiresVision' $null) -eq $true) {
        if ((Get-ContractProperty $Model 'SupportsVision' $null) -ne $true) {
            $reasons.Add([pscustomobject]@{ Reason = 'CAPABILITY_VISION_MISSING'; Detail = "requirement RequiresVision but model '$modelId' does not support vision" })
        }
    }
    if ((Get-ContractProperty $req 'RequiresToolUse' $null) -eq $true) {
        if ((Get-ContractProperty $Model 'SupportsToolUse' $null) -ne $true) {
            $reasons.Add([pscustomobject]@{ Reason = 'CAPABILITY_TOOL_USE_MISSING'; Detail = "requirement RequiresToolUse but model '$modelId' does not support tool use" })
        }
    }
    if ((Get-ContractProperty $req 'RequiresStructuredOutput' $null) -eq $true) {
        if ((Get-ContractProperty $Model 'SupportsStructuredOutput' $null) -ne $true) {
            $reasons.Add([pscustomobject]@{ Reason = 'STRUCTURED_OUTPUT_MISSING'; Detail = "requirement RequiresStructuredOutput but model '$modelId' does not support structured output" })
        }
    }

    # ---- reasoning --------------------------------------------------------------
    $requiresReasoning = Get-ContractProperty $req 'RequiresReasoning' $null
    $minReasoning = Get-ContractProperty $req 'MinimumReasoningLevel' $null
    $supportsReasoning = Get-ContractProperty $Model 'SupportsReasoning' $null
    $supportedLevels = @(Get-DbM19ArrayValue $Model 'ReasoningLevelsSupported')
    $reasoningCapable = ($supportsReasoning -eq $true -or $supportedLevels.Count -gt 0)
    if ($requiresReasoning -eq $true -and -not $reasoningCapable) {
        $reasons.Add([pscustomobject]@{ Reason = 'REASONING_LEVEL_INSUFFICIENT'; Detail = "requirement RequiresReasoning but model '$modelId' asserts no reasoning capability and no normalized reasoning levels" })
    }
    if ($minReasoning -and $minReasoning -ne 'NONE') {
        $order = Get-AiRoutingReasoningOrder
        $reqIdx = [int]$order[$minReasoning]
        $maxIdx = 0
        foreach ($lvl in $supportedLevels) {
            $li = [int]$order[$lvl]
            if ($li -gt $maxIdx) { $maxIdx = $li }
        }
        if ($maxIdx -lt $reqIdx) {
            $reasons.Add([pscustomobject]@{ Reason = 'REASONING_LEVEL_INSUFFICIENT'; Detail = "requirement MinimumReasoningLevel=$minReasoning but model '$modelId' max supported reasoning is $(if ($supportedLevels.Count -eq 0) { 'none asserted' } else { $supportedLevels -join '/' })" })
        }
    }

    # ---- context / output limits ---------------------------------------------------
    $requiredContext = Get-ContractProperty $req 'RequiredContextTokens' $null
    $contextWindow = Get-ContractProperty $Model 'ContextWindow' $null
    if ($null -ne $requiredContext -and $null -ne $contextWindow -and $contextWindow -lt $requiredContext) {
        $reasons.Add([pscustomobject]@{ Reason = 'CONTEXT_TOO_SMALL'; Detail = "ContextWindow $contextWindow < RequiredContextTokens $requiredContext" })
    }
    $expectedOutput = Get-ContractProperty $req 'ExpectedOutputTokens' $null
    $maxOutput = Get-ContractProperty $Model 'MaxOutputTokens' $null
    if ($null -ne $expectedOutput -and $null -ne $maxOutput -and $maxOutput -lt $expectedOutput) {
        $reasons.Add([pscustomobject]@{ Reason = 'OUTPUT_LIMIT_TOO_SMALL'; Detail = "MaxOutputTokens $maxOutput < ExpectedOutputTokens $expectedOutput" })
    }

    # ---- reliability ---------------------------------------------------------------
    $requiredReliability = Get-ContractProperty $req 'RequiredReliability' $null
    if ($requiredReliability) {
        $order = Get-AiRoutingReliabilityOrder
        $reqRelIdx = [int]$order[$requiredReliability]
        $modelRel = Get-ContractProperty $Model 'ReliabilityClass' $null
        $modelRelIdx = if ($modelRel -and $order.ContainsKey($modelRel)) { [int]$order[$modelRel] } else { 0 }
        if ($modelRelIdx -lt $reqRelIdx) {
            $reasons.Add([pscustomobject]@{ Reason = 'RELIABILITY_TOO_LOW'; Detail = "required reliability '$requiredReliability' but model '$modelId' ReliabilityClass is '$(if ($modelRel) { $modelRel } else { 'none asserted' })'" })
        }
    }

    # ---- pricing coverage ---------------------------------------------------------------
    $coverage = Get-DbM19PriceCoverage -Pricing $Pricing -ProviderId $providerId -ModelId $modelId -ProcessingTier $ProcessingTier
    if (-not $coverage.HasAnyRecord) {
        $reasons.Add([pscustomobject]@{ Reason = 'PRICE_UNAVAILABLE'; Detail = $coverage.Message })
    } elseif (-not $coverage.HasTierRecord) {
        $reasons.Add([pscustomobject]@{ Reason = 'PROCESSING_TIER_UNSUPPORTED'; Detail = $coverage.Message })
    }

    # ---- selected reasoning level (minimum satisfying the requirement) ----------------
    $selected = Get-DbM19SelectedReasoningLevel -Requirement $req -Model $Model

    # deterministic ordering of reasons by vocabulary position
    $reasonOrder = Get-DbM19RejectionReasons
    $ordered = @($reasons | Sort-Object -Property @{ Expression = { $idx = [array]::IndexOf($reasonOrder, $_.Reason); if ($idx -lt 0) { 9999 } else { $idx } }; Ascending = $true })

    $fits = ($ordered.Count -eq 0)
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($fits) {
        if ($health -notin @('AVAILABLE')) {
            $warnings.Add("provider '$providerId' health is '$health' (not confirmed AVAILABLE); routed on current configured state")
        }
        if (-not $coverage.HasTierRecord -or -not $coverage.HasAnyRecord) {
            # cannot happen when fits (price gates reject); defensive only
            $warnings.Add("price coverage state: $($coverage.Message)")
        }
    }

    return @{
        Fits                     = $fits
        Eligible                 = $fits
        Model                    = $Model
        Provider                 = $prov
        ProviderId               = $providerId
        ModelId                  = $modelId
        GatewayProviderId        = $gatewayId
        UnderlyingModelId        = $underlyingId
        SelectedReasoningLevel   = $selected
        RejectionReasons         = @($ordered)
        FirstReason              = if ($ordered.Count -gt 0) { $ordered[0].Reason } else { $null }
        Warnings                 = @($warnings)
        PriceCoverage            = $coverage
    }
}

function Get-DbM19SelectedReasoningLevel {
    <#
    .SYNOPSIS
    Minimum normalized reasoning level that satisfies the requirement for this
    model: the smallest supported level >= the required level. Never auto-MAX;
    when the model asserts no normalized levels the required level is returned
    (STEP 1 already rejected unverifiable minimums).
    #>
    param(
        [AllowNull()][object]$Requirement,
        [AllowNull()][pscustomobject]$Model
    )
    $req = $Requirement
    $required = Get-ContractProperty $req 'MinimumReasoningLevel' $null
    if (-not $required) {
        $needs = Get-ContractProperty $req 'RequiresReasoning' $null
        $required = if ($needs -eq $true) { 'MEDIUM' } else { 'NONE' }
    }
    $levels = @(Get-DbM19ArrayValue $Model 'ReasoningLevelsSupported')
    if ($levels.Count -eq 0) { return $required }
    $order = Get-AiRoutingReasoningOrder
    $reqIdx = [int]$order[$required]
    $best = $null
    $bestIdx = [int]::MaxValue
    foreach ($lvl in $levels) {
        $li = [int]$order[$lvl]
        if ($li -ge $reqIdx -and $li -lt $bestIdx) { $bestIdx = $li; $best = $lvl }
    }
    if ($null -eq $best) { return $required }  # STEP 1 would have rejected; keep honest
    return $best
}

# -----------------------------------------------------------------------------
# STEP 1 -- eligible model set (deterministic iteration)
# -----------------------------------------------------------------------------
function Get-EligibleAiModels {
    <#
    .SYNOPSIS
    STEP 1 for the whole catalogue. Deterministically iterates the model catalogue
    (sorted by ModelId/ProviderId/GatewayProviderId) and splits it into:
      Eligible  -- model records that passed hard constraints (with their selected
                  reasoning level and price coverage),
      Rejected  -- one row per model route: Model, ProviderId, ModelId,
                  GatewayProviderId, UnderlyingModelId, RejectionReasons
                  (structured vocabulary + detail), FirstReason.
    No candidate is silently dropped: every rejected route carries its reasons.
    #>
    param(
        [AllowNull()][System.Collections.IDictionary]$Catalogue,
        [AllowNull()][System.Collections.IDictionary]$Providers,
        [AllowNull()][object]$Requirement,
        [AllowNull()][System.Collections.IDictionary]$Pricing,
        [AllowNull()][System.Collections.IDictionary]$ProviderHealth,
        [AllowNull()][pscustomobject]$Policy,
        [string]$ProcessingTier = 'STANDARD',
        [AllowNull()]$TimestampUtc
    )
    $models = @()
    if ($null -ne $Catalogue) {
        $models = @($Catalogue.Values | Sort-Object -Property `
            @{ Expression = { [string](Get-ContractProperty $_ 'ModelId' '') }; Ascending = $true }, `
            @{ Expression = { [string](Get-ContractProperty $_ 'ProviderId' '') }; Ascending = $true }, `
            @{ Expression = { [string](Get-ContractProperty $_ 'GatewayProviderId' '') }; Ascending = $true })
    }

    $eligible = New-Object System.Collections.Generic.List[object]
    $rejected = New-Object System.Collections.Generic.List[object]

    foreach ($model in $models) {
        $providerId = Get-ContractProperty $model 'ProviderId' ''
        $provider = $null
        $provKey = $providerId.Trim().ToLowerInvariant()
        if ($null -ne $Providers -and $Providers.Contains($provKey)) {
            $provider = $Providers[$provKey]
        }
        $fit = Test-AiModelCapabilityFit -Model $model -Provider $provider -Requirement $Requirement `
            -Pricing $Pricing -ProviderHealth $ProviderHealth -Policy $Policy `
            -ProcessingTier $ProcessingTier -TimestampUtc $TimestampUtc

        if ($fit.Fits) {
            $null = $eligible.Add($model)
        } else {
            $null = $rejected.Add([pscustomobject]@{
                Model              = $model
                ProviderId         = $fit.ProviderId
                ModelId            = $fit.ModelId
                GatewayProviderId  = $fit.GatewayProviderId
                UnderlyingModelId  = $fit.UnderlyingModelId
                RejectionReasons   = @($fit.RejectionReasons)
                FirstReason        = $fit.FirstReason
            })
        }
    }

    return @{
        Eligible = @($eligible.ToArray())
        Rejected = @($rejected.ToArray())
        EligibleCount = $eligible.Count
        RejectedCount = $rejected.Count
    }
}

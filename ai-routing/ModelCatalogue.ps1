# ModelCatalogue.ps1 — DB-M14 model identity + capability catalogue.
#
# Provider identity and underlying-model identity are SEPARABLE: the same
# underlying model reachable through different gateways is represented as
# distinct delivery routes (ProviderModelId/GatewayProviderId), never as
# different underlying models.
#
# Capability metadata describes WHAT a model can do. No routing policy, no
# pricing, no provider-name branching lives here. DB-M19 decides routing.
#
# Dot-source AiRoutingContracts.ps1 and AiProvider.ps1 first.

function New-AiModel {
    <#
    .SYNOPSIS
    Build a normalized model record (schemaVersion 1). Capability fields that are
    not provided are null = UNKNOWN (never guessed). False means definitively
    unsupported. Enabled defaults to false.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$ModelId,
        [string]$ProviderId,
        [string]$ProviderModelId,
        [string]$UnderlyingModelId,
        [string]$GatewayProviderId,
        [string]$DisplayName,
        [bool]$Enabled = $false,
        [string]$ModelFamily,
        [string]$ModelVersion,
        [string]$LocalOrRemote,
        [string]$EndpointOverride,
        [string]$EffectiveFrom,
        [string]$EffectiveTo,
        [Nullable[bool]]$SupportsCoding,
        [Nullable[bool]]$SupportsReasoning,
        [Nullable[bool]]$SupportsVision,
        [Nullable[bool]]$SupportsToolUse,
        [Nullable[bool]]$SupportsStructuredOutput,
        [Nullable[bool]]$SupportsPromptCaching,
        [Nullable[bool]]$SupportsBatch,
        [Nullable[bool]]$SupportsStreaming,
        [Nullable[long]]$ContextWindow,
        [Nullable[long]]$MaxOutputTokens,
        [string[]]$ReasoningLevelsSupported,
        [string]$RelativeSpeed,
        [string]$ReliabilityClass,
        [string[]]$AdditionalCapabilityTags,
        [string]$Notes
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }

    $id = if ($InputObject) { & $g 'ModelId' $ModelId } else { $ModelId }
    if (-not $id) { throw "New-AiModel: ModelId is required" }
    $id = $id.Trim().ToLowerInvariant()

    $providerId = if ($InputObject) { & $g 'ProviderId' $ProviderId } else { $ProviderId }
    if (-not $providerId) { throw "New-AiModel: ProviderId is required" }

    $providerModelId = if ($InputObject) { & $g 'ProviderModelId' $ProviderModelId } else { $ProviderModelId }
    if (-not $providerModelId) { $providerModelId = $id }

    $underlying = if ($InputObject) { & $g 'UnderlyingModelId' $UnderlyingModelId } else { $UnderlyingModelId }
    if (-not $underlying) { $underlying = $id }   # a model is its own underlying model unless a gateway says otherwise

    $gateway = if ($InputObject) { & $g 'GatewayProviderId' $GatewayProviderId } else { $GatewayProviderId }
    $display = if ($InputObject) { & $g 'DisplayName' $DisplayName } else { $DisplayName }
    if (-not $display) { $display = $id }

    $enabled    = if ($InputObject) { [bool](& $g 'Enabled' $Enabled) } else { $Enabled }
    $family     = if ($InputObject) { & $g 'ModelFamily' $ModelFamily } else { $ModelFamily }
    $version    = if ($InputObject) { & $g 'ModelVersion' $ModelVersion } else { $ModelVersion }
    $lor        = if ($InputObject) { & $g 'LocalOrRemote' $LocalOrRemote } else { $LocalOrRemote }
    $endpoint   = if ($InputObject) { & $g 'EndpointOverride' $EndpointOverride } else { $EndpointOverride }
    $effFrom    = if ($InputObject) { & $g 'EffectiveFrom' $EffectiveFrom } else { $EffectiveFrom }
    $effTo      = if ($InputObject) { & $g 'EffectiveTo' $EffectiveTo } else { $EffectiveTo }

    $cCoding    = if ($InputObject) { & $g 'SupportsCoding' $SupportsCoding } else { $SupportsCoding }
    $cReason    = if ($InputObject) { & $g 'SupportsReasoning' $SupportsReasoning } else { $SupportsReasoning }
    $cVision    = if ($InputObject) { & $g 'SupportsVision' $SupportsVision } else { $SupportsVision }
    $cTool      = if ($InputObject) { & $g 'SupportsToolUse' $SupportsToolUse } else { $SupportsToolUse }
    $cStructured= if ($InputObject) { & $g 'SupportsStructuredOutput' $SupportsStructuredOutput } else { $SupportsStructuredOutput }
    $cCaching   = if ($InputObject) { & $g 'SupportsPromptCaching' $SupportsPromptCaching } else { $SupportsPromptCaching }
    $cBatch     = if ($InputObject) { & $g 'SupportsBatch' $SupportsBatch } else { $SupportsBatch }
    $cStream    = if ($InputObject) { & $g 'SupportsStreaming' $SupportsStreaming } else { $SupportsStreaming }
    $ctxWin     = if ($InputObject) { & $g 'ContextWindow' $ContextWindow } else { $ContextWindow }
    $maxOut     = if ($InputObject) { & $g 'MaxOutputTokens' $MaxOutputTokens } else { $MaxOutputTokens }
    $reasonLvls = if ($InputObject) { & $g 'ReasoningLevelsSupported' $ReasoningLevelsSupported } else { $ReasoningLevelsSupported }
    $speed      = if ($InputObject) { & $g 'RelativeSpeed' $RelativeSpeed } else { $RelativeSpeed }
    $reliab     = if ($InputObject) { & $g 'ReliabilityClass' $ReliabilityClass } else { $ReliabilityClass }
    $tags       = if ($InputObject) { & $g 'AdditionalCapabilityTags' $AdditionalCapabilityTags } else { $AdditionalCapabilityTags }
    $notes      = if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }

    # normalize list fields: null/absent -> empty array (a single string stays an array of one)
    if ($null -eq $reasonLvls) { $reasonLvls = @() } else { $reasonLvls = @($reasonLvls) }
    if ($null -eq $tags) { $tags = @() } else { $tags = @($tags) }

    $model = [pscustomobject]@{
        SchemaVersion            = 1
        ModelId                  = $id
        ProviderId               = $providerId.Trim().ToLowerInvariant()
        ProviderModelId          = $providerModelId
        UnderlyingModelId        = $underlying
        GatewayProviderId        = $gateway
        DisplayName              = $display
        Enabled                  = $enabled
        ModelFamily              = $family
        ModelVersion             = $version
        LocalOrRemote            = $lor
        EndpointOverride         = $endpoint
        EffectiveFrom            = $effFrom
        EffectiveTo              = $effTo
        SupportsCoding           = $cCoding
        SupportsReasoning        = $cReason
        SupportsVision           = $cVision
        SupportsToolUse          = $cTool
        SupportsStructuredOutput = $cStructured
        SupportsPromptCaching    = $cCaching
        SupportsBatch            = $cBatch
        SupportsStreaming        = $cStream
        ContextWindow            = $ctxWin
        MaxOutputTokens          = $maxOut
        ReasoningLevelsSupported = @($reasonLvls)
        RelativeSpeed            = $speed
        ReliabilityClass         = $reliab
        AdditionalCapabilityTags = @($tags)
        Notes                    = $notes
    }
    return $model
}

function Test-AiModel {
    <#
    .SYNOPSIS
    Validate a model record. Uses defensive property reads so hand-crafted
    records validate deterministically under Set-StrictMode.
    #>
    param([pscustomobject]$Model)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Model) { return @{ Valid = $false; Errors = @('Model is null') } }
    if (-not (Get-ContractProperty $Model 'ModelId' '')) { $errors.Add('ModelId required') }
    if (-not (Get-ContractProperty $Model 'ProviderId' '')) { $errors.Add('ProviderId required') }
    if ((Get-ContractProperty $Model 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    $ctx = Get-ContractProperty $Model 'ContextWindow' $null
    if ($null -ne $ctx -and $ctx -le 0) { $errors.Add('ContextWindow must be positive when present') }
    $maxOut = Get-ContractProperty $Model 'MaxOutputTokens' $null
    if ($null -ne $maxOut -and $maxOut -le 0) { $errors.Add('MaxOutputTokens must be positive when present') }
    foreach ($lvl in @(Get-ContractProperty $Model 'ReasoningLevelsSupported' @())) {
        if ($lvl -and -not (Test-IsValidReasoningLevel $lvl)) { $errors.Add("ReasoningLevelsSupported contains invalid level '$lvl'") }
    }
    $speed = Get-ContractProperty $Model 'RelativeSpeed' $null
    if ($speed -and -not (Test-IsValidRelativeSpeed $speed)) { $errors.Add("RelativeSpeed '$speed' invalid") }
    $rel = Get-ContractProperty $Model 'ReliabilityClass' $null
    if ($rel -and -not (Test-IsValidReliabilityClass $rel)) { $errors.Add("ReliabilityClass '$rel' invalid") }
    $lor = Get-ContractProperty $Model 'LocalOrRemote' $null
    if ($lor -and -not (Test-IsValidLocalOrRemote $lor)) { $errors.Add("LocalOrRemote '$lor' invalid") }
    $endpoint = Get-ContractProperty $Model 'EndpointOverride' $null
    if ($endpoint -and $endpoint -notmatch '^[a-z0-9]+://') { $errors.Add("EndpointOverride '$endpoint' must be a URI") }
    $effFrom = Get-ContractProperty $Model 'EffectiveFrom' $null
    $effTo = Get-ContractProperty $Model 'EffectiveTo' $null
    if ($effFrom -and $effTo) {
        $d1 = [datetime]::MinValue; $d2 = [datetime]::MinValue
        $ok1 = [datetime]::TryParse($effFrom, [ref]$d1)
        $ok2 = [datetime]::TryParse($effTo, [ref]$d2)
        if (-not ($ok1 -and $ok2)) { $errors.Add('EffectiveFrom/EffectiveTo must be parseable dates') }
        elseif ($d1 -gt $d2) { $errors.Add('EffectiveFrom must be <= EffectiveTo') }
    }
    $leak = Test-AiRoutingSecretValueLeak $Model
    if ($leak.Leak) { $errors.Add('secret value detected in model record') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}

# --- catalogue operations -----------------------------------------------------------

function Add-AiModel {
    param(
        [System.Collections.IDictionary]$Catalogue,
        [pscustomobject]$Model
    )
    $t = Test-AiModel $Model
    if (-not $t.Valid) { throw "Add-AiModel: invalid model '$($Model.ModelId)': $($t.Errors -join '; ')" }
    if ($Catalogue.ContainsKey($Model.ModelId)) {
        throw "Add-AiModel: duplicate ModelId '$($Model.ModelId)'"
    }
    $Catalogue[$Model.ModelId] = $Model
    return $Catalogue[$Model.ModelId]
}

function Get-AiModel {
    param([System.Collections.IDictionary]$Catalogue, [string]$ModelId)
    if (-not $ModelId) { return $null }
    $key = $ModelId.Trim().ToLowerInvariant()
    if ($Catalogue -and $Catalogue.ContainsKey($key)) { return $Catalogue[$key] }
    return $null
}

function Get-AiModels {
    param([System.Collections.IDictionary]$Catalogue)
    if (-not $Catalogue) { return @() }
    return @($Catalogue.Values)
}

function Get-AiEnabledModels {
    param([System.Collections.IDictionary]$Catalogue)
    if (-not $Catalogue) { return @() }
    return @($Catalogue.Values | Where-Object { $_.Enabled })
}

function Find-AiModelByProvider {
    param([System.Collections.IDictionary]$Catalogue, [string]$ProviderId)
    if (-not $Catalogue) { return @() }
    $pid = $ProviderId.Trim().ToLowerInvariant()
    return @($Catalogue.Values | Where-Object { $_.ProviderId -eq $pid })
}

function Find-AiModelByUnderlyingModel {
    <#
    .SYNOPSIS
    Find every delivery route for the same underlying model (direct provider +
    gateway routes). Proves provider/underlying identity separation.
    #>
    param([System.Collections.IDictionary]$Catalogue, [string]$UnderlyingModelId)
    if (-not $Catalogue) { return @() }
    return @($Catalogue.Values | Where-Object { $_.UnderlyingModelId -eq $UnderlyingModelId })
}

# --- capability query (filtering only, NOT routing) --------------------------------

function Find-AiModelByCapability {
    <#
    .SYNOPSIS
    Return eligible models for a capability requirement. This is capability
    FILTERING - it returns candidates, never a winner. No pricing, no scoring,
    no routing decision (DB-M19).
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [System.Collections.IDictionary]$Providers,
        [pscustomobject]$Requirement,
        [System.Collections.IDictionary]$ProviderHealth,
        [switch]$IncludeDisabled
    )
    if (-not $Catalogue) { return @() }
    $eligible = @()
    $reasonOrder = Get-AiRoutingReasoningOrder
    $speedOrder = Get-AiRoutingSpeedOrder
    $relOrder = Get-AiRoutingReliabilityOrder
    $rejectHealth = @('UNAVAILABLE', 'DISABLED', 'AUTH_ERROR')

    foreach ($m in $Catalogue.Values) {
        $ok = $true
        if (-not $m.Enabled -and -not $IncludeDisabled) { $ok = $false }
        if ($ok -and $Providers) {
            if ($Providers.ContainsKey($m.ProviderId)) {
                if (-not $Providers[$m.ProviderId].Enabled -and -not $IncludeDisabled) { $ok = $false }
            } else { $ok = $false }
        }
        if ($ok -and $ProviderHealth) {
            $h = $ProviderHealth[$m.ProviderId]
            if ($h -in $rejectHealth) { $ok = $false }
        }
        if ($ok -and $Requirement) {
            $r = $Requirement
            if ($r.AllowedProviders -and ($r.AllowedProviders -notcontains $m.ProviderId)) { $ok = $false }
            if ($ok -and $r.DisallowedProviders -and ($r.DisallowedProviders -contains $m.ProviderId)) { $ok = $false }
            if ($ok -and $r.AllowedModels -and ($r.AllowedModels -notcontains $m.ModelId)) { $ok = $false }
            if ($ok -and $r.DisallowedModels -and ($r.DisallowedModels -contains $m.ModelId)) { $ok = $false }

            if ($ok -and $r.RequiresCoding -and ($m.SupportsCoding -ne $true)) { $ok = $false }
            if ($ok -and $r.RequiresVision -and ($m.SupportsVision -ne $true)) { $ok = $false }
            if ($ok -and $r.RequiresToolUse -and ($m.SupportsToolUse -ne $true)) { $ok = $false }
            if ($ok -and $r.RequiresStructuredOutput -and ($m.SupportsStructuredOutput -ne $true)) { $ok = $false }
            if ($ok -and $r.RequiresReasoning) {
                $reasoningCapable = ($m.SupportsReasoning -eq $true) -or (@($m.ReasoningLevelsSupported).Count -gt 0)
                if (-not $reasoningCapable) { $ok = $false }
            }
            if ($ok -and $r.MinimumReasoningLevel) {
                $levels = @($m.ReasoningLevelsSupported)
                if ($levels.Count -eq 0) { $ok = $false }
                else {
                    $reqIdx = $reasonOrder[$r.MinimumReasoningLevel]
                    $maxIdx = 0
                    foreach ($lvl in $levels) { $i = $reasonOrder[$lvl]; if ($i -gt $maxIdx) { $maxIdx = $i } }
                    if ($maxIdx -lt $reqIdx) { $ok = $false }
                }
            }
            if ($ok -and $r.RequiredContextTokens) {
                if ($null -eq $m.ContextWindow -or $m.ContextWindow -lt $r.RequiredContextTokens) { $ok = $false }
            }
            if ($ok -and $r.ExpectedOutputTokens) {
                if ($null -eq $m.MaxOutputTokens -or $m.MaxOutputTokens -lt $r.ExpectedOutputTokens) { $ok = $false }
            }
            if ($ok -and $r.RequiredReliability) {
                $reqIdx = $relOrder[$r.RequiredReliability]
                $mIdx = if ($m.ReliabilityClass) { $relOrder[$m.ReliabilityClass] } else { 0 }
                if ($mIdx -lt $reqIdx) { $ok = $false }
            }
            if ($ok -and $r.PreferredLatency) {
                $reqIdx = $speedOrder[$r.PreferredLatency]
                $mIdx = if ($m.RelativeSpeed) { $speedOrder[$m.RelativeSpeed] } else { 0 }
                if ($mIdx -eq 0 -or $mIdx -gt $reqIdx) { $ok = $false }
            }
            if ($ok -and $r.LocalAllowed -eq $false -and $m.LocalOrRemote -eq 'LOCAL') { $ok = $false }
            if ($ok -and $r.RemoteAllowed -eq $false -and $m.LocalOrRemote -eq 'REMOTE') { $ok = $false }
        }
        if ($ok) { $eligible += $m }
    }
    return @($eligible)
}

# --- catalogue validation -----------------------------------------------------------

function Validate-AiModelCatalogue {
    <#
    .SYNOPSIS
    Validate a model catalogue, optionally cross-checked against a provider
    catalogue (provider reference resolution, duplicate ProviderModelId).
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [System.Collections.IDictionary]$Providers
    )
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Catalogue) { $errors.Add('Catalogue is null'); return @{ Valid = $false; Errors = @($errors) } }

    foreach ($key in $Catalogue.Keys) {
        $m = $Catalogue[$key]
        if ($m.ModelId -ne $key) { $errors.Add("Catalogue key '$key' does not match record ModelId '$($m.ModelId)'") }
        $t = Test-AiModel $m
        if (-not $t.Valid) { $errors.Add("Model '$key': $($t.Errors -join '; ')") }
        if ($Providers -and -not $Providers.ContainsKey($m.ProviderId)) {
            $errors.Add("Model '$key' references unknown provider '$($m.ProviderId)'")
        }
    }

    # duplicate ProviderModelId within the same provider (semantics prohibit it)
    if ($Catalogue.Count -gt 1) {
        $groups = @{}
        foreach ($key in $Catalogue.Keys) {
            $m = $Catalogue[$key]
            if (-not $m.ProviderModelId) { continue }
            $gKey = "$($m.ProviderId)::$($m.ProviderModelId)"
            if ($groups.ContainsKey($gKey)) { $errors.Add("Duplicate ProviderModelId '$($m.ProviderModelId)' for provider '$($m.ProviderId)' (models '$($groups[$gKey])' and '$key')") }
            else { $groups[$gKey] = $key }
        }
    }

    $leak = Test-AiRoutingSecretValueLeak $Catalogue
    if ($leak.Leak) { $errors.Add('secret value detected in model catalogue') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}

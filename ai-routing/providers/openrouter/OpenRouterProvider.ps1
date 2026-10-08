# OpenRouterProvider.ps1 -- DB-M23 OpenRouter gateway/provider route adapter.
#
# OpenRouter is a GATEWAY (a provider ROUTE), never a model. Gateway identity is
# distinct from model identity: GatewayProviderId=openrouter, UnderlyingModelId is
# the model part of the route (after the last '/' separator).
#
#   - New-OpenRouterProviderConfiguration : provider record (ProviderType=GATEWAY,
#     GatewayType=OPENROUTER) + ApiKeyReference (an env-var NAME, never a value).
#   - Test-OpenRouterProviderConfiguration : structural + semantic validation.
#   - Get-OpenRouterRouteDecomposition : split an OpenRouter route id
#     ('org/model', optionally ':variant') into ModelId / ProviderModelId /
#     UnderlyingModelId / GatewayProviderId.
#   - Register-OpenRouterRoute : map a route into the DB-M14 model catalogue via
#     New-AiModel (READ-ONLY). LocalOrRemote='REMOTE'. Unknown capability metadata
#     stays null (= UNKNOWN).
#
# Pricing reuses DB-M15 (Get-AiPriceAt) via the common execution gate -- NO
# scraping, NO live pricing. NO network, NO provider calls, NO secrets stored.

. (Join-Path $PSScriptRoot "..\common\AdapterContracts.ps1")     # DB-M23 common
. (Join-Path $PSScriptRoot "..\common\AdapterExecutionGate.ps1") # price status + gate
. (Join-Path $PSScriptRoot "..\..\AiProvider.ps1")               # DB-M14 provider record (READ-ONLY)
. (Join-Path $PSScriptRoot "..\..\ModelCatalogue.ps1")           # DB-M14 model record (READ-ONLY)

# --- OpenRouter provider configuration ---------------------------------------------------

function New-OpenRouterProviderConfiguration {
    <#
    .SYNOPSIS
    Build the OpenRouter provider configuration. ProviderId is forced 'openrouter'
    (gateway identity). GatewayType is forced 'OPENROUTER'. ApiKeyReference is an
    environment-variable NAME (never a value); the secret value is resolved only
    inside the adapter boundary and only as a redacted Authorization header.
    #>
    param(
        [string]$ApiKeyReference = 'OPENROUTER_API_KEY',
        [bool]$Enabled = $false,
        [bool]$SupportsStreaming = $false,
        [bool]$SupportsTools = $false,
        [bool]$SupportsStructuredOutput = $false,
        [bool]$SupportsReasoningControls = $false,
        [string]$ConfigurationKey,
        [AllowNull()][string]$Notes
    )
    return [pscustomobject]@{
        SchemaVersion              = (Get-DbM23SchemaVersions).LocalProviderConfigurationVersion
        ProviderId                 = 'openrouter'
        DisplayName                = 'OpenRouter'
        ProviderType               = 'GATEWAY'
        GatewayType                = 'OPENROUTER'
        BaseEndpoint               = 'https://openrouter.ai/api/v1'
        Enabled                    = [bool]$Enabled
        SupportsStreaming          = [bool]$SupportsStreaming
        SupportsTools              = [bool]$SupportsTools
        SupportsStructuredOutput   = [bool]$SupportsStructuredOutput
        SupportsReasoningControls  = [bool]$SupportsReasoningControls
        ApiKeyReference            = $ApiKeyReference
        ConfigurationKey           = $ConfigurationKey
        Notes                      = $Notes
    }
}

function Test-OpenRouterProviderConfiguration {
    <#
    .SYNOPSIS
    Deterministic validation of an OpenRouter provider configuration.
    #>
    param([AllowNull()][object]$Configuration)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Configuration) { return @{ Valid = $false; Errors = @('Configuration is null') } }

    $providerId = [string](Get-ContractProperty $Configuration 'ProviderId' '')
    if ($providerId -ne 'openrouter') { $errors.Add("ProviderId must be 'openrouter' (found '$providerId')") }
    $ptype = [string](Get-ContractProperty $Configuration 'ProviderType' '')
    if ($ptype -ne 'GATEWAY') { $errors.Add("ProviderType must be 'GATEWAY' (found '$ptype')") }
    $gtype = [string](Get-ContractProperty $Configuration 'GatewayType' '')
    if ($gtype -ne 'OPENROUTER') { $errors.Add("GatewayType must be 'OPENROUTER' (found '$gtype')") }
    $endpoint = [string](Get-ContractProperty $Configuration 'BaseEndpoint' '')
    if ($endpoint -and $endpoint -notmatch '^https://') {
        $errors.Add("BaseEndpoint must be https:// (found '$endpoint')")
    }

    $keyRef = [string](Get-ContractProperty $Configuration 'ApiKeyReference' '')
    if ($keyRef) {
        if ($keyRef -notmatch '^[A-Z][A-Z0-9_]{2,}$') {
            $errors.Add("ApiKeyReference must be an env-var NAME matching ^[A-Z][A-Z0-9_]{2,}\$ (never a value)")
        }
    } else {
        $errors.Add('ApiKeyReference is required (an env-var NAME)')
    }

    $leak = Test-DbM23SecretLeak $Configuration
    if ($leak.Leak) { $errors.Add("secret-like value detected in configuration: $($leak.Fields -join '; ')") }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}

# --- OpenRouter route decomposition -------------------------------------------------------

function Get-OpenRouterRouteDecomposition {
    <#
    .SYNOPSIS
    Decompose an OpenRouter route id ('org/model', optionally ':variant') into the
    DB-M14 model identities:
      - ProviderModelId  = the full route id (native case preserved)
      - UnderlyingModelId = the model part after the last '/' separator (the
        ':variant' suffix, if any, is stripped -- the underlying MODEL identity)
      - ModelId          = 'or:<route>' (lowercase catalogue key, unique per route)
      - GatewayProviderId = 'openrouter'
    Returns @{ Valid; Errors; ProviderId; ModelId; ProviderModelId;
    UnderlyingModelId; GatewayProviderId }.
    #>
    param([string]$RouteId)
    $errors = New-Object System.Collections.Generic.List[string]
    $route = [string]$RouteId
    if (-not $route) {
        return @{ Valid = $false; Errors = @('RouteId is required'); ProviderId = 'openrouter';
                  ModelId = $null; ProviderModelId = $null; UnderlyingModelId = $null; GatewayProviderId = 'openrouter' }
    }
    $route = $route.Trim()
    $slash = $route.LastIndexOf('/')
    if ($slash -lt 1 -or $slash -ge $route.Length - 1) {
        return @{ Valid = $false; Errors = @("RouteId '$route' must look like 'org/model'");
                  ProviderId = 'openrouter'; ModelId = $null; ProviderModelId = $null;
                  UnderlyingModelId = $null; GatewayProviderId = 'openrouter' }
    }
    $org = $route.Substring(0, $slash)
    $modelPart = $route.Substring($slash + 1)
    if (-not $org) {
        return @{ Valid = $false; Errors = @("RouteId '$route' must include a provider org before '/'");
                  ProviderId = 'openrouter'; ModelId = $null; ProviderModelId = $null;
                  UnderlyingModelId = $null; GatewayProviderId = 'openrouter' }
    }
    # strip ':variant' from the model part -- the underlying model identity
    $underlying = $modelPart
    $colon = $underlying.IndexOf(':')
    if ($colon -ge 0) { $underlying = $underlying.Substring(0, $colon) }
    if (-not $underlying) {
        return @{ Valid = $false; Errors = @("RouteId '$route' has an empty model part");
                  ProviderId = 'openrouter'; ModelId = $null; ProviderModelId = $null;
                  UnderlyingModelId = $null; GatewayProviderId = 'openrouter' }
    }
    return @{
        Valid = $true
        Errors = @()
        ProviderId = 'openrouter'
        ModelId = ('or:' + $route).ToLowerInvariant()
        ProviderModelId = $route
        UnderlyingModelId = $underlying
        GatewayProviderId = 'openrouter'
    }
}

# --- OpenRouter route registration (DB-M14 catalogue, READ-ONLY) -------------------------

function Register-OpenRouterRoute {
    <#
    .SYNOPSIS
    Map an OpenRouter route into the DB-M14 model catalogue via New-AiModel.
    Gateway identity stays distinct from model identity (GatewayProviderId =
    'openrouter', UnderlyingModelId = model part of the route). LocalOrRemote is
    forced 'REMOTE'. Unknown capability metadata stays null (= UNKNOWN).
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Configuration,
        [string]$RouteId,
        [AllowNull()][string]$DisplayName,
        [Nullable[bool]]$SupportsCoding,
        [Nullable[bool]]$SupportsReasoning,
        [Nullable[bool]]$SupportsVision,
        [Nullable[bool]]$SupportsToolUse,
        [Nullable[bool]]$SupportsStructuredOutput,
        [Nullable[bool]]$SupportsPromptCaching,
        [AllowNull()][long]$ContextWindow,
        [AllowNull()][long]$MaxOutputTokens,
        [AllowNull()][string[]]$ReasoningLevelsSupported,
        [AllowNull()][string]$Notes
    )
    $cfgValid = Test-OpenRouterProviderConfiguration $Configuration
    if (-not $cfgValid.Valid) {
        throw "Register-OpenRouterRoute: invalid OpenRouter configuration: $($cfgValid.Errors -join '; ')"
    }
    $dec = Get-OpenRouterRouteDecomposition -RouteId $RouteId
    if (-not $dec.Valid) {
        throw "Register-OpenRouterRoute: $($dec.Errors -join '; ')"
    }
    $enabled = [bool](Get-ContractProperty $Configuration 'Enabled' $false)
    return New-AiModel -ModelId $dec.ModelId -ProviderId $dec.ProviderId `
        -ProviderModelId $dec.ProviderModelId -UnderlyingModelId $dec.UnderlyingModelId `
        -GatewayProviderId $dec.GatewayProviderId -DisplayName $DisplayName -Enabled $enabled `
        -LocalOrRemote 'REMOTE' `
        -SupportsCoding $SupportsCoding -SupportsReasoning $SupportsReasoning `
        -SupportsVision $SupportsVision -SupportsToolUse $SupportsToolUse `
        -SupportsStructuredOutput $SupportsStructuredOutput -SupportsPromptCaching $SupportsPromptCaching `
        -ContextWindow $ContextWindow -MaxOutputTokens $MaxOutputTokens `
        -ReasoningLevelsSupported $ReasoningLevelsSupported -Notes $Notes
}

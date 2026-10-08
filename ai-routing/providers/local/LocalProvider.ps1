# LocalProvider.ps1 -- DB-M23 generic local provider adapter.
#
# The local provider abstraction is GENERIC: a runtime (Ollama, LM Studio,
# llama.cpp server, any OpenAI-compatible local endpoint) is expressed by the
# DB-M14 ProviderType/GatewayType vocabulary and the DB-M23 ApiStyle, NEVER by a
# hard-coded runtime name in shared logic. This is NOT "Ollama == local models".
#
#   - New-LocalProviderConfiguration : LocalProviderConfiguration v1. Locality is
#     forced 'LOCAL'. SecretReference / ConfigurationKey are NAMES, never values.
#   - Test-LocalProviderConfiguration : structural + semantic validation.
#   - Register-LocalModel : map a configured local model into the DB-M14 model
#     catalogue (New-AiModel, READ-ONLY). LocalOrRemote='LOCAL'; EndpointOverride=
#     provider endpoint. Unknown capabilities stay null (= UNKNOWN), never invented.
#   - Get-LocalProviderHealthEvidence : local conditions -> DB-M22 evidence
#     (UNAVAILABLE/DISABLED/AUTH_ERROR/RATE_LIMITED), never MODEL_QUALITY.
#
# NO network, NO provider calls, NO secrets stored, NO polling loops (evidence is
# recorded only when an attempt or explicit health event occurs).

. (Join-Path $PSScriptRoot "..\common\AdapterContracts.ps1")     # DB-M23 common
. (Join-Path $PSScriptRoot "..\common\AdapterExecutionGate.ps1") # price status + gate
. (Join-Path $PSScriptRoot "..\..\AiProvider.ps1")               # DB-M14 provider record (READ-ONLY)
. (Join-Path $PSScriptRoot "..\..\ModelCatalogue.ps1")           # DB-M14 model record (READ-ONLY)
. (Join-Path $PSScriptRoot "..\..\provider-health\ProviderHealthContracts.ps1")  # DB-M22 (READ-ONLY)

# --- LocalProviderConfiguration v1 ------------------------------------------------------

function New-LocalProviderConfiguration {
    <#
    .SYNOPSIS
    Build a LocalProviderConfiguration v1. Locality is forced 'LOCAL'. No secret
    VALUE is ever accepted; SecretReference / ConfigurationKey hold NAMES only.
    #>
    param(
        [string]$ProviderId,
        [string]$DisplayName,
        [string]$Endpoint,
        [string]$ApiStyle = 'OPENAI_COMPATIBLE',
        [bool]$Enabled = $false,
        [bool]$RequiresAuthentication = $false,
        [Nullable[int]]$DefaultTimeoutSeconds,
        [bool]$SupportsStreaming = $false,
        [bool]$SupportsToolCalls = $false,
        [bool]$SupportsStructuredOutput = $false,
        [string]$HealthMode = 'PASSIVE',
        [string]$ConfigurationKey,
        [string]$SecretReference,
        [AllowNull()][string]$Notes
    )
    if (-not $ProviderId) { throw "New-LocalProviderConfiguration: ProviderId is required" }
    return [pscustomobject]@{
        SchemaVersion            = (Get-DbM23SchemaVersions).LocalProviderConfigurationVersion
        ProviderId               = $ProviderId.Trim().ToLowerInvariant()
        DisplayName              = $DisplayName
        Endpoint                 = $Endpoint
        ApiStyle                 = $ApiStyle
        Enabled                  = [bool]$Enabled
        RequiresAuthentication   = [bool]$RequiresAuthentication
        DefaultTimeoutSeconds    = $DefaultTimeoutSeconds
        SupportsStreaming        = [bool]$SupportsStreaming
        SupportsToolCalls        = [bool]$SupportsToolCalls
        SupportsStructuredOutput = [bool]$SupportsStructuredOutput
        HealthMode               = $HealthMode
        Locality                 = 'LOCAL'
        ConfigurationKey         = $ConfigurationKey
        SecretReference          = $SecretReference
        Notes                    = $Notes
    }
}

function Test-LocalProviderConfiguration {
    <#
    .SYNOPSIS
    Deterministic validation of a LocalProviderConfiguration v1. Returns @{ Valid; Errors }.
    #>
    param([AllowNull()][object]$Configuration)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Configuration) { return @{ Valid = $false; Errors = @('Configuration is null') } }

    $providerId = [string](Get-ContractProperty $Configuration 'ProviderId' '')
    if (-not $providerId) { $errors.Add('ProviderId is required') }
    $locality = [string](Get-ContractProperty $Configuration 'Locality' '')
    if ($locality -ne 'LOCAL') { $errors.Add("Locality must be 'LOCAL' (found '$locality')") }

    $endpoint = [string](Get-ContractProperty $Configuration 'Endpoint' '')
    if (-not $endpoint) { $errors.Add('Endpoint is required') }
    elseif ($endpoint -notmatch '^(https?|local)://') { $errors.Add("Endpoint '$endpoint' must look like a URI (http://, https:// or local://)") }

    $style = [string](Get-ContractProperty $Configuration 'ApiStyle' 'GENERIC')
    if (-not (Test-IsValidDbM23ApiStyle $style)) { $errors.Add("ApiStyle '$style' invalid") }

    $healthMode = [string](Get-ContractProperty $Configuration 'HealthMode' 'UNKNOWN')
    if (-not (Test-IsValidDbM23HealthMode $healthMode)) { $errors.Add("HealthMode '$healthMode' invalid") }

    # bool fields must be actual bools when present
    foreach ($b in @('Enabled', 'RequiresAuthentication', 'SupportsStreaming', 'SupportsToolCalls', 'SupportsStructuredOutput')) {
        $v = (Get-ContractProperty $Configuration $b $null)
        if ($null -ne $v -and $v -isnot [bool]) { $errors.Add("$b must be a bool") }
    }

    $timeout = (Get-ContractProperty $Configuration 'DefaultTimeoutSeconds' $null)
    if ($null -ne $timeout -and ([int]$timeout -le 0)) { $errors.Add('DefaultTimeoutSeconds must be positive when present') }

    $secretRef = [string](Get-ContractProperty $Configuration 'SecretReference' '')
    if ($secretRef) {
        if ($secretRef -notmatch '^[A-Z][A-Z0-9_]{2,}$') {
            $errors.Add("SecretReference must be an env-var NAME matching ^[A-Z][A-Z0-9_]{2,}\$ (never a value)")
        }
    }
    $requiresAuth = [bool](Get-ContractProperty $Configuration 'RequiresAuthentication' $false)
    if ($requiresAuth -and -not $secretRef) {
        $errors.Add('RequiresAuthentication=true requires a SecretReference (env-var NAME)')
    }
    $cfgKey = [string](Get-ContractProperty $Configuration 'ConfigurationKey' '')
    if ($cfgKey -and $cfgKey -notmatch '^[A-Z][A-Z0-9_]{2,}$') {
        $errors.Add('ConfigurationKey must be a KEY NAME matching ^[A-Z][A-Z0-9_]{2,}$ (never a value)')
    }

    $leak = Test-DbM23SecretLeak $Configuration
    if ($leak.Leak) { $errors.Add("secret-like value detected in configuration: $($leak.Fields -join '; ')") }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}

# --- local model registration (DB-M14 catalogue, READ-ONLY) ----------------------------

function Register-LocalModel {
    <#
    .SYNOPSIS
    Map a configured local model into the DB-M14 model catalogue via New-AiModel.
    Capabilities not configured/discovered stay null (= UNKNOWN). LocalOrRemote is
    forced 'LOCAL'; EndpointOverride carries the provider endpoint. Health state is
    NOT part of the model record (health lives in DB-M22).
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Configuration,
        [string]$ModelId,
        [AllowNull()][string]$DisplayName,
        [Nullable[bool]]$SupportsCoding,
        [Nullable[bool]]$SupportsReasoning,
        [Nullable[bool]]$SupportsVision,
        [Nullable[bool]]$SupportsToolUse,
        [Nullable[bool]]$SupportsStructuredOutput,
        [Nullable[bool]]$SupportsStreaming,
        [AllowNull()][long]$ContextWindow,
        [AllowNull()][long]$MaxOutputTokens,
        [AllowNull()][string[]]$ReasoningLevelsSupported,
        [AllowNull()][string]$Notes
    )
    $cfgValid = Test-LocalProviderConfiguration $Configuration
    if (-not $cfgValid.Valid) {
        throw "Register-LocalModel: invalid local provider configuration: $($cfgValid.Errors -join '; ')"
    }
    if (-not $ModelId) { throw "Register-LocalModel: ModelId is required" }
    $modelId = $ModelId.Trim().ToLowerInvariant()
    $providerId = [string](Get-ContractProperty $Configuration 'ProviderId' '')
    $endpoint = [string](Get-ContractProperty $Configuration 'Endpoint' '')
    $enabled = [bool](Get-ContractProperty $Configuration 'Enabled' $false)

    $toolCap = $SupportsToolUse
    if ($null -eq $toolCap) { $toolCap = (Get-ContractProperty $Configuration 'SupportsToolCalls' $null) }
    $structuredCap = $SupportsStructuredOutput
    if ($null -eq $structuredCap) { $structuredCap = (Get-ContractProperty $Configuration 'SupportsStructuredOutput' $null) }
    $streamCap = $SupportsStreaming
    if ($null -eq $streamCap) { $streamCap = (Get-ContractProperty $Configuration 'SupportsStreaming' $null) }

    return New-AiModel -ModelId $modelId -ProviderId $providerId `
        -UnderlyingModelId $modelId -GatewayProviderId '' `
        -DisplayName $DisplayName -Enabled $enabled `
        -LocalOrRemote 'LOCAL' -EndpointOverride $endpoint `
        -SupportsCoding $SupportsCoding -SupportsReasoning $SupportsReasoning `
        -SupportsVision $SupportsVision -SupportsToolUse $toolCap `
        -SupportsStructuredOutput $structuredCap -SupportsStreaming $streamCap `
        -ContextWindow $ContextWindow -MaxOutputTokens $MaxOutputTokens `
        -ReasoningLevelsSupported $ReasoningLevelsSupported -Notes $Notes
}

# --- local health evidence (DB-M22 contract, READ-ONLY) --------------------------------

function Get-DbM23LocalHealthConditions {
    # Local-condition vocabulary (DB-M23-owned, distinct from the DB-M22 evidence
    # vocabulary because it describes the LOCAL runtime's observed state).
    return @('OFFLINE', 'MODEL_NOT_LOADED', 'DISABLED', 'AUTH_ERROR', 'RATE_LIMITED', 'HEALTHY')
}

function Get-LocalProviderHealthEvidence {
    <#
    .SYNOPSIS
    Map a local condition to a DB-M22 ProviderHealthEvidence v1 (READ-ONLY
    contract). Local endpoint failure is NEVER MODEL_QUALITY: FailureCategory is
    PROVIDER_AVAILABILITY / AUTHENTICATION / RATE_LIMIT / CONFIGURATION as
    appropriate. No polling loop: evidence is created only when an attempt or an
    explicit health event occurred (ObservedAtUtc is the event time).
    #>
    param(
        [string]$ProviderId,
        [AllowNull()][string]$GatewayProviderId = '',
        [AllowNull()][string]$UnderlyingModelId = '',
        [string]$Condition = 'HEALTHY',
        $ObservedAtUtc = $null,
        [AllowNull()][string]$Notes = '',
        [AllowNull()][datetime]$RetryAfterUtc
    )
    $conditions = Get-DbM23LocalHealthConditions
    if ($Condition -notin $conditions) { throw "Get-LocalProviderHealthEvidence: Condition '$Condition' invalid" }
    $observedAt = $ObservedAtUtc
    if ($null -eq $observedAt) { $observedAt = [datetime]::UtcNow }

    # Condition -> DB-M22 evidence mapping (evidence recorded, NOT a probe).
    switch ($Condition) {
        'OFFLINE'         { $state = 'UNAVAILABLE';  $etype = 'PASSIVE_FAILURE'; $failure = 'PROVIDER_AVAILABILITY' }
        'MODEL_NOT_LOADED'{ $state = 'UNAVAILABLE';  $etype = 'PASSIVE_FAILURE'; $failure = 'PROVIDER_AVAILABILITY' }
        'DISABLED'        { $state = 'DISABLED';     $etype = 'CONFIGURATION';   $failure = '' }
        'AUTH_ERROR'      { $state = 'AUTH_ERROR';   $etype = 'PASSIVE_FAILURE'; $failure = 'AUTHENTICATION' }
        'RATE_LIMITED'    { $state = 'RATE_LIMITED'; $etype = 'PASSIVE_FAILURE'; $failure = 'RATE_LIMIT' }
        'HEALTHY'         { $state = 'AVAILABLE';    $etype = 'PASSIVE_SUCCESS'; $failure = '' }
    }
    $fields = @{
        ProviderId        = $ProviderId
        GatewayProviderId = $GatewayProviderId
        UnderlyingModelId = $UnderlyingModelId
        ObservedState     = $state
        EvidenceType      = $etype
        ObservedAtUtc     = $observedAt
        FailureCategory   = $failure
        Notes             = $Notes
    }
    if ($null -ne $RetryAfterUtc) { $fields['RetryAfterUtc'] = $RetryAfterUtc }
    return New-ProviderHealthEvidence -Fields $fields
}

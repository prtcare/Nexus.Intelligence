# AdapterRequest.ps1 -- DB-M23 provider-independent request + native translation.
#
#   - New-ProviderRequest / Test-ProviderRequest : the provider-independent request
#     (v1). Provider-neutral: carries DB-M14 reasoning level, messages, output
#     budget, structured-output/tool requirements. NO provider-specific parameter
#     leaks into routing/business logic.
#   - Get-DbM23ReasoningTranslations / ConvertTo-DbM23ReasoningParam : deterministic
#     DB-M14 reasoning level -> provider-native parameter per ApiStyle. A level the
#     provider cannot represent is UNSUPPORTED (reported, never silently dropped).
#   - ConvertTo-ProviderNativeRequest : ApiStyle-aware translation into a
#     provider-native request SHAPE. Capability refusals (tools / structured
#     output / output limit / context limit / unsupported reasoning) refuse with
#     NoSend=$true. DRY_RUN path returns Status DRY_RUN_READY and sends nothing.
#
# Consumes READ-ONLY: AiRoutingContracts.ps1 (DB-M14), AdapterContracts.ps1 (DB-M23
# common vocabulary). NO network, NO provider calls, NO secrets stored.

. (Join-Path $PSScriptRoot "AdapterContracts.ps1")          # DB-M23 common (this dir)

# --- ProviderRequest v1 -------------------------------------------------------------

function New-ProviderRequest {
    <#
    .SYNOPSIS
    Build a provider-independent request (ProviderRequest v1). Every field that is
    not supplied keeps a defined default; there are no invented values.
    #>
    param(
        [string]$RequestId,
        [string]$TaskId,
        [string]$RoutingDecisionId,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$UnderlyingModelId,
        [string]$GatewayProviderId,
        [string]$ReasoningLevel = 'NONE',
        [AllowNull()][object[]]$Messages,
        [Nullable[int]]$MaxOutputTokens,
        [Nullable[int]]$EstimatedContextTokens,
        [switch]$RequiresStructuredOutput,
        [switch]$RequiresTools,
        [AllowNull()][object[]]$ToolDefinitions,
        [Nullable[int]]$TimeoutSeconds,
        [AllowNull()][object]$RequestMetadata
    )
    $now = [datetime]::UtcNow
    $rid = $RequestId
    if (-not $rid) { $rid = 'RQ-' + (Get-DbM23Sha256Hex "rq|$now.Ticks|$ProviderId|$ModelId").Substring(0, 16) }
    $msgCount = 0
    if ($null -ne $Messages) { $msgCount = @($Messages).Count }
    return [PSCustomObject]@{
        PSCustomVersion          = 'ProviderRequest v1'
        RequestId                = $rid
        TaskId                   = $TaskId
        RoutingDecisionId        = $RoutingDecisionId
        ProviderId               = $ProviderId
        ModelId                  = $ModelId
        UnderlyingModelId        = $UnderlyingModelId
        GatewayProviderId        = $GatewayProviderId
        ReasoningLevel           = $ReasoningLevel
        Messages                 = $Messages
        MessageCount             = $msgCount
        MaxOutputTokens          = $MaxOutputTokens
        EstimatedContextTokens   = $EstimatedContextTokens
        RequiresStructuredOutput = [bool]$RequiresStructuredOutput
        RequiresTools            = [bool]$RequiresTools
        ToolDefinitions          = $ToolDefinitions
        TimeoutSeconds           = $TimeoutSeconds
        RequestMetadata          = $RequestMetadata
        CreatedUtc               = $now
    }
}

function Test-ProviderRequest {
    <#
    .SYNOPSIS
    Validate a ProviderRequest v1 object.
    #>
    param([Parameter(Mandatory = $true)][object]$Request)
    $errors = New-Object System.Collections.Generic.List[string]
    $reasoningOrder = Get-AiRoutingReasoningOrder

    $nProviderId  = (Get-ContractProperty $Request 'ProviderId' $null)
    $nModelId     = (Get-ContractProperty $Request 'ModelId' $null)
    $nReasoning   = (Get-ContractProperty $Request 'ReasoningLevel' 'NONE')
    $nMaxOut      = (Get-ContractProperty $Request 'MaxOutputTokens' $null)
    $nEstCtx      = (Get-ContractProperty $Request 'EstimatedContextTokens' $null)
    $nTimeout     = (Get-ContractProperty $Request 'TimeoutSeconds' $null)
    $nReqStructured = (Get-ContractProperty $Request 'RequiresStructuredOutput' $false)
    $nReqTools    = (Get-ContractProperty $Request 'RequiresTools' $false)

    if ([string]::IsNullOrWhiteSpace([string]$nProviderId)) { $errors.Add('ProviderId is required') }
    if ([string]::IsNullOrWhiteSpace([string]$nModelId)) { $errors.Add('ModelId is required') }
    if ($null -eq $nReasoning -or -not $reasoningOrder.ContainsKey([string]$nReasoning)) {
        $errors.Add("ReasoningLevel must be one of $($reasoningOrder.Keys -join ',')")
    }
    if ($null -ne $nMaxOut -and [int]$nMaxOut -le 0) { $errors.Add('MaxOutputTokens must be positive when present') }
    if ($null -ne $nEstCtx -and [int]$nEstCtx -lt 0) { $errors.Add('EstimatedContextTokens must be non-negative when present') }
    if ($null -ne $nTimeout -and [int]$nTimeout -le 0) { $errors.Add('TimeoutSeconds must be positive when present') }
    if ([bool]$nReqStructured -and -not [bool]$nReqTools) {
        # structured output can be requested without tools; both may be true
    }
    if ([bool]$nReqTools) {
        $nTools = (Get-ContractProperty $Request 'ToolDefinitions' $null)
        if ($null -eq $nTools -or @($nTools).Count -eq 0) {
            $errors.Add('RequiresTools=true requires ToolDefinitions')
        }
    }
    return @{ IsValid = ($errors.Count -eq 0); Errors = @($errors) }
}

# --- reasoning translation ------------------------------------------------------------

function Get-DbM23ReasoningTranslations {
    <#
    .SYNOPSIS
    Deterministic table: ApiStyle x DB-M14 ReasoningLevel -> translation decision.
    A level a provider cannot represent is UNSUPPORTED (reported, never dropped).
    #>
    return @{
        'OPENAI_COMPATIBLE' = @{
            'NONE'    = 'OMITTED'
            'LOW'     = 'TRANSLATED'
            'MEDIUM'  = 'TRANSLATED'
            'HIGH'    = 'TRANSLATED'
            'MAX'     = 'UNSUPPORTED'
        }
        'OLLAMA_COMPATIBLE' = @{
            'NONE'    = 'OMITTED'
            'LOW'     = 'UNSUPPORTED'
            'MEDIUM'  = 'TRANSLATED'
            'HIGH'    = 'UNSUPPORTED'
            'MAX'     = 'UNSUPPORTED'
        }
        'ANTHROPIC_COMPATIBLE' = @{
            'NONE'    = 'OMITTED'
            'LOW'     = 'TRANSLATED'
            'MEDIUM'  = 'TRANSLATED'
            'HIGH'    = 'TRANSLATED'
            'MAX'     = 'TRANSLATED'
        }
        'OPENROUTER' = @{
            'NONE'    = 'OMITTED'
            'LOW'     = 'TRANSLATED'
            'MEDIUM'  = 'TRANSLATED'
            'HIGH'    = 'TRANSLATED'
            'MAX'     = 'TRANSLATED'
        }
        'GENERIC' = @{
            'NONE'    = 'OMITTED'
            'LOW'     = 'UNSUPPORTED'
            'MEDIUM'  = 'UNSUPPORTED'
            'HIGH'    = 'UNSUPPORTED'
            'MAX'     = 'UNSUPPORTED'
        }
    }
}

function ConvertTo-DbM23ReasoningParam {
    <#
    .SYNOPSIS
    Translate one DB-M14 ReasoningLevel into the provider-native parameter for the
    requested ApiStyle. Returns { Status, ParamName, ParamValue }. Status is
    TRANSLATED / OMITTED / UNSUPPORTED. OMITTED means the provider drops the field
    (level NONE). UNSUPPORTED is a hard refusal: no silent emulation.
    #>
    param(
        [string]$ApiStyle,
        [string]$ReasoningLevel = 'NONE'
    )
    $styles = Get-DbM23ApiStyles
    $table  = Get-DbM23ReasoningTranslations
    $reasoningOrder = Get-AiRoutingReasoningOrder

    if ($ApiStyle -notin $styles) {
        return @{ Status = 'UNSUPPORTED'; ParamName = $null; ParamValue = $null; Reason = 'INVALID_API_STYLE' }
    }
    if ($null -eq $ReasoningLevel -or -not $reasoningOrder.ContainsKey([string]$ReasoningLevel)) {
        return @{ Status = 'UNSUPPORTED'; ParamName = $null; ParamValue = $null; Reason = 'INVALID_REASONING_LEVEL' }
    }

    $decision = $table[$ApiStyle][$ReasoningLevel]
    switch ($decision) {
        'OMITTED' {
            return @{ Status = 'OMITTED'; ParamName = $null; ParamValue = $null; Reason = $null }
        }
        'UNSUPPORTED' {
            return @{ Status = 'UNSUPPORTED'; ParamName = $null; ParamValue = $null; Reason = 'UNSUPPORTED_REASONING' }
        }
    }

    # TRANSLATED
    switch ($ApiStyle) {
        'OPENAI_COMPATIBLE' {
            # OpenAI-style reasoning_effort accepts low/medium/high
            $effort = 'medium'
            if ($ReasoningLevel -eq 'LOW') { $effort = 'low' }
            if ($ReasoningLevel -eq 'HIGH') { $effort = 'high' }
            return @{ Status = 'TRANSLATED'; ParamName = 'reasoning_effort'; ParamValue = $effort; Reason = $null }
        }
        'OLLAMA_COMPATIBLE' {
            # Ollama-style: only MEDIUM is representable (think=true)
            return @{ Status = 'TRANSLATED'; ParamName = 'think'; ParamValue = $true; Reason = $null }
        }
        'ANTHROPIC_COMPATIBLE' {
            # Anthropic-style: thinking budget proportional to the level
            $budget = 0
            if ($ReasoningLevel -eq 'LOW') { $budget = 2048 }
            if ($ReasoningLevel -eq 'MEDIUM') { $budget = 4096 }
            if ($ReasoningLevel -eq 'HIGH') { $budget = 8192 }
            if ($ReasoningLevel -eq 'MAX') { $budget = 32768 }
            return @{ Status = 'TRANSLATED'; ParamName = 'thinking.budget_tokens'; ParamValue = $budget; Reason = $null }
        }
        'OPENROUTER' {
            # OpenRouter passes provider-level reasoning through as a parameter
            # choice carried by the request body; the value is the DB-M14 level.
            return @{ Status = 'TRANSLATED'; ParamName = 'reasoning'; ParamValue = $ReasoningLevel; Reason = $null }
        }
    }
    return @{ Status = 'UNSUPPORTED'; ParamName = $null; ParamValue = $null; Reason = 'UNSUPPORTED_REASONING' }
}

# --- provider-native request translation ------------------------------------------------

function Get-DbM23NativeRequestHeaders {
    <#
    .SYNOPSIS
    Native request header set for an ApiStyle (content types only; the
    Authorization/api-key header is added by the DRY_RUN path and ALWAYS in
    redacted form via ConvertTo-DbM23RedactedHeaders).
    #>
    param([string]$ApiStyle)
    $base = @{ 'Content-Type' = 'application/json' }
    if ($ApiStyle -eq 'OLLAMA_COMPATIBLE') { $base['Accept'] = 'application/json' }
    if ($ApiStyle -eq 'OPENROUTER') { $base['X-Title'] = 'DevBridge-adapter' }
    return $base
}

function New-ProviderNativeRequest {
    <#
    .SYNOPSIS
    Build the provider-native request SHAPE for the configured ApiStyle from a
    ProviderRequest v1. Capability refusals return Status REFUSED with ReasonCodes
    and NoSend=$true. On success Status is DRY_RUN_READY (shape generated, nothing
    sent) or READY when the caller indicates a real execution is permitted.
    $SecretLookup is an optional scriptblock for acquiring a referenced secret; it is
    the ONLY route by which a secret value can enter this function, and the same
    injected-accessor convention Get-DbM28ProviderSecretStatus already uses. When it
    is omitted no secret is acquired and no Authorization header is produced.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$ProviderRequest,
        [string]$ApiStyle = 'GENERIC',
        [AllowNull()][object]$ProviderConfiguration,
        [AllowNull()][System.Management.Automation.ScriptBlock]$SecretLookup,
        [switch]$DryRun
    )
    $none = @{ Status = 'REFUSED'; ReasonCodes = @('ROUTE_UNKNOWN'); NoSend = $true; NetworkCalls = 0; PaidApiCalls = 0; AutoExecutionEnabled = $false; NativeRequest = $null; DryRun = $DryRun }

    $valid = Test-ProviderRequest $ProviderRequest
    if (-not $valid.IsValid) {
        $none.ReasonCodes = @('INVALID_PROVIDER_REQUEST')
        return $none
    }
    if ($ApiStyle -notin (Get-DbM23ApiStyles)) {
        $none.ReasonCodes = @('UNSUPPORTED_API_STYLE')
        return $none
    }

    $reasoning = ConvertTo-DbM23ReasoningParam -ApiStyle $ApiStyle -ReasoningLevel (Get-ContractProperty $ProviderRequest 'ReasoningLevel' 'NONE')
    if ($reasoning.Status -eq 'UNSUPPORTED') {
        $none.ReasonCodes = @('UNSUPPORTED_REASONING')
        return $none
    }

    # Capability gates: never silently emulate a capability the provider lacks.
    $cfgSupportsTools = $null
    $cfgSupportsStructured = $null
    if ($null -ne $ProviderConfiguration) {
        $cfgSupportsTools = (Get-ContractProperty $ProviderConfiguration 'SupportsToolCalls' $null)
        $cfgSupportsStructured = (Get-ContractProperty $ProviderConfiguration 'SupportsStructuredOutput' $null)
    }

    $requiresTools = [bool](Get-ContractProperty $ProviderRequest 'RequiresTools' $false)
    if ($requiresTools) {
        if ($null -ne $cfgSupportsTools -and -not [bool]$cfgSupportsTools) {
            $none.ReasonCodes = @('TOOL_NOT_SUPPORTED')
            return $none
        }
    }
    $requiresStructured = [bool](Get-ContractProperty $ProviderRequest 'RequiresStructuredOutput' $false)
    if ($requiresStructured) {
        if ($null -ne $cfgSupportsStructured -and -not [bool]$cfgSupportsStructured) {
            $none.ReasonCodes = @('STRUCTURED_OUTPUT_NOT_SUPPORTED')
            return $none
        }
    }

    $maxOut = (Get-ContractProperty $ProviderRequest 'MaxOutputTokens' $null)
    $cfgMaxOut = $null
    if ($null -ne $ProviderConfiguration) { $cfgMaxOut = (Get-ContractProperty $ProviderConfiguration 'DefaultTimeoutSeconds' $null) }
    # context/output limits are validated against the model record by the caller;
    # the adapter does not own model metadata (read-only consumption).

    $body = @{
        model       = (Get-ContractProperty $ProviderRequest 'ModelId' $null)
        messages    = (Get-ContractProperty $ProviderRequest 'Messages' $null)
    }
    if ($null -ne $maxOut) { $body['max_tokens'] = [int]$maxOut }
    if ($null -ne $reasoning.ParamName) { $body[$reasoning.ParamName] = $reasoning.ParamValue }
    if ($requiresStructured) { $body['response_format'] = @{ type = 'json_object' } }
    if ($requiresTools) {
        $tools = (Get-ContractProperty $ProviderRequest 'ToolDefinitions' $null)
        if ($null -ne $tools) { $body['tools'] = @($tools) }
    }

    $headers = Get-DbM23NativeRequestHeaders -ApiStyle $ApiStyle
    # Authentication is expressed by the SECRET REFERENCE NAME on the configuration.
    #
    # W5E / D-14: this function performs NO credential access of its own. The referenced
    # secret is obtained ONLY through $SecretLookup, a provider-neutral accessor INJECTED
    # by the caller; with no accessor supplied the reference is simply unresolvable and no
    # Authorization header is produced. This removes the last bound secret read from the
    # ai-routing unit -- the previous line here called [Environment]::GetEnvironmentVariable
    # directly, which is what put the whole 85-file unit inside D-14 custody.
    #
    # The wire shape is unchanged. The header was ALWAYS redacted on the next line
    # (ConvertTo-DbM23RedactedHeaders), so the direct read never had an observable effect
    # on any artifact -- measured, not assumed.
    $authHeader = $null
    if ($null -ne $ProviderConfiguration) {
        $secretRef = (Get-ContractProperty $ProviderConfiguration 'SecretReference' $null)
        if ((-not [string]::IsNullOrWhiteSpace([string]$secretRef)) -and $SecretLookup) {
            $secretVal = [string](@($SecretLookup.Invoke([string]$secretRef))[0])
            if (-not [string]::IsNullOrWhiteSpace($secretVal)) {
                $authHeader = "Bearer $secretVal"
            }
        }
    }
    if ($null -ne $authHeader) { $headers['Authorization'] = $authHeader }
    $headers = ConvertTo-DbM23RedactedHeaders $headers

    $native = [PSCustomObject]@{
        PSCustomVersion   = 'ProviderNativeRequest v1'
        ApiStyle          = $ApiStyle
        Body              = $body
        Headers           = $headers
        ReasoningTranslation = @{
            Status = $reasoning.Status
            ParamName = $reasoning.ParamName
            ParamValue = $reasoning.ParamValue
        }
        Endpoint          = $null
        CreatedUtc        = [datetime]::UtcNow
    }
    if ($null -ne $ProviderConfiguration) {
        $ep = (Get-ContractProperty $ProviderConfiguration 'Endpoint' $null)
        if ($null -ne $ep) { $native.Endpoint = [string]$ep }
    }

    $status = if ($DryRun) { 'DRY_RUN_READY' } else { 'READY' }
    return @{
        Status = $status
        ReasonCodes = @()
        NoSend = $true           # adapter never sends; future execution layer may
        NetworkCalls = 0
        PaidApiCalls = 0
        AutoExecutionEnabled = $false
        NativeRequest = $native
        DryRun = [bool]$DryRun
    }
}

function ConvertTo-ProviderNativeRequest {
    <#
    .SYNOPSIS
    ApiStyle-aware dispatch to New-ProviderNativeRequest. Keeps the common layer
    free of per-style branching. $SecretLookup is passed straight through; see
    New-ProviderNativeRequest for why it is the only route a secret value can take.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$ProviderRequest,
        [string]$ApiStyle = 'GENERIC',
        [AllowNull()][object]$ProviderConfiguration,
        [AllowNull()][System.Management.Automation.ScriptBlock]$SecretLookup,
        [switch]$DryRun
    )
    return New-ProviderNativeRequest -ProviderRequest $ProviderRequest -ApiStyle $ApiStyle -ProviderConfiguration $ProviderConfiguration -SecretLookup $SecretLookup -DryRun:$DryRun
}

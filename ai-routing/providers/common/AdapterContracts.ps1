# AdapterContracts.ps1 -- DB-M23 provider-adapter shared contracts.
#
# Provider-independent vocabularies and helpers for the provider adapter layer:
#   - adapter schema versions (frozen v1)
#   - ApiStyle / discovery-mode / health-mode / response-status / price-status
#     / error-category / reasoning-translation / finish-reason vocabularies
#   - deterministic DB-M23 error category -> DB-M20 failure category map
#   - SHA-256 hex helper
#   - secret-value leak guard (DB-M23 variant) and redaction helpers
#
# Dot-source AiRoutingContracts.ps1 (DB-M14) first -- Get-ContractProperty and the
# DB-M14 vocabularies are consumed here (READ-ONLY).
#
# No AI API calls, no provider calls, no network, no secrets stored.

. (Join-Path $PSScriptRoot "..\..\AiRoutingContracts.ps1")   # DB-M14 (READ-ONLY)

function Get-DbM23SchemaVersions {
    <#
    .SYNOPSIS
    Frozen schema versions for DB-M23 v1 contracts. Incompatible changes must
    introduce v2; v1 semantics are never silently mutated.
    #>
    return @{
        LocalProviderConfigurationVersion = 1
        ProviderRequestVersion            = 1
        ProviderResponseVersion           = 1
        NormalizedUsageVersion            = 1
        ProviderNativeRequestVersion      = 1
        AdapterDryRunResultVersion        = 1
        AdapterExecutionGateVersion       = 1
    }
}

# --- vocabularies ----------------------------------------------------------------

function Get-DbM23ApiStyles {
    # Provider-api surface vocab. A local runtime is expressed by its API STYLE,
    # never by a hard-coded runtime name (the architecture is generic local, not
    # "Ollama == local models").
    return @('OPENAI_COMPATIBLE', 'OLLAMA_COMPATIBLE', 'ANTHROPIC_COMPATIBLE', 'OPENROUTER', 'GENERIC')
}

function Get-DbM23DiscoveryModes {
    # DB-M23 implements STATIC_CONFIG discovery. LIVE_DISCOVERY is future-only.
    return @('STATIC_CONFIG', 'LIVE_DISCOVERY')
}

function Get-DbM23HealthModes {
    return @('PASSIVE', 'ACTIVE', 'MANUAL', 'UNKNOWN')
}

function Get-DbM23ResponseStatuses {
    return @('SUCCESS', 'ERROR', 'DRY_RUN_READY')
}

function Get-DbM23PriceStatuses {
    # CONFIGURED      = effective DB-M15 record with a non-zero provider token price
    # FREE            = effective DB-M15 record with an explicit zero provider token price
    # LOCAL_COST_UNKNOWN = LOCAL provider, no effective record: provider token price is
    #                      zero by default at the PROVIDER level only; operational cost
    #                      stays unknown (LOCAL is never automatically FREE)
    # PRICE_UNKNOWN   = remote route, no effective record
    return @('CONFIGURED', 'FREE', 'LOCAL_COST_UNKNOWN', 'PRICE_UNKNOWN')
}

function Get-DbM23ErrorCategories {
    # DB-M23 normalized provider-error vocabulary. Maps deterministically onto the
    # DB-M20 failure-category vocabulary (see Get-DbM23DbM20CategoryMap).
    return @(
        'AUTHENTICATION', 'RATE_LIMIT', 'PROVIDER_UNAVAILABLE', 'TIMEOUT',
        'INVALID_OUTPUT', 'CONTEXT_TOO_LARGE', 'TOOL_FAILURE', 'UNKNOWN_FAILURE'
    )
}

function Get-DbM23ReasoningTranslationStatuses {
    return @('TRANSLATED', 'OMITTED', 'UNSUPPORTED')
}

function Get-DbM23FinishReasons {
    return @('STOP', 'LENGTH', 'TOOL_CALLS', 'CONTENT_FILTER', 'STRUCTURED_OUTPUT', 'ERROR', 'UNKNOWN')
}

function Get-DbM23AdapterGateReasonCodes {
    return @(
        'AUTO_EXECUTION_PROHIBITED', 'ROUTING_NOT_ELIGIBLE', 'BUDGET_BLOCK',
        'HEALTH_BLOCK', 'UNSUPPORTED_REASONING', 'TOOL_NOT_SUPPORTED',
        'STRUCTURED_OUTPUT_NOT_SUPPORTED', 'OUTPUT_LIMIT_EXCEEDED',
        'CONTEXT_LIMIT_EXCEEDED', 'AUTH_REQUIRED_NOT_CONFIGURED', 'ROUTE_UNKNOWN'
    )
}

function Test-IsValidDbM23ApiStyle([string]$Value)          { $Value -in (Get-DbM23ApiStyles) }
function Test-IsValidDbM23DiscoveryMode([string]$Value)     { $Value -in (Get-DbM23DiscoveryModes) }
function Test-IsValidDbM23HealthMode([string]$Value)        { $Value -in (Get-DbM23HealthModes) }
function Test-IsValidDbM23ResponseStatus([string]$Value)    { $Value -in (Get-DbM23ResponseStatuses) }
function Test-IsValidDbM23PriceStatus([string]$Value)       { $Value -in (Get-DbM23PriceStatuses) }
function Test-IsValidDbM23ErrorCategory([string]$Value)     { $Value -in (Get-DbM23ErrorCategories) }
function Test-IsValidDbM23FinishReason([string]$Value)      { $Value -in (Get-DbM23FinishReasons) }

# --- DB-M23 error category -> DB-M20 failure category ----------------------------

function Get-DbM23DbM20CategoryMap {
    <#
    .SYNOPSIS
    Deterministic map from the DB-M23 provider-error category to the DB-M20
    failure-category vocabulary. Every DB-M23 category maps to exactly one DB-M20
    member so provider errors feed DB-M20/DB-M22 cleanly with NO provider-specific
    failure logic inside DB-M20.
    #>
    return @{
        'AUTHENTICATION'        = 'AUTHENTICATION'
        'RATE_LIMIT'            = 'RATE_LIMIT'
        'PROVIDER_UNAVAILABLE'  = 'PROVIDER_AVAILABILITY'   # DB-M20 vocabulary member
        'TIMEOUT'               = 'TIMEOUT'
        'INVALID_OUTPUT'        = 'INVALID_OUTPUT'
        'CONTEXT_TOO_LARGE'     = 'CONTEXT_TOO_LARGE'
        'TOOL_FAILURE'          = 'TOOL_FAILURE'
        'UNKNOWN_FAILURE'       = 'UNKNOWN_FAILURE'
    }
}

function ConvertTo-DbM23DbM20FailureCategory {
    <#
    .SYNOPSIS
    Map one DB-M23 error category onto the DB-M20 failure-category vocabulary.
    Unknown categories map to UNKNOWN_FAILURE (never invented).
    #>
    param([string]$Category)
    $map = Get-DbM23DbM20CategoryMap
    if ($map.ContainsKey($Category)) { return $map[$Category] }
    return 'UNKNOWN_FAILURE'
}

# --- SHA-256 hex helper -----------------------------------------------------------

function Get-DbM23Sha256Hex {
    <#
    .SYNOPSIS
    Deterministic lowercase SHA-256 hex of a string (identity/evidential hashes).
    #>
    param([string]$InputText)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputText)
    $hash = $sha.ComputeHash($bytes)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $hash) { $null = $sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

# --- secret-value guard (DB-M23 variant) -----------------------------------------

function Test-DbM23SecretLeak {
    <#
    .SYNOPSIS
    Scan a DB-M23 configuration / request / response / result object for
    API-key-like VALUES. Names and references that are references by design
    (SecretReference, ConfigurationKey, ApiKeyReference, ids, endpoints, statuses,
    numeric thresholds) are exempt. Free-text fields (Notes, Message) ARE scanned.
    Response payload fields (Text, StructuredContent, ToolCalls) are exempt: they
    are provider-produced content, not configuration, and DB-M23 stores raw
    response content only as a REFERENCE (RawResponseReference), never verbatim.
    #>
    param([AllowNull()][object]$Target)
    $exempt = @(
        'SchemaVersion', 'ProviderId', 'ModelId', 'ProviderModelId', 'UnderlyingModelId',
        'GatewayProviderId', 'DisplayName', 'ApiStyle', 'Locality', 'HealthMode',
        'DiscoveryMode', 'ResponseStatus', 'PriceStatus', 'FinishReason', 'Status',
        'ErrorCategory', 'FailureCategory', 'UsageSource', 'OperationalCostUnknown',
        'ConfigurationKey', 'SecretReference', 'ApiKeyReference', 'BaseEndpoint',
        'Endpoint', 'EndpointOverride', 'DefaultTimeoutSeconds', 'ContextWindow',
        'MaxOutputTokens', 'RequiredContextTokens', 'EstimatedContextTokens',
        'InputTokens', 'CachedInputTokens', 'CacheWriteTokens', 'OutputTokens',
        'ReasoningTokens', 'TotalTokens', 'ToolCalls', 'ToolDefinitions', 'Text',
        'StructuredContent', 'LatencyMs', 'RequestId', 'RoutingDecisionId', 'TaskId',
        'ProviderRequestId', 'RawResponseReference', 'RetryAfterUtc', 'TimestampUtc',
        'ObservedAtUtc', 'ObservedState', 'EvidenceType', 'Source', 'RouteId',
        'AttemptIdReference', 'RequestMetadata', 'Headers', 'ReasoningLevel',
        'ReasoningLevelsSupported', 'ProviderTokenPrice', 'InputPricePerMillion',
        'OutputPricePerMillion', 'PricingRecordId', 'RequiresAuthentication',
        'RequiresStructuredOutput', 'RequiresTools', 'SupportsStreaming',
        'SupportsToolCalls', 'SupportsStructuredOutput', 'Enabled', 'Configured',
        'ProviderType', 'GatewayType', 'ReasonCodes', 'AutoExecutionEnabled',
        'NetworkCalls', 'PaidApiCalls', 'NoSend', 'DryRun', 'RequiresHumanOverride',
        'SelectedProviderId', 'SelectedModelId', 'LocalOrRemote', 'Message'
    )
    $patterns = @(
        '^sk-[A-Za-z0-9_-]{8,}$',                 # OpenAI-style (whole field)
        '^AIza[0-9A-Za-z_-]{10,}$',               # Google-style (whole field)
        '^gh[pousr]_[A-Za-z0-9]{20,}$',           # GitHub tokens (whole field)
        '^[A-Za-z0-9+/=_\-]{32,}$',               # generic high-entropy token (whole field)
        '^-----BEGIN'                             # PEM block (whole field)
    )
    # substring patterns: a secret-like token ANYWHERE in a non-exempt free-text
    # field (e.g. Notes) is a leak, not just a whole-field match.
    $subPatterns = @(
        'sk-[A-Za-z0-9_-]{8,}',
        'AIza[0-9A-Za-z_-]{10,}',
        'gh[pousr]_[A-Za-z0-9]{20,}',
        '(?i)api[_-]?key[=:]\S',
        '(?i)secret[=:]\S',
        '(?i)password[=:]\S'
    )
    $leaks = New-Object System.Collections.Generic.List[string]

    function Test-DbM23LeakValue([string]$fieldName, [object]$value) {
        if ($null -eq $value) { return }
        if ($fieldName -in $exempt) { return }
        $s = [string]$value
        if ($s.Length -lt 8) { return }
        foreach ($p in $patterns) {
            if ($s -match $p) { $leaks.Add("$fieldName = <redacted> matches $p"); return }
        }
        foreach ($sp in $subPatterns) {
            if ($s -match $sp) { $leaks.Add("$fieldName contains a secret-like token"); return }
        }
        if ($s -match '(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*\S') {
            $leaks.Add("$fieldName contains inline credential assignment")
        }
    }

    function Test-DbM23LeakObject([string]$path, [object]$obj) {
        if ($null -eq $obj) { return }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($k in $obj.Keys) {
                $v = $obj[$k]
                $name = if ($path) { "$path.$k" } else { [string]$k }
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-DbM23LeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-DbM23LeakObject $name $item } else { Test-DbM23LeakValue ([string]$k) $item } }
                }
                else { Test-DbM23LeakValue ([string]$k) $v }
            }
            return
        }
        if ($obj -is [PSCustomObject]) {
            foreach ($prop in $obj.PSObject.Properties) {
                $name = if ($path) { "$path.$($prop.Name)" } else { $prop.Name }
                $v = $prop.Value
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-DbM23LeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-DbM23LeakObject $name $item } else { Test-DbM23LeakValue $prop.Name $item } }
                }
                else { Test-DbM23LeakValue $prop.Name $v }
            }
            return
        }
        Test-DbM23LeakValue 'value' $obj
    }

    Test-DbM23LeakObject '' $Target
    return @{ Leak = ($leaks.Count -gt 0); Fields = @($leaks) }
}

# --- redaction helpers -------------------------------------------------------------

function ConvertTo-DbM23RedactedValue {
    <#
    .SYNOPSIS
    Deterministically redact a value that looks like a credential. A bare secret
    becomes '<redacted>'; a 'Bearer <token>' / 'Token <token>' / 'Basic <cred>'
    header value keeps the scheme and redacts the credential. Anything else is
    returned verbatim.
    #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    if ($s -match '^(sk-[A-Za-z0-9_-]{8,}|AIza[0-9A-Za-z_-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|[A-Za-z0-9+/=_\-]{32,}|-----BEGIN)') {
        return '<redacted>'
    }
    if ($s -match '(?i)^(Bearer|Basic|Token|ApiKey|X-Api-Key)\s+(\S+)$') {
        return "$($Matches[1]) <redacted>"
    }
    if ($s -match '(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*\S') {
        return '<redacted>'
    }
    return $s
}

function ConvertTo-DbM23RedactedHeaders {
    <#
    .SYNOPSIS
    Return a copy of a headers map with every header value redacted. The native
    request's Authorization/api-key header is always carried in redacted form so
    no secret ever reaches a result/log/serialized artifact.
    #>
    param([AllowNull()][object]$Headers)
    $out = @{}
    if ($null -eq $Headers) { return $out }
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($k in $Headers.Keys) { $out[[string]$k] = ConvertTo-DbM23RedactedValue $Headers[$k] }
    }
    elseif ($Headers -is [PSCustomObject]) {
        foreach ($p in $Headers.PSObject.Properties) { $out[$p.Name] = ConvertTo-DbM23RedactedValue $p.Value }
    }
    return $out
}

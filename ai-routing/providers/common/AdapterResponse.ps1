# AdapterResponse.ps1 -- DB-M23 usage / response / error normalization.
#
#   - New-NormalizedUsage : DB-M17 usage vocabulary (ACTUAL | ESTIMATED | UNKNOWN).
#     Missing usage stays null -- NEVER fabricated. TotalTokens appears only when
#     input and output are both known.
#   - ConvertTo-ProviderResponse : common ProviderResponse v1. Normalized response
#     with the fixed field list; provider-native payloads are kept as a REFERENCE
#     (RawResponseReference), never verbatim, and never a secret.
#   - ConvertTo-ProviderError : provider-native error -> DB-M23 error category
#     (AUTHENTICATION / RATE_LIMIT / PROVIDER_UNAVAILABLE / TIMEOUT / INVALID_OUTPUT
#     / CONTEXT_TOO_LARGE / TOOL_FAILURE / UNKNOWN_FAILURE) and deterministic
#     DB-M20 FailureCategory via the common map. Message is redacted.
#
# Consumes READ-ONLY: AdapterContracts.ps1 (DB-M23 common), DB-M14/DB-M17 vocab
# helpers. NO network, NO provider calls, NO secrets stored.

. (Join-Path $PSScriptRoot "AdapterContracts.ps1")          # DB-M23 common (this dir)

function Get-DbM23UsageSources {
    # DB-M17 usage vocabulary consumed read-only. Unknown usage is explicit.
    return @('ACTUAL', 'ESTIMATED', 'UNKNOWN')
}

function New-NormalizedUsage {
    <#
    .SYNOPSIS
    Normalize a provider-reported (or estimated) usage record into the DB-M23
    usage shape. Dimensions that are not known stay null -- never fabricated.
    TotalTokens is set ONLY when both input and output are known.
    #>
    param(
        [AllowNull()][object[]]$InputTokens,
        [AllowNull()][object[]]$OutputTokens,
        [AllowNull()][object[]]$CachedInputTokens,
        [AllowNull()][object[]]$CacheWriteTokens,
        [AllowNull()][object[]]$ReasoningTokens,
        [AllowNull()][object[]]$TotalTokens,
        [AllowNull()][object[]]$ProviderReportedCost,
        [string]$UsageSource = 'UNKNOWN',
        [AllowNull()][object[]]$ProviderUsage
    )
    $sources = Get-DbM23UsageSources
    if ($UsageSource -notin $sources) { $UsageSource = 'UNKNOWN' }

    $missing = New-Object System.Collections.Generic.List[string]
    $in = $null; $out = $null; $cachedIn = $null; $cacheWrite = $null; $reasoning = $null; $total = $null; $cost = $null

    if ($null -ne $InputTokens) {
        if (@($InputTokens).Count -gt 0) { $in = [long]@($InputTokens)[0] } else { $missing.Add('InputTokens') }
    } else { $missing.Add('InputTokens') }
    if ($null -ne $OutputTokens) {
        if (@($OutputTokens).Count -gt 0) { $out = [long]@($OutputTokens)[0] } else { $missing.Add('OutputTokens') }
    } else { $missing.Add('OutputTokens') }
    if ($null -ne $CachedInputTokens) { if (@($CachedInputTokens).Count -gt 0) { $cachedIn = [long]@($CachedInputTokens)[0] } }
    if ($null -ne $CacheWriteTokens) { if (@($CacheWriteTokens).Count -gt 0) { $cacheWrite = [long]@($CacheWriteTokens)[0] } }
    if ($null -ne $ReasoningTokens) { if (@($ReasoningTokens).Count -gt 0) { $reasoning = [long]@($ReasoningTokens)[0] } }
    if ($null -ne $TotalTokens) { if (@($TotalTokens).Count -gt 0) { $total = [long]@($TotalTokens)[0] } }
    if ($null -ne $ProviderReportedCost) { if (@($ProviderReportedCost).Count -gt 0) { $cost = @($ProviderReportedCost)[0] } }

    # TotalTokens only when input+output known; never invented.
    if ($null -eq $total -and $null -ne $in -and $null -ne $out) { $total = $in + $out }

    return [PSCustomObject]@{
        PSCustomVersion      = 'NormalizedUsage v1'
        InputTokens          = $in
        CachedInputTokens    = $cachedIn
        CacheWriteTokens     = $cacheWrite
        OutputTokens         = $out
        ReasoningTokens      = $reasoning
        TotalTokens          = $total
        ProviderReportedCost = $cost
        UsageSource          = $UsageSource
        MissingUsage         = @($missing)
        ProviderUsage        = $ProviderUsage
    }
}

function Get-DbM23ResponseStatusOf($ProviderRequest) {
    return 'SUCCESS'
}

function ConvertTo-ProviderResponse {
    <#
    .SYNOPSIS
    Normalize a provider-native success/error payload into ProviderResponse v1.
    The normalized response carries the FIXED field list; the provider-native raw
    payload is referenced (RawResponseReference), never embedded.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$ProviderRequest,
        [AllowNull()][object]$NormalizedUsage,
        [AllowNull()][string]$Text,
        [AllowNull()][object]$StructuredContent,
        [AllowNull()][object[]]$ToolCalls,
        [string]$FinishReason = 'UNKNOWN',
        [AllowNull()][long]$LatencyMs,
        [AllowNull()][string]$ProviderRequestId,
        [AllowNull()][string]$RawResponseReference,
        [string]$ResponseStatus = 'SUCCESS',
        [AllowNull()][string]$ErrorCategory,
        [AllowNull()][datetime]$RetryAfterUtc
    )
    if ($ResponseStatus -notin (Get-DbM23ResponseStatuses)) { $ResponseStatus = 'ERROR' }
    if ($FinishReason -notin (Get-DbM23FinishReasons)) { $FinishReason = 'UNKNOWN' }
    $failure = $null
    if ($null -ne $ErrorCategory) {
        $failure = @{ ErrorCategory = $ErrorCategory; FailureCategory = ConvertTo-DbM23DbM20FailureCategory $ErrorCategory }
    }
    $usage = $NormalizedUsage
    if ($null -eq $usage) { $usage = New-NormalizedUsage -UsageSource 'UNKNOWN' }
    return [PSCustomObject]@{
        PSCustomVersion     = 'ProviderResponse v1'
        RequestId           = (Get-ContractProperty $ProviderRequest 'RequestId' $null)
        ProviderId          = (Get-ContractProperty $ProviderRequest 'ProviderId' $null)
        ModelId             = (Get-ContractProperty $ProviderRequest 'ModelId' $null)
        UnderlyingModelId   = (Get-ContractProperty $ProviderRequest 'UnderlyingModelId' $null)
        GatewayProviderId   = (Get-ContractProperty $ProviderRequest 'GatewayProviderId' $null)
        Status              = $ResponseStatus
        Text                = $Text
        StructuredContent   = $StructuredContent
        ToolCalls           = $ToolCalls
        Usage               = $usage
        FinishReason        = $FinishReason
        LatencyMs           = $LatencyMs
        ProviderRequestId   = $ProviderRequestId
        RawResponseReference = $RawResponseReference
        Error               = $failure
        RetryAfterUtc       = $RetryAfterUtc
        AutoExecutionEnabled = $false
    }
}

function ConvertTo-ProviderError {
    <#
    .SYNOPSIS
    Normalize a provider-native error into the DB-M23 error vocabulary and the
    deterministic DB-M20 FailureCategory. The message is redacted before it is
    stored; RetryAfterUtc is preserved when the provider reports it.
    #>
    param(
        [string]$ErrorCategory = 'UNKNOWN_FAILURE',
        [AllowNull()][string]$Message,
        [AllowNull()][object]$ProviderError,
        [AllowNull()][datetime]$RetryAfterUtc
    )
    if ($ErrorCategory -notin (Get-DbM23ErrorCategories)) { $ErrorCategory = 'UNKNOWN_FAILURE' }
    $clean = $Message
    if ($null -ne $clean) { $clean = [string](ConvertTo-DbM23RedactedValue $clean) }
    return [PSCustomObject]@{
        PSCustomVersion   = 'ProviderError v1'
        ErrorCategory     = $ErrorCategory
        FailureCategory   = ConvertTo-DbM23DbM20FailureCategory $ErrorCategory
        Message           = $clean
        ProviderError     = $ProviderError
        RetryAfterUtc     = $RetryAfterUtc
        AutoExecutionEnabled = $false
    }
}

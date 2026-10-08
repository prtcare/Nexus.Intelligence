# AiPricingContracts.ps1 — DB-M15 pricing contracts for the AI routing platform.
#
# Provider/model-INDEPENDENT, effective-dated pricing catalogue contracts:
#   - PricingRecord v1          (a single effective-dated rate row)
#   - PriceLookupResult v1      (deterministic price lookup response)
#   - PricingCatalogue v1       (the catalogue file / container)
#   - price status classification (CURRENT / NEEDS_REVIEW / EXPIRED / MANUAL_OVERRIDE)
#   - processing-tier / time-band / source vocabularies
#   - pricing-specific secret-value leak guard (wraps the DB-M14 guard)
#
# DB-M15 stores RATES AS DATA only. No pricing decision is hard-coded into
# business logic anywhere. Prices stay in config/pricing/*.json and are read
# through catalogue lookups. No AI API calls, no network, no paid calls.
#
# Dot-source AiRoutingContracts.ps1 (DB-M14) first (Get-ContractProperty,
# Test-AiRoutingSecretValueLeak are consumed here).

function Get-AiPricingSchemaVersions {
    <#
    .SYNOPSIS
    Frozen schema versions for DB-M15 v1 contracts. Later incompatible changes
    must introduce a new version (v2), never silently change v1 semantics.

    Registered here (NOT in DB-M14's Get-AiRoutingSchemaVersions) so DB-M14
    files stay byte-identical under parallel safety.
    #>
    return @{
        PricingRecordVersion       = 1
        PriceLookupResultVersion   = 1
        PricingCatalogueVersion    = 1
    }
}

function Get-AiPricingProcessingTiers {
    return @('STANDARD', 'BATCH', 'FLEX', 'PRIORITY')
}

function Get-AiPricingTimeBands {
    return @('DEFAULT', 'PEAK', 'OFF_PEAK')
}

function Get-AiPricingStatuses {
    return @('CURRENT', 'NEEDS_REVIEW', 'EXPIRED', 'MANUAL_OVERRIDE')
}

function Get-AiPricingLookupStates {
    return @('FOUND', 'NOT_FOUND', 'AMBIGUOUS', 'EXPIRED')
}

function Get-AiPricingSources {
    <#
    .SYNOPSIS
    Auditable price-source vocabulary:
      provider-documentation  - recorded from provider documentation (verifiable)
      manual-verified         - human verified entry
      sync-proposal           - future synchronization proposal (NOT yet verified)
      reference               - seed/reference figure from DevBridge requirements (NOT verified)
    #>
    return @('provider-documentation', 'manual-verified', 'sync-proposal', 'reference')
}

function Test-IsValidProcessingTier([string]$Value) { $Value -in (Get-AiPricingProcessingTiers) }
function Test-IsValidTimeBand([string]$Value)        { $Value -in (Get-AiPricingTimeBands) }
function Test-IsValidPricingStatus([string]$Value)   { $Value -in (Get-AiPricingStatuses) }
function Test-IsValidPricingSource([string]$Value)   { $Value -in (Get-AiPricingSources) }

function ConvertTo-AiUtc {
    <#
    .SYNOPSIS
    Normalize a datetime (object or string) to Kind=Utc so comparisons are
    INSTANT-based, never wall-clock. A string WITHOUT a zone designator is
    assumed to denote a UTC clock time; a string WITH Z (or offset) is converted
    to the equivalent UTC instant. Null returns null. This keeps pricing lookups
    deterministic regardless of the host timezone.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Utc) { return $dt }
        if ($dt.Kind -eq [System.DateTimeKind]::Local) { return $dt.ToUniversalTime() }
        return [System.DateTime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
    }
    return [System.DateTime]::Parse(
        [string]$Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}

# --- pricing-specific secret-value guard ----------------------------------------------

function Test-AiPricingSecretValueLeak {
    <#
    .SYNOPSIS
    DB-M15 secret-value leak guard. Wraps the DB-M14 guard (Test-AiRoutingSecretValueLeak)
    and additionally exempts pricing fields that legitimately hold short identifiers,
    reference metadata, or numeric rates. Pricing fields hold RATES and REFERENCE NAMES
    (ProviderId, ModelId, PricingRecordId, Currency, Source, Notes), never credentials.
    #>
    param(
        [AllowNull()][object]$Target
    )
    $pricingExempt = @(
        'PricingRecordId', 'ProviderId', 'ModelId', 'Currency', 'Source', 'VerifiedAtUtc',
        'EffectiveFromUtc', 'EffectiveToUtc', 'ProcessingTier', 'TimeBand', 'Notes',
        'InputPricePerMillion', 'CachedInputPricePerMillion', 'CacheWrite5mPricePerMillion',
        'CacheWrite1hPricePerMillion', 'OutputPricePerMillion', 'ReasoningTokenPricePerMillion',
        'ToolCallPrice', 'ImagePrice', 'AudioPrice', 'StoragePrice',
        'AdditionalMultiplier', 'MinimumCharge', 'Status', 'StatusReason',
        'ModelResolved', 'ProviderResolved', 'SchemaVersion', 'ManualOverride'
    )
    $base = Test-AiRoutingSecretValueLeak $Target
    if (-not $base.Leak) { return @{ Leak = $false; Fields = @() } }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($base.Fields)) {
        $name = ($entry -split ' = ')[0]
        if ($name -in $pricingExempt) { continue }
        $kept.Add($entry)
    }
    return @{ Leak = ($kept.Count -gt 0); Fields = @($kept) }
}

# --- pricing record construction ------------------------------------------------------

function New-AiPricingRecord {
    <#
    .SYNOPSIS
    Build a normalized effective-dated pricing record (schemaVersion 1).
    Unknown/not-applicable price dimensions stay null - never faked as zero.
    Effective-dated window semantics: [EffectiveFromUtc, EffectiveToUtc) -
    EffectiveFromUtc INCLUSIVE, EffectiveToUtc EXCLUSIVE; null EffectiveToUtc = open-ended.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$PricingRecordId,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$Currency = 'USD',
        [string]$EffectiveFromUtc,
        [string]$EffectiveToUtc,
        [string]$ProcessingTier = 'STANDARD',
        [string]$TimeBand = 'DEFAULT',
        [Nullable[double]]$InputPricePerMillion,
        [Nullable[double]]$CachedInputPricePerMillion,
        [Nullable[double]]$CacheWrite5mPricePerMillion,
        [Nullable[double]]$CacheWrite1hPricePerMillion,
        [Nullable[double]]$OutputPricePerMillion,
        [Nullable[double]]$ReasoningTokenPricePerMillion,
        [Nullable[double]]$ToolCallPrice,
        [Nullable[double]]$ImagePrice,
        [Nullable[double]]$AudioPrice,
        [Nullable[double]]$StoragePrice,
        [Nullable[double]]$AdditionalMultiplier,
        [Nullable[double]]$MinimumCharge,
        [string]$Source,
        [string]$VerifiedAtUtc,
        [bool]$ManualOverride = $false,
        [string]$Notes
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }

    $id = if ($InputObject) { & $g 'PricingRecordId' $PricingRecordId } else { $PricingRecordId }
    if (-not $id) { throw "New-AiPricingRecord: PricingRecordId is required" }
    $id = $id.Trim()

    $providerId = if ($InputObject) { & $g 'ProviderId' $ProviderId } else { $ProviderId }
    if (-not $providerId) { throw "New-AiPricingRecord: ProviderId is required" }
    $providerId = $providerId.Trim().ToLowerInvariant()

    $modelId = if ($InputObject) { & $g 'ModelId' $ModelId } else { $ModelId }
    if (-not $modelId) { throw "New-AiPricingRecord: ModelId is required" }
    $modelId = $modelId.Trim().ToLowerInvariant()

    $currency = if ($InputObject) { & $g 'Currency' $Currency } else { $Currency }
    if (-not $currency) { $currency = 'USD' }
    $currency = $currency.Trim().ToUpperInvariant()

    $effFrom = if ($InputObject) { & $g 'EffectiveFromUtc' $EffectiveFromUtc } else { $EffectiveFromUtc }
    if (-not $effFrom) { throw "New-AiPricingRecord: EffectiveFromUtc is required" }

    $effTo   = if ($InputObject) { & $g 'EffectiveToUtc' $EffectiveToUtc } else { $EffectiveToUtc }
    # A [string] param turns an unbound $null into "" — normalize empty back to null
    # so "EffectiveToUtc null = open-ended" stays the single, honest state.
    if ($effTo -is [string] -and [string]::IsNullOrWhiteSpace($effTo)) { $effTo = $null }
    $tier    = if ($InputObject) { & $g 'ProcessingTier' $ProcessingTier } else { $ProcessingTier }
    if (-not $tier) { $tier = 'STANDARD' }
    $tier = $tier.Trim().ToUpperInvariant()
    $band    = if ($InputObject) { & $g 'TimeBand' $TimeBand } else { $TimeBand }
    if (-not $band) { $band = 'DEFAULT' }
    $band = $band.Trim().ToUpperInvariant()

    $in   = if ($InputObject) { & $g 'InputPricePerMillion' $InputPricePerMillion } else { $InputPricePerMillion }
    $cin  = if ($InputObject) { & $g 'CachedInputPricePerMillion' $CachedInputPricePerMillion } else { $CachedInputPricePerMillion }
    $cw5  = if ($InputObject) { & $g 'CacheWrite5mPricePerMillion' $CacheWrite5mPricePerMillion } else { $CacheWrite5mPricePerMillion }
    $cw1  = if ($InputObject) { & $g 'CacheWrite1hPricePerMillion' $CacheWrite1hPricePerMillion } else { $CacheWrite1hPricePerMillion }
    $out  = if ($InputObject) { & $g 'OutputPricePerMillion' $OutputPricePerMillion } else { $OutputPricePerMillion }
    $rt   = if ($InputObject) { & $g 'ReasoningTokenPricePerMillion' $ReasoningTokenPricePerMillion } else { $ReasoningTokenPricePerMillion }
    $tool = if ($InputObject) { & $g 'ToolCallPrice' $ToolCallPrice } else { $ToolCallPrice }
    $img  = if ($InputObject) { & $g 'ImagePrice' $ImagePrice } else { $ImagePrice }
    $aud  = if ($InputObject) { & $g 'AudioPrice' $AudioPrice } else { $AudioPrice }
    $stg  = if ($InputObject) { & $g 'StoragePrice' $StoragePrice } else { $StoragePrice }
    $mult = if ($InputObject) { & $g 'AdditionalMultiplier' $AdditionalMultiplier } else { $AdditionalMultiplier }
    $min  = if ($InputObject) { & $g 'MinimumCharge' $MinimumCharge } else { $MinimumCharge }
    $src  = if ($InputObject) { & $g 'Source' $Source } else { $Source }
    $ver  = if ($InputObject) { & $g 'VerifiedAtUtc' $VerifiedAtUtc } else { $VerifiedAtUtc }
    $mover= if ($InputObject) { [bool](& $g 'ManualOverride' $ManualOverride) } else { $ManualOverride }
    $notes= if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }

    $record = [pscustomobject]@{
        SchemaVersion               = 1
        PricingRecordId             = $id
        ProviderId                  = $providerId
        ModelId                     = $modelId
        Currency                    = $currency
        EffectiveFromUtc            = $effFrom
        EffectiveToUtc              = $effTo
        ProcessingTier              = $tier
        TimeBand                    = $band
        InputPricePerMillion        = $in
        CachedInputPricePerMillion  = $cin
        CacheWrite5mPricePerMillion = $cw5
        CacheWrite1hPricePerMillion = $cw1
        OutputPricePerMillion       = $out
        ReasoningTokenPricePerMillion = $rt
        ToolCallPrice               = $tool
        ImagePrice                  = $img
        AudioPrice                  = $aud
        StoragePrice                = $stg
        AdditionalMultiplier        = $mult
        MinimumCharge               = $min
        Source                      = $src
        VerifiedAtUtc               = $ver
        ManualOverride              = $mover
        Notes                       = $notes
        # computed enrichment (NOT part of the persisted seed schema; set by
        # Import-AiPricingConfiguration / Validate-AiPricingCatalogue)
        ModelResolved               = $null
        ProviderResolved            = $null
    }
    return $record
}

# --- single-record validation ---------------------------------------------------------

function Test-AiPricingRecord {
    <#
    .SYNOPSIS
    Deterministically validate one pricing record (schemaVersion 1). Uses defensive
    property reads so hand-crafted records validate identically under Set-StrictMode.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([pscustomobject]$Record)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Record) { return @{ Valid = $false; Errors = @('Record is null'); Warnings = @() } }

    $id = Get-ContractProperty $Record 'PricingRecordId' ''
    if (-not $id) { $errors.Add('PricingRecordId required') }
    elseif ($id -notmatch '^[A-Za-z0-9._\-]{1,120}$') { $errors.Add("PricingRecordId '$id' contains invalid characters") }
    if ((Get-ContractProperty $Record 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    $providerId = Get-ContractProperty $Record 'ProviderId' ''
    if (-not $providerId) { $errors.Add('ProviderId required') }
    $modelId = Get-ContractProperty $Record 'ModelId' ''
    if (-not $modelId) { $errors.Add('ModelId required') }

    $currency = Get-ContractProperty $Record 'Currency' ''
    if (-not $currency) { $errors.Add('Currency required') }
    elseif ($currency -notmatch '^[A-Z]{3}$') { $errors.Add("Currency '$currency' must be ISO-4217 (3 uppercase letters)") }

    $dFrom = [datetime]::MinValue; $dTo = [datetime]::MaxValue
    $effFrom = Get-ContractProperty $Record 'EffectiveFromUtc' ''
    $effTo = Get-ContractProperty $Record 'EffectiveToUtc' $null
    $fromOk = $false; $toOk = $false
    if (-not $effFrom) { $errors.Add('EffectiveFromUtc required') }
    elseif (-not [datetime]::TryParse($effFrom, [ref]$dFrom)) { $errors.Add("EffectiveFromUtc '$effFrom' not a parseable date") }
    else { $fromOk = $true }
    if ($effTo) {
        if (-not [datetime]::TryParse($effTo, [ref]$dTo)) { $errors.Add("EffectiveToUtc '$effTo' not a parseable date") }
        else { $toOk = $true }
    }
    if ($fromOk -and $toOk -and (ConvertTo-AiUtc $effFrom) -ge (ConvertTo-AiUtc $effTo)) {
        $errors.Add('EffectiveFromUtc must be < EffectiveToUtc')
    }

    $tier = Get-ContractProperty $Record 'ProcessingTier' 'STANDARD'
    if ($tier -and -not (Test-IsValidProcessingTier $tier)) { $errors.Add("ProcessingTier '$tier' invalid") }
    $band = Get-ContractProperty $Record 'TimeBand' 'DEFAULT'
    if ($band -and -not (Test-IsValidTimeBand $band)) { $errors.Add("TimeBand '$band' invalid") }

    # negative price rejected for every price dimension that is present
    $dims = @(
        'InputPricePerMillion', 'CachedInputPricePerMillion', 'CacheWrite5mPricePerMillion',
        'CacheWrite1hPricePerMillion', 'OutputPricePerMillion', 'ReasoningTokenPricePerMillion',
        'ToolCallPrice', 'ImagePrice', 'AudioPrice', 'StoragePrice', 'AdditionalMultiplier', 'MinimumCharge'
    )
    foreach ($d in $dims) {
        $v = Get-ContractProperty $Record $d $null
        if ($null -ne $v -and $v -lt 0) { $errors.Add("$d must be >= 0 (found $v)") }
    }

    $src = Get-ContractProperty $Record 'Source' $null
    if ($src -and -not (Test-IsValidPricingSource $src)) {
        $warnings.Add("Source '$src' not in recommended vocabulary ($((Get-AiPricingSources) -join ', '))")
    }
    $ver = Get-ContractProperty $Record 'VerifiedAtUtc' $null
    if ($ver) {
        $dV = [datetime]::MinValue
        if (-not [datetime]::TryParse($ver, [ref]$dV)) { $errors.Add("VerifiedAtUtc '$ver' not a parseable date") }
    }

    $leak = Test-AiPricingSecretValueLeak $Record
    if ($leak.Leak) { $errors.Add("secret value detected in pricing record: $($leak.Fields -join '; ')") }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @($warnings) }
}

# --- price status classification ------------------------------------------------------

function Get-AiPricingRecordStatus {
    <#
    .SYNOPSIS
    Calculated/display status of a pricing record at a point in time.
    Statuses: CURRENT | NEEDS_REVIEW | EXPIRED | MANUAL_OVERRIDE.
    Precedence: EXPIRED (dates dominate) -> not-yet-effective -> active
    (MANUAL_OVERRIDE > NEEDS_REVIEW > CURRENT).
    Returns @{ Status; Reason }.
    #>
    param(
        [pscustomobject]$Record,
        $AsOfUtc = $null
    )
    $asOf = if ($null -eq $AsOfUtc) { [datetime]::UtcNow } else { ConvertTo-AiUtc $AsOfUtc }

    $effFromStr = Get-ContractProperty $Record 'EffectiveFromUtc' ''
    $effFrom = [datetime]::MinValue
    if ($effFromStr) { $effFrom = ConvertTo-AiUtc $effFromStr }
    $effToStr = Get-ContractProperty $Record 'EffectiveToUtc' $null
    $effTo = [datetime]::MaxValue
    $hasTo = $false
    if ($effToStr) { $effTo = ConvertTo-AiUtc $effToStr; $hasTo = $true }

    $modelResolved = Get-ContractProperty $Record 'ModelResolved' $null
    $verified = Get-ContractProperty $Record 'VerifiedAtUtc' $null
    $src = Get-ContractProperty $Record 'Source' $null
    $override = Get-ContractProperty $Record 'ManualOverride' $false

    if ($hasTo -and $effTo -le $asOf) {
        return @{ Status = 'EXPIRED'; Reason = 'effective period ended' }
    }
    if ($effFrom -gt $asOf) {
        return @{ Status = 'NEEDS_REVIEW'; Reason = 'not yet effective' }
    }
    if ($override) {
        return @{ Status = 'MANUAL_OVERRIDE'; Reason = 'manual override active' }
    }
    if ($verified -and $src -in @('provider-documentation', 'manual-verified') -and $modelResolved -ne $false) {
        return @{ Status = 'CURRENT'; Reason = 'verified and model resolved' }
    }
    $why = New-Object System.Collections.Generic.List[string]
    if (-not $verified) { $why.Add('unverified') }
    elseif ($src -notin @('provider-documentation', 'manual-verified')) { $why.Add("source '$src' not authoritative") }
    if ($modelResolved -eq $false) { $why.Add('model not in catalogue') }
    return @{ Status = 'NEEDS_REVIEW'; Reason = ($why -join '; ') }
}

# --- price lookup result --------------------------------------------------------------

function New-AiPriceLookupResult {
    <#
    .SYNOPSIS
    Build the PriceLookupResult v1 response for a deterministic price lookup.
    LookupState: FOUND | NOT_FOUND | AMBIGUOUS | EXPIRED.
    #>
    param(
        [string]$ProviderId,
        [string]$ModelId,
        $TimestampUtc,
        [string]$ProcessingTier,
        [string]$TimeBand,
        [string]$LookupState,
        [object[]]$MatchedRecords,
        [string]$Status,
        [bool]$IsExpired = $false,
        [bool]$IsFuture = $false,
        [bool]$HasGap = $false,
        [string]$NearestUpcomingEffectiveFromUtc,
        [string]$Message
    )
    $records = @($MatchedRecords)
    $record = $null
    if ($records.Count -eq 1) { $record = $records[0] }
    return [pscustomobject]@{
        SchemaVersion                  = 1
        ProviderId                     = $ProviderId
        ModelId                        = $ModelId
        TimestampUtc                   = $TimestampUtc
        ProcessingTier                 = $ProcessingTier
        TimeBand                       = $TimeBand
        LookupState                    = $LookupState
        MatchedRecordCount             = $records.Count
        MatchedRecords                 = $records
        Record                         = $record
        Status                         = $Status
        IsExpired                      = $IsExpired
        IsFuture                       = $IsFuture
        HasGap                         = $HasGap
        NearestUpcomingEffectiveFromUtc = $NearestUpcomingEffectiveFromUtc
        Message                        = $Message
    }
}

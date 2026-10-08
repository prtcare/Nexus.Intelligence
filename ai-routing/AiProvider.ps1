# AiProvider.ps1 — DB-M14 provider identity catalogue.
#
# Provider records are provider-INDEPENDENT identity + capability-support metadata.
# No provider-specific fields enter shared task logic. No API calls, no credentials.
# Provider state in the seed catalogue is Enabled=false / Configured=false.
#
# Dot-source AiRoutingContracts.ps1 first (this file calls Get-ContractProperty).

# --- provider record construction ---------------------------------------------------

function New-AiProvider {
    <#
    .SYNOPSIS
    Build a normalized provider record (schemaVersion 1). Accepts a PSCustomObject /
    hashtable via -InputObject (JSON hydration) or explicit parameters.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$ProviderId,
        [string]$DisplayName,
        [bool]$Enabled = $false,
        [bool]$Configured = $false,
        [string]$ProviderType = 'DIRECT',
        [string]$BaseEndpoint,
        [string]$GatewayType = 'DIRECT',
        [bool]$SupportsStreaming = $false,
        [bool]$SupportsTools = $false,
        [bool]$SupportsPromptCaching = $false,
        [bool]$SupportsBatch = $false,
        [bool]$SupportsStructuredOutput = $false,
        [bool]$SupportsReasoningControls = $false,
        [bool]$SupportsUsageReporting = $false,
        [bool]$SupportsHealthCheck = $false,
        [string]$ConfigurationKey,
        [string]$SecretReference,
        [string]$Notes
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }

    $id = if ($InputObject) { & $g 'ProviderId' $ProviderId } else { $ProviderId }
    if (-not $id) { throw "New-AiProvider: ProviderId is required" }
    $id = $id.Trim().ToLowerInvariant()

    $display = $DisplayName
    if ($InputObject) { $display = & $g 'DisplayName' $null }
    if (-not $display) { $display = $id }

    $enabled       = if ($InputObject) { [bool](& $g 'Enabled' $Enabled) } else { $Enabled }
    $configured    = if ($InputObject) { [bool](& $g 'Configured' $Configured) } else { $Configured }
    $provType      = if ($InputObject) { & $g 'ProviderType' $ProviderType } else { $ProviderType }
    $endpoint      = if ($InputObject) { & $g 'BaseEndpoint' $BaseEndpoint } else { $BaseEndpoint }
    $gateType      = if ($InputObject) { & $g 'GatewayType' $GatewayType } else { $GatewayType }
    $sStreaming    = if ($InputObject) { [bool](& $g 'SupportsStreaming' $SupportsStreaming) } else { $SupportsStreaming }
    $sTools        = if ($InputObject) { [bool](& $g 'SupportsTools' $SupportsTools) } else { $SupportsTools }
    $sCaching      = if ($InputObject) { [bool](& $g 'SupportsPromptCaching' $SupportsPromptCaching) } else { $SupportsPromptCaching }
    $sBatch        = if ($InputObject) { [bool](& $g 'SupportsBatch' $SupportsBatch) } else { $SupportsBatch }
    $sStructured   = if ($InputObject) { [bool](& $g 'SupportsStructuredOutput' $SupportsStructuredOutput) } else { $SupportsStructuredOutput }
    $sReasoning    = if ($InputObject) { [bool](& $g 'SupportsReasoningControls' $SupportsReasoningControls) } else { $SupportsReasoningControls }
    $sUsage        = if ($InputObject) { [bool](& $g 'SupportsUsageReporting' $SupportsUsageReporting) } else { $SupportsUsageReporting }
    $sHealth       = if ($InputObject) { [bool](& $g 'SupportsHealthCheck' $SupportsHealthCheck) } else { $SupportsHealthCheck }
    $cfgKey        = if ($InputObject) { & $g 'ConfigurationKey' $ConfigurationKey } else { $ConfigurationKey }
    $secretRef     = if ($InputObject) { & $g 'SecretReference' $SecretReference } else { $SecretReference }
    $notes         = if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }

    $provider = [pscustomobject]@{
        SchemaVersion             = 1
        ProviderId                = $id
        DisplayName               = $display
        Enabled                   = $enabled
        Configured                = $configured
        ProviderType              = $provType
        BaseEndpoint              = $endpoint
        GatewayType               = $gateType
        SupportsStreaming         = $sStreaming
        SupportsTools             = $sTools
        SupportsPromptCaching     = $sCaching
        SupportsBatch             = $sBatch
        SupportsStructuredOutput  = $sStructured
        SupportsReasoningControls = $sReasoning
        SupportsUsageReporting    = $sUsage
        SupportsHealthCheck       = $sHealth
        ConfigurationKey          = $cfgKey
        SecretReference           = $secretRef
        Notes                     = $notes
    }
    return $provider
}

# --- single-record validation -------------------------------------------------------

function Test-AiProvider {
    <#
    .SYNOPSIS
    Validate a provider record. Uses defensive property reads so hand-crafted
    records (not just New-AiProvider output) validate deterministically.
    #>
    param([pscustomobject]$Provider)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Provider) { return @{ Valid = $false; Errors = @('Provider is null') } }
    $id = Get-ContractProperty $Provider 'ProviderId' $null
    if (-not $id) { $errors.Add('ProviderId required') }
    if ((Get-ContractProperty $Provider 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    $provType = Get-ContractProperty $Provider 'ProviderType' $null
    if ($provType -and -not (Test-IsValidProviderType $provType)) { $errors.Add("ProviderType '$provType' invalid") }
    $gateType = Get-ContractProperty $Provider 'GatewayType' $null
    if ($gateType -and -not (Test-IsValidGatewayType $gateType)) { $errors.Add("GatewayType '$gateType' invalid") }
    $endpoint = Get-ContractProperty $Provider 'BaseEndpoint' $null
    if ($endpoint -and $endpoint -notmatch '^(https?|file|ollama|local)://' -and $provType -ne 'LOCAL') {
        $errors.Add("BaseEndpoint '$endpoint' does not look like a URI")
    }
    $secretRef = Get-ContractProperty $Provider 'SecretReference' $null
    if ($secretRef -and $secretRef -notmatch '^[A-Z][A-Z0-9_]{2,}$') {
        $errors.Add("SecretReference '$secretRef' must be an env-var NAME, not a value")
    }
    $cfgKey = Get-ContractProperty $Provider 'ConfigurationKey' $null
    if ($cfgKey -and $cfgKey -notmatch '^[A-Za-z0-9_.\-]{1,64}$') {
        $errors.Add("ConfigurationKey '$cfgKey' must be a key NAME, not a value")
    }
    $leak = Test-AiRoutingSecretValueLeak $Provider
    if ($leak.Leak) { $errors.Add('secret value detected in provider record') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}

# --- catalogue operations -----------------------------------------------------------

function Add-AiProvider {
    <#
    .SYNOPSIS
    Add a provider to a catalogue (hashtable keyed by lowercase ProviderId).
    Duplicate ProviderId is rejected.
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [pscustomobject]$Provider
    )
    $t = Test-AiProvider $Provider
    if (-not $t.Valid) { throw "Add-AiProvider: invalid provider '$($Provider.ProviderId)': $($t.Errors -join '; ')" }
    if ($Catalogue.ContainsKey($Provider.ProviderId)) {
        throw "Add-AiProvider: duplicate ProviderId '$($Provider.ProviderId)'"
    }
    $Catalogue[$Provider.ProviderId] = $Provider
    return $Catalogue[$Provider.ProviderId]
}

function Get-AiProvider {
    param([System.Collections.IDictionary]$Catalogue, [string]$ProviderId)
    if (-not $ProviderId) { return $null }
    $key = $ProviderId.Trim().ToLowerInvariant()
    if ($Catalogue -and $Catalogue.ContainsKey($key)) { return $Catalogue[$key] }
    return $null
}

function Get-AiProviders {
    param([System.Collections.IDictionary]$Catalogue)
    if (-not $Catalogue) { return @() }
    return @($Catalogue.Values)
}

function Get-AiEnabledProviders {
    param([System.Collections.IDictionary]$Catalogue)
    if (-not $Catalogue) { return @() }
    return @($Catalogue.Values | Where-Object { $_.Enabled })
}

# --- catalogue validation -----------------------------------------------------------

function Validate-AiProviderCatalogue {
    param([System.Collections.IDictionary]$Catalogue)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Catalogue) { $errors.Add('Catalogue is null'); return @{ Valid = $false; Errors = @($errors) } }
    foreach ($key in $Catalogue.Keys) {
        $p = $Catalogue[$key]
        if ($p.ProviderId -ne $key) { $errors.Add("Catalogue key '$key' does not match record ProviderId '$($p.ProviderId)'") }
        $t = Test-AiProvider $p
        if (-not $t.Valid) { $errors.Add("Provider '$key': $($t.Errors -join '; ')") }
    }
    # secret scan across the whole catalogue
    $leak = Test-AiRoutingSecretValueLeak $Catalogue
    if ($leak.Leak) { $errors.Add('secret value detected in provider catalogue') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}

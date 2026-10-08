# AiRoutingContracts.ps1 — DB-M14 shared contracts for the AI routing foundation.
#
# Provider-independent vocabulary and contracts that later milestones consume:
#   - reasoning level normalization (NONE/LOW/MEDIUM/HIGH/MAX)
#   - provider health state vocabulary
#   - relative speed / reliability vocabularies
#   - schema version constants (frozen v1)
#   - capability-requirement request contract (task -> capabilities)
#   - routing-decision response contract
#   - secret-value leak guard
#   - provider-name branching guard (ADR-005 enforcement)
#
# Dot-source only. No AI API calls, no provider calls, no network, no secrets.
#
# ADR-005: capability is abstracted as AiRole -> Provider -> Model -> Configuration.
# No business logic branches on provider name.

function Get-AiRoutingSchemaVersions {
    <#
    .SYNOPSIS
    Frozen schema versions for DB-M14 v1 contracts. Later incompatible changes
    must introduce a new version (v2), never silently change v1 semantics.
    #>
    return @{
        AiRoutingConfigVersion        = 1
        ProviderVersion               = 1
        ModelVersion                  = 1
        CapabilityRequirementVersion  = 1
        RoutingDecisionVersion        = 1
    }
}

function Get-AiRoutingReasoningLevels {
    return @('NONE', 'LOW', 'MEDIUM', 'HIGH', 'MAX')
}

function Get-AiRoutingHealthStates {
    return @('AVAILABLE', 'RATE_LIMITED', 'DEGRADED', 'AUTH_ERROR', 'UNAVAILABLE', 'DISABLED', 'UNKNOWN')
}

function Get-AiRoutingRelativeSpeeds {
    return @('VERY_FAST', 'FAST', 'NORMAL', 'SLOW')
}

function Get-AiRoutingReliabilityClasses {
    return @('EXPERIMENTAL', 'STANDARD', 'HIGH', 'CRITICAL_GRADE')
}

function Get-AiRoutingProviderTypes {
    return @('DIRECT', 'GATEWAY', 'LOCAL', 'OPENAI_COMPATIBLE', 'OLLAMA_COMPATIBLE')
}

function Get-AiRoutingGatewayTypes {
    return @('DIRECT', 'ANTHROPIC_COMPATIBLE', 'OPENAI_COMPATIBLE', 'OLLAMA_COMPATIBLE', 'OPENROUTER')
}

function Get-AiRoutingExecutionModes {
    return @('MANUAL', 'ASSISTED', 'AUTO')
}

function Get-AiRoutingLocalOrRemote {
    return @('LOCAL', 'REMOTE', 'UNKNOWN')
}

function Get-AiRoutingTaskTypes {
    return @('PLANNING', 'IMPLEMENTATION', 'VERIFICATION', 'REVIEW', 'RESEARCH', 'GOVERNANCE')
}

# Order indices used for at-least / at-most comparisons in capability queries.
function Get-AiRoutingReliabilityOrder { return @{ 'EXPERIMENTAL' = 1; 'STANDARD' = 2; 'HIGH' = 3; 'CRITICAL_GRADE' = 4 } }
function Get-AiRoutingSpeedOrder { return @{ 'VERY_FAST' = 1; 'FAST' = 2; 'NORMAL' = 3; 'SLOW' = 4 } }
function Get-AiRoutingReasoningOrder { return @{ 'NONE' = 0; 'LOW' = 1; 'MEDIUM' = 2; 'HIGH' = 3; 'MAX' = 4 } }

# --- vocabulary membership tests --------------------------------------------------

function Test-IsValidReasoningLevel([string]$Value) { $Value -in (Get-AiRoutingReasoningLevels) }
function Test-IsValidHealthState([string]$Value)   { $Value -in (Get-AiRoutingHealthStates) }
function Test-IsValidRelativeSpeed([string]$Value)  { $Value -in (Get-AiRoutingRelativeSpeeds) }
function Test-IsValidReliabilityClass([string]$Value) { $Value -in (Get-AiRoutingReliabilityClasses) }
function Test-IsValidProviderType([string]$Value)   { $Value -in (Get-AiRoutingProviderTypes) }
function Test-IsValidGatewayType([string]$Value)    { $Value -in (Get-AiRoutingGatewayTypes) }
function Test-IsValidExecutionMode([string]$Value)  { $Value -in (Get-AiRoutingExecutionModes) }
function Test-IsValidLocalOrRemote([string]$Value)  { $Value -in (Get-AiRoutingLocalOrRemote) }
function Test-IsValidTaskType([string]$Value)       { $Value -in (Get-AiRoutingTaskTypes) }

# --- generic object property reader -----------------------------------------------

function Get-ContractProperty {
    <#
    .SYNOPSIS
    Read a property from a PSCustomObject or IDictionary defensively, returning a
    default when absent or null (JSON deserialization omits null properties).
    #>
    param(
        [AllowNull()][object]$Object,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

# --- secret-value guard -----------------------------------------------------------

function Test-AiRoutingSecretValueLeak {
    <#
    .SYNOPSIS
    Scan a provider/model record or catalogue for API-key-like VALUES.
    Field names that are references by design (SecretReference, ConfigurationKey,
    *Id, endpoint, names, notes) are exempt. DB-M14 stores references, never values.
    #>
    param(
        [AllowNull()][object]$Target
    )
    $exempt = @(
        'SecretReference', 'ConfigurationKey', 'ProviderId', 'ModelId', 'ProviderModelId',
        'UnderlyingModelId', 'GatewayProviderId', 'DisplayName', 'ModelFamily',
        'ModelVersion', 'BaseEndpoint', 'EndpointOverride', 'Notes', 'RoutingReason',
        'PolicyVersion', 'SchemaVersion', 'ExecutionMode', 'TaskType', 'Complexity',
        'Risk', 'ProviderType', 'GatewayType', 'LocalOrRemote', 'RelativeSpeed',
        'ReliabilityClass', 'ReasoningLevelsSupported', 'AdditionalCapabilityTags',
        'SelectedProviderId', 'SelectedModelId', 'RoutingRequestId', 'TaskId',
        'DecisionTimestamp', 'ManualOverride', 'RequiredReliability', 'PreferredLatency',
        'MinimumReasoningLevel', 'HealthState'
    )
    $patterns = @(
        '^sk-[A-Za-z0-9_-]{8,}$',                 # OpenAI-style
        '^AIza[0-9A-Za-z_-]{10,}$',               # Google-style
        '^gh[pousr]_[A-Za-z0-9]{20,}$',           # GitHub tokens
        '^[A-Za-z0-9+/=_\-]{32,}$',               # generic high-entropy token
        '^-----BEGIN'                             # PEM block
    )
    $leaks = New-Object System.Collections.Generic.List[string]

    function Test-LeakValue([string]$fieldName, [object]$value) {
        if ($null -eq $value) { return }
        if ($fieldName -in $exempt) { return }
        $s = [string]$value
        if ($s.Length -lt 8) { return }
        foreach ($p in $patterns) {
            if ($s -match $p) {
                $leaks.Add("$fieldName = <redacted> matches $p")
                return
            }
        }
        # key=value inline forms
        if ($s -match '(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*\S') {
            $leaks.Add("$fieldName contains inline credential assignment")
        }
    }

    function Test-LeakObject([string]$path, [object]$obj) {
        if ($null -eq $obj) { return }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($k in $obj.Keys) {
                $v = $obj[$k]
                $name = if ($path) { "$path.$k" } else { [string]$k }
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) {
                    Test-LeakObject $name $v
                } elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) {
                        if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-LeakObject $name $item }
                        else { Test-LeakValue ([string]$k) $item }
                    }
                } else {
                    Test-LeakValue ([string]$k) $v
                }
            }
            return
        }
        if ($obj -is [PSCustomObject]) {
            foreach ($prop in $obj.PSObject.Properties) {
                $name = if ($path) { "$path.$($prop.Name)" } else { $prop.Name }
                $v = $prop.Value
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) {
                    Test-LeakObject $name $v
                } elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) {
                        if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-LeakObject $name $item }
                        else { Test-LeakValue $prop.Name $item }
                    }
                } else {
                    Test-LeakValue $prop.Name $v
                }
            }
            return
        }
        Test-LeakValue 'value' $obj
    }

    Test-LeakObject '' $Target
    return @{ Leak = ($leaks.Count -gt 0); Fields = @($leaks) }
}

# --- capability requirement contract (Phase 8) --------------------------------------

function New-AiCapabilityRequirement {
    <#
    .SYNOPSIS
    The stable request contract future task classification (DB-M18) and routing
    (DB-M19) will consume. Most values remain optional/null until classification
    exists; DB-M14 defines the contract only.
    #>
    param(
        [string]$TaskId,
        [string]$TaskType,
        [string]$Complexity,
        [string]$Risk,
        [Nullable[bool]]$RequiresCoding,
        [Nullable[bool]]$RequiresReasoning,
        [string]$MinimumReasoningLevel,
        [Nullable[bool]]$RequiresVision,
        [Nullable[bool]]$RequiresToolUse,
        [Nullable[bool]]$RequiresStructuredOutput,
        [Nullable[long]]$RequiredContextTokens,
        [Nullable[long]]$ExpectedOutputTokens,
        [string]$PreferredLatency,
        [string]$RequiredReliability,
        [Nullable[bool]]$LocalAllowed,
        [Nullable[bool]]$RemoteAllowed,
        [string[]]$AllowedProviders,
        [string[]]$DisallowedProviders,
        [string[]]$AllowedModels,
        [string[]]$DisallowedModels,
        [Nullable[bool]]$HumanReviewRequired,
        [Nullable[double]]$MaxAllowedCost,
        [string]$ExecutionMode = 'MANUAL',
        [string[]]$AdditionalCapabilityTags
    )
    # normalize list params: absent/null -> empty array (never @($null))
    $ap  = @(); if ($AllowedProviders)    { $ap  = @($AllowedProviders) }
    $dp  = @(); if ($DisallowedProviders) { $dp  = @($DisallowedProviders) }
    $am  = @(); if ($AllowedModels)       { $am  = @($AllowedModels) }
    $dm  = @(); if ($DisallowedModels)    { $dm  = @($DisallowedModels) }
    $tag = @(); if ($AdditionalCapabilityTags) { $tag = @($AdditionalCapabilityTags) }

    $req = [pscustomobject]@{
        SchemaVersion             = 1
        TaskId                    = $TaskId
        TaskType                  = $TaskType
        Complexity                = $Complexity
        Risk                      = $Risk
        RequiresCoding            = $RequiresCoding
        RequiresReasoning         = $RequiresReasoning
        MinimumReasoningLevel     = $MinimumReasoningLevel
        RequiresVision            = $RequiresVision
        RequiresToolUse           = $RequiresToolUse
        RequiresStructuredOutput  = $RequiresStructuredOutput
        RequiredContextTokens     = $RequiredContextTokens
        ExpectedOutputTokens      = $ExpectedOutputTokens
        PreferredLatency          = $PreferredLatency
        RequiredReliability       = $RequiredReliability
        LocalAllowed              = $LocalAllowed
        RemoteAllowed             = $RemoteAllowed
        AllowedProviders          = $ap
        DisallowedProviders       = $dp
        AllowedModels             = $am
        DisallowedModels          = $dm
        HumanReviewRequired       = $HumanReviewRequired
        MaxAllowedCost            = $MaxAllowedCost
        ExecutionMode             = $ExecutionMode
        AdditionalCapabilityTags  = $tag
    }
    return $req
}

function Test-AiCapabilityRequirement {
    param([pscustomobject]$Requirement)
    $errors = New-Object System.Collections.Generic.List[string]
    $v = Get-AiRoutingSchemaVersions
    if ($null -eq $Requirement) { return @{ Valid = $false; Errors = @('Requirement is null') } }
    if ((Get-ContractProperty $Requirement 'SchemaVersion' -1) -ne 1) { $errors.Add("SchemaVersion must be 1 (found $((Get-ContractProperty $Requirement 'SchemaVersion' '?')))") }
    if ($Requirement.ExecutionMode -and -not (Test-IsValidExecutionMode $Requirement.ExecutionMode)) { $errors.Add("ExecutionMode '$($Requirement.ExecutionMode)' invalid") }
    if ($Requirement.TaskType -and -not (Test-IsValidTaskType $Requirement.TaskType)) { $errors.Add("TaskType '$($Requirement.TaskType)' invalid") }
    if ($Requirement.Complexity -and $Requirement.Complexity -notin @('LOW','MEDIUM','HIGH')) { $errors.Add("Complexity '$($Requirement.Complexity)' invalid") }
    if ($Requirement.Risk -and $Requirement.Risk -notin @('LOW','MEDIUM','HIGH')) { $errors.Add("Risk '$($Requirement.Risk)' invalid") }
    if ($Requirement.MinimumReasoningLevel -and -not (Test-IsValidReasoningLevel $Requirement.MinimumReasoningLevel)) { $errors.Add("MinimumReasoningLevel '$($Requirement.MinimumReasoningLevel)' invalid") }
    if ($Requirement.PreferredLatency -and -not (Test-IsValidRelativeSpeed $Requirement.PreferredLatency)) { $errors.Add("PreferredLatency '$($Requirement.PreferredLatency)' invalid") }
    if ($Requirement.RequiredReliability -and -not (Test-IsValidReliabilityClass $Requirement.RequiredReliability)) { $errors.Add("RequiredReliability '$($Requirement.RequiredReliability)' invalid") }
    if ($null -ne $Requirement.RequiredContextTokens -and $Requirement.RequiredContextTokens -lt 0) { $errors.Add('RequiredContextTokens must be >= 0') }
    if ($null -ne $Requirement.ExpectedOutputTokens -and $Requirement.ExpectedOutputTokens -lt 0) { $errors.Add('ExpectedOutputTokens must be >= 0') }
    if ($null -ne $Requirement.MaxAllowedCost -and $Requirement.MaxAllowedCost -lt 0) { $errors.Add('MaxAllowedCost must be >= 0') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}

# --- routing decision contract (Phase 9) -------------------------------------------

function New-AiRoutingDecision {
    <#
    .SYNOPSIS
    Future routing-result shape. Cost fields stay null until DB-M15/M16. DB-M14
    only defines the shape; no routing logic exists.
    #>
    param(
        [string]$RoutingRequestId,
        [string]$TaskId,
        [string]$SelectedProviderId,
        [string]$SelectedModelId,
        [string]$UnderlyingModelId,
        [string]$GatewayProviderId,
        [string]$ReasoningLevel,
        [string[]]$EligibleCandidateIds,
        [string[]]$RejectedCandidateIds,
        [string]$RoutingReason,
        [Nullable[long]]$EstimatedContextTokens,
        [Nullable[long]]$EstimatedOutputTokens,
        [Nullable[double]]$EstimatedCost,
        [string]$PolicyVersion = '0.0.0',
        [bool]$ManualOverride = $false,
        [string]$DecisionTimestamp = (Get-Date -Format o)
    )
    $dec = [pscustomobject]@{
        SchemaVersion          = 1
        RoutingRequestId       = $RoutingRequestId
        TaskId                 = $TaskId
        SelectedProviderId     = $SelectedProviderId
        SelectedModelId        = $SelectedModelId
        UnderlyingModelId      = $UnderlyingModelId
        GatewayProviderId      = $GatewayProviderId
        ReasoningLevel         = $ReasoningLevel
        EligibleCandidateIds   = @($EligibleCandidateIds)
        RejectedCandidateIds   = @($RejectedCandidateIds)
        RoutingReason          = $RoutingReason
        EstimatedContextTokens = $EstimatedContextTokens
        EstimatedOutputTokens  = $EstimatedOutputTokens
        EstimatedCost          = $EstimatedCost
        PolicyVersion          = $PolicyVersion
        ManualOverride         = $ManualOverride
        DecisionTimestamp      = $DecisionTimestamp
    }
    return $dec
}

function Test-AiRoutingDecision {
    param([pscustomobject]$Decision)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Decision) { return @{ Valid = $false; Errors = @('Decision is null') } }
    if ((Get-ContractProperty $Decision 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not $Decision.RoutingRequestId -and -not $Decision.TaskId) { $errors.Add('RoutingRequestId or TaskId is required') }
    if ($Decision.ReasoningLevel -and -not (Test-IsValidReasoningLevel $Decision.ReasoningLevel)) { $errors.Add("ReasoningLevel '$($Decision.ReasoningLevel)' invalid") }
    if ($null -ne $Decision.ManualOverride -and ($Decision.ManualOverride -isnot [bool])) { $errors.Add('ManualOverride must be bool') }
    if (-not $Decision.PolicyVersion) { $errors.Add('PolicyVersion is required') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}

# --- provider-name branching guard (ADR-005) ----------------------------------------

function Test-AiProviderNameBranching {
    <#
    .SYNOPSIS
    Deterministic guard against ADR-005 violations: direct comparisons of a
    Provider/Model identifier against a literal provider/model name in shared
    business logic. Provider adapters (future DB-M23) are the only legitimate
    exception and live in their own directory.
    #>
    param(
        [string[]]$Paths,
        [string]$LiteralContent
    )
    # comparison operators take a quoted literal directly; membership operators
    # (-in/-notin) may take @('a', 'b') or a single quoted literal
    $pattern = '(?i)(?<prop>ProviderId|ProviderName|Provider|ModelId|ModelName|Model|ProviderModelId|GatewayProviderId)\s*(?<op>-eq|-ne|-in|-notin|-match|-like|-ceq|-cne)\s*(?:@\(|\[)?\s*["''`](?<lit>[A-Za-z0-9_.\-]{2,})["''`]'
    $violations = New-Object System.Collections.Generic.List[string]

    if ($LiteralContent) {
        foreach ($m in [regex]::Matches($LiteralContent, $pattern)) {
            $violations.Add("literal: prop=$($m.Groups['prop'].Value) op=$($m.Groups['op'].Value) literal=$($m.Groups['lit'].Value)")
        }
    }
    foreach ($path in $Paths) {
        if (-not (Test-Path $path)) { continue }
        $files = if ((Get-Item $path).PSIsContainer) { @(Get-ChildItem $path -Filter *.ps1 -File -Recurse) } else { @(Get-Item $path) }
        foreach ($f in $files) {
            $text = Get-Content $f.FullName -Raw -Encoding UTF8
            $lineNo = 0
            foreach ($line in $text -split "`n") {
                $lineNo++
                foreach ($m in [regex]::Matches($line, $pattern)) {
                    $violations.Add("$($f.Name):$lineNo prop=$($m.Groups['prop'].Value) op=$($m.Groups['op'].Value) literal=$($m.Groups['lit'].Value)")
                }
            }
        }
    }
    return @{ Clean = ($violations.Count -eq 0); Violations = @($violations) }
}

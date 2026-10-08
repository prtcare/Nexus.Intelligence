# CalculatorContracts.ps1 -- DB-M27 AI Cost Calculator UI contracts.
#
# Operator-facing cost calculator that ESTIMATES the expected monetary cost of a
# model/provider configuration BEFORE execution. Calculation / UI only: it never
# executes a provider/model, never makes a paid API call, and never makes a network
# call. Every token->cost number is computed by the DB-M16 authoritative engine
# (Calculate-AiAttemptCost); DB-M27 does NOT duplicate pricing formulas or data.
#
# Reuse is READ-ONLY. This file dot-sources the same cost/quality/performance/budget
# chain the DB-M26 dashboard consumes, plus the DB-M23 local/gateway price-status
# table and the DB-M16 cost engine. No DB-M14..M26 file is modified by DB-M27.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB27_*).
# ASCII-only source (PS 5.1 + BOM-safe). No secrets, no credentials.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- READ-ONLY reuse chain (mirrors ai-routing/dashboard) ------------------
. (Join-Path $PSScriptRoot '..\AiRoutingCostFoundation.ps1')                  # DB-M14 + DB-M15 + DB-M16 (read-only)
. (Join-Path $PSScriptRoot '..\providers\common\AdapterExecutionGate.ps1')    # DB-M23 price-status table (read-only)
. (Join-Path $PSScriptRoot '..\budget\BudgetPolicy.ps1')                      # DB-M21 (read-only)
. (Join-Path $PSScriptRoot '..\budget\BudgetEngine.ps1')                      # DB-M21 engine (read-only)
. (Join-Path $PSScriptRoot '..\quality-cost\AiQualityCostContracts.ps1')      # DB-M25 contracts (read-only)
. (Join-Path $PSScriptRoot '..\quality-cost\QualityCost.ps1')                 # DB-M25 engine (read-only)
. (Join-Path $PSScriptRoot '..\escalation\EscalationContracts.ps1')           # DB-M20 vocabulary (read-only)
. (Join-Path $PSScriptRoot '..\provider-health\ProviderHealthContracts.ps1')  # DB-M22 vocabulary (read-only)

# --- vocabularies ------------------------------------------------------------------

function Get-DbM27SchemaVersions {
    @{
        CalculatorRequestVersion = 1
        CalculatorViewVersion    = 1
        SelectorDataVersion      = 1
        ReadOnlyGuardVersion     = 1
        EscalationStepVersion    = 1
    }
}

function Get-DbM27RouteTypes   { @('DIRECT', 'GATEWAY', 'LOCAL') }
function Get-DbM27Currencies   { @('USD', 'INR') }
function Get-DbM27EstimatedOrActualValues { @('ESTIMATED', 'ACTUAL') }
function Get-DbM27CalculationBasis       { @('ENGINE', 'PREVIEW') }
function Get-DbM27ModelLookupStates      { @('FOUND', 'NOT_FOUND', 'INVALID_ROUTE', 'PROVIDER_UNKNOWN') }
function Get-DbM27PricingStatuses        { Get-DbM23PriceStatuses }   # CONFIGURED/FREE/LOCAL_COST_UNKNOWN/PRICE_UNKNOWN (DB-M23)

function Test-IsValidDbM27RouteType([string]$Value) { $Value -in (Get-DbM27RouteTypes) }
function Test-IsValidDbM27Currency([string]$Value)  { $Value -in (Get-DbM27Currencies) }

# --- read-only guard ----------------------------------------------------------------

function New-DbM27ReadOnlyGuard {
    <#
    .SYNOPSIS
    Deterministic read-only / no-execution guard for the calculator view. The
    calculator can never execute a provider/model, never make a paid or network
    call, and can never modify budget/routing/pricing/health/workbook/source.
    #>
    return [pscustomobject]@{
        SchemaVersion           = 1
        AutoExecutionEnabled    = $false
        HasWriteActions         = $false
        PolicyVersion           = '0.0.0'
        ProviderModelExecuted   = $false
        PaidApiCalls            = 0
        NetworkCalls            = 0
        BudgetPolicyUnmodified  = $true
        RoutingPolicyUnmodified = $true
        PricingUnmodified       = $true
        ProviderHealthUnmodified = $true
        NexusWorkbookUnmodified = $true
        NexusSourceUnmodified   = $true
        GitUnmodified           = $true
        InformationalOnly       = $true
    }
}

function Test-DbM27SecretLeak {
    <#
    .SYNOPSIS
    Scans a string for common secret-bearing patterns. Returns @{ Leak; Fields }.
    Mirrors the DB-M23/DB-M26 secret-leak guard. Never used to store a secret.
    #>
    param([AllowNull()][object]$Target)
    $text = ''
    if ($Target -is [string]) { $text = $Target }
    elseif ($Target) { $text = [string]$Target }
    if (-not $text) { return @{ Leak = $false; Fields = @() } }
    $leaks = New-Object System.Collections.Generic.List[string]
    $patterns = @(
        '(?im)(api[\s_-]?key\s*[:=]\s*["'']?[A-Za-z0-9_\-]{12,})',
        '(?im)(authorization\s*[:=]\s*["'']?(bearer\s+)?[A-Za-z0-9_\-\.]{16,})',
        '(?im)(sk-[A-Za-z0-9_\-]{16,})',
        '(?im)(password\s*[:=]\s*["'']?[^"'']{8,})',
        '(?im)(secret\s*[:=]\s*["'']?[A-Za-z0-9_\-]{12,})'
    )
    foreach ($p in $patterns) {
        if ($text -match $p) { $leaks.Add($p) }
    }
    return @{ Leak = ($leaks.Count -gt 0); Fields = @($leaks.ToArray()) }
}

# --- request -------------------------------------------------------------------------

function New-DbM27EscalationStep {
    <#
    .SYNOPSIS
    Normalize one read-only escalation-path step. Cost simulation only: the step
    only describes which model would be used next; it never changes routing policy.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [Nullable[long]]$Step,
        [string]$ProviderId,
        [string]$ModelId,
        [Nullable[long]]$AttemptCount = 1,
        [string]$PricingRecordId,
        [string]$ReasoningLevel
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }
    return [pscustomobject]@{
        SchemaVersion    = 1
        Step             = if ($InputObject) { & $g 'Step' $Step } else { $Step }
        ProviderId       = if ($InputObject) { [string](& $g 'ProviderId' $ProviderId) } else { $ProviderId }
        ModelId          = if ($InputObject) { [string](& $g 'ModelId' $ModelId) } else { $ModelId }
        AttemptCount     = if ($InputObject) { & $g 'AttemptCount' $AttemptCount } else { $AttemptCount }
        PricingRecordId  = if ($InputObject) { [string](& $g 'PricingRecordId' $PricingRecordId) } else { $PricingRecordId }
        ReasoningLevel   = if ($InputObject) { [string](& $g 'ReasoningLevel' $ReasoningLevel) } else { $ReasoningLevel }
    }
}

function New-DbM27CalculatorRequest {
    <#
    .SYNOPSIS
    Build the operator's calculator request. Every field is validated by
    Test-DbM27CalculatorRequest before the engine runs. NowUtc is injected so the
    engine is deterministic and testable.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$ProviderId,
        [string]$RouteType,
        [string]$ModelId,
        [string]$UnderlyingModelId,
        [string]$PricingRecordId,
        [string]$ReasoningLevel,
        [Nullable[long]]$InputTokens = 0,
        [Nullable[long]]$OutputTokens = 0,
        [Nullable[long]]$CachedInputTokens = 0,
        [Nullable[long]]$CacheWriteTokens = 0,
        [Nullable[long]]$AttemptCount = 1,
        [Nullable[long]]$ExpectedCorrectionAttempts = 0,
        [AllowNull()][object[]]$EscalationPath = $null,
        [string]$CurrencyTarget = 'USD',
        [string]$NowUtc
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }
    $steps = New-Object System.Collections.Generic.List[object]
    if ($InputObject) {
        $src = if ($InputObject.EscalationPath) { @($InputObject.EscalationPath) } else { @() }
        foreach ($s in $src) { $steps.Add((New-DbM27EscalationStep -InputObject $s)) }
    } elseif ($EscalationPath) {
        foreach ($s in @($EscalationPath)) { $steps.Add((New-DbM27EscalationStep -InputObject $s)) }
    }
    $reqIdNow = if ($NowUtc) { $NowUtc } else { '2026-08-31T00:00:00Z' }
    $reqIdEpoch = [long]((Get-Date -Date $reqIdNow -UFormat %s))
    return [pscustomobject]@{
        SchemaVersion               = 1
        RequestId                   = 'calc-' + ([math]::Abs($reqIdEpoch))
        ProviderId                  = if ($InputObject) { [string](& $g 'ProviderId' $ProviderId) } else { $ProviderId }
        RouteType                   = if ($InputObject) { [string](& $g 'RouteType' $RouteType) } else { $RouteType }
        ModelId                     = if ($InputObject) { [string](& $g 'ModelId' $ModelId) } else { $ModelId }
        UnderlyingModelId           = if ($InputObject) { [string](& $g 'UnderlyingModelId' $UnderlyingModelId) } else { $UnderlyingModelId }
        PricingRecordId             = if ($InputObject) { [string](& $g 'PricingRecordId' $PricingRecordId) } else { $PricingRecordId }
        ReasoningLevel              = if ($InputObject) { [string](& $g 'ReasoningLevel' $ReasoningLevel) } else { $ReasoningLevel }
        InputTokens                 = if ($InputObject) { & $g 'InputTokens' $InputTokens } else { $InputTokens }
        OutputTokens                = if ($InputObject) { & $g 'OutputTokens' $OutputTokens } else { $OutputTokens }
        CachedInputTokens           = if ($InputObject) { & $g 'CachedInputTokens' $CachedInputTokens } else { $CachedInputTokens }
        CacheWriteTokens            = if ($InputObject) { & $g 'CacheWriteTokens' $CacheWriteTokens } else { $CacheWriteTokens }
        AttemptCount                = if ($InputObject) { & $g 'AttemptCount' $AttemptCount } else { $AttemptCount }
        ExpectedCorrectionAttempts  = if ($InputObject) { & $g 'ExpectedCorrectionAttempts' $ExpectedCorrectionAttempts } else { $ExpectedCorrectionAttempts }
        EscalationPath              = @($steps.ToArray())
        CurrencyTarget              = if ($InputObject) { [string](& $g 'CurrencyTarget' $CurrencyTarget) } else { $CurrencyTarget }
        NowUtc                      = if ($InputObject) { [string](& $g 'NowUtc' $NowUtc) } else { $NowUtc }
        UsageSource                 = 'ESTIMATED'
    }
}

function Test-DbM27CalculatorRequest {
    <#
    .SYNOPSIS
    Validate a CalculatorRequest v1. Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][object]$Request)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Request) { return @{ Valid = $false; Errors = @('Request is null'); Warnings = @() } }
    if (-not [string]::IsNullOrWhiteSpace([string]$Request.ProviderId)) {
        if ($Request.ProviderId -notmatch '^[A-Za-z0-9._\-]{1,80}$') { $errors.Add("ProviderId '$($Request.ProviderId)' invalid") }
    } else { $errors.Add('ProviderId is required') }
    if (-not [string]::IsNullOrWhiteSpace([string]$Request.RouteType) -and -not (Test-IsValidDbM27RouteType ([string]$Request.RouteType))) {
        $errors.Add("RouteType '$($Request.RouteType)' must be DIRECT|GATEWAY|LOCAL")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Request.ModelId) -and $Request.ModelId -notmatch '^[A-Za-z0-9._\-:]{1,160}$') {
        $errors.Add("ModelId '$($Request.ModelId)' invalid")
    }
    if ([string]::IsNullOrWhiteSpace([string]$Request.ModelId)) { $errors.Add('ModelId is required') }
    if ([string]::IsNullOrWhiteSpace([string]$Request.CurrencyTarget)) { $errors.Add('CurrencyTarget is required') }
    elseif (-not (Test-IsValidDbM27Currency ([string]$Request.CurrencyTarget))) { $errors.Add("CurrencyTarget '$($Request.CurrencyTarget)' must be USD|INR") }
    if (-not [string]::IsNullOrWhiteSpace([string]$Request.NowUtc)) {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$Request.NowUtc, [ref]$d)) { $errors.Add("NowUtc '$($Request.NowUtc)' not a parseable date") }
    }
    foreach ($dim in @('InputTokens', 'OutputTokens', 'CachedInputTokens', 'CacheWriteTokens', 'ExpectedCorrectionAttempts')) {
        $v = Get-ContractProperty $Request $dim $null
        if ($null -ne $v -and $v -lt 0) { $errors.Add("$dim must be >= 0 (found $v)") }
    }
    $ac = Get-ContractProperty $Request 'AttemptCount' $null
    if ($null -ne $ac -and $ac -lt 1) { $errors.Add("AttemptCount must be >= 1 (found $ac)") }
    if ($null -eq $ac) { $errors.Add('AttemptCount is required') }
    $path = @(Get-ContractProperty $Request 'EscalationPath' @())
    for ($i = 0; $i -lt $path.Count; $i++) {
        $s = $path[$i]
        $st = Get-ContractProperty $s 'Step' $null
        if ($null -eq $st -or [long]$st -lt 1) { $errors.Add("EscalationPath[$i].Step must be >= 1") }
        if ([string]::IsNullOrWhiteSpace([string](Get-ContractProperty $s 'ProviderId' ''))) { $errors.Add("EscalationPath[$i].ProviderId is required") }
        if ([string]::IsNullOrWhiteSpace([string](Get-ContractProperty $s 'ModelId' ''))) { $errors.Add("EscalationPath[$i].ModelId is required") }
        $sa = Get-ContractProperty $s 'AttemptCount' $null
        if ($null -ne $sa -and $sa -lt 1) { $errors.Add("EscalationPath[$i].AttemptCount must be >= 1") }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Request.RouteType)) { $warnings.Add('RouteType empty; the engine will derive it from the provider record') }
    if ([string]::IsNullOrWhiteSpace([string]$Request.UnderlyingModelId)) { $warnings.Add('UnderlyingModelId empty; the engine will resolve it from the model catalogue') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @($warnings.ToArray()) }
}

# --- selector data (catalogue projection for the interactive UI) ----------------------

function New-DbM27SelectorData {
    <#
    .SYNOPSIS
    Project the loaded cost configuration into the selector data the interactive
    page needs: providers (with route types), models, pricing records, currencies,
    and exchange rates. Pure projection; no writes; no execution.
    #>
    param(
        [AllowNull()][object]$Configuration,
        [string]$NowUtc = '2026-08-31T00:00:00Z'
    )
    $providers = New-Object System.Collections.Generic.List[object]
    $models = New-Object System.Collections.Generic.List[object]
    $pricing = New-Object System.Collections.Generic.List[object]
    $fx = New-Object System.Collections.Generic.List[object]

    $prov = @{}
    if ($Configuration -and $Configuration.Providers) {
        foreach ($key in @($Configuration.Providers.Keys)) {
            $p = $Configuration.Providers[$key]
            $routeType = [string](Get-ContractProperty $p 'ProviderType' 'DIRECT')
            if ($routeType -notin (Get-DbM27RouteTypes)) { $routeType = 'DIRECT' }
            $providers.Add([pscustomobject]@{
                ProviderId  = [string](Get-ContractProperty $p 'ProviderId' $key)
                DisplayName = [string](Get-ContractProperty $p 'DisplayName' '')
                RouteType   = $routeType
                GatewayType = [string](Get-ContractProperty $p 'GatewayType' '')
                Enabled     = [bool](Get-ContractProperty $p 'Enabled' $false)
                Configured  = [bool](Get-ContractProperty $p 'Configured' $false)
            })
            $prov[[string](Get-ContractProperty $p 'ProviderId' $key).ToLowerInvariant()] = $routeType
        }
    }
    if ($Configuration -and $Configuration.Models) {
        foreach ($key in @($Configuration.Models.Keys)) {
            $m = $Configuration.Models[$key]
            $models.Add([pscustomobject]@{
                ModelId                = [string](Get-ContractProperty $m 'ModelId' $key)
                ProviderId             = [string](Get-ContractProperty $m 'ProviderId' '')
                ProviderModelId        = [string](Get-ContractProperty $m 'ProviderModelId' '')
                UnderlyingModelId      = [string](Get-ContractProperty $m 'UnderlyingModelId' '')
                GatewayProviderId      = [string](Get-ContractProperty $m 'GatewayProviderId' '')
                LocalOrRemote          = [string](Get-ContractProperty $m 'LocalOrRemote' 'REMOTE')
                ReasoningLevelsSupported = @(Get-ContractProperty $m 'ReasoningLevelsSupported' @())
                Enabled                = [bool](Get-ContractProperty $m 'Enabled' $false)
                DisplayName            = [string](Get-ContractProperty $m 'DisplayName' '')
            })
        }
    }
    if ($Configuration -and $Configuration.Pricing) {
        foreach ($r in @(Get-AiPricingRecords -Catalogue $Configuration.Pricing)) {
            $st = Get-AiPricingRecordStatus -Record $r -AsOfUtc $NowUtc
            $pricing.Add([pscustomobject]@{
                PricingRecordId            = [string](Get-ContractProperty $r 'PricingRecordId' '')
                ProviderId                 = [string](Get-ContractProperty $r 'ProviderId' '')
                ModelId                    = [string](Get-ContractProperty $r 'ModelId' '')
                Currency                   = [string](Get-ContractProperty $r 'Currency' 'USD')
                InputPricePerMillion       = Get-ContractProperty $r 'InputPricePerMillion' $null
                CachedInputPricePerMillion = Get-ContractProperty $r 'CachedInputPricePerMillion' $null
                CacheWrite5mPricePerMillion  = Get-ContractProperty $r 'CacheWrite5mPricePerMillion' $null
                CacheWrite1hPricePerMillion  = Get-ContractProperty $r 'CacheWrite1hPricePerMillion' $null
                OutputPricePerMillion      = Get-ContractProperty $r 'OutputPricePerMillion' $null
                ReasoningTokenPricePerMillion = Get-ContractProperty $r 'ReasoningTokenPricePerMillion' $null
                EffectiveFromUtc           = [string](Get-ContractProperty $r 'EffectiveFromUtc' '')
                EffectiveToUtc             = [string](Get-ContractProperty $r 'EffectiveToUtc' '')
                Status                     = [string]$st.Status
                StatusReason               = [string]$st.Reason
                Source                     = [string](Get-ContractProperty $r 'Source' '')
                VerifiedAtUtc              = [string](Get-ContractProperty $r 'VerifiedAtUtc' '')
                ManualOverride             = [bool](Get-ContractProperty $r 'ManualOverride' $false)
            })
        }
    }
    if ($Configuration -and $Configuration.ExchangeRates) {
        foreach ($key in @($Configuration.ExchangeRates.Keys)) {
            $x = $Configuration.ExchangeRates[$key]
            $fx.Add([pscustomobject]@{
                ExchangeRateId = [string](Get-ContractProperty $x 'ExchangeRateId' $key)
                BaseCurrency   = [string](Get-ContractProperty $x 'BaseCurrency' 'USD')
                QuoteCurrency  = [string](Get-ContractProperty $x 'QuoteCurrency' '')
                Rate           = Get-ContractProperty $x 'Rate' $null
                Source         = [string](Get-ContractProperty $x 'Source' '')
                EffectiveFromUtc = [string](Get-ContractProperty $x 'EffectiveFromUtc' '')
            })
        }
    }
    return [pscustomobject]@{
        SchemaVersion = 1
        Providers     = @($providers.ToArray())
        Models        = @($models.ToArray())
        PricingRecords = @($pricing.ToArray())
        Currencies    = @(Get-DbM27Currencies)
        ExchangeRates = @($fx.ToArray())
        RouteTypeByProvider = $prov
        PricingSource = 'config/pricing/pricing-catalogue.json (DB-M15, read-only)'
        ExchangeSource = 'config/currency/exchange-rates.json (DB-M16, read-only)'
    }
}

# --- view ------------------------------------------------------------------------------

function New-DbM27CalculatorView {
    <#
    .SYNOPSIS
    Assemble the CalculatorView v1 from computed fields. The engine fills every
    field; this constructor guarantees the shape and stamps the read-only guard.
    #>
    param(
        [AllowNull()][object]$Request,
        [AllowNull()][object]$Scenario,
        [AllowNull()][object]$Pricing,
        [AllowNull()][object]$Estimate,
        [AllowNull()][object]$Quality,
        [AllowNull()][object[]]$EscalationSteps,
        [AllowNull()][object]$EscalationTotal,
        [AllowNull()][object]$Budget,
        [AllowNull()][object]$Guard,
        [AllowNull()][object]$SelectorData,
        [string[]]$Warnings
    )
    return [pscustomobject]@{
        SchemaVersion    = 1
        Request          = $Request
        Scenario         = $Scenario
        Pricing          = $Pricing
        Estimate         = $Estimate
        Quality          = $Quality
        EscalationSteps  = @($EscalationSteps)
        EscalationTotal  = $EscalationTotal
        Budget           = $Budget
        Guard            = $Guard
        SelectorData     = $SelectorData
        Warnings         = @($Warnings)
        GeneratedAtUtc   = [string](Get-ContractProperty $Request 'NowUtc' '')
        CalculationBasis = 'ENGINE'
    }
}

# --- stdout markers (backend contract: always exit 0) ----------------------------------

function Out-DbM27Markers {
    param([string]$Token, [bool]$Pass, [string[]]$Evidence)
    Write-Output ("DB27_OUTCOME: " + $Token)
    Write-Output ("DB27_RESULT_PASS: " + $(if ($Pass) { "True" } else { "False" }))
    Write-Output ("DB27_RESULT_CODE: " + $Token)
    Write-Output "DB27_WORKBOOK_MODIFIED: False"
    Write-Output "DB27_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB27_GIT_MODIFIED: False"
    Write-Output "DB27_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB27_HUMAN_ACTION_TYPE:"
    foreach ($e in $Evidence) { Write-Output ("DB27_EVIDENCE: " + $e) }
    exit 0
}

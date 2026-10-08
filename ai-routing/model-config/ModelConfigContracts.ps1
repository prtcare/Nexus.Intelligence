# ModelConfigContracts.ps1 -- DB-M28 Model Configuration UI contracts.
#
# Operator-facing MODEL CONFIGURATION UI for the existing DevBridge AI subsystem.
# The UI lets the operator INSPECT which providers/routes/models and supported
# reasoning/capability options DevBridge may consider, and CONFIGURE operator
# policy (provider/model enablement and configuration status). DB-M28 never
# executes a provider/model, never makes a paid API call, and never makes a
# network call. AUTO_EXECUTION_ENABLED = FALSE.
#
# Reuse is READ-ONLY. This file dot-sources the same real DB-M14..M27 chain the
# dashboard and calculator consume. DB-M28 writes ONLY config\providers.json and
# config\models.json through its own validated atomic persistence adapter; it
# never writes pricing/currency/cost/performance config, never writes the Nexus
# workbook or Nexus source, never modifies budget policy, pricing records,
# provider-health state, or routing policy, and never overrides a DB-M19 hard
# capability gate.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB28_*).
# ASCII-only source (PS 5.1 + BOM-safe). No secrets, no credentials.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- READ-ONLY reuse chain ---------------------------------------------------------------
. (Join-Path $PSScriptRoot '..\router\Router.ps1')                       # DB-M14+15+16 + DB-M17/M24 + DB-M19 (read-only)
. (Join-Path $PSScriptRoot '..\provider-health\ProviderHealthEngine.ps1') # DB-M22 read-only health decisions
. (Join-Path $PSScriptRoot '..\providers\common\AdapterExecutionGate.ps1') # DB-M23 price status table (read-only)
. (Join-Path $PSScriptRoot '..\calculator\CalculatorEngine.ps1')          # DB-M27 calculator (read-only integration)

# --- vocabularies ------------------------------------------------------------------------

function Get-DbM28SchemaVersions {
    @{
        ConfigViewVersion    = 1
        ReadOnlyGuardVersion = 1
        ConfigChangeVersion  = 1
        AuditRecordVersion   = 1
        EligibilityRowVersion = 1
    }
}

function Get-DbM28TargetTypes   { @('PROVIDER', 'MODEL') }
function Get-DbM28ChangeCategories { @('PROVIDER', 'MODEL', 'CONFIG_STATUS') }
function Get-DbM28EditableProviderFields { @('Enabled', 'Configured', 'Notes') }
function Get-DbM28EditableModelFields { @('Enabled', 'Notes') }
function Get-DbM28SecretStatuses { @('CONFIGURED', 'NOT_CONFIGURED', 'INVALID_CONFIGURATION', 'NO_SECRET_REQUIRED') }
function Get-DbM28EligibilityStates {
    @('ELIGIBLE', 'DISABLED', 'CAPABILITY_MISMATCH', 'PRICING_UNKNOWN', 'PROVIDER_UNHEALTHY', 'CONFIGURATION_INCOMPLETE')
}
function Get-DbM28ImmutableConfigTargets {
    @(
        'config\ai-routing.json',
        'config\pricing\pricing-catalogue.json',
        'config\currency\exchange-rates.json',
        'config\cost\cost-calculator.json',
        'config\performance\confidence-bands.json',
        'config\devbridge.json'
    )
}
function Get-DbM28WritableConfigTargets { @('config\providers.json', 'config\models.json') }

function Test-IsValidDbM28TargetType([string]$Value) { $Value -in (Get-DbM28TargetTypes) }
function Test-IsValidDbM28EligibilityState([string]$Value) { $Value -in (Get-DbM28EligibilityStates) }

# --- read-only guard ----------------------------------------------------------------------

function New-DbM28ReadOnlyGuard {
    <#
    .SYNOPSIS
    Deterministic read-only / no-execution guard for the model-config view. The
    config UI can never execute a provider/model, never make a paid or network
    call, and never mutate budget/pricing/health/routing/workbook/source. It CAN
    write config\providers.json + config\models.json only through the validated
    atomic persistence adapter, and only fields the operator changes.
    #>
    return [pscustomobject]@{
        SchemaVersion                 = 1
        AutoExecutionEnabled          = $false
        ProviderModelExecuted         = $false
        PaidApiCalls                  = 0
        NetworkCalls                  = 0
        BudgetPolicyUnmodified        = $true
        PricingUnmodified             = $true
        ProviderHealthUnmodified      = $true
        RoutingPolicyUnmodified       = $true
        CapabilityHardChecksUnmodified = $true
        CanonicalWorkbookUnmodified   = $true
        NexusSourceUnmodified         = $true
        GitUnmodified                 = $true
        SecretValuesDisplayed         = $false
        SecretValuesLogged            = $false
        ConfigWriteAuthorizedScope    = @(Get-DbM28WritableConfigTargets)
        ConfigWriteAtomic             = $true
        ConfigWriteValidated          = $true
        ConfigWriteReadBack           = $true
        ConfigWriteAudited            = $true
    }
}

# --- secret-leak guard (mirrors DB-M14/DB-M23/DB-M26/DB-M27) --------------------------------

function Test-DbM28SecretLeak {
    <#
    .SYNOPSIS
    Scan text/objects for common secret-bearing values. Returns @{ Leak; Fields }.
    DB-M28 never renders or logs secret values; the guard is applied to every
    HTML output and audit record.
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

# --- config-change contracts ---------------------------------------------------------------

function New-DbM28ConfigChangeRequest {
    <#
    .SYNOPSIS
    The operator's configuration-change intent. Only target/field/value + action;
    TimestampUtc is injected for determinism. Validated by
    Test-DbM28ConfigChangeRequest before any persistence.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$ChangeId,
        [string]$Category,
        [string]$TargetType,
        [string]$TargetId,
        [string]$Field,
        [AllowNull()][object]$NewValue,
        [string]$OperatorAction = 'SET',
        [string]$NowUtc
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }
    $now = if ($InputObject) { [string](& $g 'NowUtc' $NowUtc) } else { $NowUtc }
    if (-not $now) { $now = '2026-08-31T12:00:00Z' }
    $epoch = [long]((Get-Date -Date $now -UFormat %s))
    $id = if ($InputObject) { [string](& $g 'ChangeId' $ChangeId) } else { $ChangeId }
    if (-not $id) { $id = 'cfg-' + ([math]::Abs($epoch)) }
    return [pscustomobject]@{
        SchemaVersion  = 1
        ChangeId       = $id
        Category       = if ($InputObject) { [string](& $g 'Category' $Category) } else { $Category }
        TargetType     = if ($InputObject) { [string](& $g 'TargetType' $TargetType) } else { $TargetType }
        TargetId       = if ($InputObject) { [string](& $g 'TargetId' $TargetId) } else { $TargetId }
        Field          = if ($InputObject) { [string](& $g 'Field' $Field) } else { $Field }
        NewValue       = if ($InputObject) { & $g 'NewValue' $NewValue } else { $NewValue }
        OperatorAction = if ($InputObject) { [string](& $g 'OperatorAction' $OperatorAction) } else { $OperatorAction }
        NowUtc         = $now
    }
}

function Test-DbM28ConfigChangeRequest {
    <#
    .SYNOPSIS
    Validate a ConfigChangeRequest v1. Only provider Enabled/Configured/Notes and
    model Enabled/Notes are editable in DB-M28. Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][object]$Request)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Request) { return @{ Valid = $false; Errors = @('Request is null'); Warnings = @() } }
    if (-not (Test-IsValidDbM28TargetType ([string](Get-ContractProperty $Request 'TargetType' '')))) {
        $errors.Add("TargetType '$(Get-ContractProperty $Request 'TargetType' '')' must be PROVIDER|MODEL")
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-ContractProperty $Request 'TargetId' ''))) {
        $errors.Add('TargetId is required')
    } else {
        $tid = [string](Get-ContractProperty $Request 'TargetId' '')
        if ($tid -notmatch '^[A-Za-z0-9._\-:]{1,160}$') { $errors.Add("TargetId '$tid' invalid") }
    }
    $tt = [string](Get-ContractProperty $Request 'TargetType' '')
    $field = [string](Get-ContractProperty $Request 'Field' '')
    if (-not $field) { $errors.Add('Field is required') }
    else {
        $allowed = if ($tt -eq 'PROVIDER') { @(Get-DbM28EditableProviderFields) } else { @(Get-DbM28EditableModelFields) }
        if ($field -notin $allowed) { $errors.Add("Field '$field' is not editable for $tt (allowed: $($allowed -join ', '))") }
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-ContractProperty $Request 'Category' ''))) { $errors.Add('Category is required') }
    $cat = [string](Get-ContractProperty $Request 'Category' '')
    if ($cat -and $cat -notin @(Get-DbM28ChangeCategories)) { $errors.Add("Category '$cat' must be one of $(@(Get-DbM28ChangeCategories) -join '|')") }
    if ($cat -eq 'PROVIDER' -and $tt -ne 'PROVIDER') { $errors.Add('Category PROVIDER requires TargetType PROVIDER') }
    if ($cat -eq 'MODEL' -and $tt -ne 'MODEL') { $errors.Add('Category MODEL requires TargetType MODEL') }
    $nv = Get-ContractProperty $Request 'NewValue' $null
    if ($field -in @('Enabled', 'Configured') -and $null -eq $nv) { $errors.Add("NewValue is required for field '$field' (bool)") }
    if ($field -eq 'Notes' -and -not [string]::IsNullOrWhiteSpace([string]$nv)) {
        $s = [string]$nv
        if ($s.Length -gt 500) { $errors.Add('Notes too long (max 500 chars)') }
        $leak = Test-DbM28SecretLeak $s
        if ($leak.Leak) { $errors.Add('Notes must not contain secret material') }
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-ContractProperty $Request 'OperatorAction' ''))) { $errors.Add('OperatorAction is required') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @($warnings.ToArray()) }
}

function New-DbM28ConfigChangeRecord {
    <#
    .SYNOPSIS
    The audited config-change record. OldValue/NewValue are NON-SECRET
    serializations; a provider row always redacts SecretReference. Never contains
    secret values.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [string]$ChangeId,
        [string]$TimestampUtc,
        [string]$Category,
        [string]$TargetType,
        [string]$TargetId,
        [string]$Field,
        [AllowNull()][object]$OldValue,
        [AllowNull()][object]$NewValue,
        [string]$OperatorAction,
        [int]$ConfigVersion = 1,
        [bool]$Applied = $false,
        [string[]]$RedactedFields
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }
    return [pscustomobject]@{
        SchemaVersion    = 1
        ChangeId         = if ($InputObject) { [string](& $g 'ChangeId' $ChangeId) } else { $ChangeId }
        TimestampUtc     = if ($InputObject) { [string](& $g 'TimestampUtc' $TimestampUtc) } else { $TimestampUtc }
        Category         = if ($InputObject) { [string](& $g 'Category' $Category) } else { $Category }
        TargetType       = if ($InputObject) { [string](& $g 'TargetType' $TargetType) } else { $TargetType }
        TargetId         = if ($InputObject) { [string](& $g 'TargetId' $TargetId) } else { $TargetId }
        Field            = if ($InputObject) { [string](& $g 'Field' $Field) } else { $Field }
        OldValue         = if ($InputObject) { & $g 'OldValue' $OldValue } else { $OldValue }
        NewValue         = if ($InputObject) { & $g 'NewValue' $NewValue } else { $NewValue }
        OperatorAction   = if ($InputObject) { [string](& $g 'OperatorAction' $OperatorAction) } else { $OperatorAction }
        ConfigVersion    = if ($InputObject) { & $g 'ConfigVersion' $ConfigVersion } else { $ConfigVersion }
        Applied          = if ($InputObject) { [bool](& $g 'Applied' $Applied) } else { $Applied }
        RedactedFields   = @(if ($InputObject) { & $g 'RedactedFields' $RedactedFields } else { $RedactedFields })
    }
}

# --- stdout markers (backend contract: always exit 0) -------------------------------------

function Out-DbM28Markers {
    param([string]$Token, [bool]$Pass, [string[]]$Evidence)
    Write-Output ("DB28_OUTCOME: " + $Token)
    Write-Output ("DB28_RESULT_PASS: " + $(if ($Pass) { "True" } else { "False" }))
    Write-Output ("DB28_RESULT_CODE: " + $Token)
    Write-Output "DB28_WORKBOOK_MODIFIED: False"
    Write-Output "DB28_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB28_GIT_MODIFIED: False"
    Write-Output "DB28_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB28_HUMAN_ACTION_TYPE:"
    foreach ($e in $Evidence) { Write-Output ("DB28_EVIDENCE: " + $e) }
    exit 0
}

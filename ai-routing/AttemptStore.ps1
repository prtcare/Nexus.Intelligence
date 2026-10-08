# AttemptStore.ps1 — DB-M17 attempt/usage history for the AI routing platform.
#
# Provider-independent, append-oriented record of every future AI model attempt.
# This milestone establishes identity + persistence contracts only. NO provider
# API calls, NO model execution, NO pricing calculation, NO routing, NO escalation
# behavior, NO automatic attempts.
#
# Frozen v1 contracts (DB-M17, additive to the DB-M14 freeze):
#   AiAttemptRecord v1  - one AI execution attempt (schemaVersion = 1)
#   AiAttemptHistory v1 - per-change append-only ordered index (schemaVersion = 1)
#
# Persistence (lightweight JSON, consistent with DevBridge conventions):
#   logs/tasks/<node>/<change>/ai-attempts/<AttemptId>.json      (canonical record)
#   logs/tasks/<node>/<change>/ai-attempts/history.json          (AiAttemptHistory v1)
#   state/attempts/<changeId>/index.json                         (discovery mirror)
#
# Append-oriented rule: every attempt stays in history. A later successful
# attempt NEVER erases earlier failed attempts. The attempt SET is immutable
# (append-only); a single record's lifecycle fields (PENDING -> RUNNING ->
# terminal) are updated in place, which is status progression, not erasure.
#
# Schema versioning: DB-M17 registers AiAttemptRecordVersion and
# AiAttemptHistoryVersion here (DB-M17-owned) rather than editing the DB-M14
# shared map in AiRoutingContracts.ps1 — the shared file is being written by the
# parallel DB-M15 lane and must not be edited concurrently. Merge into
# Get-AiRoutingSchemaVersions when the lanes converge.
#
# DB-M14 frozen provider/model contracts are READ here (dot-sourced), never
# modified. DB-M17 stores cost fields as evidence only; DB-M16 calculates them.
#
# ADR-005: no business logic branches on provider name. Provider/model ids are
# data validated against the frozen catalogues.

. (Join-Path $PSScriptRoot "AiRoutingContracts.ps1")   # vocabularies + shared helpers (read-only)

# --- schema versions (DB-M17-owned) ------------------------------------------

function Get-AiAttemptSchemaVersions {
    <#
    .SYNOPSIS
    Frozen DB-M17 schema versions. Incompatible changes must introduce v2 with
    their own validator; v1 semantics are never silently mutated.
    #>
    return @{
        AiAttemptRecordVersion  = 1
        AiAttemptHistoryVersion = 1
    }
}

# --- vocabularies --------------------------------------------------------------

function Get-AiAttemptResultStates {
    return @('PENDING', 'RUNNING', 'SUCCESS', 'FAILED', 'CANCELLED', 'ESCALATED', 'BLOCKED', 'WAITING_HUMAN', 'BUDGET_STOPPED')
}

function Get-AiAttemptTerminalStates {
    # States where the attempt is finished (no further lifecycle writes expected).
    return @('SUCCESS', 'FAILED', 'CANCELLED', 'ESCALATED', 'BLOCKED', 'BUDGET_STOPPED')
}

function Get-AiAttemptFailureCategories {
    return @('MODEL_QUALITY', 'PROVIDER_AVAILABILITY', 'RATE_LIMIT', 'AUTHENTICATION', 'TOOL_FAILURE',
             'BUILD_FAILURE', 'TEST_FAILURE', 'CONTEXT_FAILURE', 'BUDGET_FAILURE', 'VALIDATION_FAILURE', 'UNKNOWN')
}

function Get-AiAttemptUsageSources {
    # ACTUAL  = provider-reported usage. ESTIMATED = estimated. UNKNOWN = provider returned no usage.
    return @('ACTUAL', 'ESTIMATED', 'UNKNOWN')
}

function Get-AiAttemptVerificationResults {
    return @('VERIFIED', 'FAILED', 'PENDING')
}

function Test-IsValidAttemptResult([string]$Value)   { $Value -in (Get-AiAttemptResultStates) }
function Test-IsValidFailureCategory([string]$Value) { $Value -in (Get-AiAttemptFailureCategories) }
function Test-IsValidUsageSource([string]$Value)     { $Value -in (Get-AiAttemptUsageSources) }
function Test-IsValidVerificationResult([string]$Value) { $Value -in (Get-AiAttemptVerificationResults) }

# --- root / path resolution ----------------------------------------------------

function Resolve-AiAttemptRoot {
    <#
    .SYNOPSIS
    Locate the DevBridge root (the folder containing config\ai-routing.json).
    #>
    $dir = Split-Path -Parent $PSScriptRoot
    while ($dir) {
        if (Test-Path (Join-Path $dir "config\ai-routing.json")) { return $dir }
        $dir = Split-Path -Parent $dir
    }
    return Split-Path -Parent $PSScriptRoot
}

function Get-AiAttemptStoreDir {
    param([string]$Root = (Resolve-AiAttemptRoot), [string]$NodeId, [string]$ChangeId)
    if (-not $NodeId -or -not $ChangeId) { throw 'NodeId and ChangeId are required to resolve the attempt store directory' }
    return Join-Path $Root ("logs\tasks\{0}\{1}\ai-attempts" -f $NodeId, $ChangeId)
}

function Get-AiAttemptHistoryPath {
    param([string]$Root = (Resolve-AiAttemptRoot), [string]$NodeId, [string]$ChangeId)
    return Join-Path (Get-AiAttemptStoreDir -Root $Root -NodeId $NodeId -ChangeId $ChangeId) "history.json"
}

function Get-AiAttemptRecordPath {
    param([string]$Root = (Resolve-AiAttemptRoot), [string]$NodeId, [string]$ChangeId, [string]$AttemptId)
    if (-not $AttemptId) { throw 'AttemptId is required to resolve the record path' }
    return Join-Path (Get-AiAttemptStoreDir -Root $Root -NodeId $NodeId -ChangeId $ChangeId) ("{0}.json" -f $AttemptId)
}

function Get-AiAttemptStateIndexPath {
    param([string]$Root = (Resolve-AiAttemptRoot), [string]$ChangeId)
    if (-not $ChangeId) { throw 'ChangeId is required to resolve the state index path' }
    return Join-Path $Root ("state\attempts\{0}\index.json" -f $ChangeId)
}

# --- attempt record contract (v1) ----------------------------------------------

function New-AiAttemptRecord {
    <#
    .SYNOPSIS
    Construct an AiAttemptRecord v1 object. Every field is present; fields that
    are not known yet stay $null (UNKNOWN). No AI API calls. No pricing math.
    #>
    param(
        [string]$TaskId,
        [string]$MilestoneId,
        [string]$WorkItemId,
        [string]$NodeId,
        [string]$ChangeId,
        [string]$AttemptId,
        [string]$ParentAttemptId,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$UnderlyingModelId,
        [string]$GatewayProviderId,
        [string]$ReasoningLevel,
        [string]$TaskType,
        [string]$Complexity,
        [string]$Risk,
        [string]$StartedAtUtc = (Get-Date).ToUniversalTime().ToString('o'),
        [string]$EndedAtUtc,
        [Nullable[long]]$DurationMs,
        [Nullable[long]]$InputTokens,
        [Nullable[long]]$CachedInputTokens,
        [Nullable[long]]$CacheWriteTokens,
        [Nullable[long]]$OutputTokens,
        [Nullable[long]]$ReasoningTokens,
        [Nullable[long]]$ToolCalls,
        [string]$UsageSource = 'UNKNOWN',
        [Nullable[double]]$EstimatedCost,
        [Nullable[double]]$ActualCost,
        [string]$CostCurrency,
        [Nullable[double]]$ExchangeRate,
        [string]$PricingRecordId,
        [string]$Result = 'PENDING',
        [string]$VerificationResult,
        [string]$VerificationEvidencePath,
        [string]$FailureCategory,
        [string]$EscalatedFromAttemptId,
        [string]$EscalatedToAttemptId,
        [string]$EscalationReason,
        [int]$RetryNumber = 0,
        [bool]$HumanIntervention = $false,
        [string]$ContradictoryStateEvidence,
        [Nullable[long]]$ContextTokens,
        [Nullable[long]]$RawAvailableContextTokens,
        [Nullable[long]]$SelectedContextTokens,
        [Nullable[double]]$ContextReductionPercent,
        [Nullable[int]]$FilesChanged,
        [Nullable[int]]$TestsPassed,
        [Nullable[int]]$TestsFailed,
        [Nullable[int]]$TestsSkipped,
        [string]$RoutingDecisionId,
        [bool]$ManualOverride = $false,
        [string]$ExecutionMode = 'MANUAL',
        [string]$PromptHash,
        [string]$ContextHash,
        [string]$PromptArtifactReference,
        [string]$Notes
    )
    $rec = [pscustomobject]@{
        SchemaVersion                 = 1
        TaskId                        = $TaskId
        MilestoneId                   = $MilestoneId
        WorkItemId                    = $WorkItemId
        NodeId                        = $NodeId
        ChangeId                      = $ChangeId
        AttemptId                     = $AttemptId
        ParentAttemptId               = $ParentAttemptId
        ProviderId                    = $ProviderId
        ModelId                       = $ModelId
        UnderlyingModelId             = $UnderlyingModelId
        GatewayProviderId             = $GatewayProviderId
        ReasoningLevel                = $ReasoningLevel
        TaskType                      = $TaskType
        Complexity                    = $Complexity
        Risk                          = $Risk
        StartedAtUtc                  = $StartedAtUtc
        EndedAtUtc                    = $EndedAtUtc
        DurationMs                    = $DurationMs
        InputTokens                   = $InputTokens
        CachedInputTokens             = $CachedInputTokens
        CacheWriteTokens              = $CacheWriteTokens
        OutputTokens                  = $OutputTokens
        ReasoningTokens               = $ReasoningTokens
        ToolCalls                     = $ToolCalls
        UsageSource                   = $UsageSource
        EstimatedCost                 = $EstimatedCost
        ActualCost                    = $ActualCost
        CostCurrency                  = $CostCurrency
        ExchangeRate                  = $ExchangeRate
        PricingRecordId               = $PricingRecordId
        Result                        = $Result
        VerificationResult            = $VerificationResult
        VerificationEvidencePath      = $VerificationEvidencePath
        FailureCategory               = $FailureCategory
        EscalatedFromAttemptId        = $EscalatedFromAttemptId
        EscalatedToAttemptId          = $EscalatedToAttemptId
        EscalationReason              = $EscalationReason
        RetryNumber                   = $RetryNumber
        HumanIntervention             = $HumanIntervention
        ContradictoryStateEvidence    = $ContradictoryStateEvidence
        ContextTokens                 = $ContextTokens
        RawAvailableContextTokens     = $RawAvailableContextTokens
        SelectedContextTokens         = $SelectedContextTokens
        ContextReductionPercent       = $ContextReductionPercent
        FilesChanged                  = $FilesChanged
        TestsPassed                   = $TestsPassed
        TestsFailed                   = $TestsFailed
        TestsSkipped                  = $TestsSkipped
        RoutingDecisionId             = $RoutingDecisionId
        ManualOverride                = $ManualOverride
        ExecutionMode                 = $ExecutionMode
        PromptHash                    = $PromptHash
        ContextHash                   = $ContextHash
        PromptArtifactReference       = $PromptArtifactReference
        Notes                         = $Notes
    }
    # DB-M17 rule: unknown optional values stay null. [string] parameter binding
    # coerces $null -> '' for every string field, so normalize empty strings back
    # to $null. No field in the attempt record treats '' as a real value; only the
    # explicit defaults below survive (UsageSource UNKNOWN, Result PENDING, etc.).
    foreach ($prop in $rec.PSObject.Properties) {
        if ($null -ne $prop.Value -and $prop.Value -is [string] -and [string]$prop.Value -eq '') {
            $prop.Value = $null
        }
    }
    return $rec
}

# --- secret-like value guard (DB-M17 variant) ----------------------------------

function Test-AiAttemptSecretLeak {
    <#
    .SYNOPSIS
    Scan an attempt record for API-key-like VALUES. A dedicated scanner (not the
    shared Test-AiRoutingSecretValueLeak) is used because that guard exempts the
    field name 'Notes' (correct for provider records, wrong for attempts where
    Notes may carry free text). Structured identifiers, hashes and artifact
    references are exempt by design; free-text fields (Notes, EscalationReason,
    ContradictoryStateEvidence) ARE scanned. PromptHash/ContextHash are further
    structurally validated as 64-hex SHA-256 in Test-AiAttemptRecord.
    #>
    param([AllowNull()][object]$Target)
    $exempt = @(
        'SchemaVersion', 'TaskId', 'MilestoneId', 'WorkItemId', 'NodeId', 'ChangeId',
        'AttemptId', 'ParentAttemptId', 'ProviderId', 'ModelId', 'UnderlyingModelId',
        'GatewayProviderId', 'ReasoningLevel', 'TaskType', 'Complexity', 'Risk',
        'Result', 'VerificationResult', 'FailureCategory', 'UsageSource',
        'ExecutionMode', 'CostCurrency', 'RoutingDecisionId', 'PricingRecordId',
        'EscalatedFromAttemptId', 'EscalatedToAttemptId',
        'PromptHash', 'ContextHash', 'PromptArtifactReference', 'VerificationEvidencePath',
        'DurationMs', 'InputTokens', 'CachedInputTokens', 'CacheWriteTokens',
        'OutputTokens', 'ReasoningTokens', 'ToolCalls', 'ContextTokens',
        'RawAvailableContextTokens', 'SelectedContextTokens', 'ContextReductionPercent',
        'FilesChanged', 'TestsPassed', 'TestsFailed', 'TestsSkipped',
        'EstimatedCost', 'ActualCost', 'ExchangeRate', 'RetryNumber',
        'HumanIntervention', 'ManualOverride', 'StartedAtUtc', 'EndedAtUtc'
    )
    $patterns = @(
        '^sk-[A-Za-z0-9_-]{8,}$',                 # OpenAI-style
        '^AIza[0-9A-Za-z_-]{10,}$',               # Google-style
        '^gh[pousr]_[A-Za-z0-9]{20,}$',           # GitHub tokens
        '^[A-Za-z0-9+/=_\-]{32,}$',               # generic high-entropy token
        '^-----BEGIN'                             # PEM block
    )
    $leaks = New-Object System.Collections.Generic.List[string]

    function Test-AttemptLeakValue([string]$fieldName, [object]$value) {
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
        if ($s -match '(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*\S') {
            $leaks.Add("$fieldName contains inline credential assignment")
        }
    }

    function Test-AttemptLeakObject([string]$path, [object]$obj) {
        if ($null -eq $obj) { return }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($k in $obj.Keys) {
                $v = $obj[$k]
                $name = if ($path) { "$path.$k" } else { [string]$k }
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-AttemptLeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) { foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-AttemptLeakObject $name $item } else { Test-AttemptLeakValue ([string]$k) $item } } }
                else { Test-AttemptLeakValue ([string]$k) $v }
            }
            return
        }
        if ($obj -is [PSCustomObject]) {
            foreach ($prop in $obj.PSObject.Properties) {
                $name = if ($path) { "$path.$($prop.Name)" } else { $prop.Name }
                $v = $prop.Value
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-AttemptLeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) { foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-AttemptLeakObject $name $item } else { Test-AttemptLeakValue $prop.Name $item } } }
                else { Test-AttemptLeakValue $prop.Name $v }
            }
            return
        }
        Test-AttemptLeakValue 'value' $obj
    }

    Test-AttemptLeakObject '' $Target
    return @{ Leak = ($leaks.Count -gt 0); Fields = @($leaks) }
}

# --- structural validation ------------------------------------------------------

function Test-AiAttemptRecord {
    <#
    .SYNOPSIS
    Deterministic structural validation of an AiAttemptRecord v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Record)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Record) { return @{ Valid = $false; Errors = @('Record is null'); Warnings = @() } }

    if ((Get-ContractProperty $Record 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }

    # identity
    $aid = [string](Get-ContractProperty $Record 'AttemptId' '')
    if (-not $aid) { $errors.Add('AttemptId is required') }

    # task identity present
    $taskId = [string](Get-ContractProperty $Record 'TaskId' '')
    $changeId = [string](Get-ContractProperty $Record 'ChangeId' '')
    if (-not $taskId -and -not $changeId) { $errors.Add('Task identity required: TaskId or ChangeId must be present') }

    # vocabularies
    $rl = Get-ContractProperty $Record 'ReasoningLevel' $null
    if ($rl -and -not (Test-IsValidReasoningLevel $rl)) { $errors.Add("ReasoningLevel '$rl' invalid") }
    $tt = Get-ContractProperty $Record 'TaskType' $null
    if ($tt -and -not (Test-IsValidTaskType $tt)) { $errors.Add("TaskType '$tt' invalid") }
    $cx = Get-ContractProperty $Record 'Complexity' $null
    if ($cx -and $cx -notin @('LOW', 'MEDIUM', 'HIGH')) { $errors.Add("Complexity '$cx' invalid") }
    $rk = Get-ContractProperty $Record 'Risk' $null
    if ($rk -and $rk -notin @('LOW', 'MEDIUM', 'HIGH')) { $errors.Add("Risk '$rk' invalid") }
    $em = Get-ContractProperty $Record 'ExecutionMode' 'MANUAL'
    if ($em -and -not (Test-IsValidExecutionMode $em)) { $errors.Add("ExecutionMode '$em' invalid") }

    # timing
    $st = Get-ContractProperty $Record 'StartedAtUtc' $null
    $en = Get-ContractProperty $Record 'EndedAtUtc' $null
    $sdt = [datetime]::MinValue; $edt = [datetime]::MinValue
    if ($st -and -not [datetime]::TryParse([string]$st, [ref]$sdt)) { $errors.Add("StartedAtUtc '$st' is not a valid datetime") }
    if ($en -and -not [datetime]::TryParse([string]$en, [ref]$edt)) { $errors.Add("EndedAtUtc '$en' is not a valid datetime") }
    if ($sdt -gt [datetime]::MinValue -and $edt -gt [datetime]::MinValue -and $sdt -gt $edt) { $errors.Add('StartedAtUtc must be <= EndedAtUtc') }
    $dur = Get-ContractProperty $Record 'DurationMs' $null
    if ($null -ne $dur -and $dur -lt 0) { $errors.Add('DurationMs must be >= 0') }

    # token / usage counts non-negative
    foreach ($f in @('InputTokens', 'CachedInputTokens', 'CacheWriteTokens', 'OutputTokens', 'ReasoningTokens', 'ToolCalls')) {
        $v = Get-ContractProperty $Record $f $null
        if ($null -ne $v -and $v -lt 0) { $errors.Add("$f must be >= 0") }
    }

    # usage source: ACTUAL vs ESTIMATED vs UNKNOWN, never conflated
    $us = [string](Get-ContractProperty $Record 'UsageSource' 'UNKNOWN')
    if (-not (Test-IsValidUsageSource $us)) { $errors.Add("UsageSource '$us' invalid") }
    if ($us -eq 'UNKNOWN') {
        $hasUsage = $false
        foreach ($f in @('InputTokens', 'CachedInputTokens', 'CacheWriteTokens', 'OutputTokens', 'ReasoningTokens', 'ToolCalls')) {
            if ($null -ne (Get-ContractProperty $Record $f $null)) { $hasUsage = $true }
        }
        if ($hasUsage) { $errors.Add('UsageSource is UNKNOWN but token/tool usage fields are present (unknown usage cannot carry counts)') }
    }

    # result + failure category
    $res = [string](Get-ContractProperty $Record 'Result' '')
    if ($res -and -not (Test-IsValidAttemptResult $res)) { $errors.Add("Result '$res' invalid") }
    $fc = Get-ContractProperty $Record 'FailureCategory' $null
    if ($fc -and -not (Test-IsValidFailureCategory $fc)) { $errors.Add("FailureCategory '$fc' invalid") }

    # SUCCESS cannot carry contradictory blocking failure state without explicit evidence
    if ($res -eq 'SUCCESS' -and $fc -and $fc -ne 'UNKNOWN') {
        $evidence = [string](Get-ContractProperty $Record 'ContradictoryStateEvidence' '')
        if (-not $evidence) { $errors.Add('SUCCESS carries blocking FailureCategory without ContradictoryStateEvidence') }
    }

    # retry number
    $rn = Get-ContractProperty $Record 'RetryNumber' 0
    if ($null -ne $rn -and $rn -lt 0) { $errors.Add('RetryNumber must be >= 0') }

    # self-reference guards
    $efa = [string](Get-ContractProperty $Record 'EscalatedFromAttemptId' '')
    $eta = [string](Get-ContractProperty $Record 'EscalatedToAttemptId' '')
    $pa  = [string](Get-ContractProperty $Record 'ParentAttemptId' '')
    if ($aid -and $efa -and $efa -eq $aid) { $errors.Add('EscalatedFromAttemptId cannot self-reference') }
    if ($aid -and $eta -and $eta -eq $aid) { $errors.Add('EscalatedToAttemptId cannot self-reference') }
    if ($aid -and $pa -and $pa -eq $aid) { $errors.Add('ParentAttemptId cannot self-reference') }

    # context fields
    $crp = Get-ContractProperty $Record 'ContextReductionPercent' $null
    if ($null -ne $crp -and ($crp -lt 0 -or $crp -gt 100)) { $errors.Add('ContextReductionPercent must be within 0..100') }
    foreach ($f in @('ContextTokens', 'RawAvailableContextTokens', 'SelectedContextTokens')) {
        $v = Get-ContractProperty $Record $f $null
        if ($null -ne $v -and $v -lt 0) { $errors.Add("$f must be >= 0") }
    }

    # evidence counts
    foreach ($f in @('FilesChanged', 'TestsPassed', 'TestsFailed', 'TestsSkipped')) {
        $v = Get-ContractProperty $Record $f $null
        if ($null -ne $v -and $v -lt 0) { $errors.Add("$f must be >= 0") }
    }

    # verification
    $vr = Get-ContractProperty $Record 'VerificationResult' $null
    if ($vr -and -not (Test-IsValidVerificationResult $vr)) { $errors.Add("VerificationResult '$vr' invalid") }

    # exchange rate
    $exr = Get-ContractProperty $Record 'ExchangeRate' $null
    if ($null -ne $exr -and $exr -le 0) { $errors.Add('ExchangeRate must be > 0') }

    # prompt/context hashes must be real hashes (sensitive-prompt protection)
    foreach ($f in @('PromptHash', 'ContextHash')) {
        $h = [string](Get-ContractProperty $Record $f '')
        if ($h -and $h -notmatch '^[0-9a-fA-F]{64}$') { $errors.Add("$f must be a 64-character hex SHA-256 hash when present") }
    }

    # secret-like values rejected
    $leak = Test-AiAttemptSecretLeak $Record
    if ($leak.Leak) { $errors.Add(('Secret-like value detected in field(s): ' + ($leak.Fields -join '; '))) }

    # terminal result should carry an end timestamp (informational)
    if ($res -in (Get-AiAttemptTerminalStates) -and -not $en) { $warnings.Add("Result '$res' is terminal but EndedAtUtc is not set") }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @($warnings) }
}

# --- reference catalogue validation ----------------------------------------------

function Get-AiAttemptReferenceCatalogues {
    <#
    .SYNOPSIS
    Load frozen DB-M14 provider/model identity indexes from config for reference
    validation. Read-only. No provider/model library dependency.
    #>
    param([string]$Root = (Resolve-AiAttemptRoot))
    $providers = @{}
    $models = @{}
    $underlyings = @{}
    $pf = Join-Path $Root 'config\providers.json'
    if (Test-Path $pf) {
        $p = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($p.providers)) { $providers[[string]$r.ProviderId] = $true }
    }
    $mf = Join-Path $Root 'config\models.json'
    if (Test-Path $mf) {
        $m = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($m.models)) {
            $models[[string]$r.ModelId] = $true
            $underlyings[[string]$r.UnderlyingModelId] = $true
        }
    }
    foreach ($k in @($models.Keys)) { $underlyings[$k] = $true }
    return @{ Providers = $providers; Models = $models; UnderlyingModelIds = $underlyings }
}

function Test-AiAttemptRecordReferences {
    <#
    .SYNOPSIS
    Validate provider/model references on an attempt record against the frozen
    DB-M14 catalogues. Returns @{ Valid; Errors }. References are only checked
    when provided; unknown optional values stay null.
    #>
    param(
        [AllowNull()][pscustomobject]$Record,
        [AllowNull()][object]$Providers,
        [AllowNull()][object]$Models,
        [AllowNull()][object]$UnderlyingModelIds
    )
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Record) { return @{ Valid = $false; Errors = @('Record is null') } }
    if ($null -eq $Providers)     { $Providers = @{} }
    if ($null -eq $Models)        { $Models = @{} }
    if ($null -eq $UnderlyingModelIds) { $UnderlyingModelIds = @{} }

    $provId = [string](Get-ContractProperty $Record 'ProviderId' '')
    $mid    = [string](Get-ContractProperty $Record 'ModelId' '')
    $umid   = [string](Get-ContractProperty $Record 'UnderlyingModelId' '')
    $gpid   = [string](Get-ContractProperty $Record 'GatewayProviderId' '')

    if ($provId -and -not $Providers.ContainsKey($provId)) { $errors.Add("ProviderId '$provId' is not in the provider catalogue") }
    if ($gpid -and -not $Providers.ContainsKey($gpid)) { $errors.Add("GatewayProviderId '$gpid' is not in the provider catalogue") }
    if ($mid -and -not $Models.ContainsKey($mid)) { $errors.Add("ModelId '$mid' is not in the model catalogue") }
    if ($umid) {
        if (-not $UnderlyingModelIds.ContainsKey($umid)) {
            $errors.Add("UnderlyingModelId '$umid' is not a known underlying model")
        } elseif ($mid -and $Models.ContainsKey($mid)) {
            # UnderlyingModelId may be the model's own identity (default) or its true underlying.
        }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}

# --- history index (AiAttemptHistory v1) ----------------------------------------

function New-AiAttemptHistory {
    param([string]$ChangeId, [string]$NodeId, [string]$TaskId, [string]$MilestoneId)
    $now = (Get-Date).ToUniversalTime().ToString('o')
    return [pscustomobject]@{
        SchemaVersion = 1
        ChangeId      = $ChangeId
        NodeId        = $NodeId
        TaskId        = $TaskId
        MilestoneId   = $MilestoneId
        CreatedAtUtc  = $now
        UpdatedAtUtc  = $now
        AttemptIds    = @()
    }
}

function Read-AiAttemptHistory {
    <#
    .SYNOPSIS
    Load the append-only history index for one change. Returns AiAttemptHistory v1.
    Missing history is created in memory (never auto-persisted until a write).
    #>
    param([string]$Root = (Resolve-AiAttemptRoot), [string]$NodeId, [string]$ChangeId)
    $hp = Get-AiAttemptHistoryPath -Root $Root -NodeId $NodeId -ChangeId $ChangeId
    if (-not (Test-Path $hp)) {
        return New-AiAttemptHistory -ChangeId $ChangeId -NodeId $NodeId
    }
    $json = Get-Content $hp -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-ContractProperty $json 'SchemaVersion' -1) -ne 1) { throw "history schemaVersion must be 1 (found '$((Get-ContractProperty $json 'SchemaVersion' '?'))')" }
    $h = New-AiAttemptHistory -ChangeId ([string](Get-ContractProperty $json 'ChangeId' $ChangeId)) -NodeId ([string](Get-ContractProperty $json 'NodeId' $NodeId))
    $h.TaskId      = [string](Get-ContractProperty $json 'TaskId' '')
    $h.MilestoneId = [string](Get-ContractProperty $json 'MilestoneId' '')
    $h.CreatedAtUtc = [string](Get-ContractProperty $json 'CreatedAtUtc' $h.CreatedAtUtc)
    $ids = New-Object System.Collections.Generic.List[string]
    if ($json.AttemptIds) { foreach ($i in @($json.AttemptIds)) { $ids.Add([string]$i) } }
    $h.AttemptIds = @($ids)
    return $h
}

function Save-AiAttemptHistory {
    param([string]$Root = (Resolve-AiAttemptRoot), [pscustomobject]$History)
    $h = $History
    $h.UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $dir = Get-AiAttemptStoreDir -Root $Root -NodeId $h.NodeId -ChangeId $h.ChangeId
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $hp = Get-AiAttemptHistoryPath -Root $Root -NodeId $h.NodeId -ChangeId $h.ChangeId
    $h | ConvertTo-Json -Depth 10 | Set-Content -Path $hp -Encoding UTF8
    return $h
}

function Sync-AiAttemptStateIndex {
    <#
    .SYNOPSIS
    Refresh the DB-M13-documented discovery mirror at state/attempts/<changeId>/
    so DB-M24 and the DB-M12 UI can find attempt history without database
    infrastructure. This is a pointer/index only - the canonical records live in
    logs/tasks/<node>/<change>/ai-attempts/.
    #>
    param([string]$Root = (Resolve-AiAttemptRoot), [pscustomobject]$History)
    $h = $History
    $sp = Get-AiAttemptStateIndexPath -Root $Root -ChangeId $h.ChangeId
    $dir = Split-Path -Parent $sp
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $idx = [pscustomobject]@{
        SchemaVersion = 1
        ChangeId      = $h.ChangeId
        NodeId        = $h.NodeId
        TaskId        = $h.TaskId
        MilestoneId   = $h.MilestoneId
        HistoryPath   = (Get-AiAttemptHistoryPath -Root $Root -NodeId $h.NodeId -ChangeId $h.ChangeId)
        AttemptCount  = @($h.AttemptIds).Count
        AttemptIds    = @($h.AttemptIds)
        UpdatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
    $idx | ConvertTo-Json -Depth 10 | Set-Content -Path $sp -Encoding UTF8
    return $idx
}

# --- attempt id generation -------------------------------------------------------

function New-AiAttemptId {
    <#
    .SYNOPSIS
    Deterministic attempt identity: ATT-<ChangeId>-NNN (zero-padded 3).
    NNN = max existing suffix + 1 (or an explicit NextNumber). The attempt id
    identifies ONE AI execution attempt - it never reuses an Activity id or
    Change id.
    #>
    param([string]$ChangeId, [string[]]$ExistingAttemptIds, [int]$NextNumber = -1)
    $maxN = 0
    if ($ExistingAttemptIds) {
        foreach ($id in @($ExistingAttemptIds)) {
            $m = [regex]::Match([string]$id, '-(\d+)$')
            if ($m.Success) {
                $n = [int]$m.Groups[1].Value
                if ($n -gt $maxN) { $maxN = $n }
            }
        }
    }
    $n = if ($NextNumber -ge 0) { $NextNumber } else { $maxN + 1 }
    if ($n -lt 1) { $n = 1 }
    return ("ATT-{0}-{1:D3}" -f $ChangeId, $n)
}

# --- persistence -----------------------------------------------------------------

function Save-AiAttemptRecord {
    <#
    .SYNOPSIS
    Persist an AiAttemptRecord v1 to the canonical store, appending its id to the
    change history (idempotent for the same id = lifecycle update) and refreshing
    the state mirror. Rejects invalid records and duplicate new ids.
    #>
    param(
        [string]$Root = (Resolve-AiAttemptRoot),
        [pscustomobject]$Record
    )
    if ($null -eq $Record) { throw 'Record is required' }
    $aid = [string](Get-ContractProperty $Record 'AttemptId' '')
    if (-not $aid) { throw 'AttemptId is required to save an attempt record' }
    $nodeId = [string](Get-ContractProperty $Record 'NodeId' '')
    $changeId = [string](Get-ContractProperty $Record 'ChangeId' '')
    if (-not $nodeId -or -not $changeId) { throw 'NodeId and ChangeId are required to save an attempt record' }

    $v = Test-AiAttemptRecord $Record
    if (-not $v.Valid) { throw ("Invalid attempt record: " + ($v.Errors -join '; ')) }

    $dir = Get-AiAttemptStoreDir -Root $Root -NodeId $nodeId -ChangeId $changeId
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $history = Read-AiAttemptHistory -Root $Root -NodeId $nodeId -ChangeId $changeId
    if ($history.AttemptIds -notcontains $aid) {
        # append-only: a NEW attempt id is appended, never inserted into existing order
        $history.AttemptIds = @($history.AttemptIds + $aid)
    }

    $rp = Get-AiAttemptRecordPath -Root $Root -NodeId $nodeId -ChangeId $changeId -AttemptId $aid
    $Record | ConvertTo-Json -Depth 10 | Set-Content -Path $rp -Encoding UTF8

    $null = Save-AiAttemptHistory -Root $Root -History $history
    $null = Sync-AiAttemptStateIndex -Root $Root -History $history
    return $Record
}

function Read-AiAttempt {
    <#
    .SYNOPSIS
    Read one AiAttemptRecord v1 by id. Returns $null when not found.
    #>
    param(
        [string]$Root = (Resolve-AiAttemptRoot),
        [string]$NodeId,
        [string]$ChangeId,
        [Parameter(Mandatory)][string]$AttemptId
    )
    $rp = Get-AiAttemptRecordPath -Root $Root -NodeId $NodeId -ChangeId $ChangeId -AttemptId $AttemptId
    if (-not (Test-Path $rp)) { return $null }
    $json = Get-Content $rp -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-ContractProperty $json 'SchemaVersion' -1) -ne 1) { throw "attempt '$AttemptId' schemaVersion must be 1" }
    return $json
}

# --- lifecycle operations ---------------------------------------------------------
# StartAttempt / RecordUsage / RecordOutcome / RecordVerification / RecordEscalation /
# RecordHumanIntervention. History only records escalation/human intervention - it
# never implements escalation behavior itself.

function Start-AiAttempt {
    <#
    .SYNOPSIS
    Create a new PENDING attempt (StartAttempt). Assigns ATT-<ChangeId>-NNN,
    StartedAtUtc, and RetryNumber (0 for a parentless attempt, parent.RetryNumber+1
    when ParentAttemptId is given). Persists immediately. No AI API call.
    #>
    param(
        [string]$Root = (Resolve-AiAttemptRoot),
        [Parameter(Mandatory)][string]$NodeId,
        [Parameter(Mandatory)][string]$ChangeId,
        [string]$TaskId,
        [string]$MilestoneId,
        [string]$WorkItemId,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$UnderlyingModelId,
        [string]$GatewayProviderId,
        [string]$ReasoningLevel,
        [string]$TaskType,
        [string]$Complexity,
        [string]$Risk,
        [string]$ParentAttemptId,
        [int]$RetryNumber = -1,
        [string]$ExecutionMode = 'MANUAL',
        [bool]$ManualOverride = $false,
        [string]$AttemptId,
        [string]$RoutingDecisionId,
        [string]$PricingRecordId
    )
    if (-not $TaskId) { $TaskId = $NodeId }   # node is the task identity by DevBridge convention

    $history = Read-AiAttemptHistory -Root $Root -NodeId $NodeId -ChangeId $ChangeId

    $retry = 0
    if ($ParentAttemptId) {
        $parent = Read-AiAttempt -Root $Root -NodeId $NodeId -ChangeId $ChangeId -AttemptId $ParentAttemptId
        if ($null -eq $parent) { throw "ParentAttemptId '$ParentAttemptId' not found" }
        $retry = [int](Get-ContractProperty $parent 'RetryNumber' 0) + 1
    } elseif ($RetryNumber -ge 0) {
        $retry = $RetryNumber
    }

    if ($AttemptId) {
        if ($history.AttemptIds -contains $AttemptId) { throw "AttemptId '$AttemptId' already exists" }
    } else {
        $AttemptId = New-AiAttemptId -ChangeId $ChangeId -ExistingAttemptIds $history.AttemptIds
    }

    $rec = New-AiAttemptRecord -TaskId $TaskId -MilestoneId $MilestoneId -WorkItemId $WorkItemId `
        -NodeId $NodeId -ChangeId $ChangeId -AttemptId $AttemptId -ParentAttemptId $ParentAttemptId `
        -ProviderId $ProviderId -ModelId $ModelId -UnderlyingModelId $UnderlyingModelId -GatewayProviderId $GatewayProviderId `
        -ReasoningLevel $ReasoningLevel -TaskType $TaskType -Complexity $Complexity -Risk $Risk `
        -Result 'PENDING' -RetryNumber $retry -ExecutionMode $ExecutionMode -ManualOverride $ManualOverride `
        -RoutingDecisionId $RoutingDecisionId -PricingRecordId $PricingRecordId

    $null = Save-AiAttemptRecord -Root $Root -Record $rec
    return $rec
}

function Set-AiAttemptUsage {
    <#
    .SYNOPSIS
    RecordUsage: set token/tool usage on an existing attempt and persist.
    Actual provider-reported usage is recorded verbatim (UsageSource ACTUAL);
    estimates are explicitly marked ESTIMATED; if the provider returned no usage
    leave UsageSource UNKNOWN and the token fields null.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Record,
        [string]$Root = (Resolve-AiAttemptRoot),
        [Nullable[long]]$InputTokens,
        [Nullable[long]]$CachedInputTokens,
        [Nullable[long]]$CacheWriteTokens,
        [Nullable[long]]$OutputTokens,
        [Nullable[long]]$ReasoningTokens,
        [Nullable[long]]$ToolCalls,
        [string]$UsageSource = 'ESTIMATED'
    )
    $Record.InputTokens = $InputTokens
    $Record.CachedInputTokens = $CachedInputTokens
    $Record.CacheWriteTokens = $CacheWriteTokens
    $Record.OutputTokens = $OutputTokens
    $Record.ReasoningTokens = $ReasoningTokens
    $Record.ToolCalls = $ToolCalls
    $Record.UsageSource = $UsageSource
    return Save-AiAttemptRecord -Root $Root -Record $Record
}

function Set-AiAttemptOutcome {
    <#
    .SYNOPSIS
    RecordOutcome: set the result state, failure category, end timestamp and
    outcome evidence on an existing attempt and persist. DurationMs is computed
    from StartedAtUtc/EndedAtUtc when not supplied.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Record,
        [string]$Root = (Resolve-AiAttemptRoot),
        [string]$Result,
        [string]$FailureCategory,
        [string]$EndedAtUtc,
        [Nullable[long]]$DurationMs,
        [Nullable[int]]$FilesChanged,
        [Nullable[int]]$TestsPassed,
        [Nullable[int]]$TestsFailed,
        [Nullable[int]]$TestsSkipped
    )
    if ($Result) { $Record.Result = $Result }
    if ($FailureCategory) { $Record.FailureCategory = $FailureCategory }
    if ($EndedAtUtc) {
        $Record.EndedAtUtc = $EndedAtUtc
        if ($null -eq $DurationMs -and $Record.StartedAtUtc) {
            $sdt = [datetime]::MinValue; $edt = [datetime]::MinValue
            if ([datetime]::TryParse([string]$Record.StartedAtUtc, [ref]$sdt)) {
                if ([datetime]::TryParse([string]$EndedAtUtc, [ref]$edt)) {
                    $Record.DurationMs = [long][math]::Round(($edt - $sdt).TotalMilliseconds)
                }
            }
        }
    }
    if ($null -ne $DurationMs) { $Record.DurationMs = $DurationMs }
    if ($null -ne $FilesChanged) { $Record.FilesChanged = $FilesChanged }
    if ($null -ne $TestsPassed) { $Record.TestsPassed = $TestsPassed }
    if ($null -ne $TestsFailed) { $Record.TestsFailed = $TestsFailed }
    if ($null -ne $TestsSkipped) { $Record.TestsSkipped = $TestsSkipped }
    return Save-AiAttemptRecord -Root $Root -Record $Record
}

function Set-AiAttemptVerification {
    <#
    .SYNOPSIS
    RecordVerification: link the attempt to DevBridge verification evidence
    (VerificationResult + VerificationEvidencePath). References DB-M06 reports;
    does not duplicate them.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Record,
        [string]$Root = (Resolve-AiAttemptRoot),
        [string]$VerificationResult,
        [string]$VerificationEvidencePath
    )
    if ($VerificationResult) { $Record.VerificationResult = $VerificationResult }
    if ($VerificationEvidencePath) { $Record.VerificationEvidencePath = $VerificationEvidencePath }
    return Save-AiAttemptRecord -Root $Root -Record $Record
}

function Set-AiAttemptEscalation {
    <#
    .SYNOPSIS
    RecordEscalation: record escalation links (EscalatedFromAttemptId /
    EscalatedToAttemptId) and reason on an existing attempt and persist.
    Records the fact of escalation only - escalation behavior is DB-M20.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Record,
        [string]$Root = (Resolve-AiAttemptRoot),
        [string]$EscalatedFromAttemptId,
        [string]$EscalatedToAttemptId,
        [string]$EscalationReason
    )
    if ($EscalatedFromAttemptId) { $Record.EscalatedFromAttemptId = $EscalatedFromAttemptId }
    if ($EscalatedToAttemptId) { $Record.EscalatedToAttemptId = $EscalatedToAttemptId }
    if ($EscalationReason) { $Record.EscalationReason = $EscalationReason }
    return Save-AiAttemptRecord -Root $Root -Record $Record
}

function Set-AiAttemptHumanIntervention {
    <#
    .SYNOPSIS
    RecordHumanIntervention: mark that a human took over the attempt and persist.
    Optional Notes appended to the record. The manual flow (ChatGPT -> DeepSeek ->
    verification -> Claude) remains authoritative.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Record,
        [string]$Root = (Resolve-AiAttemptRoot),
        [string]$Notes
    )
    $Record.HumanIntervention = $true
    if ($Notes) {
        $Record.Notes = if ($Record.Notes) { [string]$Record.Notes + "`n" + $Notes } else { $Notes }
    }
    return Save-AiAttemptRecord -Root $Root -Record $Record
}

# --- queries / list operations ----------------------------------------------------

function Get-AiAttemptsForChange {
    <#
    .SYNOPSIS
    ListAttemptsForChange: all attempts for one change in history (append) order.
    #>
    param([string]$Root = (Resolve-AiAttemptRoot), [string]$NodeId, [string]$ChangeId)
    $history = Read-AiAttemptHistory -Root $Root -NodeId $NodeId -ChangeId $ChangeId
    $records = New-Object System.Collections.ArrayList
    foreach ($aid in @($history.AttemptIds)) {
        $r = Read-AiAttempt -Root $Root -NodeId $NodeId -ChangeId $ChangeId -AttemptId ([string]$aid)
        if ($null -ne $r) { $null = $records.Add($r) }
    }
    return $records.ToArray()
}

function Get-AiAttemptsForTask {
    <#
    .SYNOPSIS
    ListAttemptsForTask: all attempts across every change of one task/node, in
    history order per change.
    #>
    param([string]$Root = (Resolve-AiAttemptRoot), [string]$NodeId, [string]$TaskId)
    $node = if ($NodeId) { $NodeId } else { $TaskId }
    if (-not $node) { throw 'NodeId or TaskId is required' }
    $taskDir = Join-Path $Root ("logs\tasks\{0}" -f $node)
    $records = New-Object System.Collections.ArrayList
    if (Test-Path $taskDir) {
        foreach ($changeDir in @(Get-ChildItem $taskDir -Directory)) {
            foreach ($r in @(Get-AiAttemptsForChange -Root $Root -NodeId $node -ChangeId $changeDir.Name)) {
                $null = $records.Add($r)
            }
        }
    }
    return $records.ToArray()
}

function Get-AiAttemptsAll {
    <#
    .SYNOPSIS
    All attempt records under logs/tasks/<node>/<change>/ai-attempts/.
    #>
    param([string]$Root = (Resolve-AiAttemptRoot))
    $tasksDir = Join-Path $Root 'logs\tasks'
    $records = New-Object System.Collections.ArrayList
    if (Test-Path $tasksDir) {
        foreach ($node in @(Get-ChildItem $tasksDir -Directory)) {
            foreach ($change in @(Get-ChildItem $node.FullName -Directory)) {
                foreach ($r in @(Get-AiAttemptsForChange -Root $Root -NodeId $node.Name -ChangeId $change.Name)) {
                    $null = $records.Add($r)
                }
            }
        }
    }
    return $records.ToArray()
}

function Get-AiAttemptsByProvider {
    <#
    .SYNOPSIS
    ListAttemptsByProvider: attempts for one provider, scoped to a change, a task
    (node), or the whole store.
    #>
    param([string]$Root = (Resolve-AiAttemptRoot), [string]$ProviderId, [string]$NodeId, [string]$ChangeId)
    $records = @()
    if ($ChangeId) { $records = @(Get-AiAttemptsForChange -Root $Root -NodeId $NodeId -ChangeId $ChangeId) }
    elseif ($NodeId) { $records = @(Get-AiAttemptsForTask -Root $Root -NodeId $NodeId) }
    else { $records = @(Get-AiAttemptsAll -Root $Root) }
    if ($ProviderId) { $records = @($records | Where-Object { (Get-ContractProperty $_ 'ProviderId' '') -eq $ProviderId }) }
    return $records
}

function Get-AiAttemptsByModel {
    <#
    .SYNOPSIS
    ListAttemptsByModel: attempts for one model, scoped to a change, a task, or
    the whole store.
    #>
    param([string]$Root = (Resolve-AiAttemptRoot), [string]$ModelId, [string]$NodeId, [string]$ChangeId)
    $records = @()
    if ($ChangeId) { $records = @(Get-AiAttemptsForChange -Root $Root -NodeId $NodeId -ChangeId $ChangeId) }
    elseif ($NodeId) { $records = @(Get-AiAttemptsForTask -Root $Root -NodeId $NodeId) }
    else { $records = @(Get-AiAttemptsAll -Root $Root) }
    if ($ModelId) { $records = @($records | Where-Object { (Get-ContractProperty $_ 'ModelId' '') -eq $ModelId }) }
    return $records
}

function Get-AiFailedAttempts {
    <#
    .SYNOPSIS
    ListFailedAttempts: attempts whose Result is FAILED. Scoped like ByProvider.
    #>
    param([string]$Root = (Resolve-AiAttemptRoot), [string]$NodeId, [string]$ChangeId)
    $records = @()
    if ($ChangeId) { $records = @(Get-AiAttemptsForChange -Root $Root -NodeId $NodeId -ChangeId $ChangeId) }
    elseif ($NodeId) { $records = @(Get-AiAttemptsForTask -Root $Root -NodeId $NodeId) }
    else { $records = @(Get-AiAttemptsAll -Root $Root) }
    return @($records | Where-Object { (Get-ContractProperty $_ 'Result' '') -eq 'FAILED' })
}

# --- aggregation foundation (DB-M24 reads this later) ------------------------------

function Get-AiAttemptAggregates {
    <#
    .SYNOPSIS
    Basic aggregation foundation for DB-M24: attempt count by model, success/
    failure counts, attempt count by task type, first-attempt success count,
    escalation count, average duration. No model recommendation - M24 owns that.
    #>
    param([AllowNull()][object[]]$Records)
    $records = @($Records)
    $byModel = @{}
    $byResult = @{}
    $byTaskType = @{}
    $byFailure = @{}
    $durations = New-Object System.Collections.Generic.List[double]
    $escalation = 0
    $firstAttemptSuccess = 0
    $seenChange = @{}

    foreach ($r in $records) {
        $model = [string](Get-ContractProperty $r 'ModelId' '')
        if (-not $model) { $model = '(unknown)' }
        $res = [string](Get-ContractProperty $r 'Result' '')
        if (-not $res) { $res = '(unknown)' }
        $tt = [string](Get-ContractProperty $r 'TaskType' '')
        if (-not $tt) { $tt = '(unknown)' }
        $fc = [string](Get-ContractProperty $r 'FailureCategory' '')
        if (-not $fc) { $fc = '(unknown)' }
        $cid = [string](Get-ContractProperty $r 'ChangeId' '')

        $byModel[$model] = ([int]($byModel[$model])) + 1
        $byResult[$res] = ([int]($byResult[$res])) + 1
        $byTaskType[$tt] = ([int]($byTaskType[$tt])) + 1
        if ($fc -ne '(unknown)') { $byFailure[$fc] = ([int]($byFailure[$fc])) + 1 }

        $dur = Get-ContractProperty $r 'DurationMs' $null
        if ($null -ne $dur) { $durations.Add([double]$dur) }

        $efa = [string](Get-ContractProperty $r 'EscalatedFromAttemptId' '')
        if ($efa -or $res -eq 'ESCALATED') { $escalation++ }

        if ($cid -and -not $seenChange.ContainsKey($cid)) {
            $seenChange[$cid] = $true
            if ($res -eq 'SUCCESS') { $firstAttemptSuccess++ }
        }
    }

    return [pscustomobject]@{
        TotalAttempts           = $records.Count
        ByModel                 = $byModel
        ByResult                = $byResult
        ByTaskType              = $byTaskType
        FailuresByCategory      = $byFailure
        SuccessCount            = [int]($byResult['SUCCESS'])
        FailureCount            = [int]($byResult['FAILED']) + [int]($byResult['CANCELLED']) + [int]($byResult['BLOCKED']) + [int]($byResult['BUDGET_STOPPED']) + [int]($byResult['ESCALATED'])
        FirstAttemptSuccessCount = $firstAttemptSuccess
        EscalationCount         = $escalation
        AverageDurationMs       = if ($durations.Count -gt 0) { [double]($durations | Measure-Object -Average).Average } else { $null }
        DurationSampleCount     = $durations.Count
    }
}

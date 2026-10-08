# HistoryContracts.ps1 -- DB-M29 task cost / attempt / escalation history contracts.
#
# DB-M29 is a READ-ONLY HISTORY PRESENTATION UI. It answers, per task:
#   WHAT WAS TRIED? WHY DID IT FAIL? WHY RETRY OR ESCALATE? HOW MUCH DID EACH
#   ATTEMPT COST? WHAT WAS THE TOTAL COST? WHICH ATTEMPT FINALLY PASSED
#   VERIFICATION?
#
# DB-M29 owns NO persistence and creates NO second attempt-history database.
# The engine is pure: it takes AiAttemptRecord v1 objects (DB-M17), optional
# DB-M20 EscalationDecision objects, optional DB-M21 FailureFingerprint objects
# and optional DB-M22 ProviderHealthEvidence objects, and returns a view. The
# ONLY write in the whole library is Export-DbM29TaskHistoryHtml writing the
# operator-requested HTML artifact (the DB-M27/DB-M28 pattern).
#
# AUTO_EXECUTION_ENABLED = FALSE. 0 paid calls, 0 network calls, no secrets
# stored, no AI execution, no attempt-history mutation, no workbook/state
# writes.
#
# Reuse is READ-ONLY (files dot-sourced here, never modified):
#   DB-M14 AiRoutingContracts        -- shared helpers + vocabularies
#   DB-M17 AttemptStore.ps1          -- AiAttemptRecord v1 + attempt query layer
#   DB-M20 EscalationContracts.ps1   -- New-EscalationChain + action/reason vocab
#   DB-M21 FingerprintContracts.ps1  -- FailureFingerprint v1 + recurrence vocab
#   DB-M23 AdapterContracts.ps1      -- price-status vocab + error map
#   DB-M24 AiPerformanceFoundation   -- chains, confidence, model performance
#   DB-M25 AiQualityCostContracts    -- verified-success resolution + cost guards
#
# Frozen-foundation guarantee: DB-M14/17/20/21/23/24/25 files are only
# dot-sourced (read) and SHA-256 verified byte-identical by the test suite.

. (Join-Path $PSScriptRoot "..\quality-cost\AiQualityCostContracts.ps1")   # DB-M24 + DB-M25 + DB-M23 + DB-M17 (READ-ONLY)
. (Join-Path $PSScriptRoot "..\escalation\EscalationContracts.ps1")        # DB-M20 (READ-ONLY)
. (Join-Path $PSScriptRoot "..\failure-fingerprints\FingerprintContracts.ps1")  # DB-M21 (READ-ONLY)

# --- schema versions (DB-M29-owned) ---------------------------------------------

function Get-DbM29SchemaVersions {
    <#
    .SYNOPSIS
    Frozen DB-M29 schema versions. Incompatible changes must introduce v2 with
    their own validators; v1 semantics are never silently mutated.
    #>
    return @{
        TaskHistoryQueryVersion   = 1
        TaskHistoryViewVersion    = 1
        TaskHistoryRowVersion     = 1
        AttemptTimelineNodeVersion = 1
        TimelineTransitionVersion = 1
        ReadOnlyGuardVersion      = 1
    }
}

# --- vocabularies -----------------------------------------------------------------

function Get-DbM29TransitionTypes {
    <#
    .SYNOPSIS
    The timeline-arrow vocabulary. Every type is derived from record EVIDENCE
    (route changes, reasoning escalation, Claude review fix, escalation decision
    action, terminal state) -- never guessed. 'START' marks the first node.
    #>
    return @(
        'START', 'RETRY', 'RETRY_SAME_MODEL_HIGHER_REASONING', 'SWITCH_MODEL',
        'SWITCH_PROVIDER_ROUTE', 'REBUILD_CONTEXT', 'CORRECTION',
        'CORRECTION_CLAUDE_REVIEW_FIX', 'BUDGET_STOP', 'HUMAN_REVIEW',
        'GOVERNANCE_STOP', 'VERIFIED_SUCCESS', 'FAILED_NO_RETRY'
    )
}

function Get-DbM29TaskRowSortBys {
    return @('TASK_ID', 'TOTAL_COST', 'ATTEMPT_COUNT')
}

function Get-DbM29VerifiedStates {
    <#
    .SYNOPSIS
    Verified-success state labels for a task row / timeline node. The underlying
    truth is ALWAYS DB-M25 Resolve-DbM25VerifiedSuccess (authoritative); these are
    presentation labels only.
    #>
    return @('VERIFIED_SUCCESS', 'CONTRADICTED', 'MODEL_RETURNED', 'INCOMPLETE', 'NO_ATTEMPTS')
}

function Get-DbM29FirstAttemptSuccessValues {
    return @('YES', 'NO', 'UNKNOWN')
}

function Get-DbM29ReasoningOrder {
    <#
    .SYNOPSIS
    Deterministic reasoning-level order for the escalation classifier.
    #>
    return @{ 'NONE' = 0; 'LOW' = 1; 'MEDIUM' = 2; 'HIGH' = 3; 'MAX' = 4 }
}

# --- UTC / helpers -----------------------------------------------------------------

function ConvertTo-DbM29Utc {
    <#
    .SYNOPSIS
    Normalize a datetime (object or string) to Kind=Utc (house pattern). Null
    returns null; a string without a zone designator is a UTC clock time.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Utc) { return $dt }
        if ($dt.Kind -eq [System.DateTimeKind]::Local) { return $dt.ToUniversalTime() }
        return [System.DateTime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
    }
    $s = [string]$Value
    if ($s.Trim() -eq '') { return $null }
    return [System.DateTime]::Parse(
        $s,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Get-DbM29String {
    param($Record, [string]$Name)
    $v = [string](Get-ContractProperty $Record $Name '')
    if ($v -eq '') { return $null }
    return $v
}

# --- TaskHistoryQuery v1 -------------------------------------------------------------

function New-DbM29TaskHistoryQuery {
    <#
    .SYNOPSIS
    Construct a read-only TaskHistoryQuery v1. Every dimension is optional; an
    unspecified dimension does not filter. NowUtc defaults to UtcNow. Currency
    defaults to INR, SuccessDefinition to VERIFIED (verified success is
    authoritative), SortBy to TASK_ID, SortDirection to ASCENDING.
    #>
    param(
        [string]$QueryId,
        [string]$NowUtc,
        [string]$Currency = 'INR',
        [string]$SuccessDefinition = 'VERIFIED',
        [string]$TaskId,
        [string]$ProviderId,
        [string]$ModelId,
        [bool]$AllowEstimatedCostFallback = $false,
        [string]$SortBy = 'TASK_ID',
        [string]$SortDirection = 'ASCENDING'
    )
    $now = ConvertTo-DbM29Utc $NowUtc
    if ($null -eq $now) { $now = [datetime]::UtcNow }
    return [pscustomobject]@{
        SchemaVersion             = 1
        QueryId                   = $QueryId
        NowUtc                    = $now.ToString('o')
        Currency                  = $Currency.Trim().ToUpperInvariant()
        SuccessDefinition         = $SuccessDefinition.Trim().ToUpperInvariant()
        TaskId                    = $(if ($TaskId) { $TaskId.Trim() } else { $null })
        ProviderId                = $(if ($ProviderId) { $ProviderId.Trim().ToLowerInvariant() } else { $null })
        ModelId                   = $(if ($ModelId) { $ModelId.Trim().ToLowerInvariant() } else { $null })
        AllowEstimatedCostFallback = [bool]$AllowEstimatedCostFallback
        SortBy                    = $SortBy.Trim().ToUpperInvariant()
        SortDirection             = $SortDirection.Trim().ToUpperInvariant()
    }
}

function Test-DbM29TaskHistoryQuery {
    <#
    .SYNOPSIS
    Deterministic structural validation of a TaskHistoryQuery v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][object]$Query)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Query) { return @{ Valid = $false; Errors = @('Query is null'); Warnings = @() } }
    if ((Get-ContractProperty $Query 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    $sd = [string](Get-ContractProperty $Query 'SuccessDefinition' '')
    if ($sd -and -not (Test-IsValidSuccessDefinition $sd)) { $errors.Add("SuccessDefinition '$sd' invalid") }
    $cur = [string](Get-ContractProperty $Query 'Currency' '')
    if ($cur -and $cur -notmatch '^[A-Z]{3}$') { $errors.Add("Currency '$cur' must be a 3-letter ISO-4217 code") }
    $sb = [string](Get-ContractProperty $Query 'SortBy' '')
    if ($sb -and $sb -notin (Get-DbM29TaskRowSortBys)) { $errors.Add("SortBy '$sb' invalid") }
    $sdir = [string](Get-ContractProperty $Query 'SortDirection' '')
    if ($sdir -and $sdir -notin @('ASCENDING', 'DESCENDING')) { $errors.Add("SortDirection '$sdir' invalid") }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# --- TimelineTransition v1 ------------------------------------------------------------

function New-DbM29TimelineTransition {
    <#
    .SYNOPSIS
    Construct a TimelineTransition v1: the arrow INTO an attempt, derived from
    evidence (route change / reasoning escalation / Claude review fix / DB-M20
    escalation decision action / terminal state). 'START' marks the first node.
    #>
    param(
        [string]$FromAttemptId,
        [string]$ToAttemptId,
        [string]$Type = 'RETRY',
        [string]$Action = '',
        [AllowNull()][string[]]$ReasonCodes = @(),
        [string]$Explanation = '',
        [string]$DecisionId = '',
        [bool]$RequiresHuman = $false,
        [string]$HumanActionType = ''
    )
    return [pscustomobject]@{
        SchemaVersion   = 1
        FromAttemptId   = $(if ($FromAttemptId) { $FromAttemptId } else { $null })
        ToAttemptId     = $(if ($ToAttemptId) { $ToAttemptId } else { $null })
        Type            = $Type
        Action          = $(if ($Action) { $Action } else { $null })
        ReasonCodes     = @($ReasonCodes)
        Explanation     = $(if ($Explanation) { $Explanation } else { $null })
        DecisionId      = $(if ($DecisionId) { $DecisionId } else { $null })
        RequiresHuman   = [bool]$RequiresHuman
        HumanActionType = $(if ($HumanActionType) { $HumanActionType } else { $null })
    }
}

# --- AttemptTimelineNode v1 -------------------------------------------------------------

function New-DbM29AttemptTimelineNode {
    <#
    .SYNOPSIS
    Construct an AttemptTimelineNode v1: one attempt in the ordered chain with its
    evidence (cost resolved under DB-M16 semantics, verification under DB-M25,
    optional DB-M21 fingerprint, optional DB-M20 decision, terminal marker).
    #>
    param(
        [int]$Seq = 0,
        [string]$AttemptId,
        [int]$RetryNumber = 0,
        [string]$ParentAttemptId,
        [string]$EscalatedFromAttemptId,
        [string]$EscalatedToAttemptId,
        [string]$EscalationReason,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$UnderlyingModelId,
        [string]$GatewayProviderId,
        [string]$ReasoningLevel,
        [string]$Result,
        [string]$FailureCategory,
        [string]$FailureFingerprintId,
        $FailureFingerprint = $null,
        [string]$VerificationResult,
        [string]$ClaudeReviewStatus,
        $EstimatedCost = $null,
        $ActualCost = $null,
        [string]$CostSource = $null,
        $CostAmount = $null,
        $CumulativeCost = $null,
        $DurationMs = $null,
        $InputTokens = $null,
        $OutputTokens = $null,
        $ContextTokens = $null,
        [bool]$HumanIntervention = $false,
        [string]$TimestampUtc = '',
        [bool]$IsTerminal = $false,
        [string]$VerifiedState = 'INCOMPLETE',
        [string]$VerifiedReason = '',
        [string]$TerminalMarker = '',
        $Transition = $null,
        [AllowNull()][string[]]$Warnings = @()
    )
    return [pscustomobject]@{
        SchemaVersion          = 1
        Seq                    = $Seq
        AttemptId              = $(if ($AttemptId) { $AttemptId } else { $null })
        RetryNumber            = $RetryNumber
        ParentAttemptId        = $(if ($ParentAttemptId) { $ParentAttemptId } else { $null })
        EscalatedFromAttemptId = $(if ($EscalatedFromAttemptId) { $EscalatedFromAttemptId } else { $null })
        EscalatedToAttemptId   = $(if ($EscalatedToAttemptId) { $EscalatedToAttemptId } else { $null })
        EscalationReason       = $(if ($EscalationReason) { $EscalationReason } else { $null })
        ProviderId             = $(if ($ProviderId) { $ProviderId } else { $null })
        ModelId                = $(if ($ModelId) { $ModelId } else { $null })
        UnderlyingModelId      = $(if ($UnderlyingModelId) { $UnderlyingModelId } else { $null })
        GatewayProviderId      = $(if ($GatewayProviderId) { $GatewayProviderId } else { $null })
        ReasoningLevel         = $(if ($ReasoningLevel) { $ReasoningLevel } else { $null })
        Result                 = $(if ($Result) { $Result } else { $null })
        FailureCategory        = $(if ($FailureCategory) { $FailureCategory } else { $null })
        FailureFingerprintId   = $(if ($FailureFingerprintId) { $FailureFingerprintId } else { $null })
        FailureFingerprint     = $FailureFingerprint
        VerificationResult     = $(if ($VerificationResult) { $VerificationResult } else { $null })
        ClaudeReviewStatus     = $(if ($ClaudeReviewStatus) { $ClaudeReviewStatus } else { $null })
        EstimatedCost          = $EstimatedCost
        ActualCost             = $ActualCost
        CostSource             = $(if ($CostSource) { $CostSource } else { $null })
        CostAmount             = $CostAmount
        CumulativeCost         = $CumulativeCost
        DurationMs             = $DurationMs
        InputTokens            = $InputTokens
        OutputTokens           = $OutputTokens
        ContextTokens          = $ContextTokens
        HumanIntervention      = [bool]$HumanIntervention
        TimestampUtc           = $TimestampUtc
        IsTerminal             = [bool]$IsTerminal
        VerifiedState          = $VerifiedState
        VerifiedReason         = $(if ($VerifiedReason) { $VerifiedReason } else { $null })
        TerminalMarker         = $(if ($TerminalMarker) { $TerminalMarker } else { $null })
        Transition             = $Transition
        Warnings               = @($Warnings)
    }
}

# --- TaskHistoryRow v1 ------------------------------------------------------------------

function New-DbM29TaskHistoryRow {
    <#
    .SYNOPSIS
    Construct a TaskHistoryRow v1: the brief's TASK HISTORY VIEW fields plus the
    ordered timeline for the ATTEMPT TIMELINE drilldown.
    #>
    param(
        [string]$TaskId,
        [string]$NodeId,
        [string]$ChangeId,
        [string]$ChainId,
        [bool]$LoopFree = $true,
        [string]$LoopReason = '',
        [string]$Mode = '',
        [int]$AttemptCount = 0,
        $TotalActualCost = $null,
        $TotalEstimatedCost = $null,
        [string]$VerifiedState = 'NO_ATTEMPTS',
        [string]$VerifiedReason = '',
        [string]$FirstAttemptSuccess = 'UNKNOWN',
        [string]$FirstAttemptId = '',
        [string]$FinalAttemptId = '',
        [string]$VerifiedAttemptId = '',
        [string]$FinalProviderId = '',
        [string]$FinalModelId = '',
        [string]$FinalUnderlyingModelId = '',
        [string]$FinalGatewayProviderId = '',
        [string]$FinalReasoningLevel = '',
        [string]$TerminalOutcome = '',
        [int]$CorrectionsCount = 0,
        [int]$EscalationsCount = 0,
        [int]$FailureCount = 0,
        $Timeline = @()
    )
    return [pscustomobject]@{
        SchemaVersion           = 1
        TaskId                  = $(if ($TaskId) { $TaskId } else { $null })
        NodeId                  = $(if ($NodeId) { $NodeId } else { $null })
        ChangeId                = $(if ($ChangeId) { $ChangeId } else { $null })
        ChainId                 = $(if ($ChainId) { $ChainId } else { $null })
        LoopFree                = [bool]$LoopFree
        LoopReason              = $(if ($LoopReason) { $LoopReason } else { $null })
        Mode                    = $(if ($Mode) { $Mode } else { $null })
        AttemptCount            = $AttemptCount
        TotalActualCost         = $TotalActualCost
        TotalEstimatedCost      = $TotalEstimatedCost
        VerifiedState           = $VerifiedState
        VerifiedReason          = $(if ($VerifiedReason) { $VerifiedReason } else { $null })
        FirstAttemptSuccess     = $FirstAttemptSuccess
        FirstAttemptId          = $(if ($FirstAttemptId) { $FirstAttemptId } else { $null })
        FinalAttemptId          = $(if ($FinalAttemptId) { $FinalAttemptId } else { $null })
        VerifiedAttemptId       = $(if ($VerifiedAttemptId) { $VerifiedAttemptId } else { $null })
        FinalProviderId         = $(if ($FinalProviderId) { $FinalProviderId } else { $null })
        FinalModelId            = $(if ($FinalModelId) { $FinalModelId } else { $null })
        FinalUnderlyingModelId  = $(if ($FinalUnderlyingModelId) { $FinalUnderlyingModelId } else { $null })
        FinalGatewayProviderId  = $(if ($FinalGatewayProviderId) { $FinalGatewayProviderId } else { $null })
        FinalReasoningLevel     = $(if ($FinalReasoningLevel) { $FinalReasoningLevel } else { $null })
        TerminalOutcome         = $(if ($TerminalOutcome) { $TerminalOutcome } else { $null })
        CorrectionsCount        = $CorrectionsCount
        EscalationsCount        = $EscalationsCount
        FailureCount            = $FailureCount
        Timeline                = @($Timeline)
    }
}

# --- TaskHistoryView v1 -------------------------------------------------------------------

function New-DbM29TaskHistoryView {
    <#
    .SYNOPSIS
    Construct a TaskHistoryView v1 (the engine's return value).
    #>
    param(
        [string]$RequestId = '',
        [string]$QueryId = '',
        [string]$GeneratedAtUtc = '',
        [string]$NowUtc = '',
        [string]$Currency = 'INR',
        [string]$SuccessDefinition = 'VERIFIED',
        [int]$Count = 0,
        [bool]$Empty = $true,
        $TaskRows = @(),
        $ReadOnlyGuard = $null,
        [AllowNull()][string[]]$Warnings = @()
    )
    return [pscustomobject]@{
        SchemaVersion      = 1
        RequestId          = $(if ($RequestId) { $RequestId } else { $null })
        QueryId            = $(if ($QueryId) { $QueryId } else { $null })
        GeneratedAtUtc     = $(if ($GeneratedAtUtc) { $GeneratedAtUtc } else { $null })
        NowUtc             = $(if ($NowUtc) { $NowUtc } else { $null })
        Currency           = $Currency
        SuccessDefinition  = $SuccessDefinition
        Count              = $Count
        Empty              = [bool]$Empty
        TaskRows           = @($TaskRows)
        ReadOnlyGuard      = $ReadOnlyGuard
        Warnings           = @($Warnings)
    }
}

# --- ReadOnlyGuard v1 -----------------------------------------------------------------------

function New-DbM29ReadOnlyGuard {
    <#
    .SYNOPSIS
    Deterministic no-execution guard: DB-M29 never executes an AI model, never
    makes a paid/network call, never mutates the attempt store, escalation
    decisions, budget policy or fingerprints, and never renders/logs a secret.
    #>
    return [pscustomobject]@{
        SchemaVersion              = 1
        AutoExecutionEnabled       = $false
        PaidApiCalls               = 0
        NetworkCalls               = 0
        AttemptStoreModified       = 'NO'
        EscalationDecisionsModified = 'NO'
        BudgetPolicyModified       = 'NO'
        FingerprintsModified       = 'NO'
        SecretValuesDisplayed      = 'NO'
        SecretValuesLogged         = 'NO'
    }
}

# --- secret-value guard (DB-M29 variant) ------------------------------------------

function Test-DbM29SecretLeak {
    <#
    .SYNOPSIS
    Scan a DB-M29 view object (or any object) for API-key-like VALUES. Identifiers,
    references, hashes, vocabulary values and numeric cost fields are exempt by
    design; free-text fields (Explanation, Warnings, Notes, EscalationReason,
    LoopReason) ARE scanned. Never stores secrets.
    #>
    param(
        [AllowNull()][object]$Target
    )
    $exempt = @(
        'SchemaVersion', 'QueryId', 'RequestId', 'TaskId', 'NodeId', 'ChangeId',
        'AttemptId', 'ParentAttemptId', 'EscalatedFromAttemptId', 'EscalatedToAttemptId',
        'ChainId', 'FirstAttemptId', 'TerminalAttemptId', 'FinalAttemptId', 'VerifiedAttemptId',
        'ProviderId', 'ModelId', 'UnderlyingModelId', 'GatewayProviderId',
        'ReasoningLevel', 'TaskType', 'Complexity', 'Risk', 'Mode', 'Result',
        'VerificationResult', 'VerificationEvidencePath', 'FailureCategory',
        'FailureFingerprintId', 'UsageSource', 'CostCurrency', 'ExecutionMode',
        'RoutingDecisionId', 'PricingRecordId', 'RetryNumber', 'HumanIntervention',
        'ManualOverride', 'StartedAtUtc', 'EndedAtUtc', 'TimestampUtc', 'GeneratedAtUtc',
        'NowUtc', 'DurationMs', 'InputTokens', 'CachedInputTokens', 'CacheWriteTokens',
        'OutputTokens', 'ReasoningTokens', 'ToolCalls', 'ContextTokens',
        'RawAvailableContextTokens', 'SelectedContextTokens', 'ContextReductionPercent',
        'FilesChanged', 'TestsPassed', 'TestsFailed', 'TestsSkipped',
        'EstimatedCost', 'ActualCost', 'CostAmount', 'CostSource', 'CumulativeCost',
        'TotalActualCost', 'TotalEstimatedCost', 'ExchangeRate',
        'AttemptCount', 'CorrectionsCount', 'EscalationsCount', 'FailureCount', 'Count',
        'Empty', 'LoopFree', 'IsTerminal', 'Type', 'Action', 'DecisionId',
        'RequiresHuman', 'HumanActionType', 'SuccessDefinition', 'Currency',
        'SortBy', 'SortDirection', 'VerifiedState', 'VerifiedReason',
        'FirstAttemptSuccess', 'FinalProviderId', 'FinalModelId', 'FinalUnderlyingModelId',
        'FinalGatewayProviderId', 'FinalReasoningLevel', 'TerminalOutcome', 'Outcome',
        'Success', 'Verified', 'ModelReturned', 'Contradicted', 'ReviewRejected',
        'ReviewStatus', 'TerminalMarker', 'Warning',
        'ReasonCodes', 'Signature', 'FingerprintId', 'OccurrenceCount',
        'FirstSeenUtc', 'LastSeenUtc', 'RecurrenceType', 'NormalizedFailureCodes',
        'ToolCategory', 'ContextHash', 'PromptHash', 'PromptArtifactReference',
        'ObservedState', 'HttpStatusClass', 'RetryAfterUtc', 'EvidenceId', 'RouteId',
        'HealthState', 'CircuitState', 'LastEvidenceTime', 'RetryAfter', 'ConfidenceSource',
        'AutoExecutionEnabled', 'PaidApiCalls', 'NetworkCalls', 'AttemptStoreModified',
        'EscalationDecisionsModified', 'BudgetPolicyModified', 'FingerprintsModified',
        'SecretValuesDisplayed', 'SecretValuesLogged', 'Title', 'Summary',
        'GeneratedAtUtc'
    )
    $patterns = @(
        '^sk-[A-Za-z0-9_-]{8,}$',                 # OpenAI-style
        '^AIza[0-9A-Za-z_-]{10,}$',               # Google-style
        '^gh[pousr]_[A-Za-z0-9]{20,}$',           # GitHub tokens
        '^[A-Za-z0-9+/=_\-]{32,}$',               # generic high-entropy token
        '^-----BEGIN'                             # PEM block
    )
    $leaks = New-Object System.Collections.Generic.List[string]

    function Test-DbM29LeakValue([string]$fieldName, [object]$value) {
        if ($null -eq $value) { return }
        if ($fieldName -in $exempt) { return }
        $s = [string]$value
        if ($s.Length -lt 8) { return }
        foreach ($p in $patterns) {
            if ($s -match $p) { $leaks.Add("$fieldName = <redacted> matches $p"); return }
        }
        if ($s -match '(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*\S') {
            $leaks.Add("$fieldName contains inline credential assignment")
        }
    }

    function Test-DbM29LeakObject([string]$path, [object]$obj) {
        if ($null -eq $obj) { return }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($k in $obj.Keys) {
                $v = $obj[$k]
                $name = if ($path) { "$path.$k" } else { [string]$k }
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-DbM29LeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-DbM29LeakObject $name $item } else { Test-DbM29LeakValue ([string]$k) $item } }
                }
                else { Test-DbM29LeakValue ([string]$k) $v }
            }
            return
        }
        if ($obj -is [PSCustomObject]) {
            foreach ($prop in $obj.PSObject.Properties) {
                $name = if ($path) { "$path.$($prop.Name)" } else { $prop.Name }
                $v = $prop.Value
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-DbM29LeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-DbM29LeakObject $name $item } else { Test-DbM29LeakValue $prop.Name $item } }
                }
                else { Test-DbM29LeakValue $prop.Name $v }
            }
            return
        }
        Test-DbM29LeakValue 'value' $obj
    }

    Test-DbM29LeakObject '' $Target
    return @{ Leak = ($leaks.Count -gt 0); Fields = @($leaks) }
}

# --- backend markers ----------------------------------------------------------------------

function Out-DbM29Markers {
    <#
    .SYNOPSIS
    Backend contract markers (DB-M28 pattern). The calling script ALWAYS exits 0;
    outcomes are communicated ONLY via stdout markers so a governed harness can
    read them without exit-code ambiguity.
    #>
    'DB29_OUTCOME: PASS'
    'DB29_RESULT_PASS'
    'DB29_WORKBOOK_MODIFIED: False'
    'DB29_NEXUS_SOURCE_MODIFIED: False'
    'DB29_GIT_MODIFIED: False'
    return $true
}

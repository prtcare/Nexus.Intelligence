# FingerprintEngine.ps1 -- DB-M21 Part B failure-fingerprint engine.
#
# Computes FailureFingerprint v1 records, matches them against the known
# fingerprint history, types the recurrence, and decides whether an identical
# repeat may be retried. The engine emits signals only (RETRY_SUPPRESSED_
# KNOWN_FAILURE / RETRY_ALLOWED_*); it NEVER executes the retry or the replan.
# No model/provider execution. AUTO_EXECUTION_ENABLED = FALSE.
#
# Consumed read-only: DB-M14 vocab (AiRoutingContracts.ps1), DB-M20 failure
# category vocabulary (EscalationPolicy.ps1). No competing store is created.

. (Join-Path $PSScriptRoot "FingerprintContracts.ps1")

# -----------------------------------------------------------------------------
# New-AiFailureFingerprint
# -----------------------------------------------------------------------------
function New-AiFailureFingerprint {
    <#
    .SYNOPSIS
    Build a FailureFingerprint v1 from a DB-M17-style attempt record (or from
    explicit fields). Failure codes are normalized to the canonical sorted set;
    the Signature is the failure identity (task type + category + normalized
    codes + tool category), so the same meaningful failure yields the same
    signature regardless of route. Route identity and context/prompt hashes are
    structured fields for recurrence typing.
    #>
    param(
        [AllowNull()][object]$InputObject,
        [int]$AlgorithmVersion = 1,
        [string]$TaskId,
        [string]$ChangeId,
        [string]$TaskType,
        [string]$FailureCategory,
        [AllowNull()][object[]]$FailureCodes,
        [string]$ModelId,
        [string]$UnderlyingModelId,
        [string]$ProviderId,
        [string]$GatewayProviderId,
        [string]$ReasoningLevel,
        [string]$ContextHash,
        [string]$PromptHashReference,
        [string]$ToolCategory,
        [AllowNull()][int]$OccurrenceCount = 1,
        [string]$AttemptId,
        [string]$Notes,
        [AllowNull()]$TimestampUtc,
        [bool]$NormalizeLineNumbers = $true
    )
    $g = { param($n, $d) Get-ContractProperty $InputObject $n $d }
    $taskType      = if ($InputObject) { & $g 'TaskType' $TaskType } else { $TaskType }
    $failureCategory = if ($InputObject) { & $g 'FailureCategory' $FailureCategory } else { $FailureCategory }
    $toolCategory  = if ($InputObject) { & $g 'ToolCategory' $ToolCategory } else { $ToolCategory }
    $reasoningLevel = if ($InputObject) { & $g 'ReasoningLevel' $ReasoningLevel } else { $ReasoningLevel }

    if (-not $taskType -or $taskType -notin (Get-AiRoutingTaskTypes)) { throw "New-AiFailureFingerprint: TaskType '$taskType' invalid" }
    if (-not $failureCategory -or $failureCategory -notin (Get-DbM20FailureCategories)) { throw "New-AiFailureFingerprint: FailureCategory '$failureCategory' invalid" }
    if (-not $toolCategory -or $toolCategory -notin (Get-DbM21ToolCategories)) { throw "New-AiFailureFingerprint: ToolCategory '$toolCategory' invalid" }
    if ($reasoningLevel -and $reasoningLevel -notin (Get-AiRoutingReasoningLevels)) { throw "New-AiFailureFingerprint: ReasoningLevel '$reasoningLevel' invalid" }
    if ($ContextHash -and $ContextHash -notmatch '^[0-9a-f]{64}$') { throw "New-AiFailureFingerprint: ContextHash must be empty or 64-hex SHA-256" }
    if ($null -eq $TimestampUtc) { throw "New-AiFailureFingerprint: TimestampUtc is required (inject it; never read the machine clock)" }

    $codes = Get-DbM21NormalizedFailureCodes -Codes @(if ($InputObject) { & $g 'FailureCodes' $FailureCodes } else { $FailureCodes }) `
        -NormalizeLineNumbers $NormalizeLineNumbers

    $attemptId = if ($InputObject) { [string](& $g 'AttemptId' $AttemptId) } else { $AttemptId }
    $notes = if ($InputObject) { & $g 'Notes' $Notes } else { $Notes }

    $fp = New-FailureFingerprint @{
        AlgorithmVersion       = $AlgorithmVersion
        TaskId                 = if ($InputObject) { & $g 'TaskId' $TaskId } else { $TaskId }
        ChangeId               = if ($InputObject) { & $g 'ChangeId' $ChangeId } else { $ChangeId }
        TaskType               = $taskType
        FailureCategory        = $failureCategory
        NormalizedFailureCodes = $codes
        ModelId                = if ($InputObject) { & $g 'ModelId' $ModelId } else { $ModelId }
        UnderlyingModelId      = if ($InputObject) { & $g 'UnderlyingModelId' $UnderlyingModelId } else { $UnderlyingModelId }
        ProviderId             = if ($InputObject) { & $g 'ProviderId' $ProviderId } else { $ProviderId }
        GatewayProviderId      = if ($InputObject) { & $g 'GatewayProviderId' $GatewayProviderId } else { $GatewayProviderId }
        ReasoningLevel         = $reasoningLevel
        ContextHash            = if ($InputObject) { & $g 'ContextHash' $ContextHash } else { $ContextHash }
        PromptHashReference    = if ($InputObject) { & $g 'PromptHashReference' $PromptHashReference } else { $PromptHashReference }
        ToolCategory           = $toolCategory
        FirstSeenUtc           = $TimestampUtc
        LastSeenUtc            = $TimestampUtc
        OccurrenceCount        = $OccurrenceCount
        AttemptId              = $attemptId
        Notes                  = $notes
        NormalizeLineNumbers   = $NormalizeLineNumbers
    }
    return $fp
}

# -----------------------------------------------------------------------------
# Matching + recurrence typing (shared by Compare / Get-AiKnownFailureEvidence)
# -----------------------------------------------------------------------------
function Get-DbM21FailureIdentityFingerprint {
    <#
    .SYNOPSIS
    The failure-identity component string of a fingerprint (the MATCH key).
    Same meaningful failure -> same identity, regardless of route/context.
    #>
    param([AllowNull()][pscustomobject]$Fingerprint)
    if ($null -eq $Fingerprint) { return '' }
    $codes = @(Get-ContractProperty $Fingerprint 'NormalizedFailureCodes' @()) -join ';'
    return "fp$(Get-ContractProperty $Fingerprint 'AlgorithmVersion' 0)|" +
        "$(Get-ContractProperty $Fingerprint 'TaskType' '')|" +
        "$(Get-ContractProperty $Fingerprint 'FailureCategory' '')|$codes|" +
        "$(Get-ContractProperty $Fingerprint 'ToolCategory' '')"
}

function Get-DbM21ReasoningOrder {
    param([string]$Level)
    $order = Get-AiRoutingReasoningOrder
    if ($order.ContainsKey($Level)) { return [int]$order[$Level] }
    return -1
}

function Test-DbM21FieldsSame {
    <#
    .SYNOPSIS
    Lenient route-field equality for recurrence typing: two blank fields are
    "same" (nothing distinguishes them); two present fields must be equal.
    A blank vs a present field is NOT same.
    #>
    param([AllowNull()][string]$A, [AllowNull()][string]$B)
    $a = if ($A) { [string]$A } else { '' }
    $b = if ($B) { [string]$B } else { '' }
    if (-not $a -and -not $b) { return $true }
    return ($a -and $b -and $a -eq $b)
}

function Get-DbM21RecurrenceEvidence {
    <#
    .SYNOPSIS
    Core recurrence computation for one fingerprint against the known history.
    Returns the raw evidence bundle; Compare/Get-AiKnownFailureEvidence shape it.
    #>
    param(
        [AllowNull()][pscustomobject]$NewFingerprint,
        [AllowNull()][object[]]$KnownFingerprints,
        [string]$Result
    )
    if ($null -eq $NewFingerprint) { throw "Get-DbM21RecurrenceEvidence: NewFingerprint is required" }
    $newIdentity = Get-DbM21FailureIdentityFingerprint $NewFingerprint
    $newTaskType = [string](Get-ContractProperty $NewFingerprint 'TaskType' '')
    $newCat = [string](Get-ContractProperty $NewFingerprint 'FailureCategory' '')
    $newTool = [string](Get-ContractProperty $NewFingerprint 'ToolCategory' '')
    $newProvider = [string](Get-ContractProperty $NewFingerprint 'ProviderId' '')
    $newGateway = [string](Get-ContractProperty $NewFingerprint 'GatewayProviderId' '')
    $newModel = [string](Get-ContractProperty $NewFingerprint 'ModelId' '')
    $newUnderlying = [string](Get-ContractProperty $NewFingerprint 'UnderlyingModelId' '')
    $newReasoning = [string](Get-ContractProperty $NewFingerprint 'ReasoningLevel' '')
    $newContext = [string](Get-ContractProperty $NewFingerprint 'ContextHash' '')

    $matched = New-Object System.Collections.ArrayList
    foreach ($k in @($KnownFingerprints)) {
        if ($null -eq $k) { continue }
        if ((Get-DbM21FailureIdentityFingerprint $k) -eq $newIdentity) { $null = $matched.Add($k) }
    }

    if ($matched.Count -eq 0) {
        return @{
            RecurrenceType = 'FIRST_OCCURRENCE'; Matched = @(); MatchedCount = 0
            OccurrenceCount = [int](Get-ContractProperty $NewFingerprint 'OccurrenceCount' 1)
            FirstSeenUtc = Get-ContractProperty $NewFingerprint 'FirstSeenUtc' $null
            LastSeenUtc = Get-ContractProperty $NewFingerprint 'LastSeenUtc' $null
            AttemptIds = @(Get-ContractProperty $NewFingerprint 'AttemptIds' @())
            SameProvider = $false; SameGateway = $false; SameModel = $false; SameReasoning = $false
            ReasoningEscalated = $false; ContextKnown = $false; SameContext = $false
            MatchedProviderId = $null; MatchedGatewayId = $null; MatchedModelId = $null
            MatchedReasoningLevel = $null; MatchedContextHash = ''
            FailureIdentity = $newIdentity
            Message = 'no fingerprint with this failure identity is known; first occurrence'
        }
    }

    # pick the most recent matched prior as the route reference
    $ref = $matched[0]
    foreach ($m in @($matched)) {
        $mL = Get-ContractProperty $m 'LastSeenUtc' $null
        $rL = Get-ContractProperty $ref 'LastSeenUtc' $null
        if ($mL -and $rL -and ([datetime]$mL) -gt ([datetime]$rL)) { $ref = $m }
    }
    $refProvider = [string](Get-ContractProperty $ref 'ProviderId' '')
    $refGateway = [string](Get-ContractProperty $ref 'GatewayProviderId' '')
    $refModel = [string](Get-ContractProperty $ref 'ModelId' '')
    $refReasoning = [string](Get-ContractProperty $ref 'ReasoningLevel' '')

    # success now -> the known failure is resolved (even though it recurred once)
    $successNow = ($Result -in @('SUCCESS', 'PASS', 'VERIFIED', 'DONE', 'COMPLETE'))
    if ($successNow) {
        return @{
            RecurrenceType = 'KNOWN_FAILURE_RESOLVED'; Matched = @($matched); MatchedCount = $matched.Count
            OccurrenceCount = ($matched.Count + 1)
            FirstSeenUtc = Get-ContractProperty $matched[0] 'FirstSeenUtc' $null
            LastSeenUtc = Get-ContractProperty $NewFingerprint 'FirstSeenUtc' $null
            AttemptIds = @((@($matched | ForEach-Object { @(Get-ContractProperty $_ 'AttemptIds' @()) }) | ForEach-Object { $_ }) + @(Get-ContractProperty $NewFingerprint 'AttemptIds' @()))
            SameProvider = ($newProvider -and $refProvider -and $newProvider -eq $refProvider)
            SameGateway = ($newGateway -and $refGateway -and $newGateway -eq $refGateway)
            SameModel = ($newModel -and $refModel -and $newModel -eq $refModel)
            SameReasoning = ($newReasoning -and $refReasoning -and $newReasoning -eq $refReasoning)
            ReasoningEscalated = $false; ContextKnown = $false; SameContext = $false
            MatchedProviderId = $refProvider; MatchedGatewayId = $refGateway; MatchedModelId = $refModel
            MatchedReasoningLevel = $refReasoning; MatchedContextHash = ''
            FailureIdentity = $newIdentity
            Message = 'the known failure recurred but this attempt succeeded; typed KNOWN_FAILURE_RESOLVED'
        }
    }

    # recurrence typing
    $reasoningEscalated = $false
    $maxPriorReasoning = -1
    foreach ($m in @($matched)) {
        $rl = [string](Get-ContractProperty $m 'ReasoningLevel' '')
        $ord = Get-DbM21ReasoningOrder $rl
        if ($ord -gt $maxPriorReasoning) { $maxPriorReasoning = $ord }
    }
    $newReasoningOrder = Get-DbM21ReasoningOrder $newReasoning
    if ($newReasoningOrder -gt $maxPriorReasoning -and $maxPriorReasoning -ge 0) { $reasoningEscalated = $true }

    $sameProvider = Test-DbM21FieldsSame $newProvider $refProvider
    $sameGateway = Test-DbM21FieldsSame $newGateway $refGateway
    $sameModel = Test-DbM21FieldsSame $newModel $refModel
    $sameReasoning = Test-DbM21FieldsSame $newReasoning $refReasoning
    $differentModel = ($newModel -and $refModel -and $newModel -ne $refModel)

    $rt = $null
    if ($differentModel) { $rt = 'REPEATED_AFTER_MODEL_SWITCH' }
    elseif ($sameModel -and $reasoningEscalated) { $rt = 'REPEATED_AFTER_REASONING_ESCALATION' }
    elseif ($sameProvider -and $sameGateway -and $sameModel -and $sameReasoning) { $rt = 'REPEATED_SAME_ROUTE' }
    elseif ($sameProvider -and $sameModel) { $rt = 'REPEATED_SAME_MODEL' }
    else { $rt = 'REPEATED_SAME_FAILURE' }

    # known-same context: the new context hash is present and equals every
    # matched prior that carries one (both present and equal).
    $contextKnown = $false
    if ($newContext) {
        $contextKnown = $true
        foreach ($m in @($matched)) {
            $mc = [string](Get-ContractProperty $m 'ContextHash' '')
            if ($mc -and $mc -ne $newContext) { $contextKnown = $false; break }
        }
    }

    return @{
        RecurrenceType = $rt; Matched = @($matched); MatchedCount = $matched.Count
        OccurrenceCount = ($matched.Count + 1)
        FirstSeenUtc = Get-ContractProperty $matched[0] 'FirstSeenUtc' $null
        LastSeenUtc = Get-ContractProperty $NewFingerprint 'FirstSeenUtc' $null
        AttemptIds = @((@($matched | ForEach-Object { @(Get-ContractProperty $_ 'AttemptIds' @()) }) | ForEach-Object { $_ }) + @(Get-ContractProperty $NewFingerprint 'AttemptIds' @()))
        SameProvider = $sameProvider; SameGateway = $sameGateway; SameModel = $sameModel; SameReasoning = $sameReasoning
        ReasoningEscalated = $reasoningEscalated; ContextKnown = $contextKnown; SameContext = $contextKnown
        MatchedProviderId = $refProvider; MatchedGatewayId = $refGateway; MatchedModelId = $refModel
        MatchedReasoningLevel = $refReasoning; MatchedContextHash = $(if ($contextKnown) { $newContext } else { '' })
        FailureIdentity = $newIdentity
        Message = "matched $($matched.Count) known fingerprint(s); recurrence type $rt (occurrence $($matched.Count + 1))"
    }
}

# -----------------------------------------------------------------------------
# Compare-AiFailureFingerprint
# -----------------------------------------------------------------------------
function Compare-AiFailureFingerprint {
    <#
    .SYNOPSIS
    Version-scoped comparison of a fingerprint against the known history.
    Returns the recurrence type plus occurrence bookkeeping. Matching is
    failure-identity scoped; route/context differences are typed, never
    flattened. A v2 fingerprint never matches a v1 fingerprint.
    #>
    param(
        [AllowNull()][pscustomobject]$NewFingerprint,
        [AllowNull()][object[]]$KnownFingerprints,
        [string]$Result
    )
    $ev = Get-DbM21RecurrenceEvidence -NewFingerprint $NewFingerprint -KnownFingerprints $KnownFingerprints -Result $Result
    return @{
        RecurrenceType    = $ev.RecurrenceType
        MatchedCount      = $ev.MatchedCount
        OccurrenceCount   = $ev.OccurrenceCount
        FirstSeenUtc      = $ev.FirstSeenUtc
        LastSeenUtc       = $ev.LastSeenUtc
        AttemptIds        = $ev.AttemptIds
        SameProvider      = $ev.SameProvider
        SameGateway       = $ev.SameGateway
        SameModel         = $ev.SameModel
        SameReasoning     = $ev.SameReasoning
        ReasoningEscalated = $ev.ReasoningEscalated
        ContextKnown      = $ev.ContextKnown
        SameContext       = $ev.SameContext
        Message           = $ev.Message
    }
}

# -----------------------------------------------------------------------------
# Get-AiKnownFailureEvidence
# -----------------------------------------------------------------------------
function Get-AiKnownFailureEvidence {
    <#
    .SYNOPSIS
    The full evidence bundle for a fingerprint against the known history: the
    matched prior fingerprints, recurrence type, route/context flags and the
    matched route reference (used by Test-AiRepeatAttemptAllowed).
    #>
    param(
        [AllowNull()][pscustomobject]$Fingerprint,
        [AllowNull()][object[]]$KnownFingerprints,
        [string]$Result
    )
    $ev = Get-DbM21RecurrenceEvidence -NewFingerprint $Fingerprint -KnownFingerprints $KnownFingerprints -Result $Result
    return @{
        RecurrenceType      = $ev.RecurrenceType
        MatchedFingerprints = @($ev.Matched)
        MatchedCount        = $ev.MatchedCount
        OccurrenceCount     = $ev.OccurrenceCount
        FirstSeenUtc        = $ev.FirstSeenUtc
        LastSeenUtc         = $ev.LastSeenUtc
        AttemptIds          = @($ev.AttemptIds)
        SameProvider        = $ev.SameProvider
        SameGateway         = $ev.SameGateway
        SameModel           = $ev.SameModel
        SameReasoning       = $ev.SameReasoning
        ReasoningEscalated  = $ev.ReasoningEscalated
        ContextKnown        = $ev.ContextKnown
        SameContext         = $ev.SameContext
        MatchedProviderId   = $ev.MatchedProviderId
        MatchedGatewayId    = $ev.MatchedGatewayId
        MatchedModelId      = $ev.MatchedModelId
        MatchedReasoningLevel = $ev.MatchedReasoningLevel
        MatchedContextHash  = $ev.MatchedContextHash
        FailureIdentity     = $ev.FailureIdentity
        KnownFailureResolved = ($ev.RecurrenceType -eq 'KNOWN_FAILURE_RESOLVED')
        Message             = $ev.Message
    }
}

# -----------------------------------------------------------------------------
# Test-AiRepeatAttemptAllowed
# -----------------------------------------------------------------------------
function Test-AiRepeatAttemptAllowed {
    <#
    .SYNOPSIS
    Decide whether a proposed retry of a repeated failure may proceed.
    DB-M21 suppresses ONLY an identical repeat: REPEATED_SAME_ROUTE with a
    known-same context, above MaxRepeatsBeforeSuppress. A changed context, a
    reasoning escalation, or a model switch are meaningful changes ->
    RETRY_ALLOWED_* (the DB-M20 layer then replans; DB-M21 never executes it).
    #>
    param(
        [AllowNull()][object]$Evidence,
        [string]$ProposedProviderId,
        [string]$ProposedModelId,
        [string]$ProposedReasoningLevel,
        [string]$ProposedContextHash,
        [int]$MaxRepeatsBeforeSuppress = 3
    )
    if ($null -eq $Evidence) { throw "Test-AiRepeatAttemptAllowed: Evidence is required (Get-AiKnownFailureEvidence)" }
    $rt = [string](Get-ContractProperty $Evidence 'RecurrenceType' '')

    if ($rt -eq 'KNOWN_FAILURE_RESOLVED') {
        return @{ Allowed = $true; Outcome = 'RETRY_ALLOWED_KNOWN_FAILURE_RESOLVED'; RecurrenceType = $rt; OccurrenceCount = [int](Get-ContractProperty $Evidence 'OccurrenceCount' 1); Message = 'the known failure was resolved by a success; a fresh attempt is not an identical repeat' }
    }
    if ($rt -eq 'FIRST_OCCURRENCE') {
        return @{ Allowed = $true; Outcome = 'RETRY_ALLOWED_FIRST_OCCURRENCE'; RecurrenceType = $rt; OccurrenceCount = [int](Get-ContractProperty $Evidence 'OccurrenceCount' 1); Message = 'first occurrence; no repeat to suppress' }
    }
    if ($rt -ne 'REPEATED_SAME_ROUTE') {
        return @{ Allowed = $true; Outcome = 'RETRY_ALLOWED_NON_IDENTICAL_REPEAT'; RecurrenceType = $rt; OccurrenceCount = [int](Get-ContractProperty $Evidence 'OccurrenceCount' 1); Message = "recurrence type $rt is not an identical repeat; retry allowed for DB-M20 to replan" }
    }

    $occurrence = [int](Get-ContractProperty $Evidence 'OccurrenceCount' 1)
    $matchedModel = [string](Get-ContractProperty $Evidence 'MatchedModelId' '')
    $matchedReasoning = [string](Get-ContractProperty $Evidence 'MatchedReasoningLevel' '')
    $matchedContext = [string](Get-ContractProperty $Evidence 'MatchedContextHash' '')
    $sameContext = [bool](Get-ContractProperty $Evidence 'SameContext' $false)

    # meaningful changes on the PROPOSED route -> allowed
    if ($ProposedModelId -and $matchedModel -and $ProposedModelId -ne $matchedModel) {
        return @{ Allowed = $true; Outcome = 'RETRY_ALLOWED_MODEL_SWITCH'; RecurrenceType = $rt; OccurrenceCount = $occurrence; Message = 'proposed model differs from the repeated route; allowed' }
    }
    $po = Get-DbM21ReasoningOrder $ProposedReasoningLevel
    $mo = Get-DbM21ReasoningOrder $matchedReasoning
    if ($po -gt $mo -and $mo -ge 0) {
        return @{ Allowed = $true; Outcome = 'RETRY_ALLOWED_REASONING_ESCALATED'; RecurrenceType = $rt; OccurrenceCount = $occurrence; Message = 'proposed reasoning is higher than the repeated route; allowed' }
    }
    if ($ProposedContextHash -and $matchedContext -and $ProposedContextHash -ne $matchedContext) {
        return @{ Allowed = $true; Outcome = 'RETRY_ALLOWED_CONTEXT_CHANGED'; RecurrenceType = $rt; OccurrenceCount = $occurrence; Message = 'proposed context differs from the repeated context; allowed' }
    }
    if (-not $sameContext) {
        return @{ Allowed = $true; Outcome = 'RETRY_ALLOWED_NON_IDENTICAL_REPEAT'; RecurrenceType = $rt; OccurrenceCount = $occurrence; Message = 'context is not known-same (both present and equal); not an identical repeat' }
    }
    if ($occurrence -gt $MaxRepeatsBeforeSuppress) {
        return @{ Allowed = $false; Outcome = 'RETRY_SUPPRESSED_KNOWN_FAILURE'; RecurrenceType = $rt; OccurrenceCount = $occurrence; Message = "identical repeat ($occurrence occurrences, threshold $MaxRepeatsBeforeSuppress); retry suppressed -- DB-M20 must replan" }
    }
    return @{ Allowed = $true; Outcome = 'RETRY_ALLOWED_REPEAT_WITHIN_THRESHOLD'; RecurrenceType = $rt; OccurrenceCount = $occurrence; Message = "identical repeat but within threshold ($occurrence <= $MaxRepeatsBeforeSuppress); allowed" }
}

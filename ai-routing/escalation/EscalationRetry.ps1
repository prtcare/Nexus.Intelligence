# EscalationRetry.ps1 -- DB-M20 retry gating + reasoning escalation + loop protection.
#
# DB-M20 is a DECISION ENGINE: these operations only PLANNED retries and
# escalations. Nothing is executed. No paid API calls. No autonomous Nexus
# changes. AUTO_EXECUTION_ENABLED = FALSE.
#
#   Test-AiRetryAllowed          - is a same-route retry justified and bounded?
#   Get-AiNextReasoningLevel     - the next reasoning level ONE step above the
#                                  current level (never an automatic jump to MAX),
#                                  gated by model support + policy limits
#   Test-AiEscalationLoop        - prove a chain is acyclic and a proposed next
#                                  route/reasoning combination is not a revisit

. (Join-Path $PSScriptRoot "EscalationPolicy.ps1")

# -----------------------------------------------------------------------------
# Retryable-category predicate (same-route retry is only ever justified here)
# -----------------------------------------------------------------------------
function Test-DbM20CategoryRetryable([string]$Category) {
    <#
    .SYNOPSIS
    The only categories that justify a same-route retry: transient conditions
    (TIMEOUT, PROVIDER_AVAILABILITY, RATE_LIMIT, TOOL_FAILURE) plus
    BUILD_FAILURE / TEST_FAILURE where the model re-attempts the repair. A
    MODEL_QUALITY failure is NOT blindly retried at the same reasoning level
    (prefer reasoning escalation / focused correction). Unknown failures are
    never retried blindly.
    #>
    if (-not (Test-IsValidDbM20FailureCategory $Category)) { return $false }
    $class = Get-DbM20FailureClassForCategory $Category
    if ($class -eq 'TRANSIENT') { return $true }
    return ($Category -in @('BUILD_FAILURE', 'TEST_FAILURE'))
}

function Test-AiRetryAllowed {
    <#
    .SYNOPSIS
    Deterministic same-route retry gate. A same-route retry is allowed only when
    the category justifies it, the attempt budget is not exhausted
    (AttemptNumber <= Policy.MaxAttemptsPerTask), the same-model retry budget is
    not exhausted (count < Policy.MaxSameModelRetries) and the chain is
    loop-free. "Do not permit infinite retry loops."
    Returns @{ Allowed; Reason; RetryNumber }.
    #>
    param(
        [string]$Category,
        [int]$AttemptNumber,
        [AllowNull()][pscustomobject]$Policy,
        [AllowNull()][object[]]$Attempts,
        [string]$CurrentModelId,
        [bool]$LoopFree = $true
    )
    $policy = $Policy
    if ($null -eq $policy) { $policy = Get-DefaultEscalationPolicy }
    $retryNumber = $AttemptNumber

    if (-not (Test-DbM20CategoryRetryable $Category)) {
        return @{ Allowed = $false; Reason = "category '$Category' does not justify a same-route retry"; RetryNumber = $retryNumber }
    }
    if (-not $LoopFree) {
        return @{ Allowed = $false; Reason = 'attempt chain is not loop-free; retry would risk a cycle'; RetryNumber = $retryNumber }
    }
    if ($AttemptNumber -gt [int]$policy.MaxAttemptsPerTask) {
        return @{ Allowed = $false; Reason = "attempt budget exhausted (next attempt $AttemptNumber > MaxAttemptsPerTask $($policy.MaxAttemptsPerTask))"; RetryNumber = $retryNumber }
    }

    # count same-model retries already present in the chain
    $sameModelRetries = 0
    foreach ($rec in @($Attempts)) {
        if ($CurrentModelId) {
            if ([string](Get-ContractProperty $rec 'ModelId' '') -eq $CurrentModelId -and [long](Get-ContractProperty $rec 'RetryNumber' 0) -ge 1) { $sameModelRetries++ }
        } else {
            if ([long](Get-ContractProperty $rec 'RetryNumber' 0) -ge 1) { $sameModelRetries++ }
        }
    }
    if ($sameModelRetries -ge [int]$policy.MaxSameModelRetries) {
        return @{ Allowed = $false; Reason = "same-model retry budget exhausted ($sameModelRetries >= MaxSameModelRetries $($policy.MaxSameModelRetries)); do not keep retrying the same model"; RetryNumber = $retryNumber }
    }
    return @{ Allowed = $true; Reason = "same-route retry justified for '$Category' and within all limits"; RetryNumber = $retryNumber }
}

# -----------------------------------------------------------------------------
# Reasoning escalation (one step at a time; never an automatic jump to MAX)
# -----------------------------------------------------------------------------
function Get-AiNextReasoningLevel {
    <#
    .SYNOPSIS
    Determine the next reasoning level for a reasoning escalation: the LOWEST
    supported level strictly above the current level, gated by
    Policy.AllowReasoningIncrease and Policy.MaxReasoningEscalations. The engine
    NEVER jumps straight to MAX -- escalation proceeds one step per attempt.
    Returns @{ NextLevel; Allowed; Reason } (NextLevel null when blocked).
    #>
    param(
        [string]$CurrentLevel,
        [AllowNull()][string[]]$SupportedLevels,
        [int]$ReasoningEscalationsUsed = 0,
        [AllowNull()][pscustomobject]$Policy
    )
    $policy = $Policy
    if ($null -eq $policy) { $policy = Get-DefaultEscalationPolicy }

    if ($policy.AllowReasoningIncrease -ne $true) {
        return @{ NextLevel = $null; Allowed = $false; Reason = 'policy AllowReasoningIncrease is false' }
    }
    if ($ReasoningEscalationsUsed -ge [int]$policy.MaxReasoningEscalations) {
        return @{ NextLevel = $null; Allowed = $false; Reason = "reasoning-escalation budget exhausted ($ReasoningEscalationsUsed >= MaxReasoningEscalations $($policy.MaxReasoningEscalations))" }
    }

    $order = Get-AiRoutingReasoningOrder
    if (-not $CurrentLevel -or -not $order.ContainsKey($CurrentLevel)) {
        return @{ NextLevel = $null; Allowed = $false; Reason = "current reasoning level '$CurrentLevel' unknown" }
    }
    $currentIdx = [int]$order[$CurrentLevel]

    $supported = @()
    if ($SupportedLevels) { $supported = @($SupportedLevels | Where-Object { Test-IsValidReasoningLevel $_ }) }
    if ($supported.Count -eq 0) { return @{ NextLevel = $null; Allowed = $false; Reason = 'no supported reasoning levels supplied' } }

    # strictly higher supported levels, lowest first (one step up)
    $higher = @($supported | Where-Object { [int]$order[$_] -gt $currentIdx } | Sort-Object { [int]$order[$_] })
    if ($higher.Count -eq 0) {
        return @{ NextLevel = $null; Allowed = $false; Reason = "no supported reasoning level above '$CurrentLevel' (model supports: $($supported -join '/'))" }
    }
    $next = $higher[0]
    if ($next -eq 'MAX') {
        # single step into MAX is allowed ONLY when the current level is HIGH
        if ($CurrentLevel -ne 'HIGH') {
            return @{ NextLevel = $null; Allowed = $false; Reason = 'MAX is reached one step at a time; never an automatic jump to MAX' }
        }
    }
    return @{ NextLevel = $next; Allowed = $true; Reason = "reasoning escalation '$CurrentLevel' -> '$next' (one step, within limits)" }
}

# -----------------------------------------------------------------------------
# Loop protection
# -----------------------------------------------------------------------------
function Test-AiEscalationLoop {
    <#
    .SYNOPSIS
    Prove an escalation chain is acyclic and that a proposed next route/reasoning
    combination does not revisit an already-tried combination.
      Without -Proposed*: returns @{ Cyclic = -not $chain.LoopFree; Reason }.
      With -ProposedProvider/-ProposedModel/-ProposedReasoningLevel: returns
      @{ Cyclic; Reason } where Cyclic=true if the exact (provider, model,
      reasoning) combination already exists in the chain (a retry of an
      identical attempt = a loop).
    Returns @{ Cyclic; Reason }.
    #>
    param(
        [AllowNull()][pscustomobject]$Chain,
        [string]$ProposedProvider,
        [string]$ProposedModel,
        [string]$ProposedReasoningLevel,
        [AllowNull()][object[]]$Attempts
    )
    $records = @()
    if ($null -ne $Chain) { $records = @(Get-ContractProperty $Chain 'Attempts' @()) }
    if ($Attempts) { $records = @($Attempts) }

    $haveProposal = ($ProposedProvider -or $ProposedModel -or $ProposedReasoningLevel)
    if (-not $haveProposal) {
        if ($null -ne $Chain) {
            $loopFree = [bool](Get-ContractProperty $Chain 'LoopFree' $true)
            $loopReason = Get-ContractProperty $Chain 'LoopReason' $null
            return @{ Cyclic = (-not $loopFree); Reason = if ($loopFree) { 'chain is acyclic' } else { "chain is cyclic: $loopReason" } }
        }
        return @{ Cyclic = $false; Reason = 'no chain supplied; nothing to prove' }
    }

    if (-not $ProposedProvider -or -not $ProposedModel) {
        return @{ Cyclic = $false; Reason = 'loop check requires both ProposedProvider and ProposedModel' }
    }
    $reasoning = if ($ProposedReasoningLevel) { $ProposedReasoningLevel } else { 'NONE' }
    $proposalKey = ("{0}/{1}/{2}" -f $ProposedProvider.ToLowerInvariant(), $ProposedModel.ToLowerInvariant(), $reasoning.ToUpperInvariant())

    foreach ($rec in $records) {
        $p = [string](Get-ContractProperty $rec 'ProviderId' '')
        $m = [string](Get-ContractProperty $rec 'ModelId' '')
        $r = [string](Get-ContractProperty $rec 'ReasoningLevel' '')
        if (-not $r) { $r = 'NONE' }
        $key = ("{0}/{1}/{2}" -f $p.ToLowerInvariant(), $m.ToLowerInvariant(), $r.ToUpperInvariant())
        if ($key -eq $proposalKey) {
            return @{ Cyclic = $true; Reason = "proposed combination '$proposalKey' was already attempted in this chain (loop prevented)" }
        }
    }
    return @{ Cyclic = $false; Reason = "proposed combination '$proposalKey' is not a revisit" }
}

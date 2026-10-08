# EscalationCandidates.ps1 -- DB-M20 model-escalation candidates.
#
# DB-M20 is a DECISION ENGINE: this layer only RANKS candidate routes for a
# future attempt. Nothing is executed. No paid API calls. No autonomous Nexus
# changes. AUTO_EXECUTION_ENABLED = FALSE.
#
# The hard capability filters are NEVER bypassed: model escalation may only ever
# consider the DB-M19 ELIGIBLE candidates (which already passed STEP 1-3 hard
# gates). A rejected route is never re-admitted merely because it is stronger or
# more expensive. A stronger-but-ineligible model is never selected.
#
# Historical performance (DB-M24) influences ranking only when confidence is
# sufficient; INSUFFICIENT confidence must not produce overconfident
# escalation (conservative behaviour).

. (Join-Path $PSScriptRoot "EscalationPolicy.ps1")
. (Join-Path $PSScriptRoot "..\router\RoutingCandidate.ps1")   # DB-M19 candidate + evidence contracts (READ-ONLY)

# -----------------------------------------------------------------------------
# Defensive eligibility gate (hard filters are never bypassed)
# -----------------------------------------------------------------------------
function Test-DbM20CandidateEligible {
    <#
    .SYNOPSIS
    Guard: a candidate may be escalated to ONLY when it is a DB-M19 ELIGIBLE
    candidate (Status = 'ELIGIBLE', no RejectionReasons). This is the hard
    capability/context/budget filter guarantee. Returns @{ Eligible; Reason }.
    #>
    param([AllowNull()][object]$Candidate)
    if ($null -eq $Candidate) { return @{ Eligible = $false; Reason = 'candidate is null' } }
    if ([string](Get-ContractProperty $Candidate 'Status' '') -ne 'ELIGIBLE') {
        $reasons = @(Get-ContractProperty $Candidate 'RejectionReasons' @())
        $detail = if ($reasons.Count -gt 0) { ($reasons | ForEach-Object { $_.Reason }) -join ', ' } else { 'none' }
        return @{ Eligible = $false; Reason = "candidate '$($Candidate.ProviderId)/$($Candidate.ModelId)' is NOT eligible (rejected: $detail); hard filters are never bypassed" }
    }
    return @{ Eligible = $true; Reason = 'candidate is DB-M19 ELIGIBLE (passed hard filters)' }
}

function Get-DbM20RouteKey([object]$Candidate) {
    $p = [string](Get-ContractProperty $Candidate 'ProviderId' '')
    $m = [string](Get-ContractProperty $Candidate 'ModelId' '')
    return ("{0}/{1}" -f $p.ToLowerInvariant(), $m.ToLowerInvariant())
}

function Get-AiEscalationCandidates {
    <#
    .SYNOPSIS
    Rank the DB-M19 eligible candidates available for a model escalation. The
    current route and every already-attempted route in the chain are excluded.
    Ranking is deterministic and follows the policy TieBreaker chain
    (default: PerformanceConfidence -> SuccessRate -> EstimatedCost -> ModelId):
      - candidates with sufficient historical confidence rank above cold starts,
      - among them, higher verified success rate ranks first,
      - INSUFFICIENT confidence gives history little/no ranking power, so cost
        decides (conservative: no overconfident escalation),
      - known costs before unknown costs, then ModelId as the final tie-break.
    Returns @{ Candidates; Reason }. Never includes a rejected candidate.
    #>
    param(
        [AllowNull()][object[]]$EligibleCandidates,
        [AllowNull()][object[]]$RejectedCandidates,
        [string]$CurrentProviderId,
        [string]$CurrentModelId,
        [AllowNull()][object[]]$Attempts,
        [AllowNull()][pscustomobject]$Policy,
        [bool]$RequireDifferentProvider = $false,
        [Nullable[long]]$MinimumContextWindow
    )
    $policy = $Policy
    if ($null -eq $policy) { $policy = Get-DefaultEscalationPolicy }

    if ($policy.AllowModelSwitch -ne $true) {
        return @{ Candidates = @(); Reason = 'policy AllowModelSwitch is false; model escalation is disabled' }
    }

    # visited routes (already attempted in this task's chain) -- never revisited
    $visited = @{}
    foreach ($rec in @($Attempts)) {
        $p = [string](Get-ContractProperty $rec 'ProviderId' '')
        $m = [string](Get-ContractProperty $rec 'ModelId' '')
        if ($p -and $m) { $visited["$($p.ToLowerInvariant())/$($m.ToLowerInvariant())"] = $true }
    }

    $currentKey = ""
    if ($CurrentProviderId -and $CurrentModelId) { $currentKey = "$($CurrentProviderId.ToLowerInvariant())/$($CurrentModelId.ToLowerInvariant())" }

    $ranked = New-Object System.Collections.Generic.List[object]

    foreach ($cand in @($EligibleCandidates)) {
        # hard-filter guarantee: only DB-M19 ELIGIBLE candidates may be proposed
        $guard = Test-DbM20CandidateEligible $cand
        if (-not $guard.Eligible) { continue }

        $providerId = [string](Get-ContractProperty $cand 'ProviderId' '')
        $modelId = [string](Get-ContractProperty $cand 'ModelId' '')
        if (-not $providerId -or -not $modelId) { continue }

        $routeKey = Get-DbM20RouteKey $cand
        if ($routeKey -eq $currentKey) { continue }                       # current route
        if ($visited.ContainsKey($routeKey)) { continue }                  # already attempted
        if ($RequireDifferentProvider -and $providerId.ToLowerInvariant() -eq $CurrentProviderId.ToLowerInvariant()) { continue }
        if ($null -ne $MinimumContextWindow) {
            $win = Get-ContractProperty $cand 'ContextWindow' $null
            if ($null -eq $win -or [long]$win -lt [long]$MinimumContextWindow) { continue }
        }

        # performance evidence (DB-M24) attached by the DB-M19 router
        $perf = Get-ContractProperty $cand 'PerformanceEvidence' $null
        $confSufficient = $false
        $successRate = $null
        $confidence = 'INSUFFICIENT'
        $sampleCount = 0
        if ($null -ne $perf) {
            $confSufficient = [bool](Get-ContractProperty $perf 'ConfidenceSufficient' $false)
            $successRate = Get-ContractProperty $perf 'SuccessRate' $null
            $confidence = [string](Get-ContractProperty $perf 'ConfidenceLevel' 'INSUFFICIENT')
            $sampleCount = [long](Get-ContractProperty $perf 'SampleCount' 0)
        }

        $estCost = Get-ContractProperty $cand 'EstimatedCost' $null
        $costUnknown = [bool](Get-ContractProperty $cand 'CostUnknown' $false)

        $null = $ranked.Add([pscustomobject]@{
            Candidate               = $cand
            ProviderId              = $providerId
            ModelId                 = $modelId
            ContextWindow           = Get-ContractProperty $cand 'ContextWindow' $null
            SelectedReasoningLevel  = Get-ContractProperty $cand 'SelectedReasoningLevel' $null
            EstimatedCost           = if ($costUnknown) { $null } else { $estCost }
            CostUnknown             = $costUnknown
            ConfidenceSufficient    = $confSufficient
            ConfidenceLevel         = $confidence
            SuccessRate             = $successRate
            SampleCount             = $sampleCount
            PerformanceEvidenceReference = Get-ContractProperty $cand 'PerformanceEvidenceReference' $null
        })
    }

    # deterministic ranking per the policy TieBreaker chain
    $confOrder = @{ INSUFFICIENT = 0; LOW = 1; MODERATE = 2; HIGH = 3 }
    $sorted = @($ranked | Sort-Object `
        @{ Expression = { [int]$confOrder[$_.ConfidenceLevel] } }, `
        @{ Expression = { if ($_.ConfidenceSufficient) { 1 } else { 0 } } }, `
        @{ Expression = { $_.SuccessRate }; Descending = $true }, `
        @{ Expression = { $_.EstimatedCost } }, `
        @{ Expression = { $_.CostUnknown } }, `
        @{ Expression = { $_.ModelId } })

    $reason = if ($sorted.Count -eq 0) {
        'no eligible candidate for model escalation (current route, visited routes, provider or context filters excluded every candidate)'
    } else {
        "model-escalation candidates ranked deterministically ($($sorted.Count) candidates; history-weighted only when confidence is sufficient)"
    }
    return @{ Candidates = $sorted; Reason = $reason }
}

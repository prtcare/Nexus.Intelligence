# RoutingRank.ps1 -- DB-M19 STEP 5 (ranking + recommendation).
#
# The ranking engine reads EVERY weight/threshold from the RoutingPolicy v1
# object -- no policy weight is hard-coded here. Every candidate's PolicyScore is
# the sum of explained component scores (capability fit, cost, verified success,
# first-attempt success, cost-per-success, latency, reliability), each exposed so
# the recommendation is transparent (never an opaque "Score=83.7"). Ranking is
# deterministic: policy-declared tie-breakers decide between equal scores and
# every collection is iterated in sorted order.
#
# ADR-005: identifiers are data; nothing here branches on a provider/model name.

. (Join-Path $PSScriptRoot "..\AiRoutingContracts.ps1")   # DB-M14 vocab + helpers (READ-ONLY)
. (Join-Path $PSScriptRoot "RoutingPolicy.ps1")
. (Join-Path $PSScriptRoot "RoutingCandidate.ps1")
. (Join-Path $PSScriptRoot "RoutingEligibility.ps1")
. (Join-Path $PSScriptRoot "RoutingPerformance.ps1")

function Get-DbM19ReliabilityScore {
    <#
    .SYNOPSIS
    ReliabilityClass -> 0..1 score (data mapping). Unknown class = 0 (conservative:
    an unrated route is never silently treated as reliable).
    #>
    param([string]$ReliabilityClass)
    switch ($ReliabilityClass) {
        'CRITICAL_GRADE' { return 1.0 }
        'HIGH'           { return 0.75 }
        'STANDARD'       { return 0.50 }
        'EXPERIMENTAL'   { return 0.25 }
        default          { return 0.0 }
    }
}

function Get-DbM19SpeedScore {
    <#
    .SYNOPSIS
    RelativeSpeed -> 0..1 score (VERY_FAST=1.0 .. SLOW=0.25; unknown = 0).
    #>
    param([string]$RelativeSpeed)
    switch ($RelativeSpeed) {
        'VERY_FAST' { return 1.0 }
        'FAST'      { return 0.75 }
        'NORMAL'    { return 0.50 }
        'SLOW'      { return 0.25 }
        default     { return 0.0 }
    }
}

function Get-DbM19CandidateComponentScores {
    <#
    .SYNOPSIS
    The explained component scores for one candidate, given set-level references
    (MaxKnownCost, MaxKnownCostPerSuccess). Historical components are zeroed when
    evidence confidence is below the policy minimum (no ranking power).
    #>
    param(
        [AllowNull()][pscustomobject]$Candidate,
        [AllowNull()][object]$MaxKnownCost,
        [AllowNull()][object]$MaxKnownCostPerSuccess
    )
    $costEstimate = Get-ContractProperty $Candidate 'CostEstimate' $null
    $evidence = Get-ContractProperty $Candidate 'PerformanceEvidence' $null

    # cost
    $estCost = Get-ContractProperty $Candidate 'EstimatedCost' $null
    $costUnknown = Get-ContractProperty $Candidate 'CostUnknown' $false
    $costScore = 0.0
    if (-not $costUnknown -and $null -ne $estCost -and $null -ne $MaxKnownCost -and [double]$MaxKnownCost -gt 0) {
        $costScore = 1.0 - ([double]$estCost / [double]$MaxKnownCost)
        if ($costScore -lt 0) { $costScore = 0 }
    }

    # reliability (always available from the model's class)
    $reliabilityScore = Get-DbM19ReliabilityScore ([string](Get-ContractProperty $Candidate 'ReliabilityClass' ''))

    # latency (relative speed; deterministic)
    $latencyScore = Get-DbM19SpeedScore ([string](Get-ContractProperty $Candidate 'RelativeSpeed' ''))

    # historical components: only when the evidence is confident enough
    $confSufficient = $false
    $successRate = $null
    $firstAttemptRate = $null
    $costPerSuccess = $null
    if ($null -ne $evidence) {
        $confSufficient = [bool](Get-ContractProperty $evidence 'ConfidenceSufficient' $false)
        if ($confSufficient) {
            $successRate = Get-ContractProperty $evidence 'SuccessRate' $null
            $firstAttemptRate = Get-ContractProperty $evidence 'FirstAttemptSuccessRate' $null
            $costPerSuccess = Get-ContractProperty $evidence 'AverageCostPerSuccessfulTask' $null
        }
    }
    $successScore = if ($null -ne $successRate) { [double]$successRate } else { 0.0 }
    $firstAttemptScore = if ($null -ne $firstAttemptRate) { [double]$firstAttemptRate } else { 0.0 }
    $costPerSuccessScore = 0.0
    if ($null -ne $costPerSuccess -and $null -ne $MaxKnownCostPerSuccess -and [double]$MaxKnownCostPerSuccess -gt 0) {
        $costPerSuccessScore = 1.0 - ([double]$costPerSuccess / [double]$MaxKnownCostPerSuccess)
        if ($costPerSuccessScore -lt 0) { $costPerSuccessScore = 0 }
    }

    return [pscustomobject]@{
        Cost                   = [double]$costScore
        Success                = [double]$successScore
        FirstAttemptSuccess    = [double]$firstAttemptScore
        CostPerSuccess         = [double]$costPerSuccessScore
        Latency                = [double]$latencyScore
        Reliability            = [double]$reliabilityScore
    }
}

function Get-DbM19PolicyScore {
    <#
    .SYNOPSIS
    Weighted sum of the explained components. Weights come from the policy object
    (missing weight = component excluded). Returns @{ Score; UsedWeights }.
    #>
    param(
        [AllowNull()][pscustomobject]$Policy,
        [AllowNull()][object]$Components
    )
    $weights = Get-ContractProperty $Policy 'Weights' $null
    $score = 0.0
    $used = @{}
    foreach ($wn in Get-RoutingPolicyWeightNames) {
        $w = Get-ContractProperty $weights $wn $null
        if ($null -ne $w -and [double]$w -gt 0) {
            $comp = Get-ContractProperty $Components $wn 0.0
            $score += [double]$w * [double]$comp
            $used[$wn] = [double]$w
        }
    }
    return @{ Score = $score; UsedWeights = $used }
}

function Get-DbM19CandidateSelectable {
    <#
    .SYNOPSIS
    Selectability gate (data-driven): an unknown-cost candidate is selectable only
    if the policy allows cost-unknown; a candidate below the policy's minimum
    reliability is not selectable. Hard constraints were already enforced at
    eligibility.
    #>
    param(
        [AllowNull()][pscustomobject]$Candidate,
        [AllowNull()][pscustomobject]$Policy
    )
    $thresholds = Get-ContractProperty $Policy 'Thresholds' $null
    $allowUnknown = $true
    $minReliability = $null
    if ($null -ne $thresholds) {
        $allowUnknown = [bool](Get-ContractProperty $thresholds 'allowCostUnknown' $true)
        $minReliability = Get-ContractProperty $thresholds 'minimumReliability' $null
    }
    $costUnknown = Get-ContractProperty $Candidate 'CostUnknown' $false
    if ($costUnknown -and -not $allowUnknown) { return $false }
    if ($null -ne $minReliability) {
        $relScore = Get-DbM19ReliabilityScore ([string](Get-ContractProperty $Candidate 'ReliabilityClass' ''))
        if ($relScore -lt [double]$minReliability) { return $false }
    }
    return $true
}

function Rank-AiRoutingCandidates {
    <#
    .SYNOPSIS
    STEP 5. Rank the eligible candidates under a RoutingPolicy. Deterministic:
      - set-level references computed over all eligible candidates (sorted),
      - component scores + PolicyScore per candidate,
      - selectability gate from policy thresholds,
      - sort by PolicyScore DESC then the policy-declared tie-breaker chain
        (PolicyScore / EstimatedCost / ReliabilityClass / ModelId / SampleCount).
    Returns @{ Ranked; Winner; WinnerIndex; SelectableCount; NoWinnerReason }.
    #>
    param(
        [AllowNull()][object[]]$Candidates,
        [AllowNull()][pscustomobject]$Policy
    )
    $policy = $Policy
    if ($null -eq $policy) { $policy = Get-DefaultRoutingPolicy }
    $candidates = @($Candidates)

    $ordered = @($candidates | Sort-Object -Property `
        @{ Expression = { [string](Get-ContractProperty $_ 'ModelId' '') }; Ascending = $true }, `
        @{ Expression = { [string](Get-ContractProperty $_ 'ProviderId' '') }; Ascending = $true }, `
        @{ Expression = { [string](Get-ContractProperty $_ 'GatewayProviderId' '') }; Ascending = $true })

    # set-level references from the reliable subset where present (deterministic)
    $knownCosts = New-Object System.Collections.Generic.List[double]
    $knownCps = New-Object System.Collections.Generic.List[double]
    foreach ($candidate in $ordered) {
        $est = Get-ContractProperty $candidate 'EstimatedCost' $null
        $unknown = Get-ContractProperty $candidate 'CostUnknown' $false
        if (-not $unknown -and $null -ne $est) { $knownCosts.Add([double]$est) }
        $evidence = Get-ContractProperty $candidate 'PerformanceEvidence' $null
        $conf = if ($null -ne $evidence) { [bool](Get-ContractProperty $evidence 'ConfidenceSufficient' $false) } else { $false }
        if ($conf) {
            $cps = Get-ContractProperty $evidence 'AverageCostPerSuccessfulTask' $null
            if ($null -ne $cps) { $knownCps.Add([double]$cps) }
        }
    }
    $maxCost = $null
    if ($knownCosts.Count -gt 0) { $maxCost = ($knownCosts | Measure-Object -Maximum).Maximum }
    $maxCps = $null
    if ($knownCps.Count -gt 0) { $maxCps = ($knownCps | Measure-Object -Maximum).Maximum }

    # score every candidate
    foreach ($candidate in $ordered) {
        $components = Get-DbM19CandidateComponentScores -Candidate $candidate -MaxKnownCost $maxCost -MaxKnownCostPerSuccess $maxCps
        $scoreRes = Get-DbM19PolicyScore -Policy $policy -Components $components
        $candidate.ComponentScores = $components
        $candidate.PolicyScore = [double]$scoreRes.Score
        $candidate.Selectable = Get-DbM19CandidateSelectable -Candidate $candidate -Policy $policy
    }

    # deterministic sort: PolicyScore DESC, then the policy tie-breaker chain
    $sortProps = New-Object System.Collections.Generic.List[object]
    $sortProps.Add(@{ Expression = { if ($null -eq $_.PolicyScore) { [double]::MinValue } else { [double]$_.PolicyScore } }; Ascending = $false })
    $tie = @(Get-ContractProperty $policy 'TieBreaker' @())
    foreach ($key in $tie) {
        switch ($key) {
            'PolicyScore' { }   # already the primary key
            'EstimatedCost' {
                $sortProps.Add(@{ Expression = { $c = Get-ContractProperty $_ 'EstimatedCost' $null; if ($null -eq $c) { [double]::MaxValue } else { [double]$c } }; Ascending = $true })
            }
            'ReliabilityClass' {
                $sortProps.Add(@{ Expression = { $rc = [string](Get-ContractProperty $_ 'ReliabilityClass' ''); $scoreMap = @{ EXPERIMENTAL = 1; STANDARD = 2; HIGH = 3; CRITICAL_GRADE = 4 }; if ($scoreMap.ContainsKey($rc)) { $scoreMap[$rc] } else { 0 } }; Ascending = $false })
            }
            'ModelId' {
                $sortProps.Add(@{ Expression = { [string](Get-ContractProperty $_ 'ModelId' '') }; Ascending = $true })
            }
            'SampleCount' {
                $sortProps.Add(@{ Expression = { $ev = Get-ContractProperty $_ 'PerformanceEvidence' $null; if ($null -eq $ev) { 0 } else { [long](Get-ContractProperty $ev 'SampleCount' 0) } }; Ascending = $false })
            }
        }
    }
    $ranked = @($ordered | Sort-Object -Property $sortProps.ToArray())

    # assign ranks to selectable candidates (1-based); non-selectable rank = null
    $rank = 0
    foreach ($candidate in $ranked) {
        if ($candidate.Selectable -eq $true) {
            $rank += 1
            $candidate.Rank = $rank
        } else {
            $candidate.Rank = $null
        }
    }

    $selectable = @($ranked | Where-Object { $_.Selectable -eq $true })
    $winner = $null
    $winnerIndex = -1
    $noWinnerReason = $null
    if ($selectable.Count -gt 0) {
        $winner = $selectable[0]
        $winnerIndex = $selectable[0].Rank
    } else {
        $noWinnerReason = 'no candidate is selectable under the policy (cost unknown not allowed, or below the policy minimum reliability)'
    }

    return @{
        Ranked          = @($ranked)
        Winner          = $winner
        WinnerIndex     = $winnerIndex
        SelectableCount = $selectable.Count
        NoWinnerReason  = $noWinnerReason
    }
}

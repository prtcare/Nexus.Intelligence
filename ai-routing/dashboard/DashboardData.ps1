# DashboardData.ps1 -- DB-M26 read-only aggregation engine.
#
# Turns a record set (AiAttemptRecord v1), a DashboardRequest v1, an optional
# DB-M21 BudgetPolicy, an optional DB-M22 provider-health snapshot and an
# optional explicit baseline route into a DashboardView v1. Pure: takes
# everything as parameters, returns the view, writes nothing.
#
# Every number comes from the foundations READ-ONLY:
#   - cost resolution / verified-success / chain cost / quality-adjusted cost /
#     savings          -> DB-M25 QualityCost.ps1 (which reuses DB-M16 semantics)
#   - chain facts      -> DB-M24 Resolve-AiChainFacts (SuccessDefinition-aware)
#   - confidence       -> DB-M24 Get-AiConfidenceLevel / result ConfidenceLevel
#   - failure category -> DB-M17 Get-AiAttemptFailureCategories
#   - Claude review    -> DB-M20 ClaudeReviewStatus vocabulary
#   - budget           -> DB-M21 BudgetPolicy v1 (input) + policy vocabulary
#   - provider health  -> DB-M22 effective-health objects (input) + vocabulary
# The dashboard NEVER recomputes an inconsistent alternate metric: it reuses the
# foundation fields (ObservedCostPerVerifiedSuccess, FailedAttemptCost,
# EscalationCost, FirstAttemptVerifiedSuccessCount, SampleCount, ...).
#
# Reporting vs quality cost: summary cards / breakdowns / failed-cost report the
# cost evidence on executed attempts split by ACTUAL vs ESTIMATED source (DB-M16
# semantics via Resolve-DbM25RecordCost). The verified-success cost metrics use
# the query's AllowEstimatedCostFallback gate exactly as DB-M25 does. Both are
# deterministic and labelled.
#
# Read-only: the dashboard does NOT execute AI models, does NOT change routing
# policy, does NOT alter budgets (no override is ever granted), does NOT modify
# provider health, does NOT edit attempt history, and does NOT touch the
# Nexus/workbook state. AUTO_EXECUTION_ENABLED = FALSE. 0 paid calls, 0 network
# calls, no secrets stored.
#
# Frozen-foundation guarantee: DB-M14/16/17/19/20/21/22/23/24/25 files are only
# dot-sourced (read) and SHA-256 verified byte-identical by the test suite.

. (Join-Path $PSScriptRoot "DashboardContracts.ps1")                          # DB-M26 contracts (-> DB-M25 -> DB-M24/17/23/14)
. (Join-Path $PSScriptRoot "..\budget\BudgetPolicy.ps1")                      # DB-M21 (READ-ONLY)
. (Join-Path $PSScriptRoot "..\provider-health\ProviderHealthContracts.ps1")  # DB-M22 vocabulary (READ-ONLY)
. (Join-Path $PSScriptRoot "..\escalation\EscalationContracts.ps1")           # DB-M20 vocabulary (READ-ONLY)

# DB-M24 confidence bands: the DB-M25 engine (QualityCost.ps1) reads
# $script:PerfConfidenceBands to map a sample size to a confidence level. Load the
# configured bands READ-ONLY exactly as the DB-M25 harness does; fall back to the
# DB-M24 defaults if the configuration file is unusable.
$dbm26ConfidenceConfig = Import-AiPerformanceConfiguration
if (-not $dbm26ConfidenceConfig.Valid) { $script:PerfConfidenceBands = @(Get-AiDefaultConfidenceBands) }
Remove-Variable dbm26ConfidenceConfig -ErrorAction SilentlyContinue

# --- record cost resolution (DB-M16 semantics via DB-M25, READ-ONLY) ---------------------

function Get-DbM26RecordCost {
    <#
    .SYNOPSIS
    Resolve ONE attempt record's usable cost evidence. Delegates to
    Resolve-DbM25RecordCost (DB-M16 semantics, READ-ONLY): ActualCost preferred,
    EstimatedCost only when the reporting/quality pass allows the fallback.
    Returns @{ Used; Amount; Source; Executed; ExcludedReason }.
    #>
    param(
        [AllowNull()][object]$Record,
        [string]$Currency = 'INR',
        [bool]$AllowEstimatedFallback = $false
    )
    $c = Resolve-DbM25RecordCost -Record $Record -ReportingCurrencyUpper $Currency.ToUpperInvariant() -AllowEstimatedFallback $AllowEstimatedFallback
    return @{
        Used           = [bool]$c.Used
        Amount         = [double]$c.Amount
        Source         = [string]$c.Source
        Executed       = [bool]$c.Executed
        ExcludedReason = [string]$c.ExcludedReason
    }
}

# --- breakdown helpers ---------------------------------------------------------------------

function Add-DbM26Bucket {
    param([hashtable]$Map, [string]$Key, [double]$Amount, [int]$Count)
    if (-not $Map.ContainsKey($Key)) { $Map[$Key] = @{ Cost = 0d; Count = 0 } }
    $Map[$Key].Cost += $Amount
    $Map[$Key].Count += $Count
}

function Get-DbM26BreakdownArray {
    <#
    .SYNOPSIS
    Convert a bucket hashtable { Key -> @{Cost;Count} } into a sorted array of
    { Key, Cost, Count }, highest cost first.
    #>
    param([hashtable]$Map)
    $arr = New-Object System.Collections.ArrayList
    foreach ($k in $Map.Keys) {
        $null = $arr.Add([pscustomobject]@{
            Key   = [string]$k
            Cost  = [math]::Round([double]$Map[$k].Cost, 4)
            Count = [int]$Map[$k].Count
        })
    }
    return @($arr | Sort-Object -Property @{ Expression = { $_.Cost }; Descending = $true },
                                         @{ Expression = { $_.Key } })
}

# --- cost breakdown -------------------------------------------------------------------------

function Get-DbM26CostBreakdown {
    <#
    .SYNOPSIS
    Bucket the cost evidence of the filtered records by the eleven brief
    dimensions. Uses the REPORTING cost pass (fallback on) so actual + estimated
    pending are both visible. Route keys mirror DB-M25 Resolve-DbM25GroupKey
    ("provider|model|gateway", '(unknown)' / '(none)' defaults).
    #>
    param([AllowNull()][object[]]$Records, [string]$Currency = 'INR')
    $buckets = @{
        Provider = @{}; Route = @{}; Model = @{}; UnderlyingModel = @{}
        TaskType = @{}; ReasoningLevel = @{}; Success = @{}; FailureCategory = @{}
        RetryEscalation = @{}; LocalOrRemote = @{}; DirectVsGateway = @{}
    }
    foreach ($r in @($Records)) {
        $c = Get-DbM26RecordCost -Record $r -Currency $Currency -AllowEstimatedFallback $true
        $amount = $(if ($c.Used) { $c.Amount } else { 0d })

        $provider = [string](Get-ContractProperty $r 'ProviderId' '(unknown)')
        $model = [string](Get-ContractProperty $r 'ModelId' '(unknown)')
        $under = [string](Get-ContractProperty $r 'UnderlyingModelId' '(unknown)')
        $gateway = [string](Get-ContractProperty $r 'GatewayProviderId' '(none)')
        $route = ("{0}|{1}|{2}" -f $provider, $model, $gateway)
        $tt = [string](Get-ContractProperty $r 'TaskType' '(unknown)')
        $rl = [string](Get-ContractProperty $r 'ReasoningLevel' '(unknown)')
        $result = [string](Get-ContractProperty $r 'Result' '')
        if ($result -eq 'SUCCESS') { $sBucket = 'SUCCESS' }
        elseif ($result -in @('FAILED', 'CANCELLED', 'BLOCKED', 'BUDGET_STOPPED')) { $sBucket = 'FAILED' }
        elseif ($result -in @('ESCALATED', 'WAITING_HUMAN')) { $sBucket = 'OTHER' }
        else { $sBucket = 'INCOMPLETE' }
        $fc = [string](Get-ContractProperty $r 'FailureCategory' '')
        if (-not $fc) { $fc = '(none)' }
        $retry = [int](Get-ContractProperty $r 'RetryNumber' 0)
        $ef = [string](Get-ContractProperty $r 'EscalatedFromAttemptId' '')
        $et = [string](Get-ContractProperty $r 'EscalatedToAttemptId' '')
        $re = if ($retry -gt 0 -or $ef -or $et) { 'RETRY/ESCALATION' } else { 'FIRST_ATTEMPT' }
        $lor = [string](Get-ContractProperty $r 'LocalOrRemote' 'UNKNOWN')
        $dg = if ($gateway -and $gateway -ne '(none)') { 'GATEWAY' } else { 'DIRECT' }

        Add-DbM26Bucket $buckets.Provider $provider $amount 1
        Add-DbM26Bucket $buckets.Route $route $amount 1
        Add-DbM26Bucket $buckets.Model $model $amount 1
        Add-DbM26Bucket $buckets.UnderlyingModel $under $amount 1
        Add-DbM26Bucket $buckets.TaskType $tt $amount 1
        Add-DbM26Bucket $buckets.ReasoningLevel $rl $amount 1
        Add-DbM26Bucket $buckets.Success $sBucket $amount 1
        Add-DbM26Bucket $buckets.FailureCategory $fc $amount 1
        Add-DbM26Bucket $buckets.RetryEscalation $re $amount 1
        Add-DbM26Bucket $buckets.LocalOrRemote $lor $amount 1
        Add-DbM26Bucket $buckets.DirectVsGateway $dg $amount 1
    }
    return @{
        Provider = Get-DbM26BreakdownArray $buckets.Provider
        Route = Get-DbM26BreakdownArray $buckets.Route
        Model = Get-DbM26BreakdownArray $buckets.Model
        UnderlyingModel = Get-DbM26BreakdownArray $buckets.UnderlyingModel
        TaskType = Get-DbM26BreakdownArray $buckets.TaskType
        ReasoningLevel = Get-DbM26BreakdownArray $buckets.ReasoningLevel
        Success = Get-DbM26BreakdownArray $buckets.Success
        FailureCategory = Get-DbM26BreakdownArray $buckets.FailureCategory
        RetryEscalation = Get-DbM26BreakdownArray $buckets.RetryEscalation
        LocalOrRemote = Get-DbM26BreakdownArray $buckets.LocalOrRemote
        DirectVsGateway = Get-DbM26BreakdownArray $buckets.DirectVsGateway
    }
}

# --- failed-cost view ------------------------------------------------------------------------

function Get-DbM26FailedCostView {
    <#
    .SYNOPSIS
    Separate the cost of FAILED/CANCELLED attempts by failure class: model-quality,
    provider (availability), rate-limit, authentication, tool, build/test,
    context, budget-prevented, validation, verification-contradicted, Claude
    FIX/review, other. Never lumps every failure into "model failed". Only
    executed attempts with cost evidence contribute.
    #>
    param([AllowNull()][object[]]$Records, [string]$Currency = 'INR')
    $fc = @{
        ModelQuality = 0d; ProviderFailures = 0d; RateLimit = 0d; Authentication = 0d
        ToolFailure = 0d; BuildTest = 0d; ContextFailure = 0d; BudgetFailure = 0d
        ValidationFailure = 0d; Verification = 0d; ClaudeFixReview = 0d; Other = 0d
    }
    foreach ($r in @($Records)) {
        $result = [string](Get-ContractProperty $r 'Result' '')
        if ($result -notin @('FAILED', 'CANCELLED')) { continue }
        $c = Get-DbM26RecordCost -Record $r -Currency $Currency -AllowEstimatedFallback $true
        if (-not $c.Used) { continue }
        $cat = [string](Get-ContractProperty $r 'FailureCategory' '')
        $cs = [string](Get-ContractProperty $r 'ClaudeReviewStatus' '')
        $vr = [string](Get-ContractProperty $r 'VerificationResult' '')
        $key = 'Other'
        if ($cs -eq 'FIX_REQUIRED') { $key = 'ClaudeFixReview' }
        elseif ($cat -eq 'MODEL_QUALITY') { $key = 'ModelQuality' }
        elseif ($cat -eq 'PROVIDER_AVAILABILITY') { $key = 'ProviderFailures' }
        elseif ($cat -eq 'RATE_LIMIT') { $key = 'RateLimit' }
        elseif ($cat -eq 'AUTHENTICATION') { $key = 'Authentication' }
        elseif ($cat -eq 'TOOL_FAILURE') { $key = 'ToolFailure' }
        elseif ($cat -in @('BUILD_FAILURE', 'TEST_FAILURE')) { $key = 'BuildTest' }
        elseif ($cat -eq 'CONTEXT_FAILURE') { $key = 'ContextFailure' }
        elseif ($cat -eq 'BUDGET_FAILURE') { $key = 'BudgetFailure' }
        elseif ($cat -eq 'VALIDATION_FAILURE') { $key = 'ValidationFailure' }
        elseif (($cat -eq 'UNKNOWN' -or -not $cat) -and $vr -eq 'FAILED') { $key = 'Verification' }
        $fc[$key] += $c.Amount
    }
    $out = @{}
    foreach ($k in $fc.Keys) { $out[$k] = [math]::Round([double]$fc[$k], 4) }
    return $out
}

# --- attempt history ---------------------------------------------------------------------------

function Get-DbM26AttemptHistory {
    <#
    .SYNOPSIS
    Chronological, searchable attempt history. Failed attempts remain visible
    after a later success (they are plain rows, never hidden). Cost = REPORTING
    cost (actual preferred; estimated labelled as such by source column).
    #>
    param([AllowNull()][object[]]$Records, [string]$Currency = 'INR')
    $sorted = @($Records | Sort-Object -Property @{ Expression = { ConvertTo-AiPerfUtc (Get-ContractProperty $_ 'StartedAtUtc' $null) } },
                                                      @{ Expression = { [string](Get-ContractProperty $_ 'AttemptId' '') } })
    $rows = New-Object System.Collections.ArrayList
    foreach ($r in $sorted) {
        $c = Get-DbM26RecordCost -Record $r -Currency $Currency -AllowEstimatedFallback $true
        $cost = if ($c.Used) { [math]::Round($c.Amount, 4) } else { $null }
        $ef = [string](Get-ContractProperty $r 'EscalatedFromAttemptId' '')
        $et = [string](Get-ContractProperty $r 'EscalatedToAttemptId' '')
        $er = [string](Get-ContractProperty $r 'EscalationReason' '')
        $esc = ''
        if ($ef -or $et) { $esc = "from $ef to $et" }
        if ($er) { $esc = $(if ($esc) { "$esc · $er" } else { $er }) }
        if (-not $esc) { $esc = 'none' }
        $ts = [string](Get-ContractProperty $r 'StartedAtUtc' '')
        if (-not $ts) { $ts = [string](Get-ContractProperty $r 'EndedAtUtc' '') }
        $null = $rows.Add([pscustomobject]@{
            Task = [string](Get-ContractProperty $r 'TaskId' '')
            Change = [string](Get-ContractProperty $r 'ChangeId' '')
            AttemptId = [string](Get-ContractProperty $r 'AttemptId' '')
            Provider = [string](Get-ContractProperty $r 'ProviderId' '')
            Model = [string](Get-ContractProperty $r 'ModelId' '')
            Reasoning = [string](Get-ContractProperty $r 'ReasoningLevel' '')
            Result = [string](Get-ContractProperty $r 'Result' '')
            Verification = [string](Get-ContractProperty $r 'VerificationResult' '')
            Cost = $cost
            FailureCategory = [string](Get-ContractProperty $r 'FailureCategory' '')
            Escalation = $esc
            TimestampUtc = $ts
        })
    }
    return @($rows)
}

# --- verified-success view ---------------------------------------------------------------------

function Get-DbM26VerifiedSuccessView {
    <#
    .SYNOPSIS
    One row per task chain distinguishing Attempt completed / Implementation
    verified / Claude accepted / Human Git pending. Verified success semantics are
    DB-M25 Resolve-DbM25VerifiedSuccess (authoritative); a model self-PASS with
    VerificationResult FAILED is Contradicted, never success. Human Git pending is
    a label applied to verified-success chains with no accepted-review evidence
    (ClaudeReviewStatus != PASS); it never claims a stronger success than the
    evidence allows.
    #>
    param(
        [AllowNull()][object[]]$Chains,
        [AllowNull()][object[]]$Facts,
        [string]$SuccessDefinition = 'VERIFIED'
    )
    $rows = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Chains.Count; $i++) {
        $ch = $Chains[$i]
        $f = $Facts[$i]
        $recs = @($ch.Records)
        $firstRec = $recs | Select-Object -First 1
        $taskId = [string](Get-ContractProperty $firstRec 'TaskId' '')
        $changeId = [string](Get-ContractProperty $ch 'Key' '')
        $term = Get-ContractProperty $f 'TerminalAttempt' $null
        $attemptCompleted = $false; $implVerified = $false; $claudeAccepted = $false
        $humanGitPending = $false; $outcome = 'NOT_SUCCESS'
        if ($null -ne $term) {
            $attemptCompleted = (-not [string]::IsNullOrWhiteSpace([string](Get-ContractProperty $term 'Result' '')))
            $implVerified = ([string](Get-ContractProperty $term 'VerificationResult' '') -eq 'VERIFIED')
            $cs = [string](Get-ContractProperty $term 'ClaudeReviewStatus' '')
            $claudeAccepted = ($cs -eq 'PASS')
            $vr = Resolve-DbM25VerifiedSuccess -Attempt $term -SuccessDefinition $SuccessDefinition
            $outcome = [string](Get-ContractProperty $vr 'Reason' 'NOT_SUCCESS')
            $humanGitPending = ([bool](Get-ContractProperty $vr 'Success' $false)) -and ($cs -ne 'PASS')
        }
        $null = $rows.Add([pscustomobject]@{
            TaskId = $taskId
            ChangeId = $changeId
            AttemptCompleted = $attemptCompleted
            ImplementationVerified = $implVerified
            ClaudeAccepted = $claudeAccepted
            HumanGitPending = $humanGitPending
            Outcome = $outcome
        })
    }
    return @($rows)
}

# --- chain drilldown --------------------------------------------------------------------------

function Get-DbM26ChainView {
    <#
    .SYNOPSIS
    One row per task chain with per-attempt cumulative cost and the terminal
    outcome. Chain cost uses the DB-M25 Get-DbM25ChainCost semantics under the
    query's estimated-cost gate (fail + fail + pass = the full chain cost).
    #>
    param(
        [AllowNull()][object[]]$Chains,
        [AllowNull()][object[]]$Facts,
        [string]$Currency = 'INR',
        [bool]$AllowEstimatedFallback = $false
    )
    $rows = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Chains.Count; $i++) {
        $ch = $Chains[$i]
        $f = $Facts[$i]
        $recs = @($ch.Records)
        $total = 0d
        if ($recs.Count -gt 0) {
            $cc = Get-DbM25ChainCost -Records $recs -ReportingCurrencyUpper $Currency.ToUpperInvariant() -AllowEstimatedFallback $AllowEstimatedFallback
            $total = [math]::Round([double]$cc.Total, 4)
        }
        $firstRec = $recs | Select-Object -First 1
        $taskId = [string](Get-ContractProperty $firstRec 'TaskId' '')
        $changeId = [string](Get-ContractProperty $ch 'Key' '')
        $outcome = [string](Get-ContractProperty $f 'Outcome' 'INCOMPLETE')
        $attemptRows = New-Object System.Collections.ArrayList
        $running = 0d
        $seq = 0
        foreach ($a in $recs) {
            $seq++
            $ac = Get-DbM26RecordCost -Record $a -Currency $Currency -AllowEstimatedFallback $AllowEstimatedFallback
            if ($ac.Used) { $running += $ac.Amount }
            $ef = [string](Get-ContractProperty $a 'EscalatedFromAttemptId' '')
            $et = [string](Get-ContractProperty $a 'EscalatedToAttemptId' '')
            $er = [string](Get-ContractProperty $a 'EscalationReason' '')
            $esc = ''
            if ($ef -or $et) { $esc = "from $ef to $et" }
            if ($er) { $esc = $(if ($esc) { "$esc · $er" } else { $er }) }
            $null = $attemptRows.Add([pscustomobject]@{
                Seq = $seq
                AttemptId = [string](Get-ContractProperty $a 'AttemptId' '')
                Provider = [string](Get-ContractProperty $a 'ProviderId' '')
                Model = [string](Get-ContractProperty $a 'ModelId' '')
                Result = [string](Get-ContractProperty $a 'Result' '')
                Cost = $(if ($ac.Used) { [math]::Round($ac.Amount, 4) } else { $null })
                CumulativeCost = [math]::Round($running, 4)
                Escalation = $esc
            })
        }
        $null = $rows.Add([pscustomobject]@{
            TaskId = $taskId
            ChangeId = $changeId
            TotalCost = $total
            TerminalOutcome = $outcome
            AttemptCount = $recs.Count
            Attempts = @($attemptRows)
        })
    }
    return @($rows)
}

# --- quality-adjusted cost view -----------------------------------------------------------------

function Get-DbM26QualityCostView {
    <#
    .SYNOPSIS
    Ranked DB-M25 group results. Rank is presentation-only (sorted by observed
    cost per verified success, nulls last). LooksCheapButRetries flags a route
    whose attempts are cheap relative to another group but which needs retries to
    verify (brief question 4).
    #>
    param([AllowNull()][object[]]$Groups)
    $rows = New-Object System.Collections.ArrayList
    $maxAtt = 0d
    foreach ($g in $Groups) {
        $a = [double](Get-ContractProperty $g 'AverageAttemptCost' 0)
        if ($a -gt $maxAtt) { $maxAtt = $a }
    }
    $ordered = @($Groups | Sort-Object -Property @{ Expression = {
                    $o = [double](Get-ContractProperty $_ 'ObservedCostPerVerifiedSuccess' $null)
                    if ($null -eq $o) { [double]::MaxValue } else { $o }
                } },
                @{ Expression = { [int](Get-ContractProperty $_ 'SampleCount' 0) }; Descending = $true })
    $rank = 0
    foreach ($g in $ordered) {
        $rank++
        $avgAtt = [double](Get-ContractProperty $g 'AverageAttemptCost' 0)
        $aps = [double](Get-ContractProperty $g 'AverageAttemptsPerVerifiedSuccess' 0)
        $looksCheap = ($aps -gt 1.05) -and ($maxAtt -gt 0) -and ($avgAtt -lt $maxAtt)
        $null = $rows.Add([pscustomobject]@{
            Rank = $rank
            GroupKey = [string](Get-ContractProperty $g 'GroupKey' '')
            AverageAttemptCost = Get-ContractProperty $g 'AverageAttemptCost' $null
            ObservedCostPerVerifiedSuccess = Get-ContractProperty $g 'ObservedCostPerVerifiedSuccess' $null
            ExpectedCostPerVerifiedSuccess = Get-ContractProperty $g 'ExpectedCostPerVerifiedSuccess' $null
            ExpectedCostBasis = [string](Get-ContractProperty $g 'ExpectedCostBasis' '')
            AverageAttemptsPerVerifiedSuccess = $aps
            VerifiedSuccessRate = Get-ContractProperty $g 'VerifiedSuccessRate' $null
            SampleCount = [int](Get-ContractProperty $g 'SampleCount' 0)
            ConfidenceLevel = [string](Get-ContractProperty $g 'ConfidenceLevel' 'INSUFFICIENT')
            LooksCheapButRetries = $looksCheap
        })
    }
    return @($rows)
}

# --- savings view -------------------------------------------------------------------------------

function Get-DbM26SavingsView {
    <#
    .SYNOPSIS
    DB-M25 explicit-baseline savings: one SavingsAnalysis v1 per candidate group
    vs the baseline result. The baseline type/basis/label are explicit; savings are
    only ever computed by DB-M25 on equivalent verified outcomes. Returns @() when
    no baseline result was supplied.
    #>
    param(
        [AllowNull()][object[]]$Groups,
        [AllowNull()][object]$BaselineResult,
        [string]$BaselineType = 'CURRENT_DEFAULT',
        [string]$BaselineLabel = '',
        [string]$BaselineBasis = 'OBSERVED',
        [string]$Scope = ''
    )
    $rows = New-Object System.Collections.ArrayList
    if ($null -eq $BaselineResult) { return @() }
    $baseRoute = [string](Get-ContractProperty $BaselineResult 'GroupKey' '')
    foreach ($g in @($Groups)) {
        if ([string](Get-ContractProperty $g 'GroupKey' '') -ieq $baseRoute) { continue }
        $sa = Get-DbM25SavingsAnalysis -CandidateResult $g -BaselineResult $BaselineResult `
            -BaselineType $BaselineType -BaselineLabel $BaselineLabel -BaselineBasis $BaselineBasis -Scope $Scope
        if ($null -ne $sa) { $null = $rows.Add($sa) }
    }
    return @($rows)
}

# --- budget view -------------------------------------------------------------------------------

function Get-DbM26BudgetView {
    <#
    .SYNOPSIS
    Budget view from a DB-M21 BudgetPolicy v1 (input) + the dashboard's spend
    figures (DB-M16 semantics, identical to the summary cards -- never a divergent
    metric). ProjectedSpend = actual + estimated pending when the policy counts
    pending. Status derives from the policy's own WarnAtPercent/BlockAtPercent
    against the strictest applicable scope for the window. The dashboard NEVER
    grants overrides; override evidence is displayed only.
    #>
    param(
        [AllowNull()][object]$Policy,
        [double]$ActualSpend,
        [double]$EstimatedPending,
        [string]$PresetWindow,
        [string]$OverrideEvidence
    )
    $view = @{
        TaskBudget = $null; SessionBudget = $null; DailyBudget = $null; MonthlyBudget = $null
        ActualSpend = [math]::Round($ActualSpend, 4)
        EstimatedPending = [math]::Round($EstimatedPending, 4)
        ProjectedSpend = [math]::Round($ActualSpend, 4)
        WarningThresholdPercent = $null
        BlockThresholdPercent = $null
        BudgetUsedPercent = $null
        Status = 'NO_APPLICABLE_BUDGET'
        OverrideEvidence = $OverrideEvidence
        Note = ''
    }
    if ($null -eq $Policy) { return $view }
    $view.TaskBudget = Get-ContractProperty $Policy 'TaskLimit' $null
    $view.SessionBudget = Get-ContractProperty $Policy 'SessionLimit' $null
    $view.DailyBudget = Get-ContractProperty $Policy 'DailyLimit' $null
    $view.MonthlyBudget = Get-ContractProperty $Policy 'MonthlyLimit' $null
    $warn = [double](Get-ContractProperty $Policy 'WarnAtPercent' 80)
    $block = [double](Get-ContractProperty $Policy 'BlockAtPercent' 100)
    $includePending = [bool](Get-ContractProperty $Policy 'IncludeEstimatedPendingCost' $true)
    $view.WarningThresholdPercent = $warn
    $view.BlockThresholdPercent = $block
    $projected = $ActualSpend + $(if ($includePending) { $EstimatedPending } else { 0d })
    $view.ProjectedSpend = [math]::Round($projected, 4)

    $monthlyL = Get-ContractProperty $Policy 'MonthlyLimit' $null
    $dailyL = Get-ContractProperty $Policy 'DailyLimit' $null
    $scopes = New-Object System.Collections.ArrayList
    if ($PresetWindow -eq 'TODAY' -and $null -ne $dailyL) { $null = $scopes.Add(@{ Name = 'DAILY'; Limit = [double]$dailyL }) }
    if ($PresetWindow -in @('TODAY', 'THIS_MONTH') -and $null -ne $monthlyL) { $null = $scopes.Add(@{ Name = 'MONTHLY'; Limit = [double]$monthlyL }) }
    if ($scopes.Count -eq 0 -and $null -ne $monthlyL) {
        $null = $scopes.Add(@{ Name = 'MONTHLY'; Limit = [double]$monthlyL })
        $view.Note = 'window not aligned to a budget period; monthly comparison shown'
    }
    $usedMax = $null
    foreach ($s in $scopes) {
        if ([double]$s.Limit -gt 0) {
            $u = $projected / [double]$s.Limit * 100.0
            if ($null -eq $usedMax -or $u -gt $usedMax) { $usedMax = $u }
        }
    }
    if ($null -ne $usedMax) {
        $view.BudgetUsedPercent = [math]::Round($usedMax, 4)
        if ($usedMax -ge $block) { $view.Status = 'BLOCKED' }
        elseif ($usedMax -ge $warn) { $view.Status = 'WARNING' }
        else { $view.Status = 'ALLOW' }
    }
    return $view
}

# --- provider-health view -----------------------------------------------------------------------

function Get-DbM26ProviderHealthView {
    <#
    .SYNOPSIS
    Provider-health rows from the passed DB-M22 effective-health snapshot (input).
    The dashboard never polls providers. HealthyProviders = distinct providers
    with an AVAILABLE + CLOSED route; UnavailableOrRateLimitedRoutes = routes with
    an unhealthy health state or an OPEN/HALF_OPEN circuit.
    #>
    param([AllowNull()][object[]]$State)
    $rows = New-Object System.Collections.ArrayList
    $healthyProviders = @{}
    $unavailable = 0
    $unhealthy = @('RATE_LIMITED', 'DEGRADED', 'AUTH_ERROR', 'UNAVAILABLE', 'DISABLED')
    foreach ($h in @($State)) {
        $provider = [string](Get-ContractProperty $h 'ProviderId' '')
        $route = [string](Get-ContractProperty $h 'RouteId' '')
        if (-not $route) {
            $gw = [string](Get-ContractProperty $h 'GatewayProviderId' '')
            $route = if ($gw) { "$provider|$gw" } else { $provider }
        }
        $health = [string](Get-ContractProperty $h 'HealthState' 'UNKNOWN')
        $circuit = [string](Get-ContractProperty $h 'CircuitState' 'CLOSED')
        $retry = Get-ContractProperty $h 'RetryAfterUtc' $null
        $last = Get-ContractProperty $h 'ObservedAtUtc' $null
        if ($null -eq $last) { $last = Get-ContractProperty $h 'EvaluationTimestampUtc' $null }
        $fresh = [int](Get-ContractProperty $h 'FreshEvidenceCount' 0)
        $stale = [int](Get-ContractProperty $h 'StaleEvidenceCount' 0)
        $policyId = [string](Get-ContractProperty $h 'PolicyId' '')
        $confSrc = "$fresh fresh / $stale stale"
        if ($policyId) { $confSrc += " · $policyId" }
        if ($health -eq 'AVAILABLE' -and $circuit -eq 'CLOSED') { $healthyProviders[$provider] = $true }
        if ($health -in $unhealthy -or $circuit -in @('OPEN', 'HALF_OPEN')) { $unavailable++ }
        $null = $rows.Add([pscustomobject]@{
            Provider = $provider
            Route = $route
            Health = $health
            CircuitState = $circuit
            RetryAfter = $(if ($null -ne $retry) { ([datetime]$retry).ToString('o') } else { '' })
            LastEvidenceTime = $(if ($null -ne $last) { ([datetime]$last).ToString('o') } else { '' })
            ConfidenceSource = $confSrc
        })
    }
    return @{ Rows = @($rows); HealthyProviders = $healthyProviders.Count; UnavailableOrRateLimitedRoutes = $unavailable }
}

# --- model performance view ----------------------------------------------------------------------

function Get-DbM26ModelPerformanceView {
    <#
    .SYNOPSIS
    Per-route performance from the DB-M25 group results (single source, no
    divergent metric): verified success rate, first-attempt rate, attempts per
    success, cost per success, escalation share, confidence, sample. Task type /
    reasoning scoping is provided by the dashboard filters.
    #>
    param([AllowNull()][object[]]$Groups)
    $rows = New-Object System.Collections.ArrayList
    foreach ($g in @($Groups)) {
        $cps = Get-ContractProperty $g 'ObservedCostPerVerifiedSuccess' $null
        if ($null -eq $cps) { $cps = Get-ContractProperty $g 'ExpectedCostPerVerifiedSuccess' $null }
        $null = $rows.Add([pscustomobject]@{
            Route = [string](Get-ContractProperty $g 'GroupKey' '')
            VerifiedSuccessRate = Get-ContractProperty $g 'VerifiedSuccessRate' $null
            FirstAttemptSuccessRate = Get-ContractProperty $g 'FirstAttemptVerifiedSuccessRate' $null
            AttemptsPerSuccess = Get-ContractProperty $g 'AverageAttemptsPerVerifiedSuccess' $null
            CostPerSuccess = $cps
            EscalationCostShare = Get-ContractProperty $g 'EscalationCostShare' $null
            Confidence = [string](Get-ContractProperty $g 'ConfidenceLevel' 'INSUFFICIENT')
            Sample = [int](Get-ContractProperty $g 'SampleCount' 0)
        })
    }
    return @($rows)
}

# --- local / openrouter view ----------------------------------------------------------------------

function Get-DbM26LocalOpenRouterView {
    <#
    .SYNOPSIS
    Route-identity rows: the same underlying model direct vs through a gateway stay
    SEPARATE (DB-M25 GroupKey preserves the route). LocalCostStatus comes from the
    DB-M25 result (LOCAL is never invented as FREE; LOCAL_COST_UNKNOWN unless price
    evidence is known and labelled).
    #>
    param([AllowNull()][object[]]$Groups)
    $rows = New-Object System.Collections.ArrayList
    foreach ($g in @($Groups)) {
        $null = $rows.Add([pscustomobject]@{
            UnderlyingModel = [string](Get-ContractProperty $g 'UnderlyingModelId' '(unknown)')
            LocalOrRemote = [string](Get-ContractProperty $g 'LocalOrRemote' 'UNKNOWN')
            Provider = [string](Get-ContractProperty $g 'ProviderId' '(unknown)')
            Gateway = [string](Get-ContractProperty $g 'GatewayProviderId' '(none)')
            LocalCostStatus = [string](Get-ContractProperty $g 'LocalCostStatus' '')
            TotalCost = [double](Get-ContractProperty $g 'TotalAttemptCost' 0)
            AttemptCount = [int](Get-ContractProperty $g 'AttemptCount' 0)
        })
    }
    return @($rows)
}

# --- confidence summary ---------------------------------------------------------------------------

function Get-DbM26ConfidenceSummary {
    <#
    .SYNOPSIS
    Every recommendation-like analytic exposes its confidence level + sample size
    (DB-M24 bands). Low-sample figures are never overstated.
    #>
    param(
        [AllowNull()][object[]]$QualityView,
        [AllowNull()][object[]]$SavingsView,
        [AllowNull()][object[]]$PerformanceView
    )
    $rows = New-Object System.Collections.ArrayList
    foreach ($q in @($QualityView)) {
        $null = $rows.Add([pscustomobject]@{
            Analytic = ("Quality-adjusted cost: " + [string](Get-ContractProperty $q 'GroupKey' ''))
            ConfidenceLevel = [string](Get-ContractProperty $q 'ConfidenceLevel' 'INSUFFICIENT')
            SampleSize = [int](Get-ContractProperty $q 'SampleCount' 0)
        })
    }
    foreach ($s in @($SavingsView)) {
        $null = $rows.Add([pscustomobject]@{
            Analytic = ("Savings: " + [string](Get-ContractProperty $s 'CandidateRoute' '') + " vs " + [string](Get-ContractProperty $s 'BaselineRoute' ''))
            ConfidenceLevel = [string](Get-ContractProperty $s 'Confidence' 'INSUFFICIENT')
            SampleSize = [int](Get-ContractProperty $s 'SampleSize' 0)
        })
    }
    foreach ($p in @($PerformanceView)) {
        $null = $rows.Add([pscustomobject]@{
            Analytic = ("Model performance: " + [string](Get-ContractProperty $p 'Route' ''))
            ConfidenceLevel = [string](Get-ContractProperty $p 'Confidence' 'INSUFFICIENT')
            SampleSize = [int](Get-ContractProperty $p 'Sample' 0)
        })
    }
    return @($rows)
}

# --- primary group helper -------------------------------------------------------------------------

function Get-DbM26PrimaryGroup {
    <#
    .SYNOPSIS
    The group used for single-value headline cards: the request's DefaultGroupKey
    when it matches a group, else the group with the largest sample (representative).
    #>
    param([AllowNull()][object[]]$Groups, [string]$DefaultGroupKey)
    $groups = @($Groups)
    if ($groups.Count -eq 0) { return $null }
    if ($DefaultGroupKey) {
        foreach ($g in $groups) {
            if ([string](Get-ContractProperty $g 'GroupKey' '') -ieq $DefaultGroupKey) { return $g }
        }
    }
    $best = $null; $bestN = -1
    foreach ($g in $groups) {
        $n = [int](Get-ContractProperty $g 'SampleCount' 0)
        if ($n -gt $bestN) { $best = $g; $bestN = $n }
    }
    return $best
}

# --- main engine --------------------------------------------------------------------------------

function Get-DbM26DashboardView {
    <#
    .SYNOPSIS
    Build the DashboardView v1 for the passed request. Pure: takes records,
    request, budget policy, provider-health snapshot and an optional explicit
    baseline route; writes nothing. Throws when the request is invalid.
    #>
    param(
        [AllowNull()][object[]]$Records,
        [AllowNull()][object]$Request,
        [string]$NowUtc,
        [AllowNull()][object]$BudgetPolicy,
        [AllowNull()][object[]]$ProviderHealthState,
        [string]$BudgetOverrideEvidence,
        [string]$BaselineProviderId,
        [string]$BaselineModelId,
        [string]$BaselineGatewayProviderId,
        [string]$BaselineType = 'CURRENT_DEFAULT',
        [string]$BaselineLabel = '',
        [string]$BaselineBasis = 'OBSERVED'
    )
    $records = @($Records)
    $now = ConvertTo-AiPerfUtc $NowUtc
    if ($null -eq $now) { $now = [datetime]::UtcNow }

    if ($null -eq $Request) {
        $Request = New-DbM26DashboardRequest -RequestId 'dbm26-auto' -PresetWindow 'ALL_TIME' -NowUtc $now.ToString('o')
    }
    $rv = Test-DbM26DashboardRequest $Request
    if (-not $rv.Valid) { throw ("Invalid DashboardRequest: " + ($rv.Errors -join '; ')) }

    $preset = [string](Get-ContractProperty $Request 'PresetWindow' 'ALL_TIME')
    $currency = [string](Get-ContractProperty $Request 'ReportingCurrency' 'INR')
    $sd = [string](Get-ContractProperty $Request 'SuccessDefinition' 'VERIFIED')
    $allowEst = [bool](Get-ContractProperty $Request 'AllowEstimatedCostFallback' $false)
    $defaultKey = [string](Get-ContractProperty $Request 'DefaultGroupKey' '')
    $reqFrom = ConvertTo-AiPerfUtc (Get-ContractProperty $Request 'FromUtc' $null)
    $reqTo = ConvertTo-AiPerfUtc (Get-ContractProperty $Request 'ToUtc' $null)
    $reqNow = ConvertTo-AiPerfUtc (Get-ContractProperty $Request 'NowUtc' $null)
    if ($null -eq $reqNow) { $reqNow = $now }

    $m25Preset = if ($reqFrom -or $reqTo) { 'CUSTOM' } else { 'ALL_TIME' }

    # DB-M25 query mirroring the dashboard request (READ-ONLY).
    $query = New-DbM25QualityCostQuery `
        -QueryId 'DBM26' `
        -PresetWindow $m25Preset -FromUtc $(if ($reqFrom) { $reqFrom.ToString('o') } else { $null }) `
        -ToUtc $(if ($reqTo) { $reqTo.ToString('o') } else { $null }) -NowUtc $reqNow.ToString('o') `
        -ProviderId (Get-ContractProperty $Request 'ProviderId' $null) `
        -ModelId (Get-ContractProperty $Request 'ModelId' $null) `
        -UnderlyingModelId (Get-ContractProperty $Request 'UnderlyingModelId' $null) `
        -GatewayProviderId (Get-ContractProperty $Request 'GatewayProviderId' $null) `
        -TaskType (Get-ContractProperty $Request 'TaskType' $null) `
        -ReasoningLevel (Get-ContractProperty $Request 'ReasoningLevel' $null) `
        -LocalOrRemote (Get-ContractProperty $Request 'LocalOrRemote' $null) `
        -ReportingCurrency $currency -AllowEstimatedCostFallback $allowEst `
        -SuccessDefinition $sd -GroupBy 'ModelRoute'

    $filtered = @(Resolve-DbM25FilteredAttempts -Records $records -Query $query)
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($filtered.Count -eq 0) { $warnings.Add('No attempts match the request in the selected window.') }

    # --- spend split (reporting pass; DB-M16 semantics via DB-M25) --------------------------
    $actualSpend = 0d
    $estSpend = 0d
    foreach ($r in $filtered) {
        $c = Get-DbM26RecordCost -Record $r -Currency $currency -AllowEstimatedFallback $true
        if (-not $c.Used) { continue }
        if ($c.Source -eq 'ACTUAL') { $actualSpend += $c.Amount } else { $estSpend += $c.Amount }
    }
    if ($estSpend -gt 0) { $warnings.Add('Estimated-pending cost is shown on the spend cards and is excluded from verified-success cost unless estimated-cost fallback is enabled.') }

    # --- DB-M25 group results + DB-M24 chains -------------------------------------------------
    $groups = @(Get-DbM25QualityAdjustedCost -Records $records -Query $query)
    $chains = @(Resolve-AiTaskChains -Records $filtered)
    $factsList = New-Object System.Collections.ArrayList
    foreach ($ch in $chains) { $null = $factsList.Add((Resolve-AiChainFacts -Chain $ch -SuccessDefinition $sd)) }

    # --- views --------------------------------------------------------------------------------
    $qualityView = @(Get-DbM26QualityCostView -Groups $groups)
    $performanceView = @(Get-DbM26ModelPerformanceView -Groups $groups)
    $localView = @(Get-DbM26LocalOpenRouterView -Groups $groups)
    $history = @(Get-DbM26AttemptHistory -Records $filtered -Currency $currency)
    $chainView = @(Get-DbM26ChainView -Chains $chains -Facts @($factsList) -Currency $currency -AllowEstimatedFallback $allowEst)
    $verifiedView = @(Get-DbM26VerifiedSuccessView -Chains $chains -Facts @($factsList) -SuccessDefinition $sd)
    $breakdown = Get-DbM26CostBreakdown -Records $filtered -Currency $currency
    $failedView = Get-DbM26FailedCostView -Records $filtered -Currency $currency

    # --- savings (explicit baseline, optional) -------------------------------------------------
    $savingsView = @()
    if ($BaselineProviderId -or $BaselineModelId -or $BaselineGatewayProviderId) {
        $baseQuery = New-DbM25QualityCostQuery `
            -QueryId 'DBM26-BASELINE' `
            -PresetWindow $m25Preset -FromUtc $(if ($reqFrom) { $reqFrom.ToString('o') } else { $null }) `
            -ToUtc $(if ($reqTo) { $reqTo.ToString('o') } else { $null }) -NowUtc $reqNow.ToString('o') `
            -ProviderId $BaselineProviderId -ModelId $BaselineModelId -GatewayProviderId $BaselineGatewayProviderId `
            -ReportingCurrency $currency -AllowEstimatedCostFallback $allowEst `
            -SuccessDefinition $sd -GroupBy 'ModelRoute'
        $baseGroups = @(Get-DbM25QualityAdjustedCost -Records $records -Query $baseQuery)
        $baselineResult = Get-DbM26PrimaryGroup -Groups $baseGroups -DefaultGroupKey ''
        if ($null -eq $baselineResult) {
            $warnings.Add('Baseline route supplied but no baseline group matched in the window; savings view is empty.')
        } else {
            $savingsView = @(Get-DbM26SavingsView -Groups $groups -BaselineResult $baselineResult `
                -BaselineType $BaselineType -BaselineLabel $BaselineLabel -BaselineBasis $BaselineBasis -Scope $preset)
        }
    }

    $budgetView = Get-DbM26BudgetView -Policy $BudgetPolicy -ActualSpend $actualSpend -EstimatedPending $estSpend `
        -PresetWindow $preset -OverrideEvidence $BudgetOverrideEvidence
    $healthView = Get-DbM26ProviderHealthView -State $ProviderHealthState

    $confidenceSummary = @(Get-DbM26ConfidenceSummary -QualityView $qualityView -SavingsView $savingsView -PerformanceView $performanceView)

    # --- summary cards -------------------------------------------------------------------------
    $primaryGroup = Get-DbM26PrimaryGroup -Groups $groups -DefaultGroupKey $defaultKey
    $costPerVerified = $null
    if ($null -ne $primaryGroup) {
        $costPerVerified = Get-ContractProperty $primaryGroup 'ObservedCostPerVerifiedSuccess' $null
        if ($null -eq $costPerVerified) { $costPerVerified = Get-ContractProperty $primaryGroup 'ExpectedCostPerVerifiedSuccess' $null }
    }
    $verifiedTasks = 0; $firstCount = 0; $sampleTotal = 0; $failedCost = 0d; $escCost = 0d
    foreach ($g in $groups) {
        $verifiedTasks += [int](Get-ContractProperty $g 'VerifiedSuccessCount' 0)
        $firstCount += [int](Get-ContractProperty $g 'FirstAttemptVerifiedSuccessCount' 0)
        $sampleTotal += [int](Get-ContractProperty $g 'SampleCount' 0)
        $failedCost += [double](Get-ContractProperty $g 'FailedAttemptCost' 0)
        $escCost += [double](Get-ContractProperty $g 'EscalationCost' 0)
    }
    $firstRate = if ($sampleTotal -gt 0) { [math]::Round([double]$firstCount / $sampleTotal, 4) } else { $null }
    $corrCost = 0d
    for ($i = 0; $i -lt $chains.Count; $i++) {
        $f = $factsList[$i]
        $isCorr = ([int](Get-ContractProperty $f 'AttemptCount' 0) -gt 1) -or [bool](Get-ContractProperty $f 'HumanIntervention' $false)
        if ($isCorr) {
            $cc = Get-DbM25ChainCost -Records @($chains[$i].Records) -ReportingCurrencyUpper $currency.ToUpperInvariant() -AllowEstimatedFallback $allowEst
            $corrCost += [double]$cc.Total
        }
    }
    $sav = $null
    foreach ($s in $savingsView) {
        $abs = Get-ContractProperty $s 'AbsoluteSavings' $null
        if ($null -eq $abs) { continue }
        if ($defaultKey -and ([string](Get-ContractProperty $s 'CandidateRoute' '') -ieq $defaultKey)) { $sav = [double]$abs; break }
        if ($null -eq $sav) { $sav = [double]$abs }
    }

    $summaryCards = [pscustomobject]@{
        TotalAiSpend = [math]::Round($actualSpend + $estSpend, 4)
        ActualSpend = [math]::Round($actualSpend, 4)
        EstimatedPendingSpend = [math]::Round($estSpend, 4)
        VerifiedSuccessfulTasks = $verifiedTasks
        CostPerVerifiedSuccess = $costPerVerified
        FirstAttemptSuccessRate = $firstRate
        FailedAttemptCost = [math]::Round($failedCost, 4)
        EscalationCost = [math]::Round($escCost, 4)
        CorrectionCost = [math]::Round($corrCost, 4)
        QualityAdjustedSavings = $sav
        BudgetUsedPercent = $budgetView.BudgetUsedPercent
        HealthyProviders = $healthView.HealthyProviders
        UnavailableOrRateLimitedRoutes = $healthView.UnavailableOrRateLimitedRoutes
    }

    # --- assemble the view ---------------------------------------------------------------------
    return (New-DbM26DashboardView -Fields @{
        RequestId = [string](Get-ContractProperty $Request 'RequestId' $null)
        PresetWindow = $preset
        FromUtc = $(if ($reqFrom) { $reqFrom.ToString('o') } else { $null })
        ToUtc = $(if ($reqTo) { $reqTo.ToString('o') } else { $null })
        NowUtc = $reqNow.ToString('o')
        Currency = $currency
        SuccessDefinition = $sd
        GeneratedAtUtc = $reqNow.ToString('o')
        SummaryCards = $summaryCards
        CostBreakdown = $breakdown
        VerifiedSuccessView = $verifiedView
        QualityAdjustedCostView = $qualityView
        SavingsView = $savingsView
        FailedCostView = $failedView
        BudgetView = $budgetView
        ProviderHealthView = $healthView.Rows
        ModelPerformanceView = $performanceView
        AttemptHistory = $history
        ChainView = $chainView
        LocalOpenRouterView = $localView
        ConfidenceSummary = $confidenceSummary
        ReadOnlyGuard = (New-DbM26ReadOnlyGuard -Warnings @($warnings))
        WindowStartUtc = $(if ($reqFrom) { $reqFrom.ToString('o') } else { $null })
        WindowEndUtc = $(if ($reqTo) { $reqTo.ToString('o') } else { $null })
        Warnings = @($warnings)
    })
}

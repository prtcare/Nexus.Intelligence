# DashboardRender.ps1 -- DB-M26 self-contained HTML dashboard renderer.
#
# Turns a DashboardView v1 (DashboardContracts.ps1) into ONE self-contained HTML
# file: inline CSS, minimal inline JS (tab switching + chain expand + a
# searchable/filterable attempt-history table), horizontal CSS bars for simple
# cost charts. No external libraries, no network, no fonts, no writes by the
# library itself -- ConvertTo-DbM26Html returns the string; an explicit
# Export-DbM26DashboardHtml call writes the operator-requested artifact.
#
# Read-only: the rendered HTML has NO buttons/controls that write to any store,
# no model execution, no policy/budget/health mutation. Every text value is
# HTML-escaped; the dashboard never renders raw provider/model data unescaped.
#
# AUTO_EXECUTION_ENABLED = FALSE. No provider/model/paid/network calls.

function ConvertTo-DbM26HtmlEscaped {
    <#
    .SYNOPSIS
    HTML-escape a value before it is placed in rendered output. Never trusts
    provider/model/free-text values from the view.
    #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-DbM26Value {
    <#
    .SYNOPSIS
    Deterministic display formatting: money (2 decimals), rate (percent 1
    decimal), pct (percent 1 decimal), int (integer), text (as-is).
    #>
    param([AllowNull()][object]$Value, [string]$Kind = 'text', [string]$Currency = 'INR')
    if ($null -eq $Value) { return '<span class="muted">--</span>' }
    switch ($Kind) {
        'money' { return ('{0} {1:N2}' -f $Currency, [double]$Value) }
        'rate'  { return ('{0:P1}' -f [double]$Value) }
        'pct'   { return ('{0:P1}' -f ([double]$Value / 100.0)) }
        'int'   { return ('{0}' -f [int64]$Value) }
        default { return (ConvertTo-DbM26HtmlEscaped $Value) }
    }
}

function ConvertTo-DbM26Html {
    <#
    .SYNOPSIS
    Render a DashboardView v1 to a self-contained HTML string.
    Returns the HTML. Does not write anything.
    #>
    param(
        [AllowNull()][object]$View,
        [string]$Title = 'DevBridge AI Usage / Cost Dashboard'
    )
    $sb = New-Object System.Text.StringBuilder
    $escTitle = ConvertTo-DbM26HtmlEscaped ([string]$Title)

    # window label
    $windowLabel = 'ALL TIME'
    if ($null -ne $View) {
        $p = [string](Get-ContractProperty $View 'PresetWindow' 'ALL_TIME')
        $from = Get-ContractProperty $View 'FromUtc' $null
        $to = Get-ContractProperty $View 'ToUtc' $null
        switch ($p) {
            'TODAY'        { $windowLabel = 'Today' }
            'LAST_7_DAYS'  { $windowLabel = 'Last 7 days' }
            'LAST_30_DAYS' { $windowLabel = 'Last 30 days' }
            'THIS_MONTH'   { $windowLabel = 'This month' }
            'CUSTOM'       { $windowLabel = 'Custom range' }
            default        { $windowLabel = 'All time' }
        }
        if ($from -or $to) {
            $fmt = 'yyyy-MM-dd'
            $windowLabel += ' (' + $(if ($from) { ([datetime]$from).ToString($fmt) } else { 'start' }) +
                           ' .. ' + $(if ($to) { ([datetime]$to).ToString($fmt) } else { 'now' }) + ')'
        }
    }

    $null = $sb.Append('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    $null = $sb.Append("<title>${escTitle}</title>")
    $null = $sb.Append('<style>')
    $null = $sb.Append($(Get-DbM26StyleCss))
    $null = $sb.Append('</style></head><body>')
    $null = $sb.Append('<div class="wrap">')

    # header
    $null = $sb.Append('<header class="top"><h1>')
    $null = $sb.Append($escTitle)
    $null = $sb.Append('</h1>')
    if ($null -ne $View) {
        $null = $sb.Append('<div class="meta">Window: <strong>' + (ConvertTo-DbM26HtmlEscaped $windowLabel) + '</strong>')
        $null = $sb.Append(' &middot; Currency: <strong>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $View 'Currency' 'INR')) + '</strong>')
        $null = $sb.Append(' &middot; Success: <strong>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $View 'SuccessDefinition' 'VERIFIED')) + '</strong>')
        $null = $sb.Append(' &middot; <span class="badge ro">READ-ONLY ANALYTICS</span>')
        $null = $sb.Append('</div>')
    }
    $null = $sb.Append('</header>')

    if ($null -eq $View) {
        $null = $sb.Append('<div class="empty">No dashboard data. (DashboardView is null.)</div>')
        $null = $sb.Append('</div><script>' + $(Get-DbM26Js) + '</script></body></html>')
        return $sb.ToString()
    }

    # summary cards
    $null = $sb.Append($(ConvertTo-DbM26SummaryCardsHtml -View $View))

    # tabs
    $null = $sb.Append('<nav class="tabs">')
    foreach ($tab in (Get-DbM26TabDefs)) {
        $null = $sb.Append('<button class="tab' + $(if ($tab.Key -eq 'breakdown') { ' active' } else { '' }) + '" data-tab="' + $tab.Key + '">' + (ConvertTo-DbM26HtmlEscaped $tab.Label) + '</button>')
    }
    $null = $sb.Append('</nav>')

    foreach ($tab in (Get-DbM26TabDefs)) {
        $null = $sb.Append('<section id="tab-' + $tab.Key + '" class="panel' + $(if ($tab.Key -eq 'breakdown') { ' active' } else { '' }) + '">')
        $null = $sb.Append($(ConvertTo-DbM26SectionHtml -View $View -Section $tab.Section))
        $null = $sb.Append('</section>')
    }

    # confidence + read-only footer
    $null = $sb.Append($(ConvertTo-DbM26ConfidenceHtml -View $View))
    $null = $sb.Append($(ConvertTo-DbM26FooterHtml -View $View))

    $null = $sb.Append('</div>')
    $null = $sb.Append('<script>' + $(Get-DbM26Js) + '</script>')
    $null = $sb.Append('</body></html>')
    return $sb.ToString()
}

# --- tab layout ---------------------------------------------------------------------------

function Get-DbM26TabDefs {
    return @(
        @{ Key = 'breakdown';    Label = 'Cost breakdown';     Section = 'costbreakdown' },
        @{ Key = 'quality';      Label = 'Quality-adjusted cost'; Section = 'quality' },
        @{ Key = 'savings';      Label = 'Savings';            Section = 'savings' },
        @{ Key = 'failed';       Label = 'Failed cost';        Section = 'failed' },
        @{ Key = 'budget';       Label = 'Budget';             Section = 'budget' },
        @{ Key = 'health';       Label = 'Provider health';    Section = 'health' },
        @{ Key = 'performance';  Label = 'Model performance';  Section = 'performance' },
        @{ Key = 'verified';     Label = 'Verified success';   Section = 'verified' },
        @{ Key = 'history';      Label = 'Attempt history';    Section = 'history' },
        @{ Key = 'chains';       Label = 'Chains';             Section = 'chains' },
        @{ Key = 'local';        Label = 'Local / OpenRouter'; Section = 'local' }
    )
}

# --- summary cards --------------------------------------------------------------------------

function ConvertTo-DbM26SummaryCardsHtml {
    param([AllowNull()][object]$View)
    $cards = Get-ContractProperty $View 'SummaryCards' $null
    $currency = [string](Get-ContractProperty $View 'Currency' 'INR')
    $defs = @(
        @{ Field = 'TotalAiSpend';                   Label = 'Total AI Spend';                 Kind = 'money' },
        @{ Field = 'ActualSpend';                    Label = 'Actual Spend';                  Kind = 'money' },
        @{ Field = 'EstimatedPendingSpend';          Label = 'Estimated Pending Spend';        Kind = 'money' },
        @{ Field = 'VerifiedSuccessfulTasks';        Label = 'Verified Successful Tasks';      Kind = 'int' },
        @{ Field = 'CostPerVerifiedSuccess';         Label = 'Cost Per Verified Success';      Kind = 'money' },
        @{ Field = 'FirstAttemptSuccessRate';        Label = 'First-Attempt Success Rate';     Kind = 'rate' },
        @{ Field = 'FailedAttemptCost';              Label = 'Failed Attempt Cost';            Kind = 'money' },
        @{ Field = 'EscalationCost';                 Label = 'Escalation Cost';                Kind = 'money' },
        @{ Field = 'CorrectionCost';                 Label = 'Correction Cost';                Kind = 'money' },
        @{ Field = 'QualityAdjustedSavings';         Label = 'Quality-Adjusted Savings';       Kind = 'money' },
        @{ Field = 'BudgetUsedPercent';              Label = 'Budget Used %';                  Kind = 'pct' },
        @{ Field = 'HealthyProviders';               Label = 'Healthy Providers';              Kind = 'int' },
        @{ Field = 'UnavailableOrRateLimitedRoutes'; Label = 'Unavailable / Rate-Limited Routes'; Kind = 'int' }
    )
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<div class="cards">')
    if ($null -eq $cards) {
        $null = $sb.Append('<div class="card empty">No summary data.</div>')
    } else {
        foreach ($d in $defs) {
            $v = Get-ContractProperty $cards $d.Field $null
            $null = $sb.Append('<div class="card"><div class="card-label">' + (ConvertTo-DbM26HtmlEscaped $d.Label) + '</div>')
            $null = $sb.Append('<div class="card-value">' + (Format-DbM26Value -Value $v -Kind $d.Kind -Currency $currency) + '</div></div>')
        }
    }
    $null = $sb.Append('</div>')
    return $sb.ToString()
}

# --- section dispatch -----------------------------------------------------------------------

function ConvertTo-DbM26SectionHtml {
    param([AllowNull()][object]$View, [string]$Section)
    switch ($Section) {
        'costbreakdown' { return ConvertTo-DbM26CostBreakdownHtml -View $View }
        'quality'       { return ConvertTo-DbM26QualityCostHtml -View $View }
        'savings'       { return ConvertTo-DbM26SavingsHtml -View $View }
        'failed'        { return ConvertTo-DbM26FailedCostHtml -View $View }
        'budget'        { return ConvertTo-DbM26BudgetHtml -View $View }
        'health'        { return ConvertTo-DbM26HealthHtml -View $View }
        'performance'   { return ConvertTo-DbM26PerformanceHtml -View $View }
        'verified'      { return ConvertTo-DbM26VerifiedHtml -View $View }
        'history'       { return ConvertTo-DbM26HistoryHtml -View $View }
        'chains'        { return ConvertTo-DbM26ChainsHtml -View $View }
        'local'         { return ConvertTo-DbM26LocalHtml -View $View }
        default         { return '<div class="empty">Unknown section.</div>' }
    }
}

# --- cost breakdown --------------------------------------------------------------------------

function ConvertTo-DbM26CostBreakdownHtml {
    param([AllowNull()][object]$View)
    $bd = Get-ContractProperty $View 'CostBreakdown' $null
    $currency = [string](Get-ContractProperty $View 'Currency' 'INR')
    if ($null -eq $bd) { return '<div class="empty">No cost breakdown.</div>' }
    $dims = @(
        @{ Field = 'Provider';        Label = 'By provider' },
        @{ Field = 'Route';           Label = 'By route (provider|model|gateway)' },
        @{ Field = 'Model';           Label = 'By model' },
        @{ Field = 'UnderlyingModel'; Label = 'By underlying model' },
        @{ Field = 'TaskType';        Label = 'By task type' },
        @{ Field = 'ReasoningLevel';  Label = 'By reasoning level' },
        @{ Field = 'Success';         Label = 'By success / failure' },
        @{ Field = 'FailureCategory'; Label = 'By failure category' },
        @{ Field = 'RetryEscalation'; Label = 'By retry / escalation' },
        @{ Field = 'LocalOrRemote';   Label = 'By local / remote' },
        @{ Field = 'DirectVsGateway'; Label = 'By direct / gateway' }
    )
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<div class="bdexp">')
    foreach ($d in $dims) {
        $rows = @(Get-ContractProperty $bd $d.Field @())
        $null = $sb.Append('<div class="bd"><h3>' + (ConvertTo-DbM26HtmlEscaped $d.Label) + '</h3>')
        if ($rows.Count -eq 0) {
            $null = $sb.Append('<div class="muted">No data.</div>')
        } else {
            $max = 0d
            foreach ($r in $rows) { $c = [double](Get-ContractProperty $r 'Cost' 0); if ($c -gt $max) { $max = $c } }
            foreach ($r in $rows) {
                $c = [double](Get-ContractProperty $r 'Cost' 0)
                $n = [int](Get-ContractProperty $r 'Count' 0)
                $pctW = if ($max -gt 0) { [math]::Round($c / $max * 100, 1) } else { 0 }
                $null = $sb.Append('<div class="bdrow"><div class="bdkey">' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Key' '')) + '</div>')
                $null = $sb.Append('<div class="bdbar"><div class="bdfill" style="width:' + $pctW + '%"></div></div>')
                $null = $sb.Append('<div class="bdval">' + (Format-DbM26Value -Value $c -Kind 'money' -Currency $currency) + ' <span class="muted">(' + $n + ')</span></div></div>')
            }
        }
        $null = $sb.Append('</div>')
    }
    $null = $sb.Append('</div>')
    return $sb.ToString()
}

# --- quality-adjusted cost -------------------------------------------------------------------

function ConvertTo-DbM26QualityCostHtml {
    param([AllowNull()][object]$View)
    $rows = @(Get-ContractProperty $View 'QualityAdjustedCostView' @())
    $currency = [string](Get-ContractProperty $View 'Currency' 'INR')
    if ($rows.Count -eq 0) { return '<div class="empty">No quality-adjusted cost rows (no verified chains in window).</div>' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<table><thead><tr><th>Rank</th><th>Route</th><th>Attempt price</th><th>Cost per verified success</th><th>Expected</th><th>Attempts/success</th><th>Verified success rate</th><th>Sample</th><th>Confidence</th><th>Flag</th></tr></thead><tbody>')
    foreach ($r in $rows) {
        $flag = ''
        if ([bool](Get-ContractProperty $r 'LooksCheapButRetries' $false)) { $flag = '<span class="badge warn">cheap attempts, retries</span>' }
        $null = $sb.Append('<tr><td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Rank' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'GroupKey' '')) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'AverageAttemptCost' $null) -Kind 'money' -Currency $currency) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'ObservedCostPerVerifiedSuccess' $null) -Kind 'money' -Currency $currency) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'ExpectedCostPerVerifiedSuccess' $null) -Kind 'money' -Currency $currency) + ' <span class="muted">' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'ExpectedCostBasis' '')) + '</span></td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'AverageAttemptsPerVerifiedSuccess' $null) -Kind 'text') + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'VerifiedSuccessRate' $null) -Kind 'rate') + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'SampleCount' $null) -Kind 'int') + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26ConfidenceBadge (Get-ContractProperty $r 'ConfidenceLevel' 'INSUFFICIENT')) + '</td>')
        $null = $sb.Append('<td>' + $flag + '</td></tr>')
    }
    $null = $sb.Append('</tbody></table>')
    return $sb.ToString()
}

# --- savings ---------------------------------------------------------------------------------

function ConvertTo-DbM26SavingsHtml {
    param([AllowNull()][object]$View)
    $rows = @(Get-ContractProperty $View 'SavingsView' @())
    $currency = [string](Get-ContractProperty $View 'Currency' 'INR')
    if ($rows.Count -eq 0) { return '<div class="empty">No savings rows (no comparable verified chains in window).</div>' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<table><thead><tr><th>Candidate route</th><th>Baseline route</th><th>Baseline type</th><th>Basis</th><th>Baseline cost</th><th>Candidate cost</th><th>Absolute savings</th><th>Savings %</th><th>Confidence</th><th>Sample</th></tr></thead><tbody>')
    foreach ($r in $rows) {
        $null = $sb.Append('<tr><td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'CandidateRoute' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'BaselineRoute' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'BaselineType' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'BaselineBasis' '')) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'BaselineCostPerVerifiedSuccess' $null) -Kind 'money' -Currency $currency) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'ObservedCostPerVerifiedSuccess' $null) -Kind 'money' -Currency $currency) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'AbsoluteSavings' $null) -Kind 'money' -Currency $currency) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'SavingsPercent' $null) -Kind 'rate') + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26ConfidenceBadge (Get-ContractProperty $r 'Confidence' 'INSUFFICIENT')) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'SampleSize' $null) -Kind 'int') + '</td></tr>')
        $w = @(Get-ContractProperty $r 'Warnings' @())
        if ($w.Count -gt 0) {
            $null = $sb.Append('<tr class="warnrow"><td colspan="10"><span class="muted">' + (ConvertTo-DbM26HtmlEscaped ($w -join '; ')) + '</span></td></tr>')
        }
    }
    $null = $sb.Append('</tbody></table>')
    return $sb.ToString()
}

# --- failed cost -----------------------------------------------------------------------------

function ConvertTo-DbM26FailedCostHtml {
    param([AllowNull()][object]$View)
    $fc = Get-ContractProperty $View 'FailedCostView' $null
    $currency = [string](Get-ContractProperty $View 'Currency' 'INR')
    if ($null -eq $fc) { return '<div class="empty">No failed-cost view.</div>' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<div class="bdexp">')
    $buckets = @('ModelQuality', 'ProviderFailures', 'RateLimit', 'Authentication', 'ToolFailure',
                 'BuildTest', 'ContextFailure', 'BudgetFailure', 'ValidationFailure',
                 'Verification', 'ClaudeFixReview', 'Other')
    $labels = @{ ModelQuality = 'Model-quality failures'; ProviderFailures = 'Provider failures (availability)';
                 RateLimit = 'Rate limits'; Authentication = 'Authentication'; ToolFailure = 'Tool failures';
                 BuildTest = 'Build / test failures'; ContextFailure = 'Context failures';
                 BudgetFailure = 'Budget-prevented attempts'; ValidationFailure = 'Validation failures';
                 Verification = 'Verification failures'; ClaudeFixReview = 'Claude FIX / review failures';
                 Other = 'Other / unknown' }
    $max = 0d
    foreach ($b in $buckets) { $c = [double](Get-ContractProperty $fc $b 0); if ($c -gt $max) { $max = $c } }
    foreach ($b in $buckets) {
        $c = [double](Get-ContractProperty $fc $b 0)
        $pctW = if ($max -gt 0) { [math]::Round($c / $max * 100, 1) } else { 0 }
        $null = $sb.Append('<div class="bdrow"><div class="bdkey">' + (ConvertTo-DbM26HtmlEscaped $labels[$b]) + '</div>')
        $null = $sb.Append('<div class="bdbar"><div class="bdfill fail" style="width:' + $pctW + '%"></div></div>')
        $null = $sb.Append('<div class="bdval">' + (Format-DbM26Value -Value $c -Kind 'money' -Currency $currency) + '</div></div>')
    }
    $null = $sb.Append('</div>')
    return $sb.ToString()
}

# --- budget -----------------------------------------------------------------------------------

function ConvertTo-DbM26BudgetHtml {
    param([AllowNull()][object]$View)
    $b = Get-ContractProperty $View 'BudgetView' $null
    $currency = [string](Get-ContractProperty $View 'Currency' 'INR')
    if ($null -eq $b) { return '<div class="empty">No budget state supplied.</div>' }
    $status = [string](Get-ContractProperty $b 'Status' 'UNKNOWN')
    $statusBadge = '<span class="badge">' + (ConvertTo-DbM26HtmlEscaped $status) + '</span>'
    if ($status -eq 'WARNING') { $statusBadge = '<span class="badge warn">WARNING</span>' }
    if ($status -eq 'BLOCKED') { $statusBadge = '<span class="badge danger">BLOCKED</span>' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<table><tbody>')
    $rows = @(
        @{ L = 'Status'; V = $statusBadge },
        @{ L = 'Task budget'; V = (Format-DbM26Value -Value (Get-ContractProperty $b 'TaskBudget' $null) -Kind 'money' -Currency $currency) },
        @{ L = 'Session budget'; V = (Format-DbM26Value -Value (Get-ContractProperty $b 'SessionBudget' $null) -Kind 'money' -Currency $currency) },
        @{ L = 'Daily budget'; V = (Format-DbM26Value -Value (Get-ContractProperty $b 'DailyBudget' $null) -Kind 'money' -Currency $currency) },
        @{ L = 'Monthly budget'; V = (Format-DbM26Value -Value (Get-ContractProperty $b 'MonthlyBudget' $null) -Kind 'money' -Currency $currency) },
        @{ L = 'Current actual spend'; V = (Format-DbM26Value -Value (Get-ContractProperty $b 'ActualSpend' $null) -Kind 'money' -Currency $currency) },
        @{ L = 'Estimated pending spend'; V = (Format-DbM26Value -Value (Get-ContractProperty $b 'EstimatedPending' $null) -Kind 'money' -Currency $currency) },
        @{ L = 'Projected spend'; V = (Format-DbM26Value -Value (Get-ContractProperty $b 'ProjectedSpend' $null) -Kind 'money' -Currency $currency) },
        @{ L = 'Warning threshold'; V = (Format-DbM26Value -Value (Get-ContractProperty $b 'WarningThresholdPercent' $null) -Kind 'pct') },
        @{ L = 'Block threshold'; V = (Format-DbM26Value -Value (Get-ContractProperty $b 'BlockThresholdPercent' $null) -Kind 'pct') },
        @{ L = 'Budget used %'; V = (Format-DbM26Value -Value (Get-ContractProperty $b 'BudgetUsedPercent' $null) -Kind 'pct') }
    )
    foreach ($r in $rows) {
        $null = $sb.Append('<tr><th>' + (ConvertTo-DbM26HtmlEscaped $r.L) + '</th><td>' + $r.V + '</td></tr>')
    }
    $oe = Get-ContractProperty $b 'OverrideEvidence' $null
    if ($oe) {
        $null = $sb.Append('<tr><th>Human override evidence</th><td>' + (ConvertTo-DbM26HtmlEscaped ([string]$oe)) + '</td></tr>')
    }
    $null = $sb.Append('</tbody></table>')
    $null = $sb.Append('<div class="muted">The dashboard never grants budget overrides.</div>')
    return $sb.ToString()
}

# --- provider health ---------------------------------------------------------------------------

function ConvertTo-DbM26HealthHtml {
    param([AllowNull()][object]$View)
    $rows = @(Get-ContractProperty $View 'ProviderHealthView' @())
    if ($rows.Count -eq 0) { return '<div class="empty">No provider-health evidence supplied. The dashboard does not poll providers.</div>' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<table><thead><tr><th>Provider</th><th>Route</th><th>Health</th><th>Circuit state</th><th>Retry-after</th><th>Last evidence</th><th>Confidence / source</th></tr></thead><tbody>')
    foreach ($r in $rows) {
        $null = $sb.Append('<tr><td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Provider' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Route' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Health' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'CircuitState' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'RetryAfter' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'LastEvidenceTime' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'ConfidenceSource' '')) + '</td></tr>')
    }
    $null = $sb.Append('</tbody></table>')
    return $sb.ToString()
}

# --- model performance -------------------------------------------------------------------------

function ConvertTo-DbM26PerformanceHtml {
    param([AllowNull()][object]$View)
    $rows = @(Get-ContractProperty $View 'ModelPerformanceView' @())
    $currency = [string](Get-ContractProperty $View 'Currency' 'INR')
    if ($rows.Count -eq 0) { return '<div class="empty">No model performance rows (no attempts in window).</div>' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<table><thead><tr><th>Route</th><th>Verified success rate</th><th>First-attempt rate</th><th>Attempts/success</th><th>Cost/success</th><th>Escalation share</th><th>Confidence</th><th>Sample</th></tr></thead><tbody>')
    foreach ($r in $rows) {
        $null = $sb.Append('<tr><td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Route' '')) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'VerifiedSuccessRate' $null) -Kind 'rate') + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'FirstAttemptSuccessRate' $null) -Kind 'rate') + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'AttemptsPerSuccess' $null) -Kind 'text') + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'CostPerSuccess' $null) -Kind 'money' -Currency $currency) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'EscalationCostShare' $null) -Kind 'rate') + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26ConfidenceBadge (Get-ContractProperty $r 'Confidence' 'INSUFFICIENT')) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'Sample' $null) -Kind 'int') + '</td></tr>')
    }
    $null = $sb.Append('</tbody></table>')
    return $sb.ToString()
}

# --- verified success ---------------------------------------------------------------------------

function ConvertTo-DbM26VerifiedHtml {
    param([AllowNull()][object]$View)
    $rows = @(Get-ContractProperty $View 'VerifiedSuccessView' @())
    if ($rows.Count -eq 0) { return '<div class="empty">No verified-success view rows.</div>' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<table><thead><tr><th>Task</th><th>Change</th><th>Attempt completed</th><th>Implementation verified</th><th>Claude accepted</th><th>Human Git pending</th><th>Outcome</th></tr></thead><tbody>')
    foreach ($r in $rows) {
        $null = $sb.Append('<tr><td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'TaskId' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'ChangeId' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26YesNo (Get-ContractProperty $r 'AttemptCompleted' $false)) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26YesNo (Get-ContractProperty $r 'ImplementationVerified' $false)) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26YesNo (Get-ContractProperty $r 'ClaudeAccepted' $false)) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26YesNo (Get-ContractProperty $r 'HumanGitPending' $false)) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Outcome' '')) + '</td></tr>')
    }
    $null = $sb.Append('</tbody></table>')
    return $sb.ToString()
}

# --- attempt history ---------------------------------------------------------------------------

function ConvertTo-DbM26HistoryHtml {
    param([AllowNull()][object]$View)
    $rows = @(Get-ContractProperty $View 'AttemptHistory' @())
    $currency = [string](Get-ContractProperty $View 'Currency' 'INR')
    if ($rows.Count -eq 0) { return '<div class="empty">No attempts in window.</div>' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<div class="filters"><input id="hist-search" type="search" placeholder="Filter attempts..."></div>')
    $null = $sb.Append('<table id="hist-table"><thead><tr><th>Task</th><th>Change</th><th>Attempt</th><th>Provider</th><th>Model</th><th>Reasoning</th><th>Result</th><th>Verification</th><th>Cost</th><th>Failure category</th><th>Escalation</th><th>Timestamp</th></tr></thead><tbody>')
    foreach ($r in $rows) {
        $null = $sb.Append('<tr><td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Task' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Change' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'AttemptId' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Provider' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Model' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Reasoning' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Result' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Verification' '')) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'Cost' $null) -Kind 'money' -Currency $currency) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'FailureCategory' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Escalation' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'TimestampUtc' '')) + '</td></tr>')
    }
    $null = $sb.Append('</tbody></table>')
    return $sb.ToString()
}

# --- chain drilldown ---------------------------------------------------------------------------

function ConvertTo-DbM26ChainsHtml {
    param([AllowNull()][object]$View)
    $chains = @(Get-ContractProperty $View 'ChainView' @())
    $currency = [string](Get-ContractProperty $View 'Currency' 'INR')
    if ($chains.Count -eq 0) { return '<div class="empty">No task chains in window.</div>' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $chains) {
        $total = [double](Get-ContractProperty $ch 'TotalCost' 0)
        $outcome = [string](Get-ContractProperty $ch 'TerminalOutcome' 'INCOMPLETE')
        $badge = '<span class="badge">' + (ConvertTo-DbM26HtmlEscaped $outcome) + '</span>'
        if ($outcome -eq 'SUCCESS') { $badge = '<span class="badge ok">' + (ConvertTo-DbM26HtmlEscaped $outcome) + '</span>' }
        if ($outcome -eq 'FAILURE' -or $outcome -eq 'REJECTED') { $badge = '<span class="badge danger">' + (ConvertTo-DbM26HtmlEscaped $outcome) + '</span>' }
        $null = $sb.Append('<div class="chain"><div class="chain-head">Task <strong>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $ch 'TaskId' '')) + '</strong> ' + $badge +
                           ' <span class="muted">cumulative ' + (Format-DbM26Value -Value $total -Kind 'money' -Currency $currency) + '</span>' +
                           ' <span class="chain-toggle" data-target="' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $ch 'TaskId' '')) + '">expand</span></div>')
        $null = $sb.Append('<div class="chain-body" id="chain-' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $ch 'TaskId' '')) + '">')
        $null = $sb.Append('<table><thead><tr><th>#</th><th>Attempt</th><th>Provider</th><th>Model</th><th>Result</th><th>Cost</th><th>Cumulative</th><th>Escalation</th></tr></thead><tbody>')
        foreach ($a in @(Get-ContractProperty $ch 'Attempts' @())) {
            $null = $sb.Append('<tr><td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $a 'Seq' '')) + '</td>')
            $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $a 'AttemptId' '')) + '</td>')
            $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $a 'Provider' '')) + '</td>')
            $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $a 'Model' '')) + '</td>')
            $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $a 'Result' '')) + '</td>')
            $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $a 'Cost' $null) -Kind 'money' -Currency $currency) + '</td>')
            $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $a 'CumulativeCost' $null) -Kind 'money' -Currency $currency) + '</td>')
            $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $a 'Escalation' '')) + '</td></tr>')
        }
        $null = $sb.Append('</tbody></table></div></div>')
    }
    return $sb.ToString()
}

# --- local / openrouter ------------------------------------------------------------------------

function ConvertTo-DbM26LocalHtml {
    param([AllowNull()][object]$View)
    $rows = @(Get-ContractProperty $View 'LocalOpenRouterView' @())
    $currency = [string](Get-ContractProperty $View 'Currency' 'INR')
    if ($rows.Count -eq 0) { return '<div class="empty">No route-identity rows.</div>' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<table><thead><tr><th>Underlying model</th><th>Local / remote</th><th>Provider</th><th>Gateway</th><th>Local cost status</th><th>Total cost</th><th>Attempts</th></tr></thead><tbody>')
    foreach ($r in $rows) {
        $null = $sb.Append('<tr><td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'UnderlyingModel' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'LocalOrRemote' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Provider' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Gateway' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'LocalCostStatus' '')) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'TotalCost' $null) -Kind 'money' -Currency $currency) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'AttemptCount' $null) -Kind 'int') + '</td></tr>')
    }
    $null = $sb.Append('</tbody></table>')
    $null = $sb.Append('<div class="muted">Local is never shown as automatically FREE: LOCAL_COST_UNKNOWN unless provider price evidence is known and labelled.</div>')
    return $sb.ToString()
}

# --- confidence + footer -------------------------------------------------------------------------

function ConvertTo-DbM26ConfidenceBadge {
    param([AllowNull()][string]$Level)
    $lvl = if ($Level) { $Level.ToUpperInvariant() } else { 'INSUFFICIENT' }
    $cls = 'badge'
    if ($lvl -eq 'HIGH') { $cls = 'badge ok' }
    if ($lvl -eq 'MODERATE') { $cls = 'badge' }
    if ($lvl -eq 'LOW') { $cls = 'badge warn' }
    if ($lvl -eq 'INSUFFICIENT') { $cls = 'badge danger' }
    return '<span class="' + $cls + '">' + (ConvertTo-DbM26HtmlEscaped $lvl) + '</span>'
}

function ConvertTo-DbM26YesNo {
    param([AllowNull()][object]$Value)
    if ($null -ne $Value -and [bool]$Value) { return '<span class="ok">yes</span>' }
    return '<span class="muted">no</span>'
}

function ConvertTo-DbM26ConfidenceHtml {
    param([AllowNull()][object]$View)
    $rows = @(Get-ContractProperty $View 'ConfidenceSummary' @())
    if ($rows.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<h2>Confidence / sample size</h2><table><thead><tr><th>Analytic</th><th>Confidence</th><th>Sample size</th></tr></thead><tbody>')
    foreach ($r in $rows) {
        $null = $sb.Append('<tr><td>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $r 'Analytic' '')) + '</td>')
        $null = $sb.Append('<td>' + (ConvertTo-DbM26ConfidenceBadge (Get-ContractProperty $r 'ConfidenceLevel' 'INSUFFICIENT')) + '</td>')
        $null = $sb.Append('<td>' + (Format-DbM26Value -Value (Get-ContractProperty $r 'SampleSize' $null) -Kind 'int') + '</td></tr>')
    }
    $null = $sb.Append('</tbody></table>')
    return $sb.ToString()
}

function ConvertTo-DbM26FooterHtml {
    param([AllowNull()][object]$View)
    $guard = Get-ContractProperty $View 'ReadOnlyGuard' $null
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<footer class="ro"><div><span class="badge ro">READ-ONLY ANALYTICS</span> ')
    if ($null -ne $guard) {
        $null = $sb.Append('Auto execution: <strong>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $guard 'AutoExecutionEnabled' 'false')) + '</strong>')
        $null = $sb.Append(' &middot; Write actions: <strong>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $guard 'HasWriteActions' 'false')) + '</strong>')
        $null = $sb.Append(' &middot; Policy version: <strong>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $guard 'PolicyVersion' '0.0.0')) + '</strong>')
        $null = $sb.Append(' &middot; Provider/model executed: <strong>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $guard 'ProviderModelExecuted' 'false')) + '</strong>')
        $null = $sb.Append(' &middot; Paid calls: <strong>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $guard 'PaidApiCalls' '0')) + '</strong>')
        $null = $sb.Append(' &middot; Network calls: <strong>' + (ConvertTo-DbM26HtmlEscaped (Get-ContractProperty $guard 'NetworkCalls' '0')) + '</strong>')
        $w = @(Get-ContractProperty $guard 'Warnings' @())
        if ($w.Count -gt 0) { $null = $sb.Append('<div class="muted">' + (ConvertTo-DbM26HtmlEscaped ($w -join '; ')) + '</div>') }
    }
    $null = $sb.Append('</div><div class="muted">Every figure traces to DB-M16/17/21/22/24/25 evidence. No budget override, no health change, no policy change, no model execution.</div></footer>')
    return $sb.ToString()
}

# --- styles + scripts -----------------------------------------------------------------------------

function Get-DbM26StyleCss {
    return @'
:root{--bg:#f5f6f8;--card:#fff;--ink:#1a1d21;--mut:#6b7280;--line:#e2e5ea;--acc:#2563eb;--ok:#15803d;--warn:#b45309;--danger:#b91c1c}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,Segoe UI,Roboto,Arial,sans-serif}
.wrap{max-width:1200px;margin:0 auto;padding:20px}
.top{padding:8px 0 14px;border-bottom:2px solid var(--line);margin-bottom:14px}
.top h1{margin:0 0 4px;font-size:22px}
.meta{color:var(--mut);font-size:13px}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:10px;margin:14px 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 12px}
.card-label{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.card-value{font-size:20px;font-weight:600;margin-top:4px}
.tabs{display:flex;flex-wrap:wrap;gap:4px;margin:16px 0 6px}
.tab{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:6px 12px;cursor:pointer;font-size:13px;color:var(--ink)}
.tab.active{background:var(--acc);border-color:var(--acc);color:#fff}
.panel{display:none;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:14px;margin-top:6px}
.panel.active{display:block}
table{border-collapse:collapse;width:100%;font-size:13px;margin:6px 0}
th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}
th{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.03em}
.muted{color:var(--mut);font-size:12px}
.ok{color:var(--ok)}.fail{background:var(--danger)}
.badge{display:inline-block;border:1px solid var(--line);border-radius:999px;padding:1px 8px;font-size:11px;font-weight:600}
.badge.ok{color:var(--ok);border-color:var(--ok)}
.badge.warn{color:var(--warn);border-color:var(--warn)}
.badge.danger{color:var(--danger);border-color:var(--danger)}
.badge.ro{color:#fff;background:var(--acc);border-color:var(--acc)}
.bdexp{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:16px}
.bd h3{margin:2px 0 6px;font-size:13px;color:var(--mut)}
.bdrow{display:flex;align-items:center;gap:8px;margin:4px 0}
.bdkey{width:170px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px}
.bdbar{flex:1;background:var(--line);border-radius:4px;height:12px;overflow:hidden}
.bdfill{height:100%;background:var(--acc)}
.bdval{min-width:110px;text-align:right;font-size:12px}
.chain{margin:8px 0;border:1px solid var(--line);border-radius:8px}
.chain-head{padding:8px 10px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.chain-toggle{cursor:pointer;color:var(--acc);font-size:12px;margin-left:auto}
.chain-body{display:none;padding:0 10px 10px}
.empty{padding:18px;color:var(--mut);background:var(--card);border:1px dashed var(--line);border-radius:8px;margin-top:6px}
footer.ro{margin-top:18px;border-top:1px solid var(--line);padding-top:10px;color:var(--mut);font-size:12px}
.warnrow td{background:#fdf6ec}
.filters{margin:6px 0}
.filters input{padding:6px 10px;border:1px solid var(--line);border-radius:6px;width:280px;font-size:13px}
'@
}

function Get-DbM26Js {
    return @'
(function(){
  var tabs=document.querySelectorAll('.tab');
  tabs.forEach(function(b){b.addEventListener('click',function(){
    var key=b.getAttribute('data-tab');
    document.querySelectorAll('.tab').forEach(function(x){x.classList.remove('active')});
    document.querySelectorAll('.panel').forEach(function(x){x.classList.remove('active')});
    b.classList.add('active');
    var p=document.getElementById('tab-'+key); if(p){p.classList.add('active')}
  })});
  document.querySelectorAll('.chain-toggle').forEach(function(t){t.addEventListener('click',function(){
    var body=document.getElementById('chain-'+t.getAttribute('data-target')); if(body){body.style.display=(body.style.display==='block')?'none':'block'}
  })});
  var s=document.getElementById('hist-search');
  if(s){s.addEventListener('input',function(){
    var q=s.value.toLowerCase();var rows=document.querySelectorAll('#hist-table tbody tr');
    rows.forEach(function(r){r.style.display=(r.textContent.toLowerCase().indexOf(q)>=0)?'':'none'});
  })}
})();
'@
}

# --- explicit artifact write -----------------------------------------------------------------------

function Export-DbM26DashboardHtml {
    <#
    .SYNOPSIS
    Render the dashboard and write the operator-requested HTML artifact. The
    library itself performs no other writes. Returns the output path.
    #>
    param(
        [AllowNull()][object]$View,
        [string]$OutputPath,
        [string]$Title = 'DevBridge AI Usage / Cost Dashboard'
    )
    if (-not $OutputPath) { throw 'OutputPath is required' }
    $html = ConvertTo-DbM26Html -View $View -Title $Title
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $html, $utf8NoBom)
    return (Get-Item $OutputPath).FullName
}

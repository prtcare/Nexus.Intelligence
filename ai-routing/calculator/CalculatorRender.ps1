# CalculatorRender.ps1 -- DB-M27 AI Cost Calculator UI HTML renderer.
#
# Renders a CalculatorView v1 as ONE self-contained interactive HTML page (inline
# CSS/JS, no network, no external assets). The page embeds the authoritative
# DB-M16 engine result for the reference scenario plus the DB-M15 catalogue and
# DB-M16 exchange-rate data as JSON; in-browser input changes recompute a clearly
# labelled "ESTIMATED PREVIEW" with the documented per-million arithmetic. The
# library performs no writes except the explicit Export-DbM27CalculatorHtml.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB27_*).
# ASCII-only source (PS 5.1 + BOM-safe). No secrets.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "CalculatorEngine.ps1")

# --- JSON + escaping helpers -----------------------------------------------------------

function ConvertTo-DbM27Json {
    <#
    .SYNOPSIS
    Deterministic JSON writer for the flat/shallow view + selector data embedded in
    the page. Handles null/bool/number/string/array/hashtable/pscustomobject.
    Acyclic input only (the calculator view is deliberately shallow). Never emits
    secrets (no secret fields are projected).
    #>
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) {
        $s = $Value -replace '\\', '\\\\' -replace '"', '\"' -replace "`r", '' -replace "`n", ' ' -replace "`t", ' '
        $s = $s -replace '</', '<\/'
        return '"' + $s + '"'
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [byte]) {
        return ([Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        $d = [double]$Value
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return 'null' }
        $rounded = [math]::Round($d, 10)
        return ($rounded.ToString([System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($k in $Value.Keys) {
            $parts.Add((ConvertTo-DbM27Json ([string]$k)) + ':' + (ConvertTo-DbM27Json ($Value[$k])))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($it in $Value) { $items.Add((ConvertTo-DbM27Json $it)) }
        return '[' + ($items -join ',') + ']'
    }
    if ($Value -is [pscustomobject]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($p in $Value.PSObject.Properties) {
            $parts.Add((ConvertTo-DbM27Json $p.Name) + ':' + (ConvertTo-DbM27Json $p.Value))
        }
        return '{' + ($parts -join ',') + '}'
    }
    return (ConvertTo-DbM27Json ([string]$Value))
}

function ConvertTo-DbM27HtmlEscaped {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
    return $s
}

function Format-DbM27Value {
    <#
    .SYNOPSIS
    Deterministic display formatting for the HTML page. Money keeps enough
    precision for tiny per-token estimates and never shows a fabricated zero.
    #>
    param($Value, [string]$Kind = 'text', [string]$Currency = '')
    if ($null -eq $Value -and $Kind -ne 'text') { return 'unknown' }
    if ($null -eq $Value) { return '' }
    switch ($Kind) {
        'money' {
            $d = [double]$Value
            if ($d -eq 0) { return '0.00' }
            $sym = if ($Currency -eq 'INR') { 'INR ' } else { 'USD ' }
            return $sym + ([math]::Round($d, 6).ToString('0.######', [System.Globalization.CultureInfo]::InvariantCulture))
        }
        'pct' {
            $d = [double]$Value
            if ([double]::IsNaN($d)) { return 'unknown' }
            return ([math]::Round($d, 2).ToString([System.Globalization.CultureInfo]::InvariantCulture) + '%')
        }
        'int' { return ([Convert]::ToString([long]$Value, [System.Globalization.CultureInfo]::InvariantCulture)) }
        'bool' { return $(if ($Value) { 'YES' } else { 'NO' }) }
        default { return ([string]$Value) }
    }
}

# --- static HTML sections ----------------------------------------------------------------

function Get-DbM27StyleCss {
    return @'
<style>
  :root { --bg:#f7f7f8; --card:#ffffff; --ink:#1f2328; --muted:#6b7280; --line:#e5e7eb;
          --accent:#2563eb; --good:#15803d; --warn:#b45309; --bad:#b91c1c; --chip:#eef2ff; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:Segoe UI, Arial, sans-serif; background:var(--bg); color:var(--ink); font-size:14px; }
  .wrap { max-width:1080px; margin:0 auto; padding:18px; }
  header { background:linear-gradient(90deg,#1e3a8a,#2563eb); color:#fff; padding:18px 22px; border-radius:10px; }
  header h1 { margin:0 0 4px; font-size:22px; }
  header .sub { opacity:.85; font-size:13px; }
  .badge { display:inline-block; padding:2px 10px; border-radius:999px; font-size:11px; font-weight:600;
           margin:4px 6px 0 0; background:rgba(255,255,255,.18); }
  .grid { display:grid; grid-template-columns: 1fr 1fr; gap:16px; margin-top:16px; }
  @media (max-width:860px){ .grid { grid-template-columns:1fr; } }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:16px; }
  .card h2 { margin:0 0 12px; font-size:15px; color:var(--accent); }
  label { display:block; font-size:12px; color:var(--muted); margin:10px 0 4px; }
  select, input { width:100%; padding:7px 9px; border:1px solid var(--line); border-radius:6px; font-size:13px; background:#fff; }
  .row { display:grid; grid-template-columns:1fr 1fr; gap:10px; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); }
  th { color:var(--muted); font-weight:600; font-size:12px; }
  .est { color:var(--accent); font-weight:700; }
  .note { font-size:12px; color:var(--muted); margin-top:8px; }
  .chip { display:inline-block; padding:1px 8px; border-radius:999px; font-size:11px; font-weight:600; background:var(--chip); }
  .ok { color:var(--good); } .warn { color:var(--warn); } .bad { color:var(--bad); }
  .guard { margin-top:16px; border:1px dashed var(--line); border-radius:8px; padding:12px 16px; font-size:12px; color:var(--muted); background:#fbfbfc; }
  .guard b { color:var(--ink); }
  .kpi { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:10px; }
  .kpi div { background:#f8fafc; border:1px solid var(--line); border-radius:8px; padding:10px; }
  .kpi .l { font-size:11px; color:var(--muted); } .kpi .v { font-size:16px; font-weight:700; }
  .preview-flag { display:inline-block; font-size:11px; font-weight:700; padding:1px 8px; border-radius:999px;
                  background:#fef3c7; color:var(--warn); }
</style>
'@
}

function ConvertTo-DbM27ScenarioHtml {
    param($View)
    $s = $View.Scenario
    $p = $View.Pricing
    $g = $View.Guard
    if (-not $s) { return '<div class="note">No scenario resolved.</div>' }
    $routeBadge = if ($s.RouteType) { '<span class="chip">' + (ConvertTo-DbM27HtmlEscaped $s.RouteType) + '</span>' } else { '' }
    $statusColor = 'ok'
    if ($p.PriceStatus -in @('PRICE_UNKNOWN', 'LOCAL_COST_UNKNOWN')) { $statusColor = 'warn' }
    $priceStatusHtml = '<span class="chip ' + $statusColor + '">' + (ConvertTo-DbM27HtmlEscaped $p.PriceStatus) + '</span>'
    $recordStatusHtml = '<span class="chip">' + (ConvertTo-DbM27HtmlEscaped $p.PricingRecordStatus) + '</span>'
    $localNote = ''
    if ($s.RouteType -eq 'LOCAL' -and $p.OperationalCostUnknown) {
        $localNote = '<div class="note bad">LOCAL != FREE: no usable local cost basis exists; the estimate is not zero and cannot be asserted to be free.</div>'
    }
    return @"
<div>
  <div class="kpi">
    <div><div class="l">Provider</div><div class="v">$(ConvertTo-DbM27HtmlEscaped $s.ProviderDisplayName)</div></div>
    <div><div class="l">Route</div><div class="v">$routeBadge</div></div>
    <div><div class="l">Model</div><div class="v">$(ConvertTo-DbM27HtmlEscaped $s.ModelDisplayName)</div></div>
    <div><div class="l">Pricing record</div><div class="v" style="font-size:12px;">$(ConvertTo-DbM27HtmlEscaped $p.PricingRecordId)</div></div>
    <div><div class="l">Price status</div><div class="v">$priceStatusHtml</div></div>
    <div><div class="l">Record status</div><div class="v">$recordStatusHtml</div></div>
  </div>
  <div class="note">Provider/model EXECUTED: $(Format-DbM27Value $g.ProviderModelExecuted bool) (nothing runs in the calculator).
  $localNote</div>
  <div class="note">Billing identity: $(ConvertTo-DbM27HtmlEscaped $p.BillingProviderId) / $(ConvertTo-DbM27HtmlEscaped $p.BillingModelId).
  $(ConvertTo-DbM27HtmlEscaped $p.BillingNote)</div>
</div>
"@
}

function ConvertTo-DbM27EstimateHtml {
    param($View)
    $e = $View.Estimate
    if (-not $e) { return '<div class="note">No estimate computed.</div>' }
    $statusHtml = '<span class="chip ' + $(if ($e.CalculationStatus -eq 'COMPLETE') { 'ok' } else { 'bad' }) + '">' + (ConvertTo-DbM27HtmlEscaped $e.CalculationStatus) + '</span>'
    $actualNote = '<div class="note"><b>Actual-vs-estimated:</b> this is <b>ESTIMATED COST</b> (UsageSource ESTIMATED). ' +
        'ActualCost is <b>' + $(if ($null -eq $e.ActualCost) { 'none' } else { (Format-DbM27Value $e.ActualCost money $e.CostCurrency) }) + '</b> because nothing was executed.</div>'
    $recordNote = '<div class="note">Pricing version used: <b>' + (ConvertTo-DbM27HtmlEscaped $View.Pricing.PricingRecordId) + '</b> (' +
        (ConvertTo-DbM27HtmlEscaped $View.Pricing.PricingRecordStatus) + ', effective ' + (ConvertTo-DbM27HtmlEscaped $View.Pricing.EffectiveFromUtc) +
        ' -> ' + (ConvertTo-DbM27HtmlEscaped $View.Pricing.EffectiveToUtc) + '). Source: ' + (ConvertTo-DbM27HtmlEscaped $View.Pricing.Source) + '.</div>'
    return @"
<div>
  $statusHtml
  <table>
    <tr><th>Dimension</th><th>Cost</th></tr>
    <tr><td>Input (uncached)</td><td>$(Format-DbM27Value $e.InputCost money $e.PricingCurrency)</td></tr>
    <tr><td>Output</td><td>$(Format-DbM27Value $e.OutputCost money $e.PricingCurrency)</td></tr>
    <tr><td>Cached input</td><td>$(Format-DbM27Value $e.CachedInputCost money $e.PricingCurrency)</td></tr>
    <tr><td>Cache write (5m)</td><td>$(Format-DbM27Value $e.CacheWrite5mCost money $e.PricingCurrency)</td></tr>
    <tr><td>Cache write (1h)</td><td>$(Format-DbM27Value $e.CacheWrite1hCost money $e.PricingCurrency)</td></tr>
    <tr><td>Subtotal (provider currency)</td><td>$(Format-DbM27Value $e.Subtotal money $e.PricingCurrency)</td></tr>
    <tr><td><b>Per-attempt estimate ($(ConvertTo-DbM27HtmlEscaped $e.TargetCurrency))</b></td><td class="est">$(Format-DbM27Value $e.PerAttemptCost money $e.TargetCurrency)</td></tr>
  </table>
  <div class="kpi" style="margin-top:10px;">
    <div><div class="l">Attempts (incl. corrections)</div><div class="v">$(Format-DbM27Value $e.AttemptsTotal int)</div></div>
    <div><div class="l">Total multi-attempt estimate</div><div class="v">$(Format-DbM27Value $e.TotalMultiAttemptCost money $e.TargetCurrency)</div></div>
    <div><div class="l">Exchange rate</div><div class="v">$(ConvertTo-DbM27HtmlEscaped $e.ExchangeRateId)</div></div>
  </div>
  $recordNote
  $actualNote
</div>
"@
}

function ConvertTo-DbM27QualityHtml {
    param($View)
    $q = $View.Quality
    if (-not $q) { return '<div class="note">No quality panel.</div>' }
    # Never render a quality panel without observed evidence (DB-M17/M25). The
    # calculator must not pretend unobserved metrics are reliable.
    if (-not $q.HasEvidence) {
        return '<div class="note">No verified-success attempt history for this model/provider route (requires DB-M17/M25 observed evidence). Quality metrics are never invented.</div>'
    }
    $confClass = 'warn'
    if ($q.ConfidenceLevel -eq 'HIGH') { $confClass = 'ok' }
    elseif ($q.ConfidenceLevel -eq 'MODERATE') { $confClass = 'ok' }
    $lowNote = ''
    if ($q.SampleCount -lt 20) {
        $lowNote = '<div class="note warn">Sample size ' + (Format-DbM27Value $q.SampleCount int) +
            ' is INSUFFICIENT/LOW confidence. These metrics are NOT statistically reliable and must not be treated as proven.</div>'
    }
    return @"
<div>
  <table>
    <tr><th>Metric</th><th>Value</th></tr>
    <tr><td>Historical sample size</td><td>$(Format-DbM27Value $q.SampleCount int)</td></tr>
    <tr><td>Confidence category</td><td><span class="chip $confClass">$(ConvertTo-DbM27HtmlEscaped $q.ConfidenceLevel)</span></td></tr>
    <tr><td>Verified success rate</td><td>$(Format-DbM27Value $q.VerifiedSuccessRate pct)</td></tr>
    <tr><td>First-attempt success rate</td><td>$(Format-DbM27Value $q.FirstAttemptSuccessRate pct)</td></tr>
    <tr><td>Expected cost per verified success</td><td>$(Format-DbM27Value $q.ExpectedCostPerVerifiedSuccess money $View.Request.CurrencyTarget)</td></tr>
    <tr><td>Observed cost per verified success</td><td>$(Format-DbM27Value $q.ObservedCostPerVerifiedSuccess money $View.Request.CurrencyTarget)</td></tr>
    <tr><td>Expected-cost basis</td><td>$(ConvertTo-DbM27HtmlEscaped $q.ExpectedCostBasis)</td></tr>
    <tr><td>Attempts per verified success</td><td>$(Format-DbM27Value $q.AverageAttemptsPerVerifiedSuccess text)</td></tr>
  </table>
  $lowNote
  <div class="note">$(ConvertTo-DbM27HtmlEscaped $q.EvidenceNote) Quality metrics are informational and never alter the estimate above.</div>
</div>
"@
}

function ConvertTo-DbM27EscalationHtml {
    param($View)
    $steps = @($View.EscalationSteps)
    $t = $View.EscalationTotal
    if (-not $t -or -not $t.HasPath) { return '<div class="note">No escalation path supplied. Cost simulation is optional and read-only.</div>' }
    $rows = ''
    foreach ($st in $steps) {
        $rows += '<tr><td>' + (Format-DbM27Value $st.Step int) + '</td><td>' + (ConvertTo-DbM27HtmlEscaped $st.ProviderId) +
            '</td><td>' + (ConvertTo-DbM27HtmlEscaped $st.ModelId) + '</td><td>' + (Format-DbM27Value $st.PerAttemptCost money $st.Currency) +
            '</td><td>' + (Format-DbM27Value $st.StepTotal money $st.Currency) + '</td><td>' + (Format-DbM27Value $st.CumulativeCost money $st.Currency) + '</td></tr>'
    }
    return @"
<div>
  <table>
    <tr><th>Step</th><th>Provider</th><th>Model</th><th>Per-attempt est</th><th>Step total</th><th>Cumulative</th></tr>
    $rows
  </table>
  <div class="note"><b>Escalation estimate:</b> cumulative '$(Format-DbM27Value $t.CumulativeCost money $t.Currency)'. Read-only cost simulation only;
  the escalation path NEVER modifies routing policy (RoutingPolicyUnmodified: $(Format-DbM27Value $t.RoutingPolicyUnmodified bool)).</div>
</div>
"@
}

function ConvertTo-DbM27BudgetHtml {
    param($View)
    $b = $View.Budget
    if (-not $b) { return '<div class="note">No budget context.</div>' }
    if (-not $b.HasPolicy) {
        return '<div class="note">' + (ConvertTo-DbM27HtmlEscaped $b.Note) + '</div>'
    }
    $rows = ''
    foreach ($l in @($b.ApplicableLimits)) {
        $rows += '<tr><td>' + (ConvertTo-DbM27HtmlEscaped $l.Scope) + '</td><td>' + (Format-DbM27Value $l.Limit money $b.Currency) +
            '</td><td>' + (Format-DbM27Value $l.ProjectedSpend money $b.Currency) +
            '</td><td>' + (Format-DbM27Value $l.EstimatedPercentConsumed pct) + '</td><td>' + (ConvertTo-DbM27HtmlEscaped $l.Decision) + '</td></tr>'
    }
    return @"
<div>
  <div class="note">Policy: <b>$(ConvertTo-DbM27HtmlEscaped $b.PolicyId)</b> (currency $(ConvertTo-DbM27HtmlEscaped $b.Currency)). Decision: <b>$(ConvertTo-DbM27HtmlEscaped $b.Decision)</b>.</div>
  <table>
    <tr><th>Scope</th><th>Limit</th><th>Projected spend</th><th>Est. % consumed</th><th>Decision</th></tr>
    $rows
  </table>
  <div class="note">$(ConvertTo-DbM27HtmlEscaped $b.Note)</div>
</div>
"@
}

function ConvertTo-DbM27GuardFooterHtml {
    param($View)
    $g = $View.Guard
    if (-not $g) { $g = New-DbM27ReadOnlyGuard }
    return @"
<div class="guard">
  <b>Read-only calculator.</b>
  AUTO AI execution: <b>$(Format-DbM27Value $g.AutoExecutionEnabled bool)</b> |
  Provider/model executed: <b>$(Format-DbM27Value $g.ProviderModelExecuted bool)</b> |
  Paid API calls: <b>$(Format-DbM27Value $g.PaidApiCalls int)</b> |
  Network calls: <b>$(Format-DbM27Value $g.NetworkCalls int)</b> |
  Budget override capability: <b>NO</b> |
  Routing modification capability: <b>NO</b> |
  Pricing modification capability: <b>NO</b> |
  Provider health modification capability: <b>NO</b> |
  Canonical workbook modified: <b>NO</b> |
  Nexus source modified: <b>NO</b>
</div>
"@
}

function Get-DbM27Js {
    return @'
<script>
(function(){
  function $(id){ return document.getElementById(id); }
  var DATA = JSON.parse(document.getElementById('db27-data').textContent);
  var MODELS = DATA.selectors.models || [];
  var PROVIDERS = DATA.selectors.providers || [];
  var PRICES = DATA.selectors.pricingRecords || [];
  var FX = DATA.selectors.exchangeRates || [];
  var REQ = DATA.request || {};

  function fxRate(target){
    if(target==='USD') return 1;
    for(var i=0;i<FX.length;i++){ if(FX[i].quoteCurrency==='INR' && FX[i].rate){ return parseFloat(FX[i].rate); } }
    return 83.5; // fallback never used when catalogue present
  }
  function toNum(id, def){ var el=$(id); if(!el) return def; var v=parseFloat(el.value); return isNaN(v)?def:Math.max(0,v); }
  function findPrice(providerId, modelId){
    for(var i=0;i<PRICES.length;i++){ var p=PRICES[i];
      if(p.providerId===providerId && p.modelId===modelId) return p; }
    return null;
  }
  function underlyingProvider(providerId, underlyingId){
    // gateway: find the catalogue model whose id/underlying matches, use its provider
    for(var i=0;i<MODELS.length;i++){ var m=MODELS[i];
      if(m.modelId===underlyingId || m.underlyingModelId===underlyingId) return m.providerId; }
    return providerId;
  }
  function money(v, cur){
    if(v===null || v===undefined || isNaN(v)) return 'unknown';
    var sym=(cur==='INR')?'INR ':'USD ';
    var r=Math.round(v*1000000)/1000000;
    return sym + r;
  }
  function recompute(){
    var provider=$('sel-provider').value, route=$('sel-route').value, model=$('sel-model').value;
    var underlying=$('sel-underlying').value || model;
    var target=$('sel-currency').value;
    var inT=toNum('in-input',0), cacheT=toNum('in-cached',0), outT=toNum('in-output',0),
        cwT=toNum('in-cw',0), attempts=Math.max(1,toNum('in-attempts',1)), corr=Math.max(0,toNum('in-corrections',0));
    var billProv=provider, billModel=model;
    if(route==='GATEWAY'){ billModel=underlying; billProv=underlyingProvider(provider, underlying); }
    var price=findPrice(billProv, billModel);
    var out={};
    if(!price){
      out.status=(route==='LOCAL')?'LOCAL_COST_UNKNOWN':'PRICE_UNKNOWN';
      out.localUnknown=(route==='LOCAL');
      out.priceUnknown=!(route==='LOCAL');
      out.msg='no effective pricing record for '+billProv+'/'+billModel+' in the embedded DB-M15 catalogue; nothing can be priced and NO zero is shown.';
      render(out, price, target, attempts, corr);
      return;
    }
    var inp=price.inputPricePerMillion||0, outP=price.outputPricePerMillion||0,
        cin=price.cachedInputPricePerMillion||0, cw5=price.cacheWrite5mPricePerMillion||0,
        cw1=price.cacheWrite1hPricePerMillion||0;
    function cost(t,p){ return (t/1000000)*p; }
    var sub = cost(inT,inp) + cost(cacheT,cin) + cost(outT,outP) + cost(cwT,cw5);
    var conv = sub * fxRate(target);
    out.status='COMPLETE';
    out.input=cost(inT,inp); out.output=cost(outT,outP); out.cached=cost(cacheT,cin);
    out.cw5=cost(cwT,cw5); out.subtotal=sub; out.converted=conv;
    out.per=conv; out.total=conv*(attempts+corr);
    out.record=price.pricingRecordId; out.recordStatus=price.status;
    out.msg='ESTIMATED PREVIEW recomputed in the browser from the embedded DB-M15 catalogue (per-million arithmetic per the DB-M16 contract). The authoritative DB-M16 engine result for the reference scenario is shown below and stays unchanged.';
    render(out, price, target, attempts, corr);
  }
  function render(out, price, target, attempts, corr){
    var r=$('preview-results');
    var html='';
    if(out.status!=='COMPLETE'){
      html='<div class="note"><span class="preview-flag">ESTIMATED PREVIEW</span> '+
        '<b>'+out.status+'</b>: '+out.msg+'</div>';
      if(out.localUnknown){ html+='<div class="note bad">LOCAL != FREE: the estimate cannot be asserted to be zero or free.</div>'; }
    } else {
      html='<div class="kpi">'+
        '<div><div class="l">Per-attempt estimate ('+target+')</div><div class="v est">'+money(out.per,target)+'</div></div>'+
        '<div><div class="l">Total multi-attempt ('+attempts+'+'+corr+')</div><div class="v">'+money(out.total,target)+'</div></div>'+
        '<div><div class="l">Input</div><div class="v">'+money(out.input,'USD')+'</div></div>'+
        '<div><div class="l">Cached input</div><div class="v">'+money(out.cached,'USD')+'</div></div>'+
        '<div><div class="l">Output</div><div class="v">'+money(out.output,'USD')+'</div></div>'+
        '<div><div class="l">Cache write 5m</div><div class="v">'+money(out.cw5,'USD')+'</div></div>'+
        '</div>';
      html+='<div class="note">Pricing record: <b>'+out.record+'</b> ('+out.recordStatus+'). '+out.msg+'</div>';
    }
    r.innerHTML=html;
  }
  function buildSelects(){
    // provider
    var psel=$('sel-provider');
    PROVIDERS.forEach(function(p){ var o=document.createElement('option'); o.value=p.providerId;
      o.textContent=p.providerId + (p.displayName?(' - '+p.displayName):''); psel.appendChild(o); });
    // route
    var rsel=$('sel-route'); ['DIRECT','GATEWAY','LOCAL'].forEach(function(r){
      var o=document.createElement('option'); o.value=r; o.textContent=r; rsel.appendChild(o); });
    // model
    fillModels();
    // currency
    var csel=$('sel-currency'); ['USD','INR'].forEach(function(c){
      var o=document.createElement('option'); o.value=c; o.textContent=c; csel.appendChild(o); });
    // seed from the reference request
    if(REQ.providerId){ psel.value=REQ.providerId; }
    if(REQ.routeType){ rsel.value=REQ.routeType; }
    fillModels();
    if(REQ.modelId){ $('sel-model').value=REQ.modelId; }
    if(REQ.underlyingModelId){ $('sel-underlying').value=REQ.underlyingModelId; }
    if(REQ.currencyTarget){ csel.value=REQ.currencyTarget; }
  }
  function fillModels(){
    var msel=$('sel-model'); var prov=$('sel-provider').value; var route=$('sel-route').value;
    msel.innerHTML='';
    MODELS.forEach(function(m){
      var ok = (route==='GATEWAY') ? (m.providerId===prov || m.gatewayProviderId===prov)
                                   : (m.providerId===prov);
      if(ok){ var o=document.createElement('option'); o.value=m.modelId;
        o.textContent=m.modelId+(m.underlyingModelId&&m.underlyingModelId!==m.modelId?(' (underlying '+m.underlyingModelId+')'):''); msel.appendChild(o); }
    });
    if(msel.options.length===0){
      // gateway: allow any underlying id to be entered directly
      var o=document.createElement('option'); o.value=REQ.modelId||''; o.textContent=REQ.modelId||'(enter underlying below)'; msel.appendChild(o);
    }
  }
  function bind(){ ['sel-provider','sel-route','sel-model','sel-underlying','sel-currency',
    'in-input','in-cached','in-output','in-cw','in-attempts','in-corrections'].forEach(function(id){
      var el=$(id); if(el){ el.addEventListener('change',recompute); el.addEventListener('input',recompute); }
    });
    $('sel-provider').addEventListener('change', function(){ fillModels(); recompute(); });
    $('sel-route').addEventListener('change', function(){ fillModels(); recompute(); });
  }
  document.addEventListener('DOMContentLoaded', function(){ buildSelects(); bind(); recompute(); });
})();
</script>
'@
}

# --- main entry points -------------------------------------------------------------------

function ConvertTo-DbM27Html {
    <#
    .SYNOPSIS
    Render the CalculatorView v1 as ONE self-contained interactive HTML string.
    No writes, no network.
    #>
    param(
        [AllowNull()][object]$View,
        [string]$Title = 'DevBridge AI Cost Calculator'
    )
    if ($null -eq $View) { throw 'View is required' }

    $data = [ordered]@{
        request   = $View.Request
        scenario  = $View.Scenario
        estimate  = $View.Estimate
        pricing   = $View.Pricing
        guard     = $View.Guard
        selectors = $View.SelectorData
    }
    $dataJson = ConvertTo-DbM27Json $data

    return @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$Title</title>
$(Get-DbM27StyleCss)
</head>
<body>
<div class="wrap">
  <header>
    <h1>$Title</h1>
    <div class="sub">Pre-execution cost estimator. Calculation / UI only. No model execution, no paid API calls, no network calls.</div>
    <span class="badge">AUTO EXECUTION DISABLED</span><span class="badge">ESTIMATED COST</span><span class="badge">READ-ONLY</span>
  </header>

  <div class="grid">
    <div class="card">
      <h2>Estimate input (pre-execution)</h2>
      <div class="row">
        <div><label for="sel-provider">Provider</label><select id="sel-provider"></select></div>
        <div><label for="sel-route">Route</label><select id="sel-route"></select></div>
      </div>
      <div class="row">
        <div><label for="sel-model">Model</label><select id="sel-model"></select></div>
        <div><label for="sel-underlying">Underlying model (gateway)</label><input id="sel-underlying" type="text" placeholder="actual model for gateway routes"></div>
      </div>
      <div class="row">
        <div><label for="in-input">Input tokens (uncached)</label><input id="in-input" type="number" min="0" value="0"></div>
        <div><label for="in-cached">Cached input tokens</label><input id="in-cached" type="number" min="0" value="0"></div>
      </div>
      <div class="row">
        <div><label for="in-output">Output tokens</label><input id="in-output" type="number" min="0" value="0"></div>
        <div><label for="in-cw">Cache-write tokens (5m)</label><input id="in-cw" type="number" min="0" value="0"></div>
      </div>
      <div class="row">
        <div><label for="in-attempts">Number of attempts</label><input id="in-attempts" type="number" min="1" value="1"></div>
        <div><label for="in-corrections">Expected correction attempts</label><input id="in-corrections" type="number" min="0" value="0"></div>
      </div>
      <div><label for="sel-currency">Currency</label><select id="sel-currency"></select></div>
      <div class="note">Changing inputs recomputes an ESTIMATED PREVIEW in the browser. The authoritative DB-M16 engine result for the reference scenario is below and never changes from this page.</div>
    </div>

    <div class="card">
      <h2>ESTIMATED PREVIEW <span class="preview-flag">browser recompute</span></h2>
      <div id="preview-results"><div class="note">Loading...</div></div>
    </div>
  </div>

  <div class="grid">
    <div class="card"><h2>Scenario &amp; pricing version</h2>$(ConvertTo-DbM27ScenarioHtml $View)</div>
    <div class="card"><h2>Authoritative estimate (DB-M16 engine, reference scenario)</h2>$(ConvertTo-DbM27EstimateHtml $View)</div>
  </div>

  <div class="grid">
    <div class="card"><h2>Quality-aware view (informational)</h2>$(ConvertTo-DbM27QualityHtml $View)</div>
    <div class="card"><h2>Escalation estimate (read-only simulation)</h2>$(ConvertTo-DbM27EscalationHtml $View)</div>
  </div>

  <div class="card" style="margin-top:16px;"><h2>Budget context (informational)</h2>$(ConvertTo-DbM27BudgetHtml $View)</div>

  $(ConvertTo-DbM27GuardFooterHtml $View)

  <script type="application/json" id="db27-data">$dataJson</script>
  $(Get-DbM27Js)
</div>
</body>
</html>
"@
}

function Export-DbM27CalculatorHtml {
    <#
    .SYNOPSIS
    Render the calculator and write the operator-requested HTML artifact. The
    library itself performs no other writes. Returns the output path.
    #>
    param(
        [AllowNull()][object]$View,
        [string]$OutputPath,
        [string]$Title = 'DevBridge AI Cost Calculator'
    )
    if (-not $OutputPath) { throw 'OutputPath is required' }
    $html = ConvertTo-DbM27Html -View $View -Title $Title
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $html, $utf8NoBom)
    return (Get-Item $OutputPath).FullName
}

# ModelConfigRender.ps1 -- DB-M28 Model Configuration UI renderer.
#
# Renders the operator-facing MODEL CONFIGURATION console as ONE self-contained
# HTML artifact (inline CSS/JS, no network, no external resources). The page is
# a READ-ONLY configuration view with a STAGING PREVIEW: toggles recompute the
# routing-eligibility preview in the browser, but the page itself performs NO
# persistence. The operator's staged change set is presented as a validated
# ConfigChangeRequest payload for the backend validated atomic audited adapter
# (Apply-DbM28ConfigChange). DB-M19 hard capability gates are never overridden
# by a toggle, even in the preview. Secret VALUES are never rendered.
#
# The ONLY library write is Export-DbM28ModelConfigurationHtml's
# [System.IO.File]::WriteAllText of the operator-requested HTML artifact.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ModelConfigEngine.ps1')

function ConvertTo-DbM28HtmlEsc {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    if ($null -eq $s) { return '' }
    $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    $s = $s.Replace('"', '&quot;').Replace("'", '&#39;')
    return $s
}

function Get-DbM28HtmlStateClass {
    param([string]$State)
    switch ([string]$State) {
        'ELIGIBLE'                { return 'st-eligible' }
        'DISABLED'                { return 'st-disabled' }
        'CONFIGURATION_INCOMPLETE' { return 'st-incomplete' }
        'CAPABILITY_MISMATCH'     { return 'st-capability' }
        'PRICING_UNKNOWN'         { return 'st-pricing' }
        'PROVIDER_UNHEALTHY'      { return 'st-unhealthy' }
        default                   { return 'st-unknown' }
    }
}

function ConvertTo-DbM28Html {
    <#
    .SYNOPSIS
    Render the ModelConfigurationView v1 to a self-contained HTML string. Applies
    the secret-leak guard to the finished markup before returning.
    #>
    param([AllowNull()][object]$View)
    if ($null -eq $View) { throw 'View is null' }
    $buf = New-Object System.Collections.Generic.List[string]

    # --- embedded state JSON (never contains secret values) -------------------------------
    $stateJson = ConvertTo-DbM28Json -Object $View -Depth 0
    $stateJson = $stateJson.Replace('</', '<\/')

    # --- helper: table row builder -------------------------------------------------------
    $rowsFor = { param($arr, $script:cols) $out = New-Object System.Collections.Generic.List[string]
        foreach ($r in @($arr)) {
            $cells = New-Object System.Collections.Generic.List[string]
            foreach ($c in $cols) {
                $val = Get-ContractProperty $r $c $null
                $cells.Add('<td>' + (ConvertTo-DbM28HtmlEsc (if ($null -eq $val) { '' } else { $val })) + '</td>')
            }
            $out.Add('<tr>' + ($cells -join '') + '</tr>')
        }
        return ($out -join '') }

    $html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DB-M28 Model Configuration</title>
<style>
  :root { --bg:#f6f7f9; --panel:#fff; --ink:#1c2430; --muted:#6b7686; --line:#dfe3ea;
          --ok:#147a3a; --bad:#b3261e; --warn:#8a4b00; --acc:#1a56db; --chip:#eef1f6; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:-apple-system,"Segoe UI",Roboto,Arial,sans-serif; background:var(--bg); color:var(--ink); font-size:14px; }
  header { padding:18px 26px; background:var(--panel); border-bottom:1px solid var(--line); }
  header h1 { margin:0; font-size:19px; }
  header p { margin:4px 0 0; color:var(--muted); font-size:12.5px; }
  .tabs { display:flex; flex-wrap:wrap; gap:4px; padding:12px 26px 0; }
  .tab { border:1px solid var(--line); background:var(--panel); padding:7px 13px; border-radius:8px 8px 0 0;
         cursor:pointer; font-size:12.5px; font-weight:600; color:var(--muted); }
  .tab.active { background:var(--acc); border-color:var(--acc); color:#fff; }
  main { padding:18px 26px 60px; max-width:1240px; }
  .panel { display:none; background:var(--panel); border:1px solid var(--line); border-radius:0 10px 10px 10px; padding:18px; }
  .panel.active { display:block; }
  h2 { font-size:15px; margin:0 0 6px; }
  .note { color:var(--muted); font-size:12.5px; margin:0 0 12px; line-height:1.5; }
  table { width:100%; border-collapse:collapse; font-size:12.5px; }
  th,td { text-align:left; padding:6px 9px; border-bottom:1px solid var(--line); vertical-align:top; }
  th { background:var(--chip); font-weight:700; }
  td.mono, th.mono { font-family:ui-monospace,Consolas,monospace; font-size:11.5px; }
  .tag { display:inline-block; padding:1px 8px; border-radius:20px; font-size:11px; font-weight:700; }
  .tag.on { background:#e2f3e8; color:var(--ok); }
  .tag.off { background:#fbe9e7; color:var(--bad); }
  .tag.unk { background:var(--chip); color:var(--muted); }
  .st-eligible { color:var(--ok); font-weight:700; }
  .st-disabled { color:var(--muted); font-weight:700; }
  .st-incomplete { color:var(--warn); font-weight:700; }
  .st-capability { color:var(--bad); font-weight:700; }
  .st-pricing { color:#6a4fa3; font-weight:700; }
  .st-unhealthy { color:var(--bad); font-weight:700; }
  .badge { display:inline-block; padding:2px 9px; border-radius:6px; font-size:11px; font-weight:700; }
  .badge.red { background:#fbe9e7; color:var(--bad); }
  .badge.green { background:#e2f3e8; color:var(--ok); }
  .badge.amber { background:#fff3e0; color:var(--warn); }
  .card { border:1px solid var(--line); border-radius:10px; padding:14px 16px; margin:12px 0; }
  .kv { display:grid; grid-template-columns:230px 1fr; gap:4px 12px; font-size:12.5px; }
  .kv .k { color:var(--muted); }
  textarea { width:100%; min-height:90px; font-family:ui-monospace,Consolas,monospace; font-size:11.5px;
             border:1px solid var(--line); border-radius:8px; padding:8px; }
  .guard { border:1px dashed #c9a24a; background:#fffbf0; border-radius:10px; padding:12px 16px; margin-top:16px; }
  .guard h3 { margin:0 0 6px; font-size:13px; color:#8a4b00; }
  .guard ul { margin:0; padding-left:18px; font-size:12.5px; color:#4a3b1a; line-height:1.6; }
  footer { color:var(--muted); font-size:11.5px; padding:10px 26px 40px; }
  input[type=checkbox] { accent-color:var(--acc); }
  @media (max-width:820px){ .kv { grid-template-columns:1fr; } }
</style>
</head>
<body>
<header>
  <h1>DB-M28 &mdash; Model Configuration</h1>
  <p>Read-mostly operator configuration console for the DevBridge AI subsystem. Reuses DB-M14..M27 READ-ONLY.
     <strong>AUTO AI EXECUTION DISABLED</strong> &middot; provider/model executed: NO &middot; paid calls 0 &middot; network calls 0.
     Reference time (UTC): <span class="mono" id="refTime"></span></p>
</header>
'@
    $buf.Add($html)

    # --- tab bar ---------------------------------------------------------------------------
    $tabs = @(
        @{ id = 'providers'; label = '1 &middot; Providers' },
        @{ id = 'models'; label = '2 &middot; Models' },
        @{ id = 'routes'; label = '3 &middot; Routes' },
        @{ id = 'reasoning'; label = '4 &middot; Reasoning / Capability' },
        @{ id = 'local'; label = '5 &middot; Local Models' },
        @{ id = 'openrouter'; label = '6 &middot; OpenRouter / Gateway' },
        @{ id = 'pricing'; label = '7 &middot; Pricing Reference' },
        @{ id = 'eligibility'; label = '8 &middot; Routing Eligibility' },
        @{ id = 'health'; label = '9 &middot; Health (READ-ONLY)' },
        @{ id = 'secret'; label = '10 &middot; Security / Secrets' },
        @{ id = 'cost'; label = 'Cost Estimate &amp; Audit' }
    )
    $buf.Add('<div class="tabs">')
    for ($i = 0; $i -lt $tabs.Count; $i++) {
        $t = $tabs[$i]
        $buf.Add(('<button class="tab{0}" data-tab="{1}">{2}</button>' -f ($(if ($i -eq 0) { ' active' } else { '' })), $t.id, $t.label))
    }
    $buf.Add('</div>')
    $buf.Add('<main>')

    # ========== 1 PROVIDERS ===============================================================
    $buf.Add('<section class="panel active" id="p-providers">')
    $buf.Add('<h2>1 &middot; Providers</h2>')
    $buf.Add('<p class="note">Provider identity (DB-M14), enablement/configuration status, secret status, and effective health
        from the optional DB-M22 snapshot. Configured=false means NO provider is operational. SecretReference is an env-var NAME only; values are never displayed.</p>')
    $buf.Add('<table><thead><tr><th>Provider</th><th>Type</th><th>Gateway</th><th>Enabled</th><th>Configured</th>
        <th>Secret status</th><th>Tools</th><th>Streaming</th><th>Structured</th><th>Reasoning ctrl</th><th>Health</th><th>Circuit</th></tr></thead><tbody>')
    foreach ($r in @($View.Providers)) {
        $en = if ($r.Enabled) { '<span class="tag on">ENABLED</span>' } else { '<span class="tag off">disabled</span>' }
        $cf = if ($r.Configured) { '<span class="tag on">configured</span>' } else { '<span class="tag unk">NOT configured</span>' }
        $secCls = switch ($r.SecretStatus) {
            'CONFIGURED' { 'green' } 'NOT_CONFIGURED' { 'amber' } 'INVALID_CONFIGURATION' { 'red' } default { 'amber' }
        }
        $sec = '<span class="badge ' + $secCls + '">' + (ConvertTo-DbM28HtmlEsc $r.SecretStatus) + '</span>'
        $hCls = switch ($r.HealthState) { 'AVAILABLE' { 'green' } 'AUTH_ERROR' { 'red' } 'UNAVAILABLE' { 'red' } default { 'amber' } }
        $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $r.DisplayName) + '</td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $r.ProviderType) + '</td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $r.GatewayType) + '</td>
            <td><label class="tag-toggle"><input type="checkbox" data-toggle="provider" data-id="' + (ConvertTo-DbM28HtmlEsc $r.ProviderId) + '"' + $(if ($r.Enabled) { ' checked' } else { '' }) + '> ' + $en + '</label></td>
            <td>' + $cf + '</td><td>' + $sec + '</td>
            <td>' + $(if ($r.SupportsTools) { '<span class="tag on">Y</span>' } else { '<span class="tag unk">-</span>' }) + '</td>
            <td>' + $(if ($r.SupportsStreaming) { '<span class="tag on">Y</span>' } else { '<span class="tag unk">-</span>' }) + '</td>
            <td>' + $(if ($r.SupportsStructuredOutput) { '<span class="tag on">Y</span>' } else { '<span class="tag unk">-</span>' }) + '</td>
            <td>' + $(if ($r.SupportsReasoningControls) { '<span class="tag on">Y</span>' } else { '<span class="tag unk">-</span>' }) + '</td>
            <td><span class="badge ' + $hCls + '">' + (ConvertTo-DbM28HtmlEsc $r.HealthState) + '</span></td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $r.CircuitState) + '</td></tr>')
    }
    $buf.Add('</tbody></table>')
    $buf.Add('<p class="note">Provider enablement/configured status is operator policy. Toggling enablement stages a preview only;
        the routing-eligibility preview reuses the real DB-M19 gate and never overrides a hard capability check.</p>')
    $buf.Add('</section>')

    # ========== 2 MODELS ==================================================================
    $buf.Add('<section class="panel" id="p-models">')
    $buf.Add('<h2>2 &middot; Models</h2>')
    $buf.Add('<p class="note">Model catalogue (DB-M14). Capability flags are rendered exactly as asserted: YES / NO / UNKNOWN(not asserted).
        DB-M28 never invents an unsupported capability. Enabled is the operator toggle; everything else is informational.</p>')
    $buf.Add('<table><thead><tr><th>Model</th><th>Provider</th><th>Route</th><th>Version</th><th>Enabled</th>
        <th>Reasoning</th><th>Coding</th><th>ToolUse</th><th>Vision</th><th>Struct.Out</th><th>Context</th><th>Price</th></tr></thead><tbody>')
    foreach ($m in @($View.Models)) {
        $tag = { param($v) if ($v -eq 'YES') { '<span class="tag on">Y</span>' } elseif ($v -eq 'NO') { '<span class="tag off">N</span>' } else { '<span class="tag unk">?</span>' } }
        $en = if ($m.Enabled) { '<span class="tag on">ENABLED</span>' } else { '<span class="tag off">disabled</span>' }
        $pCls = switch ($m.PriceStatus) { 'CONFIGURED' { 'green' } 'FREE' { 'green' } 'LOCAL_COST_UNKNOWN' { 'amber' } default { 'amber' } }
        $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $m.DisplayName) + '</td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $m.ProviderDisplayName) + '</td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $m.RouteType) + '</td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $m.ModelVersion) + '</td>
            <td><input type="checkbox" data-toggle="model" data-id="' + (ConvertTo-DbM28HtmlEsc $m.ModelId) + '"' + $(if ($m.Enabled) { ' checked' } else { '' }) + '> ' + $en + '</td>
            <td>' + (& $tag $m.SupportsReasoning) + '</td><td>' + (& $tag $m.SupportsCoding) + '</td>
            <td>' + (& $tag $m.SupportsToolUse) + '</td><td>' + (& $tag $m.SupportsVision) + '</td>
            <td>' + (& $tag $m.SupportsStructuredOutput) + '</td>
            <td class="mono">' + $(if ($null -eq $m.ContextWindow) { 'UNKNOWN' } else { ConvertTo-DbM28HtmlEsc $m.ContextWindow }) + '</td>
            <td><span class="badge ' + $pCls + '">' + (ConvertTo-DbM28HtmlEsc $m.PriceStatus) + '</span></td></tr>')
    }
    $buf.Add('</tbody></table>')
    $buf.Add('</section>')

    # ========== 3 ROUTES ==================================================================
    $buf.Add('<section class="panel" id="p-routes">')
    $buf.Add('<h2>3 &middot; Routes</h2>')
    $buf.Add('<p class="note">Route types: DIRECT (provider-native), GATEWAY (via OpenRouter or another gateway provider), LOCAL.
        Gateway provider identity and underlying model id are kept separate and are never collapsed.</p>')
    $buf.Add('<table><thead><tr><th>Model</th><th>Provider</th><th>Route</th><th>Local/Remote</th><th>Gateway</th><th>Underlying</th></tr></thead><tbody>')
    foreach ($m in @($View.Models)) {
        $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $m.ModelId) + '</td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $m.ProviderId) + '</td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $m.RouteType) + '</td>
            <td>' + (ConvertTo-DbM28HtmlEsc $m.LocalOrRemote) + '</td>
            <td class="mono">' + $(if ($m.GatewayProviderId) { ConvertTo-DbM28HtmlEsc $m.GatewayProviderId } else { '&mdash;' }) + '</td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $m.UnderlyingModelId) + '</td></tr>')
    }
    $buf.Add('</tbody></table>')
    $buf.Add('</section>')

    # ========== 4 REASONING / CAPABILITY ==================================================
    $buf.Add('<section class="panel" id="p-reasoning">')
    $buf.Add('<h2>4 &middot; Reasoning &amp; Capability Options</h2>')
    $buf.Add('<p class="note">Normalized reasoning vocabulary: <span class="mono">' + ((@($View.ReasoningLevels.Available)) -join ', ') + '</span>.
        Per-model supported levels are asserted in the catalogue; NOT_ASSERTED means the level set is not verified until DB-M15/M19.
        Capability flags are never invented.</p>')
    $buf.Add('<table><thead><tr><th>Model</th><th>Reasoning</th><th>Supported levels</th><th>Status</th><th>Capability tags</th></tr></thead><tbody>')
    foreach ($rp in @($View.ReasoningLevels.PerModel)) {
        $m = @($View.Models | Where-Object { $_.ModelId -eq $rp.ModelId })[0]
        $lv = if ($rp.Levels.Count -gt 0) { (@($rp.Levels)) -join ', ' } else { '<span class="badge amber">NOT_ASSERTED</span>' }
        $tags = if ($m -and $m.AdditionalCapabilityTags -and $m.AdditionalCapabilityTags.Count -gt 0) { (@($m.AdditionalCapabilityTags)) -join ', ' } else { '&mdash;' }
        $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $rp.ModelId) + '</td>
            <td>' + (ConvertTo-DbM28HtmlEsc $rp.SupportsReasoning) + '</td>
            <td class="mono">' + $lv + '</td><td>' + (ConvertTo-DbM28HtmlEsc $rp.LevelsNote) + '</td>
            <td>' + (ConvertTo-DbM28HtmlEsc $tags) + '</td></tr>')
    }
    $buf.Add('</tbody></table>')
    $buf.Add('</section>')

    # ========== 5 LOCAL MODELS =============================================================
    $buf.Add('<section class="panel" id="p-local">')
    $buf.Add('<h2>5 &middot; Local Models</h2>')
    if (@($View.LocalModels).Count -eq 0) {
        $buf.Add('<p class="note">No local models are catalogued. LOCAL is NOT FREE: an unknown local cost is LOCAL_COST_UNKNOWN, never a fabricated zero.</p>')
    } else {
        $buf.Add('<p class="note">LOCAL is NOT FREE. A local route without a cost record surfaces LOCAL_COST_UNKNOWN; DB-M28 never implies a zero cost.</p>')
        $buf.Add('<table><thead><tr><th>Model</th><th>Provider</th><th>Display</th><th>Local/Remote</th><th>Route</th><th>Enabled</th></tr></thead><tbody>')
        foreach ($lm in @($View.LocalModels)) {
            $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $lm.ModelId) + '</td><td class="mono">' + (ConvertTo-DbM28HtmlEsc $lm.ProviderId) + '</td>
                <td>' + (ConvertTo-DbM28HtmlEsc $lm.DisplayName) + '</td><td>' + (ConvertTo-DbM28HtmlEsc $lm.LocalOrRemote) + '</td>
                <td class="mono">' + (ConvertTo-DbM28HtmlEsc $lm.RouteType) + '</td><td>' + (ConvertTo-DbM28HtmlEsc $lm.Enabled) + '</td></tr>')
        }
        $buf.Add('</tbody></table>')
    }
    $buf.Add('</section>')

    # ========== 6 OPENROUTER / GATEWAY =====================================================
    $buf.Add('<section class="panel" id="p-openrouter">')
    $buf.Add('<h2>6 &middot; OpenRouter / Gateway Models</h2>')
    if (@($View.OpenRouterRoutes).Count -eq 0) {
        $buf.Add('<p class="note">No gateway routes are catalogued yet. The gateway provider (openrouter) is listed separately from any underlying model;
            identities are never collapsed. Gateway routes keep UnderlyingModelId + GatewayProviderId distinct.</p>')
    } else {
        $buf.Add('<p class="note">Gateway provider identity and underlying model identity are preserved separately and never collapsed.</p>')
        $buf.Add('<table><thead><tr><th>Gateway provider</th><th>Underlying model</th><th>Model</th><th>Display</th><th>Enabled</th></tr></thead><tbody>')
        foreach ($o in @($View.OpenRouterRoutes)) {
            $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $o.GatewayProviderId) + '</td>
                <td class="mono">' + (ConvertTo-DbM28HtmlEsc $o.UnderlyingModelId) + '</td>
                <td class="mono">' + (ConvertTo-DbM28HtmlEsc $o.ModelId) + '</td>
                <td>' + (ConvertTo-DbM28HtmlEsc $o.DisplayName) + '</td><td>' + (ConvertTo-DbM28HtmlEsc $o.Enabled) + '</td></tr>')
        }
        $buf.Add('</tbody></table>')
    }
    $buf.Add('</section>')

    # ========== 7 PRICING REFERENCE ========================================================
    $buf.Add('<section class="panel" id="p-pricing">')
    $buf.Add('<h2>7 &middot; Pricing Reference (READ-ONLY)</h2>')
    $buf.Add('<p class="note">Authority: DB-M15. Pricing records are read-only; the effective record + governed status (CURRENT / NEEDS_REVIEW / EXPIRED / MANUAL_OVERRIDE)
        are shown with record id, version window and effective dates. DB-M28 cannot edit pricing; DB-M15 remains the pricing authority.</p>')
    $buf.Add('<table><thead><tr><th>Record id</th><th>Model</th><th>Effective from</th><th>Effective to</th><th>Status</th></tr></thead><tbody>')
    foreach ($pr in @($View.PricingReference.Records)) {
        $st = if ($pr.Status -eq 'CURRENT') { '<span class="badge green">CURRENT</span>' } else { '<span class="badge amber">' + (ConvertTo-DbM28HtmlEsc $pr.Status) + '</span>' }
        $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $pr.PricingRecordId) + '</td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $pr.ModelId) + '</td>
            <td class="mono">' + $(if ($pr.EffectiveFrom) { ConvertTo-DbM28HtmlEsc $pr.EffectiveFrom } else { '&mdash;' }) + '</td>
            <td class="mono">' + $(if ($pr.EffectiveTo) { ConvertTo-DbM28HtmlEsc $pr.EffectiveTo } else { '&mdash;' }) + '</td><td>' + $st + '</td></tr>')
    }
    $buf.Add('</tbody></table>')
    $buf.Add('</section>')

    # ========== 8 ROUTING ELIGIBILITY ======================================================
    $buf.Add('<section class="panel" id="p-eligibility">')
    $buf.Add('<h2>8 &middot; Routing Eligibility Summary</h2>')
    $buf.Add('<p class="note">Reuses the real DB-M19 <span class="mono">Test-AiModelCapabilityFit</span> gate READ-ONLY (availability pass + standard coding/tool-use capability pass).
        States: ' + ((@($View.EligibilitySummary.States)) -join ', ') + '. <strong>Hard capability gates can NOT be overridden by an enable/disable toggle.</strong>
        Staging a toggle updates this preview; CONFIGURATION_INCOMPLETE reflects provider Configured / secret / local-endpoint readiness.</p>')
    $buf.Add('<table><thead><tr><th>Model</th><th>Provider</th><th>State</th><th>First reason</th><th>Reasons</th><th>Config ok</th><th>Toggle-fixable</th><th>Hard gate</th></tr></thead><tbody>')
    foreach ($m in @($View.Models)) {
        $stCls = Get-DbM28HtmlStateClass $m.EligibilityState
        $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $m.ModelId) + '</td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $m.ProviderId) + '</td>
            <td class="' + $stCls + '" data-elig="' + (ConvertTo-DbM28HtmlEsc $m.ModelId) + '">' + (ConvertTo-DbM28HtmlEsc $m.EligibilityState) + '</td>
            <td class="mono">' + $(if ($m.EligibilityFirstReason) { ConvertTo-DbM28HtmlEsc $m.EligibilityFirstReason } else { '&mdash;' }) + '</td>
            <td class="mono">' + $(if (@($m.EligibilityReasons).Count -gt 0) { ConvertTo-DbM28HtmlEsc ((@($m.EligibilityReasons)) -join ', ') } else { '&mdash;' }) + '</td>
            <td>' + $(if ($m.EligibilityConfigIncomplete) { '<span class="badge amber">incomplete</span>' } else { '<span class="badge green">ok</span>' }) + '</td>
            <td>' + $(if ($m.EligibilityToggleFixable) { '<span class="tag on">toggle can fix</span>' } else { '<span class="tag off">no</span>' }) + '</td>
            <td>' + $(if ($m.EligibilityHardCapabilityGate) { '<span class="badge red">HARD</span>' } else { '<span class="badge green">none</span>' }) + '</td></tr>')
    }
    $buf.Add('</tbody></table>')
    $buf.Add('<p class="note"><strong>Hard capability override: NO.</strong> A capability-incompatible model stays CAPABILITY_MISMATCH (or its DB-M19 reason) even when enabled;
        an enablement toggle only ever clears MODEL_DISABLED / PROVIDER_DISABLED, and only when configuration is complete.</p>')
    $buf.Add('</section>')

    # ========== 9 HEALTH STATUS ============================================================
    $buf.Add('<section class="panel" id="p-health">')
    $buf.Add('<h2>9 &middot; Health Status (READ-ONLY)</h2>')
    $buf.Add('<p class="note">Source: ' + (ConvertTo-DbM28HtmlEsc $View.HealthStatus.Source) + ' (optional DB-M22 effective-health snapshot; with no snapshot, health is honestly UNKNOWN).
        DB-M28 does NOT measure health and provides NO control to mark a provider healthy, reset a circuit breaker, clear an auth error or force a failover.
        Health is consumed READ-ONLY by the DB-M19 eligibility pass.</p>')
    $buf.Add('<table><thead><tr><th>Provider</th><th>Health state</th><th>Circuit</th><th>Last checked (UTC)</th><th>From snapshot</th></tr></thead><tbody>')
    foreach ($h in @($View.HealthStatus.Rows)) {
        $hCls = switch ($h.HealthState) { 'AVAILABLE' { 'green' } 'AUTH_ERROR' { 'red' } 'UNAVAILABLE' { 'red' } 'DISABLED' { 'red' } default { 'amber' } }
        $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $h.ProviderId) + '</td>
            <td><span class="badge ' + $hCls + '">' + (ConvertTo-DbM28HtmlEsc $h.HealthState) + '</span></td>
            <td class="mono">' + (ConvertTo-DbM28HtmlEsc $h.CircuitState) + '</td>
            <td class="mono">' + $(if ($h.LastCheckedUtc) { ConvertTo-DbM28HtmlEsc $h.LastCheckedUtc } else { '&mdash;' }) + '</td>
            <td>' + $(if ($h.FromSnapshot) { '<span class="tag on">yes</span>' } else { '<span class="tag unk">no</span>' }) + '</td></tr>')
    }
    $buf.Add('</tbody></table>')
    $buf.Add('</section>')

    # ========== 10 SECURITY / SECRET STATUS ================================================
    $buf.Add('<section class="panel" id="p-secret">')
    $buf.Add('<h2>10 &middot; Security / Secret Status</h2>')
    $buf.Add('<p class="note"><strong>Secret values displayed: NO.</strong> SecretReference is an env-var NAME only. Status is derived from the referenced variable being PRESENT
        and the provider marked configured. The UI never renders, copies or logs a secret value; secrets stay in the existing secret-resolution system.</p>')
    $buf.Add('<table><thead><tr><th>Provider</th><th>Secret reference (NAME)</th><th>Status</th><th>Configured</th></tr></thead><tbody>')
    foreach ($s in @($View.SecretStatus.Rows)) {
        $secCls = switch ($s.SecretStatus) { 'CONFIGURED' { 'green' } 'NO_SECRET_REQUIRED' { 'green' } 'INVALID_CONFIGURATION' { 'red' } default { 'amber' } }
        $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $s.ProviderId) + '</td>
            <td class="mono">' + $(if ($s.SecretReference) { ConvertTo-DbM28HtmlEsc $s.SecretReference } else { '&mdash;' }) + '</td>
            <td><span class="badge ' + $secCls + '">' + (ConvertTo-DbM28HtmlEsc $s.SecretStatus) + '</span></td>
            <td>' + $(if ($s.Configured) { '<span class="tag on">configured</span>' } else { '<span class="tag unk">NOT configured</span>' }) + '</td></tr>')
    }
    $buf.Add('</tbody></table>')
    $buf.Add('</section>')

    # ========== COST ESTIMATE & AUDIT ======================================================
    $buf.Add('<section class="panel" id="p-cost">')
    $buf.Add('<h2>VIEW COST ESTIMATE &middot; Configuration Audit</h2>')
    $buf.Add('<p class="note">Cost authority: DB-M16 via the DB-M27 calculator (consumed READ-ONLY). DB-M28 contains no cost formula and cannot edit budget policy.
        Budget context is informational only &mdash; override capability: NO. The audit log records NON-SECRET old/new state per configuration change.</p>')
    $ce = $View.CostEstimate
    if ($ce.Available) {
        $buf.Add('<div class="card"><h2 style="font-size:13px">Reference estimate &mdash; ' + (ConvertTo-DbM28HtmlEsc $ce.ProviderId) + ' / ' + (ConvertTo-DbM28HtmlEsc $ce.ModelId) + ' / ' + (ConvertTo-DbM28HtmlEsc $ce.RouteType) + ' / ' + (ConvertTo-DbM28HtmlEsc $ce.ReasoningLevel) + '</h2>')
        $buf.Add('<div class="kv">
            <span class="k">Estimated cost</span><span class="mono">' + $(if ($null -eq $ce.Estimate.EstimatedCost) { 'n/a' } else { (ConvertTo-DbM28HtmlEsc $ce.Estimate.EstimatedCost) + ' ' + (ConvertTo-DbM28HtmlEsc $ce.Estimate.TargetCurrency) }) + '</span>
            <span class="k">Calculation status</span><span class="mono">' + (ConvertTo-DbM28HtmlEsc $ce.Estimate.CalculationStatus) + '</span>
            <span class="k">Pricing record</span><span class="mono">' + $(if ($ce.Pricing.PricingRecordId) { ConvertTo-DbM28HtmlEsc $ce.Pricing.PricingRecordId } else { '&mdash;' }) + '</span>
            <span class="k">Pricing record status</span><span class="mono">' + (ConvertTo-DbM28HtmlEsc $ce.Pricing.PricingRecordStatus) + '</span>
            <span class="k">Route price status</span><span class="mono">' + (ConvertTo-DbM28HtmlEsc $ce.Pricing.PriceStatus) + '</span>
            <span class="k">Quality evidence</span><span class="mono">' + $(if ($ce.Quality.HasEvidence) { (ConvertTo-DbM28HtmlEsc $ce.Quality.SampleCount) + ' sample(s), confidence ' + (ConvertTo-DbM28HtmlEsc $ce.Quality.ConfidenceLevel) } else { 'no evidence (engine-only estimate)' }) + '</span>
            <span class="k">Budget decision</span><span class="mono">' + (ConvertTo-DbM28HtmlEsc $ce.Budget.Decision) + ' (informational, override NO)</span>
        </div></div>')
    } else {
        $buf.Add('<div class="card"><p class="note">Cost estimate unavailable: ' + (ConvertTo-DbM28HtmlEsc $ce.Error) + '</p></div>')
    }
    $buf.Add('<h2 style="font-size:13px;margin-top:14px">Configuration audit log</h2>')
    if (@($View.AuditLog.Records).Count -eq 0) {
        $buf.Add('<p class="note">No configuration changes recorded yet. The audit log at <span class="mono">state/db-m28-config-changes.json</span> is created on the first operator change (non-secret records only).</p>')
    } else {
        $buf.Add('<table><thead><tr><th>Timestamp (UTC)</th><th>Target</th><th>Field</th><th>Old</th><th>New</th><th>Applied</th></tr></thead><tbody>')
        foreach ($a in @($View.AuditLog.Records)) {
            $buf.Add('<tr><td class="mono">' + (ConvertTo-DbM28HtmlEsc $a.TimestampUtc) + '</td>
                <td class="mono">' + (ConvertTo-DbM28HtmlEsc ($a.TargetType + '/' + $a.TargetId)) + '</td>
                <td class="mono">' + (ConvertTo-DbM28HtmlEsc $a.Field) + '</td>
                <td class="mono">' + (ConvertTo-DbM28HtmlEsc $a.OldValue) + '</td>
                <td class="mono">' + (ConvertTo-DbM28HtmlEsc $a.NewValue) + '</td>
                <td>' + $(if ($a.Applied) { '<span class="tag on">yes</span>' } else { '<span class="tag off">no</span>' }) + '</td></tr>')
        }
        $buf.Add('</tbody></table>')
    }
    $buf.Add('<h2 style="font-size:13px;margin-top:14px">Staged configuration changes (preview payload)</h2>')
    $buf.Add('<p class="note">Toggles above stage changes. This page performs NO persistence. The payload below is the validated ConfigChangeRequest list the backend
        validated-atomic-audited adapter (Apply-DbM28ConfigChange) applies: validate-before-save, atomic temp+Move-Item, read-back verify, non-secret audit, schema preserved.</p>')
    $buf.Add('<textarea id="applyPayload" readonly spellcheck="false" placeholder="No staged changes."></textarea>')
    $buf.Add('<p class="note">Persistence targets: <span class="mono">' + ((@($View.Persistence.Targets)) -join ', ') + '</span>. Immutable/governed: <span class="mono">' + ((@($View.Persistence.ImmutableTargets)) -join ', ') + '</span>.
        ' + (ConvertTo-DbM28HtmlEsc $View.Persistence.ImmutableLimitation) + '</p>')
    $buf.Add('</section>')

    # ========== guard footer ================================================================
    $buf.Add('<div class="guard"><h3>Read-only guard &mdash; AUTO AI EXECUTION DISABLED</h3>')
    $buf.Add('<ul>
        <li>Auto AI execution enabled: <strong>NO</strong> &middot; provider/model executed: <strong>NO</strong> &middot; paid API calls: <strong>0</strong> &middot; network calls: <strong>0</strong></li>
        <li>Budget policy modified: <strong>NO</strong> &middot; pricing modified: <strong>NO</strong> &middot; provider health modified: <strong>NO</strong> &middot; routing policy modified: <strong>NO</strong></li>
        <li>DB-M19 hard capability checks overridden: <strong>NO</strong> &middot; canonical workbook modified: <strong>NO</strong> &middot; Nexus source modified: <strong>NO</strong> &middot; Git modified: <strong>NO</strong></li>
        <li>Secret values displayed: <strong>NO</strong> &middot; secret values logged: <strong>NO</strong></li>
        <li>Persistence: validated-atomic-audited for <span class="mono">config/providers.json</span> + <span class="mono">config/models.json</span> only; pricing/health/budget/routing remain governed read-only.</li>
    </ul></div>')
    $buf.Add('</main>')

    # ========== JS ===========================================================================
    $buf.Add('<script>')
    $buf.Add('var VIEW = ' + $stateJson + ';')
    $buf.Add(@'
var staged = {};
var HARD = ['CAPABILITY_CODING_MISSING','CAPABILITY_VISION_MISSING','CAPABILITY_TOOL_USE_MISSING',
  'STRUCTURED_OUTPUT_MISSING','REASONING_LEVEL_INSUFFICIENT','CONTEXT_TOO_SMALL','OUTPUT_LIMIT_TOO_SMALL',
  'RELIABILITY_TOO_LOW','PROVIDER_DISALLOWED','MODEL_DISALLOWED','LOCALITY_CONFLICT','BUDGET_EXCEEDED','PROCESSING_TIER_UNSUPPORTED'];
function el(id){ return document.getElementById(id); }
function esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function stateClass(st){ return {ELIGIBLE:'st-eligible',DISABLED:'st-disabled',CONFIGURATION_INCOMPLETE:'st-incomplete',
  CAPABILITY_MISMATCH:'st-capability',PRICING_UNKNOWN:'st-pricing',PROVIDER_UNHEALTHY:'st-unhealthy'}[st]||'st-unknown'; }
function isHard(rs){ return (rs||[]).some(function(r){ return HARD.indexOf(r)>=0; }); }
function computePreview(m){
  var reasons = m.EligibilityReasons || [];
  if (isHard(reasons)) return m.EligibilityState;              // hard gate: never toggle-fixable
  var on = (staged[m.ModelId] !== undefined) ? staged[m.ModelId] : m.Enabled;
  if (!on) return 'DISABLED';
  if (m.EligibilityConfigIncomplete) return 'CONFIGURATION_INCOMPLETE';
  if (reasons.indexOf('PROVIDER_UNAVAILABLE')>=0) return 'PROVIDER_UNHEALTHY';
  if (reasons.indexOf('PRICE_UNAVAILABLE')>=0) return 'PRICING_UNKNOWN';
  return 'ELIGIBLE';
}
function renderElig(){
  VIEW.Models.forEach(function(m){
    var cell = document.querySelector('[data-elig="'+m.ModelId+'"]');
    if (!cell) return;
    var st = computePreview(m);
    cell.textContent = st;
    cell.className = stateClass(st);
  });
}
function refreshPayload(){
  var out = [];
  Object.keys(staged).forEach(function(id){
    if (staged[id] === undefined) return;
    var rec = VIEW.Models.filter(function(m){ return m.ModelId===id; })[0];
    if (rec) out.push({Category:'MODEL',TargetType:'MODEL',TargetId:id,Field:'Enabled',NewValue:staged[id],OperatorAction:'SET'});
  });
  if (out.length===0){ el('applyPayload').value=''; }
  else { el('applyPayload').value = JSON.stringify(out,null,2) + '\n\n// Apply via Apply-DbM28ConfigChange; the adapter validates, writes atomically, read-back-verifies and audits.';
  }
}
document.addEventListener('change', function(e){
  var t = e.target;
  if (t.dataset && (t.dataset.toggle==='model' || t.dataset.toggle==='provider')){
    var id = t.dataset.id, on = t.checked;
    staged[id] = on;
    renderElig();
    refreshPayload();
  }
});
(function(){
  document.querySelectorAll('.tab').forEach(function(btn){
    btn.addEventListener('click', function(){
      document.querySelectorAll('.tab').forEach(function(b){ b.classList.remove('active'); });
      document.querySelectorAll('.panel').forEach(function(p){ p.classList.remove('active'); });
      btn.classList.add('active');
      var p = document.getElementById('p-'+btn.dataset.tab);
      if (p) p.classList.add('active');
    });
  });
  var r = document.getElementById('refTime');
  if (r) r.textContent = VIEW.TimestampUtc;
  renderElig();
})();
'@)
    $buf.Add('</script>')
    $buf.Add('</body></html>')

    $out = $buf -join "`n"
    $leak = Test-DbM28SecretLeak $out
    if ($leak.Leak) {
        throw 'DB-M28 HTML render rejected: secret-leak guard tripped on generated markup.'
    }
    return $out
}

function Export-DbM28ModelConfigurationHtml {
    <#
    .SYNOPSIS
    Write the model-configuration console HTML artifact. THE ONLY library write.
    #>
    param([AllowNull()][object]$View, [string]$OutputPath)
    if (-not $OutputPath) { throw 'OutputPath is required' }
    $html = ConvertTo-DbM28Html -View $View
    [System.IO.File]::WriteAllText($OutputPath, $html, (New-Object System.Text.UTF8Encoding($false)))
    return $OutputPath
}

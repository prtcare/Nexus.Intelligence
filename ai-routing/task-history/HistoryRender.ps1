# HistoryRender.ps1 -- DB-M29 task cost / attempt / escalation history renderer.
#
# Self-contained HTML (inline CSS/JS, embedded JSON) presenting:
#   1. TASK HISTORY -- the brief's 13-field filterable/sortable table.
#   2. ATTEMPT TIMELINE -- per-task complete ordered chain with transition arrows
#      and reason badges, per-attempt cost (actual vs estimated labelled), failure
#      fingerprint, verification, Claude review, cumulative cost.
#   3. WHY FAIL / WHY RETRY / WHY ESCALATE -- consolidated failure + escalation
#      evidence per task.
#   4. READ-ONLY GUARD footer + warnings.
#
# The ONLY write in the library is Export-DbM29TaskHistoryHtml's WriteAllText of
# the operator-requested artifact (the DB-M27/DB-M28 pattern). Every HTML
# emission passes Test-DbM29SecretLeak before return. AUTO_EXECUTION_ENABLED =
# FALSE; 0 paid calls, 0 network calls, no secrets rendered or logged.

. (Join-Path $PSScriptRoot "HistoryContracts.ps1")   # DB-M29 contracts + foundations (READ-ONLY)

function Get-DbM29StyleCss {
    return @'
:root{--bg:#f7f7f5;--card:#ffffff;--ink:#1a1f24;--mut:#6b7280;--line:#e3e1dc;
--ac:#0f766e;--warn:#b45309;--bad:#b91c1c;--good:#15803d;--chip:#eef2ff;
--chipink:#3730a3;--arrow:#9ca3af;}
*{box-sizing:border-box}body{margin:0;font-family:Segoe UI,Roboto,Arial,sans-serif;
background:var(--bg);color:var(--ink);padding:20px}
h1{font-size:20px;margin:0 0 4px}h2{font-size:15px;margin:18px 0 8px;border-bottom:1px solid var(--line);padding-bottom:4px}
.sub{color:var(--mut);font-size:12px;margin-bottom:12px}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600;margin:1px}
.b-ok{background:#dcfce7;color:var(--good)}.b-warn{background:#fef3c7;color:var(--warn)}
.b-bad{background:#fee2e2;color:var(--bad)}.b-neu{background:#f3f4f6;color:#374151}
.b-chip{background:var(--chip);color:var(--chipink)}.b-arrow{background:#e5e7eb;color:var(--mut)}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;margin-bottom:12px}
table{width:100%;border-collapse:collapse;font-size:12px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--mut);font-weight:600;white-space:nowrap;cursor:pointer;user-select:none}
tr:hover td{background:#fbfaf7}.num{text-align:right;font-variant-numeric:tabular-nums}
.guard{margin-top:16px;padding:10px 12px;background:#eef2f7;border:1px solid #d6dee8;border-radius:6px;font-size:12px;color:#334155;line-height:1.6}
.warn{color:var(--warn);font-size:12px;margin:6px 0}
.tl{border-left:3px solid var(--line);padding-left:12px;margin:6px 0 0}
.tnode{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 12px;margin:8px 0}
.tnode.term{border:2px solid var(--good);box-shadow:0 0 0 1px var(--good)}
.tnode.term.badterm{border:2px solid var(--bad);box-shadow:0 0 0 1px var(--bad)}
.tarrow{color:var(--arrow);font-size:12px;padding:2px 0 0 4px;line-height:1.5}
.tarrow .reason{color:#475569}.kv{font-size:11px;color:var(--mut)}.kv b{color:var(--ink);font-weight:600}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:4px 12px;font-size:11px}
.empty{color:var(--mut);font-style:italic}
.ft{color:var(--mut);font-size:11px;margin-top:12px}
#timeline{font-size:12px}
'@
}

function Get-DbM29Js {
    return @'
function esc(s){if(s===null||s===undefined)return '';return String(s).replace(/[&<>"']/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];});}
function inr(v){if(v===null||v===undefined)return '—';return '₹'+(+v).toFixed(2);}
var V=null;
function fmtTs(s){if(!s)return '—';try{return new Date(s).toISOString();}catch(e){return s;}}
function stateBadge(st){if(st==='VERIFIED_SUCCESS')return '<span class="badge b-ok">VERIFIED SUCCESS</span>';
 if(st==='CONTRADICTED')return '<span class="badge b-bad">CONTRADICTED</span>';
 if(st==='MODEL_RETURNED')return '<span class="badge b-warn">MODEL RETURNED</span>';
 if(st==='INCOMPLETE')return '<span class="badge b-neu">INCOMPLETE</span>';
 if(st==='NO_ATTEMPTS')return '<span class="badge b-neu">NO ATTEMPTS</span>';return '';}
function firstBadge(v){if(v==='YES')return '<span class="badge b-ok">YES</span>';
 if(v==='NO')return '<span class="badge b-bad">NO</span>';return '<span class="badge b-neu">UNKNOWN</span>';}
function markerBadge(m){if(!m)return '';if(m==='VERIFIED_SUCCESS')return '<span class="badge b-ok">VERIFIED SUCCESS</span>';
 if(m==='BUDGET_STOP')return '<span class="badge b-warn">BUDGET STOP</span>';
 if(m==='HUMAN_REVIEW')return '<span class="badge b-warn">HUMAN REVIEW</span>';
 if(m==='GOVERNANCE_STOP')return '<span class="badge b-warn">GOVERNANCE STOP</span>';
 if(m==='FAILED_NO_RETRY')return '<span class="badge b-bad">FAILED · NO RETRY</span>';return '';}
function transChip(t){if(!t)return '';if(t==='START')return '<span class="badge b-arrow">START</span>';
 var cls='b-chip';if(t==='CORRECTION_CLAUDE_REVIEW_FIX'||t==='CORRECTION')cls='b-warn';
 if(t==='BUDGET_STOP'||t==='HUMAN_REVIEW'||t==='GOVERNANCE_STOP')cls='b-warn';
 if(t==='FAILED_NO_RETRY')cls='b-bad';return '<span class="badge '+cls+'">'+esc(t.replace(/_/g,' '))+'</span>';}
function renderTable(){
 var rows=V.TaskRows||[];
 var sortBy='TASK_ID',dir=1;
 function key(r){if(sortBy==='TOTAL_COST')return ((r.TotalActualCost||0)+(r.TotalEstimatedCost||0));
  if(sortBy==='ATTEMPT_COUNT')return (r.AttemptCount||0);return (r.TaskId||'');}
 rows.sort(function(a,b){var x=key(a),y=key(b);if(x<y)return -dir;if(x>y)return dir;return 0;});
 var h='<table id="tbl"><thead><tr>'+
  '<th data-s="TASK_ID">Task ID</th><th>Change ID</th><th>Mode</th>'+
  '<th data-s="ATTEMPT_COUNT" class="num">Attempts</th><th class="num">Total actual</th><th class="num">Total est.</th>'+
  '<th>Verified state</th><th>First-attempt</th><th>Final model</th><th>Final provider</th>'+
  '<th class="num">Corr.</th><th class="num">Esc.</th><th class="num">Fail</th></tr></thead><tbody>';
 rows.forEach(function(r){
  h+='<tr data-task="'+esc(r.TaskId)+'"><td>'+esc(r.TaskId||'')+'</td><td>'+esc(r.ChangeId||'')+'</td><td>'+esc(r.Mode||'')+'</td>'+
   '<td class="num">'+(r.AttemptCount||0)+'</td><td class="num">'+inr(r.TotalActualCost)+'</td><td class="num">'+inr(r.TotalEstimatedCost)+'</td>'+
   '<td>'+stateBadge(r.VerifiedState)+'</td><td>'+firstBadge(r.FirstAttemptSuccess)+'</td>'+
   '<td>'+esc(r.FinalModelId||'')+'</td><td>'+esc(r.FinalProviderId||'')+'</td>'+
   '<td class="num">'+(r.CorrectionsCount||0)+'</td><td class="num">'+(r.EscalationsCount||0)+'</td><td class="num">'+(r.FailureCount||0)+'</td></tr>';});
 h+='</tbody></table>';
 document.getElementById('tblwrap').innerHTML=h;
 var ths=document.querySelectorAll('#tbl th[data-s]');
 for(var i=0;i<ths.length;i++)(function(th){th.onclick=function(){
  var k=th.getAttribute('data-s');if(sortBy===k)dir=-dir;else{sortBy=k;dir=1;}renderTable();};})(ths[i]);
 var trows=document.querySelectorAll('#tbl tbody tr[data-task]');
 for(var j=0;j<trows.length;j++)(function(tr){tr.style.cursor='pointer';tr.onclick=function(){showTimeline(tr.getAttribute('data-task'));};})(trows[j]);}
function renderTimeline(r){
 var t='<div class="card"><h2>Attempt timeline — '+esc(r.TaskId||'')+'</h2><div class="sub">Change '+
  esc(r.ChangeId||'—')+' · Mode '+esc(r.Mode||'—')+' · Chain '+esc(r.ChainId||'')+' · '+stateBadge(r.VerifiedState)+
  ' · first attempt '+firstBadge(r.FirstAttemptSuccess)+'</div><div class="grid">'+
  '<span><b>Attempts</b> '+(r.AttemptCount||0)+'</span><span><b>Corrections</b> '+(r.CorrectionsCount||0)+'</span>'+
  '<span><b>Escalations</b> '+(r.EscalationsCount||0)+'</span><span><b>Failures</b> '+(r.FailureCount||0)+'</span>'+
  '<span><b>Total actual</b> '+inr(r.TotalActualCost)+'</span><span><b>Total estimated</b> '+inr(r.TotalEstimatedCost)+'</span>'+
  '<span><b>Final model</b> '+esc(r.FinalModelId||'')+'</span><span><b>Final provider</b> '+esc(r.FinalProviderId||'')+'</span></div></div>';
 var tl='<div class="card"><div class="tl">';var nodes=r.Timeline||[];
 for(var i=0;i<nodes.length;i++){var n=nodes[i];var term=(n.IsTerminal?' term':'')+((n.IsTerminal&&n.TerminalMarker!=='VERIFIED_SUCCESS')?' badterm':'');
  tl+='<div class="tnode'+term+'"><div class="kv"><b>Attempt '+n.Seq+'</b> · '+esc(n.AttemptId||'')+
   ' · '+esc(n.ProviderId||'')+' / '+esc(n.ModelId||'')+(n.GatewayProviderId?' via '+esc(n.GatewayProviderId):'')+
   ' · reasoning '+esc(n.ReasoningLevel||'—')+'</div>';
  tl+='<div>'+stateBadge(n.VerifiedState)+' '+markerBadge(n.TerminalMarker)+
   (n.Result?' <span class="badge b-neu">'+esc(n.Result)+'</span>':'')+
   (n.FailureCategory?' <span class="badge b-bad">'+esc(n.FailureCategory)+'</span>':'')+
   (n.FailureFingerprintId?' <span class="badge b-chip">FP '+esc(n.FailureFingerprintId)+'</span>':'')+
   (n.ClaudeReviewStatus?' <span class="badge b-chip">review '+esc(n.ClaudeReviewStatus)+'</span>':'')+'</div>';
  tl+='<div class="kv">Verification '+esc(n.VerificationResult||'—')+
   ' · cost <b>'+inr(n.CostAmount)+'</b>'+(n.CostSource?' ('+esc(n.CostSource)+')':'')+
   ' · cumulative '+inr(n.CumulativeCost)+
   ' · actual '+inr(n.ActualCost)+' / est '+inr(n.EstimatedCost)+
   (n.InputTokens!==null?' · in '+n.InputTokens:'')+(n.OutputTokens!==null?' · out '+n.OutputTokens:'')+
   (n.DurationMs!==null?' · '+n.DurationMs+'ms':'')+'</div>';
  var fpf=n.FailureFingerprint;
  if(fpf){tl+='<div class="kv">Fingerprint '+esc(fpf.FingerprintId||'')+
   (fpf.Signature?' · sig '+esc(String(fpf.Signature).slice(0,16))+'…':'')+
   (fpf.RecurrenceType?' · '+esc(fpf.RecurrenceType):'')+
   (fpf.NormalizedFailureCodes&&fpf.NormalizedFailureCodes.length?' · '+esc(fpf.NormalizedFailureCodes.join(',')):'')+'</div>';}
  var tr=n.Transition;
  if(tr){var rc=(tr.ReasonCodes||[]).join(', ');
   tl+='<div class="tarrow">&#8595; '+transChip(tr.Type)+(tr.Action?' · <b>'+esc(tr.Action)+'</b>':'')+
   (rc?' · <span class="reason">'+esc(rc)+'</span>':'')+
   (tr.Explanation?' · '+esc(tr.Explanation):'')+
   (tr.DecisionId?' · decision '+esc(tr.DecisionId):'')+
   (tr.RequiresHuman?' · <span class="badge b-warn">HUMAN</span>':'')+'</div>';}
  (n.Warnings||[]).forEach(function(w){tl+='<div class="kv warn">'+esc(w)+'</div>';});
  tl+='</div>';}
 tl+='</div></div>';t+=tl;
 t+='<div class="card"><h2>Why it failed · why retried · why escalated</h2>';
 var items=[];nodes.forEach(function(n){if(n.FailureCategory){items.push('<div>· '+esc(n.AttemptId||'')+' failed: '+esc(n.FailureCategory)+(n.FailureFingerprintId?' (FP '+esc(n.FailureFingerprintId)+')':'')+'</div>');}
  var tr=n.Transition;if(tr&&tr.Type!=='START'&&(tr.ReasonCodes||[]).length){items.push('<div>· '+esc(n.AttemptId||'')+' <b>'+esc(tr.Type.replace(/_/g,' '))+'</b> — '+esc((tr.ReasonCodes||[]).join(', '))+(tr.Explanation?' ('+esc(tr.Explanation)+')':'')+'</div>');}});
 if(items.length){t+='<div class="kv">'+items.join('')+'</div>';}else{t+='<div class="empty">No failure or escalation evidence recorded.</div>';}
 t+='</div>';return t;}
function showTimeline(taskId){var row=null;(V.TaskRows||[]).forEach(function(r){if((r.TaskId||'')===taskId)row=r;});
 document.getElementById('timeline').innerHTML=row?renderTimeline(row):'<div class="empty">Select a task row above.</div>';}
function load(data){V=data;
 var w=document.getElementById('warnings');w.innerHTML=(V.Warnings||[]).map(function(x){return '<div class="warn">'+esc(x)+'</div>';}).join('');
 renderTable();showTimeline('');}
'@
}

function ConvertTo-DbM29Html {
    <#
    .SYNOPSIS
    Render a TaskHistoryView v1 to a self-contained HTML page. Marker strings are
    carried in the output and asserted by the test suite. Every emission passes
    Test-DbM29SecretLeak before return.
    #>
    param(
        [AllowNull()][object]$View,
        [string]$Title = 'DevBridge Task Cost · Attempt & Escalation History'
    )
    $json = ConvertTo-Json -InputObject $View -Depth 12
    $count = [int](Get-ContractProperty $View 'Count' 0)
    $empty = [bool](Get-ContractProperty $View 'Empty' $true)
    $viewCurrency = [string](Get-ContractProperty $View 'Currency' 'INR')
    $viewSd = [string](Get-ContractProperty $View 'SuccessDefinition' 'VERIFIED')
    $viewGenerated = [string](Get-ContractProperty $View 'GeneratedAtUtc' '')

    $css = Get-DbM29StyleCss
    $js = Get-DbM29Js

    $emptyRow = ''
    if ($empty) { $emptyRow = '<tr><td colspan="13"><span class="empty">No attempt history recorded.</span></td></tr>' }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$Title</title>
<style>$css</style>
</head>
<body>
<h1>DevBridge Task Cost · Attempt &amp; Escalation History</h1>
<div class="sub">Temporary DevBridge scaffolding for Nexus Phase 1/2 · NOT part of Nexus · display only</div>
<div class="guard"><b>AUTO AI EXECUTION DISABLED · attempts executed: NO · paid calls 0 · network calls 0.</b>
Attempt-history database: NONE · DB-M17 attempt store consumed READ-ONLY.
Secret values displayed: NO. Secret values logged: NO.
Task rows: $count · Currency $viewCurrency · Success definition $viewSd</div>
<div id="warnings"></div>
<h2>Task history</h2>
<div class="card" id="tblwrap">
<table>
<thead><tr>
<th>Task ID</th><th>Change ID</th><th>Mode</th><th class="num">Attempts</th>
<th class="num">Total actual</th><th class="num">Total est.</th><th>Verified state</th>
<th>First-attempt</th><th>Final model</th><th>Final provider</th>
<th class="num">Corr.</th><th class="num">Esc.</th><th class="num">Fail</th>
</tr></thead>
<tbody>$emptyRow</tbody>
</table>
</div>
<h2>Attempt timeline</h2>
<div id="timeline"><span class="empty">Select a task row above to see its complete attempt timeline.</span></div>
<div class="ft">Generated $viewGenerated · $Title · read-only · no AI execution · no paid or network calls</div>
<script>
var DATA = $json;
$js
load(DATA);
</script>
</body>
</html>
"@
    $lv = Test-DbM29SecretLeak $html
    if ($lv.Leak) { throw ("DB-M29 renderer rejected secret-like value in output: " + ($lv.Fields -join '; ')) }
    return $html
}

function Export-DbM29TaskHistoryHtml {
    <#
    .SYNOPSIS
    Render the task-history UI and write the operator-requested HTML artifact.
    The library itself performs no other writes. Returns the output path.
    #>
    param(
        [AllowNull()][object]$View,
        [string]$OutputPath,
        [string]$Title = 'DevBridge Task Cost · Attempt & Escalation History'
    )
    if (-not $OutputPath) { throw 'OutputPath is required' }
    $html = ConvertTo-DbM29Html -View $View -Title $Title
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $html, $utf8NoBom)
    return (Get-Item $OutputPath).FullName
}

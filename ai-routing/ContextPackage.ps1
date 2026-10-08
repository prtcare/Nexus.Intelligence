# =============================================================================
# ContextPackage.ps1
# DB-M18 — Task Classification + Context Package Foundation (Lane B, AI Routing)
#
# Builds the smallest authoritative context package for a governed DevBridge task
# WITHOUT sending the whole repository/workbook/history to every model. It owns:
#   * ContextBudget v1 planning (deterministic reduction, one estimator)
#   * ContextPackage v1 construction + stable hash
#   * Context section assembly from governed metadata (mandatory first)
#   * Secret protection: suspicious content is excluded and replaced with a marker
#     plus a warning (never packaged); reuses the DB-M17/DB-M14 secret guards.
#
# HARD CONSTRAINTS (DB-M18 brief, preserved):
#   * DETERMINISTIC reduction only — no AI summarizer, no model call.
#   * Mandatory context (task identity, goal, acceptance criteria, reserved scope,
#     mandatory ADRs, explicit blockers, required report format) is NEVER dropped;
#     it can only be excerpted (large file) or reported as an explicit budget
#     failure (EXCEEDS / INSUFFICIENT_BUDGET).
#   * Token estimates are approximate and labeled EstimatedTokens (chars/4).
#   * DB-M14 / DB-M17 contracts are READ via dot-source, never modified. No
#     provider names or model selection anywhere (ADR-005).
#   * No Set-StrictMode in this library (the test suite sets it).
# =============================================================================

. (Join-Path $PSScriptRoot "AiRoutingContracts.ps1")    # DB-M14 vocabularies + shared helpers (READ-ONLY)
. (Join-Path $PSScriptRoot "AttemptStore.ps1")          # DB-M17 secret guard (READ-ONLY)
. (Join-Path $PSScriptRoot "TaskClassification.ps1")    # DB-M18 estimator + helpers (READ-ONLY)

# -----------------------------------------------------------------------------
# Primitive helpers
# -----------------------------------------------------------------------------
function Get-DbM18Sha256Hex {
    <#
    .SYNOPSIS
    SHA-256 hex digest of a UTF-8 string (stable package hash building block).
    #>
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Get-DbM18RedactionMarker {
    param([string]$Kind = 'section')
    if ($Kind -eq 'file') { return '[redacted: file content withheld - secret-like content detected]' }
    return '[redacted: section content excluded - secret-like content detected by the DB-M18 secret guard]'
}

function Get-DbM18Excerpt {
    <#
    .SYNOPSIS
    Truncate long text deterministically, marking the omitted tail so readers know
    reduction happened (excerpts are never silent).
    #>
    param([AllowNull()][string]$Text, [int]$MaxChars = 12000)
    if ($null -eq $Text) { return $null }
    if ($Text.Length -le $MaxChars) { return $Text }
    return $Text.Substring(0, $MaxChars) + "`n...[excerpted: $($Text.Length - $MaxChars) chars omitted]..."
}

# -----------------------------------------------------------------------------
# Secret protection (reuses DB-M17 + DB-M14 guards, adds embedded-token scan)
# -----------------------------------------------------------------------------
function Test-DbM18SecretText {
    <#
    .SYNOPSIS
    Detect secret-like content in free text. Reuses the DB-M17 attempt guard and
    the DB-M14 shared guard (both scan free text), then adds an embedded-token scan
    because the anchored guards only match WHOLE values (the S25 lesson).
    #>
    param([AllowNull()][string]$Text)
    if ($null -eq $Text -or $Text.Length -lt 8) { return $false }
    try {
        $attempt = Test-AiAttemptSecretLeak -Target $Text
        if ($attempt.Leak) { return $true }
    } catch { }
    try {
        $shared = Test-AiRoutingSecretValueLeak -Target $Text
        if ($shared.Leak) { return $true }
    } catch { }
    # embedded-token scan (anchored guards miss tokens inside a sentence)
    foreach ($p in @('sk-[A-Za-z0-9_-]{8,}', 'AIza[0-9A-Za-z_-]{10,}', 'gh[pousr]_[A-Za-z0-9]{20,}', '-----BEGIN')) {
        if ($Text -match $p) { return $true }
    }
    # generic high-entropy base64-ish run embedded in prose; requires + or = so
    # URLs/paths (which use '/') and plain alphanumeric hashes do not false-positive
    if ($Text -match '[A-Za-z0-9+=_-]{32,}') {
        $tok = $Matches[0]
        if ($tok -match '[+=]') { return $true }
    }
    # inline credential assignment anywhere in the text
    if ($Text -match '(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*\S') { return $true }
    return $false
}

# -----------------------------------------------------------------------------
# Context section constructor
# -----------------------------------------------------------------------------
function New-DbM18ContextSection {
    <#
    .SYNOPSIS
    One candidate context section with its (estimated) token count. Long content is
    flagged IsLargeFile so the budget planner can excerpt it rather than drop it.
    #>
    param(
        [string]$SectionId,
        [AllowNull()][string]$Title,
        [string]$Priority = 'OPTIONAL',
        [string]$ContentType = 'TEXT',
        [AllowNull()][string]$Content,
        [Nullable[long]]$Tokens,
        [bool]$IsLargeFile = $false
    )
    $tokens = if ($null -ne $Tokens) { [long]$Tokens } else { Get-EstimatedTokenCount $Content }
    $isLarge = $IsLargeFile
    if (-not $isLarge -and $null -ne $Content -and $Content.Length -gt 12000) { $isLarge = $true }
    return [pscustomobject]@{
        SectionId   = $SectionId
        Title       = $Title
        Priority    = $Priority
        ContentType = $ContentType
        Content     = $Content
        Tokens      = [long]$tokens
        IsLargeFile = $isLarge
    }
}

# -----------------------------------------------------------------------------
# Mandatory context sections (never dropped)
# -----------------------------------------------------------------------------
function New-DbM18TaskIdentitySection {
    param([AllowNull()][pscustomobject]$Task)
    $nodeId = Get-DbM18First @((Get-ContractProperty $Task 'nodeId' $null), (Get-ContractProperty $Task 'taskId' $null))
    $taskId = Get-DbM18First @((Get-ContractProperty $Task 'taskId' $null), $nodeId)
    $changeId = Get-DbM18First @((Get-ContractProperty $Task 'changeId' $null), 'none recorded')
    $nodeType = [string](Get-ContractProperty $Task 'nodeType' $null)
    $phase = [string](Get-ContractProperty $Task 'phase' $null)
    $layer = [string](Get-ContractProperty $Task 'layer' $null)
    $gate = [string](Get-ContractProperty $Task 'gate' $null)
    $parent = Get-DbM18First @((Get-ContractProperty $Task 'parentNodeId' $null), (Get-ContractProperty $Task 'currentWorkNodeId' $null))
    $feature = [string](Get-ContractProperty $Task 'featureNodeId' $null)
    $status = [string](Get-ContractProperty $Task 'status' $null)
    $verdict = Get-DbM18First @((Get-ContractProperty $Task 'preflightVerdict' $null), (Get-ContractProperty $Task 'verdict' $null))
    $content = @(
        'Task Identity',
        "Node ID: $nodeId",
        "Task ID: $taskId",
        "Change ID: $changeId",
        "Node Type: $nodeType  |  Phase: $phase  |  Layer: $layer  |  Gate: $gate",
        "Parent / Current Work: $parent  |  Feature: $feature",
        "Status: $status  |  Preflight verdict: $verdict"
    ) -join "`n"
    return New-DbM18ContextSection -SectionId 'task_identity' -Title 'Task Identity' -Priority 'MANDATORY' -ContentType 'TEXT' -Content $content
}

function New-DbM18GoalSection {
    param([AllowNull()][pscustomobject]$Task)
    $goal = Get-DbM18First @((Get-ContractProperty $Task 'goal' $null), (Get-ContractProperty $Task 'outcomePurpose' $null), (Get-ContractProperty $Task 'outcomePurposeText' $null))
    $content = if ($goal) { "Goal / Outcome-Purpose`n$goal" }
               else { "Goal / Outcome-Purpose`n(No goal is recorded in the governed metadata for this task.)" }
    return New-DbM18ContextSection -SectionId 'goal' -Title 'Goal / Outcome-Purpose' -Priority 'MANDATORY' -ContentType 'TEXT' -Content $content
}

function New-DbM18AcceptanceCriteriaSection {
    param([AllowNull()][pscustomobject]$Task)
    $ac = Get-DbM18First @((Get-ContractProperty $Task 'acceptanceCriteria' $null), (Get-ContractProperty $Task 'acceptanceCriteriaText' $null))
    $content = if ($ac) { "Acceptance Criteria`n$ac" }
               else { "Acceptance Criteria`n(Acceptance criteria are not recorded in the governed metadata for this task. Do NOT invent criteria; report the gap to the requesting lane.)" }
    return New-DbM18ContextSection -SectionId 'acceptance_criteria' -Title 'Acceptance Criteria' -Priority 'MANDATORY' -ContentType 'TEXT' -Content $content
}

function New-DbM18ReservedScopeSection {
    param([AllowNull()][pscustomobject]$Task)
    $repos = Get-DbM18ArrayValue $Task 'repositories'
    $projects = Get-DbM18ArrayValue $Task 'projects'
    $globs = Get-DbM18ArrayValue $Task 'filesGlobs'
    $schemaCtx = Get-DbM18ArrayValue $Task 'schemaContexts'
    $contracts = Get-DbM18ArrayValue $Task 'contractsApis'
    $affected = Get-DbM18ArrayValue $Task 'affectedNodes'
    $risk = [string](Get-ContractProperty $Task 'risk' $null)
    $parallelSafe = [bool](Get-ContractProperty $Task 'parallelSafe' $false)
    $fmt = { param($a) if (@($a).Count -eq 0) { '(none recorded)' } else { @($a) -join ', ' } }
    $content = @(
        'Exact Reserved Scope (must not expand without a governed change)',
        "Repositories: $(& $fmt $repos)",
        "Projects: $(& $fmt $projects)",
        "File globs: $(& $fmt $globs)",
        "Schema contexts: $(& $fmt $schemaCtx)",
        "Contract APIs: $(& $fmt $contracts)",
        "Affected nodes ($(@($affected).Count)): $(@($affected) -join ', ')",
        "Governed risk: $(if ($risk) { $risk } else { 'not recorded' })  |  Parallel-safe: $parallelSafe"
    ) -join "`n"
    return New-DbM18ContextSection -SectionId 'reserved_scope' -Title 'Exact Reserved Scope' -Priority 'MANDATORY' -ContentType 'TEXT' -Content $content
}

function Get-DbM18GoverningAdrs {
    <#
    .SYNOPSIS
    The ADRs that govern this task's chain (GOVERNS / GOVERNS_SUBSTRATE /
    CONSTRAINS relations, or any conflicting ADR). These are mandatory context.
    #>
    param([AllowNull()][pscustomobject]$Task)
    $out = New-Object System.Collections.Generic.List[object]
    $adrList = Get-DbM18ArrayValue $Task 'architectureDecisions'
    foreach ($a in $adrList) {
        $rel = [string](Get-ContractProperty $a 'relation' $null)
        $conf = [bool](Get-ContractProperty $a 'conflict' $false)
        if ($rel -eq 'GOVERNS_SUBSTRATE' -or $rel -eq 'GOVERNS' -or $rel -eq 'CONSTRAINS' -or $conf) {
            $out.Add([pscustomobject]@{ AdrId = [string](Get-ContractProperty $a 'adrId' $null); Relation = $rel; Detail = [string](Get-ContractProperty $a 'detail' $null) })
        }
    }
    return ,@($out.ToArray())   # ',' keeps the empty case a real array (bare 'return @()' emits nothing)
}

function New-DbM18MandatoryAdrSection {
    param([AllowNull()][pscustomobject]$Task)
    $adrs = Get-DbM18GoverningAdrs $Task
    if ($adrs.Count -gt 0) {
        $lines = @('Mandatory Architecture Constraints (ADRs)')
        foreach ($a in $adrs) { $lines += "- $($a.AdrId) ($($a.Relation)): $($a.Detail)" }
        $content = $lines -join "`n"
    } else {
        $content = "Mandatory Architecture Constraints (ADRs)`n(No governing ADRs are recorded for this task's chain.)"
    }
    return New-DbM18ContextSection -SectionId 'mandatory_adrs' -Title 'Mandatory Architecture Constraints (ADRs)' -Priority 'MANDATORY' -ContentType 'TEXT' -Content $content
}

function New-DbM18BlockerSection {
    param([AllowNull()][pscustomobject]$Task)
    $blockers = Get-DbM18ArrayValue $Task 'blockingReasons'
    $content = if ($blockers.Count -gt 0) {
        "Explicit Blockers`n" + ((@($blockers) | ForEach-Object { '- ' + [string]$_ }) -join "`n")
    } else {
        'Explicit Blockers`n(No explicit blockers are recorded for this task.)'
    }
    return New-DbM18ContextSection -SectionId 'blockers' -Title 'Explicit Blockers' -Priority 'MANDATORY' -ContentType 'TEXT' -Content $content
}

function New-DbM18ReportFormatSection {
    param([AllowNull()][pscustomobject]$Task)
    $nodeId = Get-DbM18First @((Get-ContractProperty $Task 'nodeId' $null), (Get-ContractProperty $Task 'taskId' $null))
    $changeId = Get-DbM18First @((Get-ContractProperty $Task 'changeId' $null), 'CHG-????-????-???')
    $content = @"
Required Completion Report Format

The implementing agent MUST return its completion evidence in this exact structure:

IMPLEMENTATION RESULT
Task: $nodeId
Change ID: $changeId
Result: PASS | FAILED | BLOCKED
Files created:
Files modified:
Files deleted:
Scope compliance: YES | NO
Implementation summary:
Acceptance criteria addressed:
  - criterion
  - evidence
Build:
  command:
  result:
Tests:
  command:
  passed:
  failed:
  skipped:
Warnings:
Errors:
Scope expansion required: YES | NO
Known limitations:
Git status:

A self-reported PASS is not final approval; independent verification follows.
"@
    return New-DbM18ContextSection -SectionId 'report_format' -Title 'Required Completion Report Format' -Priority 'MANDATORY' -ContentType 'TEXT' -Content $content
}

# -----------------------------------------------------------------------------
# Optional context sections (dropped before mandatory when budget is tight)
# -----------------------------------------------------------------------------
function New-DbM18OptionalSections {
    <#
    .SYNOPSIS
    The OPTIONAL sections that are derivable from the governed metadata. Sections
    whose source data is absent are simply not emitted (nothing is invented).
    #>
    param([AllowNull()][pscustomobject]$Task)
    $out = New-Object System.Collections.Generic.List[object]
    $deps = Get-DbM18ArrayValue $Task 'dependencies'
    if ($deps.Count -gt 0) {
        $lines = @('Dependencies')
        foreach ($d in $deps) {
            $lines += "- $([string](Get-ContractProperty $d 'dependencyId' $null)) [$([string](Get-ContractProperty $d 'state' $null))]: $([string](Get-ContractProperty $d 'detail' $null))"
        }
        $out.Add((New-DbM18ContextSection -SectionId 'dependencies' -Title 'Dependencies' -Priority 'OPTIONAL' -ContentType 'TEXT' -Content ($lines -join "`n")))
    }

    $selection = [string](Get-ContractProperty $Task 'selectionReason' $null)
    $scopeEvidence = Get-DbM18ArrayValue $Task 'scopeEvidence'
    if ($selection -or $scopeEvidence.Count -gt 0) {
        $lines = @('Why This Task Is Current')
        if ($selection) { $lines += "Selection reason: $selection" }
        if ($scopeEvidence.Count -gt 0) {
            $lines += 'Scope evidence:'
            foreach ($e in $scopeEvidence) { $lines += '  - ' + [string]$e }
        }
        $out.Add((New-DbM18ContextSection -SectionId 'why_current' -Title 'Why This Task Is Current' -Priority 'OPTIONAL' -ContentType 'TEXT' -Content ($lines -join "`n")))
    }

    $decisions = Get-DbM18ArrayValue $Task 'openDecisions'
    $nonBlocking = @($decisions | Where-Object { -not [bool](Get-ContractProperty $_ 'blocking' $false) })
    if ($nonBlocking.Count -gt 0) {
        $lines = @('Open Decisions (non-blocking)')
        foreach ($d in $nonBlocking) { $lines += "- $([string](Get-ContractProperty $d 'decisionId' $null)): $([string](Get-ContractProperty $d 'detail' $null))" }
        $out.Add((New-DbM18ContextSection -SectionId 'open_decisions' -Title 'Open Decisions (non-blocking)' -Priority 'OPTIONAL' -ContentType 'TEXT' -Content ($lines -join "`n")))
    }

    # chain-relevant audit findings only (constrains, or names an affected node)
    $findings = Get-DbM18ArrayValue $Task 'auditFindings'
    $affected = Get-DbM18ArrayValue $Task 'affectedNodes'
    $chainFindings = New-Object System.Collections.Generic.List[object]
    foreach ($f in $findings) {
        $cls = [string](Get-ContractProperty $f 'classification' $null)
        $detail = [string](Get-ContractProperty $f 'detail' $null)
        $relevant = $false
        foreach ($id in $affected) { if ($detail -and $id -and $detail.Contains([string]$id)) { $relevant = $true; break } }
        if ($cls -eq 'constrains' -or $relevant) { $chainFindings.Add($f) }
    }
    if ($chainFindings.Count -gt 0) {
        $lines = @('Audit Findings (constraining / chain-relevant)')
        foreach ($f in $chainFindings) { $lines += "- $([string](Get-ContractProperty $f 'findingId' $null)) ($([string](Get-ContractProperty $f 'severity' $null))/$([string](Get-ContractProperty $f 'classification' $null))): $([string](Get-ContractProperty $f 'detail' $null))" }
        $out.Add((New-DbM18ContextSection -SectionId 'audit_findings' -Title 'Audit Findings (constraining / chain-relevant)' -Priority 'OPTIONAL' -ContentType 'TEXT' -Content ($lines -join "`n")))
    }

    # actionable existing assets only (REUSE / REUSE_EXTEND / MISSING)
    $assets = Get-DbM18ArrayValue $Task 'existingAssets'
    $actionable = @($assets | Where-Object { $c = [string](Get-ContractProperty $_ 'classification' $null); $c -in @('REUSE','REUSE_EXTEND','MISSING') })
    if ($actionable.Count -gt 0) {
        $lines = @('Existing Assets (actionable)')
        foreach ($a in $actionable) { $lines += "- $([string](Get-ContractProperty $a 'asset' $null)) [$([string](Get-ContractProperty $a 'classification' $null))]: $([string](Get-ContractProperty $a 'detail' $null))" }
        $out.Add((New-DbM18ContextSection -SectionId 'existing_assets' -Title 'Existing Assets (actionable)' -Priority 'OPTIONAL' -ContentType 'TEXT' -Content ($lines -join "`n")))
    }

    $toolIntegration = Get-ContractProperty $Task 'toolIntegration' $null
    if ($null -ne $toolIntegration) {
        $lines = @('Tool & Integration Context')
        $obs = Get-ContractProperty $toolIntegration 'observations' @()
        foreach ($o in $obs) { $lines += 'Observation: ' + [string]$o }
        $tools = Get-ContractProperty $toolIntegration 'phase1RequiredTools' @()
        if (@($tools).Count -gt 0) { $lines += 'Phase-1 required tools: ' + (@($tools) -join ', ') }
        $lines += 'New tool approval requested: ' + [bool](Get-ContractProperty $toolIntegration 'newToolApprovalRequested' $false)
        $out.Add((New-DbM18ContextSection -SectionId 'tool_integration' -Title 'Tool & Integration Context' -Priority 'OPTIONAL' -ContentType 'TEXT' -Content ($lines -join "`n")))
    }

    $repoGovernance = Get-ContractProperty $Task 'repositoryGovernance' $null
    if ($null -ne $repoGovernance) {
        $lines = @('Repository Governance')
        $lines += 'Source: ' + [string](Get-ContractProperty $repoGovernance 'source' $null)
        $lim = [string](Get-ContractProperty $repoGovernance 'limitation' $null)
        if ($lim) { $lines += "Limitation: $lim" }
        $out.Add((New-DbM18ContextSection -SectionId 'repository_governance' -Title 'Repository Governance' -Priority 'OPTIONAL' -ContentType 'TEXT' -Content ($lines -join "`n")))
    }

    $repoStates = Get-DbM18ArrayValue $Task 'repositoryStates'
    if ($repoStates.Count -gt 0) {
        $rs = $repoStates[0]
        $lines = @('Git Baseline')
        $lines += 'Repository: ' + [string](Get-ContractProperty $rs 'repository' $null)
        $lines += 'Branch: ' + [string](Get-ContractProperty $rs 'branch' $null)
        $head = [string](Get-ContractProperty $rs 'headCommit' $null)
        if ($head) { $lines += "Head commit: $head" }
        $subj = [string](Get-ContractProperty $rs 'headSubject' $null)
        if ($subj) { $lines += "Head subject: $subj" }
        $lines += 'Git repo: ' + [bool](Get-ContractProperty $rs 'isGitRepo' $false) + '  |  Dirty: ' + [bool](Get-ContractProperty $rs 'dirty' $false)
        $out.Add((New-DbM18ContextSection -SectionId 'git_baseline' -Title 'Git Baseline' -Priority 'OPTIONAL' -ContentType 'TEXT' -Content ($lines -join "`n")))
    }

    $adrs = Get-DbM18ArrayValue $Task 'architectureDecisions'
    $nonGoverning = @($adrs | Where-Object { $rel = [string](Get-ContractProperty $_ 'relation' $null); $rel -eq 'NOT_APPLICABLE' -or $rel -eq 'INFORMATIONAL' })
    if ($nonGoverning.Count -gt 0) {
        $lines = @('Architecture Decisions (non-binding)')
        foreach ($a in $nonGoverning) { $lines += "- $([string](Get-ContractProperty $a 'adrId' $null)) ($([string](Get-ContractProperty $a 'relation' $null))): $([string](Get-ContractProperty $a 'detail' $null))" }
        $out.Add((New-DbM18ContextSection -SectionId 'architecture_decisions_nonbinding' -Title 'Architecture Decisions (non-binding)' -Priority 'OPTIONAL' -ContentType 'TEXT' -Content ($lines -join "`n")))
    }

    return ,@($out.ToArray())   # ',' keeps the empty case a real array
}

# -----------------------------------------------------------------------------
# Low-value context sections (dropped first)
# -----------------------------------------------------------------------------
function New-DbM18HistorySection {
    <#
    .SYNOPSIS
    The AI-attempt history as one compact, already-reduced section (LOW_VALUE:
    dropped before OPTIONAL when the budget is tight).
    #>
    param(
        [AllowNull()][string]$SummaryText,
        [AllowNull()][object[]]$AttemptRecords
    )
    if ($SummaryText) {
        return New-DbM18ContextSection -SectionId 'history' -Title 'AI Attempt History' -Priority 'LOW_VALUE' -ContentType 'TEXT' -Content $SummaryText
    }
    $recs = @()
    if ($null -ne $AttemptRecords) { $recs = @($AttemptRecords) }
    if ($recs.Count -gt 0) {
        $success = @($recs | Where-Object { [string](Get-ContractProperty $_ 'Result' $null) -eq 'SUCCESS' }).Count
        $nonSuccess = $recs.Count - $success
        $ids = @($recs | ForEach-Object { [string](Get-ContractProperty $_ 'AttemptId' $null) } | Where-Object { $_ })
        $text = "Prior AI attempts for this change: $($recs.Count) total ($success success, $nonSuccess non-success). Attempt ids: $($ids -join ', ')"
        return New-DbM18ContextSection -SectionId 'history' -Title 'AI Attempt History' -Priority 'LOW_VALUE' -ContentType 'TEXT' -Content $text
    }
    return New-DbM18ContextSection -SectionId 'history' -Title 'AI Attempt History' -Priority 'LOW_VALUE' -ContentType 'TEXT' -Content 'No prior AI attempts are recorded for this change.'
}

function New-DbM18SourceReferencesSection {
    param([AllowNull()][pscustomobject]$Task)
    $refs = Get-DbM18ArrayValue $Task 'sourceReferences'
    $content = 'Source References`n' + ((@($refs) | ForEach-Object { '  - ' + [string]$_ }) -join "`n")
    return New-DbM18ContextSection -SectionId 'source_references' -Title 'Source References' -Priority 'LOW_VALUE' -ContentType 'TEXT' -Content $content
}

# -----------------------------------------------------------------------------
# File context (relevant files only; binary/generated/out-of-scope rejected)
# -----------------------------------------------------------------------------
function Test-DbM18GlobMatch {
    <#
    .SYNOPSIS
    Match a relative path (forward slashes) against a single glob pattern that may
    contain '**' (any depth), '*' (within a segment) and '?' (one char).
    #>
    param([AllowNull()][string]$Path, [AllowNull()][string]$Pattern)
    if (-not $Path -or -not $Pattern) { return $false }
    $p = $Path -replace '\\','/'
    $pat = $Pattern -replace '\\','/'
    $regex = [regex]::Escape($pat)
    $regex = $regex -replace '\\\*\\\*', '.*'
    $regex = $regex -replace '\\\*', '[^/]*'
    $regex = $regex -replace '\\\?', '[^/]'
    $regex = '^' + $regex + '$'
    return ($p -match $regex)
}

function Test-DbM18FileInScope {
    param([AllowNull()][string]$Path, [AllowNull()][string[]]$Globs)
    $rel = $Path -replace '\\','/'
    foreach ($g in @($Globs)) {
        if (Test-DbM18GlobMatch -Path $rel -Pattern $g) { return $true }
    }
    return $false
}

function Test-DbM18IsTextFile {
    <#
    .SYNOPSIS
    Reject binary and generated files so they are never packaged: binary
    extensions, build/output directory segments, generated artifacts, and the
    governed workbook.
    #>
    param([AllowNull()][string]$Path)
    if (-not $Path) { return $false }
    $p = ($Path -replace '\\','/').ToLowerInvariant()
    $ext = [System.IO.Path]::GetExtension($p).ToLowerInvariant()
    $binaryExts = @('.xlsx','.xls','.doc','.docx','.pdf','.dll','.exe','.pdb','.png','.jpg','.jpeg','.gif','.ico','.bmp','.zip','.7z','.gz','.tar','.sqlite','.db','.bin','.obj','.cache','.nupkg','.suo','.wav','.mp3','.mp4','.excel')
    if ($binaryExts -contains $ext) { return $false }
    foreach ($seg in @('/bin/','/obj/','/node_modules/','/.git/','/packages/','/testresults/','/binaries/','/.vs/')) { if ($p.Contains($seg)) { return $false } }
    foreach ($gen in @('.generated.cs','.designer.cs','.assemblyinfo.cs','.user','.generated.xaml')) { if ($p.Contains($gen)) { return $false } }
    if ($p -like '*nexus_development_control*.xlsx') { return $false }
    return $true
}

function New-DbM18FileContextSections {
    <#
    .SYNOPSIS
    Build LOW_VALUE per-file context sections: only files matching the reserved
    file globs, that are text files, and that survive secret scanning. Deterministic
    ordering (sorted by path).
    #>
    param(
        [AllowNull()][hashtable]$FileContextMap,
        [AllowNull()][string]$FileContextRoot,
        [AllowNull()][string[]]$FileGlobs,
        [int]$ExcerptChars = 12000
    )
    $result = New-Object System.Collections.Generic.List[object]
    $globs = @($FileGlobs)
    if ($null -ne $FileContextMap) {
        foreach ($path in ($FileContextMap.Keys | Sort-Object)) {
            $rel = [string]$path
            if (-not (Test-DbM18FileInScope -Path $rel -Globs $globs)) { continue }
            if (-not (Test-DbM18IsTextFile -Path $rel)) { continue }
            $content = [string]$FileContextMap[$path]
            if ($content -and (Test-DbM18SecretText $content)) { $content = Get-DbM18RedactionMarker 'file' }
            $result.Add((New-DbM18ContextSection -SectionId ("file:" + $rel) -Title ("File: " + $rel) -Priority 'LOW_VALUE' -ContentType 'CODE' -Content $content))
        }
    } elseif ($FileContextRoot -and (Test-Path -LiteralPath $FileContextRoot)) {
        $rootFull = (Resolve-Path -LiteralPath $FileContextRoot).Path
        foreach ($file in @(Get-ChildItem -LiteralPath $FileContextRoot -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $rel = $file.FullName.Substring($rootFull.Length).TrimStart('\','/') -replace '\\','/'
            if (-not (Test-DbM18FileInScope -Path $rel -Globs $globs)) { continue }
            if (-not (Test-DbM18IsTextFile -Path $rel)) { continue }
            $content = [System.IO.File]::ReadAllText($file.FullName)
            if ($content -and (Test-DbM18SecretText $content)) { $content = Get-DbM18RedactionMarker 'file' }
            $result.Add((New-DbM18ContextSection -SectionId ("file:" + $rel) -Title ("File: " + $rel) -Priority 'LOW_VALUE' -ContentType 'CODE' -Content $content))
        }
    }
    return ,@($result.ToArray())   # ',' keeps the empty case a real array
}

# -----------------------------------------------------------------------------
# Section assembly (mandatory first, then optional, then low-value)
# -----------------------------------------------------------------------------
function Get-DbM18ContextSections {
    <#
    .SYNOPSIS
    Assemble the candidate context sections for a governed task, in deterministic
    order: 7 MANDATORY, then the present OPTIONAL sections, then LOW_VALUE (history,
    file context, source references).
    #>
    param(
        [AllowNull()][pscustomobject]$Task,
        [AllowNull()][string]$HistorySummary,
        [AllowNull()][object[]]$AttemptRecords,
        [AllowNull()][hashtable]$FileContextMap,
        [AllowNull()][string]$FileContextRoot,
        [AllowNull()][string[]]$FileGlobs,
        [int]$ExcerptChars = 12000
    )
    if ($null -eq $Task) { throw 'Get-DbM18ContextSections: Task is required' }
    $sections = New-Object System.Collections.Generic.List[object]
    $sections.Add((New-DbM18TaskIdentitySection $Task))
    $sections.Add((New-DbM18GoalSection $Task))
    $sections.Add((New-DbM18AcceptanceCriteriaSection $Task))
    $sections.Add((New-DbM18ReservedScopeSection $Task))
    $sections.Add((New-DbM18MandatoryAdrSection $Task))
    $sections.Add((New-DbM18BlockerSection $Task))
    $sections.Add((New-DbM18ReportFormatSection $Task))
    $optSections = New-DbM18OptionalSections $Task
    foreach ($o in $optSections) { $sections.Add($o) }
    $sections.Add((New-DbM18HistorySection -SummaryText $HistorySummary -AttemptRecords $AttemptRecords))
    $globs = @()
    if ($null -ne $FileGlobs) { $globs = @($FileGlobs) }
    if ($globs.Count -eq 0) { $globs = Get-DbM18ArrayValue $Task 'filesGlobs' }
    $fileSections = New-DbM18FileContextSections -FileContextMap $FileContextMap -FileContextRoot $FileContextRoot -FileGlobs $globs -ExcerptChars $ExcerptChars
    foreach ($f in $fileSections) { $sections.Add($f) }
    $srcRefs = Get-DbM18ArrayValue $Task 'sourceReferences'
    if ($srcRefs.Count -gt 0) { $sections.Add((New-DbM18SourceReferencesSection $Task)) }
    return ,@($sections.ToArray())
}

# -----------------------------------------------------------------------------
# ContextBudget v1 planning
# -----------------------------------------------------------------------------
function Get-DbM18SectionExcerptTokens {
    <#
    .SYNOPSIS
    The token count of a section's excerpted form (used when a large mandatory file
    must be excerpted to fit). Deterministic approximation when no content is held.
    #>
    param([AllowNull()][object]$Section, [int]$ExcerptChars = 12000)
    $content = Get-ContractProperty $Section 'Content' $null
    if ($null -ne $content) {
        $c = [string]$content
        if ($c.Length -le $ExcerptChars) { return Get-EstimatedTokenCount $c }
        return Get-EstimatedTokenCount (Get-DbM18Excerpt -Text $c -MaxChars $ExcerptChars)
    }
    return ([long][math]::Ceiling($ExcerptChars / 4.0) + 12)
}

function New-ContextBudget {
    <#
    .SYNOPSIS
    Plan how the candidate context sections fit into the available input budget
    (AllowedInputTokens minus ReservedOutputTokens). Deterministic reductions:
      1. EXCERPT large mandatory files if mandatory alone exceeds the budget;
         if even excerpted mandatory cannot fit -> EXCEEDS / INSUFFICIENT_BUDGET.
      2. DROP LOW_VALUE first (history / source refs / per-file context).
      3. DROP OPTIONAL only if still needed.
    Mandatory sections are NEVER dropped.
    #>
    param(
        [AllowNull()][string]$TaskId,
        [AllowNull()][string]$NodeId,
        [AllowNull()][string]$ChangeId,
        [long]$AllowedInputTokens,
        [long]$ReservedOutputTokens = 0,
        [AllowNull()][object[]]$Sections,
        [int]$ExcerptChars = 12000,
        [AllowNull()][string]$BudgetId
    )
    if ($AllowedInputTokens -le 0) { throw 'New-ContextBudget: AllowedInputTokens must be > 0' }
    if ($ReservedOutputTokens -lt 0) { throw 'New-ContextBudget: ReservedOutputTokens must be >= 0' }
    if ($ReservedOutputTokens -ge $AllowedInputTokens) { throw 'New-ContextBudget: ReservedOutputTokens must be less than AllowedInputTokens' }
    $available = [long]$AllowedInputTokens - [long]$ReservedOutputTokens
    if ($available -le 0) { throw 'New-ContextBudget: no input budget remains after reserving output tokens' }

    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($Sections)) {
        $sid = Get-ContractProperty $s 'SectionId' ("sec-" + $plan.Count)
        $priority = [string](Get-ContractProperty $s 'Priority' 'OPTIONAL')
        if ($priority -notin @('MANDATORY','OPTIONAL','LOW_VALUE')) { $priority = 'OPTIONAL' }
        $isLarge = [bool](Get-ContractProperty $s 'IsLargeFile' $false)
        $tokens = [long](Get-ContractProperty $s 'Tokens' 0)
        if ($tokens -le 0) {
            $c = Get-ContractProperty $s 'Content' $null
            if ($null -ne $c) { $tokens = Get-EstimatedTokenCount ([string]$c) }
        }
        $excerptTokens = if ($isLarge) { Get-DbM18SectionExcerptTokens -Section $s -ExcerptChars $ExcerptChars } else { $tokens }
        $plan.Add([pscustomobject]@{
            SectionId     = $sid
            Title         = [string](Get-ContractProperty $s 'Title' $null)
            Priority      = $priority
            ContentType   = [string](Get-ContractProperty $s 'ContentType' 'TEXT')
            Tokens        = $tokens
            ExcerptTokens = $excerptTokens
            IsLargeFile   = $isLarge
            Action        = 'INCLUDE'
            ExcludeReason = $null
        })
    }

    $mandatory = @($plan | Where-Object { $_.Priority -eq 'MANDATORY' })
    $optional  = @($plan | Where-Object { $_.Priority -eq 'OPTIONAL' })
    $lowValue  = @($plan | Where-Object { $_.Priority -eq 'LOW_VALUE' })

    $totalTokens = 0L
    foreach ($p in $plan) { $totalTokens += [long]$p.Tokens }
    $mandatoryTokens = 0L
    foreach ($m in $mandatory) { $mandatoryTokens += [long]$m.Tokens }

    $status = 'FITS'
    $strategy = 'NONE'
    $failure = $null
    $mandatoryNeedsExcerpt = ($mandatoryTokens -gt $available)

    if ($mandatoryNeedsExcerpt) {
        $effMandatory = 0L
        foreach ($m in $mandatory) { $effMandatory += if ($m.IsLargeFile) { [long]$m.ExcerptTokens } else { [long]$m.Tokens } }
        if ($effMandatory -gt $available) {
            $status = 'EXCEEDS'
            $strategy = 'INSUFFICIENT_BUDGET'
            $failure = "mandatory context requires $effMandatory tokens even after excerpting large files; available input budget is $available tokens"
            foreach ($p in $plan) { $p.Action = 'EXCLUDE'; $p.ExcludeReason = $failure }
        } else {
            foreach ($m in $mandatory) { if ($m.IsLargeFile) { $m.Action = 'EXCERPT'; $m.ExcludeReason = 'large mandatory file excerpted to fit budget' } }
            $status = 'REDUCED'
            $strategy = 'EXCERPT_LARGE_MANDATORY_FILES'
            $mandatoryTokens = $effMandatory
        }
    }

    if ($status -ne 'EXCEEDS') {
        $optTokens = 0L
        foreach ($o in $optional) { $optTokens += [long]$o.Tokens }
        $lvTokens = 0L
        foreach ($l in $lowValue) { $lvTokens += [long]$l.Tokens }
        $fitsAll = (($mandatoryTokens + $optTokens + $lvTokens) -le $available)
        if ($fitsAll -and -not $mandatoryNeedsExcerpt) {
            $status = 'FITS'
            $strategy = 'NONE'
        } else {
            $status = 'REDUCED'
            foreach ($l in $lowValue) { $l.Action = 'EXCLUDE'; $l.ExcludeReason = 'low-value context (history / source refs / per-file context) dropped first to fit budget' }
            if (($mandatoryTokens + $optTokens) -gt $available) {
                foreach ($o in $optional) { $o.Action = 'EXCLUDE'; $o.ExcludeReason = 'optional context dropped after low-value to fit budget' }
                $strategy = 'DROP_OPTIONAL_AND_LOW_VALUE'
            } else {
                $strategy = if ($mandatoryNeedsExcerpt) { 'EXCERPT_LARGE_MANDATORY_FILES_AND_DROP_LOW_VALUE' } else { 'DROP_LOW_VALUE' }
            }
        }
    }

    $selectedTokens = 0L
    foreach ($p in $plan) {
        if ($p.Action -eq 'INCLUDE')      { $selectedTokens += [long]$p.Tokens }
        elseif ($p.Action -eq 'EXCERPT')  { $selectedTokens += [long]$p.ExcerptTokens }
    }
    $reductionRequired = ($status -ne 'FITS')
    $reductionPercent = 0
    if ($totalTokens -gt 0) { $reductionPercent = [int][math]::Floor((($totalTokens - $selectedTokens) * 100.0) / $totalTokens) }

    return [pscustomobject]@{
        SchemaVersion          = 1
        BudgetId               = if ($BudgetId) { $BudgetId } else { 'BUD-' + $(if ($TaskId) { $TaskId } else { 'UNKNOWN' }) }
        TaskId                 = $TaskId
        NodeId                 = $NodeId
        ChangeId               = $ChangeId
        AllowedInputTokens     = $AllowedInputTokens
        ReservedOutputTokens   = $ReservedOutputTokens
        AvailableInputTokens   = $available
        BudgetStatus           = $status
        Strategy               = $strategy
        Failure                = $failure
        TotalTokens            = $totalTokens
        SelectedContextTokens  = $selectedTokens
        ReductionRequired      = $reductionRequired
        ReductionPercent       = $reductionPercent
        ExcerptChars           = $ExcerptChars
        Sections               = @($plan.ToArray())
    }
}

function Test-ContextBudget {
    <#
    .SYNOPSIS
    Structural validation for a ContextBudget v1 record.
    #>
    param([AllowNull()][pscustomobject]$Budget)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Budget) { return @{ Valid = $false; Errors = @('Budget is null'); Warnings = @() } }
    if ((Get-ContractProperty $Budget 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    $allowed = [long](Get-ContractProperty $Budget 'AllowedInputTokens' 0)
    $reserved = [long](Get-ContractProperty $Budget 'ReservedOutputTokens' 0)
    $selected = [long](Get-ContractProperty $Budget 'SelectedContextTokens' 0)
    if ($allowed -le 0) { $errors.Add('AllowedInputTokens must be > 0') }
    if ($reserved -lt 0) { $errors.Add('ReservedOutputTokens must be >= 0') }
    if ($reserved -ge $allowed -and $allowed -gt 0) { $errors.Add('ReservedOutputTokens must be less than AllowedInputTokens') }
    if ($selected -lt 0) { $errors.Add('SelectedContextTokens must be >= 0') }
    if ($allowed -gt 0 -and $selected -gt ($allowed - $reserved)) { $errors.Add("SelectedContextTokens ($selected) exceed available budget ($($allowed - $reserved))") }
    $status = [string](Get-ContractProperty $Budget 'BudgetStatus' $null)
    if ($status -notin @('FITS','REDUCED','EXCEEDS')) { $errors.Add("BudgetStatus '$status' invalid") }
    if ($status -eq 'EXCEEDS' -and -not (Get-ContractProperty $Budget 'Failure' $null)) { $errors.Add('EXCEEDS budget must carry an explicit Failure reason') }
    if ($status -ne 'EXCEEDS') {
        foreach ($p in @(Get-ContractProperty $Budget 'Sections' @())) {
            if ([string](Get-ContractProperty $p 'Priority' $null) -eq 'MANDATORY' -and [string](Get-ContractProperty $p 'Action' $null) -eq 'EXCLUDE') {
                $errors.Add("MANDATORY section '$([string](Get-ContractProperty $p 'SectionId' $null))' cannot be excluded")
            }
        }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# -----------------------------------------------------------------------------
# ContextPackage v1 construction + stable hash
# -----------------------------------------------------------------------------
function Build-ContextPackage {
    <#
    .SYNOPSIS
    Apply a ContextBudget plan to the candidate sections and produce a
    ContextPackage v1: sections marked for inclusion are sanitized (secret guard),
    excerpted sections are truncated deterministically, and a stable SHA-256 hash
    is computed over the fixed-order payload (GeneratedAtUtc excluded so identical
    content hashes identically). An EXCEEDS budget produces an explicit FAILED
    package, never a silently truncated one.
    #>
    param(
        [AllowNull()][pscustomobject]$Task,
        [AllowNull()][pscustomobject]$Classification,
        [AllowNull()][pscustomobject]$Budget,
        [AllowNull()][object[]]$Sections,
        [int]$ExcerptChars = 12000,
        [AllowNull()][string]$PackageId,
        [AllowNull()][string]$GeneratedAtUtc,
        [AllowNull()][string]$DevelopmentControlRole
    )
    if ($null -eq $Budget) { throw 'Build-ContextPackage: Budget is required' }
    $candidateSections = @()
    if ($null -ne $Sections) { $candidateSections = @($Sections) }
    if ($candidateSections.Count -eq 0) { throw 'Build-ContextPackage: Sections is required' }

    $taskId = Get-DbM18First @((Get-ContractProperty $Budget 'TaskId' $null), (Get-ContractProperty $Task 'taskId' $null), 'UNKNOWN')
    $nodeId = Get-DbM18First @((Get-ContractProperty $Budget 'NodeId' $null), (Get-ContractProperty $Task 'nodeId' $null), $taskId)
    $changeId = Get-DbM18First @((Get-ContractProperty $Budget 'ChangeId' $null), (Get-ContractProperty $Task 'changeId' $null))

    # --- Work Universe (role-scope) derivation, additive (Lane G) -------------
    # The context package carries the scope it belongs to. An explicit
    # -DevelopmentControlRole override wins; otherwise the (already role-scoped)
    # classification / task / budget id is honored; V1 bare ids default to
    # Foundation (the Forge's role). Additive output keys only: the hashed payload
    # is NOT extended, so existing PackageHash values are unchanged.
    $workUniverseRole = $DevelopmentControlRole
    if (-not (Test-DbM18DevelopmentControlRole -Role $workUniverseRole)) {
        $workUniverseRole = Get-ContractProperty $Classification 'WorkUniverse' $null
    }
    if (-not (Test-DbM18DevelopmentControlRole -Role $workUniverseRole)) {
        $workUniverseRole = Get-DbM18RoleOfNodeReference $nodeId
    }
    if (-not (Test-DbM18DevelopmentControlRole -Role $workUniverseRole)) {
        $workUniverseRole = Get-DbM18RoleOfNodeReference $taskId
    }
    if (-not (Test-DbM18DevelopmentControlRole -Role $workUniverseRole)) {
        $workUniverseRole = (Get-DbM18WorkUniverseDefault)
    }
    $workUniverse = Get-DbM18WorkUniverse $workUniverseRole
    $nodeAddress  = ConvertTo-DbM18NodeAddress -Role $workUniverse -Id $nodeId

    $plan = @{}
    foreach ($bsec in @(Get-ContractProperty $Budget 'Sections' @())) {
        $sid = [string](Get-ContractProperty $bsec 'SectionId' $null)
        if ($sid) { $plan[$sid] = $bsec }
    }

    $out = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $dropped = New-Object System.Collections.Generic.List[string]
    $markerFile = Get-DbM18RedactionMarker 'file'
    $markerSection = Get-DbM18RedactionMarker 'section'

    foreach ($s in $candidateSections) {
        $sid = [string](Get-ContractProperty $s 'SectionId' $null)
        $bsec = $null
        if ($sid -and $plan.ContainsKey($sid)) { $bsec = $plan[$sid] }
        $action = if ($bsec) { [string](Get-ContractProperty $bsec 'Action' 'INCLUDE') } else { 'INCLUDE' }
        $reason = if ($bsec) { Get-ContractProperty $bsec 'ExcludeReason' $null } else { $null }

        $content = Get-ContractProperty $s 'Content' $null
        $tokens = [long](Get-ContractProperty $s 'Tokens' 0)
        if ($tokens -le 0 -and $null -ne $content) { $tokens = Get-EstimatedTokenCount ([string]$content) }
        $priority = [string](Get-ContractProperty $s 'Priority' 'OPTIONAL')
        $contentType = [string](Get-ContractProperty $s 'ContentType' 'TEXT')
        $title = [string](Get-ContractProperty $s 'Title' $null)
        $included = $true

        if ($action -eq 'EXCLUDE') {
            $included = $false
            $dropped.Add($sid)
        }
        elseif ($action -eq 'EXCERPT' -and $null -ne $content) {
            $content = Get-DbM18Excerpt -Text ([string]$content) -MaxChars $ExcerptChars
            $tokens = Get-EstimatedTokenCount $content
        }

        $isMarker = ($null -ne $content) -and (($content -eq $markerFile) -or ($content -eq $markerSection))
        if ($included -and $null -ne $content) {
            if (-not $isMarker -and (Test-DbM18SecretText ([string]$content))) {
                $content = $markerSection
                $tokens = Get-EstimatedTokenCount $content
                $warnings.Add("Section '$sid' contained secret-like content; the suspicious content was excluded and replaced with a redaction marker.")
                $isMarker = $true
            }
            if ($isMarker) {
                $warnings.Add("Section '$sid' content is withheld (secret-like content detected); it is not present in the context package.")
            }
        }

        $out.Add([pscustomobject]@{
            SectionId     = $sid
            Title         = $title
            Priority      = $priority
            ContentType   = $contentType
            Content       = $content
            Tokens        = $tokens
            Included      = $included
            ExcludeReason = $reason
        })
    }

    $selected = 0L
    foreach ($o in $out) { if ($o.Included) { $selected += [long]$o.Tokens } }

    $budgetStatus = [string](Get-ContractProperty $Budget 'BudgetStatus' 'FITS')
    $packageStatus = if ($budgetStatus -eq 'EXCEEDS') { 'FAILED' } else { 'OK' }
    $failureReason = Get-ContractProperty $Budget 'Failure' $null
    $packageId = if ($PackageId) { $PackageId } else { 'PKG-' + $taskId }
    $gen = if ($GeneratedAtUtc) { $GeneratedAtUtc } else { (Get-Date).ToUniversalTime().ToString('o') }

    $mandatoryIds = @($out | Where-Object { $_.Priority -eq 'MANDATORY' } | ForEach-Object { $_.SectionId })
    $optionalIds  = @($out | Where-Object { $_.Priority -eq 'OPTIONAL' } | ForEach-Object { $_.SectionId })
    $lowValueIds  = @($out | Where-Object { $_.Priority -eq 'LOW_VALUE' } | ForEach-Object { $_.SectionId })

    $payload = [pscustomobject]@{
        SchemaVersion         = 1
        PackageId             = $packageId
        TaskId                = $taskId
        NodeId                = $nodeId
        ChangeId              = $changeId
        ClassificationId      = Get-ContractProperty $Classification 'ClassificationId' $null
        BudgetId              = Get-ContractProperty $Budget 'BudgetId' $null
        AllowedInputTokens    = Get-ContractProperty $Budget 'AllowedInputTokens' $null
        ReservedOutputTokens  = Get-ContractProperty $Budget 'ReservedOutputTokens' 0
        SelectedContextTokens = $selected
        ReductionRequired     = [bool](Get-ContractProperty $Budget 'ReductionRequired' $false)
        Sections              = @($out.ToArray())
    }
    $hash = Get-DbM18Sha256Hex ($payload | ConvertTo-Json -Depth 40 -Compress)

    return [pscustomobject]@{
        SchemaVersion         = 1
        PackageId             = $packageId
        TaskId                = $taskId
        NodeId                = $nodeId
        ChangeId              = $changeId
        ClassificationId      = Get-ContractProperty $Classification 'ClassificationId' $null
        BudgetId              = Get-ContractProperty $Budget 'BudgetId' $null
        Status                = $packageStatus
        FailureReason         = $failureReason
        AllowedInputTokens    = Get-ContractProperty $Budget 'AllowedInputTokens' $null
        ReservedOutputTokens  = Get-ContractProperty $Budget 'ReservedOutputTokens' 0
        SelectedContextTokens = $selected
        EstimatedTotalTokens  = Get-ContractProperty $Budget 'TotalTokens' 0
        ReductionRequired     = [bool](Get-ContractProperty $Budget 'ReductionRequired' $false)
        ReductionPercent      = Get-ContractProperty $Budget 'ReductionPercent' 0
        Sections              = @($out.ToArray())
        MandatorySectionIds   = $mandatoryIds
        OptionalSectionIds    = $optionalIds
        LowValueSectionIds    = $lowValueIds
        DroppedSectionIds     = @($dropped.ToArray())
        SecretWarnings        = @($warnings.ToArray())
        PackageHash           = $hash
        GeneratedAtUtc        = $gen
        WorkUniverse          = $workUniverse
        DevelopmentControlRole = $workUniverse
        NodeAddress           = $nodeAddress
        Origin                = 'DB-M18 deterministic context packaging; sources are governed task state (read-only), never provider/history blobs'
    }
}

function Test-ContextPackage {
    <#
    .SYNOPSIS
    Structural validation for a ContextPackage v1 record: status, budget invariants,
    mandatory-preservation, secret hygiene, and (optionally) hash recomputation.
    #>
    param([AllowNull()][pscustomobject]$Package, [switch]$RecomputeHash)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Package) { return @{ Valid = $false; Errors = @('Package is null'); Warnings = @() } }
    if ((Get-ContractProperty $Package 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Package 'PackageId' $null)) { $errors.Add('PackageId is required') }
    if (-not (Get-ContractProperty $Package 'TaskId' $null)) { $errors.Add('TaskId is required') }

    $status = [string](Get-ContractProperty $Package 'Status' $null)
    $allowed = Get-ContractProperty $Package 'AllowedInputTokens' $null
    $reserved = [long](Get-ContractProperty $Package 'ReservedOutputTokens' 0)
    $selected = Get-ContractProperty $Package 'SelectedContextTokens' $null
    if ($status -notin @('OK','FAILED')) { $errors.Add("Status '$status' invalid") }
    if ($null -ne $allowed -and $allowed -le 0) { $errors.Add('AllowedInputTokens must be > 0') }
    if ($null -ne $selected -and $selected -lt 0) { $errors.Add('SelectedContextTokens must be >= 0') }
    if ($null -ne $allowed -and $null -ne $selected -and $selected -gt $allowed) { $errors.Add("SelectedContextTokens ($selected) exceed AllowedInputTokens ($allowed)") }

    $sections = @(Get-ContractProperty $Package 'Sections' @())
    $markerFile = Get-DbM18RedactionMarker 'file'
    $markerSection = Get-DbM18RedactionMarker 'section'
    $redactionCount = 0
    foreach ($s in $sections) {
        $sid = [string](Get-ContractProperty $s 'SectionId' $null)
        $included = [bool](Get-ContractProperty $s 'Included' $false)
        $content = Get-ContractProperty $s 'Content' $null
        if ($included -and $null -ne $content) {
            if (($content -eq $markerFile) -or ($content -eq $markerSection)) { $redactionCount++ }
            elseif (Test-DbM18SecretText ([string]$content)) {
                $errors.Add("Included section '$sid' leaks secret-like content")
            }
        }
    }
    if ($status -eq 'OK') {
        foreach ($mid in @(Get-ContractProperty $Package 'MandatorySectionIds' @())) {
            $found = $false
            foreach ($s in $sections) {
                if ([string](Get-ContractProperty $s 'SectionId' $null) -eq $mid) {
                    if ([bool](Get-ContractProperty $s 'Included' $false)) { $found = $true }
                    break
                }
            }
            if (-not $found) { $errors.Add("MANDATORY section '$mid' was dropped") }
        }
    } else {
        if (-not (Get-ContractProperty $Package 'FailureReason' $null)) { $errors.Add('FAILED package must carry a FailureReason') }
    }
    $secretWarnings = @(Get-ContractProperty $Package 'SecretWarnings' @())
    if ($redactionCount -gt 0 -and $secretWarnings.Count -eq 0) { $warnings.Add('Redacted sections present but no SecretWarnings recorded') }
    if ($secretWarnings.Count -gt 0 -and $redactionCount -eq 0) { $warnings.Add('SecretWarnings present but no redacted section found') }

    if ($RecomputeHash) {
        $payload = [pscustomobject]@{
            SchemaVersion         = 1
            PackageId             = Get-ContractProperty $Package 'PackageId' $null
            TaskId                = Get-ContractProperty $Package 'TaskId' $null
            NodeId                = Get-ContractProperty $Package 'NodeId' $null
            ChangeId              = Get-ContractProperty $Package 'ChangeId' $null
            ClassificationId      = Get-ContractProperty $Package 'ClassificationId' $null
            BudgetId              = Get-ContractProperty $Package 'BudgetId' $null
            AllowedInputTokens    = Get-ContractProperty $Package 'AllowedInputTokens' $null
            ReservedOutputTokens  = Get-ContractProperty $Package 'ReservedOutputTokens' 0
            SelectedContextTokens = Get-ContractProperty $Package 'SelectedContextTokens' $null
            ReductionRequired     = [bool](Get-ContractProperty $Package 'ReductionRequired' $false)
            Sections              = $sections
        }
        $recomputed = Get-DbM18Sha256Hex ($payload | ConvertTo-Json -Depth 40 -Compress)
        if ($recomputed -ne [string](Get-ContractProperty $Package 'PackageHash' $null)) { $errors.Add('PackageHash does not match a recomputation over the package payload') }
    }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @($warnings.ToArray()) }
}

# -----------------------------------------------------------------------------
# Package summary (structured + markdown for manual workflow handoff)
# -----------------------------------------------------------------------------
function Get-ContextPackageSummary {
    <#
    .SYNOPSIS
    A compact, UI-discoverable summary of a ContextPackage v1 record (JSON-shaped)
    or, with -AsMarkdown, a human block for the manual workflow handoff documents.
    #>
    param([AllowNull()][pscustomobject]$Package, [switch]$AsMarkdown)
    if ($null -eq $Package) { throw 'Get-ContextPackageSummary: Package is required' }
    $sections = @(Get-ContractProperty $Package 'Sections' @())
    $includedCount = @($sections | Where-Object { [bool](Get-ContractProperty $_ 'Included' $false) }).Count
    $excludedCount = $sections.Count - $includedCount
    $summary = [pscustomobject]@{
        SchemaVersion          = 1
        PackageId              = Get-ContractProperty $Package 'PackageId' $null
        TaskId                 = Get-ContractProperty $Package 'TaskId' $null
        NodeId                 = Get-ContractProperty $Package 'NodeId' $null
        ChangeId               = Get-ContractProperty $Package 'ChangeId' $null
        WorkUniverse           = Get-ContractProperty $Package 'WorkUniverse' $null
        DevelopmentControlRole = Get-ContractProperty $Package 'DevelopmentControlRole' $null
        NodeAddress            = Get-ContractProperty $Package 'NodeAddress' $null
        ClassificationId       = Get-ContractProperty $Package 'ClassificationId' $null
        BudgetId               = Get-ContractProperty $Package 'BudgetId' $null
        Status                 = Get-ContractProperty $Package 'Status' $null
        FailureReason          = Get-ContractProperty $Package 'FailureReason' $null
        AllowedInputTokens     = Get-ContractProperty $Package 'AllowedInputTokens' $null
        ReservedOutputTokens   = Get-ContractProperty $Package 'ReservedOutputTokens' 0
        SelectedContextTokens  = Get-ContractProperty $Package 'SelectedContextTokens' $null
        EstimatedTotalTokens   = Get-ContractProperty $Package 'EstimatedTotalTokens' 0
        ReductionRequired      = [bool](Get-ContractProperty $Package 'ReductionRequired' $false)
        ReductionPercent       = Get-ContractProperty $Package 'ReductionPercent' 0
        SectionCount           = $sections.Count
        IncludedSectionCount   = $includedCount
        ExcludedSectionCount   = $excludedCount
        MandatorySectionIds    = @(Get-ContractProperty $Package 'MandatorySectionIds' @())
        OptionalSectionIds     = @(Get-ContractProperty $Package 'OptionalSectionIds' @())
        LowValueSectionIds     = @(Get-ContractProperty $Package 'LowValueSectionIds' @())
        DroppedSectionIds      = @(Get-ContractProperty $Package 'DroppedSectionIds' @())
        SecretWarningCount     = @(Get-ContractProperty $Package 'SecretWarnings' @()).Count
        PackageHash            = Get-ContractProperty $Package 'PackageHash' $null
        GeneratedAtUtc         = Get-ContractProperty $Package 'GeneratedAtUtc' $null
    }
    if ($AsMarkdown) {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('## Context Package Summary (DB-M18, deterministic)')
        $lines.Add("- Package: $($summary.PackageId)")
        $lines.Add("- Task: $($summary.TaskId)  |  Node: $($summary.NodeId)  |  Change: $($summary.ChangeId)")
        $lines.Add("- Work Universe: $($summary.WorkUniverse)  |  Role: $($summary.DevelopmentControlRole)  |  Address: $($summary.NodeAddress)")
        $lines.Add("- Status: $($summary.Status)  |  Budget: $($summary.BudgetId)")
        if ($summary.FailureReason) { $lines.Add("- Failure: $($summary.FailureReason)") }
        $lines.Add("- Tokens: $($summary.SelectedContextTokens) selected / $($summary.EstimatedTotalTokens) estimated  |  Reserve: $($summary.ReservedOutputTokens)")
        $lines.Add("- Reduction: $($summary.ReductionPercent)% ($($summary.ReductionRequired))")
        $lines.Add("- Sections: $($summary.IncludedSectionCount) included / $($summary.SectionCount) total ($($summary.ExcludedSectionCount) excluded)")
        $lines.Add("- Secret warnings: $($summary.SecretWarningCount)")
        $lines.Add("- Mandatory kept: $($summary.MandatorySectionIds -join ', ')")
        $lines.Add("- Dropped: $($summary.DroppedSectionIds -join ', ')")
        $lines.Add("- Hash: $($summary.PackageHash)")
        return ($lines -join "`n")
    }
    return $summary
}

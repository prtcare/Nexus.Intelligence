# =============================================================================
# TaskClassification.ps1
# DB-M18 — Task Classification + Context Package Foundation (Lane B, AI Routing)
#
# Provides the provider-independent, deterministic-first task classifier for the
# governed DevBridge task lifecycle. It turns a governed task shape into a
# TaskClassification v1 record and derives the DB-M14 CapabilityRequirement v1
# record that future DB-M19 routing will consume.
#
# HARD CONSTRAINTS (DB-M18 brief, preserved):
#   * DETERMINISTIC-FIRST: V1 performs ZERO AI calls. Only values derivable from
#     governed metadata are set; anything else stays null (UNKNOWN).
#   * NO provider names (DeepSeek / Claude / OpenAI / Gemini) and NO model
#     selection anywhere in classification logic (ADR-005).
#   * Does NOT select a winning model, execute AI, calculate final cost, or alter
#     task governance. Cost fields are left null (DB-M16 owns cost math).
#   * DB-M14 frozen contracts (AiRoutingContracts.ps1) are READ via dot-source,
#     never modified. DB-M14's schema registry is untouched; DB-M18 schema
#     versions live in this library's own registry (Get-DbM18SchemaVersions).
#   * No Set-StrictMode in this library (the test suite sets it), matching the
#     DB-M17 AttemptStore.ps1 convention.
# =============================================================================

. (Join-Path $PSScriptRoot "AiRoutingContracts.ps1")   # DB-M14 vocabularies + shared helpers (READ-ONLY)

# -----------------------------------------------------------------------------
# DB-M18 schema version registry (DB-M18-owned; DB-M14 registry NOT modified)
# -----------------------------------------------------------------------------
function Get-DbM18SchemaVersions {
    <#
    .SYNOPSIS
    DB-M18-owned frozen schema versions. TaskClassification v1, ContextBudget v1,
    ContextPackage v1 are frozen at DB-M18; CapabilityRequirement remains DB-M14 v1.
    Incompatible changes require v2 contracts with their own schemaVersion + validator.
    #>
    return [pscustomobject]@{
        TaskClassificationVersion = 1
        ContextBudgetVersion      = 1
        ContextPackageVersion     = 1
        CapabilityRequirementVersion = 1   # frozen DB-M14 v1, reused as-is
    }
}

# -----------------------------------------------------------------------------
# Work Universe context vocabulary (P1-WAVE-04 Lane G, additive). Structural role
# / scope awareness that mirrors the shared Nexus.DevelopmentControl.Contracts
# DevelopmentControlRole { Foundation, Products } and the DevelopmentControlAddress
# "Role:Id" form. The Forge is the Foundation role owner, so an unqualified
# single-workbook id resolves to Foundation (V1 compat); Products is recognized as
# a valid role token (cross-scope) but never guessed for a bare id (no prefix
# inference). Helpers are defined here so ContextPackage.ps1 and DependencyLineage.ps1
# (both dot-source this file transitively) share one vocabulary. No new resolver
# module is created.
# -----------------------------------------------------------------------------
function Get-DbM18DevelopmentControlRoles {
    return @('Foundation', 'Products')
}

function Get-DbM18WorkUniverseDefault {
    return 'Foundation'
}

function Test-DbM18DevelopmentControlRole {
    <#
    .SYNOPSIS
    True when the value is one of the shared DevelopmentControlRole tokens
    (Foundation | Products), case-insensitive.
    #>
    param([AllowNull()][string]$Role)
    if (-not $Role) { return $false }
    foreach ($known in @(Get-DbM18DevelopmentControlRoles)) {
        if ([string]::Equals($Role, $known, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DbM18WorkUniverse {
    <#
    .SYNOPSIS
    Canonical role-scope (Work Universe) name. Recognizes Foundation/Products
    case-insensitively and returns the canonical Pascal spelling; anything absent
    or unknown defaults to Foundation (the Forge's role, V1 single-workbook compat).
    #>
    param([AllowNull()][string]$Role)
    foreach ($known in @(Get-DbM18DevelopmentControlRoles)) {
        if ($Role -and [string]::Equals($Role, $known, [System.StringComparison]::OrdinalIgnoreCase)) { return $known }
    }
    return (Get-DbM18WorkUniverseDefault)
}

function ConvertFrom-DbM18NodeAddress {
    <#
    .SYNOPSIS
    Parse a role-scoped DevelopmentControlAddress string "Role:Id" where Role is a
    recognized role token (Foundation | Products). Returns @{ Role = <canonical>;
    NodeId = <id> } or $null when the string is NOT a recognized role-scoped address
    (a bare node id is the V1/unqualified form and is never an address here).
    #>
    param([AllowNull()][string]$Address)
    if (-not $Address) { return $null }
    $s = [string]$Address
    $idx = $s.IndexOf(':')
    if ($idx -le 0 -or $idx -ge ($s.Length - 1)) { return $null }
    $roleRaw = $s.Substring(0, $idx)
    if (-not (Test-DbM18DevelopmentControlRole -Role $roleRaw)) { return $null }
    return [pscustomobject]@{ Role = (Get-DbM18WorkUniverse $roleRaw); NodeId = $s.Substring($idx + 1) }
}

function Test-DbM18NodeAddress {
    <#
    .SYNOPSIS
    True when the string is a recognized role-scoped address ("Role:Id"). Used by the
    context/lineage scripts to recognize scope-bearing references without guessing a
    role for bare ids.
    #>
    param([AllowNull()][string]$Address)
    return ($null -ne (ConvertFrom-DbM18NodeAddress -Address $Address))
}

function Get-DbM18RoleOfNodeReference {
    <#
    .SYNOPSIS
    The role token of a reference when it is explicitly role-scoped; $null for a bare
    id (never inferred from a prefix).
    #>
    param([AllowNull()][string]$Reference)
    $addr = ConvertFrom-DbM18NodeAddress -Address $Reference
    if ($null -eq $addr) { return $null }
    return [string]$addr.Role
}

function ConvertTo-DbM18NodeAddress {
    <#
    .SYNOPSIS
    Build the canonical role-scoped address "Role:Id" for a node id. An explicit role
    wins; an already-role-scoped id is normalized to its canonical spelling; a bare id
    under an absent role defaults to Foundation (V1 single-workbook compat). Returns
    $null when no id is present.
    #>
    param([AllowNull()][string]$Role, [AllowNull()][string]$Id)
    if (-not $Id) { return $null }
    $role = Get-DbM18WorkUniverse $Role
    $id = [string]$Id
    $existing = ConvertFrom-DbM18NodeAddress -Address $id
    if ($null -ne $existing) { return ($existing.Role + ':' + $existing.NodeId) }
    return ($role + ':' + $id)
}

# -----------------------------------------------------------------------------
# Token estimation (ONE consistent, approximate method for the whole package)
# -----------------------------------------------------------------------------
function Get-EstimatedTokenCount {
    <#
    .SYNOPSIS
    Approximate token estimate: characters / 4, rounded up. Always labeled an
    estimate — never treated as a provider-reported count.
    #>
    param([AllowNull()][string]$Text)
    if ($null -eq $Text -or $Text.Length -eq 0) { return [long]0 }
    $chars = [long]$Text.Length
    return [long][math]::Ceiling($chars / 4.0)
}

# -----------------------------------------------------------------------------
# Small helpers (strict-mode safe)
# -----------------------------------------------------------------------------
function New-DbM18Signal {
    <#
    .SYNOPSIS
    One evidence signal: a named, present-or-absent observation with its evidence text.
    #>
    param([string]$Signal, [bool]$Present, [AllowNull()][string]$Evidence)
    return [pscustomobject]@{ Signal = $Signal; Present = $Present; Evidence = $Evidence }
}

function Get-DbM18First {
    <#
    .SYNOPSIS
    First non-empty value among the given candidates (used to merge overrides and
    governed metadata without string-coercion surprises).
    #>
    param([AllowNull()][object[]]$Candidates)
    foreach ($c in @($Candidates)) {
        if ($null -ne $c) {
            if ($c -is [string]) { if ($c.Trim().Length -gt 0) { return $c } }
            else { return $c }
        }
    }
    return $null
}

function Get-DbM18ArrayValue {
    <#
    .SYNOPSIS
    Read an array-valued property defensively; absent/null -> empty array (never @($null)).
    Reads the property directly rather than via the frozen DB-M14 Get-ContractProperty,
    which returns a single-element array's SCALAR (the array is unrolled on its return
    pipeline), leaving callers with a strict-mode .Count failure. The ',' wrap is required:
    a bare 'return @()' emits NOTHING on the pipeline. ',' emits the (possibly empty)
    array as a single object.
    #>
    param([AllowNull()][object]$Object, [string]$Name)
    if ($null -eq $Object) { return ,@() }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.ContainsKey($Name)) { return ,@() }
        $v = $Object[$Name]
    } else {
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) { return ,@() }
        $v = $prop.Value
    }
    if ($null -eq $v) { return ,@() }
    return ,$v
}

function Test-DbM18KeywordsIn {
    <#
    .SYNOPSIS
    Case-insensitive keyword test over a combined haystack. Returns true when any
    keyword appears as a whole word (or at a token boundary).
    #>
    param([AllowNull()][string]$Haystack, [AllowNull()][string[]]$Keywords)
    if (-not $Haystack -or -not $Keywords) { return $false }
    $h = ' ' + $Haystack.ToLowerInvariant() + ' '
    foreach ($k in $Keywords) {
        if ($k -and $h.Contains(' ' + $k.ToLowerInvariant())) { return $true }
        # also match keyword adjacent to a non-alphanumeric boundary (e.g. "ui-screen", "2fa")
        if ($h -match ("[^a-z0-9]" + [regex]::Escape($k.ToLowerInvariant()))) { return $true }
    }
    return $false
}

function Get-DbM18RiskFromEvidence {
    <#
    .SYNOPSIS
    Derive a Risk level when the preflight did not record a risk field (UNKNOWN must
    stay honest). Returns $null when nothing supports a determination.
    #>
    param([AllowNull()][string]$Verdict, [AllowNull()][object[]]$Conflicts, [AllowNull()][object[]]$BlockingReasons)
    $verdict = $Verdict
    if ($verdict) { $verdict = $verdict.ToUpperInvariant() }
    if ($verdict -eq 'FAIL' -or $verdict -eq 'BLOCKED' -or $verdict -eq 'ERROR') { return 'HIGH' }
    if (@($BlockingReasons).Count -gt 0) { return 'HIGH' }
    foreach ($c in @($Conflicts)) {
        $st = Get-ContractProperty $c 'status' $null
        if ($st) { $st = [string]$st }
        if ($st -eq 'FAIL' -or $st -eq 'BLOCKED' -or $st -eq 'ERROR') { return 'HIGH' }
        if ($st -eq 'WARN') { return 'MEDIUM' }
    }
    return $null
}

function Get-DbM18ContextRequirement {
    <#
    .SYNOPSIS
    ContextRequirement from a weighted, signal-counting score. Thresholds chosen so
    the governed WI-07-0.2.4 fixture (contract + affected-count + code-scope +
    governing-ADR = 4) lands on HIGH.
    #>
    param([int]$Score)
    if ($Score -ge 5) { return 'VERY_HIGH' }
    if ($Score -ge 3) { return 'HIGH' }
    if ($Score -ge 2) { return 'MEDIUM' }
    return 'LOW'
}

# -----------------------------------------------------------------------------
# Governed task loading (read-only merge of state artifacts)
# -----------------------------------------------------------------------------
function Get-DbM18TaskFromState {
    <#
    .SYNOPSIS
    Merge governed task state from the DevBridge state artifacts (current-task /
    preflight / reservation) into one task shape. READ-ONLY: never writes state.
    First file wins for a given property (current-task status overrides the
    preflight snapshot); later files fill gaps only.
    #>
    param(
        [string]$CurrentTaskPath,
        [string]$PreflightPath,
        [string]$ReservationPath
    )
    $merged = [pscustomobject]@{}
    foreach ($path in @($CurrentTaskPath, $PreflightPath, $ReservationPath)) {
        if (-not $path) { continue }
        if (-not (Test-Path -LiteralPath $path)) { throw "Get-DbM18TaskFromState: file not found: $path" }
        $obj = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -eq $obj) { continue }
        foreach ($prop in $obj.PSObject.Properties) {
            if ($null -eq (Get-ContractProperty $merged $prop.Name $null)) {
                $merged | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
            }
        }
    }
    return $merged
}

# -----------------------------------------------------------------------------
# Signal extraction (deterministic; every derivation traces to evidence)
# -----------------------------------------------------------------------------
function Get-DbM18TaskSignals {
    <#
    .SYNOPSIS
    Extract the classification signals from a governed task shape. Returns a
    pscustomobject with the raw signal flags plus Evidence.Signals entries for the
    classification record.
    #>
    param([AllowNull()][pscustomobject]$Task)
    $signals = New-Object System.Collections.Generic.List[object]
    $g = { param($s, $p, $e) $signals.Add((New-DbM18Signal -Signal $s -Present $p -Evidence $e)) }

    $name        = [string](Get-DbM18First @((Get-ContractProperty $Task 'name' $null), (Get-ContractProperty $Task 'taskId' $null)))
    $goal        = [string](Get-ContractProperty $Task 'goal' (Get-ContractProperty $Task 'outcomePurpose' (Get-ContractProperty $Task 'outcomePurposeText' $null)))
    $ac          = [string](Get-ContractProperty $Task 'acceptanceCriteria' (Get-ContractProperty $Task 'acceptanceCriteriaText' $null))
    $nodeType    = [string](Get-ContractProperty $Task 'nodeType' $null)
    $status      = [string](Get-ContractProperty $Task 'status' $null)
    $verdict     = [string](Get-ContractProperty $Task 'preflightVerdict' (Get-ContractProperty $Task 'verdict' $null))
    $selection   = [string](Get-ContractProperty $Task 'selectionReason' $null)
    $riskField   = [string](Get-ContractProperty $Task 'risk' $null)

    $repositories = Get-DbM18ArrayValue $Task 'repositories'
    $projects     = Get-DbM18ArrayValue $Task 'projects'
    $filesGlobs   = Get-DbM18ArrayValue $Task 'filesGlobs'
    $schemaCtx    = Get-DbM18ArrayValue $Task 'schemaContexts'
    $contracts    = Get-DbM18ArrayValue $Task 'contractsApis'
    $affected     = Get-DbM18ArrayValue $Task 'affectedNodes'
    $adrs         = Get-DbM18ArrayValue $Task 'architectureDecisions'
    $findings     = Get-DbM18ArrayValue $Task 'auditFindings'
    $blocking     = Get-DbM18ArrayValue $Task 'blockingReasons'
    $conflicts    = Get-DbM18ArrayValue $Task 'activeChangeConflicts'

    $haystack = ($name + ' ' + $goal + ' ' + $ac + ' ' + $selection + ' ' + $nodeType + ' ' + $status).ToLowerInvariant()

    # --- task-type signals (ordered in Classify-DevBridgeTask) ---
    $sigVerification     = Test-DbM18KeywordsIn $haystack @('verification','verify','test-run','validation pass')
    $sigReview           = Test-DbM18KeywordsIn $haystack @('review','audit','inspection')
    $sigArchitecture     = Test-DbM18KeywordsIn $haystack @('architecture','planning','roadmap','design doc','milestone restructure','restructure')
    $sigGovernance       = Test-DbM18KeywordsIn $haystack @('governance','process','policy','protocol','standards','controls')
    $sigResearch         = Test-DbM18KeywordsIn $haystack @('research','investigate','summariz','analy','discovery','log summary','explore')
    $sigDocumentation    = Test-DbM18KeywordsIn $haystack @('document','readme','write-up','writeup','naming','nomenclature','doc ')
    # ' sql' is space-anchored (like 'db ') so words like "azure-sql-ready" in rich
    # governance text do not false-positive into a SQL/schema signal.
    $sigCode             = Test-DbM18KeywordsIn $haystack @('code','implement','adapter','contract','schema','database','db ',' sql','api','endpoint','service','store','file','class','method','fix','bug','refactor','tests','build')

    # --- code scope signal (governed) ---
    $hasCodeScope = ($filesGlobs.Count -gt 0) -or ($contracts.Count -gt 0) -or ($repositories.Count -gt 0)

    # --- UI signal (vision) ---
    $sigUi = Test-DbM18KeywordsIn $haystack @('ui','interface','screen','front-end','frontend','web page','dashboard','dialog','form','button','window','shell','view ')

    # --- schema signal (structured output + high reasoning) ---
    $hasSchema = ($schemaCtx.Count -gt 0) -or ($sigCode -and (Test-DbM18KeywordsIn $haystack @('schema','migration','table','db ',' sql','database')))

    # --- vision-required overrides for documented UI work ---
    $requiresVision = $null
    if ($sigUi) { $requiresVision = $true; & $g 'ui-signal' $true "Task name/goal references a UI surface ($name)." }

    # --- documentation-only: no code scope AND documentation keyword ---
    $docsOnly = (-not $hasCodeScope) -and $sigDocumentation

    # --- affected-node and multi-repo signals ---
    $sigAffectedMany = ($affected.Count -gt 2)
    $sigMultiRepo    = ($repositories.Count -gt 1)

    # --- governing ADR signal ---
    $governingAdrs = @()
    foreach ($a in $adrs) {
        $rel = [string](Get-ContractProperty $a 'relation' $null)
        $conf = [bool](Get-ContractProperty $a 'conflict' $false)
        if ($rel -eq 'GOVERNS_SUBSTRATE' -or $rel -eq 'GOVERNS' -or $rel -eq 'CONSTRAINS' -or $conf) {
            $governingAdrs += [pscustomobject]@{ AdrId = [string](Get-ContractProperty $a 'adrId' $null); Relation = $rel; Detail = [string](Get-ContractProperty $a 'detail' $null) }
        }
    }
    $hasGoverningAdr = ($governingAdrs.Count -gt 0)

    # --- constraining finding for THIS task chain (only when it names an affected node) ---
    $hasConstrainingFinding = $false
    $affectedIds = @($affected) + @([string](Get-ContractProperty $Task 'nodeId' $null), [string](Get-ContractProperty $Task 'taskId' $null))
    foreach ($f in $findings) {
        $cls = [string](Get-ContractProperty $f 'classification' $null)
        if ($cls -ne 'constrains' -and $cls -ne 'CONSTRAINS') { continue }
        $detail = [string](Get-ContractProperty $f 'detail' (Get-ContractProperty $f 'findingId' $null))
        foreach ($id in $affectedIds) {
            if ($id -and $detail.ToLowerInvariant().Contains($id.ToLowerInvariant())) { $hasConstrainingFinding = $true; break }
        }
        if ($hasConstrainingFinding) { break }
    }

    # --- context-requirement score ---
    $ctxScore = 0
    if ($contracts.Count -gt 0)              { $ctxScore++; & $g 'contract-scope' $true "Capability contract(s) in scope: $($contracts -join ', ')." }
    if ($sigAffectedMany)                    { $ctxScore++; & $g 'affected-node-count' $true "$($affected.Count) affected nodes require broad context." }
    if ($hasCodeScope)                       { $ctxScore++; & $g 'code-scope' $true "Implementation scope present (repos/files/contracts)." }
    if ($hasSchema)                          { $ctxScore++; & $g 'schema-context' $true "Schema context present; structural fidelity required." }
    if ($sigMultiRepo)                       { $ctxScore++; & $g 'multi-repository' $true "Multiple repositories in scope: $($repositories -join ', ')." }
    if ($hasGoverningAdr)                    { $ctxScore++; & $g 'governing-adr' $true "Governing ADR(s): $($governingAdrs.AdrId -join ', ')." }
    if ($hasConstrainingFinding)             { $ctxScore++; & $g 'constraining-finding' $true "An audit finding constrains this task chain." }
    if ($ctxScore -eq 0)                     { & $g 'context-requirement' $false 'No scope signals; minimal context.' }

    & $g 'governed-scope' $hasCodeScope "Reserved scope present in governed metadata; human review applies."
    & $g 'risk-recorded' $true "Preflight risk field: '$riskField' (preserved verbatim when present)."
    if ($blocking.Count -gt 0) { & $g 'blockers' $true "$($blocking.Count) explicit blocker(s) recorded." } else { & $g 'blockers' $false 'No explicit blockers recorded.' }

    return [pscustomobject]@{
        Name             = $name
        Goal             = $goal
        Acceptance       = $ac
        NodeType         = $nodeType
        Status           = $status
        Verdict          = $verdict
        SelectionReason  = $selection
        RiskField        = $riskField
        Repositories     = $repositories
        Projects         = $projects
        FilesGlobs       = $filesGlobs
        SchemaContexts   = $schemaCtx
        ContractsApis    = $contracts
        AffectedNodes    = $affected
        BlockingReasons  = $blocking
        Conflicts        = $conflicts
        GoverningAdrs    = $governingAdrs
        HasGoverningAdr  = $hasGoverningAdr
        HasConstrainingFinding = $hasConstrainingFinding
        ContextScore     = $ctxScore
        RequiresVision   = $requiresVision
        DocsOnly         = $docsOnly
        HasCodeScope     = $hasCodeScope
        HasSchema        = $hasSchema
        SigVerification  = $sigVerification
        SigReview        = $sigReview
        SigArchitecture  = $sigArchitecture
        SigGovernance    = $sigGovernance
        SigResearch      = $sigResearch
        SigDocumentation = $sigDocumentation
        SigCode          = $sigCode
        SigUi            = $sigUi
        SigMultiRepo     = $sigMultiRepo
        Signals          = @($signals.ToArray())
    }
}

# -----------------------------------------------------------------------------
# Classification (deterministic-first)
# -----------------------------------------------------------------------------
function Classify-DevBridgeTask {
    <#
    .SYNOPSIS
    Classify a governed DevBridge task into a TaskClassification v1 record without
    any AI call. Explicit overrides (-Name/-Goal/-AcceptanceCriteria/-ChangeId/...)
    take precedence over governed metadata when supplied; unknown values stay null.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$Task,
        [AllowNull()][string]$TaskId,
        [AllowNull()][string]$NodeId,
        [AllowNull()][string]$ChangeId,
        [AllowNull()][string]$Name,
        [AllowNull()][string]$Goal,
        [AllowNull()][string]$AcceptanceCriteria,
        [AllowNull()][string]$Gate,
        [AllowNull()][string]$ExecutionMode = 'MANUAL',
        [AllowNull()][string]$ClassifiedAtUtc,
        [AllowNull()][string]$ClassifierVersion = 'DB-M18.1.0',
        [AllowNull()][string]$DevelopmentControlRole
    )
    $task = $Task
    $taskId = Get-DbM18First @($TaskId, (Get-ContractProperty $task 'taskId' $null), (Get-ContractProperty $task 'nodeId' $null), 'UNKNOWN')
    $nodeId = Get-DbM18First @($NodeId, (Get-ContractProperty $task 'nodeId' $null), $taskId)
    $changeId = Get-DbM18First @($ChangeId, (Get-ContractProperty $task 'changeId' $null))
    $name = Get-DbM18First @($Name, (Get-ContractProperty $task 'name' $null))
    $goal = Get-DbM18First @($Goal, (Get-ContractProperty $task 'goal' $null), (Get-ContractProperty $task 'outcomePurpose' $null), (Get-ContractProperty $task 'outcomePurposeText' $null))
    $ac   = Get-DbM18First @($AcceptanceCriteria, (Get-ContractProperty $task 'acceptanceCriteria' $null), (Get-ContractProperty $task 'acceptanceCriteriaText' $null))
    $gate = Get-DbM18First @($Gate, (Get-ContractProperty $task 'gate' $null))
    if (-not $ExecutionMode) { $ExecutionMode = 'MANUAL' }   # [string] param coercion guard
    $nodeType    = [string](Get-ContractProperty $task 'nodeType' $null)
    $milestoneId = Get-DbM18First @((Get-ContractProperty $task 'milestoneId' $null), (Get-ContractProperty $task 'currentWorkNodeId' $null), (Get-ContractProperty $task 'parentNodeId' $null))
    $workItemId  = if ($nodeType -eq 'WorkItem') { $taskId } else { $null }

    # --- Work Universe (role-scope) derivation, additive (Lane G) -------------
    # V1 single-workbook compat: a bare governed node id belongs to the Forge's role
    # (Foundation). An explicit -DevelopmentControlRole override wins; an already
    # role-scoped node id is honored verbatim; Products is recognized as a valid
    # role token (cross-scope) but never guessed for a bare id (no prefix inference).
    $workUniverseRole = $DevelopmentControlRole
    if (-not (Test-DbM18DevelopmentControlRole -Role $workUniverseRole)) {
        $workUniverseRole = Get-DbM18RoleOfNodeReference $nodeId
        if (-not (Test-DbM18DevelopmentControlRole -Role $workUniverseRole)) {
            $workUniverseRole = Get-DbM18RoleOfNodeReference $taskId
        }
        if (-not (Test-DbM18DevelopmentControlRole -Role $workUniverseRole)) {
            $workUniverseRole = (Get-DbM18WorkUniverseDefault)
        }
    }
    $workUniverse = Get-DbM18WorkUniverse $workUniverseRole
    $nodeAddress  = ConvertTo-DbM18NodeAddress -Role $workUniverse -Id $nodeId

    $sig = Get-DbM18TaskSignals -Task $task
    $signals = $sig.Signals

    # --- TaskType: ordered keyword rules (first match wins) ---
    $taskType = $null
    $ttEvidence = ''
    if ($sig.SigVerification)          { $taskType = 'VERIFICATION'; $ttEvidence = 'name/goal indicates verification activity' }
    elseif ($sig.SigReview)            { $taskType = 'REVIEW';       $ttEvidence = 'name/goal indicates review/audit activity' }
    elseif ($sig.SigArchitecture)      { $taskType = 'PLANNING';     $ttEvidence = 'name/goal indicates architecture or planning activity' }
    elseif ($sig.SigGovernance)        { $taskType = 'GOVERNANCE';   $ttEvidence = 'name/goal indicates governance/process activity' }
    elseif ($sig.DocsOnly)             { $taskType = 'RESEARCH';     $ttEvidence = 'documentation-only task (no code scope)' }
    elseif ($sig.SigResearch -and -not $sig.SigCode) { $taskType = 'RESEARCH'; $ttEvidence = 'research/summarization activity without code scope' }
    elseif ($sig.SigCode -or $sig.HasCodeScope) { $taskType = 'IMPLEMENTATION'; $ttEvidence = 'implementation/code scope detected' }
    elseif ($sig.SigResearch)          { $taskType = 'RESEARCH';     $ttEvidence = 'research/analysis activity' }
    else                               { $taskType = 'IMPLEMENTATION'; $ttEvidence = 'no stage keyword matched; default to implementation scope' }

    # --- Complexity: LOW base, additive governed signals ---
    $complexity = 'LOW'
    if ($sig.HasCodeScope) { $complexity = 'MEDIUM' }
    if ($sig.ContractsApis.Count -gt 0 -and $complexity -ne 'HIGH') { $complexity = 'MEDIUM' }
    if ($sig.AffectedNodes.Count -gt 2 -and $complexity -ne 'HIGH') { $complexity = 'MEDIUM' }
    if ($sig.HasSchema)    { $complexity = 'HIGH' }
    if ($sig.SigMultiRepo) { $complexity = 'HIGH' }
    if ($sig.Repositories.Count -gt 1) { $complexity = 'HIGH' }
    if ($taskType -eq 'GOVERNANCE')    { $complexity = 'HIGH' }
    if ($sig.SigArchitecture -and $taskType -eq 'PLANNING') { $complexity = 'HIGH' }
    # LOW revert signal: task explicitly names small/simple/minor work
    $lowSignal = Test-DbM18KeywordsIn (($sig.Name + ' ' + $sig.Goal)) @('small','simple','minor','trivial','one-liner','tiny')
    if ($lowSignal -and -not $sig.HasSchema -and $sig.Repositories.Count -le 1) { $complexity = 'LOW' }

    # --- Risk: preserve governed field verbatim; derive only when absent ---
    $risk = $null
    $riskEvidence = ''
    if ($sig.RiskField) {
        $risk = $sig.RiskField.ToUpperInvariant()
        if ($risk -notin @('LOW','MEDIUM','HIGH')) {
            $risk = $null   # governed value outside vocabulary -> do not invent a mapping
            $riskEvidence = "governed risk field '$( $sig.RiskField )' is outside LOW/MEDIUM/HIGH; risk left UNKNOWN"
        } else {
            $riskEvidence = "preflight risk preserved verbatim: $risk"
        }
    }
    if (-not $risk) {
        $risk = Get-DbM18RiskFromEvidence -Verdict $sig.Verdict -Conflicts $sig.Conflicts -BlockingReasons $sig.BlockingReasons
        if ($risk) { $riskEvidence = "risk derived from preflight evidence (verdict/conflicts/blockers): $risk" }
        else       { $riskEvidence = 'no risk signal in governed metadata; risk left UNKNOWN' }
    }

    # --- capability booleans ---
    $requiresCoding = $null
    if ($sig.DocsOnly)      { $requiresCoding = $false }
    elseif ($sig.HasCodeScope) { $requiresCoding = $true }

    $requiresReasoning = $null
    if ($sig.DocsOnly) { $requiresReasoning = $false }
    elseif ($risk -in @('MEDIUM','HIGH') -or $complexity -in @('MEDIUM','HIGH') -or $taskType -in @('PLANNING','GOVERNANCE','VERIFICATION','REVIEW','RESEARCH')) {
        $requiresReasoning = $true
    }

    $requiresStructuredOutput = $null
    if ($sig.ContractsApis.Count -gt 0 -or $sig.HasSchema) { $requiresStructuredOutput = $true }

    $requiresToolUse = $null
    if ($sig.HasCodeScope -or $taskType -in @('PLANNING','GOVERNANCE')) { $requiresToolUse = $true }

    $requiresVision = $sig.RequiresVision

    $humanReviewRequired = $null
    if ($sig.HasCodeScope -or $taskType -in @('GOVERNANCE','PLANNING','VERIFICATION','REVIEW')) { $humanReviewRequired = $true }

    # --- MinimumReasoningLevel (DB-M13 rule: HIGH risk or HIGH complexity => at least HIGH) ---
    $minReasoning = 'NONE'
    $reasoningRuleApplied = $false
    $reasoningRule = ''
    if ($risk -eq 'HIGH' -or $complexity -eq 'HIGH' -or $sig.HasSchema) {
        $minReasoning = 'HIGH'; $reasoningRuleApplied = $true
        $reasoningRule = 'HIGH risk or HIGH complexity (or schema scope) requires at least HIGH reasoning (DB-M13 §2.1)'
    }
    elseif ($taskType -in @('PLANNING','GOVERNANCE')) {
        $minReasoning = 'HIGH'; $reasoningRuleApplied = $true
        $reasoningRule = 'architecture/governance task requires HIGH reasoning'
    }
    elseif ($risk -eq 'MEDIUM' -or $complexity -eq 'MEDIUM') {
        $minReasoning = 'MEDIUM'; $reasoningRuleApplied = $false
        $reasoningRule = 'moderate complexity/risk default'
    }
    elseif ($requiresReasoning) {
        $minReasoning = 'MEDIUM'; $reasoningRuleApplied = $false
        $reasoningRule = 'reasoning-required default (research/verification/review)'
    }

    # --- ContextRequirement (signal-count score) ---
    $contextRequirement = Get-DbM18ContextRequirement -Score $sig.ContextScore

    # --- token planning (approximate, labeled) ---
    $contextTokens = Get-EstimatedTokenCount (($name + ' ' + $goal + ' ' + $ac + ' ' + $sig.SelectionReason + ' ' + ($sig.Repositories -join ', ') + ' ' + ($sig.Projects -join ', ') + ' ' + ($sig.FilesGlobs -join ', ') + ' ' + ($sig.SchemaContexts -join ', ') + ' ' + ($sig.ContractsApis -join ', ') + ' ' + ($sig.AffectedNodes -join ', ')))
    $expectedOutputTokens = [long]2048
    if ($taskType -eq 'VERIFICATION' -or $taskType -eq 'REVIEW') { $expectedOutputTokens = [long]1024 }
    elseif ($taskType -eq 'RESEARCH' -or $taskType -eq 'PLANNING' -or $taskType -eq 'GOVERNANCE') { $expectedOutputTokens = [long]512 }

    # --- ReservedScope snapshot (identity + governed scope, for the package) ---
    $reservedScope = [pscustomobject]@{
        NodeId       = $nodeId
        TaskId       = $taskId
        ChangeId     = $changeId
        Repositories = @($sig.Repositories)
        Projects     = @($sig.Projects)
        FilesGlobs   = @($sig.FilesGlobs)
        SchemaContexts = @($sig.SchemaContexts)
        ContractsApis  = @($sig.ContractsApis)
        AffectedNodes  = @($sig.AffectedNodes)
        GoverningAdrs  = @($sig.GoverningAdrs)
        RiskField      = $sig.RiskField
        Gate           = $gate
        WorkUniverse   = $workUniverse
        DevelopmentControlRole = $workUniverse
        NodeAddress    = $nodeAddress
    }

    $classifiedAt = if ($ClassifiedAtUtc) { $ClassifiedAtUtc } else { (Get-Date).ToUniversalTime().ToString('o') }
    $classificationId = 'CLS-' + $taskId

    $record = [pscustomobject]@{
        SchemaVersion              = 1
        ClassificationId           = $classificationId
        TaskId                     = $taskId
        NodeId                     = $nodeId
        ChangeId                   = $changeId
        WorkUniverse               = $workUniverse
        DevelopmentControlRole     = $workUniverse
        NodeAddress                = $nodeAddress
        WorkItemId                 = $workItemId
        MilestoneId                = $milestoneId
        ClassifiedAtUtc            = $classifiedAt
        ClassificationSource       = 'DETERMINISTIC'
        ClassifierVersion          = $ClassifierVersion
        TaskType                   = $taskType
        Complexity                 = $complexity
        Risk                       = $risk
        RequiresCoding             = $requiresCoding
        RequiresReasoning          = $requiresReasoning
        RequiresVision             = $requiresVision
        RequiresToolUse            = $requiresToolUse
        RequiresStructuredOutput   = $requiresStructuredOutput
        MinimumReasoningLevel      = $minReasoning
        ReasoningRuleApplied       = $reasoningRuleApplied
        ReasoningRule              = $reasoningRule
        ContextRequirement         = $contextRequirement
        LatencyPreference          = 'NORMAL'
        ExecutionMode              = $ExecutionMode
        HumanReviewRequired        = $humanReviewRequired
        RequiredContextTokens      = $contextTokens
        ExpectedOutputTokens       = $expectedOutputTokens
        ReservedScope              = $reservedScope
        Evidence                   = [pscustomobject]@{
            TaskTypeEvidence    = $ttEvidence
            ComplexityEvidence  = "base LOW + governed scope signals (context score $($sig.ContextScore))"
            RiskEvidence        = $riskEvidence
            ReasoningEvidence   = $reasoningRule
            Signals             = @($signals)
        }
    }

    # normalize any '' back to null so UNKNOWN survives serialization
    foreach ($prop in $record.PSObject.Properties) {
        $v = $prop.Value
        if ($null -ne $v -and $v -is [string] -and [string]$v -eq '') { $prop.Value = $null }
    }
    return $record
}

# -----------------------------------------------------------------------------
# DB-M14 CapabilityRequirement derivation (reuse frozen v1; never re-derive)
# -----------------------------------------------------------------------------
function New-CapabilityRequirement {
    <#
    .SYNOPSIS
    Derive the DB-M14 CapabilityRequirement v1 from a TaskClassification record.
    Reuses the frozen DB-M14 constructor and validator. Provider/model lists stay
    empty (ADR-005); MaxAllowedCost stays null (cost is DB-M16's territory).
    #>
    param([AllowNull()][pscustomobject]$Classification)
    if ($null -eq $Classification) { throw "New-CapabilityRequirement: Classification is required" }

    $taskId = Get-ContractProperty $Classification 'TaskId' $null
    $req = New-AiCapabilityRequirement `
        -TaskId $taskId `
        -TaskType (Get-ContractProperty $Classification 'TaskType' $null) `
        -Complexity (Get-ContractProperty $Classification 'Complexity' $null) `
        -Risk (Get-ContractProperty $Classification 'Risk' $null) `
        -RequiresCoding (Get-ContractProperty $Classification 'RequiresCoding' $null) `
        -RequiresReasoning (Get-ContractProperty $Classification 'RequiresReasoning' $null) `
        -MinimumReasoningLevel (Get-ContractProperty $Classification 'MinimumReasoningLevel' $null) `
        -RequiresVision (Get-ContractProperty $Classification 'RequiresVision' $null) `
        -RequiresToolUse (Get-ContractProperty $Classification 'RequiresToolUse' $null) `
        -RequiresStructuredOutput (Get-ContractProperty $Classification 'RequiresStructuredOutput' $null) `
        -RequiredContextTokens (Get-ContractProperty $Classification 'RequiredContextTokens' $null) `
        -ExpectedOutputTokens (Get-ContractProperty $Classification 'ExpectedOutputTokens' $null) `
        -PreferredLatency (Get-ContractProperty $Classification 'LatencyPreference' $null) `
        -HumanReviewRequired (Get-ContractProperty $Classification 'HumanReviewRequired' $null) `
        -ExecutionMode (Get-ContractProperty $Classification 'ExecutionMode' 'MANUAL')

    # DB-M14 [string] params coerce null -> ''; normalize back so UNKNOWN survives
    foreach ($prop in $req.PSObject.Properties) {
        $v = $prop.Value
        if ($null -ne $v -and $v -is [string] -and [string]$v -eq '') { $prop.Value = $null }
    }

    $check = Test-AiCapabilityRequirement $req
    if (-not $check.Valid) {
        throw "New-CapabilityRequirement produced an invalid DB-M14 CapabilityRequirement: $($check.Errors -join '; ')"
    }
    return $req
}

# -----------------------------------------------------------------------------
# Structural validation of a TaskClassification record
# -----------------------------------------------------------------------------
function Test-TaskClassification {
    <#
    .SYNOPSIS
    Structural validation for a TaskClassification v1 record: schema version,
    vocabulary membership, field types, evidence presence.
    #>
    param([AllowNull()][pscustomobject]$Classification)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Classification) { return @{ Valid = $false; Errors = @('Classification is null'); Warnings = @() } }

    if ((Get-ContractProperty $Classification 'SchemaVersion' -1) -ne 1) { $errors.Add("SchemaVersion must be 1 (found $(Get-ContractProperty $Classification 'SchemaVersion' '?'))") }
    if (-not (Get-ContractProperty $Classification 'ClassificationId' $null)) { $errors.Add('ClassificationId is required') }
    if (-not (Get-ContractProperty $Classification 'TaskId' $null)) { $errors.Add('TaskId is required') }
    if ((Get-ContractProperty $Classification 'ClassificationSource' $null) -ne 'DETERMINISTIC') { $errors.Add("ClassificationSource must be DETERMINISTIC (found '$(Get-ContractProperty $Classification 'ClassificationSource' $null)')") }

    foreach ($f in @('TaskType','Complexity','Risk','MinimumReasoningLevel','LatencyPreference','ExecutionMode','ContextRequirement')) {
        $v = Get-ContractProperty $Classification $f $null
        if ($null -eq $v -or ([string]$v).Trim().Length -eq 0) { continue }
        $sv = [string]$v
        switch ($f) {
            'TaskType'             { if (-not (Test-IsValidTaskType $sv)) { $errors.Add("TaskType '$sv' invalid") } }
            'Complexity'           { if ($sv -notin @('LOW','MEDIUM','HIGH')) { $errors.Add("Complexity '$sv' invalid") } }
            'Risk'                 { if ($sv -notin @('LOW','MEDIUM','HIGH')) { $errors.Add("Risk '$sv' invalid") } }
            'MinimumReasoningLevel'{ if (-not (Test-IsValidReasoningLevel $sv)) { $errors.Add("MinimumReasoningLevel '$sv' invalid") } }
            'LatencyPreference'    { if (-not (Test-IsValidRelativeSpeed $sv)) { $errors.Add("LatencyPreference '$sv' invalid (DB-M14 RelativeSpeeds vocabulary)") } }
            'ExecutionMode'        { if (-not (Test-IsValidExecutionMode $sv)) { $errors.Add("ExecutionMode '$sv' invalid") } }
            'ContextRequirement'   { if ($sv -notin @('LOW','MEDIUM','HIGH','VERY_HIGH')) { $errors.Add("ContextRequirement '$sv' invalid") } }
        }
    }

    foreach ($f in @('RequiresCoding','RequiresReasoning','RequiresVision','RequiresToolUse','RequiresStructuredOutput','HumanReviewRequired','ReasoningRuleApplied')) {
        $v = Get-ContractProperty $Classification $f $null
        if ($null -ne $v -and $v -isnot [bool]) { $errors.Add("$f must be bool or null") }
    }
    foreach ($f in @('RequiredContextTokens','ExpectedOutputTokens')) {
        $v = Get-ContractProperty $Classification $f $null
        if ($null -ne $v) {
            if (($v -isnot [long]) -and ($v -isnot [int]) -and ($v -isnot [int64])) { $errors.Add("$f must be a number or null") }
            if ($v -lt 0) { $errors.Add("$f must be >= 0") }
        }
    }

    $ev = Get-ContractProperty $Classification 'Evidence' $null
    if ($null -eq $ev) { $errors.Add('Evidence is required') }
    else {
        $sigs = Get-ContractProperty $ev 'Signals' @()
        if (@($sigs).Count -eq 0) { $errors.Add('Evidence.Signals must be non-empty') }
    }
    if ($null -eq (Get-ContractProperty $Classification 'ReservedScope' $null)) { $errors.Add('ReservedScope is required') }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

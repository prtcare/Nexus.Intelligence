# =============================================================================
# Test-DbM18Classification.ps1
# DB-M18 — Task Classification + Context Package Foundation (Lane B, AI Routing)
#
# Zero paid API calls. Exercises: task-type classification, complexity, risk
# preservation, capability requirements (coding/reasoning/vision/tool/structured
# output), mandatory context preservation, optional context dropping, token
# budget, secret filtering, history reduction, relevant file selection,
# binary/generated rejection, stable package hash, schema v1 round-trips,
# unknown-fields-stay-null, provider-name independence, no model selection, the
# 8 context-budget scenarios, the 8 classification examples, and the governed
# WI-07-0.2.4 fixture (READ-ONLY).
# =============================================================================

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root    = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# --- Forge host root ----------------------------------------------------------------------
# W6/LaneA moved the AI material out of Forge into this repository. S27 and S29 assert the
# classification of the LIVE governed node, and that node's state files did not move: they
# are Forge development-lifecycle state (Forge: state\current-task.json, state\preflight.json).
# The root that reaches them is resolved separately and EXPLICITLY (see AiHostRoot.ps1).
# When it is not declared the cross-tree scenarios report a SKIP rather than throwing.
. (Join-Path $PSScriptRoot "AiHostRoot.ps1")
$script:ForgeRoot = Resolve-ForgeHostRoot
$script:HostSkips = New-Object System.Collections.Generic.List[string]

$script:TempRoot = Join-Path $env:TEMP ("devbridge-dbm18-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:TempRoot | Out-Null

. (Join-Path $PSScriptRoot "TaskClassification.ps1")   # DB-M18 classifier (READ-ONLY dependency)
. (Join-Path $PSScriptRoot "ContextPackage.ps1")       # DB-M18 context package (READ-ONLY dependency)

$script:Results = 0
$script:Fails = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Results++
    if ($Condition) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message) }
}
function Assert-Throws {
    param([scriptblock]$Script, [string]$Message)
    $script:Results++
    $threw = $false
    try { & $Script | Out-Null } catch { $threw = $true }
    if ($threw) { Write-Output ("PASS: " + $Message) }
    else { $script:Fails++; Write-Output ("FAIL: " + $Message) }
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function New-TestTask {
    <#
    .SYNOPSIS
    A minimal governed task shape for unit tests. Any governed field can be set;
    unset fields stay null (UNKNOWN semantics).
    #>
    param(
        [string]$TaskId = 'T-1',
        [string]$Name = '',
        [string]$Goal = '',
        [string]$AcceptanceCriteria = '',
        [string]$Risk,
        [string]$Verdict = 'CLEAR',
        [string]$NodeType = 'WorkItem',
        [string]$Phase = 'P0',
        [string[]]$Repositories = @(),
        [string[]]$Projects = @(),
        [string[]]$FilesGlobs = @(),
        [string[]]$ContractsApis = @(),
        [string[]]$SchemaContexts = @(),
        [string[]]$AffectedNodes = @(),
        [string[]]$BlockingReasons = @(),
        [object[]]$ArchitectureDecisions = @()
    )
    return [pscustomobject]@{
        taskId                = $TaskId
        nodeId                = $TaskId
        name                  = $Name
        goal                  = $Goal
        acceptanceCriteria    = $AcceptanceCriteria
        risk                  = $Risk
        preflightVerdict      = $Verdict
        nodeType              = $NodeType
        phase                 = $Phase
        repositories          = @($Repositories)
        projects              = @($Projects)
        filesGlobs            = @($FilesGlobs)
        contractsApis         = @($ContractsApis)
        schemaContexts        = @($SchemaContexts)
        affectedNodes         = @($AffectedNodes)
        blockingReasons       = @($BlockingReasons)
        architectureDecisions = @($ArchitectureDecisions)
    }
}

function New-TestSection {
    param([string]$Id, [string]$Priority = 'OPTIONAL', [long]$Tokens = 100, [string]$Content = 'x')
    return New-DbM18ContextSection -SectionId $Id -Title $Id -Priority $Priority -ContentType 'TEXT' -Content $Content -Tokens $Tokens
}

Write-Output "================================================================"
Write-Output "DB-M18 classification + context package test suite"
Write-Output "Root: $script:Root"
Write-Output "================================================================"

# -----------------------------------------------------------------------------
# S1  Task-type classification (deterministic examples)
# -----------------------------------------------------------------------------
Write-Output "--- S1 task-type classification (8 examples) ---"

$doc = New-TestTask -TaskId 'T-DOC' -Name 'Write API documentation for the DevelopmentControl store' -Goal 'Document all 22 operations' -AcceptanceCriteria 'A docs page exists'
$c = Classify-DevBridgeTask -Task $doc -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.TaskType -eq 'RESEARCH') 'S1 documentation -> RESEARCH'
Assert-True ($c.RequiresCoding -eq $false) 'S1 documentation -> RequiresCoding false'
Assert-True ($c.RequiresReasoning -eq $false) 'S1 documentation -> RequiresReasoning false'
Assert-True ($c.Complexity -eq 'LOW') 'S1 documentation -> Complexity LOW'

$ui = New-TestTask -TaskId 'T-UI' -Name 'Add a small UI form to the operator dashboard' -Goal 'Add a form for creating a new work item' -Repositories @('DevBridge') -FilesGlobs @('src/DevBridge/**')
$c = Classify-DevBridgeTask -Task $ui -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.TaskType -eq 'IMPLEMENTATION') 'S1 small UI -> IMPLEMENTATION'
Assert-True ($c.Complexity -eq 'LOW') 'S1 small UI -> Complexity LOW (small signal)'
Assert-True ($c.RequiresVision -eq $true) 'S1 small UI -> RequiresVision true'

$coding = New-TestTask -TaskId 'T-COD' -Name 'Implement the AddChildAsync operation' -Goal 'Add the missing contract operation with tests' -Repositories @('Nexus.Developer') -FilesGlobs @('src/**') -ContractsApis @('IDevelopmentControlStore') -AffectedNodes @('WI-1','WI-2','WI-3') -Risk 'Low'
$c = Classify-DevBridgeTask -Task $coding -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.TaskType -eq 'IMPLEMENTATION') 'S1 normal coding -> IMPLEMENTATION'
Assert-True ($c.Complexity -eq 'MEDIUM') 'S1 normal coding -> Complexity MEDIUM'
Assert-True ($c.RequiresCoding -eq $true) 'S1 normal coding -> RequiresCoding true'

$db = New-TestTask -TaskId 'T-DB' -Name 'Add the Users table schema migration' -Goal 'Introduce the Users table with FK constraints' -Repositories @('Nexus.Developer') -FilesGlobs @('src/**') -SchemaContexts @('Users table') -ContractsApis @('IUserRepository')
$c = Classify-DevBridgeTask -Task $db -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.TaskType -eq 'IMPLEMENTATION') 'S1 DB/schema -> IMPLEMENTATION'
Assert-True ($c.Complexity -eq 'HIGH') 'S1 DB/schema -> Complexity HIGH (schema)'
Assert-True ($c.RequiresStructuredOutput -eq $true) 'S1 DB/schema -> RequiresStructuredOutput true'

$arch = New-TestTask -TaskId 'T-ARCH' -Name 'Design the routing architecture for Lane B' -Goal 'Produce an architecture design document and plan the milestone sequence'
$c = Classify-DevBridgeTask -Task $arch -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.TaskType -eq 'PLANNING') 'S1 architecture -> PLANNING'
Assert-True ($c.Complexity -eq 'HIGH') 'S1 architecture -> Complexity HIGH'
Assert-True ($c.MinimumReasoningLevel -eq 'HIGH') 'S1 architecture -> MinimumReasoningLevel HIGH'

$verif = New-TestTask -TaskId 'T-VER' -Name 'Verify and review the Excel persistence adapter change' -Goal 'Run verification and review the diff' -Risk 'Low'
$c = Classify-DevBridgeTask -Task $verif -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.TaskType -eq 'VERIFICATION') 'S1 verification -> VERIFICATION'
Assert-True ($c.ExpectedOutputTokens -eq 1024) 'S1 verification -> ExpectedOutputTokens 1024'

$gov = New-TestTask -TaskId 'T-GOV' -Name 'Governance decision for the release process' -Goal 'Update the release policy governance controls' -Risk 'High'
$c = Classify-DevBridgeTask -Task $gov -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.TaskType -eq 'GOVERNANCE') 'S1 high-risk governance -> GOVERNANCE'
Assert-True ($c.Risk -eq 'HIGH') 'S1 high-risk governance -> Risk preserved HIGH'
Assert-True ($c.MinimumReasoningLevel -eq 'HIGH') 'S1 high-risk governance -> MinimumReasoningLevel HIGH'
Assert-True ($c.ReasoningRuleApplied -eq $true) 'S1 high-risk governance -> ReasoningRuleApplied true'

$log = New-TestTask -TaskId 'T-LOG' -Name 'Summarize the error logs' -Goal 'Produce a summary of today is failures'
$c = Classify-DevBridgeTask -Task $log -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.TaskType -eq 'RESEARCH') 'S1 log summarization -> RESEARCH'

# -----------------------------------------------------------------------------
# S2  Complexity derivation
# -----------------------------------------------------------------------------
Write-Output "--- S2 complexity derivation ---"
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'C1' -Name 'Rename a local variable (small)' -Repositories @('R') -FilesGlobs @('src/**')) -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.Complexity -eq 'LOW') 'S2 simple code change -> LOW'
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'C2' -Name 'Implement a feature' -Repositories @('R') -FilesGlobs @('src/**') -ContractsApis @('ISvc')) -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.Complexity -eq 'MEDIUM') 'S2 normal coding with contract -> MEDIUM'
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'C3' -Name 'Schema migration' -Repositories @('R') -FilesGlobs @('src/**') -SchemaContexts @('T')) -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.Complexity -eq 'HIGH') 'S2 schema -> HIGH'
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'C4' -Name 'Cross-repo change' -Repositories @('A','B') -FilesGlobs @('src/**')) -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.Complexity -eq 'HIGH') 'S2 multi-repository -> HIGH'

# -----------------------------------------------------------------------------
# S3  Risk preservation / derivation
# -----------------------------------------------------------------------------
Write-Output "--- S3 risk preservation ---"
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'R1' -Name 'Task' -Risk 'Low') -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.Risk -eq 'LOW') 'S3 governed Low preserved verbatim'
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'R2' -Name 'Task' -Risk 'Medium') -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.Risk -eq 'MEDIUM') 'S3 governed Medium preserved verbatim'
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'R3' -Name 'Task' -Risk 'High') -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.Risk -eq 'HIGH') 'S3 governed High preserved verbatim'
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'R4' -Name 'Task' -Verdict 'FAIL') -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.Risk -eq 'HIGH') 'S3 absent risk + FAIL verdict -> HIGH'
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'R5' -Name 'Task' -Verdict 'CLEAR' -BlockingReasons @('conflict in scope')) -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.Risk -eq 'HIGH') 'S3 absent risk + blocker -> HIGH'
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'R6' -Name 'Task' -Verdict 'CLEAR') -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($null -eq $c.Risk) 'S3 no risk signal -> Risk stays UNKNOWN (null)'

# -----------------------------------------------------------------------------
# S4  Capability requirements
# -----------------------------------------------------------------------------
Write-Output "--- S4 capability requirements ---"
Assert-True ($c.RequiresCoding -eq $null) 'S4 no code scope -> RequiresCoding null'
Assert-True ($c.RequiresStructuredOutput -eq $null) 'S4 no contract/schema -> RequiresStructuredOutput null'
Assert-True ($c.RequiresVision -eq $null) 'S4 no UI signal -> RequiresVision null'
$c = Classify-DevBridgeTask -Task $coding -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.RequiresReasoning -eq $true) 'S4 MEDIUM coding -> RequiresReasoning true'
Assert-True ($c.RequiresToolUse -eq $true) 'S4 code scope -> RequiresToolUse true'
Assert-True ($c.HumanReviewRequired -eq $true) 'S4 governed coding scope -> HumanReviewRequired true'

# -----------------------------------------------------------------------------
# S5  Reasoning rule (DB-M13: HIGH risk/complexity => at least HIGH reasoning)
# -----------------------------------------------------------------------------
Write-Output "--- S5 reasoning rule ---"
$c = Classify-DevBridgeTask -Task $db -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.MinimumReasoningLevel -eq 'HIGH') 'S5 schema/HIGH complexity -> HIGH reasoning'
Assert-True ($c.ReasoningRuleApplied -eq $true) 'S5 schema -> ReasoningRuleApplied true'
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'S5B' -Name 'Task' -Risk 'High') -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.MinimumReasoningLevel -eq 'HIGH') 'S5 HIGH risk -> HIGH reasoning'
Assert-True ($c.ReasoningRuleApplied -eq $true) 'S5 HIGH risk -> ReasoningRuleApplied true'
$c = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'S5C' -Name 'Task' -Risk 'Medium') -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($c.MinimumReasoningLevel -eq 'MEDIUM') 'S5 MEDIUM risk -> MEDIUM reasoning'

# -----------------------------------------------------------------------------
# S6  Mandatory context preservation in a built package
# -----------------------------------------------------------------------------
Write-Output "--- S6 mandatory context preservation ---"
$mandatoryTask = New-TestTask -TaskId 'M-REQ' -Name 'Implement the store' -Goal 'Make all mutations atomic' -AcceptanceCriteria 'Atomic writes proven by test' `
    -Repositories @('Nexus.Developer') -FilesGlobs @('src/A/**') -ContractsApis @('IStore') -AffectedNodes @('F-1','M-1','WI-1') `
    -ArchitectureDecisions @([pscustomobject]@{ adrId='ADR-003'; relation='GOVERNS_SUBSTRATE'; conflict=$false; detail='workbook is authoritative' }) `
    -BlockingReasons @('pending decision DEC-001')
$c = Classify-DevBridgeTask -Task $mandatoryTask -ClassifiedAtUtc '2026-08-30T00:00:00Z'
$secs = Get-DbM18ContextSections -Task $mandatoryTask
$budget = New-ContextBudget -TaskId 'M-REQ' -AllowedInputTokens 20000 -Sections $secs
$pkg = Build-ContextPackage -Task $mandatoryTask -Classification $c -Budget $budget -Sections $secs -GeneratedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($pkg.Status -eq 'OK') 'S6 package Status OK'
$mandatoryIds = @('task_identity','goal','acceptance_criteria','reserved_scope','mandatory_adrs','blockers','report_format')
foreach ($mid in $mandatoryIds) {
    $included = @($pkg.Sections | Where-Object { $_.SectionId -eq $mid -and $_.Included }).Count -eq 1
    Assert-True $included "S6 mandatory section '$mid' included"
}
$goalSec = @($pkg.Sections | Where-Object { $_.SectionId -eq 'goal' })[0]
Assert-True ($goalSec.Content.Contains('Make all mutations atomic')) 'S6 goal content preserved'
$adrSec = @($pkg.Sections | Where-Object { $_.SectionId -eq 'mandatory_adrs' })[0]
Assert-True ($adrSec.Content.Contains('ADR-003')) 'S6 governing ADR content preserved'
$blkSec = @($pkg.Sections | Where-Object { $_.SectionId -eq 'blockers' })[0]
Assert-True ($blkSec.Content.Contains('pending decision DEC-001')) 'S6 blocker content preserved'
$repSec = @($pkg.Sections | Where-Object { $_.SectionId -eq 'report_format' })[0]
Assert-True ($repSec.Content.Contains('IMPLEMENTATION RESULT')) 'S6 report-format template embedded'

# -----------------------------------------------------------------------------
# S7  Optional context dropping
# -----------------------------------------------------------------------------
Write-Output "--- S7 optional context dropping ---"
$s7 = @()
$s7 += New-TestSection 'm1' 'MANDATORY' 100
$s7 += New-TestSection 'm2' 'MANDATORY' 100
$s7 += New-TestSection 'm3' 'MANDATORY' 100
$s7 += New-TestSection 'opt1' 'OPTIONAL' 300
$s7 += New-TestSection 'opt2' 'OPTIONAL' 300
$s7 += New-TestSection 'low1' 'LOW_VALUE' 100
$b7 = New-ContextBudget -TaskId 'S7' -AllowedInputTokens 800 -Sections $s7
Assert-True ($b7.BudgetStatus -eq 'REDUCED') 'S7 budget REDUCED when mandatory+optional exceed budget'
Assert-True (@($b7.Sections | Where-Object { $_.Priority -eq 'OPTIONAL' -and $_.Action -eq 'EXCLUDE' }).Count -eq 2) 'S7 both optional sections EXCLUDE'
Assert-True (@($b7.Sections | Where-Object { $_.Priority -eq 'MANDATORY' -and $_.Action -eq 'EXCLUDE' }).Count -eq 0) 'S7 mandatory never EXCLUDE'
$pkg7 = Build-ContextPackage -Task $null -Budget $b7 -Sections $s7 -GeneratedAtUtc '2026-08-30T00:00:00Z'
Assert-True (@($pkg7.Sections | Where-Object { $_.Included -and $_.Priority -eq 'OPTIONAL' }).Count -eq 0) 'S7 built package contains no optional sections'
Assert-True (@($pkg7.Sections | Where-Object { $_.Included -and $_.Priority -eq 'MANDATORY' }).Count -eq 3) 'S7 built package keeps all mandatory sections'

# -----------------------------------------------------------------------------
# S8  Token budget / estimator
# -----------------------------------------------------------------------------
Write-Output "--- S8 token budget ---"
Assert-True ((Get-EstimatedTokenCount 'abcd') -eq 1) 'S8 estimator chars/4 (4 chars -> 1)'
Assert-True ((Get-EstimatedTokenCount '') -eq 0) 'S8 estimator empty -> 0'
Assert-True ((Get-EstimatedTokenCount $null) -eq 0) 'S8 estimator null -> 0'
$long = 'x' * 200
Assert-True ((Get-EstimatedTokenCount $long) -eq 50) 'S8 estimator 200 chars -> 50'
Assert-True ((Get-EstimatedTokenCount $long) -eq (Get-EstimatedTokenCount $long)) 'S8 estimator deterministic'
$b8 = New-ContextBudget -TaskId 'S8' -AllowedInputTokens 1000 -Sections $s7
Assert-True ($b8.SelectedContextTokens -eq 1000) 'S8 everything fits at 1000 -> selected equals total'

# -----------------------------------------------------------------------------
# S9  Secret filtering
# -----------------------------------------------------------------------------
Write-Output "--- S9 secret filtering ---"
$s9 = @()
$s9 += New-TestSection 'm1' 'MANDATORY' 100 'plain content'
$s9 += New-TestSection 'leaky' 'OPTIONAL' 100 'the production gateway key is sk-proj-9F8E7D6C5B4A3210 and must stay secret'
$b9 = New-ContextBudget -TaskId 'S9' -AllowedInputTokens 1000 -Sections $s9
$pkg9 = Build-ContextPackage -Task $null -Budget $b9 -Sections $s9 -GeneratedAtUtc '2026-08-30T00:00:00Z'
$leakyOut = @($pkg9.Sections | Where-Object { $_.SectionId -eq 'leaky' })[0]
Assert-True ($leakyOut.Content.StartsWith('[redacted')) 'S9 leaky section content replaced with redaction marker'
Assert-True ($pkg9.SecretWarnings.Count -ge 1) 'S9 redaction produced a warning'
$allText = (($pkg9.Sections | ForEach-Object { [string]$_.Content }) -join ' ')
Assert-True (-not $allText.Contains('sk-proj-9F8E7D6C5B4A3210')) 'S9 the secret value never reaches the package'
$chk9 = Test-ContextPackage -Package $pkg9
Assert-True ($chk9.Valid) 'S9 redacted package passes Test-ContextPackage'

# -----------------------------------------------------------------------------
# S10  History reduction (low-value dropped first)
# -----------------------------------------------------------------------------
Write-Output "--- S10 history reduced first ---"
$s10 = @()
$s10 += New-TestSection 'm1' 'MANDATORY' 100
$s10 += New-TestSection 'm2' 'MANDATORY' 100
$s10 += New-TestSection 'm3' 'MANDATORY' 100
$s10 += New-TestSection 'opt1' 'OPTIONAL' 100
$s10 += New-TestSection 'opt2' 'OPTIONAL' 100
$s10 += New-TestSection 'history' 'LOW_VALUE' 300
$b10 = New-ContextBudget -TaskId 'S10' -AllowedInputTokens 700 -Sections $s10
Assert-True ($b10.BudgetStatus -eq 'REDUCED') 'S10 budget REDUCED'
$hPlan = @($b10.Sections | Where-Object { $_.SectionId -eq 'history' })[0]
Assert-True ($hPlan.Action -eq 'EXCLUDE') 'S10 history (LOW_VALUE) EXCLUDE first'
Assert-True (@($b10.Sections | Where-Object { $_.Priority -eq 'OPTIONAL' -and $_.Action -eq 'INCLUDE' }).Count -eq 2) 'S10 optional kept when history alone frees budget'
$pkg10 = Build-ContextPackage -Task $null -Budget $b10 -Sections $s10 -GeneratedAtUtc '2026-08-30T00:00:00Z'
Assert-True (-not (@($pkg10.Sections | Where-Object { $_.SectionId -eq 'history' })[0].Included)) 'S10 built package drops history'
Assert-True (@($pkg10.Sections | Where-Object { $_.Included -and $_.Priority -eq 'OPTIONAL' }).Count -eq 2) 'S10 built package keeps optional'

# -----------------------------------------------------------------------------
# S11  Relevant file selection
# -----------------------------------------------------------------------------
Write-Output "--- S11 relevant file selection ---"
$map11 = @{
    'src/A/DevControl/Store.cs'       = 'interface IStore {}'
    'src/A/DevControl/codec.txt'      = 'codec notes'
    'src/B/Other.cs'                  = 'out of scope'
    'docs/design.md'                  = 'out of scope doc'
}
$files11 = New-DbM18FileContextSections -FileContextMap $map11 -FileGlobs @('src/A/DevControl/**')
Assert-True (@($files11).Count -eq 2) 'S11 only in-scope files selected'
Assert-True (@($files11 | Where-Object { $_.SectionId -eq 'file:src/A/DevControl/Store.cs' }).Count -eq 1) 'S11 Store.cs selected'
Assert-True (@($files11 | Where-Object { $_.SectionId -eq 'file:src/B/Other.cs' }).Count -eq 0) 'S11 out-of-scope file excluded'

# -----------------------------------------------------------------------------
# S12  Binary/generated rejection
# -----------------------------------------------------------------------------
Write-Output "--- S12 binary/generated rejection ---"
$map12 = @{
    'src/A/DevControl/Store.cs'                       = 'interface IStore {}'
    'src/A/DevControl/bin/output.dll'                 = 'binary'
    'src/A/DevControl/obj/temp.cs'                    = 'build artifact'
    'src/A/DevControl/Generated.generated.cs'         = 'generated'
    'src/A/DevControl/NEXUS_DEVELOPMENT_CONTROL.xlsx' = 'workbook'
    'src/A/DevControl/logo.png'                       = 'image'
}
$files12 = New-DbM18FileContextSections -FileContextMap $map12 -FileGlobs @('src/A/DevControl/**')
Assert-True (@($files12).Count -eq 1) 'S12 only the text source survives (bin/obj/generated/workbook/image rejected)'
Assert-True (@($files12)[0].SectionId -eq 'file:src/A/DevControl/Store.cs') 'S12 surviving file is Store.cs'

# -----------------------------------------------------------------------------
# S13  Stable package hash
# -----------------------------------------------------------------------------
Write-Output "--- S13 stable package hash ---"
$secs13 = Get-DbM18ContextSections -Task $mandatoryTask
$b13 = New-ContextBudget -TaskId 'M-REQ' -AllowedInputTokens 20000 -Sections $secs13
$p13a = Build-ContextPackage -Task $mandatoryTask -Classification $c -Budget $b13 -Sections $secs13 -GeneratedAtUtc '2026-08-30T00:00:00Z'
$p13b = Build-ContextPackage -Task $mandatoryTask -Classification $c -Budget $b13 -Sections $secs13 -GeneratedAtUtc '2026-08-31T00:00:00Z'
Assert-True ($p13a.PackageHash -eq $p13b.PackageHash) 'S13 hash identical when GeneratedAtUtc differs (excluded from hash)'
$alt = New-TestTask -TaskId 'M-REQ' -Name 'Implement the store' -Goal 'Make all mutations atomic AND transactional' -AcceptanceCriteria 'Atomic writes proven by test' `
    -Repositories @('Nexus.Developer') -FilesGlobs @('src/A/**') -ContractsApis @('IStore') -AffectedNodes @('F-1','M-1','WI-1') `
    -ArchitectureDecisions @([pscustomobject]@{ adrId='ADR-003'; relation='GOVERNS_SUBSTRATE'; conflict=$false; detail='workbook is authoritative' })
$secsAlt = Get-DbM18ContextSections -Task $alt
$bAlt = New-ContextBudget -TaskId 'M-REQ' -AllowedInputTokens 20000 -Sections $secsAlt
$p13c = Build-ContextPackage -Task $alt -Classification $c -Budget $bAlt -Sections $secsAlt -GeneratedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($p13a.PackageHash -ne $p13c.PackageHash) 'S13 hash changes when content changes'
$chk13 = Test-ContextPackage -Package $p13a -RecomputeHash
Assert-True ($chk13.Valid) 'S13 hash recomputation matches'

# -----------------------------------------------------------------------------
# S14  Schema v1 round-trip (classification + budget + package)
# -----------------------------------------------------------------------------
Write-Output "--- S14 schema v1 round-trip ---"
$json = $c | ConvertTo-Json -Depth 30
$back = $json | ConvertFrom-Json
$chk14 = Test-TaskClassification $back
Assert-True ($chk14.Valid) 'S14 classification round-trip passes Test-TaskClassification'
Assert-True ($back.SchemaVersion -eq 1) 'S14 classification SchemaVersion stays 1'
Assert-True ($back.TaskType -eq 'IMPLEMENTATION') 'S14 classification values survive JSON'
$jsonB = $b13 | ConvertTo-Json -Depth 30
$backB = $jsonB | ConvertFrom-Json
$chkB = Test-ContextBudget $backB
Assert-True ($chkB.Valid) 'S14 budget round-trip passes Test-ContextBudget'
$jsonP = $p13a | ConvertTo-Json -Depth 40
$backP = $jsonP | ConvertFrom-Json
$chkP = Test-ContextPackage $backP
Assert-True ($chkP.Valid) 'S14 package round-trip passes Test-ContextPackage'

# -----------------------------------------------------------------------------
# S15  Unknown fields remain null
# -----------------------------------------------------------------------------
Write-Output "--- S15 unknown fields remain null ---"
$min = New-TestTask -TaskId 'MIN' -Name 'A bare task'
$cMin = Classify-DevBridgeTask -Task $min -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($null -eq $cMin.Risk) 'S15 Risk null when unknown'
Assert-True ($null -eq $cMin.ChangeId) 'S15 ChangeId null when unknown'
Assert-True ($null -eq $cMin.RequiresVision) 'S15 RequiresVision null when unknown'
Assert-True ($null -eq $cMin.RequiresStructuredOutput) 'S15 RequiresStructuredOutput null when unknown'
$jsonMin = $cMin | ConvertTo-Json -Depth 30
$backMin = $jsonMin | ConvertFrom-Json
Assert-True ((Get-ContractProperty $backMin 'Risk' 'SENTINEL-NULL') -eq 'SENTINEL-NULL') 'S15 nulls survive JSON round-trip (not coerced to "")'
Assert-True (-not $backMin.PSObject.Properties.Name.Contains('SelectedModelId')) 'S15 no SelectedModelId property ever present'

# -----------------------------------------------------------------------------
# S16  Provider-name independence (ADR-005)
# -----------------------------------------------------------------------------
Write-Output "--- S16 provider-name independence ---"
$libTextRaw = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'TaskClassification.ps1') -Raw) + "`n" + (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ContextPackage.ps1') -Raw)
# strip comment-only lines: header comments legitimately document the PROHIBITED provider
# names; the ADR-005 scan must assert they never appear in executable code
$libText = ($libTextRaw -split "`n" | Where-Object { $_.Trim().StartsWith('#') -eq $false }) -join "`n"
foreach ($pn in @('DeepSeek','Claude','OpenAI','Gemini','deepseek','claude','openai','gemini')) {
    Assert-True (-not $libText.Contains($pn)) "S16 no provider name '$pn' in DB-M18 libraries"
}
Assert-True ($cMin.TaskType -in (Get-AiRoutingTaskTypes)) 'S16 TaskType is a DB-M14 vocabulary member (provider-independent)'
Assert-True (-not $libText.Contains('ProviderId')) 'S16 no ProviderId usage in DB-M18 libraries'

# -----------------------------------------------------------------------------
# S17  No model selection
# -----------------------------------------------------------------------------
Write-Output "--- S17 no model selection ---"
Assert-True ($null -eq $cMin.PSObject.Properties['SelectedModelId']) 'S17 classification has no SelectedModelId'
Assert-True ($null -eq $cMin.PSObject.Properties['SelectedProviderId']) 'S17 classification has no SelectedProviderId'
Assert-True (-not $libText.Contains('New-AiRoutingDecision')) 'S17 libraries never build a routing decision'
Assert-True (-not $libText.Contains('Select-Model')) 'S17 libraries never call a model selector'

# -----------------------------------------------------------------------------
# S18-25  Context-budget scenarios
# -----------------------------------------------------------------------------
Write-Output "--- S18-25 context-budget scenarios ---"

# S18 fits without reduction
$s18 = @(New-TestSection 'm1' 'MANDATORY' 100; New-TestSection 'm2' 'MANDATORY' 100; New-TestSection 'o1' 'OPTIONAL' 100; New-TestSection 'l1' 'LOW_VALUE' 100)
$b18 = New-ContextBudget -TaskId 'S18' -AllowedInputTokens 1000 -Sections $s18
Assert-True ($b18.BudgetStatus -eq 'FITS') 'S18 budget FITS when everything fits'
Assert-True (-not $b18.ReductionRequired) 'S18 no reduction required'
Assert-True (@($b18.Sections | Where-Object { $_.Action -eq 'INCLUDE' }).Count -eq 4) 'S18 all sections INCLUDE'
Assert-True ($b18.SelectedContextTokens -eq 400) 'S18 selected equals total (400)'

# S19 mandatory exceeds budget -> explicit failure
$s19 = @(New-TestSection 'm1' 'MANDATORY' 500; New-TestSection 'm2' 'MANDATORY' 500; New-TestSection 'm3' 'MANDATORY' 500)
$b19 = New-ContextBudget -TaskId 'S19' -AllowedInputTokens 1000 -Sections $s19
Assert-True ($b19.BudgetStatus -eq 'EXCEEDS') 'S19 mandatory exceeds budget -> EXCEEDS'
Assert-True (-not [string]::IsNullOrEmpty($b19.Failure)) 'S19 EXCEEDS carries an explicit Failure reason'
Assert-True (@($b19.Sections | Where-Object { $_.Action -eq 'EXCLUDE' }).Count -eq 3) 'S19 all sections excluded (no silent truncation)'
$pkg19 = Build-ContextPackage -Task $null -Budget $b19 -Sections $s19 -GeneratedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($pkg19.Status -eq 'FAILED') 'S19 package Status FAILED'
Assert-True (-not [string]::IsNullOrEmpty($pkg19.FailureReason)) 'S19 package carries FailureReason'
$chk19 = Test-ContextPackage -Package $pkg19
Assert-True ($chk19.Valid) 'S19 explicit-failure package is structurally valid'

# S20 optional dropped
$s20 = @(New-TestSection 'm1' 'MANDATORY' 100; New-TestSection 'm2' 'MANDATORY' 100; New-TestSection 'm3' 'MANDATORY' 100; New-TestSection 'o1' 'OPTIONAL' 300; New-TestSection 'o2' 'OPTIONAL' 300; New-TestSection 'l1' 'LOW_VALUE' 100)
$b20 = New-ContextBudget -TaskId 'S20' -AllowedInputTokens 800 -Sections $s20
Assert-True ($b20.BudgetStatus -eq 'REDUCED') 'S20 budget REDUCED'
Assert-True ($b20.Strategy -eq 'DROP_OPTIONAL_AND_LOW_VALUE') 'S20 strategy DROP_OPTIONAL_AND_LOW_VALUE'
Assert-True (@($b20.Sections | Where-Object { $_.Priority -eq 'OPTIONAL' -and $_.Action -eq 'EXCLUDE' }).Count -eq 2) 'S20 optional dropped'

# S21 history reduced first
$s21 = @(New-TestSection 'm1' 'MANDATORY' 100; New-TestSection 'm2' 'MANDATORY' 100; New-TestSection 'm3' 'MANDATORY' 100; New-TestSection 'o1' 'OPTIONAL' 100; New-TestSection 'o2' 'OPTIONAL' 100; New-TestSection 'history' 'LOW_VALUE' 300)
$b21 = New-ContextBudget -TaskId 'S21' -AllowedInputTokens 700 -Sections $s21
Assert-True ($b21.Strategy -eq 'DROP_LOW_VALUE') 'S21 strategy DROP_LOW_VALUE (history reduced first)'
Assert-True (@($b21.Sections | Where-Object { $_.SectionId -eq 'history' -and $_.Action -eq 'EXCLUDE' }).Count -eq 1) 'S21 history section excluded'
Assert-True (@($b21.Sections | Where-Object { $_.Priority -eq 'OPTIONAL' -and $_.Action -eq 'EXCLUDE' }).Count -eq 0) 'S21 optional untouched'

# S22 large mandatory file excerpted
$bigContent = ('a' * 20000)
$s22 = @(New-TestSection 'm1' 'MANDATORY' 100; New-TestSection 'm2' 'MANDATORY' 100)
$s22 += New-DbM18ContextSection -SectionId 'big' -Title 'big' -Priority 'MANDATORY' -ContentType 'CODE' -Content $bigContent
$b22 = New-ContextBudget -TaskId 'S22' -AllowedInputTokens 4000 -Sections $s22
Assert-True ($b22.BudgetStatus -eq 'REDUCED') 'S22 budget REDUCED via excerpt'
$bigPlan = @($b22.Sections | Where-Object { $_.SectionId -eq 'big' })[0]
Assert-True ($bigPlan.Action -eq 'EXCERPT') 'S22 large mandatory file EXCERPT (not dropped)'
Assert-True ($b22.SelectedContextTokens -le 4000) 'S22 selected tokens fit after excerpt'
$pkg22 = Build-ContextPackage -Task $null -Budget $b22 -Sections $s22 -GeneratedAtUtc '2026-08-30T00:00:00Z'
$bigOut = @($pkg22.Sections | Where-Object { $_.SectionId -eq 'big' })[0]
Assert-True ($bigOut.Included) 'S22 excerpted section still included'
Assert-True ($bigOut.Content.Length -lt 20000) 'S22 excerpted content is truncated'
Assert-True ($bigOut.Content.Contains('[excerpted:')) 'S22 excerpt carries an explicit omission marker'

# S23 zero/invalid budget rejected
Assert-Throws { New-ContextBudget -TaskId 'S23' -AllowedInputTokens 0 -Sections @() } 'S23 AllowedInputTokens 0 rejected'
Assert-Throws { New-ContextBudget -TaskId 'S23' -AllowedInputTokens -5 -Sections @() } 'S23 AllowedInputTokens negative rejected'
Assert-Throws { New-ContextBudget -TaskId 'S23' -AllowedInputTokens 100 -ReservedOutputTokens -1 -Sections @() } 'S23 ReservedOutputTokens negative rejected'
Assert-Throws { New-ContextBudget -TaskId 'S23' -AllowedInputTokens 100 -ReservedOutputTokens 100 -Sections @() } 'S23 reserved equals allowed rejected'
Assert-Throws { New-ContextBudget -TaskId 'S23' -AllowedInputTokens 100 -ReservedOutputTokens 150 -Sections @() } 'S23 reserved above allowed rejected'

# S24 reserved output accounted for
$s24 = @(New-TestSection 'm1' 'MANDATORY' 100; New-TestSection 'm2' 'MANDATORY' 100; New-TestSection 'm3' 'MANDATORY' 100; New-TestSection 'o1' 'OPTIONAL' 100; New-TestSection 'o2' 'OPTIONAL' 100; New-TestSection 'l1' 'LOW_VALUE' 100)
$b24 = New-ContextBudget -TaskId 'S24' -AllowedInputTokens 1000 -ReservedOutputTokens 500 -Sections $s24
Assert-True ($b24.AvailableInputTokens -eq 500) 'S24 available = allowed - reserved (500)'
Assert-True ($b24.SelectedContextTokens -le 500) 'S24 selected never exceeds the post-reserve budget'
$b24b = New-ContextBudget -TaskId 'S24' -AllowedInputTokens 1000 -Sections $s24
Assert-True ($b24b.SelectedContextTokens -gt $b24.SelectedContextTokens) 'S24 without reserve more context fits than with reserve'

# S25 selected tokens never exceed allowed input
foreach ($case in @($b18, $b20, $b21, $b22, $b24)) {
    $allowed = [long](Get-ContractProperty $case 'AllowedInputTokens' 0)
    $sel = [long](Get-ContractProperty $case 'SelectedContextTokens' 0)
    Assert-True ($sel -le $allowed) "S25 selected ($sel) never exceeds allowed ($allowed)"
}
Assert-True ($b19.SelectedContextTokens -le [long]$b19.AllowedInputTokens) 'S25 EXCEEDS package selects zero <= allowed'

# -----------------------------------------------------------------------------
# S26  CapabilityRequirement reuse (DB-M14 frozen v1)
# -----------------------------------------------------------------------------
Write-Output "--- S26 CapabilityRequirement reuse ---"
$req = New-CapabilityRequirement -Classification $c
$chkReq = Test-AiCapabilityRequirement $req
Assert-True ($chkReq.Valid) 'S26 derived CapabilityRequirement passes Test-AiCapabilityRequirement'
Assert-True ($req.SchemaVersion -eq 1) 'S26 CapabilityRequirement SchemaVersion 1 (DB-M14 v1)'
Assert-True ($req.TaskType -eq 'IMPLEMENTATION') 'S26 TaskType carried into requirement'
Assert-True ($req.Complexity -eq 'MEDIUM') 'S26 Complexity carried into requirement'
Assert-True (@($req.AllowedProviders).Count -eq 0) 'S26 AllowedProviders empty (no provider selection)'
Assert-True (@($req.AllowedModels).Count -eq 0) 'S26 AllowedModels empty (no model selection)'
Assert-True ($req.ExecutionMode -eq 'MANUAL') 'S26 ExecutionMode MANUAL'
Assert-True ($null -eq $req.MaxAllowedCost) 'S26 MaxAllowedCost null (cost is DB-M16 territory)'
Assert-True ($req.PreferredLatency -in (Get-AiRoutingRelativeSpeeds)) 'S26 PreferredLatency is a DB-M14 RelativeSpeeds member'
$reqMin = New-CapabilityRequirement -Classification $cMin
$chkReqMin = Test-AiCapabilityRequirement $reqMin
Assert-True ($chkReqMin.Valid) 'S26 UNKNOWN-heavy classification still produces a valid requirement'
Assert-True ($null -eq $reqMin.Risk) 'S26 unknown Risk stays null in the requirement'

# -----------------------------------------------------------------------------
# S27  WI-07-0.2.4 governed fixture (READ-ONLY)
# -----------------------------------------------------------------------------
Write-Output "--- S27 WI-07-0.2.4 governed fixture ---"
# The governed node's state files are Forge development-lifecycle state and stayed in
# Forge; they are not reachable from the AI material root. Assert against the DECLARED
# host root, and when there is none report the gap instead of failing on a stale path.
if ($script:ForgeRoot) {
$fixtureTask = Get-DbM18TaskFromState `
    -CurrentTaskPath (Join-Path $script:ForgeRoot 'state\current-task.json') `
    -PreflightPath (Join-Path $script:ForgeRoot 'state\preflight.json')
$cFix = Classify-DevBridgeTask -Task $fixtureTask `
    -Goal 'Named cross-process mutex, RowVersion optimistic check, temp-write/validate/replace, one proven concurrency test.' `
    -ClassifiedAtUtc '2026-08-30T00:00:00Z'
$chkFix = Test-TaskClassification $cFix
Assert-True ($chkFix.Valid) 'S27 fixture classification structurally valid'
Assert-True ($cFix.TaskId -eq 'WI-07-0.2.4') 'S27 fixture TaskId correct'
Assert-True ($cFix.ChangeId -eq 'CHG-20260830-017') 'S27 fixture ChangeId from governed state'
Assert-True ($cFix.TaskType -eq 'IMPLEMENTATION') 'S27 fixture -> IMPLEMENTATION'
Assert-True ($cFix.Complexity -eq 'MEDIUM') 'S27 fixture -> Complexity MEDIUM (derived from governed scope)'
Assert-True ($cFix.Risk -eq 'LOW') 'S27 fixture -> Risk LOW (governed field preserved verbatim)'
Assert-True ($cFix.RequiresCoding -eq $true) 'S27 fixture -> coding required'
Assert-True ($cFix.RequiresReasoning -eq $true) 'S27 fixture -> reasoning required (nontrivial complexity)'
Assert-True ($cFix.RequiresStructuredOutput -eq $true) 'S27 fixture -> structured output required (contract in scope)'
Assert-True ($cFix.RequiresToolUse -eq $true) 'S27 fixture -> tool use required (code scope)'
Assert-True ($null -eq $cFix.RequiresVision) 'S27 fixture -> no vision requirement'
Assert-True ($cFix.MinimumReasoningLevel -eq 'MEDIUM') 'S27 fixture -> MinimumReasoningLevel MEDIUM'
Assert-True ($cFix.ContextRequirement -eq 'HIGH') 'S27 fixture -> ContextRequirement HIGH (contract+affected+scope+governing ADR)'
Assert-True ($cFix.HumanReviewRequired -eq $true) 'S27 fixture -> human review required (governed scope)'
Assert-True ($cFix.LatencyPreference -eq 'NORMAL') 'S27 fixture -> LatencyPreference NORMAL (DB-M14 vocabulary)'
Assert-True ($cFix.ExecutionMode -eq 'MANUAL') 'S27 fixture -> ExecutionMode MANUAL'

$secsFix = Get-DbM18ContextSections -Task $fixtureTask
$mandIds = @('task_identity','goal','acceptance_criteria','reserved_scope','mandatory_adrs','blockers','report_format')
foreach ($mid in $mandIds) {
    Assert-True (@($secsFix | Where-Object { $_.SectionId -eq $mid }).Count -eq 1) "S27 fixture candidate section '$mid' present"
}
$bFix = New-ContextBudget -TaskId 'WI-07-0.2.4' -AllowedInputTokens 20000 -Sections $secsFix
$pkgFix = Build-ContextPackage -Task $fixtureTask -Classification $cFix -Budget $bFix -Sections $secsFix -GeneratedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($pkgFix.Status -eq 'OK') 'S27 fixture package Status OK'
Assert-True (@($pkgFix.Sections | Where-Object { $_.Included }).Count -ge 7) 'S27 fixture package includes at least the mandatory sections'
$acFix = @($pkgFix.Sections | Where-Object { $_.SectionId -eq 'acceptance_criteria' })[0]
Assert-True ($acFix.Content.Contains('not recorded')) 'S27 fixture acceptance criteria honestly report the governed gap'
$adrFix = @($pkgFix.Sections | Where-Object { $_.SectionId -eq 'mandatory_adrs' })[0]
Assert-True ($adrFix.Content.Contains('ADR-003')) 'S27 fixture governing ADR-003 packaged'
$sumFix = Get-ContextPackageSummary -Package $pkgFix
Assert-True ($sumFix.TaskId -eq 'WI-07-0.2.4') 'S27 fixture summary TaskId correct'
$mdFix = Get-ContextPackageSummary -Package $pkgFix -AsMarkdown
Assert-True ($mdFix -match '## Context Package Summary') 'S27 fixture markdown summary renders'
} else {
    $script:HostSkips.Add('S27 WI-07-0.2.4 governed fixture: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT); the governed state\ stayed in Forge at W6/LaneA')
    Write-Output "[SKIP] S27 WI-07-0.2.4 governed fixture (Forge host root not declared)"
}

# -----------------------------------------------------------------------------
# S28  No AI / no routing / no pricing scan
# -----------------------------------------------------------------------------
Write-Output "--- S28 no AI / no routing / no pricing scan ---"
foreach ($token in @('Invoke-WebRequest','Invoke-RestMethod','System.Net.Http','System.Net.WebClient','New-AiRoutingDecision','New-AiAttemptRecord','Get-AiPricing','PricingRecord','Select-Model','Route-Task','api-key','api_key')) {
    Assert-True (-not $libText.Contains($token)) "S28 library contains no '$token' token"
}

# -----------------------------------------------------------------------------
# S29  Context-package summary
# -----------------------------------------------------------------------------
Write-Output "--- S29 context-package summary ---"
# S29 renders the summary of the S27 governed fixture, so it is subject to the same
# host-root gate.
if ($script:ForgeRoot) {
Assert-True ($sumFix.SectionCount -eq @($pkgFix.Sections).Count) 'S29 summary SectionCount matches'
Assert-True ($sumFix.SecretWarningCount -eq 0) 'S29 fixture has no secret warnings'
Assert-True ($sumFix.PackageHash -eq $pkgFix.PackageHash) 'S29 summary carries the package hash'
$sumJson = $sumFix | ConvertTo-Json -Depth 10
Assert-True ($sumJson -match '"PackageId"') 'S29 summary is JSON-serializable (UI-discoverable)'
} else {
    $script:HostSkips.Add('S29 governed-fixture summary: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT)')
    Write-Output "[SKIP] S29 governed-fixture summary (Forge host root not declared)"
}

# -----------------------------------------------------------------------------
# S30  Assembly-level isolation: DB-M14 regression still green
# -----------------------------------------------------------------------------
Write-Output "--- S30 DB-M14 frozen contract regression ---"
$regPath = Join-Path $PSScriptRoot 'Test-AiRoutingFoundation.ps1'
if (Test-Path -LiteralPath $regPath) {
    $before = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'AiRoutingContracts.ps1') -Algorithm SHA256).Hash
    # run in a child PowerShell process: the DB-M14 suite ends with `exit`, which would terminate THIS session
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $regPath | Out-Null
    $regCode = $LASTEXITCODE
    $after = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'AiRoutingContracts.ps1') -Algorithm SHA256).Hash
    Assert-True ($before -eq $after) 'S30 AiRoutingContracts.ps1 hash unchanged by DB-M18 test run'
    Assert-True ($regCode -eq 0) 'S30 DB-M14 regression suite exits 0 (all green)'
} else {
    Assert-True $false 'S30 DB-M14 regression suite not found'
}

# -----------------------------------------------------------------------------
# S31  Work Universe (role-scope) context (Lane G)
# -----------------------------------------------------------------------------
# Proves the additive Work Universe semantics: V1 bare governed node ids default
# to Foundation (the Forge's role, single-workbook compat); an explicit Products
# role is honored; role-scoped references are recognized as addresses, bare ids
# never are (SP1-M14); and the additive output keys do NOT change PackageHash
# (the hashed payload is untouched).
Write-Output "--- S31 Work Universe (role-scope) context ---"

# Default: bare node id -> Foundation, canonical Foundation:<id> address.
$cWU = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'LG-1' -Name 'Lane G fixture' -Goal 'scope test') -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($cWU.WorkUniverse -eq 'Foundation') 'S31 bare node id defaults WorkUniverse Foundation'
Assert-True ($cWU.DevelopmentControlRole -eq 'Foundation') 'S31 DevelopmentControlRole echoes Foundation'
Assert-True ($cWU.NodeAddress -eq 'Foundation:LG-1') 'S31 bare node id -> canonical Foundation:<id> address'

# Explicit Products role is honored on classification.
$cWU2 = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'LG-2' -Name 'Products scope' -Goal 'x') -DevelopmentControlRole 'Products' -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($cWU2.WorkUniverse -eq 'Products') 'S31 explicit Products role honored'
Assert-True ($cWU2.NodeAddress -eq 'Products:LG-2') 'S31 explicit Products -> Products:<id> address'

# Role-scoped node reference is honored verbatim (never guessed, never stripped).
$cWU3 = Classify-DevBridgeTask -Task (New-TestTask -TaskId 'LG-3' -Name 'Scoped' -Goal 'x') -NodeId 'Products:WI-77' -ClassifiedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($cWU3.WorkUniverse -eq 'Products') 'S31 role-scoped nodeId honored'
Assert-True ($cWU3.NodeId -eq 'Products:WI-77') 'S31 role-scoped nodeId preserved verbatim'
Assert-True ($cWU3.NodeAddress -eq 'Products:WI-77') 'S31 role-scoped nodeId -> canonical address'

# Work Universe vocabulary + address helpers.
Assert-True (Test-DbM18DevelopmentControlRole 'Foundation') 'S31 helper accepts Foundation'
Assert-True (Test-DbM18DevelopmentControlRole 'products') 'S31 helper is case-insensitive'
Assert-True (-not (Test-DbM18DevelopmentControlRole 'Widgets')) 'S31 helper rejects unknown role'
Assert-True ((Get-DbM18WorkUniverse 'products') -eq 'Products') 'S31 Get-DbM18WorkUniverse canonicalizes'
Assert-True ((Get-DbM18WorkUniverse '') -eq 'Foundation') 'S31 Get-DbM18WorkUniverse defaults Foundation'
$addr = ConvertFrom-DbM18NodeAddress -Address 'Products:WI-77'
Assert-True ($null -ne $addr -and $addr.Role -eq 'Products' -and $addr.NodeId -eq 'WI-77') 'S31 ConvertFrom parses Role:Id'
Assert-True ($null -eq (ConvertFrom-DbM18NodeAddress -Address 'WI-77')) 'S31 bare id is never an address'
Assert-True (Test-DbM18NodeAddress 'Products:WI-77') 'S31 Test-DbM18NodeAddress recognizes scoped'
Assert-True (-not (Test-DbM18NodeAddress 'WI-77')) 'S31 Test-DbM18NodeAddress rejects bare'
Assert-True ((ConvertTo-DbM18NodeAddress -Role $null -Id 'WI-77') -eq 'Foundation:WI-77') 'S31 ConvertTo defaults Foundation'
Assert-True ((ConvertTo-DbM18NodeAddress -Role 'products' -Id 'WI-77') -eq 'Products:WI-77') 'S31 ConvertTo canonicalizes role'

# Context package: additive Work Universe output keys, package hash unchanged.
$wuTask = New-TestTask -TaskId 'LG-PKG' -Name 'Package scope' -Goal 'x' -AcceptanceCriteria 'y' -Repositories @('DevBridge') -FilesGlobs @('src/**')
$cWUP = Classify-DevBridgeTask -Task $wuTask -ClassifiedAtUtc '2026-08-30T00:00:00Z'
$secsWU = Get-DbM18ContextSections -Task $wuTask
$bWU = New-ContextBudget -TaskId 'LG-PKG' -AllowedInputTokens 20000 -Sections $secsWU
$pkgWU1 = Build-ContextPackage -Task $wuTask -Classification $cWUP -Budget $bWU -Sections $secsWU -GeneratedAtUtc '2026-08-30T00:00:00Z'
$pkgWU2 = Build-ContextPackage -Task $wuTask -Classification $cWUP -Budget $bWU -Sections $secsWU -DevelopmentControlRole 'Products' -GeneratedAtUtc '2026-08-30T00:00:00Z'
Assert-True ($pkgWU1.Status -eq 'OK') 'S31 Work Universe package builds OK'
Assert-True ($pkgWU1.WorkUniverse -eq 'Foundation' -and $pkgWU1.NodeAddress -eq 'Foundation:LG-PKG') 'S31 package defaults Foundation'
Assert-True ($pkgWU2.WorkUniverse -eq 'Products' -and $pkgWU2.NodeAddress -eq 'Products:LG-PKG') 'S31 package honors explicit Products role'
Assert-True ($pkgWU1.PackageHash -eq $pkgWU2.PackageHash) 'S31 additive WorkUniverse keys do NOT change PackageHash'
$sumWU = Get-ContextPackageSummary -Package $pkgWU2
Assert-True ($sumWU.WorkUniverse -eq 'Products' -and $sumWU.DevelopmentControlRole -eq 'Products' -and $sumWU.NodeAddress -eq 'Products:LG-PKG') 'S31 package summary carries Work Universe fields'
$sumWUmd = Get-ContextPackageSummary -Package $pkgWU2 -AsMarkdown
Assert-True ($sumWUmd -match 'Products:LG-PKG') 'S31 markdown summary renders the node address'

# -----------------------------------------------------------------------------
# Cleanup + summary
# -----------------------------------------------------------------------------
Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ""
# Cross-tree scenarios that could not run are reported, never silently dropped: a run
# that skipped them is not the same evidence as a run that executed them.
Write-Output ("DB-M18 HOST SKIPS: {0}" -f $script:HostSkips.Count)
foreach ($s in $script:HostSkips) { Write-Output ("  [SKIP] " + $s) }
Write-Output ("DB-M18 classification/context tests: {0} checks, {1} failures." -f $script:Results, $script:Fails)
if ($script:Fails -gt 0) { exit 1 } else { exit 0 }

# Test-DbM27Calculator.ps1 -- DB-M27 AI Cost Calculator UI test suite (46 scenarios, S1-S46).
#
# Objective (the brief): an operator-facing AI Cost Calculator UI that ESTIMATES
# the expected monetary cost of a model/provider configuration BEFORE execution.
# Calculation/UI only -- the calculator never executes a provider/model, never
# makes a paid API call, and never makes a network call.
#
# Every scenario runs deterministically against the real DB-M14..M26 implementations
# consumed READ-ONLY (SHA-256 verified byte-identical before/after the run) plus
# deterministic synthetic fixtures. DB-M16 is the authoritative cost engine; DB-M27
# never duplicates pricing formulas or data. DB-M18.1 is preserved (R43 runs its
# child suite and asserts the KNOWN pre-existing external R45 signature).
#
# AUTO_EXECUTION_ENABLED = FALSE. Provider/model executed: NO. Paid calls: 0.
# Network calls: 0.
#
# Exit code: 0 = all 45 scenarios + all regressions passed; 1 = any failure.
# Prints "DB-M27 TEST SUMMARY: <passed> passed, <failed> failed".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "CalculatorRender.ps1")    # renderer (dot-sources engine -> contracts -> read-only reuse chain)

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# DB-M18.1 dependency lineage, the operator console, the Forge solution and the
# governed task state stayed in Forge at W6/LaneA -- none of them is AI
# implementation. Assertions about them are CROSS-TREE and the host root is
# resolved explicitly; see ai-routing\AiHostRoot.ps1. When it is not declared those
# assertions report a SKIP instead of resolving a guessed path.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'AiHostRoot.ps1')
$script:ForgeRoot = Resolve-ForgeHostRoot
$script:HostSkips = New-Object System.Collections.Generic.List[string]
$script:NowUtc = '2026-08-31T12:00:00Z'   # deterministic reference
$script:CalcFiles = @(
    'ai-routing\calculator\CalculatorContracts.ps1',
    'ai-routing\calculator\CalculatorEngine.ps1',
    'ai-routing\calculator\CalculatorRender.ps1',
    'ai-routing\calculator\Test-DbM27Calculator.ps1'
)
# The RUNTIME library (the calculator itself), scanned by the no-mutation /
# no-execution proofs. The test harness is deliberately excluded: its own
# assertion needles are the forbidden tokens, and the harness is never part of
# the runtime -- the proof is about what the calculator LIBRARY can do.
$script:LibraryFiles = @(
    'ai-routing\calculator\CalculatorContracts.ps1',
    'ai-routing\calculator\CalculatorEngine.ps1',
    'ai-routing\calculator\CalculatorRender.ps1'
)

# --- assertion helpers (must return nothing) -----------------------------------------

$script:TestCount = 0
$script:TestFails = New-Object System.Collections.Generic.List[string]
$script:ScenarioFails = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:TestCount++
    if (-not $Condition) { $script:TestFails.Add($Message) }
}
function Assert-Null {
    param($Actual, [string]$Message)
    $script:TestCount++
    if ($null -ne $Actual) { $script:TestFails.Add("$Message (expected null, got '$Actual')") }
}
function Assert-NotNull {
    param($Actual, [string]$Message)
    $script:TestCount++
    if ($null -eq $Actual) { $script:TestFails.Add("$Message (expected non-null, got null)") }
}
function Assert-Near {
    param($Actual, $Expected, [double]$Tolerance = 0.0001, [string]$Message = '')
    $script:TestCount++
    if ($null -eq $Actual -or $null -eq $Expected) {
        if ($null -ne $Actual -or $null -ne $Expected) { $script:TestFails.Add("$Message (null mismatch: actual=$Actual expected=$Expected)") }
        return
    }
    if ([math]::Abs([double]$Actual - [double]$Expected) -gt $Tolerance) {
        $script:TestFails.Add("$Message (actual=$Actual expected=$Expected)")
    }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:TestCount++
    if ("$Actual" -ne "$Expected") { $script:TestFails.Add("$Message (actual='$Actual' expected='$Expected')") }
}
function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Message)
    $script:TestCount++
    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $script:TestFails.Add("$Message (missing '$Needle')")
    }
}
function Assert-NotContains {
    param([string]$Text, [string]$Needle, [string]$Message)
    $script:TestCount++
    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $script:TestFails.Add("$Message (unexpected '$Needle' present)")
    }
}

# --- fixture helpers -------------------------------------------------------------------

$script:Config = $null
function Get-Cfg {
    if ($null -eq $script:Config) { $script:Config = Import-AiCostConfiguration }
    return $script:Config
}

function New-CfgWithGatewayLocal {
    <#
    .SYNOPSIS
    Clone the real cost configuration and add two deterministic fixture models:
    an OpenRouter GATEWAY route (or:anthropic/claude-sonnet-5) and a LOCAL model
    (local/local-7b). The catalogue/providers/pricing remain the real config data.
    #>
    $cfg = Get-Cfg
    $models = @{}
    foreach ($k in @($cfg.Models.Keys)) { $models[$k] = $cfg.Models[$k] }
    $gw = New-AiModel -ModelId 'or:anthropic/claude-sonnet-5' -ProviderId 'openrouter' `
        -ProviderModelId 'anthropic/claude-sonnet-5' -UnderlyingModelId 'claude-sonnet-5' `
        -GatewayProviderId 'openrouter' -LocalOrRemote 'REMOTE' -Enabled $true
    $lc = New-AiModel -ModelId 'local-7b' -ProviderId 'local' -ProviderModelId 'local-7b' `
        -UnderlyingModelId 'local-7b' -LocalOrRemote 'LOCAL'
    $models[$gw.ModelId] = $gw
    $models[$lc.ModelId] = $lc
    $cfg.Models = $models
    return $cfg
}

function New-Req {
    <#
    .SYNOPSIS
    Default deterministic request: anthropic / DIRECT / claude-sonnet-5.
    #>
    param(
        [string]$ProviderId = 'anthropic', [string]$RouteType = 'DIRECT', [string]$ModelId = 'claude-sonnet-5',
        [string]$UnderlyingModelId = '', [string]$PricingRecordId = '', [string]$ReasoningLevel = '',
        [long]$InputTokens = 10000, [long]$OutputTokens = 2000, [long]$CachedInputTokens = 5000,
        [long]$CacheWriteTokens = 1000, [long]$AttemptCount = 1, [long]$ExpectedCorrectionAttempts = 0,
        [object[]]$EscalationPath = $null, [string]$CurrencyTarget = 'USD', [string]$NowUtc = $script:NowUtc
    )
    return New-DbM27CalculatorRequest -ProviderId $ProviderId -RouteType $RouteType -ModelId $ModelId `
        -UnderlyingModelId $UnderlyingModelId -PricingRecordId $PricingRecordId -ReasoningLevel $ReasoningLevel `
        -InputTokens $InputTokens -OutputTokens $OutputTokens -CachedInputTokens $CachedInputTokens `
        -CacheWriteTokens $CacheWriteTokens -AttemptCount $AttemptCount -ExpectedCorrectionAttempts $ExpectedCorrectionAttempts `
        -EscalationPath $EscalationPath -CurrencyTarget $CurrencyTarget -NowUtc $NowUtc
}

function New-Att {
    <#
    .SYNOPSIS
    Deterministic synthetic AiAttemptRecord v1 (DB-M17) for quality/performance
    fixtures. Never writes to disk. CostCurrency defaults to USD to match the
    reporting currency (DB-M25 never re-converts historic costs) and carries the
    LocalOrRemote route dimension DB-M25 filters on.
    #>
    param(
        [string]$TaskId, [string]$ChangeId = $null, [string]$AttemptId, [string]$Result = 'SUCCESS', [string]$VerificationResult = 'VERIFIED',
        [double]$ActualCost, [string]$CostCurrency = 'USD',
        [string]$ProviderId = 'anthropic', [string]$ModelId = 'claude-sonnet-5',
        [string]$UnderlyingModelId = 'claude-sonnet-5', [string]$GatewayProviderId = '',
        [string]$LocalOrRemote = 'REMOTE',
        [string]$StartedAtUtc = '2026-08-20T10:00:00Z', [string]$EndedAtUtc = '2026-08-20T10:00:30Z'
    )
    # Resolve-AiTaskKey (DB-M24) prefers ChangeId over TaskId when chaining attempts.
    # Default the change key to the task id so every fixture task is its own chain
    # (SampleCount == number of tasks; a shared ChangeId would collapse them all).
    $change = if ([string]::IsNullOrWhiteSpace($ChangeId)) { $TaskId } else { $ChangeId }
    $rec = New-AiAttemptRecord -TaskId $TaskId -ChangeId $change -AttemptId $AttemptId -RetryNumber 0 `
        -Result $Result -VerificationResult $VerificationResult -FailureCategory $null `
        -ActualCost $ActualCost -EstimatedCost $null -CostCurrency $CostCurrency `
        -ProviderId $ProviderId -ModelId $ModelId -UnderlyingModelId $UnderlyingModelId `
        -GatewayProviderId $GatewayProviderId -ReasoningLevel 'MEDIUM' -TaskType 'IMPLEMENTATION' `
        -Complexity 'MEDIUM' -Risk 'LOW' -ExecutionMode 'ASSISTED' `
        -StartedAtUtc $StartedAtUtc -EndedAtUtc $EndedAtUtc
    $rec | Add-Member -MemberType NoteProperty -Name 'LocalOrRemote' -Value $LocalOrRemote -Force
    return $rec
}

function New-QualityFixtures {
    <#
    .SYNOPSIS
    N verified-success attempts for anthropic/claude-sonnet-5 at a fixed INR cost.
    Each task has exactly one attempt, so VerifiedSuccessRate = 1.0 and
    AverageAttemptsPerVerifiedSuccess = 1.0.
    #>
    param([int]$Count = 30)
    $list = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -le $Count; $i++) {
        $list.Add((New-Att -TaskId ('t' + $i) -AttemptId ('a' + $i) -ActualCost 3.5 -StartedAtUtc ('2026-08-2' + (1 + ($i % 9)) + 'T10:00:00Z') -EndedAtUtc ('2026-08-2' + (1 + ($i % 9)) + 'T10:00:30Z')))
    }
    return @($list.ToArray())
}

function Get-FxInr {
    <#
    .SYNOPSIS
    The USD->INR exchange-rate record from the config (DB-M16 read-only).
    #>
    $cfg = Get-Cfg
    foreach ($k in @($cfg.ExchangeRates.Keys)) {
        $x = $cfg.ExchangeRates[$k]
        if ([string](Get-ContractProperty $x 'QuoteCurrency' '') -eq 'INR' -and $null -ne $x.Rate) { return $x }
    }
    return $null
}

function New-BudgetPolicyFixture {
    return New-BudgetPolicy -PolicyId 'db27-budget-test' -Name 'DB-M27 test policy' -Enabled $true `
        -Currency 'INR' -TaskLimit 100 -ChangeLimit 500 -SessionLimit 1000 -DailyLimit 2000 -MonthlyLimit 50000 `
        -WarnAtPercent 80 -BlockAtPercent 100 -UnknownCostPolicy 'WARN'
}

# --- SHA / frozen-file infrastructure ---------------------------------------------------

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead((Resolve-Path $Path))
    try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
    return ([BitConverter]::ToString($hash) -replace '-', '')
}

$script:FrozenFiles = @(
    'ai-routing\AiRoutingFoundation.ps1',
    'ai-routing\ModelCatalogue.ps1',
    'ai-routing\AiRoutingPricingFoundation.ps1',
    'ai-routing\AiPricingContracts.ps1',
    'ai-routing\PricingCatalogue.ps1',
    'ai-routing\AiRoutingCostFoundation.ps1',
    'ai-routing\AiCostContracts.ps1',
    'ai-routing\AiExchangeRates.ps1',
    'ai-routing\CostCalculator.ps1',
    'ai-routing\AttemptStore.ps1',
    'ai-routing\providers\common\AdapterContracts.ps1',
    'ai-routing\providers\common\AdapterExecutionGate.ps1',
    'ai-routing\budget\BudgetPolicy.ps1',
    'ai-routing\budget\BudgetEngine.ps1',
    'ai-routing\quality-cost\AiQualityCostContracts.ps1',
    'ai-routing\quality-cost\QualityCost.ps1',
    'ai-routing\performance\AiPerformanceContracts.ps1',
    'ai-routing\performance\AiPerformanceFoundation.ps1',
    'ai-routing\performance\ModelPerformance.ps1',
    'ai-routing\dashboard\DashboardContracts.ps1',
    'ai-routing\dashboard\DashboardData.ps1',
    'ai-routing\dashboard\DashboardRender.ps1'
)
# DB-M18.1 dependency lineage is Forge development-lifecycle logic and stayed in
# Forge; it is not reachable from the AI material root. Kept as a no-mutation guard
# against the DECLARED host root, so the protection survives the move instead of
# being dropped.
$script:ForgeFrozenFiles = @(
    'scripts\ai-routing\DependencyLineage.ps1',
    'scripts\ai-routing\Test-DbM181DependencyLineage.ps1'
)
$script:ShaBefore = @{}
foreach ($rel in $script:FrozenFiles) { $script:ShaBefore[$rel] = Get-Sha256 (Join-Path $script:Root $rel) }
if ($script:ForgeRoot) {
    foreach ($rel in $script:ForgeFrozenFiles) { $script:ShaBefore[$rel] = Get-Sha256 (Join-Path $script:ForgeRoot $rel) }
    $script:ForgeFrozenBefore = $true
} else {
    $script:ForgeFrozenBefore = $false
    $script:HostSkips.Add('S46 Forge DB-M18.1 frozen-file guard: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT)')
}

$script:ConfigFiles = @(
    'config\providers.json',
    'config\models.json',
    'config\ai-routing.json',
    'config\pricing\pricing-catalogue.json',
    'config\currency\exchange-rates.json',
    'config\cost\cost-calculator.json',
    'config\performance\confidence-bands.json'
)
$script:CfgShaBefore = @{}
foreach ($rel in $script:ConfigFiles) { $script:CfgShaBefore[$rel] = Get-Sha256 (Join-Path $script:Root $rel) }

$script:WorkbookPath = 'C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx'
$script:WorkbookShaBefore = Get-Sha256 $script:WorkbookPath

$script:UiFiles = @()
if ($script:ForgeRoot) {
    $uiDir = Join-Path $script:ForgeRoot 'src\DevBridge.UI'
    if (Test-Path -LiteralPath $uiDir) {
        $script:UiFiles = @(Get-ChildItem $uiDir -Recurse -File -Include *.xaml,*.cs -ErrorAction SilentlyContinue)
    }
}
$script:UiShaBefore = @{}
foreach ($f in $script:UiFiles) { $script:UiShaBefore[$f.FullName] = Get-Sha256 $f.FullName }

# --- regression suites (child processes; read-only over the DB-M27 scope) ----------------

function Invoke-RegressionSuite {
    <#
    .SYNOPSIS
    Run a frozen dependency suite as a CHILD process (read-only over the DB-M27
    scope) and parse its outcome. Child suites use varied summary formats, so the
    parser accepts: 'TEST SUMMARY: N passed, M failed', 'N assertions, M failed',
    'N checks, A passed, B failed', and falls back to counting PASS:/FAIL: lines.
    #>
    param([string]$Name, [string]$Path, [string]$Root)
    # $Root is explicit so a regression suite that lives in the Forge host (DB-M18.1)
    # resolves against the host root instead of the AI material root.
    $base = if ($Root) { $Root } else { $script:Root }
    $full = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $base $Path }
    $log = Join-Path $env:TEMP ("db27-reg-" + $Name + '.log')
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $full > $log 2>&1
    $exit = $LASTEXITCODE
    $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
    $passed = -1
    $failed = -1
    $m = [regex]::Match($text, 'TEST SUMMARY:\s*(\d+)\s+passed,\s*(\d+)\s+failed')
    if ($m.Success) { $passed = [int]$m.Groups[1].Value; $failed = [int]$m.Groups[2].Value }
    if (-not $m.Success) {
        $m = [regex]::Match($text, '(\d+)\s+assertions?,\s*(\d+)\s+failed')
        if ($m.Success) { $passed = [int]$m.Groups[1].Value; $failed = [int]$m.Groups[2].Value }
    }
    if (-not $m.Success) {
        $m = [regex]::Match($text, '(\d+)\s+checks?,\s*(\d+)\s+passed,\s*(\d+)\s+failed')
        if ($m.Success) { $passed = [int]$m.Groups[2].Value; $failed = [int]$m.Groups[3].Value }
    }
    if ($passed -lt 0) {
        $passed = ([regex]::Matches($text, '(?m)^\s*(PASS:|\[PASS\])')).Count
        $failed = ([regex]::Matches($text, '(?m)^\s*(FAIL:|\[FAIL\])')).Count
    }
    return @{ Name = $Name; Passed = $passed; Failed = $failed; ExitCode = $exit; Log = $text }
}

$script:RegressionResults = New-Object System.Collections.Generic.List[object]
$script:ExternalDrift = New-Object System.Collections.Generic.List[string]

# --- scenarios --------------------------------------------------------------------------

# S1 UI opens (renderer produces a self-contained HTML page)
function Test-S1-UiOpens {
    $cfg = Get-Cfg
    $view = Invoke-DbM27Calculator -Configuration $cfg -Request (New-Req)
    $html = ConvertTo-DbM27Html -View $view
    Assert-True (-not [string]::IsNullOrWhiteSpace($html)) 'S1: HTML is non-empty'
    Assert-True ($html.Length -gt 4000) 'S1: HTML is substantial'
    Assert-Contains $html '<!doctype html>' 'S1: doctype present'
    Assert-Contains $html 'AI Cost Calculator' 'S1: page title present'
    Assert-Contains $html 'sel-provider' 'S1: provider select present'
    Assert-Contains $html 'sel-route' 'S1: route select present'
    Assert-Contains $html 'db27-data' 'S1: embedded data present'
    Assert-Contains $html 'AUTO EXECUTION DISABLED' 'S1: no-execution badge present'
    Assert-Contains $html 'AUTO AI execution' 'S1: guard footer present'
    $tmp = Join-Path $env:TEMP 'db27-calculator.html'
    Export-DbM27CalculatorHtml -View $view -OutputPath $tmp
    Assert-True ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 4000)) 'S1: exported artifact written and non-empty'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# S2 provider selection resolves the real catalogue provider
function Test-S2-ProviderSelection {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req)
    Assert-True $view.Scenario.ProviderFound 'S2: provider found'
    Assert-Equal $view.Scenario.ProviderId 'anthropic' 'S2: provider id round-trips'
    Assert-Equal $view.Scenario.RouteType 'DIRECT' 'S2: direct route default'
    $sel = New-DbM27SelectorData -Configuration (Get-Cfg) -NowUtc $script:NowUtc
    Assert-True (@($sel.Providers | Where-Object { $_.ProviderId -eq 'anthropic' }).Count -eq 1) 'S2: selector lists anthropic'
}

# S3 route DIRECT
function Test-S3-RouteDirect {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -RouteType 'DIRECT')
    Assert-Equal $view.Scenario.RouteType 'DIRECT' 'S3: DIRECT route accepted'
    Assert-Equal $view.Estimate.CalculationStatus 'COMPLETE' 'S3: direct estimate computed'
    Assert-Equal $view.Pricing.BillingProviderId 'anthropic' 'S3: direct bills the provider itself'
}

# S4 route GATEWAY
function Test-S4-RouteGateway {
    $cfg = New-CfgWithGatewayLocal
    $view = Invoke-DbM27Calculator -Configuration $cfg -Request (New-Req -ProviderId 'openrouter' -RouteType 'GATEWAY' -ModelId 'or:anthropic/claude-sonnet-5' -UnderlyingModelId 'claude-sonnet-5')
    Assert-Equal $view.Scenario.RouteType 'GATEWAY' 'S4: GATEWAY route accepted'
    Assert-Equal $view.Scenario.GatewayProviderId 'openrouter' 'S4: gateway identity = openrouter'
    Assert-Equal $view.Scenario.UnderlyingModelId 'claude-sonnet-5' 'S4: underlying model preserved'
}

# S5 route LOCAL
function Test-S5-RouteLocal {
    $cfg = New-CfgWithGatewayLocal
    $view = Invoke-DbM27Calculator -Configuration $cfg -Request (New-Req -ProviderId 'local' -RouteType 'LOCAL' -ModelId 'local-7b')
    Assert-Equal $view.Scenario.RouteType 'LOCAL' 'S5: LOCAL route accepted'
    Assert-Equal $view.Scenario.LocalOrRemote 'LOCAL' 'S5: local model classified LOCAL'
}

# S6 model selection validated against provider+route
function Test-S6-ModelSelection {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req)
    Assert-True $view.Scenario.ModelFound 'S6: model found'
    Assert-Equal $view.Scenario.ModelLookupState 'FOUND' 'S6: model lookup FOUND'
    $bad = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -ProviderId 'anthropic' -ModelId 'deepseek-v4-flash')
    Assert-Equal $bad.Scenario.ModelLookupState 'INVALID_ROUTE' 'S6: wrong-provider model rejected'
}

# S7 underlying-model display for gateway
function Test-S7-UnderlyingDisplay {
    $cfg = New-CfgWithGatewayLocal
    $view = Invoke-DbM27Calculator -Configuration $cfg -Request (New-Req -ProviderId 'openrouter' -RouteType 'GATEWAY' -ModelId 'or:anthropic/claude-sonnet-5' -UnderlyingModelId 'claude-sonnet-5')
    Assert-Equal $view.Scenario.UnderlyingModelId 'claude-sonnet-5' 'S7: underlying model displayed'
    Assert-Equal $view.Pricing.BillingModelId 'claude-sonnet-5' 'S7: underlying model is the billed model'
    Assert-Equal $view.Pricing.BillingProviderId 'anthropic' 'S7: underlying model provider used for pricing'
}

# S8 pricing-version display (record id + status + window)
function Test-S8-PricingVersion {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req)
    Assert-Equal $view.Pricing.PricingRecordId 'anthropic-claude-sonnet-5-standard-20260830' 'S8: pricing record id shown'
    Assert-Equal $view.Pricing.PricingRecordStatus 'NEEDS_REVIEW' 'S8: effective record status shown (governed NEEDS_REVIEW at ref time)'
    Assert-Equal $view.Pricing.PriceLookupState 'FOUND' 'S8: price lookup FOUND'
    Assert-Equal $view.Pricing.EffectiveFromUtc '2026-08-30T00:00:00Z' 'S8: effective window from shown'
    Assert-Equal $view.Pricing.Source 'reference' 'S8: pricing source shown'
}

# S9 input-token calc (uncached input at input price)
function Test-S9-InputCost {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -InputTokens 10000 -OutputTokens 0 -CachedInputTokens 0 -CacheWriteTokens 0)
    Assert-Near $view.Estimate.InputCost 0.02 0.0000001 'S9: input cost = 10000/1M * 2.0'
}

# S10 output-token calc
function Test-S10-OutputCost {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -InputTokens 0 -OutputTokens 2000 -CachedInputTokens 0 -CacheWriteTokens 0)
    Assert-Near $view.Estimate.OutputCost 0.02 0.0000001 'S10: output cost = 2000/1M * 10.0'
}

# S11 cached-input calc at the cached rate
function Test-S11-CachedInputCost {
    # EstimatedInputTokens is the TOTAL (incl. cached): total 5000, all cached -> uncached 0.
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -InputTokens 5000 -OutputTokens 0 -CachedInputTokens 5000 -CacheWriteTokens 0)
    Assert-Near $view.Estimate.CachedInputCost 0.001 0.0000001 'S11: cached input cost = 5000/1M * 0.2'
    Assert-Near $view.Estimate.InputCost 0 0.0000001 'S11: all input cached -> uncached input cost 0'
}

# S12 cache-write calc (5m) where supported; null where the record has no cache-write dimension
function Test-S12-CacheWriteCost {
    # DB-M16 bills cache-write (5m/1h) ONLY on ACTUAL usage. An ESTIMATE can never
    # charge cache-write, so it must be null with the explicit billing note -- never
    # a fabricated zero, never a made-up charge.
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -InputTokens 0 -OutputTokens 0 -CachedInputTokens 0 -CacheWriteTokens 1000)
    Assert-Null $view.Estimate.CacheWrite5mCost 'S12: cache-write never billed on an ESTIMATE (DB-M16 ACTUAL-only)'
    Assert-NotNull $view.Estimate.CacheWriteBillingNote 'S12: explicit cache-write billing note present'
    # deepseek record has no cache-write dimension -> cost stays null (never invented)
    $ds = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -PricingRecordId 'ds-v4flash-peak-20260830' -InputTokens 10000 -OutputTokens 2000 -CachedInputTokens 5000 -CacheWriteTokens 1000)
    Assert-Null $ds.Estimate.CacheWrite5mCost 'S12: cache-write unsupported -> null (where supported rule)'
    Assert-Near $ds.Estimate.InputCost 0.0022 0.0000001 'S12: deepseek uncached input cost = 5000/1M * 0.44'
}

# S13 total cost (subtotal + converted total in USD)
function Test-S13-TotalCost {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -InputTokens 10000 -OutputTokens 2000 -CachedInputTokens 5000 -CacheWriteTokens 1000)
    Assert-Near $view.Estimate.Subtotal 0.0310 0.0000001 'S13: subtotal = uncached 0.01 + output 0.02 + cached 0.001 (cache-write not billed on estimates)'
    Assert-Near $view.Estimate.ConvertedTotal 0.0310 0.0000001 'S13: converted total (USD) = subtotal'
    Assert-Equal $view.Estimate.TargetCurrency 'USD' 'S13: USD target'
}

# S14 multi-attempt total
function Test-S14-MultiAttempt {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -InputTokens 10000 -OutputTokens 2000 -CachedInputTokens 5000 -CacheWriteTokens 1000 -AttemptCount 2 -ExpectedCorrectionAttempts 1)
    Assert-Equal $view.Estimate.AttemptsTotal 3 'S14: attempts total = 2 + 1'
    Assert-Near $view.Estimate.TotalMultiAttemptCost 0.0930 0.0000001 'S14: multi-attempt = 3 x 0.0310'
    Assert-Near $view.Estimate.PerAttemptCost 0.0310 0.0000001 'S14: per-attempt = 0.0310'
}

# S15 USD target
function Test-S15-Usd {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -CurrencyTarget 'USD')
    Assert-Equal $view.Estimate.TargetCurrency 'USD' 'S15: USD currency'
    Assert-Equal $view.Estimate.CostCurrency 'USD' 'S15: cost currency USD'
    Assert-Near $view.Estimate.ConvertedTotal $view.Estimate.Subtotal 0.0000001 'S15: USD conversion is identity'
}

# S16 INR target (converted via the DB-M16 effective rate)
function Test-S16-Inr {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -CurrencyTarget 'INR')
    Assert-Equal $view.Estimate.TargetCurrency 'INR' 'S16: INR currency'
    Assert-Equal $view.Estimate.CostCurrency 'INR' 'S16: cost currency INR'
    Assert-True ($view.Estimate.ExchangeRateId -match '^fx-usdinr-dev-') 'S16: effective USD->INR rate id used'
    Assert-NotNull $view.Estimate.ExchangeRate 'S16: exchange rate resolved'
    Assert-Near $view.Estimate.ConvertedTotal ([double]$view.Estimate.Subtotal * [double]$view.Estimate.ExchangeRate) 0.00001 'S16: converted total = subtotal * rate'
    Assert-True ($view.Estimate.ConvertedTotal -gt 0) 'S16: INR estimate positive'
}

# S17 actual vs estimated distinction
function Test-S17-ActualVsEstimated {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req)
    Assert-Equal $view.Estimate.EstimatedOrActual 'ESTIMATED' 'S17: estimated flag'
    Assert-Equal $view.Estimate.UsageSource 'ESTIMATED' 'S17: usage source ESTIMATED'
    Assert-Null $view.Estimate.ActualCost 'S17: no actual cost (nothing executed)'
    Assert-NotNull $view.Estimate.EstimatedCost 'S17: estimated cost present'
    Assert-Contains (ConvertTo-DbM27Html -View $view) 'Actual-vs-estimated' 'S17: UI labels the distinction'
}

# S18 missing pricing (explicit state, never invented)
function Test-S18-MissingPricing {
    # claude-opus-5 exists in the model catalogue but has NO pricing record
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -ModelId 'claude-opus-5')
    Assert-Equal $view.Pricing.PriceLookupState 'NOT_FOUND' 'S18: lookup NOT_FOUND'
    Assert-Equal $view.Estimate.CalculationStatus 'PRICE_NOT_FOUND' 'S18: calculation PRICE_NOT_FOUND'
    Assert-Null $view.Estimate.PerAttemptCost 'S18: no fabricated price'
    Assert-Equal $view.Pricing.PriceStatus 'PRICE_UNKNOWN' 'S18: remote price unknown'
    $html = ConvertTo-DbM27Html -View $view
    Assert-Contains $html 'PRICE_NOT_FOUND' 'S18: UI shows the explicit missing-pricing state'
}

# S19 unknown local cost (never fabricated zero)
function Test-S19-UnknownLocalCost {
    $cfg = New-CfgWithGatewayLocal
    $view = Invoke-DbM27Calculator -Configuration $cfg -Request (New-Req -ProviderId 'local' -RouteType 'LOCAL' -ModelId 'local-7b')
    Assert-Equal $view.Pricing.PriceStatus 'LOCAL_COST_UNKNOWN' 'S19: LOCAL_COST_UNKNOWN'
    Assert-True $view.Pricing.OperationalCostUnknown 'S19: operational cost unknown'
    Assert-Equal $view.Pricing.ProviderTokenPrice 0 'S19: provider-level default is 0 ONLY at provider level'
    Assert-Null $view.Estimate.PerAttemptCost 'S19: no fabricated zero shown'
    $html = ConvertTo-DbM27Html -View $view
    Assert-Contains $html 'LOCAL_COST_UNKNOWN' 'S19: UI shows the unknown-local state'
    Assert-NotContains $html 'INR 0.00' 'S19: UI never shows a fabricated zero'
    Assert-NotContains $html 'USD 0.00' 'S19: UI never shows a fabricated zero'
}

# S20 LOCAL never assumed FREE
function Test-S20-LocalNeverFree {
    $cfg = New-CfgWithGatewayLocal
    $view = Invoke-DbM27Calculator -Configuration $cfg -Request (New-Req -ProviderId 'local' -RouteType 'LOCAL' -ModelId 'local-7b')
    Assert-True ($view.Pricing.PriceStatus -ne 'FREE') 'S20: no-record local is never FREE'
    Assert-Contains (ConvertTo-DbM27Html -View $view) 'LOCAL != FREE' 'S20: UI states the LOCAL != FREE invariant'
}

# S21 OpenRouter gateway identity (provider != underlying, not collapsed)
function Test-S21-OpenRouterIdentity {
    $cfg = New-CfgWithGatewayLocal
    $view = Invoke-DbM27Calculator -Configuration $cfg -Request (New-Req -ProviderId 'openrouter' -RouteType 'GATEWAY' -ModelId 'or:anthropic/claude-sonnet-5' -UnderlyingModelId 'claude-sonnet-5')
    Assert-Equal $view.Scenario.ProviderId 'openrouter' 'S21: provider is the gateway'
    Assert-Equal $view.Scenario.GatewayProviderId 'openrouter' 'S21: gateway identity openrouter'
    Assert-Equal $view.Scenario.UnderlyingModelId 'claude-sonnet-5' 'S21: underlying is the actual model'
    Assert-True ($view.Scenario.ProviderId -ne $view.Scenario.UnderlyingModelId) 'S21: provider and underlying are NOT collapsed'
    Assert-Equal $view.Pricing.BillingProviderId 'anthropic' 'S21: billing uses the underlying provider'
}

# S22 underlying model preserved end to end
function Test-S22-UnderlyingPreserved {
    $cfg = New-CfgWithGatewayLocal
    $view = Invoke-DbM27Calculator -Configuration $cfg -Request (New-Req -ProviderId 'openrouter' -RouteType 'GATEWAY' -ModelId 'or:anthropic/claude-sonnet-5' -UnderlyingModelId 'claude-sonnet-5')
    Assert-Equal $view.Scenario.UnderlyingModelId 'claude-sonnet-5' 'S22: underlying preserved in scenario'
    Assert-Equal $view.Pricing.BillingModelId 'claude-sonnet-5' 'S22: underlying preserved in billing'
    Assert-Equal $view.Request.UnderlyingModelId 'claude-sonnet-5' 'S22: underlying preserved in request echo'
}

# S23 reasoning-level selection (validated + billed per cost config INCLUDED_IN_OUTPUT, never double-charged)
function Test-S23-ReasoningLevel {
    $base = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -InputTokens 10000 -OutputTokens 2000)
    $level = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -InputTokens 10000 -OutputTokens 2000 -ReasoningLevel 'HIGH')
    Assert-Equal $level.Scenario.ReasoningLevel 'HIGH' 'S23: reasoning level selected'
    Assert-Near $level.Estimate.ConvertedTotal $base.Estimate.ConvertedTotal 0.0000001 'S23: reasoning billed INCLUDED_IN_OUTPUT (no double charge)'
    Assert-True ($level.Estimate.CalculationStatus -eq 'COMPLETE') 'S23: reasoning selection keeps estimate complete'
}

# S24 quality metric display (informational, from DB-M25)
function Test-S24-QualityDisplay {
    $records = New-QualityFixtures -Count 30
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req) -AttemptRecords $records
    Assert-True $view.Quality.HasEvidence 'S24: quality evidence present'
    Assert-Equal $view.Quality.SampleCount 30 'S24: sample size 30'
    Assert-Near $view.Quality.VerifiedSuccessRate 1.0 0.0001 'S24: verified success rate'
    Assert-Near $view.Quality.ObservedCostPerVerifiedSuccess 3.5 0.0001 'S24: observed cost per verified success = median chain cost'
    Assert-Near $view.Quality.ExpectedCostPerVerifiedSuccess 3.5 0.0001 'S24: expected cost per verified success = median chain cost'
    Assert-Equal $view.Quality.ExpectedCostBasis 'OBSERVED_CHAINS' 'S24: expected-cost basis OBSERVED_CHAINS'
    Assert-Equal $view.Quality.ConfidenceLevel 'MODERATE' 'S24: 30 chains -> MODERATE confidence'
}

# S25 low-confidence display (never statistically over-claimed)
function Test-S25-LowConfidence {
    $low = New-QualityFixtures -Count 3
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req) -AttemptRecords $low
    Assert-Equal $view.Quality.SampleCount 3 'S25: tiny sample'
    Assert-Equal $view.Quality.ConfidenceLevel 'INSUFFICIENT' 'S25: INSUFFICIENT confidence'
    Assert-Contains (ConvertTo-DbM27Html -View $view) 'not statistically reliable' 'S25: UI flags unreliable evidence'
    $high = New-QualityFixtures -Count 30
    $view2 = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req) -AttemptRecords $high
    Assert-Equal $view2.Quality.ConfidenceLevel 'MODERATE' 'S25: 30 chains -> MODERATE (confidence band 20-49)'
}

# S26 expected verified-success cost (basis OBSERVED_CHAINS / COLD_START_SIMPLE)
function Test-S26-ExpectedVerifiedSuccessCost {
    $records = New-QualityFixtures -Count 30
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req) -AttemptRecords $records
    Assert-NotNull $view.Quality.ExpectedCostPerVerifiedSuccess 'S26: expected cost per verified success present'
    Assert-Equal $view.Quality.ExpectedCostBasis 'OBSERVED_CHAINS' 'S26: expected-cost basis OBSERVED_CHAINS (MODERATE confidence)'
    Assert-Near $view.Quality.ExpectedCostPerVerifiedSuccess 3.5 0.0001 'S26: expected verified-success cost = 3.5'
    Assert-Near $view.Quality.AverageAttemptsPerVerifiedSuccess 1.0 0.0001 'S26: exactly one attempt per verified success'
}

# S27 escalation-chain estimate (read-only per-step M16 estimates)
function Test-S27-EscalationChain {
    $path = @(
        (New-DbM27EscalationStep -Step 1 -ProviderId 'anthropic' -ModelId 'claude-sonnet-5' -AttemptCount 1),
        (New-DbM27EscalationStep -Step 2 -ProviderId 'anthropic' -ModelId 'claude-haiku-4-5' -AttemptCount 1),
        (New-DbM27EscalationStep -Step 3 -ProviderId 'openai' -ModelId 'gpt-5.4' -AttemptCount 1)
    )
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -InputTokens 10000 -OutputTokens 2000 -CachedInputTokens 0 -CacheWriteTokens 0 -EscalationPath $path)
    Assert-Equal $view.EscalationTotal.HasPath $true 'S27: escalation path present'
    Assert-Equal $view.EscalationTotal.StepCount 3 'S27: three steps'
    Assert-Equal @($view.EscalationSteps).Count 3 'S27: three step rows'
    Assert-Near $view.EscalationSteps[0].PerAttemptCost 0.04 0.0001 'S27: step1 sonnet = 0.02 input + 0.02 output'
    Assert-Near $view.EscalationSteps[1].PerAttemptCost 0.02 0.0001 'S27: step2 haiku = 0.01 input + 0.01 output'
    Assert-Equal $view.EscalationTotal.SimulationOnly $true 'S27: simulation only'
    Assert-Equal $view.EscalationTotal.RoutingPolicyUnmodified $true 'S27: routing policy unmodified'
}

# S28 cumulative escalation cost
function Test-S28-CumulativeEscalation {
    $path = @(
        (New-DbM27EscalationStep -Step 1 -ProviderId 'anthropic' -ModelId 'claude-sonnet-5' -AttemptCount 1),
        (New-DbM27EscalationStep -Step 2 -ProviderId 'anthropic' -ModelId 'claude-haiku-4-5' -AttemptCount 1)
    )
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -InputTokens 10000 -OutputTokens 2000 -CachedInputTokens 0 -CacheWriteTokens 0 -EscalationPath $path)
    $cum1 = $view.EscalationSteps[0].CumulativeCost
    $cum2 = $view.EscalationSteps[1].CumulativeCost
    Assert-Near $cum1 0.04 0.0001 'S28: cumulative step1'
    Assert-Near $cum2 0.06 0.0001 'S28: cumulative step2 = 0.04 + 0.02'
    Assert-Near $view.EscalationTotal.CumulativeCost $cum2 0.0001 'S28: escalation total = final cumulative'
    Assert-True ($cum2 -gt $cum1) 'S28: cumulative strictly increases'
    foreach ($s in @($view.EscalationSteps)) {
        Assert-Equal $s.CalculationStatus 'COMPLETE' 'S28: every step priced'
        Assert-Near $s.StepTotal ([double]$s.PerAttemptCost * [long]$s.AttemptCount) 0.0001 'S28: step total = per-attempt x attempts'
    }
}

# S29 budget informational display (never grants)
function Test-S29-BudgetInformational {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -CurrencyTarget 'USD') -BudgetPolicy (New-BudgetPolicyFixture)
    Assert-True $view.Budget.HasPolicy 'S29: budget policy supplied'
    Assert-True $view.Budget.InformationalOnly 'S29: informational only'
    Assert-Equal $view.Budget.OverrideAllowed $false 'S29: override not allowed'
    Assert-True (@($view.Budget.ApplicableLimits | Where-Object { $_.Scope -eq 'TASK' }).Count -ge 1) 'S29: task limit row present'
    $task = @($view.Budget.ApplicableLimits | Where-Object { $_.Scope -eq 'TASK' })[0]
    Assert-Equal $task.Limit 100 'S29: task limit value'
    Assert-Near $task.ProjectedSpend 2.5885 0.0001 'S29: projected spend = 0.0310 USD @ fx 83.5 -> 2.5885 INR'
    Assert-Near $task.EstimatedPercentConsumed 2.5885 0.0001 'S29: estimated % consumed = projected / limit'
    Assert-Equal $task.Decision 'ALLOW' 'S29: within limits -> ALLOW (informational)'
    $html = ConvertTo-DbM27Html -View $view
    Assert-Contains $html 'INFORMATIONAL budget context' 'S29: UI labels budget as informational'
    Assert-Contains $html 'Est. % consumed' 'S29: UI shows estimated % consumed per scope'
    Assert-Contains $html 'Decision' 'S29: UI shows the per-scope warning/decision state'
    # A BLOCKED attempt is displayed as informational context but NEVER enforced or
    # overridden: the calculator reports the policy verdict and still has no capability.
    $polBlock = New-BudgetPolicy -PolicyId 'db27-block-test' -Name 'DB-M27 block test' -Enabled $true `
        -Currency 'INR' -TaskLimit 1 -WarnAtPercent 50 -BlockAtPercent 100 -UnknownCostPolicy 'WARN'
    $vb = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req -CurrencyTarget 'USD') -BudgetPolicy $polBlock
    Assert-Equal $vb.Budget.Decision 'REQUIRE_HUMAN_OVERRIDE' 'S29: over-limit policy verdict surfaced (informational)'
    $btask = @($vb.Budget.ApplicableLimits | Where-Object { $_.Scope -eq 'TASK' })[0]
    Assert-Equal $btask.Decision 'BLOCK_BUDGET_EXCEEDED' 'S29: per-scope block state surfaced'
    Assert-Equal $vb.Budget.OverrideAllowed $false 'S29: block never grants an override'
    Assert-True $vb.Budget.InformationalOnly 'S29: block context stays informational'
}

# S30 budget override impossible (no write token, never granted)
function Test-S30-BudgetOverrideImpossible {
    $guard = New-DbM27ReadOnlyGuard
    Assert-True $guard.BudgetPolicyUnmodified 'S30: guard says budget unmodified'
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req) -BudgetPolicy (New-BudgetPolicyFixture)
    Assert-Equal $view.Budget.OverrideAllowed $false 'S30: no override capability'
    Assert-True $view.Guard.BudgetPolicyUnmodified 'S30: engine guard budget unmodified'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Test-AiBudgetOverride' "S30: calculator never grants overrides ($rel)"
    }
}

# S31 routing modification impossible
function Test-S31-RoutingImpossible {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req)
    Assert-True $view.Guard.RoutingPolicyUnmodified 'S31: routing unmodified'
    Assert-Equal $view.EscalationTotal.RoutingPolicyUnmodified $true 'S31: escalation never routes'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Get-AiEscalationDecision' "S31: no escalation decision call ($rel)"
        Assert-NotContains $text 'New-RoutingDecision' "S31: no routing decision construction ($rel)"
    }
}

# S32 pricing modification impossible
function Test-S32-PricingImpossible {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req)
    Assert-True $view.Guard.PricingUnmodified 'S32: pricing unmodified'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Add-AiPricingRecord' "S32: no pricing record write ($rel)"
        Assert-NotContains $text 'Add-AiPriceVersion' "S32: no pricing version write ($rel)"
    }
}

# S33 provider-health modification impossible
function Test-S33-HealthImpossible {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req)
    Assert-True $view.Guard.ProviderHealthUnmodified 'S33: health unmodified'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Set-ProviderHealth' "S33: no health write ($rel)"
    }
}

# S34 model execution impossible
function Test-S34-ExecutionImpossible {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req)
    Assert-Equal $view.Guard.AutoExecutionEnabled $false 'S34: auto execution disabled'
    Assert-Equal $view.Guard.ProviderModelExecuted $false 'S34: no provider/model executed'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Invoke-Provider' "S34: no provider invoke ($rel)"
        Assert-NotContains $text 'Send-ProviderRequest' "S34: no provider send ($rel)"
    }
}

# S35 paid calls = 0
function Test-S35-PaidCallsZero {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req)
    Assert-Equal $view.Guard.PaidApiCalls 0 'S35: zero paid API calls'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Invoke-WebRequest' "S35: no web request ($rel)"
        Assert-NotContains $text 'Invoke-RestMethod' "S35: no rest call ($rel)"
        Assert-NotContains $text 'HttpClient' "S35: no http client ($rel)"
    }
}

# S36 network calls = 0
function Test-S36-NetworkZero {
    $view = Invoke-DbM27Calculator -Configuration (Get-Cfg) -Request (New-Req)
    Assert-Equal $view.Guard.NetworkCalls 0 'S36: zero network calls'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'System.Net.WebClient' "S36: no webclient ($rel)"
        Assert-NotContains $text 'Start-Process' "S36: no process spawn ($rel)"
        Assert-NotContains $text 'Invoke-Expression' "S36: no dynamic invocation ($rel)"
    }
}

# S37 DB-M16 regression
function Test-S37-M16Regression {
    $r = Invoke-RegressionSuite -Name 'DBM16' -Path 'ai-routing\Test-AiCostCalculator.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.ExitCode -eq 0) 'S37: DB-M16 regression exit 0'
    Assert-True ($r.Failed -eq 0) 'S37: DB-M16 regression zero failures'
}

# S38 DB-M21 regression
function Test-S38-M21Regression {
    $r = Invoke-RegressionSuite -Name 'DBM21' -Path 'ai-routing\budget\Test-DbM21Budget.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.ExitCode -eq 0) 'S38: DB-M21 regression exit 0'
    Assert-True ($r.Failed -eq 0) 'S38: DB-M21 regression zero failures'
}

# S39 DB-M23 regression
function Test-S39-M23Regression {
    $r = Invoke-RegressionSuite -Name 'DBM23' -Path 'ai-routing\providers\Test-DbM23Providers.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.ExitCode -eq 0) 'S39: DB-M23 regression exit 0'
    Assert-True ($r.Failed -eq 0) 'S39: DB-M23 regression zero failures'
}

# S40 DB-M24 regression
function Test-S40-M24Regression {
    $r = Invoke-RegressionSuite -Name 'DBM24' -Path 'ai-routing\performance\Test-AiModelPerformance.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.ExitCode -eq 0) 'S40: DB-M24 regression exit 0'
    Assert-True ($r.Failed -eq 0) 'S40: DB-M24 regression zero failures'
}

# S41 DB-M25 regression
function Test-S41-M25Regression {
    $r = Invoke-RegressionSuite -Name 'DBM25' -Path 'ai-routing\quality-cost\Test-DbM25QualityCost.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.ExitCode -eq 0) 'S41: DB-M25 regression exit 0'
    Assert-True ($r.Failed -eq 0) 'S41: DB-M25 regression zero failures'
    Assert-True ($r.Passed -ge 300) 'S41: DB-M25 regression substantial pass count'
}

# S42 DB-M26 regression
function Test-S42-M26Regression {
    $r = Invoke-RegressionSuite -Name 'DBM26' -Path 'ai-routing\dashboard\Test-DbM26Dashboard.ps1'
    $script:RegressionResults.Add($r)
    # The DB-M26 suite freezes the canonical workbook authority hash (F520060C).
    # The workbook was legitimately changed by DB-M12.4's live trial-cycle closure
    # on 2026-08-31 (current SHA 6D42C3BF...), so S41 is a KNOWN EXTERNAL drift --
    # never a DB-M27 failure. Assert the preserved signature: 381 passed / 1 failed.
    Assert-Equal $r.Passed 381 'S42: DB-M26 suite still 381 passed'
    Assert-Equal $r.Failed 1 'S42: DB-M26 suite still exactly 1 failed (S41, external workbook-authority drift)'
    Assert-Contains $r.Log 'S41' 'S42: the single failure is the known S41'
    Assert-Contains $r.Log 'F520060C' 'S42: S41 failure names the stale recorded authority hash'
    $script:ExternalDrift.Add('M26 S41 workbook-authority drift (suite records F520060C; live workbook is 6D42C3BF after DB-M12.4 closure 2026-08-31)')
}

# S43 DB-M18.1 preserved (child suite is green; R45 has relocated, not failed)
function Test-S43-M181Preserved {
    if (-not $script:ForgeRoot) {
        $script:HostSkips.Add('S43 DB-M18.1 preservation: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT); the suite is Forge-owned')
        return
    }
    $r = Invoke-RegressionSuite -Name 'DBM181' -Path 'scripts\ai-routing\Test-DbM181DependencyLineage.ps1' -Root $script:ForgeRoot
    $script:RegressionResults.Add($r)
    # This assertion used to pin the child suite at exactly one failure and name R45
    # as it. R45 ran the DB-M18 classification suite as a child; that suite is AI Head
    # material and moved there, so from Forge R45 can no longer run and the child now
    # reports it as an explicit SKIP -- a relocation, not a defect -- while its other
    # regressions were repaired. The honest expectation is therefore a fully green
    # child suite, which is STRICTLY STRONGER than the old "exactly one failure", and
    # the relocation stays visible through the R45 skip assertion.
    Assert-Contains $r.Log '[SKIP] R45' 'S43: the relocated DB-M18 dependency is reported as an explicit skip'
    if ($r.Log -match '\[FAIL\]\s+R50') {
        $m124 = Invoke-RegressionSuite -Name 'M124Verify' -Path 'scripts\Test-DBM124TrialCycleClosure.ps1' -Root $script:ForgeRoot
        $script:RegressionResults.Add($m124)
        Assert-True ($m124.ExitCode -eq 0) 'S43: M12.4 child passes standalone (R50 was a nested build-contention artifact)'
        Assert-True ($m124.Failed -eq 0) 'S43: M12.4 child standalone 0 failures'
        Assert-True ($r.Passed -ge 71 -and $r.Passed -le 72) 'S43: DB-M18.1 pass count preserved (71 under R50 flake)'
        $script:ExternalDrift.Add('DBM181 R50 flake (DB-M12.4 nested build-contention; standalone green 54/54)')
    } else {
        Assert-Equal $r.Passed 72 'S43: DB-M18.1 suite 72 passed'
        Assert-Equal $r.Failed 0 'S43: DB-M18.1 suite 0 failures'
    }
}

# S44 UI regression (Lane C WPF files byte-identical)
function Test-S44-UiRegression {
    if (-not $script:ForgeRoot) {
        $script:HostSkips.Add('S44 M12.x console byte-identity: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT); the console stayed in Forge at W6/LaneA')
        return
    }
    Assert-True ($script:UiFiles.Count -gt 0) 'S44: M12.x UI source files enumerated'
    foreach ($f in $script:UiFiles) {
        $now = Get-Sha256 $f.FullName
        Assert-True ($now -eq $script:UiShaBefore[$f.FullName]) "S44: M12.x UI file unchanged: $($f.Name)"
    }
}

# S45 build 0 errors
function Test-S45-Build {
    if (-not $script:ForgeRoot) {
        $script:HostSkips.Add('S45 Forge solution build: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT); the solution stayed in Forge at W6/LaneA')
        return
    }
    $sln = Join-Path $script:ForgeRoot 'src\DevBridge.slnx'
    Assert-True (Test-Path $sln) 'S45: solution present'
    if (-not (Test-Path $sln)) { return }
    $log = Join-Path $env:TEMP 'db27-build.log'
    & dotnet build $sln --nologo > $log 2>&1
    $exit = $LASTEXITCODE
    $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
    Assert-True ($exit -eq 0) "S45: dotnet build exit 0 (got $exit)"
    $errTokens = ([regex]::Matches($text, 'error\s+CS\d+')).Count
    Assert-True ($errTokens -eq 0) "S45: build has 0 error CS tokens (got $errTokens)"
    Assert-Contains $text '0 Error' 'S45: build summary shows 0 errors'
}

# --- no-mutation / frozen-file re-verification --------------------------------------------

function Test-S46-FrozenFilesUnchanged {
    foreach ($rel in $script:FrozenFiles) {
        $after = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($after -eq $script:ShaBefore[$rel]) "S46: frozen file unchanged: $rel"
    }
    if ($script:ForgeFrozenBefore) {
        foreach ($rel in $script:ForgeFrozenFiles) {
            $after = Get-Sha256 (Join-Path $script:ForgeRoot $rel)
            Assert-True ($after -eq $script:ShaBefore[$rel]) "S46: Forge DB-M18.1 file unchanged: $rel"
        }
    }
    foreach ($rel in $script:ConfigFiles) {
        $after = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($after -eq $script:CfgShaBefore[$rel]) "S46: config unchanged: $rel"
    }
    if ($null -ne $script:WorkbookShaBefore) {
        $now = Get-Sha256 $script:WorkbookPath
        Assert-True ($now -eq $script:WorkbookShaBefore) 'S46: canonical Nexus workbook byte-identical'
    }
}

# --- scenario registry + runner -----------------------------------------------------------

$script:Scenarios = @(
    'Test-S1-UiOpens', 'Test-S2-ProviderSelection', 'Test-S3-RouteDirect', 'Test-S4-RouteGateway',
    'Test-S5-RouteLocal', 'Test-S6-ModelSelection', 'Test-S7-UnderlyingDisplay', 'Test-S8-PricingVersion',
    'Test-S9-InputCost', 'Test-S10-OutputCost', 'Test-S11-CachedInputCost', 'Test-S12-CacheWriteCost',
    'Test-S13-TotalCost', 'Test-S14-MultiAttempt', 'Test-S15-Usd', 'Test-S16-Inr',
    'Test-S17-ActualVsEstimated', 'Test-S18-MissingPricing', 'Test-S19-UnknownLocalCost',
    'Test-S20-LocalNeverFree', 'Test-S21-OpenRouterIdentity', 'Test-S22-UnderlyingPreserved',
    'Test-S23-ReasoningLevel', 'Test-S24-QualityDisplay', 'Test-S25-LowConfidence',
    'Test-S26-ExpectedVerifiedSuccessCost', 'Test-S27-EscalationChain', 'Test-S28-CumulativeEscalation',
    'Test-S29-BudgetInformational', 'Test-S30-BudgetOverrideImpossible', 'Test-S31-RoutingImpossible',
    'Test-S32-PricingImpossible', 'Test-S33-HealthImpossible', 'Test-S34-ExecutionImpossible',
    'Test-S35-PaidCallsZero', 'Test-S36-NetworkZero',
    'Test-S37-M16Regression', 'Test-S38-M21Regression', 'Test-S39-M23Regression', 'Test-S40-M24Regression',
    'Test-S41-M25Regression', 'Test-S42-M26Regression', 'Test-S43-M181Preserved',
    'Test-S44-UiRegression', 'Test-S45-Build',
    'Test-S46-FrozenFilesUnchanged'
)

foreach ($scenario in $script:Scenarios) {
    try { & $scenario } catch { $script:ScenarioFails.Add("${scenario} threw: $($_.Exception.Message)") }
}

# --- final summary -------------------------------------------------------------------------

$passed = $script:TestCount - $script:TestFails.Count
Write-Host "DB-M27 TEST SUMMARY: $passed passed, $($script:TestFails.Count) failed"
Write-Host "DB-M27 SCENARIOS: $($script:Scenarios.Count) scenarios"
foreach ($r in $script:RegressionResults) {
    Write-Host ("DB-M27 REGRESSION {0}: {1} passed, {2} failed, exit {3}" -f $r.Name, $r.Passed, $r.Failed, $r.ExitCode)
}
foreach ($f in $script:TestFails) { Write-Host "  FAIL: $f" }
foreach ($f in $script:ScenarioFails) { Write-Host "  SCENARIO FAIL: $f" }
# Cross-tree assertions that could not run are reported, never silently dropped: a
# run that skipped them is not the same evidence as a run that executed them.
Write-Host "DB-M27 HOST SKIPS: $($script:HostSkips.Count)"
foreach ($s in $script:HostSkips) { Write-Host "  [SKIP] $s" }
if ($script:TestFails.Count -eq 0 -and $script:ScenarioFails.Count -eq 0) {
    exit 0
}
exit 1

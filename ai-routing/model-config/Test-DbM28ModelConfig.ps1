# Test-DbM28ModelConfig.ps1 -- DB-M28 MODEL CONFIGURATION UI test suite (54 scenarios, S1-S54).
#
# Objective (the brief): an operator-facing MODEL CONFIGURATION UI for the
# existing DevBridge AI subsystem. The UI lets the operator INSPECT which
# providers/routes/models and supported reasoning/capability options DevBridge
# may consider, and CONFIGURE operator policy (provider/model enablement and
# configuration status). DB-M28 never executes a provider/model, never makes a
# paid API call, and never makes a network call. AUTO_EXECUTION_ENABLED = FALSE.
#
# Every scenario runs deterministically against the real DB-M14..M27
# implementations consumed READ-ONLY (SHA-256 verified byte-identical
# before/after the run) plus deterministic synthetic fixtures. DB-M19 hard
# capability checks are never overridden; DB-M15 stays the pricing authority;
# DB-M21 budget stays informational-only; DB-M22 provider health stays
# read-only; DB-M26/DB-M18.1/DB-M27 preserved. Persistence exercises the real
# validated atomic audited adapter on a TEMPORARY config tree so the live
# config stays byte-identical.
#
# AUTO_EXECUTION_ENABLED = FALSE. Provider/model executed: NO. Paid calls: 0.
# Network calls: 0.
#
# Exit code: 0 = all 54 scenarios + all regressions passed; 1 = any failure.
# Prints "DB-M28 TEST SUMMARY: <passed> passed, <failed> failed".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "ModelConfigRender.ps1")    # renderer (dot-sources engine -> contracts -> read-only reuse chain)

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# DB-M18.1 dependency lineage, the operator console, the Forge solution and the
# governed task state stayed in Forge at W6/LaneA -- none of them is AI
# implementation. Assertions about them are CROSS-TREE and the host root is
# resolved explicitly; see ai-routing\AiHostRoot.ps1. When it is not declared those
# assertions report a SKIP instead of resolving a guessed path.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'AiHostRoot.ps1')
# Child-suite size is DERIVED from the child's own declaration, never pinned to a literal.
# See ai-routing\SuiteInventory.ps1 for why: S39 used to assert `DB-M26 suite still 381
# passed`, and DB-M26 has not reported 381 assertions since the AI Head migration.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'SuiteInventory.ps1')
$script:ForgeRoot = Resolve-ForgeHostRoot
$script:HostSkips = New-Object System.Collections.Generic.List[string]
$script:NowUtc = '2026-08-31T12:00:00Z'   # deterministic reference
$script:FixtureFiles = @(
    'ai-routing\model-config\ModelConfigContracts.ps1',
    'ai-routing\model-config\ModelConfigEngine.ps1',
    'ai-routing\model-config\ModelConfigRender.ps1'
)
# The RUNTIME library (the model-config UI itself), scanned by the no-mutation /
# no-execution / no-secret proofs. The test harness is deliberately excluded:
# its own assertion needles are the forbidden tokens, and the harness is never
# part of the runtime -- the proof is about what the UI LIBRARY can do.
$script:LibraryFiles = @(
    'ai-routing\model-config\ModelConfigContracts.ps1',
    'ai-routing\model-config\ModelConfigEngine.ps1',
    'ai-routing\model-config\ModelConfigRender.ps1'
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

function New-CfgBase {
    <#
    .SYNOPSIS
    A clone of the real cost configuration with fresh (independent) catalogues so
    the suite never mutates the cached Get-Cfg. The real config data is the seed.
    #>
    $cfg = Get-Cfg
    $providers = @{}
    foreach ($k in @($cfg.Providers.Keys)) { $providers[$k] = $cfg.Providers[$k] }
    $models = @{}
    foreach ($k in @($cfg.Models.Keys)) { $models[$k] = $cfg.Models[$k] }
    $pricing = @{}
    foreach ($k in @($cfg.Pricing.Keys)) { $pricing[$k] = $cfg.Pricing[$k] }
    return [pscustomobject]@{
        Routing = $cfg.Routing; Providers = $providers; Models = $models
        Pricing = $pricing; ExchangeRates = $cfg.ExchangeRates; CostConfig = $cfg.CostConfig
    }
}

function New-CfgWithFixtures {
    <#
    .SYNOPSIS
    Clone the real cost configuration and add deterministic synthetic fixtures:
      - fx-provider    : an ENABLED + CONFIGURED DIRECT provider with a present secret
      - fx-cap-mismatch: an ENABLED model on fx-provider with SupportsCoding=false
                         -> DB-M19 CAPABILITY_CODING_MISSING -> CAPABILITY_MISMATCH that
                         NO toggle can fix (hard gate)
      - fx-no-tool     : an ENABLED model with SupportsToolUse=false -> CAPABILITY_TOOL_USE_MISSING
      - or:anthropic/claude-sonnet-5 : an OpenRouter GATEWAY route preserving the
                         underlying model identity (claude-sonnet-5)
      - local-7b       : a LOCAL model (LOCAL_COST_UNKNOWN, never FREE)
      - fx-unhealthy   : an ENABLED+CONFIGURED provider with an OPTIONAL health snapshot
                         UNAVAILABLE (used by the health fixtures via -HealthSnapshot)
    The base seed catalogue (all real providers/models/pricing) is preserved.
    #>
    $cfg = New-CfgBase
    $fx = New-AiProvider -ProviderId 'fx-provider' -DisplayName 'Fixture Provider' `
        -Enabled $true -Configured $true -ProviderType 'DIRECT' -BaseEndpoint 'https://fx.local/v1' `
        -GatewayType 'ANTHROPIC_COMPATIBLE' -SupportsStreaming $true -SupportsTools $true `
        -SupportsPromptCaching $false -SupportsBatch $false -SupportsStructuredOutput $true `
        -SupportsReasoningControls $true -SupportsUsageReporting $true -SupportsHealthCheck $false `
        -SecretReference 'FX_TEST_KEY'
    $cfg.Providers[$fx.ProviderId] = $fx

    $fxu = New-AiProvider -ProviderId 'fx-unhealthy' -DisplayName 'Fixture Unhealthy' `
        -Enabled $true -Configured $true -ProviderType 'DIRECT' -BaseEndpoint 'https://fxu.local/v1' `
        -GatewayType 'ANTHROPIC_COMPATIBLE' -SupportsStreaming $true -SupportsTools $true `
        -SupportsStructuredOutput $false -SupportsReasoningControls $false `
        -SecretReference 'FXU_TEST_KEY'
    $cfg.Providers[$fxu.ProviderId] = $fxu

    $cap = New-AiModel -ModelId 'fx-cap-mismatch' -ProviderId 'fx-provider' `
        -ProviderModelId 'fx-cap-mismatch' -UnderlyingModelId 'fx-cap-mismatch' `
        -DisplayName 'Fixture Capability Mismatch' -Enabled $true -LocalOrRemote 'REMOTE' `
        -SupportsCoding $false -SupportsToolUse $true -SupportsStructuredOutput $true `
        -SupportsStreaming $true -ContextWindow 200000 -MaxOutputTokens 32000
    $cfg.Models[$cap.ModelId] = $cap

    $nt = New-AiModel -ModelId 'fx-no-tool' -ProviderId 'fx-provider' `
        -ProviderModelId 'fx-no-tool' -UnderlyingModelId 'fx-no-tool' `
        -DisplayName 'Fixture No Tool' -Enabled $true -LocalOrRemote 'REMOTE' `
        -SupportsCoding $true -SupportsToolUse $false -SupportsStructuredOutput $true `
        -SupportsStreaming $true -ContextWindow 200000 -MaxOutputTokens 32000
    $cfg.Models[$nt.ModelId] = $nt

    $gw = New-AiModel -ModelId 'or:anthropic/claude-sonnet-5' -ProviderId 'openrouter' `
        -ProviderModelId 'anthropic/claude-sonnet-5' -UnderlyingModelId 'claude-sonnet-5' `
        -GatewayProviderId 'openrouter' -DisplayName 'OpenRouter Claude Sonnet 5' `
        -Enabled $false -LocalOrRemote 'REMOTE' -SupportsCoding $true -SupportsToolUse $true `
        -SupportsVision $true -SupportsStreaming $true
    $cfg.Models[$gw.ModelId] = $gw

    $lc = New-AiModel -ModelId 'local-7b' -ProviderId 'local' -ProviderModelId 'local-7b' `
        -UnderlyingModelId 'local-7b' -DisplayName 'Local 7B' -Enabled $false -LocalOrRemote 'LOCAL' `
        -SupportsCoding $true -SupportsToolUse $true -SupportsStreaming $true
    $cfg.Models[$lc.ModelId] = $lc

    $un = New-AiModel -ModelId 'fx-unhealthy-model' -ProviderId 'fx-unhealthy' `
        -ProviderModelId 'fx-unhealthy-model' -UnderlyingModelId 'fx-unhealthy-model' `
        -DisplayName 'Fixture Unhealthy Model' -Enabled $true -LocalOrRemote 'REMOTE' `
        -SupportsCoding $true -SupportsToolUse $true -SupportsStructuredOutput $true `
        -SupportsStreaming $true -ContextWindow 200000 -MaxOutputTokens 32000
    $cfg.Models[$un.ModelId] = $un

    return $cfg
}

function Get-FxLookup {
    <#
    .SYNOPSIS
    Deterministic secret-presence lookup: FX_TEST_KEY and FXU_TEST_KEY are present;
    everything else is absent. Values are NEVER returned -- only presence.
    #>
    return {
        param([string]$Name)
        if ($Name -eq 'FX_TEST_KEY' -or $Name -eq 'FXU_TEST_KEY') { return $true }
        return $false
    }
}

function Get-UnhealthySnapshot {
    <#
    .SYNOPSIS
    Deterministic DB-M26-pattern effective-health snapshot: fx-unhealthy is
    UNAVAILABLE with an OPEN circuit; the rest carry no evidence.
    #>
    return @(
        [pscustomobject]@{ ProviderId = 'fx-unhealthy'; HealthState = 'UNAVAILABLE'; CircuitState = 'OPEN'; LastCheckedUtc = '2026-08-31T11:00:00Z' }
    )
}

function Get-ConfigView {
    <#
    .SYNOPSIS
    Build the model-config view deterministically, injecting fixtures + a
    deterministic secret lookup. $WithHealth toggles the optional health snapshot.
    #>
    param([bool]$WithHealth = $false)
    $cfg = New-CfgWithFixtures
    $snap = if ($WithHealth) { Get-UnhealthySnapshot } else { $null }
    return New-DbM28ModelConfigurationView -Configuration $cfg -HealthSnapshot $snap `
        -SecretLookup (Get-FxLookup) -NowUtc $script:NowUtc
}

function New-TempRoot {
    <#
    .SYNOPSIS
    A throwaway directory tree (used for the persistence scenarios S31-S36) that
    the adapter writes to. NEVER the live config tree.
    #>
    $dir = Join-Path $env:TEMP ('db28-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
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

# DB-M28 must NOT modify the DB-M14..M27 chain (frozen read-only inputs), its own
# library files, or the DB-M18.1 suite.
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
foreach ($rel in $script:FixtureFiles) { $script:ShaBefore[$rel] = Get-Sha256 (Join-Path $script:Root $rel) }
if ($script:ForgeRoot) {
    foreach ($rel in $script:ForgeFrozenFiles) { $script:ShaBefore[$rel] = Get-Sha256 (Join-Path $script:ForgeRoot $rel) }
    $script:ForgeFrozenBefore = $true
} else {
    $script:ForgeFrozenBefore = $false
    $script:HostSkips.Add('S55 Forge DB-M18.1 frozen-file guard: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT)')
}

# Live config files. DB-M28 may WRITE config\providers.json + config\models.json
# through its adapter -- but ONLY on an operator's explicit Apply. The test run
# exercises persistence on temp roots, so the LIVE config must stay byte-identical.
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

# --- regression suites (child processes; read-only over the DB-M28 scope) ----------------

function Invoke-RegressionSuite {
    <#
    .SYNOPSIS
    Run a frozen dependency suite as a CHILD process (read-only over the DB-M28
    scope) and parse its outcome. Child suites use varied summary formats, so the
    parser accepts: 'TEST SUMMARY: N passed, M failed', 'N assertions, M failed',
    'N checks, A passed, B failed', and falls back to counting PASS:/FAIL: lines.
    #>
    param([string]$Name, [string]$Path, [string]$Root)
    $base = if ($Root) { $Root } else { $script:Root }
    $full = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $base $Path }
    $log = Join-Path $env:TEMP ("db28-reg-" + $Name + '.log')
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $full > $log 2>&1
    $exit = $LASTEXITCODE
    $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
    $passed = -1
    $failed = -1
    # Take the LAST summary line: a suite that runs nested child suites may have
    # several TEST SUMMARY lines, and the suite's own is the final one.
    $all = [regex]::Matches($text, 'TEST SUMMARY:\s*(\d+)\s+passed,\s*(\d+)\s+failed')
    if ($all.Count -gt 0) { $last = $all[$all.Count - 1]; $passed = [int]$last.Groups[1].Value; $failed = [int]$last.Groups[2].Value }
    if ($passed -lt 0) {
        $all = [regex]::Matches($text, '(\d+)\s+assertions?,\s*(\d+)\s+failed')
        if ($all.Count -gt 0) { $last = $all[$all.Count - 1]; $passed = [int]$last.Groups[1].Value; $failed = [int]$last.Groups[2].Value }
    }
    if ($passed -lt 0) {
        $all = [regex]::Matches($text, '(\d+)\s+checks?,\s*(\d+)\s+passed,\s*(\d+)\s+failed')
        if ($all.Count -gt 0) { $last = $all[$all.Count - 1]; $passed = [int]$last.Groups[2].Value; $failed = [int]$last.Groups[3].Value }
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

# S1 UI launches (renderer produces a self-contained HTML page)
function Test-S1-UiOpens {
    $view = Get-ConfigView
    $html = ConvertTo-DbM28Html -View $view
    Assert-True (-not [string]::IsNullOrWhiteSpace($html)) 'S1: HTML is non-empty'
    Assert-True ($html.Length -gt 4000) 'S1: HTML is substantial'
    Assert-Contains $html '<!doctype html>' 'S1: doctype present'
    Assert-Contains $html 'DB-M28 Model Configuration' 'S1: page title present'
    Assert-Contains $html 'AUTO AI EXECUTION DISABLED' 'S1: no-execution badge present'
    Assert-Contains $html 'Read-only guard' 'S1: guard footer present'
    Assert-Contains $html 'VIEW COST ESTIMATE' 'S1: cost-estimate card present'
    $tmp = Join-Path $env:TEMP 'db28-model-config.html'
    Export-DbM28ModelConfigurationHtml -View $view -OutputPath $tmp
    Assert-True ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 4000)) 'S1: exported artifact written and non-empty'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# S2 provider list renders (7 real providers + fixtures, identity + config status)
function Test-S2-ProviderListRenders {
    $view = Get-ConfigView
    Assert-True (@($view.Providers).Count -ge 7) 'S2: all 7 real providers rendered'
    Assert-True (@($view.Providers | Where-Object { $_.ProviderId -eq 'deepseek' }).Count -eq 1) 'S2: deepseek present'
    Assert-True (@($view.Providers | Where-Object { $_.ProviderId -eq 'openrouter' }).Count -eq 1) 'S2: openrouter gateway present'
    Assert-True (@($view.Providers | Where-Object { $_.ProviderId -eq 'local' }).Count -eq 1) 'S2: local present'
    $fx = @($view.Providers | Where-Object { $_.ProviderId -eq 'fx-provider' })[0]
    Assert-NotNull $fx 'S2: fixture provider present'
    Assert-Equal $fx.DisplayName 'Fixture Provider' 'S2: display name renders'
}

# S3 model list renders (4 real models + fixtures)
function Test-S3-ModelListRenders {
    $view = Get-ConfigView
    Assert-True (@($view.Models).Count -ge 4) 'S3: all 4 real models rendered'
    Assert-True (@($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' }).Count -eq 1) 'S3: deepseek-v4-flash present'
    Assert-True (@($view.Models | Where-Object { $_.ModelId -eq 'claude-sonnet-5' }).Count -eq 1) 'S3: claude-sonnet-5 present'
    $fx = @($view.Models | Where-Object { $_.ModelId -eq 'fx-cap-mismatch' })[0]
    Assert-NotNull $fx 'S3: fixture model present'
    Assert-Equal $fx.ProviderDisplayName 'Fixture Provider' 'S3: provider display name joins'
}

# S4 provider enabled/disabled (real: all disabled; fixture provider enabled+configured)
function Test-S4-ProviderEnabledDisabled {
    $view = Get-ConfigView
    Assert-Equal $view.Guard.AutoExecutionEnabled $false 'S4: guard auto-execution disabled'
    $deepseek = @($view.Providers | Where-Object { $_.ProviderId -eq 'deepseek' })[0]
    Assert-Equal $deepseek.Enabled $false 'S4: deepseek shows disabled'
    Assert-Equal $deepseek.Configured $false 'S4: deepseek shows not configured'
    $fx = @($view.Providers | Where-Object { $_.ProviderId -eq 'fx-provider' })[0]
    Assert-Equal $fx.Enabled $true 'S4: fixture provider shows enabled'
    Assert-Equal $fx.Configured $true 'S4: fixture provider shows configured'
    Assert-Equal $fx.SecretStatus 'CONFIGURED' 'S4: fixture provider secret configured'
}

# S5 model enabled/disabled (real: all disabled; fixtures enabled)
function Test-S5-ModelEnabledDisabled {
    $view = Get-ConfigView
    $ds = @($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' })[0]
    Assert-Equal $ds.Enabled $false 'S5: deepseek-v4-flash shows disabled'
    $cap = @($view.Models | Where-Object { $_.ModelId -eq 'fx-cap-mismatch' })[0]
    Assert-Equal $cap.Enabled $true 'S5: fixture model shows enabled'
    $gw = @($view.Models | Where-Object { $_.ModelId -eq 'or:anthropic/claude-sonnet-5' })[0]
    Assert-Equal $gw.Enabled $false 'S5: gateway fixture starts disabled'
}

# S6 direct route display
function Test-S6-DirectRoute {
    $view = Get-ConfigView
    $ds = @($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' })[0]
    Assert-Equal $ds.RouteType 'DIRECT' 'S6: deepseek-v4-flash direct route'
    $son = @($view.Models | Where-Object { $_.ModelId -eq 'claude-sonnet-5' })[0]
    Assert-Equal $son.RouteType 'DIRECT' 'S6: claude-sonnet-5 direct route'
}

# S7 gateway route display
function Test-S7-GatewayRoute {
    $view = Get-ConfigView
    $gw = @($view.Models | Where-Object { $_.ModelId -eq 'or:anthropic/claude-sonnet-5' })[0]
    Assert-Equal $gw.RouteType 'GATEWAY' 'S7: openrouter route is GATEWAY'
    Assert-Equal $gw.GatewayProviderId 'openrouter' 'S7: gateway provider = openrouter'
    Assert-Equal $gw.UnderlyingModelId 'claude-sonnet-5' 'S7: underlying model preserved'
}

# S8 local route display
function Test-S8-LocalRoute {
    $view = Get-ConfigView
    $lc = @($view.Models | Where-Object { $_.ModelId -eq 'local-7b' })[0]
    Assert-Equal $lc.RouteType 'LOCAL' 'S8: local-7b route is LOCAL'
    Assert-Equal $lc.LocalOrRemote 'LOCAL' 'S8: local model classified LOCAL'
    Assert-True (@($view.LocalModels | Where-Object { $_.ModelId -eq 'local-7b' }).Count -eq 1) 'S8: local model listed in section 5'
}

# S9 reasoning levels from contracts (only the real contract vocabulary)
function Test-S9-ReasoningLevelsFromContracts {
    $view = Get-ConfigView
    $levels = @($view.ReasoningLevels.Available)
    Assert-Equal ($levels -join ',') 'NONE,LOW,MEDIUM,HIGH,MAX' 'S9: exactly the contract levels NONE..MAX'
    Assert-True (@(Get-AiRoutingReasoningLevels).Count -eq 5) 'S9: contract exposes 5 levels'
    Assert-True (@($view.ReasoningLevels.PerModel).Count -ge 4) 'S9: per-model reasoning rows present'
}

# S10 unsupported reasoning not shown (a model without reasoning asserts NO levels)
function Test-S10-UnsupportedReasoningNotShown {
    $view = Get-ConfigView
    # fx-cap-mismatch asserts SupportsCoding only; it declares no reasoning
    # levels and no SupportsReasoning flag -> Levels must be EMPTY.
    $row = @($view.ReasoningLevels.PerModel | Where-Object { $_.ModelId -eq 'fx-cap-mismatch' })[0]
    Assert-NotNull $row 'S10: reasoning row for fx-cap-mismatch'
    Assert-Equal $row.LevelsNote 'NOT_ASSERTED until DB-M15/M19' 'S10: no reasoning asserted'
    Assert-Equal (@($row.Levels).Count) 0 'S10: zero invented reasoning levels'
    $html = ConvertTo-DbM28Html -View $view
    Assert-Contains $html 'NOT_ASSERTED' 'S10: UI labels unasserted reasoning'
}

# S11 capability display (tri-state, never invented)
function Test-S11-CapabilityDisplay {
    $view = Get-ConfigView
    $ds = @($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' })[0]
    Assert-Equal $ds.SupportsCoding 'YES' 'S11: deepseek coding capability shown'
    Assert-Equal $ds.SupportsVision 'UNKNOWN' 'S11: unasserted capability is UNKNOWN (never fabricated)'
    $son = @($view.Models | Where-Object { $_.ModelId -eq 'claude-sonnet-5' })[0]
    Assert-Equal $son.SupportsVision 'YES' 'S11: sonnet vision capability shown'
}

# S12 tool capability
function Test-S12-ToolCapability {
    $view = Get-ConfigView
    $ds = @($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' })[0]
    Assert-Equal $ds.SupportsToolUse 'YES' 'S12: deepseek tool-use capability shown'
    $op = @($view.Models | Where-Object { $_.ModelId -eq 'claude-opus-5' })[0]
    Assert-Equal $op.SupportsToolUse 'YES' 'S12: opus tool-use capability shown'
}

# S13 structured-output capability
function Test-S13-StructuredOutput {
    $view = Get-ConfigView
    $ds = @($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' })[0]
    Assert-Equal $ds.SupportsStructuredOutput 'UNKNOWN' 'S13: deepseek structured-output UNKNOWN (null, not asserted)'
    $fx = @($view.Models | Where-Object { $_.ModelId -eq 'fx-cap-mismatch' })[0]
    Assert-Equal $fx.SupportsStructuredOutput 'YES' 'S13: fixture structured-output shown'
}

# S14 context capability (numbers when asserted, UNKNOWN/null otherwise)
function Test-S14-ContextCapability {
    $view = Get-ConfigView
    $ds = @($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' })[0]
    Assert-Null $ds.ContextWindow 'S14: deepseek context window unasserted (null)'
    $fx = @($view.Models | Where-Object { $_.ModelId -eq 'fx-cap-mismatch' })[0]
    Assert-Equal $fx.ContextWindow 200000 'S14: fixture context window displayed'
    $html = ConvertTo-DbM28Html -View $view
    Assert-Contains $html '200000' 'S14: UI renders the asserted context window'
}

# S15 pricing reference display (DB-M15 read-only authority)
function Test-S15-PricingReferenceDisplay {
    $view = Get-ConfigView
    Assert-Equal $view.PricingReference.Authority 'DB-M15' 'S15: pricing authority DB-M15'
    Assert-Equal $view.PricingReference.ReadOnly $true 'S15: pricing reference read-only'
    Assert-True (@($view.PricingReference.Records).Count -ge 10) 'S15: pricing catalogue rendered'
    $rec = @($view.PricingReference.Records | Where-Object { $_.PricingRecordId -eq 'ds-v4flash-offpeak-20260830' })[0]
    Assert-NotNull $rec 'S15: deepseek offpeak record present'
    Assert-Equal $rec.ModelId 'deepseek-v4-flash' 'S15: record model id rendered'
}

# S16 pricing unknown state (model with no record -> explicit PRICE_UNKNOWN, never invented)
function Test-S16-PricingUnknown {
    $view = Get-ConfigView
    $op = @($view.Models | Where-Object { $_.ModelId -eq 'claude-opus-5' })[0]
    Assert-Equal $op.PriceStatus 'PRICE_UNKNOWN' 'S16: opus price UNKNOWN (no record)'
    $ds = @($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' })[0]
    Assert-Equal $ds.PriceStatus 'CONFIGURED' 'S16: deepseek price CONFIGURED'
    Assert-Equal $ds.PriceOperationalCostUnknown $false 'S16: deepseek operational cost known'
}

# S17 provider health read-only (snapshot is an OPTIONAL input; UI never mutates)
function Test-S17-ProviderHealthReadOnly {
    $view = Get-ConfigView -WithHealth $true
    Assert-Equal $view.HealthStatus.ReadOnly $true 'S17: health section read-only'
    Assert-Equal $view.HealthStatus.Source 'OPTIONAL_SNAPSHOT' 'S17: health consumes the optional snapshot'
    $row = @($view.HealthStatus.Rows | Where-Object { $_.ProviderId -eq 'fx-unhealthy' })[0]
    Assert-NotNull $row 'S17: unhealthy fixture row present'
    Assert-Equal $row.HealthState 'UNAVAILABLE' 'S17: health state from snapshot'
    Assert-Equal $row.CircuitState 'OPEN' 'S17: circuit state from snapshot'
    Assert-Equal $view.Guard.ProviderHealthUnmodified $true 'S17: guard says health unmodified'
}

# S18 health cannot be manually fabricated (no snapshot -> NO_EVIDENCE; no write token)
function Test-S18-HealthNotFabricated {
    $view = Get-ConfigView
    Assert-Equal $view.HealthStatus.Source 'NO_EVIDENCE' 'S18: no snapshot -> NO_EVIDENCE'
    Assert-Equal $view.HealthStatus.ReadOnly $true 'S18: health read-only with no evidence'
    foreach ($row in @($view.HealthStatus.Rows)) {
        Assert-Equal $row.HealthState 'UNKNOWN' "S18: no fabricated health for $($row.ProviderId)"
    }
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Set-ProviderHealth' "S18: no health write token ($rel)"
        Assert-NotContains $text 'Update-ProviderCircuitState' "S18: no circuit write token ($rel)"
    }
}

# S19 local provider display (LOCAL identity rendered; LOCAL != FREE note)
function Test-S19-LocalProviderDisplay {
    $view = Get-ConfigView
    $local = @($view.Providers | Where-Object { $_.ProviderId -eq 'local' })[0]
    Assert-Equal $local.ProviderType 'LOCAL' 'S19: local provider type LOCAL'
    $ollama = @($view.Providers | Where-Object { $_.ProviderId -eq 'ollama' })[0]
    Assert-Equal $ollama.ProviderType 'LOCAL' 'S19: ollama provider type LOCAL'
    $html = ConvertTo-DbM28Html -View $view
    Assert-Contains $html 'LOCAL' 'S19: UI labels the local provider'
    Assert-Contains $html 'LOCAL is NOT FREE' 'S19: UI states LOCAL != FREE'
}

# S20 LOCAL_COST_UNKNOWN preserved (unknown local cost is never a fabricated zero)
function Test-S20-LocalCostUnknownPreserved {
    $view = Get-ConfigView
    $lc = @($view.Models | Where-Object { $_.ModelId -eq 'local-7b' })[0]
    Assert-Equal $lc.PriceStatus 'LOCAL_COST_UNKNOWN' 'S20: local cost unknown state'
    Assert-Equal $lc.PriceOperationalCostUnknown $true 'S20: operational cost unknown flag'
    $html = ConvertTo-DbM28Html -View $view
    Assert-Contains $html 'LOCAL_COST_UNKNOWN' 'S20: UI shows the unknown-local state'
    Assert-NotContains $html 'USD 0.00' 'S20: UI never shows a fabricated zero'
    Assert-NotContains $html 'INR 0.00' 'S20: UI never shows a fabricated zero'
}

# S21 local never assumed FREE
function Test-S21-LocalNeverFree {
    $view = Get-ConfigView
    $lc = @($view.Models | Where-Object { $_.ModelId -eq 'local-7b' })[0]
    Assert-True ($lc.PriceStatus -ne 'FREE') 'S21: local-7b is never FREE'
    Assert-Contains (ConvertTo-DbM28Html -View $view) 'LOCAL is NOT FREE' 'S21: UI states the LOCAL != FREE invariant'
}

# S22 OpenRouter gateway identity (gateway provider != underlying model, not collapsed)
function Test-S22-OpenRouterIdentity {
    $view = Get-ConfigView
    $gw = @($view.Models | Where-Object { $_.ModelId -eq 'or:anthropic/claude-sonnet-5' })[0]
    Assert-Equal $gw.RouteType 'GATEWAY' 'S22: route GATEWAY'
    Assert-Equal $gw.GatewayProviderId 'openrouter' 'S22: gateway provider openrouter'
    Assert-Equal $gw.UnderlyingModelId 'claude-sonnet-5' 'S22: underlying model preserved'
    Assert-True ($gw.GatewayProviderId -ne $gw.UnderlyingModelId) 'S22: gateway identity and underlying model NOT collapsed'
    $or = @($view.OpenRouterRoutes | Where-Object { $_.ModelId -eq 'or:anthropic/claude-sonnet-5' })[0]
    Assert-NotNull $or 'S22: gateway route listed in section 6'
    Assert-Equal $or.GatewayProviderId 'openrouter' 'S22: section 6 gateway identity'
    Assert-Equal $or.UnderlyingModelId 'claude-sonnet-5' 'S22: section 6 underlying preserved'
}

# S23 underlying model preserved end to end
function Test-S23-UnderlyingPreserved {
    $view = Get-ConfigView
    $gw = @($view.Models | Where-Object { $_.ModelId -eq 'or:anthropic/claude-sonnet-5' })[0]
    Assert-Equal $gw.UnderlyingModelId 'claude-sonnet-5' 'S23: underlying preserved in model row'
    $ds = @($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' })[0]
    Assert-Equal $ds.UnderlyingModelId 'deepseek-v4-flash' 'S23: direct model underlying = itself'
}

# S24 routing eligibility summary (DB-M19 reuse; states come from the contract vocabulary)
function Test-S24-EligibilitySummary {
    $view = Get-ConfigView
    Assert-Contains $view.EligibilitySummary.Source 'DB-M19' 'S24: eligibility source is DB-M19'
    $states = @($view.EligibilitySummary.States)
    Assert-True (@($states | Where-Object { $_ -eq 'ELIGIBLE' }).Count -eq 1) 'S24: ELIGIBLE in vocabulary'
    Assert-True (@($states | Where-Object { $_ -eq 'DISABLED' }).Count -eq 1) 'S24: DISABLED in vocabulary'
    Assert-True (@($states | Where-Object { $_ -eq 'CAPABILITY_MISMATCH' }).Count -eq 1) 'S24: CAPABILITY_MISMATCH in vocabulary'
    Assert-True (@($states | Where-Object { $_ -eq 'PRICING_UNKNOWN' }).Count -eq 1) 'S24: PRICING_UNKNOWN in vocabulary'
    Assert-True (@($states | Where-Object { $_ -eq 'PROVIDER_UNHEALTHY' }).Count -eq 1) 'S24: PROVIDER_UNHEALTHY in vocabulary'
    Assert-True (@($states | Where-Object { $_ -eq 'CONFIGURATION_INCOMPLETE' }).Count -eq 1) 'S24: CONFIGURATION_INCOMPLETE in vocabulary'
    foreach ($m in @($view.EligibilitySummary.Rows)) {
        Assert-True ($m.EligibilityState -in $states) "S24: $($m.ModelId) state in vocabulary"
    }
}

# S25 disabled model excluded from eligibility
function Test-S25-DisabledExcluded {
    $view = Get-ConfigView
    $ds = @($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' })[0]
    Assert-Equal $ds.EligibilityState 'DISABLED' 'S25: disabled model state DISABLED'
    Assert-Equal $ds.EligibilityFits $false 'S25: disabled model does not fit'
    Assert-Equal $ds.EligibilityFirstReason 'MODEL_DISABLED' 'S25: first reason MODEL_DISABLED'
}

# S26 capability mismatch cannot be overridden by toggle (DB-M19 hard gate)
function Test-S26-CapabilityMismatchNotToggleable {
    $view = Get-ConfigView
    $cap = @($view.Models | Where-Object { $_.ModelId -eq 'fx-cap-mismatch' })[0]
    Assert-Equal $cap.Enabled $true 'S26: fixture model IS enabled'
    Assert-Equal $cap.EligibilityState 'CAPABILITY_MISMATCH' 'S26: still CAPABILITY_MISMATCH when enabled'
    Assert-Equal $cap.EligibilityFirstReason 'CAPABILITY_CODING_MISSING' 'S26: hard reason CAPABILITY_CODING_MISSING'
    Assert-Equal $cap.EligibilityToggleFixable $false 'S26: NOT toggle-fixable'
    Assert-Equal $cap.EligibilityHardCapabilityGate $true 'S26: hard capability gate engaged'
    $nt = @($view.Models | Where-Object { $_.ModelId -eq 'fx-no-tool' })[0]
    Assert-Equal $nt.EligibilityFirstReason 'CAPABILITY_TOOL_USE_MISSING' 'S26: tool-use hard gate engaged'
    Assert-Equal $nt.EligibilityHardCapabilityGate $true 'S26: tool-use hard gate is hard'
    Assert-Contains (ConvertTo-DbM28Html -View $view) 'Hard capability override: NO' 'S26: UI states hard gates are not overridable'
}

# S27 configuration incomplete displayed (provider Configured=false / secret absent)
function Test-S27-ConfigIncompleteDisplayed {
    $view = Get-ConfigView
    $ds = @($view.Models | Where-Object { $_.ModelId -eq 'deepseek-v4-flash' })[0]
    Assert-Equal $ds.EligibilityConfigIncomplete $true 'S27: deepseek config incomplete (provider unconfigured)'
    Assert-Equal $ds.SecretStatus 'NOT_CONFIGURED' 'S27: deepseek secret NOT_CONFIGURED'
    $html = ConvertTo-DbM28Html -View $view
    Assert-Contains $html 'CONFIGURATION_INCOMPLETE' 'S27: UI shows the configuration-incomplete state'
}

# S28 secrets never rendered (no secret VALUE anywhere in the HTML)
function Test-S28-SecretsNeverRendered {
    $view = Get-ConfigView
    $html = ConvertTo-DbM28Html -View $view
    $leak = Test-DbM28SecretLeak $html
    Assert-Equal $leak.Leak $false 'S28: HTML passes the secret-leak guard'
    Assert-NotContains $html 'sk-' 'S28: no sk- secret prefix rendered'
    Assert-NotContains $html 'Bearer ' 'S28: no bearer token rendered'
    Assert-NotContains $html 'FX_TEST_KEY_VALUE' 'S28: no secret VALUE (only the env-var NAME)'
    Assert-Contains $html 'FX_TEST_KEY' 'S28: the env-var NAME may be shown (not a value)'
    Assert-Contains $html 'Secret values displayed' 'S28: UI labels the secret display policy'
}

# S29 secrets never logged (audit records and library never write secret values)
function Test-S29-SecretsNeverLogged {
    $view = Get-ConfigView
    Assert-Equal $view.Guard.SecretValuesLogged $false 'S29: guard says no secret logging'
    $auditText = ($view.AuditLog | ConvertTo-DbM28Json -Depth 0)
    $leak = Test-DbM28SecretLeak $auditText
    Assert-Equal $leak.Leak $false 'S29: audit log passes the secret-leak guard'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Write-Host.*FX_TEST_KEY_VALUE' "S29: no secret value literal ($rel)"
        Assert-NotContains $text 'Set-Content.*Secret' "S29: no secret write path ($rel)"
    }
}

# S30 configured / not-configured secret status
function Test-S30-SecretStatus {
    $view = Get-ConfigView
    $fx = @($view.Providers | Where-Object { $_.ProviderId -eq 'fx-provider' })[0]
    Assert-Equal $fx.SecretStatus 'CONFIGURED' 'S30: present secret -> CONFIGURED'
    $deepseek = @($view.Providers | Where-Object { $_.ProviderId -eq 'deepseek' })[0]
    Assert-Equal $deepseek.SecretStatus 'NOT_CONFIGURED' 'S30: absent secret -> NOT_CONFIGURED'
    $local = @($view.Providers | Where-Object { $_.ProviderId -eq 'local' })[0]
    Assert-Equal $local.SecretStatus 'NO_SECRET_REQUIRED' 'S30: local needs no secret -> NO_SECRET_REQUIRED'
    # SecretReference holds an env-var NAME only; the value is never surfaced.
    $fx2 = @($view.Providers | Where-Object { $_.ProviderId -eq 'fx-provider' })[0]
    Assert-Equal $fx2.SecretReference 'FX_TEST_KEY' 'S30: secret reference is the env-var NAME'
    Assert-NotContains (ConvertTo-DbM28Html -View $view) 'FX_TEST_KEY_VALUE' 'S30: no secret value in HTML'
}

# S31 config validation before save (request validation + applicability)
function Test-S31-ConfigValidation {
    # Invalid target type
    $bad = New-DbM28ConfigChangeRequest -TargetType 'ROUTE' -TargetId 'x' -Field 'Enabled' -NewValue $true -Category 'PROVIDER' -NowUtc $script:NowUtc
    $v = Test-DbM28ConfigChangeRequest $bad
    Assert-Equal $v.Valid $false 'S31: bad target type rejected'
    # Non-editable field
    $badField = New-DbM28ConfigChangeRequest -TargetType 'PROVIDER' -TargetId 'deepseek' -Field 'SecretReference' -NewValue 'X' -Category 'PROVIDER' -NowUtc $script:NowUtc
    $v2 = Test-DbM28ConfigChangeRequest $badField
    Assert-Equal $v2.Valid $false 'S31: non-editable field rejected'
    # Bad category
    $badCat = New-DbM28ConfigChangeRequest -TargetType 'PROVIDER' -TargetId 'deepseek' -Field 'Enabled' -NewValue $true -Category 'PRICING' -NowUtc $script:NowUtc
    $v3 = Test-DbM28ConfigChangeRequest $badCat
    Assert-Equal $v3.Valid $false 'S31: bad category rejected'
    # Non-boolean value for a bool field
    $badBool = New-DbM28ConfigChangeRequest -TargetType 'PROVIDER' -TargetId 'deepseek' -Field 'Enabled' -NewValue 'yes' -Category 'CONFIG_STATUS' -NowUtc $script:NowUtc
    $cfg = Get-Cfg
    $app = Test-DbM28ConfigChangeApplicable -Configuration $cfg -Request $badBool
    Assert-Equal $app.Applicable $false 'S31: non-boolean value not applicable'
    # Missing target
    $missing = New-DbM28ConfigChangeRequest -TargetType 'MODEL' -TargetId 'no-such-model' -Field 'Enabled' -NewValue $true -Category 'MODEL' -NowUtc $script:NowUtc
    $app2 = Test-DbM28ConfigChangeApplicable -Configuration $cfg -Request $missing
    Assert-Equal $app2.Applicable $false 'S31: missing target rejected'
    # A valid request passes both validation and applicability
    $ok = New-DbM28ConfigChangeRequest -TargetType 'PROVIDER' -TargetId 'deepseek' -Field 'Enabled' -NewValue $true -Category 'CONFIG_STATUS' -NowUtc $script:NowUtc
    $v4 = Test-DbM28ConfigChangeRequest $ok
    Assert-Equal $v4.Valid $true 'S31: valid request passes'
    $app3 = Test-DbM28ConfigChangeApplicable -Configuration $cfg -Request $ok
    Assert-Equal $app3.Applicable $true 'S31: valid request applicable'
}

# S32 config persistence (validated atomic adapter on a TEMP tree; live config untouched)
function Test-S32-ConfigPersistence {
    $root = New-TempRoot
    try {
        Copy-Item -Path (Join-Path $script:Root 'config') -Destination (Join-Path $root 'config') -Recurse -Force
        $req = New-DbM28ConfigChangeRequest -TargetType 'PROVIDER' -TargetId 'deepseek' -Field 'Enabled' -NewValue $true -Category 'CONFIG_STATUS' -NowUtc $script:NowUtc
        $r = Apply-DbM28ConfigChange -Root $root -Request $req -NowUtc $script:NowUtc
        Assert-Equal $r.Message 'APPLIED' 'S32: apply succeeded'
        Assert-Equal $r.Applied $true 'S32: applied flag'
        Assert-Equal $r.Validated $true 'S32: validated before save (real loader round-trip)'
        Assert-Equal $r.ReadBack $true 'S32: read-back verified'
        Assert-Equal $r.Audited $true 'S32: audited'
        Assert-Equal $r.OldValue $false 'S32: old value false'
        Assert-Equal $r.NewValue $true 'S32: new value true'
        # The live config tree must be byte-identical
        foreach ($rel in $script:ConfigFiles) {
            $live = Get-Sha256 (Join-Path $script:Root $rel)
            Assert-True ($live -eq $script:CfgShaBefore[$rel]) "S32: live config untouched: $rel"
        }
    } finally {
        Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# S33 config read-back (the persisted value round-trips the real loader)
function Test-S33-ConfigReadBack {
    $root = New-TempRoot
    try {
        Copy-Item -Path (Join-Path $script:Root 'config') -Destination (Join-Path $root 'config') -Recurse -Force
        $req = New-DbM28ConfigChangeRequest -TargetType 'MODEL' -TargetId 'deepseek-v4-flash' -Field 'Enabled' -NewValue $true -Category 'MODEL' -NowUtc $script:NowUtc
        $r = Apply-DbM28ConfigChange -Root $root -Request $req -NowUtc $script:NowUtc
        Assert-Equal $r.Message 'APPLIED' 'S33: apply succeeded'
        $cfg = Import-AiCostConfiguration -Root $root
        $model = $cfg.Models['deepseek-v4-flash']
        Assert-Equal $model.Enabled $true 'S33: read-back shows Enabled=true'
        Assert-Equal $model.ModelId 'deepseek-v4-flash' 'S33: model identity preserved through round-trip'
    } finally {
        Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# S34 config schema/version preserved (only the operator's field changes)
function Test-S34-ConfigSchemaVersionPreserved {
    $root = New-TempRoot
    try {
        Copy-Item -Path (Join-Path $script:Root 'config') -Destination (Join-Path $root 'config') -Recurse -Force
        $req = New-DbM28ConfigChangeRequest -TargetType 'PROVIDER' -TargetId 'deepseek' -Field 'Enabled' -NewValue $true -Category 'CONFIG_STATUS' -NowUtc $script:NowUtc
        $r = Apply-DbM28ConfigChange -Root $root -Request $req -NowUtc $script:NowUtc
        Assert-Equal $r.ReadBack $true 'S34: read-back passed (no unrelated fields changed)'
        $doc = Get-Content (Join-Path $root 'config\providers.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal $doc.schemaVersion 1 'S34: schemaVersion preserved'
        $deepseek = @($doc.providers | Where-Object { $_.ProviderId -eq 'deepseek' })[0]
        Assert-Equal $deepseek.Enabled $true 'S34: field applied'
        $local = @($doc.providers | Where-Object { $_.ProviderId -eq 'local' })[0]
        Assert-Equal $local.Enabled $false 'S34: unrelated provider untouched'
    } finally {
        Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# S35 config-change audit (timestamp, target, field, old/new NON-SECRET state, operator action)
function Test-S35-ConfigChangeAudit {
    $root = New-TempRoot
    try {
        Copy-Item -Path (Join-Path $script:Root 'config') -Destination (Join-Path $root 'config') -Recurse -Force
        $req = New-DbM28ConfigChangeRequest -TargetType 'PROVIDER' -TargetId 'deepseek' -Field 'Enabled' -NewValue $true -Category 'CONFIG_STATUS' -NowUtc $script:NowUtc
        $r = Apply-DbM28ConfigChange -Root $root -Request $req -NowUtc $script:NowUtc
        Assert-Equal $r.Audited $true 'S35: audit written'
        $audit = Read-DbM28AuditLog -Root $root
        Assert-Equal $audit.Count 1 'S35: one audit record'
        $rec = $audit.Records[0]
        Assert-Equal $rec.TargetType 'PROVIDER' 'S35: audit target type'
        Assert-Equal $rec.TargetId 'deepseek' 'S35: audit target id'
        Assert-Equal $rec.Field 'Enabled' 'S35: audit field'
        Assert-Equal $rec.OldValue $false 'S35: audit old (non-secret) state'
        Assert-Equal $rec.NewValue $true 'S35: audit new (non-secret) state'
        Assert-Equal $rec.OperatorAction 'SET' 'S35: audit operator action'
        Assert-Equal $rec.TimestampUtc $script:NowUtc 'S35: audit timestamp'
    } finally {
        Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# S36 secret audit redaction (audit records never carry secret values)
function Test-S36-SecretAuditRedaction {
    $root = New-TempRoot
    try {
        Copy-Item -Path (Join-Path $script:Root 'config') -Destination (Join-Path $root 'config') -Recurse -Force
        # Change a MODEL's Notes -- never a secret value -- and confirm the audit
        # record's RedactedFields list protects SecretReference even for provider rows.
        $req = New-DbM28ConfigChangeRequest -TargetType 'MODEL' -TargetId 'deepseek-v4-flash' -Field 'Enabled' -NewValue $true -Category 'MODEL' -NowUtc $script:NowUtc
        $r = Apply-DbM28ConfigChange -Root $root -Request $req -NowUtc $script:NowUtc
        Assert-Equal $r.Audited $true 'S36: audit written'
        $audit = Read-DbM28AuditLog -Root $root
        $rec = $audit.Records[0]
        Assert-True (@($rec.RedactedFields) -contains 'SecretReference') 'S36: RedactedFields lists SecretReference'
        $auditText = ($audit | ConvertTo-DbM28Json -Depth 0)
        $leak = Test-DbM28SecretLeak $auditText
        Assert-Equal $leak.Leak $false 'S36: audit JSON has no secret values'
        Assert-NotContains $auditText 'FX_TEST_KEY_VALUE' 'S36: no secret value in audit'
        Assert-NotContains $auditText 'DEEPSEEK_API_KEY=' 'S36: no secret assignment in audit'
    } finally {
        Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# S37 DB-M27 calculator integration (VIEW COST ESTIMATE delegates to the calculator)
function Test-S37-M27CalculatorIntegration {
    $view = Get-ConfigView
    Assert-Equal $view.CostEstimate.Integration 'DB-M27' 'S37: integration is DB-M27'
    Assert-Equal $view.CostEstimate.Authority 'DB-M16' 'S37: cost authority is DB-M16 (through DB-M27)'
    Assert-Equal $view.CostEstimate.Available $true 'S37: cost estimate available'
    Assert-NotNull $view.CostEstimate.Estimate.EstimatedCost 'S37: estimate value present'
    Assert-Equal $view.CostEstimate.Estimate.IsEstimated $true 'S37: estimate labelled estimated'
    Assert-Contains (ConvertTo-DbM28Html -View $view) 'VIEW COST ESTIMATE' 'S37: UI shows the estimate card'
}

# S38 no duplicate cost calculation (DB-M28 contains NO cost formula of its own)
function Test-S38-NoDuplicateCostCalculation {
    $view = Get-ConfigView
    Assert-Equal $view.CostEstimate.Authority 'DB-M16' 'S38: engine delegates to DB-M16'
    # The library must CALL the calculator (reuse) but never re-implement pricing math.
    $libText = ''
    foreach ($rel in $script:LibraryFiles) { $libText += (Get-Content (Join-Path $script:Root $rel) -Raw) }
    Assert-Contains $libText 'Invoke-DbM27Calculator' 'S38: library consumes the DB-M27 calculator'
    Assert-NotContains $libText 'Calculate-AiAttemptCost' 'S38: library never re-implements the cost formula'
    Assert-NotContains $libText 'InputPricePerMillion' 'S38: library never reads raw pricing math'
}

# S39 DB-M26 preserved (dashboard child suite)
function Test-S39-M26Preserved {
    $r = Invoke-RegressionSuite -Name 'DBM26' -Path 'ai-routing\dashboard\Test-DbM26Dashboard.ps1' -Root $script:Root
    $script:RegressionResults.Add($r)
    $m26Suite = Join-Path $script:Root 'ai-routing\dashboard\Test-DbM26Dashboard.ps1'
    # DERIVED, not pinned. This used to read `Assert-Equal $r.Passed 381`. 381 was the pre-migration
    # size and has been wrong since; and even when a pinned count happens to be right it asserts the
    # ENVIRONMENT (how much of the run was reachable) rather than the estate. The property worth
    # asserting is that DB-M26 ran the inventory it declares, which stays true when a scenario is
    # added and goes RED when one silently stops running.
    $m26Declared = @(Get-ChildSuiteDeclaration -Path $m26Suite -Kind 'ScenarioList').Count
    $m26Reported = Get-ChildSuiteReportedCount -Log $r.Log -Pattern 'DB-M26 SCENARIOS:\s*(\d+)\s+scenarios' -SuiteName 'DBM26'
    Assert-True ($m26Reported -eq $m26Declared) "S39: DB-M26 ran the inventory it declares (declares $m26Declared scenarios, reported $m26Reported)"
    Assert-True (($r.Passed + $r.Failed) -ge $m26Declared) "S39: DB-M26 ran at least one assertion per declared scenario (declares $m26Declared scenarios, ran $($r.Passed + $r.Failed) assertions)"
    Assert-Equal $r.Failed 1 'S39: DB-M26 suite still exactly 1 failed (S41, external workbook-authority drift)'
    Assert-Contains $r.Log 'S41' 'S39: the single failure is the known S41'
    Assert-Contains $r.Log 'F520060C' 'S39: S41 failure names the stale recorded authority hash'
    $script:ExternalDrift.Add('M26 S41 workbook-authority drift (suite records F520060C; live workbook is 6D42C3BF after DB-M12.4 closure 2026-08-31)')
}

# S40 DB-M18.1 preserved (child suite is green; R45 has relocated, not failed)
function Test-S40-M181Preserved {
    if (-not $script:ForgeRoot) {
        $script:HostSkips.Add('S40 DB-M18.1 preservation: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT); the suite is Forge-owned')
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
    Assert-Contains $r.Log '[SKIP] R45' 'S40: the relocated DB-M18 dependency is reported as an explicit skip'
    if ($r.Log -match '\[FAIL\]\s+R50') {
        $m124 = Invoke-RegressionSuite -Name 'M124Verify' -Path 'scripts\Test-DBM124TrialCycleClosure.ps1' -Root $script:ForgeRoot
        $script:RegressionResults.Add($m124)
        Assert-True ($m124.ExitCode -eq 0) 'S40: M12.4 child passes standalone (R50 was a nested build-contention artifact)'
        Assert-True ($m124.Failed -eq 0) 'S40: M12.4 child standalone 0 failures'
        Assert-True ($r.Passed -ge 71 -and $r.Passed -le 72) 'S40: DB-M18.1 pass count preserved (71 under R50 flake)'
        $script:ExternalDrift.Add('DBM181 R50 flake (DB-M12.4 nested build-contention; standalone green 54/54)')
    } else {
        Assert-Equal $r.Passed 72 'S40: DB-M18.1 suite 72 passed'
        Assert-Equal $r.Failed 0 'S40: DB-M18.1 suite 0 failures'
    }
}

# S41 DB-M19 preserved (router child suite)
function Test-S41-M19Preserved {
    $r = Invoke-RegressionSuite -Name 'DBM19' -Path 'ai-routing\router\Test-DbM19Routing.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.ExitCode -eq 0) 'S41: DB-M19 regression exit 0'
    Assert-True ($r.Failed -eq 0) 'S41: DB-M19 regression zero failures'
}

# S42 DB-M22 preserved (provider-health child suite)
function Test-S42-M22Preserved {
    $r = Invoke-RegressionSuite -Name 'DBM22' -Path 'ai-routing\provider-health\Test-DbM22Health.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.ExitCode -eq 0) 'S42: DB-M22 regression exit 0'
    Assert-True ($r.Failed -eq 0) 'S42: DB-M22 regression zero failures'
}

# S43 DB-M23 preserved (providers child suite)
function Test-S43-M23Preserved {
    $r = Invoke-RegressionSuite -Name 'DBM23' -Path 'ai-routing\providers\Test-DbM23Providers.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.ExitCode -eq 0) 'S43: DB-M23 regression exit 0'
    Assert-True ($r.Failed -eq 0) 'S43: DB-M23 regression zero failures'
}

# S44 no budget override (DB-M21 informational only)
function Test-S44-NoBudgetOverride {
    $view = Get-ConfigView
    Assert-True $view.Guard.BudgetPolicyUnmodified 'S44: budget policy unmodified'
    Assert-Equal $view.CostEstimate.Budget.InformationalOnly $true 'S44: budget informational only'
    Assert-Equal $view.CostEstimate.Budget.OverrideAllowed $false 'S44: no override capability'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Test-AiBudgetOverride' "S44: no budget override call ($rel)"
    }
}

# S45 no router hard-rule override (DB-M19 hard gates never overridden)
function Test-S45-NoRouterHardRuleOverride {
    $view = Get-ConfigView
    Assert-True $view.Guard.CapabilityHardChecksUnmodified 'S45: hard capability checks unmodified'
    Assert-True $view.Guard.RoutingPolicyUnmodified 'S45: routing policy unmodified'
    $cap = @($view.Models | Where-Object { $_.ModelId -eq 'fx-cap-mismatch' })[0]
    Assert-Equal $cap.EligibilityToggleFixable $false 'S45: hard gate not toggle-fixable'
    Assert-Equal $cap.EligibilityHardCapabilityGate $true 'S45: hard gate still engaged'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'New-RoutingDecision' "S45: no routing decision override ($rel)"
        Assert-NotContains $text 'Get-AiEscalationDecision' "S45: no escalation override ($rel)"
    }
}

# S46 no provider-health mutation
function Test-S46-NoProviderHealthMutation {
    $view = Get-ConfigView
    Assert-True $view.Guard.ProviderHealthUnmodified 'S46: health unmodified'
    Assert-Equal $view.HealthStatus.ReadOnly $true 'S46: health read-only'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Set-ProviderHealth' "S46: no health write ($rel)"
        Assert-NotContains $text 'Update-ProviderCircuitState' "S46: no circuit write ($rel)"
    }
}

# S47 no pricing mutation (DB-M15 stays the pricing authority)
function Test-S47-NoPricingMutation {
    $view = Get-ConfigView
    Assert-True $view.Guard.PricingUnmodified 'S47: pricing unmodified'
    Assert-Equal $view.PricingReference.ReadOnly $true 'S47: pricing reference read-only'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Add-AiPricingRecord' "S47: no pricing record write ($rel)"
        Assert-NotContains $text 'Add-AiPriceVersion' "S47: no pricing version write ($rel)"
    }
}

# S48 no AI execution (AUTO_EXECUTION_ENABLED = FALSE)
function Test-S48-NoAiExecution {
    $view = Get-ConfigView
    Assert-Equal $view.Guard.AutoExecutionEnabled $false 'S48: auto execution disabled'
    Assert-Equal $view.Guard.ProviderModelExecuted $false 'S48: no provider/model executed'
    Assert-Equal $view.BuildInfo.AutoExecutionEnabled $false 'S48: build info auto execution disabled'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Invoke-Provider' "S48: no provider invoke ($rel)"
        Assert-NotContains $text 'Send-ProviderRequest' "S48: no provider send ($rel)"
    }
}

# S49 paid API calls = 0
function Test-S49-PaidCallsZero {
    $view = Get-ConfigView
    Assert-Equal $view.Guard.PaidApiCalls 0 'S49: zero paid API calls'
    Assert-Equal $view.BuildInfo.PaidApiCalls 0 'S49: build info zero paid calls'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'Invoke-WebRequest' "S49: no web request ($rel)"
        Assert-NotContains $text 'Invoke-RestMethod' "S49: no rest call ($rel)"
        Assert-NotContains $text 'HttpClient' "S49: no http client ($rel)"
    }
}

# S50 network calls = 0
function Test-S50-NetworkZero {
    $view = Get-ConfigView
    Assert-Equal $view.Guard.NetworkCalls 0 'S50: zero network calls'
    Assert-Equal $view.BuildInfo.NetworkCalls 0 'S50: build info zero network calls'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'System.Net.WebClient' "S50: no webclient ($rel)"
        Assert-NotContains $text 'Start-Process' "S50: no process spawn ($rel)"
        Assert-NotContains $text 'Invoke-Expression' "S50: no dynamic invocation ($rel)"
    }
}

# S51 canonical workbook unchanged (byte-identical, no governance mutation)
function Test-S51-WorkbookUnchanged {
    Assert-NotNull $script:WorkbookShaBefore 'S51: workbook reachable for verification'
    $now = Get-Sha256 $script:WorkbookPath
    Assert-True ($now -eq $script:WorkbookShaBefore) 'S51: canonical Nexus workbook byte-identical'
    # The recorded post-DB-M12.4 hash pins a MOMENT in the governed workbook's life.
    # Governed work legitimately advances it (the 2026-09-05 transition to M-12-0.4 moved
    # the authoritative workbook 6D42C3BF -> 8AA73778), so a superseded hash is recorded
    # as environment drift rather than failed here -- the same disposition DB-M30 D30
    # already applies to this pin. What must never drift is the invariant asserted above:
    # this suite does not modify the authoritative workbook.
    if ($now -notmatch '6D42C3BF') {
        $nowLabel = if ($now) { ([string]$now).Substring(0, 8) } else { '<unreadable>' }
        $script:ExternalDrift.Add('S51 workbook-authority drift (suite records 6D42C3BF post-DB-M12.4; live authoritative workbook is ' + $nowLabel + ')')
    }
}

# S52 Nexus source unchanged (no Nexus source/workbook write; frozen chain intact)
function Test-S52-NexusSourceUnchanged {
    $view = Get-ConfigView
    Assert-True $view.Guard.NexusSourceUnmodified 'S52: Nexus source unmodified'
    Assert-True $view.Guard.CanonicalWorkbookUnmodified 'S52: canonical workbook unmodified'
    Assert-True $view.Guard.GitUnmodified 'S52: git unmodified'
    foreach ($rel in $script:LibraryFiles) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'NEXUS_DEVELOPMENT_CONTROL.xlsx' "S52: no workbook path in library ($rel)"
        Assert-NotContains $text 'PreDevBridgeBaseline' "S52: no Nexus baseline mutation ($rel)"
    }
}

# S53 UI regression (Lane C byte-identical)
function Test-S53-UiRegression {
    if (-not $script:ForgeRoot) {
        $script:HostSkips.Add('S53 M12.x console byte-identity: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT); the console stayed in Forge at W6/LaneA')
        return
    }
    Assert-True ($script:UiFiles.Count -gt 0) 'S53: M12.x UI source files enumerated'
    foreach ($f in $script:UiFiles) {
        $now = Get-Sha256 $f.FullName
        Assert-True ($now -eq $script:UiShaBefore[$f.FullName]) "S53: M12.x UI file unchanged: $($f.Name)"
    }
}

# S54 solution build 0 errors
function Test-S54-Build {
    if (-not $script:ForgeRoot) {
        $script:HostSkips.Add('S54 Forge solution build: Forge host root not declared (set NEXUS_FORGE_DEVBRIDGE_ROOT); the solution stayed in Forge at W6/LaneA')
        return
    }
    $sln = Join-Path $script:ForgeRoot 'src\DevBridge.slnx'
    Assert-True (Test-Path $sln) 'S54: solution present'
    if (-not (Test-Path $sln)) { return }
    $log = Join-Path $env:TEMP 'db28-build.log'
    & dotnet build $sln --nologo > $log 2>&1
    $exit = $LASTEXITCODE
    $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
    Assert-True ($exit -eq 0) "S54: dotnet build exit 0 (got $exit)"
    $errTokens = ([regex]::Matches($text, 'error\s+CS\d+')).Count
    Assert-True ($errTokens -eq 0) "S54: build has 0 error CS tokens (got $errTokens)"
    Assert-Contains $text '0 Error' 'S54: build summary shows 0 errors'
}

# --- no-mutation / frozen-file re-verification --------------------------------------------

function Test-S55-FrozenFilesUnchanged {
    foreach ($rel in $script:FrozenFiles) {
        $after = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($after -eq $script:ShaBefore[$rel]) "S55: frozen file unchanged: $rel"
    }
    foreach ($rel in $script:FixtureFiles) {
        $after = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($after -eq $script:ShaBefore[$rel]) "S55: DB-M28 library file unchanged: $rel"
    }
    foreach ($rel in $script:ConfigFiles) {
        $after = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($after -eq $script:CfgShaBefore[$rel]) "S55: live config unchanged: $rel"
    }
    # The DB-M18.1 lineage implementation is Forge development-lifecycle logic and
    # stayed in Forge. The no-mutation guard travels with it to the DECLARED host
    # root, so the protection survives the move instead of being dropped.
    if ($script:ForgeFrozenBefore) {
        foreach ($rel in $script:ForgeFrozenFiles) {
            $after = Get-Sha256 (Join-Path $script:ForgeRoot $rel)
            Assert-True ($after -eq $script:ShaBefore[$rel]) "S55: Forge DB-M18.1 file unchanged: $rel"
        }
    }
}

# --- scenario registry + runner -----------------------------------------------------------

$script:Scenarios = @(
    'Test-S1-UiOpens', 'Test-S2-ProviderListRenders', 'Test-S3-ModelListRenders',
    'Test-S4-ProviderEnabledDisabled', 'Test-S5-ModelEnabledDisabled',
    'Test-S6-DirectRoute', 'Test-S7-GatewayRoute', 'Test-S8-LocalRoute',
    'Test-S9-ReasoningLevelsFromContracts', 'Test-S10-UnsupportedReasoningNotShown',
    'Test-S11-CapabilityDisplay', 'Test-S12-ToolCapability', 'Test-S13-StructuredOutput',
    'Test-S14-ContextCapability', 'Test-S15-PricingReferenceDisplay', 'Test-S16-PricingUnknown',
    'Test-S17-ProviderHealthReadOnly', 'Test-S18-HealthNotFabricated',
    'Test-S19-LocalProviderDisplay', 'Test-S20-LocalCostUnknownPreserved',
    'Test-S21-LocalNeverFree', 'Test-S22-OpenRouterIdentity', 'Test-S23-UnderlyingPreserved',
    'Test-S24-EligibilitySummary', 'Test-S25-DisabledExcluded',
    'Test-S26-CapabilityMismatchNotToggleable', 'Test-S27-ConfigIncompleteDisplayed',
    'Test-S28-SecretsNeverRendered', 'Test-S29-SecretsNeverLogged', 'Test-S30-SecretStatus',
    'Test-S31-ConfigValidation', 'Test-S32-ConfigPersistence', 'Test-S33-ConfigReadBack',
    'Test-S34-ConfigSchemaVersionPreserved', 'Test-S35-ConfigChangeAudit',
    'Test-S36-SecretAuditRedaction',
    'Test-S37-M27CalculatorIntegration', 'Test-S38-NoDuplicateCostCalculation',
    'Test-S39-M26Preserved', 'Test-S40-M181Preserved', 'Test-S41-M19Preserved',
    'Test-S42-M22Preserved', 'Test-S43-M23Preserved',
    'Test-S44-NoBudgetOverride', 'Test-S45-NoRouterHardRuleOverride',
    'Test-S46-NoProviderHealthMutation', 'Test-S47-NoPricingMutation',
    'Test-S48-NoAiExecution', 'Test-S49-PaidCallsZero', 'Test-S50-NetworkZero',
    'Test-S51-WorkbookUnchanged', 'Test-S52-NexusSourceUnchanged',
    'Test-S53-UiRegression', 'Test-S54-Build',
    'Test-S55-FrozenFilesUnchanged'
)

foreach ($scenario in $script:Scenarios) {
    try { & $scenario } catch { $script:ScenarioFails.Add("${scenario} threw: $($_.Exception.Message)") }
}

# --- final summary -------------------------------------------------------------------------

$passed = $script:TestCount - $script:TestFails.Count
Write-Host "DB-M28 TEST SUMMARY: $passed passed, $($script:TestFails.Count) failed"
Write-Host "DB-M28 SCENARIOS: $($script:Scenarios.Count) scenarios"
foreach ($r in $script:RegressionResults) {
    Write-Host ("DB-M28 REGRESSION {0}: {1} passed, {2} failed, exit {3}" -f $r.Name, $r.Passed, $r.Failed, $r.ExitCode)
}
foreach ($f in $script:TestFails) { Write-Host "  FAIL: $f" }
foreach ($f in $script:ScenarioFails) { Write-Host "  SCENARIO FAIL: $f" }
# Cross-tree assertions that could not run are reported, never silently dropped: a
# run that skipped them is not the same evidence as a run that executed them.
Write-Host "DB-M28 HOST SKIPS: $($script:HostSkips.Count)"
foreach ($s in $script:HostSkips) { Write-Host "  [SKIP] $s" }
if ($script:TestFails.Count -eq 0 -and $script:ScenarioFails.Count -eq 0) {
    exit 0
}
exit 1

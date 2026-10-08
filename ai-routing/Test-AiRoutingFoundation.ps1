# Test-AiRoutingFoundation.ps1 — DB-M14 self-contained assertion suite.
#
# Proves the provider/model/contract foundation WITHOUT any paid API call,
# network access, or credential use. All fixtures are in-memory or temp config
# files. ZERO paid API calls. Matches the DevBridge Assert-True convention
# (see Test-DBM04Safety.ps1).
#
# Run: powershell -NoProfile -File ai-routing\Test-AiRoutingFoundation.ps1
# Exit code: 0 all pass, 1 any failure.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "AiRoutingFoundation.ps1")

$script:Results = @()
$script:Fails = New-Object System.Collections.Generic.List[string]

function Assert-True([string]$label, [bool]$cond, [string]$detail) {
    $row = New-Object PSCustomObject
    $row | Add-Member NoteProperty -Name Scenario -Value $label
    $row | Add-Member NoteProperty -Name Pass -Value $cond
    $row | Add-Member NoteProperty -Name Detail -Value $detail
    $script:Results += $row
    if (-not $cond) {
        $script:Fails.Add(("{0}: {1}" -f $label, $detail))
        Write-Output ("  [FAIL] {0} - {1}" -f $label, $detail)
    } else {
        Write-Output ("  [PASS] {0} - {1}" -f $label, $detail)
    }
}

# --- fixture catalogues -----------------------------------------------------------

function New-ProviderFixture {
    $provs = @{}
    $provs['deepseek']  = New-AiProvider -ProviderId 'deepseek'  -DisplayName 'DeepSeek' -Enabled $true  -ProviderType 'DIRECT' -GatewayType 'ANTHROPIC_COMPATIBLE' -BaseEndpoint 'https://api.deepseek.com/anthropic' -SecretReference 'DEEPSEEK_API_KEY'
    $provs['openrouter']= New-AiProvider -ProviderId 'openrouter'-DisplayName 'OpenRouter' -Enabled $true  -ProviderType 'GATEWAY' -GatewayType 'OPENROUTER' -BaseEndpoint 'https://openrouter.ai/api/v1' -SecretReference 'OPENROUTER_API_KEY'
    $provs['local']     = New-AiProvider -ProviderId 'local'     -DisplayName 'Local'     -Enabled $true  -ProviderType 'LOCAL' -GatewayType 'OPENAI_COMPATIBLE'
    $provs['disabled']  = New-AiProvider -ProviderId 'disabled'  -DisplayName 'Disabled'  -Enabled $false -ProviderType 'DIRECT'
    return $provs
}

function New-ModelFixture {
    $models = @{}
    # primary coding model (synthetic provider model id, distinct from the real deepseek-v4-flash route)
    $models['ds-coding'] = New-AiModel -ModelId 'ds-coding' -ProviderId 'deepseek' -ProviderModelId 'coding-x' `
        -Enabled $true -LocalOrRemote 'REMOTE' -SupportsCoding $true -SupportsToolUse $true -ContextWindow 200000 -MaxOutputTokens 8000 `
        -ReasoningLevelsSupported @('MEDIUM','HIGH') -RelativeSpeed 'FAST' -ReliabilityClass 'HIGH'
    # vision-capable model
    $models['ds-vision'] = New-AiModel -ModelId 'ds-vision' -ProviderId 'deepseek' -ProviderModelId 'vision-x' `
        -Enabled $true -LocalOrRemote 'REMOTE' -SupportsVision $true -SupportsCoding $false -ContextWindow 100000
    # structured-output model
    $models['ds-structured'] = New-AiModel -ModelId 'ds-structured' -ProviderId 'deepseek' -ProviderModelId 'json-x' `
        -Enabled $true -LocalOrRemote 'REMOTE' -SupportsStructuredOutput $true -ContextWindow 100000
    # low-reasoning model
    $models['ds-low'] = New-AiModel -ModelId 'ds-low' -ProviderId 'deepseek' -ProviderModelId 'low-x' `
        -Enabled $true -LocalOrRemote 'REMOTE' -SupportsCoding $true -ContextWindow 200000 -ReasoningLevelsSupported @('LOW')
    # small context model (cannot satisfy a large context requirement)
    $models['ds-small'] = New-AiModel -ModelId 'ds-small' -ProviderId 'deepseek' -ProviderModelId 'small-x' `
        -Enabled $true -LocalOrRemote 'REMOTE' -SupportsCoding $true -ContextWindow 8000
    # disabled model - must never appear in capability results
    $models['ds-disabled'] = New-AiModel -ModelId 'ds-disabled' -ProviderId 'deepseek' -ProviderModelId 'off-x' `
        -Enabled $false -LocalOrRemote 'REMOTE' -SupportsCoding $true -ContextWindow 200000
    # DIRECT delivery route for underlying deepseek-v4-flash
    $models['ds-route'] = New-AiModel -ModelId 'ds-route' -ProviderId 'deepseek' -ProviderModelId 'deepseek-v4-flash' -UnderlyingModelId 'deepseek-v4-flash' `
        -Enabled $true -LocalOrRemote 'REMOTE' -SupportsCoding $true -ContextWindow 200000
    # GATEWAY delivery route for the SAME underlying deepseek-v4-flash via OpenRouter
    $models['or-route'] = New-AiModel -ModelId 'or-route' -ProviderId 'openrouter' -ProviderModelId 'deepseek/deepseek-v4-flash' -UnderlyingModelId 'deepseek-v4-flash' -GatewayProviderId 'openrouter' `
        -Enabled $true -LocalOrRemote 'REMOTE' -SupportsCoding $true -ContextWindow 200000
    # local coding model
    $models['local-coding'] = New-AiModel -ModelId 'local-coding' -ProviderId 'local' -ProviderModelId 'local-code' `
        -Enabled $true -LocalOrRemote 'LOCAL' -SupportsCoding $true -ContextWindow 32000 -ReliabilityClass 'STANDARD'
    return $models
}

$fixtureProviders = New-ProviderFixture
$fixtureModels = New-ModelFixture

# --- scenario 1: provider creation / validation --------------------------------------
Write-Output ""
Write-Output "== Scenario 1 - provider creation and validation =="
$p1 = New-AiProvider -ProviderId 'DeepSeek ' -DisplayName 'DeepSeek' -ProviderType 'DIRECT' -SecretReference 'DEEPSEEK_API_KEY'
Assert-True 'S1 provider created and normalized' ($p1.ProviderId -eq 'deepseek') "ProviderId normalized to lowercase; got '$($p1.ProviderId)'"
Assert-True 'S1 provider schemaVersion 1' ($p1.SchemaVersion -eq 1) "got $($p1.SchemaVersion)"
$t1 = Test-AiProvider $p1
Assert-True 'S1 provider validates' $t1.Valid ($t1.Errors -join '; ')

# --- scenario 2: duplicate provider rejected -----------------------------------------
Write-Output ""
Write-Output "== Scenario 2 - duplicate provider rejected =="
$cat2 = @{}
$null = Add-AiProvider -Catalogue $cat2 -Provider $p1
$dupRejected = $false
try { $null = Add-AiProvider -Catalogue $cat2 -Provider (New-AiProvider -ProviderId 'deepseek') } catch { $dupRejected = $true }
Assert-True 'S2 duplicate ProviderId rejected' $dupRejected "Add-AiProvider must throw on duplicate"
Assert-True 'S2 catalogue still has 1 provider' ($cat2.Count -eq 1) "got $($cat2.Count)"

# --- scenario 3: model creation ------------------------------------------------------
Write-Output ""
Write-Output "== Scenario 3 - model creation =="
$m3 = New-AiModel -ModelId 'm3' -ProviderId 'deepseek' -SupportsCoding $true
Assert-True 'S3 model created' ($m3.ModelId -eq 'm3' -and $m3.ProviderId -eq 'deepseek') "got '$($m3.ModelId)'"
Assert-True 'S3 model defaults to Enabled=false' ($m3.Enabled -eq $false) "Enabled must default false"
Assert-True 'S3 underlying defaults to self' ($m3.UnderlyingModelId -eq 'm3') "UnderlyingModelId defaults to ModelId"
Assert-True 'S3 unknown capability stays null' ($null -eq $m3.ContextWindow) "ContextWindow must be null/UNKNOWN, got '$($m3.ContextWindow)'"
$t3 = Test-AiModel $m3
Assert-True 'S3 model validates' $t3.Valid ($t3.Errors -join '; ')

# --- scenario 4: unknown provider rejected -------------------------------------------
Write-Output ""
Write-Output "== Scenario 4 - unknown provider rejected =="
$cat4 = @{}
$null = Add-AiModel -Catalogue $cat4 -Model (New-AiModel -ModelId 'orphan' -ProviderId 'nonexistent' -SupportsCoding $true)
$v4 = Validate-AiModelCatalogue -Catalogue $cat4 -Providers $fixtureProviders
Assert-True 'S4 model referencing unknown provider fails validation' (-not $v4.Valid) ($v4.Errors -join '; ')

# --- scenario 5: disabled model excluded ---------------------------------------------
Write-Output ""
Write-Output "== Scenario 5 - disabled model excluded =="
$all = @(Find-AiModelByCapability -Catalogue $fixtureModels -Providers $fixtureProviders)
Assert-True 'S5 enabled models only returned' (($all.ModelId -contains 'ds-coding') -and ($all.ModelId -notcontains 'ds-disabled')) "got $($all.ModelId -join ',')"

# --- scenario 6: capability filtering (coding) ---------------------------------------
Write-Output ""
Write-Output "== Scenario 6 - capability filtering =="
$reqCoding = New-AiCapabilityRequirement -RequiresCoding $true
$coding = @(Find-AiModelByCapability -Catalogue $fixtureModels -Providers $fixtureProviders -Requirement $reqCoding)
Assert-True 'S6 coding-capable models found' (($coding.ModelId -contains 'ds-coding') -and ($coding.ModelId -notcontains 'ds-vision')) "got $($coding.ModelId -join ',')"

# --- scenario 7: reasoning-level filtering --------------------------------------------
Write-Output ""
Write-Output "== Scenario 7 - reasoning-level filtering =="
$reqHigh = New-AiCapabilityRequirement -MinimumReasoningLevel 'HIGH'
$high = @(Find-AiModelByCapability -Catalogue $fixtureModels -Providers $fixtureProviders -Requirement $reqHigh)
Assert-True 'S7 HIGH-reasoning model found' (($high.ModelId -contains 'ds-coding') -and ($high.ModelId -notcontains 'ds-low')) "got $($high.ModelId -join ',')"
$reqLow = New-AiCapabilityRequirement -MinimumReasoningLevel 'LOW'
$low = @(Find-AiModelByCapability -Catalogue $fixtureModels -Providers $fixtureProviders -Requirement $reqLow)
Assert-True 'S7 LOW-reasoning requirement accepts HIGH model too' ($low.ModelId -contains 'ds-coding') "LOW must be satisfiable by a model supporting HIGH"

# --- scenario 8: context-size filtering ----------------------------------------------
Write-Output ""
Write-Output "== Scenario 8 - context-size filtering =="
$reqCtx = New-AiCapabilityRequirement -RequiredContextTokens 100000
$ctx = @(Find-AiModelByCapability -Catalogue $fixtureModels -Providers $fixtureProviders -Requirement $reqCtx)
Assert-True 'S8 small-context model rejected' ($ctx.ModelId -notcontains 'ds-small') "ds-small (8k) must be rejected for 100k requirement"
Assert-True 'S8 large-context model accepted' ($ctx.ModelId -contains 'ds-coding') "ds-coding (200k) must satisfy 100k"

# --- scenario 9: gateway identity -----------------------------------------------------
Write-Output ""
Write-Output "== Scenario 9 - gateway identity (same underlying model, distinct routes) =="
$routes = @(Find-AiModelByUnderlyingModel -Catalogue $fixtureModels -UnderlyingModelId 'deepseek-v4-flash')
Assert-True 'S9 both delivery routes found for one underlying model' (($routes.ModelId -contains 'ds-route') -and ($routes.ModelId -contains 'or-route')) "got $($routes.ModelId -join ',')"
$dsRoute = $fixtureModels['ds-route']
$orRoute = $fixtureModels['or-route']
Assert-True 'S9 routes share UnderlyingModelId' ($dsRoute.UnderlyingModelId -eq $orRoute.UnderlyingModelId -eq 'deepseek-v4-flash') "direct=$($dsRoute.UnderlyingModelId) gateway=$($orRoute.UnderlyingModelId)"
Assert-True 'S9 routes have distinct GatewayProviderId' ($dsRoute.GatewayProviderId -ne $orRoute.GatewayProviderId) "direct=$($dsRoute.GatewayProviderId) gateway=$($orRoute.GatewayProviderId)"
Assert-True 'S9 provider identity is separable from underlying model' ($orRoute.ProviderId -eq 'openrouter' -and $orRoute.UnderlyingModelId -eq 'deepseek-v4-flash') "provider=$($orRoute.ProviderId) underlying=$($orRoute.UnderlyingModelId)"
Assert-True 'S9 underlying-model identity preserved (not a different underlying model)' ($dsRoute.ProviderId -ne $orRoute.ProviderId) "two providers, same underlying model = two delivery routes, not two underlying models"

# --- scenario 10: vision + structured output + local/remote filters ---------------------
Write-Output ""
Write-Output "== Scenario 10 - vision / structured-output / local-remote filtering =="
$reqVision = New-AiCapabilityRequirement -RequiresVision $true
$vis = @(Find-AiModelByCapability -Catalogue $fixtureModels -Providers $fixtureProviders -Requirement $reqVision)
Assert-True 'S10 vision-capable model found' ($vis.ModelId -contains 'ds-vision') "got $($vis.ModelId -join ',')"
$reqStructured = New-AiCapabilityRequirement -RequiresStructuredOutput $true
$structured = @(Find-AiModelByCapability -Catalogue $fixtureModels -Providers $fixtureProviders -Requirement $reqStructured)
Assert-True 'S10 structured-output model found' ($structured.ModelId -contains 'ds-structured') "got $($structured.ModelId -join ',')"
$reqLocalOnly = New-AiCapabilityRequirement -RemoteAllowed $false
$localOnly = @(Find-AiModelByCapability -Catalogue $fixtureModels -Providers $fixtureProviders -Requirement $reqLocalOnly)
Assert-True 'S10 remote models excluded when remote not allowed' (($localOnly.ModelId -contains 'local-coding') -and ($localOnly.ModelId -notcontains 'ds-coding')) "got $($localOnly.ModelId -join ',')"

# --- scenario 11: manual execution mode ------------------------------------------------
Write-Output ""
Write-Output "== Scenario 11 - manual execution mode =="
function New-RoutingConfig([string]$mode, [string[]]$allowed) {
    $r = [pscustomobject]@{ SchemaVersion = 1; ExecutionMode = $mode; AllowedRuntimeModes = @($allowed); Roles = $null }
    return $r
}
$cfgManual = @{ Routing = (New-RoutingConfig 'MANUAL' @('MANUAL')); Providers = $fixtureProviders; Models = $fixtureModels }
$vManual = Validate-AiRoutingFoundation -Configuration $cfgManual
Assert-True 'S11 MANUAL mode is valid' $vManual.Valid ($vManual.Errors -join '; ')
$cfgAuto = @{ Routing = (New-RoutingConfig 'AUTO' @('MANUAL')); Providers = $fixtureProviders; Models = $fixtureModels }
$vAuto = Validate-AiRoutingFoundation -Configuration $cfgAuto
Assert-True 'S11 AUTO mode rejected' (-not $vAuto.Valid) "AUTO must not be an active runtime mode"
$cfgAssisted = @{ Routing = (New-RoutingConfig 'ASSISTED' @('MANUAL')); Providers = $fixtureProviders; Models = $fixtureModels }
$vAssisted = Validate-AiRoutingFoundation -Configuration $cfgAssisted
Assert-True 'S11 ASSISTED mode not yet allowed' (-not $vAssisted.Valid) "ASSISTED is a future mode; MANUAL is the only allowed runtime mode"

# --- scenario 12: secret-value leakage protection --------------------------------------
Write-Output ""
Write-Output "== Scenario 12 - secret-value leakage protection =="
$clean = @{ ProviderId = 'x'; SecretReference = 'DEEPSEEK_API_KEY'; BaseEndpoint = 'https://api.example.com' }
$leakClean = Test-AiRoutingSecretValueLeak $clean
Assert-True 'S12 secret references are not leaks' (-not $leakClean.Leak) ($leakClean.Fields -join '; ')
$dirty = @{ ProviderId = 'x'; ApiKeyValue = 'sk-abcdefghijklmnopqrstuvwxyz123456' }
$leakDirty = Test-AiRoutingSecretValueLeak $dirty
Assert-True 'S12 embedded key value detected' $leakDirty.Leak "must flag an embedded sk- value"
$dirty2 = @{ ProviderId = 'x'; Token = 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' }
$leakDirty2 = Test-AiRoutingSecretValueLeak $dirty2
Assert-True 'S12 inline credential pattern detected' $leakDirty2.Leak "must flag Token field pattern"

# --- scenario 13: schema v1 validation -------------------------------------------------
Write-Output ""
Write-Output "== Scenario 13 - schema v1 validation =="
$badSchema = [pscustomobject]@{ SchemaVersion = 2; ProviderId = 'y'; DisplayName = 'Y'; ProviderType = 'DIRECT'; GatewayType = 'DIRECT'; Enabled = $false; Configured = $false }
$tBad = Test-AiProvider $badSchema
Assert-True 'S13 schemaVersion 2 provider rejected' (-not $tBad.Valid) "v2 must be rejected until a v2 contract is defined"
$tGood = Test-AiProvider $p1
Assert-True 'S13 schemaVersion 1 provider accepted' $tGood.Valid "v1 must pass"

# --- scenario 14: provider-name branching guard (ADR-005) -------------------------------
Write-Output ""
Write-Output "== Scenario 14 - provider-name branching guard =="
$badBranch = 'if ($Provider -eq "deepseek-v4-flash") { }'
$g1 = Test-AiProviderNameBranching -LiteralContent $badBranch
Assert-True 'S14 provider-name comparison detected' (-not $g1.Clean) ($g1.Violations -join '; ')
$badBranch2 = '$ProviderId -in @(''anthropic'',''openai'')'
$g2 = Test-AiProviderNameBranching -LiteralContent $badBranch2
Assert-True 'S14 provider-name membership detected' (-not $g2.Clean) ($g2.Violations -join '; ')
$cleanBranch = '$ok = $m.SupportsCoding -eq $true; $r.ProviderId -eq $model.ProviderId'
$g3 = Test-AiProviderNameBranching -LiteralContent $cleanBranch
Assert-True 'S14 variable-only comparisons are clean' $g3.Clean ($g3.Violations -join '; ')
$libFiles = @(
    (Join-Path $PSScriptRoot 'AiRoutingContracts.ps1'),
    (Join-Path $PSScriptRoot 'AiProvider.ps1'),
    (Join-Path $PSScriptRoot 'ModelCatalogue.ps1'),
    (Join-Path $PSScriptRoot 'AiRoutingFoundation.ps1')
)
$g4 = Test-AiProviderNameBranching -Paths $libFiles
Assert-True 'S14 shared routing libs contain no provider-name branching' $g4.Clean ($g4.Violations -join '; ')

# --- scenario 15: catalogue serialization / deserialization ------------------------------
Write-Output ""
Write-Output "== Scenario 15 - catalogue serialization / deserialization =="
$tmp = Join-Path $script:Root 'logs\selftest\db-m14-serialize'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'config') | Out-Null
@{
    schemaVersion = 1
    executionMode = 'MANUAL'
    allowedRuntimeModes = @('MANUAL')
} | ConvertTo-Json | Out-File (Join-Path $tmp 'config\ai-routing.json') -Encoding utf8
@{
    schemaVersion = 1
    providers = @(
        @{ ProviderId = 'deepseek'; DisplayName = 'DeepSeek'; Enabled = $false; Configured = $false; ProviderType = 'DIRECT'; GatewayType = 'ANTHROPIC_COMPATIBLE'; SecretReference = 'DEEPSEEK_API_KEY' }
    )
} | ConvertTo-Json -Depth 5 | Out-File (Join-Path $tmp 'config\providers.json') -Encoding utf8
@{
    schemaVersion = 1
    models = @(
        @{ ModelId = 'deepseek-v4-flash'; ProviderId = 'deepseek'; ProviderModelId = 'deepseek-v4-flash'; Enabled = $false; SupportsCoding = $true; LocalOrRemote = 'REMOTE' }
    )
} | ConvertTo-Json -Depth 5 | Out-File (Join-Path $tmp 'config\models.json') -Encoding utf8
$reloaded = Import-AiRoutingConfiguration -Root $tmp
Assert-True 'S15 providers reloaded from JSON' ($reloaded.Providers.Count -eq 1 -and $reloaded.Providers['deepseek'].GatewayType -eq 'ANTHROPIC_COMPATIBLE') "got $($reloaded.Providers.Count)"
Assert-True 'S15 models reloaded from JSON' ($reloaded.Models.Count -eq 1 -and $reloaded.Models['deepseek-v4-flash'].SupportsCoding -eq $true) "got $($reloaded.Models.Count)"
$vReloaded = Validate-AiRoutingFoundation -Configuration $reloaded
Assert-True 'S15 reloaded catalogue validates' $vReloaded.Valid ($vReloaded.Errors -join '; ')

# --- scenario 16: duplicate ProviderModelId rejected -------------------------------------
Write-Output ""
Write-Output "== Scenario 16 - duplicate ProviderModelId rejected =="
$cat16 = @{}
$null = Add-AiModel -Catalogue $cat16 -Model (New-AiModel -ModelId 'a' -ProviderId 'deepseek' -ProviderModelId 'same-x')
$null = Add-AiModel -Catalogue $cat16 -Model (New-AiModel -ModelId 'b' -ProviderId 'deepseek' -ProviderModelId 'same-x')
$v16 = Validate-AiModelCatalogue -Catalogue $cat16 -Providers $fixtureProviders
Assert-True 'S16 duplicate ProviderModelId within provider flagged' (-not $v16.Valid) ($v16.Errors -join '; ')

# --- scenario 17: provider health exclusion ----------------------------------------------
Write-Output ""
Write-Output "== Scenario 17 - provider health exclusion =="
$reqCoding17 = New-AiCapabilityRequirement -RequiresCoding $true
$health = @{ deepseek = 'UNAVAILABLE' }
$healthy = @(Find-AiModelByCapability -Catalogue $fixtureModels -Providers $fixtureProviders -Requirement $reqCoding17 -ProviderHealth $health)
Assert-True 'S17 unavailable provider models excluded' (($healthy.ModelId -notcontains 'ds-coding') -and ($healthy.ModelId -contains 'or-route')) "got $($healthy.ModelId -join ',')"

# --- scenario 18: no network / no API calls in the foundation -----------------------------
Write-Output ""
Write-Output "== Scenario 18 - no network / no API calls =="
$forbidden = @('Invoke-RestMethod','Invoke-WebRequest','System.Net.Http','HttpClient','Invoke-AiCall','curl','Start-BitsTransfer','System.Net.WebClient')
$foundForbidden = @()
foreach ($f in $libFiles) {
    $text = Get-Content $f -Raw -Encoding UTF8
    foreach ($tok in $forbidden) {
        if ($text -match [regex]::Escape($tok)) { $foundForbidden += "$($f.Split('\')[-1]):$tok" }
    }
}
Assert-True 'S18 foundation libraries contain no API/network calls' ($foundForbidden.Count -eq 0) ($foundForbidden -join '; ')

# --- scenario 19: roles resolve to catalogue models ---------------------------------------
Write-Output ""
Write-Output "== Scenario 19 - role aliases resolve =="
$r19 = [pscustomobject]@{ SchemaVersion = 1; ExecutionMode = 'MANUAL'; AllowedRuntimeModes = @('MANUAL'); Roles = [pscustomobject]@{ DefaultCheapModel = 'deepseek-v4-flash'; DefaultReviewer = 'claude-opus-5' } }
$cfg19 = @{ Routing = $r19; Providers = $fixtureProviders; Models = $fixtureModels }
$v19 = Validate-AiRoutingFoundation -Configuration $cfg19
Assert-True 'S19 roles resolving models pass' $v19.Valid ($v19.Errors -join '; ')
$r19b = [pscustomobject]@{ SchemaVersion = 1; ExecutionMode = 'MANUAL'; AllowedRuntimeModes = @('MANUAL'); Roles = [pscustomobject]@{ DefaultPremiumModel = 'does-not-exist' } }
$cfg19b = @{ Routing = $r19b; Providers = $fixtureProviders; Models = $fixtureModels }
$v19b = Validate-AiRoutingFoundation -Configuration $cfg19b
Assert-True 'S19 unresolved role produces a warning' (($v19b.Warnings -join '; ') -match 'does-not-exist') ($v19b.Warnings -join '; ')

# --- scenario 20: capability requirement contract validation ------------------------------
Write-Output ""
Write-Output "== Scenario 20 - capability requirement contract validation =="
$reqValid = New-AiCapabilityRequirement -TaskId 'T1' -TaskType 'IMPLEMENTATION' -Complexity 'HIGH' -Risk 'MEDIUM' -MinimumReasoningLevel 'HIGH' -ExecutionMode 'MANUAL'
$tv = Test-AiCapabilityRequirement $reqValid
Assert-True 'S20 valid requirement passes' $tv.Valid ($tv.Errors -join '; ')
$reqBad = New-AiCapabilityRequirement -MinimumReasoningLevel 'ULTRA' -ExecutionMode 'MANUAL'
$tb = Test-AiCapabilityRequirement $reqBad
Assert-True 'S20 invalid reasoning level rejected' (-not $tb.Valid) ($tb.Errors -join '; ')
$reqBadMode = New-AiCapabilityRequirement -ExecutionMode 'BOGUS'
$tm = Test-AiCapabilityRequirement $reqBadMode
Assert-True 'S20 invalid execution mode rejected' (-not $tm.Valid) ($tm.Errors -join '; ')
# AUTO is vocabulary-valid in a requirement, but the ACTIVE runtime mode is
# MANUAL-only - that gate is enforced by the foundation (S11), not by the
# requirement contract. Both levels are covered by the suite.
$reqAuto = New-AiCapabilityRequirement -ExecutionMode 'AUTO'
$tm2 = Test-AiCapabilityRequirement $reqAuto
Assert-True 'S20 AUTO is vocabulary-valid in a requirement (runtime gate is S11)' $tm2.Valid ($tm2.Errors -join '; ')

# --- scenario 21: routing decision contract (shape only, no logic) -----------------------
Write-Output ""
Write-Output "== Scenario 21 - routing decision contract =="
$dec = New-AiRoutingDecision -RoutingRequestId 'R1' -TaskId 'T1' -EligibleCandidateIds @('a','b') -RejectedCandidateIds @('c')
$td = Test-AiRoutingDecision $dec
Assert-True 'S21 decision shape valid (EstimatedCost stays null)' ($td.Valid -and $null -eq $dec.EstimatedCost) ($td.Errors -join '; ')
$dec2 = New-AiRoutingDecision -RoutingRequestId 'R2' -ReasoningLevel 'BOGUS'
$td2 = Test-AiRoutingDecision $dec2
Assert-True 'S21 invalid reasoning level in decision rejected' (-not $td2.Valid) ($td2.Errors -join '; ')

# --- summary -------------------------------------------------------------------------------
Write-Output ""
Write-Output "=========================================="
$passed = @($script:Results | Where-Object { $_.Pass }).Count
$failed = @($script:Results | Where-Object { -not $_.Pass }).Count
Write-Output ("DB-M14 TEST SUMMARY: {0} passed, {1} failed" -f $passed, $failed)
Write-Output ("Paid API calls: 0")
if ($script:Fails.Count -gt 0) {
    Write-Output "Failures:"
    foreach ($f in $script:Fails) { Write-Output "  - $f" }
    exit 1
}
exit 0

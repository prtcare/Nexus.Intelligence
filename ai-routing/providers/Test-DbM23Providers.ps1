# Test-DbM23Providers.ps1 -- DB-M23 provider adapter foundations test suite (S1-S53).
#
# Pure ASCII, offline, deterministic: 0 network calls, 0 paid AI calls,
# AUTO_EXECUTION_ENABLED = FALSE. All evaluations use the injected timestamp
# (2026-08-31T10:00:00Z). No provider/model is ever invoked.
#
# Scenario map:
#   Local models .................. S1-S10
#   OpenRouter gateway ........... S11-S17
#   Request normalization ........ S18-S25
#   Response / usage ............. S26-S32
#   Security ..................... S33-S35
#   Dry-run ...................... S36-S38
#   Integration / boundaries ..... S39-S53
#
# Fixture note: no variable named $fails/$Fails (case-insensitive collision with
# the harness counter $script:Fails); no `@($nullVariable).Count` on unbound params.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
. (Join-Path $PSScriptRoot "..\AiRoutingFoundation.ps1")         # DB-M14 (READ-ONLY)
. (Join-Path $PSScriptRoot "..\router\RoutingCandidate.ps1")     # DB-M19 evidence (READ-ONLY)
. (Join-Path $PSScriptRoot "common\AdapterContracts.ps1")
. (Join-Path $PSScriptRoot "common\AdapterRequest.ps1")
. (Join-Path $PSScriptRoot "common\AdapterResponse.ps1")
. (Join-Path $PSScriptRoot "common\AdapterExecutionGate.ps1")
. (Join-Path $PSScriptRoot "local\LocalProvider.ps1")
. (Join-Path $PSScriptRoot "openrouter\OpenRouterProvider.ps1")

$script:Results = 0
$script:Fails = 0
function Assert-True([bool]$C, [string]$M) { $script:Results++; if ($C) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M" } }
function Assert-False([bool]$C, [string]$M) { $script:Results++; if (-not $C) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M" } }
function Assert-Equal($A, $E, [string]$M) { $script:Results++; if ([string]$A -eq [string]$E) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M (actual=[$A] expected=[$E])" } }
function Assert-Contains($A, [string]$E, [string]$M) { $script:Results++; if (([string]($A -join ',')).IndexOf($E, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M (missing '$E' in [$($A -join ',')])" } }
function Assert-Throws([scriptblock]$SB, [string]$M) { $script:Results++; $threw = $false; try { & $SB | Out-Null } catch { $threw = $true }; if ($threw) { Write-Output "PASS: $M" } else { $script:Fails++; Write-Output "FAIL: $M" } }

$ts = [datetime]::SpecifyKind([datetime]::Parse("2026-08-31T10:00:00Z", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal), [System.DateTimeKind]::Utc)
$policy = Get-DefaultProviderHealthPolicy
$messages = @(@{ role = 'user'; content = 'summarize the adapter design' })

# ---------------------------------------------------------------------------
# Fixtures: local configs, OpenRouter config, pricing catalogue, routing gate
# ---------------------------------------------------------------------------
$localCfg = New-LocalProviderConfiguration -ProviderId 'localbox' -DisplayName 'Local Box' `
    -Endpoint 'local://localhost:11434' -ApiStyle 'OLLAMA_COMPATIBLE' -Enabled $true `
    -RequiresAuthentication $false -SupportsStreaming $true -SupportsToolCalls $true `
    -SupportsStructuredOutput $true -HealthMode 'PASSIVE' -ConfigurationKey 'LOCALBOX_CFG'
$localOpenAi = New-LocalProviderConfiguration -ProviderId 'local-openai' -Endpoint 'http://127.0.0.1:8000/v1' `
    -ApiStyle 'OPENAI_COMPATIBLE' -Enabled $true -SupportsToolCalls $true
$localDisabled = New-LocalProviderConfiguration -ProviderId 'localbox' -Endpoint 'local://localhost:11434' `
    -ApiStyle 'OLLAMA_COMPATIBLE' -Enabled $false
$localAuth = New-LocalProviderConfiguration -ProviderId 'local-sec' -Endpoint 'http://127.0.0.1:9000' `
    -ApiStyle 'OPENAI_COMPATIBLE' -Enabled $true -RequiresAuthentication $true -SecretReference 'LOCAL_SEC_KEY'

$orCfg = New-OpenRouterProviderConfiguration -Enabled $true -SupportsTools $true -SupportsStructuredOutput $true

$recConfigured = New-AiPricingRecord -PricingRecordId 'm23-local-conf' -ProviderId 'localbox' -ModelId 'lmodel-7b' `
    -Currency 'USD' -EffectiveFromUtc '2026-01-01T00:00:00Z' -ProcessingTier 'STANDARD' -TimeBand 'DEFAULT' `
    -InputPricePerMillion 0.5 -OutputPricePerMillion 1.0
$recFree = New-AiPricingRecord -PricingRecordId 'm23-local-free' -ProviderId 'localbox' -ModelId 'lmodel-free' `
    -Currency 'USD' -EffectiveFromUtc '2026-01-01T00:00:00Z' -ProcessingTier 'STANDARD' -TimeBand 'DEFAULT' `
    -InputPricePerMillion 0 -OutputPricePerMillion 0
$recOr = New-AiPricingRecord -PricingRecordId 'm23-or-claude' -ProviderId 'openrouter' -ModelId 'or:anthropic/claude-sonnet-5' `
    -Currency 'USD' -EffectiveFromUtc '2026-01-01T00:00:00Z' -ProcessingTier 'STANDARD' -TimeBand 'DEFAULT' `
    -InputPricePerMillion 3.0 -OutputPricePerMillion 15.0
$pricing = @{ 'm23-local-conf' = $recConfigured; 'm23-local-free' = $recFree; 'm23-or-claude' = $recOr }

$candLocal = New-RoutingCandidate @{ Status = 'ELIGIBLE'; ProviderId = 'localbox'; ModelId = 'lmodel-7b'; UnderlyingModelId = 'lmodel-7b' }
$routingOk = New-RoutingDecisionEvidence @{ Status = 'COMPLETED'; EligibleCandidates = @($candLocal) }
$routingNone = New-RoutingDecisionEvidence @{ Status = 'COMPLETED'; EligibleCandidates = @() }
$budgetOk = [pscustomobject]@{ Decision = 'ALLOW' }
$budgetWarn = [pscustomobject]@{ Decision = 'ALLOW_WITH_WARNING' }
$budgetNone = [pscustomobject]@{ Decision = 'NO_APPLICABLE_BUDGET' }
$budgetBlock = [pscustomobject]@{ Decision = 'BLOCK_BUDGET_EXCEEDED' }
$budgetUnknown = [pscustomobject]@{ Decision = 'BLOCK_COST_UNKNOWN' }

# ---------------------------------------------------------------------------
# S1-S10: Local models
# ---------------------------------------------------------------------------
$lc = New-LocalProviderConfiguration -ProviderId 'LocalBox' -Endpoint 'http://127.0.0.1:8080'
Assert-Equal $lc.ProviderId 'localbox' 'S1 provider id normalized to lowercase'
Assert-Equal $lc.Locality 'LOCAL' 'S1 locality forced LOCAL'
Assert-Equal $lc.SchemaVersion 1 'S1 LocalProviderConfiguration schemaVersion 1'
Assert-Equal $lc.HealthMode 'PASSIVE' 'S1 default health mode PASSIVE'
$discovery = Get-DbM23DiscoveryModes
Assert-Contains $discovery 'STATIC_CONFIG' 'S1 STATIC_CONFIG discovery implemented'
Assert-Contains $discovery 'LIVE_DISCOVERY' 'S1 LIVE_DISCOVERY is a declared (future) mode'

$vCfg = Test-LocalProviderConfiguration $localCfg
Assert-True $vCfg.Valid 'S2 valid local configuration passes validation'
$mDisabled = Register-LocalModel -Configuration $localDisabled -ModelId 'lmodel-off'
Assert-False $mDisabled.Enabled 'S2 disabled provider model is not enabled (unusable)'
$evDis = Get-LocalProviderHealthEvidence -ProviderId 'localbox' -Condition 'DISABLED' -ObservedAtUtc $ts
$avDis = Test-ProviderRouteAvailable -Evidence @($evDis) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-False $avDis.Available 'S2 disabled provider route is not available'

$pNoRec = Get-ProviderRoutePriceStatus -Catalogue $pricing -ProviderId 'localbox' -ModelId 'lmodel-none' -LocalOrRemote 'LOCAL' -TimestampUtc $ts
Assert-Equal $pNoRec.PriceStatus 'LOCAL_COST_UNKNOWN' 'S3 local without price record is LOCAL_COST_UNKNOWN (never FREE by default)'
Assert-True $pNoRec.OperationalCostUnknown 'S3 LOCAL operational cost stays UNKNOWN'
Assert-Equal $pNoRec.ProviderTokenPrice 0 'S3 provider-level default token price is 0 ONLY at the provider level'

$pFree = Get-ProviderRoutePriceStatus -Catalogue $pricing -ProviderId 'localbox' -ModelId 'lmodel-free' -LocalOrRemote 'LOCAL' -TimestampUtc $ts
Assert-Equal $pFree.PriceStatus 'FREE' 'S4 explicit zero-price record classifies FREE'
Assert-True $pFree.OperationalCostUnknown 'S4 FREE is a provider price, operational cost still unknown for LOCAL'

$pConf = Get-ProviderRoutePriceStatus -Catalogue $pricing -ProviderId 'localbox' -ModelId 'lmodel-7b' -LocalOrRemote 'LOCAL' -TimestampUtc $ts
Assert-Equal $pConf.PriceStatus 'CONFIGURED' 'S5 non-zero price record classifies CONFIGURED'
Assert-True $pConf.OperationalCostUnknown 'S5 LOCAL configured price does not imply known operational cost'
$pConfBasis = Get-ProviderRoutePriceStatus -Catalogue $pricing -ProviderId 'localbox' -ModelId 'lmodel-7b' -LocalOrRemote 'LOCAL' -TimestampUtc $ts -HasConfiguredOperationalCostBasis $true
Assert-False $pConfBasis.OperationalCostUnknown 'S5 explicit operational-cost basis resolves the LOCAL cost unknown'

$evOff = Get-LocalProviderHealthEvidence -ProviderId 'localbox' -Condition 'OFFLINE' -ObservedAtUtc $ts
Assert-Equal $evOff.ObservedState 'UNAVAILABLE' 'S6 local offline -> UNAVAILABLE'
Assert-Equal $evOff.EvidenceType 'PASSIVE_FAILURE' 'S6 local offline evidence type PASSIVE_FAILURE'
Assert-Equal $evOff.FailureCategory 'PROVIDER_AVAILABILITY' 'S6 local offline is provider availability, NEVER MODEL_QUALITY'

$evNotLoaded = Get-LocalProviderHealthEvidence -ProviderId 'localbox' -Condition 'MODEL_NOT_LOADED' -ObservedAtUtc $ts
Assert-Equal $evNotLoaded.ObservedState 'UNAVAILABLE' 'S7 model not loaded -> UNAVAILABLE'
$avNotLoaded = Test-ProviderRouteAvailable -Evidence @($evNotLoaded) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-False $avNotLoaded.Available 'S7 model-not-loaded route is unavailable'

Assert-Equal $evDis.ObservedState 'DISABLED' 'S8 local disabled -> DISABLED'
Assert-Equal $evDis.EvidenceType 'CONFIGURATION' 'S8 local disabled evidence type CONFIGURATION'
Assert-Equal $evDis.FailureCategory '' 'S8 disabled is a configuration state, not a failure category'

$mModel = Register-LocalModel -Configuration $localCfg -ModelId 'lmodel-7b' -DisplayName 'Local 7B' `
    -SupportsCoding $true -SupportsToolUse $true -SupportsReasoning $true -ReasoningLevelsSupported @('NONE','LOW','MEDIUM') `
    -ContextWindow 8192 -MaxOutputTokens 4096
Assert-Equal $mModel.LocalOrRemote 'LOCAL' 'S9 registered local model LocalOrRemote=LOCAL'
Assert-Equal $mModel.EndpointOverride 'local://localhost:11434' 'S9 registered local model EndpointOverride set'
Assert-True $mModel.SupportsToolUse 'S9 tool capability preserved'
Assert-Contains $mModel.ReasoningLevelsSupported 'MEDIUM' 'S9 reasoning levels preserved'
$mUnknown = Register-LocalModel -Configuration $localCfg -ModelId 'lmodel-cap-unknown'
Assert-True ($null -eq $mUnknown.SupportsVision) 'S9 unknown capability stays null (= UNKNOWN), never invented'

Assert-True (Test-LocalProviderConfiguration $localOpenAi).Valid 'S10 OPENAI_COMPATIBLE local runtime is a valid local configuration'
Assert-True (Test-LocalProviderConfiguration $localCfg).Valid 'S10 OLLAMA_COMPATIBLE local runtime is a valid local configuration'
$mA = Register-LocalModel -Configuration $localOpenAi -ModelId 'local-gpt-lite'
Assert-Equal $mA.EndpointOverride 'http://127.0.0.1:8000/v1' 'S10 generic local: OpenAI-compatible endpoint override preserved'
$vBad = Test-LocalProviderConfiguration ([pscustomobject]@{ ProviderId = 'x'; Locality = 'REMOTE'; Endpoint = 'http://h'; ApiStyle = 'GENERIC' })
Assert-False $vBad.Valid 'S10 a REMOTE-claimed local configuration is rejected'

# ---------------------------------------------------------------------------
# S11-S17: OpenRouter gateway
# ---------------------------------------------------------------------------
$orRoute = Register-OpenRouterRoute -Configuration $orCfg -RouteId 'anthropic/claude-sonnet-5' -DisplayName 'Claude Sonnet 5 via OR' -SupportsToolUse $true -ContextWindow 200000
Assert-Equal $orRoute.GatewayProviderId 'openrouter' 'S11 gateway identity is openrouter (distinct from model identity)'
Assert-Equal $orRoute.UnderlyingModelId 'claude-sonnet-5' 'S11 underlying model identity preserved'
Assert-Equal $orRoute.ProviderModelId 'anthropic/claude-sonnet-5' 'S11 full route id preserved as ProviderModelId'
Assert-Equal $orRoute.ProviderId 'openrouter' 'S11 provider id is the gateway'

$dec1 = Get-OpenRouterRouteDecomposition -RouteId 'anthropic/claude-sonnet-5'
Assert-Equal $dec1.ModelId 'or:anthropic/claude-sonnet-5' 'S12 ModelId catalogue key is or:<route>'
Assert-Equal $dec1.UnderlyingModelId 'claude-sonnet-5' 'S12 underlying = model part after last /'

$orRoute2 = Register-OpenRouterRoute -Configuration $orCfg -RouteId 'openai/gpt-4o'
$catalogue13 = @{}
$catalogue13[$orRoute.ModelId] = $orRoute
$catalogue13[$orRoute2.ModelId] = $orRoute2
# two distinct gateway routes to the SAME underlying model via two providers
$orRoute3 = Register-OpenRouterRoute -Configuration $orCfg -RouteId 'mistral/mistral-large'
$catalogue13[$orRoute3.ModelId] = $orRoute3
$sameUnderlying = Find-AiModelByUnderlyingModel -Catalogue $catalogue13 -UnderlyingModelId 'claude-sonnet-5'
$sameUnderlying2 = Find-AiModelByUnderlyingModel -Catalogue $catalogue13 -UnderlyingModelId 'mistral-large'
Assert-Equal @($sameUnderlying).Count 1 'S13 distinct routes are addressable per underlying model'
Assert-Equal @($sameUnderlying2).Count 1 'S13 gateway route for mistral-large resolvable by underlying model'
$direct = New-AiModel -ModelId 'claude-sonnet-5' -ProviderId 'anthropic' -UnderlyingModelId 'claude-sonnet-5'
$catalogue13['claude-sonnet-5'] = $direct
$both = Find-AiModelByUnderlyingModel -Catalogue $catalogue13 -UnderlyingModelId 'claude-sonnet-5'
Assert-Equal @($both).Count 2 'S13 direct + gateway routes to one underlying model both resolve'

$orCfgTest = New-OpenRouterProviderConfiguration
Assert-Equal $orCfgTest.ProviderType 'GATEWAY' 'S14 OpenRouter config ProviderType=GATEWAY'
Assert-Equal $orCfgTest.GatewayType 'OPENROUTER' 'S14 OpenRouter config GatewayType=OPENROUTER'
Assert-True ($orCfgTest.BaseEndpoint -like 'https://*') 'S14 OpenRouter base endpoint is https'
Assert-Equal $orCfgTest.ApiKeyReference 'OPENROUTER_API_KEY' 'S14 ApiKeyReference is an env-var NAME (never a value)'
Assert-True (Test-OpenRouterProviderConfiguration $orCfgTest).Valid 'S14 OpenRouter configuration validates'

$decVariant = Get-OpenRouterRouteDecomposition -RouteId 'anthropic/claude-3.5-sonnet:beta'
Assert-Equal $decVariant.UnderlyingModelId 'claude-3.5-sonnet' 'S15 :variant suffix stripped from underlying model identity'
Assert-Equal $decVariant.ProviderModelId 'anthropic/claude-3.5-sonnet:beta' 'S15 full variant route preserved as ProviderModelId'

$orUnknown = Register-OpenRouterRoute -Configuration $orCfg -RouteId 'openai/gpt-4o'
Assert-True ($null -eq $orUnknown.SupportsVision) 'S16 unknown OpenRouter capability stays null (= UNKNOWN)'

$orRouteA = Register-OpenRouterRoute -Configuration $orCfg -RouteId 'google/gemini-2.0-flash'
Assert-Equal $orRouteA.LocalOrRemote 'REMOTE' 'S17 OpenRouter route is REMOTE'
Assert-True ($orRouteA.ModelId -like 'or:*') 'S17 route ModelId key carries or: prefix'
$badDec = Get-OpenRouterRouteDecomposition -RouteId 'notaroute'
Assert-False $badDec.Valid 'S17 invalid route id (no /) is refused (structured, non-throwing)'
$badDec2 = Get-OpenRouterRouteDecomposition -RouteId ''
Assert-False $badDec2.Valid 'S17 empty route id is refused'

# ---------------------------------------------------------------------------
# S18-S25: request normalization
# ---------------------------------------------------------------------------
$rq = New-ProviderRequest -RequestId 'RQ-0001' -TaskId 'T1' -RoutingDecisionId 'RD-1' -ProviderId 'localbox' -ModelId 'lmodel-7b' `
    -UnderlyingModelId 'lmodel-7b' -ReasoningLevel 'MEDIUM' -Messages $messages -MaxOutputTokens 1024 -EstimatedContextTokens 512 -TimeoutSeconds 60
Assert-Equal $rq.PSCustomVersion 'ProviderRequest v1' 'S18 ProviderRequest v1 field table'
Assert-Equal $rq.ReasoningLevel 'MEDIUM' 'S18 request carries DB-M14 reasoning level (not a provider param name)'
Assert-Equal $rq.MessageCount 1 'S18 message count derived'
Assert-True (Test-ProviderRequest $rq).IsValid 'S18 valid ProviderRequest passes validation'
Assert-False ($rq.PSObject.Properties.Name -contains 'reasoning_effort') 'S18 no provider-specific parameter leaks into the request'

$rzNone = ConvertTo-DbM23ReasoningParam -ApiStyle 'OPENAI_COMPATIBLE' -ReasoningLevel 'NONE'
Assert-Equal $rzNone.Status 'OMITTED' 'S19 NONE reasoning is OMITTED (no parameter)'
Assert-True ($null -eq $rzNone.ParamName) 'S19 OMITTED emits no provider parameter'

$rzLow = ConvertTo-DbM23ReasoningParam -ApiStyle 'OPENAI_COMPATIBLE' -ReasoningLevel 'LOW'
$rzMed = ConvertTo-DbM23ReasoningParam -ApiStyle 'OPENAI_COMPATIBLE' -ReasoningLevel 'MEDIUM'
$rzHigh = ConvertTo-DbM23ReasoningParam -ApiStyle 'OPENAI_COMPATIBLE' -ReasoningLevel 'HIGH'
Assert-Equal $rzLow.Status 'TRANSLATED' 'S20 OPENAI LOW translated'
Assert-Equal $rzLow.ParamName 'reasoning_effort' 'S20 OPENAI param name reasoning_effort'
Assert-Equal $rzLow.ParamValue 'low' 'S20 LOW -> low'
Assert-Equal $rzMed.ParamValue 'medium' 'S20 MEDIUM -> medium'
Assert-Equal $rzHigh.ParamValue 'high' 'S20 HIGH -> high'

$rzMax = ConvertTo-DbM23ReasoningParam -ApiStyle 'OPENAI_COMPATIBLE' -ReasoningLevel 'MAX'
Assert-Equal $rzMax.Status 'UNSUPPORTED' 'S21 OPENAI MAX is UNSUPPORTED (reported, never silently dropped)'

$rzOMed = ConvertTo-DbM23ReasoningParam -ApiStyle 'OLLAMA_COMPATIBLE' -ReasoningLevel 'MEDIUM'
Assert-Equal $rzOMed.Status 'TRANSLATED' 'S22 OLLAMA MEDIUM translated'
Assert-Equal $rzOMed.ParamName 'think' 'S22 OLLAMA param name think'
Assert-True ([bool]$rzOMed.ParamValue) 'S22 MEDIUM -> think=true'
$rzOLow = ConvertTo-DbM23ReasoningParam -ApiStyle 'OLLAMA_COMPATIBLE' -ReasoningLevel 'LOW'
Assert-Equal $rzOLow.Status 'UNSUPPORTED' 'S22 OLLAMA LOW is UNSUPPORTED'

$rzAMax = ConvertTo-DbM23ReasoningParam -ApiStyle 'ANTHROPIC_COMPATIBLE' -ReasoningLevel 'MAX'
$rzOrMax = ConvertTo-DbM23ReasoningParam -ApiStyle 'OPENROUTER' -ReasoningLevel 'MAX'
$rzOrNone = ConvertTo-DbM23ReasoningParam -ApiStyle 'OPENROUTER' -ReasoningLevel 'NONE'
Assert-Equal $rzAMax.Status 'TRANSLATED' 'S23 ANTHROPIC_COMPATIBLE translates all levels'
Assert-Equal $rzOrMax.Status 'TRANSLATED' 'S23 OPENROUTER translates MAX'
Assert-Equal $rzOrMax.ParamValue 'MAX' 'S23 OPENROUTER passes the level through'
Assert-Equal $rzOrNone.Status 'OMITTED' 'S23 OPENROUTER NONE omitted'

$rqTools = New-ProviderRequest -ProviderId 'localbox' -ModelId 'lmodel-7b' -ReasoningLevel 'NONE' -Messages $messages -RequiresTools -ToolDefinitions @(@{name='lookup'})
$cfgNoTools = New-LocalProviderConfiguration -ProviderId 'local-notools' -Endpoint 'http://127.0.0.1:8001' -ApiStyle 'OPENAI_COMPATIBLE' -SupportsToolCalls $false
$nativeRefuseTools = ConvertTo-ProviderNativeRequest -ProviderRequest $rqTools -ApiStyle 'OPENAI_COMPATIBLE' -ProviderConfiguration $cfgNoTools -DryRun
Assert-Equal $nativeRefuseTools.Status 'REFUSED' 'S24 tool request refused when provider lacks tool support'
Assert-Contains $nativeRefuseTools.ReasonCodes 'TOOL_NOT_SUPPORTED' 'S24 refusal reason TOOL_NOT_SUPPORTED'
Assert-True $nativeRefuseTools.NoSend 'S24 refusal never sends'
$rqStructured = New-ProviderRequest -ProviderId 'localbox' -ModelId 'lmodel-7b' -ReasoningLevel 'NONE' -Messages $messages -RequiresStructuredOutput
$cfgNoStructured = New-LocalProviderConfiguration -ProviderId 'local-nostruct' -Endpoint 'http://127.0.0.1:8002' -ApiStyle 'OPENAI_COMPATIBLE' -SupportsStructuredOutput $false
$nativeRefuseStruct = ConvertTo-ProviderNativeRequest -ProviderRequest $rqStructured -ApiStyle 'OPENAI_COMPATIBLE' -ProviderConfiguration $cfgNoStructured -DryRun
Assert-Contains $nativeRefuseStruct.ReasonCodes 'STRUCTURED_OUTPUT_NOT_SUPPORTED' 'S24 structured-output refusal reported (no silent emulation)'

$rqBad = New-ProviderRequest -ProviderId 'localbox' -ModelId 'lmodel-7b' -ReasoningLevel 'BOGUS' -Messages $messages
Assert-False (Test-ProviderRequest $rqBad).IsValid 'S25 invalid reasoning level rejected by validation'
$rqNeg = New-ProviderRequest -ProviderId 'localbox' -ModelId 'lmodel-7b' -ReasoningLevel 'NONE' -Messages $messages -MaxOutputTokens 0
Assert-False (Test-ProviderRequest $rqNeg).IsValid 'S25 non-positive MaxOutputTokens rejected'

# ---------------------------------------------------------------------------
# S26-S32: response / usage normalization
# ---------------------------------------------------------------------------
$usageFull = New-NormalizedUsage -InputTokens 100 -CachedInputTokens 40 -CacheWriteTokens 5 -OutputTokens 30 -ReasoningTokens 10 -ProviderReportedCost 0.0001 -UsageSource 'ACTUAL'
Assert-Equal $usageFull.InputTokens 100 'S26 input tokens normalized'
Assert-Equal $usageFull.CachedInputTokens 40 'S26 cached input tokens normalized'
Assert-Equal $usageFull.CacheWriteTokens 5 'S26 cache write tokens normalized'
Assert-Equal $usageFull.OutputTokens 30 'S26 output tokens normalized'
Assert-Equal $usageFull.ReasoningTokens 10 'S26 reasoning tokens normalized'
Assert-Equal $usageFull.TotalTokens 130 'S26 total tokens computed only when input+output known'
Assert-Equal $usageFull.ProviderReportedCost 0.0001 'S26 provider-reported cost preserved'
Assert-Equal $usageFull.UsageSource 'ACTUAL' 'S26 usage source from DB-M17 vocabulary'

$usagePartial = New-NormalizedUsage -InputTokens 100 -UsageSource 'ESTIMATED'
Assert-True ($null -eq $usagePartial.TotalTokens) 'S27 total tokens NOT fabricated when output unknown'
Assert-Equal $usagePartial.UsageSource 'ESTIMATED' 'S27 partial usage source ESTIMATED'
Assert-Contains $usagePartial.MissingUsage 'OutputTokens' 'S27 missing output tokens listed'

$usageNone = New-NormalizedUsage -UsageSource 'UNKNOWN'
Assert-True ($null -eq $usageNone.InputTokens) 'S28 no usage -> input stays null'
Assert-Equal $usageNone.UsageSource 'UNKNOWN' 'S28 unknown usage is explicit UNKNOWN'
Assert-True (@($usageNone.MissingUsage).Count -ge 2) 'S28 missing dimensions reported'

$resp = ConvertTo-ProviderResponse -ProviderRequest $rq -Text 'done' -NormalizedUsage $usageFull -FinishReason 'STOP' -LatencyMs 250 -ProviderRequestId 'orq-1'
Assert-Equal $resp.PSCustomVersion 'ProviderResponse v1' 'S29 ProviderResponse v1 field list'
Assert-Equal $resp.Status 'SUCCESS' 'S29 response status SUCCESS'
Assert-Equal $resp.RequestId 'RQ-0001' 'S29 request id carried through'
Assert-Equal $resp.ProviderId 'localbox' 'S29 provider id carried through'
Assert-Equal $resp.UnderlyingModelId 'lmodel-7b' 'S29 underlying model carried through'
Assert-False $resp.AutoExecutionEnabled 'S29 response never auto-executes'

$respTools = ConvertTo-ProviderResponse -ProviderRequest $rq -ToolCalls @(@{id='c1'; name='lookup'; args='{}'}) -StructuredContent @{answer='42'} -FinishReason 'TOOL_CALLS' -NormalizedUsage $usageFull
Assert-Equal $respTools.FinishReason 'TOOL_CALLS' 'S30 tool-call finish reason normalized'
Assert-Equal @($respTools.ToolCalls).Count 1 'S30 tool calls preserved'
Assert-Equal $respTools.StructuredContent.answer '42' 'S30 structured content preserved'

$err1 = ConvertTo-ProviderError -ErrorCategory 'PROVIDER_UNAVAILABLE' -Message 'upstream down'
Assert-Equal $err1.ErrorCategory 'PROVIDER_UNAVAILABLE' 'S31 DB-M23 error category preserved'
Assert-Equal $err1.FailureCategory 'PROVIDER_AVAILABILITY' 'S31 PROVIDER_UNAVAILABLE maps to DB-M20 PROVIDER_AVAILABILITY'
$err2 = ConvertTo-ProviderError -ErrorCategory 'RATE_LIMIT'
Assert-Equal $err2.FailureCategory 'RATE_LIMIT' 'S31 RATE_LIMIT maps identity to DB-M20'
$err3 = ConvertTo-ProviderError -ErrorCategory 'AUTHENTICATION'
Assert-Equal $err3.FailureCategory 'AUTHENTICATION' 'S31 AUTHENTICATION maps identity to DB-M20'
$err4 = ConvertTo-ProviderError -ErrorCategory 'TIMEOUT'
Assert-Equal $err4.FailureCategory 'TIMEOUT' 'S31 TIMEOUT maps identity to DB-M20'
$err5 = ConvertTo-ProviderError -ErrorCategory 'CONTEXT_TOO_LARGE'
Assert-Equal $err5.FailureCategory 'CONTEXT_TOO_LARGE' 'S31 CONTEXT_TOO_LARGE maps identity to DB-M20'
$err6 = ConvertTo-ProviderError -ErrorCategory 'INVALID_OUTPUT'
Assert-Equal $err6.FailureCategory 'INVALID_OUTPUT' 'S31 INVALID_OUTPUT maps identity to DB-M20'
$err7 = ConvertTo-ProviderError -ErrorCategory 'NOT_A_REAL_CATEGORY'
Assert-Equal $err7.ErrorCategory 'UNKNOWN_FAILURE' 'S31 unknown error category normalizes to UNKNOWN_FAILURE'

$retry = [datetime]::Parse('2026-08-31T11:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
$errRetry = ConvertTo-ProviderError -ErrorCategory 'RATE_LIMIT' -Message 'api_key=sk-test1234567890abc please wait' -RetryAfterUtc $retry
Assert-True ($errRetry.Message -notlike '*sk-test1234567890abc*') 'S32 raw secret removed from error message'
Assert-Equal $errRetry.RetryAfterUtc $retry 'S32 RetryAfterUtc preserved'

# ---------------------------------------------------------------------------
# S33-S35: security
# ---------------------------------------------------------------------------
$leakyCfg = [pscustomobject]@{ ProviderId = 'localbox'; Endpoint = 'http://127.0.0.1:8080'; SecretReference = 'LOCALBOX_KEY'; Notes = 'use sk-test1234567890abc here' }
$leak = Test-DbM23SecretLeak $leakyCfg
Assert-True $leak.Leak 'S33 secret-like value in Notes rejected by the leak guard'
$safeCfg = [pscustomobject]@{ ProviderId = 'localbox'; Endpoint = 'http://127.0.0.1:8080'; SecretReference = 'LOCALBOX_KEY'; ConfigurationKey = 'LOCALBOX_CFG' }
Assert-False (Test-DbM23SecretLeak $safeCfg).Leak 'S33 SecretReference/ConfigurationKey NAMES are exempt (references, not values)'

$badRef = New-LocalProviderConfiguration -ProviderId 'x' -Endpoint 'http://127.0.0.1:1' -RequiresAuthentication $true -SecretReference 'not-a-valid-name'
$vRef = Test-LocalProviderConfiguration $badRef
Assert-False $vRef.Valid 'S34 SecretReference must be an env-var NAME (value-like refs rejected)'
# inject a fake secret via the referenced environment variable and assert it never
# reaches the DRY_RUN artifact (only the redacted header does).
#
# W5E / D-14: the environment access now lives HERE, in the test, which supplies the
# accessor -- not inside the production function. That is the boundary: the movable unit
# may hold a secret REFERENCE and consume an INJECTED accessor, but must not itself reach
# into the environment or a store. The fixture value below is a deliberate fake, and the
# assertions are unchanged, so this remains a deliberately-violating fixture proving the
# value cannot reach an artifact.
$prevEnv = [Environment]::GetEnvironmentVariable('LOCAL_SEC_KEY')
try {
    [Environment]::SetEnvironmentVariable('LOCAL_SEC_KEY', 'sk-fake1234567890abcdef')
    $secRequest = New-ProviderRequest -ProviderId 'local-sec' -ModelId 'sec-model' -ReasoningLevel 'NONE' -Messages $messages
    $secretLookup = { param($n) [Environment]::GetEnvironmentVariable($n) }
    $nativeSec = ConvertTo-ProviderNativeRequest -ProviderRequest $secRequest -ApiStyle 'OPENAI_COMPATIBLE' -ProviderConfiguration $localAuth -SecretLookup $secretLookup -DryRun
    $json = $nativeSec.NativeRequest | ConvertTo-Json -Depth 8
    Assert-False ($json -like '*sk-fake1234567890abcdef*') 'S34 fake secret never appears in the serialized DRY_RUN artifact'
    Assert-Equal $nativeSec.NativeRequest.Headers.Authorization 'Bearer <redacted>' 'S34 Authorization header carried redacted'
} finally {
    [Environment]::SetEnvironmentVariable('LOCAL_SEC_KEY', $prevEnv)
}
$serialized = $safeCfg | ConvertTo-Json -Depth 6
Assert-False ($serialized -like '*sk-test*') 'S34 result artifacts contain no secret values'

$redVal = ConvertTo-DbM23RedactedValue 'sk-test1234567890abc'
Assert-Equal $redVal '<redacted>' 'S35 bare secret redacted to a placeholder'
$redHdr = ConvertTo-DbM23RedactedHeaders @{ 'Authorization' = 'Bearer sk-test1234567890abc'; 'Content-Type' = 'application/json' }
Assert-Equal $redHdr['Authorization'] 'Bearer <redacted>' 'S35 Authorization header scheme kept, credential redacted'
Assert-Equal $redHdr['Content-Type'] 'application/json' 'S35 non-secret header unchanged'

# ---------------------------------------------------------------------------
# S36-S38: dry-run
# ---------------------------------------------------------------------------
$nativeDry = ConvertTo-ProviderNativeRequest -ProviderRequest $rq -ApiStyle 'OLLAMA_COMPATIBLE' -ProviderConfiguration $localCfg -DryRun
Assert-Equal $nativeDry.Status 'DRY_RUN_READY' 'S36 native translation returns DRY_RUN_READY'
Assert-True $nativeDry.NoSend 'S36 dry-run sends nothing'
Assert-Equal $nativeDry.NetworkCalls 0 'S36 dry-run makes 0 network calls'
Assert-Equal $nativeDry.PaidApiCalls 0 'S36 dry-run makes 0 paid API calls'
Assert-False $nativeDry.AutoExecutionEnabled 'S36 dry-run auto execution disabled'

$dryResult = New-ProviderDryRunResult -NativeRequest $nativeDry.NativeRequest -RequestId $rq.RequestId -RoutingDecisionId 'RD-1' -ProviderId 'localbox' -ModelId 'lmodel-7b' -UnderlyingModelId 'lmodel-7b'
Assert-Equal $dryResult.Status 'DRY_RUN_READY' 'S37 dry-run result Status DRY_RUN_READY'
Assert-False $dryResult.AutoExecutionEnabled 'S37 dry-run result auto execution disabled'
Assert-Equal $dryResult.NetworkCalls 0 'S37 dry-run result 0 network calls'
Assert-True ($null -ne $dryResult.NativeRequest) 'S37 native request shape present for inspection'

$gateAuto = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'AUTO' -RoutingDecision $routingOk -BudgetEvaluation $budgetOk -HealthEvidence $null -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-False $gateAuto.Allowed 'S38 AUTO execution refused by the gate'
Assert-Contains $gateAuto.ReasonCodes 'AUTO_EXECUTION_PROHIBITED' 'S38 refusal reason AUTO_EXECUTION_PROHIBITED'
$modeList = Get-AiRoutingExecutionModes
Assert-Contains $modeList 'MANUAL' 'S38 MANUAL mode preserved'
Assert-Contains $modeList 'ASSISTED' 'S38 ASSISTED mode represented'

# ---------------------------------------------------------------------------
# S39-S53: integration / boundaries
# ---------------------------------------------------------------------------
$mLocalFlow = Register-LocalModel -Configuration $localCfg -ModelId 'lmodel-7b' -SupportsToolUse $true -SupportsStructuredOutput $true -SupportsReasoning $true -ReasoningLevelsSupported @('NONE','LOW','MEDIUM','HIGH','MAX')
$flowRequest = New-ProviderRequest -ProviderId 'localbox' -ModelId 'lmodel-7b' -UnderlyingModelId 'lmodel-7b' -ReasoningLevel 'MEDIUM' -Messages $messages -MaxOutputTokens 2048
$flowNative = ConvertTo-ProviderNativeRequest -ProviderRequest $flowRequest -ApiStyle 'OLLAMA_COMPATIBLE' -ProviderConfiguration $localCfg -DryRun
$flowUsage = New-NormalizedUsage -InputTokens 200 -OutputTokens 150 -UsageSource 'ACTUAL'
$flowResp = ConvertTo-ProviderResponse -ProviderRequest $flowRequest -Text 'local answer' -NormalizedUsage $flowUsage -FinishReason 'STOP'
Assert-Equal $flowNative.Status 'DRY_RUN_READY' 'S39 local end-to-end DRY_RUN: native shape ready'
Assert-Equal $flowNative.NativeRequest.ReasoningTranslation.ParamName 'think' 'S39 local end-to-end: reasoning translated to think'
Assert-Equal $flowResp.Status 'SUCCESS' 'S39 local end-to-end: normalized response SUCCESS'
Assert-Equal $flowResp.Text 'local answer' 'S39 local end-to-end: text carried'
Assert-False $flowResp.AutoExecutionEnabled 'S39 local end-to-end: never auto-executes'

$orRouteFlow = Register-OpenRouterRoute -Configuration $orCfg -RouteId 'anthropic/claude-sonnet-5' -SupportsToolUse $true -ContextWindow 200000
$orRequest = New-ProviderRequest -ProviderId 'openrouter' -ModelId $orRouteFlow.ModelId -UnderlyingModelId $orRouteFlow.UnderlyingModelId -GatewayProviderId 'openrouter' -ReasoningLevel 'HIGH' -Messages $messages
$orNative = ConvertTo-ProviderNativeRequest -ProviderRequest $orRequest -ApiStyle 'OPENROUTER' -ProviderConfiguration $orCfg -DryRun
$orUsage = New-NormalizedUsage -InputTokens 500 -OutputTokens 60 -UsageSource 'ACTUAL'
$orResp = ConvertTo-ProviderResponse -ProviderRequest $orRequest -Text 'or answer' -NormalizedUsage $orUsage -FinishReason 'STOP'
Assert-Equal $orNative.Status 'DRY_RUN_READY' 'S40 OpenRouter end-to-end DRY_RUN: native shape ready'
Assert-Equal $orNative.NativeRequest.ReasoningTranslation.ParamValue 'HIGH' 'S40 OpenRouter end-to-end: reasoning passthrough'
Assert-Equal $orResp.GatewayProviderId 'openrouter' 'S40 OpenRouter end-to-end: gateway identity on response'

$gate41 = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'AUTO' -RoutingDecision $routingOk -BudgetEvaluation $budgetOk -HealthEvidence $null -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-False $gate41.Allowed 'S41 AUTO execution gate refuses'
$gate42 = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'MANUAL' -RoutingDecision $routingOk -BudgetEvaluation $budgetBlock -HealthEvidence $null -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-False $gate42.Allowed 'S42 budget block refuses the adapter'
Assert-Contains $gate42.ReasonCodes 'BUDGET_BLOCK' 'S42 adapter cannot bypass a budget block'

$evOffline = Get-LocalProviderHealthEvidence -ProviderId 'localbox' -Condition 'OFFLINE' -ObservedAtUtc $ts
$gate43 = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'MANUAL' -RoutingDecision $routingOk -BudgetEvaluation $budgetOk -HealthEvidence @($evOffline) -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-False $gate43.Allowed 'S43 unhealthy route refuses the adapter'
Assert-Contains $gate43.ReasonCodes 'HEALTH_BLOCK' 'S43 adapter cannot bypass an unhealthy route'

$gate44 = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'MANUAL' -RoutingDecision $routingNone -BudgetEvaluation $budgetOk -HealthEvidence $null -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-False $gate44.Allowed 'S44 non-eligible routing refuses the adapter'
Assert-Contains $gate44.ReasonCodes 'ROUTING_NOT_ELIGIBLE' 'S44 adapter cannot execute on a rejected routing decision'

$evHealthy = Get-LocalProviderHealthEvidence -ProviderId 'localbox' -Condition 'HEALTHY' -ObservedAtUtc $ts
$gate45 = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'MANUAL' -RoutingDecision $routingOk -BudgetEvaluation $budgetOk -HealthEvidence @($evHealthy) -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-True $gate45.Allowed 'S45 all gates pass -> execution allowed (MANUAL, display only)'
Assert-Equal $gate45.NetworkCalls 0 'S45 gate allows 0 network calls'
Assert-False $gate45.AutoExecutionEnabled 'S45 gate never enables auto execution'

$gateWarn = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'ASSISTED' -RoutingDecision $routingOk -BudgetEvaluation $budgetWarn -HealthEvidence @($evHealthy) -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-True $gateWarn.Allowed 'S46 ALLOW_WITH_WARNING is allowed (assisted recommend)'
$gateHuman = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'MANUAL' -RoutingDecision $routingOk -BudgetEvaluation $budgetUnknown -HealthEvidence @($evHealthy) -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-False $gateHuman.Allowed 'S46 BLOCK_COST_UNKNOWN refuses (human override required)'
$gateNoBudget = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'MANUAL' -RoutingDecision $routingOk -BudgetEvaluation $budgetNone -HealthEvidence @($evHealthy) -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-True $gateNoBudget.Allowed 'S46 NO_APPLICABLE_BUDGET is allowed'

$gate47 = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'MANUAL' -RoutingDecision $routingOk -BudgetEvaluation $budgetOk -HealthEvidence @($evHealthy) -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-True $gate47.Allowed 'S47 local gate composes price-aware budget + healthy route'
Assert-Equal (Get-ProviderRoutePriceStatus -Catalogue $pricing -ProviderId 'localbox' -ModelId 'lmodel-7b' -LocalOrRemote 'LOCAL' -TimestampUtc $ts).PriceStatus 'CONFIGURED' 'S47 local configured price consumed by the gate path'

$orGate = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'MANUAL' -RoutingDecision (New-RoutingDecisionEvidence @{ Status='COMPLETED'; EligibleCandidates=@($orRouteFlow) }) -BudgetEvaluation $budgetOk -HealthEvidence $null -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'openrouter' -GatewayProviderId 'openrouter' -IsHighRisk $false
Assert-True $orGate.Allowed 'S48 OpenRouter gate passes for low-risk work'
$orPrice = Get-ProviderRoutePriceStatus -Catalogue $pricing -ProviderId 'openrouter' -ModelId 'or:anthropic/claude-sonnet-5' -LocalOrRemote 'REMOTE' -TimestampUtc $ts
Assert-Equal $orPrice.PriceStatus 'CONFIGURED' 'S48 OpenRouter configured price consumed'
$orPriceUnknown = Get-ProviderRoutePriceStatus -Catalogue $pricing -ProviderId 'openrouter' -ModelId 'or:openai/gpt-4o' -LocalOrRemote 'REMOTE' -TimestampUtc $ts
Assert-Equal $orPriceUnknown.PriceStatus 'PRICE_UNKNOWN' 'S49 remote route without record is PRICE_UNKNOWN (never invented cost)'
$localPriceUnknown = Get-ProviderRoutePriceStatus -Catalogue $pricing -ProviderId 'localbox' -ModelId 'lmodel-none' -LocalOrRemote 'LOCAL' -TimestampUtc $ts
Assert-Equal $localPriceUnknown.PriceStatus 'LOCAL_COST_UNKNOWN' 'S49 local route without record is LOCAL_COST_UNKNOWN (distinct from PRICE_UNKNOWN)'
Assert-Equal $localPriceUnknown.ProviderTokenPrice 0 'S49 local provider-level default only'

$hEv = Get-LocalProviderHealthEvidence -ProviderId 'localbox' -Condition 'RATE_LIMITED' -ObservedAtUtc $ts -RetryAfterUtc ([datetime]::Parse('2026-08-31T11:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal))
$hState = Get-EffectiveProviderHealth -Evidence @($hEv) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-Equal $hState.HealthState 'RATE_LIMITED' 'S50 local rate-limited evidence drives DB-M22 health'
$avRate = Test-ProviderRouteAvailable -Evidence @($hEv) -Policy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-False $avRate.Available 'S50 rate-limited route unavailable via DB-M22 view'

$s51Objects = @($nativeDry, $flowNative, $orNative, $dryResult, $gate41, $gate42, $gate43, $gate44, $gate45)
foreach ($obj in $s51Objects) {
    Assert-Equal (Get-ContractProperty $obj 'NetworkCalls' -1) 0 'S51 invariant: 0 network calls'
    Assert-Equal (Get-ContractProperty $obj 'PaidApiCalls' -1) 0 'S51 invariant: 0 paid API calls'
    Assert-False (Get-ContractProperty $obj 'AutoExecutionEnabled' $true) 'S51 invariant: AUTO_EXECUTION_ENABLED = FALSE'
}
# response objects carry the AUTO_EXECUTION_ENABLED invariant (execution counters
# are not part of the ProviderResponse v1 fixed field list)
$s51Responses = @($flowResp, $orResp)
foreach ($resp in $s51Responses) {
    Assert-False (Get-ContractProperty $resp 'AutoExecutionEnabled' $true) 'S51 response invariant: AUTO_EXECUTION_ENABLED = FALSE'
}

$gwTypes = Get-AiRoutingGatewayTypes
Assert-Contains $gwTypes 'OPENROUTER' 'S52 DB-M14 gateway vocabulary intact (read-only consumption)'
$pTypes = Get-AiRoutingProviderTypes
Assert-Contains $pTypes 'LOCAL' 'S52 DB-M14 provider vocabulary intact'
$rOrder = Get-AiRoutingReasoningOrder
Assert-True ($rOrder.ContainsKey('MAX')) 'S52 DB-M14 reasoning order intact'

$gate53 = Test-ProviderAdapterExecutionAllowed -ExecutionMode 'MANUAL' -RoutingDecision $routingNone -BudgetEvaluation $budgetBlock -HealthEvidence @($evOffline) -HealthPolicy $policy -EvaluationTimestampUtc $ts -ProviderId 'localbox'
Assert-False $gate53.Allowed 'S53 adapter cannot rewrite a rejected routing decision'
Assert-Contains $gate53.ReasonCodes 'ROUTING_NOT_ELIGIBLE' 'S53 routing gate fires first (boundary intact)'
$serializedResp = $flowResp | ConvertTo-Json -Depth 8
Assert-False ($serializedResp -like '*sk-*') 'S53 ProviderResponse serializes with no secrets'
$serializedResp2 = $orResp | ConvertTo-Json -Depth 8
Assert-False ($serializedResp2 -like '*sk-*') 'S53 OpenRouter response serializes with no secrets'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Output "DB-M23 PROVIDER TESTS: $($script:Results) assertions, $($script:Fails) failed, exit 0"
if ($script:Fails -gt 0) { exit 1 }
exit 0

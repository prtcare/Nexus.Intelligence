# =============================================================================
# Generate-RoutingRecommendation.ps1 (DB-M19-owned fixture generator)
#
# Demonstrates the DB-M19 router end-to-end against a REPRESENTATIVE governed
# task (a self-contained fixture -- NOT state/current-task.json, which belongs
# to another lane and is never touched). Produces:
#   _fixtures/ROUTING_RECOMMENDATION.md   (the recommendation markdown)
#   _fixtures/routing-result.json          (the machine-readable result)
# and prints a short summary line for the milestone result record.
#
# Recommendation only: nothing is executed, invoked, or auto-advanced. The
# live tasks/ handoff files (CHATGPT_HANDOFF.md / DEEPSEEK_PROMPT.md /
# CLAUDE_REVIEW_PROMPT.md) are never written.
# =============================================================================

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
. (Join-Path $PSScriptRoot "..\Router.ps1")
Import-AiPerformanceConfiguration -Root $Root | Out-Null

$FixtureDir = $PSScriptRoot

# --- representative governed task -------------------------------------------------
$req = New-AiCapabilityRequirement -TaskId 'DB-M19-FIXTURE' -TaskType 'IMPLEMENTATION' `
    -Complexity 'MEDIUM' -Risk 'LOW' -RequiresCoding $true -RequiresReasoning $true `
    -MinimumReasoningLevel 'MEDIUM' -RequiresStructuredOutput $true `
    -RequiredContextTokens 32000 -ExpectedOutputTokens 2048 `
    -RequiredReliability 'HIGH' -ExecutionMode 'ASSISTED'

$request = New-RoutingRequest -TaskId 'DB-M19-FIXTURE' -Requirement $req `
    -ExecutionMode 'ASSISTED' -RequestTimestampUtc '2026-08-31T09:00:00Z' `
    -TargetCurrency 'INR'

# --- representative catalogue (DB-M15 pricing + DB-M16 FX) ------------------------
$providers = @{}
$providers['prov-a'] = New-AiProvider -ProviderId 'prov-a' -DisplayName 'Provider A' -Enabled $true -Configured $true -ProviderType 'DIRECT'
$providers['gateway-1'] = New-AiProvider -ProviderId 'gateway-1' -DisplayName 'Gateway 1' -Enabled $true -Configured $true -ProviderType 'GATEWAY'

$models = @{}
$models['model-cheap'] = New-AiModel -ModelId 'model-cheap' -ProviderId 'prov-a' -UnderlyingModelId 'model-cheap' `
    -DisplayName 'Model Cheap' -Enabled $true -LocalOrRemote 'REMOTE' -SupportsCoding $true -SupportsReasoning $true `
    -SupportsVision $false -SupportsToolUse $true -SupportsStructuredOutput $true `
    -ContextWindow 64000 -MaxOutputTokens 8192 -ReasoningLevelsSupported @('LOW','MEDIUM','HIGH') `
    -RelativeSpeed 'FAST' -ReliabilityClass 'HIGH'
$models['model-expensive'] = New-AiModel -ModelId 'model-expensive' -ProviderId 'prov-a' -UnderlyingModelId 'model-expensive' `
    -DisplayName 'Model Expensive' -Enabled $true -LocalOrRemote 'REMOTE' -SupportsCoding $true -SupportsReasoning $true `
    -SupportsVision $false -SupportsToolUse $true -SupportsStructuredOutput $true `
    -ContextWindow 128000 -MaxOutputTokens 16384 -ReasoningLevelsSupported @('LOW','MEDIUM','HIGH') `
    -RelativeSpeed 'NORMAL' -ReliabilityClass 'CRITICAL_GRADE'
$models['model-via-gw'] = New-AiModel -ModelId 'model-via-gw' -ProviderId 'gateway-1' -UnderlyingModelId 'model-expensive' `
    -GatewayProviderId 'gateway-1' -DisplayName 'Model Expensive (Gateway)' -Enabled $true -LocalOrRemote 'REMOTE' `
    -SupportsCoding $true -SupportsReasoning $true -SupportsVision $false -SupportsToolUse $true -SupportsStructuredOutput $true `
    -ContextWindow 128000 -MaxOutputTokens 16384 -ReasoningLevelsSupported @('LOW','MEDIUM','HIGH') `
    -RelativeSpeed 'NORMAL' -ReliabilityClass 'CRITICAL_GRADE'

$pricing = @{}
foreach ($p in @(
    (New-AiPricingRecord -PricingRecordId 'pr-cheap' -ProviderId 'prov-a' -ModelId 'model-cheap' -Currency 'USD' `
        -EffectiveFromUtc '2026-06-01T00:00:00Z' -InputPricePerMillion 0.5 -CachedInputPricePerMillion 0.05 -OutputPricePerMillion 1.5 -Source 'db-m19-fixture'),
    (New-AiPricingRecord -PricingRecordId 'pr-exp' -ProviderId 'prov-a' -ModelId 'model-expensive' -Currency 'USD' `
        -EffectiveFromUtc '2026-06-01T00:00:00Z' -InputPricePerMillion 2.0 -CachedInputPricePerMillion 0.2 -OutputPricePerMillion 6.0 -Source 'db-m19-fixture'),
    (New-AiPricingRecord -PricingRecordId 'pr-gw' -ProviderId 'gateway-1' -ModelId 'model-via-gw' -Currency 'USD' `
        -EffectiveFromUtc '2026-06-01T00:00:00Z' -InputPricePerMillion 0.7 -CachedInputPricePerMillion 0.07 -OutputPricePerMillion 2.0 -Source 'db-m19-fixture')
)) { $pricing[$p.PricingRecordId] = $p }

$fx = @{}
$rate = New-AiExchangeRateRecord -ExchangeRateId 'fx-usd-inr' -BaseCurrency 'USD' -QuoteCurrency 'INR' -Rate 83.5 -EffectiveAtUtc '2026-06-01T00:00:00Z'
$fx[$rate.ExchangeRateId] = $rate

$configuration = @{
    Routing = $null; Providers = $providers; Models = $models; Pricing = $pricing; ExchangeRates = $fx
    CostConfig = [pscustomobject]@{ schemaVersion = 1; ReasoningTokenBilling = 'INCLUDED_IN_OUTPUT' }
}

$health = @{ 'prov-a' = 'AVAILABLE'; 'gateway-1' = 'AVAILABLE' }

# --- route (recommendation only) ---------------------------------------------------
$rec = Get-AiRoutingRecommendation -Request $request -Configuration $configuration -ProviderHealth $health

$mdPath = Join-Path $FixtureDir 'ROUTING_RECOMMENDATION.md'
$jsonPath = Join-Path $FixtureDir 'routing-result.json'
Export-AiRoutingRecommendation -Recommendation $rec -OutputPath $mdPath -Request $request

$result = [pscustomobject]@{
    Fixture = 'DB-M19 representative task'
    Status = $rec.Status
    ExecutionMode = $rec.ExecutionMode
    Policy = $rec.Policy.PolicyId
    Winner = if ($rec.Winner) { @{ ProviderId = $rec.Winner.ProviderId; ModelId = $rec.Winner.ModelId; ReasoningLevel = $rec.Winner.SelectedReasoningLevel; EstimatedCost = $rec.Winner.EstimatedCost; CostCurrency = $rec.Winner.CostCurrency; PolicyScore = $rec.Winner.PolicyScore } } else { $null }
    EligibleCount = @($rec.EligibleCandidates).Count
    RejectedCount = @($rec.RejectedCandidates).Count
    RecommendationReason = $rec.RecommendationReason
}
$result | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -Path $jsonPath

Write-Output ("ROUTING fixture status: " + $rec.Status)
Write-Output ("ROUTING fixture winner: " + $(if ($rec.Winner) { "$($rec.Winner.ProviderId)/$($rec.Winner.ModelId) @" + $rec.Winner.EstimatedCost + " " + $rec.Winner.CostCurrency } else { 'none' }))
Write-Output ("ROUTING fixture exported: " + $mdPath)
Write-Output ("ROUTING fixture result json: " + $jsonPath)

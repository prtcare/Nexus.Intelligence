<#
.SYNOPSIS
Self-test for the AI-owned provider launch environment.

Asserts the unit describes routing/model selection by NAME and never carries a
credential VALUE across the boundary — the property Forge depends on when it
applies the environment to a coding client.

Prints "AI PROVIDER LAUNCH TEST SUMMARY: <passed> passed, <failed> failed".
Exit code 0 = all passed; 1 = any failure.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ProviderLaunchEnvironment.ps1')

$script:Count = 0
$script:Fails = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Count++
    if (-not $Condition) { $script:Fails.Add($Message) }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:Count++
    if ("$Actual" -ne "$Expected") { $script:Fails.Add("$Message (actual='$Actual' expected='$Expected')") }
}
function Assert-Null {
    param($Actual, [string]$Message)
    $script:Count++
    if ($null -ne $Actual) { $script:Fails.Add("$Message (expected null, got '$Actual')") }
}

# L01 the registered provider resolves
$env1 = Get-AiProviderLaunchEnvironment -ProviderId 'deepseek'
Assert-True ($null -ne $env1) 'L01: deepseek launch environment resolves'
Assert-Equal $env1.ProviderId 'deepseek' 'L02: provider id normalized'
Assert-Equal $env1.GatewayBaseUrl 'https://api.deepseek.com/anthropic' 'L03: gateway endpoint owned by AI'
Assert-Equal $env1.CredentialSourceVar 'DEEPSEEK_API_KEY' 'L04: credential SOURCE variable named'
Assert-Equal @($env1.CredentialTargetVars).Count 2 'L05: two credential target variables'
Assert-True (@($env1.CredentialTargetVars) -contains 'ANTHROPIC_AUTH_TOKEN') 'L06: auth token target present'

# L07 every client role is mapped to a provider model
foreach ($role in @('SONNET', 'OPUS', 'HAIKU')) {
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$env1.ModelRoleMap[$role])) "L07: role $role mapped to a model"
}
Assert-Equal @(Get-AiProviderLaunchModelNames -ProviderId 'deepseek').Count 1 'L08: one distinct model across roles'

# L09 an unregistered provider yields nothing rather than a fabricated default
Assert-Null (Get-AiProviderLaunchEnvironment -ProviderId 'no-such-provider') 'L09: unknown provider -> null'
Assert-Equal @(Get-AiProviderLaunchModelNames -ProviderId 'no-such-provider').Count 0 'L10: unknown provider -> no models'

# L11-L13 SECRET BOUNDARY: even with the credential present in the environment,
# no part of the returned record may contain its value. A launch environment that
# leaked the secret would re-export it to every consumer of this boundary.
$probeSecret = 'w6r2-probe-value-not-a-real-credential'
$env:DEEPSEEK_API_KEY = $probeSecret
try {
    $env2 = Get-AiProviderLaunchEnvironment -ProviderId 'deepseek'
    $flat = ($env2 | ConvertTo-Json -Depth 8 -Compress)
    Assert-True (-not $flat.Contains($probeSecret)) 'L11: credential value absent from the launch environment'
    Assert-True (-not $flat.Contains('Bearer')) 'L12: no authorization header materialized'
    Assert-True ($flat.Contains('DEEPSEEK_API_KEY')) 'L13: the variable NAME is present (names are not secrets)'
} finally {
    Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue
}

$script:Passed = $script:Count - $script:Fails.Count
Write-Host "AI PROVIDER LAUNCH TEST SUMMARY: $($script:Passed) passed, $($script:Fails.Count) failed"
foreach ($f in $script:Fails) { Write-Host "  FAIL: $f" }
if ($script:Fails.Count -eq 0) { Write-Host 'AI PROVIDER LAUNCH: ALL PASS'; exit 0 }
exit 1

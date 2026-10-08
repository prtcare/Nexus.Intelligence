<#
.SYNOPSIS
AI-owned provider launch environment (gateway routing + model-role selection).

WHY THIS LIVES IN THE AI HEAD
Pointing a coding client at a provider gateway, choosing which model backs which
client role, and mapping a credential into the client's expected variable names is
provider ROUTING and MODEL SELECTION. Both are AI Head concerns. A Forge launcher
that hard-codes an endpoint and a role->model table is AI implementation sitting in
Forge, which is what this unit removes: Forge now asks for the environment and
applies it.

WHAT THIS RETURNS
Variable NAMES and non-secret values only. The credential itself is never read,
resolved, returned or logged here -- the caller copies it from its own configured
variable into the target names. That keeps the secret boundary intact: this unit
describes WHERE a credential goes, never WHAT it is.
#>

Set-StrictMode -Version Latest

# Provider launch knowledge. Provider implementation, therefore AI-owned.
$script:AiProviderLaunchRegistry = @{
    'deepseek' = @{
        DisplayName          = 'DeepSeek'
        GatewayBaseUrl       = 'https://api.deepseek.com/anthropic'
        CredentialSourceVar  = 'DEEPSEEK_API_KEY'
        CredentialTargetVars = @('ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY')
        # Client role -> provider model. Routing, not presentation.
        ModelRoleMap         = [ordered]@{
            SONNET = 'deepseek-v4-flash'
            OPUS   = 'deepseek-v4-flash'
            HAIKU  = 'deepseek-v4-flash'
        }
        ClientEnv            = [ordered]@{
            CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '1'
            CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK       = '1'
            CLAUDE_CODE_DISABLE_TERMINAL_TITLE         = '1'
        }
    }
}

function Get-AiProviderLaunchProviders {
    <# .SYNOPSIS Provider ids a launch environment is defined for. #>
    return @($script:AiProviderLaunchRegistry.Keys | Sort-Object)
}

function Get-AiProviderLaunchEnvironment {
    <#
    .SYNOPSIS
    The launch environment for one provider, or $null when the provider has none.

    Returns a record describing the gateway endpoint, the credential variable
    mapping (NAMES only) and the client role -> model map. Never returns a
    credential value.
    #>
    param([Parameter(Mandatory = $true)][string]$ProviderId)

    $id = $ProviderId.Trim().ToLowerInvariant()
    if (-not $script:AiProviderLaunchRegistry.ContainsKey($id)) { return $null }
    $spec = $script:AiProviderLaunchRegistry[$id]

    return [pscustomobject]@{
        SchemaVersion        = 1
        ProviderId           = $id
        DisplayName          = [string]$spec.DisplayName
        GatewayBaseUrl       = [string]$spec.GatewayBaseUrl
        CredentialSourceVar  = [string]$spec.CredentialSourceVar
        CredentialTargetVars = @($spec.CredentialTargetVars)
        ModelRoleMap         = $spec.ModelRoleMap
        ClientEnv            = $spec.ClientEnv
        Note                 = 'Launch environment is AI-owned routing/model selection. Only variable names travel; the credential value stays in the operator environment.'
    }
}

function Get-AiProviderLaunchModelNames {
    <# .SYNOPSIS Distinct provider model names this launch environment selects. #>
    param([Parameter(Mandatory = $true)][string]$ProviderId)
    $launchEnv = Get-AiProviderLaunchEnvironment -ProviderId $ProviderId
    if ($null -eq $launchEnv) { return @() }
    return @($launchEnv.ModelRoleMap.Values | Sort-Object -Unique)
}

<#
.SYNOPSIS
AI-owned live provider health probe (DB-M22 evidence source).

WHY THIS LIVES IN THE AI HEAD
Provider-specific behaviour — which endpoint to call, which credential env var
holds the key, which response fields mean what — is provider IMPLEMENTATION. It
belongs to the AI Head, not to a Forge development-lifecycle tool. Forge reaches
this capability through its thin AI capability client and receives a NEUTRAL
health record; it never performs a provider call and never parses a provider
payload.

WHAT THIS DELIBERATELY DOES NOT RETURN
A raw balance figure. Account balance is provider-domain data. The consumer needs
"is this provider usable", which the DB-M14 health vocabulary already expresses.
Handing balance amounts back to a non-AI consumer would re-export provider
semantics across the boundary this module exists to hold.

NETWORK IS OPT-IN
A probe performs a live provider API call. Default behaviour is NO network call:
the probe reports UNKNOWN with HEALTH_UNKNOWN. A caller must explicitly opt in via
-AllowNetworkProbe or $env:NEXUS_AI_ALLOW_PROVIDER_PROBE = '1'. This means merely
opening a Forge surface can never fire a provider request, and no audit or test
run spends a paid call or touches a live credential by accident.

CREDENTIALS
Only the credential environment-variable NAME traverses this API. The value is
read from the environment at call time, used to build one request header, and
never returned, echoed, logged, hashed into a record, or written to evidence.
#>

Set-StrictMode -Version Latest

# Provider-specific probe knowledge. This table is provider implementation and is
# why the module belongs to the AI Head.
$script:AiProviderProbeRegistry = @{
    'deepseek' = @{
        # Balance endpoint; a 200 with is_available=false means the account is
        # reachable but not usable, which is a health fact, not a balance fact.
        BalanceUri      = 'https://api.deepseek.com/user/balance'
        AvailabilityKey = 'is_available'
        DefaultCredVar  = 'DEEPSEEK_API_KEY'
    }
}

function Get-AiProviderProbeProviders {
    <# .SYNOPSIS Provider ids this probe can observe. #>
    return @($script:AiProviderProbeRegistry.Keys | Sort-Object)
}

function Get-AiProviderProbeState {
    <#
    .SYNOPSIS
    Map a probe outcome onto the DB-M14 health vocabulary. Never invents a state:
    an outcome that cannot be classified is UNKNOWN, and UNKNOWN is never treated
    as healthy by the DB-M22 policy.
    #>
    param(
        [string]$ProbeStatus,
        [string]$HttpStatusClass,
        [bool]$ProviderAvailable
    )
    if ($ProbeStatus -eq 'NO_CREDENTIAL') { return 'DISABLED' }
    if ($ProbeStatus -eq 'UNSUPPORTED_PROVIDER') { return 'UNKNOWN' }
    if ($ProbeStatus -eq 'PROBE_DISABLED') { return 'UNKNOWN' }
    if ($ProbeStatus -eq 'TRANSPORT_FAILURE') { return 'UNAVAILABLE' }
    if ($ProbeStatus -eq 'PROBED') {
        if ($HttpStatusClass -eq '429') { return 'RATE_LIMITED' }
        if ($HttpStatusClass -eq '401' -or $HttpStatusClass -eq '403') { return 'AUTH_ERROR' }
        if ($HttpStatusClass -match '^5') { return 'UNAVAILABLE' }
        if ($HttpStatusClass -match '^4') { return 'DEGRADED' }
        if ($ProviderAvailable) { return 'AVAILABLE' }
        return 'UNAVAILABLE'
    }
    return 'UNKNOWN'
}

function Get-AiProviderProbeReasonCodes {
    param([string]$ProbeStatus, [string]$HealthState)
    # Members of the DB-M22 closed vocabulary only; no invented codes.
    $codes = New-Object System.Collections.Generic.List[string]
    switch ($ProbeStatus) {
        'NO_CREDENTIAL'        { $codes.Add('CONFIGURATION_DISABLED') }
        'PROBE_DISABLED'       { $codes.Add('HEALTH_UNKNOWN') }
        'UNSUPPORTED_PROVIDER' { $codes.Add('HEALTH_UNKNOWN') }
        'TRANSPORT_FAILURE'    { $codes.Add('ROUTE_UNHEALTHY') }
        'PROBED' {
            if ($HealthState -eq 'AUTH_ERROR') { $codes.Add('AUTH_REQUIRES_HUMAN') }
            elseif ($HealthState -eq 'AVAILABLE') { $codes.Add('HEALTHY_ROUTE') }
            elseif ($HealthState -eq 'RATE_LIMITED') { $codes.Add('ROUTE_UNHEALTHY') }
            else { $codes.Add('ROUTE_UNHEALTHY') }
        }
        default { $codes.Add('HEALTH_UNKNOWN') }
    }
    return @($codes)
}

function Get-AiProviderHealthProbeResult {
    <#
    .SYNOPSIS
    Probe one provider and return a NEUTRAL provider-health record.

    Returns a record with ProbeStatus / HealthState from the DB-M14 vocabulary.
    Never returns a balance amount, never returns the credential, never throws on
    an unavailable provider — an unreachable provider is a health result, not an
    exception.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [string]$CredentialEnvVar,
        [switch]$AllowNetworkProbe,
        [int]$TimeoutSec = 10,
        [string]$NowUtc
    )
    $now = if ($NowUtc) { $NowUtc } else { (Get-Date).ToUniversalTime().ToString('o') }
    $id = $ProviderId.Trim().ToLowerInvariant()

    $status = 'UNSUPPORTED_PROVIDER'
    $httpClass = ''
    $available = $false
    $note = ''

    if ($script:AiProviderProbeRegistry.ContainsKey($id)) {
        $spec = $script:AiProviderProbeRegistry[$id]
        $credVar = if ($CredentialEnvVar) { $CredentialEnvVar } else { $spec.DefaultCredVar }

        # Credential presence is checked by NAME only. The value is never read here.
        $hasCredential = -not [string]::IsNullOrWhiteSpace(
            [Environment]::GetEnvironmentVariable($credVar, 'User')) -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($credVar, 'Process'))

        $networkAllowed = ($AllowNetworkProbe.IsPresent) -or ($env:NEXUS_AI_ALLOW_PROVIDER_PROBE -eq '1')

        if (-not $hasCredential) {
            $status = 'NO_CREDENTIAL'
            $note = "Credential environment variable '$credVar' is not set; the provider cannot be probed."
        } elseif (-not $networkAllowed) {
            $status = 'PROBE_DISABLED'
            $note = 'Live provider probing is opt-in (-AllowNetworkProbe or NEXUS_AI_ALLOW_PROVIDER_PROBE=1); no request was made.'
        } else {
            try {
                $credential = [Environment]::GetEnvironmentVariable($credVar, 'User')
                if ([string]::IsNullOrWhiteSpace($credential)) {
                    $credential = [Environment]::GetEnvironmentVariable($credVar, 'Process')
                }
                $response = Invoke-RestMethod -Method Get -Uri $spec.BalanceUri `
                    -Headers @{ Authorization = "Bearer $credential" } -TimeoutSec $TimeoutSec
                $credential = $null
                $status = 'PROBED'
                $httpClass = '200'
                $available = [bool]$response.($spec.AvailabilityKey)
                $note = 'Provider balance endpoint reached; only availability was interpreted.'
            } catch {
                $status = 'TRANSPORT_FAILURE'
                $resp = $null
                try { $resp = $_.Exception.Response } catch { $resp = $null }
                if ($null -ne $resp -and $null -ne $resp.StatusCode) {
                    try { $httpClass = [string]([int]$resp.StatusCode) } catch { $httpClass = '' }
                }
                if (-not $httpClass) {
                    $m = [regex]::Match([string]$_.Exception.Message, '\b([1-5][0-9][0-9])\b')
                    if ($m.Success) { $httpClass = $m.Groups[1].Value }
                }
                $note = 'Provider balance endpoint was not reachable from this host.'
            }
        }
    } else {
        $note = "Provider '$id' has no registered probe; health is unknown."
    }

    $state = Get-AiProviderProbeState -ProbeStatus $status -HttpStatusClass $httpClass -ProviderAvailable $available
    return [pscustomobject]@{
        SchemaVersion  = 1
        ProviderId     = $id
        ProbeStatus    = $status
        HealthState    = $state
        ObservedAtUtc  = $now
        HttpStatusClass = $httpClass
        ReasonCodes    = @(Get-AiProviderProbeReasonCodes -ProbeStatus $status -HealthState $state)
        Note           = $note
    }
}

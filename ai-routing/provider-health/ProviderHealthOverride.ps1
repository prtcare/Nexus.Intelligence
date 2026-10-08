# ProviderHealthOverride.ps1 -- DB-M22 explicit human health override.
#
# A human-provided health override is honoured ONLY when the policy permits and
# when explicit evidence (OverrideReference + OverrideReason + timestamp) is
# provided. DB-M22 NEVER infers human approval. A granted manual override never
# silently re-enables a provider that configuration marks DISABLED.
#
# Decision only. No provider/model is executed. AUTO_EXECUTION_ENABLED = FALSE.

. (Join-Path $PSScriptRoot "ProviderHealthEngine.ps1")   # health contracts + engine (READ-ONLY)

function Test-ProviderHealthOverride {
    <#
    .SYNOPSIS
    Process an EXPLICIT human health override. Grants an override only when the
    policy permits (AllowManualOverride), a reason is present (when required), and
    the target is not configuration-DISABLED (ConfigurationDisabled=$true).
    Returns @{ Granted; Outcome; Reasons; Message; OverrideReference; OverrideState }.
    #>
    param(
        [AllowNull()][pscustomobject]$Policy,
        [string]$ProviderId,
        [string]$GatewayProviderId,
        [string]$OverrideReference,
        [string]$OverrideReason,
        $OverrideTimestampUtc,
        [string]$OverrideState = 'AVAILABLE',
        [bool]$ConfigurationDisabled = $false
    )
    if ($null -eq $Policy) { $Policy = Get-DefaultProviderHealthPolicy }
    $pv = Test-ProviderHealthPolicy $Policy
    if (-not $pv.Valid) { throw ("Test-ProviderHealthOverride: invalid policy: " + ($pv.Errors -join '; ')) }
    if (-not $ProviderId) { throw "Test-ProviderHealthOverride: ProviderId is required" }

    $allowOverride = [bool](Get-ContractProperty $Policy 'AllowManualOverride' $true)
    $requireReason = [bool](Get-ContractProperty $Policy 'RequireReasonForOverride' $true)
    $ts = ConvertTo-DbM22Utc $OverrideTimestampUtc

    # 1. a configuration-DISABLED provider is never silently re-enabled
    if ($ConfigurationDisabled) {
        return @{ Granted = $false; Outcome = 'OVERRIDE_PROHIBITED'; Reasons = @('CONFIGURATION_DISABLED', 'HUMAN_OVERRIDE_PROHIBITED')
                  Message = 'a configuration-DISABLED provider cannot be re-enabled by a manual health override'; OverrideReference = $OverrideReference; OverrideState = $OverrideState }
    }

    # 2. policy must permit manual overrides
    if (-not $allowOverride) {
        return @{ Granted = $false; Outcome = 'OVERRIDE_PROHIBITED'; Reasons = @('HUMAN_OVERRIDE_PROHIBITED')
                  Message = 'policy does not allow manual health overrides'; OverrideReference = $OverrideReference; OverrideState = $OverrideState }
    }

    # 3. explicit evidence is mandatory
    if ($requireReason -and -not $OverrideReason) {
        return @{ Granted = $false; Outcome = 'OVERRIDE_REASON_REQUIRED'; Reasons = @('HUMAN_OVERRIDE_REASON_REQUIRED')
                  Message = 'policy requires an explicit override reason'; OverrideReference = $OverrideReference; OverrideState = $OverrideState }
    }
    if (-not $OverrideReference) {
        return @{ Granted = $false; Outcome = 'OVERRIDE_REASON_REQUIRED'; Reasons = @('HUMAN_OVERRIDE_REASON_REQUIRED')
                  Message = 'an explicit override reference is required'; OverrideReference = $OverrideReference; OverrideState = $OverrideState }
    }
    if ($null -eq $ts) {
        return @{ Granted = $false; Outcome = 'OVERRIDE_REASON_REQUIRED'; Reasons = @('HUMAN_OVERRIDE_REASON_REQUIRED')
                  Message = 'an explicit override timestamp is required'; OverrideReference = $OverrideReference; OverrideState = $OverrideState }
    }

    return @{ Granted = $true; Outcome = 'OVERRIDE_GRANTED'; Reasons = @('HUMAN_OVERRIDE_GRANTED')
              Message = 'explicit human health override granted'; OverrideReference = $OverrideReference; OverrideState = $OverrideState }
}

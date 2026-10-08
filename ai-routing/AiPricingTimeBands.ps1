# AiPricingTimeBands.ps1 — DB-M15 time-band determination.
#
# Time-band determination is SEPARATED from price storage. Provider-specific
# pricing rule handlers live HERE, isolated from general business logic, so the
# rest of the platform never branches on provider name (ADR-005).
#
# DeepSeek peak hours (DevBridge requirements):
#   01:00-04:00 UTC  (peak interval 1)
#   06:00-10:00 UTC  (peak interval 2)
#   all other times: OFF_PEAK
#
# Boundary convention (deterministic, documented): [start, end) —
# a timestamp exactly at a peak START (01:00:00, 06:00:00) is PEAK;
# a timestamp exactly at a peak END (04:00:00, 10:00:00) is OFF_PEAK.
#
# Use the API/request timestamp in UTC. Never use local system time implicitly
# when a request timestamp is available.
#
# Dot-source AiRoutingContracts.ps1 (DB-M14) first (vocabulary helpers).

function Resolve-AiPricingTimeBand {
    <#
    .SYNOPSIS
    Resolve the time band for a provider at a UTC timestamp.
    DeepSeek: PEAK inside [01:00,04:00) or [06:00,10:00) UTC, OFF_PEAK otherwise.
    Any other provider: DEFAULT (no time-band differentiated pricing).
    #>
    param(
        [string]$ProviderId,
        $TimestampUtc = $null
    )
    $provId = $ProviderId.Trim().ToLowerInvariant()
    $ts = if ($null -eq $TimestampUtc) { [datetime]::UtcNow } else { ConvertTo-AiUtc $TimestampUtc }

    if ($provId -eq 'deepseek') {
        $minutes = $ts.TimeOfDay.TotalMinutes
        # 01:00 = 60, 04:00 = 240 ; 06:00 = 360, 10:00 = 600
        $peak1 = ($minutes -ge 60) -and ($minutes -lt 240)
        $peak2 = ($minutes -ge 360) -and ($minutes -lt 600)
        if ($peak1 -or $peak2) { return 'PEAK' }
        return 'OFF_PEAK'
    }
    return 'DEFAULT'
}

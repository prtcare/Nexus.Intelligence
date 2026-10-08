# AiExchangeRates.ps1 — DB-M16 effective-dated exchange-rate catalogue.
#
# Currency-conversion evidence is stored as effective-dated ExchangeRateRecord v1
# rows (same [start, end) window semantics as pricing). Historic converted costs
# are reproducible: the rate record applicable at the attempt timestamp is used
# and later rate changes never rewrite it.
#
# NO live internet access. Sources are MANUAL_VERIFIED | CONFIGURED |
# FUTURE_PROVIDER_SYNC. Tests never call external FX APIs.
#
# Dot-source AiRoutingPricingFoundation.ps1 (DB-M14 + DB-M15) + AiCostContracts.ps1 first.

function Add-AiExchangeRate {
    param(
        [System.Collections.IDictionary]$Catalogue,
        [pscustomobject]$Record
    )
    $t = Test-AiExchangeRateRecord $Record
    if (-not $t.Valid) { throw "Add-AiExchangeRate: invalid record '$($Record.ExchangeRateId)': $($t.Errors -join '; ')" }
    if ($Catalogue.ContainsKey($Record.ExchangeRateId)) {
        throw "Add-AiExchangeRate: duplicate ExchangeRateId '$($Record.ExchangeRateId)'"
    }
    $Catalogue[$Record.ExchangeRateId] = $Record
    return $Catalogue[$Record.ExchangeRateId]
}

function Get-AiExchangeRate {
    param([System.Collections.IDictionary]$Catalogue, [string]$ExchangeRateId)
    if (-not $ExchangeRateId) { return $null }
    if ($Catalogue -and $Catalogue.ContainsKey($ExchangeRateId)) { return $Catalogue[$ExchangeRateId] }
    return $null
}

function Get-AiExchangeRateAt {
    <#
    .SYNOPSIS
    Resolve the exchange-rate record applicable at a UTC timestamp for a
    base/quote pair: EffectiveAtUtc <= ts < EffectiveToUtc (null end = open).
    Deterministic: returns the SINGLE applicable record, $null when none, and
    reports ambiguity via -Ambiguous. Never silently chooses between records.
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [string]$BaseCurrency,
        [string]$QuoteCurrency,
        $TimestampUtc = $null
    )
    if (-not $Catalogue) { return $null }
    $ts = if ($null -eq $TimestampUtc) { [datetime]::UtcNow } else { ConvertTo-AiUtc $TimestampUtc }
    $base = $BaseCurrency.Trim().ToUpperInvariant()
    $quote = $QuoteCurrency.Trim().ToUpperInvariant()

    $candidates = @($Catalogue.Values | Where-Object {
        $_.BaseCurrency -eq $base -and $_.QuoteCurrency -eq $quote
    })
    $effective = @($candidates | Where-Object {
        $f = ConvertTo-AiUtc $_.EffectiveAtUtc
        $t = if ($_.EffectiveToUtc) { ConvertTo-AiUtc $_.EffectiveToUtc } else { [datetime]::MaxValue }
        ($f -le $ts) -and ($t -gt $ts)
    })
    if ($effective.Count -eq 1) { return $effective[0] }
    # Ambiguity (>1 applicable) means the catalogue is invalid (overlaps are
    # rejected by Validate-AiExchangeRateCatalogue). If it ever occurs in
    # unvalidated data, fail safe: never silently pick between records.
    return $null
}

function Get-AiExchangeRateCurrent {
    <#
    .SYNOPSIS
    Current-rate convenience lookup. Same semantics as Get-AiExchangeRateAt at
    [datetime]::UtcNow (explicit UTC, never local system time).
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [string]$BaseCurrency,
        [string]$QuoteCurrency
    )
    return Get-AiExchangeRateAt -Catalogue $Catalogue -BaseCurrency $BaseCurrency -QuoteCurrency $QuoteCurrency `
        -TimestampUtc ([datetime]::UtcNow)
}

function Validate-AiExchangeRateCatalogue {
    <#
    .SYNOPSIS
    Deterministically validate an exchange-rate catalogue. Errors: duplicate id,
    schema != 1, per-record failures, rate <= 0, overlapping effective windows
    for the same base/quote pair. Warnings: non-recommended source. Info: gaps
    between windows, per-pair counts.
    Returns @{ Valid; Errors; Warnings; Overlaps; Gaps }.
    #>
    param([System.Collections.IDictionary]$Catalogue)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $overlaps = New-Object System.Collections.Generic.List[string]
    $gaps = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Catalogue) { return @{ Valid = $false; Errors = @('Catalogue is null'); Warnings = @(); Overlaps = @(); Gaps = @() } }

    foreach ($key in $Catalogue.Keys) {
        $r = $Catalogue[$key]
        if ($r.ExchangeRateId -ne $key) { $errors.Add("Catalogue key '$key' does not match record ExchangeRateId '$($r.ExchangeRateId)'") }
        $t = Test-AiExchangeRateRecord $r
        if (-not $t.Valid) { $errors.Add("Exchange rate '$key': $($t.Errors -join '; ')") }
        foreach ($w in $t.Warnings) { $warnings.Add("Exchange rate '$key': $w") }
    }

    $groups = @{}
    foreach ($key in $Catalogue.Keys) {
        $r = $Catalogue[$key]
        $gKey = "$($r.BaseCurrency)|$($r.QuoteCurrency)"
        if (-not $groups.ContainsKey($gKey)) { $groups[$gKey] = New-Object System.Collections.Generic.List[object] }
        $groups[$gKey].Add($r)
    }
    foreach ($gKey in $groups.Keys) {
        $list = $groups[$gKey].ToArray()
        if ($list.Count -lt 2) { continue }
        $sorted = @($list | Sort-Object { ConvertTo-AiUtc $_.EffectiveAtUtc })
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            for ($j = $i + 1; $j -lt $sorted.Count; $j++) {
                $a = $sorted[$i]; $b = $sorted[$j]
                if (Test-IntervalsOverlap $a.EffectiveAtUtc $a.EffectiveToUtc $b.EffectiveAtUtc $b.EffectiveToUtc) {
                    $overlaps.Add("Overlap: '$($a.ExchangeRateId)' [$($a.EffectiveAtUtc) -> $($a.EffectiveToUtc)) and '$($b.ExchangeRateId)' [$($b.EffectiveAtUtc) -> $($b.EffectiveToUtc)) for $gKey")
                }
            }
        }
        for ($k = 0; $k -lt $sorted.Count - 1; $k++) {
            $prev = $sorted[$k]; $next = $sorted[$k + 1]
            if ($prev.EffectiveToUtc) {
                $prevTo = ConvertTo-AiUtc $prev.EffectiveToUtc
                $nextFrom = ConvertTo-AiUtc $next.EffectiveAtUtc
                if ($prevTo -lt $nextFrom) {
                    $gaps.Add("Gap: '$($prev.ExchangeRateId)' ends $($prev.EffectiveToUtc), '$($next.ExchangeRateId)' starts $($next.EffectiveAtUtc) for $gKey")
                }
            }
        }
    }
    foreach ($o in $overlaps) { $errors.Add($o) }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @($warnings); Overlaps = @($overlaps); Gaps = @($gaps) }
}

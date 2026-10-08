# PricingCatalogue.ps1 — DB-M15 effective-dated pricing catalogue.
#
# Deterministic price lookup and effective-dated versioning over pricing records
# (PricingRecord v1). Rates are DATA, consumed only through this catalogue - never
# hard-coded into business logic.
#
# Versioning rules:
#   - Historic records are never mutated EXCEPT to close their effective period
#     (EffectiveToUtc) when introducing a legitimate successor (Add-AiPriceVersion).
#   - A price change = old record closed at boundary T + new record effective [T, ...).
#   - Historic lookups keep resolving to the historic record.
#
# No AI API calls, no network, no paid calls, no cost calculation (DB-M16).
#
# Dot-source AiRoutingContracts.ps1, AiPricingContracts.ps1, AiPricingTimeBands.ps1 first.

# --- catalogue operations -------------------------------------------------------------

function Add-AiPricingRecord {
    param(
        [System.Collections.IDictionary]$Catalogue,
        [pscustomobject]$Record
    )
    $t = Test-AiPricingRecord $Record
    if (-not $t.Valid) { throw "Add-AiPricingRecord: invalid pricing record '$($Record.PricingRecordId)': $($t.Errors -join '; ')" }
    if ($Catalogue.ContainsKey($Record.PricingRecordId)) {
        throw "Add-AiPricingRecord: duplicate PricingRecordId '$($Record.PricingRecordId)'"
    }
    $Catalogue[$Record.PricingRecordId] = $Record
    return $Catalogue[$Record.PricingRecordId]
}

function Get-AiPricingRecord {
    param([System.Collections.IDictionary]$Catalogue, [string]$PricingRecordId)
    if (-not $PricingRecordId) { return $null }
    if ($Catalogue -and $Catalogue.ContainsKey($PricingRecordId)) { return $Catalogue[$PricingRecordId] }
    return $null
}

function Get-AiPricingRecords {
    param([System.Collections.IDictionary]$Catalogue)
    if (-not $Catalogue) { return @() }
    return @($Catalogue.Values)
}

# --- effective-dated versioning -------------------------------------------------------

function Add-AiPriceVersion {
    <#
    .SYNOPSIS
    Introduce a new price version. Never destroys old rates.
      - Without -ClosePredecessor: rejects if it would overlap an existing
        effective record for the same provider/model/tier/time-band.
      - With -ClosePredecessor: closes the immediate predecessor(s) by setting
        their EffectiveToUtc to the new record's EffectiveFromUtc (the ONLY
        permitted mutation of a historic record), then adds the new record.
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [pscustomobject]$Record,
        [switch]$ClosePredecessor
    )
    $t = Test-AiPricingRecord $Record
    if (-not $t.Valid) { throw "Add-AiPriceVersion: invalid record '$($Record.PricingRecordId)': $($t.Errors -join '; ')" }
    if ($Catalogue.ContainsKey($Record.PricingRecordId)) {
        throw "Add-AiPriceVersion: duplicate PricingRecordId '$($Record.PricingRecordId)'"
    }
    $newFrom = ConvertTo-AiUtc $Record.EffectiveFromUtc

    $overlaps = @($Catalogue.Values | Where-Object {
        $_.ProviderId -eq $Record.ProviderId -and
        $_.ModelId -eq $Record.ModelId -and
        $_.ProcessingTier -eq $Record.ProcessingTier -and
        $_.TimeBand -eq $Record.TimeBand -and
        (Test-IntervalsOverlap $newFrom $null $_.EffectiveFromUtc $_.EffectiveToUtc)
    })

    if ($overlaps.Count -gt 0) {
        if ($ClosePredecessor) {
            foreach ($old in $overlaps) {
                $oldFrom = ConvertTo-AiUtc $old.EffectiveFromUtc
                $oldTo = if ($old.EffectiveToUtc) { ConvertTo-AiUtc $old.EffectiveToUtc } else { [datetime]::MaxValue }
                if ($oldFrom -ge $newFrom) {
                    throw "Add-AiPriceVersion: record '$($old.PricingRecordId)' starts at/after the new effective date; cannot close it as a predecessor (would rewrite history)"
                }
                # close the predecessor's effective period at the change boundary
                $old.EffectiveToUtc = $Record.EffectiveFromUtc
            }
        } else {
            throw "Add-AiPriceVersion: record '$($Record.PricingRecordId)' overlaps existing effective record(s) ($($overlaps.PricingRecordId -join ', ')); use -ClosePredecessor to close the predecessor at the change boundary"
        }
    }

    $Catalogue[$Record.PricingRecordId] = $Record
    return $Catalogue[$Record.PricingRecordId]
}

function Test-IntervalsOverlap {
    <#
    .SYNOPSIS
    [aFrom, aTo) and [bFrom, bTo) overlap iff aFrom < bTo AND aTo > bFrom,
    with null end = +infinity. Adjacent periods ([a,b) then [b,c)) do NOT overlap.
    #>
    param($aFrom, $aTo, $bFrom, $bTo)
    $af = ConvertTo-AiUtc $aFrom; $bf = ConvertTo-AiUtc $bFrom
    $at = if ($aTo) { ConvertTo-AiUtc $aTo } else { [datetime]::MaxValue }
    $bt = if ($bTo) { ConvertTo-AiUtc $bTo } else { [datetime]::MaxValue }
    return (($af -lt $bt) -and ($at -gt $bf))
}

# --- deterministic price lookup -------------------------------------------------------

function Get-AiPriceAt {
    <#
    .SYNOPSIS
    Deterministic effective-dated price lookup.
      Get-AiPriceAt -Catalogue <pricing catalogue> -ProviderId <id> -ModelId <id> `
                    -TimestampUtc <UTC datetime> [-ProcessingTier <tier>] [-TimeBand <band>]
    Time-band resolution: an explicit -TimeBand wins; otherwise the provider time-band
    resolver determines it from the UTC timestamp. Returns a PriceLookupResult v1 with
    LookupState FOUND / NOT_FOUND / AMBIGUOUS / EXPIRED. Never silently chooses between
    ambiguous records - it reports AMBIGUOUS instead.
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [string]$ProviderId,
        [string]$ModelId,
        $TimestampUtc = $null,
        [string]$ProcessingTier = 'STANDARD',
        [string]$TimeBand
    )
    if (-not $Catalogue) { return $null }
    $ts = if ($null -eq $TimestampUtc) { [datetime]::UtcNow } else { ConvertTo-AiUtc $TimestampUtc }

    $provId = $ProviderId.Trim().ToLowerInvariant()
    $mid = $ModelId.Trim().ToLowerInvariant()
    $tier = $ProcessingTier.Trim().ToUpperInvariant()
    if (-not $TimeBand) { $band = Resolve-AiPricingTimeBand -ProviderId $provId -TimestampUtc $ts }
    else { $band = $TimeBand.Trim().ToUpperInvariant() }

    # every record for the requested key (provider/model/tier), regardless of band or date
    $keyRecords = @($Catalogue.Values | Where-Object {
        $_.ProviderId -eq $provId -and $_.ModelId -eq $mid -and $_.ProcessingTier -eq $tier
    })

    # effective at the timestamp: EffectiveFromUtc <= ts < EffectiveToUtc (null end = open)
    $effective = @($keyRecords | Where-Object {
        $f = ConvertTo-AiUtc $_.EffectiveFromUtc
        $t = if ($_.EffectiveToUtc) { ConvertTo-AiUtc $_.EffectiveToUtc } else { [datetime]::MaxValue }
        ($f -le $ts) -and ($t -gt $ts)
    })

    # time-band matching with precedence: a concrete band wins over DEFAULT; DEFAULT is the fallback
    $matched = @()
    if ($band -ne 'DEFAULT') {
        $specific = @($effective | Where-Object { $_.TimeBand -eq $band })
        if ($specific.Count -gt 0) { $matched = $specific }
        else { $matched = @($effective | Where-Object { $_.TimeBand -eq 'DEFAULT' }) }
    } else {
        $matched = @($effective | Where-Object { $_.TimeBand -eq 'DEFAULT' })
    }

    # --- classify the lookup state ---
    if ($matched.Count -eq 1) {
        $st = Get-AiPricingRecordStatus -Record $matched[0] -AsOfUtc $ts
        return New-AiPriceLookupResult -ProviderId $provId -ModelId $mid -TimestampUtc $ts `
            -ProcessingTier $tier -TimeBand $band -LookupState 'FOUND' -MatchedRecords $matched `
            -Status $st.Status -Message 'exactly one effective price record'
    }
    if ($matched.Count -gt 1) {
        return New-AiPriceLookupResult -ProviderId $provId -ModelId $mid -TimestampUtc $ts `
            -ProcessingTier $tier -TimeBand $band -LookupState 'AMBIGUOUS' -MatchedRecords $matched `
            -Message "multiple effective price records for the same key (should not happen in a validated catalogue)"
    }

    # no effective match: distinguish NOT_FOUND vs EXPIRED vs future-only
    if ($keyRecords.Count -eq 0) {
        return New-AiPriceLookupResult -ProviderId $provId -ModelId $mid -TimestampUtc $ts `
            -ProcessingTier $tier -TimeBand $band -LookupState 'NOT_FOUND' -MatchedRecords @() `
            -Message 'no price records exist for this key'
    }
    $historicLapsed = @($keyRecords | Where-Object { $_.EffectiveToUtc -and (ConvertTo-AiUtc $_.EffectiveToUtc) -le $ts })
    $futureRecords = @($keyRecords | Where-Object { (ConvertTo-AiUtc $_.EffectiveFromUtc) -gt $ts })
    $nextUp = $null
    if ($futureRecords.Count -gt 0) {
        $nextUp = ($futureRecords | Sort-Object { ConvertTo-AiUtc $_.EffectiveFromUtc } | Select-Object -First 1).EffectiveFromUtc
    }
    if ($historicLapsed.Count -gt 0) {
        $isFuture = $futureRecords.Count -gt 0
        $hasGap = $isFuture   # historic lapsed AND a later record exists after the gap
        return New-AiPriceLookupResult -ProviderId $provId -ModelId $mid -TimestampUtc $ts `
            -ProcessingTier $tier -TimeBand $band -LookupState 'EXPIRED' -MatchedRecords @() `
            -IsExpired $true -IsFuture $isFuture -HasGap $hasGap -NearestUpcomingEffectiveFromUtc $nextUp `
            -Message 'price coverage has lapsed (historic records exist, none effective at the timestamp)'
    }
    if ($futureRecords.Count -gt 0) {
        return New-AiPriceLookupResult -ProviderId $provId -ModelId $mid -TimestampUtc $ts `
            -ProcessingTier $tier -TimeBand $band -LookupState 'NOT_FOUND' -MatchedRecords @() `
            -IsFuture $true -NearestUpcomingEffectiveFromUtc $nextUp `
            -Message 'price not yet effective (all records start after the timestamp)'
    }
    return New-AiPriceLookupResult -ProviderId $provId -ModelId $mid -TimestampUtc $ts `
        -ProcessingTier $tier -TimeBand $band -LookupState 'NOT_FOUND' -MatchedRecords @() `
        -Message 'no effective price record for this key at the timestamp'
}

function Get-AiCurrentPrice {
    <#
    .SYNOPSIS
    Current-price convenience lookup. Uses [datetime]::UtcNow explicitly (never
    local system time). Same semantics as Get-AiPriceAt.
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$ProcessingTier = 'STANDARD',
        [string]$TimeBand
    )
    return Get-AiPriceAt -Catalogue $Catalogue -ProviderId $ProviderId -ModelId $ModelId `
        -TimestampUtc ([datetime]::UtcNow) -ProcessingTier $ProcessingTier -TimeBand $TimeBand
}

# --- catalogue validation -------------------------------------------------------------

function Validate-AiPricingCatalogue {
    <#
    .SYNOPSIS
    Deterministically validate a pricing catalogue (PricingCatalogue v1).
      Errors (invalid): duplicate PricingRecordId, schema != 1, per-record failures,
        unknown provider reference, negative price, overlapping effective periods
        for the same provider/model/tier/time-band, missing/ill-formed currency.
      Warnings (reviewable): unknown model reference, non-recommended source.
      Info: gaps between effective periods, per-status record counts.
    Gaps are reported, NOT rejected (a gap yields an EXPIRED lookup, which is a
    legitimate state the router handles explicitly).
    Returns @{ Valid; Errors; Warnings; Gaps; Overlaps; StatusCounts; Records }.
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [System.Collections.IDictionary]$Providers,
        [System.Collections.IDictionary]$Models
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $gaps = New-Object System.Collections.Generic.List[string]
    $overlaps = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Catalogue) {
        $errors.Add('Catalogue is null')
        return @{ Valid = $false; Errors = @($errors); Warnings = @(); Gaps = @(); Overlaps = @(); StatusCounts = @{}; Records = @() }
    }

    $statusCounts = @{ CURRENT = 0; NEEDS_REVIEW = 0; EXPIRED = 0; MANUAL_OVERRIDE = 0 }
    $asOf = [datetime]::UtcNow

    foreach ($key in $Catalogue.Keys) {
        $r = $Catalogue[$key]
        if ($r.PricingRecordId -ne $key) { $errors.Add("Catalogue key '$key' does not match record PricingRecordId '$($r.PricingRecordId)'") }
        $t = Test-AiPricingRecord $r
        if (-not $t.Valid) { $errors.Add("Pricing record '$key': $($t.Errors -join '; ')") }
        foreach ($w in $t.Warnings) { $warnings.Add("Pricing record '$key': $w") }
        if ($Providers) {
            if ($Providers.ContainsKey($r.ProviderId)) { $r.ProviderResolved = $true }
            else {
                $r.ProviderResolved = $false
                $errors.Add("Pricing record '$key' references unknown provider '$($r.ProviderId)'")
            }
        }
        if ($Models) {
            if ($Models.ContainsKey($r.ModelId)) { $r.ModelResolved = $true }
            else {
                $r.ModelResolved = $false
                $warnings.Add("Pricing record '$key' references model '$($r.ModelId)' not in the model catalogue (needs review; do not guess)")
            }
        }
        $st = Get-AiPricingRecordStatus -Record $r -AsOfUtc $asOf
        $statusCounts[$st.Status]++
    }

    # grouping by provider/model/tier/time-band for overlap + gap detection
    $groups = @{}
    foreach ($key in $Catalogue.Keys) {
        $r = $Catalogue[$key]
        $gKey = "$($r.ProviderId)|$($r.ModelId)|$($r.ProcessingTier)|$($r.TimeBand)"
        if (-not $groups.ContainsKey($gKey)) { $groups[$gKey] = New-Object System.Collections.Generic.List[object] }
        $groups[$gKey].Add($r)
    }
    foreach ($gKey in $groups.Keys) {
        $list = $groups[$gKey].ToArray()
        if ($list.Count -lt 2) { continue }
        $sorted = @($list | Sort-Object { ConvertTo-AiUtc $_.EffectiveFromUtc })
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            for ($j = $i + 1; $j -lt $sorted.Count; $j++) {
                $a = $sorted[$i]; $b = $sorted[$j]
                if (Test-IntervalsOverlap $a.EffectiveFromUtc $a.EffectiveToUtc $b.EffectiveFromUtc $b.EffectiveToUtc) {
                    $overlaps.Add("Overlap: '$($a.PricingRecordId)' [$($a.EffectiveFromUtc) -> $($a.EffectiveToUtc)) and '$($b.PricingRecordId)' [$($b.EffectiveFromUtc) -> $($b.EffectiveToUtc)) for $gKey")
                }
            }
        }
        for ($k = 0; $k -lt $sorted.Count - 1; $k++) {
            $prev = $sorted[$k]; $next = $sorted[$k + 1]
            if ($prev.EffectiveToUtc) {
                $prevTo = ConvertTo-AiUtc $prev.EffectiveToUtc
                $nextFrom = ConvertTo-AiUtc $next.EffectiveFromUtc
                if ($prevTo -lt $nextFrom) {
                    $gaps.Add("Gap: '$($prev.PricingRecordId)' ends $($prev.EffectiveToUtc), '$($next.PricingRecordId)' starts $($next.EffectiveFromUtc) for $gKey")
                }
            }
        }
    }
    foreach ($o in $overlaps) { $errors.Add($o) }

    return @{
        Valid        = ($errors.Count -eq 0)
        Errors       = @($errors)
        Warnings     = @($warnings)
        Gaps         = @($gaps)
        Overlaps     = @($overlaps)
        StatusCounts = $statusCounts
        Records      = @(Get-AiPricingRecords $Catalogue)
    }
}

function Validate-AiPriceHistory {
    <#
    .SYNOPSIS
    Conceptual alias for Validate-AiPricingCatalogue (the brief's ValidatePriceHistory):
    verifies the effective-dated history is consistent (no overlaps, no rewritten
    records, resolvable references, deterministic lookups).
    #>
    param(
        [System.Collections.IDictionary]$Catalogue,
        [System.Collections.IDictionary]$Providers,
        [System.Collections.IDictionary]$Models
    )
    return Validate-AiPricingCatalogue -Catalogue $Catalogue -Providers $Providers -Models $Models
}

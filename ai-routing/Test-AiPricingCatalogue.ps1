# Test-AiPricingCatalogue.ps1 — DB-M15 self-contained assertion suite.
#
# Proves the effective-dated pricing catalogue WITHOUT any paid API call,
# network access, or credential use. All fixtures are in-memory. ZERO paid
# API calls. Matches the DevBridge Assert-True convention (DB-M14).
#
# Coverage: DeepSeek time-band boundaries (mandatory), effective/historic/
# future/expired lookup, gaps, overlap rejection, AMBIGUOUS defence,
# cached/uncached/output/cache-write price dimensions, manual override,
# source metadata, status classification, band precedence + DEFAULT fallback,
# unknown dimension null, missing price, unknown/disabled model reference,
# serialization round-trip, schema v1, historic reproducibility after
# successive price changes, seed catalogue import/validation, no-network scan.
#
# Run: powershell -NoProfile -File ai-routing\Test-AiPricingCatalogue.ps1
# Exit code: 0 all pass, 1 any failure.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "AiRoutingPricingFoundation.ps1")

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

Write-Output "== DB-M15 Pricing Catalogue test suite =="

# --- fixtures -----------------------------------------------------------------

function New-FixtureRecord {
    param(
        [string]$Id,
        [string]$ProviderId,
        [string]$ModelId,
        [string]$From,
        [string]$To = $null,
        [string]$Tier = 'STANDARD',
        [string]$Band = 'DEFAULT',
        [double]$In = 1.0,
        [double]$Out = 4.0,
        [double]$Cin = 0.1,
        [bool]$ManualOverride = $false,
        [string]$Source = 'reference',
        [string]$VerifiedAtUtc = $null
    )
    return New-AiPricingRecord -PricingRecordId $Id -ProviderId $ProviderId -ModelId $ModelId `
        -EffectiveFromUtc $From -EffectiveToUtc $To -ProcessingTier $Tier -TimeBand $Band `
        -InputPricePerMillion $In -OutputPricePerMillion $Out -CachedInputPricePerMillion $Cin `
        -ManualOverride $ManualOverride -Source $Source -VerifiedAtUtc $VerifiedAtUtc
}

Write-Output "--- A. DeepSeek time-band resolution (boundary tests mandatory) ---"
$bs = @(
    @('peak interval 1 start 01:00Z inclusive', '2026-08-31T01:00:00Z', 'PEAK'),
    @('peak interval 1 inside 03:59:59Z',        '2026-08-31T03:59:59Z', 'PEAK'),
    @('peak interval 1 end 04:00Z exclusive',    '2026-08-31T04:00:00Z', 'OFF_PEAK'),
    @('off-peak between bands 05:59:59Z',        '2026-08-31T05:59:59Z', 'OFF_PEAK'),
    @('peak interval 2 start 06:00Z inclusive',  '2026-08-31T06:00:00Z', 'PEAK'),
    @('peak interval 2 inside 09:59:59Z',        '2026-08-31T09:59:59Z', 'PEAK'),
    @('peak interval 2 end 10:00Z exclusive',    '2026-08-31T10:00:00Z', 'OFF_PEAK'),
    @('off-peak 00:30Z',                         '2026-08-31T00:30:00Z', 'OFF_PEAK'),
    @('off-peak noon 12:00Z',                    '2026-08-31T12:00:00Z', 'OFF_PEAK')
)
foreach ($b in $bs) {
    $got = Resolve-AiPricingTimeBand -ProviderId 'deepseek' -TimestampUtc $b[1]
    Assert-True ("DeepSeek band: " + $b[0]) ($got -eq $b[2]) ("expect $($b[2]), got $got at $($b[1])")
}
Assert-True "non-DeepSeek provider resolves DEFAULT" `
    ((Resolve-AiPricingTimeBand -ProviderId 'anthropic' -TimestampUtc '2026-08-31T08:00:00Z') -eq 'DEFAULT') `
    "anthropic must never resolve to PEAK/OFF_PEAK"
Assert-True "provider id is normalized case-insensitively" `
    ((Resolve-AiPricingTimeBand -ProviderId 'DEEPSEEK' -TimestampUtc '2026-08-31T01:00:00Z') -eq 'PEAK') `
    "'DEEPSEEK' resolves identically to 'deepseek'"

Write-Output "--- B. pricing record construction + validation ---"
$rec = New-FixtureRecord -Id 't-basic' -ProviderId 'deepseek' -ModelId 'm1' -From '2026-08-01T00:00:00Z'
$tv = Test-AiPricingRecord $rec
Assert-True "valid record passes validation" $tv.Valid ("errors: $($tv.Errors -join '; ')")
Assert-True "record schemaVersion is 1" ($rec.SchemaVersion -eq 1) "got $($rec.SchemaVersion)"
Assert-True "tier defaults to STANDARD" ($rec.ProcessingTier -eq 'STANDARD') "got $($rec.ProcessingTier)"
Assert-True "band defaults to DEFAULT" ($rec.TimeBand -eq 'DEFAULT') "got $($rec.TimeBand)"
Assert-True "currency uppercased to USD" ($rec.Currency -eq 'USD') "got $($rec.Currency)"

$bad1 = New-FixtureRecord -Id 't-neg' -ProviderId 'deepseek' -ModelId 'm1' -From '2026-08-01T00:00:00Z' -In -5.0
Assert-True "negative price rejected" (-not (Test-AiPricingRecord $bad1).Valid) "a -5.0 input price must fail"
$bad2 = New-FixtureRecord -Id 't-cur' -ProviderId 'deepseek' -ModelId 'm1' -From '2026-08-01T00:00:00Z'
$bad2.Currency = 'US'
Assert-True "malformed currency rejected" (-not (Test-AiPricingRecord $bad2).Valid) "2-letter currency must fail"
$bad3 = New-FixtureRecord -Id 't-dates' -ProviderId 'deepseek' -ModelId 'm1' -From '2026-09-01T00:00:00Z' -To '2026-08-01T00:00:00Z'
Assert-True "EffectiveFrom >= EffectiveTo rejected" (-not (Test-AiPricingRecord $bad3).Valid) "inverted window must fail"
$bad4 = New-FixtureRecord -Id 't-tier' -ProviderId 'deepseek' -ModelId 'm1' -From '2026-08-01T00:00:00Z' -Tier 'TURBO'
Assert-True "unknown processing tier rejected" (-not (Test-AiPricingRecord $bad4).Valid) "tier 'TURBO' must fail"
$bad5 = New-FixtureRecord -Id 't-band' -ProviderId 'deepseek' -ModelId 'm1' -From '2026-08-01T00:00:00Z' -Band 'MIDNIGHT'
Assert-True "unknown time band rejected" (-not (Test-AiPricingRecord $bad5).Valid) "band 'MIDNIGHT' must fail"

Write-Output "--- C. effective-dated versioning (historic prices preserved) ---"
$cat = @{}
$v1 = New-FixtureRecord -Id 'hist-v1' -ProviderId 'deepseek' -ModelId 'm-hist' -From '2026-08-01T00:00:00Z' -In 1.0
Add-AiPricingRecord -Catalogue $cat -Record $v1 | Out-Null
$v2 = New-FixtureRecord -Id 'hist-v2' -ProviderId 'deepseek' -ModelId 'm-hist' -From '2026-09-01T00:00:00Z' -In 2.0
Add-AiPriceVersion -Catalogue $cat -Record $v2 -ClosePredecessor | Out-Null
Assert-True "predecessor's EffectiveToUtc closed at change boundary" `
    ($cat['hist-v1'].EffectiveToUtc -eq '2026-09-01T00:00:00Z') "got $($cat['hist-v1'].EffectiveToUtc)"
$l1 = Get-AiPriceAt -Catalogue $cat -ProviderId 'deepseek' -ModelId 'm-hist' -TimestampUtc '2026-08-15T00:00:00Z'
Assert-True "historic lookup resolves historic rate (in=1.0)" `
    ($l1.LookupState -eq 'FOUND' -and $l1.Record.PricingRecordId -eq 'hist-v1' -and $l1.Record.InputPricePerMillion -eq 1.0) `
    "state=$($l1.LookupState) record=$($l1.Record.PricingRecordId) in=$($l1.Record.InputPricePerMillion)"
$l2 = Get-AiPriceAt -Catalogue $cat -ProviderId 'deepseek' -ModelId 'm-hist' -TimestampUtc '2026-09-15T00:00:00Z'
Assert-True "new version effective after boundary (in=2.0)" `
    ($l2.LookupState -eq 'FOUND' -and $l2.Record.PricingRecordId -eq 'hist-v2' -and $l2.Record.InputPricePerMillion -eq 2.0) `
    "state=$($l2.LookupState) record=$($l2.Record.PricingRecordId) in=$($l2.Record.InputPricePerMillion)"
$vh = Validate-AiPricingCatalogue -Catalogue $cat
Assert-True "versioned history validates clean (no overlap, no gap)" `
    ($vh.Valid -and $vh.Overlaps.Count -eq 0 -and $vh.Gaps.Count -eq 0) `
    "Valid=$($vh.Valid) overlaps=$($vh.Overlaps.Count) gaps=$($vh.Gaps.Count)"

# overlap rejected WITHOUT -ClosePredecessor
$cat2 = @{}
Add-AiPricingRecord -Catalogue $cat2 -Record (New-FixtureRecord -Id 'ov-a' -ProviderId 'openai' -ModelId 'm-ov' -From '2026-08-01T00:00:00Z') | Out-Null
$threw = $false
try {
    Add-AiPriceVersion -Catalogue $cat2 -Record (New-FixtureRecord -Id 'ov-b' -ProviderId 'openai' -ModelId 'm-ov' -From '2026-08-15T00:00:00Z')
} catch { $threw = $true }
Assert-True "overlapping version rejected without -ClosePredecessor" $threw "an overlap must throw"
# and the historic record is untouched
Assert-True "historic record untouched after rejected version" ($cat2['ov-a'].EffectiveToUtc -eq $null) "EffectiveToUtc must remain open"

# overlap detection in Validate
$cat3 = @{}
Add-AiPricingRecord -Catalogue $cat3 -Record (New-FixtureRecord -Id 'ov1' -ProviderId 'openai' -ModelId 'm-ov2' -From '2026-08-01T00:00:00Z') | Out-Null
Add-AiPricingRecord -Catalogue $cat3 -Record (New-FixtureRecord -Id 'ov2' -ProviderId 'openai' -ModelId 'm-ov2' -From '2026-08-15T00:00:00Z') | Out-Null
$v3 = Validate-AiPricingCatalogue -Catalogue $cat3
Assert-True "Validate flags overlapping effective periods" ($v3.Overlaps.Count -eq 1) "overlaps=$($v3.Overlaps.Count)"

# gap detection -> EXPIRED lookup
$cat4 = @{}
Add-AiPricingRecord -Catalogue $cat4 -Record (New-FixtureRecord -Id 'gap-a' -ProviderId 'openai' -ModelId 'm-gap' -From '2026-08-01T00:00:00Z' -To '2026-08-10T00:00:00Z') | Out-Null
Add-AiPricingRecord -Catalogue $cat4 -Record (New-FixtureRecord -Id 'gap-b' -ProviderId 'openai' -ModelId 'm-gap' -From '2026-08-20T00:00:00Z') | Out-Null
$v4 = Validate-AiPricingCatalogue -Catalogue $cat4
Assert-True "Validate reports the gap" ($v4.Gaps.Count -eq 1) "gaps=$($v4.Gaps.Count)"
$lg = Get-AiPriceAt -Catalogue $cat4 -ProviderId 'openai' -ModelId 'm-gap' -TimestampUtc '2026-08-15T00:00:00Z'
Assert-True "lookup in a gap is EXPIRED with HasGap" `
    ($lg.LookupState -eq 'EXPIRED' -and $lg.IsExpired -and $lg.HasGap) `
    "state=$($lg.LookupState) IsExpired=$($lg.IsExpired) HasGap=$($lg.HasGap)"

Write-Output "--- D. lookup states: FOUND / NOT_FOUND / AMBIGUOUS / EXPIRED / future ---"
# EXPIRED (every window closed)
$catExp = @{}
Add-AiPricingRecord -Catalogue $catExp -Record (New-FixtureRecord -Id 'exp-a' -ProviderId 'openai' -ModelId 'm-exp' -From '2026-08-01T00:00:00Z' -To '2026-08-10T00:00:00Z') | Out-Null
$le = Get-AiPriceAt -Catalogue $catExp -ProviderId 'openai' -ModelId 'm-exp' -TimestampUtc '2026-09-01T00:00:00Z'
Assert-True "lookup after all windows closed is EXPIRED" ($le.LookupState -eq 'EXPIRED' -and $le.IsExpired) "state=$($le.LookupState)"
# NOT_FOUND (no records at all)
$cat5 = @{}
Add-AiPricingRecord -Catalogue $cat5 -Record (New-FixtureRecord -Id 'other' -ProviderId 'anthropic' -ModelId 'm-x' -From '2026-08-01T00:00:00Z') | Out-Null
$lnf = Get-AiPriceAt -Catalogue $cat5 -ProviderId 'openai' -ModelId 'does-not-exist' -TimestampUtc '2026-08-15T00:00:00Z'
Assert-True "missing price -> NOT_FOUND" ($lnf.LookupState -eq 'NOT_FOUND') "state=$($lnf.LookupState)"
# NOT_FOUND but future-only
$cat6 = @{}
Add-AiPricingRecord -Catalogue $cat6 -Record (New-FixtureRecord -Id 'fut-1' -ProviderId 'openai' -ModelId 'm-fut' -From '2027-01-01T00:00:00Z') | Out-Null
$lf = Get-AiPriceAt -Catalogue $cat6 -ProviderId 'openai' -ModelId 'm-fut' -TimestampUtc '2026-08-15T00:00:00Z'
Assert-True "future-only price -> NOT_FOUND + IsFuture + nearest date" `
    ($lf.LookupState -eq 'NOT_FOUND' -and $lf.IsFuture -and $lf.NearestUpcomingEffectiveFromUtc -eq '2027-01-01T00:00:00Z') `
    "state=$($lf.LookupState) IsFuture=$($lf.IsFuture) next=$($lf.NearestUpcomingEffectiveFromUtc)"
$stFut = Get-AiPricingRecordStatus -Record $cat6['fut-1'] -AsOfUtc '2026-08-15T00:00:00Z'
Assert-True "future record classifies NEEDS_REVIEW (not yet effective)" ($stFut.Status -eq 'NEEDS_REVIEW') "status=$($stFut.Status)"
# AMBIGUOUS (two effective records same key)
$cat7 = @{}
Add-AiPricingRecord -Catalogue $cat7 -Record (New-FixtureRecord -Id 'amb-1' -ProviderId 'openai' -ModelId 'm-amb' -From '2026-08-01T00:00:00Z') | Out-Null
Add-AiPricingRecord -Catalogue $cat7 -Record (New-FixtureRecord -Id 'amb-2' -ProviderId 'openai' -ModelId 'm-amb' -From '2026-08-01T00:00:00Z') | Out-Null
$la = Get-AiPriceAt -Catalogue $cat7 -ProviderId 'openai' -ModelId 'm-amb' -TimestampUtc '2026-08-15T00:00:00Z'
Assert-True "ambiguous overlap -> AMBIGUOUS (never silently chosen)" `
    ($la.LookupState -eq 'AMBIGUOUS' -and $la.MatchedRecordCount -eq 2) `
    "state=$($la.LookupState) matched=$($la.MatchedRecordCount)"

Write-Output "--- E. time-band precedence + DEFAULT fallback ---"
$cat8 = @{}
# deepseek m-tb: DEFAULT (1.0) AND OFF_PEAK (0.5), both effective at 00:30Z
Add-AiPricingRecord -Catalogue $cat8 -Record (New-FixtureRecord -Id 'tb-def' -ProviderId 'deepseek' -ModelId 'm-tb' -From '2026-08-01T00:00:00Z' -Band 'DEFAULT' -In 1.0) | Out-Null
Add-AiPricingRecord -Catalogue $cat8 -Record (New-FixtureRecord -Id 'tb-off' -ProviderId 'deepseek' -ModelId 'm-tb' -From '2026-08-01T00:00:00Z' -Band 'OFF_PEAK' -In 0.5) | Out-Null
# at 00:30Z deepseek resolves OFF_PEAK -> specific band wins over DEFAULT
$tb1 = Get-AiPriceAt -Catalogue $cat8 -ProviderId 'deepseek' -ModelId 'm-tb' -TimestampUtc '2026-08-31T00:30:00Z'
Assert-True "concrete OFF_PEAK band wins over DEFAULT fallback" `
    ($tb1.LookupState -eq 'FOUND' -and $tb1.Record.PricingRecordId -eq 'tb-off') `
    "record=$($tb1.Record.PricingRecordId) band=$($tb1.TimeBand)"
# at 08:00Z deepseek resolves PEAK; no PEAK record -> DEFAULT fallback
$tb2 = Get-AiPriceAt -Catalogue $cat8 -ProviderId 'deepseek' -ModelId 'm-tb' -TimestampUtc '2026-08-31T08:00:00Z'
Assert-True "DEFAULT fallback when no concrete band record exists" `
    ($tb2.LookupState -eq 'FOUND' -and $tb2.Record.PricingRecordId -eq 'tb-def') `
    "record=$($tb2.Record.PricingRecordId) band=$($tb2.TimeBand)"
# explicit -TimeBand overrides the resolver
$tb3 = Get-AiPriceAt -Catalogue $cat8 -ProviderId 'deepseek' -ModelId 'm-tb' -TimestampUtc '2026-08-31T00:30:00Z' -TimeBand 'DEFAULT'
Assert-True "explicit -TimeBand overrides resolver" ($tb3.Record.PricingRecordId -eq 'tb-def') "record=$($tb3.Record.PricingRecordId)"

Write-Output "--- F. price dimensions: cached/uncached/output/cache-write + unknown null ---"
$son = New-FixtureRecord -Id 't-dims' -ProviderId 'anthropic' -ModelId 'claude-sonnet-5' -From '2026-08-01T00:00:00Z' -In 2.0 -Out 10.0 -Cin 0.2
$son.CacheWrite5mPricePerMillion = 2.5
$son.CacheWrite1hPricePerMillion = 4.0
Assert-True "cache-write dimensions retained" `
    ($son.CacheWrite5mPricePerMillion -eq 2.5 -and $son.CacheWrite1hPricePerMillion -eq 4.0) `
    "cw5=$($son.CacheWrite5mPricePerMillion) cw1=$($son.CacheWrite1hPricePerMillion)"
Assert-True "unknown dimension stays null (not faked as zero)" `
    ($null -eq $son.ToolCallPrice -and $null -eq $son.ImagePrice -and $null -eq $son.StoragePrice -and $null -eq $son.ReasoningTokenPricePerMillion) `
    "ToolCall=$($son.ToolCallPrice) Image=$($son.ImagePrice) Storage=$($son.StoragePrice) Reasoning=$($son.ReasoningTokenPricePerMillion)"

Write-Output "--- G. status classification ---"
$now = [datetime]::UtcNow
$past = $now.AddMonths(-1)
$stCur = Get-AiPricingRecordStatus -Record (New-FixtureRecord -Id 's-cur' -ProviderId 'openai' -ModelId 'm1' -From $past.ToString('o') -Source 'provider-documentation' -VerifiedAtUtc $past.ToString('o'))
Assert-True "verified + provider-documentation + effective -> CURRENT" ($stCur.Status -eq 'CURRENT') "status=$($stCur.Status) reason=$($stCur.Reason)"
$stRef = Get-AiPricingRecordStatus -Record (New-FixtureRecord -Id 's-ref' -ProviderId 'openai' -ModelId 'm1' -From $past.ToString('o') -Source 'reference')
Assert-True "unverified reference record -> NEEDS_REVIEW" ($stRef.Status -eq 'NEEDS_REVIEW') "status=$($stRef.Status)"
$stSync = Get-AiPricingRecordStatus -Record (New-FixtureRecord -Id 's-sync' -ProviderId 'openai' -ModelId 'm1' -From $past.ToString('o') -Source 'sync-proposal' -VerifiedAtUtc $past.ToString('o'))
Assert-True "sync-proposal source not authoritative -> NEEDS_REVIEW" ($stSync.Status -eq 'NEEDS_REVIEW') "status=$($stSync.Status)"
$mo = New-FixtureRecord -Id 's-mo' -ProviderId 'openai' -ModelId 'm1' -From $past.ToString('o') -Source 'reference' -ManualOverride $true
$stMo = Get-AiPricingRecordStatus -Record $mo -AsOfUtc $past
Assert-True "manual override -> MANUAL_OVERRIDE" ($stMo.Status -eq 'MANUAL_OVERRIDE') "status=$($stMo.Status)"
# model unresolved blocks CURRENT
$mu = New-FixtureRecord -Id 's-mu' -ProviderId 'openai' -ModelId 'm1' -From $past.ToString('o') -Source 'provider-documentation' -VerifiedAtUtc $past.ToString('o')
$mu.ModelResolved = $false
$stMu = Get-AiPricingRecordStatus -Record $mu -AsOfUtc $past
Assert-True "unresolved model blocks CURRENT (-> NEEDS_REVIEW)" ($stMu.Status -eq 'NEEDS_REVIEW') "status=$($stMu.Status)"

Write-Output "--- H. Add-AiPriceVersion historic chain reproducible (3 versions) ---"
$cat9 = @{}
Add-AiPricingRecord -Catalogue $cat9 -Record (New-FixtureRecord -Id 'ch-a' -ProviderId 'openai' -ModelId 'm-ch' -From '2026-08-01T00:00:00Z' -In 1.0) | Out-Null
Add-AiPriceVersion -Catalogue $cat9 -Record (New-FixtureRecord -Id 'ch-b' -ProviderId 'openai' -ModelId 'm-ch' -From '2026-09-01T00:00:00Z' -In 2.0) -ClosePredecessor | Out-Null
Add-AiPriceVersion -Catalogue $cat9 -Record (New-FixtureRecord -Id 'ch-c' -ProviderId 'openai' -ModelId 'm-ch' -From '2026-10-01T00:00:00Z' -In 3.0) -ClosePredecessor | Out-Null
$h1 = Get-AiPriceAt -Catalogue $cat9 -ProviderId 'openai' -ModelId 'm-ch' -TimestampUtc '2026-08-15T00:00:00Z'
$h2 = Get-AiPriceAt -Catalogue $cat9 -ProviderId 'openai' -ModelId 'm-ch' -TimestampUtc '2026-09-15T00:00:00Z'
$h3 = Get-AiPriceAt -Catalogue $cat9 -ProviderId 'openai' -ModelId 'm-ch' -TimestampUtc '2026-10-15T00:00:00Z'
Assert-True "chain v1 historic rate reproducible" ($h1.Record.InputPricePerMillion -eq 1.0) "in=$($h1.Record.InputPricePerMillion)"
Assert-True "chain v2 historic rate reproducible" ($h2.Record.InputPricePerMillion -eq 2.0) "in=$($h2.Record.InputPricePerMillion)"
Assert-True "chain v3 current rate" ($h3.Record.InputPricePerMillion -eq 3.0) "in=$($h3.Record.InputPricePerMillion)"
Assert-True "chain: no overlap, no gap, valid" `
    ($( $v9 = Validate-AiPricingCatalogue -Catalogue $cat9; $v9.Valid -and $v9.Overlaps.Count -eq 0 -and $v9.Gaps.Count -eq 0 )) `
    "overlaps=$($v9.Overlaps.Count) gaps=$($v9.Gaps.Count)"
Assert-True "historic v1 record never rewritten (still in=1.0)" ($cat9['ch-a'].InputPricePerMillion -eq 1.0) "in=$($cat9['ch-a'].InputPricePerMillion)"

Write-Output "--- I. serialization round-trip + schema v1 ---"
$ser = New-FixtureRecord -Id 't-ser' -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -From '2026-08-30T00:00:00Z' -In 0.22 -Out 0.66 -Cin 0.007
$json = $ser | ConvertTo-Json -Depth 10
$back = $json | ConvertFrom-Json
$rebuilt = New-AiPricingRecord -InputObject $back
$rvt = Test-AiPricingRecord $rebuilt
Assert-True "serialization round-trip validates" $rvt.Valid ("errors: $($rvt.Errors -join '; ')")
Assert-True "round-trip preserves rate fields" `
    ($rebuilt.InputPricePerMillion -eq 0.22 -and $rebuilt.OutputPricePerMillion -eq 0.66 -and $rebuilt.CachedInputPricePerMillion -eq 0.007) `
    "in=$($rebuilt.InputPricePerMillion) out=$($rebuilt.OutputPricePerMillion) cin=$($rebuilt.CachedInputPricePerMillion)"
$sv = Get-AiPricingSchemaVersions
Assert-True "PricingRecord v1 frozen" ($sv.PricingRecordVersion -eq 1) "got $($sv.PricingRecordVersion)"
Assert-True "PriceLookupResult v1 frozen" ($sv.PriceLookupResultVersion -eq 1) "got $($sv.PriceLookupResultVersion)"
Assert-True "PricingCatalogue v1 frozen" ($sv.PricingCatalogueVersion -eq 1) "got $($sv.PricingCatalogueVersion)"
$lk = Get-AiPriceAt -Catalogue $cat -ProviderId 'deepseek' -ModelId 'm-hist' -TimestampUtc '2026-08-15T00:00:00Z'
Assert-True "lookup result schemaVersion is 1" ($lk.SchemaVersion -eq 1) "got $($lk.SchemaVersion)"

Write-Output "--- J. unknown provider/model references in validation ---"
$provs = @{}
$provs['deepseek'] = [pscustomobject]@{ ProviderId = 'deepseek'; Enabled = $true }
$models = @{}
$models['deepseek-v4-flash'] = [pscustomobject]@{ ModelId = 'deepseek-v4-flash'; Enabled = $true }
$cat10 = @{}
$rOk = New-FixtureRecord -Id 'ref-ok' -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -From '2026-08-01T00:00:00Z'
$rBadProv = New-FixtureRecord -Id 'ref-badprov' -ProviderId 'nonexistent-provider' -ModelId 'deepseek-v4-flash' -From '2026-08-01T00:00:00Z'
$rBadModel = New-FixtureRecord -Id 'ref-badmodel' -ProviderId 'deepseek' -ModelId 'not-catalogued-model' -From '2026-08-01T00:00:00Z'
Add-AiPricingRecord -Catalogue $cat10 -Record $rOk | Out-Null
Add-AiPricingRecord -Catalogue $cat10 -Record $rBadProv | Out-Null
Add-AiPricingRecord -Catalogue $cat10 -Record $rBadModel | Out-Null
$v10 = Validate-AiPricingCatalogue -Catalogue $cat10 -Providers $provs -Models $models
Assert-True "unknown provider -> validation ERROR" `
    (@($v10.Errors | Where-Object { $_ -like '*unknown provider*nonexistent-provider*' }).Count -ge 1) `
    "errors: $($v10.Errors -join ' | ')"
Assert-True "unknown model -> validation WARNING (needs review, not error)" `
    (@($v10.Warnings | Where-Object { $_ -like '*not in the model catalogue*' }).Count -ge 1) `
    "warnings: $($v10.Warnings -join ' | ')"
Assert-True "unknown model record flagged NEEDS_REVIEW" `
    ((Get-AiPricingRecordStatus -Record $rBadModel -AsOfUtc '2026-08-15T00:00:00Z').Status -eq 'NEEDS_REVIEW') `
    "status=$((Get-AiPricingRecordStatus -Record $rBadModel -AsOfUtc '2026-08-15T00:00:00Z').Status)"
Assert-True "known provider + known model -> ProviderResolved/ModelResolved set by validation" `
    ($rOk.ProviderResolved -eq $true -and $rOk.ModelResolved -eq $true) `
    "ProviderResolved=$($rOk.ProviderResolved) ModelResolved=$($rOk.ModelResolved)"

Write-Output "--- K. seed catalogue (config/pricing/pricing-catalogue.json) ---"
$seed = Import-AiPricingConfiguration
$sv2 = Validate-AiPricingFoundation -Configuration $seed
Assert-True "seed catalogue imports 10 records" ($seed.Pricing.Count -eq 10) "count=$($seed.Pricing.Count)"
Assert-True "seed catalogue validates (0 errors)" ($sv2.Valid) ("errors: $($sv2.Errors -join '; ')")
Assert-True "seed unresolved models surface as warnings, not errors" `
    ($sv2.Errors.Count -eq 0 -and $sv2.Warnings.Count -eq 5) "errors=$($sv2.Errors.Count) warnings=$($sv2.Warnings.Count)"
Assert-True "seed status counts 0/10/0/0 (all reference, unverified -> NEEDS_REVIEW)" `
    ($sv2.StatusCounts['CURRENT'] -eq 0 -and $sv2.StatusCounts['NEEDS_REVIEW'] -eq 10 -and $sv2.StatusCounts['EXPIRED'] -eq 0 -and $sv2.StatusCounts['MANUAL_OVERRIDE'] -eq 0) `
    "CURRENT=$($sv2.StatusCounts['CURRENT']) NEEDS_REVIEW=$($sv2.StatusCounts['NEEDS_REVIEW']) EXPIRED=$($sv2.StatusCounts['EXPIRED']) MO=$($sv2.StatusCounts['MANUAL_OVERRIDE'])"
$dsOff = Get-AiPriceAt -Catalogue $seed.Pricing -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -TimestampUtc '2026-08-31T00:30:00Z'
Assert-True "seed: deepseek flash OFF_PEAK 0.22/0.66" `
    ($dsOff.LookupState -eq 'FOUND' -and $dsOff.Record.InputPricePerMillion -eq 0.22 -and $dsOff.Record.OutputPricePerMillion -eq 0.66) `
    "state=$($dsOff.LookupState) in=$($dsOff.Record.InputPricePerMillion) out=$($dsOff.Record.OutputPricePerMillion)"
$dsPk = Get-AiPriceAt -Catalogue $seed.Pricing -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -TimestampUtc '2026-08-31T08:00:00Z'
Assert-True "seed: deepseek flash PEAK 0.44/1.32" `
    ($dsPk.LookupState -eq 'FOUND' -and $dsPk.Record.InputPricePerMillion -eq 0.44 -and $dsPk.Record.OutputPricePerMillion -eq 1.32) `
    "state=$($dsPk.LookupState) in=$($dsPk.Record.InputPricePerMillion) out=$($dsPk.Record.OutputPricePerMillion)"
$sonStd = Get-AiPriceAt -Catalogue $seed.Pricing -ProviderId 'anthropic' -ModelId 'claude-sonnet-5' -TimestampUtc '2026-08-31T12:00:00Z'
Assert-True "seed: sonnet-5 STANDARD 2.0/0.2/2.5/4.0/10.0" `
    ($sonStd.LookupState -eq 'FOUND' -and $sonStd.Record.InputPricePerMillion -eq 2.0 -and $sonStd.Record.CachedInputPricePerMillion -eq 0.2 -and $sonStd.Record.CacheWrite5mPricePerMillion -eq 2.5 -and $sonStd.Record.CacheWrite1hPricePerMillion -eq 4.0 -and $sonStd.Record.OutputPricePerMillion -eq 10.0) `
    "state=$($sonStd.LookupState)"
$sonBt = Get-AiPriceAt -Catalogue $seed.Pricing -ProviderId 'anthropic' -ModelId 'claude-sonnet-5' -ProcessingTier 'BATCH' -TimestampUtc '2026-08-31T12:00:00Z'
Assert-True "seed: sonnet-5 BATCH tier 1.0/5.0 (standard not overwritten)" `
    ($sonBt.LookupState -eq 'FOUND' -and $sonBt.Record.InputPricePerMillion -eq 1.0 -and $sonBt.Record.OutputPricePerMillion -eq 5.0) `
    "state=$($sonBt.LookupState) in=$($sonBt.Record.InputPricePerMillion) out=$($sonBt.Record.OutputPricePerMillion)"
$gem = Get-AiPriceAt -Catalogue $seed.Pricing -ProviderId 'gemini' -ModelId 'gemini-economical' -ProcessingTier 'FLEX' -TimestampUtc '2026-08-31T12:00:00Z'
Assert-True "seed: gemini economical FLEX 0.375/1.875 effective in-window" `
    ($gem.LookupState -eq 'FOUND' -and $gem.Record.InputPricePerMillion -eq 0.375 -and $gem.Record.OutputPricePerMillion -eq 1.875) `
    "state=$($gem.LookupState) in=$($gem.Record.InputPricePerMillion) out=$($gem.Record.OutputPricePerMillion)"
$gemExp = Get-AiPriceAt -Catalogue $seed.Pricing -ProviderId 'gemini' -ModelId 'gemini-economical' -ProcessingTier 'FLEX' -TimestampUtc '2027-03-01T12:00:00Z'
Assert-True "seed: gemini expired after 2026-12-31 window (EXPIRED)" `
    ($gemExp.LookupState -eq 'EXPIRED' -and $gemExp.IsExpired) "state=$($gemExp.LookupState)"

Write-Output "--- L. no-network / zero-paid-call scan of DB-M15 pricing libraries ---"
$libFiles = @(
    (Join-Path $PSScriptRoot "AiPricingContracts.ps1"),
    (Join-Path $PSScriptRoot "AiPricingTimeBands.ps1"),
    (Join-Path $PSScriptRoot "PricingCatalogue.ps1"),
    (Join-Path $PSScriptRoot "AiRoutingPricingFoundation.ps1")
)
$netPattern = 'Invoke-RestMethod|Invoke-WebRequest|WebRequest|HttpClient|System\.Net|Net\.Http|DownloadString|WebClient|IRestMethod'
$netHits = @()
foreach ($f in $libFiles) {
    if (Test-Path $f) {
        $m = Select-String -Path $f -Pattern $netPattern
        foreach ($x in @($m)) { $netHits += ("{0}:{1}: {2}" -f (Split-Path $f -Leaf), $x.LineNumber, $x.Line.Trim()) }
    } else {
        $netHits += "MISSING FILE: $f"
    }
}
Assert-True "DB-M15 pricing libraries contain no network/HTTP call" ($netHits.Count -eq 0) ("hits: " + ($netHits -join ' | '))

# --- summary -------------------------------------------------------------------
$pass = @($script:Results | Where-Object { $_.Pass }).Count
$total = $script:Results.Count
Write-Output ""
Write-Output ("DB-M15 TEST SUMMARY: {0} passed, {1} failed (of {2})" -f $pass, $script:Fails.Count, $total)
Write-Output "DB-M15 TEST: zero paid API calls; zero network calls; zero credentials read."
if ($script:Fails.Count -gt 0) {
    Write-Output "FAILED:"
    foreach ($f in $script:Fails) { Write-Output "  - $f" }
    exit 1
}
exit 0

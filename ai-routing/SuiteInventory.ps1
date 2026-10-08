# NEXUS V3 - W7F.2 TASK 3 (AI Head half) - read a child suite's DECLARED inventory.
#
# WHY THIS EXISTS. Two suites in this tree asserted a literal number of assertions that a
# SIBLING suite happened to produce:
#
#     DBM28 S39   Assert-Equal $r.Passed 381 'S39: DB-M26 suite still 381 passed'
#     DBM29       Assert-Equal $r26.Passed 381 'REGRESSION DBM26: still 381 passed'
#
# DB-M26 has not reported 381 assertions since the AI Head migration. Measured on this device at
# one commit it reports 359. Both assertions were therefore red, and neither could say why: a
# pinned number reports a size, never a cause, and "DB-M26 changed size" and "DB-M26 broke" are
# indistinguishable in `expected='381' actual='359'`.
#
# The fix is not a better number. DB-M26 declares its inventory in its own source and reports that
# count when it runs, so a caller can derive the expectation from the child and assert the thing
# that actually matters: THAT THE CHILD RAN THE INVENTORY IT DECLARES. That statement survives a
# scenario being added or removed, and it goes red when a scenario silently stops running --
# which is the failure a pinned count was reaching for and could not catch.
#
# The same mechanism, with the same semantics, lives in Forge at
# DevBridge/scripts/SuiteInventory.ps1. It is duplicated rather than shared because the two
# repositories are separate deliverables with no common build and no common package; a shared
# module would be a new cross-repository dependency created to save forty lines.

Set-StrictMode -Version Latest

function Get-ChildSuiteDeclaration {
    <#
    .SYNOPSIS
    Read a child suite's declared inventory from its own source.

    .DESCRIPTION
    Three declaration shapes exist in this tree, because three suites were written three ways:

      ScenarioList   $script:Scenarios = @( 'Test-A', 'Test-B', ... )
      CheckCalls     one `Assert-True '<name>' '<group>' ...` per check
      ScenarioTable  @{ Id = '<id>'; ... } inside Get-DbM32ScenarioTable

    .PARAMETER Path
    Full path to the child suite.

    .PARAMETER Kind
    Which declaration shape that suite uses.

    .OUTPUTS
    The declared names, in source order.

    .NOTES
    A missing suite, an unreadable declaration, an empty declaration or a duplicate name THROWS.
    Each of those makes the caller's assertion meaningless rather than false, and a caller that
    silently gets an empty list asserts nothing while reporting success -- which is a worse
    outcome than any number this replaces.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('ScenarioList', 'CheckCalls', 'ScenarioTable')][string]$Kind
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        # Parenthesised BEFORE -f. `"a" + "b" -f $x, $y` binds -f to the last concatenated segment
        # alone and emits a message still containing {0}/{1} -- an unreadable diagnostic is how a
        # real failure gets dismissed.
        throw (("SuiteInventory: the child suite '{0}' does not exist, so its declared {1} " +
                "inventory cannot be read. A missing suite must fail the caller's assertions, " +
                "not silently shrink them.") -f $Path, $Kind)
    }

    $text = [System.IO.File]::ReadAllText($Path)
    # Comment lines are stripped before counting. A commented-out example would otherwise be
    # counted as a check that runs, and the caller's declared-vs-reported comparison would fail on
    # a declaration that is not one.
    $code = (@($text -split "\r?\n" | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n")

    $names = New-Object System.Collections.Generic.List[string]

    if ($Kind -eq 'ScenarioList') {
        $block = [regex]::Match($code, '(?s)\$script:Scenarios\s*=\s*@\((.*?)\)\s*\r?\n')
        if (-not $block.Success) {
            throw ("SuiteInventory: '{0}' declares no `$script:Scenarios block, so its scenario " +
                   "inventory cannot be derived.") -f $Path
        }
        foreach ($q in [regex]::Matches($block.Groups[1].Value, "'([^']+)'")) { $names.Add($q.Groups[1].Value) }
    }
    elseif ($Kind -eq 'CheckCalls') {
        foreach ($q in [regex]::Matches($code, "Assert-True\s+'([^']+)'")) { $names.Add($q.Groups[1].Value) }
    }
    else {
        $body = [regex]::Match($code, '(?s)function Get-DbM32ScenarioTable\s*\{.*?return\s*@\((.*?)\n\s*\)\s*\r?\n\}')
        if (-not $body.Success) {
            throw ("SuiteInventory: '{0}' declares no Get-DbM32ScenarioTable body, so its scenario " +
                   "table cannot be derived.") -f $Path
        }
        foreach ($q in [regex]::Matches($body.Groups[1].Value, "@\{\s*Id\s*=\s*'([^']+)'")) { $names.Add($q.Groups[1].Value) }
    }

    if ($names.Count -eq 0) {
        throw (("SuiteInventory: '{0}' declares an EMPTY {1} inventory. A suite that declares " +
                "nothing cannot be regression-tested; the caller would assert nothing while " +
                "reporting success.") -f $Path, $Kind)
    }

    $dupes = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupes.Count -gt 0) {
        throw (("SuiteInventory: '{0}' declares {1} duplicate name(s) ({2}). A duplicate means " +
                "the declared count overstates coverage.") -f $Path, $dupes.Count, ($dupes -join ', '))
    }

    return $names.ToArray()
}

function Get-ChildSuiteReportedCount {
    <#
    .SYNOPSIS
    Read the inventory count a child suite REPORTED when it ran.

    .DESCRIPTION
    Pairs with Get-ChildSuiteDeclaration: the declaration says what should have run, this says what
    the child says ran. Agreement between the two is the property worth asserting, and a
    disagreement names both numbers so the cause is readable.

    .PARAMETER Log
    The child suite's captured output.

    .PARAMETER Pattern
    A regex with ONE capture group holding the count, e.g.
    'DB-M26 SCENARIOS:\s*(\d+)\s+scenarios'.

    .PARAMETER SuiteName
    Used only to build the failure message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Log,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$SuiteName
    )

    $m = [regex]::Match($Log, $Pattern)
    if (-not $m.Success) {
        throw (("SuiteInventory: '{0}' reported no inventory count matching '{1}'. A child that " +
                "does not report its inventory cannot be checked against its declaration.") -f
                $SuiteName, $Pattern)
    }
    return [int]$m.Groups[1].Value
}

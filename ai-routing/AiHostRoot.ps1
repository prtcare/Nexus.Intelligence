# =============================================================================
# AI HOST ROOT -- the Forge development host the AI material used to live inside.
# =============================================================================
#
# W6/LaneA moved the AI implementation out of Forge into this repository. Four
# things did NOT move with it, because none of them is AI implementation:
#
#   * the operator console source   Forge: src\DevBridge.UI
#   * the Forge solution            Forge: src\DevBridge.slnx
#   * DB-M18.1 dependency lineage   Forge: scripts\ai-routing\DependencyLineage.ps1
#                                   and its suite Test-DbM181DependencyLineage.ps1
#   * the governed task state       Forge: state\current-task.json, preflight.json
#
# Verification suites in this repository still assert properties of those: that the
# AI suite did not mutate the console, that the solution still builds, that the
# Forge-side dependency suite is still green, that the governed node is the live
# one. Those are CROSS-TREE assertions, and before the move they were implicit in a
# single $script:Root that spanned both trees. That root no longer exists.
#
# So the host root is resolved EXPLICITLY:
#
#   1. an explicit -ForgeRoot argument,
#   2. else $env:NEXUS_FORGE_DEVBRIDGE_ROOT,
#   3. else $null.
#
# There is NO sibling discovery and NO tree walk. A suite that cannot see the host
# reports its cross-tree assertions as explicit SKIPs -- never a silent pass, and
# never a guessed path that happens to resolve into the wrong tree.
#
# This mirrors Resolve-AiHeadRoot, the contract Forge uses to reach this repository.

function Resolve-ForgeHostRoot {
    <#
    .SYNOPSIS
    The Forge DevBridge project root, or $null when it is not explicitly declared.
    .DESCRIPTION
    Never guessed. See the header for why the cross-tree assertions exist and what a
    $null result obliges a caller to do (report a SKIP, not a pass).
    #>
    param([string]$ForgeRoot)

    if (-not [string]::IsNullOrWhiteSpace($ForgeRoot)) {
        if (Test-Path -LiteralPath $ForgeRoot) { return (Resolve-Path -LiteralPath $ForgeRoot).Path }
        return $null
    }
    $fromEnv = [System.Environment]::GetEnvironmentVariable('NEXUS_FORGE_DEVBRIDGE_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($fromEnv) -and (Test-Path -LiteralPath $fromEnv)) {
        return (Resolve-Path -LiteralPath $fromEnv).Path
    }
    return $null
}

function Test-ForgeHostResolved {
    <#
    .SYNOPSIS
    True when a Forge host root is available, so cross-tree assertions may run.
    #>
    param([string]$ForgeRoot)
    return ($null -ne (Resolve-ForgeHostRoot -ForgeRoot $ForgeRoot))
}

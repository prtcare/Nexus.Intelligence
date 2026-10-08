# EscalationExport.ps1 -- DB-M20 decision export (a pure report artifact).
#
# DB-M20 is a DECISION ENGINE. Export-AiEscalationDecision serializes a decision
# to a DB-M20-owned JSON report file. It NEVER executes the decision, never makes
# an AI/paid/network call and never touches a live task handoff artifact.
#
# Temporary DevBridge boundary (asserted here): the report may only be written
# inside the project root and NEVER under a Nexus-owned path (e.g.
# C:\Personal\Nexus.Developer) nor onto a live handoff artifact. Any other path
# is refused.

. (Join-Path $PSScriptRoot "EscalationContracts.ps1")

function Get-DbM20DevBridgeRoot {
    <#
    .SYNOPSIS
    The project root that DB-M20 export artifacts belong to, derived from this
    file's location: ai-routing\escalation\ -> <project root>.

    W6/LaneA moved the AI material from Forge's DevBridge\scripts\ai-routing\ to
    this repository's ai-routing\ -- one level shallower. The root this file
    belongs to is therefore the AI material root, two levels up, not three.
    #>
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

# Nexus-owned governance roots. The boundary below exists to keep DB-M20 exports
# out of the Nexus governance tree (roadmap / control workbook), never to keep
# them out of a path that merely spells 'nexus'. The two are not the same: this
# project lives under D:\Nexus\, so a substring test on 'nexus' refuses every
# legitimate DB-M20 export target -- including the default one. Ownership is
# therefore anchored on the governance locations themselves.
$script:DbM20NexusGovernanceRoots = @(
    'C:\Personal\Nexus.Developer'
)

function Test-DbM20NexusOwnedPath {
    <#
    .SYNOPSIS
    True when the FULL path is inside a Nexus governance root.
    #>
    param([string]$FullPath)
    foreach ($g in $script:DbM20NexusGovernanceRoots) {
        $gf = [System.IO.Path]::GetFullPath($g)
        if ($FullPath.Equals($gf, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($FullPath.StartsWith($gf + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-DbM20ExportPathAllowed {
    <#
    .SYNOPSIS
    Refuse any export target outside the DevBridge root, under a Nexus-owned
    location, or on a live handoff artifact. Returns @{ Allowed; Reason; Path }.
    #>
    param([string]$OutputPath)
    if (-not $OutputPath) { return @{ Allowed = $false; Reason = 'no output path supplied'; Path = $null } }

    $full = [System.IO.Path]::GetFullPath($OutputPath)
    $root = Get-DbM20DevBridgeRoot
    $rootFull = [System.IO.Path]::GetFullPath($root)

    # Nexus ownership is tested FIRST, so a Nexus-governance target is refused for
    # being Nexus-owned even though it is also outside the project root. The two
    # refusals are different rules and are not interchangeable.
    if (Test-DbM20NexusOwnedPath $full) {
        return @{ Allowed = $false; Reason = "export target '$full' is under a Nexus-owned path; DB-M20 never writes Nexus files (roadmap/workbook protection)"; Path = $full }
    }
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ Allowed = $false; Reason = "export target '$full' is outside the project root '$rootFull' (Temporary DevBridge boundary)"; Path = $full }
    }
    $fileName = [System.IO.Path]::GetFileName($full)
    if ($fileName -eq 'db-m20-result.json') {
        # the milestone result file has a fixed, engine-owned location; a decision
        # export is never written over it.
        return @{ Allowed = $false; Reason = "'db-m20-result.json' is the milestone result file; a decision export must use a separate DB-M20-owned path"; Path = $full }
    }
    if ($fileName -match '(?i)(handoff|ROUTING_RECOMMENDATION|TASK_HANDOFF)') {
        return @{ Allowed = $false; Reason = "export target '$full' is a live task handoff artifact; DB-M20 never modifies live handoff artifacts"; Path = $full }
    }
    return @{ Allowed = $true; Reason = "export target '$full' is inside the DevBridge root and is DB-M20-owned"; Path = $full }
}

function Export-AiEscalationDecision {
    <#
    .SYNOPSIS
    Serialize an EscalationDecision v1 to a DB-M20-owned JSON report file.
    The decision is validated first; an invalid decision is never exported.
    Returns @{ Exported; Path; DecisionId; Warnings }.
    #>
    param(
        [AllowNull()][pscustomobject]$Decision,
        [string]$OutputPath,
        [switch]$Force
    )
    if ($null -eq $Decision) { throw 'Export-AiEscalationDecision: Decision is required' }
    $v = Test-EscalationDecision $Decision
    if (-not $v.Valid) { throw "Export-AiEscalationDecision: refusing to export an invalid decision: $($v.Errors -join '; ')" }

    $decisionId = [string](Get-ContractProperty $Decision 'DecisionId' 'decision')
    $path = $OutputPath
    if (-not $path) {
        $root = Get-DbM20DevBridgeRoot
        $dir = Join-Path (Join-Path $root 'state') 'ai-routing-escalation-decisions'
        $path = Join-Path $dir "$decisionId.json"
    }

    $check = Test-DbM20ExportPathAllowed $path
    if (-not $check.Allowed) { throw "Export-AiEscalationDecision: $($check.Reason)" }

    $full = [System.IO.Path]::GetFullPath($check.Path)
    if ((Test-Path -LiteralPath $full) -and -not $Force) {
        throw "Export-AiEscalationDecision: '$full' already exists; use -Force to overwrite (DB-M20 decisions are append-only by default)"
    }

    $json = $Decision | ConvertTo-Json -Depth 12
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [System.IO.File]::WriteAllText($full, $json, (New-Object System.Text.UTF8Encoding($false)))

    return @{ Exported = $true; Path = $full; DecisionId = $decisionId; Warnings = @() }
}

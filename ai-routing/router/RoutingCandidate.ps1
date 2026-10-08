# RoutingCandidate.ps1 -- DB-M19 candidate + routing-decision-evidence contracts.
#
# RoutingCandidate v1: a single model route evaluated by the router. A candidate
# is either ELIGIBLE (passed hard constraints) or REJECTED (with the structured
# rejection reasons that caused the failure -- vocabulary members, never free text).
# Every candidate exposes the evidence the recommendation explains: capability
# fit, context fit, cost estimate, performance evidence and the policy score
# components -- never an opaque "Score=83.7".
#
# RoutingDecisionEvidence v1: the DB-M19-owned companion to the DB-M14 v1
# RoutingDecision. The DB-M14 contract stays frozen (additive-compatible only);
# the companion carries the router-specific detail the brief requires:
# EligibleCandidates + RejectedCandidates (each with full evidence),
# RecommendationReason, ManualOverride, ContextPackageId/hash, PricingRecordId,
# PerformanceEvidenceReference.
#
# ADR-005: identifiers are data, never compared to provider/model literals.

. (Join-Path $PSScriptRoot "..\AiRoutingContracts.ps1")   # DB-M14 vocab + helpers (READ-ONLY)

# -----------------------------------------------------------------------------
# RoutingCandidate v1
# -----------------------------------------------------------------------------
function New-RoutingCandidate {
    <#
    .SYNOPSIS
    Build a RoutingCandidate v1 from a field table (all fields optional; unknown
    stays null). Status is 'ELIGIBLE' or 'REJECTED'.
    #>
    param(
        [AllowNull()][hashtable]$Fields
    )
    $f = if ($null -eq $Fields) { @{} } else { $Fields }
    $status = if ($f.ContainsKey('Status')) { [string]$f['Status'] } else { 'REJECTED' }
    if ($status -ne 'ELIGIBLE' -and $status -ne 'REJECTED') { throw "New-RoutingCandidate: Status must be ELIGIBLE or REJECTED (found '$status')" }

    $candidate = [pscustomobject]@{
        SchemaVersion             = 1
        Status                    = $status
        # --- route identity ---------------------------------------------------
        ProviderId                = if ($f.ContainsKey('ProviderId')) { $f['ProviderId'] } else { $null }
        ModelId                   = if ($f.ContainsKey('ModelId')) { $f['ModelId'] } else { $null }
        UnderlyingModelId         = if ($f.ContainsKey('UnderlyingModelId')) { $f['UnderlyingModelId'] } else { $null }
        GatewayProviderId         = if ($f.ContainsKey('GatewayProviderId')) { $f['GatewayProviderId'] } else { $null }
        DisplayName               = if ($f.ContainsKey('DisplayName')) { $f['DisplayName'] } else { $null }
        LocalOrRemote             = if ($f.ContainsKey('LocalOrRemote')) { $f['LocalOrRemote'] } else { $null }
        RelativeSpeed             = if ($f.ContainsKey('RelativeSpeed')) { $f['RelativeSpeed'] } else { $null }
        ReliabilityClass          = if ($f.ContainsKey('ReliabilityClass')) { $f['ReliabilityClass'] } else { $null }
        ReasoningLevelsSupported  = if ($f.ContainsKey('ReasoningLevelsSupported')) { @($f['ReasoningLevelsSupported']) } else { @() }
        ContextWindow             = if ($f.ContainsKey('ContextWindow')) { $f['ContextWindow'] } else { $null }
        MaxOutputTokens           = if ($f.ContainsKey('MaxOutputTokens')) { $f['MaxOutputTokens'] } else { $null }
        # --- selection --------------------------------------------------------
        SelectedReasoningLevel    = if ($f.ContainsKey('SelectedReasoningLevel')) { $f['SelectedReasoningLevel'] } else { $null }
        # --- rejection evidence (REJECTED) -------------------------------------
        RejectionReasons          = if ($f.ContainsKey('RejectionReasons')) { @($f['RejectionReasons']) } else { @() }
        # --- context fit -------------------------------------------------------
        ContextFit               = if ($f.ContainsKey('ContextFit')) { $f['ContextFit'] } else { $null }
        # --- cost evidence -----------------------------------------------------
        CostEstimate             = if ($f.ContainsKey('CostEstimate')) { $f['CostEstimate'] } else { $null }
        EstimatedCost            = if ($f.ContainsKey('EstimatedCost')) { $f['EstimatedCost'] } else { $null }
        CostCurrency             = if ($f.ContainsKey('CostCurrency')) { $f['CostCurrency'] } else { $null }
        CostUnknown              = if ($f.ContainsKey('CostUnknown')) { $f['CostUnknown'] } else { $null }
        PricingRecordId          = if ($f.ContainsKey('PricingRecordId')) { $f['PricingRecordId'] } else { $null }
        # --- performance evidence ----------------------------------------------
        PerformanceEvidence      = if ($f.ContainsKey('PerformanceEvidence')) { $f['PerformanceEvidence'] } else { $null }
        PerformanceEvidenceReference = if ($f.ContainsKey('PerformanceEvidenceReference')) { $f['PerformanceEvidenceReference'] } else { $null }
        # --- ranking ------------------------------------------------------------
        ComponentScores          = if ($f.ContainsKey('ComponentScores')) { $f['ComponentScores'] } else { $null }
        PolicyScore              = if ($f.ContainsKey('PolicyScore')) { $f['PolicyScore'] } else { $null }
        Selectable               = if ($f.ContainsKey('Selectable')) { $f['Selectable'] } else { $null }
        Rank                     = if ($f.ContainsKey('Rank')) { $f['Rank'] } else { $null }
    }
    return $candidate
}

function Test-RoutingCandidate {
    <#
    .SYNOPSIS
    Structural validation of a RoutingCandidate v1. Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Candidate)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Candidate) { return @{ Valid = $false; Errors = @('Candidate is null'); Warnings = @() } }
    if ((Get-ContractProperty $Candidate 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    $status = [string](Get-ContractProperty $Candidate 'Status' '')
    if ($status -notin @('ELIGIBLE','REJECTED')) { $errors.Add("Status '$status' invalid") }
    if (-not (Get-ContractProperty $Candidate 'ModelId' '')) { $errors.Add('ModelId is required') }
    if (-not (Get-ContractProperty $Candidate 'ProviderId' '')) { $errors.Add('ProviderId is required') }
    if ($status -eq 'REJECTED') {
        $reasons = @(Get-ContractProperty $Candidate 'RejectionReasons' @())
        if ($reasons.Count -eq 0) { $errors.Add('REJECTED candidate must carry at least one RejectionReason') }
        foreach ($reason in $reasons) {
            if (([string]$reason) -notin (Get-DbM19RejectionReasons)) {
                $errors.Add("RejectionReason '$reason' not in the DB-M19 rejection vocabulary")
            }
        }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

# -----------------------------------------------------------------------------
# RoutingDecisionEvidence v1 (DB-M19-owned companion to DB-M14 RoutingDecision v1)
# -----------------------------------------------------------------------------
function New-RoutingDecisionEvidence {
    <#
    .SYNOPSIS
    Build a RoutingDecisionEvidence v1 from a field table. The DB-M14
    New-AiRoutingDecision stays frozen; this companion carries router-specific
    detail. All fields optional (unknown stays null).
    #>
    param(
        [AllowNull()][hashtable]$Fields
    )
    $f = if ($null -eq $Fields) { @{} } else { $Fields }
    return [pscustomobject]@{
        SchemaVersion        = 1
        RoutingRequestId     = if ($f.ContainsKey('RoutingRequestId')) { $f['RoutingRequestId'] } else { $null }
        TaskId               = if ($f.ContainsKey('TaskId')) { $f['TaskId'] } else { $null }
        WorkUniverse         = if ($f.ContainsKey('WorkUniverse')) { $f['WorkUniverse'] } else { $null }
        NodeAddress          = if ($f.ContainsKey('NodeAddress')) { $f['NodeAddress'] } else { $null }
        Status               = if ($f.ContainsKey('Status')) { $f['Status'] } else { $null }
        Policy               = if ($f.ContainsKey('Policy')) { $f['Policy'] } else { $null }
        EligibleCandidates   = if ($f.ContainsKey('EligibleCandidates')) { @($f['EligibleCandidates']) } else { @() }
        RejectedCandidates   = if ($f.ContainsKey('RejectedCandidates')) { @($f['RejectedCandidates']) } else { @() }
        RecommendationReason = if ($f.ContainsKey('RecommendationReason')) { $f['RecommendationReason'] } else { $null }
        ManualOverride       = if ($f.ContainsKey('ManualOverride')) { $f['ManualOverride'] } else { $null }
        DecisionTimestampUtc = if ($f.ContainsKey('DecisionTimestampUtc')) { $f['DecisionTimestampUtc'] } else { $null }
        ContextPackageId     = if ($f.ContainsKey('ContextPackageId')) { $f['ContextPackageId'] } else { $null }
        ContextPackageHash   = if ($f.ContainsKey('ContextPackageHash')) { $f['ContextPackageHash'] } else { $null }
        PricingRecordId      = if ($f.ContainsKey('PricingRecordId')) { $f['PricingRecordId'] } else { $null }
        PerformanceEvidenceReference = if ($f.ContainsKey('PerformanceEvidenceReference')) { $f['PerformanceEvidenceReference'] } else { $null }
        Mode                 = if ($f.ContainsKey('Mode')) { $f['Mode'] } else { $null }
        TargetCurrency       = if ($f.ContainsKey('TargetCurrency')) { $f['TargetCurrency'] } else { $null }
        ProcessingTier       = if ($f.ContainsKey('ProcessingTier')) { $f['ProcessingTier'] } else { $null }
        TimeBand             = if ($f.ContainsKey('TimeBand')) { $f['TimeBand'] } else { $null }
        ManualOverrideReason = if ($f.ContainsKey('ManualOverrideReason')) { $f['ManualOverrideReason'] } else { $null }
        Notes                = if ($f.ContainsKey('Notes')) { $f['Notes'] } else { $null }
    }
}

function Test-RoutingDecisionEvidence {
    <#
    .SYNOPSIS
    Structural validation of RoutingDecisionEvidence v1. Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Evidence)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Evidence) { return @{ Valid = $false; Errors = @('Evidence is null'); Warnings = @() } }
    if ((Get-ContractProperty $Evidence 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    if (-not (Get-ContractProperty $Evidence 'TaskId' '')) { $errors.Add('TaskId is required') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

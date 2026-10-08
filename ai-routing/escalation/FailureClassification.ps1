# FailureClassification.ps1 -- DB-M20 failure classification.
#
# DB-M20 is a DECISION ENGINE (no execution, no paid API calls, no autonomous
# Nexus changes). This layer maps the DB-M17 recorded failure categories (read
# through AttemptStore.ps1, never modified) plus the escalation-time signals
# (verification result, Claude review status) into the DB-M20 escalation-facing
# failure-category vocabulary, which is a strict superset.
#
# Classification is deterministic and NEVER guesses: an unknown recorded
# category is surfaced as UNKNOWN_FAILURE and handled conservatively by the
# engine (never escalated to a bigger model). Verification is authoritative:
# a self-reported SUCCESS whose independent verification FAILED is classified as
# VERIFICATION_FAILURE (self-reported PASS is not success).

. (Join-Path $PSScriptRoot "EscalationPolicy.ps1")
. (Join-Path $PSScriptRoot "..\AttemptStore.ps1")   # DB-M17 recorded categories (READ-ONLY)

# -----------------------------------------------------------------------------
# DB-M17 -> DB-M20 recorded-category mapping (deterministic)
# -----------------------------------------------------------------------------
function Get-DbM17ToDbM20FailureMap {
    <#
    .SYNOPSIS
    The deterministic mapping from the DB-M17 recorded failure-category
    vocabulary (Get-AiAttemptFailureCategories) to the DB-M20 escalation
    vocabulary. Categories shared verbatim are not listed here (identity
    mapping). CONTEXT_FAILURE is DB-M17's single context category; DB-M20
    distinguishes CONTEXT_TOO_LARGE / CONTEXT_INSUFFICIENT, so the conservative
    default is CONTEXT_TOO_LARGE (the common window-exceeded case) and the
    DB-M20-specific CONTEXT_INSUFFICIENT arrives via an explicit escalation
    signal. VALIDATION_FAILURE means the produced artifact failed validation =
    a verification failure. BUDGET_FAILURE is a stop condition (class BUDGET),
    not an escalation category -- it never escalates to a model.
    #>
    return @{
        'CONTEXT_FAILURE'    = 'CONTEXT_TOO_LARGE'
        'VALIDATION_FAILURE' = 'VERIFICATION_FAILURE'
        'BUDGET_FAILURE'     = 'UNKNOWN_FAILURE'   # + BudgetStop = $true (see Get-AiFailureCategory)
        'UNKNOWN'            = 'UNKNOWN_FAILURE'
    }
}

function Get-AiFailureCategory {
    <#
    .SYNOPSIS
    Classify the failed attempt's failure into the DB-M20 escalation vocabulary.
    Inputs (all optional; at least one classification input is required):
      -RecordedFailureCategory : a DB-M17 AiAttemptRecord.FailureCategory value
      -FailureCategory         : an explicit DB-M20 escalation category
      -VerificationResult      : VERIFIED / FAILED / PENDING (DB-M17 vocabulary)
      -ClaudeReviewStatus      : NONE / PENDING / PASS / FIX_REQUIRED
    Precedence (verification is authoritative): explicit DB-M20 category wins;
    then a Claude-review FIX_REQUIRED signal becomes CLAUDE_REVIEW_FIX; then a
    FAILED verification becomes VERIFICATION_FAILURE; then the recorded category
    (mapped when needed). Governance / authentication / budget conditions are
    never overridden by quality signals.
    Returns @{ Category; Class; Mapped; MappedFrom; BudgetStop; Reason }.
    #>
    param(
        [string]$RecordedFailureCategory,
        [string]$FailureCategory,
        [string]$VerificationResult,
        [string]$ClaudeReviewStatus
    )

    $budgetStop = $false

    # --- validate explicit DB-M20 category ------------------------------------
    if ($FailureCategory) {
        if (-not (Test-IsValidDbM20FailureCategory $FailureCategory)) {
            throw "Get-AiFailureCategory: '$FailureCategory' is not a DB-M20 escalation failure category"
        }
        if ($FailureCategory -in @('SCOPE_CHANGE_REQUIRED','GOVERNANCE_BLOCKED','HUMAN_GIT_GATE','PR_PENDING','MERGE_PENDING','ARCHITECTURE_CONFLICT')) {
            # explicit non-AI categories are authoritative
            $mappedFrom = $RecordedFailureCategory
            $mapped = -not ([string]::IsNullOrWhiteSpace($mappedFrom))
            return @{
                Category    = $FailureCategory
                Class       = Get-DbM20FailureClassForCategory $FailureCategory
                Mapped      = $mapped
                MappedFrom  = $mappedFrom
                BudgetStop  = $false
                Reason      = "explicit DB-M20 category '$FailureCategory'"
            }
        }
    }

    # --- resolve the base category --------------------------------------------
    $base = $null
    $mappedFrom = $null
    $mapped = $false
    if ($FailureCategory) {
        $base = $FailureCategory
    } elseif ($RecordedFailureCategory) {
        $recordedVocab = @(Get-AiAttemptFailureCategories)
        if ($RecordedFailureCategory -in $recordedVocab) {
            $map = Get-DbM17ToDbM20FailureMap
            if ($map.ContainsKey($RecordedFailureCategory)) {
                $mappedFrom = $RecordedFailureCategory
                $mapped = $true
                $base = $map[$RecordedFailureCategory]
                if ($RecordedFailureCategory -eq 'BUDGET_FAILURE') { $budgetStop = $true }
            } else {
                # shared verbatim (MODEL_QUALITY, PROVIDER_AVAILABILITY, RATE_LIMIT,
                # AUTHENTICATION, TOOL_FAILURE, BUILD_FAILURE, TEST_FAILURE, UNKNOWN)
                $base = $RecordedFailureCategory
            }
        } else {
            # not a valid DB-M17 category and not a valid DB-M20 category -> never guess
            throw "Get-AiFailureCategory: '$RecordedFailureCategory' is neither a DB-M17 recorded category nor a DB-M20 escalation category"
        }
    } else {
        # no category supplied: classify from the verification / Claude-review
        # signals alone (verification is authoritative; never guesses otherwise).
        if ($ClaudeReviewStatus -eq 'FIX_REQUIRED') {
            return @{
                Category    = 'CLAUDE_REVIEW_FIX'
                Class       = Get-DbM20FailureClassForCategory 'CLAUDE_REVIEW_FIX'
                Mapped      = $false
                MappedFrom  = $null
                BudgetStop  = $false
                Reason      = 'Claude review requires a fix (signal-only classification)'
            }
        }
        if ($VerificationResult -eq 'FAILED') {
            return @{
                Category    = 'VERIFICATION_FAILURE'
                Class       = Get-DbM20FailureClassForCategory 'VERIFICATION_FAILURE'
                Mapped      = $false
                MappedFrom  = $null
                BudgetStop  = $false
                Reason      = 'independent verification failed (signal-only; self-reported PASS is not success)'
            }
        }
        throw "Get-AiFailureCategory: at least one of -RecordedFailureCategory or -FailureCategory (or a FAILED verification / FIX_REQUIRED review signal) is required"
    }

    # --- governance / authentication / budget are never overridden -------------
    $class = Get-DbM20FailureClassForCategory $base
    if ($class -in @('GOVERNANCE', 'AUTHENTICATION', 'BUDGET')) {
        return @{
            Category    = $base
            Class       = $class
            Mapped      = $mapped
            MappedFrom  = $mappedFrom
            BudgetStop  = $budgetStop
            Reason      = if ($mapped) { "recorded '$mappedFrom' mapped to '$base'" } else { "category '$base'" }
        }
    }

    # --- verification / Claude-review signals (authoritative over quality) ------
    $effective = $base
    $signalReason = $null
    if ($ClaudeReviewStatus -eq 'FIX_REQUIRED') {
        $effective = 'CLAUDE_REVIEW_FIX'
        $signalReason = "Claude review requires a fix"
    } elseif ($VerificationResult -eq 'FAILED') {
        $effective = 'VERIFICATION_FAILURE'
        $signalReason = 'independent verification failed (self-reported PASS is not success)'
    }
    if ($effective -ne $base) {
        return @{
            Category    = $effective
            Class       = Get-DbM20FailureClassForCategory $effective
            Mapped      = $mapped
            MappedFrom  = if ($mapped) { $mappedFrom } else { $base }
            BudgetStop  = $budgetStop
            Reason      = "$signalReason (base '$base')"
        }
    }

    return @{
        Category    = $base
        Class       = $class
        Mapped      = $mapped
        MappedFrom  = $mappedFrom
        BudgetStop  = $budgetStop
        Reason      = if ($mapped) { "recorded '$mappedFrom' mapped to '$base'" } else { "category '$base'" }
    }
}

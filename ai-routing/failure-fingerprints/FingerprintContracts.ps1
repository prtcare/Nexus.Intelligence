# FingerprintContracts.ps1 -- DB-M21 Part B contracts, normalization + vocab.
#
# DB-M21 Part B answers "have we already seen effectively this same failure
# under effectively the same attempt conditions?" It computes a deterministic
# FailureFingerprint v1 and NEVER executes a provider/model. No paid API calls,
# no network calls, no autonomous Nexus changes. AUTO_EXECUTION_ENABLED = FALSE.
#
# The SIGNATURE is the FAILURE IDENTITY: SHA-256 over the normalized component
# string (task type, failure category, normalized failure codes, tool category).
# Same meaningful failure -> same signature, regardless of route. Route identity
# (provider/model/reasoning/gateway) and the context/prompt hashes are carried
# as STRUCTURED FIELDS and drive recurrence typing (REPEATED_SAME_ROUTE /
# REPEATED_AFTER_REASONING_ESCALATION / REPEATED_AFTER_MODEL_SWITCH / ...) and
# the retry-suppression decision -- never treated as identical.
#
# Secret protection: raw prompts/secrets are never inputs. Prompt/context are
# carried as a 64-hex ContextHash or a PromptHashReference; a secret-like value
# in any stored field rejects the fingerprint. Hash/reference only.
#
# Provider infrastructure failures (AUTHENTICATION / RATE_LIMIT /
# PROVIDER_AVAILABILITY) are part of the failure identity, so they never match
# MODEL_QUALITY fingerprints -- M24 quality history stays meaningful.
#
# Algorithm versioning: AlgorithmVersion is recorded; matching is version-scoped,
# so a v2 normalization algorithm never silently reinterprets v1 signatures.

. (Join-Path $PSScriptRoot "..\AiRoutingContracts.ps1")        # DB-M14 vocab (READ-ONLY)
. (Join-Path $PSScriptRoot "..\escalation\EscalationPolicy.ps1") # DB-M20 category vocab (READ-ONLY)

# -----------------------------------------------------------------------------
# Schema versions
# -----------------------------------------------------------------------------
function Get-DbM21FingerprintSchemaVersions {
    return [pscustomobject]@{ FailureFingerprintVersion = 1 }
}

# -----------------------------------------------------------------------------
# Primitive helpers
# -----------------------------------------------------------------------------
function Get-DbM21Sha256Hex {
    <#
    .SYNOPSIS
    SHA-256 hex digest of a UTF-8 string (deterministic hash building block).
    #>
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

# -----------------------------------------------------------------------------
# Vocabularies
# -----------------------------------------------------------------------------
function Get-DbM21RecurrenceTypes {
    <#
    .SYNOPSIS
    Recurrence types are NOT flat -- a repeated failure is typed by what changed.
    #>
    return @(
        'FIRST_OCCURRENCE',
        'REPEATED_SAME_ROUTE',
        'REPEATED_SAME_MODEL',
        'REPEATED_SAME_FAILURE',
        'REPEATED_AFTER_REASONING_ESCALATION',
        'REPEATED_AFTER_MODEL_SWITCH',
        'KNOWN_FAILURE_RESOLVED'
    )
}

function Get-DbM21RepeatSuppressionReasons {
    <#
    .SYNOPSIS
    Closed outcome vocabulary for Test-AiRepeatAttemptAllowed. The engine only
    SUPPRESSES an identical repeat (RETRY_SUPPRESSED_KNOWN_FAILURE); every other
    outcome allows the retry and leaves the replan to DB-M20.
    #>
    return @(
        'RETRY_ALLOWED_FIRST_OCCURRENCE',
        'RETRY_ALLOWED_REPEAT_WITHIN_THRESHOLD',
        'RETRY_ALLOWED_CONTEXT_CHANGED',
        'RETRY_ALLOWED_REASONING_ESCALATED',
        'RETRY_ALLOWED_MODEL_SWITCH',
        'RETRY_ALLOWED_NON_IDENTICAL_REPEAT',
        'RETRY_ALLOWED_KNOWN_FAILURE_RESOLVED',
        'RETRY_SUPPRESSED_KNOWN_FAILURE'
    )
}

function Get-DbM21ToolCategories {
    <#
    .SYNOPSIS
    Generic tool category vocabulary (build / test / verification / coding /
    runtime / provider / governance / research / other).
    #>
    return @('BUILD', 'TEST', 'VERIFICATION', 'CODING', 'RUNTIME', 'PROVIDER', 'GOVERNANCE', 'RESEARCH', 'OTHER')
}

# -----------------------------------------------------------------------------
# Normalization pipeline (fixed order, deterministic)
# -----------------------------------------------------------------------------
function Get-DbM21NormalizeFailureCode {
    <#
    .SYNOPSIS
    Normalize a single failure/error/verification code. Volatile details
    (timestamps, GUIDs, temp/user paths, and -- when allowed -- line numbers and
    retry counters) collapse to stable markers. Meaningful error-code
    differences are NEVER normalized away. The steps run in a fixed order.
    #>
    param(
        [AllowNull()][string]$Code,
        [bool]$NormalizeLineNumbers = $true
    )
    if ($null -eq $Code) { return $null }
    $s = [string]$Code
    # 1. timestamps -> <TS>
    $s = $s -replace '\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?', '<TS>'
    # 2. GUIDs -> <GUID>
    $s = $s -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<GUID>'
    # 3. temp paths -> <TMP>
    $s = $s -replace '(?i)AppData[\\/]Local[\\/]Temp[\\/]?', '<TMP>'
    $s = $s -replace '(?i)[\\/](?:Temp|tmp)[\\/]?', '<TMP>'
    # 4. absolute user-machine directory prefixes -> <USERDIR>
    $s = $s -replace '(?i)[A-Za-z]:[\\/]Users[\\/][^\\/\s]+', '<USERDIR>'
    # 5. line/column spans (12,34) / (12:34) -> (N)  (when policy allows)
    if ($NormalizeLineNumbers) {
        $s = $s -replace '\((\d+)[,:]\d+\)', '(N)'
        $s = $s -replace '(?i)(?:line|ln)\s*\d+', 'line N'
    }
    # 6. volatile retry/attempt counters -> "retry N" / "attempt N"
    $s = $s -replace '(?i)(retry|attempt)\s*#?\s*\d+', '$1 N'
    # collapse whitespace
    $s = $s -replace '[ \t\r\n]+', ' '
    return $s.Trim()
}

function Get-DbM21NormalizedFailureCodes {
    <#
    .SYNOPSIS
    Normalize an array of failure/error/verification codes, then sort and
    dedupe (deterministic canonical order). Empty/null codes are dropped.
    #>
    param(
        [AllowNull()][object[]]$Codes,
        [bool]$NormalizeLineNumbers = $true
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($c in @($Codes)) {
        if ($null -eq $c) { continue }
        $n = Get-DbM21NormalizeFailureCode -Code ([string]$c) -NormalizeLineNumbers $NormalizeLineNumbers
        if ($n) {
            $dupe = $false
            foreach ($existing in @($out)) { if ($existing -eq $n) { $dupe = $true; break } }
            if (-not $dupe) { $null = $out.Add($n) }
        }
    }
    return @($out | Sort-Object)
}

# -----------------------------------------------------------------------------
# Secret guard (DB-M21-owned; DB-M17 protection philosophy)
# -----------------------------------------------------------------------------
function Get-DbM21FingerprintSecretLeak {
    <#
    .SYNOPSIS
    Scan a FailureFingerprint v1 for secret-like VALUES. Hashes and identifiers
    are exempt; the normalized failure codes and any free-text reference ARE
    scanned. Returns the first leak found, or $null.
    #>
    param([AllowNull()][object]$Target)
    $exempt = @(
        'SchemaVersion', 'FingerprintId', 'AlgorithmVersion', 'TaskId', 'ChangeId',
        'TaskType', 'FailureCategory', 'ModelId', 'UnderlyingModelId', 'ProviderId',
        'GatewayProviderId', 'ReasoningLevel', 'ToolCategory',
        'ContextHash', 'Signature', 'FirstSeenUtc', 'LastSeenUtc',
        'OccurrenceCount', 'AttemptIds'
    )
    $patterns = @(
        '^sk-[A-Za-z0-9_-]{8,}$',                 # OpenAI-style
        '^AIza[0-9A-Za-z_-]{10,}$',               # Google-style
        '^gh[pousr]_[A-Za-z0-9]{20,}$',           # GitHub tokens
        '^[A-Za-z0-9+/=_\-]{32,}$',               # generic high-entropy token
        '^-----BEGIN'                             # PEM block
    )

    function Test-DbM21Value([string]$fieldName, [object]$value) {
        if ($null -eq $value) { return $null }
        if ($fieldName -in $exempt) { return $null }
        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            $k = 0
            foreach ($item in $value) {
                $leak = Test-DbM21Value $fieldName $item
                if ($leak) { return $leak }
                $k++
            }
            return $null
        }
        $s = [string]$value
        if ($s.Length -lt 8) { return $null }
        foreach ($p in $patterns) { if ($s -match $p) { return "$fieldName matches $p" } }
        if ($s -match '(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*\S') { return "$fieldName contains inline credential assignment" }
        return $null
    }

    if ($null -eq $Target) { return $null }
    $props = if ($Target -is [System.Collections.IDictionary]) { $Target.Keys } else { $Target.PSObject.Properties.Name }
    foreach ($name in @($props)) {
        $value = if ($Target -is [System.Collections.IDictionary]) { $Target[$name] } else { $Target.$name }
        if ($name -in $exempt) { continue }
        $leak = Test-DbM21Value ([string]$name) $value
        if ($leak) { return "$name -> $leak" }
    }
    return $null
}

# -----------------------------------------------------------------------------
# FailureFingerprint v1 (contract builder)
# -----------------------------------------------------------------------------
function New-FailureFingerprint {
    <#
    .SYNOPSIS
    Build a normalized FailureFingerprint v1 from a field table. Failure codes
    are re-normalized (idempotent) to a canonical sorted set; the Signature is
    SHA-256 of the failure-identity component string. A secret-like stored
    value rejects the fingerprint. Route identity and context/prompt hashes are
    carried as structured fields.
    #>
    param([AllowNull()][hashtable]$Fields)
    $f = if ($null -eq $Fields) { @{} } else { $Fields }
    function F([string]$n, $d) { if ($f.ContainsKey($n)) { return $f[$n] }; return $d }

    $algVer = [int](F 'AlgorithmVersion' 1)
    if ($algVer -lt 1) { throw "New-FailureFingerprint: AlgorithmVersion must be >= 1" }

    $taskType = [string](F 'TaskType' '')
    $failureCategory = [string](F 'FailureCategory' '')
    $toolCategory = [string](F 'ToolCategory' '')
    $codes = Get-DbM21NormalizedFailureCodes -Codes @(F 'NormalizedFailureCodes' @()) `
        -NormalizeLineNumbers ([bool](F 'NormalizeLineNumbers' $true))

    $codesJoined = $codes -join ';'
    $identity = "fp$algVer|$taskType|$failureCategory|$codesJoined|$toolCategory"
    $signature = Get-DbM21Sha256Hex $identity
    $fingerprintId = "FP-$algVer-$($signature.Substring(0, 16))"

    $firstSeen = F 'FirstSeenUtc' $null
    $lastSeen = F 'LastSeenUtc' $firstSeen
    $attemptId = [string](F 'AttemptId' '')
    $attemptIds = @(F 'AttemptIds' @())
    if ($attemptId -and $attemptId -notin $attemptIds) { $attemptIds = @($attemptIds + $attemptId) }

    $fp = [pscustomobject]@{
        SchemaVersion          = 1
        FingerprintId          = $fingerprintId
        AlgorithmVersion       = $algVer
        TaskId                 = [string](F 'TaskId' '')
        ChangeId               = [string](F 'ChangeId' '')
        TaskType               = $taskType
        FailureCategory        = $failureCategory
        NormalizedFailureCodes = $codes
        ModelId                = [string](F 'ModelId' '')
        UnderlyingModelId      = [string](F 'UnderlyingModelId' '')
        ProviderId             = [string](F 'ProviderId' '')
        GatewayProviderId      = [string](F 'GatewayProviderId' '')
        ReasoningLevel         = [string](F 'ReasoningLevel' '')
        ContextHash            = [string](F 'ContextHash' '')
        PromptHashReference    = [string](F 'PromptHashReference' '')
        ToolCategory           = $toolCategory
        Signature              = $signature
        FirstSeenUtc           = $firstSeen
        LastSeenUtc            = $lastSeen
        OccurrenceCount        = [int](F 'OccurrenceCount' 1)
        AttemptIds             = $attemptIds
        Notes                  = [string](F 'Notes' '')
    }

    $tv = Test-FailureFingerprint $fp
    if (-not $tv.Valid) { throw ("New-FailureFingerprint: invalid fingerprint: " + ($tv.Errors -join '; ')) }
    return $fp
}

function Test-FailureFingerprint {
    <#
    .SYNOPSIS
    Deterministic structural validation of a FailureFingerprint v1.
    Returns @{ Valid; Errors; Warnings }.
    #>
    param([AllowNull()][pscustomobject]$Fingerprint)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Fingerprint) { return @{ Valid = $false; Errors = @('Fingerprint is null'); Warnings = @() } }
    if ((Get-ContractProperty $Fingerprint 'SchemaVersion' -1) -ne 1) { $errors.Add('SchemaVersion must be 1') }
    $fpId = [string](Get-ContractProperty $Fingerprint 'FingerprintId' '')
    if ($fpId -notmatch '^FP-\d+-[0-9a-f]{16}$') { $errors.Add("FingerprintId '$fpId' malformed (FP-<version>-<16 hex>)") }
    $algVer = Get-ContractProperty $Fingerprint 'AlgorithmVersion' $null
    if ($null -eq $algVer -or [int]$algVer -lt 1) { $errors.Add('AlgorithmVersion must be >= 1') }

    $tt = [string](Get-ContractProperty $Fingerprint 'TaskType' '')
    if ($tt -and $tt -notin (Get-AiRoutingTaskTypes)) { $errors.Add("TaskType '$tt' invalid") }
    $cat = [string](Get-ContractProperty $Fingerprint 'FailureCategory' '')
    if ($cat -and $cat -notin (Get-DbM20FailureCategories)) { $errors.Add("FailureCategory '$cat' invalid") }
    $rl = [string](Get-ContractProperty $Fingerprint 'ReasoningLevel' '')
    if ($rl -and $rl -notin (Get-AiRoutingReasoningLevels)) { $errors.Add("ReasoningLevel '$rl' invalid") }
    $tc = [string](Get-ContractProperty $Fingerprint 'ToolCategory' '')
    if ($tc -and $tc -notin (Get-DbM21ToolCategories)) { $errors.Add("ToolCategory '$tc' invalid") }

    foreach ($code in @(Get-ContractProperty $Fingerprint 'NormalizedFailureCodes' @())) {
        if (-not $code) { $errors.Add('NormalizedFailureCodes contains an empty code') }
    }
    $ctx = [string](Get-ContractProperty $Fingerprint 'ContextHash' '')
    if ($ctx -and $ctx -notmatch '^[0-9a-f]{64}$') { $errors.Add('ContextHash must be empty or 64-hex SHA-256') }
    $sig = [string](Get-ContractProperty $Fingerprint 'Signature' '')
    if ($sig -notmatch '^[0-9a-f]{64}$') { $errors.Add('Signature must be 64-hex SHA-256') }
    $occ = Get-ContractProperty $Fingerprint 'OccurrenceCount' 0
    if ($occ -lt 1) { $errors.Add('OccurrenceCount must be >= 1') }

    $leak = Get-DbM21FingerprintSecretLeak $Fingerprint
    if ($leak) { $errors.Add("secret-like value rejected: $leak") }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors.ToArray()); Warnings = @() }
}

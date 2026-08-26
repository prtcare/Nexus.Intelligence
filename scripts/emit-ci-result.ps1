<#
.SYNOPSIS
  Emits the M-08-1.3 machine-readable pipeline result artifact (schema v1 of
  Nexus.Delivery.Contracts.PipelineRunResult).

.DESCRIPTION
  Reads the trx files produced by `dotnet test --logger trx`, combines them with
  the workflow-run context the caller passes in, and writes the result JSON that
  matches the PipelineRunResult contract. The pipeline runs this step with
  `if: always()` so a failing job still publishes an artifact.

  Outcome mapping from the job status GitHub Actions reports:
    success   -> Success
    failure   -> Failure
    cancelled -> Cancelled

  Test counts are counted from the trx <UnitTestResult> elements so the artifact
  reflects what actually ran rather than what was expected.
#>
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Branch,
    [Parameter(Mandatory = $true)][string]$CommitSha,
    [Parameter(Mandatory = $true)][string]$WorkflowRunId,
    [Parameter(Mandatory = $true)][string]$JobStatus,
    [Parameter(Mandatory = $true)][string]$TrxDirectory,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $false)][string]$StartedAtFile
)

$ErrorActionPreference = 'Stop'

# --- 1. Outcome ------------------------------------------------------------
$outcome = switch ($JobStatus) {
    'success'   { 'Success' }
    'failure'   { 'Failure' }
    'cancelled' { 'Cancelled' }
    default     { 'Failure' }
}

# --- 2. Test counts from the trx results -----------------------------------
$total = 0; $passed = 0; $failed = 0; $skipped = 0
$trxFiles = @(Get-ChildItem -Path $TrxDirectory -Filter '*.trx' -ErrorAction SilentlyContinue)
if ($trxFiles.Count -eq 0) {
    Write-Warning "No trx files found under '$TrxDirectory'; test counts will all be zero."
}

foreach ($trxFile in $trxFiles) {
    # LiteralPath: vstest names colliding trx files with a "[1]" suffix, and '[' ']'
    # are wildcard characters to -Path - a plain -Path here silently matches nothing.
    [xml]$trx = Get-Content -Raw -LiteralPath $trxFile.FullName
    $results = $trx.TestRun.Results.UnitTestResult
    if ($null -eq $results) { continue }

    foreach ($r in $results) {
        $total++
        switch ($r.outcome) {
            'Passed'      { $passed++; break }
            'Failed'      { $failed++; break }
            'Skipped'     { $skipped++; break }
            'NotExecuted' { $skipped++; break }
            default       { $skipped++ }  # inconclusive/aborted/etc.: neither a pass nor a fail
        }
    }
}

# --- 3. Timestamps ----------------------------------------------------------
$startedAt = if ($StartedAtFile -and (Test-Path $StartedAtFile)) {
    (Get-Content -Raw -Path $StartedAtFile).Trim()
} else {
    [DateTimeOffset]::UtcNow.ToString('o')
}
$completedAt = [DateTimeOffset]::UtcNow.ToString('o')

# --- 4. Serialize the contract ---------------------------------------------
$result = [pscustomobject]@{
    SchemaVersion = 1
    Repository    = $Repository
    Branch        = $Branch
    CommitSha     = $CommitSha
    WorkflowRunId = $WorkflowRunId
    Outcome       = $outcome
    StartedAt     = $startedAt
    CompletedAt   = $completedAt
    TestsTotal    = $total
    TestsPassed   = $passed
    TestsFailed   = $failed
    TestsSkipped  = $skipped
}

$dir = Split-Path -Parent $OutputPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Set-Content -Path $OutputPath -Value ($result | ConvertTo-Json -Depth 5) -Encoding utf8

Write-Host "Wrote $OutputPath (outcome=$outcome, tests=$total, passed=$passed, failed=$failed, skipped=$skipped)"

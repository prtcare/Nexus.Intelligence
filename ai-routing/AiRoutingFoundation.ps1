# AiRoutingFoundation.ps1 — DB-M14 entry point for the AI routing foundation.
#
# Dot-sources the shared contracts, provider identity, and model catalogue
# libraries, then exposes:
#   Import-AiRoutingConfiguration  - load + normalize config/ai-routing.json,
#                                    config/providers.json, config/models.json
#   Validate-AiRoutingFoundation   - deterministic validation of the loaded
#                                    foundation (execution mode, schema v1,
#                                    provider/model catalogues, role refs)
#
# No AI API calls, no provider calls, no network, no secrets read, no execution.

# Resolve the DevBridge root by walking up to the directory that holds config\.
$script:DevBridgeRoot = (Get-Location).Path
$script:RoutingLib = Join-Path $PSScriptRoot "AiRoutingContracts.ps1"
. $script:RoutingLib
. (Join-Path $PSScriptRoot "AiProvider.ps1")
. (Join-Path $PSScriptRoot "ModelCatalogue.ps1")

function Resolve-AiRoutingRoot {
    <#
    .SYNOPSIS
    Locate the DevBridge root (the folder containing config\ai-routing.json).
    #>
    $dir = Split-Path -Parent $PSScriptRoot
    while ($dir) {
        if (Test-Path (Join-Path $dir "config\ai-routing.json")) { return $dir }
        $dir = Split-Path -Parent $dir
    }
    return Split-Path -Parent $PSScriptRoot
}

function Import-AiRoutingConfiguration {
    <#
    .SYNOPSIS
    Load and normalize the three DB-M14 config files into in-memory catalogues.
    Returns @{ Routing; Providers (hashtable); Models (hashtable); Raw }.
    #>
    param([string]$Root = (Resolve-AiRoutingRoot))
    $routingFile = Join-Path $Root "config\ai-routing.json"
    $providersFile = Join-Path $Root "config\providers.json"
    $modelsFile = Join-Path $Root "config\models.json"

    $routing = $null
    if (Test-Path $routingFile) {
        $routing = Get-Content $routingFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $providers = @{}
    if (Test-Path $providersFile) {
        $pjson = Get-Content $providersFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in @($pjson.providers)) {
            $rec = New-AiProvider -InputObject $p
            $providers[$rec.ProviderId] = $rec
        }
    }

    $models = @{}
    if (Test-Path $modelsFile) {
        $mjson = Get-Content $modelsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($m in @($mjson.models)) {
            $rec = New-AiModel -InputObject $m
            $models[$rec.ModelId] = $rec
        }
    }

    return @{
        Routing   = $routing
        Providers = $providers
        Models    = $models
    }
}

function Validate-AiRoutingFoundation {
    <#
    .SYNOPSIS
    Deterministically validate the loaded routing foundation. Returns a summary
    object with Valid, Errors, Warnings, and the validated catalogues.
    #>
    param(
        [string]$Root = (Resolve-AiRoutingRoot),
        [AllowNull()][object]$Configuration
    )
    if (-not $Configuration) { $Configuration = Import-AiRoutingConfiguration -Root $Root }

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    # --- routing config / execution mode ------------------------------------
    $routing = $Configuration.Routing
    if ($null -eq $routing) {
        $errors.Add('config/ai-routing.json missing or unparseable')
    } else {
        if ((Get-ContractProperty $routing 'SchemaVersion' -1) -ne 1) { $errors.Add('ai-routing.json SchemaVersion must be 1') }
        $mode = Get-ContractProperty $routing 'ExecutionMode' $null
        $allowed = @(Get-ContractProperty $routing 'AllowedRuntimeModes' @('MANUAL'))
        if (-not $mode) { $errors.Add('ExecutionMode is required') }
        elseif ($mode -notin $allowed) {
            $errors.Add("ExecutionMode '$mode' is not an allowed runtime mode (allowed: $($allowed -join ', '))")
        }
        if ($mode -eq 'AUTO') { $errors.Add('AUTO execution mode is prohibited in DB-M14') }
    }

    # --- provider catalogue --------------------------------------------------
    $pv = Validate-AiProviderCatalogue $Configuration.Providers
    if (-not $pv.Valid) { foreach ($e in $pv.Errors) { $errors.Add("providers: $e") } }

    # --- model catalogue (cross-checked against providers) -------------------
    $mv = Validate-AiModelCatalogue -Catalogue $Configuration.Models -Providers $Configuration.Providers
    if (-not $mv.Valid) { foreach ($e in $mv.Errors) { $errors.Add("models: $e") } }

    # --- role aliases resolve to existing models (convenience config) --------
    $roleMap = Get-ContractProperty $routing 'Roles' $null
    if ($roleMap) {
        foreach ($prop in $roleMap.PSObject.Properties) {
            $target = [string]$prop.Value
            if ($target -and -not $Configuration.Models.ContainsKey($target.Trim().ToLowerInvariant())) {
                $warnings.Add("Role '$($prop.Name)' references model '$target' which is not in the model catalogue")
            }
        }
    }

    return [pscustomobject]@{
        Valid      = ($errors.Count -eq 0)
        Errors     = @($errors)
        Warnings   = @($warnings)
        ExecutionMode = (Get-ContractProperty $routing 'ExecutionMode' $null)
        Providers  = $Configuration.Providers
        Models     = $Configuration.Models
    }
}

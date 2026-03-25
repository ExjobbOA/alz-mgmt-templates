#Requires -Version 7
<#
.SYNOPSIS
    Compares a brownfield ALZ export against the engine's ALZ policy library
    and produces a human-readable adoption readiness report.

.DESCRIPTION
    Reads a JSON file produced by Export-BrownfieldState.ps1 and compares its
    policy definitions, policy set definitions, and role definitions against the
    engine's ALZ library to classify each as Standard, Non-standard, or Deprecated.

    Also inventories policy assignments, RBAC, infrastructure, and extracts
    configuration values the operator needs for platform.json.

    Read-only. No changes are made to Azure or to any files (unless -OutputFile is used).

.PARAMETER BrownfieldExport
    Path to the brownfield JSON export produced by Export-BrownfieldState.ps1.

.PARAMETER AlzLibraryPath
    Path to the engine's ALZ library directory (contains *.alz_policy_definition.json etc).
    Auto-detected relative to this script's location if omitted.

.PARAMETER OutputFile
    Optional path to write the full report as JSON.

.PARAMETER Detailed
    Show individual resource listings (non-standard/deprecated items), not just counts.

.EXAMPLE
    ./scripts/Compare-BrownfieldState.ps1 -BrownfieldExport ./state-snapshots/state-sylaviken-brownfield.json

.EXAMPLE
    ./scripts/Compare-BrownfieldState.ps1 -BrownfieldExport ./state-snapshots/state-sylaviken-brownfield.json -Detailed -OutputFile ./report.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BrownfieldExport,

    [string]$AlzLibraryPath = '',

    [string]$OutputFile = '',

    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NoColor = -not $Host.UI.SupportsVirtualTerminal
function Write-Step   ($msg) { if ($NoColor) { Write-Host "`n── $msg ──" }           else { Write-Host "`n`e[1m── $msg ──`e[0m" } }
function Write-Info   ($msg) { if ($NoColor) { Write-Host "[INFO]   $msg" }           else { Write-Host "`e[36m[INFO]`e[0m   $msg" } }
function Write-Ok     ($msg) { if ($NoColor) { Write-Host "[OK]     $msg" }           else { Write-Host "`e[32m[OK]`e[0m     $msg" } }
function Write-Warn   ($msg) { if ($NoColor) { Write-Host "[WARN]   $msg" }           else { Write-Host "`e[33m[WARN]`e[0m   $msg" } }
function Write-Err    ($msg) { if ($NoColor) { Write-Host "[ERROR]  $msg" }           else { Write-Host "`e[31m[ERROR]`e[0m  $msg" } }
function Write-Amba   ($msg) { if ($NoColor) { Write-Host "[AMBA]   $msg" }           else { Write-Host "`e[34m[AMBA]`e[0m   $msg" } }
function Write-Detail ($msg) { if ($NoColor) { Write-Host "         $msg" }           else { Write-Host "`e[90m         $msg`e[0m" } }

function Get-SHA256Short ([string]$InputString) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return [System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 16)
}

function ConvertTo-SortedObject ($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IList]) {
        return @($obj | ForEach-Object { ConvertTo-SortedObject $_ })
    }
    if ($obj -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        $obj.Keys | Sort-Object | ForEach-Object { $ordered[$_] = ConvertTo-SortedObject $obj[$_] }
        return [PSCustomObject]$ordered
    }
    if ($obj -is [PSCustomObject]) {
        $ordered = [ordered]@{}
        $obj.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object | ForEach-Object { $ordered[$_] = ConvertTo-SortedObject $obj.$_ }
        return [PSCustomObject]$ordered
    }
    return $obj
}

function Write-Colored ([string]$Label, [string]$Color, [string]$Msg) {
    if ($NoColor) { Write-Host "[$Label] $Msg" }
    else {
        $code = switch ($Color) {
            'Green' { '32' }
            'Yellow' { '33' }
            'Red' { '31' }
            'Cyan' { '36' }
            'Blue' { '34' }
            default { '0' }
        }
        Write-Host "`e[${code}m[$Label]`e[0m $Msg"
    }
}

# Resolve the effective policy effect from a policyRule object + parameters object.
# Returns a normalized effect string (e.g. "Deny", "DeployIfNotExists") or "Unknown".
function Get-PolicyEffect ([object]$PolicyRule, [object]$Parameters) {
    if (-not $PolicyRule) { return 'Unknown' }
    $thenProp = $PolicyRule.PSObject.Properties['then']
    if (-not $thenProp -or -not $thenProp.Value) { return 'Unknown' }
    $effectProp = $thenProp.Value.PSObject.Properties['effect']
    if (-not $effectProp) { return 'Unknown' }
    $raw = [string]$effectProp.Value
    # Parameter reference pattern (ARM uses [[parameters('effect')] to escape the leading [)
    if ($raw -match "parameters\(") {
        if ($Parameters) {
            $ep = $Parameters.PSObject.Properties['effect']
            if ($ep -and $ep.Value -and $ep.Value.PSObject.Properties['defaultValue']) {
                return [string]$ep.Value.defaultValue
            }
        }
        return 'Unknown'
    }
    return $raw
}

# Recursively walk an if-condition tree and return all resource types referenced
# via {"field":"type","equals":"..."} conditions. Handles allOf/anyOf/not nesting.
function Get-IfResourceTypes ([object]$Condition) {
    if (-not $Condition) { return @() }
    $found = [System.Collections.Generic.List[string]]::new()
    # Direct field=type condition
    $fieldProp  = $Condition.PSObject.Properties['field']
    $equalsProp = $Condition.PSObject.Properties['equals']
    if ($fieldProp -and ($fieldProp.Value -ieq 'type') -and $equalsProp) {
        [void]$found.Add([string]$equalsProp.Value)
    }
    # allOf / anyOf
    foreach ($key in @('allOf','anyOf')) {
        $prop = $Condition.PSObject.Properties[$key]
        if ($prop -and $prop.Value) {
            foreach ($item in @($prop.Value)) {
                foreach ($t in (Get-IfResourceTypes $item)) {
                    if (-not $found.Contains($t)) { [void]$found.Add($t) }
                }
            }
        }
    }
    # not
    $notProp = $Condition.PSObject.Properties['not']
    if ($notProp -and $notProp.Value) {
        foreach ($t in (Get-IfResourceTypes $notProp.Value)) {
            if (-not $found.Contains($t)) { [void]$found.Add($t) }
        }
    }
    return @($found)
}

# Normalize an effect string to a canonical category name.
function Get-EffectCategory ([string]$Effect) {
    switch -Regex ($Effect.ToLower()) {
        '^deny(action)?$'      { return 'Deny' }
        '^deployifnotexists$'  { return 'DeployIfNotExists' }
        '^modify$'             { return 'Modify' }
        '^append$'             { return 'Append' }
        '^audit(ifnotexists)?$' { return 'Audit' }
        '^disabled$'           { return 'Disabled' }
        default                { return 'Other' }
    }
}

#==============================================================================
# Load and validate inputs
#==============================================================================
Write-Host ''
if ($NoColor) { Write-Host 'ALZ Brownfield Comparison Report' } else { Write-Host "`e[1mALZ Brownfield Comparison Report`e[0m" }
Write-Host '(read-only — no changes will be made)'
Write-Host ''

if (-not (Test-Path $BrownfieldExport)) {
    Write-Error "Brownfield export not found: $BrownfieldExport"
    exit 1
}

$export = Get-Content $BrownfieldExport -Raw | ConvertFrom-Json

# Auto-detect library path relative to this script
if ($AlzLibraryPath -eq '') {
    $AlzLibraryPath = Join-Path $PSScriptRoot '../templates/core/governance/lib/alz'
}
if (-not (Test-Path $AlzLibraryPath)) {
    Write-Error "ALZ library not found at: $AlzLibraryPath`nPass -AlzLibraryPath to specify the correct path."
    exit 1
}

Write-Info "Export:  $BrownfieldExport"
Write-Info "Library: $AlzLibraryPath"
Write-Info "Tenant:  $($export.TenantId)"
Write-Info "Exported at: $($export.ExportTimestamp)"

#==============================================================================
# Load ALZ library reference sets
#==============================================================================
# $libPolicyDefs: name -> @{ DisplayName; PolicyRuleHash }
$libPolicyDefs = @{}
$libPolicySetDefs = @{}
$libRoleDefs = @{}

Get-ChildItem -Path $AlzLibraryPath -Filter '*.alz_policy_definition.json' -Recurse | ForEach-Object {
    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
    # Policy rule lives at properties.policyRule in the library JSON schema
    $ruleObj = if ($j.PSObject.Properties['properties'] -and $j.properties.PSObject.Properties['policyRule']) {
        $j.properties.policyRule
    }
    elseif ($j.PSObject.Properties['policyRule']) {
        $j.policyRule
    }
    else { $null }
    $ruleHash = if ($ruleObj) { Get-SHA256Short ((ConvertTo-SortedObject $ruleObj) | ConvertTo-Json -Depth 20 -Compress) } else { '' }
    $version = if ($j.properties.PSObject.Properties['metadata'] -and $j.properties.metadata.PSObject.Properties['version']) {
        $j.properties.metadata.version
    }
    else { '' }
    $paramsObj      = if ($j.properties.PSObject.Properties['parameters']) { $j.properties.parameters } else { $null }
    $effect         = Get-PolicyEffect $ruleObj $paramsObj
    $ruleIfBlock    = if ($ruleObj -and $ruleObj.PSObject.Properties['if']) { $ruleObj.PSObject.Properties['if'].Value } else { $null }
    $libResTypes    = @(Get-IfResourceTypes $ruleIfBlock)
    $libPolicyDefs[$j.name] = [PSCustomObject]@{ DisplayName = $j.properties.displayName; Version = $version; PolicyRuleHash = $ruleHash; Effect = $effect; TargetResourceTypes = $libResTypes }
}
Get-ChildItem -Path $AlzLibraryPath -Filter '*.alz_policy_set_definition.json' -Recurse | ForEach-Object {
    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $libPolicySetDefs[$j.name] = [PSCustomObject]@{ DisplayName = $j.properties.displayName }
}
Get-ChildItem -Path $AlzLibraryPath -Filter '*.alz_role_definition.json' -Recurse | ForEach-Object {
    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $libRoleDefs[$j.name] = $j.properties.roleName
}
$libAssignmentNames = [System.Collections.Generic.HashSet[string]]::new()
Get-ChildItem -Path $AlzLibraryPath -Filter '*.alz_policy_assignment.json' -Recurse | ForEach-Object {
    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
    [void]$libAssignmentNames.Add($j.name)
}

Write-Info "Library loaded: $($libPolicyDefs.Count) policy defs, $($libPolicySetDefs.Count) policy set defs, $($libRoleDefs.Count) role defs, $($libAssignmentNames.Count) policy assignments"

#==============================================================================
# Helper: AMBA metadata detection
#==============================================================================
function Test-AmbaMetadata ([object]$Metadata) {
    if (-not $Metadata) { return $false }
    if ($Metadata.PSObject.Properties['_deployed_by_amba'] -and $Metadata._deployed_by_amba -eq 'True') { return $true }
    if ($Metadata.PSObject.Properties['source'] -and $Metadata.source -match 'azure-monitor-baseline-alerts') { return $true }
    return $false
}

#==============================================================================
# Helper: classify a policy definition
# Returns: Deprecated | AMBA | Standard | StandardMismatch | NonStandard
#==============================================================================
function Get-PolicyDefClassification ([string]$Name, [object]$Metadata, [string]$BrownfieldHash = '') {
    if ($Metadata -and $Metadata.PSObject.Properties['deprecated'] -and $Metadata.deprecated -eq $true) {
        return 'Deprecated'
    }
    if (Test-AmbaMetadata $Metadata) { return 'AMBA' }
    if ($libPolicyDefs.ContainsKey($Name)) {
        $libEntry = $libPolicyDefs[$Name]
        # Compare policy rule hashes — if they differ the engine will overwrite the rule on deploy
        if ($BrownfieldHash -and $libEntry.PolicyRuleHash -and ($BrownfieldHash -ne $libEntry.PolicyRuleHash)) {
            return 'StandardMismatch'
        }
        return 'Standard'
    }
    return 'NonStandard'
}

#==============================================================================
# Helper: classify a policy set definition
# Returns: Deprecated | AMBA | Standard | NonStandard
#==============================================================================
function Get-PolicySetDefClassification ([string]$Name, [object]$Metadata) {
    if ($Metadata -and $Metadata.PSObject.Properties['deprecated'] -and $Metadata.deprecated -eq $true) {
        return 'Deprecated'
    }
    if (Test-AmbaMetadata $Metadata) { return 'AMBA' }
    # AMBA initiative names start with "Alerting-"
    if ($Name -match '^Alerting-') { return 'AMBA' }
    if ($libPolicySetDefs.ContainsKey($Name)) { return 'Standard' }
    return 'NonStandard'
}

function Get-RoleDefClassification ([string]$RoleName) {
    # ALZ standard roles have [ALZ] prefix in the role name
    if ($RoleName -match '^\[ALZ\]') { return 'ALZStandard' }
    # Check by GUID name in lib
    return 'Custom'
}

#==============================================================================
# Helper: extract config values from policy assignment parameters
#==============================================================================
$script:CollectedSubIds = [System.Collections.Generic.HashSet[string]]::new()
$script:CollectedLawIds = [System.Collections.Generic.HashSet[string]]::new()
$script:CollectedEmails = [System.Collections.Generic.HashSet[string]]::new()
$script:CollectedLocations = [System.Collections.Generic.HashSet[string]]::new()
$script:CollectedDcrIds = [System.Collections.Generic.HashSet[string]]::new()
$script:CollectedUamiIds = [System.Collections.Generic.HashSet[string]]::new()
$script:CollectedRgNames = [System.Collections.Generic.HashSet[string]]::new()

function Extract-ConfigValues ([object]$Parameters) {
    if (-not $Parameters) { return }
    $Parameters.PSObject.Properties | ForEach-Object {
        $v = $_.Value
        if ($v -and $v.PSObject.Properties['value']) {
            $val = $v.value
            if ($val -is [string]) {
                # Subscription ID pattern
                if ($val -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
                    [void]$script:CollectedSubIds.Add($val)
                }
                # Log Analytics workspace resource ID
                if ($val -match '/providers/Microsoft\.OperationalInsights/workspaces/') {
                    [void]$script:CollectedLawIds.Add($val)
                }
                # Email address
                if ($val -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                    [void]$script:CollectedEmails.Add($val)
                }
                # DCR resource ID
                if ($val -match '/providers/Microsoft\.Insights/dataCollectionRules/') {
                    [void]$script:CollectedDcrIds.Add($val)
                }
                # UAMI resource ID
                if ($val -match '/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/') {
                    [void]$script:CollectedUamiIds.Add($val)
                }
                # Location-like string (simple heuristic)
                if ($val -match '^[a-z][a-z0-9]+$' -and $val.Length -gt 4 -and $val.Length -lt 30) {
                    # narrow it: looks like a known Azure region pattern
                    if ($val -match 'central|north|south|east|west|europe|asia|australia|brazil|japan|uk|us|canada|france|germany|india|norway|sweden|uae|korea|switzerland|poland') {
                        [void]$script:CollectedLocations.Add($val)
                    }
                }
            }
        }
    }
}

#==============================================================================
# Report data accumulator + risk tracking
#==============================================================================
$reportScopes = @()

# Per-effect mismatch counts — populated during Section 2, consumed in Section 7
$script:MismatchCountByEffect = @{
    Deny              = 0
    DeployIfNotExists = 0
    Modify            = 0
    Append            = 0
    Audit             = 0
    Other             = 0
}

# Reverse lookup: policy definition name → list of MG scopes where it is assigned
# Built from the brownfield export so Section 2 can show assignment context for Deny changes.
$defAssignmentScopes = @{}
foreach ($mgScope in @($export.Scopes | Where-Object { $_.Scope -eq 'managementGroup' })) {
    foreach ($a in @($mgScope.Resources.PolicyAssignments)) {
        $defName = ($a.PolicyDefinitionId -split '/')[-1]
        if (-not $defAssignmentScopes.ContainsKey($defName)) {
            $defAssignmentScopes[$defName] = [System.Collections.Generic.List[object]]::new()
        }
        $defAssignmentScopes[$defName].Add([PSCustomObject]@{
            ScopeName         = $mgScope.Name
            ManagementGroupId = $mgScope.ManagementGroupId
        })
    }
}

#==============================================================================
# Section 1: Structural Overview
#==============================================================================
Write-Step 'Section 1: Structural Overview'

function Write-MgTree ([object]$Node, [int]$Depth = 0) {
    $indent = '  ' * $Depth
    $prefix = if ($Depth -eq 0) { '' } else { '└─ ' }
    Write-Host "  $indent$prefix$($Node.Name) ($($Node.DisplayName))"
    if ($Node.Children) {
        foreach ($child in $Node.Children) {
            Write-MgTree $child ($Depth + 1)
        }
    }
}

Write-Host ''
Write-Host '  Management Group Hierarchy:'
Write-MgTree $export.ManagementGroupHierarchy

# Find subscription scope
$subScope = $export.Scopes | Where-Object { $_.Scope -eq 'subscription' }
if ($subScope) {
    Write-Host ''
    Write-Host '  Platform Subscription(s):'
    foreach ($ss in @($subScope)) {
        Write-Info "  $($ss.SubscriptionId) ($($ss.Name))"
    }
}

if ($export.Warnings -and $export.Warnings.Count -gt 0) {
    Write-Host ''
    foreach ($w in $export.Warnings) { Write-Warn $w }
}
else {
    Write-Host ''
    Write-Ok 'No export warnings'
}

#==============================================================================
# Section 2: Policy Library Comparison
#==============================================================================
Write-Step 'Section 2: Policy Library Comparison'

$mgScopes = @($export.Scopes | Where-Object { $_.Scope -eq 'managementGroup' })

foreach ($scope in $mgScopes) {
    Write-Host ''
    Write-Host "  ── Scope: $($scope.Name) (MG: $($scope.ManagementGroupId)) ──"

    $scopeReport = [PSCustomObject]@{
        ScopeName         = $scope.Name
        ManagementGroupId = $scope.ManagementGroupId
        PolicyDefs        = @()
        PolicySetDefs     = @()
        RoleAssignments   = @()
        RoleDefinitions   = @()
        PolicyAssignments = @()
    }

    # --- Policy Definitions ---
    $stdDefs = 0; $stdMismatchDefs = 0; $nonStdDefs = 0; $ambaDefs = 0; $deprDefs = 0
    $stdMismatchDefList = @()
    $nonStdDefList = @()
    $deprDefList = @()
    $ambaDefList = @()

    foreach ($def in @($scope.Resources.PolicyDefinitions)) {
        $meta = if ($def.PSObject.Properties['Metadata']) { $def.Metadata }       else { $null }
        $bfHash = if ($def.PSObject.Properties['PolicyRuleHash']) { $def.PolicyRuleHash } else { '' }
        $cls = Get-PolicyDefClassification $def.Name $meta $bfHash
        $bfVer = if ($def.PSObject.Properties['Version']) { $def.Version } else { '' }
        $defEntry = [PSCustomObject]@{ Name = $def.Name; DisplayName = $def.DisplayName; Classification = $cls; BrownfieldHash = $bfHash; Version = $bfVer }
        $scopeReport.PolicyDefs += $defEntry
        switch ($cls) {
            'Standard' { $stdDefs++ }
            'StandardMismatch' {
                $stdMismatchDefs++; $stdMismatchDefList += $defEntry
                # Track effect category for Section 7 risk summary
                $mLibEntry = $libPolicyDefs[$def.Name]
                $mEffect   = if ($mLibEntry -and $mLibEntry.Effect) { $mLibEntry.Effect } else { 'Unknown' }
                $mCat      = Get-EffectCategory $mEffect
                $script:MismatchCountByEffect[$mCat]++
            }
            'NonStandard' { $nonStdDefs++; $nonStdDefList += $defEntry }
            'AMBA' { $ambaDefs++; $ambaDefList += $defEntry }
            'Deprecated' { $deprDefs++; $deprDefList += $defEntry }
        }
    }

    $totalDefs = $stdDefs + $stdMismatchDefs + $nonStdDefs + $ambaDefs + $deprDefs
    if ($totalDefs -eq 0) {
        Write-Detail "Policy Definitions: (none)"
    }
    else {
        if ($stdDefs -gt 0) { Write-Ok   "Policy Definitions:     $stdDefs standard (exact)" }
        if ($stdMismatchDefs -gt 0) { Write-Warn "Policy Definitions:     $stdMismatchDefs standard (rule mismatch — engine will overwrite)" }
        if ($nonStdDefs -gt 0) { Write-Warn "Policy Definitions:     $nonStdDefs non-standard (review required)" }
        if ($ambaDefs -gt 0) { Write-Amba "Policy Definitions:     $ambaDefs AMBA (Azure Monitor Baseline Alerts)" }
        if ($deprDefs -gt 0) { Write-Info "Policy Definitions:     $deprDefs deprecated" }

        if ($Detailed) {
            foreach ($e in $stdMismatchDefList) {
                $libEntry  = $libPolicyDefs[$e.Name]
                $bfVer     = if ($e.Version) { $e.Version } else { '?' }
                $libVer    = if ($libEntry -and $libEntry.Version) { $libEntry.Version } else { '?' }
                $effect    = if ($libEntry -and $libEntry.Effect) { $libEntry.Effect } else { 'Unknown' }
                $resTypes  = if ($libEntry -and $libEntry.TargetResourceTypes -and $libEntry.TargetResourceTypes.Count -gt 0) {
                    $libEntry.TargetResourceTypes -join ', '
                } else { '(unknown)' }
                $effCat = Get-EffectCategory $effect

                switch ($effCat) {
                    'Deny' {
                        $assignScopes = @(if ($defAssignmentScopes.ContainsKey($e.Name)) { $defAssignmentScopes[$e.Name] })
                        Write-Err "  [DENY RULE CHANGE] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  library=$libVer"
                        Write-Detail "    targets: $resTypes"
                        if ($assignScopes.Count -gt 0) {
                            $scopeStr = ($assignScopes | ForEach-Object { "$($_.ScopeName) ($($_.ManagementGroupId))" }) -join ', '
                            Write-Detail "    assigned at: $scopeStr"
                        } else {
                            Write-Detail "    assigned at: (no assignments for this definition found in export)"
                        }
                        Write-Detail "    subscriptions in scope: (not tracked in export — subscription placement not captured per MG)"
                        Write-Err   "    ⚠ Deny-effect rule is changing — verify resources of this type comply before deploying"
                    }
                    'DeployIfNotExists' {
                        Write-Warn "  [DINE RULE CHANGE] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  library=$libVer"
                        Write-Detail "    targets: $resTypes"
                        Write-Warn  "    (medium risk — may trigger remediation tasks on existing resources)"
                    }
                    'Modify' {
                        Write-Warn "  [MODIFY RULE CHANGE] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  library=$libVer"
                        Write-Detail "    targets: $resTypes"
                        Write-Warn  "    (medium risk — may change resource properties on next policy evaluation)"
                    }
                    'Append' {
                        Write-Info "  [APPEND RULE CHANGE] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  library=$libVer"
                        Write-Detail "    targets: $resTypes"
                        Write-Detail "    (low risk — append only adds properties on next resource update)"
                    }
                    'Audit' {
                        Write-Info "  [AUDIT RULE CHANGE] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  library=$libVer"
                        Write-Detail "    (low risk — audit only, no operational impact)"
                    }
                    default {
                        Write-Warn "  [RULE-MISMATCH] $($e.Name)  [effect: $effect]"
                        Write-Detail "    version: brownfield=$bfVer  library=$libVer"
                        Write-Detail "    targets: $resTypes"
                    }
                }
            }
            foreach ($e in $nonStdDefList) {
                Write-Warn "  [NON-STD] $($e.Name)  —  $($e.DisplayName)"
            }
            foreach ($e in $ambaDefList) {
                Write-Amba "  [AMBA] $($e.Name)  —  $($e.DisplayName)"
            }
            foreach ($e in $deprDefList) {
                Write-Info "  [DEPRECATED] $($e.Name)  —  $($e.DisplayName)"
            }
        }
    }

    # --- Policy Set Definitions ---
    $stdSets = 0; $nonStdSets = 0; $ambaSets = 0; $deprSets = 0
    $nonStdSetList = @()
    $ambaSetList = @()
    $deprSetList = @()

    foreach ($set in @($scope.Resources.PolicySetDefinitions)) {
        $meta = if ($set.PSObject.Properties['Metadata']) { $set.Metadata } else { $null }
        $cls = Get-PolicySetDefClassification $set.Name $meta
        # Fallback: deprecated display name prefix
        if ($set.DisplayName -match '^\[Deprecated\]') { $cls = 'Deprecated' }
        $setEntry = [PSCustomObject]@{ Name = $set.Name; DisplayName = $set.DisplayName; Classification = $cls }
        $scopeReport.PolicySetDefs += $setEntry
        switch ($cls) {
            'Standard' { $stdSets++ }
            'NonStandard' { $nonStdSets++; $nonStdSetList += $setEntry }
            'AMBA' { $ambaSets++; $ambaSetList += $setEntry }
            'Deprecated' { $deprSets++; $deprSetList += $setEntry }
        }
    }

    $totalSets = $stdSets + $nonStdSets + $ambaSets + $deprSets
    if ($totalSets -eq 0) {
        Write-Detail "Policy Set Definitions: (none)"
    }
    else {
        if ($stdSets -gt 0) { Write-Ok   "Policy Set Defs:        $stdSets standard" }
        if ($nonStdSets -gt 0) { Write-Warn "Policy Set Defs:        $nonStdSets non-standard (review required)" }
        if ($ambaSets -gt 0) { Write-Amba "Policy Set Defs:        $ambaSets AMBA" }
        if ($deprSets -gt 0) { Write-Info "Policy Set Defs:        $deprSets deprecated" }

        if ($Detailed) {
            foreach ($e in $nonStdSetList) {
                Write-Warn "  [NON-STD] $($e.Name)  —  $($e.DisplayName)"
            }
            foreach ($e in $ambaSetList) {
                Write-Amba "  [AMBA] $($e.Name)  —  $($e.DisplayName)"
            }
            foreach ($e in $deprSetList) {
                Write-Info "  [DEPRECATED] $($e.Name)  —  $($e.DisplayName)"
            }
        }
    }

    $reportScopes += $scopeReport
}

#==============================================================================
# Section 3: Policy Assignment Inventory
#==============================================================================
Write-Step 'Section 3: Policy Assignment Inventory'

# Build lookups of all brownfield def names for quick reference in Section 3
$brownfieldDefNames = [System.Collections.Generic.HashSet[string]]::new()
$brownfieldSetNames = [System.Collections.Generic.HashSet[string]]::new()
$ambaDefNames = [System.Collections.Generic.HashSet[string]]::new()
$ambaSetNames = [System.Collections.Generic.HashSet[string]]::new()
foreach ($scope in $mgScopes) {
    foreach ($d in @($scope.Resources.PolicyDefinitions)) {
        [void]$brownfieldDefNames.Add($d.Name)
        $meta = if ($d.PSObject.Properties['Metadata']) { $d.Metadata } else { $null }
        if (Test-AmbaMetadata $meta) { [void]$ambaDefNames.Add($d.Name) }
    }
    foreach ($s in @($scope.Resources.PolicySetDefinitions)) {
        [void]$brownfieldSetNames.Add($s.Name)
        $meta = if ($s.PSObject.Properties['Metadata']) { $s.Metadata } else { $null }
        if ((Test-AmbaMetadata $meta) -or $s.Name -match '^Alerting-') { [void]$ambaSetNames.Add($s.Name) }
    }
}

foreach ($scope in $mgScopes) {
    $assignments = @($scope.Resources.PolicyAssignments)
    if ($assignments.Count -eq 0) { continue }

    Write-Host ''
    Write-Host "  ── Scope: $($scope.Name) ($($assignments.Count) assignments) ──"

    $scopeEntry = $reportScopes | Where-Object { $_.ScopeName -eq $scope.Name }

    foreach ($a in $assignments) {
        $aName = ($a.ResourceId -split '/')[-1]

        # Determine how the referenced definition is classified
        $defId = $a.PolicyDefinitionId
        $defName = ($defId -split '/')[-1]
        $refStd = $libPolicyDefs.ContainsKey($defName) -or $libPolicySetDefs.ContainsKey($defName) -or $libAssignmentNames.Contains($aName)
        $refAmba = $ambaDefNames.Contains($defName) -or $ambaSetNames.Contains($defName)

        # Enforcement mode
        $em = if ($a.PSObject.Properties['EnforcementMode']) { $a.EnforcementMode } else { 'Default' }

        # Extract config values from parameters
        if ($a.PSObject.Properties['Parameters']) {
            Extract-ConfigValues $a.Parameters
        }

        $assignEntry = [PSCustomObject]@{
            Name               = $aName
            DisplayName        = $a.DisplayName
            EnforcementMode    = $em
            PolicyDefinitionId = $defId
            ReferencesStandard = $refStd
            ReferencesAmba     = $refAmba
        }
        if ($scopeEntry) { $scopeEntry.PolicyAssignments += $assignEntry }

        $emLabel = if ($em -eq 'DoNotEnforce') { 'DoNotEnforce' } else { 'Enforced' }
        $refLabel = if ($refStd) { '[std]' } elseif ($refAmba) { '[amba]' } else { '[non-std]' }

        if ($Detailed) {
            if ($refAmba) {
                Write-Amba "  $aName  ($emLabel, $refLabel)"
                Write-Detail "    $($a.DisplayName)"
            }
            elseif (-not $refStd) {
                Write-Warn "  $aName  ($emLabel, $refLabel)"
                Write-Detail "    $($a.DisplayName)"
            }
            else {
                Write-Detail "  $aName  ($emLabel, $refLabel)  $($a.DisplayName)"
            }
        }
    }

    if (-not $Detailed) {
        $total = $assignments.Count
        $nonStd = @($assignments | Where-Object {
                $defN = ($_.PolicyDefinitionId -split '/')[-1]
                $aN = ($_.ResourceId -split '/')[-1]
                -not ($libPolicyDefs.ContainsKey($defN) -or $libPolicySetDefs.ContainsKey($defN) -or $libAssignmentNames.Contains($aN) -or $ambaDefNames.Contains($defN) -or $ambaSetNames.Contains($defN))
            }).Count
        $amba = @($assignments | Where-Object {
                $defN = ($_.PolicyDefinitionId -split '/')[-1]
                $ambaDefNames.Contains($defN) -or $ambaSetNames.Contains($defN)
            }).Count
        $dne = @($assignments | Where-Object { $_.PSObject.Properties['EnforcementMode'] -and $_.EnforcementMode -eq 'DoNotEnforce' }).Count
        Write-Ok   "  $total total assignments"
        if ($nonStd -gt 0) { Write-Warn "  $nonStd reference non-standard definitions" }
        if ($amba -gt 0) { Write-Amba "  $amba reference AMBA definitions" }
        if ($dne -gt 0) { Write-Info "  $dne in DoNotEnforce mode" }
    }
}

#==============================================================================
# Section 4: RBAC Summary
#==============================================================================
Write-Step 'Section 4: RBAC Summary'

foreach ($scope in $mgScopes) {
    $ras = @($scope.Resources.RoleAssignments)
    $rds = @($scope.Resources.RoleDefinitions)

    if ($ras.Count -eq 0 -and $rds.Count -eq 0) { continue }

    Write-Host ''
    Write-Host "  ── Scope: $($scope.Name) ──"

    # Role assignments by principal type
    if ($ras.Count -gt 0) {
        $byType = $ras | Group-Object PrincipalType | Sort-Object Name
        foreach ($g in $byType) {
            Write-Info "  Role assignments — $($g.Name): $($g.Count)"
        }
    }

    # Role definitions
    if ($rds.Count -gt 0) {
        foreach ($rd in $rds) {
            $cls = Get-RoleDefClassification $rd.RoleName
            $permCount = if ($rd.Permissions) { $rd.Permissions.Count } else { 0 }
            if ($cls -eq 'ALZStandard') {
                Write-Ok "  [ALZ role] $($rd.RoleName)  ($permCount permission(s))"
            }
            else {
                Write-Warn "  [Custom role] $($rd.RoleName)  ($permCount permission(s))"
            }
        }
    }

    $scopeEntry = $reportScopes | Where-Object { $_.ScopeName -eq $scope.Name }
    if ($scopeEntry) {
        $scopeEntry.RoleAssignments = $ras
        $scopeEntry.RoleDefinitions = $rds
    }
}

#==============================================================================
# Section 5: Infrastructure Assessment
#==============================================================================
Write-Step 'Section 5: Infrastructure Assessment'

$alzRgPrefixes = @('alz-', 'ALZ-', 'rg-alz-', 'rg-amba-')
$skipRgPrefixes = @('VisualStudioOnline-', 'NetworkWatcherRG', 'cloud-shell-storage')
$expectedKeyResTypes = @('logAnalyticsWorkspace', 'automationAccount', 'hubVnet', 'firewall', 'privateDnsZones')

$infraReport = @()

foreach ($ss in @($subScope)) {
    Write-Host ''
    Write-Host "  ── Subscription: $($ss.SubscriptionId) ──"

    $rgs = @($ss.Resources.ResourceGroups)
    $keyRes = @($ss.Resources.KeyResources)

    $alzRgs = @($rgs | Where-Object { $n = $_.Name; $alzRgPrefixes | Where-Object { $n -like "$_*" } })
    $nonAlzRgs = @($rgs | Where-Object { $n = $_.Name; -not ($alzRgPrefixes | Where-Object { $n -like "$_*" }) })

    Write-Info "  Resource groups: $($rgs.Count) total  ($($alzRgs.Count) ALZ-related, $($nonAlzRgs.Count) other)"

    if ($nonAlzRgs.Count -gt 0) {
        Write-Warn "  Non-ALZ resource groups (may be unrelated workloads):"
        foreach ($rg in $nonAlzRgs) {
            Write-Detail "    $($rg.Name) [$($rg.Location)]"
        }
    }

    # Key resources
    $foundTypes = @{}
    foreach ($kr in $keyRes) {
        $foundTypes[$kr.Type] = $kr

        # Collect LAW workspace ID for config extraction
        if ($kr.Type -eq 'logAnalyticsWorkspace') {
            [void]$script:CollectedLawIds.Add($kr.ResourceId)
            [void]$script:CollectedLocations.Add($kr.Location)
        }

        # Naming convention check
        $engineName = switch ($kr.Type) {
            'logAnalyticsWorkspace' { "law-alz-$($kr.Location)" }
            'automationAccount' { "aa-alz-$($kr.Location)" }
            default { $null }
        }

        if ($engineName) {
            if ($kr.Name -eq $engineName) {
                Write-Ok "  $($kr.Type): $($kr.Name) [matches engine convention]"
            }
            else {
                Write-Warn "  $($kr.Type): $($kr.Name) [engine would use: $engineName]"
            }
        }
        else {
            Write-Info "  $($kr.Type): $($kr.Name)"
        }
    }

    # Flag missing expected resources
    $missing = @()
    if (-not $foundTypes.ContainsKey('logAnalyticsWorkspace')) { $missing += 'Log Analytics Workspace' }
    if (-not $foundTypes.ContainsKey('automationAccount')) { $missing += 'Automation Account' }
    foreach ($m in $missing) { Write-Warn "  Missing expected resource: $m" }

    $infraReport += [PSCustomObject]@{
        SubscriptionId   = $ss.SubscriptionId
        ResourceGroups   = $rgs
        KeyResources     = $keyRes
        NonAlzRgs        = $nonAlzRgs
        MissingResources = $missing
    }
}

if ($subScope.Count -eq 0) {
    Write-Info '  No subscription scope in export.'
}

#==============================================================================
# Section 6: Config Extraction
#==============================================================================
Write-Step 'Section 6: Config Extraction (draft platform.json values)'

Write-Host ''
Write-Host '  The following values were found in policy assignment parameters'
Write-Host '  and infrastructure resources. Use as a starting point for platform.json.'
Write-Host ''

$subScopeObj = @($subScope) | Select-Object -First 1

Write-Host '  {' -ForegroundColor Gray
Write-Host "    `"LOCATION_PRIMARY`": `"$($script:CollectedLocations | Select-Object -First 1)`","
if ($subScopeObj) {
    Write-Host "    `"SUBSCRIPTION_ID_MANAGEMENT`": `"$($subScopeObj.SubscriptionId)`","
}

if ($script:CollectedLawIds.Count -eq 1) {
    Write-Host "    // Log Analytics workspace found:"
    Write-Host "    // $($script:CollectedLawIds | Select-Object -First 1)"
}
elseif ($script:CollectedLawIds.Count -gt 1) {
    Write-Warn "  Multiple LAW IDs found (drift!) — review carefully:"
    foreach ($lawId in $script:CollectedLawIds) { Write-Detail "    $lawId" }
}

if ($script:CollectedEmails.Count -gt 0) {
    Write-Host "    `"SECURITY_CONTACT_EMAIL`": `"$($script:CollectedEmails | Select-Object -First 1)`","
}
if ($script:CollectedEmails.Count -gt 1) {
    Write-Warn "  Multiple email addresses found — verify which is correct:"
    foreach ($e in $script:CollectedEmails) { Write-Detail "    $e" }
}
Write-Host '  }' -ForegroundColor Gray

if ($script:CollectedDcrIds.Count -gt 0) {
    Write-Host ''
    Write-Info "  DCR IDs referenced in assignments:"
    foreach ($id in $script:CollectedDcrIds) { Write-Detail "    $id" }
}
if ($script:CollectedUamiIds.Count -gt 0) {
    Write-Host ''
    Write-Info "  UAMI IDs referenced in assignments:"
    foreach ($id in $script:CollectedUamiIds) { Write-Detail "    $id" }
}

#==============================================================================
# Section 7: Risk Summary
#==============================================================================
Write-Step 'Section 7: Risk Summary'

$totalStdDefs = 0; $totalStdMismatchDefs = 0; $totalNonStdDefs = 0; $totalAmbaDefs = 0; $totalDeprDefs = 0
$totalStdSets = 0; $totalNonStdSets = 0; $totalAmbaSets = 0; $totalDeprSets = 0
$totalNonStdAssignments = 0; $totalAmbaAssignments = 0
$totalMissingInfra = 0
$totalNonAlzRgs = 0
$totalCustomRoles = 0

foreach ($sr in $reportScopes) {
    foreach ($d in $sr.PolicyDefs) {
        switch ($d.Classification) {
            'Standard' { $totalStdDefs++ }
            'StandardMismatch' { $totalStdMismatchDefs++ }
            'NonStandard' { $totalNonStdDefs++ }
            'AMBA' { $totalAmbaDefs++ }
            'Deprecated' { $totalDeprDefs++ }
        }
    }
    foreach ($s in $sr.PolicySetDefs) {
        switch ($s.Classification) {
            'Standard' { $totalStdSets++ }
            'NonStandard' { $totalNonStdSets++ }
            'AMBA' { $totalAmbaSets++ }
            'Deprecated' { $totalDeprSets++ }
        }
    }
    foreach ($a in $sr.PolicyAssignments) {
        if ($a.ReferencesAmba) { $totalAmbaAssignments++ }
        elseif (-not $a.ReferencesStandard) { $totalNonStdAssignments++ }
    }
    foreach ($rd in $sr.RoleDefinitions) {
        if ((Get-RoleDefClassification $rd.RoleName) -eq 'Custom') { $totalCustomRoles++ }
    }
}
foreach ($ir in $infraReport) {
    $totalMissingInfra += $ir.MissingResources.Count
    $totalNonAlzRgs += $ir.NonAlzRgs.Count
}

Write-Host ''
Write-Host "  Policy Definitions:"
if ($totalStdDefs -gt 0) { Write-Ok   "    Standard — exact match:   $totalStdDefs" }
if ($totalStdMismatchDefs -gt 0) {
    $hasDenyMismatches = $script:MismatchCountByEffect['Deny'] -gt 0
    if ($hasDenyMismatches) {
        Write-Err  "    Standard — rule mismatch: $totalStdMismatchDefs (engine will overwrite on deploy)"
    } else {
        Write-Warn "    Standard — rule mismatch: $totalStdMismatchDefs (engine will overwrite on deploy)"
    }
    Write-Host ''
    Write-Host '  Rule mismatches by effect:'
    if ($script:MismatchCountByEffect['Deny']              -gt 0) { Write-Err  "    Deny:                   $($script:MismatchCountByEffect['Deny']) (review resource compliance before deploying)" }
    if ($script:MismatchCountByEffect['DeployIfNotExists'] -gt 0) { Write-Warn "    DeployIfNotExists:      $($script:MismatchCountByEffect['DeployIfNotExists']) (may trigger remediations)" }
    if ($script:MismatchCountByEffect['Modify']            -gt 0) { Write-Warn "    Modify:                 $($script:MismatchCountByEffect['Modify']) (may change resource properties)" }
    if ($script:MismatchCountByEffect['Append']            -gt 0) { Write-Info "    Append:                 $($script:MismatchCountByEffect['Append']) (may add properties on next update)" }
    if ($script:MismatchCountByEffect['Audit']             -gt 0) { Write-Ok   "    Audit/AuditIfNotExists: $($script:MismatchCountByEffect['Audit']) (informational only)" }
    if ($script:MismatchCountByEffect['Other']             -gt 0) { Write-Warn "    Other/Unknown:          $($script:MismatchCountByEffect['Other'])" }
} else { Write-Ok "    Rule mismatches:          0" }
if ($totalNonStdDefs -gt 0) { Write-Warn "    Non-standard (review):    $totalNonStdDefs" } else { Write-Ok "    Non-standard:             0" }
if ($totalAmbaDefs -gt 0) { Write-Amba "    AMBA (informational):     $totalAmbaDefs" }
if ($totalDeprDefs -gt 0) { Write-Info "    Deprecated:               $totalDeprDefs" }

Write-Host ''
Write-Host "  Policy Set Definitions:"
if ($totalStdSets -gt 0) { Write-Ok   "    Standard (safe):          $totalStdSets" }
if ($totalNonStdSets -gt 0) { Write-Warn "    Non-standard (review):    $totalNonStdSets" } else { Write-Ok "    Non-standard:             0" }
if ($totalAmbaSets -gt 0) { Write-Amba "    AMBA (informational):     $totalAmbaSets" }
if ($totalDeprSets -gt 0) { Write-Info "    Deprecated:               $totalDeprSets" }

Write-Host ''
Write-Host "  Assignments:                  Non-standard refs: $totalNonStdAssignments   AMBA refs: $totalAmbaAssignments"
Write-Host "  Custom role definitions:      $totalCustomRoles"
Write-Host "  Non-ALZ resource groups:      $totalNonAlzRgs"
Write-Host "  Missing expected resources:   $totalMissingInfra"

# Traffic light — AMBA does NOT count as non-standard for risk assessment
Write-Host ''
$hasDenyMismatches = $script:MismatchCountByEffect['Deny'] -gt 0
$hasReviewItems    = $totalNonStdDefs -gt 0 -or $totalNonStdSets -gt 0 -or $totalStdMismatchDefs -gt 0
$hasMinorDrift     = $totalDeprDefs -gt 0 -or $totalDeprSets -gt 0 -or $totalNonStdAssignments -gt 0 -or $totalNonAlzRgs -gt 0 -or $totalCustomRoles -gt 0

if (-not $hasReviewItems -and -not $hasMinorDrift) {
    Write-Colored 'GREEN' 'Green' "Brownfield is a clean portal accelerator deployment. Low risk for engine adoption."
    if ($totalAmbaDefs -gt 0 -or $totalAmbaSets -gt 0) {
        Write-Amba "  Note: AMBA monitoring stack detected ($totalAmbaDefs defs, $totalAmbaSets sets) — informational only."
    }
}
elseif ($hasDenyMismatches) {
    Write-Colored 'RED' 'Red' "Brownfield has Deny-effect policy rule changes — resource compliance must be verified before deploying."
    Write-Host '  Recommendation: Run with -Detailed to see which policies change and which resource types they target.'
    Write-Host '    a) Verify existing resources of those types comply with the updated rules'
    Write-Host '    b) Test in DoNotEnforce mode first if compliance status is uncertain'
    Write-Host '    c) Consider deploying governance-only first, then re-enable enforcement after remediation'
}
elseif ($hasReviewItems) {
    Write-Colored 'YELLOW' 'Yellow' "Brownfield has customizations or version drift that need operator decisions."
    Write-Host '  Recommendation: Run with -Detailed to review items, then decide:'
    Write-Host '    a) Add to engine config (platform.json / policy overrides)'
    Write-Host '    b) Exclude from deployment stack scope'
    Write-Host '    c) Accept removal/overwrite during stack takeover'
}
else {
    Write-Colored 'YELLOW' 'Yellow' "Brownfield has deprecated policies or minor drift — review before adoption."
}

#==============================================================================
# Optional: write JSON report
#==============================================================================
if ($OutputFile -ne '') {
    $fullReport = [PSCustomObject]@{
        ExportFile       = $BrownfieldExport
        AlzLibraryPath   = $AlzLibraryPath
        TenantId         = $export.TenantId
        ExportTimestamp  = $export.ExportTimestamp
        Scopes           = $reportScopes
        Infrastructure   = $infraReport
        ConfigExtraction = [PSCustomObject]@{
            LawIds          = @($script:CollectedLawIds)
            Emails          = @($script:CollectedEmails)
            Locations       = @($script:CollectedLocations)
            DcrIds          = @($script:CollectedDcrIds)
            UamiIds         = @($script:CollectedUamiIds)
            SubscriptionIds = @($script:CollectedSubIds)
        }
        RiskSummary      = [PSCustomObject]@{
            TotalStandardPolicyDefs         = $totalStdDefs
            TotalStandardMismatchPolicyDefs = $totalStdMismatchDefs
            TotalNonStandardPolicyDefs      = $totalNonStdDefs
            TotalAmbaPolicyDefs             = $totalAmbaDefs
            TotalDeprecatedPolicyDefs       = $totalDeprDefs
            TotalStandardPolicySets         = $totalStdSets
            TotalNonStandardPolicySets      = $totalNonStdSets
            TotalAmbaPolicySets             = $totalAmbaSets
            TotalDeprecatedPolicySets       = $totalDeprSets
            TotalNonStdAssignments          = $totalNonStdAssignments
            TotalAmbaAssignments            = $totalAmbaAssignments
            TotalCustomRoles                = $totalCustomRoles
            TotalNonAlzRgs                  = $totalNonAlzRgs
            TotalMissingInfra               = $totalMissingInfra
            MismatchByEffect                = [PSCustomObject]@{
                Deny              = $script:MismatchCountByEffect['Deny']
                DeployIfNotExists = $script:MismatchCountByEffect['DeployIfNotExists']
                Modify            = $script:MismatchCountByEffect['Modify']
                Append            = $script:MismatchCountByEffect['Append']
                Audit             = $script:MismatchCountByEffect['Audit']
                Other             = $script:MismatchCountByEffect['Other']
            }
            HasDenyMismatches               = ($script:MismatchCountByEffect['Deny'] -gt 0)
        }
    }
    $fullReport | ConvertTo-Json -Depth 10 | Set-Content $OutputFile
    Write-Host ''
    Write-Info "Full report written to: $OutputFile"
}

Write-Host ''

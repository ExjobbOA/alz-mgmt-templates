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
    Deny-effect mismatches are split into ASSIGNED (active risk) and UNASSIGNED (no current risk) blocks.

.PARAMETER IncludeAmba
    When combined with -Detailed, also expands individual AMBA and deprecated policy listings.
    Without this switch, -Detailed shows AMBA and deprecated items as counts only.

.PARAMETER DiffReport
    Optional path to write an HTML side-by-side diff report for Deny-effect policy rule mismatches.
    Requires Python 3 and scripts/diff-deny-rules.py. Opens in any browser.

.EXAMPLE
    ./scripts/Compare-BrownfieldState.ps1 -BrownfieldExport ./state-snapshots/state-sylaviken-brownfield.json

.EXAMPLE
    ./scripts/Compare-BrownfieldState.ps1 -BrownfieldExport ./state-snapshots/state-sylaviken-brownfield.json -Detailed

.EXAMPLE
    ./scripts/Compare-BrownfieldState.ps1 -BrownfieldExport ./state-snapshots/state-sylaviken-brownfield.json -Detailed -IncludeAmba -OutputFile ./report.json

.EXAMPLE
    ./scripts/Compare-BrownfieldState.ps1 -BrownfieldExport ./state-snapshots/state-sylaviken-brownfield.json -Detailed -DiffReport ./deny-diff-report.html
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BrownfieldExport,

    [string]$AlzLibraryPath = '',

    [string]$OutputFile = '',

    [string]$DiffReport = '',

    [switch]$Detailed,

    [switch]$IncludeAmba
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
# via {"field":"type","equals":"..."} or {"field":"type","in":[...]} conditions.
# Handles allOf/anyOf/not nesting. ARM parameter expressions (e.g. [[parameters('x')])
# are returned as the sentinel string "(parameterized)".
function Get-IfResourceTypes ([object]$Condition) {
    if (-not $Condition) { return @() }
    $found = [System.Collections.Generic.List[string]]::new()
    # Helper: normalize a raw type value — if it looks like an ARM expression, replace with sentinel
    $normalizeType = {
        param([string]$raw)
        if ($raw.StartsWith('[') -or $raw -match 'parameters\(') { return '(parameterized)' }
        return $raw
    }
    # Direct field=type condition with "equals"
    $fieldProp  = $Condition.PSObject.Properties['field']
    $equalsProp = $Condition.PSObject.Properties['equals']
    if ($fieldProp -and ($fieldProp.Value -ieq 'type') -and $equalsProp) {
        $v = & $normalizeType ([string]$equalsProp.Value)
        if (-not $found.Contains($v)) { [void]$found.Add($v) }
    }
    # Direct field=type condition with "in" (array)
    $inProp = $Condition.PSObject.Properties['in']
    if ($fieldProp -and ($fieldProp.Value -ieq 'type') -and $inProp -and $inProp.Value) {
        foreach ($item in @($inProp.Value)) {
            $v = & $normalizeType ([string]$item)
            if (-not $found.Contains($v)) { [void]$found.Add($v) }
        }
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

# Build MG -> direct subscription lookup from SubscriptionPlacement (added by Export-BrownfieldState v2+).
# Falls back to empty if the export was produced by an older version of the export script.
$mgSubscriptions = @{}
if ($export.PSObject.Properties['SubscriptionPlacement'] -and $export.SubscriptionPlacement) {
    $sp = $export.SubscriptionPlacement
    if ($sp -is [PSCustomObject]) {
        $sp.PSObject.Properties | ForEach-Object { $mgSubscriptions[$_.Name] = @($_.Value) }
    } elseif ($sp -is [hashtable]) {
        $mgSubscriptions = $sp
    }
}

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
    $ruleHash = if ($ruleObj) {
        $ruleJson = (ConvertTo-SortedObject $ruleObj) | ConvertTo-Json -Depth 20 -Compress
        $ruleJson = $ruleJson -replace '\[{2,}', '['  # normalize ARM escaping: [[ or [[[ (nested DINE templates) → [
        Get-SHA256Short $ruleJson
    } else { '' }
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
    Deny              = 0   # total = DenyAssigned + DenyUnassigned
    DenyAssigned      = 0   # Deny rules that are currently assigned (active risk)
    DenyUnassigned    = 0   # Deny rules that exist but are not assigned (no current impact)
    DeployIfNotExists = 0
    Modify            = 0
    Append            = 0
    Audit             = 0
    Other             = 0
}

# All StandardMismatch entries across all scopes — consumed by the DiffReport block
$script:AllStdMismatchDefList = [System.Collections.Generic.List[object]]::new()

# All Deprecated entries across all scopes — consumed by Section 7 assigned-deprecated check
$script:AllDeprDefList = [System.Collections.Generic.List[object]]::new()

# Subscription-level governance counters — populated by Section 3b
$script:TotalSubLevelNonStdAssignments = 0
$script:TotalSubLevelExemptions        = 0
$script:TotalDenyExemptions            = 0

# Networking risk counter — incremented in Section 5 for cost-duplicate scenarios
$script:NetworkingRiskCount = 0

# DNS duplicate-zone risk counter — incremented in Section 5 when brownfield zones are in the wrong RG
$script:DnsDuplicateRiskCount = 0

# Build policy set name → ALZ custom member policy definition names from library.
# Used below to expand initiative assignments to their individual member definitions.
# Seed from the export's PolicySetDefinitions.PolicyDefinitions field (populated by the
# updated Export-BrownfieldState.ps1). Fall back to ALZ library files for any sets that
# the export did not capture (e.g. older exports or non-custom sets).
$setMemberDefs = @{}

foreach ($mgScope in @($export.Scopes | Where-Object { $_.Scope -eq 'managementGroup' })) {
    foreach ($ps in @($mgScope.Resources.PolicySetDefinitions)) {
        $psName = $ps.Name
        $exportMembers = @($ps.PSObject.Properties['PolicyDefinitions'] | Select-Object -ExpandProperty Value)
        if ($exportMembers.Count -gt 0 -and -not $setMemberDefs.ContainsKey($psName)) {
            $setMemberDefs[$psName] = @($exportMembers | ForEach-Object { ($_ -split '/')[-1] } | Where-Object { $_ })
        }
    }
}

# Library fallback — fills gaps for sets not present in the export
Get-ChildItem -Path $AlzLibraryPath -Filter '*.alz_policy_set_definition.json' -Recurse | ForEach-Object {
    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
    if ($setMemberDefs.ContainsKey($j.name)) { return }  # export already has this set
    $members = [System.Collections.Generic.List[string]]::new()
    if ($j.properties.PSObject.Properties['policyDefinitions']) {
        foreach ($member in @($j.properties.policyDefinitions)) {
            $memberName = ($member.policyDefinitionId -split '/')[-1]
            if ($libPolicyDefs.ContainsKey($memberName)) {
                [void]$members.Add($memberName)
            }
        }
    }
    if ($members.Count -gt 0) { $setMemberDefs[$j.name] = @($members) }
}

# Reverse lookup: policy definition name → list of MG scopes where it is assigned.
# Handles both direct assignments and initiative (policy set) assignments.
$defAssignmentScopes = @{}

function Add-DefAssignmentScope ([string]$DefName, [string]$ScopeName, [string]$MgId) {
    if (-not $defAssignmentScopes.ContainsKey($DefName)) {
        $defAssignmentScopes[$DefName] = [System.Collections.Generic.List[object]]::new()
    }
    # Deduplicate — same def can be a member of multiple initiatives assigned at the same scope
    $already = $defAssignmentScopes[$DefName] | Where-Object { $_.ScopeName -eq $ScopeName }
    if (-not $already) {
        $defAssignmentScopes[$DefName].Add([PSCustomObject]@{
            ScopeName         = $ScopeName
            ManagementGroupId = $MgId
        })
    }
}

foreach ($mgScope in @($export.Scopes | Where-Object { $_.Scope -eq 'managementGroup' })) {
    foreach ($a in @($mgScope.Resources.PolicyAssignments)) {
        $defId   = $a.PolicyDefinitionId
        $defName = ($defId -split '/')[-1]
        if ($defId -match 'policySetDefinitions') {
            # Initiative assignment — expand to all ALZ custom member definitions
            if ($setMemberDefs.ContainsKey($defName)) {
                foreach ($memberName in $setMemberDefs[$defName]) {
                    Add-DefAssignmentScope $memberName $mgScope.Name $mgScope.ManagementGroupId
                }
            }
        } else {
            # Direct policy definition assignment
            Add-DefAssignmentScope $defName $mgScope.Name $mgScope.ManagementGroupId
        }
    }
}

# Load SubscriptionGovernance from the export (added by Export-BrownfieldState v3+).
# Falls back to empty if the export was produced by an older version.
$subscriptionGovernance = @()
if ($export.PSObject.Properties['SubscriptionGovernance'] -and $export.SubscriptionGovernance) {
    $subscriptionGovernance = @($export.SubscriptionGovernance)
}

# Build reverse-lookup: subscription ID -> parent MG ID (from SubscriptionPlacement).
# Used to populate ManagementGroupId when feeding sub-level assignments into defAssignmentScopes.
$subIdToMgId = @{}
foreach ($mgId in $mgSubscriptions.Keys) {
    foreach ($sub in @($mgSubscriptions[$mgId])) {
        $subId = if ($sub.PSObject.Properties['Id']) { $sub.Id } elseif ($sub -is [string]) { $sub } else { $null }
        if ($subId -and -not $subIdToMgId.ContainsKey($subId)) {
            $subIdToMgId[$subId] = $mgId
        }
    }
}

# Feed subscription-level assignments into defAssignmentScopes so that assigned-vs-unassigned
# classification in Compare accounts for sub-scoped direct assignments.
foreach ($subGov in $subscriptionGovernance) {
    $subId = if ($subGov.PSObject.Properties['SubscriptionId']) { $subGov.SubscriptionId } else { $null }
    if (-not $subId) { continue }
    $parentMgId = if ($subIdToMgId.ContainsKey($subId)) { $subIdToMgId[$subId] } else { '' }
    $subScopeName = "sub-$subId"

    foreach ($a in @($subGov.PolicyAssignments)) {
        $defId   = if ($a.PSObject.Properties['PolicyDefinitionId']) { $a.PolicyDefinitionId } else { '' }
        $defName = ($defId -split '/')[-1]
        if (-not $defName) { continue }
        if ($defId -match 'policySetDefinitions') {
            if ($setMemberDefs.ContainsKey($defName)) {
                foreach ($memberName in $setMemberDefs[$defName]) {
                    Add-DefAssignmentScope $memberName $subScopeName $parentMgId
                }
            }
        } else {
            Add-DefAssignmentScope $defName $subScopeName $parentMgId
        }
    }
}

# Recursively collect all MG IDs under a hierarchy node (used for subscription resolution)
function Get-AllMgIdsUnderNode ([object]$Node) {
    $ids = [System.Collections.Generic.List[string]]::new()
    [void]$ids.Add($Node.Name)
    if ($Node.Children) {
        foreach ($child in @($Node.Children)) {
            foreach ($childId in @(Get-AllMgIdsUnderNode $child)) { [void]$ids.Add($childId) }
        }
    }
    return @($ids)
}

# Find a node in the MG hierarchy by ID
function Find-HierarchyNode ([object]$Node, [string]$TargetId) {
    if ($Node.Name -ieq $TargetId) { return $Node }
    if ($Node.Children) {
        foreach ($child in @($Node.Children)) {
            $found = Find-HierarchyNode $child $TargetId
            if ($found) { return $found }
        }
    }
    return $null
}

# Return all subscriptions placed under $MgId (including descendant MGs), using SubscriptionPlacement data.
# Returns objects with Id and DisplayName. Returns empty array if SubscriptionPlacement is not in the export.
function Get-SubsUnderMg ([string]$MgId) {
    if ($mgSubscriptions.Count -eq 0) { return @() }
    $node = Find-HierarchyNode $export.ManagementGroupHierarchy $MgId
    if (-not $node) { return @() }
    $subs = [System.Collections.Generic.List[object]]::new()
    foreach ($id in @(Get-AllMgIdsUnderNode $node)) {
        if ($mgSubscriptions.ContainsKey($id)) {
            foreach ($sub in @($mgSubscriptions[$id])) { [void]$subs.Add($sub) }
        }
    }
    return @($subs)
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
                $stdMismatchDefs++
                # Compute effect and assignment status for all mismatches (used in Section 7 and DiffReport)
                $mLibEntry  = $libPolicyDefs[$def.Name]
                $mEffect    = if ($mLibEntry -and $mLibEntry.Effect) { $mLibEntry.Effect } else { 'Unknown' }
                $mCat       = Get-EffectCategory $mEffect
                $isAssigned = $defAssignmentScopes.ContainsKey($def.Name) -and $defAssignmentScopes[$def.Name].Count -gt 0
                # Enrich the entry with effect and assignment status for DiffReport consumption
                $defEntry | Add-Member -NotePropertyName Effect     -NotePropertyValue $mEffect    -Force
                $defEntry | Add-Member -NotePropertyName IsAssigned -NotePropertyValue $isAssigned -Force
                $stdMismatchDefList += $defEntry
                [void]$script:AllStdMismatchDefList.Add($defEntry)
                # Track effect category for Section 7 risk summary
                if ($mCat -eq 'Deny') {
                    $script:MismatchCountByEffect['Deny']++
                    if ($isAssigned) { $script:MismatchCountByEffect['DenyAssigned']++ }
                    else             { $script:MismatchCountByEffect['DenyUnassigned']++ }
                } else {
                    $script:MismatchCountByEffect[$mCat]++
                }
            }
            'NonStandard' { $nonStdDefs++; $nonStdDefList += $defEntry }
            'AMBA' { $ambaDefs++; $ambaDefList += $defEntry }
            'Deprecated' { $deprDefs++; $deprDefList += $defEntry; [void]$script:AllDeprDefList.Add($defEntry) }
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
            # Non-Deny mismatches first (DINE, Modify, Append, Audit, Other)
            foreach ($e in $stdMismatchDefList) {
                $libEntry  = $libPolicyDefs[$e.Name]
                $bfVer     = if ($e.Version) { $e.Version } else { '?' }
                $libVer    = if ($libEntry -and $libEntry.Version) { $libEntry.Version } else { '?' }
                $effect    = if ($libEntry -and $libEntry.Effect) { $libEntry.Effect } else { 'Unknown' }
                $resTypes  = if ($libEntry -and $libEntry.TargetResourceTypes -and $libEntry.TargetResourceTypes.Count -gt 0) {
                    $libEntry.TargetResourceTypes -join ', '
                } else { '(unknown)' }
                $effCat = Get-EffectCategory $effect
                if ($effCat -eq 'Deny') { continue }   # handled in the two Deny blocks below
                switch ($effCat) {
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

            # Deny mismatches — split into ASSIGNED (active risk) and UNASSIGNED (no current risk)
            $denyMismatches = @($stdMismatchDefList | Where-Object {
                $mLib = $libPolicyDefs[$_.Name]
                $eff  = if ($mLib -and $mLib.Effect) { $mLib.Effect } else { 'Unknown' }
                (Get-EffectCategory $eff) -eq 'Deny'
            })
            if ($denyMismatches.Count -gt 0) {
                $denyAssigned   = @($denyMismatches | Where-Object {
                    $defAssignmentScopes.ContainsKey($_.Name) -and $defAssignmentScopes[$_.Name].Count -gt 0
                })
                $denyUnassigned = @($denyMismatches | Where-Object {
                    -not ($defAssignmentScopes.ContainsKey($_.Name) -and $defAssignmentScopes[$_.Name].Count -gt 0)
                })

                if ($denyAssigned.Count -gt 0) {
                    Write-Host ''
                    Write-Err "  ── Deny-effect rule changes: ASSIGNED ($($denyAssigned.Count) — active risk) ──"
                    foreach ($e in $denyAssigned) {
                        $libEntry  = $libPolicyDefs[$e.Name]
                        $bfVer     = if ($e.Version) { $e.Version } else { '?' }
                        $libVer    = if ($libEntry -and $libEntry.Version) { $libEntry.Version } else { '?' }
                        $resTypes  = if ($libEntry -and $libEntry.TargetResourceTypes -and $libEntry.TargetResourceTypes.Count -gt 0) {
                            $libEntry.TargetResourceTypes -join ', '
                        } else { '(unknown)' }
                        $assignScopes = @($defAssignmentScopes[$e.Name])
                        $scopeStr = ($assignScopes | ForEach-Object { "$($_.ScopeName) ($($_.ManagementGroupId))" }) -join ', '
                        Write-Err    "  [DENY RULE CHANGE] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  library=$libVer"
                        Write-Detail "    targets: $resTypes"
                        Write-Detail "    assigned at: $scopeStr"
                        if ($mgSubscriptions.Count -gt 0) {
                            $allSubsInScope = [System.Collections.Generic.List[string]]::new()
                            foreach ($as in $assignScopes) {
                                foreach ($sub in @(Get-SubsUnderMg $as.ManagementGroupId)) {
                                    $subLabel = if ($sub.PSObject.Properties['DisplayName'] -and $sub.DisplayName) { "$($sub.DisplayName) ($($sub.Id))" } else { $sub.Id }
                                    if (-not $allSubsInScope.Contains($subLabel)) { [void]$allSubsInScope.Add($subLabel) }
                                }
                            }
                            if ($allSubsInScope.Count -gt 0) {
                                Write-Detail "    subscriptions in scope: $($allSubsInScope -join ', ')"
                            } else {
                                Write-Detail "    subscriptions in scope: (none placed under assigned MGs)"
                            }
                        } else {
                            Write-Detail "    subscriptions in scope: (re-run Export-BrownfieldState.ps1 to capture subscription placement)"
                        }
                        Write-Err    "    ⚠ Deny-effect rule is changing — verify resources of this type comply before deploying"
                    }
                }

                if ($denyUnassigned.Count -gt 0) {
                    Write-Host ''
                    Write-Warn "  ── Deny-effect rule changes: UNASSIGNED ($($denyUnassigned.Count) — no current risk) ──"
                    foreach ($e in $denyUnassigned) {
                        $libEntry  = $libPolicyDefs[$e.Name]
                        $bfVer     = if ($e.Version) { $e.Version } else { '?' }
                        $libVer    = if ($libEntry -and $libEntry.Version) { $libEntry.Version } else { '?' }
                        $resTypes  = if ($libEntry -and $libEntry.TargetResourceTypes -and $libEntry.TargetResourceTypes.Count -gt 0) {
                            $libEntry.TargetResourceTypes -join ', '
                        } else { '(unknown)' }
                        Write-Warn   "  [DENY RULE CHANGE] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  library=$libVer"
                        Write-Detail "    targets: $resTypes"
                        Write-Detail "    (definition exists but is not assigned — no operational impact unless assigned later)"
                    }
                }
            }

            foreach ($e in $nonStdDefList) {
                Write-Warn "  [NON-STD] $($e.Name)  —  $($e.DisplayName)"
            }
            if ($Detailed -and $IncludeAmba) {
                foreach ($e in $ambaDefList) {
                    Write-Amba "  [AMBA] $($e.Name)  —  $($e.DisplayName)"
                }
                foreach ($e in $deprDefList) {
                    Write-Info "  [DEPRECATED] $($e.Name)  —  $($e.DisplayName)"
                }
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
            if ($IncludeAmba) {
                foreach ($e in $ambaSetList) {
                    Write-Amba "  [AMBA] $($e.Name)  —  $($e.DisplayName)"
                }
                foreach ($e in $deprSetList) {
                    Write-Info "  [DEPRECATED] $($e.Name)  —  $($e.DisplayName)"
                }
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
# Section 3b: Subscription-Level Assignments & Exemptions
#==============================================================================
Write-Step 'Section 3b: Subscription-Level Assignments & Exemptions'

$script:TotalSubLevelNonStdAssignments = 0
$script:TotalSubLevelExemptions        = 0
$script:TotalDenyExemptions            = 0

if ($subscriptionGovernance.Count -eq 0) {
    Write-Info '  No subscription governance data in export.'
    Write-Info '  Re-run Export-BrownfieldState.ps1 to capture subscription-level assignments and exemptions.'
}
else {
    foreach ($subGov in $subscriptionGovernance) {
        $subId          = if ($subGov.PSObject.Properties['SubscriptionId']) { $subGov.SubscriptionId } else { '(unknown)' }
        $subDisplayName = if ($subGov.PSObject.Properties['DisplayName'] -and $subGov.DisplayName) { $subGov.DisplayName } else { $subId }
        $subAssignments = @(if ($subGov.PSObject.Properties['PolicyAssignments']) { $subGov.PolicyAssignments } else { @() })
        $subExemptions  = @(if ($subGov.PSObject.Properties['PolicyExemptions'])  { $subGov.PolicyExemptions  } else { @() })

        if ($subAssignments.Count -eq 0 -and $subExemptions.Count -eq 0) { continue }

        Write-Host ''
        Write-Host "  ── Subscription: $subDisplayName ($subId) ──"

        # --- Assignments ---
        if ($subAssignments.Count -gt 0) {
            $stdA = 0; $nonStdA = 0; $ambaA = 0; $dneA = 0
            foreach ($a in $subAssignments) {
                $defId   = if ($a.PSObject.Properties['PolicyDefinitionId']) { $a.PolicyDefinitionId } else { '' }
                $defName = ($defId -split '/')[-1]
                $aName   = if ($a.PSObject.Properties['ResourceId']) { ($a.ResourceId -split '/')[-1] } else { '' }
                $em      = if ($a.PSObject.Properties['EnforcementMode']) { $a.EnforcementMode } else { 'Default' }

                $refStd  = $libPolicyDefs.ContainsKey($defName) -or $libPolicySetDefs.ContainsKey($defName) -or $libAssignmentNames.Contains($aName)
                $refAmba = $ambaDefNames.Contains($defName) -or $ambaSetNames.Contains($defName)

                if ($em -eq 'DoNotEnforce') { $dneA++ }
                if ($refAmba)      { $ambaA++ }
                elseif ($refStd)   { $stdA++ }
                else               { $nonStdA++; $script:TotalSubLevelNonStdAssignments++ }

                if ($Detailed) {
                    $emLabel  = if ($em -eq 'DoNotEnforce') { 'DoNotEnforce' } else { 'Enforced' }
                    $refLabel = if ($refStd) { '[std]' } elseif ($refAmba) { '[amba]' } else { '[non-std]' }
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
                Write-Ok "  $($subAssignments.Count) direct policy assignment(s)"
                if ($nonStdA -gt 0) { Write-Warn "    $nonStdA reference non-standard definitions" }
                if ($ambaA   -gt 0) { Write-Amba "    $ambaA reference AMBA definitions" }
                if ($dneA    -gt 0) { Write-Info "    $dneA in DoNotEnforce mode" }
            }
        }

        # --- Exemptions ---
        if ($subExemptions.Count -gt 0) {
            $script:TotalSubLevelExemptions += $subExemptions.Count

            foreach ($ex in $subExemptions) {
                $exName     = if ($ex.PSObject.Properties['Name'])            { $ex.Name }            else { '(unknown)' }
                $exDisplay  = if ($ex.PSObject.Properties['DisplayName'] -and $ex.DisplayName) { $ex.DisplayName } else { $exName }
                $exCat      = if ($ex.PSObject.Properties['ExemptionCategory']) { $ex.ExemptionCategory } else { '(unknown)' }
                $exAssignId = if ($ex.PSObject.Properties['PolicyAssignmentId']) { $ex.PolicyAssignmentId } else { '' }

                # Check if the exempted assignment targets a Deny-effect policy
                $exAssignDefName = ($exAssignId -split '/')[-1]
                $isDenyExemption = $false
                if ($libPolicyDefs.ContainsKey($exAssignDefName)) {
                    $exEffect = $libPolicyDefs[$exAssignDefName].Effect
                    $isDenyExemption = (Get-EffectCategory $exEffect) -eq 'Deny'
                }
                if ($isDenyExemption) { $script:TotalDenyExemptions++ }

                if ($isDenyExemption) {
                    Write-Warn "  [EXEMPTION] $exDisplay  (category: $exCat)"
                    Write-Warn "    ⚠ Exempts a Deny-effect policy — verify this exemption is intentional"
                    Write-Detail "    assignment: $exAssignId"
                }
                elseif ($Detailed) {
                    Write-Info "  [EXEMPTION] $exDisplay  (category: $exCat)"
                    Write-Detail "    assignment: $exAssignId"
                }
                else {
                    Write-Info "  $($subExemptions.Count) policy exemption(s)  (use -Detailed to list)"
                    break  # summarised — don't print per-exemption in non-detailed mode
                }
            }
        }
    }

    if ($subscriptionGovernance.Count -gt 0 -and
        ($subscriptionGovernance | ForEach-Object { $_.PolicyAssignments.Count + $_.PolicyExemptions.Count } | Measure-Object -Sum).Sum -eq 0) {
        Write-Info '  No subscription-level assignments or exemptions found.'
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

    # --- Hub Networking Assessment ---
    $networkingWarnings = [System.Collections.Generic.List[string]]::new()

    $ddosFound    = @($keyRes | Where-Object { $_.Type -eq 'ddosProtectionPlan' })
    $firewallsF   = @($keyRes | Where-Object { $_.Type -eq 'azureFirewall' })
    $vpnGwsFound  = @($keyRes | Where-Object { $_.Type -eq 'vpnGateway' })
    $erGwsFound   = @($keyRes | Where-Object { $_.Type -eq 'expressRouteGateway' })
    $bastionsF    = @($keyRes | Where-Object { $_.Type -eq 'bastionHost' })
    $fwPoliciesF  = @($keyRes | Where-Object { $_.Type -eq 'firewallPolicy' })
    $resolversF   = @($keyRes | Where-Object { $_.Type -eq 'dnsPrivateResolver' })
    $dcrsF        = @($keyRes | Where-Object { $_.Type -eq 'dataCollectionRule' })
    $uamisF       = @($keyRes | Where-Object { $_.Type -eq 'userAssignedIdentity' })
    $hubVnetsF    = @($keyRes | Where-Object { $_.Type -eq 'hubVirtualNetwork' })
    $routeTablesF = @($keyRes | Where-Object { $_.Type -eq 'routeTable' })

    $hasAnyNetworking = $ddosFound.Count -gt 0 -or $firewallsF.Count -gt 0 -or $vpnGwsFound.Count -gt 0 -or
                        $erGwsFound.Count -gt 0 -or $bastionsF.Count -gt 0 -or $fwPoliciesF.Count -gt 0 -or
                        $resolversF.Count -gt 0 -or $hubVnetsF.Count -gt 0
    if ($hasAnyNetworking) {
        Write-Host ''
        Write-Host "  Hub Networking Assessment:"

        # DDoS Protection Plans
        if ($ddosFound.Count -gt 0) {
            foreach ($ddos in $ddosFound) {
                Write-Warn "  [COST]  DDoS Protection Plan: $($ddos.Name) (~`$2,944/month)"
                Write-Detail "          Engine would deploy: YES (unless deployDdosProtectionPlan=false in hubnetworking params)"
                Write-Detail "          Risk: DUPLICATE COST — pass existing plan ID as override or disable engine DDoS deployment"
                [void]$networkingWarnings.Add("DDoS plan exists: $($ddos.Name)")
                $script:NetworkingRiskCount++
            }
        }

        # Azure Firewalls
        if ($firewallsF.Count -gt 0) {
            foreach ($fw in $firewallsF) {
                $fwSku = if ($fw.PSObject.Properties['Sku'] -and $fw.Sku) {
                    $skuObj = $fw.Sku
                    if ($skuObj -is [hashtable]) { " (SKU: $($skuObj.Name)/$($skuObj.Tier))" }
                    elseif ($skuObj.PSObject.Properties['Name']) { " (SKU: $($skuObj.Name)/$($skuObj.Tier))" }
                    else { '' }
                } else { '' }
                Write-Warn "  [COST]  Azure Firewall: $($fw.Name)$fwSku"
                Write-Detail "          Engine deploys its own firewall by default with hubnetworking"
                Write-Detail "          Risk: DUPLICATE if both target AzureFirewallSubnet in the same VNet"
                [void]$networkingWarnings.Add("Firewall exists: $($fw.Name) — engine deploys its own by default")
            }
        }

        # VPN Gateways
        if ($vpnGwsFound.Count -gt 0) {
            foreach ($gw in $vpnGwsFound) {
                $skuStr = if ($gw.PSObject.Properties['Sku'] -and $gw.Sku) { " (SKU: $($gw.Sku))" } else { '' }
                Write-Warn "  [COST]  VPN Gateway: $($gw.Name)$skuStr (30+ min deploy, significant monthly cost)"
                Write-Detail "          Engine deploys VPN gateway if enabled in hubnetworking config"
                Write-Detail "          Risk: DUPLICATE COST — disable engine VPN gateway or reuse existing"
                [void]$networkingWarnings.Add("VPN gateway exists: $($gw.Name) — disable engine VPN gateway or reuse")
                $script:NetworkingRiskCount++
            }
        }

        # ExpressRoute Gateways
        if ($erGwsFound.Count -gt 0) {
            foreach ($gw in $erGwsFound) {
                $skuStr = if ($gw.PSObject.Properties['Sku'] -and $gw.Sku) { " (SKU: $($gw.Sku))" } else { '' }
                Write-Warn "  [COST]  ExpressRoute Gateway: $($gw.Name)$skuStr (significant monthly cost)"
                Write-Detail "          Engine deploys ER gateway if enabled in hubnetworking config"
                Write-Detail "          Risk: DUPLICATE COST — disable engine ER gateway or reuse existing"
                [void]$networkingWarnings.Add("ExpressRoute gateway exists: $($gw.Name) — disable engine ER gateway or reuse")
                $script:NetworkingRiskCount++
            }
        }

        # Bastion Hosts
        if ($bastionsF.Count -gt 0) {
            foreach ($b in $bastionsF) {
                $skuStr = if ($b.PSObject.Properties['Sku'] -and $b.Sku) { " (SKU: $($b.Sku))" } else { '' }
                Write-Info "  [INFO]  Bastion Host: $($b.Name)$skuStr"
                Write-Detail "          Engine deploys Bastion by default — verify AzureBastionSubnet not duplicated"
            }
        }

        # Firewall Policies
        if ($fwPoliciesF.Count -gt 0) {
            foreach ($fp in $fwPoliciesF) {
                $tierStr = if ($fp.PSObject.Properties['SkuTier'] -and $fp.SkuTier) { " (tier: $($fp.SkuTier))" } else { '' }
                Write-Warn "  [INFO]  Firewall Policy: $($fp.Name)$tierStr"
                Write-Detail "          Engine creates its own policy unless firewallPolicyId override is provided"
                Write-Detail "          Existing policy ResourceId (for override): $($fp.ResourceId)"
                [void]$networkingWarnings.Add("Firewall policy exists: $($fp.Name) — set as firewallPolicyId override if desired")
            }
        }

        # Hub VNets + route table notes
        if ($hubVnetsF.Count -gt 0) {
            foreach ($vnet in $hubVnetsF) {
                $addrStr = if ($vnet.PSObject.Properties['AddressSpace'] -and $vnet.AddressSpace) { $vnet.AddressSpace -join ', ' } else { '(unknown)' }
                Write-Info "  [INFO]  Hub VNet: $($vnet.Name) ($addrStr)"
                Write-Detail "          Engine default hub address: 10.20.0.0/16 — verify no overlap with workload spokes"
            }
            if ($routeTablesF.Count -gt 0) {
                Write-Info "  [INFO]  Route tables: $($routeTablesF.Count) found"
                Write-Detail "          Engine creates route tables pointing 0.0.0.0/0 → firewall private IP"
                Write-Detail "          If existing route tables use a different firewall IP, traffic will reroute on first deploy"
            }
        }

        # DNS Private Resolvers
        if ($resolversF.Count -gt 0) {
            foreach ($r in $resolversF) {
                Write-Warn "  [INFO]  DNS Private Resolver: $($r.Name)"
                Write-Detail "          Engine conditionally deploys a resolver — verify DNS chain does not conflict"
                Write-Detail "          Engine DNS chain: Resolver → FW Policy DNS proxy → VNet custom DNS"
                [void]$networkingWarnings.Add("DNS Private Resolver exists: $($r.Name) — verify engine DNS chain compatibility")
            }
        }

        # DCRs and UAMIs
        if ($dcrsF.Count -gt 0) {
            Write-Info "  [INFO]  Data Collection Rules: $($dcrsF.Count)"
            Write-Detail "          Engine deploys 3 DCRs (VM Insights, Change Tracking, MDFC SQL)"
            Write-Detail "          Existing DCRs are not removed; workloads referencing old DCRs are unaffected"
        }
        if ($uamisF.Count -gt 0) {
            Write-Info "  [INFO]  User Assigned Managed Identities: $($uamisF.Count)"
            Write-Detail "          Engine creates its own UAMI for AMA — coexists with existing UAMIs"
        }
    }

    $infraReport += [PSCustomObject]@{
        SubscriptionId     = $ss.SubscriptionId
        ResourceGroups     = $rgs
        KeyResources       = $keyRes
        NonAlzRgs          = $nonAlzRgs
        MissingResources   = $missing
        NetworkingWarnings = @($networkingWarnings)
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

if ($script:DnsDuplicateRiskCount -gt 0) {
    Write-Host ''
    Write-Warn "  Private DNS zone config (DUPLICATE_RISK detected):"
    Write-Detail "    Engine DNS RG naming: rg-alz-dns-{location}  (parDnsResourceGroupNamePrefix)"
    Write-Detail "    To avoid duplicates, either move brownfield zones to that RG pre-migration,"
    Write-Detail "    or add to hubnetworking bicepparam:"
    Write-Detail '      privateDnsSettings: { deployPrivateDnsZones: false }'
}

# Platform subscription mapping from SubscriptionPlacement (requires Export-BrownfieldState v2+)
Write-Host ''
Write-Host '  Platform subscription mapping (from MG placement):'
if ($mgSubscriptions.Count -gt 0) {
    $platformMgMap = @{
        'management'   = 'SUBSCRIPTION_ID_MANAGEMENT'
        'connectivity' = 'SUBSCRIPTION_ID_CONNECTIVITY'
        'identity'     = 'SUBSCRIPTION_ID_IDENTITY'
        'security'     = 'SUBSCRIPTION_ID_SECURITY'
    }
    # Build normalized name -> actual MG ID from hierarchy
    $normalizedToActualMg = @{}
    if ($export.ManagementGroupHierarchy) {
        foreach ($id in @(Get-AllMgIdsUnderNode $export.ManagementGroupHierarchy)) {
            $norm = $id -replace '(?i)^alz-', ''
            $normalizedToActualMg[$norm.ToLower()] = $id
        }
    }
    foreach ($normName in @('management', 'connectivity', 'identity', 'security')) {
        $key = $platformMgMap[$normName]
        $actualId = if ($normalizedToActualMg.ContainsKey($normName)) { $normalizedToActualMg[$normName] } else { $normName }
        $subs = @(Get-SubsUnderMg $actualId)
        if ($subs.Count -eq 1) {
            $sub = $subs[0]
            $subId = if ($sub.PSObject.Properties['Id']) { $sub.Id } else { '(unknown)' }
            $subName = if ($sub.PSObject.Properties['DisplayName'] -and $sub.DisplayName) { " ($($sub.DisplayName))" } else { '' }
            Write-Ok "    $key`: $subId$subName"
        } elseif ($subs.Count -gt 1) {
            Write-Warn "    $key`: multiple subscriptions found under $actualId — check placement:"
            foreach ($sub in $subs) {
                $subId = if ($sub.PSObject.Properties['Id']) { $sub.Id } else { '?' }
                $subName = if ($sub.PSObject.Properties['DisplayName'] -and $sub.DisplayName) { $sub.DisplayName } else { '' }
                Write-Detail "      $subId ($subName)"
            }
        } else {
            Write-Detail "    $key`: (none found — check tenant root for unplaced subs or MG named '$actualId')"
        }
    }
} else {
    Write-Detail "    (not available — re-run Export-BrownfieldState.ps1 to capture subscription placement)"
}

# Hub networking from infrastructure scan
Write-Host ''
Write-Host '  Hub networking (from infrastructure scan):'
$hubVnets        = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'hubVirtualNetwork' })
$firewalls       = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'azureFirewall' })
$privateDnsZones = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'privateDnsZone' })
$ddosPlansAll    = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'ddosProtectionPlan' })
$vpnGwsAll       = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'vpnGateway' })
$erGwsAll        = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'expressRouteGateway' })
$bastionsAll     = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'bastionHost' })
$fwPoliciesAll   = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'firewallPolicy' })
$resolversAll    = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'dnsPrivateResolver' })
$dcrsAll         = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'dataCollectionRule' })
$uamisAll        = @($infraReport | ForEach-Object { $_.KeyResources } | Where-Object { $_.Type -eq 'userAssignedIdentity' })

if ($hubVnets.Count -gt 0) {
    foreach ($vnet in $hubVnets) {
        $addrSpace = if ($vnet.PSObject.Properties['AddressSpace'] -and $vnet.AddressSpace) { $vnet.AddressSpace -join ', ' } else { '(unknown)' }
        Write-Ok "    Hub VNet: $($vnet.Name) ($addrSpace) in $($vnet.ResourceGroup)"
    }
} else {
    Write-Detail "    Hub VNet: (none found — check -PlatformSubscriptionIds covers the connectivity sub)"
}
if ($firewalls.Count -gt 0) {
    foreach ($fw in $firewalls) {
        Write-Warn "    Azure Firewall: $($fw.Name) in $($fw.ResourceGroup) [engine will also deploy one by default]"
    }
} else {
    Write-Detail "    Azure Firewall: (none found)"
}
if ($ddosPlansAll.Count -gt 0) {
    foreach ($d in $ddosPlansAll) {
        Write-Warn "    DDoS Protection Plan: $($d.Name) (~`$2,944/month — engine may deploy a second)"
    }
} else {
    Write-Detail "    DDoS Protection Plan: (none found)"
}
if ($vpnGwsAll.Count -gt 0) {
    foreach ($gw in $vpnGwsAll) { Write-Warn "    VPN Gateway: $($gw.Name) (cost + 30-min deploy — engine may add another if enabled)" }
} else {
    Write-Detail "    VPN Gateway: (none found)"
}
if ($erGwsAll.Count -gt 0) {
    foreach ($gw in $erGwsAll) { Write-Warn "    ExpressRoute Gateway: $($gw.Name) (significant cost — engine may add another if enabled)" }
} else {
    Write-Detail "    ExpressRoute Gateway: (none found)"
}
if ($bastionsAll.Count -gt 0) {
    foreach ($b in $bastionsAll) { Write-Info "    Bastion Host: $($b.Name)" }
} else {
    Write-Detail "    Bastion Host: (none found)"
}
if ($fwPoliciesAll.Count -gt 0) {
    foreach ($fp in $fwPoliciesAll) {
        Write-Info "    Firewall Policy: $($fp.Name) (engine creates its own unless firewallPolicyId override is set)"
    }
}
if ($resolversAll.Count -gt 0) {
    foreach ($r in $resolversAll) { Write-Warn "    DNS Private Resolver: $($r.Name) (verify DNS chain compatibility with engine)" }
}
# ── Private DNS Zone Assessment ──
Write-Host ''
Write-Host '  Private DNS Zone Assessment:'
if ($privateDnsZones.Count -eq 0) {
    Write-Detail "    (none found — engine will create the full Private Link zone set on deployment)"
} else {
    # Zone inventory by resource group
    $zonesByRg = [ordered]@{}
    foreach ($z in ($privateDnsZones | Sort-Object ResourceGroup, Name)) {
        if (-not $zonesByRg.ContainsKey($z.ResourceGroup)) {
            $zonesByRg[$z.ResourceGroup] = [System.Collections.Generic.List[object]]::new()
        }
        $zonesByRg[$z.ResourceGroup].Add($z)
    }
    Write-Info "    Zone inventory ($($privateDnsZones.Count) total):"
    foreach ($rg in $zonesByRg.Keys) {
        Write-Detail "      $rg ($($zonesByRg[$rg].Count) zones)"
    }

    # Engine default zones (avm/ptn/network/private-link-private-dns-zones:0.7.2)
    # Source: state-snapshots/state-alen-after-cd4.json — update if AVM module version changes
    $engineDefaultZones = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    @(
        'privatelink.adf.azure.com'
        'privatelink.agentsvc.azure-automation.net'
        'privatelink.afs.azure.net'
        'privatelink.api.adu.microsoft.com'
        'privatelink.api.azureml.ms'
        'privatelink.azure-automation.net'
        'privatelink.azure-devices.net'
        'privatelink.azure-devices-provisioning.net'
        'privatelink.azurecr.io'
        'privatelink.azuredatabricks.net'
        'privatelink.azurehdinsight.net'
        'privatelink.azureiotcentral.com'
        'privatelink.azurewebsites.net'
        'privatelink.batch.azure.com'
        'privatelink.blob.core.windows.net'
        'privatelink.cassandra.cosmos.azure.com'
        'privatelink.cognitiveservices.azure.com'
        'privatelink.datafactory.azure.net'
        'privatelink.dev.azuresynapse.net'
        'privatelink.dfs.core.windows.net'
        'privatelink.directline.botframework.com'
        'privatelink.documents.azure.com'
        'privatelink.dp.kubernetesconfiguration.azure.com'
        'privatelink.eventgrid.azure.net'
        'privatelink.file.core.windows.net'
        'privatelink.grafana.azure.com'
        'privatelink.gremlin.cosmos.azure.com'
        'privatelink.guestconfiguration.azure.com'
        'privatelink.his.arc.azure.com'
        'privatelink.media.azure.net'
        'privatelink.mongo.cosmos.azure.com'
        'privatelink.monitor.azure.com'
        'privatelink.notebooks.azure.net'
        'privatelink.ods.opinsights.azure.com'
        'privatelink.oms.opinsights.azure.com'
        'privatelink.prod.migration.windowsazure.com'
        'privatelink.queue.core.windows.net'
        'privatelink.redis.cache.windows.net'
        'privatelink.search.windows.net'
        'privatelink.service.signalr.net'
        'privatelink.servicebus.windows.net'
        'privatelink.siterecovery.windowsazure.com'
        'privatelink.sql.azuresynapse.net'
        'privatelink.table.core.windows.net'
        'privatelink.table.cosmos.azure.com'
        'privatelink.vaultcore.azure.net'
        'privatelink.web.core.windows.net'
        'privatelink.wvd.microsoft.com'
    ) | ForEach-Object { [void]$engineDefaultZones.Add($_) }

    # Hub VNet resource IDs for link detection
    $hubVnetIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($vnet in $hubVnets) {
        if ($vnet.PSObject.Properties['ResourceId'] -and $vnet.ResourceId) {
            [void]$hubVnetIds.Add($vnet.ResourceId)
        }
    }

    $matchCount          = 0
    $duplicateRiskCount  = 0
    $extraCount          = 0
    $activeCount         = 0
    $hubLinkedCount      = 0
    $dnsRgSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Engine DNS RG pattern: parDnsResourceGroupNamePrefix (default 'rg-alz-dns') + '-' + location
    $engineDnsRgPattern = 'rg-alz-dns-*'

    Write-Host ''
    foreach ($zone in ($privateDnsZones | Sort-Object Name)) {
        # Engine default check — also matches region-parameterized backup zone
        $isEngineZone = $engineDefaultZones.Contains($zone.Name) -or
                        ($zone.Name -match '^privatelink\.\w+\.backup\.windowsazure\.com$')

        $recordCount      = if ($zone.PSObject.Properties['RecordSetCount']) { $zone.RecordSetCount } else { $null }
        $hasActiveRecords = $null -ne $recordCount -and $recordCount -gt 2

        $vnetLinks  = if ($zone.PSObject.Properties['VNetLinks']) { @($zone.VNetLinks) } else { @() }
        $hubLinks   = @($vnetLinks | Where-Object {
            $_.PSObject.Properties['VirtualNetworkId'] -and $hubVnetIds.Contains($_.VirtualNetworkId)
        })
        $spokeLinks = @($vnetLinks | Where-Object {
            -not ($_.PSObject.Properties['VirtualNetworkId'] -and $hubVnetIds.Contains($_.VirtualNetworkId))
        })

        $flags = [System.Collections.Generic.List[string]]::new()
        if ($hasActiveRecords)       { [void]$flags.Add("ACTIVE_RECORDS:$recordCount") }
        if ($hubLinks.Count -gt 0)   { [void]$flags.Add('HUB_LINKED') }
        if ($spokeLinks.Count -gt 0) { [void]$flags.Add("SPOKE_LINKS:$($spokeLinks.Count)") }
        $flagStr = if ($flags.Count -gt 0) { "  [$($flags -join ', ')]" } else { '' }

        if ($isEngineZone) {
            if ($zone.ResourceGroup -like $engineDnsRgPattern) {
                $matchCount++
                Write-Ok   "    MATCH           $($zone.Name)$flagStr"
            } else {
                $duplicateRiskCount++
                $script:DnsDuplicateRiskCount++
                [void]$dnsRgSet.Add($zone.ResourceGroup)
                Write-Err  "    DUPLICATE_RISK  $($zone.Name)  (in $($zone.ResourceGroup))$flagStr"
            }
        } else {
            $extraCount++
            Write-Info "    EXTRA           $($zone.Name)$flagStr"
        }

        if ($hasActiveRecords)     { $activeCount++ }
        if ($hubLinks.Count -gt 0) { $hubLinkedCount++ }
    }

    # MISSING: engine defaults not present in brownfield
    $brownfieldZoneSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($z in $privateDnsZones) { [void]$brownfieldZoneSet.Add($z.Name) }
    $missingCount = 0
    foreach ($ez in $engineDefaultZones) {
        if (-not $brownfieldZoneSet.Contains($ez)) { $missingCount++ }
    }

    Write-Host ''
    if ($matchCount -gt 0)         { Write-Ok   "    MATCH:          $matchCount — in engine DNS RG, fully managed" }
    if ($duplicateRiskCount -gt 0) { Write-Err  "    DUPLICATE_RISK: $duplicateRiskCount — wrong RG, engine will create conflicting duplicates" }
    if ($extraCount -gt 0)         { Write-Info "    EXTRA:          $extraCount — not in engine defaults, engine won't touch these" }
    if ($missingCount -gt 0)       { Write-Info "    MISSING:        $missingCount engine default zones not yet deployed (will be created)" }
    if ($activeCount -gt 0)        { Write-Warn "    ACTIVE_RECORDS: $activeCount zone(s) have records beyond SOA+NS — orphaning breaks Private Link resolution" }
    if ($hubLinkedCount -gt 0)     { Write-Warn "    HUB_LINKED:     $hubLinkedCount zone(s) already linked to hub VNet — verify engine link creation is idempotent" }

    if ($duplicateRiskCount -gt 0) {
        Write-Host ''
        Write-Warn "    ! DUPLICATE_RISK — action required before engine deployment:"
        Write-Detail "      Option A: Move brownfield zones to engine DNS RG (rg-alz-dns-{location})"
        Write-Detail "      Option B: Set privateDnsSettings.deployPrivateDnsZones = false in hubnetworking config"
        Write-Detail "                and manage zone-to-VNet links via Azure Policy parameter overrides."
        if ($dnsRgSet.Count -gt 0) {
            Write-Detail "      Brownfield DNS RG(s): $($dnsRgSet -join ', ')"
        }
    }
    if ($hubLinkedCount -gt 0 -and $duplicateRiskCount -eq 0) {
        Write-Host ''
        Write-Warn "    ! Engine will create hub VNet links for these zones — verify existing link names won't conflict."
    }
}
if ($dcrsAll.Count -gt 0) {
    Write-Info "    Data Collection Rules: $($dcrsAll.Count) (engine deploys 3 more — existing unaffected)"
}
if ($uamisAll.Count -gt 0) {
    Write-Info "    User Assigned Managed Identities: $($uamisAll.Count)"
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
    $hasDenyAssigned = $script:MismatchCountByEffect['DenyAssigned'] -gt 0
    if ($hasDenyAssigned) {
        Write-Err  "    Standard — rule mismatch: $totalStdMismatchDefs (engine will overwrite on deploy)"
    } else {
        Write-Warn "    Standard — rule mismatch: $totalStdMismatchDefs (engine will overwrite on deploy)"
    }
    Write-Host ''
    Write-Host '  Rule mismatches by effect:'
    if ($script:MismatchCountByEffect['DenyAssigned']      -gt 0) { Write-Err  "    Deny (assigned):        $($script:MismatchCountByEffect['DenyAssigned']) (active risk — review resource compliance before deploying)" }
    if ($script:MismatchCountByEffect['DenyUnassigned']    -gt 0) { Write-Warn "    Deny (unassigned):      $($script:MismatchCountByEffect['DenyUnassigned']) (definition-only — no current impact)" }
    if ($script:MismatchCountByEffect['DeployIfNotExists'] -gt 0) { Write-Warn "    DeployIfNotExists:      $($script:MismatchCountByEffect['DeployIfNotExists']) (may trigger remediations)" }
    if ($script:MismatchCountByEffect['Modify']            -gt 0) { Write-Warn "    Modify:                 $($script:MismatchCountByEffect['Modify']) (may change resource properties)" }
    if ($script:MismatchCountByEffect['Append']            -gt 0) { Write-Info "    Append:                 $($script:MismatchCountByEffect['Append']) (may add properties on next update)" }
    if ($script:MismatchCountByEffect['Audit']             -gt 0) { Write-Ok   "    Audit/AuditIfNotExists: $($script:MismatchCountByEffect['Audit']) (informational only)" }
    if ($script:MismatchCountByEffect['Other']             -gt 0) { Write-Warn "    Other/Unknown:          $($script:MismatchCountByEffect['Other'])" }
} else { Write-Ok "    Rule mismatches:          0" }
if ($totalNonStdDefs -gt 0) { Write-Warn "    Non-standard (review):    $totalNonStdDefs" } else { Write-Ok "    Non-standard:             0" }
if ($totalAmbaDefs -gt 0) { Write-Amba "    AMBA (informational):     $totalAmbaDefs" }
if ($totalDeprDefs -gt 0) {
    $deprAssigned   = @($script:AllDeprDefList | Where-Object {
        $defAssignmentScopes.ContainsKey($_.Name) -and $defAssignmentScopes[$_.Name].Count -gt 0
    })
    $deprUnassigned = $totalDeprDefs - $deprAssigned.Count
    if ($deprAssigned.Count -gt 0) {
        Write-Warn "    Deprecated (assigned):    $($deprAssigned.Count) (engine will replace with successor — review before deploying)"
        Write-Info "    Deprecated (unassigned):  $deprUnassigned"
        if ($Detailed) {
            Write-Host ''
            Write-Warn "  ── Deprecated definitions still assigned ──"
            foreach ($e in $deprAssigned) {
                $assignScopes = @($defAssignmentScopes[$e.Name])
                $scopeStr = ($assignScopes | ForEach-Object { "$($_.ScopeName) ($($_.ManagementGroupId))" }) -join ', '
                Write-Warn   "  [DEPRECATED ASSIGNED] $($e.Name)"
                Write-Detail "    display name: $($e.DisplayName)"
                Write-Detail "    assigned at:  $scopeStr"
            }
        }
    } else {
        Write-Info "    Deprecated:               $totalDeprDefs"
    }
}

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
if ($script:NetworkingRiskCount -gt 0) {
    Write-Warn "  Networking cost-duplicate risk: $($script:NetworkingRiskCount) item(s) — DDoS plan/VPN/ER gateway may be deployed twice"
} else {
    Write-Ok   "  Networking cost-duplicate risk: 0"
}
if ($script:DnsDuplicateRiskCount -gt 0) {
    Write-Err  "  Private DNS duplicate-zone risk: $($script:DnsDuplicateRiskCount) zone(s) — wrong RG, engine will create conflicting duplicates"
} else {
    Write-Ok   "  Private DNS duplicate-zone risk: 0"
}

Write-Host ''
Write-Host '  Subscription-level governance:'
if ($subscriptionGovernance.Count -eq 0) {
    Write-Detail '    (not captured — re-run Export-BrownfieldState.ps1 to include subscription-level data)'
}
else {
    if ($script:TotalSubLevelNonStdAssignments -gt 0) {
        Write-Warn "    Non-standard direct assignments: $($script:TotalSubLevelNonStdAssignments) (review required)"
    }
    else {
        Write-Ok "    Non-standard direct assignments: 0"
    }
    if ($script:TotalSubLevelExemptions -gt 0) {
        if ($script:TotalDenyExemptions -gt 0) {
            Write-Warn "    Policy exemptions: $($script:TotalSubLevelExemptions) total  ($($script:TotalDenyExemptions) exempt Deny-effect — review)"
        }
        else {
            Write-Info "    Policy exemptions: $($script:TotalSubLevelExemptions)"
        }
    }
    else {
        Write-Ok "    Policy exemptions:               0"
    }
}

# Traffic light — AMBA does NOT count as non-standard for risk assessment.
# Only ASSIGNED Deny mismatches trigger RED; unassigned-only Deny mismatches are YELLOW.
Write-Host ''
$hasDenyAssigned = $script:MismatchCountByEffect['DenyAssigned'] -gt 0
$hasReviewItems  = $totalNonStdDefs -gt 0 -or $totalNonStdSets -gt 0 -or $totalStdMismatchDefs -gt 0
$hasMinorDrift   = $totalDeprDefs -gt 0 -or $totalDeprSets -gt 0 -or $totalNonStdAssignments -gt 0 -or $totalNonAlzRgs -gt 0 -or $totalCustomRoles -gt 0 -or $script:TotalSubLevelNonStdAssignments -gt 0 -or $script:TotalDenyExemptions -gt 0 -or $script:NetworkingRiskCount -gt 0 -or $script:DnsDuplicateRiskCount -gt 0

if (-not $hasReviewItems -and -not $hasMinorDrift) {
    Write-Colored 'GREEN' 'Green' "Brownfield is a clean portal accelerator deployment. Low risk for engine adoption."
    if ($totalAmbaDefs -gt 0 -or $totalAmbaSets -gt 0) {
        Write-Amba "  Note: AMBA monitoring stack detected ($totalAmbaDefs defs, $totalAmbaSets sets) — informational only."
    }
}
elseif ($hasDenyAssigned) {
    Write-Colored 'RED' 'Red' "Brownfield has assigned Deny-effect policy rule changes — resource compliance must be verified before deploying."
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
            SubLevelNonStdAssignments       = $script:TotalSubLevelNonStdAssignments
            SubLevelExemptions              = $script:TotalSubLevelExemptions
            SubLevelDenyExemptions          = $script:TotalDenyExemptions
            MismatchByEffect                = [PSCustomObject]@{
                DenyAssigned      = $script:MismatchCountByEffect['DenyAssigned']
                DenyUnassigned    = $script:MismatchCountByEffect['DenyUnassigned']
                Deny              = $script:MismatchCountByEffect['Deny']
                DeployIfNotExists = $script:MismatchCountByEffect['DeployIfNotExists']
                Modify            = $script:MismatchCountByEffect['Modify']
                Append            = $script:MismatchCountByEffect['Append']
                Audit             = $script:MismatchCountByEffect['Audit']
                Other             = $script:MismatchCountByEffect['Other']
            }
            HasDenyAssignedMismatches       = ($script:MismatchCountByEffect['DenyAssigned'] -gt 0)
            HasDenyMismatches               = ($script:MismatchCountByEffect['Deny'] -gt 0)
        }
    }
    $fullReport | ConvertTo-Json -Depth 10 | Set-Content $OutputFile
    Write-Host ''
    Write-Info "Full report written to: $OutputFile"
}

Write-Host ''

#==============================================================================
# Optional: generate HTML diff report for Deny-effect rule mismatches
#==============================================================================
if ($DiffReport -ne '') {
    $pythonScript = Join-Path $PSScriptRoot 'diff-deny-rules.py'
    if (-not (Test-Path $pythonScript)) {
        Write-Warn "diff-deny-rules.py not found at $pythonScript — skipping diff report"
    } else {
        $python = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' }
                  elseif (Get-Command python -ErrorAction SilentlyContinue) { 'python' }
                  else { $null }
        if (-not $python) {
            Write-Warn 'Python 3 not found in PATH — skipping diff report'
        } else {
            Write-Info "Generating policy rule diff report: $DiffReport"
            # Build mismatch info from Compare's authoritative list and pass to Python.
            # Python renders diffs; Compare is the authority on what's actually different.
            $mismatchInfoArr = @($script:AllStdMismatchDefList | ForEach-Object {
                [ordered]@{
                    Name        = $_.Name
                    DisplayName = if ($_.PSObject.Properties['DisplayName']) { $_.DisplayName } else { '' }
                    Effect      = if ($_.PSObject.Properties['Effect'])      { $_.Effect }      else { 'Unknown' }
                    IsAssigned  = if ($_.PSObject.Properties['IsAssigned'])  { [bool]$_.IsAssigned } else { $false }
                    Version     = if ($_.PSObject.Properties['Version'])     { $_.Version }     else { '' }
                }
            })
            $tempFile = [System.IO.Path]::GetTempFileName() + '.json'
            ($mismatchInfoArr | ConvertTo-Json -Depth 3) | Set-Content -Path $tempFile -Encoding UTF8
            try {
                & $python $pythonScript `
                    --export $BrownfieldExport `
                    --library $AlzLibraryPath `
                    --output $DiffReport `
                    --mismatch-info $tempFile
                if (Test-Path $DiffReport) {
                    Write-Ok "Diff report written to: $DiffReport"
                }
            } finally {
                Remove-Item $tempFile -ErrorAction SilentlyContinue
            }
        }
    }
}

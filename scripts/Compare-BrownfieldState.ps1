#Requires -Version 7
<#
.SYNOPSIS
    Jämför ett in-place takeover-export mot engine:ns ALZ-principbibliotek
    och producerar en läsbar adoptionsberedskapsrapport.

.DESCRIPTION
    Läser en JSON-fil producerad av Export-BrownfieldState.ps1 och jämför dess
    policydefinitioner, policysetdefinitioner och rolldefinitioner mot engine:ns
    ALZ-bibliotek för att klassificera varje post som Standard, Icke-standard eller Utfasad.

    Inventerar även policytilldelningar, RBAC, infrastruktur och extraherar
    konfigurationsvärden som operatören behöver som override-parametrar i tenant-konfigurationsrepot.

    Skrivskyddat. Inga ändringar görs i Azure eller i några filer (såvida inte -OutputFile används).

.PARAMETER BrownfieldExport
    Sökväg till JSON-exporten producerad av Export-BrownfieldState.ps1.

.PARAMETER AlzLibraryPath
    Sökväg till engine:ns ALZ-bibliotekskatalog (innehåller *.alz_policy_definition.json m.fl.).
    Detekteras automatiskt relativt till skriptets placering om den utelämnas.

.PARAMETER OutputFile
    Valfri sökväg att skriva hela rapporten som JSON.

.PARAMETER Detailed
    Visa individuella resursposter (icke-standard/utfasade objekt), inte bara antal.
    Deny-effekt-avvikelser delas upp i ASSIGNED (aktiv risk) och UNASSIGNED (ingen nuvarande risk).

.PARAMETER IncludeAmba
    Kombinerat med -Detailed: expandera även individuella AMBA- och utfasade policyposter.
    Utan denna switch visar -Detailed AMBA och utfasade poster enbart som antal.

.PARAMETER DiffReport
    Valfri sökväg att skriva en HTML-rapport med side-by-side-diff för Deny-effekt-avvikelser.
    Kräver Python 3 och scripts/diff-deny-rules.py. Öppnas i valfri webbläsare.

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
if ($NoColor) { Write-Host 'ALZ In-Place Takeover — Jämförelserapport' } else { Write-Host "`e[1mALZ In-Place Takeover — Jämförelserapport`e[0m" }
Write-Host '(skrivskyddat — inga ändringar görs)'
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
Write-Info "Bibliotek: $AlzLibraryPath"
Write-Info "Tenant:  $($export.TenantId)"
Write-Info "Exporterat: $($export.ExportTimestamp)"
Write-Info "Strategi: In-place takeover — engine tar över befintlig MG-hierarki"

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

Write-Info "Bibliotek laddat: $($libPolicyDefs.Count) policydefinitioner, $($libPolicySetDefs.Count) policysetdefinitioner, $($libRoleDefs.Count) rolldefinitioner, $($libAssignmentNames.Count) policytilldelningar"

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

# Prenumerationsnivå-räknare — uppdateras av Sektion 3b
$script:TotalSubLevelNonStdAssignments = 0
$script:TotalSubLevelExemptions        = 0
$script:TotalDenyExemptions            = 0

# Resurslås-räknare — uppdateras under Sektion 5
$script:LockBlockingCount = 0
$script:LockCautionCount  = 0
$script:LockTotalCount    = 0

# ALZ engine role definition check counters — populated by Section 4 role def subsection
$script:RoleDefNameCollisionCount = 0
$script:RoleDefDriftCount         = 0
$script:RoleDefCheckResults       = [System.Collections.Generic.List[object]]::new()

# Policy-driven identity audit counters — populated by Section 4 policy-driven identity audit
$script:OrphanRiskCount  = 0
$script:MissingRbacCount = 0

# Blueprint assessment counter — populated by Section 4b
$script:BlueprintCount = 0

# Defender for Cloud-räknare — uppdateras av Sektion 5b
$script:MmaProvisioningCount = 0

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
# Sektion 1: Strukturöversikt
#==============================================================================
Write-Step 'Sektion 1: Strukturöversikt'

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
Write-Host '  Management Group-hierarki:'
Write-MgTree $export.ManagementGroupHierarchy

# Hitta prenumerationsscope
$subScope = $export.Scopes | Where-Object { $_.Scope -eq 'subscription' }
if ($subScope) {
    Write-Host ''
    Write-Host '  Plattformsprenumeration(er):'
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
    Write-Ok 'Inga exportvarningar'
}

#==============================================================================
# Sektion 2: Jämförelse mot principbibliotek
#==============================================================================
Write-Step 'Sektion 2: Jämförelse mot principbibliotek'

$mgScopes = @($export.Scopes | Where-Object { $_.Scope -eq 'managementGroup' })

foreach ($scope in $mgScopes) {
    Write-Host ''
    Write-Host "  ── Scope: $($scope.Name) (MG: $($scope.ManagementGroupId)) ──"  # scope-namn är tekniska identifierare, behålls på engelska

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
        Write-Detail "Policydefinitioner: (inga)"
    }
    else {
        if ($stdDefs -gt 0) { Write-Ok   "Policydefinitioner:     $stdDefs standard (exakt match)" }
        if ($stdMismatchDefs -gt 0) { Write-Warn "Policydefinitioner:     $stdMismatchDefs standard (regelavvikelse — engine skriver över)" }
        if ($nonStdDefs -gt 0) { Write-Warn "Policydefinitioner:     $nonStdDefs icke-standard (granskning krävs)" }
        if ($ambaDefs -gt 0) { Write-Amba "Policydefinitioner:     $ambaDefs AMBA (Azure Monitor Baseline Alerts)" }
        if ($deprDefs -gt 0) { Write-Info "Policydefinitioner:     $deprDefs utfasade" }

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
                        Write-Warn "  [DINE REGELÄNDRING] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  bibliotek=$libVer"
                        Write-Detail "    påverkar: $resTypes"
                        Write-Warn  "    (medelhög risk — kan trigga remedieringsuppgifter på befintliga resurser)"
                    }
                    'Modify' {
                        Write-Warn "  [MODIFY REGELÄNDRING] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  bibliotek=$libVer"
                        Write-Detail "    påverkar: $resTypes"
                        Write-Warn  "    (medelhög risk — kan ändra resursegenskaper vid nästa policyutvärdering)"
                    }
                    'Append' {
                        Write-Info "  [APPEND REGELÄNDRING] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  bibliotek=$libVer"
                        Write-Detail "    påverkar: $resTypes"
                        Write-Detail "    (låg risk — append lägger bara till egenskaper vid nästa resursuppdatering)"
                    }
                    'Audit' {
                        Write-Info "  [AUDIT REGELÄNDRING] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  bibliotek=$libVer"
                        Write-Detail "    (låg risk — audit är informativ, ingen operationell påverkan)"
                    }
                    default {
                        Write-Warn "  [REGELAVVIKELSE] $($e.Name)  [effekt: $effect]"
                        Write-Detail "    version: brownfield=$bfVer  bibliotek=$libVer"
                        Write-Detail "    påverkar: $resTypes"
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
                    Write-Err "  ── Deny-effekt regeländringar: TILLDELADE ($($denyAssigned.Count) — aktiv risk) ──"
                    foreach ($e in $denyAssigned) {
                        $libEntry  = $libPolicyDefs[$e.Name]
                        $bfVer     = if ($e.Version) { $e.Version } else { '?' }
                        $libVer    = if ($libEntry -and $libEntry.Version) { $libEntry.Version } else { '?' }
                        $resTypes  = if ($libEntry -and $libEntry.TargetResourceTypes -and $libEntry.TargetResourceTypes.Count -gt 0) {
                            $libEntry.TargetResourceTypes -join ', '
                        } else { '(okänd)' }
                        $assignScopes = @($defAssignmentScopes[$e.Name])
                        $scopeStr = ($assignScopes | ForEach-Object { "$($_.ScopeName) ($($_.ManagementGroupId))" }) -join ', '
                        Write-Err    "  [DENY REGELÄNDRING] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  bibliotek=$libVer"
                        Write-Detail "    påverkar: $resTypes"
                        Write-Detail "    tilldelad vid: $scopeStr"
                        if ($mgSubscriptions.Count -gt 0) {
                            $allSubsInScope = [System.Collections.Generic.List[string]]::new()
                            foreach ($as in $assignScopes) {
                                foreach ($sub in @(Get-SubsUnderMg $as.ManagementGroupId)) {
                                    $subLabel = if ($sub.PSObject.Properties['DisplayName'] -and $sub.DisplayName) { "$($sub.DisplayName) ($($sub.Id))" } else { $sub.Id }
                                    if (-not $allSubsInScope.Contains($subLabel)) { [void]$allSubsInScope.Add($subLabel) }
                                }
                            }
                            if ($allSubsInScope.Count -gt 0) {
                                Write-Detail "    prenumerationer i scope: $($allSubsInScope -join ', ')"
                            } else {
                                Write-Detail "    prenumerationer i scope: (inga placerade under tilldelade MG:er)"
                            }
                        } else {
                            Write-Detail "    prenumerationer i scope: (kör Export-BrownfieldState.ps1 igen för att samla prenumerationsplacering)"
                        }
                        Write-Err    "    ⚠ Deny-effekt-regel ändras — verifiera att resurser av denna typ uppfyller kraven innan deployment"
                    }
                }

                if ($denyUnassigned.Count -gt 0) {
                    Write-Host ''
                    Write-Warn "  ── Deny-effekt regeländringar: OTILLDELADE ($($denyUnassigned.Count) — ingen nuvarande risk) ──"
                    foreach ($e in $denyUnassigned) {
                        $libEntry  = $libPolicyDefs[$e.Name]
                        $bfVer     = if ($e.Version) { $e.Version } else { '?' }
                        $libVer    = if ($libEntry -and $libEntry.Version) { $libEntry.Version } else { '?' }
                        $resTypes  = if ($libEntry -and $libEntry.TargetResourceTypes -and $libEntry.TargetResourceTypes.Count -gt 0) {
                            $libEntry.TargetResourceTypes -join ', '
                        } else { '(okänd)' }
                        Write-Warn   "  [DENY REGELÄNDRING] $($e.Name)"
                        Write-Detail "    version: brownfield=$bfVer  bibliotek=$libVer"
                        Write-Detail "    påverkar: $resTypes"
                        Write-Detail "    (definition finns men är inte tilldelad — ingen operationell påverkan såvida den inte tilldelas)"
                    }
                }
            }

            foreach ($e in $nonStdDefList) {
                Write-Warn "  [ICKE-STD] $($e.Name)  —  $($e.DisplayName)"
            }
            if ($Detailed -and $IncludeAmba) {
                foreach ($e in $ambaDefList) {
                    Write-Amba "  [AMBA] $($e.Name)  —  $($e.DisplayName)"
                }
                foreach ($e in $deprDefList) {
                    Write-Info "  [UTFASAD] $($e.Name)  —  $($e.DisplayName)"
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
        Write-Detail "Policysetdefinitioner: (inga)"
    }
    else {
        if ($stdSets -gt 0) { Write-Ok   "Policysetdefinitioner:  $stdSets standard" }
        if ($nonStdSets -gt 0) { Write-Warn "Policysetdefinitioner:  $nonStdSets icke-standard (granskning krävs)" }
        if ($ambaSets -gt 0) { Write-Amba "Policysetdefinitioner:  $ambaSets AMBA" }
        if ($deprSets -gt 0) { Write-Info "Policysetdefinitioner:  $deprSets utfasade" }

        if ($Detailed) {
            foreach ($e in $nonStdSetList) {
                Write-Warn "  [ICKE-STD] $($e.Name)  —  $($e.DisplayName)"
            }
            if ($IncludeAmba) {
                foreach ($e in $ambaSetList) {
                    Write-Amba "  [AMBA] $($e.Name)  —  $($e.DisplayName)"
                }
                foreach ($e in $deprSetList) {
                    Write-Info "  [UTFASAD] $($e.Name)  —  $($e.DisplayName)"
                }
            }
        }
    }

    $reportScopes += $scopeReport
}

#==============================================================================
# Sektion 3: Policytilldelningsinventering
#==============================================================================
Write-Step 'Sektion 3: Policytilldelningsinventering'

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
    Write-Host "  ── Scope: $($scope.Name) ($($assignments.Count) tilldelningar) ──"

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
        Write-Ok   "  $total tilldelningar totalt"
        if ($nonStd -gt 0) { Write-Warn "  $nonStd refererar icke-standard-definitioner" }
        if ($amba -gt 0) { Write-Amba "  $amba refererar AMBA-definitioner" }
        if ($dne -gt 0) { Write-Info "  $dne i DoNotEnforce-läge" }
    }
}

#==============================================================================
# Sektion 3b: Prenumerationsnivå-tilldelningar och undantag
#==============================================================================
Write-Step 'Sektion 3b: Prenumerationsnivå-tilldelningar och undantag'

$script:TotalSubLevelNonStdAssignments = 0
$script:TotalSubLevelExemptions        = 0
$script:TotalDenyExemptions            = 0

if ($subscriptionGovernance.Count -eq 0) {
    Write-Info '  Ingen prenumerationsstyrningsdata i exporten.'
    Write-Info '  Kör Export-BrownfieldState.ps1 igen för att samla prenumerationsnivå-tilldelningar och undantag.'
}
else {
    foreach ($subGov in $subscriptionGovernance) {
        $subId          = if ($subGov.PSObject.Properties['SubscriptionId']) { $subGov.SubscriptionId } else { '(unknown)' }
        $subDisplayName = if ($subGov.PSObject.Properties['DisplayName'] -and $subGov.DisplayName) { $subGov.DisplayName } else { $subId }
        $subAssignments = @(if ($subGov.PSObject.Properties['PolicyAssignments']) { $subGov.PolicyAssignments } else { @() })
        $subExemptions  = @(if ($subGov.PSObject.Properties['PolicyExemptions'])  { $subGov.PolicyExemptions  } else { @() })

        if ($subAssignments.Count -eq 0 -and $subExemptions.Count -eq 0) { continue }

        Write-Host ''
        Write-Host "  ── Prenumeration: $subDisplayName ($subId) ──"

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
                Write-Ok "  $($subAssignments.Count) direkt policytilldelning(ar)"
                if ($nonStdA -gt 0) { Write-Warn "    $nonStdA refererar icke-standard-definitioner" }
                if ($ambaA   -gt 0) { Write-Amba "    $ambaA refererar AMBA-definitioner" }
                if ($dneA    -gt 0) { Write-Info "    $dneA i DoNotEnforce-läge" }
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
                    Write-Warn "  [UNDANTAG] $exDisplay  (kategori: $exCat)"
                    Write-Warn "    ⚠ Undantar en Deny-effekt-policy — verifiera att detta undantag är avsiktligt"
                    Write-Detail "    tilldelning: $exAssignId"
                }
                elseif ($Detailed) {
                    Write-Info "  [UNDANTAG] $exDisplay  (kategori: $exCat)"
                    Write-Detail "    tilldelning: $exAssignId"
                }
                else {
                    Write-Info "  $($subExemptions.Count) policyundantag  (använd -Detailed för att lista)"
                    break
                }
            }
        }
    }

    if ($subscriptionGovernance.Count -gt 0 -and
        ($subscriptionGovernance | ForEach-Object { $_.PolicyAssignments.Count + $_.PolicyExemptions.Count } | Measure-Object -Sum).Sum -eq 0) {
        Write-Info '  Inga prenumerationsnivå-tilldelningar eller undantag hittades.'
    }
}

#==============================================================================
# Sektion 4: RBAC-sammanfattning
#==============================================================================
Write-Step 'Sektion 4: RBAC-sammanfattning'

foreach ($scope in $mgScopes) {
    $ras = @($scope.Resources.RoleAssignments)
    $rds = @($scope.Resources.RoleDefinitions)

    if ($ras.Count -eq 0 -and $rds.Count -eq 0) { continue }

    Write-Host ''
    Write-Host "  ── Scope: $($scope.Name) ──"

    # Rolltilldelningar per principaltyp
    if ($ras.Count -gt 0) {
        $byType = $ras | Group-Object PrincipalType | Sort-Object Name
        foreach ($g in $byType) {
            Write-Info "  Rolltilldelningar — $($g.Name): $($g.Count)"
        }
    }

    # Rolldefinitioner — per-roll GUID/behörighetsanalys finns i ALZ Engine-rolldefinitionskontroll nedan.
    if ($rds.Count -gt 0) {
        $customRdCount = @($rds | Where-Object { (Get-RoleDefClassification $_.RoleName) -eq 'Custom' }).Count
        if ($customRdCount -gt 0) {
            Write-Warn "  Rolldefinitioner: $($rds.Count) totalt  ($customRdCount icke-ALZ anpassade)"
        } else {
            Write-Info "  Rolldefinitioner: $($rds.Count)"
        }
    }

    $scopeEntry = $reportScopes | Where-Object { $_.ScopeName -eq $scope.Name }
    if ($scopeEntry) {
        $scopeEntry.RoleAssignments = $ras
        $scopeEntry.RoleDefinitions = $rds
    }
}

#---------- ALZ Engine Role Definition Check ----------
# Load engine role defs with actions for comparison against brownfield state.
# Permissions in the brownfield export = $role.Actions (string array); notActions are not captured.
$engineRoleLibDefs = @(Get-ChildItem -Path $AlzLibraryPath -Filter '*.alz_role_definition.json' -Recurse |
    ForEach-Object {
        $j          = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $perms      = if ($j.properties.PSObject.Properties['permissions'] -and $j.properties.permissions.Count -gt 0) {
            $j.properties.permissions[0]
        } else { $null }
        $libActions = @(if ($perms -and $perms.PSObject.Properties['actions']) { $perms.actions } else { @() } )
        $libActions = @($libActions | Sort-Object)
        [PSCustomObject]@{
            Guid       = $j.name
            RoleName   = $j.properties.roleName   # e.g. "Subscription-Owner (alz)"
            RoleBase   = ($j.properties.roleName -replace '\s*\([^)]+\)\s*$', '')
            LibActions = $libActions
        }
    })

# Collect all brownfield role defs across all MG scopes (portal may deploy them at any level)
$allBfRoleDefs = [System.Collections.Generic.List[object]]::new()
foreach ($scope in $mgScopes) {
    foreach ($rd in @($scope.Resources.RoleDefinitions)) {
        [void]$allBfRoleDefs.Add($rd)
    }
}

Write-Host ''
Write-Host '  ── ALZ Engine-rolldefinitionskontroll ──'

foreach ($erd in $engineRoleLibDefs) {
    # GUID match: export stores Name = full resource ID; extract trailing GUID segment
    $guidMatch = @($allBfRoleDefs | Where-Object { ($_.Name -split '/')[-1] -ieq $erd.Guid })

    # Name match: base name (strip trailing (xxx) suffix) under a different GUID
    $nameMatch = @($allBfRoleDefs | Where-Object {
        ($_.RoleName -replace '\s*\([^)]+\)\s*$', '') -ieq $erd.RoleBase -and
        ($_.Name -split '/')[-1] -ine $erd.Guid
    })

    $status   = 'MISSING'
    $bfGuid   = $null
    $permDiff = @()

    if ($guidMatch.Count -gt 0) {
        $bf        = $guidMatch[0]
        $bfGuid    = ($bf.Name -split '/')[-1]
        # Export Permissions = $role.Actions (actions string array only)
        $bfActions  = @($bf.Permissions | Sort-Object)
        $libActions = $erd.LibActions
        $libJoined  = ($libActions -join '|')
        $bfJoined   = ($bfActions  -join '|')
        if ($libJoined -ne $bfJoined) {
            $status    = 'DRIFT'
            $inLibOnly = @($libActions | Where-Object { $bfActions  -notcontains $_ })
            $inBfOnly  = @($bfActions  | Where-Object { $libActions -notcontains $_ })
            foreach ($a in $inLibOnly) { $permDiff += "      + $a  (engine adds)" }
            foreach ($r in $inBfOnly)  { $permDiff += "      - $r  (brownfield only, engine removes)" }
        } else {
            $status = 'MATCH'
        }
    } elseif ($nameMatch.Count -gt 0) {
        $status = 'NAME_COLLISION'
        $bfGuid = ($nameMatch[0].Name -split '/')[-1]
    }

    switch ($status) {
        'MATCH'          { Write-Ok   "  [MATCH]          $($erd.RoleName)  (GUID: $($erd.Guid))" }
        'DRIFT'          { Write-Warn "  [DRIFT]          $($erd.RoleName)  (GUID: $($erd.Guid)) — engine skriver över behörigheter vid deployment" }
        'NAME_COLLISION' { Write-Warn "  [NAME_COLLISION] $($erd.RoleName)  (engine GUID: $($erd.Guid)) — befintlig roll med samma visningsnamn under GUID: $bfGuid" }
        'MISSING'        { Write-Ok   "  [SAKNAS]         $($erd.RoleName) — finns ej i brownfield, engine skapar den" }
    }
    foreach ($line in $permDiff) { Write-Detail $line }

    if ($status -eq 'DRIFT')          { $script:RoleDefDriftCount++ }
    if ($status -eq 'NAME_COLLISION') { $script:RoleDefNameCollisionCount++ }

    [void]$script:RoleDefCheckResults.Add([PSCustomObject]@{
        LibraryGuid    = $erd.Guid
        LibraryName    = $erd.RoleName
        Status         = $status
        BrownfieldGuid = $bfGuid
        PermissionDiff = $permDiff
    })
}

#---------- Policy-Driven Identity Audit ----------
# Identifies policy assignments that hold managed identities with cross-MG role assignments.
# When the engine deploys, it creates NEW managed identities for its policy assignments. The old
# identities' role assignments become orphaned (ORPHAN_RISK). Also flags cases where the
# brownfield already lacks the expected cross-MG grants (MISSING_RBAC).

# Engine cross-MG RBAC expectations, derived from the three -rbac.bicep modules.
# Each entry: { AssignmentName; SourceScope; TargetScope; RoleDefGuids[] }
$engineCrossMgRbacExpectations = @(
    # platform/main-rbac.bicep (full mode): Enable-DDoS-VNET from connectivity → Network Contributor on platform
    @{ AssignmentName = 'Enable-DDoS-VNET';         SourceScope = 'governance-platform-connectivity'; TargetScope = 'governance-platform';    RoleDefGuids = @('4d97b98b-1d4f-4787-a291-c67834d212e7') }
    # platform-connectivity/main-rbac.bicep (full mode): Deploy-Private-DNS-Zones from corp → Network Contributor on connectivity
    @{ AssignmentName = 'Deploy-Private-DNS-Zones';  SourceScope = 'governance-landingzones-corp';     TargetScope = 'governance-platform-connectivity'; RoleDefGuids = @('4d97b98b-1d4f-4787-a291-c67834d212e7') }
    # landingzones/main-rbac.bicep: eight policy assignments from platform/connectivity → landingzones
    @{ AssignmentName = 'Deploy-VM-ChangeTrack';     SourceScope = 'governance-platform';              TargetScope = 'governance-landingzones'; RoleDefGuids = @('9980e02c-c2be-4d73-94e8-173b1dc7cf3c','92aaf0da-9dab-42b6-94a3-d43ce8d16293','749f88d5-cbae-40b8-bcfc-e573ddc772fa','f1a07417-d97a-45cb-824c-7a7467783830','acdd72a7-3385-48ef-bd42-f606fba81ae7') }
    @{ AssignmentName = 'Deploy-VM-Monitoring';      SourceScope = 'governance-platform';              TargetScope = 'governance-landingzones'; RoleDefGuids = @('9980e02c-c2be-4d73-94e8-173b1dc7cf3c','92aaf0da-9dab-42b6-94a3-d43ce8d16293','749f88d5-cbae-40b8-bcfc-e573ddc772fa','f1a07417-d97a-45cb-824c-7a7467783830','acdd72a7-3385-48ef-bd42-f606fba81ae7') }
    @{ AssignmentName = 'Deploy-vmArc-ChangeTrack';  SourceScope = 'governance-platform';              TargetScope = 'governance-landingzones'; RoleDefGuids = @('92aaf0da-9dab-42b6-94a3-d43ce8d16293','749f88d5-cbae-40b8-bcfc-e573ddc772fa','acdd72a7-3385-48ef-bd42-f606fba81ae7') }
    @{ AssignmentName = 'Deploy-VMSS-ChangeTrack';   SourceScope = 'governance-platform';              TargetScope = 'governance-landingzones'; RoleDefGuids = @('9980e02c-c2be-4d73-94e8-173b1dc7cf3c','92aaf0da-9dab-42b6-94a3-d43ce8d16293','749f88d5-cbae-40b8-bcfc-e573ddc772fa','f1a07417-d97a-45cb-824c-7a7467783830','acdd72a7-3385-48ef-bd42-f606fba81ae7') }
    @{ AssignmentName = 'Deploy-vmHybr-Monitoring';  SourceScope = 'governance-platform';              TargetScope = 'governance-landingzones'; RoleDefGuids = @('92aaf0da-9dab-42b6-94a3-d43ce8d16293','749f88d5-cbae-40b8-bcfc-e573ddc772fa','acdd72a7-3385-48ef-bd42-f606fba81ae7','cd570a14-e51a-42ad-bac8-bafd67325302') }
    @{ AssignmentName = 'Deploy-VMSS-Monitoring';    SourceScope = 'governance-platform';              TargetScope = 'governance-landingzones'; RoleDefGuids = @('9980e02c-c2be-4d73-94e8-173b1dc7cf3c','92aaf0da-9dab-42b6-94a3-d43ce8d16293','749f88d5-cbae-40b8-bcfc-e573ddc772fa','f1a07417-d97a-45cb-824c-7a7467783830','acdd72a7-3385-48ef-bd42-f606fba81ae7') }
    @{ AssignmentName = 'Deploy-MDFC-DefSQL-AMA';    SourceScope = 'governance-platform';              TargetScope = 'governance-landingzones'; RoleDefGuids = @('9980e02c-c2be-4d73-94e8-173b1dc7cf3c','92aaf0da-9dab-42b6-94a3-d43ce8d16293','749f88d5-cbae-40b8-bcfc-e573ddc772fa','f1a07417-d97a-45cb-824c-7a7467783830','acdd72a7-3385-48ef-bd42-f606fba81ae7') }
    @{ AssignmentName = 'Enable-DDoS-VNET';          SourceScope = 'governance-platform-connectivity'; TargetScope = 'governance-landingzones'; RoleDefGuids = @('4d97b98b-1d4f-4787-a291-c67834d212e7') }
)

$roleGuidToName = @{
    '9980e02c-c2be-4d73-94e8-173b1dc7cf3c' = 'Virtual Machine Contributor'
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293' = 'Log Analytics Contributor'
    '749f88d5-cbae-40b8-bcfc-e573ddc772fa' = 'Monitoring Contributor'
    'f1a07417-d97a-45cb-824c-7a7467783830' = 'Managed Identity Operator'
    'acdd72a7-3385-48ef-bd42-f606fba81ae7' = 'Reader'
    'cd570a14-e51a-42ad-bac8-bafd67325302' = 'Azure Connected Machine Resource Administrator'
    '4d97b98b-1d4f-4787-a291-c67834d212e7' = 'Network Contributor'
}

# Build index: principal ID → list of role assignments (with scope name) across all MG scopes
$raByPrincipalId = @{}
foreach ($s in $mgScopes) {
    foreach ($ra in @($s.Resources.RoleAssignments)) {
        $raPrincipalId = if ($ra.PSObject.Properties['PrincipalId']) { $ra.PrincipalId } else { $null }
        if (-not $raPrincipalId) { continue }
        if (-not $raByPrincipalId.ContainsKey($raPrincipalId)) {
            $raByPrincipalId[$raPrincipalId] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$raByPrincipalId[$raPrincipalId].Add([PSCustomObject]@{
            ResourceId       = if ($ra.PSObject.Properties['ResourceId']) { $ra.ResourceId } else { $null }
            RoleDefinitionId = if ($ra.PSObject.Properties['RoleDefinitionId']) { $ra.RoleDefinitionId } else { $null }
            Scope            = if ($ra.PSObject.Properties['Scope']) { $ra.Scope } else { $null }
            ScopeName        = $s.Name
        })
    }
}

# Build list of all policy assignments with managed identities, with backward compat for older exports
$allPaWithIdentity = [System.Collections.Generic.List[object]]::new()
foreach ($s in $mgScopes) {
    foreach ($pa in @($s.Resources.PolicyAssignments)) {
        $identPid = $null
        # New exports: promoted ManagedIdentityPrincipalId field
        if ($pa.PSObject.Properties['ManagedIdentityPrincipalId'] -and $null -ne $pa.ManagedIdentityPrincipalId) {
            $identPid = $pa.ManagedIdentityPrincipalId
        }
        # Backward compat: derive from Identity.PrincipalId where Identity.Type == 'SystemAssigned'
        elseif ($pa.PSObject.Properties['Identity'] -and $null -ne $pa.Identity) {
            $identObj = $pa.Identity
            if ($identObj.PSObject.Properties['Type'] -and $identObj.Type -eq 'SystemAssigned' -and
                $identObj.PSObject.Properties['PrincipalId'] -and $null -ne $identObj.PrincipalId) {
                $identPid = $identObj.PrincipalId
            }
        }
        if (-not $identPid) { continue }

        $rid            = if ($pa.PSObject.Properties['ResourceId']) { $pa.ResourceId } else { $null }
        $assignmentName = if ($rid) { ($rid -split '/')[-1] } else { $null }
        $paScope        = if ($pa.PSObject.Properties['Scope']) { $pa.Scope } else { $null }
        if (-not $assignmentName) { continue }

        [void]$allPaWithIdentity.Add([PSCustomObject]@{
            AssignmentName  = $assignmentName
            PrincipalId     = $identPid
            ScopeName       = $s.Name
            AssignmentScope = $paScope
        })
    }
}

Write-Host ''
Write-Host '  ── Policy-driven identitetsgranskning ──'

if ($allPaWithIdentity.Count -eq 0) {
    Write-Info '  Inga policytilldelningar med managed identities hittades — exporten kan sakna identitetsdata'
    Write-Info '  (Kör Export-BrownfieldState.ps1 igen för att samla managed identity-principal-ID:n)'
} else {
    # --- Del 1: ORPHAN_RISK — identiteter med befintliga cross-MG-rolltilldelningar ---
    foreach ($paEntry in $allPaWithIdentity) {
        $crossMgRas = @()
        if ($raByPrincipalId.ContainsKey($paEntry.PrincipalId)) {
            $crossMgRas = @($raByPrincipalId[$paEntry.PrincipalId] |
                Where-Object { $_.Scope -ine $paEntry.AssignmentScope })
        }
        if ($crossMgRas.Count -eq 0) { continue }

        $script:OrphanRiskCount++
        Write-Warn "  [ORPHAN_RISK] $($paEntry.AssignmentName) @ $($paEntry.ScopeName)"
        Write-Detail "    Identity principal ID: $($paEntry.PrincipalId)"
        Write-Detail "    Engine skapar ny managed identity — $($crossMgRas.Count) cross-MG-rolltilldelning(ar) föräldralösa:"
        foreach ($ra in $crossMgRas) {
            $roleGuid    = if ($ra.RoleDefinitionId) { ($ra.RoleDefinitionId -split '/')[-1] } else { '(okänd)' }
            $roleName    = if ($roleGuidToName.ContainsKey($roleGuid)) { $roleGuidToName[$roleGuid] } else { $roleGuid }
            Write-Detail "      Målscope: $($ra.ScopeName) — $roleName"
            if ($ra.ResourceId) { Write-Detail "        $($ra.ResourceId)" }
        }
    }

    # --- Del 2: MISSING_RBAC — förväntad cross-MG-behörighet saknas i brownfield ---
    foreach ($expectation in $engineCrossMgRbacExpectations) {
        $paEntries = @($allPaWithIdentity | Where-Object {
            $_.AssignmentName -eq $expectation.AssignmentName -and $_.ScopeName -eq $expectation.SourceScope
        })
        if ($paEntries.Count -eq 0) { continue }  # assignment absent from brownfield — not a MISSING_RBAC issue
        $paEntry = $paEntries[0]

        $targetScopeExists = @($mgScopes | Where-Object { $_.Name -eq $expectation.TargetScope }).Count -gt 0
        if (-not $targetScopeExists) { continue }  # target MG not in this tenant (e.g. full-mode scope in simple-mode tenant)

        $missingRoles = @()
        foreach ($roleGuid in $expectation.RoleDefGuids) {
            $hasRole = $false
            if ($raByPrincipalId.ContainsKey($paEntry.PrincipalId)) {
                $hasRole = @($raByPrincipalId[$paEntry.PrincipalId] | Where-Object {
                    $_.ScopeName -eq $expectation.TargetScope -and
                    $_.RoleDefinitionId -and ($_.RoleDefinitionId -split '/')[-1] -ieq $roleGuid
                }).Count -gt 0
            }
            if (-not $hasRole) { $missingRoles += $roleGuid }
        }

        if ($missingRoles.Count -gt 0) {
            $script:MissingRbacCount++
            Write-Warn "  [MISSING_RBAC] $($expectation.AssignmentName) @ $($expectation.SourceScope) → $($expectation.TargetScope)"
            Write-Detail "    Identity principal ID: $($paEntry.PrincipalId)"
            Write-Detail "    Saknade roll(er) vid målscope:"
            foreach ($g in $missingRoles) {
                $roleName = if ($roleGuidToName.ContainsKey($g)) { $roleGuidToName[$g] } else { $g }
                Write-Detail "      $roleName  ($g)"
            }
        }
    }

    # --- Del 3: RENA scopes ---
    $scopesWithIdentities = @($allPaWithIdentity | Select-Object -ExpandProperty ScopeName | Sort-Object -Unique)
    foreach ($s in $mgScopes) {
        if ($scopesWithIdentities -notcontains $s.Name) {
            Write-Ok "  [REN] $($s.Name) — inga policy-drivna identiteter"
        }
    }

    if ($script:OrphanRiskCount -eq 0 -and $script:MissingRbacCount -eq 0) {
        Write-Ok "  Cross-MG RBAC: alla policy-drivna identiteter är rena"
    } else {
        if ($script:OrphanRiskCount  -gt 0) {
            Write-Warn "  $($script:OrphanRiskCount) ORPHAN_RISK-post(er) — cross-MG-rolltilldelningar föräldralösa när engine skapar nya managed identities"
            Write-Detail "             Befintliga identiteter kan rensas bort efter att engine är deployed."
        }
        if ($script:MissingRbacCount -gt 0) { Write-Warn "  $($script:MissingRbacCount) MISSING_RBAC-post(er) — brownfield saknar redan förväntade cross-MG-behörigheter" }
    }
}

#==============================================================================
# Sektion 4b: Blueprint-granskning
#==============================================================================
Write-Step 'Sektion 4b: Blueprint-granskning'

# Known ALZ / CAF blueprint display name fragments (matched case-insensitively)
$knownAlzBlueprintPatterns = @(
    'caf-foundation', 'caf-migrate', 'caf foundation', 'caf migration',
    'alz', 'azure landing zone', 'eslz', 'enterprise scale'
)

$blueprintAssignments = @()
if ($export.PSObject.Properties['BlueprintAssignments'] -and $null -ne $export.BlueprintAssignments) {
    $blueprintAssignments = @($export.BlueprintAssignments)
}

$script:BlueprintCount = $blueprintAssignments.Count

if ($blueprintAssignments.Count -eq 0) {
    Write-Ok '  Inga blueprint-tilldelningar hittades'
} else {
    Write-Err "  $($blueprintAssignments.Count) blueprint-tilldelning(ar) hittades — MÅSTE tas bort innan engine-deployment"
    Write-Host ''

    foreach ($ba in $blueprintAssignments) {
        $name      = if ($ba.PSObject.Properties['Name'])              { $ba.Name }              else { $ba['Name'] }
        $subId     = if ($ba.PSObject.Properties['SubscriptionId'])    { $ba.SubscriptionId }    else { $ba['SubscriptionId'] }
        $bpId      = if ($ba.PSObject.Properties['BlueprintId'])       { $ba.BlueprintId }       else { $ba['BlueprintId'] }
        $state     = if ($ba.PSObject.Properties['ProvisioningState']) { $ba.ProvisioningState } else { $ba['ProvisioningState'] }
        $lockMode  = if ($ba.PSObject.Properties['LockMode'])          { $ba.LockMode }          else { $ba['LockMode'] }
        if (-not $lockMode) { $lockMode = 'None' }

        # Kontrollera om detta ser ut som ett känt ALZ/CAF-blueprint
        $isAlzBlueprint = $false
        $checkStr = "$name $bpId".ToLower()
        foreach ($pattern in $knownAlzBlueprintPatterns) {
            if ($checkStr -like "*$pattern*") { $isAlzBlueprint = $true; break }
        }

        $tag = if ($isAlzBlueprint) { '[ALZ_BLUEPRINT]' } else { '[BLUEPRINT]' }
        Write-Err "  $tag  $name  (prenumeration: $subId)"
        Write-Detail "    Blueprint-ID:       $bpId"
        Write-Detail "    Provisioneringsstatus: $state"

        if ($lockMode -eq 'AllResourcesReadOnly') {
            Write-Err  "    Låsläge:            $lockMode — BLOCKERAR: engine kan inte ändra blueprint-hanterade resurser"
        } elseif ($lockMode -eq 'AllResourcesDoNotDelete') {
            Write-Warn "    Låsläge:            $lockMode — engine kan ändra men inte ta bort blueprint-hanterade resurser"
        } else {
            Write-Info "    Låsläge:            $lockMode"
        }

        Write-Host ''
        Write-Detail "    Åtgärd krävs:"
        Write-Detail "      1. Ta bort tilldelningen av detta blueprint innan engine körs"
        Write-Detail "         Blueprint-hanterade resurser kvarstår men blir ohanterade efter borttagning"
        Write-Detail "      2. Granska blueprint-artefakter — identifiera vilka policytilldelningar och"
        Write-Detail "         rolltilldelningar det skapade; engine behöver äga dessa efter migration"
        if ($isAlzBlueprint) {
            Write-Detail "      3. Detta verkar vara ett ALZ/CAF-blueprint — dess policytilldelningar"
            Write-Detail "         kommer troligen att direkt konflikta med engine:ns styrningsdeployment"
        }
        Write-Host ''
    }
}

#==============================================================================
# Sektion 4c: CI/CD-identitetsgranskning
#==============================================================================
Write-Step 'Sektion 4c: CI/CD-identitetsgranskning'

$highPrivList = @()
if ($export.PSObject.Properties['HighPrivilegeIdentities'] -and $null -ne $export.HighPrivilegeIdentities) {
    $highPrivList = @($export.HighPrivilegeIdentities)
}

if ($highPrivList.Count -eq 0) {
    Write-Info '  Ingen högprivilegierad identitetsdata insamlad'
    Write-Detail '    Kör Export-BrownfieldState.ps1 igen för att inkludera CI/CD-identitetsdata'
} else {
    $spnEntries  = @($highPrivList | Where-Object {
        $pt = if ($_.PSObject.Properties['PrincipalType']) { $_.PrincipalType } else { $_['PrincipalType'] }
        $pt -eq 'ServicePrincipal'
    })
    $userEntries = @($highPrivList | Where-Object {
        $pt = if ($_.PSObject.Properties['PrincipalType']) { $_.PrincipalType } else { $_['PrincipalType'] }
        $pt -eq 'User'
    })
    $groupEntries = @($highPrivList | Where-Object {
        $pt = if ($_.PSObject.Properties['PrincipalType']) { $_.PrincipalType } else { $_['PrincipalType'] }
        $pt -eq 'Group'
    })

    Write-Info "  Högprivilegierade (Owner/Contributor) tilldelningar vid int-root MG: $($highPrivList.Count)"
    Write-Host ''

    foreach ($hp in $highPrivList) {
        $rn = if ($hp.PSObject.Properties['RoleName'])      { $hp.RoleName }      else { $hp['RoleName'] }
        $pt = if ($hp.PSObject.Properties['PrincipalType']) { $hp.PrincipalType } else { $hp['PrincipalType'] }
        $pi = if ($hp.PSObject.Properties['PrincipalId'])   { $hp.PrincipalId }   else { $hp['PrincipalId'] }
        $sc = if ($hp.PSObject.Properties['Scope'])         { $hp.Scope }         else { $hp['Scope'] }
        switch ($pt) {
            'ServicePrincipal' {
                Write-Warn "  $rn — ServicePrincipal: $pi"
                Write-Detail '    Troligen CI/CD-identitet. Verifiera om detta är nuvarande deployment-principal.'
                Write-Detail '    Åtgärd: verifiera och planera borttagning efter att engine OIDC-bootstrap är validerad.'
            }
            'User' {
                Write-Info "  $rn — Användare: $pi"
                Write-Detail '    Mänsklig administratör — påverkas inte av bootstrap. Granska för lägsta privilegium.'
            }
            'Group' {
                Write-Info "  $rn — Grupp: $pi"
                Write-Detail '    Entra ID-grupp — påverkas inte av bootstrap. Granska för lägsta privilegium.'
            }
            default {
                Write-Info "  $rn — ${pt}: $pi"
            }
        }
        if ($sc) { Write-Detail "    Scope: $sc" }
    }

    Write-Host ''
    if ($spnEntries.Count -gt 0) {
        Write-Warn "  $($spnEntries.Count) tjänsteprincipal(er) med Owner/Contributor vid int-root — granska innan engine-bootstrap"
    }
    if ($userEntries.Count -gt 0 -or $groupEntries.Count -gt 0) {
        Write-Info "  $($userEntries.Count + $groupEntries.Count) användare/grupptilldelning(ar) — överväg granskning för lägsta privilegium"
    }
}

# Check for existing bootstrap artifacts in the infrastructure report
# (infraReport is built in Section 5, so we scan the raw export here)
$bootstrapUamiPattern = 'id-alz-mgmt-.*-(plan|apply)-\d+'
$whatIfRoleName       = 'Landing Zone Reader'
$whatIfAction         = 'deployments/whatIf/action'

$existingBootstrapUamis = @()
$existingWhatIfRole     = $false

foreach ($ss in @($subScope)) {
    foreach ($kr in @($ss.Resources.KeyResources)) {
        if ($kr.Type -eq 'userAssignedIdentity') {
            $n = if ($kr.PSObject.Properties['Name']) { $kr.Name } else { '' }
            if ($n -imatch $bootstrapUamiPattern) {
                $existingBootstrapUamis += $n
            }
        }
    }
}

foreach ($scope in $mgScopes) {
    foreach ($rd in @($scope.Resources.RoleDefinitions)) {
        $rdName  = if ($rd.PSObject.Properties['RoleName'])    { $rd.RoleName }    else { '' }
        $rdPerms = if ($rd.PSObject.Properties['Permissions']) { $rd.Permissions } else { @() }
        if ($rdName -imatch [regex]::Escape($whatIfRoleName)) {
            $existingWhatIfRole = $true
        } elseif (@($rdPerms) | Where-Object { $_ -imatch [regex]::Escape($whatIfAction) }) {
            $existingWhatIfRole = $true
        }
    }
}

Write-Host ''
if ($existingBootstrapUamis.Count -gt 0 -or $existingWhatIfRole) {
    Write-Warn '  Befintliga bootstrap-artefakter detekterade (bootstrap kan ha körts delvis):'
    foreach ($u in $existingBootstrapUamis) {
        Write-Detail "    UAMI: $u"
    }
    if ($existingWhatIfRole) {
        Write-Detail "    Anpassad roll: '$whatIfRoleName' (eller åtgärd $whatIfAction) hittad"
    }
    Write-Detail '  Åtgärd: verifiera bootstrap-tillstånd innan onboard.ps1 körs igen (kör cleanup.ps1 först vid behov)'
} else {
    Write-Ok '  Inga befintliga bootstrap-artefakter detekterade'
    Write-Detail '    Bootstrap skapar nya UAMIs + OIDC-federation för GitHub Actions'
}

#==============================================================================
# Sektion 5: Infrastrukturgranskning
#==============================================================================
Write-Step 'Sektion 5: Infrastrukturgranskning'

$alzRgPrefixes = @('alz-', 'ALZ-', 'rg-alz-', 'rg-amba-')
$skipRgPrefixes = @('VisualStudioOnline-', 'NetworkWatcherRG', 'cloud-shell-storage')
$expectedKeyResTypes = @('logAnalyticsWorkspace', 'automationAccount', 'hubVnet', 'firewall', 'privateDnsZones')

$infraReport = @()

foreach ($ss in @($subScope)) {
    Write-Host ''
    Write-Host "  ── Prenumeration: $($ss.SubscriptionId) ──"

    $rgs = @($ss.Resources.ResourceGroups)
    $keyRes = @($ss.Resources.KeyResources)

    $alzRgs = @($rgs | Where-Object { $n = $_.Name; $alzRgPrefixes | Where-Object { $n -like "$_*" } })
    $nonAlzRgs = @($rgs | Where-Object { $n = $_.Name; -not ($alzRgPrefixes | Where-Object { $n -like "$_*" }) })

    Write-Info "  Resursgrupper: $($rgs.Count) totalt  ($($alzRgs.Count) ALZ-relaterade, $($nonAlzRgs.Count) övriga)"

    if ($nonAlzRgs.Count -gt 0) {
        Write-Warn "  Icke-ALZ-resursgrupper (kan vara orelaterade arbetsbelastningar):"
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
                Write-Ok "  $($kr.Type): $($kr.Name) [matchar engine-konvention]"
            }
            else {
                Write-Warn "  $($kr.Type): $($kr.Name) [engine skulle använda: $engineName]"
            }
        }
        else {
            Write-Info "  $($kr.Type): $($kr.Name)"
        }
    }

    # Flagga saknade förväntade resurser
    $missing = @()
    if (-not $foundTypes.ContainsKey('logAnalyticsWorkspace')) { $missing += 'Log Analytics-arbetsyta' }
    if (-not $foundTypes.ContainsKey('automationAccount')) { $missing += 'Automation Account' }
    foreach ($m in $missing) { Write-Warn "  Förväntad resurs saknas: $m" }

    # --- Hub-nätverksgranskning ---
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
        Write-Host "  Hub-nätverksgranskning (override-värden för tenant-konfig-repo):"

        # DDoS-skyddsplaner — extrahera resurs-ID för override
        if ($ddosFound.Count -gt 0) {
            foreach ($ddos in $ddosFound) {
                Write-Info "  [OVERRIDE]  DDoS-skyddsplan: $($ddos.Name)"
                Write-Detail "    Resurs-ID (ange som ddosProtectionPlanResourceId i hubnetworking-params):"
                Write-Detail "    $($ddos.ResourceId)"
                [void]$networkingWarnings.Add("DDoS-plan finns: $($ddos.Name)")
            }
        }

        # Azure-brandväggar — extrahera resurs-ID för override
        if ($firewallsF.Count -gt 0) {
            foreach ($fw in $firewallsF) {
                $fwSku = if ($fw.PSObject.Properties['Sku'] -and $fw.Sku) {
                    $skuObj = $fw.Sku
                    if ($skuObj -is [hashtable]) { " (SKU: $($skuObj.Name)/$($skuObj.Tier))" }
                    elseif ($skuObj.PSObject.Properties['Name']) { " (SKU: $($skuObj.Name)/$($skuObj.Tier))" }
                    else { '' }
                } else { '' }
                Write-Info "  [OVERRIDE]  Azure-brandvägg: $($fw.Name)$fwSku"
                Write-Detail "    Resurs-ID:"
                Write-Detail "    $($fw.ResourceId)"
                [void]$networkingWarnings.Add("Brandvägg finns: $($fw.Name)")
            }
        }

        # VPN-gateways — extrahera resurs-ID för override
        if ($vpnGwsFound.Count -gt 0) {
            foreach ($gw in $vpnGwsFound) {
                $skuStr = if ($gw.PSObject.Properties['Sku'] -and $gw.Sku) { " (SKU: $($gw.Sku))" } else { '' }
                Write-Info "  [OVERRIDE]  VPN-gateway: $($gw.Name)$skuStr"
                Write-Detail "    Resurs-ID:"
                Write-Detail "    $($gw.ResourceId)"
                [void]$networkingWarnings.Add("VPN-gateway finns: $($gw.Name)")
            }
        }

        # ExpressRoute-gateways — extrahera resurs-ID för override
        if ($erGwsFound.Count -gt 0) {
            foreach ($gw in $erGwsFound) {
                $skuStr = if ($gw.PSObject.Properties['Sku'] -and $gw.Sku) { " (SKU: $($gw.Sku))" } else { '' }
                Write-Info "  [OVERRIDE]  ExpressRoute-gateway: $($gw.Name)$skuStr"
                Write-Detail "    Resurs-ID:"
                Write-Detail "    $($gw.ResourceId)"
                [void]$networkingWarnings.Add("ExpressRoute-gateway finns: $($gw.Name)")
            }
        }

        # Bastion Hosts
        if ($bastionsF.Count -gt 0) {
            foreach ($b in $bastionsF) {
                $skuStr = if ($b.PSObject.Properties['Sku'] -and $b.Sku) { " (SKU: $($b.Sku))" } else { '' }
                Write-Info "  [INFO]  Bastion Host: $($b.Name)$skuStr"
                Write-Detail "    Resurs-ID: $($b.ResourceId)"
            }
        }

        # Brandväggspolicyer — extrahera resurs-ID för override
        if ($fwPoliciesF.Count -gt 0) {
            foreach ($fp in $fwPoliciesF) {
                $tierStr = if ($fp.PSObject.Properties['SkuTier'] -and $fp.SkuTier) { " (tier: $($fp.SkuTier))" } else { '' }
                Write-Info "  [OVERRIDE]  Brandväggspolicy: $($fp.Name)$tierStr"
                Write-Detail "    Resurs-ID (ange som firewallPolicyId override):"
                Write-Detail "    $($fp.ResourceId)"
                [void]$networkingWarnings.Add("Brandväggspolicy finns: $($fp.Name)")
            }
        }

        # Hub-VNets — extrahera resurs-ID för override
        if ($hubVnetsF.Count -gt 0) {
            foreach ($vnet in $hubVnetsF) {
                $addrStr = if ($vnet.PSObject.Properties['AddressSpace'] -and $vnet.AddressSpace) { $vnet.AddressSpace -join ', ' } else { '(okänt)' }
                Write-Info "  [OVERRIDE]  Hub-VNet: $($vnet.Name) ($addrStr)"
                Write-Detail "    Resurs-ID (hubVirtualNetworkResourceId för peering-override):"
                Write-Detail "    $($vnet.ResourceId)"
            }
            if ($routeTablesF.Count -gt 0) {
                Write-Info "  [INFO]  Route tables: $($routeTablesF.Count) hittade"
                Write-Detail "    Engine skapar route tables med 0.0.0.0/0 → brandväggens privata IP"
                Write-Detail "    Om befintliga route tables pekar på annat brandväggs-IP reroutes trafik vid första deployment"
            }
        }

        # DNS Private Resolvers
        if ($resolversF.Count -gt 0) {
            foreach ($r in $resolversF) {
                Write-Info "  [INFO]  DNS Private Resolver: $($r.Name)"
                Write-Detail "    Resurs-ID: $($r.ResourceId)"
                Write-Detail "    Engine-DNS-kedja: Resolver → FW Policy DNS-proxy → VNet custom DNS — verifiera kompatibilitet"
                [void]$networkingWarnings.Add("DNS Private Resolver finns: $($r.Name)")
            }
        }

        # DCR:er och UAMI:s — extrahera resurs-ID:n för override
        if ($dcrsF.Count -gt 0) {
            Write-Info "  [OVERRIDE]  Data Collection Rules: $($dcrsF.Count)"
            foreach ($dcr in $dcrsF) { Write-Detail "    $($dcr.Name): $($dcr.ResourceId)" }
        }
        if ($uamisF.Count -gt 0) {
            Write-Info "  [OVERRIDE]  User Assigned Managed Identities: $($uamisF.Count)"
            foreach ($uami in $uamisF) { Write-Detail "    $($uami.Name): $($uami.ResourceId)" }
        }
    }

    # --- Resource Lock Assessment ---
    $allLocks = @()
    if ($ss.Resources.PSObject.Properties['ResourceLocks']) {
        $allLocks = @($ss.Resources.ResourceLocks)
    }

    if ($allLocks.Count -gt 0) {
        Write-Host ''
        Write-Host "  Resurslås-granskning: ($($allLocks.Count) lås hittade)"

        # RG name patterns the engine deploys into or creates
        $engineRgPatterns = @('alz-', 'ALZ-', 'rg-alz-', 'rg-amba-')
        # Resource types the engine modifies (LAW, AA, hub VNet RG resources)
        $engineResourceTypes = @(
            'Microsoft.OperationalInsights/workspaces',
            'Microsoft.Automation/automationAccounts',
            'Microsoft.Network/virtualNetworks',
            'Microsoft.Network/azureFirewalls',
            'Microsoft.Network/bastionHosts',
            'Microsoft.Network/virtualNetworkGateways',
            'Microsoft.Network/privateDnsZones',
            'Microsoft.Network/dnsResolvers'
        )

        $lockResults = @()

        foreach ($lock in $allLocks) {
            $level     = [string]$lock.Level
            $scope     = [string]$lock.Scope
            $rgName    = [string]$lock.ResourceGroup
            $resType   = [string]$lock.ResourceType
            $resName   = [string]$lock.ResourceName

            # Determine if this lock targets something the engine will touch
            $targetsEngineRg  = $scope -eq 'resourceGroup' -and
                                ($engineRgPatterns | Where-Object { $rgName -like "$_*" })
            $targetsEngineRes = $scope -eq 'resource' -and
                                ($engineResourceTypes | Where-Object { $resType -like $_ })
            $targetsSubscription = $scope -eq 'subscription'

            $classification = if ($level -eq 'ReadOnly' -and ($targetsEngineRg -or $targetsEngineRes -or $targetsSubscription)) {
                'BLOCKING'
            } elseif ($level -eq 'CanNotDelete' -and ($targetsEngineRg -or $targetsEngineRes)) {
                'CAUTION'
            } else {
                'SAFE'
            }

            switch ($classification) {
                'BLOCKING' { $script:LockBlockingCount++ }
                'CAUTION'  { $script:LockCautionCount++ }
            }
            $script:LockTotalCount++

            $scopeDesc = switch ($scope) {
                'subscription'  { "prenumeration" }
                'resourceGroup' { "RG: $rgName" }
                'resource'      { "resurs: $resName ($resType) i $rgName" }
                default         { $scope }
            }

            $lockResults += [PSCustomObject]@{
                Name           = $lock.Name
                Level          = $level
                Scope          = $scope
                Classification = $classification
                ScopeDesc      = $scopeDesc
                ResourceGroup  = $rgName
                ResourceName   = $resName
                ResourceType   = $resType
            }

            switch ($classification) {
                'BLOCKING' {
                    Write-Warn "  [BLOCKERAR] $level-lås '$($lock.Name)' på $scopeDesc"
                    Write-Detail "             Låset blockerar engine-deployment direkt vid in-place."
                    Write-Detail "             Åtgärd: ta bort låset eller exkludera resursen före deployment."
                }
                'CAUTION' {
                    Write-Warn "  [VARNING]  $level-lås '$($lock.Name)' på $scopeDesc"
                    Write-Detail "             CanNotDelete-lås blockerar inte deployment men kan förhindra stack-rensningsoperationer."
                    Write-Detail "             Åtgärd: kontrollera om låset påverkar engine-resurser."
                }
                'SAFE' {
                    Write-Info "  [OK]       $level-lås '$($lock.Name)' på $scopeDesc"
                }
            }
        }

        if ($script:LockBlockingCount -gt 0) {
            Write-Host ''
            Write-Warn "  Lås-rekommendation: åtgärda blockerande lås innan engine-deployment."
        }
    }

    $infraReport += [PSCustomObject]@{
        SubscriptionId     = $ss.SubscriptionId
        ResourceGroups     = $rgs
        KeyResources       = $keyRes
        NonAlzRgs          = $nonAlzRgs
        MissingResources   = $missing
        NetworkingWarnings = @($networkingWarnings)
        ResourceLocks      = $allLocks
    }
}

if ($subScope.Count -eq 0) {
    Write-Info '  Inget prenumerationsscope i exporten.'
}

#==============================================================================
# Sektion 5b: Defender for Cloud-granskning
#==============================================================================
Write-Step 'Sektion 5b: Defender for Cloud-granskning'

# Defender plans the engine enables via Deploy-MDFC-Config-H224 (subset most commonly enabled by portal ALZ)
$engineEnabledPlans = @(
    'VirtualMachines', 'SqlServers', 'AppServices', 'StorageAccounts', 'Containers',
    'KeyVaults', 'Dns', 'Arm', 'OpenSourceRelationalDatabases', 'SqlServerVirtualMachines',
    'CosmosDbs', 'CloudPosture'
)

$defenderStateList = @()
if ($export.PSObject.Properties['DefenderState'] -and $null -ne $export.DefenderState) {
    $defenderStateList = @($export.DefenderState)
}

if ($defenderStateList.Count -eq 0) {
    Write-Info '  Ingen Defender-data insamlad — kör Export-BrownfieldState.ps1 igen för att inkludera Defender-data'
} else {
    foreach ($ds in $defenderStateList) {
        $subId = if ($ds.PSObject.Properties['SubscriptionId']) { $ds.SubscriptionId } else { $ds['SubscriptionId'] }
        Write-Host ''
        Write-Host "  ── Prenumeration: $subId ──"

        # --- Defender-planer ---
        $plans = @(if ($ds.PSObject.Properties['DefenderPlans']) { $ds.DefenderPlans } else { $ds['DefenderPlans'] })
        if ($plans.Count -gt 0) {
            $enabledPlans  = @($plans | Where-Object {
                $t = if ($_.PSObject.Properties['PricingTier']) { $_.PricingTier } else { $_['PricingTier'] }
                $t -eq 'Standard'
            })
            $disabledPlans = @($plans | Where-Object {
                $t = if ($_.PSObject.Properties['PricingTier']) { $_.PricingTier } else { $_['PricingTier'] }
                $t -ne 'Standard'
            })

            Write-Info "  Defender-planer: $($enabledPlans.Count) aktiverade (Standard), $($disabledPlans.Count) inaktiverade (Free)"

            # Planer som engine kommer att aktivera men som nu är inaktiverade
            $willEnable = @($disabledPlans | Where-Object {
                $n = if ($_.PSObject.Properties['Name']) { $_.Name } else { $_['Name'] }
                $engineEnabledPlans -contains $n
            })
            if ($willEnable.Count -gt 0) {
                Write-Warn "  Engine aktiverar $($willEnable.Count) ytterligare plan(er):"
                foreach ($p in $willEnable) {
                    $n = if ($p.PSObject.Properties['Name']) { $p.Name } else { $p['Name'] }
                    Write-Detail "    $n (nu Free — engine-policy sätter Standard)"
                }
            } else {
                Write-Ok '  Alla engine-obligatoriska Defender-planer är redan aktiverade'
            }

            # Planer med sub-planer (P1/P2 — engine kan ändra tier)
            foreach ($p in $enabledPlans) {
                $n  = if ($p.PSObject.Properties['Name'])    { $p.Name }    else { $p['Name'] }
                $sp = if ($p.PSObject.Properties['SubPlan']) { $p.SubPlan } else { $p['SubPlan'] }
                if ($sp) {
                    Write-Info "  $n — sub-plan: $sp (verifiera att engine-policy matchar önskad tier)"
                }
            }
        }

        # --- Säkerhetskontakter ---
        $contacts = @(if ($ds.PSObject.Properties['SecurityContacts']) { $ds.SecurityContacts } else { $ds['SecurityContacts'] })
        if ($contacts.Count -gt 0) {
            foreach ($c in $contacts) {
                $emails = if ($c.PSObject.Properties['Emails']) { $c.Emails } else { $c['Emails'] }
                if ($emails) {
                    Write-Info "  Säkerhetskontakt-e-post: $emails"
                    Write-Detail "    Engine-policy (Deploy-MDFC-Config-H224) skriver över detta."
                    Write-Detail "    Åtgärd: kontrollera att emailSecurityContact i platform.json policy-overrides matchar önskat värde."
                }
            }
        } else {
            Write-Info '  Inga säkerhetskontakter konfigurerade'
        }

        # --- Auto-provisionering (MMA-detektering) ---
        $autoProv = @(if ($ds.PSObject.Properties['AutoProvisioning']) { $ds.AutoProvisioning } else { $ds['AutoProvisioning'] })
        $mmaEntry = $autoProv | Where-Object {
            $n = if ($_.PSObject.Properties['Name']) { $_.Name } else { $_['Name'] }
            $n -eq 'mma-agent' -or $n -eq 'MicrosoftMonitoringAgent'
        }
        if ($mmaEntry) {
            $mmaState = if ($mmaEntry.PSObject.Properties['AutoProvision']) { $mmaEntry.AutoProvision } else { $mmaEntry['AutoProvision'] }
            if ($mmaState -eq 'On') {
                $script:MmaProvisioningCount++
                Write-Warn '  MMA auto-provisionering: PÅ — äldre Log Analytics-agent driftsätts på nya VM:ar'
                Write-Detail '    Engine använder AMA-baserad monitorering (Deploy-MDFC-DefSQL-AMA, DCR:er).'
                Write-Detail '    Både MMA och AMA körs parallellt efter deployment.'
                Write-Detail '    Åtgärd: planera MMA-avveckling efter att AMA-täckning är bekräftad.'
            } else {
                Write-Ok "  MMA auto-provisionering: $mmaState"
            }
        }
    }
}

#==============================================================================
# Sektion 5c: Tagg-schemabedömning
#==============================================================================
Write-Step 'Sektion 5c: Tagg-schemabedömning'

# Collect all tag keys from RGs and key resources across every subscription scope
$tagKeyCounts  = @{}   # key -> count of resources that carry it
$tagKeyValues  = @{}   # key -> HashSet of distinct values seen
$taggedObjects = 0

foreach ($ss in @($subScope)) {
    # Resource groups
    foreach ($rg in @($ss.Resources.ResourceGroups)) {
        $rawTags = if ($rg.PSObject.Properties['Tags']) { $rg.Tags } else { $null }
        if (-not $rawTags) { continue }
        $taggedObjects++
        foreach ($kv in $rawTags.PSObject.Properties) {
            $k = $kv.Name
            if (-not $tagKeyCounts.ContainsKey($k)) {
                $tagKeyCounts[$k]  = 0
                $tagKeyValues[$k]  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
            $tagKeyCounts[$k]++
            if ($kv.Value) { [void]$tagKeyValues[$k].Add([string]$kv.Value) }
        }
    }
    # Key resources
    foreach ($kr in @($ss.Resources.KeyResources)) {
        $rawTags = if ($kr.PSObject.Properties['Tags']) { $kr.Tags } else { $null }
        if (-not $rawTags) { continue }
        $taggedObjects++
        foreach ($kv in $rawTags.PSObject.Properties) {
            $k = $kv.Name
            if (-not $tagKeyCounts.ContainsKey($k)) {
                $tagKeyCounts[$k]  = 0
                $tagKeyValues[$k]  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
            $tagKeyCounts[$k]++
            if ($kv.Value) { [void]$tagKeyValues[$k].Add([string]$kv.Value) }
        }
    }
}

# Scan policy assignments for tag-enforcement policies
$tagPolicies = [System.Collections.Generic.List[string]]::new()
foreach ($scope in $mgScopes) {
    foreach ($pa in @($scope.Resources.PolicyAssignments)) {
        $paName = ($pa.ResourceId -split '/')[-1]
        $defId  = if ($pa.PSObject.Properties['PolicyDefinitionId']) { $pa.PolicyDefinitionId } else { '' }
        $defName = ($defId -split '/')[-1]
        if ($paName -imatch 'tag' -or $defName -imatch 'tag') {
            if (-not $tagPolicies.Contains($paName)) { [void]$tagPolicies.Add($paName) }
        }
    }
}

$totalSampleObjects = [System.Math]::Max($taggedObjects, 1)
$mandatoryThreshold = 0.80

if ($tagKeyCounts.Count -eq 0) {
    Write-Info '  Inga taggar hittades på granskade resurser'
} else {
    # Separate mandatory candidates from optional
    $mandatoryKeys = @($tagKeyCounts.GetEnumerator() | Where-Object {
        ($_.Value / $totalSampleObjects) -ge $mandatoryThreshold
    } | Sort-Object { -$_.Value })

    $optionalKeys = @($tagKeyCounts.GetEnumerator() | Where-Object {
        ($_.Value / $totalSampleObjects) -lt $mandatoryThreshold
    } | Sort-Object { -$_.Value })

    Write-Info "  Tagg-inventering: $($tagKeyCounts.Count) distinkta nyckel(ar) across $taggedObjects granskade objekt"
    Write-Host ''
    Write-Host '  Tagg-frekvens (nyckel → täckning):'
    foreach ($entry in (@($mandatoryKeys) + @($optionalKeys))) {
        $pct    = [int](($entry.Value / $totalSampleObjects) * 100)
        $marker = if (($entry.Value / $totalSampleObjects) -ge $mandatoryThreshold) { '[TROLIGEN OBLIGATORISK]' } else { '[valfri]               ' }
        $valCount = $tagKeyValues[$entry.Key].Count
        $valHint  = if ($valCount -le 5) { " — värden: $($tagKeyValues[$entry.Key] -join ', ')" } else { " — $valCount distinkta värden" }
        Write-Detail "    $marker  $($entry.Key)  ($($entry.Value)/$taggedObjects = $pct%)$valHint"
    }

    if ($mandatoryKeys.Count -gt 0) {
        Write-Host ''
        Write-Ok   "  $($mandatoryKeys.Count) tagg-nyckel(ar) förekommer på ≥$([int]($mandatoryThreshold*100))% av objekt (troligen obligatoriska):"
        foreach ($mk in $mandatoryKeys) {
            Write-Detail "    $($mk.Key)"
        }
        Write-Detail '  Åtgärd: lägg till dessa i parTags i platform.json (se Sektion 6-förslag)'
    } else {
        Write-Info  '  Inga tagg-nycklar uppnår ≥80%-tröskeln — taggning är gles eller inkonsekvent'
    }
}

if ($tagPolicies.Count -gt 0) {
    Write-Host ''
    Write-Warn "  Tagg-enforcement-policies detekterade ($($tagPolicies.Count)):"
    foreach ($tp in $tagPolicies) {
        Write-Detail "    $tp"
    }
    Write-Detail '  Åtgärd: verifiera att dessa tilldelningar inte ingår i ett ALZ-initiativ — engine kan omtilldela dem.'
} else {
    Write-Info '  Inga tagg-enforcement-policytilldelningar detekterade'
}

#==============================================================================
# Sektion 6: Konfigurationsextraktion
#==============================================================================
Write-Step 'Sektion 6: Konfigurationsextraktion (override-värden för tenant-konfig-repo)'

Write-Host ''
Write-Host '  Följande värden hittades i den befintliga miljön.'
Write-Host '  Använd dem som override-parametrar i tenant-konfigurationsrepot.'
Write-Host '  Vid in-place takeover behåller engine:n befintlig infrastruktur — ange resurs-ID:n som overrides.'
Write-Host ''

$subScopeObj = @($subScope) | Select-Object -First 1

Write-Host '  {' -ForegroundColor Gray
Write-Host "    `"LOCATION_PRIMARY`": `"$($script:CollectedLocations | Select-Object -First 1)`","
if ($subScopeObj) {
    Write-Host "    `"SUBSCRIPTION_ID_MANAGEMENT`": `"$($subScopeObj.SubscriptionId)`","
}

if ($script:CollectedLawIds.Count -eq 1) {
    Write-Host "    // Log Analytics-arbetsyta hittad:"
    Write-Host "    // $($script:CollectedLawIds | Select-Object -First 1)"
}
elseif ($script:CollectedLawIds.Count -gt 1) {
    Write-Warn "  Flera LAW-ID:n hittade (avvikelse!) — granska noggrant:"
    foreach ($lawId in $script:CollectedLawIds) { Write-Detail "    $lawId" }
}

if ($script:CollectedEmails.Count -gt 0) {
    Write-Host "    `"SECURITY_CONTACT_EMAIL`": `"$($script:CollectedEmails | Select-Object -First 1)`","
}
if ($script:CollectedEmails.Count -gt 1) {
    Write-Warn "  Flera e-postadresser hittade — verifiera vilken som är korrekt:"
    foreach ($e in $script:CollectedEmails) { Write-Detail "    $e" }
}
Write-Host '  }' -ForegroundColor Gray

if ($script:CollectedDcrIds.Count -gt 0) {
    Write-Host ''
    Write-Info "  DCR-ID:n refererade i tilldelningar:"
    foreach ($id in $script:CollectedDcrIds) { Write-Detail "    $id" }
}
if ($script:CollectedUamiIds.Count -gt 0) {
    Write-Host ''
    Write-Info "  UAMI-ID:n refererade i tilldelningar:"
    foreach ($id in $script:CollectedUamiIds) { Write-Detail "    $id" }
}

# parTags-förslag (från Sektion 5c obligatorisk tagg-analys)
if ($tagKeyCounts.Count -gt 0) {
    $mandatoryTagsForSec6 = @($tagKeyCounts.GetEnumerator() | Where-Object {
        ($_.Value / [System.Math]::Max($taggedObjects, 1)) -ge $mandatoryThreshold
    } | Sort-Object Name | ForEach-Object { $_.Key })
    if ($mandatoryTagsForSec6.Count -gt 0) {
        Write-Host ''
        Write-Info "  Föreslagna parTags (baserat på tagg-frekvensanalys — uppdatera värden vid behov):"
        Write-Host '  parTags: {' -ForegroundColor Gray
        foreach ($tk in $mandatoryTagsForSec6) {
            $sampleVal = if ($tagKeyValues[$tk].Count -eq 1) { $tagKeyValues[$tk] | Select-Object -First 1 } else { '<uppdatera-värde>' }
            Write-Host "    `"$tk`": `"$sampleVal`"" -ForegroundColor Gray
        }
        Write-Host '  }' -ForegroundColor Gray
    }
}

# Plattformsprenumerationsmapping från SubscriptionPlacement
Write-Host ''
Write-Host '  Plattformsprenumerationsmapping (från MG-placering):'
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
    $fullModeSubsFound = 0
    foreach ($normName in @('management', 'connectivity', 'identity', 'security')) {
        $key = $platformMgMap[$normName]
        $actualId = if ($normalizedToActualMg.ContainsKey($normName)) { $normalizedToActualMg[$normName] } else { $normName }
        $subs = @(Get-SubsUnderMg $actualId)
        if ($subs.Count -eq 1) {
            $fullModeSubsFound++
            $sub = $subs[0]
            $subId = if ($sub.PSObject.Properties['Id']) { $sub.Id } else { '(okänd)' }
            $subName = if ($sub.PSObject.Properties['DisplayName'] -and $sub.DisplayName) { " ($($sub.DisplayName))" } else { '' }
            Write-Ok "    $key`: $subId$subName"
        } elseif ($subs.Count -gt 1) {
            $fullModeSubsFound++
            Write-Warn "    $key`: flera prenumerationer hittade under $actualId — kontrollera placering:"
            foreach ($sub in $subs) {
                $subId = if ($sub.PSObject.Properties['Id']) { $sub.Id } else { '?' }
                $subName = if ($sub.PSObject.Properties['DisplayName'] -and $sub.DisplayName) { $sub.DisplayName } else { '' }
                Write-Detail "      $subId ($subName)"
            }
        } else {
            Write-Detail "    $key`: (ej hittad)"
        }
    }

    # PLATFORM_MODE=simple: en prenumeration direkt under platform-MG
    if ($fullModeSubsFound -eq 0) {
        $platformActualId = if ($normalizedToActualMg.ContainsKey('platform')) { $normalizedToActualMg['platform'] } else { 'platform' }
        $platformDirectSubs = @(if ($mgSubscriptions.ContainsKey($platformActualId)) { $mgSubscriptions[$platformActualId] } else { @() })
        if ($platformDirectSubs.Count -eq 1) {
            $sub = $platformDirectSubs[0]
            $subId = if ($sub.PSObject.Properties['Id']) { $sub.Id } else { '(okänd)' }
            $subName = if ($sub.PSObject.Properties['DisplayName'] -and $sub.DisplayName) { " ($($sub.DisplayName))" } else { '' }
            Write-Ok  "    SUBSCRIPTION_ID_PLATFORM (simple-läge): $subId$subName"
            Write-Detail "    Sätt PLATFORM_MODE=simple och SUBSCRIPTION_ID_PLATFORM i platform.json."
            Write-Detail "    De fyra full-mode-sub-ID:na bör också sättas till detta värde (schemat kräver alla nycklar)."
        } elseif ($platformDirectSubs.Count -gt 1) {
            Write-Warn "    Flera prenumerationer hittade direkt under platform-MG ($platformActualId) — kontrollera placering:"
            foreach ($sub in $platformDirectSubs) {
                $subId = if ($sub.PSObject.Properties['Id']) { $sub.Id } else { '?' }
                $subName = if ($sub.PSObject.Properties['DisplayName'] -and $sub.DisplayName) { $sub.DisplayName } else { '' }
                Write-Detail "      $subId ($subName)"
            }
        } else {
            Write-Warn "    Inga prenumerationer hittades under management/connectivity/identity/security eller platform-MG."
            Write-Detail "    Kör Export-BrownfieldState.ps1 igen och kontrollera att -PlatformSubscriptionIds täcker rätt prenumerationer."
        }
    }
} else {
    Write-Detail "    (ej tillgänglig — kör Export-BrownfieldState.ps1 igen för att samla prenumerationsplacering)"
}

# Hub-nätverksresurser från infrastrukturscan — resurs-ID:n för overrides
Write-Host ''
Write-Host '  Hub-nätverk (från infrastrukturscan) — resurs-ID:n för overrides:'
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
        $addrSpace = if ($vnet.PSObject.Properties['AddressSpace'] -and $vnet.AddressSpace) { $vnet.AddressSpace -join ', ' } else { '(okänt)' }
        Write-Ok "    Hub-VNet: $($vnet.Name) ($addrSpace) i $($vnet.ResourceGroup)"
        Write-Detail "      Resurs-ID (hubVirtualNetworkResourceId): $($vnet.ResourceId)"
    }
} else {
    Write-Detail "    Hub-VNet: (ej hittad — kontrollera att -PlatformSubscriptionIds täcker connectivity-sub)"
}
if ($firewalls.Count -gt 0) {
    foreach ($fw in $firewalls) {
        Write-Info "    Azure-brandvägg: $($fw.Name) i $($fw.ResourceGroup)"
        Write-Detail "      Resurs-ID: $($fw.ResourceId)"
    }
} else {
    Write-Detail "    Azure-brandvägg: (ej hittad)"
}
if ($ddosPlansAll.Count -gt 0) {
    foreach ($d in $ddosPlansAll) {
        Write-Info "    DDoS-skyddsplan: $($d.Name)"
        Write-Detail "      Resurs-ID (ddosProtectionPlanResourceId): $($d.ResourceId)"
    }
} else {
    Write-Detail "    DDoS-skyddsplan: (ej hittad)"
}
if ($vpnGwsAll.Count -gt 0) {
    foreach ($gw in $vpnGwsAll) {
        Write-Info "    VPN-gateway: $($gw.Name)"
        Write-Detail "      Resurs-ID: $($gw.ResourceId)"
    }
} else {
    Write-Detail "    VPN-gateway: (ej hittad)"
}
if ($erGwsAll.Count -gt 0) {
    foreach ($gw in $erGwsAll) {
        Write-Info "    ExpressRoute-gateway: $($gw.Name)"
        Write-Detail "      Resurs-ID: $($gw.ResourceId)"
    }
} else {
    Write-Detail "    ExpressRoute-gateway: (ej hittad)"
}
if ($bastionsAll.Count -gt 0) {
    foreach ($b in $bastionsAll) {
        Write-Info "    Bastion Host: $($b.Name)"
        Write-Detail "      Resurs-ID: $($b.ResourceId)"
    }
} else {
    Write-Detail "    Bastion Host: (ej hittad)"
}
if ($fwPoliciesAll.Count -gt 0) {
    foreach ($fp in $fwPoliciesAll) {
        Write-Info "    Brandväggspolicy: $($fp.Name)"
        Write-Detail "      Resurs-ID (firewallPolicyId): $($fp.ResourceId)"
    }
}
if ($resolversAll.Count -gt 0) {
    foreach ($r in $resolversAll) {
        Write-Info "    DNS Private Resolver: $($r.Name)"
        Write-Detail "      Resurs-ID: $($r.ResourceId)"
    }
}
# ── Privat DNS-zonbedömning ──
Write-Host ''
Write-Host '  Privat DNS-zon-inventering och override-extraktion:'
if ($privateDnsZones.Count -eq 0) {
    Write-Detail "    (inga hittade — engine skapar det fullständiga Private Link-zonsettet vid deployment)"
} else {
    # Zoninventering per resursgrupp
    $zonesByRg = @{}
    foreach ($z in ($privateDnsZones | Sort-Object ResourceGroup, Name)) {
        if (-not $zonesByRg.Contains($z.ResourceGroup)) {
            $zonesByRg[$z.ResourceGroup] = [System.Collections.Generic.List[object]]::new()
        }
        $zonesByRg[$z.ResourceGroup].Add($z)
    }
    Write-Info "    Zoninventering ($($privateDnsZones.Count) totalt):"
    foreach ($rg in $zonesByRg.Keys) {
        Write-Detail "      $rg ($($zonesByRg[$rg].Count) zoner)"
    }

    # Engine-defaultzoner (avm/ptn/network/private-link-private-dns-zones:0.7.2)
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

    $engineZoneCount = 0
    $extraCount      = 0
    $activeCount     = 0
    $hubLinkedCount  = 0
    $dnsRgSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    Write-Host ''
    foreach ($zone in ($privateDnsZones | Sort-Object Name)) {
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
        if ($hasActiveRecords)       { [void]$flags.Add("AKTIVA_POSTER:$recordCount") }
        if ($hubLinks.Count -gt 0)   { [void]$flags.Add('HUB_LÄNKAD') }
        if ($spokeLinks.Count -gt 0) { [void]$flags.Add("SPOKE-LÄNKAR:$($spokeLinks.Count)") }
        $flagStr = if ($flags.Count -gt 0) { "  [$($flags -join ', ')]" } else { '' }

        if ($isEngineZone) {
            $engineZoneCount++
            [void]$dnsRgSet.Add($zone.ResourceGroup)
            Write-Info "    ENGINE-zon  $($zone.Name)  (RG: $($zone.ResourceGroup))$flagStr"
        } else {
            $extraCount++
            Write-Detail "    ANPASSAD    $($zone.Name)  (RG: $($zone.ResourceGroup))$flagStr"
        }

        if ($hasActiveRecords)     { $activeCount++ }
        if ($hubLinks.Count -gt 0) { $hubLinkedCount++ }
    }

    # Saknade engine-defaultzoner
    $brownfieldZoneSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($z in $privateDnsZones) { [void]$brownfieldZoneSet.Add($z.Name) }
    $missingCount = 0
    foreach ($ez in $engineDefaultZones) {
        if (-not $brownfieldZoneSet.Contains($ez)) { $missingCount++ }
    }

    Write-Host ''
    Write-Info "    Engine-defaultzoner: $engineZoneCount   Anpassade: $extraCount   Saknas: $missingCount"
    if ($activeCount -gt 0)    { Write-Warn "    AKTIVA_POSTER: $activeCount zon(er) har poster utöver SOA+NS — verifiera att orphaning inte bryter Private Link-resolution" }
    if ($hubLinkedCount -gt 0) { Write-Warn "    HUB_LÄNKAD: $hubLinkedCount zon(er) redan länkade till hub-VNet — verifiera att engine-länkning är idempotent" }

    # DNS-RG override-extraktion — primär override för in-place
    if ($dnsRgSet.Count -gt 0) {
        Write-Host ''
        Write-Ok "    Befintlig DNS-resursgrupp (ange som privateDnsSettings.dnsResourceGroupId):"
        foreach ($rg in $dnsRgSet) {
            Write-Detail "      $rg"
        }
        Write-Detail "    Vid in-place hanterar engine:n zonerna i befintlig RG — inga duplikat skapas."
    }
}
if ($dcrsAll.Count -gt 0) {
    Write-Info "    Data Collection Rules: $($dcrsAll.Count) befintliga"
    foreach ($dcr in $dcrsAll) { Write-Detail "      $($dcr.Name): $($dcr.ResourceId)" }
}
if ($uamisAll.Count -gt 0) {
    Write-Info "    User Assigned Managed Identities: $($uamisAll.Count) befintliga"
    foreach ($uami in $uamisAll) { Write-Detail "      $($uami.Name): $($uami.ResourceId)" }
}

#==============================================================================
# Sektion 7: Risksammanfattning
#==============================================================================
Write-Step 'Sektion 7: Risksammanfattning'

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
Write-Host "  Policydefinitioner:"
if ($totalStdDefs -gt 0) { Write-Ok   "    Standard — exakt match:       $totalStdDefs" }
if ($totalStdMismatchDefs -gt 0) {
    $hasDenyAssigned = $script:MismatchCountByEffect['DenyAssigned'] -gt 0
    if ($hasDenyAssigned) {
        Write-Err  "    Standard — regelavvikelse:     $totalStdMismatchDefs (engine skriver över vid deployment)"
    } else {
        Write-Warn "    Standard — regelavvikelse:     $totalStdMismatchDefs (engine skriver över vid deployment)"
    }
    Write-Host ''
    Write-Host '  Regelavvikelser per effekt:'
    if ($script:MismatchCountByEffect['DenyAssigned']      -gt 0) { Write-Err  "    Deny (tilldelade):        $($script:MismatchCountByEffect['DenyAssigned']) (aktiv risk — verifiera resursefterlevnad innan deployment)" }
    if ($script:MismatchCountByEffect['DenyUnassigned']    -gt 0) { Write-Warn "    Deny (otilldelade):       $($script:MismatchCountByEffect['DenyUnassigned']) (definition finns — ingen nuvarande påverkan)" }
    if ($script:MismatchCountByEffect['DeployIfNotExists'] -gt 0) { Write-Warn "    DeployIfNotExists:        $($script:MismatchCountByEffect['DeployIfNotExists']) (kan trigga remedieringar)" }
    if ($script:MismatchCountByEffect['Modify']            -gt 0) { Write-Warn "    Modify:                   $($script:MismatchCountByEffect['Modify']) (kan ändra resursegenskaper)" }
    if ($script:MismatchCountByEffect['Append']            -gt 0) { Write-Info "    Append:                   $($script:MismatchCountByEffect['Append']) (kan lägga till egenskaper vid nästa uppdatering)" }
    if ($script:MismatchCountByEffect['Audit']             -gt 0) { Write-Ok   "    Audit/AuditIfNotExists:   $($script:MismatchCountByEffect['Audit']) (informativ)" }
    if ($script:MismatchCountByEffect['Other']             -gt 0) { Write-Warn "    Övriga/okända:            $($script:MismatchCountByEffect['Other'])" }
} else { Write-Ok "    Regelavvikelser:              0" }
if ($totalNonStdDefs -gt 0) { Write-Warn "    Icke-standard (granska):      $totalNonStdDefs" } else { Write-Ok "    Icke-standard:                0" }
if ($totalAmbaDefs -gt 0) { Write-Amba "    AMBA (informativ):             $totalAmbaDefs" }
if ($totalDeprDefs -gt 0) {
    $deprAssigned   = @($script:AllDeprDefList | Where-Object {
        $defAssignmentScopes.ContainsKey($_.Name) -and $defAssignmentScopes[$_.Name].Count -gt 0
    })
    $deprUnassigned = $totalDeprDefs - $deprAssigned.Count
    if ($deprAssigned.Count -gt 0) {
        Write-Warn "    Utfasade (tilldelade):        $($deprAssigned.Count) (engine ersätter med efterföljare — granska innan deployment)"
        Write-Info "    Utfasade (otilldelade):       $deprUnassigned"
        if ($Detailed) {
            Write-Host ''
            Write-Warn "  ── Utfasade definitioner fortfarande tilldelade ──"
            foreach ($e in $deprAssigned) {
                $assignScopes = @($defAssignmentScopes[$e.Name])
                $scopeStr = ($assignScopes | ForEach-Object { "$($_.ScopeName) ($($_.ManagementGroupId))" }) -join ', '
                Write-Warn   "  [UTFASAD TILLDELAD] $($e.Name)"
                Write-Detail "    visningsnamn: $($e.DisplayName)"
                Write-Detail "    tilldelad vid: $scopeStr"
            }
        }
    } else {
        Write-Info "    Utfasade:                     $totalDeprDefs"
    }
}

Write-Host ''
Write-Host "  Policysetdefinitioner:"
if ($totalStdSets -gt 0) { Write-Ok   "    Standard (säkert):            $totalStdSets" }
if ($totalNonStdSets -gt 0) { Write-Warn "    Icke-standard (granska):      $totalNonStdSets" } else { Write-Ok "    Icke-standard:                0" }
if ($totalAmbaSets -gt 0) { Write-Amba "    AMBA (informativ):             $totalAmbaSets" }
if ($totalDeprSets -gt 0) { Write-Info "    Utfasade:                     $totalDeprSets" }

Write-Host ''
Write-Host "  Tilldelningar:                   Icke-std-refs: $totalNonStdAssignments   AMBA-refs: $totalAmbaAssignments"
Write-Host "  Anpassade rolldefinitioner:      $totalCustomRoles"
if ($script:RoleDefCheckResults.Count -gt 0) {
    if ($script:RoleDefNameCollisionCount -gt 0) {
        Write-Warn "  ALZ rolldefinitionskontroll:     $($script:RoleDefCheckResults.Count) roller — $($script:RoleDefNameCollisionCount) NAME_COLLISION, $($script:RoleDefDriftCount) DRIFT"
    } elseif ($script:RoleDefDriftCount -gt 0) {
        Write-Warn "  ALZ rolldefinitionskontroll:     $($script:RoleDefCheckResults.Count) roller — $($script:RoleDefDriftCount) DRIFT (engine skriver över)"
    } else {
        Write-Ok   "  ALZ rolldefinitionskontroll:     $($script:RoleDefCheckResults.Count) roller — alla MATCH eller SAKNAS (säkert att deploya)"
    }
}
Write-Host "  Icke-ALZ-resursgrupper:          $totalNonAlzRgs"
Write-Host "  Saknade förväntade resurser:     $totalMissingInfra"
if ($script:LockTotalCount -gt 0) {
    if ($script:LockBlockingCount -gt 0) {
        Write-Warn "  Resurslås: $($script:LockTotalCount) totalt  ($($script:LockBlockingCount) BLOCKERAR — blockerar engine-deployment direkt)"
    } elseif ($script:LockCautionCount -gt 0) {
        Write-Warn "  Resurslås: $($script:LockTotalCount) totalt  ($($script:LockCautionCount) VARNING — granska innan stack-operationer)"
    } else {
        Write-Ok   "  Resurslås: $($script:LockTotalCount) totalt  (0 blockerande)"
    }
} else {
    Write-Ok   "  Resurslås: 0"
}

Write-Host ''
Write-Host '  Prenumerationsnivå-styrning:'
if ($subscriptionGovernance.Count -eq 0) {
    Write-Detail '    (ej insamlad — kör Export-BrownfieldState.ps1 igen för att inkludera prenumerationsdata)'
}
else {
    if ($script:TotalSubLevelNonStdAssignments -gt 0) {
        Write-Warn "    Icke-std direkttilldelningar: $($script:TotalSubLevelNonStdAssignments) (granskning krävs)"
    }
    else {
        Write-Ok "    Icke-std direkttilldelningar: 0"
    }
    if ($script:TotalSubLevelExemptions -gt 0) {
        if ($script:TotalDenyExemptions -gt 0) {
            Write-Warn "    Policyundantag: $($script:TotalSubLevelExemptions) totalt  ($($script:TotalDenyExemptions) undantar Deny-effekt — granska)"
        }
        else {
            Write-Info "    Policyundantag: $($script:TotalSubLevelExemptions)"
        }
    }
    else {
        Write-Ok "    Policyundantag:               0"
    }
}

Write-Host ''
Write-Host '  Defender for Cloud-status:'
if ($script:MmaProvisioningCount -gt 0) {
    Write-Warn "    MMA auto-provisionering PÅ: $($script:MmaProvisioningCount) prenumeration(er) — planera AMA-migration efter deployment"
} else {
    Write-Ok   "    MMA auto-provisionering: av (eller ej insamlad)"
}

Write-Host ''
Write-Host '  Blueprint-tilldelningar:'
if ($script:BlueprintCount -gt 0) {
    Write-Err  "    $($script:BlueprintCount) blueprint-tilldelning(ar) — MÅSTE tas bort innan engine-deployment"
} else {
    Write-Ok   "    0 blueprint-tilldelningar"
}

Write-Host ''
Write-Host '  Cross-MG RBAC (policy-drivna identiteter):'
if ($script:OrphanRiskCount -gt 0) {
    Write-Warn "    ORPHAN_RISK: $($script:OrphanRiskCount) identitet(er) — cross-MG-rolltilldelningar föräldralösa när engine skapar nya"
} else {
    Write-Ok   "    ORPHAN_RISK: 0"
}
if ($script:MissingRbacCount -gt 0) {
    Write-Warn "    MISSING_RBAC: $($script:MissingRbacCount) förväntad(e) cross-MG-behörighet(er) saknas i brownfield"
} else {
    Write-Ok   "    MISSING_RBAC: 0"
}

# Trafikljus — In-place takeover-modell. AMBA räknas INTE som icke-standard.
# Blueprint-blockerare och blockerande resurslås triggar RÖTT.
# Deny-avvikelser, NAME_COLLISION och granskningsposter triggar GULT.
Write-Host ''
$hasDenyAssigned   = $script:MismatchCountByEffect['DenyAssigned'] -gt 0
$hasBlueprintBlock = $script:BlueprintCount -gt 0
$hasBlockingLocks  = $script:LockBlockingCount -gt 0
$hasNameCollision  = $script:RoleDefNameCollisionCount -gt 0
$hasReviewItems    = $totalNonStdDefs -gt 0 -or $totalNonStdSets -gt 0 -or $totalStdMismatchDefs -gt 0
$hasMinorDrift     = $totalDeprDefs -gt 0 -or $totalDeprSets -gt 0 -or $totalNonStdAssignments -gt 0 -or $totalNonAlzRgs -gt 0 -or $totalCustomRoles -gt 0 -or $script:TotalSubLevelNonStdAssignments -gt 0 -or $script:TotalDenyExemptions -gt 0 -or $script:LockCautionCount -gt 0 -or $script:RoleDefDriftCount -gt 0 -or $script:OrphanRiskCount -gt 0 -or $script:MissingRbacCount -gt 0 -or $script:MmaProvisioningCount -gt 0

if (-not $hasReviewItems -and -not $hasMinorDrift -and -not $hasBlueprintBlock -and -not $hasBlockingLocks) {
    Write-Colored 'GREEN' 'Green' "Befintlig miljö är ren. Låg risk för in-place takeover."
    if ($totalAmbaDefs -gt 0 -or $totalAmbaSets -gt 0) {
        Write-Amba "  OBS: AMBA-monitoringstack detekterad ($totalAmbaDefs definitioner, $totalAmbaSets sets) — informativ."
    }
}
elseif ($hasBlueprintBlock -or $hasBlockingLocks) {
    Write-Colored 'RED' 'Red' "Miljön har blockerare som måste åtgärdas innan engine-deployment."
    if ($hasBlueprintBlock) {
        Write-Host "  Blueprint: $($script:BlueprintCount) aktiv blueprint-tilldelning(ar) — blockerar engine-styrning."
        Write-Host '    a) Ta bort alla blueprints i Sektion 4b innan engine startas'
        Write-Host '    b) Granska blueprint-artefakter för att identifiera policy/rolltilldelningar som engine måste äga'
    }
    if ($hasBlockingLocks) {
        Write-Host "  Resurslås: $($script:LockBlockingCount) blockerande lås — blockerar engine-deployment direkt."
        Write-Host '    a) Ta bort eller exkludera resurser med blockerande lås innan deployment'
    }
}
elseif ($hasDenyAssigned -or $hasReviewItems -or $hasNameCollision) {
    Write-Colored 'YELLOW' 'Yellow' "Miljön har poster som kräver granskning innan eller under engine-deployment."
    Write-Host '  Engine-deployment är möjlig. Granska dessa poster:'
    Write-Host '    a) Verifiera att befintliga resurser uppfyller nya Deny-policies'
    Write-Host '    b) Kontrollera NAME_COLLISION för rolldefinitioner — skapar driftkonfusion'
    Write-Host '    c) Rensa föräldralösa managed identity-rolltilldelningar efter engine-deployment'
    if ($hasDenyAssigned) {
        Write-Host '  Kör med -Detailed för att se vilka policies ändras och vilka resurstyper de påverkar.'
    }
}
else {
    Write-Colored 'YELLOW' 'Yellow' "Miljön har utfasade policies eller lägre avvikelse — granska innan adoption."
}

#==============================================================================
# Valfritt: skriv JSON-rapport
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
            TotalResourceLocks              = $script:LockTotalCount
            BlockingResourceLocks           = $script:LockBlockingCount
            CautionResourceLocks            = $script:LockCautionCount
            HasBlockingLocks                = ($script:LockBlockingCount -gt 0)
            RoleDefCheck                    = [PSCustomObject]@{
                Results            = @($script:RoleDefCheckResults)
                NameCollisionCount = $script:RoleDefNameCollisionCount
                DriftCount         = $script:RoleDefDriftCount
            }
        }
    }
    $fullReport | ConvertTo-Json -Depth 10 | Set-Content $OutputFile
    Write-Host ''
    Write-Info "Fullständig rapport skriven till: $OutputFile"
}

Write-Host ''

#==============================================================================
# Valfritt: generera HTML-diff-rapport för Deny-effekt-regelavvikelser
#==============================================================================
if ($DiffReport -ne '') {
    $pythonScript = Join-Path $PSScriptRoot 'diff-deny-rules.py'
    if (-not (Test-Path $pythonScript)) {
        Write-Warn "diff-deny-rules.py hittades inte vid $pythonScript — hoppar över diff-rapport"
    } else {
        $python = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' }
                  elseif (Get-Command python -ErrorAction SilentlyContinue) { 'python' }
                  else { $null }
        if (-not $python) {
            Write-Warn 'Python 3 hittades inte i PATH — hoppar över diff-rapport'
        } else {
            Write-Info "Genererar principregelsdiff-rapport: $DiffReport"
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
                    Write-Ok "Diff-rapport skriven till: $DiffReport"
                }
            } finally {
                Remove-Item $tempFile -ErrorAction SilentlyContinue
            }
        }
    }
}

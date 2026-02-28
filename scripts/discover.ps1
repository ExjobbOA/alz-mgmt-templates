#Requires -Version 7
<#
.SYNOPSIS
    ALZ Brownfield Discovery — "git diff" for an existing Azure tenant.
    Read-only. No changes are made.

.DESCRIPTION
    Scans an existing Azure tenant and produces a green/yellow/red report
    showing how ready each subscription is for ALZ adoption:

      Green  — no conflicts with ALZ policies, safe to adopt straight away
      Yellow — potential conflicts that require a decision before adoption
      Red    — hard conflicts that must be resolved before adoption

    Run this before onboard.ps1 on a brownfield tenant. Review the output,
    make placement decisions, resolve reds, then proceed with adoption.

.PARAMETER TenantId
    Azure tenant ID to scan. Auto-detected from az account show if omitted.

.PARAMETER OutputPath
    Optional path to write the full report as JSON.

.EXAMPLE
    ./scripts/discover.ps1

.EXAMPLE
    ./scripts/discover.ps1 -TenantId 'xxxxxxxx-...' -OutputPath './report.json'
#>

[CmdletBinding()]
param(
    [string] $TenantId   = '',
    [string] $OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NoColor = -not $Host.UI.SupportsVirtualTerminal
function Write-Step   ($msg) { if ($NoColor) { Write-Host "`n── $msg ──" }           else { Write-Host "`n`e[1m── $msg ──`e[0m" } }
function Write-Info   ($msg) { if ($NoColor) { Write-Host "[INFO]   $msg" }           else { Write-Host "`e[36m[INFO]`e[0m   $msg" } }
function Write-Green  ($msg) { if ($NoColor) { Write-Host "[GREEN]  $msg" }           else { Write-Host "`e[32m[GREEN]`e[0m  $msg" } }
function Write-Yellow ($msg) { if ($NoColor) { Write-Host "[YELLOW] $msg" }           else { Write-Host "`e[33m[YELLOW]`e[0m $msg" } }
function Write-Red    ($msg) { if ($NoColor) { Write-Host "[RED]    $msg" }           else { Write-Host "`e[31m[RED]`e[0m    $msg" } }
function Write-Skip   ($msg) { if ($NoColor) { Write-Host "[SKIP]   $msg" }           else { Write-Host "`e[90m[SKIP]`e[0m   $msg" } }

#==============================================================================
# ALZ policy conflict map
# Maps resource type (lowercase) → ALZ policy assignment names that apply to it.
# This drives the yellow/red classification.
#
# STUB: this list covers the most common deny policies. Extend as needed.
#       Severity 'Red' = Deny effect (will break things immediately)
#       Severity 'Yellow' = Audit effect or fixable with an exclusion
#==============================================================================
$alzPolicyConflictMap = @{
    'microsoft.network/publicipaddresses'        = @(
        [pscustomobject]@{ Policy = 'Deny-Public-IP';                Severity = 'Red' }
    )
    'microsoft.network/networkinterfaces'        = @(
        [pscustomobject]@{ Policy = 'Deny-IP-forwarding';            Severity = 'Yellow' }
    )
    'microsoft.network/networksecuritygroups'    = @(
        [pscustomobject]@{ Policy = 'Deny-MgmtPorts-Internet';       Severity = 'Yellow' }
        [pscustomobject]@{ Policy = 'Deny-RDP-From-Internet';        Severity = 'Red' }
        [pscustomobject]@{ Policy = 'Deny-SSH-From-Internet';        Severity = 'Red' }
    )
    'microsoft.network/virtualnetworks'          = @(
        [pscustomobject]@{ Policy = 'Deny-Subnet-Without-Nsg';       Severity = 'Yellow' }
    )
    'microsoft.storage/storageaccounts'          = @(
        [pscustomobject]@{ Policy = 'Deny-Storage-http';             Severity = 'Yellow' }
        [pscustomobject]@{ Policy = 'Deny-Public-Endpoints-Storage'; Severity = 'Yellow' }
    )
    'microsoft.keyvault/vaults'                  = @(
        [pscustomobject]@{ Policy = 'Deny-Public-Endpoints-KeyVault'; Severity = 'Yellow' }
    )
    'microsoft.sql/servers'                      = @(
        [pscustomobject]@{ Policy = 'Deny-Public-Endpoints-Sql';     Severity = 'Yellow' }
    )
    'microsoft.containerservice/managedclusters' = @(
        [pscustomobject]@{ Policy = 'Deny-Priv-Escalation-AKS';      Severity = 'Red' }
        [pscustomobject]@{ Policy = 'Deny-Privileged-AKS';           Severity = 'Red' }
    )
}

#==============================================================================
# Step 1: Resolve inputs
#==============================================================================
function Resolve-Inputs {
    Write-Step 'Resolving inputs'

    if ($Script:TenantId -eq '') {
        $account = az account show 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($account) { $Script:TenantId = $account.tenantId }
    }

    if ($Script:TenantId -eq '') {
        $Script:TenantId = Read-Host 'Tenant ID'
        if ($Script:TenantId -eq '') { Write-Error 'Tenant ID is required'; exit 1 }
    }

    Write-Info "Tenant: $Script:TenantId"
}

#==============================================================================
# Step 2: Discover all subscriptions in the tenant
#==============================================================================
function Get-AllSubscriptions {
    Write-Step 'Discovering subscriptions'

    $subs = Get-AzSubscription -TenantId $Script:TenantId -ErrorAction SilentlyContinue
    Write-Info "Found $($subs.Count) subscription(s)"
    return $subs
}

#==============================================================================
# Step 3: Find which MG a subscription currently lives in
#
# STUB: iterates the known ALZ MG names using the same REST approach as
#       cleanup.ps1. Does not discover arbitrary/custom MG hierarchies.
#       Full implementation would walk the tenant MG tree recursively.
#==============================================================================
function Get-SubManagementGroup([string]$SubscriptionId) {
    $candidateMgs = @(
        'connectivity', 'identity', 'management', 'security',
        'corp', 'online',
        'platform', 'landingzones',
        'sandbox', 'decommissioned',
        'alz'
    )

    foreach ($mgName in $candidateMgs) {
        $response = Invoke-AzRestMethod `
            -Path "/providers/Microsoft.Management/managementGroups/$mgName/subscriptions?api-version=2020-05-01" `
            -Method GET `
            -ErrorAction SilentlyContinue
        if (-not $response -or $response.StatusCode -ne 200) { continue }

        $subList = ($response.Content | ConvertFrom-Json).value
        if ($subList | Where-Object { $_.name -eq $SubscriptionId }) {
            return $mgName
        }
    }

    return '(tenant root)'
}

#==============================================================================
# Step 4: Inventory resource types in a subscription
#==============================================================================
function Get-ResourceSummary([string]$SubscriptionId) {
    Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue | Out-Null

    $resources = Get-AzResource -ErrorAction SilentlyContinue
    if (-not $resources) { return @() }

    return $resources |
        Group-Object { $_.ResourceType.ToLower() } |
        ForEach-Object { [pscustomobject]@{ Type = $_.Name; Count = $_.Count } }
}

#==============================================================================
# Step 5: Check resource inventory against the ALZ policy conflict map
#
# STUB: this is a resource-type-level check only.
#       Deep inspection (e.g. NSG rules with 0.0.0.0/0 on port 22/3389,
#       storage accounts with public access enabled, Key Vault firewall off)
#       would go here and would change Yellow → Red for specific resources.
#==============================================================================
function Get-PolicyConflicts($ResourceSummary) {
    $conflicts = @()

    foreach ($group in $ResourceSummary) {
        if (-not $alzPolicyConflictMap.ContainsKey($group.Type)) { continue }

        foreach ($entry in $alzPolicyConflictMap[$group.Type]) {
            $conflicts += [pscustomobject]@{
                ResourceType = $group.Type
                Count        = $group.Count
                Policy       = $entry.Policy
                Severity     = $entry.Severity
            }
        }
    }

    # STUB: deep NSG rule inspection (inbound allow 22/3389 from 0.0.0.0/0) → Red
    # STUB: storage account public blob access check → Red

    return $conflicts
}

#==============================================================================
# Step 5b: Check for existing policy/role definitions at MG and sub scope
#
# This is the "custom policies disappearing" guard the senior raised.
# Deployment Stacks with DeleteAll only manage what they deployed — they won't
# delete things they never owned. But there are still two real risks:
#
#   1. Name collision: ALZ tries to create a policy def that already exists
#      at the same scope → ARM deployment error
#   2. Effect collision: customer has their own assignments at sub/MG scope
#      that conflict with or are shadowed by incoming ALZ MG-level policies
#
# This function surfaces both so they can be resolved before adoption.
#
# STUB: the enumeration calls below are real. What's stubbed is the
#       comparison against the full ALZ policy library — that would require
#       loading all the .alz_policy_definition.json files and comparing names.
#==============================================================================
function Get-PolicyDefinitionConflicts([string]$SubscriptionId) {
    $conflicts = @()

    Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue | Out-Null

    # Get all custom policy definitions visible from this subscription
    $customDefs = Get-AzPolicyDefinition -Custom -ErrorAction SilentlyContinue
    if ($customDefs) {
        Write-Info "  Custom policy definitions visible: $($customDefs.Count)"

        foreach ($def in $customDefs) {
            # STUB: compare $def.Name against the ALZ policy library name list
            # If there is a name match, it's a Red conflict (ARM will error on deploy)
            # For now, just surface all custom definitions as Yellow for human review
            $conflicts += [pscustomobject]@{
                Kind     = 'CustomPolicyDefinition'
                Name     = $def.Name
                Scope    = $def.Properties.metadata.category ?? '(unknown)'
                Severity = 'Yellow'
                Detail   = 'Custom policy definition — verify no name collision with ALZ library'
            }
        }
    }

    # Get all custom policy set definitions (initiatives)
    $customSets = Get-AzPolicySetDefinition -Custom -ErrorAction SilentlyContinue
    if ($customSets) {
        Write-Info "  Custom initiative definitions visible: $($customSets.Count)"
        foreach ($set in $customSets) {
            $conflicts += [pscustomobject]@{
                Kind     = 'CustomInitiativeDefinition'
                Name     = $set.Name
                Scope    = '(initiative)'
                Severity = 'Yellow'
                Detail   = 'Custom initiative — verify no name collision with ALZ library'
            }
        }
    }

    # Get existing policy assignments at subscription scope
    $assignments = Get-AzPolicyAssignment -Scope "/subscriptions/$SubscriptionId" -ErrorAction SilentlyContinue
    if ($assignments) {
        Write-Info "  Existing policy assignments at sub scope: $($assignments.Count)"
        foreach ($a in $assignments) {
            # STUB: check if this assignment's effect conflicts with an incoming ALZ assignment
            # covering the same resource types. For now, surface as Yellow.
            $conflicts += [pscustomobject]@{
                Kind     = 'ExistingPolicyAssignment'
                Name     = $a.Name
                Scope    = $a.Properties.scope
                Severity = 'Yellow'
                Detail   = 'Existing assignment — review interaction with incoming ALZ MG-level policies'
            }
        }
    }

    # Get existing custom role definitions
    $customRoles = Get-AzRoleDefinition -Custom -ErrorAction SilentlyContinue
    if ($customRoles) {
        Write-Info "  Custom role definitions visible: $($customRoles.Count)"
        foreach ($role in $customRoles) {
            # STUB: ALZ creates a 'Landing Zone Reader (WhatIf/Validate)' role.
            # Check for name collision with that and any other ALZ role defs.
            $conflicts += [pscustomobject]@{
                Kind     = 'CustomRoleDefinition'
                Name     = $role.Name
                Scope    = '(role)'
                Severity = 'Yellow'
                Detail   = 'Custom role definition — verify no name collision with ALZ roles'
            }
        }
    }

    return $conflicts
}

#==============================================================================
# Step 6: Classify subscription
#==============================================================================
function Get-Classification($Conflicts) {
    if ($Conflicts.Count -eq 0)                                       { return 'Green' }
    if ($Conflicts | Where-Object { $_.Severity -eq 'Red' })         { return 'Red' }
    return 'Yellow'
}

#==============================================================================
# Step 7: Print report
#==============================================================================
function Write-Report($Results) {
    Write-Step 'Brownfield Discovery Report'

    $green  = @($Results | Where-Object { $_.Classification -eq 'Green' })
    $yellow = @($Results | Where-Object { $_.Classification -eq 'Yellow' })
    $red    = @($Results | Where-Object { $_.Classification -eq 'Red' })

    Write-Host ''
    if ($NoColor) {
        Write-Host "  $($green.Count) GREEN   — safe to adopt"
        Write-Host "  $($yellow.Count) YELLOW  — review required before adoption"
        Write-Host "  $($red.Count) RED     — must resolve before adoption"
    } else {
        Write-Host "  `e[32m$($green.Count) green`e[0m   — safe to adopt"
        Write-Host "  `e[33m$($yellow.Count) yellow`e[0m  — review required before adoption"
        Write-Host "  `e[31m$($red.Count) red`e[0m     — must resolve before adoption"
    }
    Write-Host ''

    foreach ($r in $green) {
        Write-Green  "$($r.SubscriptionName) ($($r.SubscriptionId))"
        Write-Host   "           Current MG : $($r.CurrentMg)"
        Write-Host   "           Resources  : $($r.ResourceCount) total"
    }

    foreach ($r in $yellow) {
        Write-Yellow "$($r.SubscriptionName) ($($r.SubscriptionId))"
        Write-Host   "           Current MG : $($r.CurrentMg)"
        Write-Host   "           Resources  : $($r.ResourceCount) total"
        foreach ($c in $r.Conflicts) {
            Write-Host "           ! $($c.Count)x [$($c.ResourceType)] → '$($c.Policy)'"
        }
    }

    foreach ($r in $red) {
        Write-Red    "$($r.SubscriptionName) ($($r.SubscriptionId))"
        Write-Host   "           Current MG : $($r.CurrentMg)"
        Write-Host   "           Resources  : $($r.ResourceCount) total"
        foreach ($c in $r.Conflicts) {
            Write-Host "           x $($c.Count)x [$($c.ResourceType)] → '$($c.Policy)'"
        }
    }

    Write-Host ''
    Write-Host '  Next steps:'
    Write-Host '    Green  → run onboard.ps1, then assign to target MG in platform.json'
    Write-Host '    Yellow → review conflicts above, add policy exclusions or fix resources'
    Write-Host '    Red    → resolve hard conflicts before onboarding'
    Write-Host ''

    if ($Script:OutputPath -ne '') {
        $Results | ConvertTo-Json -Depth 5 | Set-Content $Script:OutputPath
        Write-Info "Full report written to $Script:OutputPath"
    }
}

#==============================================================================
# Main
#==============================================================================
$Script:TenantId   = $TenantId
$Script:OutputPath = $OutputPath

Write-Host ''
if ($NoColor) { Write-Host 'ALZ Brownfield Discovery' } else { Write-Host "`e[1mALZ Brownfield Discovery`e[0m" }
Write-Host '(read-only — no changes will be made)'
Write-Host ''

Resolve-Inputs

$subs    = Get-AllSubscriptions
$results = @()

foreach ($sub in $subs) {
    Write-Step "Scanning: $($sub.Name)"
    Write-Info "  ID         : $($sub.Id)"

    $currentMg  = Get-SubManagementGroup -SubscriptionId $sub.Id
    Write-Info "  Current MG : $currentMg"

    $resources  = Get-ResourceSummary -SubscriptionId $sub.Id
    $totalCount = ($resources | Measure-Object -Property Count -Sum).Sum
    Write-Info "  Resources  : $totalCount total across $($resources.Count) type(s)"

    $conflicts      = Get-PolicyConflicts -ResourceSummary $resources
    $policyConflicts = Get-PolicyDefinitionConflicts -SubscriptionId $sub.Id
    $allConflicts   = @($conflicts) + @($policyConflicts)
    $classification = Get-Classification -Conflicts $allConflicts

    switch ($classification) {
        'Green'  { Write-Green  "  → Green" }
        'Yellow' { Write-Yellow "  → Yellow ($($conflicts.Count) potential conflict(s))" }
        'Red'    { Write-Red    "  → Red ($( ($conflicts | Where-Object { $_.Severity -eq 'Red' }).Count) hard conflict(s))" }
    }

    $results += [pscustomobject]@{
        SubscriptionId   = $sub.Id
        SubscriptionName = $sub.Name
        CurrentMg        = $currentMg
        ResourceCount    = $totalCount
        ResourceTypes    = $resources
        Conflicts        = $allConflicts
        Classification   = $classification
    }
}

Write-Report -Results $results

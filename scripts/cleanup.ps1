#Requires -Version 7
<#
.SYNOPSIS
    ALZ Tenant Cleanup — tears down all resources created by a previous bootstrap
    and governance deployment so the tenant can be onboarded fresh.

.DESCRIPTION
    Cleanup order:
      1. Delete governance Deployment Stacks at the intermediate root MG (reverse dep order)
         Each stack was created with ActionOnUnmanage=DeleteAll, so its managed resources
         (policy assignments, role assignments, child management groups) are deleted with it.
      2. Explicitly delete any management groups still present under the intermediate root
         (bottom-up), and finally the intermediate root MG itself.
      3. Delete the identity resource group (contains plan + apply UAMIs and their
         federated identity credentials).
      4. Remove role assignments for the UAMIs at the tenant root management group.
      5. Remove the custom 'Landing Zone Reader' role definition.

    Every step is idempotent — resources that no longer exist are silently skipped.
    No resource is touched without explicit confirmation (or -DryRun to preview only).

.PARAMETER ConfigRepoPath
    Path to the alz-mgmt config repo. Used to read defaults from config/platform.json.
    Default: ../alz-mgmt

.PARAMETER IntRootMgId
    Intermediate root management group name (e.g. 'alz').
    Loaded from platform.json (INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID) if not supplied.

.PARAMETER TenantRootMgId
    Tenant root management group GUID.
    Loaded from platform.json (MANAGEMENT_GROUP_ID) if not supplied.

.PARAMETER BootstrapSubscriptionId
    Subscription where the identity resource group lives.
    Loaded from platform.json (SUBSCRIPTION_ID_MANAGEMENT) if not supplied.

.PARAMETER Location
    Azure region — used to derive default identity resource group / UAMI names.
    Loaded from platform.json (LOCATION) if not supplied.

.PARAMETER IdentityRgName
    Override for the identity resource group name.
    Default: rg-alz-mgmt-identity-<location>-1

.PARAMETER DryRun
    Print every action without making any changes.

.EXAMPLE
    # Preview — no changes
    ./scripts/cleanup.ps1 -DryRun

.EXAMPLE
    # Explicit values (skips config file loading)
    ./scripts/cleanup.ps1 `
        -IntRootMgId           'alz' `
        -TenantRootMgId        'yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy' `
        -BootstrapSubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -Location              'swedencentral'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigRepoPath           = '',
    [string] $IntRootMgId              = '',
    [string] $TenantRootMgId           = '',
    [string] $BootstrapSubscriptionId  = '',
    [string] $Location                 = '',
    [string] $IdentityRgName           = '',
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NoColor = -not $Host.UI.SupportsVirtualTerminal
function Write-Step ($msg) { if ($NoColor) { Write-Host "`n── $msg ──" }         else { Write-Host "`n`e[1m── $msg ──`e[0m" } }
function Write-Info ($msg) { if ($NoColor) { Write-Host "[INFO]  $msg" }          else { Write-Host "`e[36m[INFO]`e[0m  $msg" } }
function Write-Ok   ($msg) { if ($NoColor) { Write-Host "[OK]    $msg" }          else { Write-Host "`e[32m[OK]`e[0m    $msg" } }
function Write-Warn ($msg) { if ($NoColor) { Write-Host "[WARN]  $msg" }          else { Write-Host "`e[33m[WARN]`e[0m  $msg" } }
function Write-Skip ($msg) { if ($NoColor) { Write-Host "[SKIP]  $msg" }          else { Write-Host "`e[90m[SKIP]`e[0m  $msg" } }
function Write-Dry  ($msg) { if ($NoColor) { Write-Host "[DRY]   $msg" }          else { Write-Host "`e[33m[DRY]`e[0m   $msg" } }
function Write-Fail ($msg) { Write-Error "[ERROR] $msg" }

$TemplatesRoot = Split-Path $PSScriptRoot -Parent

# ─── Step 0: Resolve inputs from config/platform.json ────────────────────────
function Resolve-Inputs {
    Write-Step 'Resolving inputs'

    # Locate config repo
    $Script:ConfigRepoPath = $ConfigRepoPath
    if ($Script:ConfigRepoPath -eq '') {
        $candidate = Join-Path $TemplatesRoot '../alz-mgmt'
        if (Test-Path $candidate) {
            $Script:ConfigRepoPath = (Resolve-Path $candidate).Path
        }
    } elseif (Test-Path $Script:ConfigRepoPath) {
        $Script:ConfigRepoPath = (Resolve-Path $Script:ConfigRepoPath).Path
    }

    $platformJson = if ($Script:ConfigRepoPath) { Join-Path $Script:ConfigRepoPath 'config/platform.json' } else { $null }
    if ($platformJson -and (Test-Path $platformJson)) {
        Write-Info "Loading defaults from $platformJson"
        $p = Get-Content $platformJson | ConvertFrom-Json
        if ($IntRootMgId            -eq '') { $Script:IntRootMgId            = $p.INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID }
        if ($TenantRootMgId         -eq '') { $Script:TenantRootMgId         = $p.MANAGEMENT_GROUP_ID }
        if ($BootstrapSubscriptionId -eq '') { $Script:BootstrapSubscriptionId = $p.SUBSCRIPTION_ID_MANAGEMENT }
        if ($Location               -eq '') { $Script:Location               = $p.LOCATION }
    } else {
        $Script:IntRootMgId            = $IntRootMgId
        $Script:TenantRootMgId         = $TenantRootMgId
        $Script:BootstrapSubscriptionId = $BootstrapSubscriptionId
        $Script:Location               = $Location
    }

    # Interactive fallback
    function Prompt-If-Empty([ref]$Var, [string]$Label) {
        if ($Var.Value -ne '') { return }
        $Var.Value = Read-Host $Label
        if ($Var.Value -eq '') { Write-Fail "$Label is required."; exit 1 }
    }
    Prompt-If-Empty ([ref]$Script:IntRootMgId)            'Intermediate root MG name (e.g. alz)'
    Prompt-If-Empty ([ref]$Script:TenantRootMgId)         'Tenant root MG GUID'
    Prompt-If-Empty ([ref]$Script:BootstrapSubscriptionId) 'Bootstrap subscription ID'
    Prompt-If-Empty ([ref]$Script:Location)               'Azure region (e.g. swedencentral)'

    # Derive resource names (can be overridden)
    $Script:IdentityRgName = if ($IdentityRgName -ne '') {
        $IdentityRgName
    } else {
        "rg-alz-mgmt-identity-$Script:Location-1"
    }
    $Script:UamiPlanName  = "id-alz-mgmt-$Script:Location-plan-1"
    $Script:UamiApplyName = "id-alz-mgmt-$Script:Location-apply-1"

    Write-Ok "Intermediate root MG : $Script:IntRootMgId"
    Write-Ok "Tenant root MG GUID  : $Script:TenantRootMgId"
    Write-Ok "Bootstrap sub        : $Script:BootstrapSubscriptionId"
    Write-Ok "Identity RG          : $Script:IdentityRgName (in sub $Script:BootstrapSubscriptionId)"
}

# ─── Step 1: Confirm plan ─────────────────────────────────────────────────────
function Confirm-Plan {
    Write-Step 'Cleanup plan'
    Write-Host ''
    Write-Host "  Will delete (if present):"
    Write-Host "    Deployment stacks at MG '$Script:IntRootMgId' scope (governance stacks)"
    Write-Host "    Management groups under '$Script:IntRootMgId' + '$Script:IntRootMgId' itself"
    Write-Host "    Resource group '$Script:IdentityRgName' in sub '$Script:BootstrapSubscriptionId'"
    Write-Host "    Role assignments for plan/apply UAMIs at MG '$Script:TenantRootMgId'"
    Write-Host "    Custom role 'Landing Zone Reader (WhatIf/Validate)' at MG '$Script:TenantRootMgId'"
    Write-Host ''
    Write-Host "  This does NOT delete:"
    Write-Host "    The tenant root management group ('$Script:TenantRootMgId')"
    Write-Host "    Any Azure subscriptions"
    Write-Host "    GitHub environments or variables"
    Write-Host ''

    if ($DryRun) { Write-Warn 'DRY RUN — no changes will be made.'; return }

    $confirm = Read-Host 'Type YES to proceed'
    if ($confirm -ne 'YES') { Write-Info 'Aborted.'; exit 0 }
}

# ─── Shared helper: try-delete with skip on not-found ─────────────────────────
function Invoke-WithSkip([scriptblock]$Action, [string]$NotFoundMsg) {
    try {
        & $Action
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '(?i)not\s*found|ResourceNotFound|404|does not exist') {
            Write-Skip $NotFoundMsg
        } else {
            throw
        }
    }
}

# ─── Step 2: Delete governance Deployment Stacks ──────────────────────────────
function Remove-GovernanceStacks {
    Write-Step 'Deleting governance Deployment Stacks'

    # Stack names: {intRootMgId}-{step-name}, deleted in reverse dependency order
    $stackNames = @(
        # 1st pass: RBAC stacks (depend on everything else)
        "$Script:IntRootMgId-governance-platform-connectivity-rbac"
        "$Script:IntRootMgId-governance-landingzones-rbac"
        "$Script:IntRootMgId-governance-platform-rbac"
        # 2nd pass: leaf child MG stacks
        "$Script:IntRootMgId-governance-platform-connectivity"
        "$Script:IntRootMgId-governance-platform-identity"
        "$Script:IntRootMgId-governance-platform-management"
        "$Script:IntRootMgId-governance-platform-security"
        "$Script:IntRootMgId-governance-landingzones-corp"
        "$Script:IntRootMgId-governance-landingzones-online"
        # 3rd pass: intermediate child MG stacks
        "$Script:IntRootMgId-governance-platform"
        "$Script:IntRootMgId-governance-landingzones"
        "$Script:IntRootMgId-governance-sandbox"
        "$Script:IntRootMgId-governance-decommissioned"
        # Last: int-root (owns policy + role defs)
        "$Script:IntRootMgId-governance-int-root"
    )

    foreach ($stackName in $stackNames) {
        Write-Info "  Stack: $stackName"

        if ($DryRun) {
            Write-Dry "  Remove-AzManagementGroupDeploymentStack -ManagementGroupId '$Script:IntRootMgId' -Name '$stackName' -ActionOnUnmanage DeleteAll -Force"
            continue
        }

        Invoke-WithSkip {
            $existing = Get-AzManagementGroupDeploymentStack `
                -ManagementGroupId $Script:IntRootMgId `
                -Name $stackName `
                -ErrorAction SilentlyContinue
            if (-not $existing) { Write-Skip "  Stack '$stackName' not found — skipping."; return }

            Write-Info "  Deleting stack '$stackName' (ActionOnUnmanage=DeleteAll)..."
            Remove-AzManagementGroupDeploymentStack `
                -ManagementGroupId $Script:IntRootMgId `
                -Name $stackName `
                -ActionOnUnmanage DeleteAll `
                -Force | Out-Null
            Write-Ok "  Deleted: $stackName"
        } "Stack '$stackName' not found — skipped."
    }
}

# ─── Step 3: Explicitly delete management group hierarchy ─────────────────────
function Remove-ManagementGroupHierarchy {
    Write-Step 'Deleting management group hierarchy'

    # Bottom-up deletion order (children before parents)
    $mgOrder = @(
        # Leaf level
        'management', 'connectivity', 'identity', 'security'
        'corp', 'online'
        # Intermediate level
        'platform', 'landingzones'
        'sandbox', 'decommissioned'
        # Root of ALZ hierarchy — deleted last
        $Script:IntRootMgId
    )

    foreach ($mgName in $mgOrder) {
        Write-Info "  MG: $mgName"

        if ($DryRun) {
            Write-Dry "  Remove-AzManagementGroup -GroupName '$mgName'"
            continue
        }

        Invoke-WithSkip {
            $mg = Get-AzManagementGroup -GroupName $mgName -ErrorAction SilentlyContinue
            if (-not $mg) { Write-Skip "  MG '$mgName' not found — skipping."; return }

            Write-Info "  Deleting management group '$mgName'..."
            Remove-AzManagementGroup -GroupName $mgName -ErrorAction Stop | Out-Null
            Write-Ok "  Deleted MG: $mgName"
        } "MG '$mgName' not found — skipped."
    }
}

# ─── Step 4: Delete identity resource group ───────────────────────────────────
function Remove-IdentityResourceGroup {
    Write-Step 'Deleting identity resource group'
    Write-Info "  RG '$Script:IdentityRgName' in subscription '$Script:BootstrapSubscriptionId'"

    if ($DryRun) {
        Write-Dry "  Select-AzSubscription -SubscriptionId '$Script:BootstrapSubscriptionId'"
        Write-Dry "  Remove-AzResourceGroup -Name '$Script:IdentityRgName' -Force"
        return
    }

    # Before deleting, collect UAMI principal IDs for role assignment cleanup in the next step
    $Script:PlanPrincipalId  = $null
    $Script:ApplyPrincipalId = $null

    Select-AzSubscription -SubscriptionId $Script:BootstrapSubscriptionId | Out-Null

    $rg = Get-AzResourceGroup -Name $Script:IdentityRgName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Skip "Resource group '$Script:IdentityRgName' not found — skipping."
        return
    }

    # Capture principal IDs before we delete the RG
    $planUami = Get-AzUserAssignedIdentity `
        -ResourceGroupName $Script:IdentityRgName `
        -Name $Script:UamiPlanName `
        -ErrorAction SilentlyContinue
    $applyUami = Get-AzUserAssignedIdentity `
        -ResourceGroupName $Script:IdentityRgName `
        -Name $Script:UamiApplyName `
        -ErrorAction SilentlyContinue

    if ($planUami)  { $Script:PlanPrincipalId  = $planUami.PrincipalId;  Write-Info "  Plan UAMI principal  : $Script:PlanPrincipalId" }
    if ($applyUami) { $Script:ApplyPrincipalId = $applyUami.PrincipalId; Write-Info "  Apply UAMI principal : $Script:ApplyPrincipalId" }

    Write-Info "  Deleting resource group '$Script:IdentityRgName' (includes UAMIs and federated credentials)..."
    Remove-AzResourceGroup -Name $Script:IdentityRgName -Force | Out-Null
    Write-Ok "  Deleted: $Script:IdentityRgName"
}

# ─── Step 5: Remove UAMI role assignments at tenant root MG ───────────────────
function Remove-UamiRoleAssignments {
    Write-Step 'Removing UAMI role assignments at tenant root MG'

    $mgScope = "/providers/Microsoft.Management/managementGroups/$Script:TenantRootMgId"

    if ($DryRun) {
        Write-Dry "  Get-AzRoleAssignment -Scope '$mgScope' | where PrincipalId in (plan, apply)"
        Write-Dry "  Remove-AzRoleAssignment for each match"
        return
    }

    # Collect principal IDs to look for
    $principals = @()
    if ($Script:PlanPrincipalId)  { $principals += $Script:PlanPrincipalId }
    if ($Script:ApplyPrincipalId) { $principals += $Script:ApplyPrincipalId }

    if ($principals.Count -eq 0) {
        # RG was already gone — try to find orphaned/Unknown assignments at the MG scope
        Write-Warn "  UAMI principal IDs not captured (RG was already deleted)."
        Write-Warn "  Searching for Unknown principals at MG scope '$Script:TenantRootMgId'..."

        $allAssignments = Get-AzRoleAssignment -Scope $mgScope -ErrorAction SilentlyContinue
        $orphaned = $allAssignments | Where-Object { $_.ObjectType -eq 'Unknown' }

        if ($orphaned) {
            Write-Warn "  Found $($orphaned.Count) orphaned role assignment(s) — review manually:"
            $orphaned | ForEach-Object {
                Write-Host "    ObjectId=$($_.ObjectId)  Role=$($_.RoleDefinitionName)"
            }
            Write-Warn "  Run: Remove-AzRoleAssignment -ObjectId <id> -RoleDefinitionId <id> -Scope '$mgScope'"
        } else {
            Write-Skip "  No orphaned assignments found at MG scope."
        }
        return
    }

    foreach ($principalId in $principals) {
        $assignments = Get-AzRoleAssignment `
            -Scope $mgScope `
            -ObjectId $principalId `
            -ErrorAction SilentlyContinue
        if (-not $assignments) {
            Write-Skip "  No role assignments found for principal $principalId"
            continue
        }
        foreach ($ra in $assignments) {
            Write-Info "  Removing: $($ra.RoleDefinitionName) → $principalId"
            Remove-AzRoleAssignment `
                -ObjectId $principalId `
                -RoleDefinitionId $ra.RoleDefinitionId `
                -Scope $mgScope `
                -ErrorAction SilentlyContinue | Out-Null
            Write-Ok "  Removed role assignment: $($ra.RoleDefinitionName)"
        }
    }
}

# ─── Step 6: Remove custom role definition ────────────────────────────────────
function Remove-CustomRoleDefinition {
    Write-Step "Removing custom role definition 'Landing Zone Reader (WhatIf/Validate)'"

    $mgScope = "/providers/Microsoft.Management/managementGroups/$Script:TenantRootMgId"
    $roleName = 'Landing Zone Reader (WhatIf/Validate)'

    if ($DryRun) {
        Write-Dry "  Get-AzRoleDefinition -Name '$roleName' -Scope '$mgScope'"
        Write-Dry "  Remove-AzRoleDefinition ..."
        return
    }

    $role = Get-AzRoleDefinition -Name $roleName -Scope $mgScope -ErrorAction SilentlyContinue
    if (-not $role) {
        Write-Skip "Custom role '$roleName' not found — skipping."
        return
    }

    Write-Info "  Removing role definition: $roleName (ID: $($role.Id))"
    Remove-AzRoleDefinition -Id $role.Id -Force -ErrorAction SilentlyContinue | Out-Null
    Write-Ok "  Removed: $roleName"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
function Write-Summary {
    Write-Host ''
    Write-Host '══════════════════════════════════════════════════════════'
    Write-Host '  Cleanup complete!'
    Write-Host '══════════════════════════════════════════════════════════'
    Write-Host ''
    Write-Host '  The Azure tenant is now clean and ready for a fresh onboarding.'
    Write-Host ''
    Write-Host '  Next step:'
    Write-Host '    ./scripts/onboard.ps1 -ConfigRepoPath ../alz-mgmt ...'
    Write-Host ''
}

# ─── Main ────────────────────────────────────────────────────────────────────

$Script:ConfigRepoPath          = $ConfigRepoPath
$Script:IntRootMgId             = $IntRootMgId
$Script:TenantRootMgId          = $TenantRootMgId
$Script:BootstrapSubscriptionId = $BootstrapSubscriptionId
$Script:Location                = $Location
$Script:IdentityRgName          = $IdentityRgName
$Script:UamiPlanName            = ''
$Script:UamiApplyName           = ''
$Script:PlanPrincipalId         = $null
$Script:ApplyPrincipalId        = $null

Write-Host ''
if ($NoColor) { Write-Host 'ALZ Tenant Cleanup' } else { Write-Host "`e[1mALZ Tenant Cleanup`e[0m" }
if ($DryRun)  { Write-Warn '(dry run — no changes will be made)' }
Write-Host ''

Resolve-Inputs
Confirm-Plan

Remove-GovernanceStacks
Remove-ManagementGroupHierarchy
Remove-IdentityResourceGroup
Remove-UamiRoleAssignments
Remove-CustomRoleDefinition

if (-not $DryRun) { Write-Summary } else { Write-Host ''; Write-Warn 'Dry run complete — no changes were made.' }

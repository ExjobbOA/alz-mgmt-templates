<#
.SYNOPSIS
    Exports Azure Landing Zone Deployment Stack state for K5 change containment verification.

.DESCRIPTION
    Captures two layers of data for each Deployment Stack:
    1. Stack metadata  — ProvisioningState, DeploymentId, resource list
    2. Resource snapshot — actual property values for key resources (e.g. policy assignment parameters)

    Run BEFORE and AFTER a change, then diff the two JSON files.
    Only the affected stack should show differences.

.PARAMETER OutputFile
    Path for the JSON export file.

.PARAMETER SubscriptionId
    The connectivity/platform subscription ID.

.PARAMETER TenantIntRootMgId
    The intermediate root management group ID (tenant-specific GUID).

.EXAMPLE
    # Before change
    ./Export-ALZStackState.ps1 -OutputFile "state-before.json" -SubscriptionId "6f051987-..." -TenantIntRootMgId "3aadcd6c-..."

    # After change
    ./Export-ALZStackState.ps1 -OutputFile "state-after.json" -SubscriptionId "6f051987-..." -TenantIntRootMgId "3aadcd6c-..."

    # Diff (PowerShell)
    $before = Get-Content "state-before.json" | ConvertFrom-Json
    $after  = Get-Content "state-after.json"  | ConvertFrom-Json
    # Or use: git diff --no-index state-before.json state-after.json
#>

param(
    [Parameter(Mandatory)]
    [string]$OutputFile,

    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$TenantIntRootMgId
)

$ErrorActionPreference = "Stop"

# ============================================================
# 1. Define all stacks to export
# ============================================================

$mgStacks = @(
    @{ Scope = "mg"; MgId = $TenantIntRootMgId; Name = "$TenantIntRootMgId-governance-int-root" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-platform" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-landingzones" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-landingzones-corp" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-landingzones-online" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-sandbox" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-decommissioned" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-platform-rbac" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-landingzones-rbac" }
)

$subStacks = @(
    @{ Scope = "sub"; Name = "alz-core-logging" }
    @{ Scope = "sub"; Name = "alz-networking-hub" }
)

# ============================================================
# 2. Helper: Get key resource properties for a stack
# ============================================================

function Get-StackResourceSnapshot {
    param(
        [string]$StackName,
        [array]$ResourceIds
    )

    $snapshots = @()

    foreach ($rid in $ResourceIds) {
        $snapshot = @{
            ResourceId = $rid
        }

        # Policy assignments — capture parameter values (this is where email changes show up)
        if ($rid -match "Microsoft.Authorization/policyAssignments/") {
            try {
                $assignmentName = ($rid -split "/")[-1]
                $scope = $rid -replace "/providers/Microsoft.Authorization/policyAssignments/.*", ""

                $assignment = Get-AzPolicyAssignment -Name $assignmentName -Scope $scope -ErrorAction SilentlyContinue
                if ($assignment) {
                    $snapshot.Type = "policyAssignment"
                    $snapshot.DisplayName = $assignment.DisplayName
                    $snapshot.Parameters = $assignment.Parameter | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                    $snapshot.EnforcementMode = $assignment.EnforcementMode
                }
            }
            catch {
                $snapshot.Error = $_.Exception.Message
            }
        }

        # Policy definitions — capture the rule hash (not full rule, to keep diff clean)
        elseif ($rid -match "Microsoft.Authorization/policyDefinitions/") {
            try {
                $defName = ($rid -split "/")[-1]
                $scope = $rid -replace "/providers/Microsoft.Authorization/policyDefinitions/.*", ""

                $def = Get-AzPolicyDefinition -Name $defName -ManagementGroupName ($scope -split "/")[-1] -ErrorAction SilentlyContinue
                if ($def) {
                    $snapshot.Type = "policyDefinition"
                    $snapshot.DisplayName = $def.DisplayName
                    # Hash the policy rule to detect changes without bloating the export
                    $ruleJson = $def.PolicyRule | ConvertTo-Json -Depth 20 -Compress
                    $snapshot.PolicyRuleHash = [System.BitConverter]::ToString(
                        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                            [System.Text.Encoding]::UTF8.GetBytes($ruleJson)
                        )
                    ).Replace("-", "").Substring(0, 16)
                }
            }
            catch {
                $snapshot.Error = $_.Exception.Message
            }
        }

        # Policy set definitions (initiatives)
        elseif ($rid -match "Microsoft.Authorization/policySetDefinitions/") {
            try {
                $setName = ($rid -split "/")[-1]
                $scope = $rid -replace "/providers/Microsoft.Authorization/policySetDefinitions/.*", ""

                $setDef = Get-AzPolicySetDefinition -Name $setName -ManagementGroupName ($scope -split "/")[-1] -ErrorAction SilentlyContinue
                if ($setDef) {
                    $snapshot.Type = "policySetDefinition"
                    $snapshot.DisplayName = $setDef.DisplayName
                    $snapshot.PolicyDefinitionCount = ($setDef.PolicyDefinition | ConvertFrom-Json).Count
                }
            }
            catch {
                $snapshot.Error = $_.Exception.Message
            }
        }

        $snapshots += $snapshot
    }

    return $snapshots
}

# ============================================================
# 3. Export each stack
# ============================================================

Write-Host "Starting ALZ stack state export..." -ForegroundColor Cyan
Write-Host "Output: $OutputFile" -ForegroundColor Cyan

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

$export = @{
    ExportTimestamp   = (Get-Date -Format "o")
    SubscriptionId    = $SubscriptionId
    TenantIntRootMgId = $TenantIntRootMgId
    Stacks            = @()
}

# Management group stacks
foreach ($s in $mgStacks) {
    Write-Host "  Exporting MG stack: $($s.Name)..." -ForegroundColor Yellow
    try {
        $stack = Get-AzManagementGroupDeploymentStack -ManagementGroupId $s.MgId -Name $s.Name

        $resourceIds = @()
        if ($stack.Resources) {
            $resourceIds = $stack.Resources | ForEach-Object {
                if ($_ -is [string]) { $_ } else { $_.Id }
            }
        }

        $stackExport = @{
            Name              = $stack.Name
            Scope             = "managementGroup"
            ManagementGroupId = $s.MgId
            ProvisioningState = $stack.ProvisioningState
            DeploymentId      = $stack.DeploymentId
            ResourceCount     = $resourceIds.Count
            ResourceIds       = $resourceIds | Sort-Object
            DeletedResources  = @($stack.DeletedResources | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Id } })
            DetachedResources = @($stack.DetachedResources | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Id } })
            ResourceSnapshots = @(Get-StackResourceSnapshot -StackName $s.Name -ResourceIds $resourceIds)
        }

        $export.Stacks += $stackExport
        Write-Host "    OK — $($resourceIds.Count) resources" -ForegroundColor Green
    }
    catch {
        Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $export.Stacks += @{
            Name  = $s.Name
            Scope = "managementGroup"
            Error = $_.Exception.Message
        }
    }
}

# Subscription stacks
foreach ($s in $subStacks) {
    Write-Host "  Exporting Sub stack: $($s.Name)..." -ForegroundColor Yellow
    try {
        $stack = Get-AzSubscriptionDeploymentStack -Name $s.Name

        $resourceIds = @()
        if ($stack.Resources) {
            $resourceIds = $stack.Resources | ForEach-Object {
                if ($_ -is [string]) { $_ } else { $_.Id }
            }
        }

        $stackExport = @{
            Name              = $stack.Name
            Scope             = "subscription"
            ProvisioningState = $stack.ProvisioningState
            DeploymentId      = $stack.DeploymentId
            ResourceCount     = $resourceIds.Count
            ResourceIds       = $resourceIds | Sort-Object
            DeletedResources  = @($stack.DeletedResources | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Id } })
            DetachedResources = @($stack.DetachedResources | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Id } })
            ResourceSnapshots = @(Get-StackResourceSnapshot -StackName $s.Name -ResourceIds $resourceIds)
        }

        $export.Stacks += $stackExport
        Write-Host "    OK — $($resourceIds.Count) resources" -ForegroundColor Green
    }
    catch {
        Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $export.Stacks += @{
            Name  = $s.Name
            Scope = "subscription"
            Error = $_.Exception.Message
        }
    }
}

# ============================================================
# 4. Write output
# ============================================================

$export | ConvertTo-Json -Depth 30 | Out-File -FilePath $OutputFile -Encoding utf8
Write-Host "`nExport complete: $OutputFile" -ForegroundColor Cyan
Write-Host "Stacks exported: $($export.Stacks.Count)" -ForegroundColor Cyan

#Requires -Version 7
<#
.SYNOPSIS
    Exports portal-deployed Azure Landing Zone governance and infrastructure state as JSON.

.DESCRIPTION
    Scans a portal-deployed Azure Landing Zone tenant and exports its governance and
    infrastructure state as JSON. The output is structurally compatible with
    Export-ALZStackState.ps1 so you can diff brownfield state against engine-deployed
    state using Compare-ALZStackState.ps1.

    Key difference from Export-ALZStackState.ps1: this script queries resources directly
    because a portal-deployed ALZ has no Deployment Stacks.

    Read-only. No changes are made to the tenant.

.PARAMETER OutputFile
    Path for the JSON export file.

.PARAMETER RootManagementGroupId
    The intermediate root management group ID (e.g. 'alz').
    Auto-detected from the tenant if omitted.

.PARAMETER TenantId
    Azure tenant ID. Auto-detected from az account show if omitted.

.PARAMETER PlatformSubscriptionIds
    Subscription IDs to scan for infrastructure resources (logging, networking, etc.).
    If omitted, the script attempts to locate subscriptions under the platform MGs
    (management, connectivity, identity, security, or platform).

.EXAMPLE
    ./Export-BrownfieldState.ps1 -OutputFile "brownfield-state.json"

.EXAMPLE
    ./Export-BrownfieldState.ps1 `
        -OutputFile "brownfield-state.json" `
        -RootManagementGroupId "alz" `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -PlatformSubscriptionIds @("sub-id-1", "sub-id-2")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputFile,

    [string]$RootManagementGroupId = '',

    [string]$TenantId = '',

    [string[]]$PlatformSubscriptionIds = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NoColor = -not $Host.UI.SupportsVirtualTerminal
function Write-Step  ($msg) { if ($NoColor) { Write-Host "`n── $msg ──" }          else { Write-Host "`n`e[1m── $msg ──`e[0m" } }
function Write-Info  ($msg) { if ($NoColor) { Write-Host "[INFO]  $msg" }           else { Write-Host "`e[36m[INFO]`e[0m  $msg" } }
function Write-Ok    ($msg) { if ($NoColor) { Write-Host "[OK]    $msg" }           else { Write-Host "`e[32m[OK]`e[0m    $msg" } }
function Write-Warn  ($msg) { if ($NoColor) { Write-Host "[WARN]  $msg" }           else { Write-Host "`e[33m[WARN]`e[0m  $msg" } }
function Write-Fail  ($msg) { if ($NoColor) { Write-Host "[SKIP]  $msg" }           else { Write-Host "`e[31m[SKIP]`e[0m  $msg" } }

# Well-known ALZ intermediate root child MG names used for auto-detection
$AlzWellKnownChildMgs = @('platform', 'landingzones', 'sandbox', 'decommissioned')

# Platform MG names used when discovering platform subscriptions
$AlzPlatformMgs = @('management', 'connectivity', 'identity', 'security')
$AlzPlatformFallbackMg = 'platform'

# ============================================================
# Helper: compute SHA256 hash (first 16 hex chars)
# ============================================================
function Get-SHA256Short ([string]$InputString) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return [System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 16)
}

# ============================================================
# Helper: safely get a property value from a PSObject without
# throwing in strict mode if the property doesn't exist.
# Tries each name in order and returns the first non-null value.
# ============================================================
function Get-PropSafe ($Obj, [string[]]$Names) {
    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    }
    return $null
}

# ============================================================
# Helper: normalize an MG name for well-known name comparisons
#   - strips ALZ- prefix (case-insensitive)
#   - lowercases
#   - normalises plural variants (sandboxes -> sandbox)
# ============================================================
function Get-NormalizedMgName ([string]$Name) {
    # Strip ALZ- prefix case-insensitively, then lowercase
    $n = $Name -replace '(?i)^alz-', ''
    $n = $n.ToLower()
    # Normalise plural variants
    if ($n -eq 'sandboxes') { $n = 'sandbox' }
    return $n
}

# ============================================================
# Step 1: Resolve TenantId
# ============================================================
function Resolve-TenantId {
    Write-Step 'Resolving tenant identity'

    if ($Script:TenantId -eq '') {
        $account = az account show 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($account) {
            $Script:TenantId = $account.tenantId
            Write-Info "Tenant ID auto-detected: $Script:TenantId"
        }
    }

    if ($Script:TenantId -eq '') {
        Write-Error 'Could not determine TenantId. Pass -TenantId explicitly or log in with az login.'
    }

    Write-Info "Tenant: $Script:TenantId"
}

# ============================================================
# Step 2: Discover the ALZ intermediate root MG
# ============================================================
function Resolve-RootManagementGroup {
    Write-Step 'Resolving ALZ intermediate root management group'

    if ($Script:RootManagementGroupId -ne '') {
        Write-Info "Using provided root MG: $Script:RootManagementGroupId"
        return
    }

    Write-Info 'Scanning tenant root for ALZ intermediate root...'

    # Get all top-level MGs under the tenant root
    $tenantRootMgs = Get-AzManagementGroup -ErrorAction SilentlyContinue
    if (-not $tenantRootMgs) {
        Write-Error 'Could not retrieve management groups. Ensure you have Reader access at the tenant root.'
    }

    foreach ($mg in $tenantRootMgs) {
        # Expand one level to check for the well-known ALZ child MGs
        $expanded = Get-AzManagementGroup -GroupId $mg.Name -Expand -ErrorAction SilentlyContinue
        if (-not $expanded) { continue }

        $childNames        = @($expanded.Children | ForEach-Object { $_.Name })
        $normalizedChildren = $childNames | ForEach-Object { Get-NormalizedMgName $_ }
        $matches            = $normalizedChildren | Where-Object { $AlzWellKnownChildMgs -contains $_ }

        if ($matches.Count -ge 2) {
            $Script:RootManagementGroupId = $mg.Name
            Write-Info "ALZ intermediate root detected: $Script:RootManagementGroupId (children: $($childNames -join ', '))"
            return
        }
    }

    Write-Warn 'Could not auto-detect ALZ intermediate root. Pass -RootManagementGroupId explicitly.'
    Write-Warn 'Continuing without a root MG — governance scopes will be empty.'
}

# ============================================================
# Step 3: Build MG hierarchy recursively
# ============================================================
function Get-MgHierarchy ([string]$GroupId) {
    $mg = Get-AzManagementGroup -GroupId $GroupId -Expand -Recurse -ErrorAction SilentlyContinue
    if (-not $mg) {
        Write-Warn "  Could not expand MG '$GroupId' — skipping."
        return $null
    }

    function ConvertTo-Node ($mgObj) {
        # Root object has Details.Parent.Id; child objects (PSAzureManagementGroupChildInfo) do not
        $parentId = ''
        if ($mgObj.PSObject.Properties['Details'] -and $mgObj.Details.Parent) {
            $parentId = $mgObj.Details.Parent.Id
        } elseif ($mgObj.PSObject.Properties['ParentId']) {
            $parentId = $mgObj.ParentId
        }
        $node = @{
            Name        = $mgObj.Name
            DisplayName = $mgObj.DisplayName
            ParentId    = $parentId
            Children    = @()
        }
        if ($mgObj.Children) {
            foreach ($child in $mgObj.Children) {
                $node.Children += ConvertTo-Node $child
            }
        }
        return $node
    }

    return ConvertTo-Node $mg
}

# ============================================================
# Step 4: Collect all MG IDs from the hierarchy (flat list)
# ============================================================
function Get-AllMgIds ([hashtable]$HierarchyNode) {
    $ids = @($HierarchyNode.Name)
    foreach ($child in $HierarchyNode.Children) {
        $ids += Get-AllMgIds -HierarchyNode $child
    }
    return $ids
}

# ============================================================
# Step 5: Discover platform subscriptions
# ============================================================
function Resolve-PlatformSubscriptions {
    Write-Step 'Resolving platform subscriptions'

    if ($Script:PlatformSubscriptionIds.Count -gt 0) {
        Write-Info "Using $($Script:PlatformSubscriptionIds.Count) provided platform subscription(s)."
        return
    }

    Write-Info 'Attempting to locate platform subscriptions from MG hierarchy...'

    $found = @()

    # Build a map of normalized MG name -> actual MG ID from the hierarchy so that
    # REST calls use the real MG ID even when it carries a prefix like ALZ-.
    $normalizedToActual = @{}
    if ($Script:ActualMgIds) {
        foreach ($actualId in $Script:ActualMgIds) {
            $normalizedToActual[(Get-NormalizedMgName $actualId)] = $actualId
        }
    }

    # Try dedicated platform MGs first
    foreach ($mgName in $AlzPlatformMgs) {
        # Resolve the actual MG ID (may have ALZ- prefix in the tenant)
        $actualMgId = if ($normalizedToActual.ContainsKey($mgName)) {
            $normalizedToActual[$mgName]
        } else {
            $mgName
        }

        $response = Invoke-AzRestMethod `
            -Path "/providers/Microsoft.Management/managementGroups/$actualMgId/subscriptions?api-version=2020-05-01" `
            -Method GET `
            -ErrorAction SilentlyContinue

        if ($response -and $response.StatusCode -eq 200) {
            $subs = ($response.Content | ConvertFrom-Json).value
            foreach ($sub in $subs) {
                if ($sub.name -notin $found) {
                    $found += $sub.name
                    Write-Info "  Found subscription $($sub.name) under MG '$actualMgId'"
                }
            }
        }
    }

    # Fall back to generic platform MG
    if ($found.Count -eq 0) {
        $actualFallbackId = if ($normalizedToActual.ContainsKey($AlzPlatformFallbackMg)) {
            $normalizedToActual[$AlzPlatformFallbackMg]
        } else {
            $AlzPlatformFallbackMg
        }

        $response = Invoke-AzRestMethod `
            -Path "/providers/Microsoft.Management/managementGroups/$actualFallbackId/subscriptions?api-version=2020-05-01" `
            -Method GET `
            -ErrorAction SilentlyContinue

        if ($response -and $response.StatusCode -eq 200) {
            $subs = ($response.Content | ConvertFrom-Json).value
            foreach ($sub in $subs) {
                if ($sub.name -notin $found) {
                    $found += $sub.name
                    Write-Info "  Found subscription $($sub.name) under MG '$actualFallbackId' (fallback)"
                }
            }
        }
    }

    if ($found.Count -eq 0) {
        $Script:Warnings += 'Could not locate any platform subscriptions. Infrastructure discovery skipped. Pass -PlatformSubscriptionIds explicitly.'
        Write-Warn 'No platform subscriptions found — infrastructure scopes will be skipped.'
    }

    $Script:PlatformSubscriptionIds = $found
}

# ============================================================
# Step 6: Discover governance resources for a management group
# ============================================================
function Get-GovernanceScope ([string]$MgId, [string]$ScopeName) {
    Write-Info "  Scanning governance scope: $ScopeName (MG: $MgId)"

    $scope     = "/providers/Microsoft.Management/managementGroups/$MgId"
    $resources = @{
        PolicyDefinitions    = @()
        PolicySetDefinitions = @()
        PolicyAssignments    = @()
        RoleDefinitions      = @()
        RoleAssignments      = @()
    }

    # --- Custom policy definitions ---
    # Wrap in @() so single results are always arrays (avoids .Count issues in strict mode)
    $defs = @(Get-AzPolicyDefinition -ManagementGroupName $MgId -Custom -ErrorAction SilentlyContinue)
    foreach ($def in $defs) {
        # ResourceId may be called PolicyDefinitionId in newer Az.Resources versions
        $rid = Get-PropSafe $def 'ResourceId', 'PolicyDefinitionId', 'Id'
        if (-not $rid) { continue }
        if ($rid -inotmatch "managementGroups/$MgId/") { continue }

        try {
            $ruleJson = (Get-PropSafe $def 'PolicyRule', 'Properties') | ConvertTo-Json -Depth 20 -Compress
            $hash     = Get-SHA256Short $ruleJson
        }
        catch {
            $hash = '(hash-error)'
        }

        $resources.PolicyDefinitions += @{
            ResourceId     = $rid
            Type           = 'policyDefinition'
            Name           = $def.Name
            DisplayName    = (Get-PropSafe $def 'DisplayName')
            PolicyRuleHash = $hash
            Metadata       = (Get-PropSafe $def 'Metadata')
            Scope          = $scope
        }
    }
    if ($defs.Count -gt 0) { Write-Info "    PolicyDefinitions: $($resources.PolicyDefinitions.Count)" }

    # --- Custom policy set definitions (initiatives) ---
    $sets = @(Get-AzPolicySetDefinition -ManagementGroupName $MgId -Custom -ErrorAction SilentlyContinue)
    foreach ($set in $sets) {
        $rid = Get-PropSafe $set 'ResourceId', 'PolicySetDefinitionId', 'Id'
        if (-not $rid) { continue }
        if ($rid -inotmatch "managementGroups/$MgId/") { continue }

        try {
            $polDefs   = Get-PropSafe $set 'PolicyDefinition', 'PolicyDefinitions'
            $defCount  = if ($polDefs -is [string]) { ($polDefs | ConvertFrom-Json).Count }
                         elseif ($polDefs) { @($polDefs).Count }
                         else { 0 }
        }
        catch {
            $defCount = 0
        }

        $resources.PolicySetDefinitions += @{
            ResourceId            = $rid
            Type                  = 'policySetDefinition'
            Name                  = $set.Name
            DisplayName           = (Get-PropSafe $set 'DisplayName')
            PolicyDefinitionCount = $defCount
            Scope                 = $scope
        }
    }
    if ($sets.Count -gt 0) { Write-Info "    PolicySetDefinitions: $($resources.PolicySetDefinitions.Count)" }

    # --- Policy assignments ---
    $assignments = @(Get-AzPolicyAssignment -Scope $scope -ErrorAction SilentlyContinue)
    foreach ($a in $assignments) {
        # Only include assignments scoped directly to this MG (not child scopes)
        $aScope = Get-PropSafe $a 'Scope'
        if (-not $aScope) {
            $props = Get-PropSafe $a 'Properties'
            if ($props) { $aScope = $props.scope }
        }
        if ($aScope -and ($aScope -ine $scope)) { continue }

        $params = $null
        try {
            $rawParams = Get-PropSafe $a 'Parameter', 'Parameters'
            $params = if ($rawParams -is [string]) { $rawParams | ConvertFrom-Json }
                      else { $rawParams | ConvertTo-Json -Depth 10 | ConvertFrom-Json }
        }
        catch { }

        $identity = $null
        $aIdentity = Get-PropSafe $a 'Identity'
        if ($aIdentity) {
            $identity = @{
                Type        = (Get-PropSafe $aIdentity 'Type')
                PrincipalId = (Get-PropSafe $aIdentity 'PrincipalId')
            }
        }

        $rid = Get-PropSafe $a 'ResourceId', 'PolicyAssignmentId', 'Id'
        $resources.PolicyAssignments += @{
            ResourceId         = $rid
            Type               = 'policyAssignment'
            DisplayName        = (Get-PropSafe $a 'DisplayName')
            PolicyDefinitionId = (Get-PropSafe $a 'PolicyDefinitionId')
            Parameters         = $params
            EnforcementMode    = (Get-PropSafe $a 'EnforcementMode')
            Identity           = $identity
            Scope              = $scope
        }
    }
    if ($assignments.Count -gt 0) { Write-Info "    PolicyAssignments: $($resources.PolicyAssignments.Count)" }

    # --- Custom role definitions ---
    $roles = Get-AzRoleDefinition -Custom -ErrorAction SilentlyContinue |
        Where-Object { $_.AssignableScopes -contains $scope }
    if ($roles) {
        foreach ($role in $roles) {
            $resources.RoleDefinitions += @{
                ResourceId       = $role.Id
                Type             = 'roleDefinition'
                Name             = $role.Id
                RoleName         = $role.Name
                Permissions      = $role.Actions
                AssignableScopes = @($role.AssignableScopes)
            }
        }
        Write-Info "    RoleDefinitions: $($resources.RoleDefinitions.Count)"
    }

    # --- Role assignments ---
    $roleAssignments = Get-AzRoleAssignment -Scope $scope -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -ieq $scope }
    if ($roleAssignments) {
        foreach ($ra in $roleAssignments) {
            $resources.RoleAssignments += @{
                ResourceId          = $ra.RoleAssignmentId
                Type                = 'roleAssignment'
                RoleDefinitionId    = $ra.RoleDefinitionId
                PrincipalId         = $ra.ObjectId
                PrincipalType       = $ra.ObjectType
                Scope               = $scope
            }
        }
        Write-Info "    RoleAssignments: $($resources.RoleAssignments.Count)"
    }

    $total = $resources.PolicyDefinitions.Count +
             $resources.PolicySetDefinitions.Count +
             $resources.PolicyAssignments.Count +
             $resources.RoleDefinitions.Count +
             $resources.RoleAssignments.Count

    return @{
        Name               = $ScopeName
        Scope              = 'managementGroup'
        ManagementGroupId  = $MgId
        ResourceCount      = $total
        Resources          = $resources
    }
}

# ============================================================
# Step 7: Discover infrastructure resources for a subscription
# ============================================================
function Get-InfrastructureScope ([string]$SubscriptionId, [string]$ScopeName) {
    Write-Info "  Scanning infrastructure scope: $ScopeName (sub: $SubscriptionId)"

    $resources = @{
        ResourceGroups = @()
        KeyResources   = @()
    }

    $ctx = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
    if (-not $ctx) {
        $msg = "Could not set context for subscription $SubscriptionId — skipping infrastructure scope."
        $Script:Warnings += $msg
        Write-Warn $msg
        return $null
    }

    # --- Resource groups ---
    $rgs = @(Get-AzResourceGroup -ErrorAction SilentlyContinue)
    if ($rgs) {
        foreach ($rg in $rgs) {
            $resources.ResourceGroups += @{
                Name     = $rg.ResourceGroupName
                Location = $rg.Location
                Tags     = $rg.Tags
            }
        }
        Write-Info "    ResourceGroups: $($resources.ResourceGroups.Count)"
    }

    # --- Log Analytics workspaces ---
    $laws = @(Get-AzResource -ResourceType 'Microsoft.OperationalInsights/workspaces' -ErrorAction SilentlyContinue)
    if ($laws) {
        foreach ($law in $laws) {
            $detail = Get-AzOperationalInsightsWorkspace `
                -ResourceGroupName $law.ResourceGroupName `
                -Name $law.Name `
                -ErrorAction SilentlyContinue
            $resources.KeyResources += @{
                ResourceId    = $law.ResourceId
                Type          = 'logAnalyticsWorkspace'
                Name          = $law.Name
                Location      = $law.Location
                ResourceGroup = $law.ResourceGroupName
                Sku           = if ($detail) { $detail.Sku } else { $null }
                RetentionDays = if ($detail) { $detail.RetentionInDays } else { $null }
                Tags          = $law.Tags
            }
        }
        Write-Info "    Log Analytics workspaces: $($laws.Count)"
    }

    # --- Automation accounts ---
    $aas = @(Get-AzResource -ResourceType 'Microsoft.Automation/automationAccounts' -ErrorAction SilentlyContinue)
    if ($aas) {
        foreach ($aa in $aas) {
            $resources.KeyResources += @{
                ResourceId    = $aa.ResourceId
                Type          = 'automationAccount'
                Name          = $aa.Name
                Location      = $aa.Location
                ResourceGroup = $aa.ResourceGroupName
                Tags          = $aa.Tags
            }
        }
        Write-Info "    Automation accounts: $($aas.Count)"
    }

    # --- Hub VNets (VNets with GatewaySubnet or AzureFirewallSubnet indicate a hub) ---
    $vnets = @(Get-AzVirtualNetwork -ErrorAction SilentlyContinue)
    if ($vnets) {
        foreach ($vnet in $vnets) {
            $subnetNames = @($vnet.Subnets | ForEach-Object { $_.Name })
            $isHub       = ($subnetNames -contains 'GatewaySubnet') -or
                           ($subnetNames -contains 'AzureFirewallSubnet') -or
                           ($subnetNames -contains 'AzureFirewallManagementSubnet')

            $peerings = @($vnet.VirtualNetworkPeerings | ForEach-Object {
                @{
                    Name                          = $_.Name
                    RemoteVirtualNetworkId        = $_.RemoteVirtualNetwork.Id
                    PeeringState                  = $_.PeeringState
                    AllowGatewayTransit           = $_.AllowGatewayTransit
                    UseRemoteGateways             = $_.UseRemoteGateways
                    AllowForwardedTraffic         = $_.AllowForwardedTraffic
                }
            })

            $subnets = @($vnet.Subnets | ForEach-Object {
                @{
                    Name          = $_.Name
                    AddressPrefix = $_.AddressPrefix
                    NsgId         = if ($_.NetworkSecurityGroup) { $_.NetworkSecurityGroup.Id } else { $null }
                    RouteTableId  = if ($_.RouteTable) { $_.RouteTable.Id } else { $null }
                }
            })

            $resources.KeyResources += @{
                ResourceId     = $vnet.Id
                Type           = if ($isHub) { 'hubVirtualNetwork' } else { 'virtualNetwork' }
                Name           = $vnet.Name
                Location       = $vnet.Location
                ResourceGroup  = $vnet.ResourceGroupName
                AddressSpace   = @($vnet.AddressSpace.AddressPrefixes)
                Subnets        = $subnets
                Peerings       = $peerings
                Tags           = $vnet.Tag
            }
        }
        Write-Info "    Virtual networks: $($vnets.Count)"
    }

    # --- Azure Firewalls ---
    $firewalls = @(Get-AzFirewall -ErrorAction SilentlyContinue)
    if ($firewalls) {
        foreach ($fw in $firewalls) {
            $resources.KeyResources += @{
                ResourceId    = $fw.Id
                Type          = 'azureFirewall'
                Name          = $fw.Name
                Location      = $fw.Location
                ResourceGroup = $fw.ResourceGroupName
                Sku           = $fw.Sku
                ThreatIntelMode = $fw.ThreatIntelMode
                Tags          = $fw.Tag
            }
        }
        Write-Info "    Azure Firewalls: $($firewalls.Count)"
    }

    # --- Public IPs ---
    $pips = @(Get-AzPublicIpAddress -ErrorAction SilentlyContinue)
    if ($pips) {
        foreach ($pip in $pips) {
            $resources.KeyResources += @{
                ResourceId        = $pip.Id
                Type              = 'publicIpAddress'
                Name              = $pip.Name
                Location          = $pip.Location
                ResourceGroup     = $pip.ResourceGroupName
                AllocationMethod  = $pip.PublicIpAllocationMethod
                Sku               = $pip.Sku.Name
                Tags              = $pip.Tag
            }
        }
        Write-Info "    Public IPs: $($pips.Count)"
    }

    # --- NSGs ---
    $nsgs = @(Get-AzNetworkSecurityGroup -ErrorAction SilentlyContinue)
    if ($nsgs) {
        foreach ($nsg in $nsgs) {
            $resources.KeyResources += @{
                ResourceId    = $nsg.Id
                Type          = 'networkSecurityGroup'
                Name          = $nsg.Name
                Location      = $nsg.Location
                ResourceGroup = $nsg.ResourceGroupName
                RuleCount     = $nsg.SecurityRules.Count
                Tags          = $nsg.Tag
            }
        }
        Write-Info "    NSGs: $($nsgs.Count)"
    }

    # --- Route tables ---
    $rts = @(Get-AzRouteTable -ErrorAction SilentlyContinue)
    if ($rts) {
        foreach ($rt in $rts) {
            $resources.KeyResources += @{
                ResourceId            = $rt.Id
                Type                  = 'routeTable'
                Name                  = $rt.Name
                Location              = $rt.Location
                ResourceGroup         = $rt.ResourceGroupName
                RouteCount            = $rt.Routes.Count
                DisableBgpRoutePropagation = $rt.DisableBgpRoutePropagation
                Tags                  = $rt.Tag
            }
        }
        Write-Info "    Route tables: $($rts.Count)"
    }

    # --- Private DNS zones ---
    $dnsZones = @(Get-AzPrivateDnsZone -ErrorAction SilentlyContinue)
    if ($dnsZones) {
        foreach ($zone in $dnsZones) {
            $resources.KeyResources += @{
                ResourceId    = $zone.ResourceId
                Type          = 'privateDnsZone'
                Name          = $zone.Name
                ResourceGroup = $zone.ResourceGroupName
                Tags          = $zone.Tags
            }
        }
        Write-Info "    Private DNS zones: $($dnsZones.Count)"
    }

    $total = $resources.ResourceGroups.Count + $resources.KeyResources.Count

    return @{
        Name           = $ScopeName
        Scope          = 'subscription'
        SubscriptionId = $SubscriptionId
        ResourceCount  = $total
        Resources      = $resources
    }
}

# ============================================================
# Step 8: Map MG hierarchy to named governance scopes
#
# Mirrors the scope names used in Export-ALZStackState.ps1 so
# Compare-ALZStackState.ps1 can match them by Name.
# ============================================================
function Get-GovernanceScopesFromHierarchy ([hashtable]$Root) {
    $scopes = @()

    # Determine all MG IDs in the tree
    $allMgIds = Get-AllMgIds -HierarchyNode $Root

    # int-root scope = the root itself
    $intRootScope = Get-GovernanceScope -MgId $Root.Name -ScopeName 'governance-int-root'
    if ($intRootScope) { $scopes += $intRootScope }

    # Named child MG scopes
    $namedScopes = @{
        'platform'              = 'governance-platform'
        'connectivity'          = 'governance-platform-connectivity'
        'identity'              = 'governance-platform-identity'
        'management'            = 'governance-platform-management'
        'security'              = 'governance-platform-security'
        'landingzones'          = 'governance-landingzones'
        'corp'                  = 'governance-landingzones-corp'
        'online'                = 'governance-landingzones-online'
        'sandbox'               = 'governance-sandbox'
        'decommissioned'        = 'governance-decommissioned'
    }

    foreach ($mgId in ($allMgIds | Where-Object { $_ -ne $Root.Name })) {
        $normalizedMgId = Get-NormalizedMgName $mgId
        $scopeName = if ($namedScopes.ContainsKey($normalizedMgId)) {
            $namedScopes[$normalizedMgId]
        }
        else {
            "governance-mg-$mgId"
        }

        $scopeData = Get-GovernanceScope -MgId $mgId -ScopeName $scopeName
        if ($scopeData) { $scopes += $scopeData }
    }

    return $scopes
}

# ============================================================
# Main
# ============================================================

Write-Host ''
if ($NoColor) { Write-Host 'Export-BrownfieldState' } else { Write-Host "`e[1mExport-BrownfieldState`e[0m" }
Write-Host '(read-only — no changes will be made)'
Write-Host ''

# Script-level state
$Script:TenantId                 = $TenantId
$Script:RootManagementGroupId    = $RootManagementGroupId
$Script:PlatformSubscriptionIds  = $PlatformSubscriptionIds
$Script:Warnings                 = @()
$Script:ActualMgIds              = @()   # populated after hierarchy build; used for normalized MG lookups

Resolve-TenantId
Resolve-RootManagementGroup

# ============================================================
# Build MG hierarchy
# ============================================================
$mgHierarchy = $null

if ($Script:RootManagementGroupId -ne '') {
    Write-Step 'Building management group hierarchy'
    $mgHierarchy = Get-MgHierarchy -GroupId $Script:RootManagementGroupId

    if ($mgHierarchy) {
        $allIds = Get-AllMgIds -HierarchyNode $mgHierarchy
        $Script:ActualMgIds = $allIds
        Write-Ok "MG hierarchy built — $($allIds.Count) management group(s)"
    }
    else {
        $msg = "Could not expand MG hierarchy from root '$Script:RootManagementGroupId'."
        $Script:Warnings += $msg
        Write-Warn $msg
    }
}

# ============================================================
# Governance scopes
# ============================================================
$governanceScopes = @()

if ($mgHierarchy) {
    Write-Step 'Discovering governance resources'
    try {
        $governanceScopes = Get-GovernanceScopesFromHierarchy -Root $mgHierarchy
        Write-Ok "Governance scopes collected: $($governanceScopes.Count)"
    }
    catch {
        $msg = "Governance discovery failed: $($_.Exception.Message)"
        $Script:Warnings += $msg
        Write-Warn $msg
    }
}
else {
    Write-Warn 'Skipping governance discovery — no MG hierarchy available.'
}

# ============================================================
# Resolve platform subscriptions, then scan infrastructure
# ============================================================
Resolve-PlatformSubscriptions

$infrastructureScopes = @()

if ($Script:PlatformSubscriptionIds.Count -gt 0) {
    Write-Step 'Discovering infrastructure resources'

    # Build normalized->actual map for scope-name resolution
    $normalizedToActualInfra = @{}
    if ($Script:ActualMgIds) {
        foreach ($actualId in $Script:ActualMgIds) {
            $normalizedToActualInfra[(Get-NormalizedMgName $actualId)] = $actualId
        }
    }

    foreach ($subId in $Script:PlatformSubscriptionIds) {
        # Derive a friendly scope name from MG placement where possible
        $scopeName = "core-subscription-$subId"
        foreach ($mgName in $AlzPlatformMgs) {
            $actualMgId = if ($normalizedToActualInfra.ContainsKey($mgName)) {
                $normalizedToActualInfra[$mgName]
            } else {
                $mgName
            }

            $response = Invoke-AzRestMethod `
                -Path "/providers/Microsoft.Management/managementGroups/$actualMgId/subscriptions?api-version=2020-05-01" `
                -Method GET `
                -ErrorAction SilentlyContinue

            if ($response -and $response.StatusCode -eq 200) {
                $match = ($response.Content | ConvertFrom-Json).value |
                    Where-Object { $_.name -eq $subId }
                if ($match) {
                    # Use normalized name for the scope label
                    $scopeName = "core-$mgName"
                    break
                }
            }
        }

        # Special-case the logging scope name to match Export-ALZStackState naming
        if ($scopeName -eq 'core-management') { $scopeName = 'core-logging' }

        try {
            $infraScope = Get-InfrastructureScope -SubscriptionId $subId -ScopeName $scopeName
            if ($infraScope) {
                $infrastructureScopes += $infraScope
                Write-Ok "  $scopeName — $($infraScope.ResourceCount) resource(s)"
            }
        }
        catch {
            $msg = "Infrastructure discovery failed for subscription $subId`: $($_.Exception.Message)"
            $Script:Warnings += $msg
            Write-Fail $msg
        }
    }
}

# ============================================================
# Assemble and write output
# ============================================================
Write-Step 'Writing output'

$export = @{
    ExportTimestamp        = (Get-Date -Format 'o')
    TenantId               = $Script:TenantId
    RootManagementGroupId  = $Script:RootManagementGroupId
    DiscoveryMode          = 'brownfield'
    ManagementGroupHierarchy = $mgHierarchy
    Scopes                 = @($governanceScopes) + @($infrastructureScopes)
    Warnings               = $Script:Warnings
}

$export | ConvertTo-Json -Depth 30 | Out-File -FilePath $OutputFile -Encoding utf8

Write-Host ''
Write-Ok "Export complete: $OutputFile"
Write-Info "Total scopes exported: $($export.Scopes.Count)"
Write-Info "Governance scopes:     $($governanceScopes.Count)"
Write-Info "Infrastructure scopes: $($infrastructureScopes.Count)"

if ($Script:Warnings.Count -gt 0) {
    Write-Host ''
    Write-Warn "$($Script:Warnings.Count) warning(s):"
    foreach ($w in $Script:Warnings) {
        Write-Warn "  $w"
    }
}

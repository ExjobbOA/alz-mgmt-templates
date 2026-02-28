metadata name = 'ALZ Bicep - Platform Cross-MG RBAC Module'
metadata description = 'ALZ Bicep Module used to assign RBAC roles to policy-assigned managed identities across management groups. In full mode: assigns Network Contributor on platform to Enable-DDoS-VNET identity from connectivity MG. In simple mode: assigns Network Contributor on platform to Deploy-Private-DNS-Zones identity from corp MG (absorbed from governance-platform-connectivity-rbac).'

targetScope = 'managementGroup'

//================================
// Parameters
//================================

@description('Required. The name of the Platform management group where role assignments will be created.')
param parPlatformManagementGroupName string

@description('Required. The name of the Connectivity management group where Enable-DDoS-VNET policy is assigned (full mode only).')
param parConnectivityManagementGroupName string

@description('Optional. The name of the Corp management group where Deploy-Private-DNS-Zones policy is assigned (simple mode only).')
param parCorpManagementGroupName string = 'corp'

@description('Optional. PLATFORM_MODE — "simple" absorbs the connectivity RBAC step into this module.')
@allowed(['full', 'simple'])
param parPlatformMode string = 'full'

@description('Optional. Array of policy assignment names excluded from deployment across all management groups.')
param parManagementGroupExcludedPolicyAssignments array = []

@sys.description('Set Parameter to true to Opt-out of deployment telemetry.')
param parEnableTelemetry bool = true

//================================
// Variables
//================================

var builtInRoleDefinitionIds = {
  networkContributor: '/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7'
}

var policyAssignmentsRequiringCrossMgRbac = {
  'Enable-DDoS-VNET': [
    builtInRoleDefinitionIds.networkContributor
  ]
}

var absorbedPolicyAssignmentsRbac = {
  'Deploy-Private-DNS-Zones': [
    builtInRoleDefinitionIds.networkContributor
  ]
}

//================================
// Resources
//================================

// Full mode: Enable-DDoS-VNET policy assignment in Connectivity MG
resource policyAssignmentEnableDdosVnet 'Microsoft.Authorization/policyAssignments@2024-04-01' existing = if (parPlatformMode == 'full' && !contains(parManagementGroupExcludedPolicyAssignments, 'Enable-DDoS-VNET')) {
  name: 'Enable-DDoS-VNET'
  scope: managementGroup(parConnectivityManagementGroupName)
}

// Simple mode: Deploy-Private-DNS-Zones policy assignment in Corp MG
resource policyAssignmentPrivateDnsZones 'Microsoft.Authorization/policyAssignments@2024-04-01' existing = if (parPlatformMode == 'simple' && !contains(parManagementGroupExcludedPolicyAssignments, 'Deploy-Private-DNS-Zones')) {
  name: 'Deploy-Private-DNS-Zones'
  scope: managementGroup(parCorpManagementGroupName)
}

//================================
// Modules
//================================

// Full mode: Enable-DDoS-VNET role assignments to Platform MG
@batchSize(1)
module rbacEnableDdosVnet 'br/public:avm/ptn/authorization/role-assignment:0.2.4' = [
  for roleDefId in (parPlatformMode == 'full' && !contains(parManagementGroupExcludedPolicyAssignments, 'Enable-DDoS-VNET') ? policyAssignmentsRequiringCrossMgRbac['Enable-DDoS-VNET'] : []): {
    name: 'rbac-ddosvnet-${substring(uniqueString(roleDefId), 0, 8)}'
    params: {
      principalId: policyAssignmentEnableDdosVnet.identity.principalId
      roleDefinitionIdOrName: roleDefId
      principalType: 'ServicePrincipal'
      managementGroupId: parPlatformManagementGroupName
      enableTelemetry: parEnableTelemetry
    }
  }
]

// Simple mode: Deploy-Private-DNS-Zones role assignments to Platform MG (absorbed from governance-platform-connectivity-rbac)
@batchSize(1)
module rbacPrivateDnsZones 'br/public:avm/ptn/authorization/role-assignment:0.2.4' = [
  for roleDefId in (parPlatformMode == 'simple' && !contains(parManagementGroupExcludedPolicyAssignments, 'Deploy-Private-DNS-Zones') ? absorbedPolicyAssignmentsRbac['Deploy-Private-DNS-Zones'] : []): {
    name: 'rbac-privdns-${substring(uniqueString(roleDefId), 0, 8)}'
    params: {
      principalId: policyAssignmentPrivateDnsZones.identity.principalId
      roleDefinitionIdOrName: roleDefId
      principalType: 'ServicePrincipal'
      managementGroupId: parPlatformManagementGroupName
      enableTelemetry: parEnableTelemetry
    }
  }
]

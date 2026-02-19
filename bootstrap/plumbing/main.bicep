targetScope = 'managementGroup'

@description('Subscription där RG + UAMI ska skapas (t.ex. management subscription).')
param bootstrapSubscriptionId string

@description('Region för identity-resurser.')
param location string = 'swedencentral'

@description('GitHub org.')
param githubOrg string = 'ExjobbOA'

@description('Config/module repo (där environments finns).')
param moduleRepo string = 'alz-mgmt'

@description('Templates/engine repo (där workflows ligger).')
param templatesRepo string = 'alz-mgmt-templates'

@description('GitHub environments.')
param envPlan string = 'alz-mgmt-plan'
param envApply string = 'alz-mgmt-apply'

@description('Branch som workflows är bundna till i job_workflow_ref.')
param workflowRefBranch string = 'refs/heads/main'

@description('Valfritt override. Tom sträng => derivation från location.')
param identityRgName string = ''

@description('Valfritt override. Tom sträng => derivation från location.')
param uamiPlanName string = ''

@description('Valfritt override. Tom sträng => derivation från location.')
param uamiApplyName string = ''

// Built-in role definition GUIDs (konstanter)
var roleOwnerId  = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'  // Owner
var roleReaderId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'  // Reader

// Deriverade namn (stabila men lätta att ändra)
var effectiveIdentityRgName = empty(identityRgName)
  ? 'rg-alz-mgmt-identity-${location}-1'
  : identityRgName

var effectiveUamiPlanName = empty(uamiPlanName)
  ? 'id-alz-mgmt-${location}-plan-1'
  : uamiPlanName

var effectiveUamiApplyName = empty(uamiApplyName)
  ? 'id-alz-mgmt-${location}-apply-1'
  : uamiApplyName

// Skapa UAMI + FICs i subscription-scope
module identity 'modules/identity-oidc.bicep' = {
  name: 'bootstrap-identity-oidc'
  scope: subscription(bootstrapSubscriptionId)
  params: {
    location: location
    identityRgName: effectiveIdentityRgName
    uamiPlanName: effectiveUamiPlanName
    uamiApplyName: effectiveUamiApplyName

    githubOrg: githubOrg
    moduleRepo: moduleRepo
    templatesRepo: templatesRepo
    envPlan: envPlan
    envApply: envApply
    workflowRefBranch: workflowRefBranch
  }
}

// RBAC på MG-scope (matchar acceleratorupplägget)
// apply = Owner
resource raApplyOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, effectiveUamiApplyName, roleOwnerId)
  scope: managementGroup()
  properties: {
    principalId: identity.outputs.applyPrincipalId
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleOwnerId)
    principalType: 'ServicePrincipal'
  }
}

// plan = Reader
resource raPlanReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, effectiveUamiPlanName, roleReaderId)
  scope: managementGroup()
  properties: {
    principalId: identity.outputs.planPrincipalId
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleOwnerId)
    principalType: 'ServicePrincipal'
  }
}

// Extra: custom role för deployments what-if/validate (så plan kan köra what-if utan att vara Owner)
// (Reader täcker "read", den här täcker actions som Reader saknar.)
var alzReaderRoleName = 'Landing Zone Reader (WhatIf/Validate)'
var alzReaderRoleId = guid(managementGroup().id, 'alz_reader')

resource alzReaderRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: alzReaderRoleId
  scope: managementGroup()
  properties: {
    roleName: alzReaderRoleName
    description: 'Allows ARM/Bicep deployment validate and what-if actions at MG scope. Use alongside Reader.'
    type: 'CustomRole'
    assignableScopes: [
      managementGroup().id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Resources/deployments/validate/action'
          'Microsoft.Resources/deployments/whatIf/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

// Assign custom role to plan identity
resource raPlanAlzReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, effectiveUamiPlanName, alzReaderRoleId)
  scope: managementGroup()
  properties: {
    principalId: identity.outputs.planPrincipalId
    roleDefinitionId: '${managementGroup().id}/providers/Microsoft.Authorization/roleDefinitions/${alzReaderRoleId}'
    principalType: 'ServicePrincipal'
  }
}

output identityResourceGroup string = effectiveIdentityRgName
output planClientId string = identity.outputs.planClientId
output applyClientId string = identity.outputs.applyClientId
output planPrincipalId string = identity.outputs.planPrincipalId
output applyPrincipalId string = identity.outputs.applyPrincipalId

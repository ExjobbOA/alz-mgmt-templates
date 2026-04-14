targetScope = 'subscription'

param location string
param identityRgName string

param uamiPlanName string
param uamiApplyName string

param githubOrg string
param moduleRepo string
param envPlan string
param envApply string

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: identityRgName
  location: location
}

module uami 'uami-oidc.bicep' = {
  name: 'uami-oidc'
  scope: rg
  params: {
    location: location
    uamiPlanName: uamiPlanName
    uamiApplyName: uamiApplyName

    githubOrg: githubOrg
    moduleRepo: moduleRepo
    envPlan: envPlan
    envApply: envApply
  }
}

output planClientId string = uami.outputs.planClientId
output applyClientId string = uami.outputs.applyClientId
output planPrincipalId string = uami.outputs.planPrincipalId
output applyPrincipalId string = uami.outputs.applyPrincipalId

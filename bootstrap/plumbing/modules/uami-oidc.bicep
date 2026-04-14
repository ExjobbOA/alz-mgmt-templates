targetScope = 'resourceGroup'

param location string

param uamiPlanName string
param uamiApplyName string

param githubOrg string
param moduleRepo string
param envPlan string
param envApply string

resource uamiPlan 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiPlanName
  location: location
}

resource uamiApply 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiApplyName
  location: location
}

var issuer = 'https://token.actions.githubusercontent.com'
var audience = 'api://AzureADTokenExchange'

var subjectPlan  = 'repo:${githubOrg}/${moduleRepo}:environment:${envPlan}'
var subjectApply = 'repo:${githubOrg}/${moduleRepo}:environment:${envApply}'

resource ficPlan 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'github-plan'
  parent: uamiPlan
  properties: {
    issuer: issuer
    audiences: [audience]
    subject: subjectPlan
  }
}

resource ficApply 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'github-apply'
  parent: uamiApply
  properties: {
    issuer: issuer
    audiences: [audience]
    subject: subjectApply
  }
  dependsOn: [
    ficPlan
  ]
}

output planClientId string = uamiPlan.properties.clientId
output applyClientId string = uamiApply.properties.clientId
output planPrincipalId string = uamiPlan.properties.principalId
output applyPrincipalId string = uamiApply.properties.principalId

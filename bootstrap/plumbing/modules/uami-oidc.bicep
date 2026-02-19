targetScope = 'resourceGroup'

param location string

param uamiPlanName string
param uamiApplyName string

param githubOrg string
param moduleRepo string
param templatesRepo string
param envPlan string
param envApply string
param workflowRefBranch string

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

var workflowCiPath = '.github/workflows/ci-template.yaml'
var workflowCdPath = '.github/workflows/cd-template.yaml'

var workflowRefCi = '${githubOrg}/${templatesRepo}/${workflowCiPath}@${workflowRefBranch}'
var workflowRefCd = '${githubOrg}/${templatesRepo}/${workflowCdPath}@${workflowRefBranch}'

var subjectCiPlan  = 'repo:${githubOrg}/${moduleRepo}:environment:${envPlan}:job_workflow_ref:${workflowRefCi}'
var subjectCdPlan  = 'repo:${githubOrg}/${moduleRepo}:environment:${envPlan}:job_workflow_ref:${workflowRefCd}'
var subjectCdApply = 'repo:${githubOrg}/${moduleRepo}:environment:${envApply}:job_workflow_ref:${workflowRefCd}'
var subjectPlanSimple  = 'repo:${githubOrg}/${moduleRepo}:environment:${envPlan}'
var subjectApplySimple = 'repo:${githubOrg}/${moduleRepo}:environment:${envApply}'

resource ficCiPlan 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'ci-plan'
  parent: uamiPlan
  properties: {
    issuer: issuer
    audiences: [ audience ]
    subject: subjectCiPlan
  }
}

resource ficCdPlan 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'cd-plan'
  parent: uamiPlan
  properties: {
    issuer: issuer
    audiences: [ audience ]
    subject: subjectCdPlan
  }
  dependsOn: [
    ficCiPlan
  ]
}

resource ficCdApply 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'cd-apply'
  parent: uamiApply
  properties: {
    issuer: issuer
    audiences: [ audience ]
    subject: subjectCdApply
  }
}

resource ficPlanSimple 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'plan-simple'
  parent: uamiPlan
  properties: {
    issuer: issuer
    audiences: [ audience ]
    subject: subjectPlanSimple
  }
  dependsOn: [
    ficCdPlan
  ]
}

resource ficApplySimple 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'apply-simple'
  parent: uamiApply
  properties: {
    issuer: issuer
    audiences: [ audience ]
    subject: subjectApplySimple
  }
  dependsOn: [
    ficCdApply
  ]
}

output planClientId string = uamiPlan.properties.clientId
output applyClientId string = uamiApply.properties.clientId
output planPrincipalId string = uamiPlan.properties.principalId
output applyPrincipalId string = uamiApply.properties.principalId

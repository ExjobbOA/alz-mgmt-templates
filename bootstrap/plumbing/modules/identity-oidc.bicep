targetScope = 'subscription'

param location string
param identityRgName string

param uamiPlanName string
param uamiApplyName string

param githubOrg string
param moduleRepo string
param templatesRepo string
param envPlan string
param envApply string
param workflowRefBranch string

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: identityRgName
  location: location
}

resource uamiPlan 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiPlanName
  scope: rg
  location: rg.location
}

resource uamiApply 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiApplyName
  scope: rg
  location: rg.location
}

// GitHub OIDC standard
var issuer = 'https://token.actions.githubusercontent.com'
var audience = 'api://AzureADTokenExchange'

// Workflow paths (exakt som Terraformn bygger: workflows från templatesRepo)
var workflowCiPath = '.github/workflows/ci-template.yaml'
var workflowCdPath = '.github/workflows/cd-template.yaml'

// job_workflow_ref template: ORG/TEMPLATES_REPO/<path>@refs/heads/main
var workflowRefCi = '${githubOrg}/${templatesRepo}/${workflowCiPath}@${workflowRefBranch}'
var workflowRefCd = '${githubOrg}/${templatesRepo}/${workflowCdPath}@${workflowRefBranch}'

// Subjects (exakt samma format som Terraformn genererar)
var subjectCiPlan  = 'repo:${githubOrg}/${moduleRepo}:environment:${envPlan}:job_workflow_ref:${workflowRefCi}'
var subjectCdPlan  = 'repo:${githubOrg}/${moduleRepo}:environment:${envPlan}:job_workflow_ref:${workflowRefCd}'
var subjectCdApply = 'repo:${githubOrg}/${moduleRepo}:environment:${envApply}:job_workflow_ref:${workflowRefCd}'

// Plan identity: 2 federated creds (ci-plan + cd-plan)
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
}

// Apply identity: 1 federated cred (cd-apply)
resource ficCdApply 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'cd-apply'
  parent: uamiApply
  properties: {
    issuer: issuer
    audiences: [ audience ]
    subject: subjectCdApply
  }
}

output planClientId string = uamiPlan.properties.clientId
output applyClientId string = uamiApply.properties.clientId
output planPrincipalId string = uamiPlan.properties.principalId
output applyPrincipalId string = uamiApply.properties.principalId

targetScope = 'tenant'

@description('Management group name to create (e.g. alz).')
param managementGroupName string = 'alz'

@description('Display name for the management group.')
param managementGroupDisplayName string = 'Azure Landing Zones'

@description('Parent management group id/name (e.g. tenant root mg id).')
param managementGroupParentId string

// Create or update the MG under the parent.
// This is intentionally minimal to avoid auth checks against child scopes.
resource mg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: managementGroupName
  properties: {
    displayName: managementGroupDisplayName
    details: {
      parent: {
        id: '/providers/Microsoft.Management/managementGroups/${managementGroupParentId}'
      }
    }
  }
}

output createdManagementGroupId string = mg.id

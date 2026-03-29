# Iteration 2: Brownfield Integration

## Objective
Demonstrate that the ALZ platform can assess and safely integrate 
existing ClickOps-built landing zones into GitOps governance 
without disrupting workloads.

## Approach

## Discovery
We need to make a PowerShell script that takes a root management group ID as input, and recurses down the hierarchy, and at each node queries for the relevant resource types. 

We will use Get-AzManagementGroup -Recurse for the tree, but we will flatten it after.

Policy queries need to be scoped per MG since Get-AzPolicyAssignment takes a -Scope parameter

Role assignments at MG scope use /providers/Microsoft.Management/managementGroups/{id} as the scope string

For subscription-level resources (the hub VNet, Log Analytics, etc.), you'll need to identify which subscriptions are "platform" subscriptions and query into them, probably by convention or by checking for known resource types

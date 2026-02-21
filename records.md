# Logbook: Thesis Project - ALZ Bicep & IaC

### Feb 1–9: Project Initiation and Setup

* **Planning**: Established the purpose, research questions, and methodology for the thesis.
* **Environment**: Configured the local machine with Azure CLI, Git, VS Code, and PowerShell 7.
* **Bootstrap**: Utilized the `Deploy-Accelerator` to generate the GitHub organization and the initial repositories.
* **Configuration**: Defined `swedencentral` as the primary region and set `6f051987-3995-4c82-abb3-90ba101a0ab4` as the target platform subscription.

### Feb 10: Initial Deployment & Cleanup

* **Incident**: Accidentally triggered a CD flow that deployed resources before the configuration was fully finalized.
* **Recovery**: Manually cleared Deployment Stacks, moved the subscription back, and deleted incorrectly created Management Groups.
* **CI/CD Hardening**: Modified `cd.yaml` to disable automatic execution on push to main and set all deployment steps to a default value of `false`.

### Feb 11–17: Major Architectural Refactoring

* **Repository Restructuring**: Refactored the entire codebase into a two-repo architecture to separate logic from configuration:
* **Engine Repo**: Centralized Bicep modules and generic workflow logic.
* **Tenant Repo**: Contains environment-specific configurations, parameters, and tenant-unique deployment triggers.


* **Paradox Solution**: Addressed the "Cold Start Paradox" where pipelines failed against empty tenants. Updated `bicep-deploy` logic to verify the existence of the `alz` Management Group before attempting `What-If` operations.
* **OIDC & IAM**: Configured Federated Identity Credentials (FIC) to allow GitHub to authenticate via OIDC, eliminating the need for client secrets.

### Feb 18–19: Bootstrap Implementation & Workflow Optimization

* **Cloud Shell Bootstrap**: Implemented a Bicep-based bootstrap solution designed to be run manually via Cloud Shell at the subscription scope. This ensures a self-sovereign setup independent of external Terraform modules.
* **Bicep Guardrails**: Introduced `@batchSize(1)` on module loops for role assignments to mitigate transient errors caused by Entra ID propagation delays (eventual consistency).
* **Deterministic Flow**: Split the deployment phase into several separate jobs (Governance, Logging, Connectivity) with explicit `needs` dependencies to prevent race conditions.

### Feb 20: Connectivity Troubleshooting & Reversion to Monolith CD

* **Observation**: The pipeline execution failed during the Platform Connectivity stage. The process terminated without providing a specific error code or descriptive log message, and the subscription remained in its original Management Group.
* **Troubleshooting**: Investigated the **Azure Activity Log** and extracted a JSON entry revealing a `BadRequest` hidden behind the asynchronous operation.
* **Root Cause**: An IAM Condition attached to the `apply` identity's *User Access Administrator* role restricted the management of `Owner` and `UAA` roles, which was required for the subscription move.
* **Resolution**: Manually adjusted the IAM Condition to permit the operations required for subscription movement.
* **CD Strategy**: Due to the difficulty of debugging silent failures in a split-job architecture, decided to revert to a **monolithic CD pipeline** to ensure better visibility and state consistency during the current phase.

### Feb 21: Issues with a Non-Existent DDoS Plan

* **Problem: The networking deployment stack (alz-networking-hub) keeps crashing because it is looking for a DDoS Protection Plan that doesn't exist.
* **Error Message: The system reports NotFound and points specifically to a resource named ddos-alz-swedencentral.
* **What is happening: Even though I have explicitly turned off DDoS in my settings (deployDdosProtectionPlan: false), Azure is still trying to verify if that plan exists. The pipeline completely stops when it tries to build the Virtual Network.
* **The weird part: It doesn't matter if I clear my "deployment stacks" or update the config files—Azure seems to "remember" or force a search for this plan anyway. It creates a total bottleneck because the build is waiting for a resource I have specifically said I don't want to use.


## Feb 21: Refactoring Bicep Logic to Solve "Ghost" Parameters

###  The Problem

The deployment of the Networking Hub stack (`alz-networking-hub`) failed repeatedly because the Azure Resource Manager (ARM) engine attempted to validate a **DDoS Protection Plan** reference, even when the feature was disabled.

Initial attempts to fix this within the module block failed due to strict Bicep syntax rules:

1. **Scope Restriction:** Variables cannot be declared inside a `module` object within a `for`-loop.
2. **BCP183 Error:** The `params:` property in a module requires a direct **object literal**. It does not allow function calls like `union()` directly within the assignment.


### 🛠 The Solution: Three-Step Array Transformation

To bypass these language restrictions, the parameter logic was refactored into standalone variables outside the module declaration.

#### 1. Pre-calculating Effective IDs

Created an `effectiveDdosIds` array to determine if a hub should use a local plan, a primary plan, or no plan at all (`null`).

```bicep
var effectiveDdosIds = [
  for (hub, i) in hubNetworks: hub.?ddosProtectionPlanResourceId ?? (
    hub.ddosProtectionPlanSettings.deployDdosProtectionPlan
      ? resDdosProtectionPlan[i].outputs.resourceId
      : (hubNetworks[0].ddosProtectionPlanSettings.deployDdosProtectionPlan
          ? resDdosProtectionPlan[0].outputs.resourceId
          : null)
  )
]

```

#### 2. Defining Base Parameters

A base object `hubVnetParamsBase` was created to hold all mandatory networking configurations (Address prefixes, subnets, encryption, etc.).

#### 3. Conditional Merging with `union()`

A final variable `hubVnetParams` was created. By using `union()` here (which is allowed in variable declarations), the `ddosProtectionPlanResourceId` key is **completely omitted** from the object if the value is null.

```bicep
var hubVnetParams = [
  for (hub, i) in hubNetworks: union(
    hubVnetParamsBase[i],
    effectiveDdosIds[i] != null ? { ddosProtectionPlanResourceId: effectiveDdosIds[i] } : {}
  )
]

```

###  Outcome & Implementation

The `resHubVirtualNetwork` module now references the pre-calculated objects:

```bicep
module resHubVirtualNetwork 'br/public:avm/res/network/virtual-network:0.7.2' = [
  for (hub, i) in hubNetworks: {
    name: 'vnet-${hub.name}-${uniqueString(parHubNetworkingResourceGroupNamePrefix, hub.location)}'
    params: hubVnetParams[i] // Reference to the clean object
  }
]

```

**Result:** Since the DDoS key is now physically absent from the JSON payload when disabled, Azure no longer triggers the `NotFound` validation for the Sweden Central plan. This successfully resolved the cross-region dependency bug.


**Issue:** The GitHub "Cancel workflow" command is ineffective, and manual intervention via Azure CLI/Portal also fails to terminate the deployment sequence.

Technical Observations:

Manual Intervention Failure: Attempts to manually cancel the deployment via az deployment sub cancel or deleting the stack in the Portal did not break the loop. The automation script immediately detects the missing/cancelled state as a "failure" and triggers a fresh cleanup and restart.

The Idempotency Trap: The pipeline's resilience logic is "too effective." It treats a manual cancellation as a transient error, meaning the automation is essentially fighting against the developer's intent to stop.

Locked Sequence: Because the script manages the entire lifecycle (Delete -> Create -> Retry), it creates a closed loop that cannot be interrupted until the maximum retry count (10) is reached or the GitHub Runner times out.

Här är loggposten för den slutgiltiga Bicep-fixen, där vi använder "Object Spread" för att navigera runt språkets begränsningar.

---


## Feb 21: Bicep Compilation & The "Object Spread" Solution

###  The Problem (Round 2)

The previous attempt to move parameter logic into standalone variables failed due to a new set of Bicep compilation errors:

1. **BCP183:** `module.params` must be a direct **object literal**. Referencing a pre-calculated variable (like `hubVnetParams[i]`) is not permitted in this context.
2. **BCP182:** Variables using a `for`-body cannot reference `module.outputs`. Since our DDoS ID logic depends on `resDdosProtectionPlan[i].outputs.resourceId`, it cannot be stored in a variable outside the module loop.

### 🛠 The Solution: Inline Object Spread (`...`)

To resolve these conflicting rules, the logic was moved back inside the module's `params` block, using **Object Spread** to conditionally include the DDoS property.

#### Implementation Detail

By wrapping the logic in a spread operator `... (condition ? { key: value } : {})`, we ensure the code remains an **object literal** while still being dynamic.

```bicep
params: {
  name: hub.name
  location: hub.location
  // ... other standard params

  // Conditional inclusion via Object Spread
  ...((
    hub.?ddosProtectionPlanResourceId ?? (
      hub.ddosProtectionPlanSettings.deployDdosProtectionPlan
        ? resDdosProtectionPlan[i].outputs.resourceId
        : hubNetworks[0].ddosProtectionPlanSettings.deployDdosProtectionPlan
            ? resDdosProtectionPlan[0].outputs.resourceId
            : null
    )
  ) != null ? {
    ddosProtectionPlanResourceId: (hub.?ddosProtectionPlanResourceId ?? (hub.ddosProtectionPlanSettings.deployDdosProtectionPlan ? resDdosProtectionPlan[i].outputs.resourceId : resDdosProtectionPlan[0].outputs.resourceId))
  } : {})
}

```

---

###  Outcome

* **Syntax Compliance:** This approach satisfies **BCP183** (it is an object literal) and **BCP182** (outputs are accessed within the module scope).
* **Logic Perfection:** When DDoS is disabled, the expression evaluates to an empty object `{}`. When spread, it results in **no key being sent** to the Azure API.
* **Deployment Status:** This eliminates the "Ghost" reference to the Sweden Central DDoS plan during the VNet creation/update phase.

Här är loggposten för den pragmatiska lösningen. Vi går ifrån avancerad Bicep-syntax (som spread/union) och använder istället en **villkorlig logik med dubbla moduler**. Detta är ett klassiskt mönster för att hantera begränsningar i Bicep v0.40.2 där man vill garantera att en "property" inte ens skickas till Azure.

---

## Feb 21: Bypassing Bicep v0.40.2 Limitations with Dual-Module Logic

### The Problem (The Syntax Wall)

Even with object spreading, Bicep v0.40.2 can be unpredictable when trying to completely omit a property (like `ddosProtectionPlanResourceId`) within a complex object that also contains a `for`-loop (subnets).

Simply setting a flag to `false` in the parameters wasn't enough, as the template logic still generated a "null-key" that triggered validation against a non-existent DDoS plan in Sweden Central.

### 🛠 The Solution: Parameter-Driven Module Switching

Instead of fighting with object-merging functions, the template was refactored to use two separate module blocks governed by an `if`-condition.

#### Strategy:

* **Module A (`noDdos`):** Deploys the VNet **without** the DDoS property entirely.
* **Module B (`withDdos`):** Deploys the VNet **with** the DDoS property included.
* **Logic:** An `if` statement checks the calculated DDoS ID. If it's `null`, Module A runs; otherwise, Module B runs.

#### Implementation:

```bicep
// Module A: Runs only if the calculated DDoS ID is NULL
module resHubVirtualNetwork_noDdos 'br/public:avm/res/network/virtual-network:0.7.2' = [
  for (hub, i) in hubNetworks: if (effectiveDdosId == null) {
    name: 'vnet-${hub.name}-noddo'
    params: {
      // No ddosProtectionPlanResourceId key present here
      ...
    }
  }
]

// Module B: Runs only if the calculated DDoS ID is NOT NULL
module resHubVirtualNetwork_withDdos 'br/public:avm/res/network/virtual-network:0.7.2' = [
  for (hub, i) in hubNetworks: if (effectiveDdosId != null) {
    name: 'vnet-${hub.name}-ddos'
    params: {
      ddosProtectionPlanResourceId: effectiveDdosId
      ...
    }
  }
]

```

### Outcome & Practical Benefits

* **Zero Ghost References:** Since the "No DDoS" module version doesn't even contain the key, Azure has nothing to validate. The `NotFound` error is physically impossible in this state.
* **Clean UX:** The user (tenant) only needs to care about the simple `true/false` flag in their `.bicepparam` file.
* **Robustness:** This bypasses the **BCP183** and **BCP182** errors by using standard Bicep patterns that are supported across all versions.

---

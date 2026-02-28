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



---

## Feb 21: Bypassing Bicep v0.40.2 Limitations with Dual-Module Logic

### The Problem (The Syntax Wall)

Even with object spreading, Bicep v0.40.2 can be unpredictable when trying to completely omit a property (like `ddosProtectionPlanResourceId`) within a complex object that also contains a `for`-loop (subnets).

Simply setting a flag to `false` in the parameters wasn't enough, as the template logic still generated a "null-key" that triggered validation against a non-existent DDoS plan in Sweden Central.

### The Solution: Parameter-Driven Module Switching

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

## Feb 25: Centralized Parameters Refactoring

### The Problem

All 18 `.bicepparam` files in `alz-mgmt` contained heavily duplicated values. The subscription ID appeared 100+ times across the codebase, `parLocations` was copy-pasted into every file, and resource name strings like `law-alz-swedencentral` were hardcoded at every scope. Naming conventions were also inconsistent (`mi-alz-` vs `uami-alz-`, `dcr-ct-alz-` vs `dcr-alz-changetracking-`, etc.). Any change to the primary region or subscription ID required editing every file by hand.

### The Solution: platform.json as Single Source of Truth

The `bicep-variables` CI action already exported every key in `platform.json` as environment variables before deployment steps. Since `readEnvironmentVariable()` in `.bicepparam` files resolves at Bicep compile time, `platform.json` could serve as the single source of truth without needing a generation script or template files.

All 18 `.bicepparam` files were refactored to:
1. Declare a `var` block reading from `readEnvironmentVariable()` calls
2. Derive all compound resource identifiers (workspace IDs, DCR IDs, etc.) from those vars
3. Reference only vars in `param` assignments — zero hardcoded subscription IDs or location strings

New fields added to `platform.json`: `ENABLE_TELEMETRY`, `SECURITY_CONTACT_EMAIL`, and `LOCATION_SECONDARY` set to `northeurope`.

### Naming Convention Normalization

Standardized all resource names across files:

| Old name | New name |
|----------|----------|
| `mi-alz-{location}` | `uami-alz-{location}` |
| `dcr-ct-alz-{location}` | `dcr-alz-changetracking-{location}` |
| `dcr-vmi-alz-{location}` | `dcr-alz-vminsights-{location}` |
| `dcr-mdfcsql-alz-{location}` | `dcr-alz-mdfcsql-{location}` |

### VS Code False Positives

The VS Code Bicep extension reports errors on `var` blocks and `readEnvironmentVariable()` in `.bicepparam` files. These are false positives — the extension language server can't resolve the `using` target path (which requires the templates repo to be checked out at `./platform/`). The Bicep CLI (0.40.2+) compiles these files correctly; verified with `az bicep build-params` against all files with env vars set.

### Key Pattern: DNS Zone Prefix Variable

The `landingzones-corp` policy overrides previously repeated a 100-character resource ID path 45 times (once per private DNS zone). Solved by computing a `dnsPrefixId` var:

```bicep
var dnsPrefixId = '/subscriptions/${subIdConn}/resourceGroups/${rgDns}/providers/Microsoft.Network/privateDnsZones/'
// Each zone then becomes:
azureKeyVaultPrivateDnsZoneId: { value: '${dnsPrefixId}privatelink.vaultcore.azure.net' }
```

### Outcome

`platform.json` is now the only file a tenant operator needs to edit. Changing the primary region or subscription ID propagates automatically to all deployment scopes at compile time. `CLAUDE.md` updated with local dev workflow instructions and documentation of the VS Code false-positive issue.

---
# Log Entry: Connectivity Deployment Failure — DDoS Plan Reference (ALZ)

**Date:** February 21, 2026
**Status:** Resolved
**Environment:** Azure Landing Zone (ALZ) — Connectivity Hub
**Regions:** `swedencentral`, `northeurope`
**Subscription ID:** `6f051987-3995-4c82-abb3-90ba101a0ab4`

## Observed Problem

Connectivity hub deployment failed multiple times when creating hub networking resources. The deployment returned:

* `DeploymentFailed`
* Error code: `NotFound`

The error message referenced a DDoS plan that could not be found:

> Resource `/subscriptions/.../resourceGroups/rg-alz-conn-swedencentral/providers/Microsoft.Network/ddosProtectionPlans/ddos-alz-swedencentral` not found.

## Checks Performed

* Deleted the failed deployment stack.
* Deleted/cleaned resources in the target resource groups for the affected regions.
* Confirmed the DDoS plan resource was not present in the subscription.
* Removed DDoS plan references from Bicep templates and parameter files.
* Set `deployDdosProtectionPlan = false`.
* Re-ran the GitHub Actions deployment.

Result: failure continued with the same `NotFound` message.

## Template Change (to avoid passing a bad value)

Added a null-safe value for the DDoS plan ID so the VNet deployment does not receive an invalid resource ID:

```bicep id="i0y1x2"
// Ensure no invalid IDs are passed to the VNet resource
ddosProtectionPlanResourceId: hub.?ddosProtectionPlanResourceId ?? null
```

Also removed the `name` field under `ddosProtectionPlanSettings` in the `.bicepparam` file so the deployment cannot build a DDoS plan resource ID from parameters.

Also tried a dual module style for the virtual networking

## Root Cause Found

Checked Azure Policy assignments at the Connectivity management group scope. Found a policy assignment:

* **Policy:** "Virtual networks should be protected by Azure DDoS Network Protection"
* **Effect:** `Modify`

Observed behavior during deployment:

1. Bicep sent a request to create the VNet without DDoS enabled.
2. The policy ran during validation/deployment.
3. Because the effect was `Modify`, the policy tried to add the DDoS plan ID (stored in the policy assignment parameters) into the VNet.
4. The DDoS plan in the policy parameters had been deleted.
5. ARM failed the deployment with `NotFound`.

Reference thread: [Azure/Azure-Landing-Zones #3540](https://github.com/Azure/Azure-Landing-Zones/issues/3540)

## Resolution Steps

* Opened the policy assignment in Azure Portal (Connectivity management group scope).
* Changed **Policy Enforcement** from `Default` to `Disabled`.
* Re-ran the GitHub Actions deployment.

Result: VNet creation completed successfully and the overall connectivity deployment succeeded.

## Notes / Follow-up

* If the policy is kept, its parameters must be updated to point to an existing DDoS plan, or changed so it does not try to add one.
* Leaving the policy enabled while it references a deleted DDoS plan will block future VNet deployments.
* Keeping the null-safe Bicep logic reduces the chance of accidentally passing invalid values in future changes.
---
### Feb 25: Centralized Parameters — Design & Implementation Plan

* **Problem**: Configuration is scattered across 18 `.bicepparam` files with heavy
  duplication — the subscription ID appears 100+ times, `parLocations` is copy-pasted
  into every file, and resource IDs are hardcoded per scope. Naming is also inconsistent
  (`uami-alz-` vs `mi-alz-`, `dcr-alz-changetracking-` vs `dcr-ct-alz-`).
* **Approach**: Use `readEnvironmentVariable()` in `.bicepparam` files to read directly
  from `config/platform.json`, which is already exported as environment variables by the
  `bicep-variables` action before any deployment step. No generation scripts or template
  files required.
* **Pattern**: Each `.bicepparam` file will open with a `var` block that reads scalar
  values from env vars and derives compound resource IDs via Bicep string interpolation.
* **Goal**: `platform.json` becomes the only file a tenant operator needs to touch for
  a standard deployment. `.bicepparam` files are structural wiring only.
* **Naming conventions to enforce**: `law-alz-{location}`, `uami-alz-{location}`,
  `dcr-alz-{type}-{location}`, `rg-alz-{purpose}-{location}` applied consistently
  across all scopes.
---

## Feb 25: Centralized Parameters Refactoring

### The Problem

All 18 `.bicepparam` files in `alz-mgmt` contained heavily duplicated values. The subscription ID appeared 100+ times across the codebase, `parLocations` was copy-pasted into every file, and resource name strings like `law-alz-swedencentral` were hardcoded at every scope. Naming conventions were also inconsistent (`mi-alz-` vs `uami-alz-`, `dcr-ct-alz-` vs `dcr-alz-changetracking-`, etc.). Any change to the primary region or subscription ID required editing every file by hand.

### The Solution: platform.json as Single Source of Truth

The `bicep-variables` CI action already exported every key in `platform.json` as environment variables before deployment steps. Since `readEnvironmentVariable()` in `.bicepparam` files resolves at Bicep compile time, `platform.json` could serve as the single source of truth without needing a generation script or template files.

All 18 `.bicepparam` files were refactored to:
1. Declare a `var` block reading from `readEnvironmentVariable()` calls
2. Derive all compound resource identifiers (workspace IDs, DCR IDs, etc.) from those vars
3. Reference only vars in `param` assignments — zero hardcoded subscription IDs or location strings

New fields added to `platform.json`: `ENABLE_TELEMETRY`, `SECURITY_CONTACT_EMAIL`, and `LOCATION_SECONDARY` set to `northeurope`.

### Naming Convention Normalization

Standardized all resource names across files:

| Old name | New name |
|----------|----------|
| `mi-alz-{location}` | `uami-alz-{location}` |
| `dcr-ct-alz-{location}` | `dcr-alz-changetracking-{location}` |
| `dcr-vmi-alz-{location}` | `dcr-alz-vminsights-{location}` |
| `dcr-mdfcsql-alz-{location}` | `dcr-alz-mdfcsql-{location}` |

### VS Code False Positives

The VS Code Bicep extension reports errors on `var` blocks and `readEnvironmentVariable()` in `.bicepparam` files. These are false positives — the extension language server can't resolve the `using` target path (which requires the templates repo to be checked out at `./platform/`). The Bicep CLI (0.40.2+) compiles these files correctly; verified with `az bicep build-params` against all files with env vars set.

### Key Pattern: DNS Zone Prefix Variable

The `landingzones-corp` policy overrides previously repeated a 100-character resource ID path 45 times (once per private DNS zone). Solved by computing a `dnsPrefixId` var:

```bicep
var dnsPrefixId = '/subscriptions/${subIdConn}/resourceGroups/${rgDns}/providers/Microsoft.Network/privateDnsZones/'
// Each zone then becomes:
azureKeyVaultPrivateDnsZoneId: { value: '${dnsPrefixId}privatelink.vaultcore.azure.net' }
```

### Outcome

`platform.json` is now the only file a tenant operator needs to edit. Changing the primary region or subscription ID propagates automatically to all deployment scopes at compile time.

---

## Feb 26: Onboarding + Cleanup Scripts

Two scripts added to `scripts/`:

- **`cleanup.ps1`** — tears down management group hierarchies, deployment stacks, identity resources, and role assignments to return a tenant to a clean state before re-onboarding.
- **`onboard.ps1`** — end-to-end tenant bootstrapping: creates GitHub environments, runs the bootstrap ARM deployment, captures the UAMI client IDs from outputs, and writes them back as GitHub environment variables and into `platform.json` / `plumbing.bicepparam`.

### Bug 1: PowerShell quote-stripping when calling `az`

**Symptom:** `az deployment mg create --parameters <json>` returned `Unable to parse parameter: {key:{value:...}}` — keys and string values were unquoted.

**Root cause:** PowerShell strips quotes from JSON strings when passing them as arguments to native executables. The inline `$paramsJson` string lost its double-quotes before `az` received it.

**Fix:** Write the parameters object to a temp `.json` file and pass `@<path>` to `--parameters` instead of an inline string. The `@file` syntax bypasses shell quoting entirely.

### Bug 2: Concurrent Federated Identity Credential writes

**Error:** `ConcurrentFederatedIdentityCredentialsWritesForSingleManagedIdentity` — Azure rejects parallel writes of multiple federated credentials under the same managed identity.

**Root cause:** The compiled `bootstrap/plumbing/main.json` did not preserve the Bicep `dependsOn` chain from `uami-oidc.bicep`. In the ARM JSON, `ci-plan` and `cd-plan` (both children of `uamiPlan`) each depended only on the parent UAMI — not on each other — so ARM deployed them in parallel.

**Fix:** Updated `main.json` directly to serialize all three credential writes:
- `cd-plan` now `dependsOn` `ci-plan`
- `cd-apply` now `dependsOn` `cd-plan`

Also updated `uami-oidc.bicep` source with the same chain so future recompiles stay correct.

---

## Feb 27: OIDC Subject Mismatch + Cold-Start Deployment Stack Failure

### Bug 3: OIDC subject claim mismatch (`AADSTS700213`)

**Symptom:** First CD run for a new tenant (alz-mgmt-3) failed with `AADSTS700213: No matching federated identity record found for presented assertion subject 'repo:ExjobbOA/alz-mgmt-3:environment:alz-mgmt-apply'`.

**Root cause:** The Federated Identity Credentials created by `onboard.ps1` include `job_workflow_ref` in the subject string (per the subject contract). However, GitHub's default OIDC `sub` claim for environment-based jobs is only `repo:ORG/REPO:environment:ENV` — `job_workflow_ref` is a separate JWT claim, NOT included in `sub` unless explicitly opted-in via the GitHub API.

**Fix:** Added `Set-OidcSubjectClaim` step to `onboard.ps1` that calls `PUT /repos/{org}/{repo}/actions/oidc/customization/sub` with `{"use_default":false,"include_claim_keys":["repo","context","job_workflow_ref"]}`. This makes GitHub include `job_workflow_ref` in the OIDC `sub`, matching the FIC subject format.

**Note:** Existing repos also need this configured manually once:
```powershell
'{"use_default":false,"include_claim_keys":["repo","context","job_workflow_ref"]}' | gh api --method PUT repos/ExjobbOA/alz-mgmt/actions/oidc/customization/sub --input -
```

### Bug 4: Deployment Stack cold-start authorization failure (re-discovery)

**Symptom:** `governance-int-root` Deployment Stack failed on every attempt with `Authorization failed ... does not have permission to perform action 'Microsoft.Resources/deployments/write' at scope '/providers/Microsoft.Management/managementGroups/alz/...'`. Persisted for hours — not a propagation delay.

**Root cause:** Azure Deployment Stacks evaluate permissions for **all target scopes in the template before executing any resources**. The `int-root` stack deploys policy definitions and nested deployments at the `alz` MG scope. On a clean tenant, `alz` doesn't exist yet, so ARM cannot resolve RBAC inheritance at that scope → fails before the stack can create `alz` → circular deadlock on every run.

**Fix:** Added a "Pre-create Intermediate Root MG (cold-start)" step in the `deploy` job of `cd-template.yaml`, before the `governance-int-root` stack step. Uses `New-AzManagementGroup` to create the empty `alz` shell (idempotent). Waits 60s for RBAC inheritance to propagate when newly created.

**Note:** This is a re-implementation of a previously removed step. Deployment Stacks always require the target scope to exist before they can evaluate permissions.

---

## Feb 28: First Full End-to-End Deploy — Green

**Milestone:** First successful full pipeline run on Alen's tenant after a clean slate: `cleanup.ps1` → `onboard.ps1` → CD pipeline.

All governance stacks completed successfully:

- Pre-create ALZ MG hierarchy (cold-start)
- `governance-int-root` — ALZ policy/role definition library deployed at `alz` scope
- `governance-platform` + 4 child MGs (connectivity, identity, management, security)
- `governance-landingzones` + corp + online
- `governance-sandbox`, `governance-decommissioned`
- All RBAC stacks
- `core-logging` (Log Analytics, Automation Account, AMA/DCR)

**Networking excluded intentionally:** Hub networking was not deployed in this run due to Azure infrastructure cost. The networking stack is implemented and available but left disabled for evaluation tenants.

**Total pipeline time:** ~1h34m (cold-start, all stacks CREATE not UPDATE). Subsequent incremental runs will be significantly faster since ARM skips unchanged resources on stack UPDATE.

**Bugs resolved leading up to this milestone:**
- Bug 1 (Feb 26): PowerShell quote-stripping on `az` CLI calls → `@file` workaround
- Bug 2 (Feb 26): Concurrent FIC writes during bootstrap → serialized `dependsOn` in ARM JSON
- Bug 3 (Feb 27): OIDC subject claim mismatch → `Set-OidcSubjectClaim` added to `onboard.ps1`
- Bug 4 (Feb 27): Deployment Stack cold-start auth failure → pre-create full MG skeleton before any stack step

---

## Feb 28: PLATFORM_MODE=simple Implemented (Iteration 1 / 4a)

### What was built

`PLATFORM_MODE` is a new field in `platform.json` that acts as a floodgate controlling whether the full platform sub-MG hierarchy deploys or collapses into a single `platform` MG. Default for iteration 1 is `"simple"`.

**Templates repo (`alz-mgmt-templates`):**

- **`platform/main.bicep`**: Added `parIncludeSubMgPolicies bool` param. When `true`, 5 sub-MG policies are concatenated into the platform policy assignments at `platform` scope: `Enable-DDoS-VNET` (from connectivity), `Deny-MgmtPorts-Internet`, `Deny-Public-IP`, `Deny-Subnet-Without-Nsg`, `Deploy-VM-Backup` (from identity). Added `networkContributor` to `builtInRoleDefinitionIds` and `Enable-DDoS-VNET` to `alzPolicyAssignmentRoleDefinitions` so AVM creates the Network Contributor role assignment automatically.
- **`platform/main-rbac.bicep`**: Added `parPlatformMode` param (`"full"` | `"simple"`). Full mode: existing behavior (Network Contributor on platform MG for Enable-DDoS-VNET identity from connectivity). Simple mode: absorbed connectivity-rbac behavior (Network Contributor on platform MG for Deploy-Private-DNS-Zones identity from corp MG). The two modes are mutually exclusive — whichever is active, the other's for-loop evaluates to `[]`.
- **`cd-template.yaml`**: Gated 4 sub-MG governance steps (`governance-platform-connectivity/identity/management/security`) and `governance-platform-connectivity-rbac` on `PLATFORM_MODE != 'simple'` in both the whatif and deploy jobs. Pre-create step now skips the 4 sub-MGs when `PLATFORM_MODE=simple`.

**Config repos (`alz-mgmt`, `alz-mgmt-3`):**

- **`platform.json`**: Added `PLATFORM_MODE: "simple"`, added `SUBSCRIPTION_ID_PLATFORM` (the single subscription to place under `platform` MG), removed `SUBSCRIPTION_ID_CONNECTIVITY/IDENTITY/SECURITY` (not needed in simple mode — sub-MG steps don't run).
- **`platform/main.bicepparam`**: Added `parIncludeSubMgPolicies = includeSubMgPolicies` and `subscriptionsToPlaceInManagementGroup: platformSubscriptions` (places `SUBSCRIPTION_ID_PLATFORM` under `platform` MG in simple mode).
- **`platform/main-rbac.bicepparam`**: Added `parPlatformMode = platformMode` and `parCorpManagementGroupName = 'corp'`.

### Deployment flow in simple mode

1. Pre-create: `alz`, `landingzones`, `platform`, `sandbox`, `decommissioned`, `corp`, `online` (sub-MGs skipped)
2. `governance-int-root` → `governance-platform` (now includes 5 extra policies) → `governance-landingzones` → corp/online → sandbox/decommissioned
3. `governance-platform-rbac` (now absorbs connectivity RBAC in simple mode) → `governance-landingzones-rbac`
4. `core-logging`

Steps skipped in simple mode: `governance-platform-connectivity/identity/management/security` and `governance-platform-connectivity-rbac`.

---

## Iteration Roadmap & PLATFORM_MODE Architecture Decision

### Iteration 1 scope (current)
- **3a** Greenfield deployment on a new tenant (post-`cleanup.ps1` → `onboard.ps1` → CD)
- **3b** Re-deployment on an existing ALZ set up with this method (idempotent stack update)
- **4a** Single Platform Management Group — one subscription, one `platform` MG, no child breakdown

### Iteration 2 scope (planned)
- **4b** Multi-platform MG support — formalize connectivity/identity/management/security as a supported path (infrastructure already exists in the codebase, needs proper platform.json shape and CI/CD conditioning)
- **3c** Brownfield integration — import existing ALZ not set up with this method into stacks

### PLATFORM_MODE: the floodgate model

The platform MG hierarchy works like a river with a floodgate:

- The **main channel** is the `platform` MG — 41 ALZ policy assignments always flow here regardless of mode
- In **full mode** the floodgate opens: 5 additional policies bifurcate into 4 sub-channels (connectivity, identity, management, security child MGs). Each child MG also receives its own subscription.
- In **simple mode** the floodgate stays closed: those 5 policies stay consolidated at `platform` scope, one subscription sits directly under `platform`, and the 4 sub-channels are never created.

**Policy inventory per sub-MG (what gets consolidated in simple mode):**

| Sub-MG | Policies | Notes |
|--------|----------|-------|
| `connectivity` | Enable-DDoS-VNET | 1 policy |
| `identity` | Deny-MgmtPorts-Internet, Deny-Public-IP, Deny-Subnet-Without-Nsg, Deploy-VM-Backup | 4 policies |
| `management` | — | Empty container only |
| `security` | — | Empty container only |

**Implementation plan for PLATFORM_MODE (iteration 1 work):**
1. Add `PLATFORM_MODE: "simple"` to `platform.json` (default for iteration 1)
2. Add `parIncludeSubMgPolicies: bool` to `platform/main.bicep` — when `true`, the 5 sub-MG policies are assigned directly at `platform` scope
3. Replace `SUBSCRIPTION_ID_MANAGEMENT/CONNECTIVITY/IDENTITY/SECURITY` with a single `SUBSCRIPTION_ID_PLATFORM` in `platform.json` for simple mode
4. In `cd-template.yaml`: read `PLATFORM_MODE`, skip the 4 sub-MG stack steps when `simple`
5. In pre-create step: skip connectivity/identity/management/security MG creation when `PLATFORM_MODE == simple`
6. Absorb `governance-platform-connectivity-rbac` into the platform RBAC step in simple mode — it assigns `Network Contributor` on `connectivity` to the managed identity of the `Deploy-Private-DNS-Zones` policy (originating from Corp MG). In simple mode that role assignment retargets to `platform` instead (where the subscription and DNS zones live). `governance-platform-rbac` and `governance-landingzones-rbac` survive simple mode unchanged.

**Why simple mode is the right default for iteration 1:** Most evaluation tenants have one subscription. Four empty child MGs with no subscriptions add structural complexity without governance benefit. Simple mode also gives a cleaner onboarding story — one subscription ID, one platform MG.

---

## Feb 28: cleanup.ps1 — Subscription Movement Fix

**Problem:** Running `cleanup.ps1` after a full deployment failed with `ResourceDeletionFailed` on the `governance-platform-connectivity` stack. ARM cannot delete a management group that still has a subscription in it. The stack's `DeleteAll` logic tried to delete the `connectivity` MG while the platform subscription was still placed there.

**Fix:** Added `Remove-SubscriptionsFromHierarchy` as a pre-step before stack deletion. It iterates all known ALZ MG names and calls the `managementGroups/subscriptions` REST API to find any subscriptions placed there, then moves them to the tenant root MG before stacks are deleted.

**Implementation detail:** Initial attempt used `Get-AzManagementGroup -Expand` and filtered children by `Type`. Failed because `Set-StrictMode -Version Latest` throws on property access when the object shape is inconsistent across Az PS versions. Fixed by using `Invoke-AzRestMethod` against the dedicated REST endpoint directly — more reliable and explicit.

**Note:** This is a development-only concern. On a production tenant you would never run cleanup.

---

## Feb 28: Brownfield Discovery Script — Prototype

A real brownfield tenant is being onboarded next week. Ahead of that, a discovery script (`scripts/discover.ps1`) was built as a read-only "git diff" diagnostic tool.

### Concept

The core analogy: brownfield adoption is like a merge conflict. The platform has a desired state (ALZ MG hierarchy, policy library, RBAC). The existing tenant has its own state. They've diverged. The discovery script surfaces where they agree (green), where there are decisions to make (yellow), and where there are hard conflicts that must be resolved before adoption (red).

### What it does

1. **Discovers** all subscriptions in the tenant and their current MG placement
2. **Inventories** resource types per subscription
3. **Flags resource conflicts** — matches resource types against a map of ALZ deny policies that would affect them (e.g. `Deny-Public-IP` → any `Microsoft.Network/publicIPAddresses`)
4. **Flags policy definition conflicts** — enumerates existing custom policy definitions, initiatives, assignments, and role definitions that could collide with ALZ library names or be shadowed by incoming MG-level assignments
5. **Classifies** each subscription as Green / Yellow / Red
6. **Outputs** a color-coded console report and optionally a JSON file for further review

### The "custom policies disappearing" concern

A key requirement raised: existing custom policies must not be lost during adoption. Deployment Stacks with `DeleteAll` only manage what they deployed — they won't delete things they never owned. But two real risks remain:

- **Name collision**: ALZ tries to create a policy def with the same name as an existing one → ARM deployment error
- **Effect collision**: customer's sub-level or MG-level assignments overlap with incoming ALZ MG-level policies → unexpected effective policy

The script surfaces both. All custom policy definitions/initiatives are flagged Yellow by default. The stub for full name-collision detection (comparing against the `.alz_policy_definition.json` library) is marked clearly — when implemented, confirmed collisions would escalate to Red.

### Stubs (not yet implemented)

- Deep NSG rule inspection (inbound allow 0.0.0.0/0 on port 22/3389 → Red)
- Storage account public access check → Red
- Actual name comparison against ALZ policy library files → flip Yellow → Red on confirmed collisions
- Arbitrary MG hierarchy traversal (current implementation only checks known ALZ MG names)

### Output artifact

The `-OutputPath` flag writes the full result as JSON. This is the artifact to review with stakeholders before touching anything in the tenant. After review, decisions feed into a placement config (sub → target MG, policy exclusions, custom policies to preserve) that an adoption script would read.

---

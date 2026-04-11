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

### Bug 3: `subscriptionResourceId` fails at management group scope

**Error:** `Unable to evaluate template language function 'subscriptionResourceId'. At least 3 parameters should be provided.`

**Root cause:** The compiled `main.json` used `subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ...)` with only 2 arguments for the built-in Owner and Reader role assignments. At management group deployment scope there is no implicit subscription context, so ARM cannot resolve it. The Bicep source correctly used `tenantResourceId()` — the compiled JSON was stale from an older version.

**Fix:** Updated `main.json` to use `tenantResourceId('Microsoft.Authorization/roleDefinitions', ...)` for both role assignments. Built-in role definitions are tenant-scoped resources; `tenantResourceId` is the correct function.

### Outcome

`onboard.ps1` ran successfully end-to-end on a second tenant (Nordlo Alen, `c785e463-...`). GitHub environments created, bootstrap deployed, UAMI client IDs written back to `alz-mgmt-2` config repo and GitHub environment variables.

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

---

## Mar 01: Networking Issues on Fresh Deployment — Three Bugs Fixed

While enabling hub networking for the empirical testing pass, three separate failures surfaced and were fixed.

### Bug 1: ALZ NSG Policy Blocks Placeholder Subnets

**Error:** `RequestDisallowedByPolicy` — `AzureBastionSubnet` disallowed because it had no NSG.

**Cause:** The hub networking `.bicepparam` pre-created subnets for Firewall, Bastion, VPN Gateway, and DNS Resolver even though all corresponding `deploy*` flags were `false`. The ALZ `Deny-Subnet-Without-Nsg` policy rejects any subnet without an NSG.

**Fix:** Removed all placeholder subnets from both hub networks (swedencentral + northeurope). Comments in the file document how to re-add each subnet when enabling the corresponding resource. A VNet with no subnets is valid and policy-compliant.

---

### Bug 2: Enable-DDoS-VNET Policy Causes LinkedAuthorizationFailed

**Error:** `LinkedAuthorizationFailed` — ARM tried to join VNets to a DDoS plan in subscription `00000000-0000-0000-0000-000000000000`.

**Root cause:** The ALZ library ships `Enable-DDoS-VNET` with `effect: Modify` and a placeholder DDoS plan resource ID (`/subscriptions/00000000-.../placeholder`). In simple mode, `parIncludeSubMgPolicies=true` causes this assignment to be deployed at the **platform MG** scope — covering the platform subscription where the hub VNets live. No override existed to neutralise it.

The existing override in `landingzones/main.bicepparam` only overrode `ddosPlan` (pointing to a plan that also doesn't exist since `deployDdosProtectionPlan: false`), leaving `effect: Modify` intact — so the policy still fired and still failed.

**Fix:** Added `effect: Audit` override to both `platform/main.bicepparam` (missing override) and `landingzones/main.bicepparam` (wrong override). With `Audit` the policy reports non-compliant VNets but does not attempt to modify them. When a real DDoS plan is deployed, change the effect back to `Modify` and uncomment the `ddosPlan` override.

---

### Bug 3: First-Deployment Check Returns 403 Instead of 404 on Blank Tenant

**Error:** `bicep-first-deployment-check` failed with `AuthorizationFailed` when querying the `alz` management group.

**Root cause:** When `alz` doesn't exist yet, Azure cannot walk an RBAC inheritance chain from a non-existent scope and returns 403 instead of 404. The check correctly refuses to treat a permission error as a "not found" signal — but this made it impossible to run CD on a blank tenant immediately after onboarding, even though the plan UAMI has explicit Reader at the tenant root MG.

**Fix:** Added optional `parentManagementGroupId` input to `bicep-first-deployment-check`. When a 403 is received, the action falls back to listing the parent MG's direct children (which the plan UAMI can always read via its explicit assignment). If `alz` is absent from the children list → first deployment. `MANAGEMENT_GROUP_ID` is passed as the parent from `cd-template.yaml`.

---

## Mar 02: platform.json Expansion — Iteration 2 Planning

### Current state

`platform.json` is the single source of truth for infrastructure-level config (subscription IDs, location, MG IDs, PLATFORM_MODE). All `.bicepparam` files derive compound resource IDs from these vars via Bicep string interpolation in var blocks — no hardcoded subscription IDs or location strings.

### What's still hardcoded (identified via full scan)

A scan of all `.bicepparam` files found the following values that should move to `platform.json` in iteration 2:

| Value | Current location | Why it varies per tenant |
|-------|-----------------|--------------------------|
| Network address space primary (`10.0.0.0/22`) | `hubnetworking/main.bicepparam` | Every tenant has different IP ranges |
| Network address space secondary (`10.1.0.0/22`) | `hubnetworking/main.bicepparam` | As above |
| P2S VPN address pools (`172.16.0.0/24`, `172.16.1.0/24`) | `virtualwan/main.bicepparam` | Client VPN address space |
| Log retention days (`365`) | `logging/main.bicepparam` | Compliance requirements vary |
| LAW SKU (`PerGB2018`) | `logging/main.bicepparam` | Some tenants use Capacity Reservation |
| Automation Account SKU (`Basic`) | `logging/main.bicepparam` | Tenant preference |
| Deploy Automation Account (`false`) | `logging/main.bicepparam` | Not all tenants need it |
| MG display names (`'Azure Landing Zones'`, `'Platform'`, etc.) | All MG `.bicepparam` files | Tenant branding |
| Wait consistency counters | All MG `.bicepparam` files | Currently inconsistent (platform-security uses 30, others 10/40) — should be one central value |

### Design decision

The principle is: the more that can be edited in `platform.json`, the better. A tenant operator should never need to open a `.bicepparam` file for a standard deployment. Values that are already correctly derived from existing platform.json vars (resource names, RG names) should stay as var-block derivations — moving scalar inputs to platform.json and keeping derivation logic in var blocks is the right split.

The Lunavi blog (`lunavi.com/blog/utilizing-bicep-parameter-files-with-alz-bicep`) independently arrived at the same pattern using a flat `.env` file. Key difference: they pre-build full resource ID strings in the env file. Our approach derives IDs in var blocks from scalar inputs — more maintainable since changing location or naming convention updates one var expression, not dozens of env var strings.

### Planned iteration 2 additions to platform.json

```json
"NETWORK_ADDRESS_SPACE_PRIMARY": "10.0.0.0/22",
"NETWORK_ADDRESS_SPACE_SECONDARY": "10.1.0.0/22",
"P2S_VPN_ADDRESS_POOL_PRIMARY": "172.16.0.0/24",
"P2S_VPN_ADDRESS_POOL_SECONDARY": "172.16.1.0/24",
"LOG_RETENTION_DAYS": "365",
"LAW_SKU": "PerGB2018",
"AUTOMATION_ACCOUNT_SKU": "Basic",
"DEPLOY_AUTOMATION_ACCOUNT": "false",
"WAIT_COUNTER_POLICY_ASSIGNMENTS": "40",
"WAIT_COUNTER_ROLE_ASSIGNMENTS": "40",
"WAIT_COUNTER_DEFAULT": "10"
```

MG display names are lower priority — they could be added as individual keys (`MG_DISPLAY_NAME_ROOT`, `MG_DISPLAY_NAME_PLATFORM`, etc.) but are not needed for functional parity.

---

---

## Mar 02: Iteration 2 Scope

### Context

The platform is built for a consulting company managing a fleet of customer tenants. Each customer gets their own config repo (`alz-mgmt`) while the templates repo is shared across all customers. This MSP model is the primary driver for several iteration 2 decisions — particularly brownfield adoption (consulting companies rarely get greenfield customers) and the tag pinning strategy (breaking changes in templates must not hit all customers simultaneously).

### Architecture

- **Create `alz` MG in bootstrap (`onboard.ps1`)** — enables OIDC plan UAMI to be scoped to `alz` instead of tenant root (least privilege). Cold-start workaround in `cd-template.yaml` and the full MG pre-create step can be removed as a consequence.
- **Scope plan UAMI Reader to `alz`** — currently assigned at tenant root, which is broader than needed. Bootstrap creating `alz` first is the prerequisite for this.
- **Tag templates repo** — `v1.0.0` for iteration 1, `v2.0.0` for iteration 2. All customer config repos pin to a specific tag rather than `@main`. Enables controlled rollout of template updates across the fleet — test on one customer before upgrading the rest.

### platform.json expansion

Move all remaining tenant-specific hardcoded values out of `.bicepparam` files:

```json
"NETWORK_ADDRESS_SPACE_PRIMARY": "10.0.0.0/22",
"NETWORK_ADDRESS_SPACE_SECONDARY": "10.1.0.0/22",
"P2S_VPN_ADDRESS_POOL_PRIMARY": "172.16.0.0/24",
"P2S_VPN_ADDRESS_POOL_SECONDARY": "172.16.1.0/24",
"LOG_RETENTION_DAYS": "365",
"LAW_SKU": "PerGB2018",
"AUTOMATION_ACCOUNT_SKU": "Basic",
"DEPLOY_AUTOMATION_ACCOUNT": "false",
"WAIT_COUNTER_POLICY_ASSIGNMENTS": "40",
"WAIT_COUNTER_ROLE_ASSIGNMENTS": "40",
"WAIT_COUNTER_DEFAULT": "10"
```

MG display names are lower priority but follow the same principle.

### PLATFORM_MODE full

- Formalize multi-subscription platform with connectivity/identity/management/security child MGs as a tested, supported path
- Define the full-mode `platform.json` shape properly (four separate subscription IDs)
- End-to-end test full mode deploy

### Brownfield

Highest priority after architecture. The consulting company's customers almost never start greenfield.

- **Harden `discover.ps1`** — complete stubs: NSG inbound rule inspection, storage public access check, ALZ policy name collision detection against the `.alz_policy_definition.json` library
- **Solve Deployment Stack adoption** — how to bring existing resources under stack management non-destructively. Core challenge: `DeleteAll` stacks will destroy resources they didn't create. Need a safe import path.
- **Fleet scale** — `discover.ps1` should be runnable across multiple tenants in sequence, not just one at a time

### Operational hardening

- Harden `cleanup.ps1` robustness
- Review role definitions — use built-in where possible instead of custom
- ~~Fix `ddosResourceId` unused variable warning in `landingzones/main.bicepparam`~~ — resolved Mar 10, see below

### MSP/fleet model

- Document the one-templates-repo / many-config-repos pattern explicitly in `CLAUDE.md` and `README`
- Define tag pinning strategy — how the consulting company communicates and rolls out template upgrades to customers

---

## Mar 10: Enable-DDoS-VNET Policy — LinkedAuthorizationFailed on Cold Start

### Problem

During Alen's tenant cold-start CD, the `alz-networking-hub` deployment stack failed consistently with:

```
LinkedAuthorizationFailed: The client has permission to perform action
'Microsoft.Network/ddosProtectionPlans/join/action' on scope '.../vnet-alz-swedencentral',
however the linked subscription '00000000-0000-0000-0000-000000000000' was not found.
```

The pipeline retried but failed every time — not a transient error.

### Root Cause

The ALZ policy library ships two `Enable-DDoS-VNET` policy assignments with `effect: Modify` and a placeholder DDoS plan ID:

```
/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/providers/Microsoft.Network/ddosProtectionPlans/placeholder
```

- `lib/alz/platform/connectivity/Enable-DDoS-VNET.alz_policy_assignment.json` — scope: connectivity MG
- `lib/alz/landingzones/Enable-DDoS-VNET.alz_policy_assignment.json` — scope: landingzones MG

When the hub VNets are deployed under `platform-connectivity`, Azure Policy evaluates these assignments and the `Modify` effect attempts to associate the VNet with the placeholder DDoS plan. Since subscription `00000000-0000-0000-0000-000000000000` doesn't exist, ARM rejects the deployment with `LinkedAuthorizationFailed`.

This is distinct from the Feb 21 "ghost parameter" issue (which was a Bicep template-level problem). This is a policy library default that has never been overridden in `alz-mgmt-alen`.

Oskar's tenant did not exhibit this problem because `platform/main.bicepparam` and `landingzones/main.bicepparam` already had `effect: Audit` overrides (added during earlier troubleshooting). Alen's repo was missing these overrides, and `landingzones/main.bicepparam` only overrode `ddosPlan` (not `effect`), leaving `Modify` active with the placeholder ID.

### Fix

Set `effect: Audit` for `Enable-DDoS-VNET` in all three `.bicepparam` files in the tenant config repo:

- `config/core/governance/mgmt-groups/int-root.bicepparam` (safety net — no assignment at this scope currently but future-proof)
- `config/core/governance/mgmt-groups/platform/main.bicepparam` — covers the connectivity-scoped assignment
- `config/core/governance/mgmt-groups/landingzones/main.bicepparam` — covers the landingzones-scoped assignment; `ddosPlan` override commented out since there's no deployed plan

`Audit` was chosen over `Disabled` — the policy still reports non-compliance but doesn't modify resources. When a real DDoS Protection Plan is deployed in the future, change `effect` back to `Modify` and uncomment the `ddosPlan` override with the correct plan resource ID.

### Required action for all tenant config repos

Every tenant repo that doesn't deploy a DDoS Protection Plan must have these overrides. This is now standard in both `alz-mgmt-oskar` and `alz-mgmt-alen`.

---

### Design Note: readEnvironmentVariable() vs. Extendable Params

During a review of the official ALZ Bicep accelerator team's discussion, they described the repetition problem (every `.bicepparam` file must restate `location`, subscription IDs, etc.) and said extendable parameter files — currently experimental — will eventually solve it.

Our platform already solves this today via `readEnvironmentVariable()` + `platform.json` as a single source of truth, exported to env vars by the `bicep-variables` CI action before any Bicep compile step. The approach works because we own the full build environment (GitHub Actions). The ALZ team's broader audience (arbitrary CI/CD setups, local terminal, Cloud Shell) makes a compile-time env var dependency less practical for them as a reference implementation.

---

## Mar 24: Export-BrownfieldState.ps1 — Brownfield Discovery Script

### Purpose

`scripts/Export-BrownfieldState.ps1` scans a portal-deployed Azure Landing Zone tenant and exports its governance and infrastructure state as JSON. Output format mirrors `Export-ALZStackState.ps1` so `Compare-ALZStackState.ps1` can diff brownfield state against an engine-deployed state.

Key difference from the stack-based export: no deployment stacks exist on a portal-deployed tenant, so resources are queried directly via Az PowerShell cmdlets.

### Design notes

- Captures: MG hierarchy, custom policy definitions (with SHA256 rule hash), policy set definitions, policy assignments, custom role definitions, role assignments, resource groups, and key infrastructure resources (LAW, Automation, VNets, Firewalls, DNS zones)
- MG name normalization handles portal accelerator naming conventions (`ALZ-platform`, `ALZ-sandboxes`, etc.) — strips `ALZ-` prefix and normalizes plurals (`sandboxes` → `sandbox`) before matching well-known scope names
- Uses a `Get-PropSafe` helper for all policy object property access — needed because Az.Resources 7.x changed the property structure of `PsPolicyDefinition`, `PsPolicySetDefinition`, and `PsPolicyAssignment` objects (e.g. `Scope` is now a direct property, not nested under `Properties`)
- All `Get-Az*` results wrapped in `@()` to ensure array type and safe `.Count` access in strict mode
- `DiscoveryMode: "brownfield"` field in output distinguishes these exports from stack-based ones

### State snapshots

All state JSON files moved to `state-snapshots/` folder.

### Tested against

Sylaviken tenant (portal-accelerator ALZ, `ALZ-` prefixed MG names, single platform subscription). Export produced 9 governance scopes + 1 infrastructure scope, 283 custom policy definitions, 53 initiatives.

---

## Mar 13: Compare-ALZStackState.ps1 — False Positives Fixed

### Problem

After CD #2 (K5 email-change test on Alen's tenant), `Compare-ALZStackState.ps1` reported 6 stacks as changed instead of the expected 1. All 6 reported "Resource changed" despite having identical policy assignment parameters.

### Root Cause

The script compared full stack resource snapshots using `ConvertTo-Json -Depth 20 -Compress` string equality. PowerShell's `ConvertTo-Json` does not guarantee property ordering — the same object serialized twice can produce different JSON strings if the underlying hashtable iterates in different order. This caused false positives for every stack that was re-exported (new `DeploymentId`) but whose content was identical.

Verified by manually comparing the flagged resources: `Enable-DDoS-VNET` had identical `ddosPlan` and `effect` values in both snapshots; the only difference was JSON property ordering.

### Fix

Replaced the full JSON string comparison with type-aware field-specific comparison:

- **`policyAssignment`**: compare `Parameters` (keys sorted, values serialized) + `EnforcementMode`
- **`policyDefinition`**: compare `PolicyRuleHash`
- **`policySetDefinition`**: compare `PolicyDefinitionCount`

After the fix, re-running the diff on the same snapshot files (`state-alen-baseline.json` vs `state-alen-after-change.json`) correctly reported 1 changed stack (governance-int-root) with exactly 2 parameter changes (`emailSecurityContact` and `actionGroupEmail`) — K5 PASSED.

---

## Mar 13: Iteration 2 — Config Monorepo Architecture Decision

### Context

Iteration 1 used one config repo per tenant (`alz-mgmt-oskar`, `alz-mgmt-alen`). At 2 tenants this is manageable. The target deployment context (Nordlo) operates 20+ tenants. Scaling the multi-repo model linearly — one repo, one set of GitHub environments, one workflow copy per tenant — is operationally impractical.

During iteration 1 evaluation, the ALZ product team's guidance (ALZ Weekly Q&A — Week 10) was reviewed. Their recommendation for subscription vending: single repo, config-file-per-entity, pipeline as orchestrator. The core insight is directly applicable to our layer despite the difference in scope (subscription vending vs. full tenant governance platform vending).

### Decision

Adopt the **compromise monorepo** (Option C): consolidate all tenant config repos into a single `alz-mgmt` repo while keeping the engine repo (`alz-mgmt-templates`) separate.

```
alz-mgmt-templates/        ← engine repo (unchanged)
alz-mgmt/                  ← consolidated tenant config repo
  tenants/
    oskar/config/
      platform.json
      *.bicepparam
    alen/config/
      platform.json
      *.bicepparam
  .github/workflows/
    ci.yaml                 ← single workflow, matrix per affected tenant
    cd.yaml                 ← single workflow, tenant selection parameter
```

### Rationale

A full monorepo (engine + config in one repo) was evaluated and rejected. The engine and config repos change at different rates, for different reasons, by different roles — merging them would require CI to distinguish between template changes (revalidate all tenants) and config changes (validate affected tenant only), adding complexity without meaningful benefit.

The multi-repo model from iteration 1 is not deprecated — it remains the correct choice for strict org-boundary isolation scenarios where a customer requires their config to live in their own GitHub org.

### What changes

- CI: path filtering on `tenants/**`, matrix build from `git diff` to find affected tenant folders
- CD: explicit tenant name parameter; deploy job scopes to `tenants/<name>/config/`, selects the correct GitHub environment and OIDC identity
- `onboard.ps1`: creates a folder + writes `platform.json` instead of creating a full GitHub repo
- `cleanup.ps1`: removes the tenant folder instead of deleting a repository
- GitHub OIDC: environments and federated credentials remain per-tenant, but all live in the single `alz-mgmt` repo — FIC subject claims use environment name to discriminate tenants

### What stays the same

Engine repo, `.bicepparam` format, `readEnvironmentVariable()` pattern, `platform.json` schema, deployment stacks, OIDC identity strategy (per-tenant plan + apply UAMIs), K5 stack state tooling.

### Open question: engine changes triggering config repo CI

`git diff`-based matrix detection works for config changes but not for engine repo changes. When a template is updated in `alz-mgmt-templates`, no change lands in `alz-mgmt` — CI does not auto-trigger. Options: (1) repository dispatch webhook from templates repo to config repo on release tag push, (2) scheduled nightly validation, (3) manual trigger. This is an unresolved CI design problem to address during iteration 2 implementation.

Full trade-off analysis: `docs/iteration2-repo-architecture-tradeoff.md`.

---

## Mar 25: Iteration 2 — Brownfield Tooling Session (Compare-BrownfieldState)

### Context

Late-night session (~01:30–04:00 CET) building and iterating on the offline analysis half of the brownfield integration tooling. Target tenant throughout: Sylaviken — portal-deployed ALZ from April 2024, uppercase MG naming (`ALZ`, `ALZ-platform`, etc.), AMBA deployed alongside standard ALZ, single platform subscription `93ff5894-...`.

### Three-script architecture (established)

The session confirmed a clean three-script separation for brownfield integration, all read-only:

- **`Export-BrownfieldState.ps1`** — live Azure scan, produces a single JSON snapshot of governance (MG hierarchy, policy defs/sets/assignments, RBAC) and infrastructure (resource groups, Log Analytics, Automation Accounts, VNets). Built and tested in a prior session.
- **`Compare-BrownfieldState.ps1`** — offline analysis, takes the export JSON and compares against the engine's ALZ library. Produces a seven-section adoption readiness report. Built and iterated heavily in this session.
- **`discover.ps1`** — live scan, checks subscription resources against ALZ deny policies for compliance risk. Not yet built — next priority.

Operator workflow: `export → compare → discover`. Compare and discover both consume the export snapshot but are independent of each other.

### Iteration history (Compare-BrownfieldState)

**Iteration 1 — Initial build**

Seven-section report: structural overview, policy library comparison, assignment inventory, RBAC summary, infrastructure assessment, config extraction, risk summary. First run against Sylaviken showed 123 non-standard policy definitions — suspiciously high.

**Iteration 2 — AMBA classification**

All 123 "non-standard" definitions were Azure Monitor Baseline Alerts (AMBA), a known supported extension deployed by the portal accelerator. Added AMBA detection via metadata (`_deployed_by_amba == "True"` or `source` containing `azure-monitor-baseline-alerts`). Result: 0 genuinely non-standard definitions, 123 correctly classified as AMBA. Also surfaced `Enforce-Encryption-CMK` as the only genuinely non-standard policy set definition.

**Iteration 3 — Policy rule hash verification**

The 92 "standard" definitions were matched by name only. If the brownfield had an older version the engine would silently overwrite it on deploy without any warning. Added SHA256 hash comparison of the `policyRule` object between the brownfield export and the library JSON files. Initial result: version string comparison showed 5 mismatches, but unreliable because most brownfield definitions lacked version metadata in the export.

**Iteration 4 — Hash normalization**

All 92 showed as mismatches because Azure API responses and library JSON files serialize object properties in different order, producing different hashes for identical policy rules. Fix: added `ConvertTo-SortedObject` recursive deep-sort applied before hashing in both `Export-BrownfieldState.ps1` and `Compare-BrownfieldState.ps1`. Result after normalization: 3 exact matches, 89 genuine rule mismatches.

Verified one manually: `Deny-Subnet-Without-Nsg` — brownfield `SystemDataCreatedAt: 2024-04-17`, version `1.0.0`. Library is `2.0.0` (adds GatewaySubnet/AzureFirewallSubnet exclusions, documented in Enterprise-Scale changelog). All 89 mismatches are real governance drift — the portal accelerator does not auto-update policy definitions after initial deployment.

Notable finding: many definitions show the same version string in both brownfield and library but different hashes — the ALZ team has updated rule logic without bumping version numbers. This proves hash comparison is necessary; version strings alone are insufficient for detecting drift.

**Iteration 5 — Version display fix**

Brownfield version showed as `?` in the mismatch output because the export script was reading `metadata.version` instead of the top-level `Version` property. Fixed export capture and compare display. Output now shows `brownfield=1.0.0  library=2.0.0` cleanly.

**Iteration 6 — Assignment classification fix**

42 assignments were falsely flagged as `[non-std]` because the classification logic extracted the last segment of `PolicyDefinitionId` and looked it up in the custom ALZ definition library. For assignments that reference built-in Azure policies (Microsoft-authored), the last segment is a GUID — not in the library. Examples: `Deny-Classic-Resources`, `Deny-IP-forwarding`, `Deny-Storage-http`, `Deploy-VM-Monitoring`, `Deploy-VM-Backup`.

Fix: loaded `*.alz_policy_assignment.json` files (78 found) as an additional reference set. Assignments are now matched by their own name (`$aName`, last segment of the assignment resource ID) against this set. An assignment is standard if its name is in the ALZ assignment library OR its referenced definition is a known custom ALZ def/set.

Result: only 3 genuinely non-standard assignments remain: `Deploy-ASC-Monitoring`, `Deploy-AKS-Policy`, `Deploy-Log-Analytics`.

### Final report numbers — Sylaviken

**Policy definitions:** 3 standard exact, 89 standard rule mismatch (engine will overwrite on deploy), 0 non-standard, 123 AMBA, 68 deprecated.

**Policy set definitions:** 40 standard, 1 non-standard (`Enforce-Encryption-CMK`), 6 AMBA, 6 deprecated.

**Assignments:** 3 non-standard (`Deploy-ASC-Monitoring`, `Deploy-AKS-Policy`, `Deploy-Log-Analytics`), 5 AMBA, remainder standard.

**Infrastructure:** LAW named `ALZ-law` (engine would deploy `law-alz-swedencentral`), Automation Account `ALZ-aauto` (engine: `aa-alz-swedencentral`). 3 non-ALZ resource groups: `VisualStudioOnline-*`, `rg-copilot-weu`, `NetworkWatcherRG`. Drift detected in LAW references: stale subscription ID `10738f61-...` appearing in some assignment parameters alongside the correct `93ff5894-...`.

**Risk rating:** YELLOW — customizations and version drift present, operator decisions required before stack takeover.

### Key thesis findings

1. Portal-deployed ALZ tenants do not receive policy definition updates automatically. 89 of 92 standard definitions had different policy rule hashes from the library, all at `v1.0.0` from April 2024.
2. Version strings alone are unreliable for detecting policy drift — the ALZ team updates rule logic without bumping version numbers. Hash comparison is necessary.
3. AMBA policies require separate classification. They are a known extension, not tenant-custom policies, and would be massively over-reported as non-standard without explicit handling.
4. Assignment classification must check the ALZ assignment library, not just the referenced definition library. Many standard ALZ assignments reference built-in Microsoft-authored policies, which are not in the custom lib.

**Iteration 7 — Deny-effect risk analysis**

The 89 rule mismatches were all treated equally in the output. A Deny-effect policy rule change can block operations on existing resources (outage risk), while an Audit change is informational only. Operators need to know which mismatches are dangerous before deploying.

Added effect extraction from the library JSON at load time (`Get-PolicyEffect` resolves the default value when the effect is a parameter reference like `[[parameters('effect')]`). Added `Get-IfResourceTypes` to recursively walk `allOf`/`anyOf`/`not` condition trees and extract the resource types the policy evaluates.

Under `-Detailed`, each mismatch is now labelled by effect:
- `[DENY RULE CHANGE]` — shows target resource types, which MG scopes the policy is assigned at, and a hard warning to verify compliance before deploying.
- `[DINE RULE CHANGE]` — medium risk, may trigger remediations on existing resources.
- `[MODIFY RULE CHANGE]` — medium risk, may change resource properties on next evaluation.
- `[APPEND/AUDIT RULE CHANGE]` — low risk.

Section 7 now breaks out the 89 mismatches by effect category. Traffic light is upgraded to RED when any Deny mismatches exist (previously all mismatches → YELLOW).

Sylaviken breakdown: 54 Deny, 18 DINE, 2 Modify, 4 Append, 11 Audit. Risk rating upgraded to RED.

**Iteration 8 — Initiative-aware assignment resolution**

The "assigned at" field in the Deny output was empty for most policies because `$defAssignmentScopes` only tracked direct assignments. Most ALZ policies are deployed via initiatives (policy set definitions), not individual assignments — 46 of 74 assignments in the Sylaviken export reference a policy set, not a policy definition directly.

Fix: at startup, build `$setMemberDefs` from the library `*.alz_policy_set_definition.json` files (set name → list of ALZ custom member definition names, extracted from `properties.policyDefinitions[].policyDefinitionId`). When iterating assignments, expand initiative assignments to all their member definitions and record the scope against each. Deduplicated so a definition that appears in multiple initiatives assigned at the same scope is listed once.

Result: 13 Deny definitions now resolve to real MG assignment scopes (up from 3). The remainder correctly show "no assignments found" — either the initiative containing them isn't assigned in this tenant, or the policy isn't a member of any library initiative.

### Final report numbers — Sylaviken (updated after iterations 7–8)

**Policy definitions:** 3 standard exact, 89 standard rule mismatch (engine will overwrite on deploy), 0 non-standard, 123 AMBA, 68 deprecated.

**Rule mismatches by effect:** 54 Deny, 18 DeployIfNotExists, 2 Modify, 4 Append, 11 Audit/AuditIfNotExists.

**Policy set definitions:** 40 standard, 1 non-standard (`Enforce-Encryption-CMK`), 6 AMBA, 6 deprecated.

**Assignments:** 3 non-standard (`Deploy-ASC-Monitoring`, `Deploy-AKS-Policy`, `Deploy-Log-Analytics`), 5 AMBA, remainder standard.

**Infrastructure:** LAW named `ALZ-law` (engine would deploy `law-alz-swedencentral`), Automation Account `ALZ-aauto` (engine: `aa-alz-swedencentral`). 3 non-ALZ resource groups: `VisualStudioOnline-*`, `rg-copilot-weu`, `NetworkWatcherRG`. Drift detected in LAW references: stale subscription ID `10738f61-...` appearing in some assignment parameters alongside the correct `93ff5894-...`.

**Risk rating:** RED — 54 Deny-effect policy rule changes require resource compliance verification before stack takeover.

### What's next

Build/redesign `discover.ps1` — the compliance risk scanner (live subscription scan against ALZ deny policies). Then test the full three-script workflow end-to-end. These three scripts complete the brownfield integration tooling for iteration 2.

**Iteration 9 — Fix `Get-IfResourceTypes`: `in` operator and ARM expression sentinel**

Two bugs fixed in `Get-IfResourceTypes` in `Compare-BrownfieldState.ps1`:

1. The function only handled `{"field":"type","equals":"..."}` conditions. ALZ uses `{"field":"type","in":[...]}` for multi-type policies (e.g. `DenyAction-DeleteResources`). These fell through and the resource type showed as `(unknown)` in `-Detailed` output. Added an `in`-array branch alongside the existing `equals` branch.

2. When the matched type value is an ARM parameter expression like `[[parameters('resourceType')]`, the raw expression was leaking into the `-Detailed` report. Added a normalization step: any value starting with `[` or containing `parameters(` is replaced with the sentinel string `(parameterized)`.

Non-detailed output is unaffected (these fields only appear under `-Detailed`). Numbers on Sylaviken are unchanged.

---

## Mar 29: Compare-BrownfieldState — Report Quality Pass (PR #158)

### Changes

**Deny mismatch split — assigned vs unassigned**

All 54 Deny-effect rule mismatches were previously treated as equal risk. A mismatch on an unassigned definition has zero operational impact (the definition exists on the tenant but nothing is currently enforcing it). Split the output and the Section 7 risk summary:

- ASSIGNED Deny mismatches (definition is active via a direct or initiative assignment) → `Write-Err`, appear under `── Deny-effect rule changes: ASSIGNED ──` block
- UNASSIGNED Deny mismatches → `Write-Warn`, appear under a separate `── Deny-effect rule changes: UNASSIGNED ──` block

Traffic light now only turns RED for ASSIGNED Deny mismatches. UNASSIGNED-only Deny mismatches produce YELLOW. Section 7 reports `Deny (assigned)` and `Deny (unassigned)` counts separately.

**`-IncludeAmba` switch**

`-Detailed` previously expanded all 123 AMBA definition names into the output — 123 lines of noise on every run. AMBA items are now suppressed in detailed output by default. Added `-IncludeAmba` switch: when combined with `-Detailed`, AMBA and deprecated items are individually listed. Without it, they show as counts only.

**Subscription placement in Deny detail output**

The "subscriptions in scope" field in Deny mismatch detail was a placeholder in the previous session. Now reads from `SubscriptionPlacement` data (captured by Export) and shows actual subscription IDs and display names under each assigned MG scope.

**Section 6 expansion**

Added to the config extraction section:
- Platform subscription mapping: reads `SubscriptionPlacement` to match MG names (management, connectivity, identity, security) to subscription IDs and outputs them as draft `SUBSCRIPTION_ID_*` values for `platform.json`
- Hub networking summary: VNet names, address spaces, Firewall names, Private DNS zone counts — derived from the infrastructure scan

**Export: SubscriptionPlacement collection**

`Export-BrownfieldState.ps1` now collects `SubscriptionPlacement` during the MG hierarchy build step — for each MG ID in the hierarchy it calls the REST API to get directly placed subscriptions and stores them as `MG ID → [{Id, DisplayName}]`. Exported as top-level `SubscriptionPlacement` key in the JSON.

### Sylaviken numbers (unchanged by this PR)

Policy definitions: 3 standard exact, 89 rule mismatch, 0 non-standard, 123 AMBA, 68 deprecated. Rule mismatches by effect: 54 Deny (13 assigned, 41 unassigned), 18 DINE, 2 Modify, 4 Append, 11 Audit. Risk rating: RED (assigned Deny mismatches present).

---

## Mar 30: diff-deny-rules.py — HTML Diff Report (PRs #159, #160, #161)

### Problem

The terminal output identifies WHICH policy rules are changing but not HOW. An operator needing to verify resource compliance before deploying needs to see the actual diff — what changed in the `policyRule.if` block, the `then.details` block, etc.

### Architecture decision: Compare as mismatch authority

Initial prototype of `diff-deny-rules.py` detected mismatches independently using its own normalized text comparison. Ran into a 49-mismatch discrepancy — Python saw 49 DINE mismatches, Compare saw 9. Root cause: PowerShell `ConvertTo-Json` and Python `json.dumps` serialize nested objects differently — property ordering diverges in deeply nested DINE deployment templates, producing different hashes even after sorting.

Decision: make Compare the authority on what is and isn't a mismatch. Python only renders diffs — it receives a JSON file listing every mismatched policy name (with Effect, IsAssigned, Version) from Compare, and looks up the actual rule objects to diff. Eliminates the serialization divergence entirely.

### Tier structure

Four tiers in the HTML report:

| Tier | Condition | Colour |
|------|-----------|--------|
| 1 | Assigned, Deny/DenyAction, rule changed | Red |
| 2 | Assigned, DINE/Modify/Append, rule changed | Yellow |
| 3 | Assigned, no real rule change after normalization | Green note |
| 4 | Unassigned, rule changed | Grey (muted) |

Tier 3 catches cases where Compare's hash detects a difference but normalized text comparison shows identical content — serialization artifact, no action needed. Tier 4 diffs are shown with `opacity: 0.75` so priority ordering is visually clear.

### ARM bracket normalization bug

`[[parameters(` in library JSON (ARM escape) vs `[parameters(` from Azure API. Initially used `re.sub(r'\[\[', '[', text)` (single-pass), which left `[[[parameters(` in DINE policies with nested deployment templates (e.g. `Deploy-Custom-Route-Table`). A three-bracket run `[[[` → first pass replaces `[[` → `[[` → leaving `[[`. Fix: `re.sub(r'\[{2,}', '[', text)` and PowerShell `-replace '\[{2,}', '['` collapse any run of 2+ brackets to one in a single pass. Reduces real mismatch count from 9 to 8 (Deploy-Custom-Route-Table drops out — was a normalization artifact, not a real diff).

### Deprecated-assigned detection in Section 7

68 deprecated policy definitions in Sylaviken. Previously reported as a single count. Added logic to cross-reference the deprecated list against `defAssignmentScopes`: 60 are assigned (via the `Deploy-Resource-Diag` initiative, which still lists the deprecated `Deploy-Diagnostics-*` members). 8 are unassigned.

Section 7 now reports:
- `Deprecated (assigned): 60` with `Write-Warn` + note about engine replacement
- `Deprecated (unassigned): 8` with `Write-Info`
- Under `-Detailed`: each assigned deprecated definition listed with display name and which scope(s) it's assigned at

The 60 "assigned" count is via initiative expansion — the `Deploy-Resource-Diag` initiative is what's actually assigned, and it references all the deprecated diagnostics policies as members. The engine will replace them with the newer `Deploy-Diag-LogsCat` initiative on deploy.

### Final numbers — Sylaviken

Mismatches passed to Python: 8. Tier 1: 1 (Deny, assigned). Tier 2: 1 (DINE, assigned). Tier 3: 0. Tier 4: 6 (unassigned, various effects).

### Housekeeping

Generated output files (`compare-output-detailed.txt`, `deny-diff-report.html`) removed from git tracking and added to `.gitignore`. These are local operator artifacts, not repo content.

---

## Mar 31: Brownfield Tooling — Subscription-Level Governance (Task 1)

### Problem

`Export-BrownfieldState.ps1` only scanned MG-scoped policy assignments. Brownfield tenants commonly have policy assignments scoped directly to subscriptions (e.g. MDFC/Defender plans add assignments at subscription scope automatically). These were invisible to Compare, so a Deny-effect policy assigned at subscription scope would be misclassified as "unassigned" — underreporting active risk.

Policy exemptions also only exist at subscription/resource group level (not MG level) and were not captured at all.

### Export changes

New function `Get-SubscriptionGovernance`:
- Called for **all** subscriptions in `SubscriptionPlacement` — not just platform subs. Landing zone subs are where Deny-effect policies most often affect workloads.
- Collects policy assignments filtered to exact subscription scope (same pattern as MG-level scope filtering)
- Collects policy exemptions via REST `GET /subscriptions/{id}/providers/Microsoft.Authorization/policyExemptions?api-version=2022-07-01-preview` (no clean Az PowerShell cmdlet)
- Exported under new top-level key `SubscriptionGovernance` — backward compatible; older exports that lack this key are handled gracefully in Compare

**Bug fixed during testing:** `SubscriptionPlacement` entries are hashtables (written in-memory during the export run, not deserialized from JSON). `$sub.PSObject.Properties['Id']` doesn't resolve hashtable keys — only works on PSCustomObjects. Fixed to use `$sub -is [hashtable]` + `ContainsKey('Id')` check. Without this fix 0 subscriptions were scanned.

### Compare changes

- Loads `SubscriptionGovernance` from export (graceful fallback to empty array for older exports)
- Builds `subIdToMgId` reverse-lookup from `SubscriptionPlacement` (sub ID → parent MG ID)
- Feeds sub-level assignments into `defAssignmentScopes` using scope name `"sub-{subscriptionId}"` — this fixes the misclassification of sub-scoped Deny assignments as "unassigned"
- New **Section 3b**: per-sub assignment counts with std/non-std/AMBA classification; per-sub exemption listing with Deny-effect exemption flagging (always shown regardless of `-Detailed`)
- Section 7 adds `Subscription-level governance:` block with non-standard assignment count and exemption count; Deny exemptions contribute to `$hasMinorDrift`
- Sub-level counts included in `-OutputFile` JSON report

### Sylaviken findings

Section 3b found:
- Sylaviken Mgmt Sub (`93ff5894-...`): 2 non-standard direct assignments — `DataProtectionSecurityCenter` and `OpenSourceRelationalDatabasesProtectionSecurityCenter` (MDFC/Defender plan auto-assignments, expected noise)
- Sylaviken Corp Sub (`db8f96fe-...`): 1 non-standard direct assignment — same ASC assignment
- 0 policy exemptions across all subs

Section 7: `Non-standard direct assignments: 3`, `Policy exemptions: 0`.

These MDFC assignments are built-in Azure Security Center assignments automatically created when Defender plans are enabled — not ALZ library entries, correct to flag as non-standard.

---

## Apr 06: Brownfield Tooling — Gap Closure Sprint (Gaps 1–7)

### Background

After the initial brownfield tooling was in place (Export, Compare, diff report, subscription-level governance), we did a structured gap analysis and defined 10 discrete gaps between the current tooling and full pre-migration coverage. Each gap was scoped as a self-contained Claude Code task with explicit acceptance criteria.

This entry documents all 7 gaps completed in this sprint. Gaps 8–10 (Defender for Cloud, Tags, Bootstrap Identity) are deferred.

---

### Gap 3: Hub Networking Full State Assessment (PR #164 area)

**Problem**: Export collected VNets, firewalls, PIPs, NSGs, route tables, and private DNS zones but Compare did almost nothing with the data — just listed RGs and LAW naming.

**Export changes**: Added bastion hosts, VPN/ER gateways, firewall policies, DNS private resolvers, DCRs, UAMIs. Hub detection via subnet names (GatewaySubnet, AzureFirewallSubnet).

**Compare changes**: New hub networking assessment subsection in Section 5. Cross-references brownfield hub topology against engine defaults — flags address space mismatches (10.0.0.0/22 brownfield vs 10.20.0.0/16 engine default), flags existing route tables (engine will overwrite next-hop to firewall IP), flags DCR coexistence (engine creates 3 more, existing ones untouched), flags UAMI coexistence. Peering inventory for spoke mapping.

---

### Gap 4: Private DNS Zones & VNet Links (PR #164 area)

**Problem**: Export captured DNS zones but Compare didn't classify them or flag the critical DUPLICATE_RISK case (zone in wrong RG → engine creates a conflicting second zone).

**Export changes**: Added VNet link collection per DNS zone via REST (`/virtualNetworkLinks`). Added `HubLinked` flag per zone.

**Compare changes**: New Private DNS Zone Assessment block in Section 5. Classifies each zone as `DUPLICATE_RISK` (exists but in wrong RG — engine will create a conflicting duplicate), `MATCH` (exists in correct engine RG), `EXTRA` (not in engine defaults — engine won't touch), or `MISSING` (not yet deployed). Flags `HUB_LINKED` zones. Provides operator guidance: move zones to engine RG, or disable engine DNS deployment and manage via policy parameter overrides. Zone duplicate count feeds `$DnsDuplicateRiskCount` → Section 7 + traffic light.

**Testing**: Oskar tenant had 2 DUPLICATE_RISK zones (`privatelink.blob.core.windows.net`, `privatelink.vaultcore.azure.net`) in `rg-alz-conn-swedencentral` instead of engine's `rg-alz-dns-swedencentral`. Correctly flagged.

---

### Gap 5: Resource Locks (PR #165)

**Problem**: Engine deploys configurable `CanNotDelete` or `ReadOnly` locks. Brownfield may already have locks on RGs or resources that would block stack operations.

**Export changes**: REST scan of all resource groups and key resources for `Microsoft.Authorization/locks`. Captures lock name, level (CanNotDelete / ReadOnly), scope.

**Compare changes**: New Resource Lock Assessment block in Section 5. Classifies as `BLOCKING` (ReadOnly — prevents engine writes, deployment will fail) or `CAUTION` (CanNotDelete — blocks stack cleanup/delete operations but not deployments). `BLOCKING` count feeds `$LockBlockingCount` → RED traffic light. Summary in Section 7.

---

### Gap 6: Cost-Incurring Resource Inventory (PR #166/#167)

**Problem**: Engine deploys DDoS plans (~$2944/month), Azure Firewall (~$1386/month), VPN/ER gateways, Bastion — if brownfield already has these and engine creates duplicates, customer pays double.

**Export changes**: None needed — infrastructure scan already collected these resource types.

**Compare changes**: New Section 5b: Cost Risk Assessment. For each cost-incurring resource type, checks if brownfield already has one. If yes, flags the monthly cost and explains the duplicate risk. Calculates worst-case duplicate monthly total. Summary in Section 7; contributes to `$hasMinorDrift`.

---

### Gap 1: Custom RBAC Role Definitions (PR #168)

**Problem**: Engine deploys 5 custom role definitions (e.g. `Subscription-Owner (alz)`) with specific GUIDs and permission sets. Brownfield may have same-named roles under different GUIDs, or same-GUID roles with drifted permissions.

**Export changes**: None needed — `Get-AzRoleDefinition -Custom` already collected role definitions.

**Compare changes**: New ALZ Engine Role Definition Check subsection in Section 4. Loads engine role defs from `lib/alz/*.alz_role_definition.json`. For each engine role: GUID match → check permissions (MATCH or DRIFT), name match under different GUID → NAME_COLLISION, absent → MISSING (safe, engine will create). DRIFT and NAME_COLLISION counts feed Section 7 counters. NAME_COLLISION also contributes to `$hasReviewItems` (YELLOW).

**Testing**: Oskar tenant had all 5 ALZ roles as exact MATCH — expected for engine-deployed tenant.

---

### Gap 2: RBAC Role Assignments & Policy-Driven Managed Identities (this PR)

**Problem**: Engine creates ~20+ cross-MG role assignments for managed identities that back DINE/Modify policy assignments (three `-rbac.bicep` modules). When the engine deploys, it creates NEW managed identities — the old ones' cross-MG role assignments become orphaned. Export didn't capture identity principal IDs. `Get-AzPolicyAssignment` in Az.Resources 7.x does not surface `identity.principalId` on returned PS objects.

**Export changes**:
- REST supplement: `GET {mgScope}/providers/Microsoft.Authorization/policyAssignments?$filter=atScope()&api-version=2024-04-01` to reliably capture `identity.principalId` (Az.Resources PowerShell bug workaround). `api-version=2023-04-01` doesn't exist — returns 400; correct version is `2024-04-01`. Also required `$filter=atScope()` — MG-scope list without filter returns 400.
- `ManagedIdentityPrincipalId` field on every policy assignment record.
- Post-processing: stamps `IsPolicyDriven = true/false` on every role assignment by matching principal IDs against the managed identity set.

**Compare changes**: New Policy-Driven Identity Audit subsection in Section 4. Hardcodes cross-MG RBAC expectations from the three `-rbac.bicep` modules (10 grants). Flags:
- `ORPHAN_RISK` — identity has cross-MG role assignments that will be stranded; outputs exact principal IDs and role assignment resource IDs for cleanup
- `MISSING_RBAC` — expected cross-MG grant absent from brownfield
- `CLEAN` — no policy-driven identities at scope

**Testing**: Oskar tenant showed 9 ORPHAN_RISK items (8 platform-MG assignments → landingzones grants, 1 corp `Deploy-Private-DNS-Zones` → platform grant). 0 MISSING_RBAC — tenant was engine-deployed so all grants present. 92 PAs with identity captured, 189 policy-driven RAs flagged.

---

### Gap 7: Legacy Blueprint Assignments (this PR)

**Problem**: Blueprints (deprecated) were common in early ALZ deployments. Blueprint-assigned resources are locked and can't be modified by deployment stacks. Engine does not manage blueprints.

**Export changes**: New `Get-BlueprintAssignments` function using Blueprint REST API (`/subscriptions/{id}/providers/Microsoft.Blueprint/blueprintAssignments?api-version=2018-11-01-preview`). Scans all subscriptions in `SubscriptionPlacement`. Captures name, blueprintId, provisioningState, lockMode, parameters, resourceGroups. Stored under top-level `BlueprintAssignments` key.

**Compare changes**: New Section 4b: Blueprint Assessment. Detects known ALZ/CAF blueprint name patterns (`caf-foundation`, `caf-migrate`, `eslz`, `azure landing zone`, etc.) and tags as `ALZ_BLUEPRINT`. Flags `AllResourcesReadOnly` lock mode as BLOCKING, `AllResourcesDoNotDelete` as WARN. Per-assignment operator guidance. Blueprint count drives RED traffic light in Section 7 (alongside blocking locks).

**Testing**: No test tenants had blueprint assignments — verified correct `[OK] No blueprint assignments found` output and backward compatibility for exports missing the `BlueprintAssignments` key.

---

### Gaps 8–10: Deferred

- **Gap 8** (Defender for Cloud): Export MDfC plan state per subscription, compare against what engine policies will configure. Deferred — lower migration risk than gaps 1–7.
- **Gap 9** (Tags): Capture existing tag schemas, flag conflicts with engine tag parameters. Deferred — informational only, no deployment blocker.
- **Gap 10** (Bootstrap Identity): Verify UAMI, FIC, GitHub environment state matches what `onboard.ps1` creates. Deferred — only relevant at onboarding time, not mid-migration.

---

## Apr 07: Brownfield Tooling — Gaps 9–10, ARM Normalization Fix, Parallel Deployment Reframe

### Gap 9: Tag Schema Assessment (PR #173)

**Problem**: Brownfield tenants commonly enforce tagging via Azure Policy. The engine ships its own `parTags` parameter that gets applied to all engine-deployed resource groups. Without knowing which tag keys the existing environment enforces, operators can't correctly set `parTags` — they'd either miss required tags (causing non-compliance on engine-deployed RGs) or add redundant ones.

**Export changes**: None needed — resource groups captured by the existing infrastructure scan already include tags.

**Compare changes**: New Section 5d: Tag Schema Assessment. Scans tag keys across all tagged resource groups in the infrastructure scope. Keys appearing on ≥80% of tagged objects are classified as "mandatory." Cross-references against known ALZ tag enforcement policy assignment name patterns to distinguish policy-enforced keys from organically applied ones. Section 6 config extraction gains a `parTags` block with discovered mandatory keys and sample values.

---

### Gap 10: CI/CD Identity & Bootstrap State Assessment (PR #174)

**Problem**: Before running the engine, operators need to know which high-privilege service principals have Owner/Contributor at the int-root MG scope, whether a prior `onboard.ps1` run has already created UAMIs, and whether a WhatIf custom role exists. Without this, they cannot plan identity decommissioning or detect double-bootstrap.

**Export changes**: New `Get-HighPrivilegeIdentities` function — REST call to list Owner + Contributor role assignments at the int-root MG scope (`atScope()` filter). Stored under top-level `HighPrivilegeIdentities` key.

**Compare changes**: New Section 4c: CI/CD Identity Assessment.
- Lists all Owner/Contributor principals at int-root scope with type classification: `ServicePrincipal` (likely CI/CD pipeline identity — flag for decommissioning after engine OIDC is validated), `User`/`Group` (should be least-privileged post-migration).
- Detects existing bootstrap UAMIs (`id-alz-mgmt-*-plan/apply-*` pattern) in the infrastructure scope — indicates a prior `onboard.ps1` run or an existing engine bootstrap that will be overwritten.
- Detects existing WhatIf custom role (any role containing `deployments/whatIf/action`) in MG-scope role definitions.
- Per-identity operator guidance: plan decommissioning after engine OIDC is validated, not before.

**Also in this PR — ARM bracket normalization fix**: Changed single-pass `\[\[ → [` to `\[{2,} → [` in both the `Export` hashing and `Compare` hashing. The original single-pass left `[[[` in DINE policies with nested ARM templates (e.g. `Deploy-Custom-Route-Table`), producing spurious rule hash mismatches. The fix collapses any run of 2+ opening brackets to one in a single pass. Effect: Sylaviken's real mismatch count drops from 9 to 8 (one of the 9 was a normalization artifact).

**Also in this PR — diff-deny-rules.py Tier 4 improvement**: Unassigned Deny mismatches (Tier 4) now render as unified diff cards instead of a compact table. Clickable TOC anchors added. Cards rendered at `opacity: 0.75` to visually deprioritize unassigned items while keeping them accessible.

---

### Parallel Deployment Reframe (feat/compare-parallel-deployment-reframe)

After the gap closure sprint, we re-examined the fundamental framing of the Compare report. The original report was written assuming **in-place takeover**: the engine deploys into the existing MG hierarchy and takes over management of existing resources. Every risk item was framed as a "blocker before deploying the engine."

The actual migration strategy is **parallel deployment**: the engine always deploys a fresh hierarchy alongside the existing one. Subscriptions are migrated one at a time after validation. The existing hierarchy is never the engine's deployment target — it continues running unchanged until decommissioned.

This changes the risk model entirely. Almost nothing blocks the engine deployment itself. Risk materializes at **subscription move time**, not at engine deploy time.

**Changes to `Compare-BrownfieldState.ps1`**:

- **Mode banner**: Two `[INFO]` lines added after the header (Export/Library/Tenant lines) establish the parallel deployment framing before any section output.
- **Section 4 ORPHAN_RISK**: `[ERROR]` → `[WARN]`. Text changed from "will be stranded after migration" to "will need cleanup during decommissioning." Managed identities in the old hierarchy remain functional until the old hierarchy is removed — this is a decommissioning task, not an engine deployment blocker.
- **Section 5 locks**: BLOCKING downgraded from `Write-Err` to `Write-Warn`. All lock guidance changed from "remove before running the engine" to "old hierarchy — does not affect parallel engine deployment, review during decommissioning." ReadOnly locks on old-hierarchy RGs are irrelevant — the engine deploys its own RGs in the new hierarchy.
- **Section 5 DNS DUPLICATE_RISK**: Options reordered. Option A is now "deploy engine to a different connectivity subscription" — if the engine uses a different subscription, there is no DNS zone name conflict at all. Original options (move zones, disable deployment) are now B and C.
- **Section 5b cost risk**: Framing changed from "duplicate risk" to "transitional cost." The engine deploying a new DDoS plan or VPN gateway alongside an existing one is intentional in parallel mode — not an accident. `[COST]`/`[OK]` → `[INFO]`; "worst-case duplicate cost" → "estimated transitional cost during migration"; per-type override guidance and the `$costOverrides` variable removed (overriding to reuse existing resources is not the parallel model pattern).
- **Section 6 config extraction**: Framing changed from "starting point for platform.json" to "reference values, not overrides." The engine deploys its own resources; these values inform configuration of the new hierarchy, not collision avoidance.
- **Section 7 summary**: ORPHAN_RISK display downgraded to `Write-Warn`. Locks display changed from `Write-Err` to `Write-Warn`. Cost line changed from `Write-Warn` to `Write-Info` with "transitional" framing. Networking cost line reframed from "cost-duplicate risk" to "transitional cost." Duplicate subscription-level governance block removed.
- **Traffic light**:
  - RED triggers only on: DNS same-subscription conflicts (engine cannot deploy cleanly without resolving these) and active blueprint assignments (governance conflict at subscription move time). Deny-effect mismatches and resource locks removed from RED.
  - YELLOW gains Deny-effect mismatches. New YELLOW message: "Engine deployment is safe. Review these items before moving subscriptions: a) verify subscription workloads comply with new hierarchy Deny policies, b) plan decommissioning of old hierarchy resources, c) clean up orphaned managed identities."
  - `$hasMinorDrift` gains `$LockBlockingCount` so blocking locks still contribute to at least YELLOW.
  - RED title is conditional: "DNS zone conflicts..." when DNS triggers it, fallback generic message when only blueprints trigger it.

---

### Platform Subscription Strategy in Parallel Deployment

A conceptual clarity issue surfaced during the reframe work: when the engine deploys a new hierarchy and operators begin migrating subscriptions, **platform subscriptions are the highest-stakes moves**.

Existing platform subscriptions — especially the connectivity subscription — contain resources that may not comply with the engine's Deny-effect policies. Moving such a subscription into the new ALZ hierarchy triggers policy evaluation. If the hub VNet has subnets without NSGs, or the DDoS policy is still in Modify mode with a stale plan ID, the evaluation will fail or silently modify resources.

**Two paths forward, each with clear tradeoffs**:

1. **Create fresh platform subscriptions**: Cleanest option. Engine deploys its hub VNet, LAW, and other platform resources into new subscriptions. Old platform subscriptions remain under the old hierarchy until decommissioning. No compliance risk at move time. Cost implication: two sets of platform resources run in parallel during the transition — intentional and framed explicitly as transitional cost in the updated Compare report.

2. **Reuse existing platform subscriptions**: Move the existing connectivity/management/identity subscriptions into the new hierarchy. Requires a pre-migration compliance pass: every resource in the subscription must satisfy the new hierarchy's Deny policies before the subscription is moved. For connectivity this means verifying NSGs on all subnets, setting the DDoS policy effect to Audit (or pointing it at a real plan), and ensuring no disallowed public IPs exist on non-firewall resources. The Compare report surfaces which Deny-effect policies are changing — the planned `discover.ps1` (compliance pre-check against live subscription resources) is the instrument for the subscription-level compliance verification step.

**Implication for tooling**: The Compare report's updated YELLOW guidance now explicitly lists "verify subscription workloads comply with new hierarchy Deny policies" as item (a) before moving any subscription. The report does not yet distinguish between platform subscriptions (higher risk — contain infrastructure the engine will also deploy) and landing zone subscriptions (lower risk — workload-only, no overlap with engine-managed infrastructure). Making this distinction visible is a planned improvement to `discover.ps1`.

---

## Apr 11: Brownfield Tooling — In-Place Takeover Reframe & Section 7 Restructure

### In-Place Takeover Reframe (feat/in-place-takeover-scripts)

After further analysis of the actual migration strategy, we reversed the parallel deployment reframe from Apr 7. The correct model for this project is **in-place takeover**: the engine deploys directly against the existing MG hierarchy, Deployment Stacks take ownership of engine-defined resources (policy defs, sets, assignments, role defs), and all existing infrastructure (LAW, hub VNet, firewall, DDoS plan, DCRs, UAMIs) is kept in place. Operators pass existing resource IDs as override parameters — no parallel resources are created, no transitional cost.

This changes the risk model again. Conflicts now materialise **at engine deployment time**, not at subscription move time:
- Resource locks on resources the engine modifies block deployment directly.
- Deny-assigned policy mismatches are active blockers (policy fires immediately on engine-deployed resources).
- There is no "duplicate cost" concept — the engine never creates parallel copies of platform infrastructure.
- DNS zone conflicts don't exist — the operator simply sets `privateDnsSettings.dnsResourceGroupId` to the existing DNS RG; the engine manages the zones in-place.

**Changes to `Export-BrownfieldState.ps1`**:
- `DiscoveryMode` output value changed from `'brownfield'` to `'in-place-takeover'`.
- All user-facing text (SYNOPSIS, DESCRIPTION, output messages) translated to Swedish. Variable and function names remain English.

**Changes to `Compare-BrownfieldState.ps1`**:

- **Strategy banner**: Header changed to "ALZ In-Place Takeover — Jämförelserapport"; strategy line reads "engine tar över befintlig MG-hierarki".
- **Section 5b removed**: Entire Cost Risk Assessment section (~50 lines) deleted. Variables `$script:NetworkingRiskCount`, `$script:DnsDuplicateRiskCount`, `$script:CostRiskWorstCase` removed. There is no concept of running old and new resources simultaneously in in-place.
- **Section 5 networking — [COST] → [OVERRIDE]**: Each discovered hub network resource (LAW, hub VNet, firewall, firewall policy, DDoS plan, DCR, UAMI) now prints `[OVERRIDE]` with its full Resource ID and a note about which parameter to set in the tenant config repo. No cost warnings, no `$script:NetworkingRiskCount` increments.
- **Section 6 DNS**: Replaced MATCH/DUPLICATE_RISK/EXTRA/MISSING classification with ENGINE-zon/ANPASSAD inventory. All discovered DNS zones are shown as informational. At the end of the zone list, the script extracts the distinct DNS resource group(s) and prints them as the value to set for `privateDnsSettings.dnsResourceGroupId`. Instruction: "vid in-place hanterar engine:n zonerna i befintlig RG — inga duplikat skapas."
- **Lock messaging**: BLOCKING message changed from "does not affect parallel engine deployment — review during decommissioning" to "blockerar engine-deployment direkt vid in-place — åtgärd: ta bort låset eller exkludera resursen före deployment."
- **ORPHAN_RISK**: Removed "old hierarchy decommissioning" framing. New text: "cross-MG-rolltilldelningar föräldralösa när engine skapar nya managed identities — befintliga identiteter kan rensas bort efter att engine är deployed."
- **Section 4c CI/CD**: Removed "decommissioning old hierarchy" framing from service principal guidance.
- **Traffic light**: RED condition now includes Deny-assigned mismatches (not just blueprints and blocking locks). DNS conflict removed from RED (no longer a risk in in-place). All text in Swedish.
- **All output text in Swedish**: User-facing strings in all `Write-*` calls translated.

---

### Section 7 Restructure (same branch)

Section 7 was restructured into two clearly separated blocks to match the in-place model's distinction between what the engine owns and what it ignores.

**Block 1 — Inom engine-scope (påverkas vid deploy)**

Covers everything that Deployment Stacks will manage. Displayed with full severity (OK/WARN/ERR). Each subsection:
- **Policydefinitioner**: Exakt match count + regelavvikelse count; if avvikelser > 0, breakdown per effect (Deny assigned/unassigned, DINE, Modify, Append, Audit).
- **Policysetdefinitioner**: Exakt match count (set mismatches are not classified separately — noted inline).
- **Policy assignments**: Count of assignments referencing engine-library policies (standard refs). Note that parameter/enforcement mode comparison is not automated.
- **Rolldefinitioner**: MATCH / DRIFT / NAME_COLLISION / SAKNAS as separate lines (computed inline from `$script:RoleDefCheckResults`; added `$rdMatchCount` and `$rdMissingCount` computed variables in Section 7 instead of adding new script-level counters).
- **Blueprint-tilldelningar**: Count, MÅSTE tas bort if > 0.
- **Resurslås**: X BLOCKERAR / Y VARNING / Z totalt.
- **Cross-MG RBAC**: ORPHAN_RISK and MISSING_RBAC counts.

**Block 2 — Utanför engine-scope (rörs ej av engine)**

Inventory of resources that exist in the tenant but are never touched by the engine. Neutral `Write-Host` formatting — no OK/WARN/ERR severity. Listed items: non-standard policy defs, non-standard policy sets, AMBA defs, AMBA sets, deprecated defs, deprecated sets, non-standard assignments, custom (non-ALZ) role defs, non-ALZ resource groups, non-standard subscription-level assignments.

**Traffic light — based only on Block 1**:
- **RED**: blueprints OR blocking locks OR Deny-assigned mismatches. Each blocker type prints a specific action line.
- **YELLOW**: DINE/Modify mismatches, role DRIFT, NAME_COLLISION, ORPHAN_RISK, DenyUnassigned, Append mismatches, caution locks, MISSING_RBAC. Per-item action lines only for items that are present.
- **GREEN**: no mismatches within Block 1 at all; AMBA note printed if AMBA stack detected (informational only).

Block 2 items (non-standard, AMBA, deprecated, custom roles) no longer influence the traffic light colour.

**`$totalStdAssignments`** added to the aggregation loop — previously only non-standard and AMBA assignment counts were tracked; now standard (engine-library-referencing) assignment count is also available for Block 1 display.

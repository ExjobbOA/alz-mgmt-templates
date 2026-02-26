# Brownfield Integration Guide

> How to bring an existing Azure environment (ClickOps or otherwise drifted) under platform management.

## Mental Model: It's a Merge Conflict

Brownfield integration is structurally identical to resolving a merge conflict in git.

| Git | Azure Brownfield |
|-----|-----------------|
| `git diff` | Discovery script — what exists vs what the platform expects |
| Merge conflict | Drift between ClickOps reality and reference architecture |
| Conflict markers `<<<<` / `>>>>` | Per-resource delta: "exists in Azure but not in template" / "in template but doesn't exist yet" |
| Resolve by accepting ours / theirs / both | Reconciliation decision: adopt as-is, replace, or exclude from platform scope |
| `git add` after resolving | Config alignment — updating `.bicepparam` to reflect accepted reality |
| Clean merge commit | `DetachAll` → `DeleteAll` transition: environment now under platform control |

The discovery script's job is `git status` before the merge — surface everything that's in Azure but not captured in code, so the operator makes a conscious decision on each conflict before a single deployment runs. Deploying without this is the equivalent of blindly accepting "theirs" on every conflict: fast, but you will lose things that only existed in the working tree.

The analogy holds in the hard cases too. A tenant whose MG hierarchy is fundamentally different from ALZ is like two branches that have diverged so far the merge is no longer meaningful — you're choosing between rebase (migrate to ALZ structure, disruptive) or a new branch from scratch (fork the templates, maintainability cost).

---

## The Problem

This platform is designed greenfield-first: `ActionOnUnmanage=DeleteAll`, the ALZ management group hierarchy assumed to not exist yet, and What-If running against empty scopes. A brownfield tenant — one set up manually through the portal, or that ran partial ALZ deployments, or that has evolved away from the reference architecture — breaks every one of these assumptions.

---

## Categories of Drift

### 1. Structural drift — MG hierarchy doesn't match ALZ

The `alz-empty` pattern creates the canonical ALZ hierarchy:

```
Tenant Root
└── alz (intermediate root)
    ├── platform
    │   ├── platform-connectivity
    │   ├── platform-identity
    │   ├── platform-management
    │   └── platform-security
    ├── landingzones
    │   ├── landingzones-corp
    │   └── landingzones-online
    ├── sandbox
    └── decommissioned
```

If the tenant has a different structure:
- **MGs with different names** → template creates parallel MGs; old ones stay as orphans
- **Missing child MGs** → safe, template creates them
- **Extra MGs outside the template** → Deployment Stacks don't manage MGs directly, so they stay; but subscriptions inside may get moved if the template targets them

### 2. Policy drift — extra or conflicting policy assignments

Manually assigned policies at any scope conflict with what the platform assigns. `Modify`-effect policies are the most dangerous — they can shadow or override platform assignments silently, or reference deleted resources (the DDoS ghost problem is an example of this).

### 3. Subscription placement drift — subscriptions in wrong MGs

The governance templates move subscriptions into their designated MGs. If prod workloads are in the wrong MG they will inherit new policy assignments on move — potentially breaking compliance posture or triggering `Deny` effects on existing resources.

### 4. Networking drift — existing hub VNet, gateway, or peerings

The hub networking template owns the hub VNet. If a VNet already exists with different address space, peerings, or subnets, the Deployment Stack will try to reconcile it. With `DeleteAll`, peerings to spoke VNets would be deleted.

### 5. RBAC drift — extra role assignments

Usually safe to leave in place. The platform adds its own RBAC; extras are additive. Dangerous only if something in the existing environment depends on an assignment that the platform would explicitly remove.

---

## Integration Phases

### Phase 0 — Discovery (read-only, touch nothing)

Audit what exists before any deployment. Key things to capture:

```powershell
# MG hierarchy
Get-AzManagementGroup -Recurse -Expand | ConvertTo-Json -Depth 10

# Policy assignments at each scope
Get-AzPolicyAssignment -Scope "/providers/Microsoft.Management/managementGroups/<root-mg-id>"

# Custom role definitions
Get-AzRoleDefinition | Where-Object IsCustom | Select-Object Name, Id, Description

# Existing Deployment Stacks (if any prior ALZ attempt)
Get-AzManagementGroupDeploymentStack -ManagementGroupId "<root-mg-id>"

# Existing networking resources in connectivity subscription
Set-AzContext -Subscription "<connectivity-sub-id>"
Get-AzVirtualNetwork | Select-Object Name, Location, AddressSpace
Get-AzVirtualNetworkGateway | Select-Object Name, Location
```

Document the delta between reality and what the platform expects.

### Phase 1 — Bootstrap (always safe)

`scripts/onboard.ps1` is safe for brownfield. It creates new identity resources (UAMI, FICs) and GitHub environments. Run it normally — it does not touch MGs, policies, subscriptions, or networking.

See [scripts/README.md](scripts/README.md) for prerequisites and usage.

### Phase 2 — Config alignment

Update `config/platform.json` and the relevant `.bicepparam` files in the tenant config repo to reflect the existing environment:

- Set correct subscription IDs for management, connectivity, identity, security
- If their intermediate root MG name isn't `alz`, set `INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID` to match
- For networking: adjust address spaces, gateway SKUs, and region config in `hubnetworking/main.bicepparam` to match existing resources (so What-If shows no change rather than a destructive replace)

The goal: What-If should show minimal or zero changes on uncontested resources before you deploy anything.

### Phase 3 — Staged deployment with `DetachAll`

**This is the critical difference from greenfield.** First runs must use `DetachAll`, not `DeleteAll`.

In `cd.yaml`, override the `actionOnUnmanage` input when triggering the workflow:

```yaml
# When manually dispatching CD for brownfield adoption
actionOnUnmanage: DetachAll   # don't delete drift, just stop managing unrecognized resources
```

With `DetachAll`:
- Resources in the Bicep template get created or updated normally
- Resources that exist in Azure but aren't in the template are **detached** (left in place, no longer stack-managed)
- Nothing is deleted that the platform didn't explicitly create

This lets the platform adopt the environment without destroying anything it didn't create.

### Phase 4 — Remediate drift

With What-If output from Phase 3, assess each drift item:

| Drift | Option A | Option B |
|-------|----------|----------|
| Different MG names | Rename (manual, then platform manages) | Accept and configure `INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID` |
| Extra policy assignments | Leave (DetachAll ignores them) | Remove manually if they conflict |
| Subscription in wrong MG | Accept the move (test policy impact first) | Exclude from platform scope |
| Networking address space mismatch | Align config to reality | Migrate VNet (high risk) |
| Custom RBAC | Leave in place | Consolidate into platform role defs |

### Phase 5 — Switch to `DeleteAll`

Once the environment is stable and all drift is either reconciled or explicitly excluded from the platform scope, switch stacks to `DeleteAll` to enforce the platform going forward. This is the steady-state operating mode.

---

## What the Platform Currently Lacks for Brownfield

The platform as-is hardcodes `ActionOnUnmanage=DeleteAll` in `bicep-deploy/action.yaml`. To properly support brownfield you would need:

1. **A `brownfieldMode` input on `cd.yaml`** — switches all stacks to `DetachAll` for the duration of the adoption phase
2. **A What-If-only CD run** — triggers all What-If steps without deploying, to get a full diff across all scopes before committing
3. **Per-scope `actionOnUnmanage` override** — e.g. conservative (`DetachAll`) on networking, strict (`DeleteAll`) on governance

---

## The Policy Blind Spot

Policy-related resources are the most dangerous category of "uncommitted working tree changes" — they exist only in Azure, are rarely documented, and are silently deleted by `DeleteAll` stacks without any warning.

### What can disappear

**Custom policy definitions** at the tenant root or child MGs. The governance stack deploys the ALZ policy library. If the tenant has custom definitions with the same name, ARM overwrites them. Different names: they get detached or deleted depending on stack mode.

**Custom policy assignments** on MGs or subscriptions not covered by the template. Any manually assigned policy at any scope inside the stack's management boundary is removed by `DeleteAll`.

**Policy exemptions** — the most invisible risk. An exemption was created to allow a resource that would otherwise be non-compliant. It's not scoped to a deployment, it's not in any parameter file, and no one thinks to audit it. It disappears silently, the resource becomes non-compliant, and depending on the policy effect, it may be blocked or modified on the next ARM operation.

**Initiative assignments with custom parameters** — if someone tuned an initiative's parameters (e.g. pointed a DINE policy at a specific Log Analytics workspace), that configuration lives only in the assignment object in Azure. The platform will replace it with its own defaults.

### Why this is worse than other drift

With networking or RBAC drift, the impact is usually visible immediately (something stops working). With policy drift, the impact is delayed: the resource still exists, it just loses its governance guardrails. You won't know until an audit, a compliance report, or a production incident reveals that a `Deny` policy that was supposed to block public endpoints was quietly removed during platform adoption.

### What the discovery script must capture

Before any deployment, the discovery phase must enumerate at every relevant scope:

```powershell
# All policy assignments (including manual ones not in the template)
Get-AzPolicyAssignment -Scope $mgScope -WarningAction SilentlyContinue

# All custom policy definitions
Get-AzPolicyDefinition -Custom -ManagementGroupName $mgId

# All policy exemptions — these are almost never audited
Get-AzPolicyExemption -Scope $mgScope

# All initiative (policy set) assignments
Get-AzPolicySetDefinition -Custom -ManagementGroupName $mgId
```

Each of these that doesn't have a corresponding entry in the platform templates is an unresolved conflict. The operator must decide: capture it in code, accept that it disappears, or block the deployment until it's resolved.

> Note: the discovery phase does not prevent deletions — it prevents *silent* deletions. An operator may look at a legacy exemption and consciously decide to let it go. That's fine. The problem being solved is unknowing loss, not loss itself.

---

## The Unsolvable Cases

**Structural MG hierarchy that is fundamentally different from ALZ** is the hardest scenario. If the tenant's MG structure cannot be mapped to the ALZ canonical hierarchy, there are only two options:

1. **Migrate to ALZ structure** — phased, disruptive, requires subscription moves and policy reassignment. High risk for production environments.
2. **Fork the templates** — create a variant of the governance templates that matches their structure. Maintainability cost: you diverge from the upstream ALZ library and must reconcile updates manually.

Neither is automated. Both require a human architectural decision before any tooling can help.

---

## Quick Reference: Brownfield vs Greenfield

| | Greenfield | Brownfield |
|--|--|--|
| `ActionOnUnmanage` | `DeleteAll` | `DetachAll` → `DeleteAll` after stabilization |
| What-If scope | Empty (skip if MG missing) | Existing environment (will show changes) |
| Subscription moves | Assumed safe | Audit policy impact first |
| Networking | Create fresh | Align config to reality before deploying |
| Bootstrap | Always safe | Always safe |
| Time to steady state | One CD run | Phases over days/weeks depending on drift severity |

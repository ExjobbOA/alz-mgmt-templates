# Brownfield Tooling — Feature Plan

Three features to extend the brownfield export and compare tooling.

---

## Task 1: Subscription-level policy assignments and exemptions

**Status:** In progress

### Problem
Export only scans MG-scoped policy assignments. Brownfield tenants commonly have assignments and
policy exemptions scoped directly to subscriptions. These are invisible today, meaning:
- The `defAssignmentScopes` reverse-lookup in Compare is incomplete (a Deny-effect def could be
  assigned at subscription scope — but Compare doesn't know, so it reports it as "unassigned")
- Sub-level exemptions that bypass governance are never surfaced

### Export-BrownfieldState.ps1 changes

New function `Get-SubscriptionGovernance([string]$SubscriptionId, [string]$DisplayName)`:
- Set-AzContext to the sub, error out gracefully with Write-Warn if it fails
- Policy assignments: `Get-AzPolicyAssignment -Scope /subscriptions/{id}` — filter to those
  whose scope equals exactly `/subscriptions/{id}` (same pattern as MG-level filtering)
- Policy exemptions: REST GET `GET /subscriptions/{id}/providers/Microsoft.Authorization/
  policyExemptions?api-version=2022-07-01-preview` via `Invoke-AzRestMethod` (no clean cmdlet)
- Returns object: `{ SubscriptionId, DisplayName, PolicyAssignments[], PolicyExemptions[] }`

Call site: after the existing "Collecting subscription placement" step, iterate over
**all** subscriptions in `$Script:SubscriptionPlacement.Values` (flat list of `{Id, DisplayName}`
objects). Not just platform subs — landing zone subs are where Deny-effect policies bite.

New export key `SubscriptionGovernance`: array of the above objects, added to the exported JSON
alongside `Scopes` and `SubscriptionPlacement`.

New step header: `Scanning subscription-level governance` — consistent with existing style.

### Compare-BrownfieldState.ps1 changes

1. **Load** `SubscriptionGovernance` from the export (gracefully handle missing — older exports).

2. **Feed into `defAssignmentScopes`** — for each sub-level assignment, call
   `Add-DefAssignmentScope` with:
   - `ScopeName` = `"sub-{subscriptionId}"`
   - `ManagementGroupId` = the MG that has this subscription in `SubscriptionPlacement`
     (reverse-lookup: iterate `mgSubscriptions` to find which MG contains this sub ID)
   This happens right after the existing MG-level `defAssignmentScopes` population loop, before
   any classification code runs.

3. **New Section 3b**: `Subscription-Level Assignments & Exemptions`
   - Per-sub: count of direct assignments (with same std/non-std/AMBA classification as Section 3)
   - Per-sub: list of exemptions with category (Waiver / Mitigated), which assignment they exempt,
     and Write-Warn for any exemption that covers a Deny-effect policy
   - Only emits output if at least one sub has data

4. **Section 7 risk summary** additions:
   - `Sub-level non-standard assignments: N`
   - `Policy exemptions: N total  (X Deny-effect exemptions — review)`
   - Deny-effect exemptions bump traffic light to at least YELLOW

### JSON shape for `SubscriptionGovernance`

```json
"SubscriptionGovernance": [
  {
    "SubscriptionId": "xxxxxxxx-...",
    "DisplayName": "my-landing-zone-sub",
    "PolicyAssignments": [
      {
        "ResourceId": "/subscriptions/.../policyAssignments/...",
        "Type": "policyAssignment",
        "DisplayName": "...",
        "PolicyDefinitionId": "/providers/Microsoft.Authorization/...",
        "Parameters": { ... },
        "EnforcementMode": "Default",
        "Identity": null,
        "Scope": "/subscriptions/..."
      }
    ],
    "PolicyExemptions": [
      {
        "ResourceId": "/subscriptions/.../policyExemptions/...",
        "Name": "...",
        "DisplayName": "...",
        "ExemptionCategory": "Waiver",
        "PolicyAssignmentId": "/providers/Microsoft.Management/...",
        "PolicyDefinitionReferenceIds": ["..."],
        "Scope": "/subscriptions/..."
      }
    ]
  }
]
```

---

## Task 2: Compliance pre-check for Deny-effect mismatches

**Status:** Planned

### Problem
Compare tells the operator "verify resources of this type comply before deploying" but doesn't
check for them. The operator has to manually figure out what's in scope.

### Compare-BrownfieldState.ps1 changes

New switch parameter: `-ComplianceCheck`

When enabled, after Section 7, run **Section 8: Compliance Pre-Check**:
1. For each assigned Deny-effect StandardMismatch (from `$script:AllStdMismatchDefList` where
   `IsAssigned = true` and `Effect` is Deny/DenyAction):
   - Get target resource types from `$libPolicyDefs[$name].TargetResourceTypes`
   - Get subscriptions in blast radius via `Get-SubsUnderMg` over the def's assignment scopes
   - Skip types that are `(parameterized)` with a Write-Warn
2. Resource count query — prefer `Search-AzGraph` (single cross-sub call), fall back to
   per-sub `Get-AzResource -ResourceType $type`
3. Report: `Write-Err` if count > 0, `Write-Ok` if 0

Requires live Az context — error early with a clear message if not connected.
Results are included in `-OutputFile` JSON and in the `-DiffReport` HTML if both are specified.

---

## Task 3: What-if dry-run

**Status:** Planned

### Problem
No local dry-run between "read the Compare report" and "trigger GitHub Actions deploy."

### New script: `scripts/Invoke-ALZWhatIf.ps1`

**Read-only.** Does NOT modify any files.

Parameters:
- `-EngineRoot` — path to templates repo root (defaults to `$PSScriptRoot/..`)
- `-ConfigRoot` — path to the config repo root containing `config/` and `platform.json`
- `-ConfigFile` — path to `platform.json` (defaults to `$ConfigRoot/config/platform.json`)
- `-Scope` — optional: run what-if for a single scope only
- `-OutputFile` — optional JSON output

**Scope table** (read from the same logic as the cd-template.yaml — hardcoded in the script as
a static map, not by parsing YAML):

| Scope name | Template path (relative to EngineRoot) | Params path (relative to ConfigRoot) | Deploy type | MG target |
|---|---|---|---|---|
| governance-int-root | templates/core/governance/mgmt-groups/int-root/main.bicep | config/core/governance/mgmt-groups/int-root.bicepparam | managementGroup | (root MG from platform.json) |
| governance-landingzones | templates/core/governance/mgmt-groups/landingzones/main.bicep | config/core/governance/mgmt-groups/landingzones/main.bicepparam | managementGroup | landingzones |
| ... (all scopes from cd-template.yaml) |

**Execution per scope:**
1. Check target MG exists — skip with Write-Warn if not (cold-start safety)
2. Load env vars from `platform.json` (same as `bicep-variables` action)
3. Build the `.bicepparam` file via `az bicep build-params` with env vars set in process scope
4. Run `New-AzManagementGroupDeployment -WhatIf -WhatIfResultFormat FullResourcePayloads` or
   `New-AzSubscriptionDeployment -WhatIf` depending on deploy type
5. Collect and summarize: new / modified / deleted resource counts
6. Flag destructive changes: deletions and property modifications

**Output:** human-readable console report + optional JSON. Does not open or modify any files
other than writing the optional `-OutputFile`.

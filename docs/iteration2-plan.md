# Iteration 2 — Implementation Plan

**Status:** Planning
**Start:** 2026-03-13
**Repos:** `alz-mgmt-templates` (engine), `alz-mgmt` (new consolidated config repo)

---

## Scope

Iteration 2 has four tracks:

| Track | Priority | Description |
|-------|----------|-------------|
| **A. Config monorepo** | High | Consolidate per-tenant config repos into a single `alz-mgmt` repo |
| **B. Brownfield integration** | High | Adopt existing Azure tenants not set up with this platform |
| **C. platform.json expansion** | Medium | Move remaining hardcoded values into `platform.json` |
| **D. Operational hardening** | Medium | Bootstrap improvements, tag pinning, PLATFORM_MODE full |

---

## Track A — Config Monorepo

The largest structural change. Detailed rationale in `iteration2-repo-architecture-tradeoff.md` and `records.md` (Mar 13 entry).

### A1. Create new `alz-mgmt` repo

- Create repo `ExjobbOA/alz-mgmt` with `tenants/` folder structure
- Migrate Oskar's config: `tenants/oskar/config/` (copy from `alz-mgmt-oskar`)
- Migrate Alen's config: `tenants/alen/config/` (copy from `alz-mgmt-alen`)
- Add root `bicepconfig.json` (shared linter config)
- Add `.gitignore`, `README.md`

### A2. Rework CI (`ci-template.yaml` in templates repo + `ci.yaml` in config repo)

**Config repo `ci.yaml`:**
- Triggers on PR to main
- Detects changed tenant folders via `git diff --name-only origin/main...HEAD`
- Parses folder names → `tenants/<name>/` → builds matrix
- Calls `ci-template.yaml` once per affected tenant, passing `tenant` name and the correct GitHub environment

**Templates repo `ci-template.yaml`:**
- Accept `tenantName` input parameter
- Set working path to `tenants/${{ inputs.tenantName }}/config/`
- All existing lint + What-If steps scoped to that path
- No change to the composite actions themselves

**Edge case:** PR touching multiple tenants → parallel matrix jobs, one per tenant. PR touching only engine changes (from templates repo dispatch) → all tenants validated.

### A3. Rework CD (`cd-template.yaml` in templates repo + `cd.yaml` in config repo)

**Config repo `cd.yaml`:**
- `workflow_dispatch` only
- Input: `tenant` (dropdown or free text — list all folder names under `tenants/`)
- Calls `cd-template.yaml` with `tenant` name + per-tenant GitHub environment selection

**Templates repo `cd-template.yaml`:**
- Accept `tenantName` input
- All file references scoped to `tenants/${{ inputs.tenantName }}/config/`
- GitHub environment selection: `alz-mgmt-plan-<tenantName>` and `alz-mgmt-apply-<tenantName>`
- Boolean deployment step inputs unchanged

### A4. Update `onboard.ps1`

Current behavior: creates GitHub repo + environments + secrets, runs bootstrap ARM template, writes client IDs back.

New behavior:
1. Creates folder `tenants/<tenantName>/config/` in `alz-mgmt` repo (local + push, or via GitHub API)
2. Copies template `platform.json` and `.bicepparam` stubs into the folder
3. Creates GitHub environments in `alz-mgmt` (not a new repo): `alz-mgmt-plan-<tenantName>` and `alz-mgmt-apply-<tenantName>`
4. Runs bootstrap ARM deployment → captures `planClientId`, `applyClientId`
5. Writes `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` as env vars in the tenant-specific GitHub environments
6. Writes OIDC custom subject claim for the `alz-mgmt` repo (one-time per repo, not per tenant)
7. Updates `tenants/<tenantName>/config/platform.json` with UAMI client IDs

### A5. GitHub environment and OIDC naming strategy

FIC subject format: `repo:ExjobbOA/alz-mgmt:environment:alz-mgmt-plan-<tenantName>:job_workflow_ref:...`

Per-tenant environments in one repo:
- `alz-mgmt-plan-oskar` / `alz-mgmt-apply-oskar`
- `alz-mgmt-plan-alen` / `alz-mgmt-apply-alen`
- etc.

Each environment has its own `AZURE_CLIENT_ID` (the UAMI for that tenant) and the shared `AZURE_TENANT_ID` + `AZURE_SUBSCRIPTION_ID`. The CD workflow selects the environment based on the `tenant` input.

### A6. Update `cleanup.ps1`

- Remove the GitHub repo deletion step
- Add removal of tenant folder from `alz-mgmt` (commit + push, or via GitHub API)
- Remove the two tenant-specific GitHub environments from `alz-mgmt`
- Azure teardown (stacks, MGs, identity RG) unchanged

### A7. Engine → config repo trigger (open problem)

When a template is updated in `alz-mgmt-templates` and tagged, `alz-mgmt` CI does not auto-trigger. Options:

| Option | Complexity | Notes |
|--------|------------|-------|
| Repository dispatch on tag push | Low | Templates repo dispatches to `alz-mgmt` → triggers full matrix CI |
| Scheduled nightly validation | Low | Drift detection, not real-time |
| Manual trigger | None | Acceptable for thesis scope |

**Decision for iteration 2:** Manual trigger. Document as limitation, propose repository dispatch as the production recommendation.

---

## Track B — Brownfield Integration

The consulting company's customers almost never start greenfield. Brownfield adoption is the highest-priority practical feature after the monorepo migration.

### Core challenge

Azure Deployment Stacks track ownership of what they deployed. Importing existing resources into a stack without destroying and recreating them requires careful handling — `DeleteAll` on an existing tenant would destroy resources the stack never owned.

### B1. Harden `discover.ps1`

The prototype from Feb 28 surfaces conflicts between an existing tenant and the ALZ target state. Complete the stubs:

- **NSG inbound rule inspection**: flag subnets with inbound allow rules on port 22/3389 from `0.0.0.0/0` as Red (blocked by `Deny-MgmtPorts-Internet` policy)
- **Storage public access**: flag storage accounts with public blob access as Red
- **ALZ policy name collision**: compare existing custom policy definitions against the ALZ library JSON files — confirmed name collisions escalate from Yellow to Red
- **Multi-tenant batch mode**: accept a list of tenant IDs and run discovery across all of them in sequence, outputting one JSON report per tenant

Output: color-coded console report + JSON artifact. The JSON artifact feeds the adoption decision and placement config.

### B2. Deployment Stack adoption strategy

The core question: how do you bring existing resources under stack management without destroying them?

Options under investigation:

| Approach | Description | Risk |
|----------|-------------|------|
| **Detach + reimport** | Delete the existing resource and redeploy under the stack | Downtime, potential data loss |
| **Stack with `DetachAll`** | Deploy stack with `actionOnUnmanage: DetachAll` — resources not in the template are detached (not deleted), then re-associated on next deploy | Safe for resources, but complex state reconciliation |
| **Parallel stacks** | Deploy ALZ governance stacks alongside existing resources without touching them — policies apply immediately but no resource ownership transfer | Safe, but governance and resource stacks diverge |

The `DetachAll` approach is the most promising for production. The stack is first deployed with `DetachAll`, existing resources are brought into scope gradually. If the stack is then switched to `DeleteAll`, only newly stack-managed resources are at risk.

**Iteration 2 goal:** Define and document the recommended brownfield adoption sequence. Prototype and test with at least one real brownfield scenario.

### B3. Brownfield test scenario

- Identify a test tenant with existing resources (MGs, subscriptions, some custom policies)
- Run `discover.ps1` → produce conflict report
- Resolve conflicts (policy exclusions, MG placement decisions)
- Run `onboard.ps1` + CD with `DetachAll` stacks
- Verify existing resources survive, ALZ governance applied, no unexpected deletes
- Document the full sequence as a runbook

---

## Track C — platform.json Expansion

Move all remaining tenant-specific hardcoded values out of `.bicepparam` files into `platform.json`. These values currently force a tenant operator to edit Bicep files for standard deployment customization.

### Values to migrate

| Key | Current location | Default |
|-----|-----------------|---------|
| `NETWORK_ADDRESS_SPACE_PRIMARY` | `hubnetworking/main.bicepparam` | `"10.0.0.0/22"` |
| `NETWORK_ADDRESS_SPACE_SECONDARY` | `hubnetworking/main.bicepparam` | `"10.1.0.0/22"` |
| `P2S_VPN_ADDRESS_POOL_PRIMARY` | `virtualwan/main.bicepparam` | `"172.16.0.0/24"` |
| `P2S_VPN_ADDRESS_POOL_SECONDARY` | `virtualwan/main.bicepparam` | `"172.16.1.0/24"` |
| `LOG_RETENTION_DAYS` | `logging/main.bicepparam` | `"365"` |
| `LAW_SKU` | `logging/main.bicepparam` | `"PerGB2018"` |
| `DEPLOY_AUTOMATION_ACCOUNT` | `logging/main.bicepparam` | `"false"` |
| `WAIT_COUNTER_POLICY_ASSIGNMENTS` | All MG `.bicepparam` | `"40"` |
| `WAIT_COUNTER_ROLE_ASSIGNMENTS` | All MG `.bicepparam` | `"40"` |

MG display names (`MG_DISPLAY_NAME_ROOT`, etc.) are lower priority — add if time allows.

### Implementation

1. Add keys to `platform.json` in both tenant configs (oskar, alen)
2. Add `readEnvironmentVariable()` calls in the affected `.bicepparam` var blocks
3. Remove the now-redundant hardcoded values from `.bicepparam` files
4. Verify with `az bicep build-params` (all env vars set from `platform.json`)

---

## Track D — Operational Hardening

### D1. Bootstrap: create `alz` MG in `onboard.ps1`

Currently the `alz` MG is pre-created by `cd-template.yaml` (cold-start step). Move this to bootstrap:

- `onboard.ps1` creates the empty `alz` MG before deploying the bootstrap ARM template
- Plan UAMI can then be scoped to `alz` instead of tenant root (least privilege)
- Remove the cold-start pre-create step from `cd-template.yaml`
- Remove the `bicep-first-deployment-check` action (no longer needed — `alz` always exists after onboard)

### D2. Tag pinning strategy

- Tag `alz-mgmt-templates` at `v1.0.0` (iteration 1 complete)
- Tag at `v2.0.0` when iteration 2 is complete
- Config repo workflow files pin to a tag: `uses: ExjobbOA/alz-mgmt-templates/.github/workflows/ci-template.yaml@v2.0.0`
- Document the upgrade process: test on one tenant, validate K5, then update remaining tenants

### D3. PLATFORM_MODE full

- Formalize multi-subscription platform (connectivity/identity/management/security child MGs) as a tested path
- Define the full-mode `platform.json` shape properly — four separate subscription IDs are already in the schema, just untested end-to-end
- Deploy and test full mode on a dedicated tenant (requires 4 subscriptions)
- Add full mode to the empirical test pass if time allows

---

## Test Plan (Iteration 2)

Reuse the same K1–K6 criteria from iteration 1, applied to the monorepo architecture.

| Test | What changes vs. iteration 1 |
|------|------------------------------|
| K1 Cold start | `onboard.ps1` creates folder, not repo. CD targets `tenants/alen/config/` |
| K1 Idempotent | Same as iteration 1, different workflow path |
| K2 Spårbarhet | PR now in `alz-mgmt`, not `alz-mgmt-alen` |
| K3 Kontrollerad process | Same PR flow, same CODEOWNERS approach |
| K4 Rollback | Same |
| K5 Förändringspåverkan | Same K5 tooling — export, change, re-export, compare |
| K6 Cold start | Clean tenant + new `onboard.ps1` → CD → verify |

Additional metric: **onboarding time comparison** (iteration 1 vs iteration 2) — demonstrates the scaling improvement quantitatively.

Brownfield test (Track B) adds a new empirical scenario outside the K1–K6 framework.

---

## Step-by-step execution order

1. **records.md + this plan doc** ← done
2. **Track C** — platform.json expansion (low risk, isolated, no CI/CD changes needed first)
3. **Track D1** — bootstrap `alz` MG creation (small change, removes cold-start complexity)
4. **Track A** — monorepo migration
   - A1: create repo structure
   - A2: rework CI
   - A3: rework CD
   - A4+A5: update `onboard.ps1` + environment naming
   - A6: update `cleanup.ps1`
5. **Track D2** — tag pinning (after A is stable and tested)
6. **Track B** — brownfield integration
   - B1: harden `discover.ps1`
   - B2: define + prototype stack adoption strategy
   - B3: brownfield test scenario end-to-end
7. **Empirical test pass** — repeat K1–K6 on monorepo + brownfield scenario
8. **Track D3** — PLATFORM_MODE full (if time allows)

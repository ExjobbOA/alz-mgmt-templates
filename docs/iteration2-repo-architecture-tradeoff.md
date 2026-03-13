# Iteration 2: Repository Architecture Evolution

**Trade-off analysis — Multi-repo vs. monorepo tenant configuration**

Working document for iteration 2 planning — Oskar & Alen

---

## 1. Context

Iteration 1 of the ALZ management platform used a multi-repo configuration strategy: one shared engine repository (`alz-mgmt-templates`) and one separate configuration repository per tenant (`alz-mgmt-oskar`, `alz-mgmt-alen`). This architecture was chosen to provide strict tenant isolation and a clean separation between platform code and tenant-specific configuration.

During evaluation of iteration 1, we analyzed Microsoft's prescribed patterns for subscription vending and multi-tenant IaC management. The primary reference point is [ALZ Weekly Question – Week 10 – Subscription Vending: Repo Structure, Security & Multi-Tenant](https://www.youtube.com/watch?v=example), where the ALZ product team recommends a single-repo approach with one configuration file per vended entity and the CI/CD pipeline as the orchestration layer. Additional guidance from the Cloud Adoption Framework ([aka.ms/subvending](https://aka.ms/subvending)) and the ALZ architecture center reinforces this pattern.

The ALZ team's guidance is aimed at subscription vending — deploying application landing zones into an existing platform. Our platform operates one layer above that: we vend entire tenant governance platforms (management group hierarchies, policy, networking, identity). Despite the difference in scope, the structural recommendations around repo layout, config-per-entity, and pipeline orchestration are directly applicable.

A key finding from this analysis was that our multi-repo approach introduces operational overhead that grows linearly with tenant count. For Nordlo, managing 20+ tenants, this overhead is a real concern. However, merging everything into a single repo (as the ALZ team describes for their subscription vending context) would sacrifice an architectural advantage our two-repo split provides.

This document analyzes the trade-offs and proposes a compromise: consolidate tenant config repos into a monorepo while keeping the engine repo separate.

---

## 2. What the ALZ team prescribes

In the Week 10 episode, Jared describes the recommended Terraform approach (which the team confirms translates to Bicep with minor differences):

- **One single repository** for your IaC code, with configuration files (`.tfvars` / `.bicepparam`) per subscription.
- **One state file per vended subscription** (Terraform) or one separate ARM deployment per subscription (Bicep) — never one giant deployment covering everything.
- **The pipeline is the orchestrator** across multiple subscriptions. It uses `git diff` to detect changed config files, builds a matrix, and deploys affected subscriptions in parallel.
- **Configuration files define everything** — subscription name, management group placement, location, resource groups, tags, virtual networks, peering settings. The IaC module is generic and configurable; you don't copy-paste code between subscriptions.
- **For multi-tenant**, the same repo manages subscriptions across all tenants. The config file includes a tenant ID, and the pipeline selects the appropriate identity (one per tenant, not a single cross-tenant identity).

Zach adds the Bicep-specific nuance: use separate `.bicepparam` files per subscription, have CI point at different param files to detect drift, and deploy only the scopes that changed rather than everything at once.

The team explicitly recommends against separate repos or branches per subscription, calling it "a nightmare to deal with."

---

## 3. Where our iteration 1 design aligns and diverges

### 3.1 Alignment

| Aspect | ALZ guidance | Our iteration 1 |
|---|---|---|
| Config-per-entity | `.tfvars` / `.bicepparam` per subscription | `platform.json` + `.bicepparam` files per tenant |
| Pipeline as orchestrator | CI/CD detects changes and deploys selectively | CI validates per-scope, CD deploys selected stacks |
| Identity per tenant | Separate UAMI or service principal per tenant | Two UAMIs per tenant (plan + apply), OIDC federated |
| Engine reusability | One set of IaC modules, variables drive differences | Shared `alz-mgmt-templates` repo, `readEnvironmentVariable()` pattern |
| Separate deployments | One state file / ARM deployment per subscription | One deployment stack per governance scope (11 stacks per tenant) |

### 3.2 Divergence

| Aspect | ALZ guidance | Our iteration 1 |
|---|---|---|
| Repo structure | Single repo for code + config | Two repos — engine separate from config |
| Config repo count | One repo, file-per-entity | One repo per tenant |
| Cross-entity visibility | All configs visible in one place | Fragmented across tenant repos |
| CI/CD workflow duplication | One workflow set | Trigger workflows duplicated per tenant repo |

---

## 4. Three options evaluated

### Option A: Full monorepo (merge engine + all tenant configs)

This is the literal interpretation of the ALZ team's guidance — everything in one repo.

```
alz-platform/
  templates/               ← engine (currently alz-mgmt-templates)
  tenants/
    oskar/config/
    alen/config/
  .github/workflows/
```

**Pros:** Simplest model. Template changes and config changes can land in the same PR. No cross-repo checkout needed. `.bicepparam` paths simplify to relative paths within the same tree.

**Cons:** The engine and tenant configs change at different rates, for different reasons, by potentially different people. CI must now distinguish between template changes (rebuild and validate all tenants) and config changes (validate only the affected tenant). A template fix shows up in the same git history as someone changing a tenant's `SECURITY_CONTACT_EMAIL`. The engine repo does not have a scaling problem — it is one repo regardless of tenant count. Merging it in adds CI/CD complexity without solving a real problem.

**Verdict:** Over-consolidation. Solves a problem we don't have (engine repo sprawl) while creating a new one (mixed change detection in CI).

### Option B: Keep everything as-is (multi-repo)

Retain the iteration 1 architecture unchanged.

**Pros:** Proven, tested, works for two tenants. Strong tenant isolation.

**Cons:** Does not address the scaling concern. At 20+ tenants, repo management overhead (creation, permissions, environments, secrets, workflow duplication) becomes significant. No fleet-wide visibility. Cross-repo engine upgrade propagation requires additional orchestration.

**Verdict:** Valid for small-scale or strict-isolation scenarios, but does not meet Nordlo's operational requirements.

### Option C: Tenant config monorepo, engine stays separate (compromise)

Consolidate all tenant configs into a single repo. Keep the engine repo as-is.

```
alz-mgmt-templates/        ← engine repo (unchanged)
  templates/
  .github/workflows/
  .github/actions/
  scripts/

alz-mgmt/                  ← consolidated tenant config repo
  tenants/
    oskar/config/
      platform.json
      *.bicepparam
    alen/config/
      platform.json
      *.bicepparam
  .github/workflows/
    ci.yaml
    cd.yaml
```

**Pros:** Solves the scaling problem — adding a tenant is creating a folder, not a repo. Fleet-wide visibility in one place. Single CI/CD workflow set with path filtering and matrix builds. Engine repo keeps its independent lifecycle, versioning, and clean separation of concerns. Engine upgrades don't pollute tenant config history and vice versa. Aligns with the ALZ team's core recommendations (config-per-entity, pipeline as orchestrator, single config location) while preserving an architectural advantage they don't need at their layer (engine/config separation).

**Cons:** Tenant isolation is weaker than multi-repo — access control is at repo level, not per-tenant. CODEOWNERS can mitigate but isn't equivalent. If a tenant requires org-boundary separation, the monorepo can't accommodate it without a hybrid exception. Pipeline is more complex than iteration 1 (path filtering, matrix generation, tenant-scoped identity routing).

**Verdict:** Best fit. Takes the scaling win from the ALZ guidance, keeps the architectural win from iteration 1.

---

## 5. Comparison matrix

| Dimension | Multi-repo (iter. 1) | Full monorepo (option A) | Compromise (option C) |
|---|---|---|---|
| Tenant isolation | Strong — separate repos | Weakest — shared with engine | Moderate — shared config repo, CODEOWNERS |
| Engine/config separation | Clean — different repos | Lost — same repo | Preserved — engine stays separate |
| Onboarding effort | High — repo + envs + secrets | Low — folder only | Low — folder + identity bootstrap |
| CI/CD maintenance | Duplicated per tenant repo | Single but complex (dual change detection) | Single, scoped to config changes only |
| Fleet visibility | Fragmented | Full | Full |
| Pipeline blast radius | Narrow (one tenant) | Widest (engine + all tenants) | Moderate (all tenants, but not engine) |
| Scaling at 20+ tenants | Linear repo overhead | Flat | Flat |
| Engine upgrade propagation | Cross-repo triggering needed | Immediate (same repo) | Separate but simpler (one config repo to trigger) |
| Alignment with ALZ guidance | Partial | Full (literal) | Strong (adapted to our layer) |
| CI/CD complexity | Simple | Highest | Moderate |

---

## 6. DSR rationale

Design Science Research is built around iterative refinement. The move from multi-repo to the compromise monorepo is a design evolution informed by evaluation of the first iteration — not a correction of a mistake.

Iteration 1 validated the core engine architecture: the engine/config split, the `platform.json` single-source-of-truth pattern, deployment stacks, OIDC identity, and the full ALZ governance lifecycle. These design decisions are preserved in iteration 2.

What changes is the configuration distribution model — how tenant configs are organized and how the CI/CD pipeline discovers and deploys them. The templates repo, the `.bicepparam` structure, deployment stacks, and the identity strategy all remain unchanged.

Critically, we evaluated the ALZ team's full-monorepo recommendation and made a deliberate decision to adapt rather than adopt it wholesale. The guidance targets subscription vending (deploying application landing zones into an existing platform). Our platform operates one layer above — vending entire governance platforms. At our layer, the engine/config separation has value that doesn't exist in their context, because our engine is substantially more complex and evolves independently of tenant configuration.

This evaluation also produces stronger empirical data: iteration 1 results (multi-repo) can be compared directly against iteration 2 results (config monorepo) to assess the impact on onboarding time, pipeline complexity, and operational overhead.

---

## 7. What changes in practice

### 7.1 Changes required

1. Create a new consolidated config repo (`alz-mgmt`) with `tenants/<name>/config/` folder structure.
2. Migrate existing tenant configs (`alz-mgmt-oskar`, `alz-mgmt-alen`) into tenant folders.
3. Rework CI workflow: path filtering on `tenants/**`, build a matrix of affected tenants from `git diff`.
4. Rework CD workflow: accept a tenant name parameter, scope deployment to that tenant's config folder and identity.
5. Update `onboard.ps1` to create a folder + `platform.json` instead of a full repository.
6. Update `cleanup.ps1` to remove a tenant folder instead of deleting a repository.

### 7.2 What stays the same

- The templates engine repo — completely unchanged.
- The `.bicepparam` file format and `readEnvironmentVariable()` pattern.
- The `platform.json` structure and the `bicep-variables` composite action.
- Deployment stacks, their scopes, and deny settings.
- OIDC authentication with per-tenant UAMIs (plan + apply).
- The K5 stack state verification tooling (`Export-ALZStackState.ps1` / `Compare-ALZStackState.ps1`).

---

## 8. Risk assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Pipeline rework takes longer than expected | Medium | High | Use Claude Code to accelerate. Timebox to 2–3 days; if blocked, revert to multi-repo and document as limitation. |
| Retesting consumes thesis writing time | Medium | Medium | Reuse existing K5 tooling — tests are automated. Budget 1 day for re-execution. |
| Cross-tenant pipeline bug | Low | High | Tenant-scoped identity + GitHub environment protection rules. CD always requires explicit tenant selection. |
| Loss of org-boundary isolation | Low | Low | Document as known limitation. Hybrid model (monorepo + exception repos for regulated tenants) is a viable future extension. |

---

## 9. Recommendation

Adopt option C — the compromise monorepo — for iteration 2. It takes the scaling win from the ALZ team's guidance while keeping the engine/config separation that our platform's architecture benefits from.

The multi-repo model from iteration 1 remains a valid pattern for strict org-boundary isolation scenarios. It should be documented as an alternative, not deprecated.

Fallback: if the pipeline rework cannot be completed within the timeboxed period, the platform reverts to multi-repo and the scaling concern is documented as a limitation with a concrete path forward in the discussion chapter.

---

## References

- ALZ Weekly Question – Week 10 – Subscription Vending: Repo Structure, Security & Multi-Tenant (YouTube)
- Cloud Adoption Framework — Subscription vending guidance: [aka.ms/subvending](https://aka.ms/subvending)
- AVM Bicep subscription vending module: [aka.ms/subvending/bicep](https://aka.ms/subvending/bicep)
- AVM Terraform subscription vending module: [aka.ms/subvending/tf](https://aka.ms/subvending/tf)

# T10 — K11 Livscykeluppdatering (library + CI action-on-unmanage)

**Test ID:** T10
**Criterion:** K11 Livscykeluppdatering
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Engine repo tag produced:** `_v0.3.0-lib-<version>_`
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Criterion reference

K11 — Livscykeluppdatering. Kumara et al. (2021) beskriver konfigurationsdrift som en
konsekvens av okoordinerade ändringar. Alonso et al. (2023) betonar att diskrepanser mellan kod
och infrastruktur undergräver IaC:s grundprinciper. Beetz och Harrer (2022) visar att
GitOps-mönstret möjliggör kontinuerlig konvergens mot önskat tillstånd — men detta förutsätter
att det önskade tillståndet i sig hålls aktuellt. T10 testar kriteriet genom att
ALZ-biblioteksversionen bumpas i engine-repot, uppdateringsverktyg körs, engine-repot taggas,
och en CD-pipeline deployar den uppdaterade konfigurationen mot en tenant. Deployment stacks
verifierar att deprecated policys rensas och att nya definitioner tillkommer utan manuella
ingrepp.

**Target library version:** `_2026.04.0_` (or current latest on run day — confirm)
**Source library version:** `2025.09.2`

---

## Phase 0 — Pre-flight

### 0.1 Tenant baseline health

- [ ] Last CD run succeeded (no lingering red stacks)
- [ ] No open drift alerts from `Compare-BrownfieldState.ps1`
- [ ] All 16 stacks exist and track expected resources

**Last successful CD run URL:** _paste URL_
**Timestamp:** _paste timestamp_

### 0.2 Release notes review

External release notes for target library version (screenshot the page — evidence that operator
consulted change documentation before absorbing update).

![Release notes screenshot](screenshots/t10-release-notes.png)

**Breaking changes identified (from release notes):**
- _paste_
- _paste_

**New policy sets / definitions of note:**
- _paste_

**Deprecated / removed policies expected to be cleaned up by DeleteAll:**
- _paste_

### 0.3 Baseline state snapshot

Export current stack state:
```
.\scripts\Export-ALZStackState.ps1 -OutputPath .\state-snapshots\state-t10-baseline.json
```

**Baseline snapshot file:** `state-snapshots/state-t10-baseline.json`

**Baseline policy counts** (from Azure portal at `alz` MG scope):

| Item                     | Count |
|--------------------------|-------|
| Policy definitions       |       |
| Policy set definitions   |       |
| Policy assignments       |       |
| Role definitions         |       |

**Baseline portal screenshots:**
- ![Policy definitions at alz MG](screenshots/t10-baseline-definitions.png)
- ![Policy assignments at int-root](screenshots/t10-baseline-assignments-introot.png)
- ![Policy assignments at landingzones](screenshots/t10-baseline-assignments-lz.png)

### 0.4 EncryptTransit workaround state

Currently active in `alz-mgmt-oskar/config/core/governance/mgmt-groups/int-root.bicepparam`:

```bicep
managementGroupExcludedPolicyAssignments: ['Enforce-EncryptTransit']
```

Reason: case-sensitivity bug in 2025.09.2 library — `AKSIngressHttpsOnlyEffect` accepts
`["audit", "deny", "disabled"]` (lowercase) but the underlying built-in requires TitleCase.

_Notes / observations:_

---

## Phase 1 — Commit 1: enable DeleteAll on governance stacks

### 1.1 Change

`.github/workflows/cd-template.yaml`: flip `actionOnUnmanage: 'DetachAll'` → `'DeleteAll'` on
lines **565, 584, 602, 620, 639, 658, 678, 697, 716, 735, 753, 772, 790, 808**.

Leave **lines 827 (networking) and 846 (logging) as `DetachAll`**.

### 1.2 Commit

**SHA:** _paste_
**Message:** `ci: enable DeleteAll on governance stacks for auto-cleanup of deprecated policies`

### 1.3 CI what-if result

Expected: zero resource changes (only CI-config change, no desired-state change).

![CI what-if output for commit 1](screenshots/t10-commit1-whatif.png)

**Observed:** _any resource changes? if yes, investigate before proceeding_

### 1.4 CD run after merge

**Run URL:** _paste_
**Result:** _green / red_
**Deletions observed:** _expected none — if anything got deleted, that's pre-existing stack
drift being cleaned up. Document what and why._

![CD run 1 summary](screenshots/t10-commit1-cd.png)

_Notes / observations:_

---

## Phase 2 — Commit 2: bump ALZ library version

### 2.1 Metadata bump

`templates/core/governance/tooling/alz_library_metadata.json`:

```diff
- "ref": "2025.09.2"
+ "ref": "_2026.04.0_"
```

### 2.2 Regenerate library

Commands run:
```powershell
cd templates/core/governance/lib
Remove-Item -Path ".\alz" -Recurse -Force

cd ../tooling
alzlibtool generate architecture "." alz --for-alz-bicep -o "../lib"
```

**alzlibtool output:**
```
<paste console output>
```

### 2.3 Update Bicep references

```powershell
.\Update-AlzLibraryReferences.ps1 -WhatIf
```

![Update-AlzLibraryReferences WhatIf output](screenshots/t10-updater-whatif.png)

Then apply:
```powershell
.\Update-AlzLibraryReferences.ps1
```

![Update-AlzLibraryReferences apply output](screenshots/t10-updater-apply.png)

### 2.4 Bug fix verification

Before committing, verify the EncryptTransit case bug is fixed in the regenerated library.

Check `templates/core/governance/lib/alz/Enforce-EncryptTransit_20241211.alz_policy_set_definition.json`:

| Parameter                    | 2025.09.2 value          | New lib value      | Fixed? |
|------------------------------|--------------------------|--------------------|--------|
| `AKSIngressHttpsOnlyEffect`  | `["audit","deny","disabled"]` | _paste_            | Y / N  |

_If still lowercase in the new lib, skip Phase 3 (keep the workaround). The test still passes
for K11 as long as the rest of the library update flows through; the exclusion just stays._

### 2.5 Git diff stats

```
git diff --stat
```
```
<paste git diff --stat output>
```

**Summary:**
- Files added to `lib/alz/`: _count_
- Files removed from `lib/alz/`: _count_
- `mgmt-groups/*/main.bicep` files modified: _count_

### 2.6 Commit

**SHA:** _paste_
**Message:** `chore: bump ALZ library 2025.09.2 -> _<new-version>_`

Commit body:
```
<paste>
```

_Notes / observations:_

---

## Phase 3 — Commit 3 (tenant repo): remove EncryptTransit workaround

**Only if Phase 2 confirmed the bug is fixed.**

### 3.1 Change

`alz-mgmt-oskar/config/core/governance/mgmt-groups/int-root.bicepparam`:

```diff
-  managementGroupDoNotEnforcePolicyAssignments: []
-  // Temporary workaround: 'Enforce-EncryptTransit' has a case-sensitivity bug in the ALZ library
-  // where the policy set sends effect 'deny' but the built-in policy definition requires 'Deny'.
-  // Remove this exclusion once the library is updated with the fix.
-  managementGroupExcludedPolicyAssignments: ['Enforce-EncryptTransit']
+  managementGroupDoNotEnforcePolicyAssignments: []
+  managementGroupExcludedPolicyAssignments: []
```

### 3.2 Commit

**SHA:** _paste_
**Message:** `fix: remove Enforce-EncryptTransit exclusion (case bug fixed in lib _<new-version>_)`

_Notes / observations:_

---

## Phase 4 — Evidence run

### 4.1 Engine repo PR and tag

**PR URL:** _paste_
**PR merged at:** _timestamp_

Tag:
```
git tag -a v0.3.0-lib-_<new-version>_ -m "ALZ library _<new-version>_"
git push origin v0.3.0-lib-_<new-version>_
```

**Tag URL:** _paste_

![Engine repo tag on GitHub](screenshots/t10-engine-tag.png)

### 4.2 Tenant repo PR

Engine ref/submodule bump to point at the new tag, plus commit 3 from Phase 3.

**PR URL:** _paste_
**PR merged at:** _timestamp_

### 4.3 CD run (the K11 evidence run)

**Run URL:** _paste_
**Result:** _green / red_
**Total duration:** _paste_

#### 4.3.1 CI what-if output

Expected adds: new policy definitions / sets from the new library version.
Expected removes: deprecated definitions / sets that were in 2025.09.2 but not in the new
version.
Expected modifies: policy assignments where the effect default TitleCase-fix landed.

```
<paste what-if output — focus on Apply: Governance-Intermediate Root and Apply: Governance-Landing Zones stacks>
```

![CI what-if — int-root](screenshots/t10-whatif-introot.png)
![CI what-if — landingzones](screenshots/t10-whatif-lz.png)

#### 4.3.2 Deployment stack execution log

Look for lines showing `Delete: <resource>` entries (DeleteAll kicking in on deprecated
resources) and `Create: <resource>` entries for new definitions.

```
<paste relevant log lines — filter for 'Delete' and 'Create'>
```

![CD run log showing DeleteAll in action](screenshots/t10-cd-deletes.png)
![CD run log showing new definitions being created](screenshots/t10-cd-creates.png)

### 4.4 Post-deploy state snapshot

```
.\scripts\Export-ALZStackState.ps1 -OutputPath .\state-snapshots\state-t10-after.json
.\scripts\Compare-ALZStackState.ps1 `
  -BaselinePath .\state-snapshots\state-t10-baseline.json `
  -CurrentPath .\state-snapshots\state-t10-after.json
```

**Diff summary:**
```
<paste Compare-ALZStackState output>
```

### 4.5 Post-deploy portal verification

| Item                     | Baseline | After | Delta |
|--------------------------|----------|-------|-------|
| Policy definitions       |          |       |       |
| Policy set definitions   |          |       |       |
| Policy assignments       |          |       |       |
| Role definitions         |          |       |       |

![Policy definitions at alz MG — after](screenshots/t10-after-definitions.png)
![Policy assignments at int-root — after](screenshots/t10-after-assignments-introot.png)
![Policy assignments at landingzones — after](screenshots/t10-after-assignments-lz.png)

### 4.6 Specific deprecated-policy cleanup verification

Pick 2–3 known-deprecated items and verify they are gone in the new state (not just detached).

| Deprecated item                                   | Pre: exists? | Post: exists? | Auto-removed? |
|---------------------------------------------------|--------------|---------------|---------------|
| _e.g. Enforce-EncryptTransit (deprecated set)_    | Y            |               |               |
| _e.g. any policy flagged as removed in release notes_ |              |               |               |
| _e.g. any assignment using a removed def_         |              |               |               |

### 4.7 EncryptTransit policy healthy

If workaround was removed in Phase 3, verify the policy now assigns cleanly.

![EncryptTransit policy set at alz MG](screenshots/t10-encrypttransit-healthy.png)

_Notes / observations:_

---

## Phase 5 — Thesis mapping

### 5.1 Evidence → criterion mapping

| Evidence artifact                                | K11 aspect demonstrated                          |
|--------------------------------------------------|--------------------------------------------------|
| Release notes screenshot (0.2)                   | Operator absorbs external change documentation   |
| `alz_library_metadata.json` diff (2.1)           | Single-point version declaration (code as source of truth) |
| `Update-AlzLibraryReferences.ps1` output (2.3)   | Tooling-assisted engine-repo update              |
| CI what-if (4.3.1)                               | Platform predicts change before applying         |
| CD stack log with deletes (4.3.2)                | Deployment stacks auto-reconcile without manual intervention |
| Before/after portal screenshots (0.3 vs 4.5)     | Drift between code and infrastructure resolved   |
| Tenant workaround removed (3.1)                  | Local drift caused by upstream bug remediated by upstream update |

### 5.2 Result vs criterion

- [ ] Library version successfully bumped in engine repo
- [ ] `alzlibtool` regenerated the lib without manual edits
- [ ] `Update-AlzLibraryReferences.ps1` updated Bicep references automatically
- [ ] Engine repo tagged
- [ ] CD pipeline deployed the update to the tenant without manual stack-state edits
- [ ] Deprecated policies were removed automatically via `DeleteAll`
- [ ] New policy definitions were added to the `alz` MG automatically
- [ ] Local workaround for EncryptTransit could be removed (if bug fixed in new lib)

**Criterion verdict:** _Passed / Partially passed / Not passed_

**Justification (1–2 paragraphs, academic Swedish for thesis chapter 4):**

> _paste here when writing up_

### 5.3 Findings for chapter 5 (diskussion / begränsningar)

**Finding 1: `DetachAll` default vs documented `DeleteAll` behavior.**
The Microsoft ALZ accelerator documentation describes automatic cleanup of deprecated policies
as a property of deployment stacks when deployed with `ActionOnUnmanage: DeleteAll`. The
bootstrapped `cd-template.yaml` ships with `DetachAll` on all 16 stacks by default. Without
flipping this knob, the auto-cleanup mechanism Kumara et al. (2021) and Alonso et al. (2023)
would recognize as addressing configuration drift does not activate. This is a gap between
documentation and default configuration. Operators absorbing library updates on out-of-the-box
accelerator deployments would not get the advertised behavior.

**Finding 2: Case-sensitivity bug took N library versions to fix.**
The `Enforce-EncryptTransit` policy set carried a lowercase-`deny` default that conflicted with
the underlying built-in policy across multiple library versions. This required a local
workaround in the tenant repo to bypass the assignment. The T10 run demonstrated that library
update absorption is not purely a technical exercise — the operator must also track whether
pre-existing local workarounds can now be retired. This aligns with the operator-as-change-
absorber model K11 measures.

**Finding 3 (if any):** _paste_

### 5.4 Scope boundary — what T10 did NOT test

- AVM module version bumps (deferred to T10b for attribution clarity — same lifecycle
  mechanism applies, same CI/CD path, not exercised in this run)
- Breaking-change scenarios where the library removes a policy that has active non-compliant
  resources (would require a fabricated failure scenario; not part of K11)
- Rollback path (reverting to previous library version) — not required by K11 phrasing but
  worth acknowledging as a limitation

---

## Appendix A — Command reference

```powershell
# Baseline snapshot
.\scripts\Export-ALZStackState.ps1 -OutputPath .\state-snapshots\state-t10-baseline.json

# Library regeneration
cd templates/core/governance/lib
Remove-Item -Path ".\alz" -Recurse -Force
cd ../tooling
alzlibtool generate architecture "." alz --for-alz-bicep -o "../lib"

# Reference update
.\Update-AlzLibraryReferences.ps1 -WhatIf
.\Update-AlzLibraryReferences.ps1

# Post-deploy snapshot + diff
.\scripts\Export-ALZStackState.ps1 -OutputPath .\state-snapshots\state-t10-after.json
.\scripts\Compare-ALZStackState.ps1 `
  -BaselinePath .\state-snapshots\state-t10-baseline.json `
  -CurrentPath .\state-snapshots\state-t10-after.json

# Tag engine repo
git tag -a v0.3.0-lib-<new-version> -m "ALZ library <new-version>"
git push origin v0.3.0-lib-<new-version>
```

## Appendix B — Screenshot filename convention

Store under `docs/screenshots/` in the engine repo:

- `t10-release-notes.png`
- `t10-baseline-definitions.png`
- `t10-baseline-assignments-introot.png`
- `t10-baseline-assignments-lz.png`
- `t10-commit1-whatif.png`
- `t10-commit1-cd.png`
- `t10-updater-whatif.png`
- `t10-updater-apply.png`
- `t10-engine-tag.png`
- `t10-whatif-introot.png`
- `t10-whatif-lz.png`
- `t10-cd-deletes.png`
- `t10-cd-creates.png`
- `t10-after-definitions.png`
- `t10-after-assignments-introot.png`
- `t10-after-assignments-lz.png`
- `t10-encrypttransit-healthy.png`
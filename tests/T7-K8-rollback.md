# T7 — Rollback

**Test ID:** T7
**Criterion:** K8 Rollback
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Syfte

Visa att en kodändring kan rullas tillbaka via revert-commit och att Azure-state
återförs till pre-change-tillståndet. Operatören ska kunna lita på att en revert
faktiskt återställer plattformen, inte bara koden.

K8 mäts genom att revert:a T6:s ändring och verifiera att Azure-state matchar
pre-change-snapshoten.

---

## Context

T6 introducerade en parameter-ändring (effect: Audit → Deny på en specifik
policy assignment). T7 reverterar samma ändring och verifierar att Azure återgår till
ursprungstillståndet.

Mätinstrumentet är samma som K5: what-if pre-deploy + LastModifiedDate post-deploy +
direkt parameter-verifikation.

---

## Phase 0 — Pre-flight

### 0.1 Baseline (efter T6)

- T6 har körts klart med ändring deployad
- Engine-tag: _paste senaste tag_
- 11/11 stackar succeeded
- T6:s parameter-ändring synlig i Azure (`effect: Deny`)

### 0.2 Snapshot av LastModifiedDate per stack (post-T6)

```powershell
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7" |
  Select-Object Name, LastModifiedDate

Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz" |
  Select-Object Name, LastModifiedDate

Get-AzSubscriptionDeploymentStack |
  Select-Object Name, LastModifiedDate
```

| Stack | LastModifiedDate (post-T6) |
|---|---|
| _ | _ |

---

## Phase 1 — Skapa revert-PR

### 1.1 Identifiera T6:s commit

```powershell
cd C:\Users\granl\repos\alz-mgmt
git log --oneline -5
```

Identifiera commit-SHA för T6:s parameter-ändring.

**T6 commit SHA:** _paste_

### 1.2 Skapa revert

```powershell
git switch main
git pull
git switch -c test/k8-rollback
git revert <T6-commit-SHA> --no-edit
git push -u origin test/k8-rollback
```

Öppna PR mot main.

**PR URL:** _paste_

---

## Phase 2 — What-if-prognos

### 2.1 CI kör what-if automatiskt

**What-if URL:** _paste_

### 2.2 Verifiera att prognosen är spegelbild av T6

Förväntat: what-if rapporterar samma stack som ändras (`landingzones-corp`), men nu
i motsatt riktning:

```
~ Microsoft.Authorization/policyAssignments/Deny-Public-Endpoints
    ~ properties.parameters.effect.value: "Deny" => "Audit"
```

Övriga stackar visar bara brus.

**Screenshot:** `t7-1-whatif-revert.png`

---

## Phase 3 — Merge och CD

### 3.1 Merge revert-PR

### 3.2 CD-resultat

**CD run URL:** _paste_
**Resultat:** _green/red_
**Duration:** _paste_

### 3.3 Snapshot av LastModifiedDate per stack (post-revert)

```powershell
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7" |
  Select-Object Name, LastModifiedDate

Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz" |
  Select-Object Name, LastModifiedDate

Get-AzSubscriptionDeploymentStack |
  Select-Object Name, LastModifiedDate
```

| Stack | LastModifiedDate (post-T6) | LastModifiedDate (post-revert) | Ändrad? |
|---|---|---|---|
| _ | _ | _ | Ja/Nej |

Förväntat: endast `landingzones-corp` har ny `LastModifiedDate`. Övriga är oförändrade.

---

## Phase 4 — Direkt verifikation av parameter

### 4.1 Hämta parameter-värde

```powershell
Get-AzPolicyAssignment -Scope "/providers/Microsoft.Management/managementGroups/corp" -Name "Deny-Public-Endpoints" |
  Select-Object -ExpandProperty Parameters
```

Förväntat: `effect.value` är nu tillbaka till `Audit` (eller pre-T6-värdet).

**Screenshot:** `t7-2-parameter-restored.png`

---

## Phase 5 — Resultat

### 5.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| What-if rapporterar revert-ändring som spegelbild av T6 | _ | Phase 2 |
| Endast den reverterade stackens LastModifiedDate uppdateras | _ | Phase 3 |
| Parameter-värdet i Azure återställt till pre-T6 | _ | Phase 4 |

### 5.2 Observationer

[Fyll i efter körning]

### 5.3 Verdict

- [ ] K8 Passed
- [ ] K8 Partially passed
- [ ] K8 Not passed

**En-meningskommentar:** _paste efter körning_

---

## Evidens-artefakter

1. PR URL för revert
2. What-if URL från CI
3. CD run URL
4. Tabell med LastModifiedDate pre/post per stack
5. `t7-1-whatif-revert.png` — what-if visar revert-ändring
6. `t7-2-parameter-restored.png` — Azure visar att parametern är återställd

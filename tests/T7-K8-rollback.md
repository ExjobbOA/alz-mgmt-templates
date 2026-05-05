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
pre-T6-snapshoten.

---

## Context

T6 introducerade en parameter-ändring (`Enable-DDoS-VNET` `effect: Audit → Disabled`
i `landingzones/main.bicepparam`). T7 reverterar samma ändring och verifierar att
Azure återgår till ursprungstillståndet.

Mätinstrumentet är samma som K5: what-if pre-deploy + LastModifiedDate post-deploy +
direkt parameter-verifikation. Skillnaden är riktningen — T7 förväntar sig att
prognosen är en spegelbild av T6:s prognos.

---

## Phase 0 — Pre-flight

### 0.1 Baseline (efter T6)

- T6 har körts klart med ändring deployad
- Engine-tag: _paste senaste tag_
- 11/11 stackar succeeded
- T6:s parameter-ändring synlig i Azure (`Enable-DDoS-VNET` `effect: Disabled`)

### 0.2 Snapshot av LastModifiedDate per stack (post-T6)

```powershell
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7" |
  Select-Object Name, @{Name="LastModifiedDate"; Expression={$_.SystemData.LastModifiedAt}}

Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz" |
  Select-Object Name, @{Name="LastModifiedDate"; Expression={$_.SystemData.LastModifiedAt}}

Get-AzSubscriptionDeploymentStack |
  Select-Object Name, @{Name="LastModifiedDate"; Expression={$_.SystemData.LastModifiedAt}}
```

name                                                     LastModifiedDate
----                                                     ----------------
3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7-governance-int-root 4/30/2026 1:36:21 PM
name                               LastModifiedDate
----                               ----------------
alz-governance-landingzones        5/4/2026 7:50:43 PM
alz-governance-landingzones-corp   4/26/2026 7:32:27 PM
alz-governance-landingzones-online 4/26/2026 7:37:34 PM
alz-governance-platform            4/26/2026 7:39:27 PM
alz-governance-sandbox             4/26/2026 7:51:35 PM
alz-governance-decommissioned      4/26/2026 7:56:21 PM
alz-governance-platform-rbac       4/26/2026 8:01:51 PM
alz-governance-landingzones-rbac   4/26/2026 8:03:25 PM
name               LastModifiedDate
----               ----------------
alz-networking-hub 4/26/2026 8:06:39 PM
alz-core-logging   4/26/2026 8:11:01 PM

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

Vi skapar revert i github ui i PR vyn se screenshot `t7-revertPR.png`

Öppna PR mot main.

**PR URL:** https://github.com/ExjobbOA/alz-mgmt-oskar/pull/101

---

## Phase 2 — What-if-prognos

### 2.1 CI kör what-if automatiskt

**What-if URL:** https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/25342277145/job/74302352559

### 2.2 Verifiera att prognosen är spegelbild av T6

Förväntat: what-if rapporterar samma stack som ändras (`governance-landingzones`),
men nu i motsatt riktning:

```
~ Microsoft.Authorization/policyAssignments/Enable-DDoS-VNET
    ~ properties.parameters.effect.value: "Disabled" => "Audit"
```

Övriga stackar visar bara brus.

Faktiskt resultat stämmer överens med förväntat

**Screenshot:** `t7-1-whatif-revert.png`

---

## Phase 3 — Merge, CD och verifiera utfall

### 3.1 Merge revert-PR och kör CD

Klicka merge i GitHub. Trigga CD via `workflow_dispatch` med
`governance-landingzones: true` (övriga steg kan vara false för snabbare körning,
eller true för att visa att de inte påverkas).

**CD run URL:** https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/25342869489/job/74304375709
**Resultat:** _green/red_
**Duration:** _paste_

### 3.2 Snapshot av LastModifiedDate per stack (post-revert)

```powershell
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7" |
  Select-Object Name, @{Name="LastModifiedDate"; Expression={$_.SystemData.LastModifiedAt}}

Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz" |
  Select-Object Name, @{Name="LastModifiedDate"; Expression={$_.SystemData.LastModifiedAt}}

Get-AzSubscriptionDeploymentStack |
  Select-Object Name, @{Name="LastModifiedDate"; Expression={$_.SystemData.LastModifiedAt}}
```

name                                                     LastModifiedDate
----                                                     ----------------
3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7-governance-int-root 4/30/2026 1:36:21 PM

name                               LastModifiedDate
----                               ----------------
alz-governance-landingzones        5/4/2026 8:55:28 PM
alz-governance-landingzones-corp   4/26/2026 7:32:27 PM
alz-governance-landingzones-online 4/26/2026 7:37:34 PM
alz-governance-platform            4/26/2026 7:39:27 PM
alz-governance-sandbox             4/26/2026 7:51:35 PM
alz-governance-decommissioned      4/26/2026 7:56:21 PM
alz-governance-platform-rbac       4/26/2026 8:01:51 PM
alz-governance-landingzones-rbac   4/26/2026 8:03:25 PM

name               LastModifiedDate
----               ----------------
alz-networking-hub 4/26/2026 8:06:39 PM
alz-core-logging   4/26/2026 8:11:01 PM

Förväntat: endast `governance-landingzones` har ny `LastModifiedDate`. Övriga är
oförändrade.

Faktiskt resultat identiskt med förväntat resultat.

### 3.3 Direkt parameter-verifikation i Azure


Förväntat: `effect.value` är nu tillbaka till `Audit` (pre-T6-värdet).
Faktiskt resultat identiskt med förväntat resultat.

**Screenshot:** `t7-2-parameter-restored.png`

---

## Phase 4 — Resultat

### 4.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| What-if rapporterar revert-ändring som spegelbild av T6 | Ja | Phase 2 |
| Endast den reverterade stackens LastModifiedDate uppdateras | Ja | Phase 3.2 |
| Parameter-värdet i Azure återställt till pre-T6 (`Audit`) | Ja | Phase 3.3 |

### 4.2 Observationer

Inga intressanta observationer mer än att det funkade smidigt och att revert var enkelt att göra via github ui och att effekten sågs tydligt i whatif förutom brus. 

### 4.3 Verdict

- [x] K8 Passed
- [ ] K8 Partially passed
- [ ] K8 Not passed

**En-meningskommentar:** Plattformen möjiggör revert på smidigt sätt. 
---

## Evidens-artefakter

1. PR URL för revert
2. What-if URL från CI
3. CD run URL
4. Tabell med LastModifiedDate pre/post per stack
5. `t7-1-whatif-revert.png` — what-if visar revert-ändring
6. `t7-2-parameter-restored.png` — Azure visar att parametern är återställd
7. `t7-revertPR.png` - visar hur vi revertar merge från t6 i github
# T6 — Förändringspåverkan

**Test ID:** T6
**Criterion:** K5 Förändringspåverkan
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Syfte

Visa att what-if-prognosen pre-deploy matchar det faktiska utfallet post-deploy.
Operatören ska kunna lita på att what-if förutspår vad som kommer hända i Azure innan
en deploy körs.

K5 mäts genom att göra en kontrollerad parameter-ändring, observera what-if-prognos,
köra CD, och jämföra prognos med utfall via deployment stack `LastModifiedDate` per
stack.

---

## Context

What-if är Azure-validerat verktyg som rapporterar förväntade ändringar innan en deploy
körs. T10 visade att what-if har känt brus (AVM-substitution, pass-through-pattern,
API-rendering-drift) men att äkta ändringar är distinkta från bruset.

För K5 görs en specifik mätbar ändring av en policy assignment-parameter. Den ändringen
ska synas i what-if som en `~ Modify` på rätt resurs i rätt stack, och post-deploy ska
rätt stack ha uppdaterad `LastModifiedDate`.

---

## Phase 0 — Pre-flight

### 0.1 Baseline

- Engine-tag: _paste senaste tag_
- 11/11 stackar succeeded
- Inga öppna PRs

### 0.2 Snapshot av LastModifiedDate per stack

Innan ändring, dokumentera nuvarande LastModifiedDate:

```powershell
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7" |
  Select-Object Name, LastModifiedDate

Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz" |
  Select-Object Name, LastModifiedDate

Get-AzSubscriptionDeploymentStack |
  Select-Object Name, LastModifiedDate
```

| Stack | LastModifiedDate (pre-change) |
|---|---|
| _ | _ |

---

## Phase 1 — Genomför ändring

### 1.1 Välj parameter att ändra

Välj en policy assignment-parameter som är säker att ändra och tydligt kan kopplas till
en specifik stack. Förslag: en `effect`-parameter på en assignment i `landingzones-corp`-
stacken (liten stack, lätt att verifiera).

Exempel: ändra `Deny-Public-Endpoints`-assignmentens `effect`-parameter från `Audit`
till `Deny` i `landingzones-corp.bicepparam`.

### 1.2 Skapa PR

```powershell
cd C:\Users\granl\repos\alz-mgmt
git switch -c test/k5-change-impact
# editera bicepparam-filen
git add config/core/governance/mgmt-groups/landingzones/landingzones-corp/main.bicepparam
git commit -m "test(K5): change effect parameter for change impact test"
git push -u origin test/k5-change-impact
```

Öppna PR mot main.

**PR URL:** _paste_

---

## Phase 2 — What-if-prognos

### 2.1 CI kör what-if automatiskt

Vänta in CI:n och hämta what-if-output för alla stackar.

**What-if URL:** _paste_

### 2.2 Per-stack-sammanfattning

| Stack | Resource changes | Innehåller K5-ändringen? |
|---|---|---|
| int-root | _ | Nej |
| platform | _ | Nej |
| landingzones | _ | Nej |
| **landingzones-corp** | _ | **Ja** |
| ... | _ | Nej |

Förväntat: bara `landingzones-corp` visar en faktisk parameter-ändring (utöver
brusprofilen). Övriga stackar visar endast brus.

### 2.3 Specifik ändring i prognosen

Verifiera att what-if rapporterar exakt den parameter-ändring som gjordes:

```
~ Microsoft.Authorization/policyAssignments/Deny-Public-Endpoints
    ~ properties.parameters.effect.value: "Audit" => "Deny"
```

**Screenshot:** `t6-1-whatif-prognosis.png`

---

## Phase 3 — Merge och CD

### 3.1 Merge PR

Klicka merge i GitHub.

### 3.2 CD-resultat

**CD run URL:** _paste_
**Resultat:** _green/red_
**Duration:** _paste_

### 3.3 Snapshot av LastModifiedDate per stack post-deploy

```powershell
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7" |
  Select-Object Name, LastModifiedDate

Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz" |
  Select-Object Name, LastModifiedDate

Get-AzSubscriptionDeploymentStack |
  Select-Object Name, LastModifiedDate
```

| Stack | LastModifiedDate (pre-change) | LastModifiedDate (post-change) | Ändrad? |
|---|---|---|---|
| _ | _ | _ | Ja/Nej |

Förväntat: endast `landingzones-corp` har ny `LastModifiedDate`. Övriga är oförändrade.

---

## Phase 4 — Direkt verifikation av parameter

### 4.1 Hämta nuvarande parameter-värde

```powershell
Get-AzPolicyAssignment -Scope "/providers/Microsoft.Management/managementGroups/corp" -Name "Deny-Public-Endpoints" |
  Select-Object -ExpandProperty Parameters
```

Förväntat: `effect.value` är nu `Deny` (eller vad som specificerades i ändringen).

**Screenshot:** `t6-2-parameter-applied.png`

---

## Phase 5 — Resultat

### 5.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| What-if rapporterar K5-ändring på exakt rätt resurs i rätt stack | _ | Phase 2 |
| Endast den ändrade stackens LastModifiedDate uppdateras | _ | Phase 3 |
| Parameter-värdet i Azure matchar bicepparam-värdet | _ | Phase 4 |

### 5.2 Observationer

[Fyll i efter körning]

### 5.3 Verdict

- [ ] K5 Passed
- [ ] K5 Partially passed
- [ ] K5 Not passed

**En-meningskommentar:** _paste efter körning_

---

## Notering

T6:s ändring lämnas kvar i baseline för T7 (rollback) som testar att samma ändring kan
återställas via revert-commit. Cleanup sker i T7.

---

## Evidens-artefakter

1. PR URL för K5-ändringen
2. What-if URL från CI
3. CD run URL
4. Tabell med LastModifiedDate pre/post per stack
5. `t6-1-whatif-prognosis.png` — what-if visar exakt ändring
6. `t6-2-parameter-applied.png` — Azure visar att parameter-värdet är applicerat

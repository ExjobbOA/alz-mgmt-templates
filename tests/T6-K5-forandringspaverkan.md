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
stack samt direkt parameter-kontroll i Azure.

---

## Context

What-if är Azures validerade verktyg som rapporterar förväntade ändringar innan en
deploy körs. T10 visade att what-if har känt brus (AVM-substitution,
pass-through-pattern, API-rendering-drift) men att äkta ändringar är distinkta från
bruset.

För K5 görs en specifik mätbar ändring av en policy assignment-parameter. Den
ändringen ska synas i what-if som en `~ Modify` på rätt resurs i rätt stack, och
post-deploy ska rätt stack ha uppdaterad `LastModifiedDate` samt rätt
parameter-värde i Azure.

---

## Phase 0 — Pre-flight

### 0.1 Baseline

- Engine-tag: 1.1.5
- 11/11 stackar succeeded
- Inga öppna PRs

### 0.2 Snapshot av LastModifiedDate per stack

Innan ändring, dokumentera nuvarande LastModifiedDate för alla stackar. Behövs för
att verifiera isolation post-deploy (endast målstacken ska uppdateras):

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
alz-governance-landingzones        4/26/2026 7:26:49 PM
alz-governance-landingzones-corp   4/26/2026 7:32:27 PM
alz-governance-landingzones-online 4/26/2026 7:37:34 PM
alz-governance-platform            4/26/2026 7:39:27 PM
alz-governance-sandbox             4/26/2026 7:51:35 PM
alz-governance-decommissioned      4/26/2026 7:56:21 PM
alz-governance-platform-rbac       4/26/2026 8:01:51 PM
alz-governance-landingzones-rbac   4/26/2026 8:03:25 PM
              > 

alz-networking-hub 4/26/2026 8:06:39 PM
alz-core-logging   4/26/2026 8:11:01 PM
---

## Phase 1 — Genomför ändring

### 1.1 Vald parameter

Ändringen görs på `Enable-DDoS-VNET`-assignmentens `effect`-parameter i
`landingzones/main.bicepparam`. Egenskaper som gör den lämplig:

- Ändringen är **idag** `effect: 'Audit'` — den förändras till `effect: 'Disabled'`
- Funktionellt neutral i båda riktningar: `Audit` rapporterar bara compliance,
  `Disabled` slår av policyn helt — ingendera påverkar några resurser
- Ligger i en specifik stack (`governance-landingzones`) — gör isolation tydlig
- Reversibel via revert-commit i T7

**Stack som ska uppdateras:** `governance-landingzones`
**Övriga stackar:** ska INTE uppdateras (`LastModifiedDate` oförändrad)

### 1.2 Skapa PR

```powershell
cd C:\Users\granl\repos\alz-mgmt
git switch -c test/k5-change-impact
```

Editera `config/core/governance/mgmt-groups/landingzones/main.bicepparam`,
ändra `Enable-DDoS-VNET` block:

```bicep
'Enable-DDoS-VNET': {
  parameters: {
    effect: {
      value: 'Disabled'   // ändrat från 'Audit'
    }
  }
}
```

```powershell
git add config/core/governance/mgmt-groups/landingzones/main.bicepparam
git commit -m "test(K5): change Enable-DDoS-VNET effect Audit -> Disabled for change impact test"
git push -u origin test/k5-change-impact
```

Öppna PR mot main.

**PR URL:** https://github.com/ExjobbOA/alz-mgmt-oskar/pull/100

---

## Phase 2 — What-if-prognos

### 2.1 CI kör what-if automatiskt

Vänta in CI:n och hämta what-if-output för alla stackar.

**What-if URL:** https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/25339059512/job/74291676742

### 2.2 Specifik ändring i prognosen

Verifiera att what-if rapporterar exakt den parameter-ändring som gjordes:

```
~ Microsoft.Authorization/policyAssignments/Enable-DDoS-VNET
    ~ properties.parameters.effect.value: "Audit" => "Disabled"
```

**Screenshot:** `t6-1-whatif-prognosis.png`

---

## Phase 3 — Merge, CD och verifiera utfall

### 3.1 Merge PR och kör CD

Klicka merge i GitHub. Trigga CD via `workflow_dispatch` med
`governance-landingzones: true` (övriga steg kan vara false för snabbare körning,
eller true för att visa att de inte påverkas). Vi körde på endast landingzones

**CD run URL:** https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/25339680911/job/74293687331
**Resultat:** Grönt
**Duration:** 18m 27s 

### 3.2 Snapshot av LastModifiedDate per stack post-deploy

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

Förväntat: endast `governance-landingzones` har ny `LastModifiedDate`. Övriga är
oförändrade.

Det stämmer

### 3.3 Direkt parameter-verifikation i Azure

Kollar manuellt i portalen på assignmenten 

Förväntat: `effect.value` är nu `Disabled`.

**Screenshot:** `t6-2-parameter-applied.png`

---

## Phase 4 — Resultat

### 4.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| What-if rapporterar K5-ändring på exakt rätt resurs i rätt stack | Ja | Phase 2 |
| Endast den ändrade stackens LastModifiedDate uppdateras | Ja | Phase 3.2 |
| Parameter-värdet i Azure matchar bicepparam-värdet | Ja | Phase 3.3 |

### 4.2 Observationer

Trots vanligt brus var ändringen lätt att se för den stack ut

### 4.3 Verdict

- [x] K5 Passed
- [ ] K5 Partially passed
- [ ] K5 Not passed

**En-meningskommentar:** En ändring i koden reflekteras tydligt i både whatif och azure state

---

## Notering

T6:s ändring (`Enable-DDoS-VNET: Audit → Disabled` i `landingzones/main.bicepparam`)
lämnas kvar i baseline för T7 (rollback) som testar att samma ändring kan återställas
via revert-commit. Cleanup sker i T7.

T7 behöver uppdateras parallellt så att den refererar till `Enable-DDoS-VNET` i
`governance-landingzones`-stacken (inte `Deny-Public-Endpoints` i `landingzones-corp`
som tidigare).

---

## Evidens-artefakter

1. PR URL för K5-ändringen
2. What-if URL från CI
3. CD run URL
4. Tabell med LastModifiedDate pre/post per stack
5. `t6-1-whatif-prognosis.png` — what-if visar exakt ändring
6. `t6-2-parameter-applied.png` — Azure visar att parameter-värdet är applicerat
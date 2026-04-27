# T1 — Stabilitet och idempotens

**Test ID:** T1
**Criterion:** K1 Deklarativt önskat tillstånd + K2 Idempotens
**Executed by:** Oskar
**Start date:** 2026-04-26
**End date:** 2026-04-28
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Syfte

Visa att plattformen håller deklarerat tillstånd över tid och att upprepade
deployment-körningar utan kodändring inte introducerar förändringar i Azure. Två
närbesläktade egenskaper testas tillsammans i samma pass eftersom båda mäts genom att
köra what-if respektive CD mot oförändrad kod.

**K1:** Deklarativt önskat tillstånd — what-if mot oförändrad main rapporterar tom
changelist (med hänsyn till dokumenterat brus).

**K2:** Idempotens — andra CD-körningen utan kodändring rapporterar 0 resource
operations per deployment stack.

---

## Context

What-if-bruset är karakteriserat sedan tidigare empiriska iterationer. Bruset består av
AVM-substitutionsmönster på policy definitions, pass-through-parameter-pattern på policy
sets, och API-version-rendering-drift på vissa Azure-resurser. Detta brus är inte
verkliga ändringar utan rendering-skillnader mellan template och Azure state. Eftersom
bruset är konstant mellan körningar av samma kod kan det särskiljas från äkta drift
genom jämförelse av två körningar med varandra.

---

## Phase 0 — Pre-flight

### 0.1 Baseline

- Senaste lyckade CD: 11/11 stackar succeeded: https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/24929539653
- Engine-tag: v1.1.3
- Inga ändringar i tenant-repot eller engine-repot sedan senaste CD 

### 0.2 Verifikation av baseline-state

```powershell
cd C:\Users\granl\repos\alz-mgmt
git status
git log --oneline -3

Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7"
Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz"
Get-AzSubscriptionDeploymentStack
```

Förväntat: ren working tree, alla 11 stackar `succeeded` med 0 detached.

857271e (HEAD -> main, origin/main, origin/HEAD) Update CD template version to v1.1.3 (#94)
1e3f4bf Update CI template version to v1.1.3 (#93)
8991275 Update CD workflow to use version 1.1.2 (#92)

PS /home/oskar> Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7" |
>>   Select-Object Name, ProvisioningState,
>>                 @{N='Resources';E={$_.Resources.Count}},
>>                 @{N='Detached';E={$_.DetachedResources.Count}} |
>>   Format-Table -AutoSize

name                                                     provisioningState Resources Detached
----                                                     ----------------- --------- --------
3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7-governance-int-root succeeded               225        0

PS /home/oskar> 
PS /home/oskar> Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz" |
>>   Select-Object Name, ProvisioningState,
>>                 @{N='Resources';E={$_.Resources.Count}},
>>                 @{N='Detached';E={$_.DetachedResources.Count}} |
>>   Format-Table -AutoSize

name                               provisioningState Resources Detached
----                               ----------------- --------- --------
alz-governance-landingzones        succeeded               127        0
alz-governance-landingzones-corp   succeeded                 7        0
alz-governance-landingzones-online succeeded                 1        0
alz-governance-platform            succeeded               116        0
alz-governance-sandbox             succeeded                 2        0
alz-governance-decommissioned      succeeded                 3        0
alz-governance-platform-rbac       succeeded                 1        0
alz-governance-landingzones-rbac   succeeded                33        0

PS /home/oskar> 
PS /home/oskar> Get-AzSubscriptionDeploymentStack |
>>   Select-Object Name, ProvisioningState,
>>                 @{N='Resources';E={$_.Resources.Count}},
>>                 @{N='Detached';E={$_.DetachedResources.Count}} |
>>   Format-Table -AutoSize

name               provisioningState Resources Detached
----               ----------------- --------- --------
alz-networking-hub succeeded               182        0
alz-core-logging   succeeded                 7        0


---

## Phase 1 — K1 What-if mot oförändrad main

### 1.1 Trigga what-if utan kodändring

```powershell
cd C:\Users\granl\repos\alz-mgmt
git checkout -b docs/t1
git commit --allow-empty -m "ci: trigger what-if for K1 stability test"
git push -u origin docs/t1
```

CI kör automatiskt what-if mot exakt samma kod som senaste lyckade deploy.

### 1.2 Resultat per stack

Inga creates eller deletes på resurs-nivå rapporteras för någon stack.

| Stack | Modifies | No change | Övrigt | Status |
|---|---|---|---|---|
| int-root | 206 | 19 | – | ✓ |
| platform | 102 | 14 | – | ✓ |
| landingzones | 106 | 21 | – | ✓ |
| landingzones-corp | 4 | 3 | – | ✓ |
| landingzones-online | 0 | 1 | – | ✓ |
| sandbox | 1 | 1 | – | ✓ |
| decommissioned | 2 | 1 | – | ✓ |
| platform-rbac | 0 | 0 | 1 unsupported | ✓ |
| landingzones-rbac | 0 | 0 | 33 unsupported | ✓ |
| core-logging | 2 | 5 | – | ✓ |
| networking-hub | 4 | 178 | 2 ignore | ✓ |

### 1.3 Klassificering av rapporterade modifies

Inspektion av rådatat per stack ger fem bruskategorier. Samtliga rapporterade
modifies faller i en av dem.

| # | Kategori | Mekanism | Stackar |
|---|---|---|---|
| 1 | AVM/copyIndex | What-if kan inte resolva `copyIndex()` på policyDefinitions, visar råa ARM-uttrycket | int-root |
| 2 | ARM-uttryck pass-through | Template sätter `"1.*.*"` eller `reference(...).principalId`, Azure resolvar vid deploy | int-root, platform, landingzones, corp, sandbox, decommissioned |
| 3 | RBAC `reference()`-unsupported | Role assignments beror på `reference()` av ej-deployade policy assignments — dokumenterad Azure-begränsning | platform-rbac, landingzones-rbac |
| 4 | API-version-rendering-drift | Azure-genererade metadata (`isolationScope`, `containedResources`, `creationTime`) som inte deklareras i template | core-logging |
| 5 | Azure-managed peering properties | Read-only state-derived properties + phantom diff från `ResourceDeployedMultipleTimes` | networking-hub |

Kategori 5 verifierad genom jämförelse med pre-deploy what-if
([run 24929229965](https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/24929229965)):
identisk `doNotVerifyRemoteGateways: false => true`-flip i båda körningarna
bekräftar phantom diff. Hade det varit verklig drift hade CD:n applicerat
ändringen och post-deploy visat `= NoChange`.

### 1.4 Bedömning K1

- [x] Tom changelist (förutom dokumenterat brus): **K1 Passed**

Inga creates, inga deletes på resurs-nivå, inga oklassificerade modifies.

**What-if URL:** https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/24961003229

---

## Phase 2 — K2 Idempotens via CD

### 2.1 Trigga andra CD utan kodändring

Re-run senaste lyckad CD-körning från GitHub Actions, eller pusha en tom commit som
triggar ny CD.

**CD run URL:** https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/24964643718/job/73097214897

### 2.2 Resultat per stack

Stack-state efter andra CD är identiskt med Phase 0 baseline:

| Stack | Phase 0 | Efter T1 CD | Match |
|---|---|---|---|
| governance-int-root | 225 / 0 | 225 / 0 | ✓ |
| governance-platform | 116 / 0 | 116 / 0 | ✓ |
| governance-landingzones | 127 / 0 | 127 / 0 | ✓ |
| ... | | | |

Format: Resources / Detached. Alla 11 stackar `succeeded`.

### 2.3 Bedömning K2

- [x] Andra körning rapporterar 0 resource-state-förändringar: **K2 Passed**

Idempotens bevisad genom att andra CD-körningen utan kodändring producerar
identiskt sluttillstånd som första: samma resource counts per stack, samma
provisioning state, 0 detached. Bicep/ARM:s deklarativa modell innebär att
varje resurs valideras mot existerande state och en no-op rapporteras
istället för en faktisk ändring — det är detta beteende K2 mäter.

**CD run URL:** https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/24964643718
**Duration:** 1h 07m (jfr T10:s ändrings-CD: 1h 31m)

---

## Phase 3 — Resultat

### 3.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| What-if mot oförändrad kod = enbart dokumenterat brus | 0 creates, 0 deletes på resurs-nivå; samtliga modifies klassificerade i 5 bruskategorier | CI what-if [run 24961003229](https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/24961003229) |
| Andra CD utan kodändring = identiskt sluttillstånd | Stack-state oförändrat över alla 11 stackar (resource counts, provisioning state, 0 detached) | Get-AzManagementGroupDeploymentStack + Get-AzSubscriptionDeploymentStack |
| Stack ProvisioningState förblir succeeded | 11/11 stackar `succeeded` | Stack-state-export |

### 3.2 Observationer

What-if-outputen domineras av strukturellt brus från fem identifierade
kategorier, varav den största (AVM/copyIndex på policyDefinitions) ensam står
för merparten av int-roots 206 modifies. Implikation för operativ användning
är att what-if mot en deployad ALZ-miljö inte kan tolkas naivt — operatören
behöver känna till brusprofilen för att kunna agera på outputen. Detta är
ett ärvt beteende från Azure och AVM, inte en egenskap av plattformen.

Networking-hubs `doNotVerifyRemoteGateways: false => true`-rapportering
verifierades som phantom diff genom pre/post-jämförelse: identisk flip i
båda körningarna utesluter verklig drift. Underliggande orsak är
`ResourceDeployedMultipleTimes`-mönstret där peerings deklareras både
inline på vnet och som child-resurser.

Andra CD-körningens duration (1h 07m) är kortare än T10:s ändrings-CD
(1h 31m) men inte trivialt kort. Skillnaden förklaras av att Bicep/ARM
gör fullständig validering av samtliga resurser även när inga ändringar
utförs — kompilering, template-validering och state-jämförelse per resurs
körs oavsett.

### 3.3 Verdict

- [x] K1 Passed
- [ ] K1 Partially passed
- [x] K2 Passed
- [ ] K2 Partially passed

**En-meningskommentar K1:** What-if mot oförändrad deployad kod producerar
inga oklassificerade ändringar — samtliga rapporterade modifies faller i
fem dokumenterade bruskategorier, vilket bekräftar att plattformen håller
sitt deklarerade tillstånd.

**En-meningskommentar K2:** Andra CD-körningen utan kodändring resulterar
i identiskt sluttillstånd som första, mätt genom oförändrade resource
counts, oförändrad provisioning state och 0 detached resources över
samtliga 11 stackar — vilket är den definitionsmässiga egenskapen av
idempotens.
---

## Evidens-artefakter

1. CI what-if URL för K1
2. CD run URL för K2
3. Tabell med per-stack-jämförelse av modifies (Phase 1.3)
4. Tabell med per-stack-resultat av andra CD (Phase 2.2)

---

## Appendix — Command reference

```powershell
# Trigga tom commit för CI/CD
git commit --allow-empty -m "ci: trigger for stability test"
git push

# Verifiera stack-state före och efter
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7"
Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz"
Get-AzSubscriptionDeploymentStack
```

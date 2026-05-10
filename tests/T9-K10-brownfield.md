# T9 — Brownfield-kompatibilitet

**Test ID:** T9
**Criterion:** K10 Brownfield-kompatibilitet
**Executed by:** Oskar
**Start date:** 2026-05-01
**End date:** 2026-05-03
**Tenant:** Sylaviken Nordlo-tenant
**Status:** Ej genomförd — scope-cuttad efter två CD-iterationer (se Phase 3)

---

## Syfte

Visa att plattformen kan driftsättas mot en existerande Azure-tenant utan att
förstöra befintliga resurser, och att den reagerar korrekt på drift mellan
ALZ-managed och customer-managed policies.

---

## Context

Sylaviken är Nordlos testmiljö — en portal-deployad ALZ Accelerator, inte
IaC-deployad. Plattformen körs i *simple mode* och *governance-only* (ingen
networking, ingen core-logging — LAW finns redan).

### Tenant-struktur

```
Tenant Root Group  (adf9c0bb-91e2-4d3b-9a83-9a7ef2412bcf)
├── (3 subs UTANFÖR ALZ — out of scope)
├── ALZ                                       (intermediate root)
│   ├── ALZ-decommissioned
│   ├── ALZ-landingzones
│   │   ├── ALZ-corp                          → Sylaviken Corp Sub  db8f96fe-826b-4fa0-9252-d655d3f62854
│   │   └── ALZ-online
│   ├── ALZ-platform                          → Sylaviken Mgmt Sub  93ff5894-3e0b-4de9-9438-80e0fb7100de
│   └── ALZ-sandboxes
└── sylaviken                                 (syskon-MG, out of scope)
```

T9 scope:ar till `ALZ`-MG och nedåt.

### Naming-konvention

Sylaviken använder ALZ Accelerator-portal-naming, inte ALZ-Bicep-konventionen:

| Resurs | ALZ-Bicep | Sylaviken |
|---|---|---|
| Logging RG | `rg-alz-logging-${loc}` | `ALZ-mgmt` |
| LAW | `law-alz-${loc}` | `ALZ-law` |
| AMA UAMI | `id-alz-ama-${loc}` | `id-ama-prod-swedencentral-001` |
| DCRs | `dcr-alz-{type}-${loc}` | `dcr-{type}-prod-swedencentral-001` |

Hanteras via `var`-patcher i `int-root.bicepparam`.

---

## Engine prerequisite

Engine-tag `v1.1.5` med dessa fixar mergade:

1. Precreate parameteriserad
2. `targetManagementGroupId` parameteriserad
3. `cleanup.ps1` parameteriserad
4. Tre `main-rbac.bicepparam` parameteriserade

Plattformen baseras på AVM Bicep (`avm/ptn/alz/empty:0.3.5`).

---

## Phase 0 — Pre-flight

### 0.1 Scope och tidsstämpel

- **Engine-version:** e72921a
- **Start:** 2026-05-01
- **Operatör:** Oskar — Owner @ Tenant Root tilldelat 2026-05-01

### 0.2 Pre-onboarding baseline

Screenshots i `tests/evidence/`:
- `t9-0-pre-mg.png` — MG-hierarki
- `t9-0-pre-mgmt-rgs.png` — RGs i Sylaviken Mgmt Sub
- `t9-0-pre-alz-mgmt-resources.png` — innehåll i `ALZ-mgmt`-RG
- `t9-0-phase5-target.png` — T9-test-policy

### 0.3 Skapa custom policy för Phase 5

Test-policy `[T9 TEST — DELETE AFTER 2026-05-16] Audit storage accounts with HTTPS-only disabled`
skapad och tilldelad på `ALZ` MG med `effect=Audit`.

### 0.4 Sylaviken-fork

```powershell
gh repo create ExjobbOA/alz-mgmt-sylaviken --private
git clone https://github.com/ExjobbOA/alz-mgmt-oskar.git alz-mgmt-sylaviken
# bumpa cd.yaml + ci.yaml till @v1.1.5
```

### 0.5 platform.json

Skapad manuellt med Sylaviken-värden (MG-IDs, sub-IDs, simple mode, Sylaviken
naming). `SECURITY_CONTACT_EMAIL` hämtad från befintlig `Deploy-MDFC-Config-*`.

### 0.6 Sylaviken-edits i forken

- `landingzones-corp/main.bicepparam`: exclude `'Deploy-Private-DNS-Zones'`
- `landingzones/main.bicepparam` + `main-rbac.bicepparam`: exclude `'Enable-DDoS-VNET'`
- `int-root.bicepparam`: patcha `var rgLogging = 'ALZ-mgmt'`, `var lawName = 'ALZ-law'`

---

## Phase 1 — Onboarding

```powershell
.\scripts\onboard.ps1 `
  -ConfigRepoPath          '../alz-mgmt-sylaviken' `
  -BootstrapSubscriptionId '93ff5894-3e0b-4de9-9438-80e0fb7100de' `
  -ManagementGroupId       'adf9c0bb-91e2-4d3b-9a83-9a7ef2412bcf' `
  -GithubOrg               'ExjobbOA' `
  -ModuleRepo              'alz-mgmt-sylaviken'
```

**Resultat:** Lyckades. UAMIs, custom role, RBAC och GitHub environments
konfigurerade korrekt utan collisions. Screenshot: `t9-1-onboarded.png`

---

## Phase 2 — CD-deploy

### 2.1 Iteration 1

**CD run:** https://github.com/ExjobbOA/alz-mgmt-sylaviken/actions/runs/25260770477
**Resultat:** Failed på int-root-stacken
**Fel:**
- 8 × `RoleAssignmentExists` — engine försöker skapa role assignments för
  policy MI:er; samma deterministiska GUID:s finns redan från Sylavikens
  portal-deploy
- 1 × `InvalidPolicyDefinitionIdUpdate` på `Deploy-Diag-LogsCat` — Sylaviken
  pekar på allLogs-initiativet (`0884adba-...`), engine vill peka på
  audit-initiativet (`f5b29bc4-...`); Azure tillåter inte byte av
  `policyDefinitionId` på existerande assignment

Båda hanterades via `managementGroupExcludedPolicyAssignments` i
`int-root.bicepparam`.

### 2.2 Iteration 2

**CD run:** https://github.com/ExjobbOA/alz-mgmt-sylaviken/actions/runs/25281362749
**Resultat:** Int-root green, landingzones failed
**Fel:**
- 1 × `InvalidPolicyDefinitionIdUpdate` på `Enforce-GR-KeyVault` — samma
  felklass som ovan; engine refererar `_20260203`-versionen, Sylaviken en
  äldre

Vid det här laget framgick att brownfield-takeover av Sylaviken skulle kräva
en omfattande exclusion-lista över alla scopes. T9 scope-cuttades enligt
överenskommelse med Nordlo (se Phase 3).

---

## Phase 3 — Scope-cut och felmekanismer

### 3.1 Beslut om scope-cut

Vid projektets uppstart överenskom Oskar och Nordlo att brownfield-validering
kunde scope-cuttas om tidsbudgeten blev pressande. Efter två CD-iterationer
hade två återkommande felklasser identifierats utan enkel lösning inom
tidsramen — varje CD-körning tar ~2 timmar och iterativ exclusion av
ytterligare kolliderande policies hade krävt flera körningar utan att tillföra
ny information om plattformen i sig. Beslut: 2026-05-03 — Phase 4
(drift-restoration) och Phase 5 (customer-managed-respect) skiftas till future
work, K1–K9-validering och slutskrivning prioriteras.

### 3.2 Felmekanismer

De två felklasserna som uppstod är dokumenterade upstream-problem i
Bicep-providern respektive Azure ARM:

**`RoleAssignmentExists`** uppstår eftersom Bicep skapar role assignments med
deterministiska GUID:er, beräknade som `guid(scope, principalId,
roleDefinitionId)`. När engine försöker skapa role assignments för policy MI:er
på `ALZ`-MG-scope:n returnerar Azure 409 Conflict eftersom Sylavikens
portal-deploy redan skapat identiska GUID:er via samma formel. Bicep saknar
idempotent existence-check för role assignments — detta är ett känt
återkommande problem dokumenterat i öppen issue **Azure/bicep #18454** [1]:

> "We have written a bunch of Bicep code over the past 2 years and the one
> problem we consistently run into is conflicts on role assignments in our
> templates because the role assignment already exists [...] When I heard about
> @onlyIfNotExists(), I thought it was the solution to this problem but
> unfortunately after testing, it doesn't look like it works this way."

**`InvalidPolicyDefinitionIdUpdate`** uppstår eftersom Azure ARM inte tillåter
ändring av `policyDefinitionId` på en existerande policy assignment. När
ALZ-libet uppdaterar sin standardversion av en policy (t.ex.
`Enforce-Guardrails-KeyVault` → `_20260203`, eller migrationen från
ALZ-custom-initiativ till built-in-initiativ för Diag-LogsCat) är det inte en
in-place-uppgradering utan kräver delete + recreate. Microsoft dokumenterar
allLogs-vs-audit-scenariot under ALZ "Known Issues" [2] — det är samma scenario
som reproducerades på `Deploy-Diag-LogsCat` i T9.

För hantering inom T9 användes AVM Bicep:s inbyggda
`managementGroupExcludedPolicyAssignments`-parameter, vilket är ramverkets
officiella mekanism för att hoppa över specifika assignments som redan finns
deployade på annat sätt. Detta löser dock inte takeover av befintliga
assignments — det undantar dem bara från CRUD via modulen.

---

## Phase 4 — Drift på ALZ-managed policy
**Status:** Ej genomförd. Skiftad till future work (se 3.1).

## Phase 5 — Drift på customer-managed policy
**Status:** Ej genomförd. Skiftad till future work (se 3.1).

---

## Phase 6 — Verdict och cleanup

### 6.1 Verdict

**K10 ej utvärderat — testet inte genomfört enligt plan.**

Phase 4 (drift-restoration) och Phase 5 (customer-managed respect) skiftades
till future work enligt scope-cut-överenskommelse med Nordlo (se 3.1). De två
partiella CD-körningarna gav teknisk insikt om brownfield-felmekanismer i
Bicep/ARM (se 3.2), men utgör inte K10-validering.

### 6.2 Cleanup

Säkerhetsmässig cleanup utförd 2026-05-03:
1. T9-test-policy (assignment + definition) raderade
2. Identity RG raderad (innehöll UAMIs + FICs)
3. Owner @ Tenant Root-tilldelning för Oskar borttagen

Lämnas kvar i Sylaviken som T9-evidens:
- Deployment stack `ALZ-governance-int-root` (16 engine-managed policy assignments)
- Failed deployment stack `ALZ-governance-landingzones` (0 managed resurser)

---

## Future work

- Phase 4 + 5 (drift-tester)
- Cleanup-first takeover-pipeline (delete + recreate-sekvens med risk-fönster)
"En alternativ brownfield-strategi som inte kräver in-place takeover är parallell hierarchy-deployment med audit-only-effects och iterativ subscription-migration. Plattformen i denna avhandling stödjer denna modell tekniskt — engine kan deploya till godtyckligt namngiven intermediate root MG. Operationellt kräver den dock customer-koordinering, MG-restrukturering, och custom-policy-portation som ligger utanför thesis-scope. Det rekommenderas som primär migrationsväg för enterprise-kunder."

OBS PÅ WIKI STÅR DETTA 
Deployment Stacks Automatic Cleanup

Unlike classic Bicep deployments, deployment stacks automatically remove resources that are no longer defined in your templates. This means:

    Deprecated policies are automatically unassigned when you update the ALZ library
    No manual cleanup required for removed policy assignments
    Consistent state between your templates and deployed resources
    Safe deletion - only removes resources managed by the deployment stack

This is a major improvement over ALZ Bicep Classic, where you had to manually remove deprecated policy assignments before deploying updates.

SÅ GREJEN ÄR ATT DET MAN MÅSTE GÖRA FÖR IN PLACE ÄR ATT MANUELLT RENSA ALLA 

---

## Referenser

| # | URL | |
|---|---|---|
| 1 | https://github.com/Azure/bicep/issues/18454 | RoleAssignmentExists upstream Bicep-bug, öppen sedan nov 2025 |
| 2 | https://azure.github.io/Azure-Landing-Zones/known-issues/ | Microsofts officiella Known Issues, allLogs vs audit-migrationen |
| 3 | https://github.com/ExjobbOA/alz-mgmt-sylaviken/actions/runs/25260770477 | T9 iteration 1 CD-fail |
| 4 | https://github.com/ExjobbOA/alz-mgmt-sylaviken/actions/runs/25281362749 | T9 iteration 2 CD-fail |
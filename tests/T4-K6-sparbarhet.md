# T4 — Spårbarhet

**Test ID:** T4
**Criterion:** K6 Spårbarhet
**Executed by:** Oskar
**Start date:** 2026-04-30
**End date:** 2026-04-30
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Syfte

Visa att en ändring kan spåras från PR till slutlig Azure-resurs i båda
riktningarna. Testet körs med en kontrollerad live-ändring så att kedjan
verifieras under aktuella förhållanden, inte i efterhand mot historiska data.

K6 mäts genom screenshots från GitHub UI och Azure Portal. Värdet ligger i att
en operatör visuellt kan följa kedjan utan extra verktyg.

---

## Phase 0 — Pre-flight

### 0.1 Förbered ändringen

Ändringen sker enbart i tenant-repot — i `int-root.bicepparam` läggs en custom
policy definition + assignment till via `customerPolicyDefs` och
`customerPolicyAssignments`. Egenskaper som gör ändringen lämplig som
spårningsobjekt:

- Funktionellt neutral: `effect: 'Disabled'` i policy-rule + `enforcementMode: 'DoNotEnforce'` i assignment — påverkar inga resurser
- Visuellt identifierbar: unikt namn (`T4-Trace-Audit-Tag`) och egen metadata-category (`T4-trace`) gör båda objekten triviala att hitta i Policy-bladet
- Self-revertable: sätt arrayerna tillbaka till `[]` i en följd-PR, deployment stack-semantiken (`DeleteAll`) städar resurserna automatiskt
- Validerar customer-extension-mekaniken som biprodukt — inget i lib eller engine rörs

**Spårningsobjekt efter deploy:**
- Custom policy definition: `T4-Trace-Audit-Tag` på alz MG
- Policy assignment: `T4 trace test — audit assignment` på alz MG

**Fil att editera:** `config/core/governance/mgmt-groups/int-root.bicepparam`

### 0.2 Baseline

- Engine-tag (oförändrad under testet): v1.1.3
- Senaste lyckade CD-körning innan testet: https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/24964643718

---

## Phase 1 — Skapa ändringen

### 1.1 Branch + edit + commit + PR

```powershell
cd C:\Users\granl\repos\alz-mgmt
git checkout -b t4/trace-test
```

Editera `config/core/governance/mgmt-groups/int-root.bicepparam`:

Ersätt `customerPolicyDefs: []` med:

```bicep
customerPolicyDefs: [
  {
    name: 'T4-Trace-Audit-Tag'
    properties: {
      displayName: 'T4 trace test — audit missing trace tag'
      description: 'Temporary custom policy for K6 traceability test. Audits resource groups missing a t4-trace tag. Effect set to Disabled, does not affect any resources.'
      mode: 'All'
      policyType: 'Custom'
      metadata: {
        category: 'T4-trace'
        version: '1.0.0'
      }
      parameters: {}
      policyRule: {
        if: {
          allOf: [
            {
              field: 'type'
              equals: 'Microsoft.Resources/subscriptions/resourceGroups'
            }
            {
              field: 'tags[t4-trace]'
              exists: 'false'
            }
          ]
        }
        then: {
          effect: 'Disabled'
        }
      }
    }
  }
]
```

Ersätt `customerPolicyAssignments: []` med:

```bicep
customerPolicyAssignments: [
  {
    name: 'T4-Trace-Audit-Tag'
    location: location
    identity: {
      type: 'None'
    }
    properties: {
      displayName: 'T4 trace test — audit assignment'
      description: 'Temporary policy assignment for K6 traceability test.'
      policyDefinitionId: '/providers/Microsoft.Management/managementGroups/${intRootMgId}/providers/Microsoft.Authorization/policyDefinitions/T4-Trace-Audit-Tag'
      enforcementMode: 'DoNotEnforce'
      parameters: {}
      scope: '/providers/Microsoft.Management/managementGroups/${intRootMgId}'
      metadata: {
        category: 'T4-trace'
      }
      notScopes: []
    }
  }
]
```

```powershell
git add config\core\governance\mgmt-groups\int-root.bicepparam
git commit -m "T4 trace test: add custom policy definition and assignment"
git push -u origin t4/trace-test
```

Skapa PR i GitHub.

| Artefakt | Värde |
|---|---|
| Branch | `t4/trace-test` |
| Commit SHA | `5f90b8b` |
| PR-nummer | #96 |
| PR-URL | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/96 |

### 1.2 Merge

| Artefakt | Värde |
|---|---|
| Merge commit SHA | `c0d0326` |

### 1.3 Vänta på CD

CD triggas via `workflow_dispatch` med stack-väljare. Vald stack:
`governance-int-root` (custom policy + assignment hamnar på alz MG via
int-root-templaten).

| Artefakt | Värde |
|---|---|
| CD workflow run | #81 |
| Triggad av | Oskar (workflow_dispatch) |
| Stack-input | `governance-int-root` |
| CD-resultat | green |
| CD-duration | 16m 8s (varav `Apply: Governance-Intermediate Root` 14m 25s) |
| Övriga apply-steg | 0s (skippade enligt stack-väljaren) |

---

## Phase 2 — Framåtspårning (PR → Azure-resurs)

Ta screenshot vid varje länk i kedjan. Spårningsobjektet är assignmenten
`T4 trace test — audit assignment` (mer iögonfallande i listvy än definitionen).

| Steg | Vad screenshoten ska visa | Filnamn |
|---|---|---|
| PR i GitHub | PR-nummer, beskrivning, "Merged"-status, författare | `t4-fwd-1-pr.png` |
| CI what-if-resultat | PR-trigger validerar exakt vilka Azure-resurser som ska skapas/modifieras | `t4-fwd-2-whatif.png` |
| Merge-commit | Commit SHA, författare, datum, meddelande | `t4-fwd-3-commit.png` |
| Workflow run översikt | CD-körning på main, status grön, 16m 8s, alla apply-steg utom valt skippade (0s) | `t4-fwd-4a-workflow.png` |
| Show inputs (expanderat) | workflow_dispatch-input visar vald stack | `t4-fwd-4b-input.png` |
| Deployment-jobb (header) | Stack-info: namn, template, params-fil, scope | `t4-fwd-5a-job-header.png` |
| Deployment-jobb (T4-resurser) | Logg med `T4-Trace-Audit-Tag`-träffar (definition + assignment) | `t4-fwd-5b-t4-resources1.png` + `t4-fwd-5b-t4-resources2.png` |
| Stack i portalen | Stack på Tenant Root MG, status Succeeded, last modified matchar CD | `t4-fwd-6-stack.png` |
| Policy assignment | `T4 trace test — audit assignment` synlig på alz MG | `t4-fwd-7-resource.png` |

---

## Phase 3 — Bakåtspårning (Azure-resurs → PR)

Bakåtspårning testar att kedjan är följbar i båda riktningarna. Eftersom flera
länkar är bidirektionella (Azure ↔ portal-vyer, GitHub commit ↔ PR) räcker det
att verifiera de icke-triviala stegen där spårning kräver aktivt arbete.

| Steg | Vad screenshoten ska visa | Filnamn |
|---|---|---|
| Stack → deployment | Top-level deployment på Tenant Root MG med correlation ID, start time, deployment name | `t4-bwd-1-deployment.png` |
| Deployment → workflow | GitHub Actions-loggrad i `Apply: Governance-Intermediate Root` med UTC-tidsstämpel som matchar Azure-deployens start time (modulo UTC↔CEST-offset) | `t4-bwd-2-workflow.png` |
| Workflow → PR | PR #96 — sluten cirkel, samma PR som framåtspårningen startade från | `t4-bwd-3-pr.png` |

---

## Phase 4 — Resultat

### 4.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| Framåtspårning fullständig (PR → resurs) | Ja, alla 9 länkar i kedjan dokumenterade utan brutna steg | Phase 2-screenshots |
| Bakåtspårning fullständig (resurs → PR) | Ja, deterministisk matchning via correlation ID + tidsstämpel | Phase 3-screenshots |
| Inga brutna länkar i kedjan | Inga | Genomgång av screenshots |
| Bakåtspårning landar på samma PR som framåtspårning startade från | Ja, PR #96 i båda ändar | jämför `t4-bwd-3-pr.png` mot `t4-fwd-1-pr.png` |

### 4.2 Observationer

**Cross-scope-spårning fungerar.** Deployment stacken bor på Tenant Root MG,
men de resurser den hanterar och de nestade deployments som skapar dem bor på
alz MG. Båda scopes är följbara via Azure Portal och delar correlation ID som
binder dem till samma stack-körning. Detta är en designad egenskap av
deployment stacks och värdefullt i en MSP-kontext där governance-orkestrering
ofta sker på högre scope än de styrda resurserna.

**Deploys på stack-nivå, inte resurs-nivå.** En CD-körning som triggades av en
T4-edit deployar hela `governance-int-root`-stackens innehåll (alla ALZ
policy-definitions, role-definitions, policy-set-definitions och
policy-assignments på alz MG), inte enbart de två T4-resurserna. Det är
förväntat beteende — deployment stacks opererar på stack-nivå och konvergerar
till deklarerat sluttillstånd snarare än kirurgisk resurs-uppdatering.

**Loggen rapporterar varje policy assignment två gånger.** AVM-pattern-modulen
propagerar resource-status från både den nestade modulen och dess parent-scope,
vilket ger två succeeded-rader per assignment i CD-loggen. Verifierat att det
endast skapas en faktisk resurs i Azure (synligt i Policy → Assignments).

**UTC↔lokal-tid-friktion mellan systemen.** GitHub Actions visar tidsstämplar
i UTC medan Azure Portal visar dem i lokal tid (CEST = UTC+2). Bakåtspårning
via tidsstämpel kräver att operatören kompenserar för 2 timmar. Sambandet är
fortfarande deterministiskt — Azure-deployens start time `12:02:09` (CEST)
matchade `Apply: Governance-Intermediate Root`-loggens `10:02:04` (UTC) på
sekund-nivå, vilket bekräftade att samma händelse spåras.

**Lokal `bicep build-params`-validering är inte möjlig.** Eftersom tenant-repot
använder `readEnvironmentVariable()` och `using`-statements som pekar på engine
under en CI-injicerad `platform/`-katalog, kan parameter-filer endast valideras
i CI-miljön. Pre-commit-validering faller bort som möjlighet — operatören får
förlita sig på CI som första syntax-gate.

### 4.3 Verdict

- [x] K6 Passed
- [ ] K6 Partially passed
- [ ] K6 Not passed

**En-meningskommentar:** Spårningen är fullständig och deterministisk i båda
riktningarna; identifierad operativ friktion (UTC↔lokal-tid, dubbelrapporterade
loggrader, cross-scope-navigering) bryter inte K6 men dokumenteras som
användarfriktion värd att känna till.

---

## Phase 5 — Cleanup

Skapa en följd-PR som återställer `customerPolicyDefs` och
`customerPolicyAssignments` till `[]` i `int-root.bicepparam`. Vid nästa CD
plockar `DeleteAll`-semantiken automatiskt bort både definitionen och
assignmenten från alz MG.

| Artefakt | Värde |
|---|---|
| Cleanup-PR | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/98|
| Merge SHA |4410be6|
| CD-körning som utförde städning |https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/25168187158/job/73779910725|
| Verifierat att `T4-Trace-Audit-Tag` saknas i portalen | Finns inte kvar|

Detta är inte en del av K6-bevisningen men är hygien — testartefakter ska inte
lämnas kvar i tenanten.

---

## Evidens-artefakter

1. Nio screenshots framåtspårning (`t4-fwd-1` till `t4-fwd-7`, vissa med a/b-suffix)
2. Tre screenshots bakåtspårning (`t4-bwd-1` till `t4-bwd-3`)
3. PR #96, merge-SHA `c0d0326`, CD-körning #81
4. Phase 4.2-observationer dokumenterar fyra fynd om operativ friktion

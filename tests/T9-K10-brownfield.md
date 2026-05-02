# T9 — Brownfield-kompatibilitet

**Test ID:** T9
**Criterion:** K10 Brownfield-kompatibilitet
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Tenant:** Sylaviken Nordlo-tenant

---

## Syfte

Visa att plattformen kan driftsättas mot en existerande Azure-tenant utan att förstöra
befintliga resurser, och att plattformen reagerar korrekt på drift mellan ALZ-policies
och custom policies. K10 är det test som mest direkt validerar plattformens
användbarhet i MSP-kontext.

K10 har två delaspekter:
1. **Brownfield-onboarding:** Existerande tenant-resurser respekteras vid initial
   plattform-deploy
2. **Drift-hantering:** Manuella ändringar av ALZ-managed resurser återställs;
   manuella ändringar av customer-managed resurser lämnas orörda

---

## Context

Sylaviken är Nordlos testmiljö och utgör ett brownfield-scenario enligt definitionen
i uppsatsen: en redan implementerad ALZ-hierarki som är clickops-deployad (manuellt
i portalen), inte deployad via IaC. T9 validerar **brownfield-integration** — att
plattformen kan deployas in i den existerande clickops-byggda hierarkin utan att
förstöra eller modifiera resurser som inte är explicit deklarerade i
tenant-konfigurationen.

Sylaviken-hierarkin är i *simple mode*: en platform-subscription istället för
separata management-/connectivity-/identity-subs, och en corp landing zone:

```
Tenant Root Group
└── ALZ
    ├── ALZ-decommissioned
    ├── ALZ-landingzones
    │   ├── ALZ-corp        → Sylaviken Corp Sub
    │   └── ALZ-online
    ├── ALZ-platform        → Sylaviken Mgmt Sub
    └── ALZ-sandboxes
```

Eftersom hierarkin redan finns och inga nätverksresurser ska sättas upp deployar
plattformen i governance-only-läge (`networking: false`, `core-logging: false`).
LAW-referensen i `int-root.bicepparam` pekar på Sylavikens existerande LAW i
Mgmt Sub.

---

## Engine prerequisite

Detta test förutsätter att följande engine-fixar är mergade och engine-repo:t är
taggat **`v1.1.4`** (eller senare):

1. **Precreate parameteriserad** — `cd-template.yaml` läser MG-namn från
   `MG_NAME_*` env vars istället för hårdkodade literaler. Utan detta skapar
   precreate parallella `landingzones`/`platform`/etc.-MG:er som syskon till
   Sylavikens `ALZ-*`-MG:er.
2. **`targetManagementGroupId` parameteriserad** — `cd-template.yaml` och
   `ci-template.yaml` använder `${{ env.MG_NAME_* }}` på alla what-if-steg.
   Utan detta skippar what-if tyst på brownfield-tenants → deploy körs utan
   validering.
3. **`cleanup.ps1` parameteriserad** — inte direkt T9-blocker (cleanup körs
   inte under testet) men krävs om någon retest behöver cleanup mellan körningar.

Och i tenant-config-template-repo:t (`alz-mgmt-oskar`):

4. **Tre `main-rbac.bicepparam` parameteriserade** — läser MG-namn från
   `MG_NAME_*` env vars. Utan detta misslyckas RBAC-stackarnas `existing`
   policy-assignment-lookups vid validation.

**Innan du börjar — verifiera:**

```bash
# I alz-mgmt-templates: senaste tag ska vara v1.1.4 eller senare
git -C ../alz-mgmt-templates describe --tags --abbrev=0

# I alz-mgmt-oskar: senaste main-commit ska inkludera RBAC-bicepparam-fixen
git -C ../alz-mgmt-oskar log --oneline main | grep -i "bicepparam\|main-rbac" | head -3
```

---

## Phase 0 — Pre-flight

### 0.1 Scope och tidsstämpel

Sylaviken är Nordlos testmiljö, så ingen kund-koordinering krävs. Inför körning,
dokumentera kort i `tests/evidence/t9-0-scope.md`:

- Scope (vilka MG:er, vilka subscriptions som ingår i körningen)
- Tidsstämpel för start (för att kunna korrelera mot loggar/audit i efterhand)
- Engine-version (commit SHA + tag) som testet körs mot

### 0.2 Pre-onboarding snapshot av Sylaviken

Detta är absolut-baselinen — innan onboarding-skriptet eller plattformen rör tenanten.
Ta screenshots i Azure Portal av varje vy nedan och spara i `tests/evidence/`.

| Vy | Var i portalen | Filnamn |
|---|---|---|
| MG-hierarki | Management groups (expandera alla noder) | `t9-0-pre-mg.png` |
| Policy definitions (Custom) | Policy → Definitions, filter Type = Custom | `t9-0-pre-policies.png` |
| Policy assignments på ALZ-MG | Policy → Assignments, scope = ALZ | `t9-0-pre-assignments.png` |
| Virtuella nätverk | Virtual networks (alla subs) | `t9-0-pre-vnets.png` |
| RGs i Mgmt Sub | Sylaviken Mgmt Sub → Resource groups | `t9-0-pre-mgmt-rgs.png` |
| RGs i Corp Sub | Sylaviken Corp Sub → Resource groups | `t9-0-pre-corp-rgs.png` |

Notera kort i `tests/evidence/t9-0-pre-baseline.md` antal resurser per kategori
för senare jämförelse.

### 0.3 Identifiera custom (non-ALZ) policy för Phase 5

Phase 5 testar att plattformen lämnar customer-managed (clickops-deployade) custom
policies orörda. Det kräver att en sådan policy faktiskt existerar i Sylaviken.

Inspektera `t9-0-pre-policies.png` (Phase 0.2) och välj en custom policy definition
som **inte** matchar något i `templates/core/governance/lib/alz/`. Notera namn och
ID i `tests/evidence/t9-0-phase5-target.md`.

Om Sylaviken endast har ALZ-bibliotekspolicies i custom-vyn (vilket kan hända i en
"ren" testmiljö): skapa en clickops-deployad custom policy i förväg. T.ex. en
trivial Audit-policy via Portal → Policy → Definitions → + Policy definition.
Dokumentera detta som del av Phase 0 i evidens-loggen.

### 0.4 Skapa Sylaviken-fork

Sylaviken får ett eget tenant-config-repo (samma mönster som `alz-mgmt-oskar`):

```bash
gh repo create ExjobbOA/alz-mgmt-sylaviken --template ExjobbOA/alz-mgmt-oskar --private
gh repo clone ExjobbOA/alz-mgmt-sylaviken
cd alz-mgmt-sylaviken

# Bumpa engine-version i CI/CD workflows till v1.1.4
sed -i 's|alz-mgmt-templates/.github/workflows/cd-template.yaml@v[0-9.]*|alz-mgmt-templates/.github/workflows/cd-template.yaml@v1.1.4|' .github/workflows/cd.yaml
sed -i 's|alz-mgmt-templates/.github/workflows/ci-template.yaml@v[0-9.]*|alz-mgmt-templates/.github/workflows/ci-template.yaml@v1.1.4|' .github/workflows/ci.yaml
sed -i 's|platform_ref: v[0-9.]*|platform_ref: v1.1.4|' .github/workflows/cd.yaml
```

Verifiera att båda workflow-filerna nu refererar `v1.1.4` på alla ställen:

```bash
grep -E "alz-mgmt-templates|platform_ref" .github/workflows/{cd,ci}.yaml
```

### 0.5 Brownfield-takeover

Generera `platform.json` och override-fragments mot Sylaviken. Detta är read-only —
det rör inte tenanten:

```powershell
cd ../alz-mgmt-templates/scripts/brownfield-takeover

# Steg 1: AzGovViz-discovery (om inte redan körd)
.\Run-AzGovViz.ps1 -TenantId '<sylaviken-tenant-id>' -OutputPath './azgovviz-output'

# Steg 2: Generera platform.json
.\Build-PlatformJson.ps1 `
  -AzGovVizPath './azgovviz-output' `
  -OutputPath '../../alz-mgmt-sylaviken/config/platform.json'

# Steg 3: Generera override-fragment (referens — inte committed direkt)
.\Build-OverrideFragments.ps1 `
  -AzGovVizPath './azgovviz-output' `
  -OutputPath './sylaviken-fragments'
```

Verifiera att genererad `platform.json` innehåller Sylaviken-specifika MG-namn:

```bash
cd ../alz-mgmt-sylaviken
grep -E "MG_NAME_(LANDINGZONES|SANDBOX|PLATFORM|CORP)" config/platform.json
# Förväntat:
#   "MG_NAME_LANDINGZONES": "ALZ-landingzones"
#   "MG_NAME_SANDBOX":      "ALZ-sandboxes"
#   "MG_NAME_PLATFORM":     "ALZ-platform"
#   "MG_NAME_CORP":         "ALZ-corp"
```

Om någon `MG_NAME_*` saknas eller har fel värde — stoppa och inspektera AzGovViz-
output. Phase 1 och precreate-steget i CD är beroende av att alla `MG_NAME_*`
är korrekt satta.

### 0.6 Sylaviken-specifika edits

Brownfield-takeover-scripten genererar `platform.json`. Övriga edits görs manuellt
i forken före commit.

#### 0.6.1 Excluded policy assignments — i BÅDA `main.bicepparam` OCH `main-rbac.bicepparam`

I linje med scope-begränsningen (governance-only, inga nätverksresurser) exkluderas
två policy assignments som har parametrar som pekar på nätverksresurser. **Båda
listorna måste hållas synkade** — main-stacken och RBAC-stacken läser från olika
bicepparam och måste komma överens, annars försöker RBAC slå upp policies som
main-stacken excluderade → 404 vid deploy.

**`config/core/governance/mgmt-groups/landingzones/landingzones-corp/main.bicepparam`** —
lägg till exclusion:

```bicep
param landingZonesCorpConfig = {
  ...
  managementGroupExcludedPolicyAssignments: ['Deploy-Private-DNS-Zones']
  ...
}
```

**`config/core/governance/mgmt-groups/landingzones/main.bicepparam`** — lägg till
exclusion (ersätt eventuell `effect: 'Audit'`-workaround från forkens template):

```bicep
param landingZonesConfig = {
  ...
  managementGroupExcludedPolicyAssignments: ['Enable-DDoS-VNET']
  ...
}
```

**`config/core/governance/mgmt-groups/landingzones/main-rbac.bicepparam`** — sync med
ovanstående:

```bicep
param parManagementGroupExcludedPolicyAssignments = ['Enable-DDoS-VNET']
```

`landingzones-corp` har ingen separat `main-rbac.bicepparam` — Deploy-Private-DNS-Zones-
exclusion behöver bara skrivas in på ett ställe där.

Konsekvensen — att corp MG saknar private-DNS-governance och landingzones MG
saknar DDoS-policy under T9 — noteras i Phase 6 verdict som en följdeffekt
av scope-begränsningen.

#### 0.6.2 Enforce-EncryptTransit-exclusion på int-root

Library-versionen `2026.04.0` har **inte** fixat case-sensitivity-buggen i
Enforce-EncryptTransit-policy-set:t (verifierat: `AKSIngressHttpsOnlyEffect`
har `default='deny'` med `allowedValues=['audit','deny','disabled']`, vilket
är inkonsistent mot built-in policy-definitionernas uppercase-krav). Behåll
exclusion i `config/core/governance/mgmt-groups/int-root.bicepparam`:

```bicep
param intRootConfig = {
  ...
  managementGroupExcludedPolicyAssignments: ['Enforce-EncryptTransit']
  ...
}
```

#### 0.6.3 Display names

Engine deployar med `createOrUpdateManagementGroup: true`, så MG display names
i tenant-config skriver över Sylavikens existerande display names. Sätt display
names i bicepparam-filerna att matcha Sylaviken exakt (avläs från
`t9-0-pre-mg.png`):

- `int-root.bicepparam`: `managementGroupDisplayName` ska matcha vad ALZ MG
  heter i Sylaviken
- `platform/main.bicepparam`: byt eventuell test-leftover (`'Platform (test)'`
  el. liknande) mot Sylavikens faktiska value
- `sandbox/main.bicepparam`: kontrollera plural/singular (`'Sandbox'` vs
  `'Sandboxes'`) — Sylaviken har `ALZ-sandboxes` så displaynamnet är troligen
  `'Sandboxes'`

Annars hamnar "modifierat: display name X→Y" på flera MG:er i Phase 3 diff,
vilket inte är destruktivt men skapar brus i evidensen.

#### 0.6.4 LAW-referens

`int-root.bicepparam` har en parameter som pekar på Log Analytics Workspace i
Sylaviken Mgmt Sub. Verifiera att den pekar på Sylavikens existerande LAW
(troligen `law-alz-swedencentral` per Nordlo-konvention):

```bash
grep -i "law\|logAnalytics" config/core/governance/mgmt-groups/int-root.bicepparam
```

#### 0.6.5 Commit och push

```bash
cd alz-mgmt-sylaviken
git add -A
git commit -m "Sylaviken-specific configuration

- platform.json generated from brownfield takeover (AzGovViz output)
- Excluded Enable-DDoS-VNET on landingzones (main + main-rbac, sync)
- Excluded Deploy-Private-DNS-Zones on landingzones-corp
- Excluded Enforce-EncryptTransit on int-root (library 2026.04.0
  case-sensitivity bug not fixed upstream)
- Display names match Sylaviken's existing clickops MG hierarchy
- Workflows pinned to engine v1.1.4"
git push
```

---

## Phase 1 — Onboarding

Onboarding-skriptet förbereder tenanten för plattformshantering: identity-RG,
UAMIs med federated identity credentials, role assignments på management-group,
GitHub environments med variables för CD-pipelinen. Detta måste köras först
eftersom CD förutsätter att dessa artefakter finns.

### 1.1 Kör onboard.ps1 mot Sylaviken

Från `alz-mgmt-templates`-repo:t, peka på Sylaviken-forken:

```powershell
cd alz-mgmt-templates

.\scripts\onboard.ps1 `
  -ConfigRepoPath          '../alz-mgmt-sylaviken' `
  -BootstrapSubscriptionId '<sylaviken-mgmt-sub-id>' `
  -ManagementGroupId       '<sylaviken-tenant-root-mg-id>' `
  -GithubOrg               'ExjobbOA' `
  -ModuleRepo              'alz-mgmt-sylaviken'
```

`Location` defaultar till `swedencentral`, `EnvPlan`/`EnvApply` till
`alz-mgmt-plan`/`alz-mgmt-apply` — alla OK för Sylaviken.

Kör först med `-DryRun` för att validera planen utan att rotera något:

```powershell
.\scripts\onboard.ps1 `
  -ConfigRepoPath          '../alz-mgmt-sylaviken' `
  -BootstrapSubscriptionId '<sylaviken-mgmt-sub-id>' `
  -ManagementGroupId       '<sylaviken-tenant-root-mg-id>' `
  -GithubOrg               'ExjobbOA' `
  -ModuleRepo              'alz-mgmt-sylaviken' `
  -DryRun
```

Sedan utan `-DryRun` när planen ser ut som förväntat.

**Resultat:** _paste_
**Duration:** _paste_
**Logg-fil:** _path_

### 1.2 Verifiera onboarding-artefakter

Bekräfta i portalen och i GitHub att förväntade artefakter är skapade. Notera
att script:et skapar **UAMI:er + federated identity credentials**, inte en
service principal med client secret:

| Artefakt | Var | Förväntat | Bekräftat | Screenshot |
|---|---|---|---|---|
| Identity RG | Sylaviken Mgmt Sub → Resource groups | `rg-alz-mgmt-identity-swedencentral-1` | _ | `t9-1-identity-rg.png` |
| UAMI plan | Identity RG | `id-alz-mgmt-swedencentral-plan-1` | _ | `t9-1-uami-plan.png` |
| UAMI apply | Identity RG | `id-alz-mgmt-swedencentral-apply-1` | _ | `t9-1-uami-apply.png` |
| FIC plan | UAMI plan → Federated credentials | `repo:ExjobbOA/alz-mgmt-sylaviken:environment:alz-mgmt-plan` | _ | `t9-1-fic-plan.png` |
| FIC apply | UAMI apply → Federated credentials | `repo:ExjobbOA/alz-mgmt-sylaviken:environment:alz-mgmt-apply` | _ | `t9-1-fic-apply.png` |
| RBAC plan UAMI | Sylaviken root MG → Role assignments | Reader på root MG | _ | `t9-1-rbac-plan.png` |
| RBAC apply UAMI | Sylaviken root MG → Role assignments | Owner på root MG | _ | `t9-1-rbac-apply.png` |
| GitHub env plan | Repo → Settings → Environments | `alz-mgmt-plan` med variables | _ | `t9-1-gh-env-plan.png` |
| GitHub env apply | Repo → Settings → Environments | `alz-mgmt-apply` med variables | _ | `t9-1-gh-env-apply.png` |
| Variables | Variables i båda environments | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (per-env) | _ | `t9-1-gh-variables.png` |

### 1.3 Sanity-check mot baseline efter onboarding

Ta nya screenshots av RG-vyerna i Mgmt Sub och Corp Sub. Lägg sida vid sida mot
baseline från Phase 0.2:

| Sub | Baseline | Efter onboarding | Diff |
|---|---|---|---|
| Sylaviken Mgmt Sub | `t9-0-pre-mgmt-rgs.png` | `t9-1-post-onboarding-mgmt-rgs.png` | _ |
| Sylaviken Corp Sub | `t9-0-pre-corp-rgs.png` | `t9-1-post-onboarding-corp-rgs.png` | _ |

Förväntat: enbart identity-RG (`rg-alz-mgmt-identity-swedencentral-1`) tillkommen
i Mgmt Sub. Corp Sub oförändrad. Inga RG borttagna eller renamead.

---

## Phase 2 — Initial CD-deploy

### 2.1 Trigga CD mot Sylaviken

CD-workflow:n har bara `workflow_dispatch:` som trigger. Trigga via
GitHub-UI:t eller `gh`:

```bash
cd alz-mgmt-sylaviken
gh workflow run cd.yaml
gh run watch
```

**CD run URL:** _paste_
**Resultat:** _green/red_
**Duration:** _paste_

### 2.2 Stack-state efter deploy

Verifiera deployment stacks i portalen för respektive scope. Stack-namnen prefixas
med intermediate root MG ID:t (`ALZ` för Sylaviken). I simple mode med governance-
only deployas följande stacks:

| Scope | Stack-namn | actionOnUnmanage | Förväntat | Screenshot |
|---|---|---|---|---|
| Tenant Root MG | `ALZ-governance-int-root` | DeleteAll | Succeeded | `t9-2-stack-int-root.png` |
| ALZ MG | `ALZ-governance-landingzones` | DeleteAll | Succeeded | `t9-2-stack-landingzones.png` |
| ALZ MG | `ALZ-governance-landingzones-corp` | DeleteAll | Succeeded | `t9-2-stack-landingzones-corp.png` |
| ALZ MG | `ALZ-governance-landingzones-online` | DeleteAll | Succeeded | `t9-2-stack-landingzones-online.png` |
| ALZ MG | `ALZ-governance-platform` | DeleteAll | Succeeded | `t9-2-stack-platform.png` |
| ALZ MG | `ALZ-governance-sandbox` | DeleteAll | Succeeded | `t9-2-stack-sandbox.png` |
| ALZ MG | `ALZ-governance-decommissioned` | DeleteAll | Succeeded | `t9-2-stack-decomm.png` |
| ALZ MG | `ALZ-governance-platform-rbac` | DeleteAll | Succeeded | `t9-2-stack-platform-rbac.png` |
| ALZ MG | `ALZ-governance-landingzones-rbac` | DeleteAll | Succeeded | `t9-2-stack-landingzones-rbac.png` |

Notera särskilt att alla governance-stacks använder `actionOnUnmanage: DeleteAll`
— det är "farligare" valet jämfört med `DetachAll`. Att brownfield-skydd ändå
håller (Phase 3) är därmed starkare evidens för K10.

För varje stack, notera:

| Stack | ProvisioningState | Resources count | Detached count |
|---|---|---|---|
| _ | _ | _ | _ |

---

## Phase 3 — Post-deploy snapshot och diff

### 3.1 Dokumentera post-deploy state

Ta samma uppsättning screenshots som Phase 0.2 men med `t9-3-post-`-prefix på
filnamnen.

### 3.2 Diff per kategori

Lägg pre-onboarding-screenshots (Phase 0.2) sida vid sida mot post-deploy-screenshots
(Phase 3.1). Notera vad som tillkommit, borttagits, och modifierats per kategori:

| Kategori | Tillkommit | Borttaget | Modifierat | Källa |
|---|---|---|---|---|
| MG-hierarki | _ | _ | _ | `t9-0-pre-mg.png` vs `t9-3-post-mg.png` |
| Policy assignments | _ | _ | _ | `t9-0-pre-assignments.png` vs `t9-3-post-assignments.png` |
| Custom policies | _ | _ | _ | `t9-0-pre-policies.png` vs `t9-3-post-policies.png` |
| Vnets | _ | _ | _ | `t9-0-pre-vnets.png` vs `t9-3-post-vnets.png` |
| RGs (Mgmt + Corp) | _ | _ | _ | `t9-0-pre-*-rgs.png` vs `t9-3-post-*-rgs.png` |

Förväntat:
- **Tillkommit:** onboarding-artefakter (identity-RG från Phase 1) + ALZ
  policy-assignments och policy-definitions på existerande MG:er. **Inga nya
  MG:er** (clickops-hierarkin återanvänds tack vare parameteriserat precreate),
  **inga nya nätverksresurser** (governance-only).
- **Borttaget: 0 clickops-deployade resurser**
- **Modifierat:** endast policy-scopes som plattformen explicit deklarerar.
  MG display names kan flagga som "modifierat" om Phase 0.6.3 inte gjordes
  helt komplett — notera i så fall som icke-destruktivt.

Notera särskilt: i simple mode med `parIncludeSubMgPolicies=true` på platform-MG
hamnar även 4-5 connectivity/identity-policies (`Enable-DDoS-VNET`,
`Deny-MgmtPorts-Internet`, `Deny-Public-IP`, `Deny-Subnet-Without-Nsg`,
`Deploy-VM-Backup`) på `ALZ-platform` direkt. `Enable-DDoS-VNET` har
`effect: 'Audit'`-override (inert utan VNet/DDoS-plan); de andra är rena
Deny/Audit utan parameter-beroenden. Förväntat och dokumenterat — inte fail.

---

## Phase 4 — Drift-hantering: ALZ-managed policy

### 4.1 Manuell ändring i portalen

Välj en ALZ-managed policy assignment, ändra dess parameter manuellt i Azure Portal.

**Vald policy:** _paste_
**Ändring:** _paste_
**Screenshot med drift:** `t9-4-alz-drift-applied.png`

### 4.2 Trigga CD

```bash
cd alz-mgmt-sylaviken
gh workflow run cd.yaml
gh run watch
```

(CD-workflow:n har endast `workflow_dispatch:` som trigger — push-trigger fungerar
inte.)

**CD run URL:** _paste_

### 4.3 Verifiera återställning

Öppna policy assignment i portalen efter att CD körts (Policy → Assignments → välj
policyn → Parameters-fliken). Bekräfta att den manuella ändringen är överskriven av
ALZ-värdet.

**Screenshot efter CD (återställd):** `t9-4-alz-drift-restored.png`

Förväntat: parametern är tillbaka till ALZ-deklarerat värde.

---

## Phase 5 — Drift-hantering: customer-managed policy

### 5.1 Identifiera customer-policy

Använd policyn identifierad i Phase 0.3 (custom policy som inte är från ALZ-
biblioteket).

**Vald policy:** _paste från Phase 0.3-evidens_

### 5.2 Manuell ändring

Ändra parametern manuellt i portalen.

**Screenshot med drift:** `t9-5-clickops-drift-applied.png`

### 5.3 Trigga CD

```bash
cd alz-mgmt-sylaviken
gh workflow run cd.yaml
gh run watch
```

**CD run URL:** _paste_

### 5.4 Verifiera att den clickops-deployade policyn är orörd

Öppna policy definition i portalen efter CD (Policy → Definitions → välj policyn →
Definition-fliken). Bekräfta att den manuella ändringen finns kvar.

**Screenshot efter CD (orörd):** `t9-5-clickops-untouched.png`

Förväntat: policyn behåller den manuella ändringen — plattformen rör inte
clickops-deployade resurser som inte är explicit deklarerade i tenant-konfigurationen.

---

## Phase 6 — Resultat

### 6.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| Onboarding skapar enbart förväntade artefakter (identity-RG, 2 UAMIs, FICs, RBAC, GH envs) | _ | Phase 1 |
| 0 customer-resurser raderade vid initial deploy | _ | Phase 3 |
| 0 nya/parallella MG:er skapade (clickops-hierarkin återanvänds) | _ | Phase 3 |
| ALZ-introducerade resurser (policies, role assignments) tillkommer som väntat | _ | Phase 3 |
| ALZ-managed drift återställs av nästa CD | _ | Phase 4 |
| Customer-managed resurser lämnas orörda | _ | Phase 5 |

### 6.2 Observationer

[Fyll i efter körning]

### 6.3 Verdict

- [ ] K10 Passed (båda delaspekterna verifierade)
- [ ] K10 Partially passed (en delaspekt verifierad)
- [ ] K10 Not passed

**En-meningskommentar:** _paste efter körning_

### 6.4 Noteringar för thesis

- Library 2026.04.0 löste **inte** Enforce-EncryptTransit case-sensitivity-buggen.
  Exclusion behölls. Lyft som limitation och separat upstream-issue.
- Excluded-policy-listan måste hållas synkad mellan `main.bicepparam` och
  `main-rbac.bicepparam` manuellt — Bicep tillåter inte env-vars att vara
  arrayer. Värd att lyfta som limitation och möjlig framtida förbättring
  (`@export`-mönster med delad bicep-fil).
- `parIncludeSubMgPolicies=true` i simple mode flyttar connectivity/identity-
  policies upp till platform-MG:n. `Enable-DDoS-VNET` har Audit-override för
  att förbli inert utan VNet/DDoS-plan; de andra fyra är rena Deny/Audit utan
  parameter-beroenden. Förväntat ALZ-beteende, ej fail.

---

## Evidens-artefakter

**Phase 0 — Baseline + förberedelser:**
- `t9-0-scope.md` — scope, tidsstämpel, engine-version
- `t9-0-pre-mg.png`, `t9-0-pre-policies.png`, `t9-0-pre-assignments.png`,
  `t9-0-pre-vnets.png`, `t9-0-pre-mgmt-rgs.png`, `t9-0-pre-corp-rgs.png`
- `t9-0-pre-baseline.md` — antal resurser per kategori
- `t9-0-phase5-target.md` — vald custom policy för Phase 5
- Sylaviken-fork commit-SHA (länk till GitHub commit)

**Phase 1 — Onboarding:**
- Onboarding-script logg
- `t9-1-identity-rg.png`, `t9-1-uami-plan.png`, `t9-1-uami-apply.png`,
  `t9-1-fic-plan.png`, `t9-1-fic-apply.png`, `t9-1-rbac-plan.png`,
  `t9-1-rbac-apply.png`, `t9-1-gh-env-plan.png`, `t9-1-gh-env-apply.png`,
  `t9-1-gh-variables.png`
- `t9-1-post-onboarding-mgmt-rgs.png`, `t9-1-post-onboarding-corp-rgs.png`

**Phase 2 — CD-deploy:**
- CD run URL
- `t9-2-stack-int-root.png`, `t9-2-stack-landingzones.png`,
  `t9-2-stack-landingzones-corp.png`, `t9-2-stack-landingzones-online.png`,
  `t9-2-stack-platform.png`, `t9-2-stack-sandbox.png`,
  `t9-2-stack-decomm.png`, `t9-2-stack-platform-rbac.png`,
  `t9-2-stack-landingzones-rbac.png`

**Phase 3 — Post-deploy diff:**
- Samma vyer som Phase 0.2 men med `t9-3-post-`-prefix

**Phase 4 — ALZ-drift:**
- CD run URL för drift-trigger
- `t9-4-alz-drift-applied.png`, `t9-4-alz-drift-restored.png`

**Phase 5 — Clickops-drift:**
- CD run URL för drift-trigger
- `t9-5-clickops-drift-applied.png`, `t9-5-clickops-untouched.png`

---

## Notering

Sylaviken är Nordlos testmiljö, inte en skarp kund-tenant. Det betyder att rollback
och felsökning kan göras utan kund-koordinering, men exekveringen ska ändå loggas
ordentligt så att resultaten håller som evidens för K10. Vid oväntade resultat —
stoppa, dokumentera, och stäm av med Jesper innan fortsatt arbete.

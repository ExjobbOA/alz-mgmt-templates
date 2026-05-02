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
i uppsatsen: en redan implementerad ALZ-hierarki som är portal-deployad (ALZ
Accelerator-upplevelsen), inte deployad via IaC. T9 validerar **brownfield-integration**
— att plattformen kan deployas in i den existerande portal-byggda hierarkin utan att
förstöra eller modifiera resurser som inte är explicit deklarerade i
tenant-konfigurationen.

### Tenant-struktur (verifierad 2026-05-02)

```
Tenant Root Group  (adf9c0bb-91e2-4d3b-9a83-9a7ef2412bcf)
├── (3 subs UTANFÖR ALZ-hierarkin — out of scope för T9)
│   ├── Azure subscription 1 - Sylaviken    10738f61-8bdd-413f-90f3-bf43466d3150
│   ├── Sylaviken Conn Sub                   e7d6973c-6844-456c-b3fa-3c88aa5925b9
│   └── Sylaviken Identity Sub               e55d4377-5480-44da-b459-088f7e14084e
├── ALZ                                       (intermediate root)
│   ├── ALZ-decommissioned                    (0 subs)
│   ├── ALZ-landingzones
│   │   ├── ALZ-corp                          → Sylaviken Corp Sub  db8f96fe-826b-4fa0-9252-d655d3f62854
│   │   └── ALZ-online                        (0 subs)
│   ├── ALZ-platform                          → Sylaviken Mgmt Sub  93ff5894-3e0b-4de9-9438-80e0fb7100de
│   └── ALZ-sandboxes                         (0 subs)
└── sylaviken                                 (syskon-MG, 0 subs, out of scope)
```

Sylaviken-hierarkin är i *simple mode*: en platform-subscription istället för
separata management-/connectivity-/identity-subs, och en corp landing zone.
Eftersom hierarkin redan finns och inga nätverksresurser ska sättas upp deployar
plattformen i governance-only-läge (`networking: false`, `core-logging: false`).
LAW-referensen i `int-root.bicepparam` patchas att peka på Sylavikens existerande
LAW (se Phase 0.6.4) — Sylaviken använder ALZ Accelerator-portal-naming
(`ALZ-mgmt`-RG, `ALZ-law`), inte ALZ-Bicep-konventionen (`rg-alz-logging-*`,
`law-alz-*`).

### Out-of-scope (dokumenterat för Phase 3-diff-tolkning)

T9 scope:ar till `ALZ`-MG och nedåt. Följande är out-of-scope och ska vara
oberörda efter Phase 6:
- 3 Tenant-Root-subs (`Azure subscription 1 - Sylaviken`, `Sylaviken Conn Sub`,
  `Sylaviken Identity Sub`)
- Syskon-MG `sylaviken`
- Resurser i Mgmt Sub utanför `ALZ-mgmt`-RG: `rg-alz-prereqs` (portal-deploy-
  artefakter), `rg-amba-monitoring-001` (AMBA baseline alerts),
  `NetworkWatcherRG` (auto-skapad av Azure), `rg-copilot-weu` och
  `VisualStudioOnline-*` (Microsoft Copilot / Dev-resurser i West Europe)

---

## Engine prerequisite

Detta test förutsätter att följande engine-fixar är mergade och engine-repo:t är
taggat **`v1.1.5`** (eller senare):

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
# I alz-mgmt-templates: senaste tag ska vara v1.1.5 eller senare
git -C ../alz-mgmt-templates describe --tags --abbrev=0

# I alz-mgmt-oskar: senaste main-commit ska inkludera RBAC-bicepparam-fixen
git -C ../alz-mgmt-oskar log --oneline main | grep -i "bicepparam\|main-rbac" | head -3
```

---

## Operatör-rättigheter

För att köra hela T9-cykeln (takeover + onboard + CD + drift-test + cleanup) krävs
**Owner @ Tenant Root Group** för operatörens personliga konto. Detta motiveras av:

- Onboard-deployen tilldelar UAMI:erna **Owner** på Tenant Root MG (apply-UAMI)
  och **Reader** + custom WhatIf-roll (plan-UAMI). För att kunna utföra dessa
  role assignments måste operatören själv kunna tilldela Owner — vilket kräver
  Owner eller User Access Administrator på samma scope.
- Owner ger även rätt att skapa custom role definitions (krävs för
  `Landing Zone Reader (WhatIf/Validate)`-rollen som bootstrap-bicepen skapar).
- Sylaviken är Nordlos testmiljö — pragmatiskt motiverbart i thesis, inte
  appropriate för skarp kund-tenant.

**Tilldelnings-procedur** (kräver Global Admin → Elevate Access om Azure RBAC inte
redan är aktiverat på root-scope):

1. Portal → Microsoft Entra ID → Properties → toggle "Access management for Azure
   resources" till **Yes** → Save → vänta 30-60s → logga ut/in
2. Portal → Management groups → Tenant Root Group → Access control (IAM) → + Add
   → Add role assignment
3. Role: **Owner** (highly privileged-varianten — krävs för att kunna tilldela
   Owner till UAMI:er senare i onboard) → Members: ditt konto → Assignment type:
   **Active** + duration: **Permanent** → Review + assign
4. Tillbaka till Microsoft Entra ID → Properties → toggle till **No** → Save

**Cleanup efter Phase 6:**
- Tenant Root → IAM → välj din egen Owner-tilldelning → Remove
- UAMI:erna behåller sina rättigheter (de driver framtida CD)

**Audit-spår:** dokumentera i `tests/evidence/t9-0-scope.md`:
```
Operatör-rättigheter under T9:
- <datum tid>: Elevated access aktiverat
- <datum tid>: Owner @ Tenant Root Group tilldelat oskar@...
- <datum tid>: Elevated access deaktiverat
- (Owner-tilldelningen kvar tills T9 Phase 6 verdict)
- <datum>: Owner-tilldelningen borttagen efter T9-cleanup
```

---

## Phase 0 — Pre-flight

### 0.1 Scope och tidsstämpel

Sylaviken är Nordlos testmiljö, så ingen kund-koordinering krävs. Inför körning,
dokumentera kort i `tests/evidence/t9-0-scope.md`:

- Scope (vilka MG:er, vilka subscriptions som ingår i körningen — använd
  Tenant-struktur-blocket från Context som referens)
- Tidsstämpel för start (för att kunna korrelera mot loggar/audit i efterhand)
- Engine-version: `v1.1.5` + commit SHA
- Operatör-rättigheter (se "Operatör-rättigheter"-sektionen ovan)

### 0.2 Pre-onboarding snapshot av Sylaviken

Detta är absolut-baselinen — innan något skript eller plattformen rör tenanten.
Ta screenshots i Azure Portal av varje vy nedan och spara i `tests/evidence/`.

| Vy | Var i portalen | Filnamn |
|---|---|---|
| MG-hierarki | Management groups (expandera alla noder) | `t9-0-pre-mg.png` |
| Policy definitions (Custom) | Policy → Definitions, filter Type = Custom | `t9-0-pre-policies.png` |
| Policy assignments på ALZ-MG | Policy → Assignments, scope = ALZ | `t9-0-pre-assignments.png` |
| Virtuella nätverk | Virtual networks (alla subs) | `t9-0-pre-vnets.png` |
| RGs i Mgmt Sub | Sylaviken Mgmt Sub → Resource groups | `t9-0-pre-mgmt-rgs.png` |
| RGs i Corp Sub | Sylaviken Corp Sub → Resource groups | `t9-0-pre-corp-rgs.png` |
| Resurser i ALZ-mgmt RG | Sylaviken Mgmt Sub → ALZ-mgmt → Overview | `t9-0-pre-alz-mgmt-resources.png` |

Notera kort i `tests/evidence/t9-0-pre-baseline.md`:

```
Tenant: 5 subs och 9 MG:er totalt; T9 scope:ar till ALZ-hierarkin (1 platform-sub
+ 1 corp-sub). Tre Tenant-Root-subs och syskon-MG `sylaviken` är out-of-scope.

Sylaviken Mgmt Sub innehåller 6 RGs:
- ALZ-mgmt        — logging (LAW + DCR + UAMI + Automation Account) — INOM scope
- rg-alz-prereqs   — portal-deploy-artefakter — out of scope
- rg-amba-monitoring-001 — AMBA baseline alerts — out of scope
- NetworkWatcherRG — auto-skapad av Azure — out of scope
- rg-copilot-weu / VisualStudioOnline-* — Microsoft Copilot/Dev-resurser
  (West Europe) — out of scope

Naming-konvention i ALZ-mgmt avviker från ALZ-Bicep-defaults:
- LAW heter ALZ-law (inte law-alz-swedencentral)
- AMA UAMI heter id-ama-prod-swedencentral-001 (inte id-alz-ama-swedencentral)
- DCR:s heter dcr-{type}-prod-swedencentral-001 (inte dcr-alz-{type}-swedencentral)
- Automation Account ALZ-aauto med legacy ChangeTracking solution

Detta är ett autentiskt brownfield-scenario och kräver patching av int-root.bicepparam
var-deklarationer (se Phase 0.6.4).
```

### 0.3 Skapa custom (non-ALZ) policy för Phase 5

Phase 5 testar att plattformen lämnar customer-managed (clickops-deployade) custom
policies orörda. Eftersom Sylaviken inte har egna custom policies skapar vi en
tydligt märkt test-policy som städas bort efter T9.

**Skapa via Portal → Policy → Definitions → + Policy definition. Sätt scope till
`ALZ` MG.** Fyll i:

- **Name:** `T9-Test-Audit-StorageHttpsOnly`
- **Display name:** `[T9 TEST — DELETE AFTER 2026-XX-XX] Audit storage accounts with HTTPS-only disabled`
- **Description:** `Test-only policy created for thesis test T9 (K10 brownfield). Safe to delete after test completion. Owner: Oskar / ExjobbOA.`
- **Category:** välj Create new → `T9-test`
- **Definition:** klistra in:

```json
{
  "mode": "All",
  "policyRule": {
    "if": {
      "allOf": [
        { "field": "type", "equals": "Microsoft.Storage/storageAccounts" },
        { "field": "Microsoft.Storage/storageAccounts/supportsHttpsTrafficOnly", "equals": "false" }
      ]
    },
    "then": { "effect": "[parameters('effect')]" }
  },
  "parameters": {
    "effect": {
      "type": "String",
      "metadata": {
        "displayName": "Effect",
        "description": "Audit by default — drift target for T9 Phase 5"
      },
      "allowedValues": ["Audit", "Disabled"],
      "defaultValue": "Audit"
    }
  }
}
```

**Tilldela** policyn till `ALZ` MG via Portal → Policy → Assignments → Assign policy
→ scope: `ALZ` MG → välj `T9-Test-Audit-StorageHttpsOnly` → behåll default `Audit`
på effect-parametern → Review + create.

Spara screenshot av definition-vyn (`t9-0-phase5-target.png`) **före** AzGovViz-
körningen — bevis på att policyn fanns innan takeover-scripten kördes.

Notera definition-ID och assignment-ID i `tests/evidence/t9-0-phase5-target.md`.

### 0.4 Skapa Sylaviken-fork

Sylaviken får ett eget tenant-config-repo (samma mönster som `alz-mgmt-oskar`):

```bash
gh repo create ExjobbOA/alz-mgmt-sylaviken --template ExjobbOA/alz-mgmt-oskar --private
gh repo clone ExjobbOA/alz-mgmt-sylaviken
cd alz-mgmt-sylaviken

# Bumpa engine-version i CI/CD workflows till v1.1.5
sed -i 's|alz-mgmt-templates/.github/workflows/cd-template.yaml@v[0-9.]*|alz-mgmt-templates/.github/workflows/cd-template.yaml@v1.1.5|' .github/workflows/cd.yaml
sed -i 's|alz-mgmt-templates/.github/workflows/ci-template.yaml@v[0-9.]*|alz-mgmt-templates/.github/workflows/ci-template.yaml@v1.1.5|' .github/workflows/ci.yaml
sed -i 's|platform_ref: v[0-9.]*|platform_ref: v1.1.5|' .github/workflows/cd.yaml
```

Verifiera att båda workflow-filerna nu refererar `v1.1.5` på alla ställen:

```bash
grep -E "alz-mgmt-templates|platform_ref" .github/workflows/{cd,ci}.yaml
```

### 0.5 Brownfield-takeover

Generera `platform.json` och override-fragments mot Sylaviken. Detta är skrivskyddat
mot Sylaviken — inget rörs i tenanten.

#### 0.5.1 Setup (engångsuppgift)

```powershell
# Workspace-layout: alz-mgmt-templates och Azure-Governance-Visualizer ska vara siblings
cd <workspace>
git clone https://github.com/Azure/Azure-Governance-Visualizer.git

# Verifiera Az-modulerna
Get-Module -ListAvailable Az.Accounts, Az.Resources | Select-Object Name, Version
# Om tomt: Install-Module -Name Az -Scope CurrentUser -Force -AllowClobber

# Autentisera mot Sylaviken
Connect-AzAccount -Tenant <sylaviken-tenant-id>
Set-AzContext -Subscription 93ff5894-3e0b-4de9-9438-80e0fb7100de  # Mgmt Sub

# Verifiera att hela hierarkin är synlig (kräver Owner från sektionen ovan)
Get-AzManagementGroup | Select-Object Name, DisplayName
```

#### 0.5.2 AzGovViz-discovery

```powershell
cd <workspace>/alz-mgmt-templates
New-Item -ItemType Directory -Force `
    -Path ./scripts/brownfield-takeover/azgovviz-output

cd ../Azure-Governance-Visualizer

./pwsh/AzGovVizParallel.ps1 `
    -ManagementGroupId 'ALZ' `
    -OutputPath ../alz-mgmt-templates/scripts/brownfield-takeover/azgovviz-output `
    -NoMDfCSecureScore `
    -NoPolicyComplianceStates `
    -NoResourceDiagnosticsPolicyLifecycle `
    -NoPIMEligibility `
    -NoResources `
    -NoCsvExport
```

Output hamnar i `JSON_ALZ_<yyyyMMdd_HHmmss>/`. Förväntad körtid 3-10 min för en
liten tenant.

#### 0.5.3 Generera platform.json + fragment

```powershell
cd ../alz-mgmt-templates

$jsonRoot = Get-ChildItem ./scripts/brownfield-takeover/azgovviz-output -Directory -Filter 'JSON_*' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

./scripts/brownfield-takeover/Build-PlatformJson.ps1 `
    -AzGovVizJsonPath $jsonRoot.FullName `
    -OutputDirectory  ./scripts/brownfield-takeover/takeover-fragments

./scripts/brownfield-takeover/Build-OverrideFragments.ps1 `
    -AzGovVizJsonPath $jsonRoot.FullName `
    -OutputDirectory  ./scripts/brownfield-takeover/takeover-fragments `
    -AlzLibraryPath   ./templates/core/governance/lib/alz
```

#### 0.5.4 Granska och kopiera platform.json

Verifiera att genererad `platform.json` innehåller Sylaviken-specifika MG-namn
och förväntade subscription-ID:n:

```bash
cat ./scripts/brownfield-takeover/takeover-fragments/platform.json
```

Förväntat:
```json
{
  "PLATFORM_MODE": "simple",
  "INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID": "ALZ",
  "MANAGEMENT_GROUP_ID": "adf9c0bb-91e2-4d3b-9a83-9a7ef2412bcf",
  "MG_NAME_PLATFORM":       "ALZ-platform",
  "MG_NAME_LANDINGZONES":   "ALZ-landingzones",
  "MG_NAME_CORP":           "ALZ-corp",
  "MG_NAME_ONLINE":         "ALZ-online",
  "MG_NAME_SANDBOX":        "ALZ-sandboxes",
  "MG_NAME_DECOMMISSIONED": "ALZ-decommissioned",
  "MG_NAME_CONNECTIVITY":   "",
  "MG_NAME_IDENTITY":       "",
  "MG_NAME_MANAGEMENT":     "",
  "MG_NAME_SECURITY":       "",
  "SUBSCRIPTION_ID_MANAGEMENT": "93ff5894-3e0b-4de9-9438-80e0fb7100de",
  "SUBSCRIPTION_ID_PLATFORM":   "93ff5894-3e0b-4de9-9438-80e0fb7100de",
  "SUBSCRIPTION_ID_*":          "(samma sub-id pga simple mode)",
  "LOCATION":         "swedencentral",
  "LOCATION_PRIMARY": "swedencentral",
  "ENABLE_TELEMETRY": "true",
  ...
}
```

Om någon `MG_NAME_*` saknas eller har fel värde — stoppa och inspektera AzGovViz-
output. Phase 1 och precreate-steget i CD är beroende av att alla `MG_NAME_*`
är korrekt satta.

Kopiera till forken:
```bash
cp ./scripts/brownfield-takeover/takeover-fragments/platform.json \
   ../alz-mgmt-sylaviken/config/platform.json
```

#### 0.5.5 Granska override-fragments

Granskning enligt brownfield-takeover/README.md sektion "Granska outputen".
Tre delmoment:

- **A. Granska platform.json** (gjord ovan)
- **B. Städa overrides** — ta bort brus där `Audit-*`/`Deny-*`/`Deploy-*`-prefix
  upprepar definitionens default
- **C. Parametrisera matchande literaler** — där en literal matchar konvention,
  byt mot `lawResourceId`/`location`/`securityEmail`-variabel. **OBS:** Sylaviken
  matchar **inte** ALZ-Bicep-konventionen för logging-resurser (se Phase 0.6.4),
  så `lawResourceId`-patchningen måste göras i `int-root.bicepparam`-vars först,
  sedan kan overrides referera variabeln.

Verifiera också att `custom-assignments.txt` listar `T9-Test-Audit-StorageHttpsOnly`
— bevis på att policyn fångades av AzGovViz som customer-managed.

### 0.6 Sylaviken-specifika edits

Brownfield-takeover-scripten genererar `platform.json` och fragment. Övriga edits
görs manuellt i forken före commit.

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

**`config/core/governance/mgmt-groups/landingzones/main-rbac.bicepparam`** — sync
med ovanstående:

```bicep
param parManagementGroupExcludedPolicyAssignments = ['Enable-DDoS-VNET']
```

`landingzones-corp` har ingen separat `main-rbac.bicepparam` — Deploy-Private-DNS-
Zones-exclusion behöver bara skrivas in på ett ställe där.

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

- `int-root.bicepparam`: `managementGroupDisplayName` = `'ALZ'` (matchar
  display name som syns i Tenant-struktur-diagrammet)
- `platform/main.bicepparam`: byt eventuell test-leftover (`'Platform (test)'`
  el. liknande) mot `'ALZ-platform'`
- `sandbox/main.bicepparam`: ändra display name till `'ALZ-sandboxes'` (plural)
- `landingzones/main.bicepparam`, `landingzones-corp/main.bicepparam`,
  `landingzones-online/main.bicepparam`, `decommissioned/main.bicepparam`:
  matcha Sylaviken-display-names exakt

Annars hamnar "modifierat: display name X→Y" på flera MG:er i Phase 3 diff,
vilket inte är destruktivt men skapar brus i evidensen.

#### 0.6.4 LAW + logging-resurser — patcha int-root.bicepparam vars

**Sylaviken matchar inte ALZ-Bicep-konventionen** för logging-resurser. Engine-
template:t förutsätter `rg-alz-logging-${location}` + `law-alz-${location}`, men
Sylaviken har:

| Resurstyp | ALZ-Bicep-konvention | Sylaviken-faktiskt |
|---|---|---|
| Logging RG | `rg-alz-logging-swedencentral` | `ALZ-mgmt` |
| LAW | `law-alz-swedencentral` | `ALZ-law` |
| AMA UAMI | `id-alz-ama-swedencentral` | `id-ama-prod-swedencentral-001` |
| ChangeTracking DCR | `dcr-alz-changetracking-swedencentral` | `dcr-changetracking-prod-swedencentral-001` |
| DefenderSQL DCR | `dcr-alz-defendersql-swedencentral` | `dcr-defendersql-prod-swedencentral-001` |
| VMInsights DCR | `dcr-alz-vminsights-swedencentral` | `dcr-vminsights-prod-swedencentral-001` |
| Automation Account | n/a (nyare ALZ använder DCR) | `ALZ-aauto` (+ legacy ChangeTracking solution) |

I `config/core/governance/mgmt-groups/int-root.bicepparam` (rad 10-12), patcha
`var`-deklarationerna:

```bicep
// Före (ALZ-Bicep-konvention):
var rgLogging = 'rg-alz-logging-${location}'
var lawName = 'law-alz-${location}'
var lawResourceId = '/subscriptions/${subIdMgmt}/resourceGroups/${rgLogging}/providers/Microsoft.OperationalInsights/workspaces/${lawName}'

// Efter (Sylaviken — portal-deployed ALZ Accelerator naming):
// Sylaviken uses ALZ Accelerator (portal-deployed) naming, not the ALZ-Bicep convention.
// Patching these vars rather than parameterizing every policy override gives single
// source of truth — all assignments referencing the LAW automatically point right.
var rgLogging = 'ALZ-mgmt'
var lawName = 'ALZ-law'
var lawResourceId = '/subscriptions/${subIdMgmt}/resourceGroups/${rgLogging}/providers/Microsoft.OperationalInsights/workspaces/${lawName}'
```

Detta gör att alla policy-overrides i `parPolicyAssignmentParameterOverrides` som
refererar `lawResourceId` automatiskt pekar på rätt LAW.

**För DCR/UAMI-referenser** (förväntat förekomma i `Deploy-VM-Monitoring`,
`Deploy-VM-ChangeTracking`, `Deploy-AzSqlDb-DefenderSQL`, `Deploy-MDFC-DefSQL-AMA`):
om `Build-OverrideFragments` extraherar literaler för dessa, lämna dem som
literaler i overriden eller skapa nya `var`-deklarationer i `int-root.bicepparam`
om flera policies refererar samma resurs (samma logik som `lawResourceId`).
Avgörs av vad fragmenten faktiskt innehåller.

Verifiera efter patching:
```bash
grep -E "rgLogging|lawName|lawResourceId" \
  config/core/governance/mgmt-groups/int-root.bicepparam
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
- Display names match Sylaviken's existing portal-deployed MG hierarchy
- int-root.bicepparam: patched rgLogging/lawName vars to ALZ-mgmt/ALZ-law
  (Sylaviken uses ALZ Accelerator naming, not ALZ-Bicep convention)
- Workflows pinned to engine v1.1.5"
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

# Dry-run först — validera planen utan att rotera något
.\scripts\onboard.ps1 `
  -ConfigRepoPath          '../alz-mgmt-sylaviken' `
  -BootstrapSubscriptionId '93ff5894-3e0b-4de9-9438-80e0fb7100de' `
  -ManagementGroupId       'adf9c0bb-91e2-4d3b-9a83-9a7ef2412bcf' `
  -GithubOrg               'ExjobbOA' `
  -ModuleRepo              'alz-mgmt-sylaviken' `
  -DryRun

# När planen ser OK ut — kör utan -DryRun
.\scripts\onboard.ps1 `
  -ConfigRepoPath          '../alz-mgmt-sylaviken' `
  -BootstrapSubscriptionId '93ff5894-3e0b-4de9-9438-80e0fb7100de' `
  -ManagementGroupId       'adf9c0bb-91e2-4d3b-9a83-9a7ef2412bcf' `
  -GithubOrg               'ExjobbOA' `
  -ModuleRepo              'alz-mgmt-sylaviken'
```

`Location` defaultar till `swedencentral`, `EnvPlan`/`EnvApply` till
`alz-mgmt-plan`/`alz-mgmt-apply` — alla OK för Sylaviken.

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
| Custom role | Tenant Root MG → Access control → Roles | `Landing Zone Reader (WhatIf/Validate)` | _ | `t9-1-custom-role.png` |
| RBAC plan UAMI | Tenant Root MG → Role assignments | Reader + custom WhatIf-roll | _ | `t9-1-rbac-plan.png` |
| RBAC apply UAMI | Tenant Root MG → Role assignments | Owner | _ | `t9-1-rbac-apply.png` |
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
i Mgmt Sub. Corp Sub oförändrad. Inga RG borttagna eller renamead. `ALZ-mgmt`-RG:n
oförändrad (LAW, DCR:s, UAMI, Automation Account intakta).

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
| ALZ-mgmt RG-resurser | _ | _ | _ | `t9-0-pre-alz-mgmt-resources.png` vs `t9-3-post-alz-mgmt-resources.png` |

Förväntat:
- **Tillkommit:** onboarding-artefakter (identity-RG från Phase 1) + ALZ
  policy-assignments och policy-definitions på existerande MG:er. **Inga nya
  MG:er** (portal-hierarkin återanvänds tack vare parameteriserat precreate),
  **inga nya nätverksresurser** (governance-only).
- **Borttaget: 0 customer-resurser.** Specifikt: `ALZ-mgmt`-RG:ns innehåll
  (LAW, DCR:s, UAMI, Automation Account, ChangeTracking-Solution) är intakt.
  De out-of-scope-resurser som listas i Context-sektionen är oförändrade.
- **Modifierat:** endast policy-scopes som plattformen explicit deklarerar.
  MG display names kan flagga som "modifierat" om Phase 0.6.3 inte gjordes
  helt komplett — notera i så fall som icke-destruktivt.
- **Custom policy `T9-Test-Audit-StorageHttpsOnly`** ska finnas kvar oförändrad
  (den är customer-managed, inte ALZ-managed).

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

### 5.1 Customer-policy

Använd `T9-Test-Audit-StorageHttpsOnly` skapad i Phase 0.3.

**Definition-ID:** _paste från Phase 0.3-evidens_
**Assignment-ID:** _paste från Phase 0.3-evidens_

### 5.2 Manuell ändring

Portal → Policy → Assignments → välj T9-test-policyn → Edit assignment → Parameters
→ ändra `effect` från `Audit` till `Disabled` → Review + save.

**Screenshot med drift:** `t9-5-clickops-drift-applied.png`

### 5.3 Trigga CD

```bash
cd alz-mgmt-sylaviken
gh workflow run cd.yaml
gh run watch
```

**CD run URL:** _paste_

### 5.4 Verifiera att den clickops-deployade policyn är orörd

Öppna policy assignment i portalen efter CD (Policy → Assignments → välj T9-test-
policyn → Parameters-fliken). Bekräfta att `effect` fortfarande är `Disabled`
(vår manuella ändring) och inte återställd till definitions-default.

**Screenshot efter CD (orörd):** `t9-5-clickops-untouched.png`

Förväntat: assignment-parametern behåller den manuella ändringen — plattformen rör
inte clickops-deployade resurser som inte är explicit deklarerade i tenant-
konfigurationen.

---

## Phase 6 — Resultat

### 6.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| Onboarding skapar enbart förväntade artefakter (identity-RG, 2 UAMIs, FICs, custom role, RBAC, GH envs) | _ | Phase 1 |
| 0 customer-resurser raderade vid initial deploy | _ | Phase 3 |
| ALZ-mgmt-RG:ns innehåll (LAW + DCR + UAMI + Automation Account) intakt | _ | Phase 3 |
| 0 nya/parallella MG:er skapade (portal-hierarkin återanvänds) | _ | Phase 3 |
| ALZ-introducerade resurser (policies, role assignments) tillkommer som väntat | _ | Phase 3 |
| ALZ-managed drift återställs av nästa CD | _ | Phase 4 |
| Customer-managed policy (T9-test) lämnas orörd | _ | Phase 5 |

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
- Sylaviken är portal-deployad ALZ Accelerator, inte ALZ-Bicep — naming för
  logging-resurser (`ALZ-mgmt`/`ALZ-law` istället för `rg-alz-logging-*`/
  `law-alz-*`) avviker från konvention. Detta hanteras genom att patcha
  `var`-deklarationer i `int-root.bicepparam` (single source of truth-mönster).
  Värt att diskutera som autentiskt brownfield-bevis i thesis — engine-stacken
  är robust mot naming-drift via parametrisering.

### 6.5 Cleanup

Efter Phase 6 verdict:

1. Ta bort T9-test-policy:
   - Portal → Policy → Assignments → `T9-Test-Audit-StorageHttpsOnly` → Delete
   - Portal → Policy → Definitions → `T9-Test-Audit-StorageHttpsOnly` → Delete
2. Ta bort operatör-Owner-tilldelning:
   - Portal → Management groups → Tenant Root Group → IAM → välj egen Owner-
     tilldelning → Remove
3. Verifiera att UAMI:erna fortfarande har sina RBAC-tilldelningar:
   ```powershell
   Get-AzRoleAssignment -Scope "/providers/Microsoft.Management/managementGroups/<tenant-root-id>" |
     Where-Object { $_.DisplayName -match 'id-alz-mgmt-swedencentral-(plan|apply)-1' }
   ```

Dokumentera cleanup i `t9-0-scope.md` med tidsstämplar.

---

## Evidens-artefakter

**Phase 0 — Baseline + förberedelser:**
- `t9-0-scope.md` — scope, tidsstämpel, engine-version, operatör-rättigheter-spår
- `t9-0-pre-mg.png`, `t9-0-pre-policies.png`, `t9-0-pre-assignments.png`,
  `t9-0-pre-vnets.png`, `t9-0-pre-mgmt-rgs.png`, `t9-0-pre-corp-rgs.png`,
  `t9-0-pre-alz-mgmt-resources.png`
- `t9-0-pre-baseline.md` — antal resurser per kategori + naming-konventions-noter
- `t9-0-phase5-target.png` + `t9-0-phase5-target.md` — T9-test-policy-skapande
- Sylaviken-fork commit-SHA (länk till GitHub commit)
- AzGovViz-output-mappen (zippad)

**Phase 1 — Onboarding:**
- Onboarding-script logg
- `t9-1-identity-rg.png`, `t9-1-uami-plan.png`, `t9-1-uami-apply.png`,
  `t9-1-fic-plan.png`, `t9-1-fic-apply.png`, `t9-1-custom-role.png`,
  `t9-1-rbac-plan.png`, `t9-1-rbac-apply.png`, `t9-1-gh-env-plan.png`,
  `t9-1-gh-env-apply.png`, `t9-1-gh-variables.png`
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
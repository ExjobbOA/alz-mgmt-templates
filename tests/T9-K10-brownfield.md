# T9 — Brownfield-kompatibilitet

**Test ID:** T9
**Criterion:** K10 Brownfield-kompatibilitet
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Tenant:** Sylaviken Nordlo-tenant

---

## Syfte

Visa att plattformen kan driftsättas mot en existerande Azure-tenant utan att
förstöra befintliga resurser, och att plattformen reagerar korrekt på drift mellan
ALZ-managed och customer-managed policies. Två delaspekter:

1. **Brownfield-onboarding:** existerande tenant-resurser respekteras vid initial deploy
2. **Drift-hantering:** ALZ-managed drift återställs; customer-managed drift lämnas orörd

---

## Context

Sylaviken är Nordlos testmiljö — en portal-deployad ALZ Accelerator-hierarki, inte
IaC-deployad. Plattformen körs i *simple mode* (en platform-sub) och *governance-only*
(ingen networking, ingen core-logging — LAW finns redan i tenanten).

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

T9 scope:ar till `ALZ`-MG och nedåt. Allt annat (3 Tenant-Root-subs, syskon-MG
`sylaviken`, RGs i Mgmt Sub utanför `ALZ-mgmt`) är out of scope och ska vara
oberörda efter Phase 6.

### Naming-konvention

Sylaviken använder ALZ Accelerator-portal-naming, inte ALZ-Bicep-konventionen:

| Resurs | ALZ-Bicep | Sylaviken |
|---|---|---|
| Logging RG | `rg-alz-logging-${loc}` | `ALZ-mgmt` |
| LAW | `law-alz-${loc}` | `ALZ-law` |
| AMA UAMI | `id-alz-ama-${loc}` | `id-ama-prod-swedencentral-001` |
| DCRs | `dcr-alz-{type}-${loc}` | `dcr-{type}-prod-swedencentral-001` |

Hanteras genom att patcha `var`-deklarationer i `int-root.bicepparam` (Phase 0.6.4).

---

## Engine prerequisite

Engine-tag `v1.1.5` eller senare med följande fixar mergade:

1. Precreate parameteriserad (cd-template.yaml läser `MG_NAME_*`)
2. `targetManagementGroupId` parameteriserad (cd + ci-template)
3. `cleanup.ps1` parameteriserad
4. Tre `main-rbac.bicepparam` parameteriserade i `alz-mgmt-oskar`

Verifiera:
```bash
git -C ../alz-mgmt-templates describe --tags --abbrev=0   # ska ge v1.1.5+
```

---

## Operatör-rättigheter

**Owner @ Tenant Root Group** krävs för hela cykeln (onboard tilldelar Owner till
UAMI och skapar custom role definition). Tilldelas via Entra → Properties →
Elevate Access → IAM-blade → Active/Permanent. Tas bort efter Phase 6.

Notera tilldelnings- och bortagnings-tider direkt i denna fil (Phase 6.5).

---

## Phase 0 — Pre-flight

### 0.1 Scope och tidsstämpel

- **Engine-version:** _commit SHA_
- **Start:** _datum tid_
- **Operatör:** Oskar (oskar@...) — Owner @ Tenant Root tilldelat _datum tid_

### 0.2 Pre-onboarding baseline

Screenshots i `tests/evidence/`:
- `t9-0-pre-mg.png` — MG-hierarki
- `t9-0-pre-mgmt-rgs.png` — RGs i Sylaviken Mgmt Sub
- `t9-0-pre-alz-mgmt-resources.png` — innehåll i `ALZ-mgmt`-RG
- `t9-0-phase5-target.png` — T9-test-policy (skapas i 0.3)

### 0.3 Skapa custom policy för Phase 5

Sylaviken har inga egna custom policies, så vi skapar en tydligt märkt test-policy
(cleanup i Phase 6.5).

Portal → Policy → Definitions → + Policy definition, scope = `ALZ` MG:

- **Display name:** `[T9 TEST — DELETE AFTER 2026-05-16] Audit storage accounts with HTTPS-only disabled`
- **Description:** `Test-only policy for T9 (K10 brownfield). Owner: Oskar / ExjobbOA.`
- **Category:** Create new → `T9-test`
- **Policy rule:**

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
      "allowedValues": ["Audit", "Disabled"],
      "defaultValue": "Audit"
    }
  }
}
```

Tilldela policyn till `ALZ` MG med default-värde `Audit`. Spara
`t9-0-phase5-target.png`.

### 0.4 Skapa Sylaviken-fork

```powershell
cd <workspace>
gh repo create ExjobbOA/alz-mgmt-sylaviken --private
git clone https://github.com/ExjobbOA/alz-mgmt-oskar.git alz-mgmt-sylaviken
cd alz-mgmt-sylaviken
git remote set-url origin https://github.com/ExjobbOA/alz-mgmt-sylaviken.git
git push -u origin main
```

Bumpa `cd.yaml` och `ci.yaml` till `@v1.1.5` (`platform_ref: v1.1.5` också). Direkt-edit
i GitHub UI eller lokalt + push. Verifiera:

```powershell
Get-Content .github/workflows/cd.yaml, .github/workflows/ci.yaml |
  Select-String "alz-mgmt-templates|platform_ref"
```

### 0.5 Brownfield-takeover

Generera `platform.json` + override-fragments enligt
`scripts/brownfield-takeover/README.md`:

1. AzGovViz-discovery med `-ManagementGroupId 'ALZ'`
2. `Build-PlatformJson.ps1`
3. `Build-OverrideFragments.ps1`

Skrivskyddat mot Sylaviken — säkert att köra om.

Verifiera att genererad `platform.json` har:
- `MG_NAME_PLATFORM: "ALZ-platform"`, `MG_NAME_LANDINGZONES: "ALZ-landingzones"`,
  `MG_NAME_SANDBOX: "ALZ-sandboxes"`, etc.
- `MANAGEMENT_GROUP_ID: "adf9c0bb-91e2-4d3b-9a83-9a7ef2412bcf"`
- `SUBSCRIPTION_ID_*: "93ff5894-..."` (alla samma i simple mode)

Kopiera till `../alz-mgmt-sylaviken/config/platform.json`.

Verifiera också att `custom-assignments.txt` listar `T9-Test-Audit-StorageHttpsOnly`.

### 0.6 Sylaviken-edits i forken

Granska + städa override-fragments enligt brownfield-takeover/README.md, sen:

**Excluded policy assignments — synkat på båda ställen:**
- `landingzones-corp/main.bicepparam`: lägg till `'Deploy-Private-DNS-Zones'` i
  `managementGroupExcludedPolicyAssignments`
- `landingzones/main.bicepparam` OCH `landingzones/main-rbac.bicepparam`:
  lägg till `'Enable-DDoS-VNET'` i respektive excluded-list (sync krävs)

**`int-root.bicepparam` — patcha logging-vars** (rad 10-12):
```bicep
var rgLogging = 'ALZ-mgmt'
var lawName = 'ALZ-law'
```

**Display names** i bicepparam-filerna: matcha Sylaviken-värdena från
`t9-0-pre-mg.png` (annars flaggas de som "modifierat" i Phase 3).

Commit + push.

---

## Phase 1 — Onboarding

```powershell
cd alz-mgmt-templates

.\scripts\onboard.ps1 `
  -ConfigRepoPath          '../alz-mgmt-sylaviken' `
  -BootstrapSubscriptionId '93ff5894-3e0b-4de9-9438-80e0fb7100de' `
  -ManagementGroupId       'adf9c0bb-91e2-4d3b-9a83-9a7ef2412bcf' `
  -GithubOrg               'ExjobbOA' `
  -ModuleRepo              'alz-mgmt-sylaviken' `
  -DryRun

# Sen utan -DryRun
```

**Resultat:** _paste_

Verifiera i portalen + GitHub:
- Identity RG `rg-alz-mgmt-identity-swedencentral-1` skapad i Mgmt Sub
- Två UAMI:er + FICs i den RG:n
- Custom role `Landing Zone Reader (WhatIf/Validate)` på Tenant Root MG
- Role assignments: apply-UAMI = Owner, plan-UAMI = Reader + custom WhatIf-roll
- GitHub environments `alz-mgmt-plan` + `alz-mgmt-apply` med `AZURE_*`-variables

Screenshot: `t9-1-onboarded.png` (identity-RG + UAMIs i samma vy räcker)

---

## Phase 2 — Initial CD-deploy

```bash
cd alz-mgmt-sylaviken
gh workflow run cd.yaml
gh run watch
```

**CD run URL:** _paste_
**Resultat:** _green/red_
**Duration:** _paste_

Förväntade stacks (alla med `actionOnUnmanage: DeleteAll`):
- `ALZ-governance-int-root` (Tenant Root MG)
- `ALZ-governance-{landingzones, landingzones-corp, landingzones-online, platform, sandbox, decommissioned}` (ALZ MG)
- `ALZ-governance-{platform-rbac, landingzones-rbac}` (ALZ MG)

Screenshot: `t9-2-stacks.png` (lista över alla stacks med Succeeded-status räcker).

---

## Phase 3 — Post-deploy diff

Ta `t9-3-post-mg.png`, `t9-3-post-mgmt-rgs.png`, `t9-3-post-alz-mgmt-resources.png`.

Jämför mot Phase 0.2:

| Vad | Förväntat | Observerat |
|---|---|---|
| Nya MG:er | 0 (portal-hierarki återanvänds) | _ |
| Raderade customer-resurser | 0 | _ |
| `ALZ-mgmt`-RG-innehåll | intakt (LAW + DCR + UAMI + Automation Account) | _ |
| Tillkomna policy-assignments | ALZ-bibliotekets på respektive MG | _ |
| `T9-Test-Audit-StorageHttpsOnly` | finns kvar, customer-managed | _ |

I simple mode med `parIncludeSubMgPolicies=true` flyttas några
connectivity/identity-policies upp till `ALZ-platform` (förväntat ALZ-beteende).

---

## Phase 4 — Drift på ALZ-managed policy

1. Portal → välj en ALZ-managed policy assignment, ändra parameter manuellt
2. `gh workflow run cd.yaml && gh run watch`
3. Verifiera att parametern är återställd

**Vald policy:** _paste_
**Ändring:** _paste_
**CD run URL:** _paste_
**Screenshots:** `t9-4-drift-applied.png`, `t9-4-drift-restored.png`

---

## Phase 5 — Drift på customer-managed policy (T9-test)

1. Portal → Policy → Assignments → välj T9-test-policyn → Edit → ändra `effect`
   från `Audit` till `Disabled`
2. `gh workflow run cd.yaml && gh run watch`
3. Verifiera att `effect` fortfarande är `Disabled` efter CD

**CD run URL:** _paste_
**Screenshots:** `t9-5-drift-applied.png`, `t9-5-untouched.png`

---

## Phase 6 — Resultat

### 6.1 Förväntat vs observerat

| Förväntat | Observerat |
|---|---|
| Onboarding skapar bara förväntade artefakter | _ |
| 0 customer-resurser raderade | _ |
| `ALZ-mgmt`-RG intakt | _ |
| 0 nya/parallella MG:er | _ |
| ALZ-introducerade resurser tillkommer som väntat | _ |
| ALZ-managed drift återställs | _ |
| Customer-managed drift lämnas orörd | _ |

### 6.2 Verdict

- [ ] K10 Passed
- [ ] K10 Partially passed
- [ ] K10 Not passed

**Kommentar:** _paste_

### 6.3 Observationer

[Fyll i efter körning — t.ex. oväntade beteenden, manuella overrides som behövdes,
limitations som upptäcktes]

### 6.4 Cleanup

1. Portal → Policy → Assignments + Definitions → ta bort `T9-Test-Audit-StorageHttpsOnly`
2. Portal → Tenant Root MG → IAM → ta bort egen Owner-tilldelning
3. Notera tider här: borttaget _datum tid_

---

## Notering

Vid oväntade resultat — stoppa, dokumentera, stäm av med Jesper innan fortsatt arbete.
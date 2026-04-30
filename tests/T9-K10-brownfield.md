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

Eftersom hierarkin redan finns deployar plattformen i governance-only-läge
(`networking: false`, `core-logging: false` med parameter-overrides som pekar på
existerande resurser i Sylaviken Mgmt Sub).

---

## Phase 0 — Pre-flight

### 0.1 Scope

Sylaviken är Nordlos testmiljö, så ingen kund-koordinering krävs. Inför körning,
dokumentera kort:

- Scope (vilka MG:er, vilka subscriptions som ingår i körningen)
- Tidsstämpel för start (för att kunna korrelera mot loggar/audit i efterhand)

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

### 0.3 Generera platform.json och override-fragment

Konfigurera plattformen för att respektera Sylaviken-strukturen — använd
existerande MG-namn där relevant, exkludera MG:er som inte ska ligga under
ALZ-paraplyet, override:a parameter-defaults där Sylaviken har egna värden.

**Exklusion av networking-pekande policies.** I linje med scope-begränsningen
i Context exkluderas de två policy assignments som har parametrar som pekar på
nätverksresurser — annars hamnar inerta policies med placeholder-värden i
tenanten:

- `Deploy-Private-DNS-Zones` på corp MG (~60 `azure*PrivateDnsZoneId`-parametrar)
- `Enable-DDoS-VNET` på landingzones MG (1 `ddosPlan`-parameter)

Båda exkluderas via `managementGroupExcludedPolicyAssignments` i respektive
MG-config i Sylaviken `platform.json`:

```json
{
  "corp": {
    "managementGroupExcludedPolicyAssignments": ["Deploy-Private-DNS-Zones"]
  },
  "landingzones": {
    "managementGroupExcludedPolicyAssignments": ["Enable-DDoS-VNET"]
  }
}
```

Verifiera mot engine-repo:t att exakt nyckel-struktur matchar hur `alzCoreType`
propagerar config ner i respektive `main.bicep`. RBAC-wiringen för
Deploy-Private-DNS-Zones i `platform/main-rbac.bicep` skippas automatiskt
eftersom den är wrappad i `!contains(parManagementGroupExcludedPolicyAssignments, ...)`.

Konsekvensen — att corp MG saknar private-DNS-governance och landingzones MG
saknar DDoS-policy under T9 — noteras i Phase 6 verdict som en följdeffekt
av scope-begränsningen.

---

## Phase 1 — Onboarding

Onboarding-skriptet förbereder tenanten för plattformshantering: bootstrap-identitet,
state-RG, GitHub-secrets för CD-pipelinen, etc. Detta måste köras först eftersom CD
förutsätter att dessa artefakter finns.

### 1.1 Kör onboarding-skriptet mot Sylaviken

```powershell
.\scripts\Onboard-Tenant.ps1 `
  -TenantId "<sylaviken-tenant-id>" `
  -ConfigPath "config/sylaviken/platform.json"
```

**Resultat:** _paste_
**Duration:** _paste_
**Logg-fil:** _path_

### 1.2 Verifiera onboarding-artefakter

Bekräfta i portalen att förväntade artefakter är skapade:

| Artefakt | Var i portalen | Förväntat | Bekräftat | Screenshot |
|---|---|---|---|---|
| Bootstrap SP | Entra → App registrations | `<bootstrap-sp-name>` | _ | `t9-1-bootstrap-sp.png` |
| State RG | Sylaviken Mgmt Sub → Resource groups | `<state-rg-name>` | _ | `t9-1-state-rg.png` |
| Role assignments | Bootstrap SP → Azure role assignments | Owner @ ALZ MG | _ | `t9-1-bootstrap-roles.png` |
| GitHub secrets | Repo → Settings → Secrets and variables → Actions | `AZURE_*`-secrets | _ | `t9-1-gh-secrets.png` |

### 1.3 Sanity-check mot baseline efter onboarding

Ta nya screenshots av RG-vyerna i Mgmt Sub och Corp Sub. Lägg sida vid sida mot
baseline från Phase 0.2:

| Sub | Baseline | Efter onboarding | Diff |
|---|---|---|---|
| Sylaviken Mgmt Sub | `t9-0-pre-mgmt-rgs.png` | `t9-1-post-onboarding-mgmt-rgs.png` | _ |
| Sylaviken Corp Sub | `t9-0-pre-corp-rgs.png` | `t9-1-post-onboarding-corp-rgs.png` | _ |

Förväntat: enbart state-RG tillkommen i Mgmt Sub. Corp Sub oförändrad. Inga RG
borttagna eller renamead.

---

## Phase 2 — Initial CD-deploy

### 2.1 Kör CD mot Sylaviken

**CD run URL:** _paste_
**Resultat:** _green/red_
**Duration:** _paste_

### 2.2 Stack-state efter deploy

Verifiera deployment stacks i portalen:

- ALZ MG → Deployments → Stacks
- ALZ-platform MG → Deployments → Stacks
- ALZ-landingzones MG → Deployments → Stacks
- Sylaviken Mgmt Sub → Deployments → Stacks

Screenshot:a vardera och fyll i:

| Scope | Stack-namn | ProvisioningState | Resources | Detached | Screenshot |
|---|---|---|---|---|---|
| ALZ MG | _ | _ | _ | _ | `t9-2-stack-alz.png` |
| ALZ-platform MG | _ | _ | _ | _ | `t9-2-stack-platform.png` |
| ALZ-landingzones MG | _ | _ | _ | _ | `t9-2-stack-lz.png` |
| Sylaviken Mgmt Sub | _ | _ | _ | _ | `t9-2-stack-mgmt.png` |

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
- Tillkommit: onboarding-artefakter (state-RG från Phase 1) + ALZ policy-assignments
  och policy-definitions på existerande MG:er. **Inga nya MG:er** (clickops-hierarkin
  återanvänds), **inga nya nätverksresurser** (governance-only).
- **Borttaget: 0 clickops-deployade resurser**
- Modifierat: endast policy-scopes som plattformen explicit deklarerar.

---

## Phase 4 — Drift-hantering: ALZ-managed policy

### 4.1 Manuell ändring i portalen

Välj en ALZ-managed policy assignment, ändra dess parameter manuellt i Azure Portal.

**Vald policy:** _paste_
**Ändring:** _paste_

### 4.2 Trigga CD

Pusha en tom commit för att trigga ny CD-körning.

### 4.3 Verifiera återställning

Öppna policy assignment i portalen efter att CD körts (Policy → Assignments → välj
policyn → Parameters-fliken). Bekräfta att den manuella ändringen är överskriven av
ALZ-värdet.

**Screenshot före CD (med drift):** `t9-4-alz-drift-applied.png`
**Screenshot efter CD (återställd):** `t9-4-alz-drift-restored.png`

Förväntat: parametern är tillbaka till ALZ-deklarerat värde.

---

## Phase 5 — Drift-hantering: customer-managed policy

### 5.1 Identifiera customer-policy

Välj en custom policy definition som är customer-skapad (inte ALZ).

**Vald policy:** _paste_

### 5.2 Manuell ändring

Ändra parametern manuellt i portalen.

### 5.3 Trigga CD

Pusha tom commit, vänta på CD.

### 5.4 Verifiera att den clickops-deployade policyn är orörd

Öppna policy definition i portalen efter CD (Policy → Definitions → välj policyn →
Definition-fliken). Bekräfta att den manuella ändringen finns kvar.

**Screenshot före CD (med drift):** `t9-5-clickops-drift-applied.png`
**Screenshot efter CD (orörd):** `t9-5-clickops-untouched.png`

Förväntat: policyn behåller den manuella ändringen — plattformen rör inte
clickops-deployade resurser som inte är explicit deklarerade i tenant-konfigurationen.

---

## Phase 6 — Resultat

### 6.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| Onboarding skapar enbart förväntade artefakter | _ | Phase 1 |
| 0 customer-resurser raderade vid initial deploy | _ | Phase 3 |
| ALZ-introducerade resurser tillkommer som väntat | _ | Phase 3 |
| ALZ-managed drift återställs av nästa CD | _ | Phase 4 |
| Customer-managed resurser lämnas orörda | _ | Phase 5 |

### 6.2 Observationer

[Fyll i efter körning]

### 6.3 Verdict

- [ ] K10 Passed (båda delaspekterna verifierade)
- [ ] K10 Partially passed (en delaspekt verifierad)
- [ ] K10 Not passed

**En-meningskommentar:** _paste efter körning_

---

## Evidens-artefakter

**Phase 0 — Baseline:**
- `t9-0-pre-mg.png`, `t9-0-pre-policies.png`, `t9-0-pre-assignments.png`,
  `t9-0-pre-vnets.png`, `t9-0-pre-mgmt-rgs.png`, `t9-0-pre-corp-rgs.png`
- `t9-0-pre-baseline.md` — antal resurser per kategori

**Phase 1 — Onboarding:**
- Onboarding-script logg
- `t9-1-bootstrap-sp.png`, `t9-1-state-rg.png`, `t9-1-bootstrap-roles.png`,
  `t9-1-gh-secrets.png`
- `t9-1-post-onboarding-mgmt-rgs.png`, `t9-1-post-onboarding-corp-rgs.png`

**Phase 2 — CD-deploy:**
- CD run URL
- `t9-2-stack-alz.png`, `t9-2-stack-platform.png`, `t9-2-stack-lz.png`,
  `t9-2-stack-mgmt.png`

**Phase 3 — Post-deploy diff:**
- Samma vyer som Phase 0 men med `t9-3-post-`-prefix

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
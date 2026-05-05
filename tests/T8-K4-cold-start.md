# T8 — Cold start

**Test ID:** T8
**Criterion:** K4 Automatiserad driftsättning
**Executed by:** Oskar
**Date:** _YYYY-MM-DD_
**Tenant:** Test-tenant efter manuell teardown

---

## Syfte

Visa att plattformen kan driftsättas från grunden mot en tom tenant via det
dokumenterade flödet: nytt config-repo från template → `onboard.ps1` → tuning
av `platform.json` → commit/PR/CD.

K4 mäts genom två frågor:
1. **Slutresultat:** deployade alla 11 stackar `Succeeded`?
2. **Runbook-validitet:** räckte `scripts/README.md` + `onboard.ps1` för att ta
   tenanten från noll till grön CD utan eskalering eller odokumenterad
   improvisation?

---

## Context

Plattformen är designad för att en operatör ska kunna ta en tom Azure-tenant från
noll till deployad ALZ-baseline. `onboard.ps1` automatiserar enligt
`scripts/README.md`:
- Skapar GitHub-environments (`alz-mgmt-plan`, `alz-mgmt-apply`)
- Deployar bootstrap-Bicep (UAMIs + OIDC federated credentials + role assignments)
- Skriver `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` som
  GitHub environment variables
- Uppdaterar `config/platform.json` (MG-id, location, management-sub)
- Uppdaterar `config/bootstrap/plumbing.bicepparam`

Tidigare iterationer (T1–T7) har kört mot redan onboardad tenant. T8 är första
gången hela kedjan testas från noll.

**Repo-strategi:** Existerande `alz-mgmt` markeras som GitHub template repository.
Ett nytt tillfälligt repo skapas från template:t inför testet och raderas
efteråt. GitHub environments, variables och secrets transfereras inte vid
template-baserad repo-creation.

**Cleanup-strategi:** Teardown utförs manuellt via Az PowerShell istället för
`scripts/cleanup.ps1`, för att eliminera projektets eget destructive tooling som
confounder.

---

## Phase 0 — Teardown

Förbereder en tom tenant. Inte del av cold-start-flödet som testas.

### 0.1 Markera alz-mgmt som template

Engångsåtgärd: GitHub UI → `alz-mgmt` → Settings → General → kryssa "Template
repository".

### 0.2 Manuell teardown

```powershell
# A. Flytta subscriptions till tenant root
New-AzManagementGroupSubscription -GroupId "<tenant-root-guid>" -SubscriptionId "<sub-id>"

# B. Radera deployment stacks
$mgs = @("alz", "<andra-MGs>")
foreach ($mg in $mgs) {
    Get-AzManagementGroupDeploymentStack -ManagementGroupId $mg |
      Remove-AzManagementGroupDeploymentStack -ManagementGroupId $mg
}
Get-AzSubscriptionDeploymentStack | Remove-AzSubscriptionDeploymentStack

# C. Radera management groups (leaf-up, intermediate root sist)
Remove-AzManagementGroup -GroupId "<leaf>"
Remove-AzManagementGroup -GroupId "alz"

# D. Radera identity-RG (kills UAMIs + federated creds + role assignments)
Remove-AzResourceGroup -Name "<identity-rg>" -SubscriptionId "<management-sub>" -Force
```

### 0.3 Verifiera tom tenant

```powershell
Get-AzManagementGroup                      # endast tenant root
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7"
Get-AzSubscriptionDeploymentStack
```
PS /home/oskar> Get-AzManagementGroup                      # endast tenant root                                               

Id          : /providers/Microsoft.Management/managementGroups/3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7
Type        : Microsoft.Management/managementGroups
Name        : 3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7
TenantId    : 3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7
DisplayName : Tenant Root Group

PS /home/oskar> Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7"
PS /home/oskar> Get-AzSubscriptionDeploymentStack
PS /home/oskar> 

| Verifiering | Förväntat | Observerat |
|---|---|---|
| MG-hierarki | Endast tenant root | ja |
| Stacks (MG + sub) | Tomma listor | ja |
| Identity-RG | Existerar inte | nej |

`t8-cleantenant.png`
---

## Phase 1 — Onboard från template

### 1.1 Skapa nytt config-repo

Via github ui klona template
`t8-clone.png`
### 1.2 Kör onboard.ps1
PS C:\Users\granl\repos> git clone https://github.com/ExjobbOA/alz-mgmt-t8.git
```powershell
cd C:\Users\granl\repos\alz-mgmt-templates
./scripts/onboard.ps1 `
    -ConfigRepoPath          '../alz-mgmt-t8' `
    -BootstrapSubscriptionId '6f051987-3995-4c82-abb3-90ba101a0ab4' `
    -ManagementGroupId       '3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7' `
    -Location                'swedencentral'
```
ALZ Tenant Onboarding


── Checking prerequisites ──
[OK]    az, gh, git — all present.
[OK]    Azure: logged in as oskar.granlof@nordlo.com (tenant 3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7)
[OK]    GitHub CLI: authenticated.

── Resolving inputs ──
[INFO]  Config repo: C:\Users\granl\repos\alz-mgmt-t8
[INFO]  Loading defaults from config/platform.json...

── Plan ──

  Config repo path    : C:\Users\granl\repos\alz-mgmt-t8
  GitHub org/repo     : ExjobbOA/alz-mgmt-t8
  Templates repo      : alz-mgmt-templates
  Bootstrap sub ID    : 6f051987-3995-4c82-abb3-90ba101a0ab4
  Root MG GUID        : 3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7
  Azure region        : swedencentral
  GitHub environments : alz-mgmt-plan (plan)  alz-mgmt-apply (apply)
  Workflow branch     : refs/heads/main

Proceed with onboarding? [y/N]: y

── Creating GitHub environments ──
[INFO]    Creating environment 'alz-mgmt-plan'...
[OK]      'alz-mgmt-plan' ready.
[INFO]    Creating environment 'alz-mgmt-apply'...
[OK]      'alz-mgmt-apply' ready.

── Configuring OIDC subject claim (environment-only) ──
[OK]    OIDC subject claim configured: sub will be environment-only (repo:ORG/REPO:environment:ENV).

── Running bootstrap Bicep deployment ──
[INFO]    Deploying to management group: 3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7
[INFO]    (This may take 2–5 minutes)
[OK]    Bootstrap deployment complete.
[OK]      Identity RG    : rg-alz-mgmt-identity-swedencentral-1
[OK]      Plan clientId  : 282b9df7-9ae6-46d1-a47e-70139ce1c997
[OK]      Apply clientId : 67cf34c3-935a-46e4-8833-9961fc8bc283

── Fetching Azure tenant ID ──
[OK]    Tenant ID: 3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7

── Writing GitHub environment variables ──
[INFO]    alz-mgmt-plan : AZURE_CLIENT_ID
✓ Created variable AZURE_CLIENT_ID for ExjobbOA/alz-mgmt-t8 environment alz-mgmt-plan
[INFO]    alz-mgmt-plan : AZURE_TENANT_ID
✓ Created variable AZURE_TENANT_ID for ExjobbOA/alz-mgmt-t8 environment alz-mgmt-plan
[INFO]    alz-mgmt-plan : AZURE_SUBSCRIPTION_ID
✓ Created variable AZURE_SUBSCRIPTION_ID for ExjobbOA/alz-mgmt-t8 environment alz-mgmt-plan
[INFO]    alz-mgmt-apply : AZURE_CLIENT_ID
✓ Created variable AZURE_CLIENT_ID for ExjobbOA/alz-mgmt-t8 environment alz-mgmt-apply
[INFO]    alz-mgmt-apply : AZURE_TENANT_ID
✓ Created variable AZURE_TENANT_ID for ExjobbOA/alz-mgmt-t8 environment alz-mgmt-apply
[INFO]    alz-mgmt-apply : AZURE_SUBSCRIPTION_ID
✓ Created variable AZURE_SUBSCRIPTION_ID for ExjobbOA/alz-mgmt-t8 environment alz-mgmt-apply
[OK]    All environment variables written.

── Updating config/platform.json ──
[OK]    config/platform.json updated.

── Updating config/bootstrap/plumbing.bicepparam ──
[OK]    config/bootstrap/plumbing.bicepparam updated.

══════════════════════════════════════════════════════════
  Onboarding complete!
══════════════════════════════════════════════════════════

  Azure resources:
    Identity resource group : rg-alz-mgmt-identity-swedencentral-1
    Plan UAMI client ID     : 282b9df7-9ae6-46d1-a47e-70139ce1c997
    Apply UAMI client ID    : 67cf34c3-935a-46e4-8833-9961fc8bc283
    Tenant ID               : 3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7

  GitHub (ExjobbOA/alz-mgmt-t8):
    'alz-mgmt-plan'  → AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID
    'alz-mgmt-apply' → AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID

  Config files updated:
    C:\Users\granl\repos\alz-mgmt-t8\config\platform.json
### 1.3 Verifiera onboard-output

| Output | Förväntat | Observerat |
|---|---|---|
| GitHub-environments | `alz-mgmt-plan`, `alz-mgmt-apply` |x|
| UAMIs i identity-RG | Plan-UAMI + Apply-UAMI |x|
| Federated credentials | Bundna till environments |x|
| GitHub Variables | `AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID` |x|
| `platform.json` | `MANAGEMENT_GROUP_ID`, `LOCATION`, management-sub satta |x|


---

## Phase 2 — Tenant-config och PR

### 2.1 Verifiera platform.json

`onboard.ps1` skriver bara MG-id, location och management-sub. Övriga värden
ärvs från template:t och ska verifieras explicit:

```powershell
cd ../alz-mgmt-coldstart
git switch -c cold-start/initial-config
```

Kollas i `config/platform.json`:
`SUBSCRIPTION_ID_CONNECTIVITY/IDENTITY/SECURITY`, `NETWORK_TYPE`, `MG_NAME_*`,
`LOCATION_SECONDARY`, `SECURITY_CONTACT_EMAIL`, `PLATFORM_MODE`.

### 2.2 Bicepparam-overrides

För minimal cold-start kan detta hoppas över. Anteckna om något krävs.

### 2.3 Commit + PR

```powershell
git add config/
git commit -m "Cold start: tenant configuration"
git push -u origin cold-start/initial-config
gh pr create --fill
```

**PR URL:** https://github.com/ExjobbOA/alz-mgmt-t8/pull/1

---

## Phase 3 — CI + CD

### 3.1 CI

Vänta in CI på PR:en. First-deployment what-if hanteras av
`bicep-first-deployment-check`.

**CI run URL:** https://github.com/ExjobbOA/alz-mgmt-t8/actions/runs/25376145422/job/74411660901

### 3.2 CD

Merge PR. Trigga CD via `workflow_dispatch` med alla steg satta till `true`.

**CD run URL:** https://github.com/ExjobbOA/alz-mgmt-t8/actions/runs/25376563766/job/74413118836

---

## Phase 4 — Resultat

### 4.1 Stack-state (slutresultat)

```powershell
Set-AzContext -SubscriptionId "<bootstrap-sub-id>"
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7" |
  Select-Object Name, ProvisioningState
Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz" |
  Select-Object Name, ProvisioningState
Get-AzSubscriptionDeploymentStack |
  Select-Object Name, ProvisioningState
```

PS /home/oskar> Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7" |
>>   Select-Object Name, ProvisioningState

name                                                     provisioningState
----                                                     -----------------
3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7-governance-int-root succeeded

PS /home/oskar> Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz" |
>>   Select-Object Name, ProvisioningState

name                               provisioningState
----                               -----------------
alz-governance-landingzones        succeeded
alz-governance-landingzones-corp   succeeded
alz-governance-landingzones-online succeeded
alz-governance-platform            succeeded
alz-governance-sandbox             succeeded
alz-governance-decommissioned      succeeded
alz-governance-platform-rbac       succeeded
alz-governance-landingzones-rbac   succeeded

PS /home/oskar> Get-AzSubscriptionDeploymentStack |
>>   Select-Object Name, ProvisioningState

name               provisioningState
----               -----------------
alz-networking-hub succeeded
alz-core-logging   succeeded

**Antal Succeeded: 11/11
**Screenshot:** `t8-1-stacks-green.png`

### 4.2 Runbook-validitet

| Förväntat enligt runbook | Stämde? | Källa |
|---|---|---|
| Manuell teardown lämnar tenant tom |Ja| Phase 0.3 |
| `onboard.ps1` exekverar korrekt|Ja| Phase 1.3 |
| Tenant-konfig kan göras med endast `platform.json` + bicepparam |Ja| Phase 2 |
| CI + CD grön |Ja| Phase 3 |
| Alla 11 stackar `Succeeded` |Ja| Phase 4.1 |

### 4.3 Findings

Det viktigaste output:et. Allt som krävde improvisation utöver runbook:en:
Vi hade  en bugg i våran CI som gjorde att den inte kunde köras, det hade med first deployment check att göra där vi hade skrivit vars istället för env som prefix på tenant root guid, men räknas som ett separat problem för whatif ska skippas ändå vid first deployment

### 4.4 Verdict

- [x] **K4 Passed** — alla 11 stackar `Succeeded`, runbook räckte utan eskalering
- [ ] **K4 Partially passed** — stackarna deployade men runbook hade gap som
  krävde improvisation
- [ ] **K4 Not passed** — cold start kunde inte slutföras utan att gå utanför
  plattformens dokumenterade flöde

**En-meningskommentar:** _paste efter körning_

---

## Efter testet

Radera test-repo:t: `gh repo delete <org>/alz-mgmt-coldstart --yes`

---

## Evidens-artefakter

1. PR URL
2. CI run URL
3. CD run URL
4. `t8-1-stacks-green.png` — 11/11 stackar Succeeded
5. Findings-tabell (Phase 4.3)
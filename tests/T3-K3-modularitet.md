# T3 — Modularitet

**Test ID:** T3
**Criterion:** K3 Modularitet och separation
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Syfte

Visa att plattformen är arkitektoniskt separerad mellan engine och tenant, att engine-
uppdateringar propagerar utan tenant-edits, och att modulariteten är synlig i repo-
strukturen och deployment stack-uppdelningen.

K3 har tre delaspekter:
1. Engine-tenant-separation i kod (ren konfig i tenant-repot)
2. Engine-bumpar propagerar till tenant utan kodändringar i tenant-repot
3. Tenant-isolation: en tenants ändring påverkar inte andra tenants

Den tredje aspekten kan inte testas empiriskt eftersom plattformen är deployad mot
endast en tenant. Den behandlas arkitektoniskt.

---

## Context

Plattformen är uppdelad i två repos:

- **Engine-repo (`alz-mgmt-templates`):** Innehåller all Bicep-logik, AVM-referenser och
  template-strukturer. Versioneras med taggar.
- **Tenant-repo (`alz-mgmt`):** Innehåller endast `using`-statements och `bicepparam`-
  filer som pekar på engine-repots templates via `ENGINE_REF`-variabel.

Deployment är uppdelad i 11 separata deployment stacks som var och en har sin egen
state, sitt eget `actionOnUnmanage`-beteende och sin egen lifecycle. Detta är
modulariteten på runtime-nivå.

---

## Phase 0 — Pre-flight

### 0.1 Baseline

- Engine-tag: _paste senaste tag_
- Tenant-repo: huvudbranch ren, inga öppna PRs

---

## Phase 1 — Repo-separation

### 1.1 Tenant-repot ska vara ren konfig

Sök efter Bicep-resource och module-deklarationer i tenant-repot. Om plattformen är
korrekt modulär ska resultatet vara tomt eller endast innehålla `using` och `param`.

```powershell
cd C:\Users\granl\repos\alz-mgmt
Get-ChildItem -Recurse -Filter "*.bicep" -Exclude "*.bicepparam" |
  Select-String -Pattern "^\s*resource\s+|^\s*module\s+" |
  Select-Object Path, LineNumber, Line
```

```powershell
# Verifiera att bicepparam-filer endast innehåller using + params
Get-ChildItem -Recurse -Filter "*.bicepparam" |
  Select-String -Pattern "^\s*resource\s+|^\s*module\s+" |
  Select-Object Path, LineNumber, Line
```

**Resultat:** _antal träffar_

Förväntat: 0 träffar, eller endast vitlistade undantag som dokumenteras.

### 1.2 Engine-repot innehåller all logik

Verifiera att Bicep-templates faktiskt finns i engine-repot:

```powershell
cd C:\Users\granl\repos\alz-mgmt-templates
Get-ChildItem -Recurse -Filter "*.bicep" |
  Select-String -Pattern "^\s*resource\s+|^\s*module\s+" |
  Measure-Object
```

**Antal resource/module-deklarationer:** _paste_

---

## Phase 2 — Engine-bump propagerar utan tenant-edits

### 2.1 Bevis från tag-progressionen

Plattformen genomgick fem engine-tags under iteration 2 (`v1.0.5-baseline` →
`v1.1.0` → `v1.1.1` → `v1.1.2` → `v1.1.3`). För varje tag ändrades endast
`ENGINE_REF`-variabeln i tenant-repots workflow-config — inga Bicep-filer i
tenant-repot rördes.

```powershell
# Verifiera att tenant-repot inte har commits som ändrar Bicep-logik
cd C:\Users\granl\repos\alz-mgmt
git log --since="2026-04-01" --pretty=format:"%h %s" --all
```

För varje commit i tenant-repot under T10-perioden, klassificera:

| Commit | Innebörd | Berör Bicep-logik? |
|---|---|---|
| _ | _ | Ja/Nej |

Förväntat: alla commits är konfigändringar (ENGINE_REF, parameter-edits) eller
metadata. Ingen Bicep-logik ändras i tenant-repot.

### 2.2 ENGINE_REF som propageringsmekanism

```powershell
cd C:\Users\granl\repos\alz-mgmt
Select-String -Path .github\workflows\*.yaml -Pattern "ENGINE_REF|platform_ref" -Context 1,2
```

Förväntat: ENGINE_REF refereras i workflow-filerna som källa till engine-versionen.
Ändring av denna variabel räcker för att uppdatera plattformen.

---

## Phase 3 — Deployment stack-modularitet

### 3.1 Per-stack-isolation

Listan av deployment stacks visar att plattformen är uppdelad i 11 oberoende enheter
med var sin lifecycle:

```powershell
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7"
Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz"
Get-AzSubscriptionDeploymentStack
```

| Stack | Scope | Egen actionOnUnmanage | Egen state |
|---|---|---|---|
| governance-int-root | tenant root MG | DeleteAll | Ja |
| governance-platform | alz MG | DeleteAll | Ja |
| governance-landingzones | alz MG | DeleteAll | Ja |
| governance-landingzones-corp | alz MG | DeleteAll | Ja |
| governance-landingzones-online | alz MG | DeleteAll | Ja |
| governance-sandbox | alz MG | DeleteAll | Ja |
| governance-decommissioned | alz MG | DeleteAll | Ja |
| governance-platform-rbac | alz MG | DeleteAll | Ja |
| governance-landingzones-rbac | alz MG | DeleteAll | Ja |
| networking-hub | subscription | DetachAll | Ja |
| core-logging | subscription | DetachAll | Ja |

Detta visar att modulariteten är operativ, inte bara strukturell — varje stack kan
deployas, uppdateras eller felsökas separat.

---

## Phase 4 — Tenant-isolation (arkitektoniskt argument)

Tenant-isolation följer av att varje tenant deployas till sin egen Azure-subscription
med separata Management Groups, deployment stacks och OIDC-credentials. Plattformens
engine-repo refereras via `ENGINE_REF` i tenant-repots workflow-config, vilket innebär
att en tenant-konfig inte kan påverka andra tenanters runtime-state utan att
respektive tenant-credentials kompromissas.

Empirisk verifikation av tenant-A vs tenant-B-isolation kräver multi-tenant-deployment
vilket är utanför detta arbetes scope. Plattformen är dock designad för MSP-användning
där flera tenants ska kunna driftas parallellt, och separationen är avgörande för den
användningen.

---

## Phase 5 — Resultat

### 5.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| Tenant-repot saknar Bicep-resource/module-deklarationer | _ | grep-output |
| Engine-bumpar propagerar via ENGINE_REF utan tenant-edits | _ | git log + workflow-grep |
| 11 deployment stacks är oberoende enheter | _ | Get-AzManagementGroupDeploymentStack |

### 5.2 Observationer

[Fyll i efter körning]

### 5.3 Verdict

- [ ] K3 Passed
- [ ] K3 Partially passed
- [ ] K3 Not passed

**En-meningskommentar:** _paste efter körning_

---

## Evidens-artefakter

1. PowerShell-output av tenant-repo-grep (resource/module-träffar)
2. PowerShell-output av engine-repo Bicep-deklarationsräkning
3. Git log över tenant-repot med klassificering av commits
4. Tabell av deployment stacks från Get-AzManagementGroupDeploymentStack

---

## Appendix — Command reference

```powershell
# Tenant-repo grep
cd C:\Users\granl\repos\alz-mgmt
Get-ChildItem -Recurse -Filter "*.bicep" -Exclude "*.bicepparam" |
  Select-String -Pattern "^\s*resource\s+|^\s*module\s+"

# Tag-progression (engine)
cd C:\Users\granl\repos\alz-mgmt-templates
git tag -l --sort=-creatordate

# Stack-state
Get-AzManagementGroupDeploymentStack -ManagementGroupId "3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7"
Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz"
Get-AzSubscriptionDeploymentStack
```

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

Sylaviken Nordlo-tenanten är en existerande MSP-kund-miljö. Plattformen ska kunna
introduceras där utan att existerande customer-resurser (MG-hierarki, custom policies,
nätverk, etc.) raderas eller modifieras. Plattformen ska bara hantera de delar som
explicit deklareras i tenant-konfiguratione.

Detta är det mest känsliga testet i serien eftersom det körs mot en faktisk kund-miljö.
Allt arbete ska planeras i samråd med Nordlo och med tydlig rollback-plan.

---

## Phase 0 — Pre-flight

### 0.1 Förberedelser med Nordlo

- Skriftligt godkännande från ansvarig på Nordlo att testa mot Sylaviken-tenanten
- Tydligt scope överenskommet (vilka MG:er, vilka subscriptions)
- Rollback-plan etablerad innan deploy
- Tidsfönster definierat

### 0.2 Pre-deploy snapshot av Sylaviken

Innan plattformen rörs, dokumentera nuvarande tenant-state:

```powershell
# MG-hierarki
Get-AzManagementGroup -Expand -Recurse |
  Select-Object Name, DisplayName, ParentName |
  Export-Csv -Path tests/evidence/sylaviken-pre-mg.csv

# Custom policy definitions
Get-AzPolicyDefinition -Custom |
  Select-Object Name, DisplayName, ResourceId |
  Export-Csv -Path tests/evidence/sylaviken-pre-policies.csv

# Network resources (vnets, peerings, etc)
Get-AzVirtualNetwork |
  Select-Object Name, ResourceGroupName, AddressSpace |
  Export-Csv -Path tests/evidence/sylaviken-pre-vnets.csv

# Resource groups
Get-AzResourceGroup |
  Select-Object ResourceGroupName, Location, Tags |
  Export-Csv -Path tests/evidence/sylaviken-pre-rgs.csv
```

Spara även en lista på alla resurs-IDs som referens för diff-jämförelse.

### 0.3 Generera platform.json och override-fragment

Konfigurera plattformen för att respektera Sylaviken-strukturen — använd
existerande MG-namn där relevant, exkludera MG:er som inte ska ligga under ALZ-paraplyet,
override:a parameter-defaults där Sylaviken har egna värden.

---

## Phase 1 — Initial deploy

### 1.1 Kör CD mot Sylaviken

**CD run URL:** _paste_
**Resultat:** _green/red_
**Duration:** _paste_

### 1.2 Stack-state efter deploy

```powershell
Get-AzManagementGroupDeploymentStack -ManagementGroupId "<sylaviken-tenant-root>"
Get-AzManagementGroupDeploymentStack -ManagementGroupId "<sylaviken-alz-mg>"
Get-AzSubscriptionDeploymentStack
```

| Stack | ProvisioningState | Resources | Detached |
|---|---|---|---|
| _ | _ | _ | _ |

---

## Phase 2 — Post-deploy snapshot och diff

### 2.1 Dokumentera post-deploy state

Samma kommandon som Phase 0.2 men med `-post-`-suffix på filnamn.

### 2.2 Diff per kategori

Använd Compare-Object eller motsvarande för att jämföra pre/post:

```powershell
# Exempel för MG-hierarkin
$pre = Import-Csv tests/evidence/sylaviken-pre-mg.csv
$post = Import-Csv tests/evidence/sylaviken-post-mg.csv
Compare-Object $pre $post -Property Name -PassThru
```

| Kategori | Tillkommit | Borttaget | Modifierat |
|---|---|---|---|
| MG-hierarki | _ | _ | _ |
| Custom policies | _ | _ | _ |
| Vnets | _ | _ | _ |
| Resource groups | _ | _ | _ |

Förväntat:
- Tillkommit: ALZ-introducerade resurser (alz-MG, ALZ-policies, ALZ-RGs)
- **Borttaget: 0 customer-resurser**
- Modifierat: endast resurser som ALZ uttryckligen ska hantera

---

## Phase 3 — Drift-hantering: ALZ-managed policy

### 3.1 Manuell ändring i portalen

Välj en ALZ-managed policy assignment, ändra dess parameter manuellt i Azure Portal.

**Vald policy:** _paste_
**Ändring:** _paste_

### 3.2 Trigga CD

Pusha en tom commit för att trigga ny CD-körning.

### 3.3 Verifiera återställning

Hämta policy assignment efter CD och bekräfta att den manuella ändringen är
överskriven av ALZ-värdet.

```powershell
Get-AzPolicyAssignment -Name "<vald-policy>" -Scope "<scope>" |
  Select-Object -ExpandProperty Parameters
```

Förväntat: parametern är tillbaka till ALZ-deklarerat värde.

**Screenshot:** `t9-1-alz-drift-restored.png`

---

## Phase 4 — Drift-hantering: customer-managed policy

### 4.1 Identifiera customer-policy

Välj en custom policy definition som är customer-skapad (inte ALZ).

**Vald policy:** _paste_

### 4.2 Manuell ändring

Ändra parametern manuellt i portalen.

### 4.3 Trigga CD

Pusha tom commit, vänta på CD.

### 4.4 Verifiera att customer-policyn är orörd

```powershell
Get-AzPolicyDefinition -Name "<customer-policy>" |
  Select-Object -ExpandProperty Parameters
```

Förväntat: customer-policy:n behåller den manuella ändringen — ALZ rör inte
customer-managed resurser.

**Screenshot:** `t9-2-customer-untouched.png`

---

## Phase 5 — Resultat

### 5.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| 0 customer-resurser raderade vid initial deploy | _ | Phase 2 |
| ALZ-introducerade resurser tillkommer som väntat | _ | Phase 2 |
| ALZ-managed drift återställs av nästa CD | _ | Phase 3 |
| Customer-managed resurser lämnas orörda | _ | Phase 4 |

### 5.2 Observationer

[Fyll i efter körning]

### 5.3 Verdict

- [ ] K10 Passed (båda delaspekterna verifierade)
- [ ] K10 Partially passed (en delaspekt verifierad)
- [ ] K10 Not passed

**En-meningskommentar:** _paste efter körning_

---

## Evidens-artefakter

1. Pre-deploy snapshots: `sylaviken-pre-mg.csv`, `sylaviken-pre-policies.csv`,
   `sylaviken-pre-vnets.csv`, `sylaviken-pre-rgs.csv`
2. Post-deploy snapshots med `-post-`-suffix
3. Compare-Object diff per kategori
4. CD run URL för initial deploy
5. CD run URL för drift-trigger
6. `t9-1-alz-drift-restored.png` — ALZ-policy återställd efter manuell drift
7. `t9-2-customer-untouched.png` — customer-policy orörd efter CD

---

## Notering

T9 körs mot en faktisk kund-tenant. All exekvering sker i samråd med Nordlo och med
tydlig kommunikation. Om något oväntat händer, stoppa direkt och kontakta Lasse/Jesper
innan fortsatt arbete.

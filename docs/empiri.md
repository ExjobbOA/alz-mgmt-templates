# Empiriinsamling — Iteration 1 Testpass

**Datum:** 2026-03-03
**Utförare:** Oskar Granlöf
**Syfte:** Samla in empiriskt underlag för utvärderingskriterierna K1, K2, K3, K4 och K6.

---

## Godkänt utfall per kriterium

| Kriterium | Beskrivning | Godkänt om |
|-----------|-------------|------------|
| K1 | Automatiserad driftsättning | Alla 3 körningar Succeeded, inga kodkorrigeringar under körning |
| K2 | Spårbarhet | Fullständig kedja commit → PR → pipeline → Azure-förändring dokumenterad |
| K3 | Kontrollerad process | Samtliga förändringar via PR-flöde, noll direktmanipulation i portalen |
| K4 | Rollback | Miljön återställd utan manuell rekonstruktion, spårbart i loggar |
| K6 | Cold start | Onboard → CD genomfört mot greenfield-tenant med enbart dokumenterade kommandon |

---

## Del 1 — Cold start Oskar (K6 + K1 #1)

### Förutsättningar

| Check | Status |
|-------|--------|
| alz-mgmt-oskar på main, ren | ✅ |
| alz-mgmt-templates på main, ren | ✅ |
| Repo omdöpt till alz-mgmt-oskar | ✅ |
| plumbing.bicepparam uppdaterad med nytt repo-namn | ✅ |
| Tenant: enbart tenant root management group och en subscription | ✅ |
| Utföraren är Owner + User Access Administrator på tenant root | ✅ |
| GitHub-repot alz-mgmt-oskar har inga environments | ✅ |

### Onboard

| Fält | Värde |
|------|-------|
| Starttid | |
| Sluttid | |
| Utfall | Succeeded |
| Varaktighet | 44,89 sekunder |
| Kommentar | GitHub environments skapade, UAMIs deployade, env-variabler skrivna |

### CD-körning #1

| Fält | Värde |
|------|-------|
| Starttid | 23:00 |
| Sluttid | 00:20 |
| Varaktighet | ~1h 20min |
| Actions run URL | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22644686558 |
| Slutstatus | Succeeded |
| Antal retries | 1 (networking — VNet peering race condition, ARM-transient) |
| Kommentar | Alla steg gröna. Retry hanterades automatiskt av pipeline. |

### Azure-verifiering efter CD-körning #1

| Check | Status |
|-------|--------|
| MG-hierarki (alz → platform, landingzones, sandbox, decommissioned) | ✅ |
| Policy assignments på alz MG (16 st) + ytterligare på barn-MGs | ✅ |
| Resource group rg-alz-logging-swedencentral med LAW, UAMI, DCRs | ✅ |
| Resource groups rg-alz-conn-swedencentral och rg-alz-conn-northeurope med hub VNets | ✅ |
| VNet peering Connected mellan swedencentral och northeurope | ✅ |

---

## Del 2 — Idempotent omdriftsättning Oskar (K1 #2)

### CD-körning #2 (inga ändringar)

| Fält | Värde |
|------|-------|
| Starttid | 00:31 |
| Sluttid | 01:50 |
| Varaktighet | ~1h 20min |
| Actions run URL | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22647650534 |
| Slutstatus | Succeeded |
| What-if: inga ändringar bekräftade | Ej tillämpligt — se not nedan |
| Kommentar | skip_what_if: false |

**Not — ARM what-if brus:**
What-if-outputen visade sig vara opålitlig för governance-steg och kan inte användas som idempotensbevis:
- `properties.definitionVersion` rapporteras tas bort på alla policy assignments — Azure-managed property som inte sätts av mallen (false positive)
- `policyRule` visas som `~ Modify` på alla custom policy definitions — ARM kan inte resolva `copyIndex()` vid what-if-tid och jämför råa ARM-uttryck mot deployade värden (känd ARM-begränsning)
- `doNotVerifyRemoteGateways: false → true` på VNet peerings — computed property, troligen false positive
- governance-int-root: loggen trunkeras av GitHub Actions p.g.a. outputstorlek — sammanfattningsraden syns inte

**Slutsats:** What-if är oanvändbar som förändringsindikator för policy-tung ALZ-infrastruktur. De flesta ALZ-team accepterar bruset. Pipeline Succeeded utan retries används som idempotensbevis för denna körning.

**Metodbyte för Del 4 (Alens test):** ARM-state exporteras till JSON före och efter idempotenskörningen och jämförs med diff — ger ett definitivt, brusfrips bevis oberoende av what-if.

---

## Del 3 — Kontrollerad förändring + rollback (K2 + K3 + K4)

### Del 3a — Applicera förändring (SECURITY_CONTACT_EMAIL)

| Fält | Värde |
|------|-------|
| Ändring | `SECURITY_CONTACT_EMAIL: "" → "oskar.granlof@nordlo.com"` |
| Commit SHA | ef01b55 |
| PR-länk | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/66 |
| Starttid | 14:55 |
| Sluttid | 15:16 |
| Varaktighet | ~21 min |
| Actions run URL | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22672449387 |
| Slutstatus | Succeeded |
| Verifierad i Azure | ✅ Policy assignment "Deploy Microsoft Defender for Cloud configuration" på alz MG visar emailSecurityContact = "oskar.granlof@nordlo.com" |
| Kommentar | Endast governance-int-root kördes (enda steget som påverkas av SECURITY_CONTACT_EMAIL) |

### Del 3b — Rollback

| Fält | Värde |
|------|-------|
| Revert commit SHA | 2139a5b |
| PR-länk | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/67 |
| Actions run URL | |
| Slutstatus | |
| Miljö återställd | |
| Kommentar | |

### Spårbarhet (K2)

```
commit (change) → PR → Actions run → förändring i Azure
      ↓
commit (revert) → PR → Actions run → återställt tillstånd
```

| Länk | Värde |
|------|-------|
| Change commit | ef01b55 |
| Change PR | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/66 |
| Change Actions run | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22672449387 |
| Revert commit | 2139a5b |
| Revert PR | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/67 |
| Revert Actions run | |

---

## Del 4 — Cold start Alen (K6 #2 + K1 #3)

### Plan: Deployment Stack-jämförelse för idempotensverifiering

What-if är opålitlig för policy-tung infrastruktur (se Del 2). Istället exporteras alla Deployment Stacks
efter CD #3 och CD #4 och jämförs med diff. Stacks listar exakt vilka resurser de äger — om listan är
identisk (bortsett från timestamps) är deployn bevisligen idempotent.

**Steg:**
1. Kör CD #3 (Alens cold start) → `Succeeded`
2. Kör exportskript → sparar till `stacks-after-cd3.json`
3. Kör CD #4 (inga ändringar, `skip_what_if: true`)
4. Kör exportskript → sparar till `stacks-after-cd4.json`
5. Diff de två filerna (exkludera timestamps) → förväntat: identiska

**Exportskript (PowerShell):**
```powershell
$mgStacks = @(
    @{ MgId = '3aadcd6c-...'; Name = '3aadcd6c-...-governance-int-root' }
    @{ MgId = 'alz';          Name = 'alz-governance-platform' }
    @{ MgId = 'alz';          Name = 'alz-governance-landingzones' }
    @{ MgId = 'alz';          Name = 'alz-governance-landingzones-corp' }
    @{ MgId = 'alz';          Name = 'alz-governance-landingzones-online' }
    @{ MgId = 'alz';          Name = 'alz-governance-sandbox' }
    @{ MgId = 'alz';          Name = 'alz-governance-decommissioned' }
    @{ MgId = 'alz';          Name = 'alz-governance-rbac' }
)

$result = foreach ($s in $mgStacks) {
    Get-AzManagementGroupDeploymentStack -ManagementGroupId $s.MgId -Name $s.Name |
        Select-Object Name, ProvisioningState, Resources, DeletedResources, DetachedResources
}

# Subscription-scoped stacks
$result += Get-AzSubscriptionDeploymentStack -Name 'alz-core-logging' |
    Select-Object Name, ProvisioningState, Resources, DeletedResources, DetachedResources
$result += Get-AzSubscriptionDeploymentStack -Name 'alz-networking-hub' |
    Select-Object Name, ProvisioningState, Resources, DeletedResources, DetachedResources

$result | ConvertTo-Json -Depth 20 | Out-File "stacks-after-cd3.json"  # byt filnamn för cd4
```

**Godkänt om:** `diff stacks-after-cd3.json stacks-after-cd4.json` visar inga skillnader utöver timestamps,
och `DeletedResources`/`DetachedResources` är tomma i båda.

### Förutsättningar

| Check | Status |
|-------|--------|
| Tenant: enbart tenant root management group och en subscription | |
| Utföraren är Owner + User Access Administrator på tenant root | |
| GitHub-repot alz-mgmt-alen har inga environments | |

### Onboard

| Fält | Värde |
|------|-------|
| Starttid | |
| Sluttid | |
| Utfall | |
| Kommentar | |

### CD-körning #3

| Fält | Värde |
|------|-------|
| Starttid | |
| Sluttid | |
| Actions run URL | |
| Slutstatus | |
| Hierarki identisk med Oskars | |
| Kommentar | |

---

## Sammanfattning

| Kriterium | Körning | Datum | Utfall | Artefakt |
|-----------|---------|-------|--------|----------|
| K1 | #1 Cold start Oskar | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22644686558 |
| K1 | #2 Idempotent Oskar | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22647650534 |
| K1 | #3 Cold start Alen | 2026-03-03 | | |
| K2 | Förändring (email) | 2026-03-03 | | |
| K2 | Rollback | 2026-03-03 | | |
| K3 | Förändring via PR | 2026-03-03 | | |
| K3 | Rollback via PR | 2026-03-03 | | |
| K4 | Rollback-deploy | 2026-03-03 | | |
| K6 | Cold start Oskar | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22644686558 |
| K6 | Cold start Alen | 2026-03-03 | | |

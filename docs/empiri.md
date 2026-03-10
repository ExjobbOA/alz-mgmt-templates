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
| K5 | Förändringspåverkan | `Compare-ALZStackState.ps1` skriver `K5 PASSED` — enbart governance-int-root ändrades, alla övriga 10 stackar UNCHANGED |
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
| MG-hierarki (alz → platform, landingzones, sandbox, decommissioned) | ✅ [screenshot](screenshots/del1-mg-hierarchy.png) |
| Policy assignments på alz MG (16 st) | ✅ [screenshot](screenshots/del1-policy-assignments.png) |
| Policy assignments på platform MG (61 st) | ✅ [screenshot](screenshots/del1-policy-platform.png) |
| Policy assignments på landingzones MG (69 st) | ✅ [screenshot](screenshots/del1-policy-landingzones.png) |
| Resource group rg-alz-logging-swedencentral med LAW, UAMI, DCRs | ✅ [screenshot](screenshots/del1-resource-groups.png) |
| Resource groups rg-alz-conn-swedencentral och rg-alz-conn-northeurope med hub VNets | ✅ [screenshot](screenshots/del1-resource-groups.png) |
| VNet peering Connected mellan swedencentral och northeurope | ✅ [screenshot](screenshots/del1-vnet-peering.png) |

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

## Del 3 — Kontrollerad förändring + rollback + K5 (K2 + K3 + K4 + K5)

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
| Verifierad i Azure | ✅ emailSecurityContact = "oskar.granlof@nordlo.com" i policy assignment på alz MG — [screenshot](screenshots/del3a-email-set.png) |
| Kommentar | Endast governance-int-root kördes (enda steget som påverkas av SECURITY_CONTACT_EMAIL) |

### Del 3b — Rollback

| Fält | Värde |
|------|-------|
| Revert commit SHA | 2139a5b |
| PR-länk | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/67 |
| Starttid | 15:25 |
| Sluttid | 15:43 |
| Varaktighet | ~18 min |
| Actions run URL | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22673623003 |
| Slutstatus | Succeeded |
| Miljö återställd | ✅ emailSecurityContact tomt i policy assignment på alz MG — [screenshot](screenshots/del3b-email-empty.png) |
| Kommentar | Endast governance-int-root kördes |

### Del 3c — K5 förändringspåverkan (Deployment Stack-diff, Oskars tenant)

Metodbyte: ARM what-if är opålitlig för policy-tung infrastruktur (se Del 2). Istället används
`Export-ALZStackState.ps1` + `Compare-ALZStackState.ps1` (scripts/ i templates-repot) för att
fånga två lager per stack: stack-metadata (DeploymentId) och resursinnehåll (faktiska policy
assignment-parametrar). Diff av JSON-exporterna ger definitiv, brusfrisk bevisning.

**Baseline:** `SECURITY_CONTACT_EMAIL: "oskar.granlof@nordlo.com"` (nuläge efter Del 3a).
**Förändring:** `SECURITY_CONTACT_EMAIL: "oskar.granlof@nordlo.com" → "test@example.com"`.
Metodvalet att använda ett värde→värde-byte (inte tomt→värde) gör att baseline kan exporteras
direkt utan extra CD-körning, och ger ett tydligare parameterdiff.

| Fält | Värde |
|------|-------|
| Baseline-export | state-before.json (exporterad 2026-03-04 21:00) |
| Ändring | `SECURITY_CONTACT_EMAIL: "oskar.granlof@nordlo.com" → "test@example.com"` |
| Commit SHA | 0b99811 |
| PR-länk | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/69 |
| Starttid CD | 21:17 |
| Sluttid CD | 21:39 |
| Varaktighet | ~22 min |
| Actions run URL | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22687444623 |
| Slutstatus | Succeeded |
| CD-steg körda | governance-int-root only |
| Export efter ändring | state-after.json (exporterad 2026-03-04 21:39) |
| Diff: endast governance-int-root | ✅ |
| K5 godkänt | ✅ |

**Compare-skript output:**

```
============================================
 K5 Change Containment -- Diff Report
============================================
Before: state-before.json
After:  state-after.json

  CHANGED: 3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7-governance-int-root
    DeploymentId changed
    Resource changed: Deploy-MDFC-Config-H224
      -> Policy assignment parameters changed
      -> Parameter 'emailSecurityContact': {"value":"oskar.granlof@nordlo.com"} -> {"value":"test@example.com"}
    Resource changed: Deploy-SvcHealth-BuiltIn
      -> Policy assignment parameters changed
      -> Parameter 'actionGroupResources': {"value":{"actionGroupEmail":["oskar.granlof@nordlo.com"],...}} -> {"value":{"actionGroupEmail":["test@example.com"],...}}
  UNCHANGED: alz-governance-platform
  UNCHANGED: alz-governance-landingzones
  UNCHANGED: alz-governance-landingzones-corp
  UNCHANGED: alz-governance-landingzones-online
  UNCHANGED: alz-governance-sandbox
  UNCHANGED: alz-governance-decommissioned
  UNCHANGED: alz-governance-platform-rbac
  UNCHANGED: alz-governance-landingzones-rbac
  UNCHANGED: alz-core-logging
  UNCHANGED: alz-networking-hub

============================================
 Summary
============================================
Changed stacks:   1
Unchanged stacks: 10

RESULT: Only '3aadcd6c-...-governance-int-root' was affected.
K5 PASSED: Change was contained to the expected scope.
```

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
| Revert Actions run | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22673623003 |

---

## Del 4 — Cold start Alen (K6 #2 + K1 #3 + K5)

### Plan: Deployment Stack-jämförelse för idempotens- och förändringspåverkan

What-if är opålitlig för policy-tung infrastruktur (se Del 2). Istället exporteras alla Deployment Stacks
och jämförs med diff. Metoden används för två syften:

- **K1 idempotens:** Stacks före och efter en no-change-körning är identiska
- **K5 förändringspåverkan:** Stacks före och efter en avgränsad ändring skiljer sig *enbart* på förväntade stackar

**Steg:**
1. Kör CD #3 (Alens cold start) → `Succeeded`
2. Kör exportskript → `stacks-baseline.json`
3. Applicera avgränsad ändring (`SECURITY_CONTACT_EMAIL`) → PR → merge → CD #4 (governance-int-root)
4. Kör exportskript → `stacks-after-change.json`
5. Diff: förväntat att **endast** governance-int-root-stacken skiljer → K5 bevisat
6. Kör CD #5 (inga ändringar, `skip_what_if: true`)
7. Kör exportskript → `stacks-after-cd5.json`
8. Diff stacks-after-change.json vs stacks-after-cd5.json → identiska → K1 idempotens bevisat

**Export och diff (PowerShell) — använder `scripts/Export-ALZStackState.ps1` och `scripts/Compare-ALZStackState.ps1`:**

```powershell
# Export (kör med rätt -OutputFile per steg)
cd c:\repos\alz-mgmt-templates
./scripts/Export-ALZStackState.ps1 `
    -OutputFile "state-alen-baseline.json" `
    -SubscriptionId "<ALENS_SUBSCRIPTION_ID>" `
    -TenantIntRootMgId "<ALENS_TENANT_GUID>"

# Diff (K5: baseline vs after-change)
powershell -ExecutionPolicy Bypass -File ./scripts/Compare-ALZStackState.ps1 `
    -BeforeFile "state-alen-baseline.json" `
    -AfterFile "state-alen-after-change.json"

# Diff (K1: after-change vs after-cd5)
powershell -ExecutionPolicy Bypass -File ./scripts/Compare-ALZStackState.ps1 `
    -BeforeFile "state-alen-after-change.json" `
    -AfterFile "state-alen-after-cd5.json"
```

Skripten fångar två lager per stack: stack-metadata (DeploymentId) och resursinnehåll (policy
assignment-parametrar). Se Del 3c för metodbeskrivning och exempeloutput.

**K5 godkänt om:** Compare-skriptet skriver `K5 PASSED` — enbart governance-int-root-stacken ändrades.

**K1 godkänt om:** Compare-skriptet skriver `RESULT: No stacks changed. Deployment was fully idempotent.`

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

### CD-körning #3 (cold start)

| Fält | Värde |
|------|-------|
| Starttid | |
| Sluttid | |
| Actions run URL | |
| Slutstatus | |
| Hierarki identisk med Oskars | |
| Kommentar | |

### Stack-export baseline

| Fält | Värde |
|------|-------|
| Fil | stacks-baseline.json |
| Status | |

### CD-körning #4 — K5 förändring (SECURITY_CONTACT_EMAIL)

| Fält | Värde |
|------|-------|
| Ändring | `SECURITY_CONTACT_EMAIL: "" → "test@example.com"` |
| Commit SHA | |
| PR-länk | |
| Starttid | |
| Sluttid | |
| Actions run URL | |
| Slutstatus | |
| Kommentar | Endast governance-int-root |

### Stack-export efter förändring

| Fält | Värde |
|------|-------|
| Fil | stacks-after-change.json |
| Diff mot baseline | |
| K5 godkänt | |

### CD-körning #5 — K1 idempotens (no-change)

| Fält | Värde |
|------|-------|
| Starttid | |
| Sluttid | |
| Actions run URL | |
| Slutstatus | |
| Kommentar | skip_what_if: true |

### Stack-export efter idempotenskörning

| Fält | Värde |
|------|-------|
| Fil | stacks-after-cd5.json |
| Diff mot stacks-after-change.json | |
| K1 godkänt | |

---

## Sammanfattning

| Kriterium | Körning | Datum | Utfall | Artefakt |
|-----------|---------|-------|--------|----------|
| K1 | #1 Cold start Oskar | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22644686558 |
| K1 | #2 Idempotent Oskar | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22647650534 |
| K1 | #3 Cold start Alen | 2026-03-03 | | |
| K2 | Förändring (email) | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22672449387 |
| K2 | Rollback | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22673623003 |
| K3 | Förändring via PR | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/66 |
| K3 | Rollback via PR | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/67 |
| K4 | Rollback-deploy | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22673623003 |
| K5 | Förändringspåverkan Oskar (stack-diff) | 2026-03-04 | K5 PASSED | state-before.json vs state-after.json — 1/11 stackar ändrad (governance-int-root), [CD run](https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22687444623) |
| K5 | Förändringspåverkan Alen (stack-diff) | 2026-03-04 | | state-before.json vs state-after.json |
| K6 | Cold start Oskar | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22644686558 |
| K6 | Cold start Alen | 2026-03-04 | | |

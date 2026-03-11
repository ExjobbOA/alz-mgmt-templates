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

## Del 4 — Alens tenant (K6 + K1 + K2 + K3 + K4 + K5)

Alla kriterier verifieras på Alens greenfield-tenant. Export och diff via
`scripts/Export-ALZStackState.ps1` + `scripts/Compare-ALZStackState.ps1` (se Del 3c för metodbeskrivning).

Hämta Alens tenant-GUID och subscription-ID före start:
```powershell
Connect-AzAccount
Get-AzTenant        # MANAGEMENT_GROUP_ID / TenantIntRootMgId
Get-AzSubscription  # SubscriptionId
```

---

### Fas 1 — Förutsättningar

| Check | Status |
|-------|--------|
| Tenant: enbart tenant root MG + en subscription | |
| Inga GitHub environments i alz-mgmt-alen | |
| `alz-mgmt-alen` på main, ren | |
| `alz-mgmt-templates` på main, ren | |
| `SECURITY_CONTACT_EMAIL: ""` i alz-mgmt-alen/config/platform.json | |
| `az login --tenant <id>` + `gh auth login` klart | |
| `Connect-AzAccount` + `Set-AzContext` klart (för cleanup + export) | |

---

### Fas 2 — Cleanup

```powershell
Connect-AzAccount
Set-AzContext -Subscription "<ALENS_SUB_ID>"
cd c:\repos\alz-mgmt-templates
./scripts/cleanup.ps1
```

| Fält | Värde |
|------|-------|
| Utfall | |
| Kommentar | |

---

### Fas 3 — Onboard (K6)

```powershell
az login --tenant <ALENS_TENANT_GUID>
gh auth login
./scripts/onboard.ps1 `
    -ConfigRepoPath       '../alz-mgmt-alen' `
    -ModuleRepo           'alz-mgmt-alen' `
    -BootstrapSubscriptionId '<ALENS_SUB_ID>' `
    -ManagementGroupId    '<ALENS_TENANT_GUID>' `
    -Location             'swedencentral'
```

| Fält | Värde |
|------|-------|
| Starttid | 12:52 |
| Sluttid | 12:53 |
| Utfall | Succeeded |
| GitHub environments skapade | alz-mgmt-plan + alz-mgmt-apply, båda med AZURE_CLIENT_ID satt |
| Kommentar | Varaktighet ~1 min |

---

### Fas 4 — CD #1: Cold start (K6 + K1 körning #3)

Trigga CD med **alla steg aktiverade**.

**Not — DDoS policy-bug:** Första körningsförsöket (starttid 12:57) avbröts vid networking-steget med `LinkedAuthorizationFailed` — Azure Policy `Enable-DDoS-VNET` med `Modify`-effekt injicerade ett placeholder DDoS-plan med subscription `00000000-0000-0000-0000-000000000000` i hub-VNetsen. Fixen (override `effect: Audit` i `platform/main.bicepparam` och `landingzones/main.bicepparam`, matchandes Oskars konfiguration) applicerades via PR i `alz-mgmt-alen` och `alz-mgmt-templates` innan omstarten. Omstarten kördes med skip_what_if.

| Fält | Värde |
|------|-------|
| Starttid | 14:51 |
| Sluttid | 15:56 |
| Varaktighet | ~1h 5min |
| Actions run URL | https://github.com/ExjobbOA/alz-mgmt-alen/actions/runs/22905778818 |
| Slutstatus | Succeeded |
| Kommentar | Ingen retry — alla steg gröna |

**Screenshots efter CD:**

| Screenshot | Tagen |
|------------|-------|
| MG-hierarki (alz → platform, landingzones, sandbox, decommissioned) | ✅ [screenshot](screenshots/del4-mg-hierarchy.jpeg) |
| Policy assignments (alz-MG, 16 st) | ✅ [screenshot](screenshots/del4-policy-alz.jpeg) |
| Policy assignments (platform-MG, 61 st) | ✅ [screenshot](screenshots/del4-policy-platform.jpeg) |
| Policy assignments (landingzones-MG, 69 st) | ✅ [screenshot](screenshots/del4-policy-landingzones.jpeg) |
| Resource groups på subscriptionen | ✅ [screenshot](screenshots/del4-resource-groups.jpeg) |
| VNet swedencentral (capabilities, 1 peering) | ✅ [screenshot](screenshots/del4-vnet-overview.jpeg) |
| VNet peering Connected (swedencentral ↔ northeurope) | ✅ [screenshot](screenshots/del4-vnet-peering.jpeg) |

---

### Fas 5 — Stack-export baseline

```powershell
cd c:\repos\alz-mgmt-templates
./scripts/Export-ALZStackState.ps1 `
    -OutputFile "state-alen-baseline.json" `
    -SubscriptionId "<ALENS_SUB_ID>" `
    -TenantIntRootMgId "<ALENS_TENANT_GUID>"
```

| Fält | Värde |
|------|-------|
| Fil | state-alen-baseline.json |
| Antal stackar exporterade | 11 |
| Alla ProvisioningState: succeeded | ✅ |

---

### Fas 6 — K5 förändring: SECURITY_CONTACT_EMAIL (K2 + K3 + K5)

I `alz-mgmt-alen`:
```powershell
git checkout -b test/k5-email-change
# Sätt SECURITY_CONTACT_EMAIL: "alen@example.com" i config/platform.json
git add config/platform.json
git commit -m "test: set SECURITY_CONTACT_EMAIL for K5 stack-diff test"
git push -u origin test/k5-email-change
# Skapa PR, merga
```

| Fält | Värde |
|------|-------|
| Ändring | `SECURITY_CONTACT_EMAIL: "" → "alen@example.com"` |
| Commit SHA | 3a2f8c0 |
| PR-länk | https://github.com/ExjobbOA/alz-mgmt-alen/pull/7 |

#### CD #2 — K5-ändring (governance-int-root only)

| Fält | Värde |
|------|-------|
| Starttid | 17:21 |
| Sluttid | 17:44 |
| Varaktighet | ~22 min |
| Actions run URL | https://github.com/ExjobbOA/alz-mgmt-alen/actions/runs/22912613229 |
| Slutstatus | Succeeded |

**Screenshot:** Policy assignment `Deploy-MDFC-Config-H224` → `emailSecurityContact = "alen@example.com"` i Azure Portal.

| Screenshot | Tagen |
|------------|-------|
| emailSecurityContact satt | ✅ [screenshot](screenshots/del4-email-set.png) |

---

### Fas 7 — Stack-export efter förändring + K5-diff

```powershell
./scripts/Export-ALZStackState.ps1 `
    -OutputFile "state-alen-after-change.json" `
    -SubscriptionId "<ALENS_SUB_ID>" `
    -TenantIntRootMgId "<ALENS_TENANT_GUID>"

powershell -ExecutionPolicy Bypass -File ./scripts/Compare-ALZStackState.ps1 `
    -BeforeFile "state-alen-baseline.json" `
    -AfterFile "state-alen-after-change.json"
```

**Not — Compare-skript bugg åtgärdad:** Det ursprungliga `Compare-ALZStackState.ps1` jämförde hela resurs-snapshots som råa JSON-strängar via `ConvertTo-Json -Compress`. PowerShells JSON-serialisering producerar icke-deterministisk property-ordning mellan körningar, vilket gav falska positiver — 6 stackar rapporterades som ändrade trots att innehållet var identiskt. Scriptet skrevs om till typmedveten fältspecifik jämförelse: för `policyAssignment` jämförs `Parameters` nyckel-för-nyckel (sorterade) + `EnforcementMode`; för `policyDefinition` jämförs `PolicyRuleHash`; för `policySetDefinition` jämförs `PolicyDefinitionCount`. Efter fixen ger scriptet korrekt utfall.

| Fält | Värde |
|------|-------|
| Fil | state-alen-after-change.json |
| K5 godkänt | ✅ |

**Compare-skript output:**

```
============================================
 K5 Change Containment -- Diff Report
============================================
Before: state-alen-baseline.json
After:  state-alen-after-change.json

  CHANGED: c785e463-29cf-46e6-9b1d-ae17db0a6ac4-governance-int-root
    DeploymentId changed
    Resource changed: Deploy-MDFC-Config-H224
      -> Policy assignment parameters changed
      -> Parameter 'emailSecurityContact': {"value":""} -> {"value":"alen@example.com"}
    Resource changed: Deploy-SvcHealth-BuiltIn
      -> Policy assignment parameters changed
      -> Parameter 'actionGroupResources': {"value":{"actionGroupEmail":[""],...}} -> {"value":{"actionGroupEmail":["alen@example.com"],...}}
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

RESULT: Only 'c785e463-29cf-46e6-9b1d-ae17db0a6ac4-governance-int-root' was affected.
K5 PASSED: Change was contained to the expected scope.
```

---

### Fas 8 — Rollback: SECURITY_CONTACT_EMAIL (K4 + K2 + K3)

I `alz-mgmt-alen`:
```powershell
git checkout -b test/revert-del4-k5-email
# Sätt SECURITY_CONTACT_EMAIL: "" i config/platform.json
git add config/platform.json
git commit -m "test: revert SECURITY_CONTACT_EMAIL for Del 4 K5 rollback test"
git push -u origin test/revert-del4-k5-email
# Skapa PR, merga
```

| Fält | Värde |
|------|-------|
| Ändring | `SECURITY_CONTACT_EMAIL: "alen@example.com" → ""` |
| Commit SHA | 0987ca4 |
| PR-länk | https://github.com/ExjobbOA/alz-mgmt-alen/pull/8 |

#### CD #3 — Rollback (governance-int-root only)

| Fält | Värde |
|------|-------|
| Starttid | 13:50 |
| Sluttid | 14:10 |
| Varaktighet | ~20 min |
| Actions run URL | https://github.com/ExjobbOA/alz-mgmt-alen/actions/runs/22953276891 |
| Slutstatus | Succeeded |

**Screenshot:** `emailSecurityContact` tomt i Azure Portal.

| Screenshot | Tagen |
|------------|-------|
| emailSecurityContact tomt | ✅ [screenshot](screenshots/del4-email-reverted.jpeg) |

---

### Fas 9 — K1 Idempotens (stack-diff)

Exportera state efter rollback, kör sedan CD igen utan ändringar, exportera igen och diff.

```powershell
./scripts/Export-ALZStackState.ps1 `
    -OutputFile "state-alen-after-revert.json" `
    -SubscriptionId "<ALENS_SUB_ID>" `
    -TenantIntRootMgId "<ALENS_TENANT_GUID>"
```

#### CD #4 — Idempotens (governance-int-root only, inga ändringar)

| Fält | Värde |
|------|-------|
| Starttid | 14:16 |
| Sluttid | 14:38 |
| Varaktighet | ~22 min |
| Actions run URL | https://github.com/ExjobbOA/alz-mgmt-alen/actions/runs/22954477017 |
| Slutstatus | Succeeded |

```powershell
./scripts/Export-ALZStackState.ps1 `
    -OutputFile "state-alen-after-cd4.json" `
    -SubscriptionId "<ALENS_SUB_ID>" `
    -TenantIntRootMgId "<ALENS_TENANT_GUID>"

powershell -ExecutionPolicy Bypass -File ./scripts/Compare-ALZStackState.ps1 `
    -BeforeFile "state-alen-after-revert.json" `
    -AfterFile "state-alen-after-cd4.json"
```

| Fält | Värde |
|------|-------|
| Fil | state-alen-after-cd4.json |
| K1 godkänt | ✅ |

**Not — idempotenstolkning:** `DeploymentId changed` är förväntat — varje CD-körning skapar ett nytt deployment. Frånvaron av `Resource changed`-rader bevisar att stack-innehållet (policy assignment-parametrar, enforcement mode, policy definition hashes) är identiskt före och efter omdriftsättningen.

**Compare-skript output:**

```
============================================
 K5 Change Containment -- Diff Report
============================================
Before: state-alen-after-revert.json
After:  state-alen-after-cd4.json

  CHANGED: c785e463-29cf-46e6-9b1d-ae17db0a6ac4-governance-int-root
    DeploymentId changed
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

RESULT: Only 'c785e463-...-governance-int-root' was affected.
K5 PASSED: Change was contained to the expected scope.
```

---

## Sammanfattning

| Kriterium | Körning | Datum | Utfall | Artefakt |
|-----------|---------|-------|--------|----------|
| K1 | #1 Cold start Oskar | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22644686558 |
| K1 | #2 Idempotent Oskar | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22647650534 |
| K1 | #3 Cold start Alen | 2026-03-10 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-alen/actions/runs/22905778818 |
| K1 | #4 Idempotent Alen (stack-diff) | 2026-03-11 | K1 PASSED | state-alen-after-revert.json vs state-alen-after-cd4.json — DeploymentId ändrad, inget innehåll ändrat, [CD run](https://github.com/ExjobbOA/alz-mgmt-alen/actions/runs/22954477017) |
| K2 | Förändring (email) | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22672449387 |
| K2 | Rollback | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22673623003 |
| K3 | Förändring via PR | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/66 |
| K3 | Rollback via PR | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/pull/67 |
| K4 | Rollback-deploy Oskar | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22673623003 |
| K4 | Rollback-deploy Alen | 2026-03-11 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-alen/actions/runs/22953276891 |
| K5 | Förändringspåverkan Oskar (stack-diff) | 2026-03-04 | K5 PASSED | state-before.json vs state-after.json — 1/11 stackar ändrad (governance-int-root), [CD run](https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22687444623) |
| K5 | Förändringspåverkan Alen (stack-diff) | 2026-03-10 | K5 PASSED | state-alen-baseline.json vs state-alen-after-change.json — 1/11 stackar ändrad (governance-int-root), [CD run](https://github.com/ExjobbOA/alz-mgmt-alen/actions/runs/22912613229) |
| K6 | Cold start Oskar | 2026-03-04 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-oskar/actions/runs/22644686558 |
| K6 | Cold start Alen | 2026-03-10 | Succeeded | https://github.com/ExjobbOA/alz-mgmt-alen/actions/runs/22905778818 |

# T8 — Cold start

**Test ID:** T8
**Criterion:** K4 Automatiserad driftsättning
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Tenant:** Tom test-tenant (separat från Oskar test tenant)

---

## Syfte

Visa att plattformen kan driftsättas från grunden mot en helt tom tenant genom att
följa runbook:en, och att antalet manuella steg är dokumenterade och minimerade. Cold
start är det starkaste testet av plattformens automation eftersom inga tidigare
deployment-state finns att luta sig på.

K4 mäts genom att exekvera runbook:en med stoppur och logga varje steg.

---

## Context

Plattformen är designad för att en operatör (eller automation) ska kunna ta en tom
Azure-tenant från noll till deployad ALZ-baseline genom att följa runbook:en utan
specialkunskap. Mål är att minimera antalet manuella steg, inte att uppnå noll.

Tidigare iterationer (T1-T7) har kört mot en redan onboardad tenant. T8 är första
gången hela kedjan testas från noll, vilket validerar att inga implicita steg eller
beroenden finns som tagits för givna.

---

## Phase 0 — Pre-flight

### 0.1 Krav på cold start-tenanten

- Tom Azure-tenant utan tidigare ALZ-deployment
- Subscription med tillräckliga rättigheter (Owner på subscription, Management Group
  Contributor på tenant root)
- Tillgång till runbook-dokumentet

### 0.2 Verktyg

- ALZ PowerShell-modulen för bootstrap (om relevant)
- alzlibtool för library-generering
- GitHub-tillgång för att skapa nytt tenant-repo

### 0.3 Runbook-referens

Plats för runbook: _paste path eller URL_

---

## Phase 1 — Exekvera runbook med stoppur

För varje steg, dokumentera tid och om steget var manuellt eller automatiserat.

| # | Steg | Start | Slut | Duration | Manuellt? | Anteckningar |
|---|---|---|---|---|---|---|
| 1 | Skapa nytt tenant-repo | _ | _ | _ | _ | _ |
| 2 | Bootstrap accelerator (alz PowerShell) | | | | | |
| 3 | Konfigurera platform.json med tenant-värden | | | | | |
| 4 | Skapa OIDC federated credentials | | | | | |
| 5 | Sätta GitHub repo Variables (CLIENT_ID, TENANT_ID, etc) | | | | | |
| 6 | Konfigurera branch protection | | | | | |
| 7 | Generera ALZ library via alzlibtool | | | | | |
| 8 | Push till main, första CD körs | | | | | |
| 9 | Verifiera 11 stackar grön | | | | | |

**Total tid:** _paste_

**Antal manuella steg:** _paste_

**Antal odokumenterade manuella steg (finding):** _paste_

---

## Phase 2 — Verifiera resultat

### 2.1 Stack-state efter cold start

```powershell
Set-AzContext -SubscriptionId "<cold-start-subscription>"

Get-AzManagementGroupDeploymentStack -ManagementGroupId "<tenant-root-id>"
Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz"
Get-AzSubscriptionDeploymentStack
```

| Stack | ProvisioningState | Resources | Detached |
|---|---|---|---|
| _ | _ | _ | _ |

Förväntat: alla 11 stackar succeeded, 0 detached.

### 2.2 What-if mot deployad kod

Verifiera att second pass är tyst (idempotent).

---

## Phase 3 — Resultat

### 3.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| Cold start kan exekveras från runbook utan eskalering | _ | Phase 1-tabellen |
| Alla 11 stackar succeeded efter första CD | _ | Phase 2.1 |
| Tid från noll till deployad: rimlig (<X timmar) | _ | Phase 1 total |

### 3.2 Observationer

Fyll i alla manuella steg och diskutera om de är nödvändiga eller kan automatiseras.
Detta är det viktigaste output:et från T8 — varje finding är en åtgärd för framtida
runbook-förbättringar.

[Fyll i efter körning]

### 3.3 Verdict

- [ ] K4 Passed (alla manuella steg är dokumenterade i runbook)
- [ ] K4 Partially passed (odokumenterade manuella steg uppstod)
- [ ] K4 Not passed (cold start kunde inte slutföras)

**En-meningskommentar:** _paste efter körning_

---

## Evidens-artefakter

1. Runbook-version som följdes (commit-SHA eller datum)
2. Phase 1-tabellen som logg
3. Stack-state-output efter cold start
4. Eventuella screenshots av OIDC-konfig, branch protection, etc
5. Lista på findings (odokumenterade manuella steg) för framtida runbook-uppdatering

---

## Notering

T8 är resurskrävande och bör schemaläggas på en hel dag. Om det failar efter en längre
exekvering, klassificera failure-läget noggrant — det är värdefull data om var
runbook:en behöver förbättras.

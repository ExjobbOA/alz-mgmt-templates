# Testplan — Alens tenant (Del 4)

Fullständigt testpass på Alens greenfield-tenant. Bevisar K1, K2, K3, K4, K5, K6.

## Vad bevisas

| Fas | Kriterium | Metod |
|-----|-----------|-------|
| 3 | K6 | Onboard med enbart dokumenterade kommandon mot greenfield-tenant |
| 4 | K6 + K1 #3 | CD #1 (full cold start) Succeeded |
| 6–7 | K2 + K3 + K5 | Kontrollerad ändring via PR → CD → stack-diff visar K5 PASSED |
| 8 | K4 + K2 + K3 | Rollback via PR → CD → emailSecurityContact tomt |
| 9 | K1 idempotens | CD utan ändringar → stack-diff visar No stacks changed |

---

## Fas 1 — Förutsättningar

Verifiera innan ni börjar:

- [ ] Alens tenant: enbart tenant root MG + en subscription, inga Deployment Stacks, inga sub-MGs
- [ ] Inga GitHub environments i `alz-mgmt-alen` (Settings → Environments)
- [ ] `alz-mgmt-alen` på `main`, ren (`git status`)
- [ ] `alz-mgmt-templates` på `main`, ren
- [ ] `SECURITY_CONTACT_EMAIL: ""` i `alz-mgmt-alen/config/platform.json`

Hämta Alens IDs:
```powershell
Connect-AzAccount
Get-AzTenant        # MANAGEMENT_GROUP_ID / TenantIntRootMgId
Get-AzSubscription  # SubscriptionId
```

---

## Fas 2 — Cleanup

Återställ Alens tenant till blank slate.

```powershell
Connect-AzAccount
Set-AzContext -Subscription "<ALENS_SUB_ID>"
cd c:\repos\alz-mgmt-templates
./scripts/cleanup.ps1
```

Verifiera att inga sub-MGs eller Deployment Stacks finns kvar i portalen.

---

## Fas 3 — Onboard (K6)

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

Verifiera efteråt:
- GitHub: `alz-mgmt-alen` → Settings → Environments → `alz-mgmt-plan` och `alz-mgmt-apply` finns
- Båda environments har `AZURE_CLIENT_ID` satt

---

## Fas 4 — CD #1: Cold start (K6 + K1 körning #3)

Trigga CD i `alz-mgmt-alen` med **alla steg aktiverade**.

Notera: starttid, sluttid, Actions run URL.

Screenshots att ta när CD är klar:
1. MG-hierarki (Management Groups-vyn i portalen)
2. Policy assignments på `alz`-MG:t
3. Policy assignments på platform-MG:t
4. Policy assignments på landingzones-MG:t
5. Resource groups på subscriptionen
6. VNet / hub peering

---

## Fas 5 — Stack-export baseline

Kör direkt efter CD #1 är klar.

```powershell
cd c:\repos\alz-mgmt-templates
./scripts/Export-ALZStackState.ps1 `
    -OutputFile "state-alen-baseline.json" `
    -SubscriptionId "<ALENS_SUB_ID>" `
    -TenantIntRootMgId "<ALENS_TENANT_GUID>"
```

Verifiera: 11 stackar exporterade, alla `ProvisioningState: succeeded`.

---

## Fas 6 — K5-förändring: SECURITY_CONTACT_EMAIL (K2 + K3 + K5)

### 6a. Gör ändringen i alz-mgmt-alen

```powershell
cd c:\repos\alz-mgmt-alen
git checkout main && git pull
git checkout -b test/k5-email-change
```

Sätt `SECURITY_CONTACT_EMAIL: "alen@example.com"` i `config/platform.json`.

```powershell
git add config/platform.json
git commit -m "test: set SECURITY_CONTACT_EMAIL for K5 stack-diff test"
git push -u origin test/k5-email-change
```

Skapa PR, merga.

### 6b. CD #2 (governance-int-root only)

Trigga CD med **enbart `governance-int-root`** aktiverat.

Notera: starttid, sluttid, Actions run URL.

Screenshot: Policy assignment `Deploy-MDFC-Config-H224` i portalen → visa `emailSecurityContact = "alen@example.com"`.

---

## Fas 7 — Stack-export efter förändring + K5-diff

```powershell
cd c:\repos\alz-mgmt-templates
./scripts/Export-ALZStackState.ps1 `
    -OutputFile "state-alen-after-change.json" `
    -SubscriptionId "<ALENS_SUB_ID>" `
    -TenantIntRootMgId "<ALENS_TENANT_GUID>"

powershell -ExecutionPolicy Bypass -File ./scripts/Compare-ALZStackState.ps1 `
    -BeforeFile "state-alen-baseline.json" `
    -AfterFile "state-alen-after-change.json"
```

Förväntat:
```
K5 PASSED: Change was contained to the expected scope.
Changed stacks: 1 (governance-int-root)
Unchanged stacks: 10
```

Kopiera hela outputen till empiri.md fas 7.

---

## Fas 8 — Rollback (K4 + K2 + K3)

### 8a. Gör rollback i alz-mgmt-alen

```powershell
cd c:\repos\alz-mgmt-alen
git checkout main && git pull
git checkout -b test/k5-email-revert
```

Sätt `SECURITY_CONTACT_EMAIL: ""` i `config/platform.json`.

```powershell
git add config/platform.json
git commit -m "test: revert SECURITY_CONTACT_EMAIL for K4 rollback test"
git push -u origin test/k5-email-revert
```

Skapa PR, merga.

### 8b. CD #3 (governance-int-root only)

Trigga CD med **enbart `governance-int-root`** aktiverat.

Notera: starttid, sluttid, Actions run URL.

Screenshot: Policy assignment `Deploy-MDFC-Config-H224` → `emailSecurityContact` tomt.

---

## Fas 9 — K1 Idempotens (stack-diff)

### 9a. Export efter rollback

```powershell
cd c:\repos\alz-mgmt-templates
./scripts/Export-ALZStackState.ps1 `
    -OutputFile "state-alen-after-revert.json" `
    -SubscriptionId "<ALENS_SUB_ID>" `
    -TenantIntRootMgId "<ALENS_TENANT_GUID>"
```

### 9b. CD #4 (governance-int-root only, inga ändringar)

Trigga CD med **enbart `governance-int-root`** aktiverat. Ingen kodändring — samma config som efter rollback.

Notera: starttid, sluttid, Actions run URL.

### 9c. Export + diff

```powershell
./scripts/Export-ALZStackState.ps1 `
    -OutputFile "state-alen-after-cd4.json" `
    -SubscriptionId "<ALENS_SUB_ID>" `
    -TenantIntRootMgId "<ALENS_TENANT_GUID>"

powershell -ExecutionPolicy Bypass -File ./scripts/Compare-ALZStackState.ps1 `
    -BeforeFile "state-alen-after-revert.json" `
    -AfterFile "state-alen-after-cd4.json"
```

Förväntat:
```
RESULT: No stacks changed. Deployment was fully idempotent.
```

Kopiera hela outputen till empiri.md fas 9.

---

## Fas 10 — Commit state-filer till repo

```powershell
cd c:\repos\alz-mgmt-templates
git add state-alen-*.json
git commit -m "docs(empiri): add Alen tenant stack state exports"
git push
```

Skapa PR, merga.

---

## Sammanfattning: vad dokumenteras var

| Artefakt | Plats |
|----------|-------|
| Starttid/sluttid/Actions URL per CD | empiri.md Del 4 |
| Screenshots | docs/screenshots/del4-*.png + länkat i empiri.md |
| Compare-skript output | empiri.md fas 7 + fas 9 |
| state-alen-*.json | alz-mgmt-templates root (committade) |
| Commit SHA + PR-länk per ändring | empiri.md fas 6 + fas 8 |
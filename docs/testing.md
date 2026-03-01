# Empiriskt testpass — Iteration 1

Syfte: Samla in empiri för utvärderingskriterierna K1, K2, K3, K4 och K6.
K5 tillhör iteration 2 och ingår inte här.

---

## Förutsättningar innan passet

- [ ] Alla öppna PRs mergade i samtliga repos
- [ ] `alz-mgmt-templates`, `alz-mgmt`, `alz-mgmt-3` på `main`, rena
- [ ] Az PowerShell-modul installerad (`Install-Module Az`)
- [ ] Azure CLI installerat (`az`)
- [ ] GitHub CLI installerat (`gh`)
- [ ] Inloggad på Oskars tenant: `az login --tenant 3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`
- [ ] Inloggad på Alens tenant: `az login --tenant c785e463-29cf-46e6-9b1d-ae17db0a6ac4`
- [ ] GitHub CLI autentiserad: `gh auth login`

---

## Pre-steg: Byt namn på config-repos

Görs en gång, innan passet startar. Uppdaterar repo-namn och OIDC FICs.

### 1. Döp om Oskars repo

```powershell
cd c:\Users\granl\repos\alz-mgmt
gh repo rename alz-mgmt-oskar --yes
git remote set-url origin https://github.com/ExjobbOA/alz-mgmt-oskar.git
```

### 2. Döp om Alens repo

```powershell
cd c:\Users\granl\repos\alz-mgmt-3
gh repo rename alz-mgmt-alen --yes
git remote set-url origin https://github.com/ExjobbOA/alz-mgmt-alen.git
```

### 3. Uppdatera plumbing.bicepparam i Oskars repo

Ändra:
```
param moduleRepo = 'alz-mgmt-oskar'
```

### 4. Uppdatera plumbing.bicepparam i Alens repo

Ändra:
```
param moduleRepo = 'alz-mgmt-alen'
```

### 5. Commit + PR i båda repos, merge till main

```powershell
# Oskars repo
cd c:\Users\granl\repos\alz-mgmt
git checkout -b chore/rename-repo
git add config/bootstrap/plumbing.bicepparam
git commit -m "chore: update moduleRepo to alz-mgmt-oskar"
git push -u origin chore/rename-repo

# Alens repo
cd c:\Users\granl\repos\alz-mgmt-3
git checkout -b chore/rename-repo
git add config/bootstrap/plumbing.bicepparam
git commit -m "chore: update moduleRepo to alz-mgmt-alen"
git push -u origin chore/rename-repo
```

Merga båda PRs. Pull main.

---

## Del 1 — Cold start Oskar (K6 + K1 körning #1)

**Täcker:** K6 (cold-start-förmåga), K1 körning #1

### Steg

```powershell
# 1. Cleanup
cd c:\Users\granl\repos\alz-mgmt-templates
Connect-AzAccount -Tenant '3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7'
Set-AzContext -SubscriptionId '6f051987-3995-4c82-abb3-90ba101a0ab4'
./scripts/cleanup.ps1

# 2. Onboard
az login --tenant '3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7'
./scripts/onboard.ps1 `
    -BootstrapSubscriptionId '6f051987-3995-4c82-abb3-90ba101a0ab4' `
    -ManagementGroupId       '3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7'

# 3. CD — triggas manuellt i GitHub Actions
# Aktivera: alla steg (governance-int-root, platform, platform-children,
# landingzones, landingzones-children, sandbox, decommissioned, rbac, core, networking)
# skip_what_if: false
```

### Dokumentera

- [ ] Tidsstämpel för start och slut
- [ ] GitHub Actions run-URL (K1, K6)
- [ ] Slutstatus: Succeeded / Failed
- [ ] Antal retry-triggers (förväntat: 0–2 transientfel ok)
- [ ] Skärmdump: management group-hierarki i Azure-portalen
- [ ] Skärmdump: onboard.ps1 output (terminal)

---

## Del 2 — Idempotent omdriftsättning Oskar (K1 körning #2)

**Täcker:** K1 körning #2 (idempotens)

Kör CD igen direkt efter Del 1, utan några kodändringar.

```
# Triggas manuellt i GitHub Actions — samma inställningar som Del 1
```

### Dokumentera

- [ ] GitHub Actions run-URL
- [ ] Slutstatus: Succeeded
- [ ] What-if output: verifiera att inga resurser ändrades (0 changes expected)
- [ ] Skärmdump: what-if-sammanfattning ur Actions-loggen

---

## Del 3 — Kontrollerad förändring + rollback (K2 + K3 + K4)

**Täcker:** K2 (spårbarhet), K3 (kontrollerad process), K4 (rollback)

### Vald förändring

Lägg till en säkerhetskontakt-epost i `platform.json`:

```json
"SECURITY_CONTACT_EMAIL": "test@example.com"
```

### Steg

**Del 3a — Applicera förändringen**

```powershell
cd c:\Users\granl\repos\alz-mgmt
git checkout main && git pull
git checkout -b test/security-contact-email
# Redigera config/platform.json: sätt SECURITY_CONTACT_EMAIL till "test@example.com"
git add config/platform.json
git commit -m "test: add security contact email for empirical test"
git push -u origin test/security-contact-email
```

- [ ] Skapa PR, merga (K3 — process dokumenterad)
- [ ] Kör CD (core-logging räcker — det är dit SECURITY_CONTACT_EMAIL propagerar)
- [ ] Verifiera förändringen i Azure (policy-parameter / MDFC-konfiguration)
- [ ] Dokumentera: commit-SHA, PR-länk, Actions run-URL, observerat utfall

**Del 3b — Rollback**

```powershell
git checkout main && git pull
git checkout -b test/revert-security-contact
git revert HEAD --no-edit
git push -u origin test/revert-security-contact
```

- [ ] Skapa PR, merga (K3 — revert också via process)
- [ ] Kör CD igen
- [ ] Verifiera att miljön återgick
- [ ] Dokumentera: revert-commit-SHA, PR-länk, Actions run-URL

### Spårbarhet att dokumentera (K2)

```
commit (change) → PR → Actions run → förändring i Azure
      ↓
commit (revert) → PR → Actions run → återställt tillstånd
```

---

## Del 4 — Cold start Alen (K6 körning #2 + K1 körning #3)

**Täcker:** K6 körning #2, K1 körning #3

```powershell
# 1. Cleanup
Connect-AzAccount -Tenant 'c785e463-29cf-46e6-9b1d-ae17db0a6ac4'
Set-AzContext -SubscriptionId '0fbc92c2-828a-4fff-917c-487bf299d344'
cd c:\Users\granl\repos\alz-mgmt-templates
./scripts/cleanup.ps1

# 2. Onboard
az login --tenant 'c785e463-29cf-46e6-9b1d-ae17db0a6ac4'
cd c:\Users\granl\repos\alz-mgmt-templates
./scripts/onboard.ps1 `
    -ConfigRepoPath          'c:\Users\granl\repos\alz-mgmt-3' `
    -BootstrapSubscriptionId '0fbc92c2-828a-4fff-917c-487bf299d344' `
    -ManagementGroupId       'c785e463-29cf-46e6-9b1d-ae17db0a6ac4'

# 3. CD i GitHub Actions för alz-mgmt-alen — alla steg
```

### Dokumentera

- [ ] GitHub Actions run-URL
- [ ] Slutstatus: Succeeded
- [ ] Skärmdump: management group-hierarki i Azure-portalen (Alens tenant)
- [ ] Jämför hierarkin med Oskars → ska vara identisk struktur

---

## Empirisammanfattning

Fyll i efter passet:

| Kriterium | Körning | Datum | Utfall | Artefakt |
|-----------|---------|-------|--------|----------|
| K1 | #1 Cold start Oskar | | | Actions run URL |
| K1 | #2 Idempotent Oskar | | | Actions run URL |
| K1 | #3 Cold start Alen | | | Actions run URL |
| K2 | Förändring (email) | | | Commit SHA + PR |
| K2 | Rollback | | | Commit SHA + PR |
| K3 | Förändring via PR | | | PR-länk |
| K3 | Rollback via PR | | | PR-länk |
| K4 | Rollback-deploy | | | Actions run URL |
| K6 | Cold start Oskar | | | onboard output + Actions |
| K6 | Cold start Alen | | | onboard output + Actions |

---

## Vad räknas som godkänt utfall?

| Kriterium | Godkänt |
|-----------|---------|
| K1 | Alla 3 körningar Succeeded, inga kodkorrigeringar under körning |
| K2 | Fullständig kedja commit → PR → pipeline → Azure-förändring dokumenterad |
| K3 | Samtliga förändringar skedde via PR-flöde, noll direktmanipulation i portalen |
| K4 | Miljön återställd utan manuell rekonstruktion, spårbart i loggar |
| K6 | Cleanup → onboard → CD genomfört med enbart dokumenterade kommandon |

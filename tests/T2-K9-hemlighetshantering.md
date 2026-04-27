# T2 — Hemlighetshantering

**Test ID:** T2
**Criterion:** K9 Hemlighetshantering
**Executed by:** Oskar
**Start date:** 2026-04-27
**End date:** _YYYY-MM-DD_
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Syfte

Visa att plattformens autentiseringsmodell eliminerar behovet av lagrade
credentials. Kumara et al. (2021) och Guerriero et al. (2019) formulerar K9
som principen att hemligheter ska isoleras från kod och injiceras
parametriskt vid exekvering. Plattformen implementerar detta genom OIDC-
federation mellan GitHub Actions och Microsoft Entra ID, vilket gör att
inga client secrets eller service principal-lösenord behöver lagras
överhuvudtaget — kortlivade ID-tokens utbyts vid runtime baserat på
workflow-context.

K9 mäts genom statisk verifiering av att OIDC-modellen är korrekt
implementerad samt att inga alternativa autentiseringsvägar (lagrade
credentials) existerar.

---

## Context

Vid varje CD-körning sker autentisering enligt följande sekvens:

1. GitHub Actions begär en kortlivad ID-token från GitHubs OIDC-provider
2. Tokenen presenteras för Microsoft Entra ID via `azure/login@v2`
3. Entra ID validerar tokenen mot federerade credentials på UAMI:n
4. Om validering lyckas utfärdas en Azure access token för UAMI:n
5. Workflowen autentiserar mot Azure som UAMI:n

Inga steg i denna kedja kräver lagrade lösenord. Federationen etableras
genom subject-claim-matching: workflow-contextet (`repo:org/repo:ref:...`)
måste matcha det subject som konfigurerats på UAMI:ns federerade credential.

---

## Phase 0 — Pre-flight

### 0.1 Komponenter som verifieras

| Komponent | Plats | Vad som verifieras |
|---|---|---|
| Federated credential | UAMI i Azure | Subject, issuer, audience korrekt konfigurerade |
| Workflow-permissions | `.github/workflows/*.yaml` | `id-token: write` satt |
| Workflow-login-steg | `.github/workflows/*.yaml` | `azure/login@v2` med `client-id`/`tenant-id`/`subscription-id` (inte `creds`) |
| GitHub repo secrets | GitHub UI | Inga Azure-credentials lagrade |

---

## Phase 1 — Federated credential på UAMI

### 1.1 Identifiera UAMI:erna för Oskar test tenant

UAMI:erna skapas av bootstrap-flödet och är scoped till tenanten via en
dedikerad identity-subscription. Plattformen använder en split-modell med
två separata UAMIs per tenant: en för plan/what-if (read-only) och en för
apply (write). Detta begränsar what-if-workflowens behörigheter och
förhindrar att en kompromettering av PR-flödet leder till skrivåtkomst.

```powershell
Get-AzUserAssignedIdentity -ResourceGroupName "rg-alz-mgmt-identity-swedencentral-1" |
  Select-Object Name, ResourceGroupName, Location |
  Format-Table -AutoSize
```
Name                                ResourceGroupName                       Location

id-alz-mgmt-swedencentral-apply-1   rg-alz-mgmt-identity-swedencentral-1    swedencentral
id-alz-mgmt-swedencentral-plan-1    rg-alz-mgmt-identity-swedencentral-1    swedencentral

| UAMI | Funktion |
|---|---|
| `id-alz-mgmt-swedencentral-apply-1` | Apply (CD) — write-behörighet |
| `id-alz-mgmt-swedencentral-plan-1` | Plan/what-if (CI) — read-behörighet |

### 1.2 Federerade credentials

```powershell
Get-AzFederatedIdentityCredential `
  -ResourceGroupName "rg-alz-mgmt-identity-swedencentral-1" `
  -IdentityName "id-alz-mgmt-swedencentral-apply-1" |
  Select-Object Name, Issuer, Subject, Audience |
  Format-Table -AutoSize
```
Name         Issuer                                      Subject                                                 Audience

github-apply https://token.actions.githubusercontent.com repo:ExjobbOA/alz-mgmt-oskar:environment:alz-mgmt-apply {api://AzureADTokenExchange}

```powershell
Get-AzFederatedIdentityCredential `
  -ResourceGroupName "rg-alz-mgmt-identity-swedencentral-1" `
  -IdentityName "id-alz-mgmt-swedencentral-plan-1" |
  Select-Object Name, Issuer, Subject, Audience |
  Format-Table -AutoSize
```
Name        Issuer                                      Subject                                                Audience

github-plan https://token.actions.githubusercontent.com repo:ExjobbOA/alz-mgmt-oskar:environment:alz-mgmt-plan {api://AzureADTokenExchange}

Båda federationerna använder GitHub:s officiella OIDC-issuer
(`https://token.actions.githubusercontent.com`) och Microsoft Entra:s
standardaudience (`api://AzureADTokenExchange`). Subject-claim:erna är
environment-scopade, vilket innebär att tokens utfärdade i andra
workflow-contexts (PR-trigger, andra branches, andra repos) inte accepteras
av Entra ID under federation-utbytet.

---

## Phase 2 — Workflow-konfiguration

Plan-jobben (CI och CD what-if) är bundna till environmentet
`alz-mgmt-plan`, apply-jobbet till `alz-mgmt-apply`. Båda matchar
respektive UAMI:s federerade credential-subject (Phase 1.2).
Permissions-blocket beviljar endast `id-token: write` och `contents: read`.

### 2.1 Plan-jobb (CI och CD what-if)

```yaml
whatif:
  environment: alz-mgmt-plan
  permissions:
    id-token: write
    contents: read
```

### 2.2 Apply-jobb (CD)

```yaml
deploy:
  environment: alz-mgmt-apply
  permissions:
    id-token: write
    contents: read
```

### 2.3 OIDC-login (identisk i båda jobb och workflows)

```yaml
- name: OIDC Login to Tenant
  uses: azure/login@v2
  with:
    client-id: ${{ vars.AZURE_CLIENT_ID }}
    tenant-id: ${{ vars.AZURE_TENANT_ID }}
    subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

Ingenstans förekommer `creds:`-parametern (legacy-läget med lagrad
client secret). Klient-, tenant- och subscription-ID lagras som GitHub
Actions Variables (publika), inte Secrets — de är offentliga
identifierare och ger ingen åtkomst utan matchande federerad credential
på UAMI:n.

### 2.4 Tenant-repots wrappers

Tenant-repots workflows är tunna wrappers som anropar engine-repots
reusable workflows pinnade till en specifik engine-tag (här `v1.1.3`).
De innehåller inga egna login-steg eller secrets-referenser — all
OIDC-autentisering ärvs från engine-repot.

```yaml
# .github/workflows/02-cd.yaml
jobs:
  plan_and_apply:
    uses: ExjobbOA/alz-mgmt-templates/.github/workflows/cd-template.yaml@v1.1.3
    permissions:
      id-token: write
      contents: read
```

```yaml
# .github/workflows/01-ci.yaml
jobs:
  validate_and_plan:
    uses: ExjobbOA/alz-mgmt-templates/.github/workflows/ci-template.yaml@v1.1.3
    permissions:
      id-token: write
      contents: read
      pull-requests: write
```

CI-wrappern har även `pull-requests: write` för att kunna kommentera
what-if-resultat på PR:er — inte autentiseringsrelaterat.

---

## Phase 3 — Frånvaro av lagrade credentials

### 3.1 Tenant-repots Variables och Secrets

Tenant-repot (`alz-mgmt`) har två GitHub environments som matchar
plattformens plan/apply-modell. Environment-variables är scope-bundna:
en workflow kan bara läsa variables för det environment den binder sig
till, vilket ger ett extra lager av access control utöver federated
credential-subject.

**Environment variables (`alz-mgmt-plan`):**

| Variable | Värde | UAMI |
|---|---|---|
| `AZURE_CLIENT_ID` | `7309b103-efd3-...` | plan-UAMI:n |
| `AZURE_SUBSCRIPTION_ID` | `6f051987-3995-...` | shared |
| `AZURE_TENANT_ID` | `3aadcd6c-3c4c-...` | shared |

**Environment variables (`alz-mgmt-apply`):**

| Variable | Värde | UAMI |
|---|---|---|
| `AZURE_CLIENT_ID` | `2f57546d-2384-...` | apply-UAMI:n |
| `AZURE_SUBSCRIPTION_ID` | `6f051987-3995-...` | shared |
| `AZURE_TENANT_ID` | `3aadcd6c-3c4c-...` | shared |

`AZURE_CLIENT_ID` skiljer sig mellan environments — det matchar split-
modellen från Phase 1.2 där plan- och apply-jobb autentiserar som olika
UAMIs med olika behörigheter. `AZURE_TENANT_ID` och
`AZURE_SUBSCRIPTION_ID` är gemensamma eftersom båda UAMIs lever i samma
tenant och identity-subscription.

**Secrets-fliken** är tom i båda environments. Inga repository-level
secrets är heller konfigurerade.

Att GUID-värdena kan visas öppet — inklusive i denna rapport — är en
direkt konsekvens av OIDC-modellen: klient-ID:t har ingen självständig
autentiseringsförmåga utan motsvarande federerad credential på UAMI:n
(verifierat i Phase 1).

Screenshot: `tests/screenshots/t2-secretsandvars.png`

### 3.2 Engine-repots Variables och Secrets

Engine-repot (`alz-mgmt-templates`) har inga environments, secrets
eller variables konfigurerade. All autentiseringskonfiguration är
isolerad till tenant-repot, vilket möjliggör att samma engine kan
delas mellan flera tenant-repos utan att deras credentials blandas.

## Phase 4 — Resultat

### 4.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| Federerade credentials med korrekt issuer, subject och audience finns på UAMIs | github-apply och github-plan med GitHub OIDC-issuer, environment-bundna subjects, audience `api://AzureADTokenExchange` | Phase 1.2 |
| Workflows har `id-token: write` permission | Verifierat i CI-template, CD-template (plan + apply), och tenant-wrappers | Phase 2 |
| `azure/login@v2` använder client-id/tenant-id-inputs (inte `creds:`) | Alla login-steg använder `vars.*`-inputs; `creds:` förekommer inte | Phase 2.3 |
| Inga Azure-credentials lagrade som GitHub Secrets | Secrets-fliken tom i båda environments; inga repository-level secrets | Phase 3.1 |
| Engine-repot har ingen autentiseringskonfiguration | Inga environments, secrets eller variables i engine-repot | Phase 3.2 |

### 4.2 Observationer

Plattformen implementerar K9 starkare än vad litteraturen formulerar.
Kumara et al. (2021) och Guerriero et al. (2019) beskriver principen som
att hemligheter ska *isoleras från kod och injiceras parametriskt vid
exekvering*. OIDC-modellen tar detta ett steg längre: det finns inga
hemligheter att isolera överhuvudtaget. Autentisering bygger på
matchning av kortlivade tokens mot federerade credentials, inte på att
lagra och skydda lösenord.

Split-modellen mellan plan- och apply-UAMIs (Phase 1.1) implementerar
även en form av minsta-privilegium som är ortogonal mot K9 men
relaterad: en kompromettering av PR-flödet (vilket triggar plan-jobbet)
ger inte skrivåtkomst mot Azure, eftersom plan-UAMI:n saknar sådana
roller. Detta är en arkitektonisk konsekvens av environment-bundna
federated credentials.

Att autentiseringskonfigurationen är isolerad till tenant-repot
(Phase 3.2) möjliggör samtidigt att engine-repot kan delas mellan
flera tenant-repos utan att deras credentials blandas — en designprincip
som direkt stödjer den MSP-anpassning som plattformen är byggd för.

### 4.3 Verdict

- [x] K9 Passed
- [ ] K9 Partially passed
- [ ] K9 Not passed

**En-meningskommentar:** Plattformens autentiseringsmodell eliminerar
behovet av lagrade credentials genom OIDC-federation mellan GitHub
Actions och Microsoft Entra ID — verifierat genom existerande federerade
credentials på UAMIs, korrekt workflow-konfiguration utan `creds:`-
parametrar, och frånvaro av Azure-relaterade GitHub Secrets i båda repos.

---

## Evidens-artefakter

1. PowerShell-output av `Get-AzUserAssignedIdentity` (Phase 1.1)
2. PowerShell-output av `Get-AzFederatedIdentityCredential` för båda UAMIs (Phase 1.2)
3. Workflow-snippets från `ci-template.yaml`, `cd-template.yaml`, tenant-wrappers (Phase 2)
4. `tests/screenshots/t2-secretsandvars.png` — tenant-repots Variables/Secrets-vy (Phase 3.1)
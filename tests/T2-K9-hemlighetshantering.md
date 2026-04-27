# T2 — Hemlighetshantering

**Test ID:** T2
**Criterion:** K9 Hemlighetshantering
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Tenant:** N/A (statiskt repo-test)

---

## Syfte

Visa att plattformen inte exponerar hemligheter i koden, att autentisering mellan
GitHub Actions och Azure sker via OIDC istället för lagrade lösenord, och att känsliga
parametrar i Bicep är markerade med `@secure()`.

K9 mäts genom statisk analys av repos. Inga deployment krävs.

---

## Context

Plattformen använder OIDC (OpenID Connect) federated credentials för
GitHub-Actions-till-Azure-autentisering. Inga client secrets eller service
principal-lösenord lagras i workflow-filerna eller GitHub-secrets — bara en kortlivad
token utbyts vid runtime baserat på workflow-context.

För statisk analys används gitleaks, ett community-validerat verktyg som scannar git-
historik och arbetskopia efter mönster som matchar API-keys, lösenord och tokens.

---

## Phase 0 — Pre-flight

### 0.1 Verktyg

- gitleaks (https://github.com/gitleaks/gitleaks) installerat lokalt eller via Docker
- PowerShell `Select-String` för manuell grep

### 0.2 Repos som scannas

1. `alz-mgmt-templates` (engine-repot)
2. `alz-mgmt` (Oskar-test-tenanten)

---

## Phase 1 — Gitleaks-scan

### 1.1 Engine-repo

```powershell
cd C:\Users\granl\repos\alz-mgmt-templates
gitleaks detect --source . --verbose --report-path tests/evidence/gitleaks-engine.json
```

**Resultat:** _antal fynd_

### 1.2 Tenant-repo

```powershell
cd C:\Users\granl\repos\alz-mgmt
gitleaks detect --source . --verbose --report-path tests/evidence/gitleaks-tenant.json
```

**Resultat:** _antal fynd_

### 1.3 Klassificering av eventuella fynd

| Fynd | Fil | Typ | Bedömning |
|---|---|---|---|
| _ | _ | _ | False positive / Real leak |

False positives är vanliga: GUIDs som matchar generic secret-pattern, Azure subscription
IDs (offentliga identifierare, inte secrets), OIDC-related URLs.

---

## Phase 2 — Workflow-secrets-grep

### 2.1 Sök efter secrets-användning

```powershell
# Engine-repo
cd C:\Users\granl\repos\alz-mgmt-templates
Get-ChildItem .github/workflows -Recurse -Filter "*.yaml" |
  Select-String -Pattern "secrets\." |
  Select-Object Path, LineNumber, Line

# Tenant-repo
cd C:\Users\granl\repos\alz-mgmt
Get-ChildItem .github/workflows -Recurse -Filter "*.yaml" |
  Select-String -Pattern "secrets\." |
  Select-Object Path, LineNumber, Line
```

### 2.2 Klassificera varje secret-referens

| Fil | Variabel | Typ |
|---|---|---|
| _ | _ | _ |

Förväntat: alla `secrets.*`-referenser är antingen `GITHUB_TOKEN` (GitHub-injicerad
automatiskt vid workflow-start) eller bör konverteras till `vars.*` om de är offentliga
identifierare. Riktiga lösenord ska inte förekomma.

### 2.3 Verifiera OIDC-konfiguration

I GitHub repo settings → Secrets and variables → Actions:
- Variables (offentliga): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID*`
- Secrets: tomt eller endast `GITHUB_TOKEN`-relaterat

Screenshot av Variables/Secrets-sidan tas som evidens.

---

## Phase 3 — @secure()-dekoratör i Bicep

### 3.1 Räkna parametrar med @secure()

```powershell
cd C:\Users\granl\repos\alz-mgmt-templates
Get-ChildItem -Recurse -Filter "*.bicep" |
  Select-String -Pattern "@secure\(\)" |
  Select-Object Path, LineNumber, Line
```

### 3.2 Sök efter parametrar som borde ha @secure()

```powershell
Get-ChildItem -Recurse -Filter "*.bicep" |
  Select-String -Pattern "param\s+\w*[Pp]assword|param\s+\w*[Kk]ey|param\s+\w*[Ss]ecret|param\s+\w*[Tt]oken" |
  Select-Object Path, LineNumber, Line
```

| Fil | Parameter | Har @secure()? |
|---|---|---|
| _ | _ | Ja/Nej |

---

## Phase 4 — Resultat

### 4.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| Gitleaks: 0 verkliga fynd över alla repos | _ | gitleaks-rapporter |
| Workflows refererar bara GITHUB_TOKEN i secrets | _ | grep-output |
| Alla känsliga Bicep-parametrar har @secure() | _ | grep-output |
| OIDC används för Azure-autentisering | _ | GitHub repo settings |

### 4.2 Observationer

[Fyll i efter körning]

### 4.3 Verdict

- [ ] K9 Passed
- [ ] K9 Partially passed
- [ ] K9 Not passed

**En-meningskommentar:** _paste efter körning_

---

## Evidens-artefakter

1. `tests/evidence/gitleaks-engine.json`
2. `tests/evidence/gitleaks-tenant.json`
3. Screenshot av GitHub repo Secrets/Variables-sida
4. PowerShell-output av `secrets.`-grep
5. PowerShell-output av `@secure()`-grep

---

## Appendix — Installation av gitleaks

```powershell
# Via Docker (rekommenderat — ingen lokal installation)
docker run --rm -v ${PWD}:/path zricethezav/gitleaks:latest detect --source /path

# Eller via release-binär
# https://github.com/gitleaks/gitleaks/releases
```

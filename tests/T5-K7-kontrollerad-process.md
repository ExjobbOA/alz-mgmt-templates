# T5 — Kontrollerad process

**Test ID:** T5
**Criterion:** K7 Kontrollerad process
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Syfte

Visa att plattformen blockerar bypass-försök som skulle kringgå den deklarativa kedjan.
Tre oberoende vägar runt processen testas:

1. **Portal-edit** av en plattform-hanterad resurs
2. **Direkt push** till main utan PR
3. **Workflow-trigger från obehörig identitet** (t.ex. en fork)

K7 mäts genom screenshots av blockeringsmeddelanden från Azure och GitHub.

---

## Context

Plattformens säkerhetsmodell bygger på tre lager:

- **Azure Policy** + deployment stacks med `denyDelete`/`denySettings` blockerar
  manuella ändringar i portalen av plattformshanterade resurser
- **GitHub branch protection** på main blockerar direkta pushes och kräver PR med
  godkännande
- **GitHub OIDC federation** med subject-claim-bindning blockerar workflow-körningar
  från obehöriga repos eller branches

Alla tre testas separat med diskreta försök.

---

## Phase 0 — Pre-flight

### 0.1 Verifiera att skydden är aktiva

Innan testet, dokumentera att skydden är konfigurerade:

**Branch protection:**
- GitHub repo settings → Branches → main → Require pull request before merging: aktiv
- Require status checks to pass: aktiv

**Deployment stack denySettings:**

```powershell
Get-AzManagementGroupDeploymentStack -ManagementGroupId "alz" -Name "alz-governance-platform" |
  Select-Object -ExpandProperty DenySettings
```

**OIDC federated credentials:**
- Azure Portal → Microsoft Entra → App registration → Federated credentials
- Subject claim ska binda till specifika repo:n och branches

---

## Phase 1 — Bypass-försök 1: Portal-edit

### 1.1 Välj en plattform-hanterad resurs

Välj en policy assignment som tydligt är hanterad av en deployment stack, t.ex.
`Deploy-MCSB2-Monitoring` på alz-MG.

### 1.2 Försök redigera i portalen

1. Azure Portal → Management Groups → alz → Policy → Assignments
2. Klicka på `Deploy-MCSB2-Monitoring`
3. Försök ändra parameter eller scope
4. Försök Delete

### 1.3 Förväntat resultat

Azure ska blockera ändringen med felmeddelande som refererar till deployment stack
denySettings.

**Screenshot:** `t5-1-portal-edit-blocked.png`

---

## Phase 2 — Bypass-försök 2: Direkt push till main

### 2.1 Försök pusha utan PR

```powershell
cd C:\Users\granl\repos\alz-mgmt
git switch main
git pull
echo "# bypass test" >> README.md
git add README.md
git commit -m "bypass test: direct push to main"
git push origin main
```

### 2.2 Förväntat resultat

Git ska rejecta pushen med felmeddelande från GitHub branch protection.

**Screenshot:** `t5-2-push-rejected.png` (terminal med error output)

### 2.3 Cleanup

```powershell
git reset --hard HEAD~1
```

---

## Phase 3 — Bypass-försök 3: OIDC från obehörig källa

### 3.1 Förbered försök

Skapa en fork av tenant-repot under en annan GitHub-användare eller en separat branch
som inte är subject-claim-tillåten i OIDC-konfiguratione. Försök trigga workflowen
därifrån.

Alternativ: ändra workflow-filen lokalt så att den försöker köra OIDC-login med en
annan identitet eller mot en annan subscription.

### 3.2 Försök trigga workflow

Pusha till fork:en eller obehörig branch, observera workflow-resultatet i GitHub
Actions.

### 3.3 Förväntat resultat

Azure-login-steget ska faila med ett OIDC-rejection-meddelande som indikerar att
subject-claim inte matchar federated credential.

**Screenshot:** `t5-3-oidc-rejected.png`

### 3.4 Cleanup

Ta bort fork:en eller branchen efter dokumentation.

---

## Phase 4 — Resultat

### 4.1 Förväntat vs observerat

| Bypass-försök | Förväntat | Observerat | Källa |
|---|---|---|---|
| Portal-edit av managed resource | Blockerad av denySettings | _ | Phase 1-screenshot |
| Direkt push till main | Rejected av branch protection | _ | Phase 2-screenshot |
| OIDC från obehörig källa | Rejected av subject-claim | _ | Phase 3-screenshot |

### 4.2 Observationer

[Fyll i efter körning. Vad var oväntat, hur tydligt var felmeddelandet, etc.]

### 4.3 Verdict

- [ ] K7 Passed (alla tre blockerade)
- [ ] K7 Partially passed (2 av 3)
- [ ] K7 Not passed (1 eller 0 av 3)

**En-meningskommentar:** _paste efter körning_

---

## Evidens-artefakter

1. `t5-1-portal-edit-blocked.png` — Azure portal blockering av manuell edit
2. `t5-2-push-rejected.png` — GitHub rejection av direct push
3. `t5-3-oidc-rejected.png` — Azure OIDC-rejection av obehörig identitet
4. Konfigurationsbevis från Phase 0 (branch protection, denySettings, federated
   credentials)

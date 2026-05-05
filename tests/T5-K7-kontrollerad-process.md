# T5 — Kontrollerad process

**Test ID:** T5
**Criterion:** K7 Kontrollerad process
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Syfte

Visa att alla ändringar mot plattformen passerar den deklarativa kedjan
PR → CI → review → merge → CD. Ingen ändring kan nå Azure utanför kedjan.

K7 mäts genom ett aktivt test (direkt push till main) plus konfigurationsbevis
för de två andra kontrollpunkterna i kedjan.

---

## Context

Plattformens "kontrollerade process" består av tre kontrollpunkter:

1. **GitHub branch protection** på `main` — kräver PR med godkännande, blockerar
   direkta pushes
2. **CD-trigger** — `cd.yaml` har endast `workflow_dispatch`, ingen
   `push:`-trigger. CD körs aldrig automatiskt på en commit
3. **OIDC federated credentials** — Azure-login i CD är bunden till specifika
   subject claims (repo + branch/environment). Workflow-körningar från obehöriga
   källor får inget Azure-token

Phase 1 testar (1) aktivt. Phase 2 dokumenterar (2) och (3) som konfiguration —
de är statiska egenskaper av setup, inte runtime-beteenden som behöver
provoceras fram för 15hp-omfattning.

**Notering om portal-edits:** Plattformen kör `denySettingsMode: "None"` på alla
deployment stacks. Manuella portal-edits är därför inte blockerade i Azure utan
**detekteras och reverteras** av reconciliation på nästa CD-körning. Det
beteendet hör till K8 (rollback) / K11 (state-konvergens), inte K7.

---

## Phase 0 — Pre-flight

### 0.1 Baseline

- Engine-tag: _paste senaste tag_
- 11/11 stackar succeeded
- Inga öppna PRs
- Branch `main` är upp-to-date lokalt

---

## Phase 1 — Aktivt test: Direkt push till main

### 1.1 Försök pusha utan PR

```powershell
cd C:\Users\granl\repos\alz-mgmt
git switch main
git pull
"# bypass test" | Out-File -Append README.md
git add README.md
git commit -m "bypass test: direct push to main"
git push origin main
```

### 1.2 Förväntat resultat

`git push` rejectas av GitHub med felmeddelande från branch protection.
Tenant-repots `main` förblir oförändrad.

**Screenshot:** `t5-1-push-rejected.png` (terminal med GitHub:s rejection-output)

### 1.3 Cleanup

```powershell
git reset --hard HEAD~1
```

Verifiera att den lokala commiten är borta:

```powershell
git log --oneline -3
```

---

## Phase 2 — Konfigurationsbevis

### 2.1 Branch protection på main

GitHub repo settings → Branches → branch protection rule för `main`.

Relevanta regler som ska vara aktiva:
- Require a pull request before merging
- Require status checks to pass before merging (CI)

**Screenshot:** `t5-2-branch-protection.png`

### 2.2 OIDC federated credentials

Azure Portal → RG för plan och apply, vi kollar apply identiteten:
Federated credentials.

Verifiera att subject claim binder federated credential till specifik repo
och branch/environment, t.ex.:

```
repo:ExjobbOA/alz-mgmt-oskar:ref:refs/heads/main
repo:ExjobbOA/alz-mgmt-oskar:environment:alz-mgmt-plan
```

En workflow-körning från en fork eller obehörig branch kommer inte matcha
någon av dessa subject claims och får därmed inget Azure-token.

**Screenshot:** `t5-3-oidc-subject-claim.png`

### 2.3 CD-trigger är manuell

Verifiera i `alz-mgmt-oskar/.github/workflows/cd.yaml` att CD endast triggas
av `workflow_dispatch` — inget `push:` på main, ingen automatisk trigger:

```yaml
on:
  workflow_dispatch:
    inputs:
      ...
```

Det innebär att även om en commit hade nått main (vilket Phase 1 visar att
den inte kan), så skulle CD inte köra automatiskt utan kräver explicit trigger
av en operatör.

**Källa:** `cd.yaml` rad 3–4 (refereras i rapporten, ingen separat screenshot
behövs).

---

## Phase 3 — Resultat

### 3.1 Förväntat vs observerat

| Kontrollpunkt | Förväntat | Observerat | Källa |
|---|---|---|---|
| Direkt push till main | Rejected av branch protection | Rejected av branch protection | Phase 1 |
| PR krävs för merge | Branch protection rule aktiv | Ja | Phase 2.1 |
| OIDC bunden till repo/branch | Federated credential subject claim konfigurerad | Ja, bunden till environment | Phase 2.2 |
| CD körs ej automatiskt | Endast `workflow_dispatch` i `cd.yaml` | Ja cd körs bara på workflow dispatch, alternativet är att den körs automatiskt vid PR fast efter godkännande/review av när whatif har körts| Phase 2.3 |

### 3.2 Observationer

[Fyll i efter körning. Vad var oväntat, hur tydligt var rejection-meddelandet, etc.]
Ingenting oväntat

### 3.3 Verdict

- [x ] K7 Passed (alla fyra kontrollpunkter verifierade)
- [ ] K7 Partially passed
- [ ] K7 Not passed

**En-meningskommentar:** Inget kontroversiellt 

---

## Evidens-artefakter

1. `t5-1-push-rejected.png` — terminal med GitHub:s rejection av direct push
2. `t5-2-branch-protection.png` — GitHub branch protection rule på main
3. `t5-3-oidc-subject-claim.png` — Entra federated credential med subject claim
4. Referens till `cd.yaml` rad 3–4 (manuell trigger)
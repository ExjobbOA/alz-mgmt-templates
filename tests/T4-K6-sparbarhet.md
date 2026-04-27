# T4 — Spårbarhet

**Test ID:** T4
**Criterion:** K6 Spårbarhet
**Executed by:** Oskar
**Start date:** _YYYY-MM-DD_
**End date:** _YYYY-MM-DD_
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Syfte

Visa att en ändring kan spåras från PR till slutlig Azure-resurs i båda riktningarna:

- **Framåt:** PR → merge commit → workflow run → deployment → resource i Azure
- **Bakåt:** Azure-resurs → deployment history → workflow run → commit → PR

K6 mäts genom screenshots från GitHub UI och Azure Portal. Det är ett UI-baserat test
utan automatisering eftersom värdet ligger i att en operatör visuellt kan följa kedjan.

---

## Context

Spårbarhet är en operativ egenskap. När något i Azure ser oväntat ut ska en operatör
kunna identifiera vilken kod som producerade resursen, vilken commit som introducerade
ändringen, och vilken person som skrev koden. Omvänt ska en kodändring kunna följas
till sin produktionseffekt.

GitHub Actions och Azure Resource Manager exponerar båda dessa kedjor via sina
respektive UI:n. Ingen extern verktyg behövs.

---

## Phase 0 — Pre-flight

### 0.1 Baseline

- En lyckad CD-körning bör ha skett nyligen, helst med en specifik identifierbar
  ändring (T10:s lib-bump fungerar utmärkt som källmaterial)
- Engine-tag: _paste senaste tag_

---

## Phase 1 — Framåtspårning

### 1.1 Välj startpunkt

Välj en specifik PR från senaste arbete. Förslag: T10:s tenant-PR
(https://github.com/ExjobbOA/alz-mgmt-oskar/pull/93).

### 1.2 Steg-för-steg-screenshots

Ta en screenshot vid varje länk i kedjan:

1. **PR i GitHub** — visar PR-nummer, beskrivning, mergad-status
2. **Merge-commit i main** — visar SHA, författare, datum, meddelande
3. **Workflow run-vy** — kopplar commit-SHA till specifik workflow-körning
4. **Deployment-jobb-detalj** — visar vilken deployment stack som uppdaterades
5. **Azure Portal: deployment stack-vyn** — visar att stacken uppdaterades med specifik
   correlation ID
6. **Azure Portal: en specifik resurs** — t.ex. en av de policy definitions som
   skapades, med "deployments"-flik som länkar tillbaka till deployment

| Steg | Filnamn för screenshot |
|---|---|
| PR i GitHub | `t4-fwd-1-pr.png` |
| Merge-commit | `t4-fwd-2-commit.png` |
| Workflow run | `t4-fwd-3-workflow.png` |
| Deployment-jobb | `t4-fwd-4-job.png` |
| Stack i portalen | `t4-fwd-5-stack.png` |
| Specifik resurs | `t4-fwd-6-resource.png` |

---

## Phase 2 — Bakåtspårning

### 2.1 Välj slutpunkt

Välj en specifik resurs i Azure som producerats av plattformen. Förslag: en av de nya
policy definitions från 2026.04.0, t.ex. `Audit-AKS-kubenet`.

### 2.2 Steg-för-steg-screenshots

Följ kedjan baklänges:

1. **Azure Portal: resurs-detaljvy** — visar policy definition med metadata
2. **Deployment history på resursen eller dess parent-MG** — visar vilken deployment
   som senast modifierade resursen
3. **Deployment-detaljvy** — visar correlation ID, deployment-namn (innehåller
   stack-namn och timestamp)
4. **GitHub Actions: workflow run** — sökning på samma timestamp eller correlation ID
5. **Workflow run-vy: commit-länk** — leder till specifik commit
6. **Commit-detaljvy: PR-länk** — leder till PR där ändringen introducerades

| Steg | Filnamn för screenshot |
|---|---|
| Resurs-detaljvy | `t4-bwd-1-resource.png` |
| Deployment history | `t4-bwd-2-history.png` |
| Deployment-detaljvy | `t4-bwd-3-deployment.png` |
| Workflow run i GitHub | `t4-bwd-4-workflow.png` |
| Commit-detaljvy | `t4-bwd-5-commit.png` |
| PR | `t4-bwd-6-pr.png` |

---

## Phase 3 — Resultat

### 3.1 Förväntat vs observerat

| Förväntat | Observerat | Källa |
|---|---|---|
| Framåtspårning fullständig (PR → resurs) | _ | Phase 1-screenshots |
| Bakåtspårning fullständig (resurs → PR) | _ | Phase 2-screenshots |
| Inga brutna länkar i kedjan | _ | Genomgång av screenshots |

### 3.2 Observationer

[Fyll i efter körning. Eventuella länkar som krävde extra klick eller var otydliga.]

### 3.3 Verdict

- [ ] K6 Passed
- [ ] K6 Partially passed
- [ ] K6 Not passed

**En-meningskommentar:** _paste efter körning_

---

## Evidens-artefakter

1. Sex screenshots för framåtspårning (`t4-fwd-1` till `t4-fwd-6`)
2. Sex screenshots för bakåtspårning (`t4-bwd-1` till `t4-bwd-6`)
3. Eventuella anteckningar om friktion i kedjan

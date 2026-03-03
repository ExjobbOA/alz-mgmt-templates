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
| Utfall | |
| Kommentar | |

### CD-körning #1

| Fält | Värde |
|------|-------|
| Starttid | |
| Sluttid | |
| Actions run URL | |
| Slutstatus | |
| Antal retries | |
| Kommentar | |

---

## Del 2 — Idempotent omdriftsättning Oskar (K1 #2)

### CD-körning #2 (inga ändringar)

| Fält | Värde |
|------|-------|
| Starttid | |
| Sluttid | |
| Actions run URL | |
| Slutstatus | |
| What-if: inga ändringar bekräftade | |
| Kommentar | |

---

## Del 3 — Kontrollerad förändring + rollback (K2 + K3 + K4)

### Del 3a — Applicera förändring (SECURITY_CONTACT_EMAIL)

| Fält | Värde |
|------|-------|
| Commit SHA | |
| PR-länk | |
| Actions run URL | |
| Slutstatus | |
| Verifierad i Azure | |
| Kommentar | |

### Del 3b — Rollback

| Fält | Värde |
|------|-------|
| Revert commit SHA | |
| PR-länk | |
| Actions run URL | |
| Slutstatus | |
| Miljö återställd | |
| Kommentar | |

### Spårbarhet (K2)

```
commit (change) → PR → Actions run → förändring i Azure
      ↓
commit (revert) → PR → Actions run → återställt tillstånd
```

| Länk | Värde |
|------|-------|
| Change commit | |
| Change PR | |
| Change Actions run | |
| Revert commit | |
| Revert PR | |
| Revert Actions run | |

---

## Del 4 — Cold start Alen (K6 #2 + K1 #3)

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

### CD-körning #3

| Fält | Värde |
|------|-------|
| Starttid | |
| Sluttid | |
| Actions run URL | |
| Slutstatus | |
| Hierarki identisk med Oskars | |
| Kommentar | |

---

## Sammanfattning

| Kriterium | Körning | Datum | Utfall | Artefakt |
|-----------|---------|-------|--------|----------|
| K1 | #1 Cold start Oskar | 2026-03-03 | | |
| K1 | #2 Idempotent Oskar | 2026-03-03 | | |
| K1 | #3 Cold start Alen | 2026-03-03 | | |
| K2 | Förändring (email) | 2026-03-03 | | |
| K2 | Rollback | 2026-03-03 | | |
| K3 | Förändring via PR | 2026-03-03 | | |
| K3 | Rollback via PR | 2026-03-03 | | |
| K4 | Rollback-deploy | 2026-03-03 | | |
| K6 | Cold start Oskar | 2026-03-03 | | |
| K6 | Cold start Alen | 2026-03-03 | | |

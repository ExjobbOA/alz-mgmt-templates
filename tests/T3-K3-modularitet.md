# T3 — Modularitet

**Test ID:** T3
**Criterion:** K3 Modularitet och separation
**Executed by:** Oskar
**Start date:** 2026-04-27
**End date:** _YYYY-MM-DD_
**Tenant:** Oskar test tenant (`3aadcd6c-3c4c-49bc-a9d5-57b7fbf31db7`)

---

## Syfte

Verifiera att tenant-repot per design inte innehåller Bicep-logik — endast
`*.bicepparam`-filer som via `using`-statements pekar på engine-repots
templates. Konsekvensen är att engine-uppdateringar propagerar till tenanten
utan att tenant-koden behöver ändras.

---

## Phase 1 — Inventarera tenant-repots Bicep-filer

```powershell
cd C:\Users\granl\repos\alz-mgmt
Get-ChildItem -Recurse -Include "*.bicep","*.bicepparam" |
  Group-Object Extension |
  Select-Object Name, Count
```

Förväntat:

| Filtyp | Antal |
|---|---|
| `.bicep` | 19 |
| `.bicepparam` | 0 |

Resultat: 
PS C:\Users\granl\repos\alz-mgmt> Get-ChildItem -Recurse -Include "*.bicep","*.bicepparam" |
>>   Group-Object Extension |
>>   Select-Object Name, Count
Name        Count
----        -----
.bicepparam    19
---

## Phase 2 — Resultat

### Verdict

- [ x] K3 Passed (0 `.bicep`-filer i tenant-repot)
- [ ] K3 Not passed (≥1 `.bicep`-fil utan legitim motivering)

**En-meningskommentar:** _
En-meningskommentar: Tenant-repot innehåller 19 .bicepparam-filer och noll .bicep-filer, vilket bekräftar att Bicep-logik per konstruktion bor i engine-repot och att engine-uppdateringar propagerar utan tenant-kodändringar.
---

## Evidens

1. `Get-ChildItem`-output som listar filtypsfördelningen
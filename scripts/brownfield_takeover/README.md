# scripts/brownfield-takeover/

Verktyg för att ta över en befintlig, portaldriftsatt Azure Landing Zone så att
engine kan hantera den framöver. Använder [Azure Governance Visualizer][azgovviz]
(AzGovViz) som upptäcktslager och genererar Bicep-fragment för
tenant-konfigurationsrepot.

| Script | Syfte |
|--------|-------|
| [Build-OverrideFragments.ps1](#build-overridefragmentsps1) | Extrahera policytilldelningarnas parametervärden från AzGovViz JSON-output; generera ett `parPolicyAssignmentParameterOverrides`-fragment per MG-scope |

[azgovviz]: https://github.com/Azure/Azure-Governance-Visualizer

---

## När det här används

Målet är en ALZ-tenant som driftsattes via Azure-portalen ("Deploy a landing
zone"-upplevelsen) och sedan dess legat utan IaC-hantering. Syftet är att peka
engine mot den befintliga management group-hierarkin, låta deployment stacks ta
över ägarskapet av ALZ-biblioteksobjekten och bevara tenantens specifika
parametervärden (LAW-resurs-ID, säkerhetskontaktens e-post, location,
DCR/UAMI-IDs osv.) i det nya tenant-konfigurationsrepot.

Skrivskyddat. Ingenting i den här mappen skriver till Azure eller till något repo.

> **Varför strategin är säker:** deployment stacks med `deleteResources` hanterar
> bara det som är deklarerat i stacken. Anpassade policyer, rolldefinitioner och
> resurser utanför stackens hanterade set lämnas orörda. Definitioner med samma
> namn som ett ALZ-biblioteksobjekt skrivs över vid första deployen — vilket är
> det avsedda beteendet för takeover.

---

## Setup

### Förväntad mapplayout

Instruktionerna nedan utgår från denna on-disk-layout:

```
<workspace>/
├── alz-mgmt-templates/               (detta repo — engine)
├── alz-mgmt-<tenant>/                (tenantens konfigurationsrepo)
└── Azure-Governance-Visualizer/      (klonas separat — se nedan)
```

AzGovViz ligger utanför båda repona. Klona det **inte** inuti
`alz-mgmt-templates/` — det är ett separat underhållet upstream-verktyg med sin
egen livscykel och ska hämtas oberoende.

### Klona AzGovViz

```powershell
cd <workspace>
git clone https://github.com/Azure/Azure-Governance-Visualizer.git
```

Pinna en specifik commit om reproducerbarhet spelar roll för ett visst
kunduppdrag.

### Verktygskrav

```powershell
# Runtime
winget install Microsoft.PowerShell   # PS 7+

# Az-moduler — AzGovViz eget prerequisites-script installerar det som behövs
cd <workspace>/Azure-Governance-Visualizer
./pwsh/prerequisites.ps1
```

### Autentisering

```powershell
Connect-AzAccount -Tenant <target-tenant-guid>
Set-AzContext -Subscription <any-subscription-in-tenant>
```

Identiteten behöver **Reader på tenantens rot-management group** — tillräckligt
för att AzGovViz ska kunna gå igenom hela hierarkin och räkna upp
governance-objekten.

---

## Arbetsflöde

Tre steg: upptäck, syntetisera, committa.

### 1. Kör AzGovViz mot måltenanten

Från `Azure-Governance-Visualizer/`:

```powershell
./pwsh/AzGovVizParallel.ps1 `
    -ManagementGroupId '<intermediate-root-mg-id>' `
    -OutputPath ../alz-mgmt-templates/scripts/brownfield-takeover/azgovviz-output `
    -NoMDfCSecureScore `
    -NoPolicyComplianceStates `
    -NoResourceDiagnosticsPolicyLifecycle `
    -NoPIMEligibility `
    -NoResources `
    -NoCsvExport
```

`-No*`-flaggorna stänger av allt som inte behövs för fragment-syntesen.
`-NoResources` är den stora tidsvinsten — hoppar över per-resurs-skanningen som
dominerar AzGovViz-körningen på tenants med riktiga workloads.

`-ManagementGroupId` är den **intermediära** roten — det som portalen driftsatte
som ALZ-rot. Standardportalen producerar `alz`, men verifiera mot MG-hierarkin
innan körning.

Output hamnar i `scripts/brownfield-takeover/azgovviz-output/JSON_<mgId>_<yyyyMMdd_HHmmss>/`.

### 2. Syntetisera fragment

```powershell
cd <workspace>/alz-mgmt-templates

# Hämta senaste AzGovViz-output-mappen
$jsonRoot = Get-ChildItem ./scripts/brownfield-takeover/azgovviz-output -Directory -Filter 'JSON_*' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

./scripts/brownfield-takeover/Build-OverrideFragments.ps1 `
    -AzGovVizJsonPath  $jsonRoot.FullName `
    -OutputDirectory   ./scripts/brownfield-takeover/takeover-fragments `
    -AlzLibraryPath    ./templates/core/governance/lib/alz
```

### 3. Granska och committa till tenant-konfigurationsrepot

Genererade filer hamnar i `takeover-fragments/`:

| Fil | Innehåll |
|-----|----------|
| `override-<mgId>.bicepparam` | Komplett `param parPolicyAssignmentParameterOverrides = {...}`-block med literala värden från brownfield-tenanten |
| `custom-assignments.txt` | Tilldelningar vid MG-scopes som **inte** finns i ALZ-biblioteket — granska per rad |

För varje `override-<mgId>.bicepparam`, öppna motsvarande `.bicepparam` i
tenant-konfigurationsrepot och ersätt det befintliga
`parPolicyAssignmentParameterOverrides`-blocket:

| Genererad fil | Mål i `alz-mgmt-<tenant>/` |
|---------------|----------------------------|
| `override-<intRootMgId>.bicepparam` | `config/core/governance/mgmt-groups/int-root.bicepparam` |
| `override-platform.bicepparam` | `config/core/governance/mgmt-groups/platform/main.bicepparam` |
| `override-connectivity.bicepparam` | `config/core/governance/mgmt-groups/platform/platform-connectivity/main.bicepparam` |
| `override-identity.bicepparam` | `config/core/governance/mgmt-groups/platform/platform-identity/main.bicepparam` |
| `override-management.bicepparam` | `config/core/governance/mgmt-groups/platform/platform-management/main.bicepparam` |
| `override-landingzones.bicepparam` | `config/core/governance/mgmt-groups/landingzones/main.bicepparam` |
| `override-corp.bicepparam` | `config/core/governance/mgmt-groups/landingzones/landingzones-corp/main.bicepparam` |
| `override-online.bicepparam` | `config/core/governance/mgmt-groups/landingzones/landingzones-online/main.bicepparam` |
| `override-sandbox.bicepparam` | `config/core/governance/mgmt-groups/sandbox/main.bicepparam` |

Bara filer för scopes som faktiskt hade ALZ-biblioteksmatchande tilldelningar
genereras.

Innan commit, gå igenom varje fragment och avgör per värde:

- **Matchar engine-konventionen** (LAW-sökväg som `lawResourceId` skulle
  konstruera från `platform.json`, location som matchar `LOCATION_PRIMARY`,
  e-post som matchar `SECURITY_CONTACT_EMAIL`) → ersätt det literala värdet med
  variabelreferensen (`lawResourceId`, `location`, `securityEmail`) så att
  overriden överlever framtida `platform.json`-ändringar.
- **Matchar inte** (fel RG-namn, fel LAW-namn, annan region) → behåll det
  literala värdet. Bestäm separat om resursen ska migreras till
  ALZ-konventionsnamn under eller efter takeover.

`custom-assignments.txt` listar tilldelningar utanför ALZ-biblioteket. Per rad,
bestäm: migrera in i tenant-repots `customerPolicyAssignments`-array, eller
lämna orörd. Deployment stacks hanterar bara det som är deklarerat i stacken, så
icke-migrerade anpassade tilldelningar överlever takeover orörda.

---

## Build-OverrideFragments.ps1

### Parametrar

| Parameter | Obligatorisk | Beskrivning |
|-----------|--------------|-------------|
| `-AzGovVizJsonPath` | **Ja** | Sökväg till `JSON_<root>_<timestamp>/`-mappen producerad av `AzGovVizParallel.ps1` |
| `-OutputDirectory` | **Ja** | Där fragment-filerna skrivs; skapas om den saknas |
| `-AlzLibraryPath` | Nej | Sökväg till `*.alz_policy_assignment.json`-filerna. När den anges genereras bara ALZ-biblioteksmatchande tilldelningsnamn till fragment; allt annat hamnar i `custom-assignments.txt`. **Starkt rekommenderad** — utan den läcker anpassade tenantspecifika tilldelningar in i fragment-outputen. |

### Driftsanteckningar

- **Idempotent.** Varje körning skriver över output-mappen. Säkert att köra om.
- **Skrivskyddat mot Azure.** Inga API-anrop — all data kommer från AzGovViz
  JSON-output. Generera om fragment från en befintlig AzGovViz-dump utan att
  autentisera om.
- **Bevarande av literala värden.** Parametervärden genereras exakt som de
  ser ut i brownfield-tenanten. Ingen inferens, ingen substitution.
  Parameterisering är operatörens beslut under granskning.
- **Tomma parametrar hoppas över.** Tilldelningar där `properties.parameters` är
  tom exkluderas från fragmentet — engine-policydefinitionernas defaultvärden
  gäller och ingen override behövs.

---

## Inte i scope för det här verktyget

| Fråga | Var det hanteras |
|-------|------------------|
| `platform.json`-skalärer (sub-ID:n, MG-namnoverrides, location, säkerhets-e-post) | Fyll i för hand från AzGovViz hierarki-HTML, eller fråga ARM direkt |
| Infrastruktur-resurs-ID:n (hub-VNet, Firewall, DNS-zoner) | Engine konstruerar dem från `platform.json`-skalärer i `.bicepparam`-filer; redigera de filerna direkt om kundens resurser inte följer ALZ-namnkonventionen |
| Namnkollisioner för policydefinitioner | Flaggas inte — engine skriver över biblioteksnamngivna anpassade definitioner vid första deployen, vilket är rätt beteende för takeover |
| Rolltilldelningar, blueprints, resurslås | Engine driftsätter sina egna; befintliga utanför stackens hanterade set lämnas orörda |

Se `../README.md` för den fullständiga examensarbets-kontexten om varför
in-place-takeover-strategin kollapsar större delen av den traditionella
brownfield-auditerings-ytan.

---

## `.gitignore`

Båda output-mapparna innehåller tenantspecifik data (subscription-ID:n,
LAW-resurs-ID:n, säkerhetskontakt-e-postadresser) som **aldrig** får committas
till engine-repot. Den hör bara hemma i tenant-konfigurationsrepot, efter
operatörens granskning.

Lägg till i rot-`.gitignore`:

```
scripts/brownfield-takeover/azgovviz-output/
scripts/brownfield-takeover/takeover-fragments/
```
# scripts/brownfield-takeover/

Verktyg för att ta över en befintlig, portaldriftsatt Azure Landing Zone så att
engine kan hantera den framöver. Använder [Azure Governance Visualizer][azgovviz]
(AzGovViz) som upptäcktslager och genererar en `platform.json`-kandidat samt
Bicep-fragment för tenant-konfigurationsrepot.

| Script | Syfte |
|--------|-------|
| [Build-PlatformJson.ps1](#build-platformjsonps1) | Härled `platform.json`-skalärer (sub-ID:n, MG-namn, location, säkerhetskontakt) från hierarki + tilldelningsparametrar |
| [Build-OverrideFragments.ps1](#build-overridefragmentsps1) | Extrahera policytilldelningarnas parametervärden; generera ett `parPolicyAssignmentParameterOverrides`-fragment per MG-scope |

[azgovviz]: https://github.com/Azure/Azure-Governance-Visualizer

---

## När det här används

Målet är en ALZ-tenant som driftsattes via Azure-portalen ("Deploy a landing
zone"-upplevelsen) och sedan dess legat utan IaC-hantering. Syftet är att peka
engine mot den befintliga management group-hierarkin, låta deployment stacks ta
över ägarskapet av ALZ-biblioteksobjekten och bevara tenantens specifika
konfiguration i det nya tenant-konfigurationsrepot.

Skrivskyddat mot Azure. Scripten skriver bara till sin egen output-mapp.

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

# Az-moduler — verifiera att Az.Accounts och Az.Resources finns
Get-Module -ListAvailable Az.Accounts, Az.Resources | Select-Object Name, Version

# Om tomt, installera:
Install-Module -Name Az -Scope CurrentUser -Force -AllowClobber
```

> AzGovViz kommer med ett eget `./pwsh/prerequisites.ps1`. Det installerar
> ingenting vid lokal körning utanför AzDO/GitHub Actions, så verifiera Az-
> modulerna manuellt enligt ovan.

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

Fyra steg: upptäck, syntetisera `platform.json`, syntetisera fragment, granska
och committa till tenant-repot.

### 1. Kör AzGovViz mot måltenanten

Skapa först output-mappen (AzGovViz skapar den inte själv):

```powershell
New-Item -ItemType Directory -Force `
    -Path ../alz-mgmt-templates/scripts/brownfield-takeover/azgovviz-output
```

Kör sen AzGovViz från `Azure-Governance-Visualizer/`:

```powershell
cd <workspace>/Azure-Governance-Visualizer

./pwsh/AzGovVizParallel.ps1 `
    -ManagementGroupId '<int-root-mg-id>' `
    -OutputPath ../alz-mgmt-templates/scripts/brownfield-takeover/azgovviz-output `
    -NoMDfCSecureScore `
    -NoPolicyComplianceStates `
    -NoResourceDiagnosticsPolicyLifecycle `
    -NoPIMEligibility `
    -NoResources `
    -NoCsvExport
```

`-No*`-flaggorna stänger av allt som inte behövs för syntes. `-NoResources` är
den stora tidsvinsten — hoppar över per-resurs-skanningen som dominerar
AzGovViz-körningen på tenants med riktiga workloads.

`-ManagementGroupId` är den **intermediära** roten — det som portalen driftsatte
som ALZ-rot. Standardportalen producerar `alz`, men verifiera med
`Get-AzManagementGroup | Select-Object Name, DisplayName` innan körning.

Output hamnar i `scripts/brownfield-takeover/azgovviz-output/JSON_<mgId>_<yyyyMMdd_HHmmss>/`.

### 2. Generera `platform.json`-kandidat

```powershell
cd <workspace>/alz-mgmt-templates

# Hämta senaste AzGovViz-output-mappen
$jsonRoot = Get-ChildItem ./scripts/brownfield-takeover/azgovviz-output -Directory -Filter 'JSON_*' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

./scripts/brownfield-takeover/Build-PlatformJson.ps1 `
    -AzGovVizJsonPath $jsonRoot.FullName `
    -OutputDirectory  ./scripts/brownfield-takeover/takeover-fragments
```

### 3. Generera tilldelnings-fragment

```powershell
./scripts/brownfield-takeover/Build-OverrideFragments.ps1 `
    -AzGovVizJsonPath $jsonRoot.FullName `
    -OutputDirectory  ./scripts/brownfield-takeover/takeover-fragments `
    -AlzLibraryPath   ./templates/core/governance/lib/alz
```

Båda scripten är skrivskyddade mot Azure — inga API-anrop, all data kommer från
AzGovViz JSON-output. Du kan köra om dem utan att autentisera om.

### 4. Granska och committa till tenant-konfigurationsrepot

Genererade filer hamnar i `takeover-fragments/`:

| Fil | Innehåll |
|-----|----------|
| `platform.json` | `platform.json`-kandidat med härledda skalärer + defaultvärden för icke-härledbara fält |
| `platform.json.notes.txt` | Härledningsstatus per fält — vad som kom från brownfield och vad som är default |
| `override-<mgId>.bicepparam` | `param parPolicyAssignmentParameterOverrides = {...}` per MG-scope, med literala värden från brownfield |
| `custom-assignments.txt` | Tilldelningar utanför ALZ-biblioteket — informativ lista, ingen åtgärd krävs |

#### 4a. platform.json

Öppna `takeover-fragments/platform.json.notes.txt` och läs igenom
härledningsstatusen. Gå sen igenom kandidaten i `platform.json` och granska
främst:

- **Tomma fält.** Vissa arketyp-MG:er kanske inte finns i just denna tenant
  (vanligt i "simple mode" där `management/connectivity/identity/security`
  saknas). Scriptet hanterar det automatiskt genom att kollapsa alla
  `SUBSCRIPTION_ID_*` till `platform`-suben, men verifiera att det stämmer.
- **`NETWORK_TYPE`.** Default är `hubnetworking`. Bekräfta mot faktisk
  brownfield-topologi — om kunden kör Virtual WAN byt till `virtualwan`.
- **`LOCATION_SECONDARY`.** Inte härledbart. Fyll i om DR-geo-par är relevant
  för engagemanget.
- **`SUBSCRIPTION_ID_*` när flera prenumerationer finns under samma MG.**
  Scriptet tar första, vilket oftast är rätt men inte alltid.

Kopiera till `alz-mgmt-<tenant>/config/platform.json` när du är nöjd.

#### 4b. Fragment

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
- **Uppenbart brus** (parametrar där värdet bara upprepar ALZ-bibliotekets
  default — t.ex. `effect: 'Audit'` på en Audit-tilldelning) → ta bort. Scriptet
  bevarar alla brownfield-värden verbatim utan att jämföra mot biblioteket,
  eftersom "är det här värdet brus eller medveten portal-drift" är en
  omdömesfråga som inte låter sig automatiseras utan mer kontext.

#### 4c. custom-assignments.txt

Listar tilldelningar utanför ALZ-biblioteket. Engine-stacken rör inte dessa vid
takeover, så de överlever orörda oavsett vad du gör. Om du vill att engine ska
hantera dem framöver kan du lägga in dem i tenant-repots
`customerPolicyAssignments`-array — annars behöver du inte göra något.

---

## Build-PlatformJson.ps1

### Parametrar

| Parameter | Obligatorisk | Beskrivning |
|-----------|--------------|-------------|
| `-AzGovVizJsonPath` | **Ja** | Sökväg till `JSON_<root>_<timestamp>/`-mappen producerad av `AzGovVizParallel.ps1` |
| `-OutputDirectory` | **Ja** | Där `platform.json`-kandidaten skrivs; skapas om den saknas |

### Härledningslogik

| Fält | Källa |
|------|-------|
| `INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID` | AzGovViz `-ManagementGroupId` |
| `MANAGEMENT_GROUP_ID` | Int-roots `mgParentId` (tenantens rot-MG) |
| `PLATFORM_MODE` | `simple` om `management/connectivity/identity/security` saknas, annars `hybrid` |
| `MG_NAME_*` | Första barn med arketypsnamn under förväntad förälder |
| `SUBSCRIPTION_ID_*` | Första prenumeration direkt under respektive MG. I simple mode kollapsar alla till `platform`-suben |
| `LOCATION` / `LOCATION_PRIMARY` | Vanligast förekommande Azure-region i tilldelningsparametrar |
| `SECURITY_CONTACT_EMAIL` | `Deploy-MDFC-Config-*.emailSecurityContact`, fallback `Deploy-SvcHealth-BuiltIn.actionGroupEmail` |

### Default-värden (granska och justera)

| Fält | Default | Kommentar |
|------|---------|-----------|
| `NETWORK_TYPE` | `hubnetworking` | Operatören väljer `hubnetworking` eller `virtualwan` |
| `ENABLE_TELEMETRY` | `true` | Engine-default |
| `LOCATION_SECONDARY` | `""` | Inte härledbart från brownfield |

---

## Build-OverrideFragments.ps1

### Parametrar

| Parameter | Obligatorisk | Beskrivning |
|-----------|--------------|-------------|
| `-AzGovVizJsonPath` | **Ja** | Sökväg till `JSON_<root>_<timestamp>/`-mappen |
| `-OutputDirectory` | **Ja** | Där fragment-filerna skrivs |
| `-AlzLibraryPath` | Nej | Sökväg till `*.alz_policy_assignment.json`-filerna. När den anges genereras bara ALZ-biblioteksmatchande tilldelningsnamn till fragment; allt annat hamnar i `custom-assignments.txt`. **Starkt rekommenderad** — utan den läcker anpassade tenantspecifika tilldelningar in i fragment-outputen. |

### Driftsanteckningar

- **Idempotent.** Varje körning skriver över output-mappen. Säkert att köra om.
- **Skrivskyddat mot Azure.** Inga API-anrop.
- **Bevarande av literala värden.** Parametervärden genereras exakt som de
  ser ut i brownfield-tenanten. Ingen inferens, ingen substitution, ingen
  jämförelse mot bibliotekets default. Städning och parametrering är
  operatörens beslut under granskning.
- **Tomma parametrar hoppas över.** Tilldelningar där `properties.parameters` är
  tom exkluderas — engine-policydefinitionernas defaultvärden gäller och ingen
  override behövs.

---

## Kända gotchas

### AzGovViz skapar inte output-mappen

Du får ett `path ... does not exist - please create it!`-fel. Skapa mappen
manuellt innan körning (se steg 1 ovan).

### Platshållare i kommandot

Om du kopierar in `'<int-root-mg-id>'` bokstavligen istället för att byta ut det
mot det faktiska MG-namnet får du ett `404 NotFound`-fel från ARM. Kör
`Get-AzManagementGroup | Select-Object Name, DisplayName` för att hitta rätt
namn.

### Simple mode vs hybrid mode

En portaldriftsatt ALZ i "simple mode" har bara `platform`-MG:n utan
`management/connectivity/identity/security`-underbarnen. Prenumerationen ligger
direkt under `platform`, inte under `management`. `Build-PlatformJson.ps1`
upptäcker detta automatiskt och kollapsar alla `SUBSCRIPTION_ID_*` till
platform-suben.

---

## Inte i scope för detta verktyg

| Fråga | Var det hanteras |
|-------|------------------|
| Infrastruktur-resurs-ID:n (hub-VNet, Firewall, DNS-zoner) | Engine konstruerar dem från `platform.json`-skalärer i `.bicepparam`-filer; redigera dem direkt om kundens resurser inte följer ALZ-namnkonventionen |
| Namnkollisioner för policydefinitioner | Flaggas inte — engine skriver över biblioteksnamngivna anpassade definitioner vid första deployen, vilket är rätt beteende för takeover |
| Rolltilldelningar, blueprints, resurslås | Engine driftsätter sina egna; befintliga utanför stackens hanterade set lämnas orörda |
| Parametrisering av literala värden till `lawResourceId`/`location`/`securityEmail` | Manuell operatörsuppgift under granskning — kräver omdöme om värdet matchar engine-konventionen |

Se `../README.md` för den fullständiga examensarbets-kontexten om varför
in-place-takeover-strategin kollapsar större delen av den traditionella
brownfield-auditerings-ytan.

---

## `.gitignore`

Output-mapparna innehåller tenantspecifik data (subscription-ID:n,
LAW-resurs-ID:n, säkerhetskontakt-e-postadresser) som **aldrig** får committas
till engine-repot. Den hör bara hemma i tenant-konfigurationsrepot, efter
operatörens granskning.

Lägg till i rot-`.gitignore`:

```
scripts/brownfield-takeover/azgovviz-output/
scripts/brownfield-takeover/takeover-fragments/
```
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

### 4. Granska och committa

Se [Granska outputen](#granska-outputen) nedan för hur du läser och städar
filerna innan du kopierar dem in i tenant-konfigurationsrepot.

---

## Granska outputen

De genererade filerna hamnar i `takeover-fragments/`:

| Fil | Innehåll |
|-----|----------|
| `platform.json` | Kandidat med härledda skalärer + defaultvärden för icke-härledbara fält |
| `platform.json.notes.txt` | Härledningsstatus per fält |
| `override-<mgId>.bicepparam` | `parPolicyAssignmentParameterOverrides`-block per MG-scope, literalerna från brownfield |
| `custom-assignments.txt` | Tilldelningar utanför ALZ-biblioteket — informativ lista, ingen åtgärd krävs |

Granskningen har tre delmoment. Ta dem i ordning.

### A. Granska `platform.json`

Öppna `platform.json.notes.txt` för härledningsstatus per fält. Kolla sen
kandidaten mot följande punkter:

| Punkt | Vad du gör |
|-------|-----------|
| Tomma `MG_NAME_*` | Vanligt i simple mode där `management/connectivity/identity/security` saknas. Om din engine-template läser dem ändå, fyll i tomma strängar eller konventionsnamn |
| `NETWORK_TYPE` | Default `hubnetworking`. Byt till `virtualwan` om kunden kör Virtual WAN |
| `LOCATION_SECONDARY` | Tomt — fyll i om DR-geopar är relevant |
| `SUBSCRIPTION_ID_*` när flera subs finns under samma MG | Scriptet tar första. Verifiera att det blev rätt för kundens arkitektur |

Kopiera till `alz-mgmt-<tenant>/config/platform.json` när du är nöjd.

### B. Städa overrides

**Tumregeln.** Titta på varje parametervärde och fråga: *kan engine veta det här
utan att veta om min tenant?*

- **Nej** → värdet är nödvändig konfiguration. Behåll.
- **Ja** → värdet är brus som upprepar ALZ-bibliotekets default. Ta bort.

**Namnprefix avslöjar default-effect** i ALZ-bibliotekets tilldelningar. Det är
90%-pålitligt och räcker för granskningen:

| Prefix | Default-effect | Vad `effect`-parametern betyder om den finns i overriden |
|--------|----------------|----------------------------------------------------------|
| `Audit-*` | `Audit` | Upprepar default → brus |
| `Deny-*` | `Deny` | Upprepar default → brus |
| `Deploy-*` | `DeployIfNotExists` | Upprepar default → brus |
| `Enforce-*` | `Deny` eller initiativ | Troligen brus, verifiera |
| `Enable-*` | `DeployIfNotExists` | Upprepar default → brus |

Om du är osäker på ett specifikt värde, öppna motsvarande
`*.alz_policy_definition.json` i `templates/core/governance/lib/alz/` och
jämför mot `properties.parameters.<namn>.defaultValue`.

**Tre konkreta exempel från Sylaviken:**

*Nödvändig override — behåll:*
```bicep
'Deploy-AzActivity-Log': {
  parameters: {
    logAnalytics: {
      value: '/subscriptions/6f05.../law-alz-swedencentral'  // LAW-ID, engine kan inte gissa
    }
  }
}
```

*Brus — hela blocket kan tas bort:*
```bicep
'Audit-TrustedLaunch': {
  parameters: {
    effect: {
      value: 'Audit'   // Audit-prefix → default är redan Audit → upprepning
    }
  }
}
```

*Delvis brus — behåll LAW, ta bort `enableAscFor*`-upprepningar om de matchar
definitionens default:*
```bicep
'Deploy-MDFC-Config-H224': {
  parameters: {
    logAnalytics: { value: '/subscriptions/...' }     // behåll
    emailSecurityContact: { value: 'test@ex.com' }    // behåll
    enableAscForAppServices: { value: 'Disabled' }    // granska mot def.default — troligen brus
    enableAscForArm:        { value: 'Disabled' }    // samma
    // ... osv
  }
}
```

### C. Parametrisera matchande literaler

När en literal värde matchar vad engine skulle konstruera från `platform.json`,
byt ut den mot variabelreferensen så att overriden överlever framtida
`platform.json`-ändringar. Så här ser det ut i praktiken:

**Före** (det verktyget emitterar):
```bicep
'Deploy-AzActivity-Log': {
  parameters: {
    logAnalytics: {
      value: '/subscriptions/6f051987-3995-4c82-abb3-90ba101a0ab4/resourceGroups/rg-alz-logging-swedencentral/providers/Microsoft.OperationalInsights/workspaces/law-alz-swedencentral'
    }
  }
}
```

**Efter** (vad du committar — om LAW-sökvägen matchar konventionen):
```bicep
'Deploy-AzActivity-Log': {
  parameters: {
    logAnalytics: {
      value: lawResourceId
    }
  }
}
```

`lawResourceId` är redan deklarerad som `var` högst upp i `int-root.bicepparam`
och konstrueras från `SUBSCRIPTION_ID_MANAGEMENT`, `LOCATION` och namn-
konventionen. Samma sak för `location` (→ `LOCATION_PRIMARY`) och
`securityEmail` (→ `SECURITY_CONTACT_EMAIL`).

**Jämförelsen du gör** mellan literal och variabel:

| Literal innehåller | Jämför med | Matchar? |
|--------------------|-----------|----------|
| `/subscriptions/<sub>/resourceGroups/rg-alz-logging-<loc>/providers/Microsoft.OperationalInsights/workspaces/law-alz-<loc>` | `lawResourceId` | Ja → byt ut |
| `swedencentral` | `location` | Ja → byt ut |
| `rg-alz-asc-swedencentral` | `'rg-alz-asc-${location}'` | Ja → byt ut |
| `test@example.com` | `securityEmail` (från platform.json) | Ja → byt ut |

### D. När resurs-ID:n inte följer ALZ-konventionen

I Sylaviken matchar alla resursnamn konventionen (`law-alz-swedencentral`,
`dcr-alz-changetracking-swedencentral` osv.) eftersom portalen använde ALZ-
defaults. I en riktig kund-brownfield kan det se helt annorlunda ut — LAW:en
heter kanske `log-prod-sec-01` i en RG som heter `rg-monitoring`, och att byta
namn på en Log Analytics workspace kräver omdeploy och historikförlust.

Du har två val, välj baserat på omfattning:

**Få resurser utanför konventionen → litera­lera i fragment.** Lämna den
extraherade literala resurs-ID:n som den är i fragmentet. Varje referens till
resursen blir då hårdkodad, men det är en liten mängd duplikat.

**Flera policies refererar samma resurs → patcha var-deklarationen.**
Öppna `alz-mgmt-<tenant>/config/core/governance/mgmt-groups/int-root.bicepparam`
och byt ut `var lawResourceId = ...`-raden mot kundens faktiska sökväg:

```bicep
// Före
var lawResourceId = '/subscriptions/${subIdMgmt}/resourceGroups/${rgLogging}/providers/Microsoft.OperationalInsights/workspaces/${lawName}'

// Efter (kundens LAW utanför konventionen)
var lawResourceId = '/subscriptions/xxxxxxxx-xxxx/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/log-prod-sec-01'
```

Sen kan overriden i fragmentet fortsätta referera `lawResourceId` som variabel,
och alla tilldelningar som pekar på LAW:en följer med automatiskt. En patch,
många referenser uppdaterade.

Samma logik gäller `rgLogging`, `lawName`, `uamiName`, DCR-namnen — alla är
`var`-deklarationer i `int-root.bicepparam` som kan patchas individuellt.

### E. custom-assignments.txt

Listar tilldelningar utanför ALZ-biblioteket. Engine-stacken rör inte dessa vid
takeover, så de överlever orörda. Om du vill att engine ska hantera dem
framöver kan du lägga in dem i tenant-repots `customerPolicyAssignments`-array
— annars behöver du inte göra något.

---

## Fragment-scopes och deras målfiler

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

Bara filer för scopes med ALZ-biblioteksmatchande tilldelningar genereras.

---

## Build-PlatformJson.ps1

### Parametrar

| Parameter | Obligatorisk | Beskrivning |
|-----------|--------------|-------------|
| `-AzGovVizJsonPath` | **Ja** | Sökväg till `JSON_<root>_<timestamp>/`-mappen |
| `-OutputDirectory` | **Ja** | Där `platform.json`-kandidaten skrivs |

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
| `-AlzLibraryPath` | Nej | Sökväg till `*.alz_policy_assignment.json`-filerna. När den anges genereras bara ALZ-biblioteksmatchande tilldelningsnamn till fragment; allt annat hamnar i `custom-assignments.txt`. **Starkt rekommenderad.** |

### Driftsanteckningar

- **Idempotent.** Varje körning skriver över output-mappen.
- **Skrivskyddat mot Azure.** Inga API-anrop.
- **Bevarande av literala värden.** Parametervärden emitteras verbatim från
  brownfield. Ingen inferens, ingen jämförelse mot bibliotekets default.
  Städning och parametrering är operatörens beslut under granskning.
- **Tomma parametrar hoppas över.** Tilldelningar där `properties.parameters`
  är tom exkluderas.

---

## Kända gotchas

### AzGovViz skapar inte output-mappen

Du får `path ... does not exist - please create it!`. Skapa mappen manuellt
(se steg 1).

### Platshållare i kommandot

Om du kopierar in `'<int-root-mg-id>'` bokstavligen får du `404 NotFound` från
ARM. Kör `Get-AzManagementGroup | Select-Object Name, DisplayName` för att
hitta rätt namn.

### Simple mode vs hybrid mode

En portaldriftsatt ALZ i simple mode har bara `platform`-MG:n utan
`management/connectivity/identity/security`-underbarnen. Prenumerationen ligger
direkt under `platform`, inte under `management`. `Build-PlatformJson.ps1`
upptäcker detta automatiskt och kollapsar alla `SUBSCRIPTION_ID_*` till
platform-suben.

---

## Inte i scope för detta verktyg

| Fråga | Var det hanteras |
|-------|------------------|
| Infrastruktur-resurs-ID:n (hub-VNet, Firewall, DNS-zoner) | Engine konstruerar dem från `platform.json`-skalärer i `.bicepparam`-filer. När konventionen inte stämmer, patcha `var`-deklarationerna i `int-root.bicepparam` — se [avsnitt D](#d-när-resurs-idn-inte-följer-alz-konventionen) |
| Namnkollisioner för policydefinitioner | Flaggas inte — engine skriver över biblioteksnamngivna anpassade definitioner vid första deployen |
| Rolltilldelningar, blueprints, resurslås | Engine driftsätter sina egna; befintliga utanför stackens hanterade set lämnas orörda |
| Automatisk parametrisering till variabelreferenser | Manuell operatörsuppgift — kräver omdöme om värdet matchar engine-konventionen, se [avsnitt C](#c-parametrisera-matchande-literaler) |

Se `../README.md` för den fullständiga examensarbets-kontexten om varför
in-place-takeover-strategin kollapsar större delen av den traditionella
brownfield-auditerings-ytan.

---

## `.gitignore`

Output-mapparna innehåller tenantspecifik data (subscription-ID:n,
LAW-resurs-ID:n, säkerhetskontakt-e-postadresser) som **aldrig** får committas
till engine-repot.

Lägg till i rot-`.gitignore`:

```
scripts/brownfield-takeover/azgovviz-output/
scripts/brownfield-takeover/takeover-fragments/
```
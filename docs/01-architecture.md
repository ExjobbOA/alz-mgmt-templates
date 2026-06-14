# Arkitektur

Det här dokumentet förklarar hur plattformen är byggd och hur delarna hänger ihop. Det är skrivet
för dig som är van vid Azure och infrastruktur men kanske inte har jobbat så mycket med
Infrastructure as Code eller Bicep. Vi tar grundbegreppen först och bygger vidare därifrån.

## Grundbegrepp

### Infrastructure as Code och Bicep

Infrastructure as Code (IaC) betyder att infrastrukturen beskrivs i textfiler som checkas in i Git
i stället för att klickas fram i portalen. Koden är sanningen: det som står där är det som ska
finnas i Azure, och utrullningen är en automatisk process som gör verkligheten lik koden.

Bicep är Microsofts språk för det här på Azure. Det är deklarativt, alltså du beskriver
sluttillståndet snarare än stegen dit. Två filtyper återkommer hela tiden:

* `.bicep` är en template som beskriver resurser. I den här plattformen är templatesen generella
  och innehåller ingen kunddata.
* `.bicepparam` är en parameterfil som matar en template med värden. Det är där kundens värden
  kommer in, fast som vi snart ser hämtas de i sin tur från en enda konfigurationsfil.

Bicep bygger ovanpå Azure Verified Modules (AVM), Microsofts officiella och versionerade
byggstenar. Plattformen använder AVM-modulen `avm/ptn/alz/empty` som grund för styrningen, samma
modul som Microsofts egen accelerator.

### Azure Landing Zones

Azure Landing Zones (ALZ) är Microsofts referensarkitektur för hur en Azure-miljö struktureras i
grunden. Kärnan är en hierarki av management groups (containrar ovanför prenumerationer som
styrning kan sättas på) med Azure Policy och rolltilldelningar på rätt nivåer. En prenumeration
som placeras på rätt plats i hierarkin ärver automatiskt rätt styrning och säkerhet.

Hierarkin delas in i arketyper med olika syfte och därför olika policyuppsättning: platform (för
delade plattformstjänster), landing zones (där arbetslaster bor, uppdelat i corp för internt och
online för internetexponerat), sandbox (experiment med lösare styrning) och decommissioned
(avveckling).

### Deployment stacks

En vanlig Bicep-utrullning skapar och uppdaterar resurser men håller inte reda på vad som
försvinner. Tar du bort en policy ur koden ligger den kvar i Azure tills någon städar manuellt.

Deployment stacks löser det. En stack är ett Azure-objekt som äger en uppsättning resurser och
följer koden över tid. Plattformen kör alla utrullningar som stackar med samma konfiguration som
Microsofts accelerator:

* `ActionOnUnmanage: DeleteAll` på styrnings- och RBAC-stackarna. Försvinner en policytilldelning
  eller rolltilldelning ur koden tas den bort i Azure vid nästa körning. Det är säkert för
  styrningsresurser eftersom de går att återskapa ur koden.
* `ActionOnUnmanage: DetachAll` på de två stackarna som äger riktiga resurser med data, alltså
  loggning och nätverk. Försvinner något ur koden släpper stacken bara taget om resursen i stället
  för att radera den.
* `DenySettingsMode: None`. Stacken lägger inga egna skrivspärrar på resurserna, så att Azure
  Policy fritt kan remediera.

En begränsning att känna till: deployment stacks stödjer ännu inte what-if, alltså
förhandsgranskning av ändringar. Pipelinen kör därför en vanlig what-if först med samma template
och parametrar, och verkställer sedan via stacken. Även det mönstret kommer från Microsofts
accelerator.

### OIDC-inloggning mot Azure

Pipelinen loggar in i Azure utan lagrade hemligheter. GitHub utfärdar en kortlivad token vid
körning, och Azure litar på den om den matchar en förkonfigurerad federation mot en managed
identity. Det finns alltså inga klienthemligheter att rotera eller läcka. Modellen med två
identiteter, en för plan och en för apply, beskrivs i `docs/06-security-and-oidc.md`.

## Engine och tenant

Plattformen är delad i två sorters repon med olika ansvar, och det är själva uppdelningen som gör
logiken återanvändbar över kunder.

Engine-repot (`alz-mgmt-templates`) innehåller all logik: Bicep-templates, hela policybiblioteket
under `lib/alz/`, de återanvändbara workflowsen, fyra composite actions och PowerShell-skripten.
Det känner inte till någon enskild kund och versioneras med Git-tags.

Tenant-repot (ett per kund) innehåller bara konfiguration: `platform.json`, `.bicepparam`-filer
och två tunna workflows. Kopplingen ser ut så här i tenantens `cd.yaml`:

```yaml
jobs:
  plan_and_apply:
    uses: ExjobbOA/alz-mgmt-templates/.github/workflows/cd-template.yaml@v1.1.8
    with:
      platform_ref: v1.1.8
      parameters_file_name: config/platform.json
```

Taggen står alltså på två ställen: i `uses:`-raden (vilken version av workflowen som körs) och i
`platform_ref` (vilken version av engine-repot som checkas ut till `./platform`). Tenantens
parameterfiler refererar sedan in i den utcheckningen, till exempel så här i
`config/core/governance/mgmt-groups/int-root.bicepparam`:

```bicep
using '../../../../platform/templates/core/governance/mgmt-groups/int-root/main.bicep'
```

Antalet `../` varierar med hur djupt parameterfilen ligger, men mönstret är detsamma: konfiguration
i tenant-repot, logik i `./platform`.

## Management group-hierarkin och plattformsläget

Hierarkin följer ALZ. Under tenantens befintliga rot skapas en intermediate root (konfigurerbart
id, till exempel `alz`), och under den arketyperna: platform, landingzones (med corp och online
som barn), sandbox och decommissioned.

Nyckeln `PLATFORM_MODE` i `platform.json` styr hur platform-delen ser ut:

* `full` bygger ut platform med fyra egna under-management-groups: connectivity, identity,
  management och security, i linje med Microsofts fulla referenshierarki.
* `simple` slår ihop dem. Plattformstjänsterna hamnar direkt under platform, vilket ger en
  plattare hierarki för mindre eller nystartade miljöer. Schemat i `platform.json` är detsamma i
  båda lägena, så en miljö kan växa från simple till full utan att konfigurationsformatet ändras.

I pipelinen är effekten att stegen för de fyra platform-barnen och deras RBAC hoppas över när
`PLATFORM_MODE` är `simple`. Mekaniken på Bicep-sidan sitter framför allt i
`platform/main-rbac.bicep`.

## Stackarna

Varje del av plattformen rullas ut som en egen deployment stack. Poängen med många små stackar i
stället för en stor är att en ändring stannar i sin stack, vilket gör utrullningar förutsägbara
och lätta att felsöka. Den egenskapen går dessutom att bevisa, se driftsdokumentet.

Pipelinen definierar 16 stackar. Styrning på management group-nivå, med `DeleteAll`:

* `governance-int-root` (skapas på tenantens rot-MG, bygger intermediate root och hierarkin)
* `governance-landingzones`
* `governance-landingzones-corp`
* `governance-landingzones-online`
* `governance-platform`
* `governance-platform-connectivity` (endast full mode)
* `governance-platform-identity` (endast full mode)
* `governance-platform-management` (endast full mode)
* `governance-platform-security` (endast full mode)
* `governance-sandbox`
* `governance-decommissioned`

RBAC på management group-nivå, med `DeleteAll`:

* `governance-platform-rbac`
* `governance-platform-connectivity-rbac` (endast full mode)
* `governance-landingzones-rbac`

På prenumerationsnivå, med `DetachAll`:

* `core-logging` (Log Analytics-arbetsyta med mera, i management-prenumerationen)
* `networking-hub` (hub-nätverk i connectivity-prenumerationen, körs bara när `NETWORK_TYPE` är
  `hubnetworking`)

I simple mode hoppas de fem full mode-stackarna över, så 11 av 16 körs. Det är de 11 stackar
rapporten redovisar i utvärderingen. En experimentell virtual WAN-variant fanns under
utvecklingen men togs bort inför överlämningen; `hubnetworking` är den nätverkstyp som ingår.

RBAC ligger i egna stackar, skilda från policy-stackarna. Det håller isär rolltilldelningar och
policy, som har beroenden mellan sig, så att ordningsföljden går att styra.

## Konfigurationsmekanismen

Inom ett tenant-repo bor all kundspecifik data på ett ställe: `config/platform.json`. Den är
sanningskällan för prenumerations-id:n, management group-namn, region, plattformsläge, nätverkstyp
och kontaktuppgifter.

Kedjan från konfiguration till utrullning:

1. `platform.json` innehåller värdena som vanlig JSON.
2. Vid varje körning läser composite-actionen `bicep-variables` in filen och plattar ut den till
   miljövariabler i `GITHUB_ENV`.
3. Parameterfilerna läser värdena med `readEnvironmentVariable('NAMN')` och innehåller därför
   ingen hårdkodad kunddata.

Parameterfilerna blir därmed lika generella som templatesen, och det kundspecifika bärs av
`platform.json`. Det är också därför onboardingen lägger sådan vikt vid att fylla den filen rätt:
det är den hela utrullningen läser ifrån.

## Pipelinen

Tenant-repot har två tunna workflows som anropar engine-repots återanvändbara mallar.

CI (`ci.yaml`, anropar `ci-template.yaml`) är granskningsgrinden. Den triggas på pull requests mot
main och bygger och lintar all Bicep så att fel fångas innan något verkställs.

CD (`cd.yaml`, anropar `cd-template.yaml`) är utrullningen och består av två jobb:

1. What If, i GitHub-miljön `alz-mgmt-plan`. Kör en vanlig what-if per stack med samma template
   och parametrar som apply skulle använda. Kan hoppas över med flaggan `skip_what_if`, men det
   vill man normalt inte.
2. Deploy, i GitHub-miljön `alz-mgmt-apply`. Verkställer varje stack som en deployment stack.
   Jobbet körs bara om What If inte misslyckades eller avbröts.

Under huven finns fyra composite actions i engine-repot: `bicep-installer` (rätt verktygsversioner),
`bicep-variables` (platform.json till miljövariabler), `bicep-first-deployment-check` och
`bicep-deploy` (själva stack-körningen med rätt scope och inställningar).

Kallstart, alltså den allra första utrullningen mot en tom tenant, hanteras av två mekanismer
tillsammans. Bakgrunden är att en ny deployment stack validerar rättigheter på varje scope i
templaten innan den skapar något, och på en tom tenant finns inga management groups än, så
valideringen skulle fastna i ett moment 22.

* I What If-jobbet tolkar `bicep-first-deployment-check` det 403-svar som i praktiken betyder att
  en management group inte finns än som en 404, så att förhandsgranskningen inte faller på att
  scopet saknas.
* I Deploy-jobbet förskapar ett eget steg hela MG-skelettet i förälder-först-ordning innan
  stackarna körs. Steget är idempotent (befintliga grupper hoppas över), läser gruppnamnen från
  `MG_NAME_*`-värdena i `platform.json`, hoppar över platform-barnen i simple mode, och väntar in
  RBAC-propagering när något nytt skapats.

I praktiken kör du `governance-int-root` först vid en kallstart och låter resten följa, se
onboarding- och driftsdokumenten.

## Var ligger vad

### Engine-repot (`alz-mgmt-templates`)

```
templates/
  core/
    governance/
      mgmt-groups/        Bicep per arketyp och under-MG, samt main-rbac.bicep för RBAC-stackarna
      lib/alz/            policybiblioteket: definitioner, initiativ, tilldelningar och
                          rolldefinitioner som JSON, verbatim från ALZ-biblioteket
      tooling/            alz_library_metadata.json (pinnad biblioteksversion) och
                          Update-AlzLibraryReferences.ps1 (synkar bibliotekets referenser)
    logging/              core-logging-stacken
  networking/
    hubnetworking/        networking-hub-stacken
.github/
  workflows/              ci-template.yaml och cd-template.yaml (de återanvändbara mallarna)
  actions/                bicep-installer, bicep-variables, bicep-first-deployment-check,
                          bicep-deploy
bootstrap/
  plumbing/               Bicep som skapar OIDC-identiteterna (se onboarding och security)
  subjects/               subject-contract.md, kontraktet för OIDC-subjektet
scripts/                  onboard.ps1, cleanup.ps1 och stack-state-verktygen
tests/                    testfall T1 till T10 från utvärderingen, med evidens och skärmbilder
state-snapshots/          sparade stack-state-ögonblicksbilder från testerna
docs/                     den här dokumentationen
```

### Tenant-repot

```
config/
  platform.json            kundens värden, enda sanningskällan
  core/governance/
    mgmt-groups/           .bicepparam per stack, inklusive *-rbac-filerna
  core/logging/            .bicepparam för core-logging
  networking/
    hubnetworking/         .bicepparam för networking-hub
  bootstrap/
    plumbing.bicepparam    endast för manuell bootstrap, se onboardingdokumentet
.github/workflows/         ci.yaml och cd.yaml som anropar engine-mallarna på en pinnad tag
```

Med den här kartan är resten av dokumentationen lätt att följa: onboarding för att sätta upp en
tenant, drift för det löpande arbetet, och livscykel för uppdateringar över tid.

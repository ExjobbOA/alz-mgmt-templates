# alz-mgmt-templates

Bicep-baserad plattform för att rulla ut och livscykelhantera Azure Landing Zones åt flera
tenants. Det här är engine-repot: här ligger all logik, alla Bicep-templates, hela
policybiblioteket, de återanvändbara pipeline-mallarna och PowerShell-skripten. Varje kund har ett
eget tunt tenant-repo som bara innehåller konfiguration och pekar hit via en specifik tag.

Plattformen är en MSP-anpassning av Microsofts officiella ALZ-accelerator för Bicep (Azure Verified
Modules for Platform Landing Zone). Den byggdes och utvärderades inom ett examensarbete och lämnas
över till Nordlo som en referens- och lärandeartefakt.

Den här dokumentationen kompletterar exjobbsrapporten. Rapporten svarar på varför: bakgrund,
designval, kriterier och utvärdering. Dokumentationen här svarar på hur: hur delarna hänger ihop,
var saker ligger, exakt hur man använder allting, och hur plattformen underhålls över tid.

## Vad det här är, och inte är

Det är en fungerande referensimplementation av en multi-tenant ALZ-plattform i Bicep: tydlig
uppdelning mellan engine och tenant, utrullning via GitHub Actions och Azure deployment stacks, och
lösenordsfri inloggning mot Azure via OIDC-federation. Där Microsofts accelerator använder
Terraform för själva bootstrap-steget görs hela kedjan här i Bicep.

Det är inte en nyckelfärdig produkt. Plattformen är greenfield-orienterad: stöd för att ta över en
redan befintlig miljö (brownfield) byggdes men ingick inte i utvärderingen. Kostnadsdrivande
nätverksresurser är avstängda som standard, och några designval är medvetet enklare än Microsofts,
till exempel att apply-identiteten har Owner. Allt sådant är beskrivet och motiverat i
dokumentationen så att ni vet vad ni tittar på.

## Engine och tenant

Plattformen är uppdelad i två sorters repon, och det är den uppdelningen som gör att samma logik
kan betjäna vilken kund som helst.

Engine-repot (det här) innehåller all logik och ingen kunddata: Bicep-templates, policybiblioteket
under `lib/alz/`, de återanvändbara workflowsen, composite actions och skripten. Det versioneras
med Git-tags, till exempel `v1.1.8`.

Tenant-repot (ett per kund) innehåller bara konfiguration: en `platform.json`, en uppsättning
`.bicepparam`-filer och två tunna workflows. Tenant-repots `cd.yaml` anropar engine-repots
återanvändbara workflow på en pinnad tag och skickar samma tag som checkout-referens:

```yaml
uses: ExjobbOA/alz-mgmt-templates/.github/workflows/cd-template.yaml@v1.1.8
with:
  platform_ref: v1.1.8
```

Vid körning checkar workflowen ut engine-repot till `./platform`, och tenantens parameterfiler
refererar in i den utcheckningen med relativa `using`-sökvägar.

Eftersom logik och konfiguration är åtskilda kan en fix i engine-repot nå alla kunder genom att
taggen bumpas i respektive tenant-repo, medan en kund som inte är redo kan ligga kvar på en äldre,
beprövad tag. Hur en sådan repin går till står i livscykeldokumentet.

## Hitta i dokumentationen

Läs i den här ordningen:

1. `docs/01-architecture.md`: hur allt hänger ihop. Börjar med en genomgång av IaC, Bicep,
   deployment stacks och OIDC för dig som inte jobbat med det förut, och går sedan igenom
   engine mot tenant, hierarkin, stackarna, konfigurationsmekanismen och pipelinen.
2. `docs/02-onboarding.md`: hur en ny tenant sätts upp från noll, vad `onboard.ps1` gör steg för
   steg, och hur du verifierar att allt blev rätt.
3. `docs/03-operations.md`: löpande drift. Köra CD, läsa what-if, bevisa att en ändring stannar i
   sin stack, rulla tillbaka, och de workarounds som finns.
4. `docs/04-lifecycle-and-updates.md`: uppdatera policybiblioteket och AVM-referenserna, och rulla
   ut en ny engine-version till tenants.
5. `docs/05-patterns-and-learnings.md`: mönster att ta med sig, både från MSP-anpassningen och
   direkt från Microsoft, med ärliga avvägningar.
6. `docs/06-security-and-oidc.md`: identitets- och OIDC-modellen i detalj.

Tenant-repot har en egen README som är en konfigurationsreferens för varje nyckel i
`platform.json`.

## Adoptera plattformen i en ny organisation

Referenserna till `ExjobbOA/alz-mgmt-templates` är medvetet hårdkodade och markerade med
`# ADOPTION:`-kommentarer i koden. GitHub tillåter inte uttryck i en reusable-workflow-referens,
så `uses:`-raden måste vara en litteral och är den obligatoriska ändringen vid adoption. Det här
är ställena att byta när plattformen tas in i en ny organisation:

* Tenant-repots `.github/workflows/ci.yaml` och `cd.yaml`: `uses:`-raden (org/repo och tag) samt
  värdet på `platform_ref`.
* Engine-repots `.github/workflows/ci-template.yaml` och `cd-template.yaml`: `repository:` i
  stegen som checkar ut engine-repot till `./platform`.
* `bootstrap/plumbing/main.bicep`: defaultvärdena för `githubOrg` och `moduleRepo`. De kan också
  lämnas och i stället anges vid körning, eftersom `onboard.ps1` läser org och repo från
  git-remotes.

## Förhållande till Microsofts accelerator

Plattformen ligger nära Microsofts ALZ-accelerator för Bicep. Policybiblioteket, AVM-modulerna,
deployment stack-konfigurationen och what-if-mönstret är desamma. De medvetna avvikelserna, alltså
engine/tenant-uppdelningen, konfiguration via `platform.json`, plattformsläget simple och Bicep i
stället för Terraform i bootstrap, beskrivs i patterns-dokumentet. Microsofts dokumentation är en
bra referens vid sidan av den här: https://azure.github.io/Azure-Landing-Zones/bicep/

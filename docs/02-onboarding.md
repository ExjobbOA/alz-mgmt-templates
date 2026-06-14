# Onboarding av en ny tenant

Det här dokumentet går igenom hur en ny tenant sätts upp från noll med `scripts/onboard.ps1`, vad
skriptet gör i varje steg, och hur du verifierar att allt blev rätt. Läs `docs/01-architecture.md`
först om begreppen är nya.

## Skriptets två jobb

`onboard.ps1` gör i grunden två saker:

1. Det skapar bindningen mellan GitHub och Azure, alltså den OIDC-federation som låter kundens
   pipeline logga in i Azure utan lagrade hemligheter. Den måste finnas innan någon CD-körning kan
   göras.
2. Det fyller `config/platform.json` med kundens värden, så att pipelinen har sin konfiguration
   att läsa.

Skriptet deployar identiteterna, men det deployar aldrig själva plattformen. Plattformen rullas
alltid ut av CD, efter att `platform.json` committats och gått genom en pull request.

## Förkrav

* PowerShell 7 eller senare (skriptet kräver det).
* `az` (Azure CLI), inloggad mot rätt tenant med `az login`.
* `gh` (GitHub CLI), autentiserad med `gh auth login`.
* `git`.
* Bicep CLI tillgängligt via `az bicep` (skriptet kontrollerar det, och `az` kan installera det
  vid behov).

Du behöver också rättigheter i båda ändar: i Azure måste du kunna skapa resurser i
bootstrap-prenumerationen och rolltilldelningar på tenantens rot-management-group, och i GitHub
måste du kunna administrera kundens repo (skapa environments och variabler).

Skriptet kontrollerar verktygen och inloggningarna innan det gör något.

## Vad du behöver ha till hands

Två värden:

* `-BootstrapSubscriptionId`: prenumerationen där identitetsresurserna ska skapas.
* `-ManagementGroupId`: tenantens rot-management-group, som GUID. Det är där rolltilldelningarna
  läggs.

Resten listar skriptet ut. GitHub-organisation och repo-namn läses från git-remotes, och finns det
redan en `config/platform.json` läses defaultvärden därifrån (management group, prenumeration,
region). Saknas något frågar skriptet interaktivt. Regionen är `swedencentral` om inget annat
anges, och GitHub-miljöerna heter `alz-mgmt-plan` och `alz-mgmt-apply` om du inte byter namn med
`-EnvPlan`/`-EnvApply` (gör inte det utan att läsa `docs/06-security-and-oidc.md` först, namnen är
en del av OIDC-subjektet).

Skriptet utgår från att tenant-repot ligger som granne till engine-repot (`../alz-mgmt`). Ligger
det någon annanstans anger du `-ConfigRepoPath`.

## Köra skriptet

Kör alltid en torrkörning först. Den visar exakt vad skriptet skulle göra utan att ändra något:

```powershell
./scripts/onboard.ps1 `
  -BootstrapSubscriptionId '<subscription-guid>' `
  -ManagementGroupId       '<tenant-root-mg-guid>' `
  -DryRun
```

Ser planen rätt ut kör du samma kommando utan `-DryRun`. Skriptet visar då en sammanställd plan
och kräver ett y innan det gör något skarpt.

## Steg för steg

Skriptet kör följande i ordning. Steg 4 till 8 bygger tillsammans bindningen, steg 9 fyller
konfigurationen.

1. Förkrav. Kontrollerar att `az`, `gh` och `git` finns och att du är inloggad i både Azure och
   GitHub.
2. Indata. Löser ut repo-sökväg, organisation och repo-namn från git-remotes, läser defaultvärden
   ur `platform.json`, och frågar efter det som saknas.
3. Plan och bekräftelse. Visar allt som kommer att göras och väntar på ditt y.
4. Skapar GitHub-miljöerna `alz-mgmt-plan` och `alz-mgmt-apply` i tenant-repot.
5. Återställer repots OIDC-subjekt till GitHubs standard (`use_default`). Det gör subjektet rent
   miljöbaserat, `repo:ORG/REPO:environment:ENV`, vilket är exakt det format de federerade
   inloggningsuppgifterna matchar.
6. Kör bootstrap-deployen, Azure-sidan av bindningen (se nästa avsnitt). Den heter
   `alz-bootstrap`, körs med `az deployment mg create` mot rot-management-gruppen från
   `bootstrap/plumbing/main.bicep`, och tar normalt 2 till 5 minuter. Ur deployens outputs fångar
   skriptet de två identiteternas client-id:n och resursgruppens namn.
7. Hämtar Azures tenant-id (`az account show`).
8. Skriver GitHub-miljövariablerna. I varje miljö sätts `AZURE_CLIENT_ID` (plan-miljön får
   plan-identitetens id, apply-miljön apply-identitetens), `AZURE_TENANT_ID` och
   `AZURE_SUBSCRIPTION_ID` (bootstrap-prenumerationen i båda). Det är variablerna som
   `azure/login`-steget i pipelinen läser.
9. Uppdaterar `config/platform.json`: `MANAGEMENT_GROUP_ID`, `LOCATION`, `LOCATION_PRIMARY` och
   `SUBSCRIPTION_ID_MANAGEMENT`. I simple mode sätts även de fyra plattformsfälten
   (`SUBSCRIPTION_ID_PLATFORM`/`CONNECTIVITY`/`IDENTITY`/`SECURITY`) till samma prenumeration, så
   att schemat är detsamma oavsett läge. I full mode uppdateras de fyra bara om de redan var
   identiska; annars rör skriptet bara `SUBSCRIPTION_ID_MANAGEMENT` och påminner dig om att se
   över resten.

Till sist skrivs en sammanfattning med identiteterna, resursgruppen, tenant-id, de satta
variablerna och nästa steg.

## Vad som skapas i Azure

Bootstrap-deployen körs från `bootstrap/plumbing/main.bicep`. Namnet plumbing syftar bara på att
det här är rören som måste finnas innan något annat kan logga in. Den skapar:

* En resursgrupp, `rg-alz-mgmt-identity-<region>-1`, i bootstrap-prenumerationen.
* Två user-assigned managed identities, en för plan och en för apply.
* En federerad inloggningsuppgift (federated identity credential) på varje identitet, med
  subjektet `repo:ORG/REPO:environment:ENV`. Att subjektet bara bygger på miljönamnet, inte på
  branch eller workflow-referens, är ett medvetet val: engine-taggen kan bumpas utan att några
  inloggningsuppgifter behöver göras om.
* Rolltilldelningar på rot-management-gruppen: apply får Owner, plan får Reader plus den egna
  rollen `Landing Zone Reader (WhatIf/Validate)` som bara innehåller de två deployment-actions
  Reader saknar för att kunna köra what-if och validering. Detaljer och avvägningar i
  `docs/06-security-and-oidc.md`.

## Vad som skapas i GitHub

De två miljöerna med var sina tre variabler, plus subjektåterställningen. Det är andra halvan av
bindningen: Azure litar på en token vars subjekt matchar `repo:ORG/REPO:environment:ENV`, och
GitHub utfärdar en sådan när ett jobb körs i rätt miljö.

## Efter skriptet: granska, committa, kör CD

Skriptet skriver `platform.json` lokalt men committar ingenting. Avsluta så här:

1. Granska `config/platform.json`. Kör du full mode med olika prenumerationer för connectivity,
   identity och security justerar du dem nu. Se även över `SECURITY_CONTACT_EMAIL` och
   `LOCATION_SECONDARY`.
2. Committa och pusha, och öppna en pull request så att CI kör (bygge och lint av all Bicep).
3. När CI är grön, kör CD med bara `governance-int-root` påslaget som första körning, så att
   intermediate root och hierarkin etableras. Kör därefter resten. Flaggorna och hur en körning
   läses beskrivs i `docs/03-operations.md`.

## Verifiera bindningen

I GitHub, under Settings och Environments: att `alz-mgmt-plan` och `alz-mgmt-apply` finns och har
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID` och `AZURE_SUBSCRIPTION_ID`.

I Azure, att identiteterna finns:

```bash
az identity list --resource-group "rg-alz-mgmt-identity-<region>-1" -o table
```

Att de federerade inloggningsuppgifterna har rätt subjekt:

```bash
az identity federated-credential list \
  --identity-name "<uami-namn>" \
  --resource-group "rg-alz-mgmt-identity-<region>-1" -o table
```

Att rolltilldelningarna ligger på rot-management-gruppen:

```bash
az role assignment list \
  --scope "/providers/Microsoft.Management/managementGroups/<root-mg-guid>" -o table
```

## Manuell bootstrap

Skriptet bygger bootstrap-parametrarna i minnet, så det vanliga flödet läser aldrig
`config/bootstrap/plumbing.bicepparam`. Den filen finns för den som vill deploya bara
identiteterna för hand, till exempel vid felsökning. Fyll i värdena och kör:

```bash
az deployment mg create \
  --name alz-bootstrap \
  --management-group-id '<root-mg-guid>' \
  --location '<region>' \
  --template-file bootstrap/plumbing/main.bicep \
  --parameters @config/bootstrap/plumbing.bicepparam
```

Det ger samma resultat som skriptets steg 6, men du anger parametrarna själv.

## Riva ner

`scripts/cleanup.ps1` river det som onboarding och styrningen skapat, i rätt ordning: först
deployment-stackarna vid intermediate root (i omvänd beroendeordning, och eftersom de kör
`DeleteAll` följer deras policy- och rolltilldelningar med), sedan kvarvarande management groups
nerifrån och upp inklusive intermediate root, sedan identitetsresursgruppen, rolltilldelningarna
på rot-gruppen och till sist custom-rollen. Varje steg är idempotent och kräver bekräftelse, och
`-DryRun` finns även här. Kör den bara när en tenant faktiskt avvecklas: utan identiteterna kan
pipelinen inte längre logga in.

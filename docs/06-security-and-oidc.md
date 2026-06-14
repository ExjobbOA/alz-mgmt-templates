# Säkerhet och OIDC

Plattformen loggar in i Azure utan lagrade hemligheter, via OIDC-federation mellan GitHub och
Microsoft Entra ID. Det här dokumentet beskriver hur federationen är uppsatt, de två identiteterna
och deras rättigheter, subjektkontraktet, var säkerheten faktiskt sitter, och en öppen jämförelse
med Microsofts modell.

## Lösenordsfri inloggning

Vid varje körning utfärdar GitHub en kortlivad token för det jobb som körs. Azure accepterar den
om den matchar en federerad inloggningsuppgift (federated identity credential) på en managed
identity. Token är kortlivad och utfärdas vid körning, så det finns inga klienthemligheter att
lagra, rotera eller läcka.

Tre fält avgör matchningen:

* Utfärdare (issuer): `https://token.actions.githubusercontent.com`
* Målgrupp (audience): `api://AzureADTokenExchange`
* Subjekt (subject): `repo:<ORG>/<REPO>:environment:<ENV>`

## De två identiteterna

Bootstrappen skapar två user-assigned managed identities i resursgruppen
`rg-alz-mgmt-identity-<region>-1`, med rolltilldelningar på tenantens rot-management-group. De har
medvetet olika rättigheter.

Plan-identiteten används av What If-jobbet, via GitHub-miljön `alz-mgmt-plan`. Den ska kunna läsa
allt och förhandsgranska, men inte ändra något. Den får två roller:

* Den inbyggda Reader.
* Den egna rollen `Landing Zone Reader (WhatIf/Validate)`, som definieras i samma bootstrap-Bicep
  och innehåller exakt två actions: `Microsoft.Resources/deployments/validate/action` och
  `Microsoft.Resources/deployments/whatIf/action`. Reader täcker läsningen men saknar just de två
  deployment-actions som krävs för what-if och validering; custom-rollen lägger till dem och inget
  mer, och är tänkt att användas tillsammans med Reader.

Apply-identiteten används av Deploy-jobbet, via miljön `alz-mgmt-apply`, och har den inbyggda
rollen Owner på rot-management-gruppen. Det är den som verkställer utrullningarna.

Uppdelningen betyder att förhandsgranskningen körs med en identitet som inte kan ändra något, och
att den privilegierade identiteten bara används när något faktiskt ska verkställas.

## Subjektkontraktet

Subjektet matchas exakt och har formatet:

```
repo:<ORG>/<REPO>:environment:<ENV>
```

Det bygger alltså bara på organisation, repo och miljönamn. Två saker följer av det, och båda står
i `bootstrap/subjects/subject-contract.md` som är sanningskällan:

Miljönamnen `alz-mgmt-plan` och `alz-mgmt-apply` är låsta. De är en del av subjektet, så döps de
om slutar inloggningen fungera tills de federerade inloggningsuppgifterna gjorts om.

Workflow-sökvägar och git-referenser är däremot inte låsta. Ett alternativ hade varit att baka in
den anropande workflowens referens i subjektet (`job_workflow_ref`), men det valdes bort medvetet.
Den federerade inloggningsuppgiften lever i Entra ID, så varje attribut som bakas in i subjektet
blir något som måste underhållas på Azure-sidan per tenant. Eftersom engine-repot konsumeras via
tags, och varje tenant ska kunna uppgradera oberoende, hade en referens i subjektet tvingat fram
en ny inloggningsuppgift vid varje tag-bump, vilket inte skalar. Med miljöbaserat subjekt är en
repin en ren GitHub-ändring: engine-versionen styrs av `platform_ref` i tenant-repots workflow,
under branch protection, medan credential-hanteringen ligger still.

## Var säkerheten sitter

Att subjektet inte innehåller någon git-referens betyder inte att vem som helst kan trigga en
utrullning. Skyddet är en kombination av tre lager:

* Federationen: bara jobb i rätt repo och rätt miljö kan få en token som Azure accepterar.
* Uppdelningen plan mot apply: förhandsgranskningen kan inte ändra något alls.
* GitHubs environment protection rules: de styr vem som får köra jobb i en miljö. Med required
  reviewers på `alz-mgmt-apply` krävs ett mänskligt godkännande innan Deploy får köra, och
  branch protection på tenant-repot styr vem som kan ändra konfigurationen och taggen.

## Avvägning mot Microsofts modell

Här finns en medveten skillnad värd att vara öppen med. Microsofts accelerator-bootstrap skapar
fyra egna least privilege-roller på tenant root och undviker breda roller som Owner. Den här
plattformen ger apply Owner.

Alternativet övervägdes. Slutsatsen blev att apply-fasens operationsbredd, alltså att skapa
management groups, policytilldelningar och RBAC-strukturer ner genom hela hierarkin, i praktiken
kräver Owner-rättigheter, och att en custom-roll som täcker hela den ytan bara blir en kopia av
Owner med ett annat namn. Det är ett ärligt förenklingsval, men Microsofts modell är mer granulär
och mer least privilege, och det är en reell skillnad.

Vill ni härda plattformen är ordningen given: slå på required reviewers på apply-miljön och branch
protection på tenant-repot (kostar inget, ger mycket), och pröva därefter att ersätta Owner på
apply med en snävare rolluppsättning om er riskbild kräver det. Plan-sidan är redan minimal.

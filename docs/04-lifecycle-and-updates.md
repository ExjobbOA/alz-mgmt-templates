# Livscykel och uppdateringar

Plattformen sätts inte upp en gång och lämnas. Policybiblioteket och AVM-modulerna uppdateras av
Microsoft över tid, och poängen med konstruktionen är att kunna ta in de uppdateringarna under
kontroll och rulla ut dem till kunderna i egen takt. Det här dokumentet täcker tre saker: uppdatera
policybiblioteket, uppdatera AVM-moduler, och versionera engine-repot ut till tenants.

Microsofts dokumentation är en bra referens vid sidan av det här:
https://azure.github.io/Azure-Landing-Zones/bicep/

## Uppdatera policybiblioteket

### Vad biblioteket är och hur det pinnas

`templates/core/governance/lib/alz/` är en ögonblicksbild av Azure Landing Zones Library vid en
bestämd version: policydefinitioner, initiativ, rolldefinitioner och policytilldelningar som JSON.
Bicep-templatesen läser in dem med `loadJsonContent` via fyra variabler i varje `main.bicep`:
`alzRbacRoleDefsJson`, `alzPolicyDefsJson`, `alzPolicySetDefsJson` och `alzPolicyAssignmentsJson`.

Versionen pinnas i `templates/core/governance/tooling/alz_library_metadata.json`, som beroendet
`platform/alz` med fältet `ref` (för närvarande `2026.04.0`). Biblioteket bor i repot
`Azure/Azure-Landing-Zones-Library`, där en version ligger under `platform/alz/<version>`.

### Stegen

1. Välj målversion. Aktuella versioner och ändringsloggar finns via bibliotekets repo och
   Microsofts what's new-sida.
2. Höj `ref` i `alz_library_metadata.json`.
3. Uppdatera innehållet i `lib/alz/` till den nya versionen. Assets hämtas med ALZ-bibliotekets
   eget verktyg `alzlibtool` eller direkt från det versionerade biblioteksrepot; exakt kommando
   står i bibliotekets dokumentation eftersom verktyget ägs och versioneras separat.
4. Kör `templates/core/governance/tooling/Update-AlzLibraryReferences.ps1`. Skriptet skannar
   `lib/alz/` och skriver om de fyra variablerna i varje berörd `main.bicep` så att Bicep plockar
   upp det som tillkommit, försvunnit eller bytt namn. Katalogstrukturen styr målet: bibliotekets
   rot mappas till int-root, `lib/alz/platform/` till platform och så vidare. Kör med `-WhatIf`
   först för att se exakt vad som skulle ändras.
5. Validera. Öppna en pull request så att CI bygger och lintar, och läs CD:s what-if noga. Med
   `DeleteAll` på styrningsstackarna är det i what-if du ser vilka tilldelningar en
   biblioteksuppdatering tar bort, inte bara vad den lägger till.
6. Tagga engine-repot och rulla ut enligt sista avsnittet.

### Två saker att hålla koll på

Azure Policy-versionering hanteras inte automatiskt i Bicep-flödet. En tilldelning kan peka på en
viss version av en inbyggd policy, och att flytta till en nyare definitionsversion är ett manuellt
moment. Microsoft beskriver läget här:
https://azure.github.io/Azure-Landing-Zones/policy/policyVersioning/

Om en uppdatering byter namn på eller tar bort en tilldelning som finns i en exclusion-lista
gäller SYNC-kontraktet: listan i `main.bicepparam` och `parManagementGroupExcludedPolicyAssignments`
i motsvarande `*-rbac.bicepparam` måste vara identiska, annars faller RBAC-stacken. Det är också
rätt tillfälle att ompröva undantag som infördes för buggar i en äldre biblioteksversion; de kan ha
blivit onödiga, och ett kvarglömt undantag betyder att en policy inte tillämpas fast den kunde.

## Uppdatera AVM-moduler

Modulerna är pinnade till exakta versioner i Bicep-koden, som `br/public:avm/ptn/alz/empty:0.3.6`
för styrningen och modulerna i `templates/core/logging/main.bicep` för loggningen.

1. Läs modulens release notes. AVM-moduler kan ha brytande ändringar mellan versioner, så det här
   är inte en formalitet.
2. Höj versionen på `module`-raden.
3. Validera med CI och what-if som ovan.
4. Tagga och rulla ut.

Ett konkret exempel på varför versionerna spelar roll: Azure Monitoring Agent-modulen ligger på
`avm/ptn/alz/ama:0.2.0` därför att den versionen löser en namnkrock på lås som annars slår till
under deployment stack-valideringen. Nedgradera den inte utan att veta varför den höjdes.

## Versionera engine-repot och rulla ut till tenants

### Modellen

Engine-repot släpps som Git-tags. Varje tenant pinnar en tag på två ställen i både `ci.yaml` och
`cd.yaml`: i `uses:`-raden (vilken version av den återanvändbara workflowen som körs) och i
`platform_ref` (vilken version av engine-repot som checkas ut till `./platform`). Håll dem på
samma tag.

Eftersom varje kund pinnar själv styr du vilka kunder som får en uppdatering och när. OIDC-subjektet
är miljöbaserat och tag-agnostiskt, så en repin är en ren GitHub-ändring; inga federerade
inloggningsuppgifter behöver röras.

### Rulla ut en ny version till en kund

1. Gör klart ändringen i engine-repot och sätt en ny tag, till exempel `v1.1.9`.
2. I tenant-repot, byt taggen i `uses:` och `platform_ref` i båda workflow-filerna.
3. Öppna en pull request så att CI och what-if kör mot den nya versionen. Läs what-if.
4. Kör CD när det ser rätt ut.

Kunderna är oberoende, så rulla gärna ut till en kund först och låt den ligga innan resten tas.
Det är ett enkelt sätt att canary-testa en engine-version.

### Vad DeleteAll och DetachAll betyder vid uppdatering

Styrnings- och RBAC-stackarna kör `DeleteAll`: det en ny biblioteksversion tar bort ur koden tas
bort i Azure vid nästa CD. Det är avsett, men det gör what-if-granskningen till det viktigaste
steget i en uppdatering. De två prenumerationsstackarna kör `DetachAll`: försvinner något ur deras
kod släpps det i stället för att raderas, så en uppdatering kan inte råka ta med sig Log
Analytics-data eller nätverk. Mer om att läsa en körning i `docs/03-operations.md`.

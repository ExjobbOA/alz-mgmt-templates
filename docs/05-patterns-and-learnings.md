# Mönster och lärdomar

Plattformen är värd att läsa som ett exempel, inte bara att drifta. Mönstren finns på två nivåer:
det projektet själv gjorde i MSP-anpassningen, och det Microsoft gör i sin accelerator som
plattformen ärver. Sist står de ärliga avvägningarna, alltså vad som är medvetet enklare eller
obeprövat, så att ni vet var gränserna går.

## Mönster från MSP-anpassningen

Separera logik från konfiguration. Den bärande idén är uppdelningen i ett engine-repo och ett
tenant-repo per kund. Engine-repot innehåller all logik och ingen kunddata, tenant-repot bara
konfiguration. Det är det som låter samma kodbas betjäna många kunder och en fix nå alla som
pekar om till en ny tag. Mönstret är användbart långt utanför just ALZ.

Behandla konfiguration som data. Allt kundspecifikt bor i en `platform.json`, och parameterfilerna
läser den via miljövariabler i stället för att hårdkoda värden. Parameterfilerna blir lika
generella som templatesen, och det är entydigt var kundens sanning finns.

Versionera med tags och låt varje kund uppgradera oberoende. Engine-repot släpps som tags, varje
tenant pinnar en. Det ger kontroll över vem som får en uppdatering när, och gör canary-utrullning
till en naturlig arbetsform.

Gör OIDC-subjektet tag-agnostiskt. Subjektet bygger bara på repo och miljönamn, inte på branch
eller workflow-referens. Hade referensen ingått hade varje tag-bump krävt nya federerade
inloggningsuppgifter per tenant, vilket inte skalar. Nu är en repin en ren GitHub-ändring medan
credential-hanteringen ligger still på Azure-sidan.

Dela upp i många små stackar med egna flaggor. Varje del är en egen deployment stack som kan
köras separat, och en ändring stannar i sin stack. Det går dessutom att bevisa med
stack-state-verktygen, vilket gör påståendet testbart i stället för en förhoppning.

Förskapa det som valideringen kräver. Deployment stacks validerar rättigheter på alla scopes innan
de skapar något, vilket låser sig på en tom tenant. Lösningen är ett idempotent steg som förskapar
MG-skelettet förälder-först innan stackarna körs. Mönstret, att avväpna en valideringscirkel genom
att etablera ett minimalt skelett först, återkommer i fler sammanhang än det här.

Bygg in ett enklare läge utan att ändra schemat. Plattformsläget simple slår ihop de fyra
platform-barnen till en plattare hierarki, men `platform.json` ser likadan ut i båda lägena. En
miljö kan börja enkelt och växa till full utan konfigurationsbrott.

## Mönster direkt från Microsoft

Använd deployment stacks för livscykel, inte bara utrullning. En stack följer koden över tid och
tar bort det som försvinner ur den. Det är det som gör att styrningen i Azure faktiskt speglar
koden i Git, i stället för att driva isär.

Skilj styrningsinnehåll från utrullningslogik via ett versionerat bibliotek. ALZ-biblioteket
håller policy, initiativ, roller och tilldelningar som versionerade data, separat från Bicep-koden
som rullar ut dem. Styrningen kan uppdateras för sig och logiken för sig.

Bygg på versionerade moduler. AVM ger byggstenar med semantisk versionering, så uppgraderingar
sker medvetet och en i taget i stället för att allt flyter.

Förhandsgranska även när verktyget saknar stödet. Stacks stödjer inte what-if än, så acceleratorn
kör en vanlig what-if med samma indata före apply. Att sätta en granskning framför ett verktyg som
saknar en är ett mönster i sig.

Dela identiteten i plan och apply. Förhandsgranskningen körs med en identitet som inte kan ändra
något, och bara verkställandet använder den privilegierade. Grundmodellen kommer från
acceleratorns bootstrap.

## Ärliga avvägningar

Apply-identiteten har Owner, vilket är bredare än Microsofts modell. Microsofts bootstrap skapar
fyra least privilege-roller på tenant root och undviker Owner. Här övervägdes samma väg, men
slutsatsen blev att apply-fasens operationsbredd (management groups, policy, RBAC ner genom hela
hierarkin) i praktiken kräver Owner, och att en custom-roll som täcker hela ytan bara blir en
omdöpt Owner. Det är ett ärligt val, men Microsofts modell är mer least privilege, och det här är
första punkten att titta på vid härdning. Se `docs/06-security-and-oidc.md`.

Brownfield byggdes men utvärderades inte. Plattformen är greenfield-orienterad; övertagande av en
portaldeployad miljö testades inledningsvis men lyftes ur utvärderingen i samråd med
fallstudieföretaget. Rapportens slutsats är dessutom att den anpassningslogik som krävs för att
härbärgera en handbyggd miljö utgör bestående teknisk skuld. Lita inte på den vägen utan att
verifiera den själv först.

Att följa uppströms är löpande arbete. Policyversionering är manuell i Bicep-flödet och en
biblioteksuppdatering sker i flera steg. Det är inte en brist i plattformen så mycket som
villkoret för att leva nära acceleratorn, men arbetet måste planeras in. Se
`docs/04-lifecycle-and-updates.md`.

Konfigurationsmekanismen är egen. `platform.json` med miljövariabler är plattformens lösning,
medan Microsoft rör sig mot en egen konfigurationsfil för acceleratorn. Mekanismen är enkel och
fungerar, men den är något ni själva förvaltar när uppströms ändrar struktur.

Undantag som bär versionsantaganden ska omprövas. Ett exempel är det undantag för
`Enforce-EncryptTransit` som infördes för en bugg i en äldre biblioteksversion. Sådana undantag
ska prövas på nytt vid varje biblioteksuppgradering: antingen kan de tas bort och styrningen
återfås, eller så ska de stå kvar med en aktuell motivering. Ett kvarglömt undantag är en policy
som inte tillämpas fast den kunde.

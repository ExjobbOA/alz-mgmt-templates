# Drift

Det här dokumentet handlar om den löpande driften när en tenant väl är uppsatt: hur du kör en
utrullning, läser förhandsgranskningen, bevisar att en ändring stannar där den ska, rullar
tillbaka, och vad de inbyggda workarounden gör. Ny tenant: se `docs/02-onboarding.md`. Uppdatering
av bibliotek eller engine: se `docs/04-lifecycle-and-updates.md`.

## Köra en utrullning

CD startas manuellt från tenant-repots `cd.yaml` (Actions, workflow_dispatch). Den anropar
engine-repots `cd-template.yaml`, som kör två jobb i ordning: först What If, sedan Deploy. Deploy
körs bara om What If inte misslyckades eller avbröts.

Vid start väljer du vilka delar som ska köras. Tenant-workflowen exponerar grupperade flaggor, och
alla är avstängda som standard, så en körning är alltid ett aktivt val av delmängd:

* `governance-int-root`: intermediate root-stacken.
* `governance-landingzones`: landingzones-stacken.
* `governance-landingzones-children`: corp- och online-stackarna tillsammans.
* `governance-platform`: platform-stacken.
* `governance-platform-children`: de fyra platform-barnen tillsammans (ignoreras i simple mode).
* `governance-sandbox` och `governance-decommissioned`: respektive stack.
* `governance-rbac`: alla tre RBAC-stackarna tillsammans.
* `core`: core-logging-stacken.
* `networking`: networking-hub-stacken (körs dessutom bara när `NETWORK_TYPE` är `hubnetworking`).

Två stackar kan alltså inte råka köras för att någon glömt en flagga, utan allt är opt-in per
körning. En full körning är helt enkelt alla flaggor påslagna. De fem full mode-stackarna har
dessutom en grind i engine-mallen på `PLATFORM_MODE`, så de körs aldrig i simple mode oavsett
flaggor.

Utöver flaggorna finns `skip_what_if`, som hoppar över förhandsgranskningen. Låt den vara av i
normalfallet; what-if är din enda blick på vad som händer innan det händer.

Engine-mallen har samma uppsättning flaggor fast granulära, en per stack, för den som anropar
`cd-template.yaml` direkt. Det operatören möter är dock tenant-filens grupperade.

## Läsa what-if

What If kör en vanlig förhandsgranskning per vald stack, med exakt samma template och parametrar
som apply skulle använda. Läs den innan Deploy får köra, och var särskilt uppmärksam på
borttagningar.

Styrnings- och RBAC-stackarna kör `DeleteAll`: en policytilldelning eller rolltilldelning som
försvunnit ur koden tas bort i Azure. Det är avsiktligt, men det betyder att what-if är stället
där du ser vad som kommer att försvinna, inte bara vad som tillkommer. En oväntad borttagningsrad
är en signal att stanna och kontrollera.

## Bevisa att en ändring stannar i sin stack

En av poängerna med många små stackar är att en ändring i en stack inte ska röra de andra. Det går
att bevisa med skripten i `scripts/`:

```powershell
./scripts/Export-ALZStackState.ps1 -OutputFile "state-before.json" `
  -SubscriptionId "<subscription-id>" -TenantIntRootMgId "<intermediate-root-id>"

# gör ändringen, kör CD

./scripts/Export-ALZStackState.ps1 -OutputFile "state-after.json" `
  -SubscriptionId "<subscription-id>" -TenantIntRootMgId "<intermediate-root-id>"

./scripts/Compare-ALZStackState.ps1 -BeforeFile "state-before.json" -AfterFile "state-after.json"
```

Exporten fångar per stack både metadata (status, resurslista) och faktiska egenskapsvärden på
nyckelresurser, till exempel parametrar på policytilldelningar. Jämförelsen delar in stackarna i
tre grupper: de med innehållsändringar, de som omdeployats utan innehållsändring, och de som är
orörda, och visar vilka egenskaper som ändrats. Resultatet du vill se är att bara den stack du
rörde har innehållsändringar. Det var med den här metoden förändringsisoleringen bevisades i
utvärderingen, och `state-snapshots/` innehåller ögonblicksbilder därifrån.

## Rulla tillbaka

Koden är sanningen, så en återställning är en backad ändring i konfigurationen plus en ny
CD-körning. Stacken stämmer av Azure mot det tillbakatagna läget.

Tänk på vad `DeleteAll` betyder här: lade din ändring till en tilldelning och du backar den, tas
tilldelningen bort vid nästa körning. Konsekvent och förutsägbart, men läs what-if även vid en
återställning. De två prenumerationsstackarna (`core-logging`, `networking-hub`) kör `DetachAll`,
så en återställning där raderar inte arbetsytan eller nätverket, den släpper bara taget om det som
lyfts ur koden.

## Bärande workarounds och när man rör dem

Konfigurationen innehåller några medvetna undantag. De ser ut som städobjekt men håller
utrullningen grön, och var och en har en förklarande kommentar i sin fil. Rör dem först när
förutsättningen de vilar på har ändrats.

DDoS-policyn `Enable-DDoS-VNET` är överskriven till `effect: Audit` i platform-, landingzones- och
connectivity-parametrarna. Biblioteket levererar den med `effect: Modify` och ett platshållar-id
för en DDoS-plan, och utan en riktig plan skulle Modify försöka koppla in platshållaren i varje
VNet och faila. Audit rapporterar i stället för att modifiera. Den dagen ni deployar en riktig
DDoS-plan flippar ni tillbaka till Modify och pekar på den.

Nätverket är avstängt på alla kostnadsdrivande delar som standard: `deploy*`-flaggorna för Azure
Firewall, Bastion, gateways, DDoS och DNS private resolver är `false`, och privata DNS-zoner
deployas inte (`deployPrivateDnsZones: false` på båda hubbarna). Det håller en referensmiljö nära
noll i kostnad. För att slå på en tjänst sätter du dess flagga till `true` och avkommenterar
motsvarande subnät i parameterfilen. Subnäten ligger förkommenterade därför att policyn
`Deny-Subnet-Without-Nsg` blockerar subnät utan NSG; ett VNet utan subnät är giltigt och
compliant, så subnät läggs till först när deras tjänst faktiskt deployas. Behövs privata
endpoints längre fram är det vedertagna ALZ-mönstret att deploya hela zonuppsättningen
centraliserat på en hub, inte en delmängd utspridd på båda.

Resurslåset är avstängt (`parGlobalResourceLock: None`) så att nedrivning och omdeploy inte
blockeras i en utvärderingsmiljö. I produktion vill man typiskt ha `CanNotDelete`.

Och SYNC-kontraktet för exclusions: om en policytilldelning exkluderas i en stacks
`main.bicepparam` måste samma tilldelning stå i `parManagementGroupExcludedPolicyAssignments` i
motsvarande `*-rbac.bicepparam`. Annars letar RBAC-stacken efter en tilldelning som inte finns och
faller vid körning. Listorna är normalt tomma; ändrar du den ena, ändra den andra i samma commit.

## Vanliga situationer

Kallstart. En ny deployment stack validerar rättigheter på alla scopes i templaten innan den
skapar något, och på en tom tenant finns inga management groups än. Två mekanismer hanterar det:
What If-jobbets `bicep-first-deployment-check` tolkar 403 (gruppen finns inte) som 404 så att
förhandsgranskningen går igenom, och Deploy-jobbet förskapar hela MG-skelettet förälder-först,
idempotent och simple mode-medvetet, med en väntan på RBAC-propagering när något skapats. I
praktiken: kör `governance-int-root` först, sedan resten.

En stack failar mitt i en körning. Stackarna är oberoende, så de som redan gått igenom påverkas
inte. Rätta orsaken och kör om med bara de berörda flaggorna påslagna.

Deployment-historiken städas. `bicep-deploy` rensar tidigare deployment-poster i scopet före varje
körning. Det ser destruktivt ut men är ett medvetet sätt att hålla sig under Azures kvot för
deployment-historik per scope. Det rör inte resurserna stacken äger, bara historikposterna.

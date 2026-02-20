**20 feb**

**Teknisk logg: Verifierad avvikelse i Platform Connectivity **

Under exekvering av steget Platform Connectivity har en kritisk diskrepans mellan pipelinens rapporterade status och det faktiska tillståndet i Azure identifierats. Steget genomförs utan att generera några felkoder eller varningsmeddelanden i loggen, men den förväntade resursförändringen uteblir. 

Observationer: 

Utebliven förflyttning: Den aktuella subskriptionen kvarstår i sin ursprungliga Management Group trots att kommandot för förflyttning har exekverats. 

Frånvaro av felmeddelanden: Inga API-fel, timeout-notiser eller "Access Denied"-meddelanden registreras i GitHub Actions-konsolen. 

Asynkront stopp: Processen avslutas utan att signalera misslyckande (non-zero exit code), vilket innebär att pipelinen fortsätter som om operationen vore framgångsrik trots att miljöns tillstånd är oförändrat. 

Detta skapar ett blockerat läge där startpunkten för efterföljande nätverkskonfiguration aldrig etableras, då subskriptionen fysiskt befinner sig på fel plats i hierarkin för att ärva de nödvändiga policy-inställningarna och rättigheterna. 

 
**Lösning:**

Problem: Pipeline failar med BadRequest trots till synes korrekta roller. 

Hitta beviset: JSON-logg i Activity Log pekar på roleAssignments. 

Rotorsak: En IAM Condition blockerade identiteten från att röra Owner/UAA-roller, vilket krävdes för subskriptions-operationen. 

Lösning: Justering av IAM-condition för att tillåta nödvändiga operationer. 

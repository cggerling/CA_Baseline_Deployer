# Testanleitung: CA Baseline Deployer über die Weboberfläche

Diese Anleitung ist für dich, wenn du den Deployer auf deinem eigenen Rechner testen willst. Du arbeitest dabei nur mit Explorer, Browser und der Weboberfläche des Deployers, eine Kommandozeile brauchst du nicht.

Bitte teste ausschließlich in einem Testtenant. Die CA-Policies starten zwar im Modus „Nur Bericht“, der Deployer legt aber Gruppen, Konten, Named Locations und eine App-Registrierung an.

## Was du brauchst

- einen Windows-Rechner, auf dem du Programme installieren darfst
- einen Entra-ID-Testtenant mit Entra ID P1, für die risikobasierten Policies P2
- ein Konto in diesem Tenant mit der Rolle Global Administrator. Alternativ reichen diese fünf Rollen zusammen: Conditional Access Administrator, Authentication Policy Administrator, Privileged Role Administrator, User Administrator und Cloud Application Administrator.
- Zugriff auf das Repository auf GitHub oder ein ZIP mit dem Deployer, das du von mir bekommst

## 1. PowerShell 7 installieren

Der Deployer läuft mit PowerShell 7. Das ist ein eigenes Programm neben der Windows PowerShell, die auf jedem Rechner schon dabei ist.

1. Öffne den Microsoft Store und suche nach „PowerShell“.
2. Installier die App „PowerShell“ von Microsoft Corporation.

Ohne Store geht es auch über die Downloadseite <https://aka.ms/powershell-release?tag=stable>. Lade dort die Datei `PowerShell-…-win-x64.msi` herunter und installier sie mit den Standardeinstellungen.

Hast du PowerShell 7 schon, kannst du diesen Schritt überspringen. Die Startdatei aus Schritt 3 merkt es auch selbst, wenn es fehlt, und öffnet dann die Downloadseite.

## 2. Den Deployer herunterladen

Hast du eine Einladung zum Repository auf GitHub bekommen:

1. Nimm die Einladung an. Sie kommt per Mail oder steht unter <https://github.com/notifications>.
2. Öffne das Repository und klick auf den grünen Button **Code** und dann auf **Download ZIP**.

Hast du das ZIP direkt von mir bekommen, speicher es einfach ab.

Bevor du das ZIP entpackst:

1. Klick im Explorer mit der rechten Maustaste auf die ZIP-Datei und wähl **Eigenschaften**.
2. Setz unten auf der Registerkarte „Allgemein“ den Haken bei **Zulassen** und bestätige mit **OK**.

Windows markiert Dateien aus dem Internet und warnt sonst bei jedem Start. Mit dem Haken gilt die Freigabe für alle entpackten Dateien.

Entpack das ZIP dann in einen Ordner außerhalb von OneDrive, zum Beispiel `C:\Tools\CA_Baseline_Deployer`. In OneDrive-Ordnern sind Dateien manchmal nur als Platzhalter vorhanden, das stört den Start.

## 3. Die Oberfläche starten

1. Öffne den entpackten Ordner im Explorer.
2. Doppelklick auf **CA-Baseline-Deployer starten.cmd**.

Es öffnet sich ein schwarzes Konsolenfenster und kurz danach dein Browser mit der Oberfläche. Lass das Konsolenfenster offen, solange du testest. Die Anmeldefenster von Microsoft erscheinen später darüber, und wenn du es schließt, endet auch die Oberfläche.

Zeigt Windows stattdessen „Der Computer wurde durch Windows geschützt“, klick auf **Weitere Informationen** und dann auf **Trotzdem ausführen**. Das passiert, wenn das ZIP vor dem Entpacken nicht freigegeben wurde.

## 4. Durch die Schritte gehen

Die Seitenleiste links zeigt alle Schritte. Ein Haken heißt erledigt, ein Ausrufezeichen heißt, dass noch etwas fehlt. Jeder Schritt erklärt oben, worum es geht, was der Deployer macht und was du vorher erledigen solltest.

1. **Willkommen:** Lies den Haftungsausschluss und setz den Haken. Vorher geht es nicht weiter.
2. **Voraussetzungen:** Die Oberfläche prüft deinen Rechner selbst. Fehlt das Modul Microsoft.Graph.Authentication, klick auf **Fehlendes installieren**. Dafür brauchst du keine Administratorrechte.
3. **Tenant:** Leg einen neuen Tenant an. Die Oberfläche fragt nach der Domäne, die auf `.onmicrosoft.com` endet, und sucht die Tenant-ID selbst heraus.
4. **App-Registrierung:** Klick auf **App-Registrierung anlegen** und melde dich im Microsoft-Fenster an. Über diese App läuft später das Deployment.
5. **Anmeldung prüfen:** Hier siehst du, ob deine Rollen reichen und ob im Tenant noch die Sicherheitsstandards aktiv sind. Die müssen für Conditional Access aus sein.
6. **Persona-Gruppen, Named Locations, Policies, Authentifizierungsmethoden, Breakglass-Konten:** Zu jeder Einstellung steht eine Empfehlung. Für einen ersten Test kannst du die Vorgaben übernehmen.
7. **Prüfen und Probelauf:** Erst die Offline-Prüfung, dann den Probelauf gegen den Tenant. Der Probelauf ändert nichts und zeigt dir, was angelegt würde.
8. **Ausrollen:** Jetzt legt der Deployer alles an. Legt er neue Breakglass-Konten an, zeigt die Oberfläche die Kennwörter genau einmal. Speicher sie sofort, zum Beispiel in deinem Passwortmanager.

## 5. Nach dem Test aufräumen

Im Schritt **Zurücknehmen**:

1. Wähl das Protokoll deines Deployments aus.
2. Setz den Haken bei **Endgültig löschen (Purge)**, damit Gruppen und Konten nicht 30 Tage im Papierkorb liegen.
3. Klick auf **Zurücknehmen** und bestätige mit `JA`.
4. Wenn die Rücknahme fertig ist, klick unten auf **Deployer-App löschen**. Mach das wirklich erst zum Schluss, denn ohne die App kann sich der Deployer nicht mehr anmelden.

Danach klickst du oben rechts auf **Beenden** und kannst das Konsolenfenster schließen.

## Wenn etwas hakt

- **Das Anmeldefenster erscheint nicht:** Es liegt meist hinter dem Konsolenfenster. Schau in der Taskleiste nach.
- **Die Installation des Graph-Moduls scheitert:** Die Tabelle im Schritt „Voraussetzungen“ nennt die Ursache, oft ein Proxy oder eine Firewall. Schick mir dann einen Screenshot der Tabelle.
- **Etwas anderes geht schief:** Jeder Lauf schreibt ein Protokoll in den Ordner `Logs` im Deployer-Ordner. Schick mir die passende Datei, damit ich nachsehen kann.

# CA Baseline Deployer

Mit diesem Tool bekommst du einen guten Startpunkt für Conditional Access in Entra ID. Es rollt eine Sammlung von Einstellungen per Code in deinen Tenant aus, die aus meiner Sicht ein solides Fundament für die weitere Arbeit mit Conditional Access bilden. Dazu gehören Persona-Gruppen, Breakglass-Konten, eine Restricted Management Administrative Unit, Named Locations, Authentifizierungsstärken und die CA-Policies selbst. Authentifizierungsmethoden ergänzt der Deployer nur so weit, wie die Stärken sie brauchen.

Fertig ist dein Conditional Access damit nicht. Die Policies starten im Modus „Nur Bericht“, und welche Ausnahmen, Länder und Netze zu deiner Umgebung passen, entscheidest du danach selbst.

> Du nutzt das Tool auf eigene Verantwortung. Lies vorher den [Haftungsausschluss](DISCLAIMER.md). Falsch konfigurierte CA-Policies können alle Benutzer eines Tenants aussperren. Probier das Deployment deshalb zuerst in einem Testtenant aus, bevor du es produktiv einsetzt.

## Weboberfläche

Doppelklick auf `CA-Baseline-Deployer starten.cmd` im Repo-Ordner, oder in PowerShell 7:

```powershell
.\Start-CABaselineGui.ps1
```

Wie jemand ohne Kommandozeile vom ersten Download bis zum Aufräumen kommt, steht in der [Testanleitung](docs/Testanleitung.md).

Die Oberfläche führt dich in 13 Schritten durch das Deployment: Voraussetzungen prüfen und fehlende Module installieren, Tenant erfassen, App-Registrierung anlegen, Anmeldung prüfen, Persona-Gruppen benennen, Named Locations, Auswahl der Policies, Authentifizierungsmethoden und Passkeys, Breakglass-Konten, Offline-Prüfung und Probelauf, Ausrollen und Zurücknehmen. Zu jedem Schritt steht dabei, worum es geht, was der Deployer macht und was du vorher erledigen solltest. In der Seitenleiste siehst du, welche Schritte vollständig sind und wo noch etwas fehlt.

Über die Startseite hinaus kommst du erst, wenn du den Haftungsausschluss bestätigt hast. Die Bestätigung gilt für die laufende Sitzung.

Über die Vorlagen hinaus kannst du in der Oberfläche Folgendes einstellen:

- Zusätzliche Personas. Für sie legt der Deployer nur eine Entra-Sicherheitsgruppe an. Keine CA-Policy verweist auf sie, und es entstehen keine neuen Policies. Du kannst eine zusätzliche Persona als Sub-Persona genau einer Haupt-Persona zuordnen, etwa VIP unter Internals. Ihr Gruppenname setzt sich dann aus beiden zusammen (`SG-CA-Persona-Internals-VIP`). In der Config steht das unter `personas.additional`.
- Role-assignable je Persona. Vorausgewählt ist die Empfehlung aus `groups/personas.json`. Wählst du sie ab, bekommst du einen Hinweis. An einer bestehenden Gruppe lässt sich das Flag nicht mehr ändern. In der Config steht das unter `personas.roleAssignable`.
- Eigene Named Locations mit einem Namen nach dem Schema `NL-<Persona>-<Zweck>-<Typ>`. IP-Bereiche kannst du aus einer Text- oder CSV-Datei importieren. In der Config steht das unter `namedLocations.custom`.
- Die IP-Bereiche von Zscaler als `NL-Global-ZScaler_Ranges-IP`. Die Liste kommt von `config.zscaler.com` (empfohlene Hub-Bereiche der gewählten Cloud). Der Deployer holt sie bei jedem Lauf neu ab und schreibt ins Protokoll, was sich seit dem Import geändert hat. Ist Zscaler nicht erreichbar, nimmt er den gespeicherten Stand und warnt.

Ein paar Dinge zum Betrieb:

- Der Server lauscht nur auf `localhost` und verlangt ein zufälliges Token, das in der geöffneten Adresse steht. Gib die Adresse deshalb nicht weiter.
- Alles, was du in der Oberfläche einstellst, landet sofort in `config/tenants/<tenant>.json`. Die Skripte auf der Kommandozeile lesen dieselbe Datei.
- Deployment, Undo, App-Registrierung und Rollenprüfung laufen als eigene `pwsh`-Prozesse im Konsolenfenster des Servers. Die Microsoft-Anmeldung erscheint deshalb über diesem Fenster, die Ausgabe siehst du live im Browser.
- Rückfragen gibt es dabei keine. Was der Deployer auf der Kommandozeile fragen würde, steht vorher in der Config. Das betrifft auch die Umstellung auf Passkey-Profile (`authenticationMethods.migrateToPasskeyProfiles`) und Eingaben, die du bewusst leer lässt (`"-"`).
- Kennwörter neuer Breakglass-Konten zeigt die Oberfläche genau einmal in einem eigenen Fenster. Der Server hält sie nur im Speicher, bis der Browser sie abgeholt hat.
- Die Oberfläche prüft deine Eingaben, bevor sie in der Config landen. Kopierfehler wie Leerzeichen am Rand, Anführungszeichen oder unsichtbare Zeichen bereinigt sie selbst. IP-Bereiche prüft sie auf die Regeln von Entra (nur öffentliche Adressen, Präfix größer als /8, höchstens 2000 Bereiche). Länder klickst du aus einer Liste an.
- Skripte oder Schriften lädt die Oberfläche nicht aus dem Internet nach. Ins Internet geht sie nur für die Anmeldung, die Prüfung der Voraussetzungen, die Installation des Graph-Moduls, den Abruf des AAGUID-Katalogs, den Abruf der Zscaler-Bereiche und den Abgleich von Tenant-ID und Domäne. Beim Abgleich schickt sie nur den Domänennamen an den öffentlichen Anmeldedienst von Microsoft.

## Schnellstart auf der Kommandozeile

1. Config anlegen: Kopier `config/tenant.example.json` nach `config/tenants/<tenant>.json` und füll sie aus.
2. Offline prüfen:
   ```powershell
   .\Deploy-CABaseline.ps1 -ConfigPath .\config\tenants\contoso.json -ValidateOnly
   ```
3. App-Registrierung in deinem Tenant anlegen. Die Client-ID landet direkt in der Config:
   ```powershell
   .\tools\New-DeployerApp.ps1 -TenantId <Tenant-ID> -ConfigPath .\config\tenants\contoso.json
   ```
4. Probelauf mit Global Administrator oder den Rollen aus dem Abschnitt „Anmeldung im Tenant“:
   ```powershell
   .\Deploy-CABaseline.ps1 -ConfigPath .\config\tenants\contoso.json -WhatIf
   ```
5. Ausrollen:
   ```powershell
   .\Deploy-CABaseline.ps1 -ConfigPath .\config\tenants\contoso.json
   ```
6. Wenn du fertig bist, die App abschalten:
   ```powershell
   .\tools\Remove-DeployerApp.ps1 -TenantId <Tenant-ID>
   ```

Mit `-PolicyKey '1*'` rollst du einzelne Policies aus, mit `-Steps` einzelne Schritte. Jeder Lauf schreibt ein Protokoll nach `Logs/` (nicht im Repo). Prüf- und Probeläufe bekommen die Endung `-validate` bzw. `-whatif`. Die Datei entsteht gleich beim Start und wird nach jedem Eintrag gespeichert. Schließt du das Fenster mitten im Lauf, steht trotzdem alles drin, was bis dahin angelegt wurde, und der Undo funktioniert damit.

## Deployment zurücknehmen

`Undo-CABaseline.ps1` liest ein oder mehrere Protokolle und macht die Änderungen in umgekehrter Reihenfolge rückgängig:

```powershell
.\Undo-CABaseline.ps1 -ConfigPath .\config\tenants\contoso.json -LogPath .\Logs\<Protokoll>.json -WhatIf
.\Undo-CABaseline.ps1 -ConfigPath .\config\tenants\contoso.json -LogPath .\Logs\<Protokoll>.json
```

Angelegte Objekte werden gelöscht, hinzugefügte Mitgliedschaften vorher entfernt. Mitglieder einer role-assignable Group gelten als privilegiert und lassen sich mit den Rechten der App erst löschen, wenn sie nicht mehr in der Gruppe sind. Authentifizierungsmethoden und Stärken bekommen ihren vorherigen Stand zurück. Vertrauenswürdige Named Locations verlieren vor dem Löschen ihre Markierung, sonst lehnt Graph das Löschen ab. Policies und Named Locations, die es vorher schon gab und die der Lauf nur geändert hat, setzt das Skript nicht automatisch zurück. Es meldet sie, und den alten Stand findest du im Protokoll unter `Before`.

Gelöschte Gruppen, Benutzer und die AU liegen 30 Tage im Papierkorb. Mit `-Purge` entfernst du sie endgültig. Das ist in Testtenants praktisch, damit ein neuer Lauf sauber startet. Vor dem Ausführen zeigt das Skript die Liste und verlangt die Eingabe `JA`, außer du rufst es mit `-Force` auf.

## Aufbau

```
Deploy-CABaseline.ps1          Einstiegspunkt
CA-Baseline-Deployer starten.cmd  startet die Weboberfläche per Doppelklick
Start-CABaselineGui.ps1        startet die Weboberfläche
Undo-CABaseline.ps1            nimmt ein Deployment anhand seines Protokolls zurück
DISCLAIMER.md                  Haftungsausschluss
docs/Testanleitung.md          Anleitung zum Testen nur mit der Weboberfläche
config/
  tenant.example.json          Vorlage für eine Tenant-Config
  tenants/                     deine Tenant-Configs, nur lokal (.gitignore)
definitions/
  administrative-units/        Restricted Management AU für die geschützten Personas
  authentication-methods/      Passkey-Profile und AAGUID-Katalog
  authentication-strengths/    ModernMFA, Phish-resistant-MFA-Prod, Bootstrap_Recovery
  breakglass/                  Schema für neu angelegte Notfallkonten
  conditional-access/          die Policies #000 bis #502
  groups/personas.json         die sieben Persona-Gruppen
  named-locations/             Länder- und IP-Locations
gui/                           Weboberfläche (www/) und Startskript für ihre Aufträge
src/CABaseline/                PowerShell-Modul mit den einzelnen Schritten
Sources/                       Rohexporte aus dem Referenztenant und id-mapping.json
tools/
  ConvertFrom-CAExport.ps1     macht aus Exporten tenantneutrale Vorlagen
  New-DeployerApp.ps1          legt die App-Registrierung in deinem Tenant an
  Remove-DeployerApp.ps1       deaktiviert oder löscht sie wieder
  Update-AaguidCatalog.ps1     erzeugt den AAGUID-Katalog aus dem FIDO Metadata Service
  Test-CAConnection.ps1        prüft Anmeldung, aktive Rollen und Sicherheitsstandards
  Install-CAPrerequisites.ps1  prüft den Rechner und installiert fehlende Module
```

## Platzhalter

Die Vorlagen enthalten keine Objekt-IDs aus einem bestimmten Tenant. Dort stehen Platzhalter, die der Deployer im Zieltenant auflöst:

| Platzhalter | Wird zu |
|---|---|
| `{{group:Admins}}` | ID der Persona-Gruppe, Name nach `naming.groupNamePattern` |
| `{{group:AllPersonas}}` | IDs aller Persona-Gruppen aus `groups/personas.json` |
| `{{namedLocation:NL-...}}` | ID der Named Location mit diesem Namen |
| `{{authStrength:ModernMFA}}` | ID der Authentifizierungsstärke |
| `{{input:Name}}` | Wert aus `inputs` in deiner Tenant-Config |
| `{{unmapped:<GUID>}}` | nichts: der Deployer bricht für diese Policy ab, bis die ID zugeordnet ist |

Anwendungs-IDs von Microsoft (Office 365, Intune usw.) sind in allen Tenants gleich und bleiben unverändert.

## Metadaten im Block `_deployer`

Jede Vorlage beginnt mit einem Block `_deployer`. Den liest nur der Deployer, an Graph geht er nicht. Er enthält den Schlüssel, die Kategorie (Global, Admins, Internals und so weiter), ob die Policy standardmäßig ausgewählt ist, und die Eingaben, die zu deinem Tenant gehören. Die Weboberfläche nutzt dieselben Angaben.

Diese Eingaben kennst nur du:

- #210 Token Protection braucht die Namen deiner Autopilot-Enrollment-Profile. Sie werden im Gerätefilter ausgenommen. Fehlen sie in der Config, fragt der Deployer nach. Mit `-` lässt du die Liste bewusst leer.
- Trusted Networks und Corporate Sites brauchen deine öffentlichen IP-Bereiche. Bis du sie einträgst, steht dort `192.0.2.1/32` aus dem Dokumentationsbereich TEST-NET-1 (RFC 5737), weil Graph keine leere IP-Location annimmt. Der Deployer warnt, solange der Platzhalter verwendet wird.
- Die Reiseausnahme `NL-Global-Travel_Exception-Country_IP` braucht die Länder, für die Reiseausnahmen gelten. Graph lehnt eine Länder-Location ohne Länder ab, deshalb steht dort bis zur echten Angabe `DE` als Platzhalter, ebenfalls mit Warnung.

## Ablauf eines Deployments

1. Named Locations
2. Authentifizierungsstärken
3. Persona-Gruppen
4. Breakglass-Konten
5. Restricted Management AU
6. Authentifizierungsmethoden
7. Service Principals der referenzierten Microsoft-Apps
8. CA-Policies

Jeder Schritt gleicht ab, was im Tenant schon existiert, und legt nichts doppelt an. Neue Policies starten im Modus „Nur Bericht“ (`policies.stateOnCreate`). Bei Policies, die es schon gibt, lässt der Deployer den Status so, wie du ihn gesetzt hast.

Admins, Breakglass und ServiceAccounts sind role-assignable Groups. Ihre Mitglieder kann damit nur ein Privileged Role Administrator ändern. Eine Entra-Rolle weist der Deployer diesen Gruppen nicht zu.

Bei den Breakglass-Konten fragt der Deployer zuerst nach vorhandenen Konten, sofern `breakglassAccounts` in der Config leer ist. Gibt es keine, legt er `emergency_access_01` und `emergency_access_02` auf der onmicrosoft.com-Domäne an. Die Kennwörter erscheinen genau einmal in der Konsole und landen nicht im Protokoll. Danach nimmt er die Konten in die Breakglass-Gruppe auf. Rollen und eigene Breakglass-Policies kommen in einer späteren Version.

Die Restricted Management AU legt der Deployer leer an. Liegt eine Gruppe erst einmal in der AU, können tenant-weite Admins ihre Mitglieder nicht mehr ändern, auch Global Admins nicht. Nimm Admins, Breakglass und ServiceAccounts deshalb selbst auf, sobald die Mitglieder gepflegt sind. Welche Gruppen vorgesehen sind, steht im Protokoll.

Bei den Authentifizierungsmethoden fasst der Deployer nur Methoden an, die eine Stärke braucht und die im Tenant deaktiviert sind. Die schaltet er für die Persona-Gruppen ein. Ziele, die noch in der deaktivierten Methode hinterlegt waren, übernimmt er nicht. Aktivierte Methoden bleiben komplett unverändert, auch ihre Ziele. Fehlen dort Persona-Gruppen, steht das als Warnung im Protokoll. Die Registrierungskampagne rührt der Deployer nicht an. Passkeys (FIDO2) bekommt standardmäßig nur die Persona Admins (`authenticationMethods.passkeyPersonas`). Windows Hello for Business konfigurierst du in Intune. Für die zertifikatbasierte Anmeldung brauchst du eine hinterlegte Zertifizierungsstelle, deshalb prüft der Deployer dort nur und warnt.

### Passkey-Profile

Für Passkeys (FIDO2) legt der Deployer zwei Profile an, beschrieben in `definitions/authentication-methods/passkey-profiles.json`:

| Profil | Passkey-Typen | Attestierung | Erlaubte Authenticatoren | Zugewiesen an |
|---|---|---|---|---|
| Privileged User Accounts | gerätegebunden | ja | Windows Hello (Hardware, VBS, Software), Microsoft Authenticator, ausgewählte YubiKeys | Personas aus `authenticationMethods.passkeyPersonas` |
| Non-Privileged User Accounts | gerätegebunden und synchronisiert | nein | keine Einschränkung | Personas, die in der Config darauf zeigen |

Welche Persona Passkeys bekommt, steht in `authenticationMethods.passkeyPersonas`, das Profil je Persona in `authenticationMethods.passkeyProfileByPersona` (`Privileged` oder `NonPrivileged`, Standard `Privileged`). Admins bekommen immer das Profil für privilegierte Konten. Zeigt keine Persona auf das zweite Profil, liegt es nur bereit. Eine Registrierungskampagne startet der Deployer in keinem Fall.

Welche YubiKeys erlaubt sind, fragt der Deployer beim Lauf ab. Er zeigt dir dazu die YubiKey-Produkte aus dem Katalog mit ihren Firmware-Ständen. Willst du die Auswahl fest hinterlegen, trag die Produktschlüssel unter `authenticationMethods.passkeyHardwareProducts` in die Config ein, zum Beispiel `["YubiKey5SerieswithNFC"]`. Eine leere Liste bedeutet: kein YubiKey. Yubico vergibt pro Firmware-Generation eine eigene AAGUID. Ein Produkt im Katalog umfasst deshalb mehrere AAGUIDs, und ein YubiKey 5C ohne NFC ist ein anderes Produkt als der YubiKey 5 NFC.

Ein paar Regeln gelten dabei:

- Microsoft erlaubt höchstens drei Passkey-Profile, das Standardprofil mitgezählt. Ist kein Platz mehr, legt der Deployer nichts an und warnt.
- Ein Profil mit gleichem Namen bleibt unverändert. Weichen dessen AAGUIDs von der Vorlage ab, steht das als Warnung im Protokoll.
- Ist Passkey (FIDO2) schon aktiv, ergänzt der Deployer nur fehlende Profile. Ziele und deren Profilzuweisung lässt er in Ruhe und meldet, wenn eine Persona-Gruppe das vorgesehene Profil nicht hat.
- Ist der Tenant noch nicht auf Passkey-Profile umgestellt, fragt der Deployer vorher. Die Umstellung lässt sich laut Microsoft nicht zurücknehmen, auch nicht mit dem Undo. Mit `-NonInteractive` stellt er nicht um.

Den Katalog erzeugt `tools/Update-AaguidCatalog.ps1` aus dem FIDO Alliance Metadata Service (MDS). Übernommen werden nur Einträge, die dort aktuell als FIDO-zertifiziert gelten. Microsoft Authenticator steht nicht im MDS, die beiden AAGUIDs dafür kommen aus der Microsoft-Doku. Weitere Hersteller nimmst du mit `-Vendor` auf.

Manche Policies verweisen auf Microsoft-Apps, die nicht in jedem Tenant als Service Principal registriert sind, zum Beispiel „Intune Enrollment“ in #013. Der Deployer sucht alle App-IDs aus den ausgewählten Policies, registriert fehlende und vermerkt das im Protokoll. Unabhängig von der Policy-Auswahl registriert er außerdem „Microsoft Authenticator Credential Registration“ (`6aa00308-ea33-4caa-90d6-ae905d8cb51b`), die Passkeys im Authenticator braucht.

CA-Policies schreibt der Deployer über den Beta-Endpunkt von Graph, weil die Vorlagen Felder wie `agents` und `includeAgentActions` enthalten, die es in v1.0 nicht gibt.

## Anmeldung im Tenant

Das Deployment läuft interaktiv mit delegierten Rechten über eine eigene App-Registrierung in deinem Tenant. `tools/New-DeployerApp.ps1` richtet sie so ein:

- nur für diesen Tenant (Single-Tenant), öffentlicher Client ohne Secret und ohne Zertifikat
- „Zuweisung erforderlich“ aktiviert, zugewiesen bist nur du als ausführender Admin (weitere über `-AssignUsers`)
- ausschließlich delegierte Berechtigungen mit Admin-Consent: `Policy.Read.All`, `Policy.ReadWrite.ConditionalAccess`, `Policy.ReadWrite.AuthenticationMethod`, `Group.ReadWrite.All`, `User.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `AdministrativeUnit.ReadWrite.All`, `Application.ReadWrite.All`

Was der Code darf, hängt damit immer auch an deinen Rollen. Am einfachsten ist Global Administrator. Nach dem Prinzip der geringsten Rechte reichen diese Rollen, die während des Deployments aktiv sein müssen:

| Rolle | Wofür |
|---|---|
| Conditional Access Administrator | Policies, Named Locations, Authentifizierungsstärken |
| Authentication Policy Administrator | Authentifizierungsmethoden |
| Privileged Role Administrator | role-assignable Groups, deren Mitglieder, Restricted Management AU, Admin-Consent der Deployer-App |
| User Administrator | Breakglass-Konten anlegen |
| Cloud Application Administrator | Deployer-App anlegen, fehlende Service Principals registrieren |

App-only-Zugriff mit Zertifikat ist absichtlich nicht vorgesehen. Die Anwendungsberechtigung `RoleManagement.ReadWrite.Directory` würde jedem, der das Zertifikat besitzt, dauerhaft den Weg zum Global Admin öffnen. Außerdem greifen Anwendungsberechtigungen laut Microsoft nicht auf Objekte in einer Restricted Management AU.

## Voraussetzungen

- PowerShell 7.2 oder neuer
- Modul `Microsoft.Graph.Authentication`. `tools/Install-CAPrerequisites.ps1` prüft deinen Rechner und installiert das Modul mit `-Install` für deinen Benutzer, ohne Administratorrechte. Bei Problemen mit Proxy, Ausführungsrichtlinie oder Modulordner nennt es Ursache und Lösung.
- Entra ID P1 (dynamische Gruppe für Gäste, role-assignable Groups, Restricted Management AU), für die risikobasierten Policies P2

## Neue Exporte übernehmen

```powershell
.\tools\ConvertFrom-CAExport.ps1 -SourcePath .\Sources -MappingFile .\Sources\id-mapping.json -OutputPath .\definitions
```

Der Konverter überschreibt die Vorlagen im Zielordner. Korrekturen, die du danach in `definitions` gemacht hast, gehen dabei verloren. Konvertier einen neuen Export deshalb in einen leeren Ordner und übernimm die Unterschiede einzeln.

# CA Baseline Deployer

Mit diesem Repo wird ein Conditional-Access-Framework für Entra ID per Code in Kundentenants ausgerollt. Dazu gehören Persona-Gruppen, Breakglass-Konten, eine Restricted Management Administrative Unit, Named Locations, Authentifizierungsstärken und die CA-Policies selbst. Die Authentifizierungsmethoden ergänzt der Deployer nur so weit, wie die Stärken sie brauchen.

> Die Nutzung erfolgt auf eigene Verantwortung. Vor dem Einsatz bitte den [Haftungsausschluss](DISCLAIMER.md) lesen. CA-Policies können bei falscher Konfiguration alle Benutzer eines Tenants aussperren, deshalb gehört vor jedem produktiven Einsatz ein Durchlauf in einem Testtenant dazu.

## Weboberfläche

```powershell
.\Start-CABaselineGui.ps1
```

Die Oberfläche führt in 13 Schritten durch das ganze Deployment: Voraussetzungen prüfen und fehlende Module installieren, Tenant erfassen, App-Registrierung anlegen, Anmeldung prüfen, Persona-Gruppen benennen, Named Locations, Auswahl der Policies, Authentifizierungsmethoden und Passkeys, Breakglass-Konten, Offline-Prüfung und Probelauf, Ausrollen und Zurücknehmen. Zu jedem Schritt steht dabei, worum es geht, was der Deployer macht und was vorher erledigt sein muss. Die Seitenleiste zeigt, welche Schritte vollständig sind und wo noch etwas fehlt.

Weiter als bis zur Startseite geht es erst, wenn du den Haftungsausschluss bestätigt hast.

Was die Oberfläche über die Vorlagen hinaus anbietet:

- Zusätzliche Personas. Für sie legt der Deployer nur eine Entra-Sicherheitsgruppe an. Keine CA-Policy verweist auf sie, und es entstehen keine neuen Policies. Eine zusätzliche Persona kann als Sub-Persona genau einer Haupt-Persona zugeordnet sein, etwa VIP unter Internals. Ihr Gruppenname wird dann aus beiden gebildet (`SG-CA-Persona-Internals-VIP`). Steht in der Config unter `personas.additional`.
- Role-assignable je Persona. Vorausgewählt ist die Empfehlung aus `groups/personas.json`. Wer sie abwählt, bekommt einen Hinweis. Das Flag lässt sich an einer bestehenden Gruppe nicht mehr ändern. Steht unter `personas.roleAssignable`.
- Eigene Named Locations mit einem Namen nach dem Schema `NL-<Persona>-<Zweck>-<Typ>`. IP-Bereiche lassen sich aus einer Text- oder CSV-Datei importieren. Steht unter `namedLocations.custom`.
- Import der IP-Bereiche von Zscaler als `NL-Global-ZScaler_Ranges-IP`. Die Liste kommt von `config.zscaler.com` (empfohlene Hub-Bereiche der gewählten Cloud). Der Deployer holt sie bei jedem Lauf neu ab und schreibt ins Protokoll, was sich seit dem Import geändert hat. Ist Zscaler nicht erreichbar, nimmt er den gespeicherten Stand und warnt.

Ein paar Dinge zum Betrieb:

- Der Server lauscht nur auf `localhost` und verlangt ein zufälliges Token, das in der geöffneten Adresse steht. Die Adresse also nicht weitergeben.
- Alles, was die Oberfläche einstellt, landet sofort in `config/tenants/<kunde>.json`. Die Skripte auf der Kommandozeile lesen dieselbe Datei.
- Deployment, Undo, App-Registrierung und Rollenprüfung laufen als eigene `pwsh`-Prozesse im Konsolenfenster des Servers. Die Microsoft-Anmeldung erscheint deshalb über diesem Fenster, die Ausgabe live im Browser.
- Rückfragen gibt es dabei keine. Was der Deployer auf der Kommandozeile fragen würde, steht vorher in der Config. Das betrifft auch die Umstellung auf Passkey-Profile (`authenticationMethods.migrateToPasskeyProfiles`) und bewusst leere Kundeneingaben (`"-"`).
- Kennwörter neuer Breakglass-Konten zeigt die Oberfläche genau einmal in einem eigenen Fenster. Der Server hält sie nur im Speicher, bis der Browser sie abgeholt hat.
- Eingaben werden geprüft, bevor sie in der Config landen. Kopierfehler wie Leerzeichen am Rand, Anführungszeichen oder unsichtbare Zeichen bereinigt die Oberfläche selbst. IP-Bereiche prüft sie auf die Regeln von Entra (nur öffentliche Adressen, Präfix größer als /8, höchstens 2000 Bereiche). Länder werden aus einer Liste angeklickt.
- Die Oberfläche lädt keine Skripte oder Schriften aus dem Internet nach. Ins Internet geht sie nur für die Anmeldung, die Prüfung der Voraussetzungen, die Installation des Graph-Moduls, den Abruf des AAGUID-Katalogs, den Abruf der Zscaler-Bereiche und den Abgleich von Tenant-ID und Domäne. Beim Abgleich wird nur der Domänenname an den öffentlichen Anmeldedienst von Microsoft geschickt.

## Schnellstart auf der Kommandozeile

1. Config anlegen: `config/tenant.example.json` nach `config/tenants/<kunde>.json` kopieren und ausfüllen.
2. Offline prüfen:
   ```powershell
   .\Deploy-CABaseline.ps1 -ConfigPath .\config\tenants\kunde.json -ValidateOnly
   ```
3. App-Registrierung im Kundentenant anlegen, die Client-ID landet direkt in der Config:
   ```powershell
   .\tools\New-DeployerApp.ps1 -TenantId <Tenant-ID> -ConfigPath .\config\tenants\kunde.json
   ```
4. Mit Global Administrator oder den Rollen aus dem Abschnitt „Anmeldung im Tenant“ einen Probelauf machen:
   ```powershell
   .\Deploy-CABaseline.ps1 -ConfigPath .\config\tenants\kunde.json -WhatIf
   ```
5. Ausrollen:
   ```powershell
   .\Deploy-CABaseline.ps1 -ConfigPath .\config\tenants\kunde.json
   ```
6. Nach Projektende die App abschalten:
   ```powershell
   .\tools\Remove-DeployerApp.ps1 -TenantId <Tenant-ID>
   ```

Mit `-PolicyKey '1*'` lassen sich einzelne Policies ausrollen, mit `-Steps` einzelne Schritte. Jeder Lauf schreibt ein Protokoll nach `Logs/` (nicht im Repo). Prüf- und Probeläufe bekommen die Endung `-validate` bzw. `-whatif`. Die Datei entsteht gleich beim Start und wird nach jedem Eintrag gespeichert. Wird das Fenster mitten im Lauf geschlossen, steht trotzdem alles drin, was bis dahin angelegt wurde, und der Undo funktioniert damit.

## Deployment zurücknehmen

`Undo-CABaseline.ps1` liest ein oder mehrere Protokolle und macht die Änderungen in umgekehrter Reihenfolge rückgängig:

```powershell
.\Undo-CABaseline.ps1 -ConfigPath .\config\tenants\kunde.json -LogPath .\Logs\<Protokoll>.json -WhatIf
.\Undo-CABaseline.ps1 -ConfigPath .\config\tenants\kunde.json -LogPath .\Logs\<Protokoll>.json
```

Angelegte Objekte werden gelöscht, hinzugefügte Mitgliedschaften vorher entfernt. Das ist nötig, weil Mitglieder einer role-assignable Group als privilegiert gelten und sich mit den Rechten der App erst löschen lassen, wenn sie nicht mehr in der Gruppe sind. Authentifizierungsmethoden und Stärken bekommen ihren vorherigen Stand zurück. Vertrauenswürdige Named Locations verlieren vor dem Löschen ihre Markierung, sonst lehnt Graph das Löschen ab. Policies und Named Locations, die es vorher schon gab und die der Lauf nur geändert hat, setzt das Skript nicht automatisch zurück; es meldet sie, und der alte Stand steht im Protokoll unter `Before`.

Gelöschte Gruppen, Benutzer und die AU liegen 30 Tage im Papierkorb. Mit `-Purge` werden sie endgültig entfernt, was für Testtenants praktisch ist, damit ein neuer Lauf sauber startet. Vor dem Ausführen zeigt das Skript die Liste und verlangt die Eingabe `JA`.

## Aufbau

```
Deploy-CABaseline.ps1          Einstiegspunkt
Start-CABaselineGui.ps1        startet die Weboberfläche
Undo-CABaseline.ps1            nimmt ein Deployment anhand seines Protokolls zurück
DISCLAIMER.md                  Haftungsausschluss
config/
  tenant.example.json          Vorlage für eine Kunden-Config
  tenants/                     echte Kunden-Configs, nur lokal (.gitignore)
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
  New-DeployerApp.ps1          legt die App-Registrierung im Kundentenant an
  Update-AaguidCatalog.ps1     erzeugt den AAGUID-Katalog aus dem FIDO Metadata Service
  Test-CAConnection.ps1        prüft Anmeldung, aktive Rollen und Sicherheitsstandards
  Install-CAPrerequisites.ps1  prüft den Rechner und installiert fehlende Module
  Remove-DeployerApp.ps1       deaktiviert oder löscht sie wieder
```

## Platzhalter

Die Vorlagen enthalten keine Objekt-IDs aus einem bestimmten Tenant. Stattdessen stehen dort Platzhalter, die der Deployer im Zieltenant auflöst:

| Platzhalter | Wird zu |
|---|---|
| `{{group:Admins}}` | ID der Persona-Gruppe, Name nach `naming.groupNamePattern` |
| `{{group:AllPersonas}}` | IDs aller Persona-Gruppen aus `groups/personas.json` |
| `{{namedLocation:NL-...}}` | ID der Named Location mit diesem Namen |
| `{{authStrength:ModernMFA}}` | ID der Authentifizierungsstärke |
| `{{input:Name}}` | Wert aus `inputs` in der Kunden-Config |
| `{{unmapped:<GUID>}}` | nichts: der Deployer bricht für diese Policy ab, bis die ID zugeordnet ist |

Anwendungs-IDs von Microsoft (Office 365, Intune usw.) sind in allen Tenants gleich und bleiben unverändert.

## Metadaten im Block `_deployer`

Jede Vorlage beginnt mit einem Block `_deployer`. Den liest nur der Deployer, an Graph geht er nicht. Er enthält den Schlüssel, die Kategorie (Global, Admins, Internals und so weiter), ob die Policy standardmäßig ausgewählt ist, und die Kundeneingaben. Eine spätere Oberfläche zur Auswahl der Policies soll dieselben Angaben nutzen.

Kundeneingaben sind Werte, die nur der Kunde kennt:

- #210 Token Protection braucht die Namen der Autopilot-Enrollment-Profile. Sie werden im Gerätefilter ausgenommen. Fehlen sie in der Config, fragt der Deployer nach; mit `-` lässt sich die Liste bewusst leer lassen.
- Trusted Networks und Corporate Sites brauchen die öffentlichen IP-Bereiche. Bis sie eingetragen sind, steht dort `192.0.2.1/32` aus dem Dokumentationsbereich TEST-NET-1 (RFC 5737), weil Graph keine leere IP-Location annimmt. Der Deployer warnt, solange der Platzhalter verwendet wird.
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

Jeder Schritt gleicht ab, was im Tenant schon existiert, und legt nichts doppelt an. Neue Policies starten im Modus „Nur Bericht“ (`policies.stateOnCreate`). Bei Policies, die es schon gibt, lässt der Deployer den Status so, wie der Kunde ihn gesetzt hat.

Admins, Breakglass und ServiceAccounts sind role-assignable Groups. Damit können nur Privileged Role Administrators ihre Mitglieder ändern. Eine Entra-Rolle weist der Deployer diesen Gruppen nicht zu.

Bei den Breakglass-Konten fragt der Deployer zuerst nach vorhandenen Konten, sofern `breakglassAccounts` in der Config leer ist. Gibt es keine, legt er `emergency_access_01` und `emergency_access_02` auf der onmicrosoft.com-Domäne an. Die Kennwörter erscheinen genau einmal in der Konsole und landen nicht im Protokoll. Danach nimmt er die Konten in die Breakglass-Gruppe auf. Rollen und eigene Breakglass-Policies kommen in einer späteren Version.

Die Restricted Management AU legt der Deployer leer an. Liegt eine Gruppe erst einmal in der AU, können tenant-weite Admins ihre Mitglieder nicht mehr ändern, auch Global Admins nicht. Der Kunde nimmt Admins, Breakglass und ServiceAccounts deshalb selbst auf, sobald die Mitglieder gepflegt sind. Welche Gruppen vorgesehen sind, steht im Protokoll.

Bei den Authentifizierungsmethoden fasst der Deployer nur Methoden an, die eine Stärke braucht und die im Tenant deaktiviert sind. Die schaltet er für die Persona-Gruppen ein; Ziele, die noch in der deaktivierten Methode hinterlegt waren, übernimmt er nicht. Aktivierte Methoden bleiben komplett unverändert, auch ihre Ziele. Fehlen dort Persona-Gruppen, steht das als Warnung im Protokoll. Die Registrierungskampagne rührt der Deployer nicht an. Passkeys (FIDO2) bekommt nur die Persona Admins (`authenticationMethods.passkeyPersonas`). Windows Hello for Business wird in Intune konfiguriert. Für die zertifikatbasierte Anmeldung braucht der Kunde eine hinterlegte Zertifizierungsstelle, deshalb prüft der Deployer dort nur und warnt.

### Passkey-Profile

Für Passkeys (FIDO2) legt der Deployer zwei Profile an, beschrieben in `definitions/authentication-methods/passkey-profiles.json`:

| Profil | Passkey-Typen | Attestierung | Erlaubte Authenticatoren | Zugewiesen an |
|---|---|---|---|---|
| Privileged User Accounts | gerätegebunden | ja | Windows Hello (Hardware, VBS, Software), Microsoft Authenticator, ausgewählte YubiKeys | Personas aus `authenticationMethods.passkeyPersonas` |
| Non-Privileged User Accounts | gerätegebunden und synchronisiert | nein | keine Einschränkung | Personas, die in der Config darauf zeigen |

Welche Persona Passkeys bekommt, steht in `authenticationMethods.passkeyPersonas`, das Profil je Persona in `authenticationMethods.passkeyProfileByPersona` (`Privileged` oder `NonPrivileged`, Standard `Privileged`). Admins bekommen immer das Profil für privilegierte Konten. Zeigt keine Persona auf das zweite Profil, liegt es nur bereit. Eine Registrierungskampagne startet der Deployer in keinem Fall.

Welche YubiKeys erlaubt sind, fragt der Deployer beim Lauf ab. Er zeigt dazu die YubiKey-Produkte aus dem Katalog mit ihren Firmware-Ständen. Wer die Auswahl fest hinterlegen will, trägt die Produktschlüssel unter `authenticationMethods.passkeyHardwareProducts` in die Config ein, zum Beispiel `["YubiKey5SerieswithNFC"]`. Eine leere Liste bedeutet: kein YubiKey. Yubico vergibt pro Firmware-Generation eine eigene AAGUID. Ein Produkt im Katalog umfasst deshalb mehrere AAGUIDs, und ein YubiKey 5C ohne NFC ist ein anderes Produkt als der YubiKey 5 NFC.

Ein paar Regeln gelten dabei:

- Microsoft erlaubt höchstens drei Passkey-Profile, das Standardprofil mitgezählt. Ist kein Platz mehr, legt der Deployer nichts an und warnt.
- Ein Profil mit gleichem Namen bleibt unverändert. Weichen dessen AAGUIDs von der Vorlage ab, steht das als Warnung im Protokoll.
- Ist Passkey (FIDO2) schon aktiv, ergänzt der Deployer nur fehlende Profile. Ziele und deren Profilzuweisung lässt er in Ruhe und meldet, wenn eine Persona-Gruppe das vorgesehene Profil nicht hat.
- Ist der Tenant noch nicht auf Passkey-Profile umgestellt, fragt der Deployer vorher. Die Umstellung lässt sich laut Microsoft nicht zurücknehmen, auch nicht mit dem Undo. Mit `-NonInteractive` stellt er nicht um.

Den Katalog erzeugt `tools/Update-AaguidCatalog.ps1` aus dem FIDO Alliance Metadata Service (MDS). Übernommen werden nur Einträge, die dort aktuell als FIDO-zertifiziert gelten. Microsoft Authenticator steht nicht im MDS, die beiden AAGUIDs dafür kommen aus der Microsoft-Doku. Weitere Hersteller lassen sich mit `-Vendor` aufnehmen.

Manche Policies verweisen auf Microsoft-Apps, die nicht in jedem Tenant als Service Principal registriert sind, zum Beispiel „Intune Enrollment“ in #013. Der Deployer sucht alle App-IDs aus den ausgewählten Policies, registriert fehlende und vermerkt das im Protokoll. Unabhängig von der Policy-Auswahl registriert er außerdem „Microsoft Authenticator Credential Registration“ (`6aa00308-ea33-4caa-90d6-ae905d8cb51b`), die Passkeys im Authenticator braucht.

CA-Policies schreibt der Deployer über den Beta-Endpunkt von Graph, weil die Vorlagen Felder wie `agents` und `includeAgentActions` enthalten, die es in v1.0 nicht gibt.

## Anmeldung im Kundentenant

Das Deployment läuft interaktiv mit delegierten Rechten über eine eigene App-Registrierung im Kundentenant. `tools/New-DeployerApp.ps1` richtet sie so ein:

- nur für diesen Tenant (Single-Tenant), öffentlicher Client ohne Secret und ohne Zertifikat
- „Zuweisung erforderlich“ aktiviert, zugewiesen ist nur der Admin, der das Skript ausführt (weitere über `-AssignUsers`)
- ausschließlich delegierte Berechtigungen mit Admin-Consent: `Policy.Read.All`, `Policy.ReadWrite.ConditionalAccess`, `Policy.ReadWrite.AuthenticationMethod`, `Group.ReadWrite.All`, `User.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `AdministrativeUnit.ReadWrite.All`, `Application.ReadWrite.All`

Was der Code darf, hängt damit immer auch an den Rollen des angemeldeten Admins. Am einfachsten ist Global Administrator. Nach dem Prinzip der geringsten Rechte reichen diese Rollen, die während des Deployments aktiv sein müssen:

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
- Modul `Microsoft.Graph.Authentication`. `tools/Install-CAPrerequisites.ps1` prüft den Rechner und installiert das Modul mit `-Install` für den aktuellen Benutzer, ohne Administratorrechte. Bei Problemen mit Proxy, Ausführungsrichtlinie oder Modulordner nennt es Ursache und Lösung.
- Entra ID P1 (dynamische Gruppe für Gäste, role-assignable Groups, Restricted Management AU); für die risikobasierten Policies P2

## Neue Exporte übernehmen

```powershell
.\tools\ConvertFrom-CAExport.ps1 -SourcePath .\Sources -MappingFile .\Sources\id-mapping.json -OutputPath .\definitions
```

Der Konverter überschreibt die Vorlagen im Zielordner. Korrekturen, die danach in `definitions` gemacht wurden, gehen dabei verloren. Bei einem neuen Export deshalb in einen leeren Ordner konvertieren und die Unterschiede einzeln übernehmen.

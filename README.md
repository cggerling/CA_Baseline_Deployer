# CA Baseline Deployer

Mit diesem Repo wird ein Conditional-Access-Framework für Entra ID per Code in Kundentenants ausgerollt. Dazu gehören Persona-Gruppen, Breakglass-Konten, eine Restricted Management Administrative Unit, Named Locations, Authentifizierungsstärken und die CA-Policies selbst. Die Authentifizierungsmethoden ergänzt der Deployer nur so weit, wie die Stärken sie brauchen.

> Die Nutzung erfolgt auf eigene Verantwortung. Vor dem Einsatz bitte den [Haftungsausschluss](DISCLAIMER.md) lesen. CA-Policies können bei falscher Konfiguration alle Benutzer eines Tenants aussperren, deshalb gehört vor jedem produktiven Einsatz ein Durchlauf in einem Testtenant dazu.

## Schnellstart

1. Config anlegen: `config/tenant.example.json` nach `config/tenants/<kunde>.json` kopieren und ausfüllen.
2. Offline prüfen:
   ```powershell
   .\Deploy-CABaseline.ps1 -ConfigPath .\config\tenants\kunde.json -ValidateOnly
   ```
3. App-Registrierung im Kundentenant anlegen, die Client-ID landet direkt in der Config:
   ```powershell
   .\tools\New-DeployerApp.ps1 -TenantId <Tenant-ID> -ConfigPath .\config\tenants\kunde.json
   ```
4. Rollen per PIM aktivieren (siehe unten) und einen Probelauf machen:
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

Mit `-PolicyKey '1*'` lassen sich einzelne Policies ausrollen, mit `-Steps` einzelne Schritte. Jeder Lauf schreibt ein Protokoll nach `Logs/` (nicht im Repo). Die Datei entsteht gleich beim Start und wird nach jedem Eintrag gespeichert. Wird das Fenster mitten im Lauf geschlossen, steht trotzdem alles drin, was bis dahin angelegt wurde, und der Undo funktioniert damit.

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
Undo-CABaseline.ps1            nimmt ein Deployment anhand seines Protokolls zurück
DISCLAIMER.md                  Haftungsausschluss
config/
  tenant.example.json          Vorlage für eine Kunden-Config
  tenants/                     echte Kunden-Configs, nur lokal (.gitignore)
definitions/
  administrative-units/        Restricted Management AU für die geschützten Personas
  authentication-strengths/    ModernMFA, Phish-resistant-MFA-Prod, Bootstrap_Recovery
  breakglass/                  Schema für neu angelegte Notfallkonten
  conditional-access/          die Policies #000 bis #502
  groups/personas.json         die sieben Persona-Gruppen
  named-locations/             Länder- und IP-Locations
src/CABaseline/                PowerShell-Modul mit den einzelnen Schritten
Sources/                       Rohexporte aus dem Referenztenant und id-mapping.json
tools/
  ConvertFrom-CAExport.ps1     macht aus Exporten tenantneutrale Vorlagen
  New-DeployerApp.ps1          legt die App-Registrierung im Kundentenant an
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

Manche Policies verweisen auf Microsoft-Apps, die nicht in jedem Tenant als Service Principal registriert sind, zum Beispiel „Intune Enrollment“ in #013. Der Deployer sucht alle App-IDs aus den ausgewählten Policies, registriert fehlende und vermerkt das im Protokoll.

CA-Policies schreibt der Deployer über den Beta-Endpunkt von Graph, weil die Vorlagen Felder wie `agents` und `includeAgentActions` enthalten, die es in v1.0 nicht gibt.

## Anmeldung im Kundentenant

Das Deployment läuft interaktiv mit delegierten Rechten über eine eigene App-Registrierung im Kundentenant. `tools/New-DeployerApp.ps1` richtet sie so ein:

- nur für diesen Tenant (Single-Tenant), öffentlicher Client ohne Secret und ohne Zertifikat
- „Zuweisung erforderlich“ aktiviert, zugewiesen ist nur der Admin, der das Skript ausführt (weitere über `-AssignUsers`)
- ausschließlich delegierte Berechtigungen mit Admin-Consent: `Policy.Read.All`, `Policy.ReadWrite.ConditionalAccess`, `Policy.ReadWrite.AuthenticationMethod`, `Group.ReadWrite.All`, `User.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `AdministrativeUnit.ReadWrite.All`, `Application.ReadWrite.All`

Was der Code darf, hängt damit immer auch an den Rollen des angemeldeten Admins. Für das Deployment werden sie per PIM aktiviert:

| Rolle | Wofür |
|---|---|
| Conditional Access Administrator | Policies, Named Locations, Authentifizierungsstärken |
| Authentication Policy Administrator | Authentifizierungsmethoden |
| Privileged Role Administrator | role-assignable Groups, deren Mitglieder, Restricted Management AU |
| User Administrator | Breakglass-Konten anlegen |
| Cloud Application Administrator | fehlende Service Principals registrieren |

App-only-Zugriff mit Zertifikat ist absichtlich nicht vorgesehen. Die Anwendungsberechtigung `RoleManagement.ReadWrite.Directory` würde jedem, der das Zertifikat besitzt, dauerhaft den Weg zum Global Admin öffnen. Außerdem greifen Anwendungsberechtigungen laut Microsoft nicht auf Objekte in einer Restricted Management AU.

## Voraussetzungen

- PowerShell 7.2 oder neuer
- Modul `Microsoft.Graph.Authentication`
- Entra ID P1 (dynamische Gruppe für Gäste, role-assignable Groups, Restricted Management AU); für die risikobasierten Policies P2

## Neue Exporte übernehmen

```powershell
.\tools\ConvertFrom-CAExport.ps1 -SourcePath .\Sources -MappingFile .\Sources\id-mapping.json -OutputPath .\definitions
```

Der Konverter überschreibt die Vorlagen im Zielordner. Korrekturen, die danach in `definitions` gemacht wurden, gehen dabei verloren. Bei einem neuen Export deshalb in einen leeren Ordner konvertieren und die Unterschiede einzeln übernehmen.

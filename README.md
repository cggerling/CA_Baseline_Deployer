# CA Baseline Deployer

Mit diesem Repo wird ein Conditional-Access-Framework für Entra ID per Code in Kundentenants ausgerollt. Dazu gehören die Persona-Gruppen, eine Restricted Management Administrative Unit, Named Locations, Authentifizierungsstärken und die CA-Policies selbst. Die Authentifizierungsmethoden prüft der Deployer nur so weit, wie die Stärken sie brauchen.

> Stand: Vorlagen, Gruppen- und AU-Definitionen sowie die Config-Vorlage sind fertig. Das eigentliche Deployment-Skript (`Deploy-CABaseline.ps1`) und die Skripte für die App-Registrierung entstehen als Nächstes.

## Aufbau

```
config/
  tenant.example.json          Vorlage für eine Kunden-Config
  tenants/                     echte Kunden-Configs, nur lokal (.gitignore)
definitions/
  administrative-units/        Restricted Management AU für die geschützten Personas
  authentication-strengths/    ModernMFA, Phish-resistant-MFA-Prod, Bootstrap_Recovery
  conditional-access/          die Policies #000 bis #502
  groups/personas.json         die sieben Persona-Gruppen
  named-locations/             Länder- und IP-Locations
Sources/                       Rohexporte aus dem Referenztenant und id-mapping.json
tools/
  ConvertFrom-CAExport.ps1     macht aus Exporten tenantneutrale Vorlagen
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
| `{{unmapped:<GUID>}}` | nichts: der Deployer bricht ab, bis die ID zugeordnet ist |

Anwendungs-IDs von Microsoft (Office 365, Intune usw.) sind in allen Tenants gleich und bleiben unverändert.

## Metadaten im Block `_deployer`

Jede Vorlage beginnt mit einem Block `_deployer`. Den liest nur der Deployer, an Graph geht er nicht. Er enthält den Schlüssel, die Kategorie (Global, Admins, Internals und so weiter), ob die Policy standardmäßig ausgewählt ist, und die Kundeneingaben. Eine spätere Oberfläche zur Auswahl der Policies soll dieselben Angaben nutzen.

Kundeneingaben sind Werte, die nur der Kunde kennt, zum Beispiel:

- #210 Token Protection: die Namen der Autopilot-Enrollment-Profile. Sie werden im Gerätefilter ausgenommen. Ohne Angabe fragt der Deployer nach.
- Trusted Networks und Corporate Sites: die öffentlichen IP-Bereiche. Bis sie eingetragen sind, steht dort `192.0.2.1/32` aus dem Dokumentationsbereich TEST-NET-1 (RFC 5737), weil Graph keine leere IP-Location annimmt. Der Deployer warnt, solange der Platzhalter verwendet wird.

## Ablauf eines Deployments

1. Named Locations
2. Authentifizierungsstärken
3. Persona-Gruppen
4. Breakglass-Konten in ihre Gruppe aufnehmen
5. Restricted Management AU anlegen und die geschützten Gruppen hinzufügen
6. Authentifizierungsmethoden prüfen und bei Bedarf ergänzen
7. CA-Policies

Jeder Schritt gleicht ab, was im Tenant schon existiert, und legt nichts doppelt an. Neue Policies starten im Modus „Nur Bericht“ (`enabledForReportingButNotEnforced`). Mit `-WhatIf` lässt sich vorher ansehen, was passieren würde.

Die Breakglass-Konten kommen vor der AU dran. Liegt eine Gruppe erst einmal in der Restricted Management AU, können tenant-weite Admins ihre Mitglieder nicht mehr ändern, auch Global Admins nicht.

Schritt 6 ist additiv. Er schaltet nur Methoden frei, die eine verwendete Stärke braucht und die im Tenant fehlen. Er deaktiviert nichts, entfernt keine Ziele und rührt die Registrierungskampagne nicht an. Passkeys (FIDO2) werden nur für die Persona Admins freigeschaltet. Windows Hello for Business wird in Intune konfiguriert, für die zertifikatbasierte Anmeldung braucht der Kunde eine hinterlegte Zertifizierungsstelle. Bei beiden prüft der Deployer nur und warnt. Die komplette Methodenrichtlinie auszurollen bleibt optional (`authenticationMethods.deployFullPolicy`).

## Anmeldung im Kundentenant

Das Deployment läuft interaktiv mit delegierten Rechten. Im Kundentenant wird dafür eine eigene App-Registrierung angelegt:

- nur für diesen Tenant (Single-Tenant), als öffentlicher Client ohne Secret und ohne Zertifikat
- „Zuweisung erforderlich“ aktiviert, zugewiesen sind nur die Admins, die deployen
- ausschließlich delegierte Berechtigungen mit Admin-Consent: `Policy.ReadWrite.ConditionalAccess`, `Policy.ReadWrite.AuthenticationMethod`, `Policy.Read.All`, `Group.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `AdministrativeUnit.ReadWrite.All`, `Application.Read.All`
- nach dem Projekt wird die App deaktiviert oder gelöscht

Was der Code darf, hängt damit immer auch an den Rollen des angemeldeten Admins. Diese werden per PIM nur für das Deployment aktiviert: Conditional Access Administrator, Authentication Policy Administrator und Privileged Role Administrator. Die letzte Rolle ist für role-assignable Groups und die Restricted Management AU nötig.

App-only-Zugriff mit Zertifikat kommt bewusst nicht zum Einsatz. Die Anwendungsberechtigung `RoleManagement.ReadWrite.Directory` würde jedem, der das Zertifikat besitzt, dauerhaft den Weg zum Global Admin öffnen. Außerdem greifen Anwendungsberechtigungen laut Microsoft nicht auf Objekte in einer Restricted Management AU.

## Voraussetzungen

- PowerShell 7.2 oder neuer
- Modul `Microsoft.Graph.Authentication`
- Entra ID P1 (dynamische Gruppe für Gäste, role-assignable Groups, Restricted Management AU); für die risikobasierten Policies P2

## Neue Exporte übernehmen

```powershell
.\tools\ConvertFrom-CAExport.ps1 -SourcePath .\Sources -MappingFile .\Sources\id-mapping.json -OutputPath .\definitions
```

Der Konverter überschreibt die Vorlagen im Zielordner. Korrekturen, die danach in `definitions` gemacht wurden, gehen dabei verloren. Bei einem neuen Export deshalb in einen leeren Ordner konvertieren und die Unterschiede einzeln übernehmen.

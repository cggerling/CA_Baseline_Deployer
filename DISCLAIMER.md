# Haftungsausschluss

Dieses Repository und alle darin enthaltenen Skripte, Vorlagen und Anleitungen stelle ich ohne Gewähr bereit. Wenn du sie einsetzt, tust du das auf eigene Verantwortung.

## Keine Gewährleistung

Für Richtigkeit, Vollständigkeit, Aktualität und Eignung für einen bestimmten Zweck übernehme ich keine Gewähr. Microsoft ändert Entra ID, Microsoft Graph und die Beta-Endpunkte laufend. Ein Skript, das heute funktioniert, kann morgen andere Ergebnisse liefern oder Fehler auslösen.

## Haftung

Soweit gesetzlich zulässig, ist die Haftung für Schäden aus der Nutzung ausgeschlossen. Das gilt insbesondere für ausgesperrte Konten, unterbrochene Anmeldungen, Datenverlust, Betriebsunterbrechungen und Folgeschäden. Unberührt bleibt die Haftung für Vorsatz und grobe Fahrlässigkeit sowie für Schäden aus der Verletzung von Leben, Körper oder Gesundheit.

## Risiken beim Einsatz

Conditional-Access-Policies greifen direkt in die Anmeldung aller Benutzer eines Tenants ein. Eine falsch konfigurierte Policy kann Administratoren und Benutzer vollständig aussperren. Der Deployer legt neue Policies deshalb im Modus „Nur Bericht“ an. Bevor du eine Policy einschaltest, prüf sie mit den Anmeldeprotokollen und dem What-If-Werkzeug in Entra ID.

Bevor du das Tool in einem produktiven Tenant einsetzt, solltest du Folgendes erledigt haben:

- einen vollständigen Durchlauf in einem Testtenant, zuerst mit `-WhatIf`
- funktionierende Breakglass-Konten, die von den Policies ausgenommen sind und deren Anmeldung überwacht wird
- eine Sicherung der bestehenden Konfiguration, damit du den vorherigen Stand wiederherstellen kannst
- die Freigabe durch die Person, die für den Tenant verantwortlich ist

`Undo-CABaseline.ps1` nimmt nur zurück, was im Protokoll steht. Was du nach dem Deployment von Hand geändert hast, kennt das Skript nicht.

## Deine Verantwortung

Für die Lizenzierung (Entra ID P1 oder P2), die Einhaltung interner Richtlinien, den Datenschutz und regulatorische Vorgaben bist du als Betreiber des Tenants verantwortlich. Die Vorlagen sind ein Ausgangspunkt, den du an deine Umgebung anpassen musst. Eine Sicherheitsbewertung oder Rechtsberatung ersetzen sie nicht.

## Marken

Dies ist kein Produkt von Microsoft und wird von Microsoft weder unterstützt noch geprüft. Microsoft, Entra ID, Intune und Microsoft Graph sind Marken der Microsoft Corporation.

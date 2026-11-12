# Haftungsausschluss

Dieses Repository und alle darin enthaltenen Skripte, Vorlagen und Anleitungen werden ohne Gewähr bereitgestellt. Wer sie einsetzt, tut das auf eigene Verantwortung.

## Keine Gewährleistung

Für Richtigkeit, Vollständigkeit, Aktualität und Eignung für einen bestimmten Zweck wird keine Gewähr übernommen. Microsoft ändert Entra ID, Microsoft Graph und die Beta-Endpunkte laufend. Ein Skript, das heute funktioniert, kann morgen andere Ergebnisse liefern oder Fehler auslösen.

## Haftung

Soweit gesetzlich zulässig, ist die Haftung für Schäden aus der Nutzung ausgeschlossen. Das gilt insbesondere für ausgesperrte Konten, unterbrochene Anmeldungen, Datenverlust, Betriebsunterbrechungen und Folgeschäden. Unberührt bleibt die Haftung für Vorsatz und grobe Fahrlässigkeit sowie für Schäden aus der Verletzung von Leben, Körper oder Gesundheit.

## Risiken beim Einsatz

Conditional-Access-Policies greifen direkt in die Anmeldung aller Benutzer eines Tenants ein. Eine falsch konfigurierte Policy kann Administratoren und Benutzer vollständig aussperren. Der Deployer legt neue Policies deshalb im Modus „Nur Bericht“ an. Vor dem Einschalten muss jede Policy mit den Anmeldeprotokollen und dem What-If-Werkzeug in Entra ID geprüft werden.

Vor dem Einsatz in einem produktiven Tenant gehören dazu:

- ein vollständiger Durchlauf in einem Testtenant, zuerst mit `-WhatIf`
- funktionierende Breakglass-Konten, die von den Policies ausgenommen sind und deren Anmeldung überwacht wird
- eine Sicherung der bestehenden Konfiguration, damit sich der vorherige Stand wiederherstellen lässt
- die Freigabe durch den Verantwortlichen des Tenants

`Undo-CABaseline.ps1` nimmt nur zurück, was im Protokoll steht. Änderungen, die nach dem Deployment von Hand gemacht wurden, kennt das Skript nicht.

## Verantwortung des Betreibers

Für die Lizenzierung (Entra ID P1 oder P2), die Einhaltung interner Richtlinien, den Datenschutz und regulatorische Vorgaben ist der Betreiber des jeweiligen Tenants verantwortlich. Die Vorlagen sind ein Ausgangspunkt und müssen an die Umgebung angepasst werden. Sie ersetzen weder eine Sicherheitsbewertung noch eine Rechtsberatung.

## Marken

Dies ist kein Produkt von Microsoft und wird von Microsoft weder unterstützt noch geprüft. Microsoft, Entra ID, Intune und Microsoft Graph sind Marken der Microsoft Corporation.

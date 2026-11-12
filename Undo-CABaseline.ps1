<#
.SYNOPSIS
    Nimmt ein Deployment anhand seines Protokolls zurück.

.DESCRIPTION
    Liest ein oder mehrere Protokolle aus Logs/ und macht die Änderungen in umgekehrter
    Reihenfolge rückgängig:

      - angelegte Objekte werden gelöscht (Policies, Named Locations, Stärken, Gruppen,
        Breakglass-Konten, Restricted AU, Service Principals)
      - hinzugefügte Gruppen- und AU-Mitgliedschaften werden entfernt
      - geänderte Authentifizierungsmethoden und Stärken bekommen ihren vorherigen Stand zurück

    Geänderte Policies und Named Locations, die es vorher schon gab, setzt das Skript nicht
    automatisch zurück. Es meldet sie, der vorherige Stand steht im Protokoll unter "Before".

    Gelöscht wird nur, was im Protokoll steht. Vorher zeigt das Skript die Liste und fragt nach.

.PARAMETER ConfigPath
    Kunden-Config des Tenants, in dem das Deployment lief.

.PARAMETER LogPath
    Ein oder mehrere Protokolle (z. B. bei mehreren abgebrochenen Läufen).

.PARAMETER Purge
    Gelöschte Gruppen, Benutzer und AUs zusätzlich aus dem Papierkorb entfernen. Ohne -Purge
    lassen sie sich 30 Tage lang wiederherstellen.

.PARAMETER Force
    Ohne Rückfrage ausführen.

.EXAMPLE
    .\Undo-CABaseline.ps1 -ConfigPath .\config\tenants\cdx-test.json -LogPath .\Logs\M365x42039049.onmicrosoft.com-20261111-235043.json -WhatIf

.EXAMPLE
    .\Undo-CABaseline.ps1 -ConfigPath .\config\tenants\cdx-test.json -LogPath (Get-ChildItem .\Logs\M365x42039049*.json) -Purge
#>

#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$ConfigPath,
    [Parameter(Mandatory)] [string[]]$LogPath,
    [switch]$Purge,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src/CABaseline/CABaseline.psm1') -Force

$config = Read-CAJson (Resolve-Path $ConfigPath)
Initialize-CAContext -RepoRoot $repoRoot -Config $config -WhatIfMode:$WhatIfPreference

$entries = foreach ($path in $LogPath) { Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json }
$plan = @(Get-CAUndoPlan @($entries))

if (-not $plan.Count) { Write-Host 'Im Protokoll steht nichts, was sich zurücknehmen ließe.' -ForegroundColor Yellow; return }

Write-Host "`nGeplante Rücknahme ($($plan.Count) Schritte, neueste Änderung zuerst):" -ForegroundColor Cyan
$plan | Format-Table Op, Kind, Object, Note -AutoSize -Wrap | Out-Host
if ($Purge) { Write-Host 'Mit -Purge: Gruppen, Benutzer und AUs werden endgültig gelöscht.' -ForegroundColor Yellow }

if (-not $WhatIfPreference -and -not $Force) {
    $answer = Read-Host "Zum Ausführen 'JA' eingeben"
    if ($answer -cne 'JA') { Write-Host 'Abgebrochen.' -ForegroundColor Yellow; return }
}

$tenantLabel = (Get-CAConfigValue 'tenant.primaryDomain' 'tenant') -replace '[^\w\.-]', '_'
$undoLog = Join-Path $repoRoot ("Logs/undo-{0}-{1:yyyyMMdd-HHmmss}.json" -f $tenantLabel, (Get-Date))
Start-CALog $undoLog

Connect-CABaseline
if ($WhatIfPreference) { Write-Host '*** WhatIf: Es wird nichts geändert. ***' -ForegroundColor Magenta }

try { Invoke-CAUndo $plan -Purge:$Purge }
finally {
    Save-CALog $undoLog

    $log = (Get-CAContext).Log
    Write-Host "`n=== Zusammenfassung ===" -ForegroundColor White
    $log | Group-Object Action | Sort-Object Name | ForEach-Object { '{0,-14} {1}' -f $_.Name, $_.Count } | Out-Host
    $problems = @($log | Where-Object Action -in 'warnung', 'fehler')
    if ($problems) { $problems | Format-Table Object, Action, Detail -AutoSize -Wrap | Out-Host }
    Write-Host "Protokoll: $undoLog"
}

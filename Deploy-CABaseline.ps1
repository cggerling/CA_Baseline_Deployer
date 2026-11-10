<#
.SYNOPSIS
    Rollt das CA-Framework in einen Kundentenant aus.

.DESCRIPTION
    Reihenfolge:
      1. Named Locations
      2. Authentifizierungsstärken
      3. Persona-Gruppen
      4. Breakglass-Konten (vorhandene übernehmen oder zwei neue anlegen) und Gruppenmitgliedschaft
      5. Restricted Management AU mit den geschützten Persona-Gruppen
      6. Authentifizierungsmethoden, die die Stärken brauchen (nur ergänzend)
      7. Service Principals der Microsoft-Apps, auf die Policies verweisen
      8. CA-Policies

    Jeder Schritt gleicht mit dem Tenant ab. Neue Policies starten mit dem Status aus
    policies.stateOnCreate (Standard: Nur Bericht). Bei bestehenden Policies bleibt der Status unverändert.

    Das Protokoll landet in Logs/<Tenant>-<Zeitstempel>.json. Kennwörter neuer
    Breakglass-Konten stehen nur einmal in der Konsole und nie im Protokoll.

.PARAMETER ConfigPath
    Kunden-Config, z. B. config/tenants/contoso.json.

.PARAMETER ValidateOnly
    Prüft Vorlagen und Config ohne Anmeldung und ohne Graph-Aufruf.

.PARAMETER PolicyKey
    Nur diese Policies ausrollen (Schlüssel, * erlaubt). Überschreibt policies.include.

.PARAMETER Steps
    Nur bestimmte Schritte ausführen. Die Schritte, deren IDs spätere Schritte brauchen,
    laufen trotzdem lesend mit.

.PARAMETER NonInteractive
    Keine Rückfragen. Policies mit fehlenden Pflichteingaben werden übersprungen.

.EXAMPLE
    .\Deploy-CABaseline.ps1 -ConfigPath .\config\tenants\contoso.json -ValidateOnly

.EXAMPLE
    .\Deploy-CABaseline.ps1 -ConfigPath .\config\tenants\contoso.json -WhatIf

.EXAMPLE
    .\Deploy-CABaseline.ps1 -ConfigPath .\config\tenants\contoso.json -PolicyKey '0*','1*'
#>

#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$ConfigPath,
    [switch]$ValidateOnly,
    [string[]]$PolicyKey,
    [ValidateSet('NamedLocations', 'AuthStrengths', 'Groups', 'Breakglass', 'AdminUnit', 'AuthMethods', 'ServicePrincipals', 'Policies')]
    [string[]]$Steps,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src/CABaseline/CABaseline.psm1') -Force

$config = Read-CAJson (Resolve-Path $ConfigPath)
Initialize-CAContext -RepoRoot $repoRoot -Config $config -WhatIfMode:$WhatIfPreference -ValidateOnly:$ValidateOnly -NonInteractive:$NonInteractive

$defs     = Get-CADefinitions
$policies = @(Select-CAPolicies $defs.Policies $PolicyKey)
$run      = { param($name) -not $Steps -or $Steps -contains $name }

$scopes = Get-CARequiredScopes

if (-not $ValidateOnly) {
    $tenantId = Get-CAConfigValue 'tenant.tenantId'
    $clientId = Get-CAConfigValue 'tenant.deployerAppClientId'
    $connect  = @{ TenantId = $tenantId; Scopes = $scopes; NoWelcome = $true }
    if ($clientId -and $clientId -ne '00000000-0000-0000-0000-000000000000') { $connect.ClientId = $clientId }
    else { Write-Warning 'Keine deployerAppClientId in der Config. Anmeldung über die Standard-App "Microsoft Graph Command Line Tools".' }

    Connect-MgGraph @connect
    $ctx = Get-MgContext
    if ($ctx.TenantId -ne $tenantId) { throw "Angemeldet im Tenant $($ctx.TenantId), die Config gehört zu $tenantId. Abbruch." }
    Write-Host "Angemeldet als $($ctx.Account) im Tenant $($ctx.TenantId)" -ForegroundColor Cyan
}

if ($WhatIfPreference) { Write-Host '*** WhatIf: Es wird nichts geändert. ***' -ForegroundColor Magenta }
if ($ValidateOnly)     { Write-Host '*** Nur Prüfung, keine Verbindung zum Tenant. ***' -ForegroundColor Magenta }
Write-Host "Ausgewählte Policies: $($policies.Count) von $($defs.Policies.Count)`n"

# Die ersten drei Schritte liefern die IDs für die Platzhalter. Sie laufen deshalb immer,
# bei abgewählten Schritten aber nur lesend (WhatIf).
function Invoke-Step([string]$Name, [scriptblock]$Action, [switch]$AlwaysResolve) {
    $ctx = Get-CAContext
    $selected = & $run $Name
    if (-not $selected -and -not $AlwaysResolve) { return }
    $savedWhatIf = $ctx.WhatIf
    if (-not $selected) { $ctx.WhatIf = $true }
    Write-Host "`n=== $Name ===" -ForegroundColor White
    try { & $Action }
    finally { $ctx.WhatIf = $savedWhatIf }
}

try {
    Invoke-Step 'NamedLocations'    { Sync-CANamedLocations $defs.NamedLocations } -AlwaysResolve
    Invoke-Step 'AuthStrengths'     { Sync-CAAuthStrengths $defs.AuthStrengths } -AlwaysResolve
    Invoke-Step 'Groups'            { Sync-CAPersonaGroups $defs.Personas } -AlwaysResolve
    Invoke-Step 'Breakglass'        { Sync-CABreakglass $defs.Breakglass }
    Invoke-Step 'AdminUnit'         { Sync-CARestrictedAU $defs.AdminUnit $defs.Personas }
    Invoke-Step 'AuthMethods'       { Sync-CAAuthMethods $defs.AuthStrengths }
    Invoke-Step 'ServicePrincipals' { Sync-CAServicePrincipals $policies }
    Invoke-Step 'Policies'          { Sync-CAPolicies $policies }
}
finally {
    $log = (Get-CAContext).Log
    $tenantLabel = (Get-CAConfigValue 'tenant.primaryDomain' 'tenant') -replace '[^\w\.-]', '_'
    $logPath = Join-Path $repoRoot ("Logs/{0}-{1:yyyyMMdd-HHmmss}.json" -f $tenantLabel, (Get-Date))
    Save-CALog $logPath

    Write-Host "`n=== Zusammenfassung ===" -ForegroundColor White
    $log | Group-Object Action | Sort-Object Name | ForEach-Object { '{0,-14} {1}' -f $_.Name, $_.Count } | Out-Host
    $problems = @($log | Where-Object Action -in 'warnung', 'fehler')
    if ($problems) {
        Write-Host 'Warnungen und Fehler:' -ForegroundColor Yellow
        $problems | Format-Table Step, Object, Action, Detail -AutoSize -Wrap | Out-Host
    }
    Write-Host "Protokoll: $logPath"
}

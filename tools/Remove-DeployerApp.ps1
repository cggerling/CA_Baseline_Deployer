<#
.SYNOPSIS
    Entfernt die App-Registrierung "CA Baseline Deployer" nach Projektende.

.DESCRIPTION
    Standardmäßig wird die Anmeldung an der App nur deaktiviert (accountEnabled = false
    am Service Principal). Mit -Delete wird die App gelöscht. Gelöschte Apps liegen
    30 Tage im Papierkorb und lassen sich in dieser Zeit wiederherstellen.

.EXAMPLE
    .\tools\Remove-DeployerApp.ps1 -TenantId 11111111-2222-3333-4444-555555555555

.EXAMPLE
    .\tools\Remove-DeployerApp.ps1 -TenantId 11111111-2222-3333-4444-555555555555 -Delete
#>

#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string]$TenantId,
    [string]$DisplayName = 'CA Baseline Deployer',
    [switch]$Delete
)

$ErrorActionPreference = 'Stop'
$g = 'https://graph.microsoft.com/v1.0'

Connect-MgGraph -TenantId $TenantId -NoWelcome -Scopes 'Application.ReadWrite.All'

$app = (Invoke-MgGraphRequest -Uri "$g/applications?`$filter=$([uri]::EscapeDataString("displayName eq '$DisplayName'"))&`$select=id,appId,displayName").value
if (-not $app) { Write-Host "Keine App '$DisplayName' gefunden." -ForegroundColor Yellow; return }
if ($app.Count -gt 1) { throw "Mehrere Apps heißen '$DisplayName'. Bitte im Portal prüfen." }
$app = $app[0]

if ($Delete) {
    if ($PSCmdlet.ShouldProcess("$($app.displayName) ($($app.appId))", 'App-Registrierung löschen')) {
        Invoke-MgGraphRequest -Method DELETE -Uri "$g/applications/$($app.id)" | Out-Null
        Write-Host '[OK] App gelöscht (30 Tage im Papierkorb wiederherstellbar)' -ForegroundColor Green
    }
}
else {
    $sp = (Invoke-MgGraphRequest -Uri "$g/servicePrincipals?`$filter=appId eq '$($app.appId)'&`$select=id").value[0]
    if ($PSCmdlet.ShouldProcess("$($app.displayName) ($($app.appId))", 'Anmeldung deaktivieren')) {
        Invoke-MgGraphRequest -Method PATCH -Uri "$g/servicePrincipals/$($sp.id)" -Body '{"accountEnabled":false}' | Out-Null
        Write-Host '[OK] Anmeldung an der App deaktiviert' -ForegroundColor Green
    }
}
Disconnect-MgGraph -ErrorAction SilentlyContinue -WarningAction SilentlyContinue *> $null

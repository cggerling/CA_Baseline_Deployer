<#
.SYNOPSIS
    Legt im Kundentenant die App-Registrierung "CA Baseline Deployer" an.

.DESCRIPTION
    Die App ist ein öffentlicher Client ohne Secret und ohne Zertifikat. Sie bekommt
    nur delegierte Graph-Berechtigungen (Liste in Get-CARequiredScopes) mit Admin-Consent.
    Anmelden dürfen nur zugewiesene Benutzer, standardmäßig der Admin, der das Skript ausführt.

    Für den Admin-Consent auf RoleManagement.ReadWrite.Directory braucht der ausführende
    Admin die Rolle Privileged Role Administrator oder Global Administrator.

    Gibt es die App unter diesem Namen schon, legt das Skript keine zweite an. Es übernimmt
    die vorhandene, ergänzt fehlende Zuweisungen und trägt die Client-ID ein.

    Am Ende steht die Client-ID in der Konsole. Mit -ConfigPath wird sie direkt in die
    Kunden-Config geschrieben.

.PARAMETER TenantId
    Tenant-ID des Kunden.

.PARAMETER DisplayName
    Name der App-Registrierung.

.PARAMETER AssignUsers
    Weitere UPNs, die sich an der App anmelden dürfen.

.PARAMETER ConfigPath
    Kunden-Config, in die tenant.deployerAppClientId geschrieben wird.

.EXAMPLE
    .\tools\New-DeployerApp.ps1 -TenantId 11111111-2222-3333-4444-555555555555 -ConfigPath .\config\tenants\contoso.json
#>

#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$TenantId,
    [string]$DisplayName = 'CA Baseline Deployer',
    [string[]]$AssignUsers = @(),
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/CABaseline/CABaseline.psm1') -Force

$graphAppId = '00000003-0000-0000-c000-000000000000'
$scopes     = Get-CARequiredScopes
$g          = 'https://graph.microsoft.com/v1.0'

Connect-MgGraph -TenantId $TenantId -NoWelcome -Scopes 'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'User.Read.All'
$me = Invoke-MgGraphRequest -Uri "$g/me?`$select=id,userPrincipalName"
Write-Host "Angemeldet als $($me.userPrincipalName)" -ForegroundColor Cyan

# UPNs vorab bereinigen und prüfen, damit ein Tippfehler nicht erst nach dem Anlegen auffällt
$AssignUsers = @($AssignUsers | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
$assignIds = @(foreach ($upn in $AssignUsers) {
    if ($upn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw "'$upn' ist kein gültiger Benutzerprinzipalname (name@domäne)." }
    try { (Invoke-MgGraphRequest -Uri "$g/users/$([uri]::EscapeDataString($upn))?`$select=id").id }
    catch { throw "Benutzer '$upn' gibt es in diesem Tenant nicht." }
})

# Zuweisen ist idempotent: Eine schon vorhandene Zuweisung wird übersprungen
function Add-AppAssignment([string]$SpId, [string[]]$UserIds) {
    $have = @((Invoke-MgGraphRequest -Uri "$g/servicePrincipals/$SpId/appRoleAssignedTo?`$select=principalId").value | ForEach-Object { $_.principalId })
    $added = 0
    foreach ($uid in $UserIds | Select-Object -Unique) {
        if ($have -contains $uid) { continue }
        Invoke-MgGraphRequest -Method POST -Uri "$g/servicePrincipals/$SpId/appRoleAssignedTo" -Body (@{
            principalId = $uid; resourceId = $SpId; appRoleId = '00000000-0000-0000-0000-000000000000'
        } | ConvertTo-Json) | Out-Null
        $added++
    }
    Write-Host "[OK] Zuweisungen: $added neu, $(@($UserIds | Select-Object -Unique).Count - $added) bereits vorhanden" -ForegroundColor Green
}

function Set-ConfigClientId([string]$AppId) {
    if (-not $ConfigPath) { return }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $cfg.tenant.deployerAppClientId = $AppId
    $cfg.tenant.tenantId = $TenantId
    $cfg | ConvertTo-Json -Depth 20 | Set-Content $ConfigPath -Encoding utf8
    Write-Host "[OK] Client-ID in $ConfigPath eingetragen" -ForegroundColor Green
}

$existing = @((Invoke-MgGraphRequest -Uri "$g/applications?`$filter=$([uri]::EscapeDataString("displayName eq '$DisplayName'"))&`$select=id,appId").value)
if ($existing.Count -gt 1) { throw "Es gibt $($existing.Count) Apps mit dem Namen '$DisplayName'. Bitte im Tenant bereinigen oder einen anderen Namen wählen." }
if ($existing.Count -eq 1) {
    # Die App gibt es schon, etwa aus einem früheren Lauf. Sie wird übernommen statt neu angelegt.
    $appId = $existing[0].appId
    Write-Host "[OK] App '$DisplayName' existiert bereits, Client-ID $appId wird übernommen" -ForegroundColor Green
    $sp = (Invoke-MgGraphRequest -Uri "$g/servicePrincipals?`$filter=appId eq '$appId'&`$select=id").value | Select-Object -First 1
    if ($sp) { Add-AppAssignment $sp.id (@($me.id) + $assignIds) }
    else { Write-Host '[WARNUNG] Zur App gibt es keinen Service Principal. Am einfachsten die App mit tools/Remove-DeployerApp.ps1 löschen und neu anlegen.' -ForegroundColor Yellow }
    Set-ConfigClientId $appId
    Write-Host "`nClient-ID: $appId" -ForegroundColor Cyan
    Disconnect-MgGraph -ErrorAction SilentlyContinue -WarningAction SilentlyContinue *> $null
    return
}

# IDs der benötigten Berechtigungen am Microsoft-Graph-Service-Principal nachschlagen
$graphSp = (Invoke-MgGraphRequest -Uri "$g/servicePrincipals?`$filter=appId eq '$graphAppId'&`$select=id,oauth2PermissionScopes").value[0]
$scopeIds = foreach ($s in $scopes) {
    $match = $graphSp.oauth2PermissionScopes | Where-Object { $_.value -eq $s }
    if (-not $match) { throw "Berechtigung $s gibt es am Graph-Service-Principal nicht." }
    @{ id = $match.id; type = 'Scope' }
}

if (-not $PSCmdlet.ShouldProcess($DisplayName, 'App-Registrierung anlegen')) { return }

$app = Invoke-MgGraphRequest -Method POST -Uri "$g/applications" -Body (@{
    displayName            = $DisplayName
    signInAudience         = 'AzureADMyOrg'
    isFallbackPublicClient = $true
    publicClient           = @{ redirectUris = @('http://localhost') }
    requiredResourceAccess = @(@{ resourceAppId = $graphAppId; resourceAccess = @($scopeIds) })
    notes                  = 'Nur für das Deployment des CA-Frameworks. Nach Projektende deaktivieren oder löschen.'
} | ConvertTo-Json -Depth 10)
Write-Host "[OK] App angelegt, Client-ID $($app.appId)" -ForegroundColor Green

# Redirect-URI für die Anmeldung über den Windows-Broker (WAM) kennt erst nach dem Anlegen die Client-ID
Invoke-MgGraphRequest -Method PATCH -Uri "$g/applications/$($app.id)" -Body (@{
    publicClient = @{ redirectUris = @('http://localhost', "ms-appx-web://Microsoft.AAD.BrokerPlugin/$($app.appId)") }
} | ConvertTo-Json -Depth 5) | Out-Null

$sp = Invoke-MgGraphRequest -Method POST -Uri "$g/servicePrincipals" -Body (@{
    appId                     = $app.appId
    appRoleAssignmentRequired = $true
} | ConvertTo-Json)
Write-Host '[OK] Service Principal angelegt, Zuweisung erforderlich' -ForegroundColor Green

# Admin-Consent für alle Benutzer. Wirksam ist er trotzdem nur für zugewiesene Benutzer mit passenden Rollen.
Invoke-MgGraphRequest -Method POST -Uri "$g/oauth2PermissionGrants" -Body (@{
    clientId    = $sp.id
    consentType = 'AllPrincipals'
    resourceId  = $graphSp.id
    scope       = ($scopes -join ' ')
} | ConvertTo-Json) | Out-Null
Write-Host '[OK] Admin-Consent erteilt' -ForegroundColor Green

Add-AppAssignment $sp.id (@($me.id) + $assignIds)
Set-ConfigClientId $app.appId

Write-Host "`nClient-ID: $($app.appId)" -ForegroundColor Cyan
Write-Host 'Für das Deployment braucht der angemeldete Admin Global Administrator oder diese Rollen: Conditional Access Administrator, Authentication Policy Administrator, Privileged Role Administrator, User Administrator, Cloud Application Administrator.'
Disconnect-MgGraph -ErrorAction SilentlyContinue -WarningAction SilentlyContinue *> $null

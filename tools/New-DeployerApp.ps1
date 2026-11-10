<#
.SYNOPSIS
    Legt im Kundentenant die App-Registrierung "CA Baseline Deployer" an.

.DESCRIPTION
    Die App ist ein öffentlicher Client ohne Secret und ohne Zertifikat. Sie bekommt
    nur delegierte Graph-Berechtigungen (Liste in Get-CARequiredScopes) mit Admin-Consent.
    Anmelden dürfen nur zugewiesene Benutzer, standardmäßig der Admin, der das Skript ausführt.

    Für den Admin-Consent auf RoleManagement.ReadWrite.Directory braucht der ausführende
    Admin die Rolle Privileged Role Administrator oder Global Administrator.

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

$existing = (Invoke-MgGraphRequest -Uri "$g/applications?`$filter=$([uri]::EscapeDataString("displayName eq '$DisplayName'"))&`$select=id,appId").value
if ($existing) { throw "Es gibt bereits eine App '$DisplayName' (Client-ID $($existing[0].appId)). Erst mit tools/Remove-DeployerApp.ps1 entfernen oder anderen Namen wählen." }

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

$userIds = @($me.id)
foreach ($upn in $AssignUsers) {
    $userIds += (Invoke-MgGraphRequest -Uri "$g/users/$([uri]::EscapeDataString($upn))?`$select=id").id
}
foreach ($uid in $userIds | Select-Object -Unique) {
    Invoke-MgGraphRequest -Method POST -Uri "$g/servicePrincipals/$($sp.id)/appRoleAssignedTo" -Body (@{
        principalId = $uid
        resourceId  = $sp.id
        appRoleId   = '00000000-0000-0000-0000-000000000000'
    } | ConvertTo-Json) | Out-Null
}
Write-Host "[OK] $(@($userIds | Select-Object -Unique).Count) Benutzer zugewiesen" -ForegroundColor Green

if ($ConfigPath) {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $cfg.tenant.deployerAppClientId = $app.appId
    $cfg.tenant.tenantId = $TenantId
    $cfg | ConvertTo-Json -Depth 20 | Set-Content $ConfigPath -Encoding utf8
    Write-Host "[OK] Client-ID in $ConfigPath eingetragen" -ForegroundColor Green
}

Write-Host "`nClient-ID: $($app.appId)" -ForegroundColor Cyan
Write-Host 'Vor dem Deployment die Rollen per PIM aktivieren: Conditional Access Administrator, Authentication Policy Administrator, Privileged Role Administrator, User Administrator, Cloud Application Administrator.'
Disconnect-MgGraph | Out-Null

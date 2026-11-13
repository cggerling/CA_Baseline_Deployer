<#
.SYNOPSIS
    Prüft Anmeldung, aktive Rollen und Sicherheitsstandards in deinem Tenant, ohne etwas zu ändern.

.DESCRIPTION
    Meldet sich mit der Deployer-App aus der Config an und liest:
      - welche Entra-Rollen der angemeldete Admin gerade aktiv hat (PIM-Aktivierungen eingeschlossen)
      - ob die Sicherheitsstandards (Security Defaults) eingeschaltet sind. Solange sie aktiv sind,
        lassen sich keine CA-Policies anlegen.
      - ob Passkey (FIDO2) schon auf Passkey-Profile umgestellt ist

    Für jeden Deployment-Schritt steht dabei, welche Rolle er braucht und ob sie aktiv ist.
    Global Administrator deckt alle Schritte ab.

    Das Ergebnis steht am Ende zusätzlich als eine JSON-Zeile mit dem Präfix ##CABASELINE-RESULT##,
    die die Weboberfläche auswertet.

.EXAMPLE
    .\tools\Test-CAConnection.ps1 -ConfigPath .\config\tenants\contoso.json
#>

#Requires -Version 7.2

[CmdletBinding()]
param([Parameter(Mandatory)] [string]$ConfigPath)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/CABaseline/CABaseline.psm1') -Force

$config = Read-CAJson (Resolve-Path $ConfigPath)
Initialize-CAContext -RepoRoot $repoRoot -Config $config -WhatIfMode:$true -NonInteractive
Connect-CABaseline

$g = 'https://graph.microsoft.com/v1.0'
$me = Invoke-MgGraphRequest -Uri "$g/me?`$select=id,userPrincipalName"

$active = @{}
$uri = "$g/me/transitiveMemberOf/microsoft.graph.directoryRole?`$select=displayName,roleTemplateId"
while ($uri) {
    $page = Invoke-MgGraphRequest -Uri $uri
    foreach ($r in $page.value) { $active[$r.roleTemplateId] = $r.displayName }
    $uri = $page['@odata.nextLink']
}

$globalAdmin = '62e90394-69f5-4237-9190-012177145e10'
$roles = @(
    [ordered]@{ id = 'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9'; name = 'Conditional Access Administrator';    steps = @('NamedLocations', 'AuthStrengths', 'Policies') }
    [ordered]@{ id = '0526716b-113d-4c15-b2c8-68e3c22b9f80'; name = 'Authentication Policy Administrator'; steps = @('AuthMethods') }
    [ordered]@{ id = 'e8611ab8-c189-46e8-94e1-60213ab1f814'; name = 'Privileged Role Administrator';       steps = @('Groups', 'Breakglass', 'AdminUnit') }
    [ordered]@{ id = 'fe930be7-5e62-47db-91af-98c3a49a38b1'; name = 'User Administrator';                  steps = @('Breakglass') }
    [ordered]@{ id = '158c047a-c907-4556-b7ef-446551a6b5f7'; name = 'Cloud Application Administrator';     steps = @('ServicePrincipals') }
)
$isGa = $active.ContainsKey($globalAdmin)
foreach ($r in $roles) { $r.active = $isGa -or $active.ContainsKey($r.id) }

$secDefaults = Invoke-MgGraphRequest -Uri "$g/policies/identitySecurityDefaultsEnforcementPolicy"
$fido2 = Invoke-MgGraphRequest -Uri "$g/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2"
$profiles = @(if ($fido2.ContainsKey('passkeyProfiles')) { $fido2.passkeyProfiles })

Write-Host "`nAngemeldet als $($me.userPrincipalName)"
Write-Host ("Global Administrator aktiv: {0}" -f ($isGa ? 'ja' : 'nein'))
foreach ($r in $roles) {
    $mark = if ($r.active) { '[OK]   ' } else { '[FEHLT]' }
    Write-Host ("{0} {1,-37} für {2}" -f $mark, $r.name, ($r.steps -join ', ')) -ForegroundColor ($r.active ? 'Green' : 'Yellow')
}
Write-Host ("Sicherheitsstandards: {0}" -f ($secDefaults.isEnabled ? 'EIN, vor dem Deployment ausschalten' : 'aus')) -ForegroundColor ($secDefaults.isEnabled ? 'Yellow' : 'Green')
Write-Host ("Passkey (FIDO2): {0}, Passkey-Profile: {1}" -f $fido2.state, ($profiles.Count ? "$($profiles.Count) vorhanden" : 'noch nicht umgestellt'))

$result = [ordered]@{
    account                 = $me.userPrincipalName
    tenantId                = (Get-MgContext).TenantId
    globalAdministrator     = $isGa
    roles                   = $roles
    securityDefaultsEnabled = [bool]$secDefaults.isEnabled
    fido2State              = $fido2.state
    passkeyProfiles         = @($profiles | ForEach-Object { $_.name })
}
[Console]::Out.WriteLine('##CABASELINE-RESULT## ' + ($result | ConvertTo-Json -Depth 5 -Compress))
Disconnect-MgGraph -ErrorAction SilentlyContinue -WarningAction SilentlyContinue *> $null

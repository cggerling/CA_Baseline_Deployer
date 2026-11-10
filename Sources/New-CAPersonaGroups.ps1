<#
.SYNOPSIS
    Legt die Conditional-Access-Persona-Gruppen in Entra ID an (oder entfernt Testgruppen).

.DESCRIPTION
    Erstellt die Gruppen gemäß Persona-Konzept:
      - SG-CA-Persona-Admins       Role-assignable, Assigned
      - SG-CA-Persona-Breakglass   Role-assignable, Assigned
      - SG-CA-Persona-Internals    Assigned
      - SG-CA-Persona-Externals    Assigned
      - SG-CA-Persona-Developers   Assigned
      - SG-CA-Persona-Guests       Dynamic: (user.userType -eq "guest")
      - SG-CA-Persona-ServiceUser  Role-assignable, Assigned

    Optional (-AddToRestrictedAU) wird eine Restricted Management Administrative Unit
    angelegt bzw. wiederverwendet und Admins, Breakglass und ServiceUser werden hinzugefügt.

    Bereits vorhandene Gruppen (gleicher displayName) werden übersprungen, nicht verändert.

.PARAMETER Test
    Testlauf: Allen Gruppennamen (und dem AU-Namen) wird "TEST-" vorangestellt,
    z. B. TEST-SG-CA-Persona-Admins. Die produktiven Gruppen werden nicht angefasst.

.PARAMETER RemoveTestGroups
    Löscht die mit -Test angelegten Gruppen (exakte Namen aus der Definition mit Präfix "TEST-")
    und, falls vorhanden, die Test-AU. Produktive Gruppen werden nie gelöscht.
    Gelöschte Gruppen landen zunächst für 30 Tage im Papierkorb (Soft Delete).

.PARAMETER Force
    Überspringt die Sicherheitsabfrage bei -RemoveTestGroups.

.PARAMETER AddToRestrictedAU
    Legt die RMAU an (falls nicht vorhanden) und fügt die vorgesehenen Gruppen hinzu.
    ACHTUNG: Danach können tenant-weite Admins (auch Global Admins) die Gruppen nicht mehr
    bearbeiten, solange sie keine auf die AU gescopte Rolle haben. Erst Mitglieder pflegen,
    dann in die RMAU verschieben.

.PARAMETER RestrictedAUName
    Name der Restricted Management Administrative Unit.

.EXAMPLE
    .\New-CAPersonaGroups.ps1 -Test
    Legt TEST-SG-CA-Persona-* an.

.EXAMPLE
    .\New-CAPersonaGroups.ps1 -RemoveTestGroups
    Löscht alle TEST-SG-CA-Persona-* Gruppen (und die Test-AU) nach Rückfrage.

.EXAMPLE
    .\New-CAPersonaGroups.ps1

.EXAMPLE
    .\New-CAPersonaGroups.ps1 -AddToRestrictedAU -RestrictedAUName 'AU-CA-Persona-Restricted'

.NOTES
    Benötigt: Microsoft.Graph.Authentication, Microsoft.Graph.Groups
    Rolle:    mindestens Privileged Role Administrator für role-assignable Groups und RMAU
    Lizenz:   Entra ID P1 für dynamische Gruppen und role-assignable Groups
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Create')]
param(
    [Parameter(ParameterSetName = 'Create')]
    [switch]$Test,

    [Parameter(ParameterSetName = 'Remove', Mandatory)]
    [switch]$RemoveTestGroups,

    [Parameter(ParameterSetName = 'Remove')]
    [switch]$Force,

    [switch]$AddToRestrictedAU,

    [string]$RestrictedAUName = 'AU-CA-Persona-Restricted'
)

$ErrorActionPreference = 'Stop'
$testPrefix = 'TEST-'
$auUri      = 'https://graph.microsoft.com/v1.0/directory/administrativeUnits'

# ---------------------------------------------------------------------------
# Gruppendefinition
# ---------------------------------------------------------------------------
$groupDefinitions = @(
    @{
        DisplayName        = 'SG-CA-Persona-Admins'
        Description        = 'CA Persona: Administratoren - Konten mit privilegierten Rollen'
        IsAssignableToRole = $true
        Dynamic            = $false
        MembershipRule     = $null
        RestrictedAU       = $true
    }
    @{
        DisplayName        = 'SG-CA-Persona-Breakglass'
        Description        = 'CA Persona: Notfallkonten mit hoechsten Rechten, nur fuer den Krisenfall'
        IsAssignableToRole = $true
        Dynamic            = $false
        MembershipRule     = $null
        RestrictedAU       = $true
    }
    @{
        DisplayName        = 'SG-CA-Persona-Internals'
        Description        = 'CA Persona: Interne Mitarbeitende - festangestellte Mitarbeitende'
        IsAssignableToRole = $false
        Dynamic            = $false
        MembershipRule     = $null
        RestrictedAU       = $false
    }
    @{
        DisplayName        = 'SG-CA-Persona-Externals'
        Description        = 'CA Persona: Externe Mitarbeitende - vollwertiger Account im Tenant inkl. Lizenz (Partner, Berater, befristete Kraefte)'
        IsAssignableToRole = $false
        Dynamic            = $false
        MembershipRule     = $null
        RestrictedAU       = $false
    }
    @{
        DisplayName        = 'SG-CA-Persona-Developers'
        Description        = 'CA Persona: Entwickler - interne Mitarbeitende mit vollwertigem Account, die aufgrund ihrer Rolle abweichende Richtlinien benoetigen'
        IsAssignableToRole = $false
        Dynamic            = $false
        MembershipRule     = $null
        RestrictedAU       = $false
    }
    @{
        DisplayName        = 'SG-CA-Persona-Guests'
        Description        = 'CA Persona: Gaeste - B2B-Gastkonten fuer die Zusammenarbeit'
        IsAssignableToRole = $false
        Dynamic            = $true
        MembershipRule     = '(user.userType -eq "guest")'
        RestrictedAU       = $false
    }
    @{
        DisplayName        = 'SG-CA-Persona-ServiceUser'
        Description        = 'CA Persona: Dienstkonten - Benutzerkonten fuer Anwendungen oder Skripte'
        IsAssignableToRole = $false
        Dynamic            = $false
        MembershipRule     = $null
        RestrictedAU       = $true
    }
)

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
function Get-GroupByName([string]$Name) {
    Get-MgGroup -Filter "displayName eq '$Name'" -ConsistencyLevel eventual -CountVariable c
}

function Get-AUByName([string]$Name) {
    (Invoke-MgGraphRequest -Method GET -Uri "$auUri`?`$filter=displayName eq '$Name'" -OutputType PSObject).value |
        Select-Object -First 1
}

# ---------------------------------------------------------------------------
# Modus: Testgruppen entfernen
# ---------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Remove') {

    Connect-MgGraph -Scopes 'Group.ReadWrite.All', 'RoleManagement.ReadWrite.Directory', 'AdministrativeUnit.ReadWrite.All' -NoWelcome
    Write-Host "Verbunden mit Tenant: $((Get-MgContext).TenantId)" -ForegroundColor Cyan

    # Nur exakte Testnamen aus der Definition, nie produktive Gruppen
    $toDelete = foreach ($def in $groupDefinitions) {
        Get-GroupByName ($testPrefix + $def.DisplayName)
    }
    $testAU = Get-AUByName ($testPrefix + $RestrictedAUName)

    if (-not $toDelete -and -not $testAU) {
        Write-Host 'Keine Testgruppen oder Test-AU gefunden.' -ForegroundColor Yellow
        return
    }

    Write-Host "`nFolgende Objekte werden gelöscht:" -ForegroundColor Cyan
    $toDelete | ForEach-Object { Write-Host "  Gruppe: $($_.DisplayName)  ($($_.Id))" }
    if ($testAU) { Write-Host "  AU:     $($testAU.displayName)  ($($testAU.id))" }

    if (-not $Force -and -not $WhatIfPreference) {
        $answer = Read-Host "`nZum Bestätigen 'JA' eingeben"
        if ($answer -cne 'JA') { Write-Host 'Abgebrochen.' -ForegroundColor Yellow; return }
    }

    # Gruppen zuerst aus der Test-AU lösen, damit der RMAU-Schutz das Löschen nicht blockiert
    if ($testAU) {
        $auMembers = (Invoke-MgGraphRequest -Method GET -Uri "$auUri/$($testAU.id)/members?`$select=id" -OutputType PSObject).value.id
        foreach ($g in $toDelete | Where-Object { $auMembers -contains $_.Id }) {
            if ($PSCmdlet.ShouldProcess($g.DisplayName, 'Aus Test-AU entfernen')) {
                Invoke-MgGraphRequest -Method DELETE -Uri "$auUri/$($testAU.id)/members/$($g.Id)/`$ref"
                Write-Host "[OK]     $($g.DisplayName) aus AU entfernt" -ForegroundColor Green
            }
        }
    }

    foreach ($g in $toDelete) {
        if ($PSCmdlet.ShouldProcess($g.DisplayName, 'Gruppe löschen')) {
            try {
                Remove-MgGroup -GroupId $g.Id
                Write-Host "[OK]     $($g.DisplayName) gelöscht" -ForegroundColor Green
            }
            catch {
                Write-Host "[FEHLER] $($g.DisplayName): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    if ($testAU -and $PSCmdlet.ShouldProcess($testAU.displayName, 'Test-AU löschen')) {
        Invoke-MgGraphRequest -Method DELETE -Uri "$auUri/$($testAU.id)"
        Write-Host "[OK]     AU $($testAU.displayName) gelöscht" -ForegroundColor Green
    }

    Write-Host "`nHinweis: Gelöschte Gruppen liegen 30 Tage im Papierkorb (Entra ID > Gruppen > Gelöschte Gruppen)." -ForegroundColor Cyan
    return
}

# ---------------------------------------------------------------------------
# Modus: Gruppen anlegen
# ---------------------------------------------------------------------------
$prefix = if ($Test) { $testPrefix } else { '' }
if ($Test) {
    $RestrictedAUName = $testPrefix + $RestrictedAUName
    Write-Host '*** TESTLAUF: Alle Namen erhalten das Präfix TEST- ***' -ForegroundColor Magenta
}

$scopes = @('Group.ReadWrite.All', 'RoleManagement.ReadWrite.Directory')
if ($AddToRestrictedAU) { $scopes += 'AdministrativeUnit.ReadWrite.All' }

Connect-MgGraph -Scopes $scopes -NoWelcome
Write-Host "Verbunden mit Tenant: $((Get-MgContext).TenantId)" -ForegroundColor Cyan

$createdGroups = @{}

foreach ($def in $groupDefinitions) {
    $name     = $prefix + $def.DisplayName
    $existing = Get-GroupByName $name

    if ($existing) {
        Write-Host "[SKIP]   $name existiert bereits (Id: $($existing[0].Id))" -ForegroundColor Yellow
        $createdGroups[$name] = @{ Group = $existing[0]; Def = $def }
        continue
    }

    $description = if ($Test) { "TEST - $($def.Description)" } else { $def.Description }

    $body = @{
        displayName     = $name
        description     = $description
        mailEnabled     = $false
        mailNickname    = $name
        securityEnabled = $true
    }

    if ($def.IsAssignableToRole) {
        # Immutable, nur bei Erstellung setzbar; nicht kombinierbar mit dynamischer Mitgliedschaft
        $body.isAssignableToRole = $true
    }

    if ($def.Dynamic) {
        $body.groupTypes                    = @('DynamicMembership')
        $body.membershipRule                = $def.MembershipRule
        $body.membershipRuleProcessingState = 'On'
    }

    if ($PSCmdlet.ShouldProcess($name, 'Gruppe anlegen')) {
        $group = New-MgGroup -BodyParameter $body
        $createdGroups[$name] = @{ Group = $group; Def = $def }

        $typ = if ($def.Dynamic) { "Dynamic: $($def.MembershipRule)" }
               elseif ($def.IsAssignableToRole) { 'Assigned, role-assignable' }
               else { 'Assigned' }
        Write-Host "[OK]     $name angelegt ($typ) - Id: $($group.Id)" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Optional: Restricted Management Administrative Unit
# ---------------------------------------------------------------------------
if ($AddToRestrictedAU) {
    $au = Get-AUByName $RestrictedAUName

    if ($au) {
        if (-not $au.isMemberManagementRestricted) {
            throw "Die AU '$RestrictedAUName' existiert, ist aber KEINE Restricted Management AU. Bitte anderen Namen waehlen."
        }
        Write-Host "[SKIP]   AU $RestrictedAUName existiert bereits (Id: $($au.id))" -ForegroundColor Yellow
    }
    elseif ($PSCmdlet.ShouldProcess($RestrictedAUName, 'Restricted Management AU anlegen')) {
        $auBody = @{
            displayName                  = $RestrictedAUName
            description                  = 'Schutz der CA-Persona-Gruppen vor Aenderungen durch tenant-weite Admins'
            isMemberManagementRestricted = $true
        } | ConvertTo-Json
        $au = Invoke-MgGraphRequest -Method POST -Uri $auUri -Body $auBody -ContentType 'application/json' -OutputType PSObject
        Write-Host "[OK]     AU $RestrictedAUName angelegt (Id: $($au.id))" -ForegroundColor Green
    }

    if ($au) {
        $auMembers = (Invoke-MgGraphRequest -Method GET -Uri "$auUri/$($au.id)/members?`$select=id" -OutputType PSObject).value.id

        foreach ($entry in $createdGroups.GetEnumerator() | Where-Object { $_.Value.Def.RestrictedAU }) {
            $g = $entry.Value.Group

            if ($auMembers -contains $g.Id) {
                Write-Host "[SKIP]   $($entry.Key) ist bereits in der AU" -ForegroundColor Yellow
                continue
            }

            if ($PSCmdlet.ShouldProcess($entry.Key, "Zu AU $RestrictedAUName hinzufuegen")) {
                $refBody = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/groups/$($g.Id)" } | ConvertTo-Json
                Invoke-MgGraphRequest -Method POST -Uri "$auUri/$($au.id)/members/`$ref" -Body $refBody -ContentType 'application/json'
                Write-Host "[OK]     $($entry.Key) zur AU hinzugefuegt" -ForegroundColor Green
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Zusammenfassung
# ---------------------------------------------------------------------------
Write-Host "`nErgebnis:" -ForegroundColor Cyan
$createdGroups.GetEnumerator() | Sort-Object Name | ForEach-Object {
    [PSCustomObject]@{ DisplayName = $_.Name; Id = $_.Value.Group.Id }
} | Format-Table -AutoSize

if ($Test) {
    Write-Host 'Aufräumen mit: .\New-CAPersonaGroups.ps1 -RemoveTestGroups' -ForegroundColor Magenta
}

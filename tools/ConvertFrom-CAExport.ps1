<#
.SYNOPSIS
    Wandelt Graph-Exporte (CA-Policies, Authentifizierungsstärken, Named Locations)
    in tenantneutrale Vorlagen für das Repo um.

.DESCRIPTION
    Exporte aus einem Tenant enthalten Objekt-IDs, die es nur dort gibt. Der Konverter
    ersetzt sie durch Platzhalter, die Deploy-CABaseline.ps1 im Zieltenant wieder auflöst:

      {{group:<Persona>}}            Persona-Gruppe, z. B. {{group:Admins}}
      {{namedLocation:<Name>}}       Named Location, z. B. {{namedLocation:NL-Global-Corporate_Sites-IP}}
      {{authStrength:<Schlüssel>}}   Authentifizierungsstärke, z. B. {{authStrength:ModernMFA}}

    Woher die Zuordnung kommt:
      - Gruppen und Named Locations stehen in der Mapping-Datei (id-mapping.json).
      - Die IDs der Stärken liest der Konverter aus den AuthStr_*.json im Quellordner.

    IDs, die sich nicht zuordnen lassen, werden zu {{unmapped:<GUID>}}. Der Konverter
    meldet sie, und der Deployer bricht ab, solange noch eine davon übrig ist.
    Anwendungs-IDs von Microsoft (z. B. Office 365) sind in jedem Tenant gleich und bleiben stehen.

    Felder, die Graph selbst verwaltet (id, Zeitstempel, @odata.context), werden entfernt.
    Der Inhalt bleibt sonst unverändert: Korrekturen an Policies gehören in eigene Commits.

.PARAMETER SourcePath
    Ordner mit den Exporten.

.PARAMETER MappingFile
    JSON mit den Zuordnungen für Gruppen und Named Locations.

.PARAMETER OutputPath
    Zielordner, normalerweise der Ordner definitions im Repo.

.EXAMPLE
    .\tools\ConvertFrom-CAExport.ps1 -SourcePath .\Sources -MappingFile .\Sources\id-mapping.json -OutputPath .\definitions
#>

#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SourcePath,
    [Parameter(Mandatory)] [string]$MappingFile,
    [Parameter(Mandatory)] [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# .NET-Dateifunktionen kennen den PowerShell-Pfad nicht, deshalb absolut auflösen
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# Felder, die Graph beim Anlegen selbst setzt und die in einer Vorlage nichts verloren haben
$readOnlyKeys = @('id', 'templateId', 'createdDateTime', 'modifiedDateTime', 'deletedDateTime')

$mapping  = Get-Content $MappingFile -Raw | ConvertFrom-Json -AsHashtable
$unmapped = [System.Collections.Generic.List[string]]::new()

function Read-Json([string]$Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
}

function Write-Json($Object, [string]$Path) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    # LF und UTF-8 ohne BOM, passend zu .gitattributes
    $json = ($Object | ConvertTo-Json -Depth 30) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

# Entfernt rekursiv alle "...@odata.context"-Einträge
function Remove-ODataContext($Node) {
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) {
            if ($k -like '*@odata.context') { $Node.Remove($k); continue }
            Remove-ODataContext $Node[$k]
        }
    }
    elseif ($Node -is [System.Collections.IList]) {
        foreach ($item in $Node) { Remove-ODataContext $item }
    }
}

function Remove-ReadOnly([System.Collections.IDictionary]$Node) {
    foreach ($k in $readOnlyKeys) { $Node.Remove($k) }
    Remove-ODataContext $Node
}

# Ersetzt eine GUID über die passende Zuordnungstabelle durch einen Platzhalter
function ConvertTo-Placeholder([string]$Value, [hashtable]$Table, [string]$Kind, [string]$Context) {
    if ($Value -notmatch $guidPattern) { return $Value }        # z. B. "All" oder "AllTrusted"
    if ($Table.ContainsKey($Value))    { return "{{${Kind}:$($Table[$Value])}}" }
    $unmapped.Add("$Context -> $Kind $Value")
    return "{{unmapped:$Value}}"
}

function New-Template([string]$Key, [System.Collections.IDictionary]$DeployerInfo, [System.Collections.IDictionary]$Body) {
    $info = [ordered]@{ key = $Key }
    foreach ($k in $DeployerInfo.Keys) { $info[$k] = $DeployerInfo[$k] }
    $result = [ordered]@{ '_deployer' = $info }
    foreach ($k in $Body.Keys) { $result[$k] = $Body[$k] }
    $result
}

# Dateinamen ohne '#' und mit normalen Bindestrichen (U+2011 und U+2010 kommen aus Copy & Paste)
function Get-SafeName([string]$Name) {
    ($Name -replace '^#', '') -replace "[‐‑]", '-'
}

# ---------------------------------------------------------------------------
# Authentifizierungsstärken
# ---------------------------------------------------------------------------
$strengthMap = @{}
foreach ($file in Get-ChildItem -LiteralPath $SourcePath -Filter 'AuthStr_*.json') {
    $src = Read-Json $file.FullName
    $key = $file.BaseName -replace '^AuthStr_', ''
    $strengthMap[$src.id] = $key

    Remove-ReadOnly $src
    foreach ($k in 'policyType', 'requirementsSatisfied') { $src.Remove($k) }   # von Graph berechnet

    $out = Join-Path $OutputPath "authentication-strengths/$key.json"
    Write-Json (New-Template $key @{} $src) $out
    Write-Host "[Stärke]   $key"
}

# ---------------------------------------------------------------------------
# Named Locations
# ---------------------------------------------------------------------------
foreach ($file in Get-ChildItem -LiteralPath $SourcePath -Filter 'NL-*.json') {
    $src = Read-Json $file.FullName
    $key = Get-SafeName $src.displayName
    Remove-ReadOnly $src

    $out = Join-Path $OutputPath "named-locations/$key.json"
    Write-Json (New-Template $key @{} $src) $out
    Write-Host "[Location] $key"
}

# ---------------------------------------------------------------------------
# Conditional-Access-Policies
# ---------------------------------------------------------------------------
foreach ($file in Get-ChildItem -LiteralPath $SourcePath -Filter '#*.json') {
    $src  = Read-Json $file.FullName
    $name = $src.displayName
    $key  = Get-SafeName $file.BaseName
    Remove-ReadOnly $src

    $users = $src.conditions.users
    foreach ($prop in 'includeGroups', 'excludeGroups') {
        if ($users -and $users[$prop]) {
            $users[$prop] = @($users[$prop] | ForEach-Object { ConvertTo-Placeholder $_ $mapping.groups 'group' $name })
        }
    }

    $locations = $src.conditions.locations
    foreach ($prop in 'includeLocations', 'excludeLocations') {
        if ($locations -and $locations[$prop]) {
            $locations[$prop] = @($locations[$prop] | ForEach-Object { ConvertTo-Placeholder $_ $mapping.namedLocations 'namedLocation' $name })
        }
    }

    # Der Export enthält die komplette Stärke. Für das Deployment reicht die Referenz.
    $grant = $src.grantControls
    if ($grant -and $grant.authenticationStrength) {
        $id = $grant.authenticationStrength.id
        $grant.authenticationStrength = [ordered]@{ id = (ConvertTo-Placeholder $id $strengthMap 'authStrength' $name) }
    }

    # Kategorie aus dem Namensschema: "#100-Admins-AllApps-..." -> "Admins"
    $category = ((Get-SafeName $name) -split '-')[1]

    $info = [ordered]@{
        category        = $category
        defaultSelected = $true
        customerInput   = @()
    }

    $out = Join-Path $OutputPath "conditional-access/$key.json"
    Write-Json (New-Template $key $info $src) $out
    Write-Host "[Policy]   $key"
}

if ($unmapped.Count) {
    Write-Warning "Nicht zugeordnete IDs ($($unmapped.Count)). Sie stehen als {{unmapped:...}} in den Vorlagen:"
    $unmapped | ForEach-Object { Write-Warning "  $_" }
}

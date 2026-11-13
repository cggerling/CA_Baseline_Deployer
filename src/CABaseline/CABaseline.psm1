<#
    CABaseline: Funktionen für Deploy-CABaseline.ps1

    Das Modul liest die Vorlagen aus definitions/, löst die Platzhalter für den
    Zieltenant auf und gleicht jedes Objekt mit dem Tenant ab. Alle Graph-Aufrufe
    laufen über Invoke-CAGraph, damit -WhatIf und das Deployment-Protokoll an
    einer Stelle hängen.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:Ctx = $null

# Delegierte Graph-Berechtigungen für das Deployment. Was davon tatsächlich wirkt,
# hängt zusätzlich an den Rollen des angemeldeten Admins.
function Get-CARequiredScopes {
    @(
        'Policy.Read.All'
        'Policy.ReadWrite.ConditionalAccess'
        'Policy.ReadWrite.AuthenticationMethod'
        'Group.ReadWrite.All'
        'User.ReadWrite.All'
        'RoleManagement.ReadWrite.Directory'
        'AdministrativeUnit.ReadWrite.All'
        'Application.ReadWrite.All'
    )
}

# ===========================================================================
# Kontext, Protokoll, Ausgabe
# ===========================================================================

function Initialize-CAContext {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Config,
        [switch]$WhatIfMode,
        [switch]$ValidateOnly,
        [switch]$NonInteractive
    )
    $script:Ctx = [ordered]@{
        RepoRoot       = $RepoRoot
        Config         = $Config
        WhatIf         = [bool]$WhatIfMode
        ValidateOnly   = [bool]$ValidateOnly
        NonInteractive = [bool]$NonInteractive
        Groups         = @{}      # Persona-Schlüssel -> Objekt-ID
        ExtraGroups    = @{}      # zusätzliche Personas, ohne Bezug zu Policies
        NamedLocations = @{}      # Name -> Objekt-ID
        AuthStrengths  = @{}      # Schlüssel -> Objekt-ID
        OptionalProducts = @{}    # Auswahl optionaler Passkey-Hardware, damit nur einmal gefragt wird
        SkippedNamedLocations = @{}  # abgewählte Locations, die es im Tenant nicht gibt
        Log           = [System.Collections.Generic.List[object]]::new()
        LogPath        = $null    # gesetzt über Start-CALog, dann wird nach jedem Eintrag gespeichert
        FakeCounter    = 0
    }
}

# Legt die Protokolldatei gleich zu Beginn an. Ab dann landet jeder Eintrag sofort auf der Platte.
# Bricht ein Lauf hart ab (Fenster geschlossen, Strg+C bei einer Rückfrage), steht im Protokoll
# trotzdem alles, was bis dahin angelegt wurde, und Undo-CABaseline.ps1 kann damit arbeiten.
function Start-CALog {
    param([Parameter(Mandatory)] [string]$Path)
    $script:Ctx.LogPath = $Path
    Save-CALog $Path
}

function Get-CAContext { $script:Ctx }

# Schreibt eine Zeile in die Konsole und ins Deployment-Protokoll
function Write-CALog {
    param(
        [Parameter(Mandatory)] [string]$Step,
        [Parameter(Mandatory)] [string]$Object,
        [Parameter(Mandatory)]
        [ValidateSet('angelegt', 'aktualisiert', 'unverändert', 'übersprungen', 'warnung', 'fehler', 'info', 'würde anlegen', 'würde ändern')]
        [string]$Action,
        [string]$Detail = '',
        # Für Undo-CABaseline.ps1: Art und ID des geänderten Objekts, bei Mitgliedschaften
        # die ID des Containers, bei Änderungen der Stand davor
        [string]$Kind,
        [string]$ObjectId,
        [string]$ParentId,
        $Before
    )
    $script:Ctx.Log.Add([pscustomobject]@{
        Time = (Get-Date).ToString('s'); Step = $Step; Object = $Object; Action = $Action; Detail = $Detail
        Kind = $Kind; ObjectId = $ObjectId; ParentId = $ParentId; Before = $Before
    })
    if ($script:Ctx.LogPath) {
        try { Save-CALog $script:Ctx.LogPath }
        catch { Write-Warning "Protokoll konnte nicht gespeichert werden: $($_.Exception.Message)" }
    }
    $color = switch ($Action) {
        'angelegt'      { 'Green' }
        'aktualisiert'  { 'Green' }
        'warnung'       { 'Yellow' }
        'fehler'        { 'Red' }
        'würde anlegen' { 'Cyan' }
        'würde ändern'  { 'Cyan' }
        default         { 'Gray' }
    }
    $line = '[{0,-13}] {1}' -f $Action, $Object
    if ($Detail) { $line += "  ($Detail)" }
    Write-Host $line -ForegroundColor $color
}

function Save-CALog {
    param([Parameter(Mandatory)] [string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    # Erst in eine Temp-Datei, dann austauschen. So liegt nie eine halb geschriebene Datei da.
    $tmp = "$Path.tmp"
    ConvertTo-Json -InputObject @($script:Ctx.Log) -Depth 30 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $Path -Force
}

# Fragt interaktiv nach. Im nicht-interaktiven Modus kommt $null zurück.
function Read-CAInput([string]$Prompt) {
    if ($script:Ctx.NonInteractive -or $script:Ctx.ValidateOnly) { return $null }
    Read-Host $Prompt
}

# Platzhalter-ID für -WhatIf und -ValidateOnly, wenn ein Objekt noch nicht existiert
function New-FakeId([string]$Hint) {
    $script:Ctx.FakeCounter++
    '00000000-0000-0000-0000-{0:d12}' -f $script:Ctx.FakeCounter
}

# ===========================================================================
# Graph
# ===========================================================================

function Invoke-CAGraph {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)] [string]$Path,
        $Body,
        [switch]$Beta,
        [switch]$All
    )
    $base = if ($Beta) { 'https://graph.microsoft.com/beta' } else { 'https://graph.microsoft.com/v1.0' }
    $uri  = if ($Path -match '^https://') { $Path } else { "$base$Path" }

    $params = @{ Method = $Method; Uri = $uri; OutputType = 'HashTable' }
    if ($null -ne $Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 30 -Compress)
        $params.ContentType = 'application/json'
    }

    for ($attempt = 1; ; $attempt++) {
        try {
            if (-not $All) { return Invoke-MgGraphRequest @params }

            # Seitenweise lesen, bis kein nextLink mehr kommt
            $items = [System.Collections.Generic.List[object]]::new()
            $next  = $uri
            while ($next) {
                $params.Uri = $next
                $page = Invoke-MgGraphRequest @params
                foreach ($v in $page.value) { $items.Add($v) }
                $next = $page['@odata.nextLink']
            }
            # Bewusst ohne Komma-Operator: Aufrufer fassen das Ergebnis mit @() zusammen oder
            # leiten es weiter. Mit Komma würde @() eine leere Liste in eine Liste mit einem
            # leeren Element verwandeln.
            return $items.ToArray()
        }
        catch {
            # Drosselung (429) und kurzzeitige Fehler bis zu dreimal wiederholen
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($attempt -lt 4 -and $status -in 429, 503, 504) {
                Start-Sleep -Seconds (5 * $attempt)
                continue
            }
            throw
        }
    }
}

# Baut einen URL-kodierten $filter-Ausdruck "<Feld> eq '<Wert>'"
function Get-CAEqFilter([string]$Field, [string]$Value) {
    [uri]::EscapeDataString("$Field eq '$($Value.Replace("'", "''"))'")
}

# IDs aus New-FakeId gibt es im Tenant nicht, Graph darf damit nicht abgefragt werden
function Test-FakeId([string]$Id) { $Id -like '00000000-0000-0000-0000-*' }

# ===========================================================================
# Definitionen und Config
# ===========================================================================

function Read-CAJson([string]$Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
}

function Get-CADefinitions {
    $root = Join-Path $script:Ctx.RepoRoot 'definitions'
    [ordered]@{
        Personas        = (Read-CAJson (Join-Path $root 'groups/personas.json')).personas
        AdminUnit       = Read-CAJson (Join-Path $root 'administrative-units/AU-CA-Persona-Restricted.json')
        Breakglass      = Read-CAJson (Join-Path $root 'breakglass/breakglass.json')
        AuthStrengths   = @(Get-ChildItem (Join-Path $root 'authentication-strengths') -Filter *.json | Sort-Object Name | ForEach-Object { Read-CAJson $_.FullName })
        NamedLocations  = @(Get-ChildItem (Join-Path $root 'named-locations') -Filter *.json | Sort-Object Name | ForEach-Object { Read-CAJson $_.FullName })
        Policies        = @(Get-ChildItem (Join-Path $root 'conditional-access') -Filter *.json | Sort-Object Name | ForEach-Object { Read-CAJson $_.FullName })
        PasskeyProfiles = @((Read-CAJson (Join-Path $root 'authentication-methods/passkey-profiles.json')).profiles)
        AaguidCatalog   = $(
            $catalogPath = Join-Path $root 'authentication-methods/aaguid-catalog.json'
            if (Test-Path $catalogPath) { Read-CAJson $catalogPath } else { @{ products = @() } }
        )
    }
}

# Liefert einen Wert aus der Config über einen Punkt-Pfad, z. B. 'naming.groupNamePattern'
function Get-CAConfigValue([string]$PathExpr, $Default = $null) {
    $node = $script:Ctx.Config
    foreach ($part in $PathExpr -split '\.') {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($part)) { $node = $node[$part] }
        else { return $Default }
    }
    if ($null -eq $node) { return $Default }
    # Listen werden ausgerollt, Aufrufer fassen sie mit @() wieder zusammen
    $node
}

# Gruppenname einer Persona. Reihenfolge:
#   1. naming.groupNames.<Persona>   fester Name für genau diese Gruppe
#   2. naming.groupNamePattern       Schema mit {Persona}, {persona} oder {PERSONA}
# Für {Persona} gilt naming.personaLabels.<Persona>, falls gesetzt, sonst der Schlüssel.
# Bei einer Sub-Persona steht die Bezeichnung der Hauptpersona davor, z. B. Internals-VIP.
function Get-PersonaGroupName([string]$PersonaKey, [string]$ParentKey) {
    $fixed = Get-CAConfigValue "naming.groupNames.$PersonaKey"
    if ($fixed -and "$fixed".Trim()) { return "$fixed".Trim() }

    $labelOf = {
        param($k)
        $l = Get-CAConfigValue "naming.personaLabels.$k"
        if ($l -and "$l".Trim()) { "$l".Trim() } else { $k }
    }
    $label = & $labelOf $PersonaKey
    if ($ParentKey) { $label = "$(& $labelOf $ParentKey)-$label" }

    $pattern = "$(Get-CAConfigValue 'naming.groupNamePattern' 'SG-CA-Persona-{Persona}')".Trim()
    $pattern.Replace('{Persona}', $label).Replace('{persona}', $label.ToLowerInvariant()).Replace('{PERSONA}', $label.ToUpperInvariant())
}

# Wählt die Policies nach include/exclude aus der Config (Platzhalter * erlaubt)
function Select-CAPolicies($Policies, [string[]]$OnlyKeys) {
    $include = @(Get-CAConfigValue 'policies.include' @('*'))
    $exclude = @(Get-CAConfigValue 'policies.exclude' @())
    foreach ($p in $Policies) {
        $key = $p._deployer.key
        if ($OnlyKeys) {
            if (-not ($OnlyKeys | Where-Object { $key -like $_ })) { continue }
        }
        elseif (-not ($include | Where-Object { $key -like $_ })) { continue }
        if ($exclude | Where-Object { $key -like $_ }) { continue }
        $p
    }
}

# ===========================================================================
# Platzhalter
# ===========================================================================

# Löst eine tenantspezifische Eingabe auf. Gibt $null zurück, wenn die Policy übersprungen werden soll.
function Resolve-CAInput([System.Collections.IDictionary]$InputDef, [string]$Owner) {
    $name   = $InputDef.name
    $values = @(Get-CAConfigValue "inputs.$name" @())
    # "-" in der Config heißt: bewusst leer. Dann wird nicht nachgefragt.
    $confirmedEmpty = $values.Count -eq 1 -and "$($values[0])".Trim() -eq '-'
    if ($confirmedEmpty) { $values = @() }

    if ($values.Count -eq 0 -and $InputDef.required -and -not $confirmedEmpty) {
        if ($script:Ctx.ValidateOnly) {
            Write-CALog 'Prüfung' $Owner 'warnung' "Eingabe '$name' fehlt in der Config. Beim Deployment wird nachgefragt."
            $values = @('BEISPIEL')
        }
        else {
            Write-Host "`n$Owner braucht die Eingabe '$name':" -ForegroundColor Yellow
            Write-Host "  $($InputDef.hint)"
            $answer = Read-CAInput 'Werte kommagetrennt eingeben, "-" für bewusst leer, Enter zum Überspringen der Policy'
            if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
            # @() außen herum: Ein if-Ausdruck mit leerer Liste liefert sonst $null
            $values = @(if ($answer.Trim() -ne '-') { $answer -split ',' | ForEach-Object Trim | Where-Object { $_ } })
        }
    }

    switch ($InputDef.render) {
        'deviceFilterOrClause' {
            if ($values.Count -eq 0) { return '' }
            $parts = $values | ForEach-Object { '{0} -eq "{1}"' -f $InputDef.attribute, $_ }
            return "`n-or (" + ($parts -join ' -or ') + ')'
        }
        default { return ($values -join ',') }
    }
}

# Ersetzt Platzhalter rekursiv. {{group:AllPersonas}} in einer Liste wird zu mehreren Einträgen.
function Resolve-CANode($Node, [hashtable]$Inputs, [string]$Owner) {
    if ($Node -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in $Node.Keys) {
            if ($k -eq '_deployer') { continue }
            $out[$k] = Resolve-CANode $Node[$k] $Inputs $Owner
        }
        return $out
    }
    if ($Node -is [System.Collections.IList]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Node) {
            if ($item -is [string] -and $item -eq '{{group:AllPersonas}}') {
                foreach ($id in $script:Ctx.Groups.Values) { $list.Add($id) }
                continue
            }
            $list.Add((Resolve-CANode $item $Inputs $Owner))
        }
        return , $list.ToArray()
    }
    if ($Node -is [string] -and $Node.Contains('{{')) {
        return [regex]::Replace($Node, '\{\{(\w+):([^}]+)\}\}', {
            param($m)
            $kind = $m.Groups[1].Value; $key = $m.Groups[2].Value
            $table = switch ($kind) {
                'group'         { $script:Ctx.Groups }
                'namedLocation' { $script:Ctx.NamedLocations }
                'authStrength'  { $script:Ctx.AuthStrengths }
                'input'         { $Inputs }
                'unmapped'      { throw "$Owner enthält eine nicht zugeordnete ID ($key). Bitte in Sources/id-mapping.json zuordnen und neu konvertieren." }
                default         { throw "$Owner enthält einen unbekannten Platzhalter: $($m.Value)" }
            }
            if (-not $table.ContainsKey($key)) { throw "$Owner verweist auf $kind '$key', das im Tenant nicht vorhanden oder nicht ausgewählt ist." }
            $table[$key]
        })
    }
    $Node
}

# ===========================================================================
# Schritt: Named Locations
# ===========================================================================

# Liest die IP-Bereiche, die Zscaler für eine Cloud empfiehlt (Hub-Präfixe). Quelle ist die
# offizielle Konfigurationsseite des Herstellers. Gibt $null zurück, wenn der Abruf scheitert.
$script:ZscalerClouds = @('zscaler.net', 'zscalerone.net', 'zscalertwo.net', 'zscalerthree.net', 'zscloud.net', 'zscalerbeta.net', 'zscalergov.net', 'zscalerten.net', 'zspreview.net')
function Get-CAZscalerRanges([string]$Cloud) {
    if ($script:ZscalerClouds -notcontains $Cloud) { throw "Unbekannte Zscaler-Cloud '$Cloud'." }
    $url = "https://config.zscaler.com/api/$Cloud/hubs/cidr/json/recommended"
    $r = Invoke-RestMethod -Uri $url -TimeoutSec 20
    if ($r.cloudName -ne $Cloud -or -not @($r.hubPrefixes).Count) { throw "Antwort von $url hat nicht das erwartete Format." }
    [pscustomobject]@{ Cloud = $Cloud; Url = $url; Ranges = @($r.hubPrefixes | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9a-fA-F.:]+/\d{1,3}$' }) }
}

# Eigene Named Locations aus namedLocations.custom als Vorlagen im Graph-Format. Bei einer
# Location mit Quelle Zscaler holt der Deployer die Bereiche bei jedem Lauf neu ab, damit
# nie eine veraltete Liste im Tenant landet.
function Get-CACustomNamedLocations($Definitions) {
    $step = 'Named Locations'
    $templateNames = @($Definitions | ForEach-Object { $_.displayName })
    $seen = @{}
    foreach ($c in @(Get-CAConfigValue 'namedLocations.custom' @())) {
        if (-not $c) { continue }
        $name = "$($c['name'])".Trim()
        if (-not $name -or $name.Length -gt 256) { Write-CALog $step $name 'fehler' 'eigene Location übersprungen: Der Name ist leer oder länger als 256 Zeichen.'; continue }
        if ($templateNames -contains $name -or $seen.ContainsKey($name.ToLowerInvariant())) { Write-CALog $step $name 'fehler' 'eigene Location übersprungen: Den Namen gibt es schon.'; continue }
        $seen[$name.ToLowerInvariant()] = $true

        if ($c['type'] -eq 'country') {
            $countries = @($c['countriesAndRegions'] | Where-Object { $_ } | ForEach-Object { "$_".Trim().ToUpperInvariant() })
            if (-not $countries.Count) { Write-CALog $step $name 'fehler' 'eigene Location übersprungen: keine Länder ausgewählt.'; continue }
            [ordered]@{
                _deployer = [ordered]@{ key = $name; custom = $true }
                '@odata.type' = '#microsoft.graph.countryNamedLocation'
                displayName = $name
                countriesAndRegions = $countries
                includeUnknownCountriesAndRegions = [bool]$c['includeUnknownCountriesAndRegions']
                countryLookupMethod = 'clientIpAddress'
            }
            continue
        }

        $ranges = @($c['ipRanges'] | Where-Object { $_ } | ForEach-Object { "$_".Trim() })
        $src = $c['source']
        if ($src -and $src['vendor'] -eq 'zscaler' -and -not $script:Ctx.ValidateOnly) {
            try {
                $z = Get-CAZscalerRanges $src['cloud']
                $added = @($z.Ranges | Where-Object { $ranges -notcontains $_ }).Count
                $removed = @($ranges | Where-Object { $z.Ranges -notcontains $_ }).Count
                if ($added -or $removed) { Write-CALog $step $name 'info' "Zscaler-Liste für $($src['cloud']) hat sich seit dem Import geändert ($added neu, $removed entfallen). Verwendet wird die aktuelle Liste." }
                $ranges = $z.Ranges
            }
            catch { Write-CALog $step $name 'warnung' "Zscaler-Liste nicht abrufbar, verwendet wird der Stand aus dem Import: $($_.Exception.Message)" }
        }
        if (-not $ranges.Count) { Write-CALog $step $name 'fehler' 'eigene Location übersprungen: keine IP-Bereiche.'; continue }
        [ordered]@{
            _deployer = [ordered]@{ key = $name; custom = $true }
            '@odata.type' = '#microsoft.graph.ipNamedLocation'
            displayName = $name
            isTrusted = [bool]$c['trusted']
            ipRanges = @($ranges | ForEach-Object {
                $type = if ($_ -match ':') { '#microsoft.graph.iPv6CidrRange' } else { '#microsoft.graph.iPv4CidrRange' }
                [ordered]@{ '@odata.type' = $type; cidrAddress = $_ }
            })
        }
    }
}

function Sync-CANamedLocations($Definitions) {
    $step = 'Named Locations'
    $existing = if ($script:Ctx.ValidateOnly) { @() } else { Invoke-CAGraph -Path '/identity/conditionalAccess/namedLocations' -All }
    # Abgewählte Locations (namedLocations.skip) legt der Deployer nicht an. Gibt es sie schon im
    # Tenant, verwenden die Policies die vorhandene. Sonst überspringt er die Policies, die sie brauchen.
    $skip = @(Get-CAConfigValue 'namedLocations.skip' @())

    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Definitions) { $all.Add($d) }
    foreach ($c in Get-CACustomNamedLocations $Definitions) { $all.Add($c) }

    foreach ($def in $all) {
        $body = Resolve-CANode $def @{} $def.displayName
        $name = $body.displayName

        if ($skip -contains $name) {
            $current = $existing | Where-Object { $_.displayName -eq $name } | Select-Object -First 1
            if ($current) {
                $script:Ctx.NamedLocations[$name] = $current.id
                Write-CALog $step $name 'unverändert' 'abgewählt, die vorhandene Location wird verwendet'
            }
            else {
                $script:Ctx.SkippedNamedLocations[$name] = $true
                Write-CALog $step $name 'übersprungen' 'abgewählt (namedLocations.skip). Policies, die sie brauchen, werden übersprungen.'
            }
            continue
        }

        # Tenantspezifische Eingaben aus der Config übernehmen. Ohne Eingabe bleibt der Platzhalter aus der Vorlage
        # stehen (192.0.2.1/32 bzw. DE), weil Graph keine leeren Locations annimmt.
        $override = Get-CAConfigValue "inputs.namedLocations.$name"
        $provided = @()
        if ($override) {
            if ($override.Contains('ipRanges') -and @($override.ipRanges).Count) {
                $body.ipRanges = @($override.ipRanges | ForEach-Object {
                    $type = if ($_ -match ':') { '#microsoft.graph.iPv6CidrRange' } else { '#microsoft.graph.iPv4CidrRange' }
                    [ordered]@{ '@odata.type' = $type; cidrAddress = $_ }
                })
                $provided += 'ipRanges'
            }
            if ($override.Contains('countriesAndRegions') -and @($override.countriesAndRegions).Count) {
                $body.countriesAndRegions = @($override.countriesAndRegions)
                $provided += 'countriesAndRegions'
            }
        }
        $inputDefs = if ($def._deployer.Contains('customerInput')) { @($def._deployer.customerInput) } else { @() }
        foreach ($in in $inputDefs) {
            if ($in.Contains('placeholder') -and $provided -notcontains $in.name) {
                Write-CALog $step $name 'warnung' "enthält noch den Platzhalter $($in.placeholder). Echte Werte unter inputs.namedLocations in der Config eintragen."
            }
        }

        # Graph nimmt keine Länder-Location ohne Länder an. Sie wird übersprungen, und Policies,
        # die darauf verweisen, melden das später selbst.
        if ($body['@odata.type'] -eq '#microsoft.graph.countryNamedLocation' -and -not @($body.countriesAndRegions).Count) {
            Write-CALog $step $name 'übersprungen' 'keine Länder angegeben (inputs.namedLocations in der Config)'
            continue
        }

        $current = $existing | Where-Object { $_.displayName -eq $name } | Select-Object -First 1
        if ($script:Ctx.ValidateOnly) {
            $script:Ctx.NamedLocations[$name] = New-FakeId $name
            continue
        }
        try {
            if ($current) {
                $script:Ctx.NamedLocations[$name] = $current.id
                if ($script:Ctx.WhatIf) { Write-CALog $step $name 'würde ändern'; continue }
                Invoke-CAGraph -Method PATCH -Path "/identity/conditionalAccess/namedLocations/$($current.id)" -Body $body | Out-Null
                Write-CALog $step $name 'aktualisiert' -Kind NamedLocation -ObjectId $current.id -Before $current
            }
            else {
                if ($script:Ctx.WhatIf) { $script:Ctx.NamedLocations[$name] = New-FakeId $name; Write-CALog $step $name 'würde anlegen'; continue }
                $new = Invoke-CAGraph -Method POST -Path '/identity/conditionalAccess/namedLocations' -Body $body
                $script:Ctx.NamedLocations[$name] = $new.id
                Write-CALog $step $name 'angelegt' $new.id -Kind NamedLocation -ObjectId $new.id
            }
        }
        catch { Write-CALog $step $name 'fehler' (Get-CAErrorText $_) }
    }
}

# Kurzer Fehlertext aus einer Graph-Antwort statt des kompletten HTTP-Dumps
function Get-CAErrorText($ErrorRecord) {
    $details = if ($ErrorRecord.ErrorDetails) { $ErrorRecord.ErrorDetails.Message } else { '' }
    $text = "$details $($ErrorRecord.Exception.Message)"
    if ($text -match '"message"\s*:\s*"([^"]+)"') { return $Matches[1] }
    $ErrorRecord.Exception.Message
}

# ===========================================================================
# Schritt: Authentifizierungsstärken
# ===========================================================================

function Sync-CAAuthStrengths($Definitions) {
    $step = 'Authentifizierungsstärken'
    $existing = if ($script:Ctx.ValidateOnly) { @() } else { Invoke-CAGraph -Path '/policies/authenticationStrengthPolicies' -All | Where-Object { $_.policyType -eq 'custom' } }

    foreach ($def in $Definitions) {
        $key  = $def._deployer.key
        $body = Resolve-CANode $def @{} $key
        $name = $body.displayName

        if ($script:Ctx.ValidateOnly) { $script:Ctx.AuthStrengths[$key] = New-FakeId $key; continue }

        $current = $existing | Where-Object { $_.displayName -eq $name } | Select-Object -First 1
        if (-not $current) {
            if ($script:Ctx.WhatIf) { $script:Ctx.AuthStrengths[$key] = New-FakeId $key; Write-CALog $step $name 'würde anlegen'; continue }
            try {
                $new = Invoke-CAGraph -Method POST -Path '/policies/authenticationStrengthPolicies' -Body $body
                $script:Ctx.AuthStrengths[$key] = $new.id
                Write-CALog $step $name 'angelegt' $new.id -Kind AuthStrength -ObjectId $new.id
            }
            catch { Write-CALog $step $name 'fehler' (Get-CAErrorText $_) }
            continue
        }

        $script:Ctx.AuthStrengths[$key] = $current.id
        $want = @($body.allowedCombinations | Sort-Object)
        $have = @($current.allowedCombinations | Sort-Object)
        if (-not (Compare-Object $want $have) -and $current.description -eq $body.description) {
            Write-CALog $step $name 'unverändert'
            continue
        }
        if ($script:Ctx.WhatIf) { Write-CALog $step $name 'würde ändern' 'Kombinationen oder Beschreibung weichen ab'; continue }

        # Die erlaubten Kombinationen lassen sich nur über eine eigene Aktion ändern
        try {
            Invoke-CAGraph -Method PATCH -Path "/policies/authenticationStrengthPolicies/$($current.id)" -Body @{ displayName = $name; description = $body.description } | Out-Null
            Invoke-CAGraph -Method POST -Path "/policies/authenticationStrengthPolicies/$($current.id)/updateAllowedCombinations" -Body @{ allowedCombinations = $want } | Out-Null
            Write-CALog $step $name 'aktualisiert' -Kind AuthStrength -ObjectId $current.id -Before @{ description = $current.description; allowedCombinations = $have }
        }
        catch { Write-CALog $step $name 'fehler' (Get-CAErrorText $_) }
    }
}

# ===========================================================================
# Schritt: Persona-Gruppen
# ===========================================================================

# Legt eine Gruppe an oder findet sie über den Namen. Gibt die Objekt-ID zurück (im Prüf- und
# Probelauf eine Test-ID), bei einem Fehler $null.
function Sync-CAGroup([string]$Step, [string]$Key, [string]$Name, [string]$Description, [bool]$RoleAssignable, [string]$MembershipRule) {
    if ($script:Ctx.ValidateOnly) { return New-FakeId $Name }

    $current = @(Invoke-CAGraph -Path "/groups?`$filter=$(Get-CAEqFilter 'displayName' $Name)&`$select=id,displayName,isAssignableToRole,groupTypes,membershipRule" -All)
    if ($current.Count -gt 1) { throw "Es gibt $($current.Count) Gruppen mit dem Namen '$Name'. Bitte im Tenant bereinigen." }
    if ($current.Count -eq 1) {
        $g = $current[0]
        if ([bool]$g.isAssignableToRole -ne $RoleAssignable) {
            Write-CALog $Step $Name 'warnung' "isAssignableToRole ist $([bool]$g.isAssignableToRole), gewählt war $RoleAssignable. Das lässt sich nachträglich nicht ändern."
        }
        elseif ($MembershipRule -and $g.membershipRule -ne $MembershipRule) {
            Write-CALog $Step $Name 'warnung' "Dynamische Regel weicht ab: '$($g.membershipRule)'"
        }
        else { Write-CALog $Step $Name 'unverändert' }
        return $g.id
    }

    # mailNickname: nur ASCII ohne Sonderzeichen, höchstens 64 Zeichen
    $nick = $Name -replace '[^A-Za-z0-9\-_]', ''
    if (-not $nick) { $nick = "CAPersona$Key" -replace '[^A-Za-z0-9\-_]', '' }
    if ($nick.Length -gt 64) { $nick = $nick.Substring(0, 64) }
    $body = [ordered]@{
        displayName     = $Name
        description     = $Description
        mailEnabled     = $false
        mailNickname    = $nick
        securityEnabled = $true
    }
    # Nur das Flag. Eine Entra-Rolle wird diesen Gruppen nicht zugewiesen.
    if ($RoleAssignable) { $body.isAssignableToRole = $true }
    if ($MembershipRule) {
        $body.groupTypes                    = @('DynamicMembership')
        $body.membershipRule                = $MembershipRule
        $body.membershipRuleProcessingState = 'On'
    }

    if ($script:Ctx.WhatIf) { Write-CALog $Step $Name 'würde anlegen'; return New-FakeId $Name }
    try {
        $new = Invoke-CAGraph -Method POST -Path '/groups' -Body $body
        Write-CALog $Step $Name 'angelegt' $new.id -Kind Group -ObjectId $new.id
        return $new.id
    }
    catch { Write-CALog $Step $Name 'fehler' (Get-CAErrorText $_); return $null }
}

# role-assignable: Vorgabe aus personas.json, in der Config unter personas.roleAssignable änderbar
function Get-CARoleAssignable($Persona) {
    $override = Get-CAConfigValue "personas.roleAssignable.$($Persona.key)"
    if ($null -ne $override) { return [bool]$override }
    [bool]$Persona.isAssignableToRole
}

# Prüft die zusätzlichen Personas aus personas.additional. Liefert nur gültige Einträge.
# Regeln: eindeutiger Schlüssel, Sub-Personas hängen an genau einer Hauptpersona, und die
# Hauptpersona ist selbst keine Sub-Persona (keine Ketten).
function Get-CAAdditionalPersonas($Personas) {
    $step = 'Persona-Gruppen'
    $baseKeys = @($Personas | ForEach-Object { $_.key })
    $list = @(Get-CAConfigValue 'personas.additional' @())
    $mains = @($list | Where-Object { $_ -and -not $_['parent'] } | ForEach-Object { $_['key'] })
    $seen = @{}
    foreach ($e in $list) {
        if (-not $e) { continue }
        $key = "$($e['key'])".Trim()
        $parent = if ($e['parent']) { "$($e['parent'])".Trim() } else { $null }
        if ($key -notmatch '^[A-Za-z][A-Za-z0-9_]{0,39}$') { Write-CALog $step $key 'fehler' 'zusätzliche Persona übersprungen: Der Schlüssel darf nur Buchstaben, Ziffern und _ enthalten und muss mit einem Buchstaben beginnen.'; continue }
        if ($baseKeys -contains $key -or $seen.ContainsKey($key.ToLowerInvariant())) { Write-CALog $step $key 'fehler' 'zusätzliche Persona übersprungen: Den Schlüssel gibt es schon.'; continue }
        if ($parent -and -not ($baseKeys -contains $parent -or $mains -contains $parent)) { Write-CALog $step $key 'fehler' "zusätzliche Persona übersprungen: Die Hauptpersona '$parent' gibt es nicht oder sie ist selbst eine Sub-Persona."; continue }
        $seen[$key.ToLowerInvariant()] = $true
        [pscustomobject]@{
            Key = $key; Parent = $parent
            Description = if ($e['description']) { "$($e['description'])".Trim() } else { $null }
            RoleAssignable = [bool]$e['roleAssignable']
        }
    }
}

function Sync-CAPersonaGroups($Personas) {
    $step = 'Persona-Gruppen'
    foreach ($p in $Personas) {
        $name = Get-PersonaGroupName $p.key
        $id = Sync-CAGroup $step $p.key $name $p.description (Get-CARoleAssignable $p) $p.membershipRule
        if ($id) { $script:Ctx.Groups[$p.key] = $id }
    }

    # Zusätzliche Personas sind reine Sicherheitsgruppen. Sie landen bewusst nicht in
    # $script:Ctx.Groups, damit keine Policy und kein {{group:AllPersonas}} sie erfasst.
    foreach ($x in Get-CAAdditionalPersonas $Personas) {
        $name = Get-PersonaGroupName $x.Key $x.Parent
        $desc = if ($x.Description) { $x.Description }
                elseif ($x.Parent) { "CA Persona: Sub-Persona von $($x.Parent)" }
                else { 'CA Persona: zusätzliche Persona' }
        $id = Sync-CAGroup $step $x.Key $name $desc $x.RoleAssignable $null
        if ($id) { $script:Ctx.ExtraGroups[$x.Key] = $id }
    }
}

function Add-CAGroupMember([string]$GroupId, [string]$MemberId, [string]$Label, [string]$Step) {
    if (Test-FakeId $GroupId) { Write-CALog $Step $Label 'würde ändern' 'zur Gruppe hinzufügen'; return }
    $members = @(Invoke-CAGraph -Path "/groups/$GroupId/members?`$select=id" -All | ForEach-Object { $_.id })
    if ($members -contains $MemberId) { Write-CALog $Step $Label 'unverändert' 'bereits Mitglied'; return }
    if ($script:Ctx.WhatIf) { Write-CALog $Step $Label 'würde ändern' 'zur Gruppe hinzufügen'; return }
    Invoke-CAGraph -Method POST -Path "/groups/$GroupId/members/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$MemberId" } | Out-Null
    Write-CALog $Step $Label 'aktualisiert' 'zur Gruppe hinzugefügt' -Kind GroupMember -ObjectId $MemberId -ParentId $GroupId
}

# ===========================================================================
# Schritt: Breakglass-Konten
# ===========================================================================

function New-CAPassword([int]$Length) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+-=?@_'.ToCharArray()
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes($Length)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Sync-CABreakglass($Definition) {
    $step = 'Breakglass'
    $accounts = @(Get-CAConfigValue 'breakglassAccounts' @())

    if ($accounts.Count -eq 0 -and -not $script:Ctx.ValidateOnly) {
        Write-Host "`nIn der Config sind keine Breakglass-Konten eingetragen." -ForegroundColor Yellow
        $answer = Read-CAInput 'Vorhandene Breakglass-Konten als UPN kommagetrennt eingeben, oder Enter, um zwei neue anzulegen'
        if ($answer) { $accounts = @($answer -split ',' | ForEach-Object Trim | Where-Object { $_ }) }
    }

    if ($script:Ctx.ValidateOnly) {
        $info = if ($accounts.Count) { "$($accounts.Count) vorhandene Konten laut Config" } else { "keine in der Config, beim Deployment wird gefragt bzw. $($Definition.count) neue angelegt" }
        Write-CALog $step 'Breakglass-Konten' 'info' $info
        return
    }

    $groupId = $script:Ctx.Groups['Breakglass']
    $created = [System.Collections.Generic.List[object]]::new()

    if ($accounts.Count -eq 0) {
        $org = (Invoke-CAGraph -Path '/organization?$select=verifiedDomains').value[0]
        $initialDomain = ($org.verifiedDomains | Where-Object { $_.isInitial }).name

        for ($i = 1; $i -le $Definition.count; $i++) {
            $nr  = $i.ToString($Definition.numberFormat)
            $upn = $Definition.userPrincipalNamePattern.Replace('{Nr}', $nr).Replace('{InitialDomain}', $initialDomain)
            $accounts += $upn

            $exists = @(Invoke-CAGraph -Path "/users?`$filter=$(Get-CAEqFilter 'userPrincipalName' $upn)&`$select=id" -All)
            if ($exists.Count) { Write-CALog $step $upn 'unverändert' 'Konto existiert bereits'; continue }
            if ($script:Ctx.WhatIf) { Write-CALog $step $upn 'würde anlegen'; continue }

            $password = New-CAPassword $Definition.passwordLength
            $body = [ordered]@{
                accountEnabled    = $true
                displayName       = $Definition.displayNamePattern.Replace('{Nr}', $nr)
                mailNickname      = ($upn -split '@')[0]
                userPrincipalName = $upn
                passwordPolicies  = 'DisablePasswordExpiration'
                passwordProfile   = @{ password = $password; forceChangePasswordNextSignIn = $false }
            }
            $new = Invoke-CAGraph -Method POST -Path '/users' -Body $body
            Write-CALog $step $upn 'angelegt' $new.id -Kind User -ObjectId $new.id
            $created.Add([pscustomobject]@{ UserPrincipalName = $upn; Password = $password })
        }
    }

    foreach ($upn in $accounts) {
        $user = @(Invoke-CAGraph -Path "/users?`$filter=$(Get-CAEqFilter 'userPrincipalName' $upn)&`$select=id" -All)
        if (-not $user.Count) {
            if ($script:Ctx.WhatIf) { Write-CALog $step $upn 'würde ändern' 'nach dem Anlegen zur Breakglass-Gruppe hinzufügen'; continue }
            Write-CALog $step $upn 'fehler' 'Konto nicht gefunden'
            continue
        }
        Add-CAGroupMember $groupId $user[0].id $upn $step
    }

    # Kennwörter nur einmal zeigen, nie ins Protokoll schreiben. Unter der Weboberfläche gehen sie
    # über eine eigene Zeile an den Browser, die der Server aus der normalen Ausgabe herausfiltert.
    if ($created.Count -and $env:CABASELINE_GUI) {
        foreach ($c in $created) {
            [Console]::Out.WriteLine('##CABASELINE-SECRET## ' + ([ordered]@{ userPrincipalName = $c.UserPrincipalName; password = $c.Password } | ConvertTo-Json -Compress))
        }
        [Console]::Out.Flush()
        Write-Host 'Kennwörter der neuen Breakglass-Konten werden einmalig in der Oberfläche angezeigt.' -ForegroundColor Red
        Clear-Variable created
    }
    elseif ($created.Count) {
        Write-Host "`n================ BREAKGLASS-KENNWÖRTER ================" -ForegroundColor Red
        Write-Host 'Werden nur jetzt angezeigt und nirgends gespeichert. Sofort im Tresor ablegen.' -ForegroundColor Red
        $created | Format-Table -AutoSize | Out-Host
        Write-Host '=======================================================' -ForegroundColor Red
        if (-not $script:Ctx.NonInteractive) { Read-Host 'Enter, sobald die Kennwörter gesichert sind' | Out-Null }
        Clear-Variable created
    }
}

# ===========================================================================
# Schritt: Restricted Management Administrative Unit
# ===========================================================================

function Sync-CARestrictedAU($Definition, $Personas) {
    $step = 'Restricted AU'
    $name = Get-CAConfigValue 'naming.administrativeUnitName' $Definition.displayName
    $protected = @($Personas | Where-Object { $_.restrictedAdministrativeUnit })

    if ($script:Ctx.ValidateOnly) {
        Write-CALog $step $name 'info' ("wird leer angelegt. Später aufnehmen: " + (($protected | ForEach-Object { Get-PersonaGroupName $_.key }) -join ', '))
        return
    }

    $all = Invoke-CAGraph -Path '/directory/administrativeUnits?$select=id,displayName,isMemberManagementRestricted' -All
    $au  = $all | Where-Object { $_.displayName -eq $name } | Select-Object -First 1

    if ($au -and -not $au.isMemberManagementRestricted) {
        throw "Die AU '$name' existiert, ist aber keine Restricted Management AU. Bitte in naming.administrativeUnitName einen anderen Namen wählen."
    }
    if (-not $au) {
        if ($script:Ctx.WhatIf) { Write-CALog $step $name 'würde anlegen'; return }
        $body = Resolve-CANode $Definition @{} $name
        $body.displayName = $name
        $au = Invoke-CAGraph -Method POST -Path '/directory/administrativeUnits' -Body $body
        Write-CALog $step $name 'angelegt' $au.id -Kind AdminUnit -ObjectId $au.id
    }
    else { Write-CALog $step $name 'unverändert' }

    # Die AU bleibt leer. Liegen die Gruppen erst in der AU, können tenant-weite Admins ihre
    # Mitglieder nicht mehr pflegen. Deshalb nimmst du sie selbst auf, sobald die
    # Mitglieder stehen.
    $intended = ($protected | ForEach-Object { Get-PersonaGroupName $_.key }) -join ', '
    Write-CALog $step $name 'info' "bleibt leer. Später aufnehmen: $intended"
}

# ===========================================================================
# Schritt: Authentifizierungsmethoden sicherstellen (additiv)
# ===========================================================================

# Welche Methode der Methodenrichtlinie eine Kombination in einer Stärke braucht
$script:CombinationToMethod = @{
    'fido2'                       = 'Fido2'
    'deviceBasedPush'             = 'MicrosoftAuthenticator'
    'microsoftAuthenticatorPush'  = 'MicrosoftAuthenticator'
    'temporaryAccessPassOneTime'  = 'TemporaryAccessPass'
    'temporaryAccessPassMultiUse' = 'TemporaryAccessPass'
    'x509CertificateMultiFactor'  = 'X509Certificate'
    'x509CertificateSingleFactor' = 'X509Certificate'
    'windowsHelloForBusiness'     = 'WindowsHelloForBusiness'
}

function Sync-CAAuthMethods($Strengths, $PasskeyProfiles, $AaguidCatalog) {
    $step = 'Authentifizierungsmethoden'

    $needed = @{}
    foreach ($s in $Strengths) {
        foreach ($combo in $s.allowedCombinations) {
            foreach ($part in $combo -split ',') {
                $method = $script:CombinationToMethod[$part.Trim()]
                if ($method) { $needed[$method] = $true }
            }
        }
    }

    $allPersonaIds = @($script:Ctx.Groups.Values)
    $passkeyIds = @(@(Get-CAConfigValue 'authenticationMethods.passkeyPersonas' @('Admins')) | ForEach-Object { $script:Ctx.Groups[$_] } | Where-Object { $_ })

    foreach ($method in $needed.Keys | Sort-Object) {
        if ($method -eq 'WindowsHelloForBusiness') {
            Write-CALog $step 'Windows Hello for Business' 'info' 'wird in Intune konfiguriert, nicht in der Methodenrichtlinie'
            continue
        }
        if ($method -eq 'X509Certificate') {
            if ($script:Ctx.ValidateOnly) { Write-CALog $step 'Zertifikat (CBA)' 'info' 'wird nur geprüft'; continue }
            $cfg = Invoke-CAGraph -Path '/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/X509Certificate'
            if ($cfg.state -ne 'enabled') {
                Write-CALog $step 'Zertifikat (CBA)' 'warnung' 'nicht aktiviert. Ohne hinterlegte Zertifizierungsstelle bringt Einschalten nichts, deshalb bleibt es aus.'
            }
            else { Write-CALog $step 'Zertifikat (CBA)' 'unverändert' 'aktiviert' }
            continue
        }

        $targets = @(if ($method -eq 'Fido2') { $passkeyIds } else { $allPersonaIds })
        $label   = @{ Fido2 = 'Passkey (FIDO2)'; MicrosoftAuthenticator = 'Microsoft Authenticator'; TemporaryAccessPass = 'Temporary Access Pass' }[$method]

        if ($method -eq 'Fido2') {
            Sync-CAFido2 -Targets $targets -Label $label -Profiles (Resolve-CAPasskeyProfiles $PasskeyProfiles $AaguidCatalog)
            continue
        }

        if ($script:Ctx.ValidateOnly) { Write-CALog $step $label 'info' "Ziele: $($targets.Count) Gruppe(n)"; continue }

        $path = "/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/$method"
        $cfg  = Invoke-CAGraph -Path $path
        if (-not $cfg.ContainsKey('includeTargets')) { $cfg = Invoke-CAGraph -Path "$path`?`$expand=includeTargets" }

        $include = @($cfg.includeTargets)
        $exclude = @($cfg.excludeTargets)

        foreach ($t in $exclude) {
            if ($targets -contains $t.id) { Write-CALog $step $label 'warnung' "Persona-Gruppe $($t.id) ist in der Methode ausgeschlossen. Das entscheidest du selbst." }
        }

        # Eine aktivierte Methode hast du bewusst konfiguriert. Der Deployer ändert sie
        # nicht, auch keine Ziele. Er meldet nur, ob die Persona-Gruppen abgedeckt sind.
        if ($cfg.state -eq 'enabled') {
            $includeIds = @($include | ForEach-Object { $_.id })
            if ($includeIds -contains 'all_users') { Write-CALog $step $label 'unverändert' 'für alle Benutzer aktiviert'; continue }
            $uncovered = @($targets | Where-Object { $includeIds -notcontains $_ })
            if ($uncovered.Count) {
                Write-CALog $step $label 'warnung' "aktiviert, aber $($uncovered.Count) Persona-Gruppe(n) sind kein Ziel. Nicht geändert, weil die Methode schon aktiv ist. Bei Bedarf von Hand ergänzen."
            }
            else { Write-CALog $step $label 'unverändert' 'aktiviert, Persona-Gruppen abgedeckt' }
            continue
        }

        # Bei einer deaktivierten Methode wirken die hinterlegten Ziele nicht. Würde der Deployer
        # sie beim Einschalten übernehmen, wären z. B. Passkeys plötzlich für alle Benutzer frei.
        # Deshalb gelten nach dem Einschalten nur die Persona-Gruppen.
        $missing    = $targets
        $newTargets = [System.Collections.Generic.List[object]]::new()
        foreach ($gid in $missing) {
            $t = [ordered]@{ targetType = 'group'; id = $gid; isRegistrationRequired = $false }
            if ($method -eq 'MicrosoftAuthenticator') {
                $t['@odata.type'] = '#microsoft.graph.microsoftAuthenticatorAuthenticationMethodTarget'
                $t.authenticationMode = 'any'
            }
            $newTargets.Add($t)
        }

        $detail = "war deaktiviert, jetzt aktiv für $($missing.Count) Persona-Gruppe(n)"
        if ($script:Ctx.WhatIf) { Write-CALog $step $label 'würde ändern' $detail; continue }

        $body = [ordered]@{
            '@odata.type'  = $cfg['@odata.type']
            state          = 'enabled'
            includeTargets = $newTargets.ToArray()
        }
        $before = [ordered]@{ '@odata.type' = $cfg['@odata.type']; state = $cfg.state; includeTargets = @($include) }
        try {
            Invoke-CAGraph -Method PATCH -Path $path -Body $body | Out-Null
            Write-CALog $step $label 'aktualisiert' $detail -Kind AuthMethod -ObjectId $method -Before $before
        }
        catch { Write-CALog $step $label 'fehler' (Get-CAErrorText $_) }
    }
}

# ---------------------------------------------------------------------------
# Passkey-Profile
# ---------------------------------------------------------------------------

# Optionale Hardware-Produkte (z. B. YubiKeys) für ein Profil. Steht die Liste in der Config
# (authenticationMethods.passkeyHardwareProducts), gilt sie. Sonst fragt der Deployer einmal
# nach und merkt sich die Antwort für den Rest des Laufs.
function Select-CAOptionalProducts([string]$Pattern, [System.Collections.IDictionary]$Products) {
    $step = 'Authentifizierungsmethoden'
    $candidates = @($Products.Values | Where-Object { $_.name -like "*$Pattern*" } | Sort-Object name)
    if (-not $candidates.Count) { return @() }

    $configured = Get-CAConfigValue 'authenticationMethods.passkeyHardwareProducts'
    if ($null -ne $configured) {
        $keys = @($configured)
        foreach ($k in @($keys | Where-Object { -not $Products.Contains($_) })) {
            Write-CALog $step 'Passkey-Profile' 'warnung' "Produkt '$k' aus der Config steht nicht im AAGUID-Katalog"
        }
        return @($keys | Where-Object { $Products.Contains($_) })
    }

    if ($script:Ctx.OptionalProducts.Contains($Pattern)) { return $script:Ctx.OptionalProducts[$Pattern] }

    $chosen = @()
    if (-not ($script:Ctx.NonInteractive -or $script:Ctx.ValidateOnly)) {
        Write-Host "`nWelche $Pattern-Produkte sollen im Profil für privilegierte Konten erlaubt sein?" -ForegroundColor Cyan
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $fw = ($candidates[$i].aaguids | ForEach-Object { $_.firmware }) -join ', '
            Write-Host ('  {0,2}  {1}  (Firmware {2})' -f ($i + 1), $candidates[$i].name, $fw)
        }
        $answer = Read-Host 'Nummern mit Komma trennen, Enter oder - für keins'
        $chosen = @(@(foreach ($n in @($answer -split '[,; ]+' | Where-Object { $_ -match '^\d+$' })) {
            $idx = [int]$n - 1
            if ($idx -ge 0 -and $idx -lt $candidates.Count) { $candidates[$idx].key }
        }) | Select-Object -Unique)
        $text = if ($chosen.Count) { $chosen -join ', ' } else { 'keins' }
        Write-CALog $step 'Passkey-Profile' 'info' "$Pattern-Auswahl: $text. Für den nächsten Lauf unter authenticationMethods.passkeyHardwareProducts in die Config übernehmen."
    }
    $script:Ctx.OptionalProducts[$Pattern] = @($chosen)
    @($chosen)
}

# Welche Persona welches Passkey-Profil bekommt. Personas aus authenticationMethods.passkeyPersonas,
# das Profil je Persona aus authenticationMethods.passkeyProfileByPersona (Standard: Privileged).
# Admins bekommen immer das Profil für privilegierte Konten.
function Get-CAPasskeyPersonaProfiles {
    $map = [ordered]@{}
    foreach ($persona in @(Get-CAConfigValue 'authenticationMethods.passkeyPersonas' @('Admins'))) {
        if (-not $persona) { continue }
        $prof = Get-CAConfigValue "authenticationMethods.passkeyProfileByPersona.$persona" 'Privileged'
        if ($persona -eq 'Admins') { $prof = 'Privileged' }
        $map[$persona] = $prof
    }
    $map
}

# Macht aus den Profilvorlagen fertige Graph-Objekte: AAGUIDs aus dem Katalog, Personas aus der Config
function Resolve-CAPasskeyProfiles($Profiles, $Catalog) {
    $step = 'Authentifizierungsmethoden'
    $products = [ordered]@{}
    foreach ($p in @($Catalog.products)) { $products[$p.key] = $p }

    foreach ($def in @($Profiles)) {
        $meta = $def._deployer
        $productKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($k in @($meta['aaguidProducts'])) { if ($k) { $productKeys.Add($k) } }
        if ($meta['optionalProducts']) {
            foreach ($k in Select-CAOptionalProducts $meta['optionalProducts'] $products) { $productKeys.Add($k) }
        }

        $aaguids = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $productKeys) {
            if (-not $products.Contains($k)) { Write-CALog $step $def.name 'warnung' "Produkt '$k' steht nicht im AAGUID-Katalog"; continue }
            foreach ($a in $products[$k].aaguids) { if (-not $aaguids.Contains($a.aaguid)) { $aaguids.Add($a.aaguid) } }
        }

        # Eine Positivliste ohne Einträge würde jeden Passkey sperren. Dann das Profil lieber weglassen.
        if ($def.keyRestrictions.isEnforced -and $def.keyRestrictions.enforcementType -eq 'allow' -and $aaguids.Count -eq 0) {
            Write-CALog $step $def.name 'warnung' 'nicht angelegt: Die Positivliste wäre leer und würde alle Passkeys sperren. AAGUID-Katalog mit tools/Update-AaguidCatalog.ps1 erzeugen.'
            continue
        }

        $pmap = Get-CAPasskeyPersonaProfiles
        $personas = @($pmap.Keys | Where-Object { $pmap[$_] -eq $meta.key })

        [pscustomobject]@{
            Key      = $meta.key
            Name     = $def.name
            Personas = @($personas | Where-Object { $_ })
            Body     = [ordered]@{
                name                   = $def.name
                passkeyTypes           = $def.passkeyTypes
                attestationEnforcement = $def.attestationEnforcement
                keyRestrictions        = [ordered]@{
                    isEnforced      = [bool]$def.keyRestrictions.isEnforced
                    enforcementType = $def.keyRestrictions.enforcementType
                    aaGuids         = $aaguids.ToArray()
                }
            }
        }
    }
}

# Passkey (FIDO2) mit Profilen. Regeln wie bei den anderen Methoden: Ist die Methode aktiv,
# bleiben Status und Ziele unverändert. Fehlende Profile legt der Deployer trotzdem an, weil das
# nichts an bestehenden Zuweisungen ändert. Ist sie deaktiviert, wird sie für die Persona-Gruppen
# eingeschaltet, jeweils mit dem Profil, das für die Persona vorgesehen ist.
function Sync-CAFido2([string[]]$Targets, [string]$Label, [object[]]$Profiles) {
    $step = 'Authentifizierungsmethoden'
    $maxProfiles = 3

    if ($script:Ctx.ValidateOnly) {
        foreach ($p in $Profiles) {
            $who = if ($p.Personas.Count) { $p.Personas -join ', ' } else { 'keiner Gruppe zugewiesen' }
            Write-CALog $step $p.Name 'info' "Passkey-Profil mit $($p.Body.keyRestrictions.aaGuids.Count) AAGUID(s), $who"
        }
        Write-CALog $step $Label 'info' "Ziele: $($Targets.Count) Gruppe(n)"
        return
    }

    $path = '/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2'
    $cfg  = Invoke-CAGraph -Path $path
    if (-not $cfg.ContainsKey('includeTargets')) { $cfg = Invoke-CAGraph -Path "$path`?`$expand=includeTargets" }
    $include  = @($cfg.includeTargets)
    $existing = @(if ($cfg.ContainsKey('passkeyProfiles')) { $cfg.passkeyProfiles })

    foreach ($t in @($cfg.excludeTargets)) {
        if ($Targets -contains $t.id) { Write-CALog $step $Label 'warnung' "Persona-Gruppe $($t.id) ist in der Methode ausgeschlossen. Das entscheidest du selbst." }
    }

    # Umstellung auf Profile: lässt sich laut Microsoft nicht zurücknehmen, deshalb nur nach Rückfrage
    $useProfiles = $existing.Count -gt 0
    $migrate = $false
    if (-not $useProfiles -and $Profiles.Count) {
        # authenticationMethods.migrateToPasskeyProfiles in der Config ersetzt die Rückfrage
        $consent = Get-CAConfigValue 'authenticationMethods.migrateToPasskeyProfiles'
        $answer  = if ($null -ne $consent) { if ($consent) { 'j' } else { 'n' } }
                   else { Read-CAInput 'Der Tenant ist noch nicht auf Passkey-Profile umgestellt. Jetzt umstellen? Das lässt sich nicht zurücknehmen. (j/N)' }
        if ($answer -match '^(j|ja|y|yes)$') { $migrate = $true; $useProfiles = $true }
        else { Write-CALog $step 'Passkey-Profile' 'warnung' 'nicht angelegt, weil der Tenant nicht auf Passkey-Profile umgestellt ist. Umstellen im Portal unter Passkey (FIDO2) oder beim nächsten Lauf bestätigen.' }
    }

    $profileIds  = @{}
    $newProfiles = [System.Collections.Generic.List[object]]::new()
    if ($useProfiles) {
        $free = $maxProfiles - $existing.Count
        foreach ($p in $Profiles) {
            $hit = $existing | Where-Object { $_.name -eq $p.Name } | Select-Object -First 1
            if ($hit) {
                $profileIds[$p.Key] = $hit.id
                $want = @($p.Body.keyRestrictions.aaGuids | Sort-Object)
                $have = @($hit.keyRestrictions.aaGuids | Sort-Object)
                if (Compare-Object $want $have) { Write-CALog $step $p.Name 'warnung' 'Passkey-Profil existiert mit anderen AAGUIDs. Nicht geändert, bei Bedarf von Hand anpassen.' }
                else { Write-CALog $step $p.Name 'unverändert' 'Passkey-Profil vorhanden' }
                continue
            }
            if ($free -le 0) { Write-CALog $step $p.Name 'warnung' "nicht angelegt, der Tenant hat schon $maxProfiles Passkey-Profile"; continue }
            $body = [ordered]@{ id = [guid]::NewGuid().ToString() }
            foreach ($k in $p.Body.Keys) { $body[$k] = $p.Body[$k] }
            $newProfiles.Add($body)
            $profileIds[$p.Key] = $body.id
            $free--
        }
    }
    $defaultProfile = if ($cfg.ContainsKey('defaultPasskeyProfile') -and $cfg.defaultPasskeyProfile) { $cfg.defaultPasskeyProfile } else { '00000000-0000-0000-0000-000000000001' }

    # Für jede Persona-Gruppe die Profile, die laut Vorlage für ihre Persona gedacht sind
    $personaOf = @{}
    foreach ($k in $script:Ctx.Groups.Keys) { $personaOf[$script:Ctx.Groups[$k]] = $k }
    $profilesFor = {
        param($gid)
        @($Profiles | Where-Object { $_.Personas -contains $personaOf[$gid] -and $profileIds.ContainsKey($_.Key) } | ForEach-Object { $profileIds[$_.Key] })
    }

    $body = [ordered]@{ '@odata.type' = $cfg['@odata.type'] }
    $changes = [System.Collections.Generic.List[string]]::new()
    if ($newProfiles.Count) {
        $body.passkeyProfiles = @($existing) + $newProfiles.ToArray()
        $changes.Add('Passkey-Profile angelegt: ' + (($newProfiles | ForEach-Object { $_.name }) -join ', '))
    }

    if ($cfg.state -eq 'enabled') {
        $includeIds = @($include | ForEach-Object { $_.id })
        if ($includeIds -contains 'all_users') {
            Write-CALog $step $Label 'warnung' 'ist bereits für alle Benutzer aktiviert. Der Deployer ändert das nicht, das entscheidest du.'
        }
        else {
            $uncovered = @($Targets | Where-Object { $includeIds -notcontains $_ })
            if ($uncovered.Count) { Write-CALog $step $Label 'warnung' "aktiviert, aber $($uncovered.Count) Persona-Gruppe(n) sind kein Ziel. Nicht geändert, weil die Methode schon aktiv ist. Bei Bedarf von Hand ergänzen." }
            else { Write-CALog $step $Label 'unverändert' 'aktiviert, Persona-Gruppen abgedeckt' }
        }
        foreach ($t in @($include | Where-Object { $Targets -contains $_.id })) {
            $wanted  = @(& $profilesFor $t.id)
            $missing = @($wanted | Where-Object { @($t.allowedPasskeyProfiles) -notcontains $_ })
            if ($missing.Count) {
                Write-CALog $step $Label 'warnung' "Persona $($personaOf[$t.id]) ist Ziel, aber ohne das vorgesehene Passkey-Profil. Nicht geändert, weil die Methode schon aktiv ist. Profil im Portal unter Enable and Target zuweisen."
            }
        }
    }
    else {
        $newTargets = foreach ($gid in $Targets) {
            $t = [ordered]@{ targetType = 'group'; id = $gid; isRegistrationRequired = $false }
            if ($useProfiles) {
                $allowed = @(& $profilesFor $gid)
                if (-not $allowed.Count) { $allowed = @($defaultProfile) }
                $t['@odata.type'] = '#microsoft.graph.passkeyAuthenticationMethodTarget'
                $t.allowedPasskeyProfiles = @($allowed)
            }
            $t
        }
        $body.state = 'enabled'
        $body.includeTargets = @($newTargets)
        $changes.Add("war deaktiviert, jetzt aktiv für $(@($Targets).Count) Persona-Gruppe(n)")
    }

    if (-not $changes.Count) { return }
    $detail = $changes -join '; '
    if ($script:Ctx.WhatIf) {
        if ($migrate) { $detail = "Umstellung auf Passkey-Profile; $detail" }
        Write-CALog $step $Label 'würde ändern' $detail
        return
    }

    $before = [ordered]@{ '@odata.type' = $cfg['@odata.type']; state = $cfg.state; includeTargets = @($include) }
    if ($existing.Count) { $before.passkeyProfiles = @($existing) }
    try {
        Invoke-CAGraph -Method PATCH -Path $path -Body $body | Out-Null
        Write-CALog $step $Label 'aktualisiert' $detail -Kind AuthMethod -ObjectId 'Fido2' -Before $before
        if ($migrate) { Write-CALog $step $Label 'info' 'Tenant auf Passkey-Profile umgestellt. Das bleibt auch nach einem Undo so.' }
    }
    catch { Write-CALog $step $Label 'fehler' (Get-CAErrorText $_) }
}

# ===========================================================================
# Schritt: Service Principals der referenzierten Microsoft-Apps
# ===========================================================================

# App-ID und Zweck. Fehlt der Service Principal, scheitert die Registrierung von Passkeys in
# Microsoft Authenticator.
$script:RequiredServicePrincipals = [ordered]@{
    '6aa00308-ea33-4caa-90d6-ae905d8cb51b' = 'der Registrierung von Passkeys im Authenticator'
}

function Sync-CAServicePrincipals($Policies) {
    $step = 'Service Principals'
    $appIds = @{}
    # Apps, die der Tenant unabhängig von den ausgewählten Policies braucht
    foreach ($fixed in $script:RequiredServicePrincipals.GetEnumerator()) {
        $appIds[$fixed.Key] = [System.Collections.Generic.List[string]]::new()
        $appIds[$fixed.Key].Add($fixed.Value)
    }
    foreach ($p in $Policies) {
        $apps = $p.conditions.applications
        if (-not $apps) { continue }
        foreach ($a in @($apps.includeApplications) + @($apps.excludeApplications)) {
            if ($a -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                if (-not $appIds.ContainsKey($a)) { $appIds[$a] = [System.Collections.Generic.List[string]]::new() }
                $appIds[$a].Add($p._deployer.key)
            }
        }
    }

    foreach ($appId in $appIds.Keys | Sort-Object) {
        $usedBy = ($appIds[$appId] | Sort-Object -Unique) -join ', '
        if ($script:Ctx.ValidateOnly) { Write-CALog $step $appId 'info' "verwendet in $usedBy"; continue }

        $sp = @(Invoke-CAGraph -Path "/servicePrincipals?`$filter=appId eq '$appId'&`$select=id,displayName" -All)
        if ($sp.Count) { Write-CALog $step "$($sp[0].displayName) ($appId)" 'unverändert' 'im Tenant registriert'; continue }

        if ($script:Ctx.WhatIf) { Write-CALog $step $appId 'würde anlegen' "fehlt im Tenant, verwendet in $usedBy"; continue }
        try {
            $new = Invoke-CAGraph -Method POST -Path '/servicePrincipals' -Body @{ appId = $appId }
            Write-CALog $step "$($new.displayName) ($appId)" 'angelegt' "war nicht registriert, verwendet in $usedBy" -Kind ServicePrincipal -ObjectId $new.id
        }
        catch {
            Write-CALog $step $appId 'fehler' "Registrierung fehlgeschlagen: $(Get-CAErrorText $_). Betroffen: $usedBy"
        }
    }
}

# ===========================================================================
# Schritt: Conditional-Access-Policies
# ===========================================================================

function Sync-CAPolicies($Policies) {
    $step = 'CA-Policies'
    $stateOnCreate = Get-CAConfigValue 'policies.stateOnCreate' 'enabledForReportingButNotEnforced'
    $existing = if ($script:Ctx.ValidateOnly) { @() } else { Invoke-CAGraph -Beta -Path '/identity/conditionalAccess/policies' -All }

    foreach ($p in $Policies) {
        $key = $p._deployer.key

        # Tenantspezifische Eingaben auflösen. Fehlt eine Pflichtangabe, wird die Policy übersprungen.
        $inputs = @{}
        $skip = $false
        foreach ($def in @($p._deployer.customerInput)) {
            if (-not $def) { continue }
            $value = Resolve-CAInput $def $key
            if ($null -eq $value) { $skip = $true; break }
            $inputs[$def.name] = $value
        }
        if ($skip) { Write-CALog $step $key 'übersprungen' 'Eingabe fehlt'; continue }

        # Verweist die Policy auf eine abgewählte Named Location, wird sie übersprungen
        $json = ConvertTo-Json -InputObject $p -Depth 30 -Compress
        $missingNl = @([regex]::Matches($json, '\{\{namedLocation:([^}]+)\}\}') | ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $script:Ctx.SkippedNamedLocations.Contains($_) } | Select-Object -Unique)
        if ($missingNl.Count) { Write-CALog $step $key 'übersprungen' "braucht die abgewählte Named Location $($missingNl -join ', ')"; continue }

        try { $body = Resolve-CANode $p $inputs $key }
        catch { Write-CALog $step $key 'fehler' $_.Exception.Message; continue }

        $name    = $body.displayName
        $current = $existing | Where-Object { $_.displayName -eq $name } | Select-Object -First 1

        if ($script:Ctx.ValidateOnly) { Write-CALog $step $name 'info' 'Platzhalter aufgelöst'; continue }

        if ($current) {
            # Der Status einer bestehenden Policy bleibt, wie du ihn gesetzt hast
            $body.Remove('state')
            if ($script:Ctx.WhatIf) { Write-CALog $step $name 'würde ändern' "Status bleibt $($current.state)"; continue }
            try {
                Invoke-CAGraph -Beta -Method PATCH -Path "/identity/conditionalAccess/policies/$($current.id)" -Body $body | Out-Null
                Write-CALog $step $name 'aktualisiert' "Status bleibt $($current.state)" -Kind CAPolicy -ObjectId $current.id -Before $current
            }
            catch { Write-CALog $step $name 'fehler' (Get-CAErrorText $_) }
        }
        else {
            $body.state = $stateOnCreate
            if ($script:Ctx.WhatIf) { Write-CALog $step $name 'würde anlegen' "Status $stateOnCreate"; continue }
            try {
                $new = Invoke-CAGraph -Beta -Method POST -Path '/identity/conditionalAccess/policies' -Body $body
                Write-CALog $step $name 'angelegt' "Status $stateOnCreate" -Kind CAPolicy -ObjectId $new.id
            }
            catch { Write-CALog $step $name 'fehler' (Get-CAErrorText $_) }
        }
    }
}

# ===========================================================================
# Anmeldung
# ===========================================================================

function Connect-CABaseline {
    $tenantId = Get-CAConfigValue 'tenant.tenantId'
    $clientId = Get-CAConfigValue 'tenant.deployerAppClientId'
    $connect  = @{ TenantId = $tenantId; Scopes = (Get-CARequiredScopes); NoWelcome = $true }
    if ($clientId -and $clientId -ne '00000000-0000-0000-0000-000000000000') { $connect.ClientId = $clientId }
    else { Write-Warning 'Keine deployerAppClientId in der Config. Anmeldung über die Standard-App "Microsoft Graph Command Line Tools".' }

    Connect-MgGraph @connect
    $ctx = Get-MgContext
    if ($ctx.TenantId -ne $tenantId) { throw "Angemeldet im Tenant $($ctx.TenantId), die Config gehört zu $tenantId. Abbruch." }
    Write-Host "Angemeldet als $($ctx.Account) im Tenant $($ctx.TenantId)" -ForegroundColor Cyan
}

# ===========================================================================
# Rücknahme eines Deployments anhand seines Protokolls
# ===========================================================================

function Get-CAHttpStatus($ErrorRecord) {
    $status = $null
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { }
    if (-not $status -and (Get-CAErrorText $ErrorRecord) -match '\b(404|NotFound|Request_ResourceNotFound)\b') { $status = 404 }
    $status
}

$script:DeletePaths = @{
    CAPolicy         = @{ Path = '/identity/conditionalAccess/policies/{0}'; Beta = $true }
    NamedLocation    = @{ Path = '/identity/conditionalAccess/namedLocations/{0}' }
    AuthStrength     = @{ Path = '/policies/authenticationStrengthPolicies/{0}' }
    Group            = @{ Path = '/groups/{0}'; Purge = $true }
    User             = @{ Path = '/users/{0}'; Purge = $true }
    AdminUnit        = @{ Path = '/directory/administrativeUnits/{0}'; Purge = $true }
    ServicePrincipal = @{ Path = '/servicePrincipals/{0}' }
}

# Ältere Protokolle kennen Kind und ObjectId noch nicht. Dann steht die ID im Detail.
$script:StepToKind = @{
    'Named Locations' = 'NamedLocation'; 'Authentifizierungsstärken' = 'AuthStrength'; 'Persona-Gruppen' = 'Group'
    'Breakglass' = 'User'; 'Restricted AU' = 'AdminUnit'
}

# Liefert die Schritte, die eine Rücknahme ausführen würde, neueste Änderung zuerst
function Get-CAUndoPlan([object[]]$Entries) {
    $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    # Neueste zuerst. Innerhalb derselben Sekunde entscheidet die Reihenfolge im Protokoll.
    $i = 0
    $ordered = $Entries | ForEach-Object { [pscustomobject]@{ E = $_; Idx = $i++ } } |
        Sort-Object @{ Expression = { $_.E.Time }; Descending = $true }, @{ Expression = 'Idx'; Descending = $true } |
        ForEach-Object E
    $plan = foreach ($e in $ordered) {
        if ($e.Action -notin 'angelegt', 'aktualisiert') { continue }
        $kind = $e.PSObject.Properties['Kind'] ? $e.Kind : $null
        $id   = $e.PSObject.Properties['ObjectId'] ? $e.ObjectId : $null
        if (-not $kind -and $e.Action -eq 'angelegt' -and $e.Detail -match $guid) {
            $kind = $script:StepToKind[$e.Step]; $id = $e.Detail
        }
        if (-not $kind) {
            [pscustomobject]@{ Op = 'manuell'; Kind = ''; Id = ''; ParentId = ''; Object = $e.Object; Before = $null; Note = "Kein Objekttyp im Protokoll ($($e.Step))" }
            continue
        }
        $op = switch ($true) {
            ($e.Action -eq 'angelegt')                    { 'löschen'; break }
            ($kind -in 'GroupMember', 'AdminUnitMember')   { 'Mitglied entfernen'; break }
            ($kind -in 'AuthMethod', 'AuthStrength')       { 'zurücksetzen'; break }
            default                                        { 'manuell' }
        }
        $note = if ($op -eq 'manuell') { 'Änderung an bestehendem Objekt, vorheriger Stand steht im Protokoll (Before)' } else { '' }
        [pscustomobject]@{
            Op = $op; Kind = $kind; Id = $id; ParentId = ($e.PSObject.Properties['ParentId'] ? $e.ParentId : '')
            Object = $e.Object; Before = ($e.PSObject.Properties['Before'] ? $e.Before : $null); Note = $note
        }
    }

    # Mitgliedschaften werden immer einzeln entfernt, auch wenn der Container danach gelöscht wird:
    # Mitglieder einer role-assignable Group gelten als privilegiert und lassen sich mit
    # User.ReadWrite.All erst löschen, wenn sie nicht mehr in der Gruppe sind. Und Gruppen in einer
    # Restricted AU bleiben nach dem Löschen der AU noch eine Weile gesperrt.
    @($plan)
}

function Invoke-CAUndo([object[]]$Plan, [switch]$Purge) {
    $step = 'Rücknahme'
    $purgeIds = [System.Collections.Generic.List[string]]::new()

    foreach ($p in $Plan) {
        $label = "$($p.Kind) $($p.Object)"
        if ($p.Op -eq 'manuell') { Write-CALog $step $label 'warnung' $p.Note; continue }
        if ($script:Ctx.WhatIf) { Write-CALog $step $label 'würde ändern' $p.Op; continue }
        try {
            switch ($p.Op) {
                'löschen' {
                    $d = $script:DeletePaths[$p.Kind]
                    if ($p.Kind -eq 'NamedLocation') {
                        # Vertrauenswürdige IP-Locations lassen sich erst löschen, wenn die Markierung weg ist
                        $nl = Invoke-CAGraph -Path "/identity/conditionalAccess/namedLocations/$($p.Id)"
                        if ($nl['isTrusted']) {
                            Invoke-CAGraph -Method PATCH -Path "/identity/conditionalAccess/namedLocations/$($p.Id)" -Body @{ '@odata.type' = $nl['@odata.type']; isTrusted = $false } | Out-Null
                        }
                    }
                    Invoke-CAGraph -Method DELETE -Path ($d['Path'] -f $p.Id) -Beta:([bool]$d['Beta']) | Out-Null
                    if ($d['Purge']) { $purgeIds.Add($p.Id) }
                }
                'Mitglied entfernen' {
                    $container = if ($p.Kind -eq 'GroupMember') { 'groups' } else { 'directory/administrativeUnits' }
                    Invoke-CAGraph -Method DELETE -Path "/$container/$($p.ParentId)/members/$($p.Id)/`$ref" | Out-Null
                }
                'zurücksetzen' {
                    if ($p.Kind -eq 'AuthMethod') {
                        $body = [ordered]@{ '@odata.type' = $p.Before.'@odata.type'; state = $p.Before.state; includeTargets = @($p.Before.includeTargets) }
                        # Passkey-Profile, die der Lauf angelegt hat, verschwinden mit der alten Liste wieder
                        if ($p.Before.PSObject.Properties['passkeyProfiles']) { $body.passkeyProfiles = @($p.Before.passkeyProfiles) }
                        Invoke-CAGraph -Method PATCH -Path "/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/$($p.Id)" -Body $body | Out-Null
                    }
                    else {
                        Invoke-CAGraph -Method PATCH -Path "/policies/authenticationStrengthPolicies/$($p.Id)" -Body @{ description = $p.Before.description } | Out-Null
                        Invoke-CAGraph -Method POST -Path "/policies/authenticationStrengthPolicies/$($p.Id)/updateAllowedCombinations" -Body @{ allowedCombinations = @($p.Before.allowedCombinations) } | Out-Null
                    }
                }
            }
            Write-CALog $step $label 'aktualisiert' $p.Op
        }
        catch {
            $text = Get-CAErrorText $_
            if ((Get-CAHttpStatus $_) -eq 404) { Write-CALog $step $label 'unverändert' 'nicht mehr vorhanden' }
            elseif ($text -match 'restricted management administrative unit') {
                Write-CALog $step $label 'fehler' 'liegt (noch) in einer Restricted AU. Kurz nach dem Löschen der AU ist das normal: Undo nach ein paar Minuten einfach noch einmal starten.'
            }
            else { Write-CALog $step $label 'fehler' $text }
        }
    }

    # Gelöschte Gruppen, Benutzer und AUs liegen 30 Tage im Papierkorb. -Purge entfernt sie endgültig.
    if ($Purge -and $purgeIds.Count -and -not $script:Ctx.WhatIf) {
        Start-Sleep -Seconds 5
        foreach ($id in $purgeIds) {
            try {
                Invoke-CAGraph -Method DELETE -Path "/directory/deletedItems/$id" | Out-Null
                Write-CALog $step $id 'aktualisiert' 'endgültig gelöscht'
            }
            catch { Write-CALog $step $id 'warnung' "endgültiges Löschen nicht möglich: $(Get-CAErrorText $_)" }
        }
    }
}

Export-ModuleMember -Function Connect-CABaseline, Get-CAUndoPlan, Invoke-CAUndo, Initialize-CAContext, Get-CAContext, Write-CALog, Save-CALog, Start-CALog, Get-CADefinitions,
    Get-CAConfigValue, Select-CAPolicies, Sync-CANamedLocations, Sync-CAAuthStrengths, Sync-CAPersonaGroups,
    Sync-CABreakglass, Sync-CARestrictedAU, Sync-CAAuthMethods, Sync-CAServicePrincipals, Sync-CAPolicies,
    Read-CAJson, Get-CARequiredScopes, Get-CAZscalerRanges

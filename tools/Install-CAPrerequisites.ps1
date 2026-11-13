<#
.SYNOPSIS
    Prüft die Voraussetzungen auf diesem Rechner und installiert fehlende Module.

.DESCRIPTION
    Geprüft wird:
      - PowerShell-Version
      - Ausführungsrichtlinie und blockierte Skriptdateien (Zone.Identifier nach ZIP-Download)
      - ob die Sitzung Administratorrechte hat (für den Deployer nicht nötig)
      - ob der Modulordner des Benutzers beschreibbar ist
      - Erreichbarkeit von PowerShell Gallery, Anmeldedienst und Microsoft Graph, Proxy
      - Modul Microsoft.Graph.Authentication

    Mit -Install installiert das Skript fehlende Module für den aktuellen Benutzer
    (Scope CurrentUser). Dafür braucht es keine Administratorrechte. Systemeinstellungen wie
    die Ausführungsrichtlinie ändert es nie, es nennt nur den passenden Befehl.

    Die letzte Zeile beginnt mit ##CABASELINE-RESULT## und enthält das Ergebnis als JSON
    für die Weboberfläche.

.PARAMETER Install
    Fehlende Module installieren.

.EXAMPLE
    .\tools\Install-CAPrerequisites.ps1

.EXAMPLE
    .\tools\Install-CAPrerequisites.ps1 -Install
#>

#Requires -Version 7.2

[CmdletBinding()]
param([switch]$Install)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$moduleName = 'Microsoft.Graph.Authentication'
$minVersion = [version]'2.0.0'
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check([string]$Name, [ValidateSet('ok', 'warn', 'err', 'info')] [string]$Status, [string]$Detail, [string]$Fix = $null) {
    $checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail; fix = $Fix })
    $tag = @{ ok = '[OK]    '; warn = '[WARNUNG]'; err = '[FEHLT] '; info = '[INFO]  ' }[$Status]
    Write-Host "$tag $Name - $Detail"
    if ($Fix) { Write-Host "          Lösung: $Fix" }
}

# Ordnet typische Fehlermeldungen einer verständlichen Ursache und einer Lösung zu
function Get-FixForError([string]$Message) {
    switch -Regex ($Message) {
        '407|Proxy Authentication' { return 'Der Proxy verlangt eine Anmeldung. In PowerShell 7: [System.Net.Http.HttpClient]::DefaultProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials, danach erneut versuchen. Sonst die IT nach einer Proxy-Ausnahme für powershellgallery.com fragen.' }
        'No such host|Name or service not known|Der angegebene Host ist unbekannt|NameResolution' { return 'Der Name lässt sich nicht auflösen. Netzwerk, VPN und DNS prüfen. In abgeschotteten Netzen das Modul auf einem anderen Rechner mit Save-Module herunterladen und in den Modulordner kopieren.' }
        'SSL|TLS|certificate|Zertifikat' { return 'Die TLS-Verbindung scheitert, meist wegen einer Firewall mit TLS-Inspektion. Das Stammzertifikat der Firewall muss im Windows-Zertifikatsspeicher liegen, oder die IT nimmt die Adresse von der Inspektion aus.' }
        'No match was found|Unable to find repository|Repository .* not found|could not be found' { return 'Die PowerShell Gallery ist nicht als Quelle registriert. Register-PSRepository -Default ausführen (oder Register-PSResourceRepository -PSGallery) und erneut installieren.' }
        'Access to the path|Zugriff auf den Pfad|UnauthorizedAccess|denied' { return 'Der Modulordner ist nicht beschreibbar. Häufige Ursache: Der Ordner Dokumente liegt in OneDrive und wird gerade synchronisiert oder ist gesperrt. OneDrive kurz pausieren oder den Ordner aus dem Ergebnis „Modulordner“ freigeben.' }
        'in use|currently in use|wird verwendet' { return 'Das Modul ist in einer anderen PowerShell-Sitzung geladen. Alle anderen PowerShell-Fenster schließen und erneut versuchen.' }
        'timed out|Zeitüberschreitung|Timeout' { return 'Zeitüberschreitung. Netzwerk oder Proxy prüfen und erneut versuchen.' }
        default { return 'Die Fehlermeldung oben gibt die Ursache an. Ohne Netzzugang zur PowerShell Gallery: Modul auf einem anderen Rechner mit Save-Module Microsoft.Graph.Authentication -Path <Ordner> herunterladen und in den Modulordner kopieren.' }
    }
}

Write-Host "`n=== Voraussetzungen auf diesem Rechner ===" -ForegroundColor White

# --- PowerShell -------------------------------------------------------------
$psv = $PSVersionTable.PSVersion
if ($psv -ge [version]'7.2') { Add-Check 'PowerShell' 'ok' "Version $psv" }
else { Add-Check 'PowerShell' 'err' "Version $psv, gebraucht wird 7.2 oder neuer" 'winget install Microsoft.PowerShell (oder das MSI von github.com/PowerShell/PowerShell). Für das MSI sind Administratorrechte nötig, für die Store-Version nicht.' }

# --- Administratorrechte ----------------------------------------------------
$isAdmin = $false
if ($IsWindows) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
Add-Check 'Administratorrechte' 'info' $(if ($isAdmin) { 'Die Sitzung läuft als Administrator. Nötig ist das nicht, Module landen trotzdem nur beim aktuellen Benutzer.' } else { 'Keine. Das reicht, der Deployer installiert nur für den aktuellen Benutzer.' })

# --- Ausführungsrichtlinie --------------------------------------------------
if ($IsWindows) {
    $policies = Get-ExecutionPolicy -List
    $gpo = $policies | Where-Object { $_.Scope -in 'MachinePolicy', 'UserPolicy' -and $_.ExecutionPolicy -ne 'Undefined' } | Select-Object -First 1
    $effective = Get-ExecutionPolicy
    if ($effective -in 'Restricted', 'AllSigned') {
        $fix = if ($gpo) { "Die Richtlinie '$effective' kommt per Gruppenrichtlinie ($($gpo.Scope)). Das kann nur die IT ändern." }
               else { 'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned (ohne Administratorrechte, nur für dich)' }
        Add-Check 'Ausführungsrichtlinie' 'err' "${effective}: Die Skripte des Deployers sind nicht signiert und würden blockiert." $fix
    }
    else { Add-Check 'Ausführungsrichtlinie' 'ok' "$effective" }

    # Nach dem Download als ZIP tragen die Dateien die Markierung "aus dem Internet"
    $blocked = @(Get-ChildItem $repoRoot -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue |
        Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue })
    if ($blocked.Count -and $effective -in 'RemoteSigned', 'AllSigned', 'Restricted') {
        Add-Check 'Blockierte Dateien' 'err' "$($blocked.Count) Skriptdatei(en) sind als Download markiert und werden bei $effective blockiert." "Get-ChildItem '$repoRoot' -Recurse | Unblock-File"
    }
    elseif ($blocked.Count) { Add-Check 'Blockierte Dateien' 'info' "$($blocked.Count) Datei(en) als Download markiert, bei '$effective' ohne Auswirkung." }
    else { Add-Check 'Blockierte Dateien' 'ok' 'keine' }
}

# --- Modulordner ------------------------------------------------------------
$userModulePath = ($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ -like "$HOME*" } | Select-Object -First 1)
if (-not $userModulePath) { $userModulePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules' }
try {
    New-Item -ItemType Directory -Force -Path $userModulePath | Out-Null
    $probe = Join-Path $userModulePath ".ca-write-test-$PID"
    [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force
    $od = if ($userModulePath -match 'OneDrive') { ' Er liegt in OneDrive. Das funktioniert, kann beim Synchronisieren aber Dateien sperren.' } else { '' }
    Add-Check 'Modulordner' $(if ($od) { 'warn' } else { 'ok' }) "$userModulePath ist beschreibbar.$od"
}
catch { Add-Check 'Modulordner' 'err' "$userModulePath ist nicht beschreibbar: $($_.Exception.Message)" (Get-FixForError $_.Exception.Message) }

# --- Netzwerk ---------------------------------------------------------------
$proxy = $null
try { $proxy = [System.Net.Http.HttpClient]::DefaultProxy.GetProxy([uri]'https://www.powershellgallery.com') } catch { }
if ($proxy -and $proxy.Host -ne 'www.powershellgallery.com') { Add-Check 'Proxy' 'info' "Verbindungen laufen über $proxy" }

$targets = [ordered]@{
    'PowerShell Gallery'   = 'https://www.powershellgallery.com/api/v2/'
    'Microsoft-Anmeldung'  = 'https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration'
    'Microsoft Graph'      = 'https://graph.microsoft.com/v1.0/$metadata'
}
foreach ($t in $targets.GetEnumerator()) {
    try {
        $r = Invoke-WebRequest -Uri $t.Value -Method Head -TimeoutSec 15 -SkipHttpErrorCheck -UseBasicParsing
        $code = [int]$r.StatusCode
        if ($code -eq 407) { Add-Check $t.Key 'err' 'Der Proxy verlangt eine Anmeldung (407).' (Get-FixForError '407') }
        else { Add-Check $t.Key 'ok' 'erreichbar' }
    }
    catch { Add-Check $t.Key 'err' "nicht erreichbar: $($_.Exception.Message)" (Get-FixForError $_.Exception.Message) }
}

# --- Graph-Modul ------------------------------------------------------------
$installed = Get-Module -ListAvailable $moduleName | Sort-Object Version -Descending | Select-Object -First 1
if ($installed -and $installed.Version -ge $minVersion) {
    Add-Check $moduleName 'ok' "Version $($installed.Version) in $(Split-Path (Split-Path $installed.ModuleBase))"
}
elseif (-not $Install) {
    $what = if ($installed) { "Version $($installed.Version) ist zu alt, gebraucht wird $minVersion oder neuer" } else { 'nicht installiert' }
    Add-Check $moduleName 'err' $what 'Mit „Fehlendes installieren“ in der Oberfläche oder: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
else {
    Write-Host "`nInstalliere $moduleName für den aktuellen Benutzer …" -ForegroundColor Cyan
    try {
        if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
            Install-PSResource -Name $moduleName -Scope CurrentUser -TrustRepository -Quiet -ErrorAction Stop
        }
        else {
            Install-Module -Name $moduleName -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
        }
        $installed = Get-Module -ListAvailable $moduleName | Sort-Object Version -Descending | Select-Object -First 1
        if ($installed) { Add-Check $moduleName 'ok' "Version $($installed.Version) installiert" }
        else { Add-Check $moduleName 'err' 'Die Installation meldete keinen Fehler, das Modul ist aber nicht auffindbar.' 'PowerShell-Fenster der Oberfläche schließen, neu starten und erneut prüfen.' }
    }
    catch {
        Add-Check $moduleName 'err' "Installation fehlgeschlagen: $($_.Exception.Message)" (Get-FixForError $_.Exception.Message)
    }
}

$failed = @($checks | Where-Object status -eq 'err').Count
Write-Host ''
if ($failed) { Write-Host "$failed Voraussetzung(en) fehlen." -ForegroundColor Yellow }
else { Write-Host 'Alle Voraussetzungen auf diesem Rechner sind erfüllt.' -ForegroundColor Green }

[Console]::Out.WriteLine('##CABASELINE-RESULT## ' + (ConvertTo-Json -InputObject ([ordered]@{ checks = @($checks); isAdmin = $isAdmin; failed = $failed }) -Depth 5 -Compress))
if ($failed) { exit 2 }

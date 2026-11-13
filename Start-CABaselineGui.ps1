<#
.SYNOPSIS
    Startet die Weboberfläche des CA Baseline Deployers.

.DESCRIPTION
    Startet einen kleinen Webserver, der nur auf localhost lauscht, und öffnet den Browser.
    Die Oberfläche führt Schritt für Schritt durch Config, App-Registrierung, Rollen, Auswahl der
    Policies, Probelauf, Deployment und Rücknahme.

    Deployment, Undo, App-Registrierung und Rollenprüfung laufen als eigene pwsh-Prozesse in diesem
    Konsolenfenster. Dadurch erscheint die Microsoft-Anmeldung wie gewohnt. Ihre Ausgabe zeigt die
    Oberfläche live an.

    Der Zugang ist durch ein zufälliges Token geschützt, das nur in der geöffneten URL steht.
    Kennwörter neuer Breakglass-Konten hält der Server nur im Speicher, bis die Oberfläche sie
    einmal abgeholt hat.

    Beenden mit Strg+C in diesem Fenster oder über „Beenden“ in der Oberfläche.

.PARAMETER Port
    Fester Port. Ohne Angabe nimmt der Server einen freien Port.

.PARAMETER NoBrowser
    Browser nicht automatisch öffnen. Die URL steht dann nur in der Konsole.

.EXAMPLE
    .\Start-CABaselineGui.ps1
#>

#Requires -Version 7.2

[CmdletBinding()]
param(
    [int]$Port,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$wwwRoot  = Join-Path $repoRoot 'gui/www'
$cfgRoot  = Join-Path $repoRoot 'config/tenants'
$logRoot  = Join-Path $repoRoot 'Logs'
Import-Module (Join-Path $repoRoot 'src/CABaseline/CABaseline.psm1') -Force

# ---------------------------------------------------------------------------
# Hintergrundprozesse: Die Ausgabe wird in C# eingesammelt, damit der Server-Thread frei bleibt
# ---------------------------------------------------------------------------
if (-not ('CABaselineGui.Job' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;

namespace CABaselineGui {
    public class Job {
        public string Id;
        public string Type;
        public DateTime Started = DateTime.Now;
        public bool Done;
        public int ExitCode = -1;
        readonly Process proc;
        readonly List<string> lines = new List<string>();
        readonly List<string> secrets = new List<string>();
        readonly object gate = new object();
        const string SecretPrefix = "##CABASELINE-SECRET## ";

        public Job(string id, string type, string exe, string[] args, string cwd) {
            Id = id; Type = type;
            var psi = new ProcessStartInfo(exe) {
                UseShellExecute = false, CreateNoWindow = false, WorkingDirectory = cwd,
                RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
                StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
            proc.OutputDataReceived += (s, e) => Add(e.Data, false);
            proc.ErrorDataReceived  += (s, e) => Add(e.Data, true);
            proc.Exited += (s, e) => {
                proc.WaitForExit();
                lock (gate) { ExitCode = proc.ExitCode; Done = true; }
            };
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            proc.StandardInput.Close();
        }

        void Add(string line, bool isError) {
            if (line == null) return;
            line = System.Text.RegularExpressions.Regex.Replace(line, "\u001b\\[[0-9;]*[A-Za-z]", "");
            lock (gate) {
                if (line.StartsWith(SecretPrefix)) secrets.Add(line.Substring(SecretPrefix.Length));
                else lines.Add(isError ? "[stderr] " + line : line);
            }
        }

        public string[] GetLines(int from) {
            lock (gate) {
                if (from < 0) from = 0;
                if (from >= lines.Count) return new string[0];
                return lines.GetRange(from, lines.Count - from).ToArray();
            }
        }

        // Kennwörter gibt es genau einmal, danach sind sie aus dem Speicher des Jobs entfernt
        public string[] TakeSecrets() {
            lock (gate) { var s = secrets.ToArray(); secrets.Clear(); return s; }
        }

        public void Stop() { try { if (!proc.HasExited) proc.Kill(true); } catch { } }
    }
}
'@
}

$jobs = @{}
$scripts = @{
    deploy  = Join-Path $repoRoot 'Deploy-CABaseline.ps1'
    undo    = Join-Path $repoRoot 'Undo-CABaseline.ps1'
    app     = Join-Path $repoRoot 'tools/New-DeployerApp.ps1'
    check   = Join-Path $repoRoot 'tools/Test-CAConnection.ps1'
    catalog = Join-Path $repoRoot 'tools/Update-AaguidCatalog.ps1'
    prereq  = Join-Path $repoRoot 'tools/Install-CAPrerequisites.ps1'
}

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
function Send-Response($Ctx, [int]$Status, $Body, [string]$ContentType = 'application/json; charset=utf-8') {
    $res = $Ctx.Response
    $res.StatusCode = $Status
    $res.ContentType = $ContentType
    $res.Headers['Cache-Control'] = 'no-store'
    $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $bytes = if ($Body -is [byte[]]) { $Body }
             elseif ($Body -is [string]) { [Text.Encoding]::UTF8.GetBytes($Body) }
             else { [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 30 -Compress)) }
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.Close()
}

function Read-Body($Ctx) {
    $reader = [IO.StreamReader]::new($Ctx.Request.InputStream, [Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
    $text | ConvertFrom-Json -AsHashtable
}

function Test-SafeName([string]$Name) { $Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' }

function Get-ConfigPath([string]$Name) {
    if (-not (Test-SafeName $Name)) { throw 'Ungültiger Name für die Config.' }
    Join-Path $cfgRoot "$Name.json"
}

function Write-Utf8File([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-StateInfo {
    $graph = Get-Module -ListAvailable Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1
    [ordered]@{
        psVersion   = $PSVersionTable.PSVersion.ToString()
        graphModule = if ($graph) { $graph.Version.ToString() } else { $null }
        repoRoot    = $repoRoot
        configs     = @(Get-ChildItem $cfgRoot -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            $info = [ordered]@{ name = $_.BaseName; domain = $null; tenantId = $null; changed = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
            try {
                $c = Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                $info.domain = $c.tenant.primaryDomain; $info.tenantId = $c.tenant.tenantId
            } catch { }
            $info
        })
        logs        = @(Get-ChildItem $logRoot -Filter *.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
            [ordered]@{ name = $_.Name; time = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'); size = $_.Length; undo = $_.Name -like 'undo-*' }
        })
        runningJob  = @($jobs.Values | Where-Object { -not $_.Done } | ForEach-Object { [ordered]@{ id = $_.Id; type = $_.Type } }) | Select-Object -First 1
    }
}

function Get-DefinitionInfo {
    Initialize-CAContext -RepoRoot $repoRoot -Config @{} -ValidateOnly -NonInteractive
    $d = Get-CADefinitions
    # Welche Policy welche Named Location braucht, damit die Oberfläche beim Abwählen warnen kann
    $nlRefs = @{}
    foreach ($p in $d.Policies) {
        $json = ConvertTo-Json -InputObject $p -Depth 30 -Compress
        $nlRefs[$p._deployer.key] = @([regex]::Matches($json, '\{\{namedLocation:([^}]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    }
    [ordered]@{
        policies = @($d.Policies | ForEach-Object {
            [ordered]@{
                key = $_._deployer.key; displayName = $_.displayName; category = $_._deployer.category
                defaultSelected = [bool]$_._deployer.defaultSelected; state = $_.state
                inputs = @(if ($_._deployer.Contains('customerInput')) { $_._deployer.customerInput })
                namedLocations = $nlRefs[$_._deployer.key]
            }
        })
        personas = @($d.Personas | ForEach-Object {
            [ordered]@{ key = $_.key; description = $_.description; roleAssignable = [bool]$_.isAssignableToRole; restrictedAU = [bool]$_.restrictedAdministrativeUnit; dynamic = [bool]$_.membershipRule }
        })
        namedLocations = @($d.NamedLocations | ForEach-Object {
            [ordered]@{
                name = $_.displayName; type = ($_.'@odata.type' -replace '#microsoft.graph.', ''); trusted = [bool]($_.Contains('isTrusted') -and $_.isTrusted)
                inputs = @(if ($_._deployer.Contains('customerInput')) { $_._deployer.customerInput })
                countries = @(if ($_.Contains('countriesAndRegions')) { $_.countriesAndRegions })
                ipRanges = @(if ($_.Contains('ipRanges')) { $_.ipRanges | ForEach-Object { $_.cidrAddress } })
            }
        })
        authStrengths = @($d.AuthStrengths | ForEach-Object { [ordered]@{ name = $_.displayName; description = $_.description; combinations = @($_.allowedCombinations) } })
        zscalerClouds = @('zscaler.net', 'zscalerone.net', 'zscalertwo.net', 'zscalerthree.net', 'zscloud.net', 'zscalerbeta.net', 'zscalergov.net', 'zscalerten.net', 'zspreview.net')
        passkeyProfiles = @($d.PasskeyProfiles | ForEach-Object {
            [ordered]@{
                key = $_._deployer.key; name = $_.name; passkeyTypes = $_.passkeyTypes; attestation = $_.attestationEnforcement
                restricted = [bool]$_.keyRestrictions.isEnforced
                products = @(if ($_._deployer.Contains('aaguidProducts')) { $_._deployer.aaguidProducts })
                optionalProducts = if ($_._deployer.Contains('optionalProducts')) { $_._deployer.optionalProducts } else { $null }
            }
        })
        aaguidProducts = @($d.AaguidCatalog.products | ForEach-Object {
            [ordered]@{ key = $_.key; name = $_.name; firmware = @($_.aaguids | ForEach-Object { $_.firmware }); count = @($_.aaguids).Count }
        })
        catalogGenerated = if ($d.AaguidCatalog.Contains('generated')) { $d.AaguidCatalog.generated } else { $null }
        breakglass = $d.Breakglass
        example = Read-CAJson (Join-Path $repoRoot 'config/tenant.example.json')
    }
}

function Start-CAJob([hashtable]$Req) {
    $type = [string]$Req.type
    if (-not $scripts.ContainsKey($type)) { throw "Unbekannter Auftrag '$type'." }
    if ($jobs.Values | Where-Object { -not $_.Done }) { throw 'Es läuft schon ein Auftrag. Bitte warten, bis er fertig ist.' }

    $a = [ordered]@{}
    if ($type -notin 'catalog', 'prereq') { $a.ConfigPath = Get-ConfigPath $Req.config }
    switch ($type) {
        'prereq' { if ($Req.mode -eq 'install') { $a.Install = $true } }
        'deploy' {
            $a.NonInteractive = $true
            switch ($Req.mode) {
                'validate' { $a.ValidateOnly = $true }
                'whatif'   { $a.WhatIf = $true }
                'live'     { }
                default    { throw 'Unbekannter Modus.' }
            }
            if ($Req.steps) { $a.Steps = @($Req.steps) }
        }
        'undo' {
            $a.LogPath = @(foreach ($n in @($Req.logs)) {
                if (-not (Test-SafeName ($n -replace '\.json$', ''))) { throw "Ungültiger Protokollname '$n'." }
                Join-Path $logRoot $n
            })
            if (-not $a.LogPath.Count) { throw 'Kein Protokoll ausgewählt.' }
            $a.Force = $true
            if ($Req.mode -eq 'whatif') { $a.WhatIf = $true }
            if ($Req.purge) { $a.Purge = $true }
        }
        'app' {
            $cfg = Read-CAJson $a.ConfigPath
            $a.TenantId = $cfg.tenant.tenantId
            if ($Req.assignUsers) { $a.AssignUsers = @($Req.assignUsers) }
        }
    }

    $id = [guid]::NewGuid().ToString('n').Substring(0, 12)
    $pwsh = (Get-Process -Id $PID).Path
    $argv = @('-NoProfile', '-NoLogo', '-File', (Join-Path $repoRoot 'gui/Invoke-CAJob.ps1'), '-Script', $scripts[$type], '-ArgsJson', (ConvertTo-Json -InputObject $a -Compress -Depth 5))
    $job = [CABaselineGui.Job]::new($id, $type, $pwsh, [string[]]$argv, $repoRoot)
    $jobs[$id] = $job
    Write-Host ("[{0:HH:mm:ss}] Auftrag {1} gestartet ({2})" -f (Get-Date), $type, $id) -ForegroundColor Cyan
    $id
}

# ---------------------------------------------------------------------------
# Anfragen
# ---------------------------------------------------------------------------
function Invoke-ApiRequest($Ctx) {
    $req  = $Ctx.Request
    $path = $req.Url.AbsolutePath
    $q    = $req.QueryString

    switch -Regex ("$($req.HttpMethod) $path") {
        '^GET /api/state$'       { return Send-Response $Ctx 200 (Get-StateInfo) }
        '^GET /api/definitions$' { return Send-Response $Ctx 200 (Get-DefinitionInfo) }
        '^GET /api/config$' {
            $p = Get-ConfigPath $q['name']
            if (-not (Test-Path $p)) { return Send-Response $Ctx 404 @{ error = 'Config nicht gefunden.' } }
            return Send-Response $Ctx 200 (Get-Content -LiteralPath $p -Raw -Encoding utf8)
        }
        '^PUT /api/config$' {
            $p = Get-ConfigPath $q['name']
            $body = Read-Body $Ctx
            if (-not ($body -is [System.Collections.IDictionary] -and $body.Contains('tenant'))) { throw 'Die Config braucht mindestens den Abschnitt tenant.' }
            Write-Utf8File $p (ConvertTo-Json -InputObject $body -Depth 30)
            return Send-Response $Ctx 200 @{ saved = $true; name = $q['name'] }
        }
        '^GET /api/log$' {
            $n = [string]$q['name']
            if (-not (Test-SafeName ($n -replace '\.json$', ''))) { throw 'Ungültiger Protokollname.' }
            $p = Join-Path $logRoot $n
            if (-not (Test-Path $p)) { return Send-Response $Ctx 404 @{ error = 'Protokoll nicht gefunden.' } }
            return Send-Response $Ctx 200 (Get-Content -LiteralPath $p -Raw -Encoding utf8)
        }
        '^GET /api/tenant-lookup$' {
            # Fragt den öffentlichen Discovery-Endpunkt von Microsoft, zu welchem Tenant eine Domäne gehört.
            # Ohne Anmeldung, übertragen wird nur der Domänenname.
            $domain = ([string]$q['domain']).Trim().ToLowerInvariant()
            if ($domain -notmatch '^[a-z0-9][a-z0-9-]{0,62}(\.[a-z0-9][a-z0-9-]{0,62})+$') { throw 'Ungültiger Domänenname.' }
            try {
                $r = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$domain/v2.0/.well-known/openid-configuration" -TimeoutSec 15
                $tid = [regex]::Match([string]$r.issuer, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}').Value
                return Send-Response $Ctx 200 ([ordered]@{ found = [bool]$tid; tenantId = $tid; region = $r.tenant_region_scope; cloud = $r.cloud_instance_name })
            }
            catch {
                $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                if ($code -eq 400 -or $code -eq 404) { return Send-Response $Ctx 200 @{ found = $false; error = 'Microsoft kennt diese Domäne keinem Tenant zu.' } }
                return Send-Response $Ctx 200 @{ found = $false; offline = $true; error = "Abgleich nicht möglich: $($_.Exception.Message)" }
            }
        }
        '^GET /api/zscaler$' {
            # Holt die aktuelle Liste direkt beim Hersteller, damit nie ein veralteter Stand importiert wird
            try {
                $z = Get-CAZscalerRanges ([string]$q['cloud'])
                return Send-Response $Ctx 200 ([ordered]@{ ok = $true; cloud = $z.Cloud; url = $z.Url; ranges = @($z.Ranges); fetched = (Get-Date).ToString('yyyy-MM-dd HH:mm') })
            }
            catch { return Send-Response $Ctx 200 @{ ok = $false; error = $_.Exception.Message } }
        }
        '^POST /api/job$' {
            $id = Start-CAJob (Read-Body $Ctx)
            return Send-Response $Ctx 200 @{ id = $id }
        }
        '^GET /api/job$' {
            $job = $jobs[[string]$q['id']]
            if (-not $job) { return Send-Response $Ctx 404 @{ error = 'Auftrag unbekannt.' } }
            $from = [int]($q['from'] ?? 0)
            return Send-Response $Ctx 200 ([ordered]@{
                id = $job.Id; type = $job.Type; done = $job.Done; exitCode = $job.ExitCode
                lines = @($job.GetLines($from)); secrets = @($job.TakeSecrets() | ForEach-Object { $_ | ConvertFrom-Json })
            })
        }
        '^POST /api/job/stop$' {
            $job = $jobs[[string]$q['id']]
            if ($job) { $job.Stop() }
            return Send-Response $Ctx 200 @{ stopped = [bool]$job }
        }
        '^POST /api/shutdown$' {
            Send-Response $Ctx 200 @{ bye = $true }
            $script:stopServer = $true
            return
        }
        default { return Send-Response $Ctx 404 @{ error = 'Unbekannter Endpunkt.' } }
    }
}

function Invoke-StaticRequest($Ctx) {
    $rel = [Uri]::UnescapeDataString($Ctx.Request.Url.AbsolutePath.TrimStart('/'))
    if (-not $rel) { $rel = 'index.html' }
    $full = [IO.Path]::GetFullPath((Join-Path $wwwRoot $rel))
    if (-not $full.StartsWith([IO.Path]::GetFullPath($wwwRoot)) -or -not (Test-Path $full -PathType Leaf)) {
        return Send-Response $Ctx 404 'Nicht gefunden' 'text/plain; charset=utf-8'
    }
    $type = switch ([IO.Path]::GetExtension($full)) {
        '.html' { 'text/html; charset=utf-8' }
        '.js'   { 'text/javascript; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.svg'  { 'image/svg+xml' }
        default { 'application/octet-stream' }
    }
    Send-Response $Ctx 200 ([IO.File]::ReadAllBytes($full)) $type
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
if (-not $Port) {
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $Port = $probe.LocalEndpoint.Port; $probe.Stop()
}
$origin = "http://localhost:$Port"
$token  = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLower()

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("$origin/")
$listener.Start()

$url = "$origin/#t=$token"
Write-Host "`nCA Baseline Deployer, Weboberfläche" -ForegroundColor White
Write-Host "Adresse: $url" -ForegroundColor Cyan
Write-Host 'Die Adresse enthält den Zugangsschlüssel. Nicht weitergeben. Beenden mit Strg+C.' -ForegroundColor DarkGray
Write-Host 'Anmeldefenster von Microsoft erscheinen über diesem Fenster.' -ForegroundColor DarkGray
if (-not $NoBrowser) { Start-Process $url }

$script:stopServer = $false
try {
    while ($listener.IsListening -and -not $script:stopServer) {
        $pending = $listener.GetContextAsync()
        while (-not $pending.Wait(500)) { }
        $ctx = $pending.Result
        try {
            $isApi = $ctx.Request.Url.AbsolutePath.StartsWith('/api/')
            if ($isApi) {
                # Nur Anfragen aus der eigenen Oberfläche: Token im Header, keine fremde Herkunft
                $o = $ctx.Request.Headers['Origin']
                if (($o -and $o -ne $origin) -or $ctx.Request.Headers['X-CA-Token'] -ne $token) {
                    Send-Response $ctx 403 @{ error = 'Kein Zugriff.' }
                    continue
                }
                Invoke-ApiRequest $ctx
            }
            else { Invoke-StaticRequest $ctx }
        }
        catch {
            try { Send-Response $ctx 400 @{ error = $_.Exception.Message } } catch { }
        }
    }
}
finally {
    foreach ($j in $jobs.Values) { $j.Stop() }
    $listener.Stop()
    $listener.Close()
    Write-Host 'Weboberfläche beendet.' -ForegroundColor DarkGray
}

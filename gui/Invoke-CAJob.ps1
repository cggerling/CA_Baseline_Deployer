<#
.SYNOPSIS
    Startet ein Skript des Deployers für die Weboberfläche.

.DESCRIPTION
    Der Server ruft dieses Skript als eigenen pwsh-Prozess auf. Es stellt die Ausgabe auf UTF-8 und
    reinen Text ohne Farbcodes um, setzt CABASELINE_GUI und ruft das eigentliche Skript mit den
    Parametern aus ArgsJson auf. Welche Skripte erlaubt sind, entscheidet der Server.
#>
param(
    [Parameter(Mandatory)] [string]$Script,
    [string]$ArgsJson = '{}'
)

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$PSStyle.OutputRendering = 'PlainText'
$env:CABASELINE_GUI = '1'

$params = $ArgsJson | ConvertFrom-Json -AsHashtable
try {
    & $Script @params
    exit 0
}
catch {
    Write-Host "FEHLER: $($_.Exception.Message)"
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    exit 1
}

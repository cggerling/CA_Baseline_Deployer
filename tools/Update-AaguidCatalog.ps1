<#
.SYNOPSIS
    Baut den AAGUID-Katalog für die Passkey-Profile aus dem FIDO Alliance Metadata Service (MDS).

.DESCRIPTION
    Der MDS ist die offizielle Liste der FIDO-zertifizierten Authenticatoren. Das Skript lädt ihn,
    nimmt die Einträge der ausgewählten Hersteller, die aktuell als zertifiziert gelten, und fasst sie
    nach Produkt zusammen. Die Firmware steht pro AAGUID dabei, weil Hersteller wie Yubico für jede
    Firmware-Generation eine eigene AAGUID vergeben.

    Microsoft Authenticator steht nicht im MDS. Die beiden AAGUIDs stammen aus der Microsoft-Doku und
    sind fest im Skript hinterlegt.

    Ergebnis: definitions/authentication-methods/aaguid-catalog.json. Der Deployer bietet die Produkte
    daraus bei den Passkey-Profilen zur Auswahl an.

.PARAMETER Vendor
    Muster für die Produktbeschreibung im MDS. Standard: YubiKey und Windows Hello.

.PARAMETER MdsFile
    Bereits heruntergeladener MDS-Blob (JWT). Ohne Angabe wird https://mds3.fidoalliance.org/ abgerufen.

.EXAMPLE
    .\tools\Update-AaguidCatalog.ps1

.EXAMPLE
    .\tools\Update-AaguidCatalog.ps1 -Vendor 'YubiKey', 'Windows Hello', 'Feitian', 'Token2'
#>

#Requires -Version 7.2

[CmdletBinding()]
param(
    [string[]]$Vendor = @('YubiKey', 'Windows Hello'),
    [string]$MdsFile,
    [string]$OutputPath = (Join-Path $PSScriptRoot '../definitions/authentication-methods/aaguid-catalog.json')
)

$ErrorActionPreference = 'Stop'

$jwt = if ($MdsFile) { Get-Content -LiteralPath $MdsFile -Raw } else { Invoke-RestMethod 'https://mds3.fidoalliance.org/' }
$payload = $jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
$payload += '=' * ((4 - $payload.Length % 4) % 4)
$mds = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json

# Yubico kodiert die Firmware als 0xMMmmpp (329476 = 5.7.4), ältere Einträge als Dezimalzahl (50100 = 5.1.0)
function ConvertTo-Firmware([long]$v) {
    if ($v -gt 65535) { return '{0}.{1}.{2}' -f ($v -shr 16), (($v -shr 8) -band 255), ($v -band 255) }
    if ($v -ge 10000) { return '{0}.{1}.{2}' -f [math]::Floor($v / 10000), [math]::Floor(($v % 10000) / 100), ($v % 100) }
    return "$v"
}

$pattern  = ($Vendor | ForEach-Object { [regex]::Escape($_) }) -join '|'
$products = [ordered]@{}

foreach ($e in $mds.entries | Where-Object { $_.aaguid -and $_.metadataStatement.description -match $pattern }) {
    $desc   = $e.metadataStatement.description.Trim()
    $status = ($e.statusReports | Sort-Object effectiveDate | Select-Object -Last 1).status
    # Vorabversionen und Einträge ohne gültige Zertifizierung gehören nicht in eine Positivliste
    if ($status -notlike 'FIDO_CERTIFIED*') { continue }
    if ($desc -match 'Preview') { continue }

    if (-not $products.Contains($desc)) {
        $products[$desc] = [ordered]@{
            key     = ($desc -replace '[^A-Za-z0-9]+', '')
            name    = $desc
            source  = 'FIDO MDS'
            aaguids = [System.Collections.Generic.List[object]]::new()
        }
    }
    $products[$desc].aaguids.Add([ordered]@{
        aaguid       = $e.aaguid
        firmware     = ConvertTo-Firmware $e.metadataStatement.authenticatorVersion
        certification = $status
    })
}

$products['Microsoft Authenticator'] = [ordered]@{
    key     = 'MicrosoftAuthenticator'
    name    = 'Microsoft Authenticator'
    source  = 'Microsoft Learn: how-to-enable-authenticator-passkey'
    aaguids = @(
        [ordered]@{ aaguid = 'de1e552d-db1d-4423-a619-566b625cdc84'; firmware = 'Android'; certification = '' }
        [ordered]@{ aaguid = '90a3ccdf-635c-4729-a248-9b709135078f'; firmware = 'iOS'; certification = '' }
    )
}

$catalog = [ordered]@{
    _hinweis  = 'Erzeugt mit tools/Update-AaguidCatalog.ps1. Änderungen von Hand gehen beim nächsten Lauf verloren.'
    generated = (Get-Date).ToString('yyyy-MM-dd')
    mdsNextUpdate = $mds.nextUpdate
    products  = @($products.Values | Sort-Object name)
}

$full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
$json = $catalog | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($full, ($json -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))

Write-Host "$($catalog.products.Count) Produkte mit $(@($catalog.products.aaguids).Count) AAGUIDs: $full"

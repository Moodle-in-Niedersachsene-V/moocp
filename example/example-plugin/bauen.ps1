# Baut das Beispiel-Plugin zu einem fertigen Plugin-Ordner: übersetzt das
# Programm mit `dart compile exe` unter dem Namen, den `programm` in
# plugin.json nennt, und legt es mit plugin.json und skills\ in den
# Zielordner. Unter Windows; auf dem Mac tut bauen.sh dasselbe.
#
#   powershell -ExecutionPolicy Bypass -File example\example-plugin\bauen.ps1 [-Ziel <Zielordner>]
#
# Vorgabe für den Zielordner ist build\beispiel in diesem Projekt. Installiert
# ist das Plugin, wenn der Ordner als plugins\beispiel im Einstellungsordner
# von moocp liegt (%APPDATA%\moocp\plugins\beispiel); dorthin schreibt das
# Skript nur, wenn er als Zielordner genannt ist, und es liest dort nichts.
# moocp vorher beenden: Ein geändertes Plugin braucht beim nächsten Start
# eine neue Zustimmung.
#
# Ein Zielordner, der nicht leer ist und keine plugin.json enthält, ist kein
# Plugin-Ordner; dann bricht das Skript ab, ohne etwas zu ändern. Sonst
# ersetzt es dort Programm, plugin.json und skills\ und lässt alles andere
# stehen.
#
# Gespeichert als UTF-8 mit BOM: Windows PowerShell 5.1 liest eine Datei
# ohne BOM in der Codepage des Systems und zeigte die Umlaute falsch an.

param(
    # Der fertige Plugin-Ordner.
    [string]$Ziel = (Join-Path $PSScriptRoot 'build\beispiel'),
    # Das dart, mit dem das Beispiel übersetzt wird.
    [string]$Dart = 'dart'
)

$ErrorActionPreference = 'Stop'

$ordner = $PSScriptRoot
$beschreibung = Get-Content -LiteralPath (Join-Path $ordner 'plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$programm = [string]$beschreibung.programm
if (-not $programm) {
    Write-Error 'plugin.json nennt kein programm.'
}
if (Test-Path -LiteralPath $Ziel -PathType Leaf) {
    Write-Error "Der Zielordner ist eine Datei: $Ziel"
}
if ((Test-Path -LiteralPath $Ziel -PathType Container) -and
    (Get-ChildItem -LiteralPath $Ziel -Force | Select-Object -First 1) -and
    -not (Test-Path -LiteralPath (Join-Path $Ziel 'plugin.json') -PathType Leaf)) {
    Write-Error "Der Zielordner ist nicht leer und kein Plugin-Ordner: $Ziel"
}
$Ziel = (New-Item -ItemType Directory -Force -Path $Ziel).FullName

# Im Projektordner: dart findet dort pubspec.yaml und holt beim ersten Mal
# die Pakete. Erst übersetzen, dann ersetzen: Schlägt das Übersetzen fehl,
# bleibt der Zielordner, wie er war.
$neu = Join-Path $Ziel "$programm.neu"
Push-Location $ordner
try {
    & $Dart compile exe 'bin\beispiel.dart' -o $neu
    if ($LASTEXITCODE -ne 0) {
        Write-Error "dart compile exe ist mit Exit-Code $LASTEXITCODE gescheitert."
    }
}
finally {
    Pop-Location
}
foreach ($alt in @('skills', 'plugin.json', $programm)) {
    $pfad = Join-Path $Ziel $alt
    if (Test-Path -LiteralPath $pfad) {
        Remove-Item -LiteralPath $pfad -Recurse -Force
    }
}
Move-Item -LiteralPath $neu -Destination (Join-Path $Ziel $programm)
Copy-Item -LiteralPath (Join-Path $ordner 'plugin.json') -Destination (Join-Path $Ziel 'plugin.json')
Copy-Item -LiteralPath (Join-Path $ordner 'skills') -Destination (Join-Path $Ziel 'skills') -Recurse
Write-Host "Das Beispiel-Plugin liegt fertig in $Ziel"

# Startet das Beispiel-Plugin zum Entwickeln und hängt es an die installierte
# moocp an (README, Teil 4, „Ein Plugin entwickeln“). Unter Windows; auf dem
# Mac tut entwickeln.sh dasselbe.
#
#   powershell -ExecutionPolicy Bypass -File beispiele\plugin\entwickeln.ps1 [-Moocp <Pfad zur moocp.exe>]
#
# Was das Skript tut, tut jeder Plugin-Entwickler auf seine Weise:
#
# 1. einen zufälligen Schlüssel erzeugen und in die Umgebungsvariable
#    MOOCP_PLUGIN_SCHLUESSEL legen -- nie auf die Kommandozeile, dort stünde
#    er in jeder Prozessliste. Plugin und moocp erben ihn von hier;
# 2. das Plugin auf dem Port aus `entwicklungsPort` in plugin.json starten
#    (`--port <Zahl>`), hier aus dem Quelltext mit `dart run`, sonst im
#    Debugger; `--entwicklung` hält das Beispiel am Leben, auch wenn seine
#    Standardeingabe endet;
# 3. moocp mit `--plugin-entwicklung <dieser Ordner>` starten. moocp fragt im
#    Dialog „Entwicklungs-Plugin anhängen“, ob es sich verbinden soll.
#
# Läuft moocp schon, holt der Start nur das Fenster nach vorn und hängt
# nichts an: moocp vorher beenden. Ein neu gebautes und neu gestartetes
# Plugin braucht keinen neuen Start von moocp, solange es denselben Schlüssel
# bekommt -- deshalb hier im selben Fenster neu starten. Strg+C beendet das
# Plugin; moocp läuft weiter und verbindet sich wieder, sobald es zurück ist.
#
# Gespeichert als UTF-8 mit BOM: Windows PowerShell 5.1 liest eine Datei
# ohne BOM in der Codepage des Systems und zeigte die Umlaute falsch an.

param(
    # Die moocp.exe; Vorgabe ist der Ort, an den der Installer sie legt.
    [string]$Moocp = (Join-Path $env:LOCALAPPDATA 'Programs\moocp\moocp.exe'),
    # Das dart, mit dem das Beispiel läuft.
    [string]$Dart = 'dart'
)

$ErrorActionPreference = 'Stop'

# Den ganzen Pfad vorher ermitteln: Im Flutter-SDK ist dart eine
# Batch-Datei, und Start-Process soll genau das Programm starten, das die
# Konsole unter diesem Namen fände.
$Dart = (Get-Command $Dart -CommandType Application | Select-Object -First 1).Source

$ordner = $PSScriptRoot
# Das Beispiel benutzt die Pakete von moocp; dart findet sie von der Wurzel
# des Repositorys aus.
$wurzel = (Resolve-Path (Join-Path $ordner '..\..')).Path

if (-not (Test-Path -LiteralPath $Moocp -PathType Leaf)) {
    Write-Error "moocp ist nicht zu finden: $Moocp (Parameter -Moocp)"
}
$beschreibung = Get-Content -LiteralPath (Join-Path $ordner 'plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$port = [int]$beschreibung.entwicklungsPort
if ($port -lt 1) {
    Write-Error 'plugin.json nennt keinen entwicklungsPort.'
}

# 32 Bytes aus dem sicheren Zufall, Base64url ohne Auffüllung -- wie moocp
# es für ein gestartetes Plugin tut.
$bytes = New-Object byte[] 32
$zufall = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$zufall.GetBytes($bytes)
$zufall.Dispose()
$env:MOOCP_PLUGIN_SCHLUESSEL = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

try {
    # Start-Process setzt die Argumente nur mit Leerzeichen zusammen; Pfade
    # mit Leerzeichen brauchen deshalb eigene Anführungszeichen.
    $quelle = Join-Path $ordner 'beispiel.dart'
    $plugin = Start-Process -FilePath $Dart -ArgumentList @('run', "`"$quelle`"", '--port', "$port", '--entwicklung') `
        -WorkingDirectory $wurzel -NoNewWindow -PassThru
    Write-Host "Beispiel-Plugin läuft auf 127.0.0.1:$port. moocp startet und fragt, ob es das Plugin anhängen soll."
    Start-Process -FilePath $Moocp -ArgumentList @('--plugin-entwicklung', "`"$ordner`"")
    $plugin.WaitForExit()
}
finally {
    Remove-Item Env:MOOCP_PLUGIN_SCHLUESSEL -ErrorAction SilentlyContinue
}

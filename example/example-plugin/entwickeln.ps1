# Startet das Beispiel-Plugin zum Entwickeln und hängt es an die installierte
# moocp an (README, Teil 4, „Ein Plugin entwickeln“). Unter Windows; auf dem
# Mac tut entwickeln.sh dasselbe.
#
#   powershell -ExecutionPolicy Bypass -File example\example-plugin\entwickeln.ps1 [-Moocp <Pfad zur moocp.exe>]
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
# bekommt. Deshalb behält das Skript den Schlüssel, bis es selbst endet: Endet
# das Plugin, startet Enter es mit demselben Schlüssel neu (etwa nach einer
# Änderung am Quelltext), und moocp verbindet sich wieder, sobald es zurück
# ist. Strg+C beendet das Plugin und das Skript; moocp läuft weiter.
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
    # Im Projektordner: dart run findet dort pubspec.yaml und holt beim
    # ersten Mal die Pakete.
    $moocpGestartet = $false
    while ($true) {
        $plugin = Start-Process -FilePath $Dart -ArgumentList @('run', 'bin\beispiel.dart', '--port', "$port", '--entwicklung') `
            -WorkingDirectory $ordner -NoNewWindow -PassThru
        if (-not $moocpGestartet) {
            Write-Host "Beispiel-Plugin läuft auf 127.0.0.1:$port. moocp startet und fragt, ob es das Plugin anhängen soll."
            Start-Process -FilePath $Moocp -ArgumentList @('--plugin-entwicklung', "`"$ordner`"")
            $moocpGestartet = $true
        }
        else {
            Write-Host "Beispiel-Plugin läuft wieder auf 127.0.0.1:$port, mit demselben Schlüssel; moocp verbindet sich von selbst."
        }
        $plugin.WaitForExit()
        # Nur Enter startet neu; Strg+C hier beendet das Skript.
        $null = Read-Host 'Das Plugin ist beendet. Enter startet es mit demselben Schlüssel neu, Strg+C beendet'
    }
}
finally {
    Remove-Item Env:MOOCP_PLUGIN_SCHLUESSEL -ErrorAction SilentlyContinue
}

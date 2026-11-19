#!/usr/bin/env python3
"""Fordert Desktop-Bauten auf GitHub an oder lädt einen bestätigten Lauf herunter."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

PLATTFORMEN = ('linux', 'windows', 'macos')
WORKFLOW = 'desktop-builds.yml'


def auswahl(text):
    werte = PLATTFORMEN if text == 'all' else text.split(',')
    if not werte or any(w not in PLATTFORMEN for w in werte):
        raise argparse.ArgumentTypeError('Plattform: linux, windows, macos oder all; mehrere mit Komma.')
    return [p for p in PLATTFORMEN if p in werte]


def matrix(platform, message):
    plattformen = auswahl(platform) if platform else [p for p in PLATTFORMEN if f'[ci:{p}]' in message]
    plattformen = plattformen or ['linux']
    runner = {'linux': 'ubuntu-24.04', 'windows': 'windows-2022', 'macos': 'macos-26'}
    return {'include': [{'platform': p, 'runner': runner[p]} for p in plattformen]}


def run(*args):
    return subprocess.check_output(args, text=True, encoding='utf-8').strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', nargs='?', default='linux', type=auswahl)
    parser.add_argument('--task', choices=['all', 'tests', 'builds'], default='all')
    parser.add_argument('--download', metavar='RUN_ID', type=int)
    parser.add_argument('--commit', help='Erwarteter Commit beim Download; Vorgabe: aktueller HEAD.')
    parser.add_argument('--output', type=Path, default=Path('build/ci-downloads'))
    parser.add_argument('--install-linux', action='store_true', help='Linux-Bundle mit dem App-Installer regulär installieren; laufende Ziel-App wird nicht beendet.')
    parser.add_argument('--matrix', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.matrix:
        print(json.dumps(matrix(os.environ.get('PLATFORM', ''), os.environ.get('MESSAGE', ''))))
        return
    if args.install_linux and (not sys.platform.startswith('linux') or args.platform != ['linux'] or args.download is None):
        parser.error('--install-linux braucht einen Linux-Rechner, nur linux und --download RUN_ID.')
    os.chdir(Path(__file__).resolve().parent.parent)
    repo = run('gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner')
    if args.download is not None:
        sha = args.commit or run('git', 'rev-parse', 'HEAD')
        ci = json.loads(run('gh', 'run', 'view', str(args.download), '-R', repo,
                            '--json', 'headSha,status,conclusion,workflowName,url'))
        if ci['headSha'] != sha or ci['workflowName'] != 'Desktop builds':
            raise RuntimeError('Der Lauf gehört nicht zum erwarteten Commit und Desktop-Workflow; nichts heruntergeladen.')
        if ci['status'] != 'completed' or ci['conclusion'] != 'success':
            raise RuntimeError(f'Der Lauf ist nicht erfolgreich abgeschlossen: {ci["url"]}')
        output = args.output.resolve() / sha
        for platform in args.platform:
            arch = 'arm64' if platform == 'macos' else 'x64'
            subprocess.run(['gh', 'run', 'download', str(args.download), '-R', repo,
                            '-n', f'moocp-{platform}-{arch}', '-D', str(output / platform)], check=True)
        if args.install_linux:
            installieren(output / 'linux' / 'moocp-linux-x64.tar.gz', sha)
        print(f'Bundles heruntergeladen: {output}')
        return
    branch = run('git', 'branch', '--show-current')
    if not branch or branch in ('main', 'master'):
        parser.error('Bau von einem eigenen Zweig anfordern, nicht vom Hauptzweig oder detached HEAD.')
    if run('git', 'status', '--porcelain'):
        parser.error('Zuerst Änderungen committen; GitHub baut ausschließlich den gepushten Commit.')
    marker = ' '.join(f'[ci:{p}]' for p in args.platform)
    subprocess.run(['git', 'commit', '--allow-empty', '-m', f'ci: request desktop bundle {marker} [ci:{args.task}]'], check=True)
    sha = run('git', 'rev-parse', 'HEAD')
    subprocess.run(['git', 'push', 'origin', f'HEAD:refs/heads/{branch}'], check=True)
    print(f'Bau angefordert: {sha} ({", ".join(args.platform)}; {args.task}).')
    print(f'Lauf anzeigen: gh run list -R {repo} --workflow {WORKFLOW} --commit {sha}')
    print(f'Nach erfolgreichem Abschluss: python tool/ci_bau.py {",".join(args.platform)} --download RUN_ID --commit {sha}')


def installieren(archiv, sha):
    # Auf Platte beim Download entpacken, nicht im möglicherweise knappen tmpfs.
    with tempfile.TemporaryDirectory(prefix='install-', dir=archiv.parent) as temp:
        with tarfile.open(archiv, 'r:gz') as paket:
            paket.extractall(temp, filter='data')
        quelle = Path(temp)
        ziel = Path.home() / '.local' / 'opt' / 'moocp'
        subprocess.run([str(quelle / 'moocp'), '--installieren', '--still',
                        f'--quelle={quelle}', f'--ziel={ziel}'], check=True)
        (ziel / 'build-commit.txt').write_text(sha + '\n', encoding='utf-8')
        print(f'Installiert: {ziel} (Commit {sha}). Eine laufende App wurde nicht beendet.')


if __name__ == '__main__':
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError, FileNotFoundError) as error:
        raise SystemExit(f'CI-Bau fehlgeschlagen: {error}') from error

#!/usr/bin/env python3
"""Startet den Experiment-Bau auf GitHub und lädt sein Bundle auf diesen Rechner."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

BRANCH = 'experiment/github-actions-builds'
REPO = 'Moodle-in-Niedersachsene-V/moocp'
WORKFLOW = 'experiment-builds.yml'


def run(*args):
    return subprocess.check_output(args, text=True, encoding='utf-8').strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['linux', 'windows', 'both'])
    parser.add_argument('--task', choices=['all', 'tests', 'builds'], default='all')
    parser.add_argument('--output', type=Path, default=Path('build/ci-downloads'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    if run('git', 'branch', '--show-current') != BRANCH:
        parser.error(f'Zuerst {BRANCH} auschecken.')
    if run('git', 'status', '--porcelain'):
        parser.error('Zuerst Änderungen committen oder beiseitelegen; der Bau verwendet nur den Commit.')
    run('gh', 'auth', 'status')
    marker = '' if args.platform == 'both' else f' [ci:{args.platform}]'
    task = '' if args.task == 'all' else f' [ci:{args.task}]'
    run('git', 'commit', '--allow-empty', '-m', f'ci: request desktop bundle{marker}{task}')
    sha = run('git', 'rev-parse', 'HEAD')
    # Explizites Ziel: kein Push auf main, kein Force und kein Erraten des Remotes.
    subprocess.run(['git', 'push', f'https://github.com/{REPO}.git', f'HEAD:refs/heads/{BRANCH}'], check=True)
    print(f'GitHub baut Commit {sha}.', flush=True)
    for _ in range(60):
        runs = json.loads(run('gh', 'run', 'list', '-R', REPO, '--workflow', WORKFLOW,
                              '--branch', BRANCH, '--commit', sha, '--event', 'push',
                              '--json', 'databaseId,url'))
        if runs:
            break
        time.sleep(2)
    else:
        raise RuntimeError('Kein Workflow-Lauf gefunden. Actions-Berechtigungen auf GitHub prüfen.')
    ci = runs[0]
    print(ci['url'], flush=True)
    subprocess.run(['gh', 'run', 'watch', str(ci['databaseId']), '-R', REPO, '--exit-status', '--interval', '15'], check=True)
    if args.task == 'tests':
        print('Tests abgeschlossen; kein Bundle angefordert.')
        return
    output = args.output.resolve() / sha
    for platform in ['linux', 'windows'] if args.platform == 'both' else [args.platform]:
        target = output / platform
        subprocess.run(['gh', 'run', 'download', str(ci['databaseId']), '-R', REPO,
                        '-n', f'moocp-{platform}-x64', '-D', str(target)], check=True)
    print(f'Bundles heruntergeladen: {output}')


if __name__ == '__main__':
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError, FileNotFoundError) as error:
        raise SystemExit(f'CI-Bau fehlgeschlagen: {error}') from error

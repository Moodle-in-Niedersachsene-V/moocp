#!/usr/bin/env python3
"""Entscheidungen des Release-Workflows (.github/workflows/release.yml, E39).

Das Skript läuft nur auf GitHub-Runnern und in den Tests der Maintainer; die
App braucht es nicht. Die YAML-Datei ruft es nur auf:

  plan           Soll gebaut und veröffentlicht werden, mit welcher Version
                 und welchem Tag? Schreibt das Ergebnis nach $GITHUB_OUTPUT.
  set-version    Setzt die Version in pubspec.yaml der Arbeitskopie (die
                 Nightly-Version kommt so in den Bau, ohne Commit).
  notes          Schreibt den Abschnitt der Version aus CHANGELOG.md.
  check-assets   Prüft, dass ein Bau die erwarteten Pakete geliefert hat.
  publish        Legt Tag und Release an und hängt die Pakete an.

Veröffentlicht wird nur aus dem offiziellen Repository: eine Nightly aus
`main`, eine stabile Version aus einem Tag `v<Version>`. Jeder andere Lauf
(Zweig, Fork, `publish: false`) baut nur und lädt die Pakete als Artefakte
hoch; er legt weder Tag noch Release an.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys

OFFICIAL_REPO = 'Moodle-in-Niedersachsene-V/moocp'
PLATFORMS = ('linux', 'windows', 'macos')
# Die Labels der Gruppe „Release“ aus CONTRIBUTING.md.
LABELS = {
    'nightly': ('fbca04', 'Found in or about a nightly'),
    'post-reviewed': ('0e8a16', 'PR reviewed after its merge'),
}
NIGHTLY_TAG = re.compile(r'^v(\d+\.\d+\.\d+)-nightly\.(\d{8})\.(\d+)$')
STABLE_TAG = re.compile(r'^v(\d+\.\d+\.\d+)$')


class CommandError(Exception):
    """Ein Befehl ist gescheitert; `stderr` trägt seine Fehlermeldung."""

    def __init__(self, args, returncode, stderr):
        super().__init__(f'{" ".join(args[:3])} …: Exit {returncode}: {stderr.strip()}')
        self.returncode = returncode
        self.stderr = stderr


class ReleaseError(Exception):
    """Der Lauf darf so nicht weiter; die Meldung nennt den Grund."""


def run(*args):
    """Führt einen Befehl aus und gibt seine Ausgabe zurück (in Tests ersetzt)."""
    result = subprocess.run(args, capture_output=True, text=True, encoding='utf-8')
    if result.returncode != 0:
        raise CommandError(args, result.returncode, result.stderr)
    return result.stdout


def api(path):
    """Fragt die GitHub-API; ein 404 ergibt None, jeder andere Fehler bricht ab."""
    try:
        return json.loads(run('gh', 'api', path) or 'null')
    except CommandError as error:
        if 'HTTP 404' in error.stderr:
            return None
        raise


def today():
    """Das Datum des Laufs in UTC: JJJJMMTT."""
    return datetime.now(timezone.utc).strftime('%Y%m%d')


# --- Version -----------------------------------------------------------------

def read_pubspec_version(pubspec='pubspec.yaml'):
    """Die Version aus pubspec.yaml ohne Buildnummer, etwa 0.13.0.

    `main` führt immer eine Version ohne Vorabkennung (E39): Die Nightly setzt
    sie erst beim Bau dazu, nie im Quelltext.
    """
    text = Path(pubspec).read_text(encoding='utf-8')
    found = re.search(r'^version:\s*(\S+)\s*$', text, re.MULTILINE)
    if not found:
        raise ReleaseError('Keine Version in pubspec.yaml gefunden.')
    match = re.fullmatch(r'(\d+\.\d+\.\d+)(?:\+\d+)?', found.group(1))
    if not match:
        raise ReleaseError(f'Die Version in pubspec.yaml ({found.group(1)}) hat nicht die Form x.y.z oder x.y.z+n.')
    return match.group(1)


def set_pubspec_version(version, build, pubspec='pubspec.yaml'):
    """Schreibt `version: <version>+<build>` in pubspec.yaml, sonst nichts.

    Gebaut wird aus der Arbeitskopie des Runners; nichts davon wird
    committet. Zeilenenden und alle anderen Zeilen bleiben unverändert.
    """
    path = Path(pubspec)
    text = path.read_bytes().decode('utf-8')
    new, count = re.subn(r'^version:[^\r\n]*', f'version: {version}+{build}', text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise ReleaseError('Keine Version in pubspec.yaml gefunden.')
    path.write_bytes(new.encode('utf-8'))


def next_nightly_number(repo, base, date):
    """Die laufende Nummer der nächsten Nightly dieses Tages: 1, 2, …

    Gezählt wird nach den Tags, nicht nach den Releases: Ein Tag ohne Release
    (ein halb gescheiterter Lauf) darf seine Nummer nicht noch einmal bekommen.
    """
    prefix = f'v{base}-nightly.{date}.'
    refs = api(f'repos/{repo}/git/matching-refs/tags/{prefix}') or []
    numbers = []
    for ref in refs:
        found = NIGHTLY_TAG.match(ref['ref'].removeprefix('refs/tags/'))
        if found and found.group(1) == base and found.group(2) == date:
            numbers.append(int(found.group(3)))
    return max(numbers, default=0) + 1


def nightly_due(repo, sha):
    """Ob `main` seit der letzten Nightly einen neuen Commit hat (oder es noch keine gibt)."""
    releases = api(f'repos/{repo}/releases?per_page=100') or []
    last = None
    for release in releases:
        found = NIGHTLY_TAG.match(release.get('tag_name', ''))
        if found and release.get('prerelease') and not release.get('draft'):
            key = (found.group(2), int(found.group(3)))
            if last is None or key > last[0]:
                last = (key, release['tag_name'])
    if last is None:
        return True
    last_sha = (api(f'repos/{repo}/commits/{last[1]}') or {}).get('sha')
    if not last_sha:
        # Der Tag der letzten Nightly ist weg: lieber eine Nightly zu viel.
        return True
    if last_sha == sha:
        return False
    comparison = api(f'repos/{repo}/compare/{last_sha}...{sha}?per_page=1') or {}
    return comparison.get('ahead_by', 1) > 0


# Die Namen der Aufträge im Workflow Checks, zugleich die erforderlichen Prüfungen von main.
REQUIRED_CHECKS = ('flutter analyze', 'flutter test')


def failed_checks(repo, sha):
    """Welche der erforderlichen Prüfungen auf dem Commit nicht grün sind (leer = alle grün).

    Je Name zählt der jüngste Lauf: ein wiederholter grüner Lauf hebt ein früheres Rot auf.
    """
    runs = (api(f'repos/{repo}/commits/{sha}/check-runs?per_page=100') or {}).get('check_runs', [])
    latest = {}
    for check in runs:
        name = check.get('name')
        if name in REQUIRED_CHECKS and (name not in latest or check.get('id', 0) > latest[name].get('id', 0)):
            latest[name] = check
    return [name for name in REQUIRED_CHECKS
            if latest.get(name, {}).get('conclusion') != 'success']


def is_on_release_line(repo, sha):
    """Ob der Commit auf `main` oder einem Zweig `release/x.y` liegt (E39, Hotfix)."""
    branches = ['main']
    refs = api(f'repos/{repo}/git/matching-refs/heads/release/') or []
    branches += [ref['ref'].removeprefix('refs/heads/') for ref in refs]
    for branch in branches:
        comparison = api(f'repos/{repo}/compare/{sha}...{branch}?per_page=1') or {}
        # Basis = der Commit, Kopf = der Zweig: liegt der Commit auf dem Zweig,
        # ist der Zweig gleich oder voraus.
        if comparison.get('status') in ('identical', 'ahead'):
            return True
    return False


# --- Plan --------------------------------------------------------------------

def plan(env, today_value=None, pubspec='pubspec.yaml'):
    """Entscheidet über den Lauf; gibt ein Wörterbuch für $GITHUB_OUTPUT zurück.

    `env`: event, ref, sha, repo, channel ('nightly' oder 'stable'),
    publish (bool, ob der Aufrufer veröffentlichen will).
    """
    event = env['event']
    ref = env['ref']
    repo = env['repo']
    sha = env['sha']
    manual = event == 'workflow_dispatch'
    scheduled = event == 'schedule'
    channel = env.get('channel') or 'nightly'
    if channel not in ('nightly', 'stable'):
        raise ReleaseError(f'Unbekannter Kanal: {channel}')
    wants_publish = (manual and env.get('publish', True)) or scheduled
    base = read_pubspec_version(pubspec)

    # Wer veröffentlichen darf, steht hier und nirgends sonst: nur das
    # offizielle Repository, eine Nightly nur von `main`, eine stabile Version
    # nur von einem Tag der Form v<Version>.
    official = repo == OFFICIAL_REPO
    on_main = ref == 'refs/heads/main'
    tag_ref = ref.removeprefix('refs/tags/') if ref.startswith('refs/tags/') else ''
    reason = ''
    if not wants_publish:
        reason = 'kein Veröffentlichen verlangt'
    elif not official:
        reason = 'nicht das offizielle Repository'
    elif channel == 'nightly' and not on_main:
        reason = 'Nightly nur von main'
    elif channel == 'stable' and not tag_ref:
        if manual:
            raise ReleaseError('Eine stabile Version braucht einen Tag: den Lauf mit einem Tag v<Version> statt mit einem Zweig starten.')
        reason = 'stabile Version nur von einem Tag'
    publish = wants_publish and not reason

    result = {
        'channel': channel, 'build': 'true', 'publish': 'false', 'prerelease': 'false',
        'base_version': base, 'version': base, 'tag': f'v{base}', 'build_number': '',
        'version_suffix': '', 'reason': reason,
    }

    if channel == 'nightly':
        date = today_value or today()
        if scheduled and not official:
            # Ein Fork mit eingeschalteten Actions baut nachts nicht alle drei Plattformen umsonst.
            result.update(build='false', reason='nicht das offizielle Repository')
            return result
        if scheduled and not nightly_due(repo, sha):
            result.update(build='false', reason='keine neuen Commits seit der letzten Nightly')
            return result
        number = next_nightly_number(repo, base, date)
        suffix = f'-nightly.{date}.{number}'
        result.update(version=f'{base}{suffix}', tag=f'v{base}{suffix}', build_number=str(number),
                      version_suffix=suffix, prerelease='true')
    elif publish:
        found = STABLE_TAG.match(tag_ref)
        if not found:
            raise ReleaseError(f'Der Tag {tag_ref} hat nicht die Form v<Version> (x.y.z).')
        if found.group(1) != base:
            raise ReleaseError(f'Der Tag {tag_ref} passt nicht zur Version {base} in pubspec.yaml auf diesem Stand.')
        if not is_on_release_line(repo, sha):
            raise ReleaseError(f'Der Tag {tag_ref} liegt weder auf main noch auf einem Zweig release/x.y.')
        result['tag'] = tag_ref

    if publish:
        # Veröffentlicht wird nur, was Checks geprüft hat: Der Release-Workflow selbst
        # prüft und testet nicht noch einmal (E39, Datenschutz in jeder Nightly).
        failed = failed_checks(repo, sha)
        if failed:
            raise ReleaseError(f'Auf {sha[:12]} sind die Prüfungen nicht grün: {", ".join(failed)}. '
                               'Erst Checks abwarten oder neu starten.')
        if api(f'repos/{repo}/releases/tags/{result["tag"]}') is not None:
            raise ReleaseError(f'Zum Tag {result["tag"]} gibt es schon ein Release.')
        result['publish'] = 'true'
    return result


# --- Pakete, Text, Veröffentlichen --------------------------------------------

def expected_files(version, platform=None):
    """Die Namen der Pakete, wie die Update-Prüfung der App sie sucht (E19, E24)."""
    files = {
        'windows': [f'moocp_setup_{version}.exe'],
        'linux': [f'moocp_setup_{version}.run', f'moocp_{version}-x86_64.AppImage', f'moocp_{version}_amd64.deb'],
        'macos': [f'moocp_{version}_macos.dmg'],
    }
    if platform:
        return files[platform]
    return [name for p in ('windows', 'linux', 'macos') for name in files[p]]


def check_assets(directory, version, platform=None):
    """Prüft, dass jedes erwartete Paket da und nicht leer ist; gibt fehlende Namen zurück."""
    problems = []
    for name in expected_files(version, platform):
        path = Path(directory) / name
        if not path.is_file():
            problems.append(f'{name}: fehlt')
        elif path.stat().st_size == 0:
            problems.append(f'{name}: leer')
    return problems


def changelog_section(base, changelog='CHANGELOG.md'):
    """Der Abschnitt `## <Version>` aus CHANGELOG.md ohne Überschrift; None, wenn er fehlt oder leer ist."""
    lines = Path(changelog).read_text(encoding='utf-8').splitlines()
    heading = re.compile(rf'^##\s+v?{re.escape(base)}(\s|$)')
    for index, line in enumerate(lines):
        if heading.match(line):
            body = []
            for following in lines[index + 1:]:
                if following.startswith('## '):
                    break
                body.append(following)
            text = '\n'.join(body).strip()
            return text or None
    return None


def ensure_labels(repo):
    """Legt die Labels `nightly` und `post-reviewed` an, wo sie fehlen."""
    existing = {label['name'].lower() for label in json.loads(
        run('gh', 'label', 'list', '--repo', repo, '--limit', '200', '--json', 'name'))}
    created = []
    for name, (color, description) in LABELS.items():
        if name not in existing:
            run('gh', 'label', 'create', name, '--repo', repo, '--color', color, '--description', description)
            created.append(name)
    return created


def publish(repo, sha, channel, tag, version, notes_file, assets_dir):
    """Legt Tag und Release an und hängt alle fünf Pakete an.

    Eine Nightly legt ihren Tag selbst an, genau auf dem gebauten Commit
    (`--target`), und ist Vorabversion, nie „latest“; eine stabile Version
    nimmt den vorhandenen Tag (`--verify-tag`) und wird „latest“.
    """
    problems = check_assets(assets_dir, version)
    if problems:
        raise ReleaseError('Pakete unvollständig: ' + '; '.join(problems))
    if channel == 'nightly':
        if api(f'repos/{repo}/git/ref/tags/{tag}') is not None:
            raise ReleaseError(f'Der Tag {tag} gibt es schon; ein zweiter Lauf hat die Nummer vergeben.')
        flags = ['--target', sha, '--prerelease', '--latest=false']
    else:
        flags = ['--verify-tag', '--latest=true']
    ensure_labels(repo)
    files = [str(Path(assets_dir) / name) for name in expected_files(version)]
    run('gh', 'release', 'create', tag, *files, '--repo', repo, '--title', f'moocp {version}',
        '--notes-file', str(notes_file), *flags)


# --- Kommandozeile -------------------------------------------------------------

def write_output(values):
    target = os.environ.get('GITHUB_OUTPUT')
    lines = ''.join(f'{key}={value}\n' for key, value in values.items())
    if target:
        with open(target, 'a', encoding='utf-8') as handle:
            handle.write(lines)
    print(lines, end='')


def flag(text):
    return str(text).strip().lower() not in ('false', '0', 'no', 'nein')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)

    p = sub.add_parser('plan')
    p.add_argument('--event', default=os.environ.get('GITHUB_EVENT_NAME', ''))
    p.add_argument('--ref', default=os.environ.get('GITHUB_REF', ''))
    p.add_argument('--sha', default=os.environ.get('GITHUB_SHA', ''))
    p.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', ''))
    p.add_argument('--channel', default='')
    p.add_argument('--publish', default='true')
    p.add_argument('--date', help='JJJJMMTT; Vorgabe: heute (UTC)')

    p = sub.add_parser('set-version')
    p.add_argument('--version', required=True)
    p.add_argument('--build', required=True)

    p = sub.add_parser('notes')
    p.add_argument('--base-version', required=True)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--require', action='store_true', help='fehlender Abschnitt ist ein Fehler')

    p = sub.add_parser('check-assets')
    p.add_argument('--version', required=True)
    p.add_argument('--dir', default='installer', type=Path)
    p.add_argument('--platform', choices=PLATFORMS)

    p = sub.add_parser('publish')
    p.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', ''))
    p.add_argument('--sha', default=os.environ.get('GITHUB_SHA', ''))
    p.add_argument('--channel', required=True, choices=['nightly', 'stable'])
    p.add_argument('--tag', required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--notes-file', required=True, type=Path)
    p.add_argument('--dir', required=True, type=Path)

    args = parser.parse_args(argv)
    try:
        if args.command == 'plan':
            env = {'event': args.event, 'ref': args.ref, 'sha': args.sha, 'repo': args.repo,
                   'channel': args.channel, 'publish': flag(args.publish)}
            write_output(plan(env, args.date))
        elif args.command == 'set-version':
            set_pubspec_version(args.version, args.build)
        elif args.command == 'notes':
            text = changelog_section(args.base_version)
            if text is None:
                message = f'In CHANGELOG.md fehlt ein Abschnitt „{args.base_version}“ mit Inhalt.'
                if args.require:
                    raise ReleaseError(message)
                print(f'::warning::{message}')
                text = ''
            args.out.write_text(text + '\n' if text else '', encoding='utf-8')
        elif args.command == 'check-assets':
            problems = check_assets(args.dir, args.version, args.platform)
            if problems:
                raise ReleaseError('Pakete unvollständig: ' + '; '.join(problems))
            for name in expected_files(args.version, args.platform):
                print(f'{name} ({(args.dir / name).stat().st_size} Bytes)')
        elif args.command == 'publish':
            publish(args.repo, args.sha, args.channel, args.tag, args.version, args.notes_file, args.dir)
    except (ReleaseError, CommandError) as error:
        print(f'::error::{error}')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

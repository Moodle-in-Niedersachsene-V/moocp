"""Prüft die Entscheidungen des Release-Workflows mit simulierter GitHub-API.

Aufruf: python tool/test_ci_release.py -v
Nichts davon geht ins Netz: `ci_release.run` (gh) ist durch ein Modell von
GitHub ersetzt, wie `tool/test_ci_bau.py` es für den CI-Client tut.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ci_release

REPO = ci_release.OFFICIAL_REPO
MAIN_SHA = 'c' * 40
OLD_SHA = 'a' * 40


class FakeGitHub:
    """Das Wenige von GitHub, was das Skript fragt, als Daten.

    `compare` bildet die Lage der Commits ab: (Basis, Kopf) -> Antwort der API.
    """

    def __init__(self):
        self.releases = []   # {'tag_name', 'prerelease', 'draft'}
        self.tags = {}       # Tagname -> Commit
        self.release_branches = []
        self.compare = {}
        self.labels = []
        self.commands = []

    def add_nightly(self, tag, sha, release=True):
        self.tags[tag] = sha
        if release:
            self.releases.append({'tag_name': tag, 'prerelease': True, 'draft': False})

    def __call__(self, *args):
        self.commands.append(args)
        if args[:2] == ('gh', 'api'):
            return self.api(args[2])
        if args[:3] == ('gh', 'label', 'list'):
            return json.dumps([{'name': n} for n in self.labels])
        if args[:3] == ('gh', 'label', 'create'):
            self.labels.append(args[3])
            return ''
        if args[:3] == ('gh', 'release', 'create'):
            return ''
        raise AssertionError(args)

    def api(self, path):
        def missing():
            raise ci_release.CommandError(('gh', 'api', path), 1, 'gh: Not Found (HTTP 404)')

        assert path.startswith('repos/'), path
        path = path.split('/', 3)[3]
        if path.startswith('releases?'):
            return json.dumps(self.releases)
        if path.startswith('releases/tags/'):
            tag = path.removeprefix('releases/tags/')
            for release in self.releases:
                if release['tag_name'] == tag:
                    return json.dumps(release)
            missing()
        if path.startswith('git/matching-refs/tags/'):
            wanted = path.removeprefix('git/matching-refs/tags/')
            return json.dumps([{'ref': f'refs/tags/{t}'} for t in self.tags if t.startswith(wanted)])
        if path.startswith('git/matching-refs/heads/release/'):
            return json.dumps([{'ref': f'refs/heads/{b}'} for b in self.release_branches])
        if path.startswith('git/ref/tags/'):
            tag = path.removeprefix('git/ref/tags/')
            if tag in self.tags:
                return json.dumps({'ref': f'refs/tags/{tag}'})
            missing()
        if path.startswith('commits/'):
            tag = path.removeprefix('commits/')
            if tag in self.tags:
                return json.dumps({'sha': self.tags[tag]})
            missing()
        if path.startswith('compare/'):
            pair = tuple(path.removeprefix('compare/').split('?')[0].split('...'))
            return json.dumps(self.compare.get(pair, {'status': 'diverged', 'ahead_by': 1, 'behind_by': 1}))
        raise AssertionError(path)


def env(**values):
    base = {'event': 'workflow_dispatch', 'ref': 'refs/heads/main', 'sha': MAIN_SHA, 'repo': REPO,
            'channel': 'nightly', 'publish': True}
    base.update(values)
    return base


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()
        patcher = patch.object(ci_release, 'run', side_effect=self.github)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.pubspec = Path(self.dir.name) / 'pubspec.yaml'
        self.write_pubspec('0.13.0+1')

    def write_pubspec(self, version):
        self.pubspec.write_text(f'name: moocp\nversion: {version}\nenvironment:\n  sdk: ^3.14.0\n', encoding='utf-8')

    def plan(self, **values):
        date = values.pop('date', '20261124')
        return ci_release.plan(env(**values), date, str(self.pubspec))

    # --- Tag und laufende Nummer ---------------------------------------------

    def test_nightly_tag_comes_from_pubspec_version_without_build_number(self):
        for pubspec in ['0.13.0+1', '0.13.0', '0.13.0+25']:
            self.write_pubspec(pubspec)
            result = self.plan()
            self.assertEqual(result['tag'], 'v0.13.0-nightly.20261124.1')
            self.assertEqual(result['version'], '0.13.0-nightly.20261124.1')
            self.assertEqual(result['base_version'], '0.13.0')

    def test_second_run_on_same_day_gets_number_two(self):
        self.github.add_nightly('v0.13.0-nightly.20261124.1', OLD_SHA)
        result = self.plan()
        self.assertEqual(result['tag'], 'v0.13.0-nightly.20261124.2')
        self.assertEqual(result['build_number'], '2')

    def test_number_counts_tags_without_release_and_continues_after_the_highest(self):
        self.github.add_nightly('v0.13.0-nightly.20261124.1', OLD_SHA)
        self.github.add_nightly('v0.13.0-nightly.20261124.4', OLD_SHA, release=False)
        self.assertEqual(self.plan()['tag'], 'v0.13.0-nightly.20261124.5')

    def test_other_day_or_other_version_does_not_count(self):
        self.github.add_nightly('v0.13.0-nightly.20261123.7', OLD_SHA)
        self.github.add_nightly('v0.12.0-nightly.20261124.3', OLD_SHA)
        self.assertEqual(self.plan()['tag'], 'v0.13.0-nightly.20261124.1')

    def test_numbers_above_nine_are_compared_as_numbers(self):
        self.github.add_nightly('v0.13.0-nightly.20261124.9', OLD_SHA)
        self.github.add_nightly('v0.13.0-nightly.20261124.10', OLD_SHA)
        self.assertEqual(self.plan()['tag'], 'v0.13.0-nightly.20261124.11')

    def test_nightly_is_a_prerelease_and_publishes_from_main(self):
        result = self.plan()
        self.assertEqual((result['publish'], result['prerelease'], result['build']), ('true', 'true', 'true'))

    def test_pubspec_must_have_plain_version(self):
        for pubspec in ['0.13', '0.13.0-nightly.1+1', 'x']:
            self.write_pubspec(pubspec)
            with self.subTest(pubspec=pubspec), self.assertRaises(ci_release.ReleaseError):
                self.plan()

    # --- Wann eine Nightly fällig ist ----------------------------------------

    def test_scheduled_run_without_new_commits_builds_and_publishes_nothing(self):
        self.github.add_nightly('v0.13.0-nightly.20261123.1', MAIN_SHA)
        result = self.plan(event='schedule')
        self.assertEqual((result['build'], result['publish']), ('false', 'false'))

    def test_scheduled_run_with_new_commits_publishes(self):
        self.github.add_nightly('v0.13.0-nightly.20261123.1', OLD_SHA)
        self.github.compare[(OLD_SHA, MAIN_SHA)] = {'status': 'ahead', 'ahead_by': 3, 'behind_by': 0}
        result = self.plan(event='schedule')
        self.assertEqual((result['build'], result['publish']), ('true', 'true'))
        self.assertEqual(result['tag'], 'v0.13.0-nightly.20261124.1')

    def test_scheduled_run_publishes_when_there_is_no_nightly_yet(self):
        self.assertEqual(self.plan(event='schedule')['publish'], 'true')

    def test_scheduled_run_compares_with_the_newest_nightly_only(self):
        self.github.add_nightly('v0.13.0-nightly.20261120.1', OLD_SHA)
        self.github.add_nightly('v0.13.0-nightly.20261123.2', MAIN_SHA)
        self.github.add_nightly('v0.13.0-nightly.20261123.10', MAIN_SHA)
        self.assertEqual(self.plan(event='schedule')['publish'], 'false')

    def test_scheduled_run_ignores_stable_and_draft_releases(self):
        self.github.releases.append({'tag_name': 'v0.12.0', 'prerelease': False, 'draft': False})
        self.github.releases.append({'tag_name': 'v0.13.0-nightly.20261123.1', 'prerelease': True, 'draft': True})
        self.github.tags['v0.13.0-nightly.20261123.1'] = MAIN_SHA
        self.assertEqual(self.plan(event='schedule')['publish'], 'true')

    def test_scheduled_run_publishes_when_the_tag_of_the_last_nightly_is_gone(self):
        self.github.releases.append({'tag_name': 'v0.13.0-nightly.20261123.1', 'prerelease': True, 'draft': False})
        self.assertEqual(self.plan(event='schedule')['publish'], 'true')

    def test_manual_run_publishes_even_without_new_commits(self):
        self.github.add_nightly('v0.13.0-nightly.20261124.1', MAIN_SHA)
        result = self.plan()
        self.assertEqual(result['publish'], 'true')
        self.assertEqual(result['tag'], 'v0.13.0-nightly.20261124.2')

    # --- Wer veröffentlichen darf --------------------------------------------

    def test_dry_run_builds_without_tag_or_release(self):
        for values in [
            {'publish': False},
            {'ref': 'refs/heads/feat/probe'},
            {'ref': 'refs/pull/5/merge', 'event': 'pull_request'},
            {'ref': 'refs/heads/feat/probe', 'event': 'push'},
            {'ref': 'refs/heads/main', 'event': 'push'},
            {'repo': 'someone/moocp'},
            {'ref': 'refs/tags/v0.13.0'},
        ]:
            with self.subTest(values=values):
                self.github.commands.clear()
                result = self.plan(**values)
                self.assertEqual((result['build'], result['publish']), ('true', 'false'))
                self.assertTrue(result['reason'])
                self.assertFalse(any(c[:3] == ('gh', 'release', 'create') for c in self.github.commands))

    def test_dry_run_still_names_the_packages_like_a_publishing_run(self):
        result = self.plan(ref='refs/heads/feat/probe')
        self.assertEqual(result['version'], '0.13.0-nightly.20261124.1')

    # --- Stabile Version -----------------------------------------------------

    def stable(self, **values):
        defaults = {'channel': 'stable', 'ref': 'refs/tags/v0.13.0'}
        defaults.update(values)
        return self.plan(**defaults)

    def test_stable_publishes_a_normal_release_for_a_tag_on_main(self):
        self.github.compare[(MAIN_SHA, 'main')] = {'status': 'identical', 'ahead_by': 0, 'behind_by': 0}
        result = self.stable()
        self.assertEqual((result['publish'], result['prerelease'], result['tag'], result['version']),
                         ('true', 'false', 'v0.13.0', '0.13.0'))
        self.assertEqual(result['version_suffix'], '')

    def test_stable_tag_may_lie_behind_main_or_on_a_release_branch(self):
        self.github.compare[(MAIN_SHA, 'main')] = {'status': 'ahead', 'ahead_by': 4, 'behind_by': 0}
        self.assertEqual(self.stable()['publish'], 'true')
        self.github.compare.clear()
        self.github.release_branches = ['release/0.13']
        self.github.compare[(MAIN_SHA, 'release/0.13')] = {'status': 'identical', 'ahead_by': 0, 'behind_by': 0}
        self.write_pubspec('0.13.1+1')
        self.assertEqual(self.stable(ref='refs/tags/v0.13.1')['publish'], 'true')

    def test_stable_refuses_a_tag_off_main_and_release_branches(self):
        self.github.release_branches = ['release/0.12']
        with self.assertRaises(ci_release.ReleaseError):
            self.stable()

    def test_stable_refuses_tag_that_differs_from_pubspec_version(self):
        self.github.compare[(MAIN_SHA, 'main')] = {'status': 'identical'}
        for tag in ['refs/tags/v0.12.0', 'refs/tags/v0.13.0-nightly.20261124.1', 'refs/tags/release-1']:
            with self.subTest(tag=tag), self.assertRaises(ci_release.ReleaseError):
                self.stable(ref=tag)

    def test_stable_refuses_a_tag_that_already_has_a_release(self):
        self.github.compare[(MAIN_SHA, 'main')] = {'status': 'identical'}
        self.github.releases.append({'tag_name': 'v0.13.0', 'prerelease': False, 'draft': False})
        with self.assertRaises(ci_release.ReleaseError):
            self.stable()

    def test_manual_stable_from_a_branch_is_an_error_but_a_dry_run_is_not(self):
        with self.assertRaises(ci_release.ReleaseError):
            self.stable(ref='refs/heads/main')
        result = self.stable(ref='refs/heads/feat/probe', publish=False)
        self.assertEqual((result['build'], result['publish'], result['version']), ('true', 'false', '0.13.0'))

    def test_stable_from_fork_is_a_dry_run(self):
        self.assertEqual(self.stable(repo='someone/moocp')['publish'], 'false')


class PubspecTest(unittest.TestCase):
    def test_set_version_changes_only_the_version_line(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'pubspec.yaml'
            path.write_bytes('name: moocp\nversion: 0.13.0+1\ndependencies:\n  # version: nein\n'.encode())
            ci_release.set_pubspec_version('0.13.0-nightly.20261124.2', 2, str(path))
            self.assertEqual(path.read_bytes().decode(),
                             'name: moocp\nversion: 0.13.0-nightly.20261124.2+2\ndependencies:\n  # version: nein\n')

    def test_real_pubspec_has_a_version_the_script_can_read(self):
        self.assertRegex(ci_release.read_pubspec_version(str(Path(__file__).parent.parent / 'pubspec.yaml')),
                         r'^\d+\.\d+\.\d+$')


class ChangelogTest(unittest.TestCase):
    TEXT = '# Changelog\n\n## 0.13.0\n- Neu: eins.\n- Fix: zwei.\n\n## 0.12.0\n- alt\n'

    def section(self, text, version):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'CHANGELOG.md'
            path.write_text(text, encoding='utf-8')
            return ci_release.changelog_section(version, str(path))

    def test_section_of_the_version_without_heading_and_without_neighbours(self):
        self.assertEqual(self.section(self.TEXT, '0.13.0'), '- Neu: eins.\n- Fix: zwei.')
        self.assertEqual(self.section(self.TEXT, '0.12.0'), '- alt')

    def test_missing_or_empty_section_is_none(self):
        self.assertIsNone(self.section(self.TEXT, '0.14.0'))
        self.assertIsNone(self.section('## 0.13.0\n\n## 0.12.0\n- x\n', '0.13.0'))

    def test_version_prefix_of_another_version_does_not_match(self):
        self.assertIsNone(self.section('## 0.13.0.1\n- x\n', '0.13.0'))
        self.assertIsNone(self.section('## 0.13.01\n- x\n', '0.13.0'))

    def test_real_changelog_has_a_section_for_the_current_version(self):
        root = Path(__file__).parent.parent
        version = ci_release.read_pubspec_version(str(root / 'pubspec.yaml'))
        self.assertIsNotNone(ci_release.changelog_section(version, str(root / 'CHANGELOG.md')))


class PublishTest(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()
        patcher = patch.object(ci_release, 'run', side_effect=self.github)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.assets = Path(self.dir.name) / 'assets'
        self.assets.mkdir()
        self.notes = Path(self.dir.name) / 'notes.md'
        self.notes.write_text('- Neu: eins.\n', encoding='utf-8')

    def fill(self, version, skip=()):
        for name in ci_release.expected_files(version):
            if name not in skip:
                (self.assets / name).write_bytes(b'x')

    def release_command(self):
        return next(c for c in self.github.commands if c[:3] == ('gh', 'release', 'create'))

    def test_expected_names_follow_the_update_check_of_the_app(self):
        self.assertEqual(ci_release.expected_files('0.13.0-nightly.20261124.2'), [
            'moocp_setup_0.13.0-nightly.20261124.2.exe',
            'moocp_setup_0.13.0-nightly.20261124.2.run',
            'moocp_0.13.0-nightly.20261124.2-x86_64.AppImage',
            'moocp_0.13.0-nightly.20261124.2_amd64.deb',
            'moocp_0.13.0-nightly.20261124.2_macos.dmg',
        ])

    def test_nightly_creates_tag_at_the_built_commit_as_prerelease_never_latest(self):
        version = '0.13.0-nightly.20261124.2'
        self.fill(version)
        ci_release.publish(REPO, MAIN_SHA, 'nightly', f'v{version}', version, self.notes, self.assets)
        command = self.release_command()
        self.assertEqual(command[3], f'v{version}')
        self.assertEqual(sum(1 for a in command if a.startswith(str(self.assets))), 5)
        self.assertEqual(command[command.index('--target') + 1], MAIN_SHA)
        self.assertIn('--prerelease', command)
        self.assertIn('--latest=false', command)
        self.assertNotIn('--latest=true', command)
        self.assertEqual(command[command.index('--notes-file') + 1], str(self.notes))
        self.assertEqual(command[command.index('--repo') + 1], REPO)

    def test_stable_uses_the_existing_tag_and_becomes_latest(self):
        self.fill('0.13.0')
        ci_release.publish(REPO, MAIN_SHA, 'stable', 'v0.13.0', '0.13.0', self.notes, self.assets)
        command = self.release_command()
        self.assertIn('--verify-tag', command)
        self.assertIn('--latest=true', command)
        self.assertNotIn('--prerelease', command)
        self.assertNotIn('--target', command)

    def test_missing_or_empty_package_creates_nothing(self):
        version = '0.13.0-nightly.20261124.2'
        self.fill(version, skip=[f'moocp_{version}_macos.dmg'])
        with self.assertRaises(ci_release.ReleaseError):
            ci_release.publish(REPO, MAIN_SHA, 'nightly', f'v{version}', version, self.notes, self.assets)
        (self.assets / f'moocp_{version}_macos.dmg').write_bytes(b'')
        with self.assertRaises(ci_release.ReleaseError):
            ci_release.publish(REPO, MAIN_SHA, 'nightly', f'v{version}', version, self.notes, self.assets)
        self.assertFalse(any(c[:3] == ('gh', 'release', 'create') for c in self.github.commands))

    def test_nightly_refuses_a_tag_that_exists(self):
        version = '0.13.0-nightly.20261124.2'
        self.fill(version)
        self.github.tags[f'v{version}'] = OLD_SHA
        with self.assertRaises(ci_release.ReleaseError):
            ci_release.publish(REPO, MAIN_SHA, 'nightly', f'v{version}', version, self.notes, self.assets)
        self.assertFalse(any(c[:3] == ('gh', 'release', 'create') for c in self.github.commands))

    def test_labels_are_created_only_when_missing_and_before_the_release(self):
        version = '0.13.0-nightly.20261124.2'
        self.fill(version)
        self.github.labels = ['bug', 'Nightly']
        ci_release.publish(REPO, MAIN_SHA, 'nightly', f'v{version}', version, self.notes, self.assets)
        created = [c[3] for c in self.github.commands if c[:3] == ('gh', 'label', 'create')]
        self.assertEqual(created, ['post-reviewed'])
        kinds = [c[:3] for c in self.github.commands]
        self.assertLess(kinds.index(('gh', 'label', 'create')), kinds.index(('gh', 'release', 'create')))

    def test_check_assets_per_platform(self):
        version = '0.13.0'
        (self.assets / f'moocp_setup_{version}.exe').write_bytes(b'x')
        self.assertEqual(ci_release.check_assets(self.assets, version, 'windows'), [])
        self.assertEqual(len(ci_release.check_assets(self.assets, version, 'linux')), 3)
        self.assertEqual(len(ci_release.check_assets(self.assets, version)), 4)


class CommandLineTest(unittest.TestCase):
    def test_plan_writes_github_output_and_a_blocked_run_fails_with_an_error_line(self):
        github = FakeGitHub()
        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory() as temp, patch.object(ci_release, 'run', side_effect=github), \
                contextlib.chdir(root):
            output = Path(temp) / 'out'
            with patch.dict(os.environ, {'GITHUB_OUTPUT': str(output)}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ci_release.main(['plan', '--event', 'workflow_dispatch', '--ref', 'refs/heads/main',
                                                  '--sha', MAIN_SHA, '--repo', REPO, '--channel', 'nightly',
                                                  '--date', '20261124']), 0)
            lines = output.read_text().splitlines()
            self.assertIn('publish=true', lines)
            self.assertIn('tag=v' + ci_release.read_pubspec_version() + '-nightly.20261124.1', lines)
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(ci_release.main(['plan', '--event', 'workflow_dispatch', '--ref', 'refs/heads/main',
                                                  '--sha', MAIN_SHA, '--repo', REPO, '--channel', 'stable']), 1)
            self.assertIn('::error::', stdout.getvalue())


if __name__ == '__main__':
    unittest.main()

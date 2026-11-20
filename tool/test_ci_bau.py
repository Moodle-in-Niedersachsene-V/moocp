"""Prüft Bauauswahl und sicheren Download mit ersetzten Git-/GitHub-Prozessen."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import ci_bau


class CiBauTest(unittest.TestCase):
    def execute(self, *arguments, branch='feat/probe', dirty=False, sha='abc123', status='completed', conclusion='success'):
        self.commands = []

        def query(*args):
            self.commands.append(args)
            if args[:3] == ('gh', 'repo', 'view'):
                return 'Moodle-in-Niedersachsene-V/moocp'
            if args[:3] == ('git', 'branch', '--show-current'):
                return branch
            if args[:3] == ('git', 'status', '--porcelain'):
                return ' M README.md' if dirty else ''
            if args[:3] == ('git', 'rev-parse', 'HEAD'):
                return 'abc123'
            if args[:3] == ('gh', 'run', 'view'):
                return json.dumps({'headSha': sha, 'workflowName': 'Desktop builds', 'status': status,
                                   'conclusion': conclusion, 'url': 'https://github.com/example/moocp/actions/runs/42'})
            raise AssertionError(args)

        def action(args, **kwargs):
            self.commands.append(tuple(args))
            return subprocess.CompletedProcess(args, 0)

        with patch.object(sys, 'argv', ['ci_bau.py', *arguments]), \
                patch.object(ci_bau, 'run', side_effect=query), \
                patch.object(ci_bau.subprocess, 'run', side_effect=action), \
                patch.object(ci_bau.os, 'chdir'), contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            ci_bau.main()

    def test_one_two_or_three_platforms_select_only_requested_runners(self):
        for requested, expected in [('linux', ['linux']), ('macos,linux', ['linux', 'macos']),
                                    ('all', ['linux', 'windows', 'macos'])]:
            with self.subTest(requested=requested):
                self.assertEqual([r['platform'] for r in ci_bau.matrix(requested, '')['include']], expected)
        self.assertEqual(ci_bau.matrix('', '[ci:macos] [ci:windows]')['include'],
                         [{'platform': 'windows', 'runner': 'windows-2022'}, {'platform': 'macos', 'runner': 'macos-26'}])
        with self.assertRaises(argparse.ArgumentTypeError):
            ci_bau.auswahl('linux,unknown')

    def test_request_pushes_only_current_feature_branch_with_selected_platform(self):
        self.execute('linux', '--task', 'builds')
        commit = next(c for c in self.commands if c[:2] == ('git', 'commit'))
        self.assertIn('[ci:linux] [ci:builds]', commit[-1])
        self.assertNotIn('[ci:windows]', commit[-1])
        self.assertIn(('git', 'push', 'origin', 'HEAD:refs/heads/feat/probe'), self.commands)

    def test_main_detached_or_uncommitted_changes_never_commit_or_push(self):
        for options in [{'branch': 'main'}, {'branch': ''}, {'dirty': True}]:
            with self.subTest(options=options), self.assertRaises(SystemExit):
                self.execute('linux', **options)
            self.assertFalse(any(c[:2] in [('git', 'commit'), ('git', 'push')] for c in self.commands))

    def test_only_successful_exact_commit_downloads_native_artifact_paths(self):
        output = Path(tempfile.gettempdir()) / 'CI Downloads ä mit Leerzeichen'
        self.execute('linux,macos', '--download', '42', '--output', str(output))
        downloads = [c for c in self.commands if c[:3] == ('gh', 'run', 'download')]
        self.assertEqual([c[c.index('-n') + 1] for c in downloads], ['moocp-linux-x64', 'moocp-macos-arm64'])
        self.assertEqual(Path(downloads[0][-1]), output.resolve() / 'abc123' / 'linux')
        self.assertFalse(any(c[:2] in [('git', 'commit'), ('git', 'push')] for c in self.commands))

    def test_other_commit_failed_cancelled_or_unfinished_run_downloads_nothing(self):
        for options in [{'sha': 'other'}, {'conclusion': 'failure'}, {'conclusion': 'cancelled'}, {'status': 'in_progress'}]:
            with self.subTest(options=options), self.assertRaises(RuntimeError):
                self.execute('linux', '--download', '42', **options)
            self.assertFalse(any(c[:3] == ('gh', 'run', 'download') for c in self.commands))

    def test_install_uses_regular_installer_and_records_commit_only_after_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source'
            source.mkdir()
            (source / 'moocp').write_text('test executable')
            archive = root / 'bundle.tar.gz'
            with tarfile.open(archive, 'w:gz') as package:
                package.add(source / 'moocp', arcname='moocp')
            target = root / '.local' / 'opt' / 'moocp'
            target.mkdir(parents=True)
            marker = target / 'build-commit.txt'
            marker.write_text('old\n')
            with patch.object(ci_bau.Path, 'home', return_value=root), \
                    patch.object(ci_bau.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'installer')):
                with self.assertRaises(subprocess.CalledProcessError):
                    ci_bau.installieren(archive, 'abc123')
            self.assertEqual(marker.read_text(), 'old\n')
            with patch.object(ci_bau.Path, 'home', return_value=root), \
                    patch.object(ci_bau.subprocess, 'run') as installer, contextlib.redirect_stdout(io.StringIO()):
                ci_bau.installieren(archive, 'abc123')
            args = installer.call_args.args[0]
            self.assertIn('--installieren', args)
            self.assertIn('--still', args)
            self.assertIn(f'--ziel={target}', args)
            self.assertEqual(marker.read_text(), 'abc123\n')


if __name__ == '__main__':
    unittest.main()

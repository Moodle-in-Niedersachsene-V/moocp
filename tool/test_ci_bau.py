"""Prüft den CI-Client ohne echte Pushes oder GitHub-Aufträge, auch auf Windows/macOS."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import ci_bau


class CiClientTest(unittest.TestCase):
    def execute(self, platform='both', task='all', branch=ci_bau.BRANCH,
                dirty=False, failed=False, delayed=False):
        self.commands = []
        self.queries = 0
        self.output = Path(tempfile.gettempdir()) / 'CI Downloads mit Leerzeichen und Umlaut ä'

        def query(*args):
            self.commands.append(args)
            if args[:3] == ('git', 'branch', '--show-current'):
                return branch
            if args[:3] == ('git', 'status', '--porcelain'):
                return ' M README.md' if dirty else ''
            if args[:3] == ('git', 'rev-parse', 'HEAD'):
                return 'abc123'
            if args[:3] == ('gh', 'run', 'list'):
                self.queries += 1
                if delayed and self.queries == 1:
                    return '[]'
                return json.dumps([{'databaseId': 42, 'url': 'https://github.com/topse/moocp/actions/runs/42'}])
            return ''

        def action(args, **kwargs):
            self.commands.append(tuple(args))
            if failed and args[:3] == ['gh', 'run', 'watch']:
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0)

        argv = ['ci_bau.py', platform, '--task', task, '--output', str(self.output)]
        with patch.object(sys, 'argv', argv), patch.object(ci_bau, 'run', side_effect=query), \
                patch.object(ci_bau.subprocess, 'run', side_effect=action), \
                patch.object(ci_bau.os, 'chdir'), patch.object(ci_bau.time, 'sleep'), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            ci_bau.main()

    def test_both_downloads_exact_run_to_native_paths_with_spaces(self):
        self.execute(delayed=True)
        self.assertEqual(self.queries, 2)
        self.assertIn(('git', 'push', 'https://github.com/topse/moocp.git',
                       f'HEAD:refs/heads/{ci_bau.BRANCH}'), self.commands)
        queries = [c for c in self.commands if c[:3] == ('gh', 'run', 'list')]
        self.assertTrue(all(c[c.index('--commit') + 1] == 'abc123' for c in queries))
        downloads = [c for c in self.commands if c[:3] == ('gh', 'run', 'download')]
        self.assertEqual(len(downloads), 2)
        for command, platform in zip(downloads, ['linux', 'windows']):
            self.assertEqual(command[3], '42')
            self.assertEqual(command[command.index('-n') + 1], f'moocp-{platform}-x64')
            self.assertEqual(Path(command[-1]), self.output.resolve() / 'abc123' / platform)

    def test_platform_markers_and_single_download(self):
        for platform in ['linux', 'windows']:
            with self.subTest(platform=platform):
                self.execute(platform=platform, task='builds')
                commit = next(c for c in self.commands if c[:2] == ('git', 'commit'))
                self.assertIn(f'[ci:{platform}]', commit[-1])
                self.assertIn('[ci:builds]', commit[-1])
                self.assertEqual(sum(c[:3] == ('gh', 'run', 'download') for c in self.commands), 1)

    def test_tests_only_downloads_no_bundle(self):
        self.execute(task='tests')
        self.assertFalse(any(c[:3] == ('gh', 'run', 'download') for c in self.commands))
        self.assertTrue(any(c[:3] == ('gh', 'run', 'watch') for c in self.commands))

    def test_failed_or_cancelled_ci_downloads_nothing(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute(failed=True)
        self.assertFalse(any(c[:3] == ('gh', 'run', 'download') for c in self.commands))

    def test_wrong_branch_or_dirty_tree_never_commits_or_pushes(self):
        for options in [{'branch': 'main'}, {'dirty': True}]:
            with self.subTest(options=options), self.assertRaises(SystemExit):
                self.execute(**options)
            self.assertFalse(any(c[:2] in [('git', 'commit'), ('git', 'push')] for c in self.commands))


if __name__ == '__main__':
    unittest.main()

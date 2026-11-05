"""Exercise public-content scanning in isolated Git repositories."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCANNER = Path(__file__).with_name('check-public-content.py')


class PublicContentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        (self.root / 'tracked.txt').write_text('public fixture\n')
        self.git('add', 'tracked.txt')

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        subprocess.run(['git', *args], cwd=self.root, check=True, capture_output=True)

    def scan(self, *args):
        return subprocess.run([sys.executable, str(SCANNER), *args], cwd=self.root,
                              text=True, capture_output=True)

    def test_untracked_credentials_are_scanned_without_printing_the_secret(self):
        secret = 'sk-' + 'a' * 32
        (self.root / 'new.txt').write_text(secret)
        self.assertEqual(self.scan().returncode, 0)
        result = self.scan('--include-untracked')
        self.assertEqual(result.returncode, 1)
        self.assertIn('new.txt:1: provider-credential', result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_ignored_runtime_files_stay_out_of_worktree_scan(self):
        (self.root / '.gitignore').write_text('.build/\n')
        folder = self.root / '.build'
        folder.mkdir()
        (folder / 'private.txt').write_text('sk-' + 'a' * 32)
        result = self.scan('--include-untracked')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('0 findings', result.stdout)

    def test_untracked_private_artifacts_are_rejected_by_path(self):
        (self.root / 'recording.wav').write_bytes(b'not real audio')
        result = self.scan('--include-untracked')
        self.assertEqual(result.returncode, 1)
        self.assertIn('recording.wav:0: private-artifact-path', result.stderr)

    def test_staged_mode_reads_index_even_when_worktree_has_changed(self):
        (self.root / 'tracked.txt').write_text('sk-' + 'a' * 32)
        result = self.scan('--staged')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.scan().returncode, 1)

    def test_staged_and_untracked_modes_cannot_be_combined(self):
        self.assertEqual(self.scan('--staged', '--include-untracked').returncode, 2)


if __name__ == '__main__':
    unittest.main()

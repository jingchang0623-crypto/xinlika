#!/usr/bin/env python3
"""Offline sampling safety checks: no hardware, credentials or ASR."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("real_evaluation", Path(__file__).with_name("evaluate-voxgate-real.py"))
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class LocalReviewTests(unittest.TestCase):
    def test_explicit_range_is_local_and_has_origin_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = bytes(range(251)) * 1000
            source = root / "selected.opus"
            source.write_bytes(raw)
            output = root / "private"
            original_read = Path.read_text

            def deny_credentials(path, *args, **kwargs):
                if path.name == "config.json":
                    raise AssertionError("offline preparation loaded credentials")
                return original_read(path, *args, **kwargs)

            # Any accidental network request fails the test, independently of credentials.
            with mock.patch("sys.argv", ["evaluate", "--raw", str(source), "--seconds", "60",
                                          "--start-seconds", "60", "--output", str(output), "--prepare-only"]), \
                 mock.patch.object(Path, "read_text", deny_credentials), \
                 mock.patch("urllib.request.urlopen", side_effect=AssertionError("unexpected network")), \
                 contextlib.redirect_stdout(io.StringIO()):
                evaluation.main()
            report = json.loads((output / "report.json").read_text())
            self.assertEqual((output / "whole.bin").read_bytes(), raw[120000:240000])
            self.assertEqual(report["original_file_sha256"], hashlib.sha256(raw).hexdigest())
            self.assertEqual(report["source_sha256"], hashlib.sha256(raw[120000:240000]).hexdigest())
            self.assertEqual(report["selected_byte_range"], [120000, 240000])
            self.assertFalse(report["asr_requested"])
            self.assertIsNone(report["whole_vs_minutes_normalized_edit_fraction"])
            self.assertIsNone(report["ground_truth"])
            self.assertEqual(report["source_kind"], "unverified")
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)

    def test_missing_requested_range_fails_before_output_or_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "short.opus"
            source.write_bytes(bytes(120000))
            output = root / "must-not-exist"
            with mock.patch("sys.argv", ["evaluate", "--raw", str(source), "--seconds", "60",
                                          "--start-seconds", "1", "--output", str(output), "--prepare-only"]), \
                 contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                evaluation.main()
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()

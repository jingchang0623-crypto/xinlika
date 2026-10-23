#!/usr/bin/env python3
"""Synthetic regression tests; no BLE, microphone, private recording, or cloud access."""
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("cb08_analysis", Path(__file__).with_name("analyze-cb08-capture.py"))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


class CaptureAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.capture = self.root / "capture"
        self.capture.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def fixture(self, payload=b"a" * 40, offset=0, dropped=0, truncated=False):
        (self.capture / "audio-test.bin").write_bytes(payload)
        rows = [{"event": "frame", "audioFile": "audio-test.bin", "audioOffset": offset,
                 "audioBytes": len(payload), "uptime": 10.0}]
        (self.capture / "events.ndjson").write_text("\n".join(json.dumps(r) for r in rows) + ("\n{" if truncated else "\n"))
        (self.capture / "capture-summary.json").write_text(json.dumps({"audio": {"bytes": len(payload)}, "droppedSubmissions": dropped}))

    def run_analysis(self, decode=False, references=None):
        return analysis.analyze(self.capture, self.root / "analysis", decode, shutil.which("ffmpeg"), -50, references or [])

    def test_truncated_event_invalidates_evidence(self):
        self.fixture(truncated=True)
        result = self.run_analysis()
        self.assertEqual(result["integrityVerdict"], "failed_or_incomplete")
        self.assertIn("truncated", result["problems"][0])

    def test_offset_or_queue_loss_not_hidden_by_summary(self):
        self.fixture(offset=5, dropped=1)
        result = self.run_analysis()
        self.assertTrue(any("noncontiguous" in p for p in result["problems"]))
        self.assertTrue(any("queue drops" in p for p in result["problems"]))

    def test_partial_codec_packet_is_not_trimmed(self):
        self.fixture(payload=b"x" * 41)
        result = self.run_analysis(decode=True)
        self.assertTrue(any("no bytes trimmed" in p for p in result["problems"]))
        self.assertEqual((self.capture / "audio-test.bin").stat().st_size, 41)

    def test_repeated_reference_content_is_ambiguous(self):
        self.fixture()
        card = self.root / "card.opus"
        card.write_bytes(b"a" * 200)
        result = self.run_analysis(references=[card])
        self.assertEqual(result["streams"][0]["referenceVerdict"], "ambiguous_exact_matches")
        self.assertEqual(result["threeHourContinuityVerdict"], "not_established")

    def test_arrival_gap_is_not_classified_as_silence(self):
        self.fixture()
        with (self.capture / "events.ndjson").open("a") as target:
            target.write(json.dumps({"event": "frame", "audioFile": "audio-test.bin", "audioOffset": 40,
                                     "audioBytes": 40, "uptime": 20.0}) + "\n")
        (self.capture / "audio-test.bin").write_bytes(b"a" * 80)
        (self.capture / "capture-summary.json").write_text(json.dumps({"audio": {"bytes": 80}}))
        result = self.run_analysis()
        self.assertEqual(result["arrivalGapsOverOneSecond"][0]["arrivalSeconds"], 10)
        self.assertNotIn("quietCandidateSeconds", result)
        self.assertEqual(result["hardwareVadVerdict"], "not_tested_energy_on_host_cannot_establish_firmware_vad")

    def test_rollover_survives_unknown_identity_during_transition(self):
        self.fixture()
        with (self.capture / "events.ndjson").open("a") as target:
            for at, name, seconds in [(100, "note-old.opus", "10800"), (101, "unknown", "unknown"), (102, "note-next.opus", "1")]:
                target.write(json.dumps({"event": "snapshot", "filename": name, "uptime": at, "seconds": seconds}) + "\n")
        result = self.run_analysis()
        self.assertEqual(len(result["fileChanges"]), 1)
        self.assertEqual(result["fileChanges"][0]["previous"], "note-old.opus")
        self.assertEqual(result["fileChanges"][0]["earliestObservationUptime"], "100")
        self.assertNotEqual(result["fileChanges"][0]["audioContinuityVerdict"], "passed")

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg required for real decoder fixture")
    def test_real_opus_decode_and_energy_without_speech_claim(self):
        encoded = self.root / "generated.ogg"
        subprocess.run([shutil.which("ffmpeg"), "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                        "aevalsrc=if(lt(t\\,1)\\,0\\,0.2*sin(2*PI*440*t)):s=16000:d=2",
                        "-ac", "1", "-c:a", "libopus", "-b:a", "16k", "-vbr", "off", "-frame_duration", "20",
                        str(encoded)], check=True)
        data = encoded.read_bytes()
        cursor, partial, packets = 0, b"", []
        while cursor < len(data):
            self.assertEqual(data[cursor:cursor + 4], b"OggS")
            segments = data[cursor + 26]
            laces = data[cursor + 27:cursor + 27 + segments]
            body = cursor + 27 + segments
            for length in laces:
                partial += data[body:body + length]
                body += length
                if length < 255:
                    packets.append(partial)
                    partial = b""
            cursor = body
        opus = packets[2:]
        self.assertTrue(opus and all(len(p) == 40 for p in opus))
        self.fixture(payload=b"".join(opus))
        result = self.run_analysis(decode=True)
        self.assertEqual(result["problems"], [])
        decoded = result["streams"][0]["decode"]
        self.assertTrue(decoded["baselineSampleCountMatches"])
        self.assertGreater(decoded["quietCandidateSeconds"], 0.6)
        self.assertGreater(decoded["decodedSeconds"] - decoded["quietCandidateSeconds"], 0.6)
        # A sine wave is active sound, not evidence of speech or hardware voice activation.
        self.assertIn("Energy only", decoded["warning"])


if __name__ == "__main__":
    unittest.main()

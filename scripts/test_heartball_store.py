#!/usr/bin/env python3
"""Synthetic evidence only; never connects to a recorder or invokes ASR."""
import json
from pathlib import Path
import tempfile
import unittest
import uuid

from heartball_store import Conflict, Store


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name))
        self.sid = str(uuid.uuid4())
        self.session = self.store.create_session(self.sid)
        self.store.update_session(self.sid, status="recording")
        (Path(self.session["directory"]) / "probe").mkdir()

    def tearDown(self):
        self.store.db.close()
        self.temp.cleanup()

    def data(self, data: bytes, name="audio-test-AE22.bin"):
        (Path(self.session["directory"]) / "probe" / name).write_bytes(data)
        return name

    def ingest(self, name, begin, count):
        self.store.ingest(self.sid, {"audioFile": name, "audioOffset": begin,
                                   "audioBytes": count, "time": "2026-10-21T03:00:00Z"})

    def test_delayed_archive_does_not_replace_newer_or_active_capture_state(self):
        import uuid
        self.store.update_session(self.sid,status='completed')
        self.store.db.execute("update sessions set started_at='2026-10-20T00:00:00Z' where id=?",(self.sid,));self.store.db.commit()
        latest=str(uuid.uuid4());self.store.create_session(latest)
        self.store.update_session(latest,status='completed')
        self.store.db.execute("update sessions set started_at='2026-10-22T19:53:56+08:00' where id=?",(latest,));self.store.db.commit()
        delayed=str(uuid.uuid4());self.store.create_session(delayed)
        self.store.update_session(delayed,status='completed')
        self.store.db.execute("update sessions set started_at='2026-10-22T08:00:29Z' where id=?",(delayed,));self.store.db.commit()
        self.assertEqual(self.store.state()['session']['id'],latest)
        self.store.update_session(delayed,status='recording')
        self.assertEqual(self.store.state()['session']['id'],delayed)

    def test_sixty_second_batch_and_persisted_tail(self):
        name = self.data(b"a" * 120160)
        self.ingest(name, 0, 120160)
        self.assertEqual([b["audioSeconds"] for b in self.store.state()["batches"]], [60])
        self.store.finish(self.sid)
        self.assertEqual([b["audioSeconds"] for b in self.store.state()["batches"]], [60, 0.08])
        self.assertEqual(sum(p.stat().st_size for p in (Path(self.session["directory"]) / "batches").iterdir()), 120160)

    def test_clock_write_alone_is_not_verification_and_old_session_does_not_inherit_it(self):
        self.store.event(self.sid, 'clock_sync_tx', {'time': '2026-10-21T03:00:00Z'})
        self.assertEqual(self.store.state()['session']['clockStatus'], 'unverified')
        self.store.event(self.sid, 'clock_verification', {'status': 'new_filename_matches_host_start', 'time': '2026-10-21T03:00:01Z', 'timezone': 'Asia/Shanghai'})
        self.assertEqual(self.store.state()['session']['clockStatus'], 'new_filename_matches_host_start')
        self.store.update_session(self.sid, status='completed')
        self.store.create_session(str(uuid.uuid4()))
        self.assertEqual(self.store.state()['session']['clockStatus'], 'unverified')

    def test_focus_end_does_not_end_capture_and_retry_is_idempotent(self):
        name = self.data(bytes(range(160)) * 20)
        self.ingest(name, 0, 160)
        fid = str(uuid.uuid4())
        self.store.focus_start(fid, self.sid)
        self.ingest(name, 160, 1600)
        self.assertEqual(self.store.state()["focuses"][0]["audioSeconds"], 0.8)
        first = self.store.focus_end(fid)
        self.assertEqual(first, self.store.focus_end(fid))
        self.assertEqual(first, self.store.focus_end(fid.upper()))
        self.assertEqual(first, self.store.focus_start(fid, self.sid))
        self.ingest(name, 1760, 1440)
        state = self.store.state()
        self.assertEqual(state["session"]["status"], "recording")
        self.assertEqual(state["session"]["audioSeconds"], 1.6)
        self.assertEqual(state["focuses"][0]["audioSeconds"], 0.8)
        self.assertEqual(len([j for j in state["jobs"] if j["kind"] == "focus_analysis"]), 1)
        self.assertTrue(all(json.loads(r[0])["hardware_commands"] == 0 for r in self.store.db.execute("SELECT payload FROM events WHERE kind LIKE 'focus_%'")))

    def test_disconnect_never_joins_partial_packets(self):
        a = self.data(b"a" * 13, "audio-old-AE22.bin")
        b = self.data(b"b" * 40, "audio-new-AE22.bin")
        self.ingest(a, 0, 13)
        self.ingest(b, 0, 40)
        self.store.finish(self.sid)
        state = self.store.state()
        self.assertEqual(state["session"]["status"], "error")
        self.assertEqual([r[0] for r in self.store.db.execute("SELECT end_byte-start_byte FROM batches")], [40])
        self.assertEqual((Path(self.session["directory"]) / "probe" / a).read_bytes(), b"a" * 13)

    def test_journal_holes_are_not_silently_filled(self):
        name = self.data(b"a" * 480)
        self.ingest(name, 0, 160)
        with self.assertRaises(Conflict):
            self.ingest(name, 320, 160)
        self.assertEqual(self.store.state()["session"]["audioSeconds"], 0.08)

    def test_atomic_focus_failure_can_retry_without_duplicate_audio(self):
        name = self.data(b"a" * 400)
        self.ingest(name, 0, 40)
        fid = str(uuid.uuid4())
        self.store.focus_start(fid, self.sid)
        initial_batches = self.store.state()["batches"]
        self.ingest(name, 40, 360)
        original = self.store._job
        self.store._job = lambda *args: (_ for _ in ()).throw(RuntimeError("synthetic failure"))
        with self.assertRaises(RuntimeError):
            self.store.focus_end(fid)
        self.assertEqual(self.store.state()["focuses"][0]["status"], "recording")
        self.assertEqual(self.store.state()["batches"], initial_batches)
        self.store._job = original
        self.store.focus_end(fid)
        self.assertEqual(len(self.store.state()["batches"]), len(initial_batches) + 1)

    def test_reopen_and_replay_preserves_identity(self):
        name = self.data(b"a" * 120000)
        self.ingest(name, 0, 120000)
        before = self.store.state()
        self.store.db.close()
        self.store = Store(Path(self.temp.name))
        self.ingest(name, 0, 120000)
        self.assertEqual(before, self.store.state())

    def test_bounds_and_input_identity(self):
        with self.assertRaises(ValueError):
            self.store.create_session(str(uuid.uuid4()), 301)
        with self.assertRaises(Conflict):
            self.store.create_session(self.sid, 120)
        with self.assertRaises(ValueError):
            self.store.focus_start("not-a-uuid", self.sid)
        with self.assertRaises(ValueError):
            self.ingest("../../private.bin", 0, 40)

    def test_same_audio_reuses_asr_job_but_keeps_both_batches(self):
        name = self.data(b"a" * 240000)
        self.ingest(name, 0, 240000)
        state = self.store.state()
        self.assertEqual(len(state["batches"]), 2)
        self.assertEqual(len(state["jobs"]), 1)
        self.assertEqual(state["jobs"][0]["status"], "blocked_quality_review")
        self.assertFalse(state["asrEnabled"])

    def test_tiny_tail_requires_context_review_not_standalone_asr(self):
        proof = {"sha256": "synthetic-card-hash", "status": "card_verified", "missingLiveRanges": [[160, 200]]}
        self.store.archive_review(self.sid, proof)
        self.store.archive_review(self.sid, proof)
        jobs = self.store.state()["jobs"]
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0]["kind"], "audio_repair_review")
        payload = json.loads(self.store.db.execute("SELECT payload FROM jobs").fetchone()[0])
        self.assertTrue(payload["context_merge_required"])
        self.assertFalse(payload["standalone_asr_allowed"])


if __name__ == "__main__":
    unittest.main()

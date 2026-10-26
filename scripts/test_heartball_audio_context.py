"""Control tests: acoustic observations are hints, never source/identity authority."""
import copy
import datetime as dt
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from zoneinfo import ZoneInfo

from heartball_processing import Processor
from heartball_store import Store, Conflict, now


class AudioContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name))
        self.processor = Processor(self.store)
        self.agent = self.processor.agent
        self.audio = self.agent.acoustics
        self.sid, self.bid, self.eid = [str(uuid.uuid4()) for _ in range(3)]
        self.store.create_session(self.sid)
        self.store.update_session(self.sid, status='completed')
        self.agent.policy(self.sid, asr=False, agent=True, source_kind='unknown')
        self.digest = hashlib.sha256(b'a'*40000).hexdigest()
        self.stamp = dt.datetime.now(ZoneInfo('Asia/Shanghai')).replace(hour=12, minute=0).isoformat()
        with self.store.transaction():
            self.store.db.execute('INSERT INTO batches VALUES(?,?,?,?,?,?,?,?,?)',
                (self.bid, self.sid, 0, 'stream', 120000, 160000, self.digest, 'private.cb08', 'test'))
        self.doc = {'id':str(uuid.uuid4()), 'session_id':self.sid, 'kind':'ambient', 'input_key':self.bid,
            'text':'多人在讨论项目界面。', 'source_kind':'unknown', 'occurred_at':self.stamp,
            'boundary_quality':'batch_exact', 'evidence':[{'batch_id':self.bid, 'audio_hash':self.digest,
                'start_byte':120000, 'end_byte':160000, 'focus_exact_batches':False}]}
        self.agent.commit_document(self.doc, {'title':'界面讨论', 'summary':self.doc['text'], 'claims':[]})
        with self.store.transaction():
            self.store.db.execute("INSERT INTO workspace_events VALUES(?,?,?,?,?,?,?,'active',1,?,?)",
                (self.eid, self.sid, 'ambient', '界面讨论', self.doc['text'], 'unknown', self.stamp, now(), now()))
            self.store.db.execute("INSERT INTO workspace_event_sources VALUES(?,?,1,?,'literal_anchor')",
                (self.eid, self.doc['id'], self.doc['text']))

    def tearDown(self):
        self.processor.close()
        self.store.db.close()
        self.temp.cleanup()

    def artifact(self):
        return {'source_sha256':self.digest, 'source_format':'raw_cb08_40',
            'producer_version':'xinlika-sherpa-probe-v1', 'selection':{'start':0, 'duration':20},
            'models':[{'name':'model.onnx', 'sha256':'a'*64}],
            'speech_intervals':[{'start_seconds':1, 'end_seconds':19}],
            'scene_windows':[{'start_seconds':0, 'end_seconds':20,
                'tags':[{'name':'Speech', 'score':0.9, 'index':0}],
                'source_medium':'unknown', 'user_identity':'unknown'}],
            'speaker_windows':[{'start_seconds':1, 'end_seconds':6,
                'anonymous_cluster':'speaker_1', 'user_identity':'not_enrolled',
                'boundary_precision':'coarse_5s_window_not_verified_turn'}],
            'anonymous_clusters':1, 'model_elapsed_seconds':1.2, 'enrollment_present':False,
            'asr_called':False, 'limits':['Uncalibrated acoustic hints']}

    def test_idempotent_and_durable_without_asr_or_source_promotion(self):
        a = self.artifact()
        identity = self.audio.import_probe(a)
        self.assertEqual(self.audio.import_probe(a), identity)
        self.assertEqual(len(self.audio.signature()), 1)
        self.assertEqual(self.store.db.execute('SELECT source_kind FROM processing_policies').fetchone()[0], 'unknown')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM claims').fetchone()[0], 0)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM transcripts').fetchone()[0], 0)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 0)
        from heartball_audio_context import AudioContextStore
        self.assertEqual(AudioContextStore(self.agent).signature(), [identity])

    def test_same_model_selection_cannot_silently_rewrite_observations(self):
        a = self.artifact()
        self.audio.import_probe(a)
        a['scene_windows'][0]['tags'][0]['score'] = .2
        with self.assertRaises(Conflict):self.audio.import_probe(a)
        a['models'][0]['sha256'] = 'b'*64
        self.audio.import_probe(a)
        self.assertEqual(len(self.audio.signature()), 2)

    def test_hash_and_canonical_duration_not_filename_determine_match(self):
        a = self.artifact()
        a['source_sha256'] = 'b'*64
        with self.assertRaises(Conflict):self.audio.import_probe(a)
        a = self.artifact();a['selection']['duration'] = 21
        with self.assertRaises(ValueError):self.audio.import_probe(a)
        a = self.artifact();a['source_format'] = 'decoded_media'
        with self.assertRaises(ValueError):self.audio.import_probe(a)

    def test_invalid_time_score_and_identity_are_rejected(self):
        changes = [lambda a:a['scene_windows'][0].update(end_seconds=21),
            lambda a:a['scene_windows'][0]['tags'][0].update(score=float('nan')),
            lambda a:a['scene_windows'][0]['tags'][0].update(score=1.1),
            lambda a:a['scene_windows'][0].update(user_identity='user'),
            lambda a:a['scene_windows'][0].update(source_medium='live'),
            lambda a:a.update(enrollment_present=True)]
        for mutate in changes:
            with self.subTest(mutate=mutate):
                a = self.artifact();mutate(a)
                with self.assertRaises(ValueError):self.audio.import_probe(a)
        self.assertEqual(self.audio.signature(), [])

    def test_revocation_blocks_import_and_model_context(self):
        self.audio.import_probe(self.artifact())
        self.agent.policy(self.sid, asr=False, agent=False, source_kind='unknown')
        self.assertEqual(self.audio.for_document(self.doc), [])
        with self.assertRaises(Conflict):self.audio.import_probe(self.artifact())

    def test_annotation_uses_batch_clock_and_focus_context_not_claim_alignment(self):
        self.audio.import_probe(self.artifact())
        hints = self.audio.for_document(self.doc)
        self.assertEqual(hints[0]['stream_start_byte'], 120000)
        self.assertEqual(hints[0]['scene_windows'][0]['start_seconds'], 0)
        self.assertTrue(hints[0]['focus_includes_boundary_context'])
        bad = copy.deepcopy(self.doc);bad['evidence'][0]['batch_id'] = str(uuid.uuid4())
        self.assertEqual(self.audio.for_document(bad), [])

    def test_personal_and_activity_receive_hints_without_retranscription(self):
        before = self.processor.personal.fingerprint(), self.processor.activities.signature()
        self.audio.import_probe(self.artifact())
        self.assertNotEqual(before, (self.processor.personal.fingerprint(), self.processor.activities.signature()))
        personal = self.processor.personal.context()
        record = next(r for r in personal['records'] if r['id']==self.doc['id'])
        self.assertEqual(record['acoustic_hints'][0]['source_medium'], 'unknown')
        self.assertTrue(self.processor.activities.context()['events'][0]['acoustic_hints'])
        class Capture:
            def extract(inner, doc, memory):
                self.assertTrue(doc['acoustic_hints'])
                return {'title':'界面讨论','summary':doc['text'],'claims':[]}
        self.processor.model = Capture()
        self.processor._extract({'document':self.doc, 'memory':[]})
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM jobs WHERE kind='asr_audio'").fetchone()[0], 0)

    def test_sampling_retains_first_last_and_discloses_total(self):
        a = self.artifact()
        a['scene_windows'] = [dict(start_seconds=i, end_seconds=i+1, tags=[]) for i in range(20)]
        self.audio.import_probe(a)
        hint = self.audio.for_document(self.doc)[0]
        self.assertEqual(hint['scene_window_count'], 20)
        self.assertEqual(len(hint['scene_windows']), 6)
        self.assertEqual((hint['scene_windows'][0]['start_seconds'],hint['scene_windows'][-1]['end_seconds']), (0,20))


if __name__=='__main__':unittest.main()

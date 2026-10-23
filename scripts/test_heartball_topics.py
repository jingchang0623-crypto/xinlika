"""Retrospective association integrity and recovery; deterministic fixtures, no ASR/model network."""
import tempfile
from pathlib import Path
import unittest
import uuid

from heartball_store import Store, Conflict
from heartball_processing import Processor


class Topics(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name))
        self.processor = Processor(self.store)
        self.agent = self.processor.agent

    def tearDown(self):
        self.processor.close(); self.store.db.close(); self.temp.cleanup()

    def event(self, text, sid=None, source='live_conversation'):
        if sid is None:
            sid = str(uuid.uuid4()); self.store.create_session(sid); self.store.update_session(sid, status='completed')
            self.agent.policy(sid, asr=False, agent=True, source_kind=source)
        doc = dict(id=str(uuid.uuid4()), input_key=str(uuid.uuid4()), session_id=sid, kind='ambient', text=text,
                   evidence=[], source_kind=source, occurred_at=None, boundary_quality='batch_exact', revision=1)
        self.agent.commit_document(doc, dict(title='记录', summary=text, claims=[]))
        context = self.agent.workspace.context(doc)
        self.agent.workspace.persist(doc, {'events': [dict(title='事件', summary=text, quote=text)]}, context)
        event = next(e for e in self.agent.state()['events'] if e['sources'][0]['document_id'] == doc['id'])
        return event

    def value(self, *events):
        return {'topics': [{'topic_id': None, 'title': '镜头标定', 'summary': '到货后继续调整镜头标定。',
                            'events': [{'id': e['id'], 'version': e['version']} for e in events]}]}

    def test_persistent_association_is_atomic_idempotent_and_preserves_original_documents(self):
        a = self.event('镜头到货待标定'); b = self.event('镜头标定改用新参数')
        context = self.processor.topics.context(b['session_id']); value = self.value(a, b)
        self.processor.topics.persist('run', value, context); self.processor.topics.persist('run', value, context)
        state = self.agent.state()
        self.assertEqual(len(state['topics']), 1); self.assertEqual(state['topics'][0]['conversation_count'], 2)
        self.assertEqual({d['text'] for d in state['documents']}, {'镜头到货待标定', '镜头标定改用新参数'})
        self.assertEqual(state['confirmedMemoryCount'], 0)

    def test_unknown_or_stale_reference_cannot_partially_link_valid_events(self):
        a = self.event('镜头到货'); b = self.event('镜头继续标定')
        context = self.processor.topics.context(b['session_id']); bad = self.value(a, b)
        bad['topics'][0]['events'][1]['id'] = str(uuid.uuid4())
        with self.assertRaises(Conflict): self.processor.topics.persist('bad', bad, context)
        self.assertEqual(self.agent.state()['topics'], [])
        self.store.db.execute('UPDATE workspace_events SET version=version+1 WHERE id=?', (a['id'],)); self.store.db.commit()
        with self.assertRaises(Conflict): self.processor.topics.persist('stale', self.value(a, b), context)
        self.assertEqual(self.agent.state()['topics'], [])

    def test_one_conversation_or_unrelated_trigger_cannot_fabricate_cross_conversation_result(self):
        a = self.event('镜头到货'); b = self.event('镜头继续标定', sid=a['session_id'])
        with self.assertRaises(ValueError):
            self.processor.topics.persist('single', self.value(a, b), self.processor.topics.context(a['session_id']))
        c = self.event('另一项讨论')
        with self.assertRaises(ValueError):
            self.processor.topics.persist('unrelated', self.value(a, c), {'session_id': str(uuid.uuid4()), **{k:v for k,v in self.processor.topics.context(c['session_id']).items() if k!='session_id'}})
        self.assertEqual(self.agent.state()['topics'], [])

    def test_background_sources_and_revoked_permissions_are_excluded(self):
        a = self.event('现场镜头反馈'); b = self.event('播放的视频', source='background_playback')
        context = self.processor.topics.context(a['session_id'])
        self.assertNotIn(b['id'], {e['id'] for e in context['events']})
        self.assertFalse(self.processor.topics.request(b['session_id']))
        c = self.event('另一现场反馈'); context = self.processor.topics.context(c['session_id'])
        self.agent.policy(a['session_id'], asr=False, agent=False, source_kind='live_conversation')
        with self.assertRaises(Conflict): self.processor.topics.persist('revoked', self.value(a,c), context)

    def test_model_result_survives_save_failure_without_repeating_inference(self):
        a = self.event('镜头到货'); b = self.event('镜头标定')
        value = self.value(a,b)
        class Model:
            calls = 0
            def reconcile_topics(self, context): self.calls += 1; return value
        self.processor.model = Model()
        payload = {'session_id': b['session_id'], 'run_key': 'recover'}
        job = {'id': str(uuid.uuid4()), 'attempts': 1}
        save = self.processor.topics.persist
        self.processor.topics.persist = lambda *args: (_ for _ in ()).throw(OSError('fixture disk unavailable'))
        with self.assertRaises(OSError): self.processor.run_topics(payload, job)
        self.processor.topics.persist = save; self.processor.run_topics(payload, job)
        self.assertEqual(self.processor.model.calls,1)
        self.assertEqual(len(self.agent.state()['topics']),1)

    def test_automatic_request_waits_for_the_complete_recording_and_is_idempotent(self):
        a = self.event('真实事项的占位测试')
        self.store.update_session(a['session_id'],status='recording')
        self.assertFalse(self.processor.topics.request(a['session_id']))
        self.store.update_session(a['session_id'],status='completed')
        self.assertTrue(self.processor.topics.request(a['session_id']))
        self.assertTrue(self.processor.topics.request(a['session_id']))
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM jobs WHERE kind='topic_reconcile'").fetchone()[0],1)


if __name__ == '__main__': unittest.main()

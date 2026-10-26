"""Agent control-flow tests; synthetic examples do not measure real speech quality."""
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import uuid

from heartball_processing import Processor
from heartball_store import Store


class Model:
    def __init__(self):
        self.calls=[]; self.intervene=True; self.approve=True; self.fail_review=False
        self.hook=None; self.bad_ref=False
    def personal_observe(self, context):
        self.calls.append('observe')
        ref={'id':context['records'][0]['id'],'version':context['records'][0]['version']}
        return {'should_intervene':self.intervene,'reason':'具体变化','working_note':'观察下一次进展','refs':[ref]}
    def personal_respond(self, context, observation):
        self.calls.append('respond')
        refs=observation['refs'] if not self.bad_ref else [{'id':str(uuid.uuid4()),'version':1}]
        return {'kind':'follow_up','title':'讨论中的交付前提','body':'讨论提到交付前要先核对接口，下一步可对齐接口状态。','refs':refs}
    def personal_review(self, context, observation, response):
        self.calls.append('review')
        if self.fail_review:
            self.fail_review=False
            raise RuntimeError('temporary provider failure')
        if self.hook:self.hook()
        return {'approved':self.approve,'reason':'具体依据复核'}


class PersonalTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(Path(self.temp.name))
        self.model=Model();self.processor=Processor(self.store,self.model)
        self.agent=self.processor.agent;self.personal=self.processor.personal
    def tearDown(self):
        self.processor.close();self.store.db.close();self.temp.cleanup()
    def doc(self, source='live_conversation'):
        sid=str(uuid.uuid4());self.store.create_session(sid)
        self.agent.policy(sid,asr=False,agent=True,source_kind=source,occurred_at='2026-10-21T09:00:00+08:00')
        doc={'id':str(uuid.uuid4()),'session_id':sid,'kind':'text','input_key':str(uuid.uuid4()),
            'text':'讨论交付前先核对接口状态。','source_kind':source,'evidence':[],
            'occurred_at':'2026-10-21T09:00:00+08:00','boundary_quality':'user_text'}
        self.agent.commit_document(doc,{'title':'接口交付讨论','summary':doc['text'],'claims':[],'validation_notes':[]})
        self.store.update_session(sid,status='completed')
        return doc
    def schedule(self):
        self.store.db.execute('UPDATE personal_agent_monitor SET last_scan=0');self.store.db.commit()
        self.assertTrue(self.personal.schedule())
        return self.store.db.execute('SELECT run_key FROM personal_agent_runs ORDER BY rowid DESC LIMIT 1').fetchone()[0]
    def result(self,key):return dict(self.store.db.execute('SELECT * FROM personal_agent_runs WHERE run_key=?',(key,)).fetchone())
    def run_personal(self,key):
        self.personal.run(key)
        if self.result(key)['finished_at']:
            self.store.db.execute("UPDATE jobs SET status='completed' WHERE kind='personal_analysis' AND input_key=?",(key,));self.store.db.commit()
    def test_quiet_gate_skips_generation_and_preserves_tentative_notes(self):
        self.doc();self.model.intervene=False;key=self.schedule();self.run_personal(key)
        self.assertEqual(self.model.calls,['observe']);self.assertEqual(self.result(key)['status'],'quiet')
        self.assertEqual(len(self.personal.context()['working_notes']),1)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM claims').fetchone()[0],0)
    def test_three_stages_publish_once_and_survive_processor_restart(self):
        self.doc();key=self.schedule();self.run_personal(key);self.run_personal(key)
        self.assertEqual(self.model.calls,['observe','respond','review'])
        self.assertEqual(self.result(key)['status'],'delivered')
        self.assertEqual(self.agent.state()['advice'][0]['kind'],'personal_follow_up')
        self.processor.close();self.processor=Processor(self.store,self.model)
        self.processor.personal.run(key)
        self.assertEqual(len(self.model.calls),3)
        self.assertFalse(self.processor.personal.schedule(clock=time.time()+10000))
    def test_review_failure_resumes_without_repeating_observation_or_draft(self):
        self.doc();key=self.schedule();self.model.fail_review=True
        with self.assertRaises(RuntimeError):self.run_personal(key)
        self.run_personal(key)
        self.assertEqual(self.model.calls,['observe','respond','review','review'])
        self.assertEqual(self.result(key)['status'],'delivered')
    def test_review_can_suppress_and_new_context_coalesces_until_scan_interval(self):
        self.doc();key=self.schedule();self.model.approve=False;self.run_personal(key)
        self.assertEqual(self.result(key)['status'],'rejected')
        self.doc();self.doc();self.assertFalse(self.personal.schedule())
        self.store.db.execute('UPDATE personal_agent_monitor SET last_scan=0');self.store.db.commit()
        self.assertTrue(self.personal.schedule());self.assertFalse(self.personal.schedule())
    def test_invalid_reference_cannot_publish(self):
        self.doc();key=self.schedule();self.model.bad_ref=True
        with self.assertRaises(ValueError):self.personal.run(key)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM advice').fetchone()[0],0)
    def test_background_and_revoked_sources_do_not_call_model(self):
        self.doc('background_playback');self.store.db.execute('UPDATE personal_agent_monitor SET last_scan=0');self.store.db.commit()
        self.assertFalse(self.personal.schedule());self.assertEqual(self.model.calls,[])
        doc=self.doc();key=self.schedule()
        self.agent.policy(doc['session_id'],asr=False,agent=False,source_kind='live_conversation')
        self.personal.run(key)
        self.assertEqual(self.result(key)['status'],'stale');self.assertEqual(self.model.calls,[])
    def test_user_correction_during_review_prevents_delivery(self):
        doc=self.doc();key=self.schedule()
        self.model.hook=lambda:self.agent.feedback({'id':str(uuid.uuid4()),'target_id':doc['id'],
            'expected_version':1,'action':'correct_document','values':{'text':'接口已完成，交付条件已满足。'}})
        self.personal.run(key)
        self.assertEqual(self.result(key)['status'],'stale')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM advice').fetchone()[0],0)
    def test_delivery_cooldown_and_dismissal_are_enforced(self):
        self.doc();key=self.schedule();self.run_personal(key)
        aid=self.result(key)['advice_id']
        self.agent.feedback({'id':str(uuid.uuid4()),'target_id':aid,'action':'mute_kind'})
        self.doc();key=self.schedule();self.run_personal(key)
        self.assertEqual(self.result(key)['status'],'muted')
        self.assertEqual(self.agent.state()['advice'][0]['status'],'dismissed')
    def test_incoming_next_minute_does_not_starve_inflight_analysis(self):
        self.doc();key=self.schedule();self.model.hook=lambda:self.doc()
        self.personal.run(key)
        self.assertEqual(self.result(key)['status'],'delivered')
    def test_worker_claims_personal_job_without_interpreting_it_as_audio(self):
        self.doc();key=self.schedule()
        self.assertTrue(self.processor.tick())
        self.assertEqual(self.result(key)['status'],'delivered')
        self.assertEqual(self.store.db.execute("SELECT status FROM jobs WHERE kind='personal_analysis'").fetchone()[0],'completed')

    def test_unknown_source_can_be_understood_without_becoming_user_fact(self):
        self.doc('unknown');key=self.schedule();self.run_personal(key)
        self.assertEqual(self.result(key)['status'],'delivered')
        self.assertTrue(self.agent.state()['advice'][0]['body'].startswith('录音中的讨论：'))
        self.assertEqual(self.agent.state()['confirmedMemoryCount'],0)

    def test_unknown_source_personal_attribution_is_blocked_even_if_critic_passes(self):
        self.doc('unknown');key=self.schedule()
        original=self.model.personal_respond
        self.model.personal_respond=lambda context,observation:{**original(context,observation),'body':'你承诺先完成接口。'}
        self.run_personal(key)
        self.assertEqual(self.result(key)['status'],'rejected_attribution')

    def test_delivered_advice_is_invalidated_by_document_correction(self):
        doc=self.doc();key=self.schedule();self.run_personal(key)
        self.agent.feedback({'id':str(uuid.uuid4()),'target_id':doc['id'],'expected_version':1,
            'action':'correct_document','values':{'text':'讨论中的交付已经完成。'}})
        self.assertEqual(self.agent.state()['advice'][0]['status'],'invalidated')
        self.assertEqual(self.personal.context()['working_notes'],[])

    def test_cooldown_limits_new_topics_without_dropping_the_records(self):
        self.doc();key=self.schedule();self.run_personal(key)
        self.doc();key=self.schedule();self.run_personal(key)
        self.assertEqual(self.result(key)['status'],'limited')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM documents').fetchone()[0],2)

    def test_revocation_during_review_cannot_publish(self):
        doc=self.doc();key=self.schedule()
        self.model.hook=lambda:self.agent.policy(doc['session_id'],asr=False,agent=False,source_kind='live_conversation')
        self.run_personal(key);self.assertEqual(self.result(key)['status'],'stale')

    def test_slow_context_analysis_does_not_block_the_asr_lane(self):
        from test_heartball_processing import FakeASR
        sid=str(uuid.uuid4());self.store.create_session(sid)
        self.agent.policy(sid,asr=True,agent=False,source_kind='test_unverified')
        folder=Path(self.store.session(sid)['directory'])/'probe';folder.mkdir(exist_ok=True)
        path=folder/'audio-test.bin';path.write_bytes(b'a'*120000)
        self.store.ingest(sid,{'audioFile':path.name,'audioOffset':0,'audioBytes':120000,'time':'synthetic'})
        self.store.update_session(sid,status='completed')
        self.doc();self.schedule();entered=threading.Event();release=threading.Event()
        original=self.model.personal_observe
        def slow(context):
            entered.set()
            if not release.wait(5):raise RuntimeError('test synchronization timeout')
            return original(context)
        self.model.personal_observe=slow;self.processor.asr=FakeASR()
        worker=threading.Thread(target=lambda:self.processor.tick(context_only=True));worker.start()
        try:
            self.assertTrue(entered.wait(3));self.assertTrue(self.processor.tick(context_only=False))
            self.assertEqual(self.processor.asr.calls,1)
        finally:release.set();worker.join(timeout=5)
        self.assertFalse(worker.is_alive())


if __name__=='__main__':unittest.main()

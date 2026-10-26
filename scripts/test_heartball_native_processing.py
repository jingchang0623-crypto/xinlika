"""Queue/receipt tests; fixtures do not measure conversation quality."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

from heartball_agent_runtime import AgentReceipt
from heartball_native_processing import NativeProcessor,NativeRuntimeService
from heartball_runtime_adapters import NativeProcessAdapter
from heartball_agent_store import AgentStore
from heartball_store import Store
from test_heartball_processing import FakeASR


class CommittingAdapter:
    def __init__(self,domain):self.domain=domain;self.calls=[]
    def run(self,task):
        self.calls.append(task)
        receipt=self.domain.receipt(task.id)
        if not receipt:
            if task.mode=='answer':
                d=self.domain.read_sources(task,[task.document_ids[0]])['sources'][0]
                receipt=self.domain.commit_answer(task,'记录中讨论了该事项。',[{'id':d['id'],'version':d['revision'],'quote':d['text']}])
            else:
                docs=self.domain.read_sources(task,task.document_ids)['sources']
                receipt=self.domain.commit(task,{'issues':[{'key':'one','title':'同一事项讨论','summary':'保留原文讨论。',
                    'admission_reason':'有明确对象的讨论。','sources':[{'document_id':d['id'],'revision':d['revision'],'span_ids':list(range(len(__import__('heartball_source_spans').source_spans(d['text']))))} for d in docs]}]})
        return AgentReceipt(runtime='fixture',task_id=task.id,status='completed',receipt=receipt)
    def close(self):pass


class NativeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.store=Store(self.root);self.agent=AgentStore(self.store)
        # NativeRuntimeService's adapter may be injected without network/config.
        self.service=NativeRuntimeService(self.agent,{'coalesce_seconds':0},adapter=object())
        self.fake=CommittingAdapter(self.service.domain);self.service.adapter=self.fake

    def tearDown(self):self.store.db.close();self.temp.cleanup()

    def document(self,text='镜头维修正在讨论。',kind='ambient'):
        sid=str(uuid.uuid4());self.store.create_session(sid);self.store.update_session(sid,status='completed')
        self.agent.policy(sid,asr=False,agent=True,source_kind='live_conversation',occurred_at='2026-10-21T12:00:00+08:00')
        did=str(uuid.uuid4());self.agent.commit_document(dict(id=did,input_key=did,session_id=sid,kind=kind,text=text,evidence=[],
            source_kind='live_conversation',occurred_at='2026-10-21T12:00:00+08:00',boundary_quality='source_interval'),dict(title='',summary='',claims=[]))
        return did

    def test_restart_does_not_reprocess_completed_sources(self):
        self.document();self.assertTrue(self.service.tick());self.assertEqual(len(self.fake.calls),1)
        service=NativeRuntimeService(self.agent,{'coalesce_seconds':0},adapter=self.fake)
        self.assertFalse(service.tick());self.assertEqual(len(self.fake.calls),1)

    def test_relation_revalidation_is_scheduled_once_without_reextracting_sources(self):
        first=self.document('镜头维修正在讨论。');second=self.document('镜头维修后续继续讨论。')
        self.service.tick();self.service.tick()
        events={r['session_id']:r['id'] for r in self.store.db.execute("SELECT * FROM workspace_events WHERE status='active'")}
        self.service.domain.commit(self.service.domain.task([first,second],'建立有原文的关系','fixture'),
            {'issues':[],'topics':[{'key':'topic','title':'维修延续','summary':'两次讨论维修。','event_keys':list(events.values())}],'omitted_document_ids':[first,second]})
        with self.store.transaction():self.agent.workspace.invalidate_document(first)
        self.service.tick();self.service.tick()
        previous=len(self.fake.calls)
        domain=self.service.domain
        class RelationAdapter:
            calls=0
            def run(inner,task):
                inner.calls+=1
                self.assertTrue(task.topic_repair_only)
                receipt=domain.commit(task,{'issues':[],'omitted_document_ids':task.document_ids})
                return AgentReceipt(runtime='fixture',task_id=task.id,status='completed',receipt=receipt)
        adapter=RelationAdapter();self.service.adapter=adapter
        self.assertTrue(self.service.tick());self.assertFalse(self.service.tick())
        self.assertEqual(adapter.calls,1);self.assertEqual(len(self.fake.calls),previous)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM native_topic_repairs').fetchone()[0],1)
        restarted=NativeRuntimeService(self.agent,{'coalesce_seconds':0},adapter=adapter)
        self.assertFalse(restarted.tick());self.assertEqual(adapter.calls,1)

    def test_commit_survives_lost_job_ack_without_inference(self):
        self.document();self.service.tick();job=self.store.db.execute("SELECT * FROM jobs WHERE kind='native_agent_analysis'").fetchone()
        task=self.fake.calls[0]
        self.store.db.execute("DELETE FROM native_source_receipts WHERE task_id=?",(task.id,))
        self.store.db.execute("UPDATE jobs SET status='retryable',available_at=0 WHERE id=?",(job['id'],));self.store.db.commit()
        # Invalid interpreter/config: the durable receipt must bypass all startup.
        self.service.adapter=NativeProcessAdapter('deepseek-harness',python='/missing/python',client_python=sys.executable,
            root=self.root,configuration={})
        self.assertTrue(self.service.tick())
        self.assertEqual(self.store.db.execute('SELECT status FROM jobs WHERE id=?',(job['id'],)).fetchone()[0],'completed')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM agent_runtime_receipts').fetchone()[0],1)
        self.assertFalse((self.root/'runtime-runs').exists())

    def test_query_uses_transcripts_without_confirmed_personal_memories(self):
        self.document();qid=str(uuid.uuid4());self.agent.ask(qid,'镜头维修')
        self.assertTrue(self.service.tick());self.assertEqual(self.fake.calls[-1].mode,'answer')
        answer=self.store.db.execute('SELECT refs,status FROM memory_answers WHERE id=?',(qid,)).fetchone()
        self.assertEqual(answer['status'],'ready');self.assertTrue(json.loads(answer['refs']))

    def test_identical_question_from_two_clients_has_two_answer_receipts(self):
        self.document()
        for _ in range(2):
            qid=str(uuid.uuid4());self.agent.ask(qid,'镜头维修');self.service.tick()
            self.assertEqual(self.store.db.execute('SELECT status FROM memory_answers WHERE id=?',(qid,)).fetchone()[0],'ready')
        self.assertNotEqual(self.fake.calls[0].id,self.fake.calls[1].id)

    def test_failed_native_document_does_not_starve_later_sources(self):
        self.document();self.service.schedule()
        self.store.db.execute("UPDATE jobs SET status='failed' WHERE kind='native_agent_analysis'");self.store.db.commit()
        later=self.document('后续另一个安排。')
        self.assertTrue(self.service.tick());self.assertEqual(self.fake.calls[-1].document_ids,[later])

    def test_provider_outage_keeps_durable_task_retryable_after_backoff(self):
        self.document();self.service.schedule()
        self.store.db.execute("UPDATE jobs SET attempts=1,status='running',lease_owner='fixture' WHERE kind='native_agent_analysis'");self.store.db.commit()
        job=dict(self.store.db.execute("SELECT * FROM jobs WHERE kind='native_agent_analysis'").fetchone())
        self.service.fail(job,AgentReceipt(runtime='fixture',task_id='fixture',status='failed',error='provider_transport_unavailable',
            usage={'guardrail_reason':'provider_transport_unavailable','requests':[{'status':'transport_error'}]}))
        row=self.store.db.execute('SELECT status,available_at FROM jobs WHERE id=?',(job['id'],)).fetchone()
        self.assertEqual(row['status'],'retryable');self.assertGreater(row['available_at'],__import__('time').time())

    def test_source_reauthorization_unblocks_the_original_job(self):
        did=self.document();self.service.schedule()
        sid=self.store.db.execute('SELECT session_id FROM documents WHERE id=?',(did,)).fetchone()[0]
        self.agent.policy(sid,asr=False,agent=False,source_kind='live_conversation');self.assertFalse(self.service.tick())
        self.agent.policy(sid,asr=False,agent=True,source_kind='live_conversation');self.assertTrue(self.service.tick())
        self.assertEqual(len(self.fake.calls),1)

    def test_midnight_does_not_make_an_invalid_multi_day_projection(self):
        first=self.document();second=self.document('次日继续讨论。')
        sid=self.store.db.execute('SELECT session_id FROM documents WHERE id=?',(first,)).fetchone()[0]
        self.store.db.execute("UPDATE documents SET occurred_at='2026-10-21T15:59:59+00:00' WHERE id=?",(first,))
        self.store.db.execute("UPDATE documents SET session_id=?,occurred_at='2026-10-21T16:00:01+00:00' WHERE id=?",(sid,second));self.store.db.commit()
        self.service.tick();self.service.tick();self.assertEqual([t.document_ids for t in self.fake.calls],[[first],[second]])

    def test_storage_only_import_can_be_enabled_after_native_upgrade(self):
        from heartball_external_import import ExternalImporter
        store=Store(self.root/'upgrade');agent=AgentStore(store);importer=ExternalImporter(agent)
        parsed={'messages':[{'conversation_id':'chat','external_id':'one','sender_id':'p','occurred_at':'2026-10-20T09:00:00+08:00','text':'讨论镜头维修。','is_self_reported':False}],'file_sha256':'a'*64}
        try:
            first=importer.ingest(parsed,account_id='local',analyze=False)
            service=NativeRuntimeService(agent,{'coalesce_seconds':0},adapter=object());service.adapter=CommittingAdapter(service.domain)
            self.assertFalse(service.tick())
            result=importer.ingest(parsed,account_id='local',analyze=True);self.assertTrue(result['analysis_enabled'])
            self.assertTrue(service.tick());self.assertEqual(service.adapter.calls[0].document_ids,first['documents'])
        finally:store.db.close()

    def test_new_focus_is_independent_of_ambient_processing(self):
        ambient=self.document();focus=self.document('圈出的重要片段。',kind='focus')
        self.service.tick();self.service.tick()
        self.assertEqual(self.fake.calls[0].document_ids,[focus]);self.assertEqual(self.fake.calls[1].document_ids,[ambient])

    def test_native_processor_reuses_asr_and_ingest_without_per_batch_model(self):
        processor=NativeProcessor(self.store,{'runtime':'fixture','coalesce_seconds':0},asr=FakeASR(),adapter=self.fake)
        processor.native.adapter=CommittingAdapter(processor.native.domain)
        try:
            sid=str(uuid.uuid4());self.store.create_session(sid);self.store.update_session(sid,status='recording')
            processor.agent.policy(sid,asr=True,agent=True,source_kind='live_conversation',occurred_at='2026-10-21T12:00:00+08:00')
            folder=Path(self.store.session(sid)['directory'])/'probe';folder.mkdir(exist_ok=True)
            audio=folder/'audio-fixture-AE22.bin';audio.write_bytes(b'a'*120000)
            self.store.ingest(sid,{'audioFile':audio.name,'audioOffset':0,'audioBytes':120000,'time':'fixture'})
            for _ in range(8):
                processor.tick(lane='asr');processor.tick(context_only=False,lane='document');processor.tick(context_only=True)
            self.assertEqual(processor.asr.calls,1);self.assertEqual(len(processor.native.adapter.calls),1)
            self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],1)
        finally:processor.close()

    def test_opt_in_runtime_preserves_existing_quiet_proactive_review_lane(self):
        class Feedback:
            calls=0
            def personal_observe(self,context):
                self.calls+=1
                return {'should_intervene':False,'reason':'没有新建议需要打扰','refs':[]}
        feedback=Feedback();processor=NativeProcessor(self.store,{'runtime':'fixture','coalesce_seconds':0},adapter=self.fake,feedback_model=feedback)
        processor.native.adapter=CommittingAdapter(processor.native.domain);processor.personal.scan_interval=0
        try:
            self.document();processor.tick(context_only=True);processor.tick(context_only=True)
            self.assertEqual(feedback.calls,1)
            self.assertEqual(self.store.db.execute('SELECT count(*) FROM advice').fetchone()[0],0)
            self.assertEqual(self.store.db.execute('SELECT status FROM personal_agent_runs ORDER BY rowid DESC LIMIT 1').fetchone()[0],'quiet')
        finally:processor.close()


if __name__=='__main__':unittest.main()

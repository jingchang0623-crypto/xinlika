"""Operational handoff invariants; no model/ASR/network calls."""
import json
from pathlib import Path
import tempfile
import unittest
import uuid

from heartball_store import Store
from heartball_agent_store import AgentStore
from heartball_native_processing import NativeRuntimeService
from heartball_shared_handoff import ForwardOnlyBoundary,ProcessingLease


class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.store=Store(self.root);self.agent=AgentStore(self.store)
        self.native=NativeRuntimeService(self.agent,{'coalesce_seconds':0},adapter=object())
        self.sid=str(uuid.uuid4());self.store.create_session(self.sid)
        self.agent.policy(self.sid,asr=True,agent=True,source_kind='live_conversation',occurred_at='2026-10-24T10:00:00+08:00')

    def tearDown(self):
        self.store.db.close();self.temp.cleanup()

    def batch(self,key):
        with self.store.transaction():
            self.store.db.execute("INSERT INTO batches VALUES(?,?,?,?,0,120000,?,'batch.opus','minute')",(key,self.sid,self.store.db.execute('SELECT count(*) FROM batches').fetchone()[0],key,key))

    def document(self,key):
        did=str(uuid.uuid4())
        self.agent.commit_document({'id':did,'input_key':'ambient_analysis:'+key,'session_id':self.sid,'kind':'ambient','text':'这是一条有明确对象的真实来源位置占位。','evidence':[], 'source_kind':'live_conversation','occurred_at':'2026-10-24T10:00:00+08:00','boundary_quality':'batch_exact'}, {'title':'','summary':'','claims':[]})
        return did

    def test_late_old_asr_excluded_but_new_batches_processed_after_restart(self):
        self.batch('old-pending');old=self.document('old-existing')
        boundary=ForwardOnlyBoundary(self.agent,'v6')
        self.batch('new-batch');late=self.document('old-pending');new=self.document('new-batch')
        ForwardOnlyBoundary(self.agent,'v6').exclude_late_baseline()
        receipts={r[0] for r in self.store.db.execute('SELECT document_id FROM native_source_receipts')}
        self.assertEqual(receipts,{old,late});self.assertNotIn(new,receipts)
        self.assertTrue(self.native.schedule())
        payload=json.loads(self.store.db.execute("SELECT payload FROM jobs WHERE kind='native_agent_analysis'").fetchone()[0])
        self.assertEqual(payload['document_ids'],[new])

    def test_boundary_does_not_reset_asr_or_reexclude_corrected_generation(self):
        self.batch('old');boundary=ForwardOnlyBoundary(self.agent,'v6');late=self.document('old')
        with self.store.transaction():
            self.store.db.execute("INSERT INTO jobs(id,kind,input_key,status,payload) VALUES('paid','asr_audio','hash','completed','{}')")
            self.store.db.execute('INSERT OR REPLACE INTO workspace_generations(document_id,generation) VALUES(?,1)',(late,))
        boundary.exclude_late_baseline()
        self.assertIsNone(self.store.db.execute('SELECT 1 FROM native_source_receipts WHERE document_id=?',(late,)).fetchone())
        self.assertEqual(self.store.db.execute("SELECT status FROM jobs WHERE id='paid'").fetchone()[0],'completed')

    def test_processing_lease_waits_for_old_worker_and_is_exclusive(self):
        old=ProcessingLease(self.root);new=ProcessingLease(self.root);third=ProcessingLease(self.root)
        try:
            self.assertTrue(old.acquire());self.assertFalse(new.acquire())
            old.close();self.assertTrue(new.acquire());self.assertFalse(third.acquire())
        finally:new.close();third.close()


if __name__=='__main__':unittest.main()

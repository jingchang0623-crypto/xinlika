"""Retrieval regressions, not a claim about model/ASR accuracy."""
from pathlib import Path
import tempfile
import unittest
import uuid
from heartball_store import Store
from heartball_agent_store import AgentStore

class RecallTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(Path(self.temp.name));self.agent=AgentStore(self.store)
        self.sid=str(uuid.uuid4());self.store.create_session(self.sid);self.agent.policy(self.sid,asr=True,agent=True,source_kind='live_conversation')
    def tearDown(self):self.store.db.close();self.temp.cleanup()
    def doc(self,text):
        did=str(uuid.uuid4());doc={'id':did,'session_id':self.sid,'input_key':did,'kind':'ambient','text':text,'source_kind':'live_conversation','evidence':[],'boundary_quality':'batch_exact'}
        self.agent.commit_document(doc,{'title':text[:80],'summary':text,'claims':[]});return did
    def test_recall_old_chinese_record_after_two_hundred_unrelated_new_records(self):
        target=self.doc('海盐项目使用墨绿色包装，联系人是顾青。')
        for i in range(220):self.doc('晚间流水事项编号'+str(i))
        result=self.agent.query_context(question='海盐包装是什么颜色？')
        self.assertIn(target,[x['id'] for x in result]);self.assertEqual(result[0]['id'],target)
        self.assertLessEqual(sum(len(str(x)) for x in result),38000)
    def test_correction_updates_index_and_invalidated_record_cannot_reappear(self):
        target=self.doc('海盐包装墨绿色')
        with self.store.transaction():self.store.db.execute("UPDATE documents SET text='海盐包装银灰色',summary='海盐包装银灰色',title='银灰色',revision=revision+1 WHERE id=?",(target,))
        self.assertTrue(any(x['record_id']==target for x in self.agent.recall.search('银灰色')))
        self.assertFalse(any(x['record_id']==target for x in self.agent.recall.search('墨绿色')))
        with self.store.transaction():self.store.db.execute("UPDATE documents SET status='superseded' WHERE id=?",(target,))
        self.assertFalse(any(x['id']==target for x in self.agent.query_context(question='银灰色')))
    def test_two_character_name_and_fts_syntax_are_data(self):
        target=self.doc('顾青负责海盐事项')
        self.assertIn(target,[x['record_id'] for x in self.agent.recall.search('顾青')])
        self.agent.recall.search('顾青" OR * - DROP TABLE claims')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM documents').fetchone()[0],1)
    def test_index_rebuild_from_existing_ledger_preserves_records(self):
        target=self.doc('蓝色风车设备改进')
        self.store.db.execute("DELETE FROM memory_search");self.store.db.commit()
        from heartball_recall import RecallIndex
        index=RecallIndex(self.store.db)
        self.assertIn(target,[x['record_id'] for x in index.search('风车')])

if __name__=='__main__':unittest.main()

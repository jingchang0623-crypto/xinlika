"""Transactional relation boundaries; fixtures do not count as quality evidence."""
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from unittest.mock import patch

from heartball_store import Store,Conflict
from heartball_agent_store import AgentStore
from heartball_agent_runtime import AgentDomain
from heartball_incremental_topics import CrossConversationReview
from heartball_skill_bundle import PROJECT


class RelationReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(Path(self.temp.name));self.agent=AgentStore(self.store);self.domain=AgentDomain(self.agent)
        self.cfg={'skill_bundle':str(PROJECT/'prompts/versions/xinlika-events-v4/bundle.json')}
        self.docs=[]
        for clock,text in [('10:00','讨论纸舟项目的目录功能，准备下周上线。'),('11:00','继续讨论纸舟项目，目录按钮现在没有反应。')]:
            sid=str(uuid.uuid4());self.store.create_session(sid);self.store.update_session(sid,status='completed');self.agent.policy(sid,asr=False,agent=True,source_kind='live_conversation')
            did=str(uuid.uuid4());self.docs.append(did)
            self.agent.commit_document({'id':did,'input_key':did,'session_id':sid,'kind':'ambient','text':text,'revision':1,'evidence':[],'source_kind':'live_conversation','occurred_at':'2026-10-24T'+clock+':00+08:00','boundary_quality':'source_interval'},{'title':'','summary':'','claims':[]})
            task=self.domain.task([did],'organize','fixture')
            self.domain.commit(task,{'issues':[{'key':'i1','title':'纸舟目录功能讨论','summary':text,'sources':[{'document_id':did,'revision':1,'quote':text}]}]})
        self.review=CrossConversationReview(self.agent,self.cfg,prime_existing=False)
    def tearDown(self):self.store.db.close();self.temp.cleanup()
    def proposal(self,c):
        es=c['model']['events']
        return {'links':[{'title':'纸舟目录功能','summary':'同一目录功能的计划与后续反馈。','events':[e['handle'] for e in es],'existing_topic':None,
            'evidence':[{'event':e['handle'],'source_index':0,'quote':e['sources'][0]['quote']} for e in es]}]}
    def task(self,c):return self.domain.task(sorted(c['dependencies']),'links',self.review.bundle.digest).model_copy(update={'topic_repair_only':True})
    def test_link_preserves_event_identity_and_sources_without_memory_writes(self):
        c=self.review.next_context();before=[tuple(r) for r in self.store.db.execute('SELECT * FROM workspace_events ORDER BY id')]
        self.review.apply(c,self.proposal(c),self.task(c))
        self.assertEqual(before,[tuple(r) for r in self.store.db.execute('SELECT * FROM workspace_events ORDER BY id')])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_all_event_topics').fetchone()[0],2)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM claims').fetchone()[0],0)
    def test_fabricated_or_missing_anchor_cannot_create_a_link(self):
        c=self.review.next_context();answer=self.proposal(c);answer['links'][0]['evidence'][0]['quote']='不存在的逐字引用文字'
        with self.assertRaises(ValueError):self.review.apply(c,answer,self.task(c))
        answer=self.proposal(c);answer['links'][0]['evidence'].pop()
        with self.assertRaises(ValueError):self.review.apply(c,answer,self.task(c))
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_all_event_topics').fetchone()[0],0)
    def test_revoked_sources_or_changed_events_reject_stale_review(self):
        c=self.review.next_context();task=self.task(c)
        self.store.db.execute("UPDATE workspace_events SET version=version+1 WHERE id=?",(next(iter(c['aliases'].values())),));self.store.db.commit()
        with self.assertRaises(Conflict):self.review.apply(c,self.proposal(c),task)
        c=self.review.next_context();task=self.task(c);did=next(iter(c['dependencies']));self.store.db.execute("UPDATE documents SET revision=revision+1 WHERE id=?",(did,));self.store.db.commit()
        with self.assertRaises(Conflict):self.review.apply(c,self.proposal(c),task)
    def test_empty_result_completes_once_without_polling_model_until_yes(self):
        c=self.review.next_context();self.review.apply(c,{'links':[]},self.task(c))
        self.store.db.execute("INSERT INTO incremental_topic_reviews VALUES(?,'completed','{}')",(c['key'],));self.store.db.commit()
        self.assertIsNone(self.review.next_context())
    def test_default_activation_primes_old_archive_without_model_calls(self):
        self.store.db.execute('DROP TABLE incremental_topic_reviews');self.store.db.execute('DROP TABLE incremental_topic_epochs');self.store.db.commit()
        review=CrossConversationReview(self.agent,self.cfg)
        self.assertIsNone(review.next_context())
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM incremental_topic_reviews WHERE status='pre_upgrade_baseline'").fetchone()[0],1)

    def test_shared_context_is_normalized_but_never_declares_same_issue(self):
        for row in self.store.db.execute('SELECT id FROM sessions').fetchall():
            self.store.event(row['id'],'recording_context',{'group_id':'shared-meeting','medium':'live_video_meeting','provided_by':'user'})
        context=self.review.next_context();groups=context['model']['shared_conversation_contexts']
        self.assertEqual(len(groups),1);self.assertEqual(len(groups[0]['member_events']),2)
        self.assertTrue(groups[0]['same_issue_is_not_asserted'])

    def test_implementation_epoch_changes_cache_without_changing_model_input(self):
        old=self.review.next_context()
        with patch('heartball_incremental_topics.implementation_digest',return_value='new-implementation'):
            changed=CrossConversationReview(self.agent,self.cfg,prime_existing=False)
        new=changed.next_context()
        self.assertNotEqual(old['key'],new['key']);self.assertEqual(old['model'],new['model'])
        with patch('heartball_incremental_topics.implementation_digest',return_value='another-upgrade'):
            guarded=CrossConversationReview(self.agent,self.cfg)
        self.assertIsNone(guarded.next_context())


if __name__=='__main__':unittest.main()

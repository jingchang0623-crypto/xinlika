"""Attention feedback changes preference projections, never recording evidence."""
import copy
import json
import unittest
import uuid
from test_heartball_incremental import IncrementalTests
from heartball_store import Conflict
import heartball_interest as interest


class InterestTests(unittest.TestCase):
    setUp=IncrementalTests.setUp
    tearDown=IncrementalTests.tearDown
    document=IncrementalTests.document
    task=IncrementalTests.task
    answer=IncrementalTests.answer
    commit=IncrementalTests.commit

    def event(self,minute='00'):
        did=self.document(minute=minute);result,_=self.commit(did)
        eid=result['receipt']['event_ids'][0]
        return dict(self.store.db.execute('SELECT * FROM workspace_events WHERE id=?',(eid,)).fetchone())

    def rate(self,event,value='important',version=0,rid=None):
        return self.agent.feedback(dict(id=rid or str(uuid.uuid4()),target_id=event['id'],action='rate_event',
            expected_version=event['version'],expected_interest_version=version,values={'interest':value}))

    def test_durable_idempotent_receipt_and_undo_without_evidence_or_memory_writes(self):
        event=self.event();original=dict(self.store.db.execute('SELECT * FROM documents').fetchone())
        events=[tuple(r) for r in self.store.db.execute('SELECT * FROM workspace_events')]
        rid=str(uuid.uuid4());first=self.rate(event,rid=rid)
        self.assertEqual(first,self.rate(event,rid=rid));self.assertEqual(first['interest_version'],1)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM feedback').fetchone()[0],1)
        with self.assertRaises(Conflict):self.rate(event,'unimportant',rid=rid)
        with self.assertRaises(Conflict):self.rate(event,'unimportant')
        self.assertEqual(self.rate(event,'neutral',1)['interest_version'],2)
        self.assertFalse(interest.context(self.store.db)['examples'])
        self.assertEqual(dict(self.store.db.execute('SELECT * FROM documents').fetchone()),original)
        self.assertEqual([tuple(r) for r in self.store.db.execute('SELECT * FROM workspace_events')],events)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM claims').fetchone()[0],0)

    def test_revised_or_revoked_evidence_is_not_a_preference(self):
        event=self.event();self.rate(event)
        self.assertEqual(interest.project(self.store.db,event)['user_interest'],'important')
        self.store.db.execute('UPDATE documents SET revision=revision+1');self.store.db.commit()
        self.assertEqual(interest.project(self.store.db,event)['user_interest'],'neutral')
        self.assertEqual(interest.context(self.store.db)['labelled_event_count'],0)
        with self.assertRaises(Conflict):self.rate(event,'unimportant',1)

    def test_revoked_policy_removes_examples(self):
        event=self.event();self.rate(event)
        self.store.db.execute('UPDATE processing_policies SET agent_allowed=0');self.store.db.commit()
        self.assertEqual(interest.context(self.store.db)['examples'],[])

    def test_continuing_the_same_matter_keeps_original_feedback_anchors(self):
        event=self.event();self.rate(event)
        before=interest.context(self.store.db)
        did=self.document('维修店说明下周寄回镜头。','02')
        result,_=self.commit(did,self.answer('e1'))
        self.assertEqual(result['receipt']['event_ids'],[event['id']])
        updated=dict(self.store.db.execute('SELECT * FROM workspace_events WHERE id=?',(event['id'],)).fetchone())
        self.assertEqual(interest.project(self.store.db,updated)['user_interest'],'important')
        self.assertEqual(interest.context(self.store.db)['profile_key'],before['profile_key'])
        self.assertEqual(interest.context(self.store.db)['examples'],before['examples'])

    def test_source_version_conflict_and_malformed_values(self):
        event=self.event();old=copy.deepcopy(event);old['version']-=1
        with self.assertRaises(Conflict):self.rate(old)
        for value in ('unsupported',None,[],{}):
            with self.assertRaises((ValueError,TypeError)):self.rate(event,value)

    def test_three_independent_ratings_and_two_same_direction_examples_required(self):
        events=[self.event(str(i).zfill(2)) for i in range(3)]
        self.rate(events[0],'unimportant');self.rate(events[1],'unimportant')
        self.assertFalse(interest.context(self.store.db)['ready_for_suggestions'])
        self.rate(events[2],'important');ctx=interest.context(self.store.db)
        self.assertTrue(ctx['ready_for_suggestions'])
        new=self.event('05')
        issue=dict(interest_level='low',interest_reason='同为不关心的维修报价闲聊',interest_example_ids=[e['id'] for e in events[:2]])
        self.assertTrue(interest.save_prediction(self.store.db,new,issue,ctx))
        self.assertEqual(interest.project(self.store.db,new)['suggested_interest'],'low')
        # Explicit user feedback wins over the model; a changed profile expires predictions.
        self.rate(new,'important')
        self.assertEqual(interest.project(self.store.db,new)['user_interest'],'important')
        other=self.event('06')
        self.assertFalse(interest.save_prediction(self.store.db,other,issue,ctx))
        fresh=interest.context(self.store.db)
        for ids in ([events[0]['id']],[events[0]['id']]*2,[events[0]['id'],events[2]['id']],['invented','unknown']):
            self.assertFalse(interest.save_prediction(self.store.db,other,{**issue,'interest_example_ids':ids},fresh))
        self.assertFalse(interest.save_prediction(self.store.db,{**other,'source_kind':'background_playback'},issue,fresh))

    def test_new_model_context_contains_bounded_examples_without_changing_source_fingerprint(self):
        event=self.event();did=self.document('明天去取维修好的镜头。','09');task=self.task(did)
        before=self.inc.prepare(task)
        self.rate(event)
        after=self.inc.prepare(task)
        self.assertEqual(task.expected_snapshot,self.inc.domain.fingerprint(task.document_ids))
        self.assertEqual(after['context']['attention_preferences']['examples'][0]['event_id'],event['id'])
        self.assertNotEqual(before['context']['attention_preferences']['profile_key'],after['context']['attention_preferences']['profile_key'])
        # A stale preference suggestion cannot make valid source processing fail.
        answer=self.answer();answer['issues'][0].update(interest_level='high',interest_reason='guess',interest_example_ids=[event['id']])
        result=self.inc.commit(task,before,answer)
        new=dict(self.store.db.execute('SELECT * FROM workspace_events WHERE id=?',(result['receipt']['event_ids'][0],)).fetchone())
        self.assertEqual(interest.project(self.store.db,new)['suggested_interest'],'normal')

    def test_api_projection_retains_unimportant_in_all_timeline_events(self):
        event=self.event();self.rate(event,'unimportant')
        state=self.agent.state(day='2026-10-21')
        self.assertEqual(state['eventInterestProtocol'],1)
        matches=[e for e in state['today']['timeline'] if e['id']==event['id']]
        self.assertEqual(matches[0]['user_interest'],'unimportant')

    def test_learned_low_cannot_hide_a_matter_as_detail(self):
        events=[self.event(str(i).zfill(2)) for i in range(3)]
        for index,event in enumerate(events):self.rate(event,'unimportant' if index<2 else 'important')
        did=self.document('维修店又补充了报价。','06');task=self.task(did);prepared=self.inc.prepare(task)
        answer=self.answer();answer['issues'][0].update(display='detail',interest_level='low',
            interest_reason='与两条少关注例子是同一具体关心点',interest_example_ids=[e['id'] for e in events[:2]])
        result=self.inc.commit(task,prepared,answer);eid=result['receipt']['event_ids'][0]
        timeline=self.agent.state(day='2026-10-21')['today']['timeline']
        item=next(e for e in timeline if e['id']==eid)
        self.assertEqual(item['suggested_interest'],'low')


if __name__=='__main__':unittest.main()

"""Persistence, provenance and replay tests; fixtures are not semantic scores."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import uuid

from heartball_store import Store,Conflict
from heartball_agent_store import AgentStore
from heartball_incremental import IncrementalDomain,IncrementalProcessAdapter,skill_version
from heartball_incremental_reuse import bounded_state,rolling_contains


class IncrementalTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.store=Store(self.root);self.agent=AgentStore(self.store);self.inc=IncrementalDomain(self.agent);self.sid=str(uuid.uuid4())
        self.store.create_session(self.sid);self.agent.policy(self.sid,asr=False,agent=True,source_kind='live_conversation',occurred_at='2026-10-21T12:00:00+08:00')
        self.store.update_session(self.sid,status='completed')

    def tearDown(self):self.store.db.close();self.temp.cleanup()

    def document(self,text='镜头维修需要两周。',minute='00',sid=None):
        sid=sid or self.sid;did=str(uuid.uuid4())
        self.agent.commit_document(dict(id=did,kind='ambient',session_id=sid,input_key=did,text=text,evidence=[],source_kind='live_conversation',occurred_at=f'2026-10-21T12:{minute}:00+08:00',boundary_quality='source_interval'),dict(title='',summary='',claims=[]))
        return did

    def task(self,did):return self.inc.domain.task([did],'增量编辑',skill_version()).model_copy(update={'complete_events':True})

    def answer(self,continuation=None):
        issue=dict(key='repair',title='镜头维修安排',summary='讨论镜头维修安排。',admission_reason='具体维修问题。',sources=[dict(document_id='d1',revision=1,all_spans=True)])
        if continuation:issue['continues_id']=continuation
        return dict(state=dict(title='维修',bullets=['讨论维修'],people=[],open_questions=[]),issues=[issue],fragments=[],topics=[])

    def commit(self,did,answer=None):
        task=self.task(did);prepared=self.inc.prepare(task)
        return self.inc.commit(task,prepared,answer or self.answer()),task

    def test_continuation_preserves_id_clock_and_all_old_sources(self):
        first=self.document();result,_=self.commit(first);eid=result['receipt']['event_ids'][0]
        second=self.document('已经联系维修店。','02');task=self.task(second);prepared=self.inc.prepare(task)
        self.assertEqual(prepared['context']['recent_events'][0]['id'],'e1');self.assertEqual(prepared['context']['previous_state']['title'],'维修')
        result=self.inc.commit(task,prepared,self.answer('e1'));self.assertEqual(result['receipt']['event_ids'],[eid])
        self.assertEqual(self.store.db.execute('SELECT occurred_at FROM workspace_events WHERE id=?',(eid,)).fetchone()[0],'2026-10-21T12:00:00+08:00')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_event_sources WHERE event_id=?',(eid,)).fetchone()[0],2)

    def test_incomplete_span_assignment_rolls_back_state_and_events(self):
        d=self.document('维修需要两周。按钮没有反应。');task=self.task(d);prepared=self.inc.prepare(task);answer=self.answer()
        answer['issues'][0]['sources']=[dict(document_id='d1',revision=1,span_ids=[0])]
        with self.assertRaises(ValueError):self.inc.commit(task,prepared,answer)
        for table in ('incremental_states','incremental_commits','workspace_events'):self.assertEqual(self.store.db.execute('SELECT count(*) FROM '+table).fetchone()[0],0)

    def test_short_feedback_can_be_an_independent_event_without_duration_floor(self):
        d=self.document('按钮没有反应。');a=self.answer();a['issues'][0].update(title='按钮无反应',category='feedback',card_style='compact')
        result,_=self.commit(d,a);eid=result['receipt']['event_ids'][0]
        self.assertEqual(self.store.db.execute('SELECT title FROM workspace_events WHERE id=?',(eid,)).fetchone()[0],'按钮无反应')

    def test_changed_generation_invalidates_compact_state(self):
        first=self.document();self.commit(first)
        with self.store.transaction():self.agent.workspace.invalidate_document(first)
        second=self.document('补充维修情况。','03');prepared=self.inc.prepare(self.task(second))
        self.assertTrue(prepared['state_reset']);self.assertEqual(prepared['context']['previous_state'],{});self.assertEqual(prepared['context']['recent_events'],[])

    def test_revoked_old_source_invalidates_state_and_candidates(self):
        first=self.document();self.commit(first)
        self.store.db.execute("UPDATE processing_policies SET agent_allowed=0 WHERE session_id=?",(self.sid,));self.store.db.commit()
        self.assertIsNone(self.inc.source_signature(first))

    def test_cross_recording_is_a_topic_not_event_continuation(self):
        first=self.document();result,_=self.commit(first)
        sid=str(uuid.uuid4());self.store.create_session(sid);self.store.update_session(sid,status='completed');self.agent.policy(sid,asr=False,agent=True,source_kind='live_conversation',occurred_at='2026-10-21T12:04:00+08:00')
        second=self.document('镜头维修店有回复。','04',sid);task=self.task(second);prepared=self.inc.prepare(task)
        self.assertEqual(len(prepared['context']['related_history']),1);self.assertFalse(prepared['context']['recent_events'])
        with self.assertRaises(ValueError):self.inc.commit(task,prepared,self.answer('e1'))
        a=self.answer();a['topics']=[dict(key='repair-topic',title='镜头维修进展',summary='不同交流继续维修问题。',event_keys=['repair','e1'])]
        self.inc.commit(task,prepared,a);self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_topics').fetchone()[0],1)

    def test_late_window_does_not_overwrite_later_running_state(self):
        newer=self.document('维修有新进展。','20');self.commit(newer)
        old=self.document('早先询问维修。','00');task=self.task(old);prepared=self.inc.prepare(task)
        self.assertTrue(prepared['late']);self.assertEqual(prepared['context']['previous_state'],{})
        a=self.answer();a['state']['title']='旧信息';self.inc.commit(task,prepared,a)
        row=self.store.db.execute('SELECT * FROM incremental_states').fetchone();self.assertEqual(row['version'],1);self.assertEqual(json.loads(row['state'])['title'],'维修')

    def test_late_correction_recalls_rebuilt_sibling_event_but_not_unrelated_future(self):
        first=self.document('准备寄修镜头。','00');first_result,_=self.commit(first)
        sibling=self.document('选择了维修店。','02');self.commit(sibling,self.answer('e1'))
        # Correcting the original invalidates the spanning event. Rebuilding
        # its remaining source at a later watermark models live progression.
        with self.store.transaction():self.agent.workspace.invalidate_document(first)
        rebuilt=self.document('维修店后来提供报价。','20');task=self.inc.domain.task([sibling,rebuilt],'重建',skill_version()).model_copy(update={'complete_events':True})
        prepared=self.inc.prepare(task);a=self.answer();a['issues'][0]['sources'].append(dict(document_id='d2',revision=1,all_spans=True))
        result=self.inc.commit(task,prepared,a);eid=result['receipt']['event_ids'][0]
        unrelated=self.document('另外讨论晚餐。','21');self.commit(unrelated)
        corrected=self.document('准备寄修镜头，。','00')
        with self.store.transaction():self.store.db.execute('UPDATE documents SET evidence=? WHERE id=?',(json.dumps([{'kind':'user_correction','previous_document_id':first}]),corrected))
        context=self.inc.prepare(self.task(corrected))['context']
        candidates=context['recent_events']
        self.assertEqual(len(candidates),1)
        self.assertIn('选择了维修店。',{r['quote'] for r in candidates[0]['sources']})
        update=context['new_sources'][0]['source_update']
        self.assertFalse(update['new_occurrence'])
        self.assertEqual(update['previous_context_candidates'],[candidates[0]['id']])
        self.assertEqual(update['previous_texts'],['准备寄修镜头。'])
        self.assertTrue(update['previous_machine_association_is_not_truth'])
        # The same late speech without a correction chain sees no future event.
        ordinary=self.document('准备寄修镜头。','00')
        normal=self.inc.prepare(self.task(ordinary))['context']
        self.assertFalse(normal['recent_events'])
        self.assertNotIn('source_update',normal['new_sources'][0])

    def test_state_compare_and_swap_rejects_concurrent_response(self):
        d=self.document();task=self.task(d);prepared=self.inc.prepare(task)
        self.store.db.execute('INSERT INTO incremental_states VALUES(?,1,?,?)',(prepared['scope'],'{}','2026-10-21T12:00:00+08:00'));self.store.db.commit()
        with self.assertRaises(Conflict):self.inc.commit(task,prepared,self.answer())
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],0)

    def test_replayed_receipt_needs_no_model_credentials_after_restart(self):
        d=self.document();result,task=self.commit(d);(self.root/'.agent-runtime-owned').touch()
        adapter=IncrementalProcessAdapter(self.root,{})
        receipt=adapter.run(task);self.assertEqual(receipt.status,'completed');self.assertEqual(receipt.usage['calls'],0)
        self.assertEqual(receipt.receipt,result['receipt']);self.assertFalse((self.root/'incremental-runs').exists())

    def test_out_of_window_cannot_be_continued(self):
        first=self.document();self.commit(first);second=self.document('维修继续。','59');prepared=self.inc.prepare(self.task(second))
        self.assertFalse(prepared['context']['recent_events'])
        with self.assertRaises(ValueError):self.inc.normalize(prepared,self.answer('e1'))

    def test_bounded_state_is_valid_json_and_deduplicates_without_partial_fields(self):
        state=bounded_state(dict(title=' 标题 ',bullets=['• 重复','重复']+['长'*200]*8,people=['甲']*12,open_questions=['问'*200]*8),maximum=600)
        self.assertLessEqual(len(json.dumps(state,ensure_ascii=False)),600);self.assertEqual(state['people'],['甲'])
        self.assertTrue(rolling_contains(1,50,51,60));self.assertFalse(rolling_contains(70,90,51,60))

    def test_disjoint_issue_ranges_reuse_mcp_normalization_without_fake_quote(self):
        d=self.document('镜头维修。嗯。下周寄送。');task=self.task(d);prepared=self.inc.prepare(task);a=self.answer()
        a['issues'][0]['sources']=[dict(document_id='d1',revision=1,span_ids=[0,2])]
        a['fragments']=[dict(source=dict(document_id='d1',revision=1,span_ids=[1]),reason='filler')]
        result=self.inc.commit(task,prepared,a)
        quotes=[r[0] for r in self.store.db.execute('SELECT quote FROM workspace_event_sources')]
        self.assertCountEqual(quotes,['镜头维修。','下周寄送。']);self.assertEqual(result['state_version'],1)

    def test_context_metadata_is_preserved_without_manufacturing_matter_labels(self):
        self.store.event(self.sid,'recording_context',{'medium':'live_video_meeting','group_id':'meeting-1','provided_by':'user'})
        d=self.document();prepared=self.inc.prepare(self.task(d))
        self.assertEqual(prepared['context']['new_sources'][0]['recording_context']['group_id'],'meeting-1')
        self.assertNotIn('same_matter',json.dumps(prepared['context']))

    def test_source_context_change_invalidates_cached_state(self):
        d=self.document();self.commit(d)
        self.store.event(self.sid,'recording_context',{'medium':'device_playback'})
        prepared=self.inc.prepare(self.task(self.document('后续内容。','03')))
        self.assertTrue(prepared['state_reset'])

    def test_two_updates_cannot_overwrite_one_continuation(self):
        first=self.document();self.commit(first)
        d=self.document('先询问费用。然后确认时间。','02');prepared=self.inc.prepare(self.task(d));a=self.answer('e1')
        second=copy.deepcopy(a['issues'][0]);second['key']='second';a['issues'].append(second)
        a['issues'][0]['sources'][0]['all_spans']=False;a['issues'][0]['sources'][0]['span_ids']=[0]
        a['issues'][1]['sources'][0]['all_spans']=False;a['issues'][1]['sources'][0]['span_ids']=[1]
        with self.assertRaises(ValueError):self.inc.normalize(prepared,a)

    def test_exact_ranges_preserve_repeated_identical_words(self):
        d=self.document('维修。嗯。维修。');a=self.answer();a['issues'][0].pop('sources');a['allocations']={'d1':['repair','~filler','repair']}
        self.commit(d,a)
        ranges=[tuple(r) for r in self.store.db.execute('SELECT start_char,end_char,quote FROM workspace_refined_ranges ORDER BY start_char')]
        self.assertEqual(ranges,[(0,3,'维修。'),(5,8,'维修。')])
        from heartball_incremental_review import audit_sources
        doc=dict(self.store.db.execute('SELECT * FROM documents WHERE id=?',(d,)).fetchone())
        self.assertTrue(audit_sources(self.store.db,[doc])['passed'])
        self.store.db.execute('DELETE FROM workspace_refined_ranges WHERE start_char=5')
        self.assertEqual(audit_sources(self.store.db,[doc])['missing_spans'],1)

    def test_reprocessed_source_retires_old_fragment_and_keeps_receipt_history(self):
        from heartball_incremental_review import audit_sources
        d=self.document('维修。嗯。维修。');a=self.answer();a.pop('fragments')
        a['issues'][0].pop('sources');a['allocations']={'d1':['repair','~filler','repair']}
        first,old_task=self.commit(d,a)
        with self.store.transaction():self.agent.workspace.invalidate_document(d)
        result,new_task=self.commit(d)
        doc=dict(self.store.db.execute('SELECT * FROM documents WHERE id=?',(d,)).fetchone())
        self.assertTrue(audit_sources(self.store.db,[doc])['passed'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM agent_source_fragments').fetchone()[0],0)
        row=self.store.db.execute('SELECT * FROM agent_source_fragment_history').fetchone()
        self.assertEqual((row['task_id'],row['replaced_by_task'],row['span_id']),(old_task.id,new_task.id,1))
        self.assertEqual(json.loads(self.store.db.execute('SELECT payload FROM incremental_commits WHERE task_id=?',(old_task.id,)).fetchone()[0]),first)
        self.assertEqual(json.loads(self.store.db.execute('SELECT payload FROM incremental_commits WHERE task_id=?',(new_task.id,)).fetchone()[0]),result)

    def test_fragment_reallocation_is_atomic_and_recoverable_after_event_invalidation(self):
        from heartball_fragment_projection import retire
        d=self.document('维修。嗯。');a=self.answer();a['issues'][0]['sources']=[dict(document_id='d1',revision=1,span_ids=[0])]
        a['fragments']=[dict(source=dict(document_id='d1',revision=1,span_ids=[1]),reason='filler')]
        self.commit(d,a)
        with self.assertRaises(RuntimeError):
            with self.store.transaction():
                retire(self.store.db,d,1,'uncommitted-replacement')
                raise RuntimeError('rollback')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM agent_source_fragments').fetchone()[0],1)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM agent_source_fragment_history').fetchone()[0],0)

    def test_startup_repairs_only_durably_completed_current_generation(self):
        from heartball_fragment_projection import repair_completed_reallocations
        d=self.document('维修。嗯。');a=self.answer();a['issues'][0]['sources']=[dict(document_id='d1',revision=1,span_ids=[0])]
        a['fragments']=[dict(source=dict(document_id='d1',revision=1,span_ids=[1]),reason='filler')]
        _,old_task=self.commit(d,a)
        saved=dict(self.store.db.execute('SELECT * FROM agent_source_fragments').fetchone())
        with self.store.transaction():self.agent.workspace.invalidate_document(d)
        _,new_task=self.commit(d)
        with self.store.transaction():
            # Recreate the old-release overlap, while current receipt is absent.
            self.store.db.execute('INSERT INTO agent_source_fragments VALUES(?,?,?,?,?)',tuple(saved.values()))
            self.store.db.execute('CREATE TABLE native_source_receipts(document_id TEXT,revision INTEGER,generation INTEGER,task_id TEXT)')
            generation=self.store.db.execute('SELECT generation FROM workspace_generations WHERE document_id=?',(d,)).fetchone()[0]
            self.store.db.execute('INSERT INTO native_source_receipts VALUES(?,?,?,?)',(d,1,generation-1,old_task.id))
            self.assertEqual(repair_completed_reallocations(self.store.db),0)
            self.store.db.execute('INSERT INTO native_source_receipts VALUES(?,?,?,?)',(d,1,generation,new_task.id))
            raw=self.store.db.execute('SELECT payload FROM incremental_commits WHERE task_id=?',(new_task.id,)).fetchone()[0]
            partial=json.loads(raw);ref=partial['proposal']['issues'][0]['sources'][0]
            ref['all_spans']=False;ref['span_ids']=[0]
            self.store.db.execute('UPDATE incremental_commits SET payload=? WHERE task_id=?',(json.dumps(partial),new_task.id))
            self.assertEqual(repair_completed_reallocations(self.store.db),0)
            self.store.db.execute('UPDATE incremental_commits SET payload=? WHERE task_id=?',(raw,new_task.id))
            self.assertEqual(repair_completed_reallocations(self.store.db),1)
            self.assertEqual(repair_completed_reallocations(self.store.db),0)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM agent_source_fragments').fetchone()[0],0)

    def test_rolling_merge_preserves_identity_sources_topics_and_short_feedback(self):
        from heartball_incremental_review import RollingReview
        first=self.document();r,_=self.commit(first);eid=r['receipt']['event_ids'][0]
        second=self.document('维修店说还要确认配件。','02');s,_=self.commit(second);other=s['receipt']['event_ids'][0]
        third=self.document('录音按钮没有反应。','03');t,_=self.commit(third);short=t['receipt']['event_ids'][0]
        for event,tid in [(eid,'one'),(other,'two')]:
            self.store.db.execute("INSERT INTO workspace_topics VALUES(?,?,?,'conversation','active',1,'2026-10-21')",(tid,tid,'原文主题'))
            self.store.db.execute('INSERT INTO workspace_event_topics VALUES(?,?)',(event,tid))
        self.store.db.commit();review=RollingReview(self.agent,{})
        context=review.next_context();self.assertIsNotNone(context)
        group=dict(title='镜头维修安排',summary='讨论维修周期及配件确认。',events=[dict(id=e['id'],version=e['version']) for e in context['events'] if e['id'] in {eid,other}])
        review.apply(context,{'merges':[group]})
        self.assertEqual(self.store.db.execute('SELECT status FROM workspace_events WHERE id=?',(eid,)).fetchone()[0],'active')
        self.assertEqual(self.store.db.execute('SELECT status FROM workspace_events WHERE id=?',(other,)).fetchone()[0],'merged')
        self.assertEqual(self.store.db.execute('SELECT status FROM workspace_events WHERE id=?',(short,)).fetchone()[0],'active')
        self.assertEqual({r[0] for r in self.store.db.execute('SELECT topic_id FROM workspace_all_event_topics WHERE event_id=?',(eid,))},{'one','two'})
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_refined_ranges WHERE event_id=?',(eid,)).fetchone()[0],2)
        self.assertFalse(self.store.db.execute('SELECT 1 FROM workspace_event_merge_parents WHERE parent_id=event_id').fetchone())
        count=self.store.db.execute('SELECT version FROM workspace_events WHERE id=?',(eid,)).fetchone()[0]
        review.apply(context,{'merges':[group]})
        self.assertEqual(self.store.db.execute('SELECT version FROM workspace_events WHERE id=?',(eid,)).fetchone()[0],count)

    def test_rolling_review_cannot_hide_events_and_checks_revoked_dependency(self):
        from heartball_incremental_review import RollingReview
        self.commit(self.document());self.commit(self.document('维修费用需要确认。','02'))
        review=RollingReview(self.agent,{});context=review.next_context()
        ref=dict(id=context['events'][0]['id'],version=context['events'][0]['version'],reason='禁止隐藏')
        with self.assertRaises(ValueError):review.apply(context,{'merges':[],'transcript_only':[ref]})
        self.store.db.execute('UPDATE processing_policies SET agent_allowed=0 WHERE session_id=?',(self.sid,));self.store.db.commit()
        with self.assertRaises(ValueError):review.apply(context,{'merges':[]})

    def test_review_allocations_are_exclusive_and_singletons_stay_independent(self):
        from heartball_incremental_review import allocated_groups
        events=[{'id':str(i),'version':1} for i in range(4)]
        groups=[dict(key='g',title='同一讨论',summary='原文支持的过程。'),dict(key='s',title='独立反馈',summary='独立。')]
        result=allocated_groups(dict(groups=groups,allocations={'e0':'g','e1':'keep','e2':'g','e3':'s'}),events)
        self.assertEqual([r['id'] for r in result[0]['events']],['0','2']);self.assertEqual(len(result),1)
        for owners in (['g'],{'e0':'g','e1':'keep','e2':'g','e3':'unknown'},{'e0':'g'}):
            with self.assertRaises(ValueError):allocated_groups(dict(groups=groups,allocations=owners),events)

    def test_span_id_map_does_not_depend_on_json_key_order(self):
        d=self.document('维修镜头。嗯。下周寄送。');a=self.answer();a['issues'][0].pop('sources');a['allocations']={'d1':{'2':'repair','0':'repair','1':'~filler'}}
        result,_=self.commit(d,a);self.assertEqual(len(result['proposal']['issues'][0]['sources']),2)
        d=self.document('另一个问题。','04');prepared=self.inc.prepare(self.task(d));a=self.answer();a['issues'][0].pop('sources');a['allocations']={'d1':{'1':'repair'}}
        with self.assertRaises(ValueError):self.inc.normalize(prepared,a)

    def test_host_binds_topic_read_version_but_rejects_actual_concurrent_change(self):
        self.commit(self.document())
        second=self.document('维修配件还在确认。','02');a=self.answer();a['topics']=[dict(key='maintenance',title='维修安排',summary='维修进展',event_keys=['repair','e1'])];self.commit(second,a)
        third=self.document('维修费用有回复。','04');task=self.task(third);prepared=self.inc.prepare(task);a=self.answer();a['topics']=[dict(key='maintenance',title='维修安排',summary='费用进展',event_keys=['repair','e1'],existing_topic_id='t1',existing_topic_version=999)]
        self.inc.commit(task,prepared,a)
        fourth=self.document('维修费用需再确认。','06');task=self.task(fourth);prepared=self.inc.prepare(task)
        self.store.db.execute('UPDATE workspace_topics SET version=version+1');self.store.db.commit()
        with self.assertRaises(Conflict):self.inc.commit(task,prepared,a)

    def test_bounded_review_plan_does_not_skip_tail_after_first_chunk_shrinks(self):
        from heartball_incremental_review import RollingReview
        for i in range(26):self.commit(self.document('讨论第'+str(i)+'份合同。','02'))
        review=RollingReview(self.agent,{});first=review.next_context();self.assertEqual(len(first['events']),24)
        refs=[dict(id=e['id'],version=e['version']) for e in first['events'][:2]]
        review.apply(first,{'merges':[dict(title='同一讨论',summary='合同讨论过程。',events=refs)]})
        self.store.db.execute('INSERT INTO incremental_reviews VALUES(?,?,?,?,?)',(first['window_key'],first['scope'],first['cutoff'],'completed','{}'));self.store.db.commit()
        second=review.next_context();self.assertEqual(len(second['events']),2)
        self.assertFalse({e['id'] for e in first['events']}&{e['id'] for e in second['events']})

    def test_revocation_during_model_call_rejects_old_context_dependency(self):
        first=self.document();self.commit(first)
        sid=str(uuid.uuid4());self.store.create_session(sid);self.store.update_session(sid,status='completed');self.agent.policy(sid,asr=False,agent=True,source_kind='live_conversation',occurred_at='2026-10-21T12:04:00+08:00')
        second=self.document('继续讨论镜头维修。','04',sid);task=self.task(second);prepared=self.inc.prepare(task)
        self.assertIn(first,prepared['dependencies'])
        self.store.db.execute('UPDATE processing_policies SET agent_allowed=0 WHERE session_id=?',(self.sid,));self.store.db.commit()
        with self.assertRaises(Conflict):self.inc.commit(task,prepared,self.answer())
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM incremental_commits').fetchone()[0],1)

    def test_focus_is_independent_and_cannot_create_multiple_events(self):
        d=self.document('需要特别记下维修安排。');self.store.db.execute("UPDATE documents SET kind='focus' WHERE id=?",(d,));self.store.db.commit()
        task=self.task(d);prepared=self.inc.prepare(task);a=self.answer();a['issues'].append(copy.deepcopy(a['issues'][0]));a['issues'][1]['key']='another'
        with self.assertRaises(ValueError):self.inc.normalize(prepared,a)
        result=self.inc.commit(task,prepared,self.answer());self.assertEqual(len(result['receipt']['event_ids']),1)

    def test_incremental_strategy_is_explicit_and_query_uses_native_fallback(self):
        from heartball_native_processing import NativeRuntimeService
        service=NativeRuntimeService(self.agent,{'analysis_strategy':'incremental'},adapter=object())
        self.assertEqual(service.analysis_skill_version(),skill_version())
        self.assertNotEqual(service.analysis_skill_version(True),skill_version())
        class Fallback:
            called=False
            def run(inner,task):inner.called=True;return 'native-query'
        fallback=Fallback();(self.root/'.agent-runtime-owned').touch();adapter=IncrementalProcessAdapter(self.root,{},fallback=fallback)
        task=self.task(self.document()).model_copy(update={'mode':'answer','question_id':'q'})
        self.assertEqual(adapter.run(task),'native-query');self.assertTrue(fallback.called)

    def test_exclusive_allocation_builds_exact_continuous_sources(self):
        d=self.document('维修镜头。嗯。下周寄送。');task=self.task(d);prepared=self.inc.prepare(task);a=self.answer();a['issues'][0].pop('sources')
        a['allocations']={'d1':['repair','~filler','repair']}
        result=self.inc.commit(task,prepared,a)
        self.assertEqual(len(result['proposal']['issues'][0]['sources']),2)
        self.assertEqual(len(result['proposal']['fragments']),1)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM agent_source_fragments').fetchone()[0],1)

    def test_exclusive_allocation_cannot_omit_duplicate_or_invent_span_ownership(self):
        d=self.document('维修镜头。按钮没反应。');task=self.task(d);prepared=self.inc.prepare(task)
        for owners in (['repair'],['repair','repair','repair'],['repair','invented']):
            a=self.answer();a['issues'][0].pop('sources');a['allocations']={'d1':owners}
            with self.assertRaises(ValueError):self.inc.commit(task,prepared,a)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],0)

    def test_allocation_normalization_does_not_mutate_model_answer(self):
        d=self.document();task=self.task(d);prepared=self.inc.prepare(task);a=self.answer();a['issues'][0].pop('sources');a['allocations']={'d1':['repair']};original=copy.deepcopy(a)
        self.inc.normalize(prepared,a);self.assertEqual(a,original)
        result=self.inc.commit(task,prepared,a);again=self.inc.commit(task,prepared,a)
        self.assertEqual(result,again)

    def test_live_scheduler_uses_same_bounded_observation_window(self):
        from heartball_native_processing import NativeRuntimeService
        service=NativeRuntimeService(self.agent,{'analysis_strategy':'incremental','coalesce_seconds':0,'analysis_window_seconds':300},adapter=object())
        first=self.document(minute='00');second=self.document(minute='04');third=self.document(minute='05')
        service.schedule();row=self.store.db.execute("SELECT payload FROM jobs WHERE kind='native_agent_analysis'").fetchone();ids=json.loads(row[0])['document_ids']
        self.assertIn(first,ids);self.assertIn(second,ids);self.assertNotIn(third,ids)

    def test_single_event_index_does_not_block_event_or_invent_relation(self):
        d=self.document();a=self.answer();a['topics']=[dict(key='one',title='维修索引',summary='仅一个事件。',event_keys=['repair'])]
        result,_=self.commit(d,a)
        self.assertEqual(result['structural_diagnostics']['singleton_indexes_not_relations'],1)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],1)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_topics').fetchone()[0],0)

    def test_failed_saved_model_candidate_can_recover_without_new_model_call(self):
        d=self.document();task=self.task(d);prepared=self.inc.prepare(task);a=self.answer();a['issues'][0].pop('sources');a['allocations']={'d1':['repair']}
        a['topics']=[dict(key='one',title='维修',summary='单节点。',event_keys=['repair'])]
        folder=self.root/'incremental-runs'/task.id/'attempt-001';folder.mkdir(parents=True);(self.root/'.agent-runtime-owned').touch()
        (folder/'context-private.json').write_text(json.dumps(prepared['context'],ensure_ascii=False))
        (folder/'answer-1-private.json').write_text(json.dumps({'content':json.dumps(a,ensure_ascii=False)}))
        (folder/'receipt.json').write_text(json.dumps({'status':'failed'}))
        receipt=IncrementalProcessAdapter(self.root,{'capture_model_payloads':True}).run(task)
        self.assertEqual(receipt.status,'completed');self.assertEqual(receipt.usage['calls'],0)
        self.assertEqual(receipt.usage['cost_basis'],'validated_saved_model_candidate')


if __name__=='__main__':unittest.main()

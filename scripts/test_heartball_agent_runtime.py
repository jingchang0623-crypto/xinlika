"""Structural/recovery tests; synthetic fixtures are NOT real-conversation quality scores."""
import asyncio
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

from heartball_store import Store,Conflict
from heartball_agent_store import AgentStore
from heartball_agent_runtime import AgentDomain,ContextReader,readonly_database
from heartball_external_import import ExternalImporter,load_messages


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.store=Store(self.root);self.agent=AgentStore(self.store);self.domain=AgentDomain(self.agent)
        self.did=self.document('午餐讨论镜头维修。之后安排寄送。')

    def tearDown(self):self.store.db.close();self.temp.cleanup()

    def document(self,text,source='live_conversation'):
        sid=str(uuid.uuid4());did=str(uuid.uuid4())
        self.store.create_session(sid)
        self.store.db.execute("UPDATE sessions SET status='completed' WHERE id=?",(sid,));self.store.db.commit()
        self.agent.policy(sid,asr=False,agent=True,source_kind=source,occurred_at='2026-10-21T22:20:00+08:00')
        self.agent.commit_document(dict(id=did,kind='ambient',session_id=sid,input_key=did,text=text,evidence=[],source_kind=source,occurred_at='2026-10-21T22:20:00+08:00',boundary_quality='source_interval'),dict(title='',summary='',claims=[]))
        return did

    def task(self,ids=None):return self.domain.task(ids or [self.did],'整理当前真实来源','test-skill')
    def proposal(self,did=None,quote='午餐讨论镜头维修。'):
        return {'issues':[{'key':'repair','title':'镜头维修','summary':'讨论维修。','sources':[{'document_id':did or self.did,'revision':1,'quote':quote}]}]}

    def test_commit_is_source_grounded_and_idempotent(self):
        task=self.task();first=self.domain.commit(task,self.proposal());again=self.domain.commit(task,self.proposal())
        self.assertTrue(again['duplicate']);self.assertEqual(first['event_ids'],again['event_ids'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],1)
        row=self.store.db.execute('SELECT occurred_at FROM workspace_events').fetchone()
        self.assertEqual(row[0],'2026-10-21T22:20:00+08:00')

    def test_same_task_different_payload_conflicts(self):
        task=self.task();self.domain.commit(task,self.proposal());value=self.proposal();value['issues'][0]['title']='另一标题'
        with self.assertRaises(Conflict):self.domain.commit(task,value)

    def test_invented_quote_never_partially_writes(self):
        with self.assertRaises(ValueError):self.domain.commit(self.task(),self.proposal(quote='没有发生过的决定'))
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],0)

    def test_revision_change_rejects_stale_write(self):
        task=self.task();self.store.db.execute('UPDATE documents SET revision=revision+1 WHERE id=?',(self.did,));self.store.db.commit()
        with self.assertRaises(Conflict):self.domain.commit(task,self.proposal())

    def test_explicit_omissions_without_silent_source_loss(self):
        extra=self.document('嗯。');task=self.task([self.did,extra])
        with self.assertRaises(ValueError):self.domain.commit(task,self.proposal())
        value=self.proposal();value['omitted_document_ids']=[extra];self.domain.commit(task,value)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM documents').fetchone()[0],2)

    def test_first_person_is_not_identity(self):
        value=self.proposal();value['memories']=[dict(kind='fact',statement='讨论维修',owner='本人',source=value['issues'][0]['sources'][0])]
        with self.assertRaises(ValueError):self.domain.commit(self.task(),value)

    def test_complete_event_contract_catches_short_feedback_lost_inside_a_handled_document(self):
        did=self.document('讨论镜头维修。录音按钮没有反应。嗯。')
        task=self.task([did]).model_copy(update={'complete_events':True})
        value={'issues':[dict(key='repair',title='讨论镜头维修',summary='讨论维修。',admission_reason='明确讨论对象。',
            sources=[dict(document_id=did,revision=1,span_ids=[0])])],
            'fragments':[dict(source=dict(document_id=did,revision=1,span_ids=[2]),reason='filler')]}
        with self.assertRaisesRegex(ValueError,'Every original span'):self.domain.commit(task,value)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],0)
        value['issues'].append(dict(key='feedback',title='录音按钮没有反应',summary='按键无反应的功能反馈。',category='feedback',card_style='compact',admission_reason='短反馈有明确操作与现象。',sources=[dict(document_id=did,revision=1,span_ids=[1])]))
        self.domain.commit(task,value)
        from heartball_day import daily_workspace
        day=daily_workspace(self.store.db,'2026-10-21')
        self.assertEqual(len(day['timeline']),2)
        self.assertEqual(next(e for e in day['timeline'] if e['category']=='feedback')['card_style'],'compact')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM agent_source_fragments').fetchone()[0],1)
        self.assertEqual(self.store.db.execute('SELECT text FROM documents WHERE id=?',(did,)).fetchone()[0],'讨论镜头维修。录音按钮没有反应。嗯。')

    def test_complete_events_cannot_double_assign_or_silently_omit_source_spans(self):
        task=self.task().model_copy(update={'complete_events':True})
        value={'issues':[],'omitted_document_ids':[self.did]}
        with self.assertRaises(ValueError):self.domain.commit(task,value)
        value={'issues':[dict(key='one',title='维修',summary='讨论维修。',admission_reason='完整事项。',sources=[dict(document_id=self.did,revision=1,span_ids=[0,1])])],
            'fragments':[dict(source=dict(document_id=self.did,revision=1,span_ids=[1]),reason='filler')]}
        with self.assertRaisesRegex(ValueError,'duplicate'):self.domain.commit(task,value)

    def test_staged_analysis_is_durable_and_invisible_until_full_atomic_commit(self):
        task=self.task().model_copy(update={'complete_events':True})
        value={'issues':[dict(key='one',title='维修讨论',summary='讨论维修安排。',admission_reason='独立事项',sources=[dict(document_id=self.did,revision=1,span_ids=[0])])]}
        receipt=self.domain.stage_analysis(task,'a',value)
        self.assertTrue(receipt['draft_only']);self.assertTrue(self.domain.stage_analysis(task,'a',value)['duplicate'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],0)
        with self.assertRaisesRegex(ValueError,'Every original span'):self.domain.commit_staged_analysis(task)
        self.assertFalse(self.domain.receipt(task.id))
        value['issues'][0]['sources'][0]['span_ids']=[0,1]
        with self.assertRaises(Conflict):self.domain.stage_analysis(task,'a',value)
        self.domain.stage_analysis(task,'a',value,receipt['digest'])
        restarted=AgentDomain(self.agent)
        self.assertEqual(restarted.read_analysis_chunk(task,'a')['proposal']['issues'][0]['sources'][0]['span_ids'],[0,1])
        first,_=restarted.commit_staged_analysis(task);again,_=restarted.commit_staged_analysis(task)
        self.assertEqual(first['event_ids'],again['event_ids']);self.assertTrue(again['duplicate'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],1)
        with self.assertRaises(Conflict):self.domain.stage_analysis(task,'late',value)

    def test_staged_analysis_rejects_bad_spans_and_changed_authority(self):
        task=self.task().model_copy(update={'complete_events':True})
        value={'issues':[dict(key='one',title='维修',summary='维修',admission_reason='完整事项',sources=[dict(document_id=self.did,revision=1,span_ids=[9])])]}
        with self.assertRaisesRegex(ValueError,'span IDs 0..1'):self.domain.stage_analysis(task,'a',value)
        value['issues'][0]['sources'][0]['span_ids']=[0,1]
        self.domain.stage_analysis(task,'a',value)
        self.store.db.execute('UPDATE documents SET revision=2 WHERE id=?',(self.did,));self.store.db.commit()
        with self.assertRaises(Conflict):self.domain.read_analysis_chunk(task,'a')
        with self.assertRaises(Conflict):self.domain.commit_staged_analysis(task)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],0)

    def test_all_spans_is_exact_explicit_selection_and_still_detects_duplicates(self):
        task=self.task().model_copy(update={'complete_events':True})
        value={'issues':[dict(key='one',title='维修与寄送',summary='完整讨论',admission_reason='明确事项',sources=[dict(document_id=self.did,revision=1,all_spans=True)])]}
        value['issues'].append(dict(value['issues'][0],key='two'))
        with self.assertRaisesRegex(ValueError,'duplicate'):self.domain.commit(task,value)
        value['issues'].pop();self.domain.stage_analysis(task,'all',value);self.domain.commit_staged_analysis(task)
        self.assertEqual(self.store.db.execute('SELECT quote FROM workspace_event_sources').fetchone()[0],'午餐讨论镜头维修。之后安排寄送。')

    def test_optional_activity_does_not_require_wrapping_unrelated_homepage_events(self):
        other=self.document('明天约见朋友。');value=self.proposal()
        value['issues'].append(dict(key='visit',title='明天约见朋友',summary='商量见面。',sources=[dict(document_id=other,revision=1,quote='明天约见朋友。')]))
        value['activities']=[dict(title='维修讨论',summary='讨论维修。',kind='conversation',issue_keys=['repair'],boundary_reason='只覆盖这次维修讨论，不包含约见事项。')]
        self.domain.commit(self.task([self.did,other]),value)
        from heartball_day import daily_workspace
        self.assertEqual(len(daily_workspace(self.store.db,'2026-10-21')['timeline']),2)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_activity_events').fetchone()[0],1)

    def test_memory_rejection_cannot_be_resurrected(self):
        value=self.proposal();value['memories']=[dict(kind='fact',statement='讨论维修',owner='unknown',source=value['issues'][0]['sources'][0])]
        receipt=self.domain.commit(self.task(),value);cid=receipt['memory_ids'][0]
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=cid,expected_version=1,action='reject'))
        with self.assertRaises(Conflict):self.domain.commit(self.task(),value)
        self.assertNotIn(cid,[m['id'] for m in self.domain.workspace()['memories']])

    def test_withdrawn_memory_can_be_recalled_as_context_but_not_a_personal_fact(self):
        value=self.proposal();value['memories']=[dict(kind='fact',statement='讨论维修',owner='unknown',source=value['issues'][0]['sources'][0])]
        cid=self.domain.commit(self.task(),value)['memory_ids'][0]
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=cid,expected_version=1,action='reject'))
        qid=str(uuid.uuid4());self.agent.ask(qid,'是否仍作为个人事实？')
        task=self.task().model_copy(update={'mode':'answer','question_id':qid})
        self.domain.commit_answer(task,'你已经付款了。',[{'id':self.did,'version':1,'quote':'午餐讨论镜头维修。'}])
        answer=self.store.db.execute('SELECT answer FROM memory_answers WHERE id=?',(qid,)).fetchone()[0]
        self.assertIn('已撤回',answer);self.assertIn('原始讨论仍保留',answer);self.assertNotIn('已经付款',answer)

    def test_corrected_fields_are_externally_visible(self):
        value=self.proposal();value['memories']=[dict(kind='fact',statement='讨论维修',owner='unknown',source=value['issues'][0]['sources'][0])]
        cid=self.domain.commit(self.task(),value)['memory_ids'][0]
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=cid,expected_version=1,action='correct',values={'owner':'其他参与者'}))
        memories=ContextReader(self.store.db).search('维修')['memories']
        self.assertEqual(memories[0]['owner'],'其他参与者');self.assertEqual(memories[0]['version'],2)

    def test_due_dates_keep_timezone_and_current_correction(self):
        value=self.proposal();value['memories']=[dict(kind='commitment',statement='讨论维修',owner='unknown',due_at='2026-10-22T10:00:00+08:00',source=value['issues'][0]['sources'][0])]
        cid=self.domain.commit(self.task(),value)['memory_ids'][0]
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=cid,expected_version=1,action='correct',values={'due_at':'2026-10-23T10:00:00+08:00'}))
        self.assertEqual(ContextReader(self.store.db).search('维修')['memories'][0]['due_at'],'2026-10-23T10:00:00+08:00')

    def test_reprocessing_does_not_duplicate_or_override_corrected_memory(self):
        value=self.proposal();value['memories']=[dict(kind='fact',statement='讨论维修',owner='unknown',source=value['issues'][0]['sources'][0])]
        cid=self.domain.commit(self.task(),value)['memory_ids'][0]
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=cid,expected_version=1,action='correct',values={'owner':'其他参与者'}))
        receipt=self.domain.commit(self.task(),value)
        self.assertEqual(receipt['memory_ids'],[cid]);self.assertEqual(self.store.db.execute('SELECT count(*) FROM claims').fetchone()[0],1)
        self.assertEqual(self.store.db.execute('SELECT owner FROM claims WHERE id=?',(cid,)).fetchone()[0],'其他参与者')

    def test_source_grant_revocation_is_enforced(self):
        row=self.store.db.execute('SELECT session_id FROM documents WHERE id=?',(self.did,)).fetchone()
        self.agent.policy(row[0],asr=False,agent=False,source_kind='live_conversation')
        with self.assertRaises(PermissionError):ContextReader(self.store.db).source(self.did)
        self.assertEqual(ContextReader(self.store.db).search('维修')['records'],[])

    def test_cross_conversation_uses_topics_not_continuation(self):
        first=self.domain.commit(self.task(),self.proposal())['event_ids'][0]
        other=self.document('接着讨论镜头维修。');value=self.proposal(other,'接着讨论镜头维修。');value['issues'][0]['continues_id']=first
        with self.assertRaises(ValueError):self.domain.commit(self.task([other]),value)
        value['issues'][0].pop('continues_id');value['topics']=[dict(key='topic',title='镜头维修',summary='继续讨论维修。',event_keys=['repair',first])]
        receipt=self.domain.commit(self.task([other]),value)
        self.assertEqual(len(receipt['topic_ids']),1)

    def test_mixed_provenance_topic_rolls_back(self):
        other=self.document('视频里的镜头维修。','background_playback')
        value=self.proposal();v2=self.proposal(other,'视频里的镜头维修。')['issues'][0];v2['key']='video';value['issues'].append(v2)
        value['topics']=[dict(key='mixed',title='维修',summary='合并',event_keys=['repair','video'])]
        with self.assertRaises(ValueError):self.domain.commit(self.task([self.did,other]),value)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],0)

    def rebuilt_relation(self):
        first=self.domain.commit(self.task(),self.proposal())['event_ids'][0]
        other=self.document('接着讨论镜头维修和寄送安排。')
        value=self.proposal(other,'接着讨论镜头维修和寄送安排。')
        value['topics']=[dict(key='topic',title='旧关系标题不可当真值',summary='旧关系摘要不可当真值',event_keys=['repair',first])]
        tid=self.domain.commit(self.task([other]),value)['topic_ids'][0]
        with self.store.transaction():self.agent.workspace.invalidate_document(self.did)
        self.domain.commit(self.task(),self.proposal())
        self.domain.commit(self.task([other]),self.proposal(other,'接着讨论镜头维修和寄送安排。'))
        return tid,other

    def test_topic_repair_requires_current_version_and_full_member_evidence(self):
        tid,other=self.rebuilt_relation();candidate=self.domain.topic_repairs()[0]
        self.assertTrue(candidate['ready']);self.assertNotIn('title',candidate);self.assertNotIn('summary',candidate)
        eids=[m['replacement_event_ids'][0] for m in candidate['members']]
        task=self.task([self.did,other]).model_copy(update={'topic_repair_only':True})
        topic=dict(key='restored',title='维修事项的两次交流',summary='当前证据仍表明同一事项。',event_keys=eids,existing_topic_id=tid)
        value={'issues':[],'topics':[topic],'omitted_document_ids':[self.did,other]}
        with self.assertRaises(Conflict):self.domain.commit(task,value)
        topic['existing_topic_version']=candidate['version']-1
        with self.assertRaises(Conflict):self.domain.commit(task,value)
        topic['existing_topic_version']=candidate['version']
        self.domain.commit(task,value)
        state=self.domain.workspace();restored=next(t for t in state['topics'] if t['id']==tid)
        self.assertEqual(set(restored['event_ids']),set(eids));self.assertFalse(self.domain.topic_repairs())

    def test_relation_candidates_do_not_leak_revoked_sources_or_match_unrelated_ranges(self):
        tid,other=self.rebuilt_relation()
        self.assertFalse(self.domain.literal_overlap('维修安排。完全不同的午餐选择。','维修安排。','完全不同的午餐选择。'))
        sid=self.store.db.execute('SELECT session_id FROM documents WHERE id=?',(other,)).fetchone()[0]
        self.agent.policy(sid,asr=False,agent=False,source_kind='live_conversation')
        self.assertFalse(self.domain.topic_repairs())

    def test_relation_only_task_cannot_reextract_personal_facts(self):
        with self.assertRaises(PermissionError):self.domain.commit(self.task().model_copy(update={'topic_repair_only':True}),self.proposal())

    def test_relation_only_task_cannot_reclassify_source_as_a_fragment(self):
        task=self.task().model_copy(update={'topic_repair_only':True})
        with self.assertRaises(PermissionError):
            self.domain.commit(task,{'issues':[], 'fragments':[dict(source=dict(document_id=self.did,revision=1,span_ids=[0]),reason='filler')]})
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM agent_source_fragments').fetchone()[0],0)

    def test_readonly_database_cannot_mutate(self):
        db=readonly_database(self.root/'heartball.sqlite')
        try:
            with self.assertRaises(Exception):db.execute('DELETE FROM documents')
        finally:db.close()

    def test_incremental_activity_retains_previous_distinct_issues(self):
        value=self.proposal();value['activities']=[dict(title='维修事项交流',summary='讨论维修与安排。',kind='conversation',issue_keys=['repair'],boundary_reason='同一次完整交流。')]
        self.domain.commit(self.task(),value)
        activity=self.domain.workspace()['activities'][0]
        extra=self.document('讨论相机保养方法。')
        value=self.proposal(extra,'讨论相机保养方法。');value['issues'][0]['key']='maintenance'
        value['activities']=[dict(title='维修与保养交流',summary='同一次交流继续讨论保养。',kind='conversation',issue_keys=['maintenance'],
            boundary_reason='有来源的同一交流延续。',continues_activity_id=activity['id'],continues_activity_version=activity['version'])]
        self.domain.commit(self.task([extra]),value)
        state=self.domain.workspace();self.assertEqual(len(state['activities']),1);self.assertEqual(len(state['activities'][0]['event_ids']),2)

    def test_correction_rebuild_keeps_valid_activity_members_and_drops_invalidated_ones(self):
        other=self.document('讨论寄送安排。');value=self.proposal()
        second=self.proposal(other,'讨论寄送安排。')['issues'][0];second['key']='shipping';value['issues'].append(second)
        value['activities']=[dict(title='维修寄送交流',summary='原活动摘要。',kind='conversation',issue_keys=['repair','shipping'],boundary_reason='同一次交流。')]
        self.domain.commit(self.task([self.did,other]),value)
        with self.store.transaction():self.agent.workspace.invalidate_document(self.did)
        preview=self.domain.workspace(preview=True,document_ids=[self.did]);activity=next(a for a in preview['activities'] if a.get('needs_rebuild'))
        self.assertEqual(activity['summary'],'')
        value=self.proposal();value['activities']=[dict(title='维修寄送交流',summary='重整后的活动。',kind='conversation',issue_keys=['repair'],boundary_reason='保留同一次交流的有效事项。',continues_activity_id=activity['id'],continues_activity_version=activity['version'])]
        self.domain.commit(self.task(),value)
        from heartball_activities import activity_projection
        mapping=activity_projection(self.store.db);active={r[0] for r in self.store.db.execute("SELECT id FROM workspace_events WHERE status='active'")}
        self.assertEqual(set(mapping),active);self.assertEqual(len({a['id'] for a in mapping.values()}),1)

    def test_revoked_existing_event_is_not_exposed_or_linked(self):
        eid=self.domain.commit(self.task(),self.proposal())['event_ids'][0]
        sid=self.store.db.execute('SELECT session_id FROM documents WHERE id=?',(self.did,)).fetchone()[0]
        self.agent.policy(sid,asr=False,agent=False,source_kind='live_conversation')
        self.assertEqual(self.domain.workspace()['events'],[])
        other=self.document('接着讨论镜头维修。');value=self.proposal(other,'接着讨论镜头维修。')
        value['topics']=[dict(key='topic',title='维修',summary='继续讨论',event_keys=['repair',eid])]
        with self.assertRaises(PermissionError):self.domain.commit(self.task([other]),value)

    def test_workspace_preview_bounds_context_without_truncating_authority_fields(self):
        issue=self.proposal()['issues'][0]
        proposal={'issues':[{**issue,'key':str(i),'summary':'来源中的讨论内容。'*140} for i in range(60)]}
        self.domain.commit(self.task(),proposal)
        full=self.domain.workspace();preview=self.domain.workspace(preview=True,document_ids=[self.did])
        self.assertGreater(len(json.dumps(full,ensure_ascii=False)),70000)
        self.assertLess(len(json.dumps(preview,ensure_ascii=False)),50000)
        self.assertTrue(preview['workspace_is_preview']);self.assertEqual(preview['available_counts']['events'],60)

    def test_import_original_message_time_duplicate_and_no_asr(self):
        export=self.root/'wechat.json';export.write_text(json.dumps({'conversation_id':'room-a','messages':[{'id':'1','timestamp':'2026-10-20 12:30:00','sender':'participant','content':'午餐讨论镜头维修。'},{'id':'1','timestamp':'2026-10-20 12:30:00','sender':'participant','content':'午餐讨论镜头维修。'}]},ensure_ascii=False))
        parsed=load_messages(export);importer=ExternalImporter(self.agent)
        first=importer.ingest(parsed,account_id='local-account',analyze=True);second=importer.ingest(parsed,account_id='local-account',analyze=True)
        self.assertEqual(first['imported_messages'],1);self.assertEqual(second['imported_messages'],0)
        doc=ContextReader(self.store.db).source(first['documents'][0])
        self.assertEqual(doc['occurred_at'],'2026-10-20T12:30:00+08:00');self.assertEqual(doc['source_kind'],'unknown')
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM jobs WHERE kind='asr_audio'").fetchone()[0],0)

    def test_import_identity_conflict_preserves_original(self):
        importer=ExternalImporter(self.agent)
        source={'messages':[{'conversation_id':'room','external_id':'m1','sender_id':'other','occurred_at':'2026-10-20T12:30:00+08:00','text':'原始内容','is_self_reported':False}],'file_sha256':'a'*64}
        first=importer.ingest(source,account_id='local',analyze=True)
        source['messages'][0]['text']='被替换内容'
        with self.assertRaises(Conflict):importer.ingest(source,account_id='local',analyze=True)
        self.assertIn('原始内容',ContextReader(self.store.db).source(first['documents'][0])['text'])

    def test_bad_time_is_not_replaced_with_import_time(self):
        export=self.root/'bad.json';export.write_text(json.dumps({'conversation_id':'room','messages':[{'sender':'x','content':'内容'}]}))
        with self.assertRaises(ValueError):load_messages(export)

    def test_import_keeps_each_message_clock_without_per_message_home_cards(self):
        export=self.root/'times.json';export.write_text(json.dumps({'conversation_id':'same-chat','messages':[
            {'id':'a','timestamp':'2026-10-20 09:00:00','sender':'p','content':'上午讨论维修。'},
            {'id':'b','timestamp':'2026-10-20 18:00:00','sender':'p','content':'晚上讨论寄送。'}]},ensure_ascii=False))
        value=ExternalImporter(self.agent).ingest(load_messages(export),account_id='me',analyze=True)
        times=[ContextReader(self.store.db).source(did)['occurred_at'] for did in value['documents']]
        self.assertEqual(times,['2026-10-20T09:00:00+08:00','2026-10-20T18:00:00+08:00'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],0)

    def test_import_analysis_permission_does_not_spill_into_another_file(self):
        importer=ExternalImporter(self.agent)
        old={'messages':[{'conversation_id':'same','external_id':'old','sender_id':'p','occurred_at':'2026-10-20T09:00:00+08:00','text':'早上内容。','is_self_reported':False}],'file_sha256':'b'*64}
        old_did=importer.ingest(old,account_id='me',analyze=False)['documents'][0]
        new={'messages':[{'conversation_id':'same','external_id':'new','sender_id':'p','occurred_at':'2026-10-20T18:00:00+08:00','text':'晚上内容。','is_self_reported':False}],'file_sha256':'c'*64}
        importer.ingest(new,account_id='me',analyze=True)
        with self.assertRaises(PermissionError):ContextReader(self.store.db).source(old_did)

    def test_txt_and_html_preserve_messages(self):
        for ext,text in [('txt','2026-10-20 12:30:00 参与者: 一段内容\n补充一行'),('html','<table><tr><td>2026-10-20 12:30:00</td><td>参与者</td><td>一段内容</td></tr></table>')]:
            export=self.root/('export.'+ext);export.write_text(text)
            value=load_messages(export,conversation_id='room')
            self.assertEqual(value['messages'][0]['sender_id'],'参与者');self.assertIn('一段内容',value['messages'][0]['text'])

    def test_stdio_mcp_is_readonly_and_returns_source(self):
        async def exercise():
            from mcp import ClientSession,StdioServerParameters
            from mcp.client.stdio import stdio_client
            command=StdioServerParameters(command=sys.executable,args=[str(Path(__file__).with_name('xinlika-mcp.py').resolve()),'--database',str(self.root/'heartball.sqlite')])
            async with stdio_client(command) as (read,write):
                async with ClientSession(read,write) as session:
                    await session.initialize();tools=await session.list_tools()
                    self.assertEqual({t.name for t in tools.tools},{'search_context','read_source'})
                    result=await session.call_tool('read_source',{'document_id':self.did})
                    self.assertFalse(result.isError);self.assertIn('2026-10-21',str(result))
        asyncio.run(exercise())

    def test_external_mcp_allowlist_and_data_boundary(self):
        fixture=self.root/'external_mcp.py'
        fixture.write_text("from mcp.server.fastmcp import FastMCP\nm=FastMCP('external-fixture')\n@m.tool()\ndef exported_message()->dict:\n return {'timestamp':'2026-10-20T12:30:00+08:00','sender':'participant','content':'a source message'}\nm.run()\n")
        async def exercise():
            from heartball_mcp import call_external
            servers={'export':{'command':sys.executable,'args':[str(fixture)],'tool_allowlist':['exported_message']}}
            with self.assertRaises(PermissionError):await call_external(servers,'export','delete_everything',{})
            value=await call_external(servers,'export','exported_message',{})
            self.assertTrue(value['instructions_are_data']);self.assertFalse(value['is_error'])
            self.assertEqual(value['structured_content']['sender'],'participant')
        asyncio.run(exercise())

    def test_internal_mcp_short_handles_commit_exact_source(self):
        task_path=self.root/'task.json';task=self.task();task_path.write_text(task.model_dump_json())
        (self.root/'.agent-runtime-owned').touch()
        async def exercise():
            from mcp import ClientSession,StdioServerParameters
            from mcp.client.stdio import stdio_client
            command=StdioServerParameters(command=sys.executable,args=[str(Path(__file__).with_name('xinlika-mcp.py').resolve()),'--database',str(self.root/'heartball.sqlite'),'--analysis-task',str(task_path)])
            async with stdio_client(command) as (read,write):
                async with ClientSession(read,write) as session:
                    await session.initialize()
                    result=await session.call_tool('read_sources',{'document_ids':['d1']})
                    self.assertFalse(result.isError);self.assertIn('source_spans',str(result));self.assertNotIn(self.did,str(result))
                    value=self.proposal();value['issues'][0]['sources']=[{'document_id':'d1','revision':1,'span_ids':[0]}]
                    result=await session.call_tool('submit_analysis',value);self.assertFalse(result.isError)
        asyncio.run(exercise())
        self.assertEqual(self.store.db.execute('SELECT document_id FROM workspace_event_sources').fetchone()[0],self.did)

    def test_staged_mcp_keeps_errors_in_task_handles_and_finalizes_exact_spans(self):
        task=self.task().model_copy(update={'complete_events':True});task_path=self.root/'staged-task.json';task_path.write_text(task.model_dump_json());(self.root/'.agent-runtime-owned').touch()
        async def exercise():
            from mcp import ClientSession,StdioServerParameters
            from mcp.client.stdio import stdio_client
            command=StdioServerParameters(command=sys.executable,args=[str(Path(__file__).with_name('xinlika-mcp.py').resolve()),'--database',str(self.root/'heartball.sqlite'),'--analysis-task',str(task_path)])
            async with stdio_client(command) as (read,write):
                async with ClientSession(read,write) as session:
                    await session.initialize()
                    value=dict(chunk_id='one',issues=[dict(key='repair',title='维修讨论',summary='维修与寄送安排。',admission_reason='完整讨论事项',sources=[dict(document_id='d1',revision=1,span_ids=[7])])])
                    result=await session.call_tool('stage_analysis',value)
                    self.assertTrue(result.isError);self.assertIn('d1',str(result));self.assertNotIn(self.did,str(result))
                    value['issues'][0]['sources'][0]['span_ids']=[0,1]
                    result=await session.call_tool('stage_analysis',value);self.assertFalse(result.isError)
                    result=await session.call_tool('commit_staged_analysis',{});self.assertFalse(result.isError)
        asyncio.run(exercise())
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM workspace_events').fetchone()[0],1)

    def test_answer_mcp_requires_version_and_selects_literal_spans(self):
        qid=str(uuid.uuid4());self.agent.ask(qid,'讨论了什么？')
        task=self.task().model_copy(update={'mode':'answer','question_id':qid})
        task_path=self.root/'answer-task.json';task_path.write_text(task.model_dump_json());(self.root/'.agent-runtime-owned').touch()
        async def exercise():
            from mcp import ClientSession,StdioServerParameters
            from mcp.client.stdio import stdio_client
            params=StdioServerParameters(command=sys.executable,args=[str(Path(__file__).with_name('xinlika-mcp.py').resolve()),'--database',str(self.root/'heartball.sqlite'),'--analysis-task',str(task_path)])
            async with stdio_client(params) as (read,write):
                async with ClientSession(read,write) as session:
                    await session.initialize()
                    result=await session.call_tool('submit_answer',{'answer':'讨论维修。','refs':[{'id':'d1'}]})
                    self.assertTrue(result.isError);self.assertIn('version',str(result))
                    result=await session.call_tool('submit_answer',{'answer':'讨论维修。','refs':[{'id':'d1','version':1,'span_ids':[0]}]})
                    self.assertFalse(result.isError)
        asyncio.run(exercise())
        row=self.store.db.execute('SELECT refs,status FROM memory_answers WHERE id=?',(qid,)).fetchone()
        self.assertEqual(row['status'],'ready');self.assertEqual(json.loads(row['refs'])[0]['quote'],'午餐讨论镜头维修。')


if __name__=='__main__':unittest.main()

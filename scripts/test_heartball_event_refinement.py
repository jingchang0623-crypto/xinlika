"""Atomic source reassignment/correction tests. Real-quality acceptance is separate."""
import json
import tempfile
import unittest
import uuid
from types import SimpleNamespace
from pathlib import Path
from heartball_store import Store, Conflict
from heartball_agent_store import AgentStore
from heartball_event_refinement import EventRefinementStore, validate_partition, source_atoms
from heartball_day import daily_workspace


class RefinementTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(Path(self.temp.name))
        self.agent=AgentStore(self.store);self.db=self.store.db;self.r=EventRefinementStore(self.agent)
        self.sid=str(uuid.uuid4());self.store.create_session(self.sid);self.store.update_session(self.sid,status='completed')
        self.agent.policy(self.sid,asr=False,agent=True,source_kind='unknown')

    def tearDown(self):self.db.close();self.temp.cleanup()

    def add(self,text,minute=0,kind='ambient'):
        d=dict(id=str(uuid.uuid4()),input_key=str(uuid.uuid4()),session_id=self.sid,kind=kind,text=text,evidence=[],source_kind='unknown',occurred_at=f'2026-10-21T14:{minute:02}:00+00:00',boundary_quality='batch_exact',revision=1)
        self.agent.commit_document(d,dict(title='旧标题',summary='旧摘要',claims=[]))
        ctx=self.agent.workspace.context(d)
        self.agent.workspace.persist(d,{'events':[dict(title='旧标题',summary='旧摘要',quote=text)]},ctx)
        return d,dict(self.db.execute('SELECT e.* FROM workspace_events e JOIN workspace_event_sources s ON s.event_id=e.id WHERE s.document_id=?',(d['id'],)).fetchone())

    def test_split_wrong_envelope_merge_same_matter_and_retain_fragment(self):
        d,a=self.add('镜头偏色。买菜。镜头先校准。2个。')
        b,be=self.add('镜头再出样。',minute=1)
        focus,fe=self.add('重点独立保留。',minute=2,kind='focus')
        ctx=self.r.next_context(self.sid)
        self.assertNotIn(fe['id'],{e['id'] for e in ctx['events']})
        atoms=ctx['atoms'];indices=lambda s:[x['index'] for x in atoms if s in x['text']]
        value={'events':[dict(title='镜头校准',summary='偏色、校准后再出样',atoms=indices('镜头')),dict(title='买菜',summary='买菜',atoms=indices('买菜'))],
               'fragments':[dict(atoms=indices('2个'),reason='incomplete_reference')]}
        self.r.persist(ctx['window_key'],value,ctx)
        merged=self.db.execute("SELECT * FROM workspace_events WHERE title='镜头校准' AND status='active'").fetchone()
        quotes=[r[0] for r in self.db.execute('SELECT quote FROM workspace_event_sources WHERE event_id=?',(merged['id'],))]
        self.assertEqual(len(quotes),3);self.assertTrue(all('买菜' not in q and '2个' not in q for q in quotes))
        self.assertEqual(merged['occurred_at'],d['occurred_at'])
        self.assertEqual(next(e for e in self.agent.workspace.state()['events'] if e['id']==merged['id'])['occurred_at'],d['occurred_at'])
        self.assertEqual(self.db.execute('SELECT text FROM documents WHERE id=?',(d['id'],)).fetchone()[0],d['text'])
        shown=[e for g in daily_workspace(self.db,'2026-10-21')['groups'] for e in g['events']]
        self.assertEqual({e['title'] for e in shown},{'镜头校准','买菜','旧标题'})
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM workspace_events WHERE status='fragment'").fetchone()[0],1)
        self.assertIsNone(self.r.next_context(self.sid))
        self.r.persist(ctx['window_key'],value,ctx) # exactly-once commit
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM workspace_refinement_runs').fetchone()[0],1)

    def test_missing_duplicate_or_invented_atoms_do_not_mutate_old_projection(self):
        _,event=self.add('第一件事。第二件事。');ctx=self.r.next_context(self.sid)
        for ids in ([0],[0,0,1],[0,1,999]):
            with self.assertRaises(ValueError):self.r.persist('invalid',{'events':[dict(title='坏结果',summary='坏结果',atoms=ids)]},ctx)
            self.assertEqual(self.db.execute('SELECT status FROM workspace_events WHERE id=?',(event['id'],)).fetchone()[0],'active')
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM workspace_refinement_runs').fetchone()[0],0)

    def test_source_revision_or_event_version_conflict_rolls_back(self):
        doc,event=self.add('吃药了。');ctx=self.r.next_context(self.sid)
        value={'events':[dict(title='吃药',summary='吃药了',atoms=[a['index'] for a in ctx['atoms']])]}
        self.db.execute('UPDATE workspace_events SET version=version+1 WHERE id=?',(event['id'],));self.db.commit()
        with self.assertRaises(Conflict):self.r.persist('stale',value,ctx)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM workspace_events').fetchone()[0],1)
        ctx=self.r.next_context(self.sid);self.db.execute('UPDATE documents SET revision=revision+1 WHERE id=?',(doc['id'],));self.db.commit()
        with self.assertRaises(Conflict):self.r.persist('stale-doc',value,ctx)

    def test_fragment_can_rejoin_when_new_context_explains_it_and_focus_not_hidden(self):
        _,old=self.add('两个。');ctx=self.r.next_context(self.sid)
        self.r.persist(ctx['window_key'],{'events':[],'fragments':[dict(atoms=[0],reason='incomplete_reference')]},ctx)
        self.add('刚才说的是两个相机镜头。',minute=1)
        ctx=self.r.next_context(self.sid)
        self.assertEqual(len(ctx['events']),2)
        self.r.persist(ctx['window_key'],{'events':[dict(title='相机镜头数量',summary='两个镜头',atoms=[a['index'] for a in ctx['atoms']])]},ctx)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM workspace_events WHERE status='active'").fetchone()[0],1)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM workspace_events WHERE status='fragment'").fetchone()[0],0)

    def test_correction_invalidates_refined_event_not_original_text(self):
        doc,_=self.add('镜头先校准。');ctx=self.r.next_context(self.sid)
        self.r.persist(ctx['window_key'],{'events':[dict(title='镜头校准',summary='镜头先校准',atoms=[a['index'] for a in ctx['atoms']])]},ctx)
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=doc['id'],expected_version=1,action='correct_document',values={'text':'镜头不用校准。'}))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM workspace_events WHERE status='active'").fetchone()[0],0)
        self.assertEqual(self.db.execute('SELECT text FROM documents WHERE id=?',(doc['id'],)).fetchone()[0],doc['text'])

    def test_split_parent_topic_is_not_blindly_inherited_by_unrelated_child(self):
        _,event=self.add('镜头偏色。买菜。')
        self.db.execute("INSERT INTO workspace_topics VALUES('camera','相机改进','相机改进','unknown','active',1,'now')")
        self.db.execute("INSERT INTO workspace_event_topics VALUES(?,'camera')",(event['id'],));self.db.commit()
        ctx=self.r.next_context(self.sid)
        self.r.persist(ctx['window_key'],{'events':[dict(title='镜头',summary='镜头偏色',atoms=[0]),dict(title='买菜',summary='买菜',atoms=[1])]},ctx)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM workspace_all_event_topics l JOIN workspace_events e ON e.id=l.event_id WHERE e.status='active'").fetchone()[0],0)

    def test_consolidation_preserves_the_selected_occurrence_of_a_repeated_quote(self):
        from heartball_event_merge import EventMergeStore
        doc,_=self.add('镜头。买菜。镜头。')
        self.add('确认镜头。',minute=1);ctx=self.r.next_context(self.sid)
        value={'events':[dict(title='第一次镜头',summary='第一次',atoms=[0]),dict(title='买菜',summary='买菜',atoms=[1]),dict(title='后来镜头',summary='后来镜头',atoms=[2]),dict(title='确认',summary='确认镜头',atoms=[3])]}
        self.r.persist(ctx['window_key'],value,ctx)
        m=EventMergeStore(self.agent);context=m.context(self.sid)
        chosen=[e for e in context['events'] if e['title'] in {'后来镜头','确认'}]
        m.persist('repeat-quote',{'merges':[dict(title='后来确认镜头',summary='镜头',events=[dict(id=e['id'],version=e['version']) for e in chosen])]},context)
        row=self.db.execute("select id from workspace_events where title='后来确认镜头'").fetchone()
        spans=list(self.db.execute('select start_char,end_char from workspace_refined_ranges where event_id=? and document_id=?',(row[0],doc['id'])))
        self.assertEqual([tuple(x) for x in spans],[(6,9)])

    def test_corrected_fragment_is_invalidated_and_never_blocks_next_window(self):
        doc,_=self.add('两个。');ctx=self.r.next_context(self.sid)
        self.r.persist(ctx['window_key'],{'fragments':[dict(atoms=[0],reason='incomplete_reference')]},ctx)
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=doc['id'],expected_version=1,action='correct_document',values={'text':'两个镜头。'}))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM workspace_events WHERE status='fragment'").fetchone()[0],0)
        self.add('去买菜。',minute=1)
        self.assertIsNotNone(self.r.next_context(self.sid))

    def test_deployment_does_not_rewrite_all_history_and_new_versions_are_eligible(self):
        _,old=self.add('旧记录。');self.r.prime_history()
        self.assertIsNone(self.r.next_context(self.sid))
        self.r.request_reaudit(self.sid);self.assertIsNotNone(self.r.next_context(self.sid))
        self.db.execute('INSERT OR IGNORE INTO workspace_refinement_coverage VALUES(?,?)',(old['id'],old['version']));self.db.commit()
        self.db.execute("UPDATE workspace_events SET version=version+1,summary='新内容' WHERE id=?",(old['id'],));self.db.commit()
        self.assertIsNotNone(self.r.next_context(self.sid))

    def test_topic_metadata_version_does_not_start_another_content_rewrite(self):
        _,event=self.add('镜头校准。');ctx=self.r.next_context(self.sid)
        self.r.persist(ctx['window_key'],{'events':[dict(title='镜头校准',summary='镜头校准',atoms=[0])]},ctx)
        self.db.execute("UPDATE workspace_events SET version=version+1 WHERE status='active'");self.db.commit()
        self.assertIsNone(self.r.next_context(self.sid))

    def test_legacy_worker_cannot_remerge_reviewed_split_during_rolling_upgrade(self):
        from heartball_event_merge import EventMergeStore
        self.add('镜头偏色。买菜。');ctx=self.r.next_context(self.sid)
        self.r.persist(ctx['window_key'],{'events':[dict(title='镜头',summary='偏色',atoms=[0]),dict(title='买菜',summary='买菜',atoms=[1])]},ctx)
        legacy=EventMergeStore(self.agent)
        self.assertIsNone(legacy.next_context(self.sid))
        self.db.execute("UPDATE workspace_events SET version=version+1 WHERE status='active'");self.db.commit()
        self.assertIsNone(legacy.next_context(self.sid))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM workspace_events WHERE status='active'").fetchone()[0],2)

    def test_exhausted_quality_review_retains_sources_and_advances_without_releasing_same_job(self):
        from heartball_processing import Processor
        from heartball_event_refinement import SourceRefinementQualityError
        for i in range(12):self.add('明确事项'+str(i)+'。',minute=i)
        class Model:
            supports_refinement=True
            def consolidate_events(self,ctx):raise AssertionError('Not the legacy merge path')
            def refine_events(self,ctx):raise SourceRefinementQualityError('Bounded proposals exhausted')
        p=Processor(self.store,Model())
        try:
            p.event_merges.refinement.request_reaudit(self.sid)
            ctx=p.event_merges.next_context(self.sid)
            self.assertTrue(p.tick(lane='reconcile'))
            row=self.db.execute("SELECT * FROM jobs WHERE input_key=?",(ctx['window_key'],)).fetchone()
            self.assertEqual(row['status'],'blocked_quality_review');self.assertEqual(row['attempts'],1)
            later=p.event_merges.next_context(self.sid)
            self.assertIsNotNone(later)
            self.assertTrue({e['id'] for e in ctx['events']}.isdisjoint({e['id'] for e in later['events']}))
            self.assertEqual(self.db.execute("SELECT COUNT(*) FROM workspace_events WHERE status='active'").fetchone()[0],12)
        finally:p.close()

    def test_terminal_window_does_not_block_later_events_and_explicit_reaudit_can_retry(self):
        for i in range(12):self.add('明确事项'+str(i)+'。',minute=i)
        ctx=self.r.next_context(self.sid)
        self.db.execute("INSERT INTO jobs(id,kind,input_key,status,payload) VALUES(?,'event_consolidate',?,'failed',?)",(str(uuid.uuid4()),ctx['window_key'],json.dumps({'session_id':self.sid,'merge_context':ctx})));self.db.commit()
        blocked={e['id'] for e in ctx['events']};next_ctx=self.r.next_context(self.sid)
        self.assertIsNotNone(next_ctx);self.assertTrue(blocked.isdisjoint({e['id'] for e in next_ctx['events']}))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM workspace_events WHERE status='active'").fetchone()[0],12)
        self.r.request_reaudit(self.sid);self.assertNotEqual(self.r.next_context(self.sid)['window_key'],ctx['window_key'])

    def test_atoms_keep_referents_and_all_punctuation_without_envelopes(self):
        text='这是相机，镜头需要先校准。\n'+'这是一个很长的句子，'*80+'结束！'
        atoms=source_atoms(text)
        self.assertEqual(''.join(atoms),text)
        self.assertEqual(atoms[0],'这是相机，镜头需要先校准。')
        self.assertLessEqual(max(map(len,atoms)),160)

    def test_failed_broad_window_is_revisited_once_in_smaller_scopes_after_later_work(self):
        for i in range(12):self.add('明确事项'+str(i)+'。',minute=i)
        original=self.r.next_context(self.sid)
        def block(ctx):
            self.db.execute("INSERT INTO jobs(id,kind,input_key,status,payload) VALUES(?,'event_consolidate',?,'blocked_quality_review',?)",(str(uuid.uuid4()),ctx['window_key'],json.dumps({'session_id':self.sid,'merge_context':ctx})));self.db.commit()
        block(original)
        later=self.r.next_context(self.sid)
        self.r.persist(later['window_key'],{'events':[dict(title='后续明确事项',summary='后续事项',atoms=[a['index'] for a in later['atoms']])]},later)
        narrow=self.r.next_context(self.sid)
        self.assertEqual(len(narrow['events']),1)
        self.assertEqual(narrow['scope'],'single_parent_after_rejected_window')
        self.assertIn(narrow['events'][0]['id'],{e['id'] for e in original['events']})
        block(narrow)
        next_narrow=self.r.next_context(self.sid)
        self.assertEqual(len(next_narrow['events']),1)
        self.assertNotEqual(next_narrow['events'][0]['id'],narrow['events'][0]['id'])

    def test_split_review_denial_cannot_rewrite_a_coherent_parent(self):
        from heartball_processing import ModelAdapter
        _,event=self.add('讨论作业速度。讨论激励效果。');ctx=self.r.next_context(self.sid)
        model=ModelAdapter.__new__(ModelAdapter);model.event_review_model='fixture'
        model.extra_body={}
        def complete(**kwargs):
            return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps({'decisions':[dict(index=0,needed=False,reason='同一次辅导讨论的不同细节')]})))])
        model.client=SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=complete)))
        value={'events':[dict(title='速度',summary='速度',atoms=[0]),dict(title='效果',summary='效果',atoms=[1])]}
        with self.assertRaises(ValueError):model.review_source_splits(value,ctx)
        self.assertEqual(self.db.execute('SELECT status FROM workspace_events WHERE id=?',(event['id'],)).fetchone()[0],'active')

    def test_refinement_requires_explicit_provider_enablement(self):
        from heartball_processing import ModelAdapter
        cfg={'base_url':'http://127.0.0.1:1/v1','api_key':'fixture','model':'fixture'}
        self.assertFalse(ModelAdapter(cfg).supports_refinement)
        self.assertTrue(ModelAdapter({**cfg,'source_refinement_enabled':True}).supports_refinement)

    def test_one_valid_split_does_not_authorize_splitting_the_coherent_remainder(self):
        from heartball_processing import ModelAdapter
        self.add('讨论作业速度。讨论激励效果。独立的寄件安排。');ctx=self.r.next_context(self.sid)
        model=ModelAdapter({'base_url':'http://127.0.0.1:1/v1','api_key':'fixture','model':'fixture'})
        response={'decisions':[dict(index=0,needed=True,keep_together=[[0,1],[2]],reason='寄件独立，辅导方法及效果仍是同一讨论')]}
        def complete(**kwargs):
            return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps(response)))])
        model.client=SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=complete)))
        value={'events':[dict(title=str(i),summary=str(i),atoms=[i]) for i in range(3)]}
        with self.assertRaisesRegex(ValueError,'One justified split'):model.review_source_splits(value,ctx)

    def test_reasoning_writer_and_independent_review_have_separate_request_options(self):
        from heartball_processing import ModelAdapter
        cfg={'base_url':'http://127.0.0.1:1/v1','api_key':'fixture','model':'writer',
             'event_extra_body':{'thinking':{'type':'enabled'}},
             'event_review_extra_body':{'thinking':{'type':'disabled'}},'event_review_max_tokens':3500}
        model=ModelAdapter(cfg)
        _,event=self.add('镜头偏色。买菜。');ctx=self.r.next_context(self.sid)
        value={'events':[dict(title='镜头',summary='镜头偏色',atoms=[0]),dict(title='买菜',summary='买菜',atoms=[1])],'fragments':[]}
        replies=[value,{'decisions':[dict(index=0,needed=True,reason='独立事项')]},{'ok':True,'issues':[]}]
        calls=[]
        def complete(**kwargs):
            calls.append(kwargs)
            return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps(replies.pop(0))))])
        model.client=SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=complete)))
        self.assertEqual(model.refine_events(ctx),value)
        self.assertEqual([c['extra_body']['thinking']['type'] for c in calls],['enabled','disabled','disabled'])
        self.assertEqual([c['max_tokens'] for c in calls[1:]],[3500,3500])
        self.assertTrue(all('json' in json.dumps(c['messages']).lower() for c in calls))


if __name__=='__main__':unittest.main()

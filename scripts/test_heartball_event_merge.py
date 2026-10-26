"""Semantic event boundaries vs transport batches; no real model, audio, or recorder."""
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from heartball_store import Store, Conflict
from heartball_processing import Processor


class EventConsolidation(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(Path(self.temp.name));self.p=Processor(self.store);self.agent=self.p.agent
        self.sid=str(uuid.uuid4());self.store.create_session(self.sid);self.store.update_session(self.sid,status='completed')
        self.agent.policy(self.sid,asr=False,agent=True,source_kind='verified_text')

    def tearDown(self):self.p.close();self.store.db.close();self.temp.cleanup()

    def doc(self,text,when='2026-10-21T06:00:00+00:00',kind='ambient'):
        d=dict(id=str(uuid.uuid4()),input_key=str(uuid.uuid4()),session_id=self.sid,kind=kind,text=text,evidence=[],source_kind='verified_text',occurred_at=when,boundary_quality='batch_exact',revision=1)
        self.agent.commit_document(d,dict(title=text,summary=text,claims=[]));return d

    def event(self,doc,quote=None):
        context=self.agent.workspace.context(doc);key=context['run_key']
        # A source document can contain multiple distinct events.
        if self.store.db.execute('SELECT 1 FROM workspace_organization_runs WHERE run_key=?',(key,)).fetchone():
            self.store.db.execute('DELETE FROM workspace_organization_runs WHERE run_key=?',(key,));self.store.db.commit()
        self.agent.workspace.persist(doc,{'events':[dict(title='候选',summary=quote or doc['text'],quote=quote or doc['text'])]},context)
        return next(e for e in self.agent.state()['events'] if e['sources'][0]['document_id']==doc['id'])

    def merge(self,*events):return {'merges':[dict(title='同一事项',summary='现状、原因及下一步。',events=[{'id':e['id'],'version':e['version']} for e in events])]}

    def test_same_matter_across_minutes_merges_without_collapsing_different_matter(self):
        d1=self.doc('讨论镜头偏色');a=self.event(d1)
        d2=self.doc('确认镜头偏色原因',when='2026-10-21T06:01:00+00:00');b=self.event(d2)
        other=self.event(self.doc('讨论另一份合同',when='2026-10-21T06:01:30+00:00'))
        ctx=self.p.event_merges.context(self.sid);self.p.event_merges.persist('run',self.merge(a,b),ctx)
        state=self.agent.state();self.assertEqual(len(state['events']),2)
        merged=next(e for e in state['events'] if e['title']=='同一事项')
        self.assertEqual(merged['occurred_at'],d1['occurred_at']);self.assertEqual(len(merged['sources']),2)
        self.assertIn(other['id'],{e['id'] for e in state['events']})
        self.assertEqual({d['text'] for d in state['documents']},{d1['text'],d2['text'],'讨论另一份合同'})
        self.p.event_merges.persist('run',self.merge(a,b),ctx);self.assertEqual(len(self.agent.state()['events']),2)

    def test_stale_or_repeated_sources_do_not_partially_hide_events(self):
        a=self.event(self.doc('片段一'));b=self.event(self.doc('片段二'));ctx=self.p.event_merges.context(self.sid)
        with self.assertRaises(Conflict):self.p.event_merges.persist('bad',self.merge(a,a),ctx)
        self.assertEqual(len(self.agent.state()['events']),2)
        self.store.db.execute('UPDATE workspace_events SET version=2 WHERE id=?',(a['id'],));self.store.db.commit()
        with self.assertRaises(Conflict):self.p.event_merges.persist('stale',self.merge(a,b),ctx)
        self.assertEqual(len(self.agent.state()['events']),2)

    def test_same_topic_later_return_is_not_one_event_across_an_independent_discussion(self):
        early=self.event(self.doc('叮嘱孩子早睡护眼',when='2026-10-21T14:09:00+00:00'))
        other=self.event(self.doc('讨论运营商合作方案',when='2026-10-21T14:30:00+00:00'))
        later=self.event(self.doc('再次叮嘱早点睡保护眼睛',when='2026-10-21T15:25:00+00:00'))
        ctx=self.p.event_merges.context(self.sid)
        with self.assertRaises(Conflict):self.p.event_merges.persist('crossed',self.merge(early,later),ctx)
        self.assertEqual(len(self.agent.state()['events']),3)
        class Model:
            def consolidate_events(model,context):return self.merge(early,later)
        self.p.model=Model()
        self.assertEqual(self.p._merge_events({'session_id':self.sid,'merge_context':ctx})['event_merges']['merges'],[])

    def test_long_continuous_discussion_is_not_split_by_total_duration(self):
        early=self.event(self.doc('讨论方案第一部分',when='2026-10-21T14:00:00+00:00'))
        later=self.event(self.doc('继续讨论同一方案',when='2026-10-21T16:30:00+00:00'))
        self.p.event_merges.persist('long',self.merge(early,later),self.p.event_merges.context(self.sid))
        self.assertEqual(len(self.agent.state()['events']),1)

    def test_one_document_sources_are_literal_envelope_and_focus_stays_independent(self):
        d=self.doc('第一段原句。中间另一话题。最后回到原句。')
        context=self.agent.workspace.context(d)
        self.agent.workspace.persist(d,{'events':[dict(title='一',summary='一',quote='第一段原句。'),dict(title='二',summary='二',quote='最后回到原句。')]},context)
        events=self.agent.state()['events'];focus=self.event(self.doc('独立重点。',kind='focus'))
        ctx=self.p.event_merges.context(self.sid);self.assertNotIn(focus['id'],{e['id'] for e in ctx['events']})
        self.p.event_merges.persist('envelope',self.merge(*events),ctx)
        merged=next(e for e in self.agent.state()['events'] if e['kind']!='focus')
        self.assertEqual({s['quote'] for s in merged['sources']},{'第一段原句。','最后回到原句。'})
        self.assertTrue(all('中间另一话题' not in s['quote'] for s in merged['sources']))
        self.assertEqual(len(self.agent.state()['events']),2)

    def test_source_correction_invalidates_merged_event_and_preserves_other_audio_sources(self):
        d=self.doc('原来的现状');a=self.event(d);b=self.event(self.doc('后续原因'))
        self.p.event_merges.persist('correct',self.merge(a,b),self.p.event_merges.context(self.sid))
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=d['id'],expected_version=1,action='correct_document',values={'text':'纠正后的现状'}))
        self.assertEqual(self.agent.state()['events'],[])
        self.assertEqual(self.store.db.execute('SELECT text FROM documents WHERE id=?',(d['id'],)).fetchone()[0],'原来的现状')

    def test_checkpoint_reuses_model_result_after_save_failure(self):
        a=self.event(self.doc('原来的现状'));b=self.event(self.doc('补充原因'));value=self.merge(a,b)
        class Model:
            calls=0
            def consolidate_events(self,context):self.calls+=1;return value
        self.p.model=Model();payload={'session_id':self.sid,'run_key':'recover'};job={'id':str(uuid.uuid4()),'attempts':1}
        save=self.p.event_merges.persist;self.p.event_merges.persist=lambda *args:(_ for _ in ()).throw(OSError('fixture'))
        with self.assertRaises(OSError):self.p.run_merges(payload,job)
        self.p.event_merges.persist=save;self.p.run_merges(payload,job)
        self.assertEqual(self.p.model.calls,1);self.assertEqual(len(self.agent.state()['events']),1)

    def test_merge_retains_multiple_auto_topic_memberships_and_correction_invalidates_all(self):
        a=self.event(self.doc('运营商合作的现状'));b=self.event(self.doc('运营商合作的定价方案'))
        topics=['topic-a','topic-b']
        for event,tid in zip([a,b],topics):
            self.store.db.execute("INSERT INTO workspace_topics VALUES(?,?,?,'conversation','active',1,'2026-10-21')",(tid,tid,'原有主题内容'))
            self.store.db.execute('INSERT INTO workspace_event_topics VALUES(?,?)',(event['id'],tid))
        self.store.db.commit()
        self.p.event_merges.persist('multi-topic',self.merge(a,b),self.p.event_merges.context(self.sid))
        state=self.agent.state();merged=next(e for e in state['events'] if e['title']=='同一事项')
        self.assertEqual({t['id'] for t in state['topics']},set(topics))
        self.assertTrue(all(merged['id'] in t['event_ids'] for t in state['topics']))
        self.assertEqual(len(merged['sources']),2)
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=merged['sources'][0]['document_id'],expected_version=1,action='correct_document',values={'text':'纠正合作的现状'}))
        self.assertTrue(all(self.store.db.execute('SELECT status FROM workspace_topics WHERE id=?',(t,)).fetchone()[0]=='invalidated' for t in topics))

    def test_transcript_only_keeps_audio_sources_and_cannot_hide_focus_or_overlap_merge(self):
        noise=self.event(self.doc('那个'));a=self.event(self.doc('讨论预算'));b=self.event(self.doc('预算的原因'))
        ctx=self.p.event_merges.context(self.sid);ctx['events'].append(noise)
        value={**self.merge(a,b),'transcript_only':[dict(id=noise['id'],version=1,reason='无独立事项的语气片段')]}
        self.p.event_merges.persist('retained',value,ctx)
        self.assertEqual(self.store.db.execute('SELECT status FROM workspace_events WHERE id=?',(noise['id'],)).fetchone()[0],'transcript_only')
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM documents').fetchone()[0],3)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM workspace_event_sources WHERE event_id=?',(noise['id'],)).fetchone()[0],1)
        self.assertEqual(len(self.agent.state()['events']),1)
        focus=self.event(self.doc('喝水了',kind='focus'))
        with self.assertRaises(Conflict):self.p.event_merges.persist('invalid-focus',{'merges':[],'transcript_only':[dict(id=focus['id'],version=1,reason='不能隐藏重点')]},{'session_id':self.sid,'events':[focus]})
        self.assertEqual(self.store.db.execute('SELECT status FROM workspace_events WHERE id=?',(focus['id'],)).fetchone()[0],'active')

    def test_model_cannot_discard_useful_speech_for_identity_or_no_merge(self):
        a=self.event(self.doc('教育行业盈利观察与合作进展'));b=self.event(self.doc('家庭作息与就医安排'))
        ctx=self.p.event_merges.context(self.sid)
        self.p.event_merges.persist('bad-filter',{'merges':[],'transcript_only':[dict(id=e['id'],version=1,reason='无同事项补充，身份未确认') for e in [a,b]]},ctx)
        self.assertEqual({e['id'] for e in self.agent.state()['events']},{a['id'],b['id']})

    def test_unmodified_merged_result_is_not_recursively_collapsed_and_trial_projection_can_recover(self):
        a=self.event(self.doc('合作的现状'));b=self.event(self.doc('合作的原因'));other=self.event(self.doc('另一个具体事项'))
        ctx=self.p.event_merges.next_context(self.sid)
        self.p.event_merges.persist(ctx['window_key'],self.merge(a,b),ctx)
        self.assertIsNone(self.p.event_merges.next_context(self.sid))
        # A previous trial version is reversible without changing source rows.
        self.store.db.execute("DELETE FROM workspace_merge_migrations WHERE key='reviewed-evidence-v7'")
        self.store.db.execute("UPDATE workspace_event_merge_parents SET run_key='trial:window-v6:test'")
        self.store.db.commit();self.p.event_merges.repair_unsafe_projection()
        self.assertEqual({e['id'] for e in self.agent.state()['events']},{a['id'],b['id'],other['id']})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM documents').fetchone()[0],3)
        self.p.event_merges.repair_unsafe_projection()
        self.assertEqual(len(self.agent.state()['events']),3)
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=a['sources'][0]['document_id'],expected_version=1,action='correct_document',values={'text':'纠正合作现状'}))
        self.assertEqual({e['id'] for e in self.agent.state()['events']},{b['id'],other['id']})

    def test_pending_contexts_coalesce_and_completed_windows_cover_full_history(self):
        self.store.update_session(self.sid,status='recording')
        self.event(self.doc('第一批'));self.assertFalse(self.p.event_merges.request(self.sid,force=False))
        self.event(self.doc('第二批'));self.assertFalse(self.p.event_merges.request(self.sid,force=False))
        self.event(self.doc('第三批'));self.assertTrue(self.p.event_merges.request(self.sid,force=False))
        self.event(self.doc('第四批'));self.assertTrue(self.p.event_merges.request(self.sid,force=False))
        self.assertFalse(self.p.event_merges.request(self.sid,force=False))
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM jobs WHERE kind='event_consolidate' AND status='queued'").fetchone()[0],1)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM jobs WHERE kind='event_consolidate' AND status='superseded'").fetchone()[0],1)
        job=self.agent.claim_job('test',kinds={'event_consolidate'})
        self.event(self.doc('第五批'))
        self.assertFalse(self.p.event_merges.request(self.sid))
        self.assertEqual(self.store.db.execute('SELECT status FROM jobs WHERE id=?',(job['id'],)).fetchone()[0],'running')
        self.agent.job_done(job)
        for i in range(30):self.event(self.doc('新讨论'+str(i),when=f'2026-10-21T07:{i:02}:00+00:00'))
        seen=set()
        for i in range(10):
            ctx=self.p.event_merges.next_context(self.sid)
            if ctx is None:break
            self.assertLessEqual(len(ctx['events']),16)
            seen.update(e['id'] for e in ctx['events'])
            self.p.event_merges.persist(ctx['window_key'],{'merges':[]},ctx)
        self.assertEqual(seen,{e['id'] for e in self.p.event_merges.context(self.sid)['events']})
        self.assertIsNone(self.p.event_merges.next_context(self.sid))

if __name__=='__main__':unittest.main()

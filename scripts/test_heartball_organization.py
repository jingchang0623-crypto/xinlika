"""Semantic boundaries, provenance, correction and checkpoint tests; deterministic models, no ASR."""
import json
import unittest
import uuid
import test_heartball_processing as fixtures
from heartball_store import Conflict
from heartball_processing import resolve_events, Organization, source_spans


class SemanticModel(fixtures.FakeModel):
    supports_organization=True
    def organize(self,doc,context):
        topic=next((t for t in context['topics'] if t['title']=='青苔相机'),None)
        previous=context['previous_events']
        return {'events':[{'title':'相机计划讨论','summary':doc['text'],'quote':doc['text'],
            'continues_id':previous[0]['id'] if previous and doc['kind']!='focus' else None,
            'topic_id':topic['id'] if topic else None,'topic_title':'' if topic else '青苔相机','topic_summary':doc['text']}]}
    def extract(self,doc,memory):
        self.calls+=1
        return {'title':'相机讨论','summary':doc['text'],'claims':[],**self.organize(doc,doc['organization_context'])}
    def answer(self,question,memory):
        event=next(m for m in memory if m['record_type']=='topic')
        return {'answer':event['statement'],'refs':[{'id':event['id'],'version':event['version']}]}


class OrganizationTests(fixtures.ProcessingTests):
    def test_cross_conversation_model_continuation_stays_a_standalone_event(self):
        value={'events':[{'title':'独立事项','summary':'真实内容','quote':'真实内容','continues_id':'other-session-event'}]}
        resolved=resolve_events(value,{'text':'真实内容','kind':'ambient'}, {'previous_events':[]})
        self.assertIsNone(resolved['events'][0]['continues_id'])
        self.assertEqual(resolved['events'][0]['quote'],'真实内容')
    # Reuse only the fixture helpers, not the parent tests for another model contract.
    def setUp(self):
        super().setUp();self.processor.model=SemanticModel();self.model=self.processor.model
    def session(self,source='verified_text',**kwargs):
        sid=super().session(source,**kwargs);self.store.update_session(sid,status='completed');return sid
    def add(self,sid,text,kind='ambient'):
        doc=dict(id=str(uuid.uuid4()),input_key=str(uuid.uuid4()),session_id=sid,kind=kind,text=text,evidence=[],source_kind='verified_text',occurred_at=None,boundary_quality='batch_exact')
        self.processor.run_document(doc,str(uuid.uuid4()));return doc
    def test_verified_physical_segments_share_context_but_unrelated_recordings_do_not(self):
        from heartball_mobile import MobileIngest
        MobileIngest(self.store,self.agent)
        root=self.session('verified_text');child=self.session('verified_text');other=self.session('verified_text')
        self.store.db.execute('insert into mobile_card_segments values(?,?,?,?,?,?,?)',(root,'note20261021-130000.opus',child,'note20261021-100000.opus',21602000,'a'*64,'2026-10-21T13:00:00+08:00'));self.store.db.commit()
        self.add(root,'青苔相机讨论镜头问题')
        doc={'session_id':child,'id':str(uuid.uuid4()),'text':'青苔相机继续讨论镜头问题','source_kind':'verified_text','kind':'ambient','revision':1}
        previous=self.agent.workspace.context(doc)['previous_events'];self.assertEqual(len(previous),1)
        self.assertEqual(self.agent.workspace.context({**doc,'session_id':other})['previous_events'],[])
        self.add(child,'青苔相机继续讨论镜头问题')
        self.assertEqual(len(self.agent.state()['events']),1)
        self.assertEqual(len(self.agent.state()['events'][0]['sources']),2)

    def test_event_continuation_topic_recall_and_focus(self):
        sid=self.session('verified_text');d1=self.add(sid,'青苔相机镜头到货');d2=self.add(sid,'青苔相机继续标定')
        state=self.agent.state();self.assertEqual(len(state['events']),1);self.assertEqual(len(state['events'][0]['sources']),2)
        self.add(self.session('verified_text'),'青苔相机下次出样')
        self.assertEqual(self.agent.state()['topics'][0]['conversation_count'],2)
        self.add(sid,'重点是先标定',kind='focus')
        state=self.agent.state();self.assertEqual(len(state['events']),3);self.assertEqual(state['confirmedMemoryCount'],0)
        qid=str(uuid.uuid4());self.agent.ask(qid,'相机进展');self.run_jobs()
        answer=self.agent.state()['answers'][0];self.assertEqual(answer['status'],'ready');self.assertNotIn('逐字核对',answer['answer'])
    def test_later_audio_processed_first_cannot_be_offered_as_earlier_audio_predecessor(self):
        sid=self.session('verified_text')
        later=dict(id=str(uuid.uuid4()),revision=1,input_key=str(uuid.uuid4()),session_id=sid,kind='ambient',text='青苔相机后段标定',evidence=[],source_kind='verified_text',occurred_at='2026-10-21T06:43:00+00:00',boundary_quality='batch_exact')
        self.processor.run_document(later,str(uuid.uuid4()))
        earlier={**later,'id':str(uuid.uuid4()),'input_key':str(uuid.uuid4()),'text':'青苔相机前段到货','occurred_at':'2026-10-21T06:42:00+00:00'}
        self.assertEqual(self.agent.workspace.context(earlier)['previous_events'],[])
        self.processor.run_document(earlier,str(uuid.uuid4()))
        after={**earlier,'id':str(uuid.uuid4()),'occurred_at':'2026-10-21T06:44:00+00:00'}
        previous=self.agent.workspace.context(after)['previous_events']
        self.assertEqual(previous[0]['occurred_at'],later['occurred_at'])
    def test_correction_hides_stale_events_topics_and_answers_then_rebuilds(self):
        doc=self.add(self.session('verified_text'),'青苔相机周五到货')
        self.agent.ask(str(uuid.uuid4()),'何时到货');self.run_jobs()
        self.agent.feedback(dict(id=str(uuid.uuid4()),target_id=doc['id'],expected_version=1,action='correct_document',values={'text':'青苔相机周六到货'}))
        state=self.agent.state();self.assertEqual(state['events'],[]);self.assertEqual(state['topics'],[]);self.assertEqual(state['answers'][0]['status'],'outdated')
        self.run_jobs();state=self.agent.state();self.assertEqual(len(state['events']),1);self.assertIn('周六',state['events'][0]['summary']);self.assertEqual(self.asr.calls,0)
    def test_invalid_model_quote_cannot_create_partial_workspace(self):
        doc=self.add(self.session('verified_text'),'青苔相机真实讨论')
        stored=dict(self.store.db.execute('SELECT * FROM documents WHERE id=?',(doc['id'],)).fetchone())
        self.agent.workspace.invalidate_document(doc['id']);context=self.agent.workspace.context(stored)
        value=self.model.organize(stored,context);value['events'][0]['quote']='伪造原句'
        with self.assertRaises(ValueError):self.agent.workspace.persist(stored,value,context)
        self.assertEqual(self.agent.state()['events'],[])
    def test_checkpoint_retry_does_not_duplicate_event_or_model_extraction(self):
        sid=self.session('verified_text');doc=dict(id=str(uuid.uuid4()),input_key='retry-event',session_id=sid,kind='ambient',text='青苔相机交付',evidence=[],source_kind='verified_text',occurred_at=None,boundary_quality='batch_exact')
        original=self.agent.workspace.persist
        self.agent.workspace.persist=lambda *args: (_ for _ in ()).throw(OSError('fixture'))
        task=str(uuid.uuid4())
        with self.assertRaises(OSError):self.processor.run_document(doc,task)
        self.agent.workspace.persist=original;self.processor.run_document(doc,task);self.processor.run_document(doc,task)
        self.assertEqual(self.model.calls,1);self.assertEqual(len(self.agent.state()['events']),1)
    def test_new_topic_invalidates_answer_and_source_groups_do_not_mix(self):
        doc=self.add(self.session('verified_text'),'青苔相机首轮')
        self.agent.ask(str(uuid.uuid4()),'相机进展');self.run_jobs()
        self.add(self.session('verified_text'),'青苔相机第二轮')
        self.assertEqual(self.agent.state()['answers'][0]['status'],'outdated')
        other={**doc,'id':str(uuid.uuid4()),'session_id':self.session('background_playback'),'source_kind':'background_playback','revision':1}
        self.assertEqual(self.agent.workspace.context(other)['topics'],[])
    def test_source_span_ids_preserve_literal_audio_transcript_without_fuzzy_quotes(self):
        text='一句原话，带错字。\n第二句说法！'
        pieces=source_spans(text);self.assertEqual(''.join(pieces),text)
        value=Organization.model_validate({'events':[{'title':'事件','summary':'摘要','span_ids':list(range(len(pieces)))}]}).model_dump()
        resolved=resolve_events(value,{'text':text,'kind':'ambient'}, {})
        self.assertEqual(resolved['events'][0]['quote'],text)
        value['events'][0].update(quote='捏造',span_ids=[999])
        with self.assertRaises(ValueError):resolve_events(value,{'text':text,'kind':'ambient'}, {})
    def test_interleaved_span_selection_keeps_exact_context_and_one_focus(self):
        text='讨论镜头。\n补充预算。\n回到镜头。'
        value=Organization.model_validate({'events':[{'title':'镜头','summary':'镜头讨论','span_ids':[0,4]},{'title':'预算','summary':'预算讨论','span_ids':[2]}]}).model_dump()
        parts=source_spans(text);value['events'][0]['span_ids']=[0,len(parts)-1]
        resolved=resolve_events(value,{'text':text,'kind':'ambient'}, {})
        self.assertEqual(resolved['events'][0]['_literal_quotes'],[parts[0],parts[-1]])
        self.assertNotIn('补充预算',''.join(resolved['events'][0]['_literal_quotes']))
        doc=self.add(self.session('verified_text'),text)
        stored=dict(self.store.db.execute('SELECT * FROM documents WHERE id=?',(doc['id'],)).fetchone())
        self.agent.workspace.invalidate_document(doc['id']);context=self.agent.workspace.context(stored)
        self.agent.workspace.persist(stored,resolved,context)
        camera=next(e for e in self.agent.workspace.state()['events'] if e['title']=='镜头')
        self.assertEqual({s['quote'] for s in camera['sources']},{parts[0],parts[-1]})
        focus=resolve_events(value,{'text':text,'kind':'focus','title':'独立重点'}, {})
        self.assertEqual(len(focus['events']),1);self.assertEqual(focus['events'][0]['quote'],text)

# Parent methods are covered by their own ProcessingTests run, not this subclass.
for name in list(fixtures.ProcessingTests.__dict__):
    if name.startswith('test_') and name not in OrganizationTests.__dict__:setattr(OrganizationTests,name,None)

if __name__=='__main__':unittest.main()

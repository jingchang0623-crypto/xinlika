"""Offline integration boundaries. These fixtures are not semantic quality scores."""
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
import uuid

from heartball_agent_store import AgentStore
from heartball_store import Store
from heartball_incremental import IncrementalDomain,IncrementalProcessAdapter,skill_version
from heartball_incremental_review import RollingReview,PROMPT,REVIEW
from heartball_skill_bundle import load_bundle,publish_manifest,FILES,PROJECT
from heartball_harness2 import read_context,FrozenReplayAdapter,digest,pack_evidence,unpack_evidence


class SkillBundleTests(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def bundle(self,change=None):
        base=load_bundle()
        for name,rel in FILES.items():
            p=self.root/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(base.texts[name]+('\n'+change if name=='incremental' and change else ''))
        return publish_manifest(self.root,'test-only')

    def test_default_extraction_preserves_historical_rolling_bodies(self):
        b=load_bundle();self.assertEqual(b.text('rolling'),PROMPT);self.assertEqual(b.text('review'),REVIEW)
        self.assertNotIn('name: xinlika-rolling',PROMPT)

    def test_digest_check_detects_silent_change_and_loaded_snapshot_is_immutable(self):
        b=self.bundle();old=b.text('incremental');(self.root/FILES['incremental']).write_text('changed')
        self.assertEqual(b.text('incremental'),old)
        with self.assertRaises(ValueError):load_bundle(b.manifest)
        with self.assertRaises(TypeError):b.texts['incremental']='changed'

    def test_bundle_rejects_unsupported_or_escaping_paths(self):
        b=self.bundle();value=json.loads(b.manifest.read_text());value['files']['review']='../../outside.md';b.manifest.write_text(json.dumps(value))
        with self.assertRaises(ValueError):load_bundle(b.manifest)

    def test_candidate_skill_actually_reaches_model_and_receipt(self):
        bundle=self.bundle('CANDIDATE_POLICY_MARKER');workspace=self.root/'workspace';(workspace).mkdir();(workspace/'.agent-runtime-owned').touch()
        s=Store(workspace);a=AgentStore(s);sid=str(uuid.uuid4());s.create_session(sid);s.update_session(sid,status='completed');a.policy(sid,asr=False,agent=True,source_kind='live_conversation')
        did=str(uuid.uuid4());a.commit_document(dict(id=did,input_key=did,kind='ambient',session_id=sid,text='按钮没有反应。',evidence=[],source_kind='live_conversation',occurred_at='2026-10-21T12:00:00+08:00',boundary_quality='source_interval'),dict(title='',summary='',claims=[]))
        task=IncrementalDomain(a).domain.task([did],'整理',skill_version(bundle)).model_copy(update={'complete_events':True});s.db.close()
        captured=[]
        class Meter:
            base_url='http://127.0.0.1:1/v1';key='fixture'
            def __init__(self,*args,**kwargs):pass
            def summary(self):return dict(calls=1,total_tokens=10,usage_complete=True)
            def close(self):pass
        class Client:
            def __init__(self,*args,**kwargs):self.chat=SimpleNamespace(completions=SimpleNamespace(create=self.create))
            def create(self,**kwargs):
                captured.append(kwargs['messages'][0]['content'])
                value=dict(state={},issues=[dict(key='i1',title='按钮无响应',summary='反馈按钮没有反应。',display='event',category='feedback',card_style='compact',admission_reason='明确反馈')],allocations={'d1':['i1']},topics=[])
                return SimpleNamespace(choices=[SimpleNamespace(finish_reason='stop',message=SimpleNamespace(content=json.dumps(value,ensure_ascii=False)))])
            def close(self):pass
        with patch('heartball_runtime_adapters.ModelMeter',Meter),patch('openai.OpenAI',Client):
            reply=IncrementalProcessAdapter(workspace,{'skill_bundle':str(bundle.manifest),'model':'fixture'}).run(task)
        self.assertEqual(reply.status,'completed',reply.error);self.assertIn('CANDIDATE_POLICY_MARKER',captured[0]);self.assertEqual(reply.usage['skill_bundle_sha256'],bundle.digest)

    def test_rolling_receipts_and_context_hash_use_candidate_resource(self):
        bundle=self.bundle();p=self.root/FILES['review'];p.write_text(p.read_text()+'\nREVIEW_POLICY_MARKER');bundle=publish_manifest(self.root,'review-only')
        s=Store(self.root/'store')
        try:
            review=RollingReview(AgentStore(s),{'skill_bundle':str(bundle.manifest)})
            self.assertIn('REVIEW_POLICY_MARKER',review.review_prompt);self.assertEqual(review.bundle.digest,bundle.digest)
        finally:s.db.close()

    def test_editor_evidence_rejects_sibling_symlinks(self):
        (self.root/'outside.json').write_text('private holdout');folder=self.root/'evidence';folder.mkdir();(folder/'leak.json').symlink_to(self.root/'outside.json')
        with self.assertRaises(ValueError):read_context(folder)

    def test_duplicate_evidence_is_lossless_and_content_addressed(self):
        files={'baseline/trajectory.md':'原始证据\n'*1000,'candidate/trajectory.md':'原始证据\n'*1000,'empty.md':'','changed.md':'另一段原声转写'}
        packed=pack_evidence(files)
        self.assertEqual(len(packed['contents']),3);self.assertEqual(unpack_evidence(packed),files)
        self.assertEqual(packed['files']['baseline/trajectory.md'],packed['files']['candidate/trajectory.md'])
        self.assertLess(len(json.dumps(packed)),len(json.dumps(files)))
        key=packed['files']['changed.md'];packed['contents'][key]='tampered'
        with self.assertRaises(ValueError):unpack_evidence(packed)


class HarnessAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:import harness2
        except ImportError:raise unittest.SkipTest('Optional pinned Harness² checkout/package required')
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=PROJECT/'.build');self.root=Path(self.temp.name);sources=self.root/'dev';task=sources/'scene';task.mkdir(parents=True)
        self.source=dict(documents=[],recording_contexts={});(task/'sources.json').write_text(json.dumps(self.source));(sources/'index.json').write_text(json.dumps(dict(tasks={'scene':digest(self.source)})))
        self.adapter=FrozenReplayAdapter(self.root/'experiment',sources,{})
    def tearDown(self):self.temp.cleanup()
    def test_upstream_tree_contract_and_skill_only_edit_surface(self):
        from harness2.core import tree
        value=tree.read_tree(self.adapter.substrate.surface(),self.adapter.base_harness());tree.validate(self.adapter.substrate.surface(),value,allow_subagents=False);self.adapter.validate_tree(value)
        value['scripts/change_source.py']='print("forbidden")'
        with self.assertRaises(ValueError):self.adapter.validate_tree(value)
    def test_immutable_integration_file_cannot_be_changed(self):
        value=dict(self.adapter.initial_tree);value['guardrails.md']='relax source checks'
        with self.assertRaises(ValueError):self.adapter.validate_tree(value)
    def test_source_tamper_rejected_before_any_model_credentials(self):
        (self.adapter.task_files('scene')/'sources.json').write_text(json.dumps(dict(documents=[{'text':'changed'}])))
        with self.assertRaises(ValueError):self.adapter.execute('scene',None,'test')
    def test_heldout_or_unknown_task_is_not_exposed(self):
        with self.assertRaises(ValueError):self.adapter.task_files('holdout')
        with self.assertRaises(RuntimeError):self.adapter.score(self.root,'scene')
    def test_engine_change_rejected_before_any_model_call(self):
        with patch('heartball_harness2.engine_snapshot',return_value={}):
            with self.assertRaisesRegex(ValueError,'engine changed'):self.adapter.execute('scene',None,'test')


class EvaluationTests(unittest.TestCase):
    def test_missing_events_cannot_pass_negative_relation_by_dropping_everything(self):
        from heartball_harness2_evaluation import assess
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);(p/'result.json').write_text(json.dumps(dict(status='completed',source_integrity={'passed':True})));(p/'deliverable.json').write_text(json.dumps(dict(events=[],topics=[])))
            docs=[dict(id='a',revision=1,text='明确问题。'),dict(id='b',revision=1,text='另一事项。')]
            refs=[dict(document_id=d['id'],revision=1,quote=d['text']) for d in docs]
            result=assess(p,{'cases':[dict(id='negative',kind='different_relation',refs=refs)]},docs)
            self.assertEqual(result['checks'][0]['result'],'unscored_missing_event_owner')

    def test_external_gate_can_reject_a_delivered_upstream_candidate(self):
        from heartball_harness2_evaluation import gate
        base=dict(status='completed',checks=[dict(id='short',result='passed')],failed=0,unscored=0,source_integrity={'passed':True})
        candidate={**base,'checks':[dict(id='short',result='failed')],'failed':1}
        self.assertFalse(gate(base,candidate)['accepted']);self.assertIn('literal_regression',gate(base,candidate)['reasons'])
        self.assertFalse(gate(base,{**candidate,'status':'failed','source_integrity':None})['accepted'])


if __name__=='__main__':unittest.main()

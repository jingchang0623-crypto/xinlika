"""Offline harness safeguards; fixtures do not measure real transcript quality."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('day_comparison',Path(__file__).with_name('compare-xinlika-day.py'))
day=importlib.util.module_from_spec(spec);spec.loader.exec_module(day)


class DayComparisonTests(unittest.TestCase):
    def setUp(self):
        self.docs=[{'id':'d1','revision':2,'text':'同一问题继续讨论。短反馈也需保留。嗯。','occurred_at':'2026-10-21T22:20:00+08:00'}]

    def proposal(self):
        ref=lambda ids:{'document_id':'d1','revision':2,'span_ids':ids}
        return {'issues':[{'sources':[ref([0])]},{'sources':[ref([1])]}],
            'fragments':[{'source':ref([2]),'reason':'filler'}],'omitted_document_ids':[]}

    def test_partition_detects_short_feedback_missing_even_when_document_was_cited(self):
        value=self.proposal();self.assertTrue(day.audit_partition(self.docs,value)['passed'])
        value['issues'].pop()
        result=day.audit_partition(self.docs,value)
        self.assertFalse(result['passed']);self.assertEqual(result['missing_spans'],1)

    def test_partition_rejects_duplicates_stale_versions_and_omissions(self):
        value=self.proposal();value['issues'][0]['sources'][0]['span_ids'].append(1)
        self.assertEqual(day.audit_partition(self.docs,value)['duplicate_spans'],1)
        value=self.proposal();value['issues'][0]['sources'][0]['revision']=1
        self.assertEqual(day.audit_partition(self.docs,value)['unknown_or_stale_spans'],1)
        value=self.proposal();value['omitted_document_ids']=['d1']
        self.assertFalse(day.audit_partition(self.docs,value)['passed'])
        self.assertTrue(day.audit_partition(self.docs,{'issues':[{'sources':[dict(document_id='d1',revision=2,all_spans=True)]}]})['passed'])

    def test_available_short_feedback_hidden_as_fragment_is_failed_not_unscored(self):
        self.assertEqual(day.anchor_verdict('completed','visible',[set()],set()),'failed')
        self.assertEqual(day.anchor_verdict('failed','visible',[set()],set()),'unscored_incomplete_run')
        self.assertEqual(day.anchor_verdict('completed','visible',[set()],set(),False),'unscored_source_anchor_unavailable')
        self.assertEqual(day.anchor_verdict('completed','separate_sources',[{'meeting'},set()],{'meeting'}),'passed')

    def test_failed_native_runs_cannot_be_scored_as_committed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);audit=path/'runtime-runs/one/tool-audit.jsonl';audit.parent.mkdir(parents=True)
            audit.write_text(json.dumps({'tool':'submit_analysis','args':{'proposal':self.proposal()},'result':{'task_id':'t1'}})+'\n')
            self.assertIsNone(day.committed_proposal(path,{'status':'failed','task_id':'t1'}))
            self.assertIsNone(day.committed_proposal(path,{'status':'completed','task_id':'t2'}))
            self.assertEqual(day.committed_proposal(path,{'status':'completed','task_id':'t1'}),self.proposal())

    def test_review_escapes_imported_text_and_labels_failed_run(self):
        docs=[dict(self.docs[0],text='<script>not an instruction</script>。')]
        page=day.review_html({'day':'2026-10-21','documents':docs},{'hermes':{'status':'failed','timeline':[],'refs':{}}})
        self.assertNotIn('<script>',page);self.assertIn('&lt;script&gt;',page)
        self.assertIn('failed',page);self.assertIn('失败运行不可评分',page)

    def test_recovery_costs_include_failed_attempt_and_preserve_unknown_usage(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for number,status,known,tokens in [(1,'failed',False,100),(2,'completed',True,60)]:
                p=root/'runtime-runs/t'/('attempt-00'+str(number));p.mkdir(parents=True)
                (p/'receipt.json').write_text(json.dumps(dict(task_id='t',status=status,seconds=10,usage=dict(calls=2,calls_with_usage=2 if known else 1,total_tokens=tokens,usage_complete=known))))
            data=day.attempt_totals(root,'t');self.assertEqual(data['totals']['calls'],4)
            self.assertEqual(data['totals']['total_tokens'],160);self.assertFalse(data['totals']['usage_complete']);self.assertIsNone(data['totals']['currency_cost'])

    def test_derivative_review_cannot_report_reused_ingest_as_free(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);history={'totals':{'calls':5,'total_tokens':100},'attempts':[]}
            (p/'day-result.json').write_text(json.dumps({'inherited_execution':history}))
            result=day.attempt_totals(p,['t']);self.assertEqual(result['totals']['total_tokens'],100)
            self.assertEqual(result['new_model_calls_for_ingest'],0)
            for index,status in enumerate(['failed','completed']):
                folder=p/'incremental-reviews'/str(index);folder.mkdir(parents=True)
                (folder/'receipt.json').write_text(json.dumps(dict(status=status,usage=dict(calls=2,total_tokens=20,usage_complete=True))))
            review=day.review_totals(p);self.assertEqual(review['failed'],1);self.assertEqual(review['totals']['total_tokens'],40)


if __name__=='__main__':unittest.main()

"""No model or ASR calls. Exercise protections against duplicate paid runs."""
import json
from pathlib import Path
import tempfile
import unittest

from heartball_harness2_safety import finished_or_claim,engine_snapshot,semantic_configuration,failed_attempt_evidence,evaluation_registration,verify_evaluation_registration


class ExperimentSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()

    def test_finished_result_reused_without_overwriting_ledger(self):
        (self.root/'provider-ledger').mkdir();p=self.root/'provider-ledger/usage.json';p.write_text('{"calls":17}')
        expected={'status':'failed','provider_usage':{'calls':17}}
        (self.root/'experiment-private.json').write_text(json.dumps(expected))
        self.assertEqual(finished_or_claim(self.root),expected)
        self.assertEqual(p.read_text(),'{"calls":17}')

    def test_interrupted_and_concurrent_runs_cannot_reset_cost(self):
        self.assertIsNone(finished_or_claim(self.root))
        with self.assertRaises(ValueError):finished_or_claim(self.root)
        other=self.root/'other';other.mkdir();(other/'provider-ledger').mkdir()
        with self.assertRaises(ValueError):finished_or_claim(other)

    def test_contract_changes_invalidate_engine_identity(self):
        (self.root/'heartball_incremental_contract.py').write_text('schema = 1')
        (self.root/'replay-xinlika-incremental.py').write_text('windows = 1')
        first=engine_snapshot(self.root)
        (self.root/'heartball_incremental_contract.py').write_text('schema = 2')
        self.assertNotEqual(first,engine_snapshot(self.root))
        cfg={'model':'example','structured_incremental':False,'extra_body':{'thinking':{'type':'disabled'}},'api_key':'secret'}
        value=semantic_configuration(cfg);cfg['extra_body']['thinking']['type']='enabled'
        self.assertEqual(value['extra_body']['thinking']['type'],'disabled')
        self.assertNotIn('secret',json.dumps(value))
        self.assertNotEqual(value,semantic_configuration({**cfg,'structured_incremental':True}))

    def test_failed_trace_contains_rejected_answer_and_exact_context(self):
        p=self.root/'task/attempt-001';p.mkdir(parents=True)
        for name,value in [('receipt.json',{'status':'failed','error':'unallocated issue'}),('context-private.json',{'new_sources':[{'id':'d1'}]}),('answer-0-private.json',{'content':'rejected output'})]:
            (p/name).write_text(json.dumps(value))
        result=failed_attempt_evidence(self.root)
        self.assertEqual(result['answer-0-private.json']['content'],'rejected output')
        self.assertEqual(result['context-private.json']['new_sources'][0]['id'],'d1')

    def test_registered_checks_must_be_unchanged_before_any_paid_call(self):
        folder=self.root/'evaluation';folder.mkdir()
        for name in ('dev-labels-private.json','holdout-labels-private.json'):(folder/name).write_text('{"cases":[]}')
        (folder/'freeze.json').write_text(json.dumps(evaluation_registration(self.root)))
        verify_evaluation_registration(self.root)
        (folder/'holdout-labels-private.json').write_text('{"cases":["changed"]}')
        with self.assertRaises(ValueError):verify_evaluation_registration(self.root)


if __name__=='__main__':unittest.main()

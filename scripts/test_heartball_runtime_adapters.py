"""Paid-request circuit breaker tests; no remote provider is contacted."""
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error
import urllib.request

from heartball_runtime_adapters import ModelMeter,invalid_tool_loop,external_environment


def failed_calls():
    messages=[]
    for i in range(2):
        cid='call-'+str(i)
        messages.extend([{'role':'assistant','tool_calls':[{'id':cid,'function':{'name':'submit_analysis','arguments':'{"wrong":true}'}}]},
            {'role':'tool','tool_call_id':cid,'content':'{"error":"Error executing tool submit_analysis: missing required field"}'}])
    return messages


class MeterTests(unittest.TestCase):
    def test_provider_outage_stops_native_retries_after_three_attempts(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);key=root/'key';key.write_text('local-fixture')
            meter=ModelMeter({'api_key_file':str(key),'base_url':'https://provider.invalid/v1','model':'fixture'},root/'meter')
            real_open=urllib.request.urlopen
            def unavailable(request,*args,**kwargs):
                if request.full_url.startswith('https://provider.invalid/'):raise urllib.error.URLError('fixture outage')
                return real_open(request,*args,**kwargs)
            try:
                with patch('heartball_runtime_adapters.urllib.request.urlopen',side_effect=unavailable):
                    for expected in (502,502,422,422):
                        req=urllib.request.Request(meter.base_url+'/chat/completions',data=b'{"messages":[]}',headers={'Authorization':'Bearer '+meter.key,'Content-Type':'application/json'})
                        with self.assertRaises(urllib.error.HTTPError) as error:real_open(req,timeout=5)
                        self.assertEqual(error.exception.code,expected)
                self.assertEqual(meter.summary()['calls'],3)
                self.assertEqual(meter.summary()['guardrail_reason'],'provider_transport_unavailable')
            finally:meter.close()

    def test_external_credentials_forward_only_explicit_operator_variables(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'external.json'
            path.write_text(json.dumps({'servers':{'fixture':{'env_allowlist':['MCP_FIXTURE_ALLOWED'],
                'headers_env':{'Authorization':'MCP_FIXTURE_AUTH'}}}}))
            with patch.dict(__import__('os').environ,{'MCP_FIXTURE_ALLOWED':'fixture','MCP_FIXTURE_AUTH':'fixture-auth','MCP_FIXTURE_UNRELATED':'must-not-forward'}):
                self.assertEqual(external_environment(path),{'MCP_FIXTURE_ALLOWED':'fixture','MCP_FIXTURE_AUTH':'fixture-auth'})
            self.assertEqual(external_environment(None),{})

    def test_invalid_repeated_calls_stop_before_paid_request(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);key=root/'key';key.write_text('local-test-fixture-not-a-real-key')
            meter=ModelMeter({'api_key_file':str(key),'base_url':'http://127.0.0.1:9/v1','model':'fixture'},root/'meter')
            try:
                req=urllib.request.Request(meter.base_url+'/chat/completions',data=json.dumps({'messages':failed_calls()}).encode(),headers={'Authorization':'Bearer '+meter.key,'Content-Type':'application/json'})
                with self.assertRaises(urllib.error.HTTPError) as error:urllib.request.urlopen(req,timeout=5)
                self.assertEqual(error.exception.code,422)
                self.assertEqual(meter.summary()['calls'],0);self.assertEqual(meter.summary()['guardrail_rejections'],1)
            finally:meter.close()

    def test_source_text_containing_error_words_is_not_a_tool_failure(self):
        messages=[{'role':'tool','content':json.dumps({'result':{'text':'Error executing tool is a quoted discussion, not a protocol failure'}})}]
        self.assertIsNone(invalid_tool_loop(messages))

    def test_successful_work_resets_distinct_error_streak_without_allowing_same_bad_call(self):
        messages=[]
        for i in range(5):
            messages.extend([{'role':'assistant','tool_calls':[{'id':str(i),'function':{'name':'stage_analysis','arguments':json.dumps({'chunk':i})}}]},
                {'role':'tool','tool_call_id':str(i),'content':'{"error":"Error executing tool stage_analysis: invalid span"}'},
                {'role':'tool','content':'{"draft_only":true}'}])
        self.assertIsNone(invalid_tool_loop(messages))
        self.assertEqual(invalid_tool_loop(failed_calls()),'repeated_invalid_tool_call')

    def test_finalization_can_retry_after_successful_draft_correction(self):
        messages=[]
        for i in range(2):
            messages.extend([{'role':'assistant','tool_calls':[{'id':'commit'+str(i),'function':{'name':'mcp__xinlika__commit_staged_analysis','arguments':'{}'}}]},
                {'role':'tool','tool_call_id':'commit'+str(i),'content':'{"error":"Error executing tool commit_staged_analysis: missing spans"}'}])
            if i==0:messages.extend([{'role':'assistant','tool_calls':[{'id':'fix','function':{'name':'mcp__xinlika__stage_analysis','arguments':'{"chunk_id":"fixed"}'}}]},
                {'role':'tool','tool_call_id':'fix','content':'{"draft_only":true}'}])
        self.assertIsNone(invalid_tool_loop(messages))


if __name__=='__main__':unittest.main()

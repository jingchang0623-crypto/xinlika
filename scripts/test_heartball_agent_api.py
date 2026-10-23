#!/usr/bin/env python3
"""Authenticated processing/feedback HTTP contract, with no device/network model."""
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from unittest.mock import patch

from heartball_store import Store
from heartball_processing import Processor
from test_heartball_processing import FakeModel, FakeASR

spec=importlib.util.spec_from_file_location("heartball_api",Path(__file__).with_name("heartball_http.py"))
service=importlib.util.module_from_spec(spec);spec.loader.exec_module(service)


class AgentAPI(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(Path(self.temp.name))
        self.processor=Processor(self.store,FakeModel(),FakeASR())
        class NoHardware:
            def start(self,*args):raise AssertionError("Text/feedback cannot start hardware")
            def stop(self,*args):raise AssertionError("Text/feedback cannot stop hardware")
        engine=NoHardware();engine.store=self.store
        self.server=service.Server(("127.0.0.1",0),service.Handler)
        self.server.engine=engine;self.server.processor=self.processor;self.server.token="test"
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.base=f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join();self.processor.close();self.store.db.close();self.temp.cleanup()

    def request(self,path,body=None,auth=True):
        headers={"Content-Type":"application/json"}
        if auth:headers["Authorization"]="Bearer test"
        req=urllib.request.Request(self.base+path,data=None if body is None else json.dumps(body).encode(),headers=headers)
        try:r=urllib.request.urlopen(req,timeout=3)
        except urllib.error.HTTPError as e:r=e
        with r:return r.code,json.load(r)

    def process(self):
        for _ in range(20):
            if not self.processor.tick():break

    def test_text_feedback_query_and_idempotent_retry(self):
        body={"id":str(uuid.uuid4()),"session_id":str(uuid.uuid4()),"text":"云杉项目交付","occurred_at":"2026-10-21T12:00:00+08:00"}
        self.assertEqual(self.request("/v1/dialogues/text",body)[0],200)
        self.process()
        self.assertEqual(self.request("/v1/dialogues/text",body)[0],200)
        _,state=self.request("/v1/agent");self.assertEqual(len(state["documents"]),1)
        c=state["claims"][0]
        correction={"id":str(uuid.uuid4()),"target_id":c["id"],"expected_version":c["version"],"action":"correct","values":{"owner":"客户"}}
        self.assertEqual(self.request("/v1/feedback",correction)[0],200)
        self.assertEqual(self.request("/v1/feedback",correction)[0],200)
        self.assertEqual(self.request("/v1/feedback",{**correction,"id":str(uuid.uuid4())})[0],409)
        query={"id":str(uuid.uuid4()),"question":"谁交付？"}
        self.assertEqual(self.request("/v1/memory/ask",query)[0],200)
        self.process()
        _,state=self.request("/v1/agent");self.assertIn("客户",state["answers"][0]["answer"])
        self.assertEqual(len(state["documents"]),1)

    def test_authentication_and_invalid_inputs_cannot_mutate(self):
        self.assertEqual(self.request("/v1/dialogues/text",{},auth=False)[0],401)
        self.assertEqual(self.request("/v1/feedback",{},auth=False)[0],401)
        self.assertEqual(self.request("/v1/agent",auth=False)[0],401)

    def test_personal_agent_provider_failure_can_be_retried(self):
        key='personal-test'
        with self.store.transaction():
            self.processor.agent.enqueue('personal_analysis',key,{'run_key':key})
            row=self.store.db.execute("SELECT id FROM jobs WHERE input_key=?",(key,)).fetchone()
            self.store.db.execute("UPDATE jobs SET status='blocked_provider',error='provider_auth',attempts=4 WHERE id=?",(row[0],))
        self.assertEqual(self.request('/v1/jobs/retry',{'id':row[0]},auth=False)[0],401)
        self.assertEqual(self.request('/v1/jobs/retry',{'id':row[0]})[0],200)
        job=self.store.db.execute('SELECT status,attempts,error FROM jobs WHERE id=?',(row[0],)).fetchone()
        self.assertEqual(tuple(job),('queued',0,None))
        self.assertEqual(self.request("/v1/dialogues/text",[])[0],400)
        self.assertEqual(self.request("/v1/audio?batch_id=../../runtime.json")[0],400)
        self.assertEqual(self.request("/v1/memory/ask",{"id":str(uuid.uuid4()),"question":""})[0],400)
        self.assertEqual(self.processor.agent.state()["documents"],[])

    def test_recording_day_query_validation_and_timezone(self):
        from test_heartball_organization import SemanticModel
        self.processor.model=SemanticModel()
        body={'id':str(uuid.uuid4()),'session_id':str(uuid.uuid4()),'text':'青苔相机准备标定','occurred_at':'2026-10-20T16:05:00+00:00'}
        self.request('/v1/dialogues/text',body); self.process()
        code,state=self.request('/v1/agent?day=2026-10-21&time_zone=Asia%2FShanghai')
        self.assertEqual(code,200); self.assertEqual(state['today']['date'],'2026-10-21')
        self.assertEqual(state['today']['groups'][0]['start_local'],'2026-10-21T00:05:00+08:00')
        self.assertEqual(self.request('/v1/agent?day=invalid')[0],400)
        self.assertEqual(self.request('/v1/agent?time_zone=invalid')[0],400)

    def test_semantic_event_topic_and_answer_need_no_confirmation_or_hardware(self):
        from test_heartball_organization import SemanticModel
        self.processor.model=SemanticModel()
        body={'id':str(uuid.uuid4()),'session_id':str(uuid.uuid4()),'text':'青苔相机准备标定'}
        self.assertEqual(self.request('/v1/dialogues/text',body)[0],200);self.process()
        _,state=self.request('/v1/agent')
        self.assertEqual(len(state['events']),1);self.assertEqual(len(state['topics']),1)
        self.assertEqual(state['confirmedMemoryCount'],0)
        self.assertEqual(self.request('/v1/memory/ask',{'id':str(uuid.uuid4()),'question':'相机进展？'})[0],200);self.process()
        _,state=self.request('/v1/agent');self.assertEqual(state['answers'][0]['status'],'ready')
        self.assertTrue(state['answers'][0]['refs']);self.assertEqual(self.processor.asr.calls,0)

    def test_text_identity_conflicts_and_audio_policy_never_inherited(self):
        body={"id":str(uuid.uuid4()),"session_id":str(uuid.uuid4()),"text":"云杉接口完成"}
        self.request("/v1/dialogues/text",body);self.process()
        self.assertEqual(self.request("/v1/dialogues/text",{**body,"text":"另一段"})[0],409)
        self.assertFalse(self.processor.agent.allowed(body["session_id"],"asr"))
        self.assertEqual(self.processor.asr.calls,0)

    def test_public_backend_has_no_hardware_engine_or_control_routes(self):
        self.assertFalse(hasattr(service, 'Engine'))
        with patch.object(service.subprocess,"Popen") as launch:
            for route in ('/v1/capture/start', '/v1/capture/stop', '/v1/focus/start', '/v1/focus/end'):
                self.assertEqual(self.request(route, {'id': str(uuid.uuid4())})[0], 404)
            launch.assert_not_called()


if __name__=="__main__":unittest.main()

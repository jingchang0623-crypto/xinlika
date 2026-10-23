"""Two independent device identities share one ledger; no hardware or cloud calls."""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from heartball_processing import Processor
from test_heartball_processing import FakeASR
from test_heartball_organization import SemanticModel
from heartball_shared import SharedWorkspace

spec=importlib.util.spec_from_file_location('shared_service',Path(__file__).with_name('heartball-shared-service.py'))
service=importlib.util.module_from_spec(spec);spec.loader.exec_module(service)


class SharedTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.server=service.make_server(self.root,'127.0.0.1',0)
        self.store=self.server.engine.store
        self.asr=FakeASR();self.model=SemanticModel()
        self.processor=Processor(self.store,self.model,self.asr)
        self.server.processor=self.processor;self.server.shared.agent=self.processor.agent
        self.server.mobile.agent=self.processor.agent
        self.phone=self.server.shared.provision('phone');self.mac=self.server.shared.provision('mac')
        self.reader=self.server.shared.provision('reader','reader')
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.base=f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join()
        self.processor.close();self.store.db.close();self.temp.cleanup()

    def request(self,path,device=None,body=None):
        headers={'Content-Type':'application/json'}
        if device:headers['Authorization']='Bearer '+device['token']
        req=urllib.request.Request(self.base+path,headers=headers,data=json.dumps(body).encode() if body is not None else None)
        try:r=urllib.request.urlopen(req,timeout=5)
        except urllib.error.HTTPError as error:r=error
        with r:return r.code,json.load(r)

    def batch(self):
        raw=b'a'*120000
        return {'id':str(uuid.uuid4()),'kind':'batch','session':{'id':str(uuid.uuid4()),'device_id':str(uuid.uuid4()),
            'started_at':'2026-10-21T14:00:00+08:00','card_file':'note20261021-140000.opus','batch_seconds':60,
            'processing':{'asr':True,'agent':True,'source_kind':'live_conversation'}},'stream_id':str(uuid.uuid4()),
            'sequence':0,'start_byte':0,'end_byte':len(raw),'stream_started_at':'2026-10-21T14:00:00+08:00',
            'received_at':'2026-10-21T14:01:00+08:00','reason':'duration','sha256':hashlib.sha256(raw).hexdigest(),
            'audio_base64':base64.b64encode(raw).decode()}

    def tick(self):
        for _ in range(60):
            if not self.processor.tick():break

    def sync(self,device=None,extra=''):
        return self.request('/v1/shared/sync?day=2026-10-21&time_zone=Asia%2FShanghai'+extra,device or self.mac)

    def correction(self,doc,text):
        return {'id':str(uuid.uuid4()),'target_id':doc['id'],'expected_version':doc['revision'],'action':'correct_document','values':{'text':text}}

    def test_homepage_admission_changes_shared_revision_without_deleting_search_sources(self):
        from heartball_timeline import save
        self.request('/v1/mobile/ingest',self.phone,self.batch());self.tick()
        _,before=self.sync();events=before['state']['today']['groups'][0]['events'];event=events[0]
        with self.store.lock,self.store.transaction():
            current=dict(self.store.db.execute('select * from workspace_events where id=?',(event['id'],)).fetchone())
            save(self.store.db,current,'detail','只有口头回应')
        _,after=self.sync(extra='&cursor='+str(before['revision'])+'&view='+before['view_key'])
        self.assertTrue(after['changed']);self.assertGreater(after['revision'],before['revision'])
        self.assertEqual(sum(len(g['events']) for g in after['state']['today']['groups']),0)
        self.assertGreater(self.store.db.execute('select count(*) from workspace_event_sources').fetchone()[0],0)

    def test_recovery_cannot_be_attached_from_another_device(self):
        from heartball_card_segments import segment_id
        body=self.batch();self.request('/v1/mobile/ingest',self.phone,body)
        root=body['session']['id'];name='note20261021-170001.opus'
        child={**body['session'],'id':segment_id(root,name),'card_file':name,'started_at':'2026-10-21T17:00:01+08:00','recovery':{'root_id':root,'previous_file':body['session']['card_file'],'previous_sha256':'a'*64,'expected_bytes':12000,'sha256':'b'*64}}
        code,_=self.request('/v1/mobile/ingest',self.mac,{'id':str(uuid.uuid4()),'session':child,'kind':'finish','at':'2026-10-21T17:00:07+08:00'})
        self.assertEqual(code,409)
        self.assertEqual(self.store.db.execute('select count(*) from mobile_card_segments').fetchone()[0],0)

    def test_voice_enrollment_auth_device_binding_and_private_status(self):
        eid=str(uuid.uuid4());begin={'action':'begin','id':eid,'consent':True}
        self.assertEqual(self.request('/v1/voice',None,begin)[0],401)
        self.assertEqual(self.request('/v1/voice',self.reader,begin)[0],403)
        self.assertEqual(self.request('/v1/voice',self.phone,begin)[0],200)
        bind={'action':'bind','enrollment_id':eid,'session_id':str(uuid.uuid4()),'slot':1,'solo':True}
        self.assertEqual(self.request('/v1/voice',self.mac,bind)[0],409)
        self.assertEqual(self.request('/v1/voice',self.phone,bind)[0],200)
        code,state=self.request('/v1/voice',self.reader)
        self.assertEqual(code,200);self.assertEqual(state['samples'][0]['status'],'waiting_audio')
        self.assertNotIn('vector',json.dumps(state));self.assertFalse(state['personal_attribution_allowed'])
        self.assertEqual(self.request('/v1/voice',self.phone,[])[0],400)
        self.assertEqual(self.request('/v1/acoustics',self.mac)[0],200)
        self.assertEqual(self.request('/v1/voice',self.phone,{'action':'revoke'})[0],200)

    def test_phone_ingest_mac_view_bidirectional_correction_and_stale_conflict(self):
        batch=self.batch();self.assertEqual(self.request('/v1/mobile/ingest',self.phone,batch)[0],200);self.tick()
        _,snapshot=self.sync();doc=snapshot['state']['documents'][0]
        self.assertEqual(doc['occurred_at'],'2026-10-21T14:00:00+08:00')
        self.assertEqual(snapshot['state']['today']['event_count'],1)
        unchanged=self.sync(extra=f"&cursor={snapshot['revision']}&view={snapshot['view_key']}")[1]
        self.assertFalse(unchanged['changed']);self.assertIsNone(unchanged['state'])
        change=self.correction(doc,'青苔相机先确认镜头')
        self.assertEqual(self.request('/v1/feedback',self.phone,change)[0],200);self.tick()
        _,mac=self.sync(extra=f"&cursor={snapshot['revision']}&view={snapshot['view_key']}")
        current=next(d for d in mac['state']['documents'] if d['status']!='superseded')
        self.assertEqual(current['text'],'青苔相机先确认镜头');self.assertGreater(mac['revision'],snapshot['revision'])
        self.assertEqual(self.request('/v1/feedback',self.mac,self.correction(doc,'旧版本覆盖'))[0],409)
        self.assertEqual(self.request('/v1/feedback',self.mac,self.correction(current,'青苔相机再确认镜头'))[0],200);self.tick()
        phone=self.sync(self.phone)[1]
        latest=next(d for d in phone['state']['documents'] if d['status']!='superseded')
        self.assertEqual(latest['text'],'青苔相机再确认镜头');self.assertEqual(self.asr.calls,1)

    def test_credentials_revocation_reader_and_hardware_isolation(self):
        self.assertEqual(self.sync(device={'token':'wrong'})[0],401)
        self.assertEqual(self.request('/health')[0],200)
        self.assertEqual(self.request('/v1/capture/start',self.mac,{'id':str(uuid.uuid4())})[0],405)
        self.assertEqual(self.request('/v1/mobile/ingest',self.reader,self.batch())[0],403)
        self.assertEqual(self.sync(self.reader)[0],200)
        hashes=[r[0] for r in self.store.db.execute('SELECT token_hash FROM shared_devices')]
        self.assertNotIn(self.phone['token'],hashes)
        self.server.shared.revoke(self.phone['deviceId'])
        self.assertEqual(self.sync(self.phone)[0],401);self.assertEqual(self.sync(self.mac)[0],200)

    def test_owner_lost_receipt_and_hash_reuse_do_not_duplicate_processing(self):
        batch=self.batch();self.request('/v1/mobile/ingest',self.phone,batch);self.tick()
        self.assertTrue(self.request('/v1/mobile/ingest',self.phone,batch)[1]['duplicate'])
        self.assertEqual(self.request('/v1/mobile/ingest',self.mac,batch)[0],409)
        other=self.batch()  # same bytes, independent real capture identity
        self.assertEqual(self.request('/v1/mobile/ingest',self.mac,other)[0],200);self.tick()
        self.assertEqual(self.asr.calls,1)
        self.assertEqual(len(self.sync()[1]['state']['documents']),2)

    def test_revision_survives_registry_restart_and_midnight_changes_view(self):
        snapshot=self.sync()[1]
        self.server.shared=SharedWorkspace(self.store,self.processor.agent)
        same=self.sync(extra=f"&cursor={snapshot['revision']}&view={snapshot['view_key']}")[1]
        self.assertFalse(same['changed'])
        next_day=self.request(f"/v1/shared/sync?day=2026-10-22&cursor={snapshot['revision']}&view={snapshot['view_key']}",self.mac)[1]
        self.assertTrue(next_day['changed']);self.assertEqual(next_day['state']['today']['date'],'2026-10-22')
        self.assertEqual(self.sync(extra='&cursor=999999999')[0],409)
        self.assertEqual(self.sync(extra='&cursor=-1')[0],400)
        self.assertEqual(self.request('/v1/shared/sync?day=bad',self.mac)[0],400)

    def test_simultaneous_corrections_have_one_winner_and_idempotent_receipt(self):
        self.request('/v1/mobile/ingest',self.phone,self.batch());self.tick()
        doc=self.sync()[1]['state']['documents'][0]
        requests=[(self.phone,self.correction(doc,'青苔相机甲')),(self.mac,self.correction(doc,'青苔相机乙'))]
        with ThreadPoolExecutor(max_workers=2) as pool:
            replies=list(pool.map(lambda v:self.request('/v1/feedback',v[0],v[1]),requests))
        self.assertEqual(sorted(code for code,_ in replies),[200,409]);self.tick()
        winner=next(i for i,r in enumerate(replies) if r[0]==200)
        self.assertEqual(self.request('/v1/feedback',requests[winner][0],requests[winner][1])[0],200)
        self.tick();self.assertEqual(self.asr.calls,1)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM feedback').fetchone()[0],1)

    def test_protected_validation_roots_refused(self):
        project=Path(__file__).resolve().parents[1]
        for name in ('heartball-lab','xinlika-mobile','xinlika-mobile-dev'):
            with self.assertRaises(ValueError):service.safe_root(project/'.build'/name)

    def test_service_restart_preserves_devices_revision_and_receipts(self):
        batch=self.batch();self.request('/v1/mobile/ingest',self.phone,batch);self.tick()
        before=self.sync()[1]
        self.server.shutdown();self.server.server_close();self.thread.join();self.processor.close();self.store.db.close()
        self.server=service.make_server(self.root,'127.0.0.1',0);self.store=self.server.engine.store
        self.processor=Processor(self.store,self.model,self.asr)
        self.server.processor=self.processor;self.server.shared.agent=self.processor.agent;self.server.mobile.agent=self.processor.agent
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.base=f'http://127.0.0.1:{self.server.server_port}'
        after=self.sync()[1]
        self.assertEqual(before['workspace_id'],after['workspace_id'])
        self.assertGreaterEqual(after['revision'],before['revision'])
        self.assertTrue(self.request('/v1/mobile/ingest',self.phone,batch)[1]['duplicate'])
        self.tick();self.assertEqual(self.asr.calls,1)

    def test_independent_workspaces_never_share_same_day_cursor_identity(self):
        original=self.sync()[1]
        from heartball_store import Store
        from heartball_agent_store import AgentStore
        with tempfile.TemporaryDirectory() as directory:
            store=Store(Path(directory));other=SharedWorkspace(store,AgentStore(store))
            snapshot=other.snapshot(str(original['revision']),original['view_key'],'2026-10-21')
            self.assertTrue(snapshot['changed'])
            self.assertNotEqual(snapshot['workspace_id'],original['workspace_id'])
            store.db.close()


if __name__=='__main__':unittest.main()

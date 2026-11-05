"""Synthetic audio exercises transport, permissions and clocks, not ASR quality."""
import base64
import copy
import hashlib
import json
import unittest
import uuid
from pathlib import Path
from unittest.mock import MagicMock
import test_heartball_shared as shared_fixtures
from heartball_watch import WatchIngest, canonical_wav
from heartball_processing import VoxgateAdapter


class WatchTests(unittest.TestCase):
    tearDown = shared_fixtures.SharedTests.tearDown
    request = shared_fixtures.SharedTests.request
    tick = shared_fixtures.SharedTests.tick
    def setUp(self):
        shared_fixtures.SharedTests.setUp(self); self.server.watch.agent=self.processor.agent
    def audio(self, sequence=0, offset=0, seconds=2, sid=None):
        wav=canonical_wav(bytes([sequence+1])*int(seconds*32000))
        return {'id':str(uuid.uuid4()),'session':{'schema_version':1,'id':sid or str(uuid.uuid4()),
            'device_id':str(uuid.uuid4()),'workspace_id':self.server.shared.workspace_id,
            'started_at':'2026-10-26T09:00:00+08:00','time_zone':'Asia/Shanghai','capture_source':'apple_watch',
            'sample_rate':16000,'channels':1,'processing':{'asr':True,'agent':True,'source_kind':'live_conversation'}},
            'kind':'segment','sequence':sequence,'offset_ms':offset,'frame_count':int(seconds*16000),
            'sha256':hashlib.sha256(wav).hexdigest(),'audio_base64':base64.b64encode(wav).decode()}
    def send(self,b,device=None):return self.request('/v1/watch/ingest',device or self.phone,b)
    def control(self,b,kind,**fields):return {'id':str(uuid.uuid4()),'session':b['session'],'kind':kind,**fields}
    def test_watch_ingress_rejects_reader_no_auth_wrong_workspace(self):
        b=self.audio()
        self.assertEqual(self.request('/v1/watch/ingest',None,b)[0],401)
        self.assertEqual(self.send(b,self.reader)[0],403)
        b['session']['workspace_id']=str(uuid.uuid4());self.assertEqual(self.send(b)[0],400)
        self.assertEqual(self.store.db.execute('select count(*) from batches').fetchone()[0],0)
    def test_watch_immutable_replay_dedup_and_owner(self):
        b=self.audio();self.assertEqual(self.send(b)[0],200)
        self.assertTrue(self.send(b)[1]['duplicate'])
        changed=copy.deepcopy(b);changed['offset_ms']=100
        self.assertEqual(self.send(changed)[0],409)
        self.assertEqual(self.send(b,self.mac)[0],409)
        self.assertEqual(self.store.db.execute('select count(*) from batches').fetchone()[0],1)
    def test_watch_hash_and_format_validation_roll_back_session(self):
        for change in ('hash','format','frames','nan'):
            b=self.audio()
            if change=='hash':b['sha256']='0'*64
            elif change=='frames':b['frame_count']=True
            elif change=='nan':b['offset_ms']=float('nan')
            else:
                data=b'not a wav';b['audio_base64']=base64.b64encode(data).decode();b['sha256']=hashlib.sha256(data).hexdigest()
            self.assertEqual(self.send(b)[0],400)
        self.assertEqual(self.store.db.execute('select count(*) from sessions').fetchone()[0],0)
    def test_watch_gap_clock_focus_and_finish_do_not_use_cb08_byte_clock(self):
        first=self.audio();self.assertEqual(self.send(first)[0],200)
        second=self.audio(sequence=1,offset=12000,seconds=3);second['session']=first['session']
        self.assertEqual(self.send(second)[0],200)
        interruption=self.control(first,'interrupted',offset_ms=2000,reason='phone_call')
        self.assertEqual(self.send(interruption)[0],200)
        focus=self.control(first,'focus',offset_ms=1000,end_ms=14000)
        self.assertEqual(self.send(focus)[0],200)
        finish=self.control(first,'ended',offset_ms=15000,segment_count=2)
        self.assertEqual(self.send(finish)[0],200)
        self.tick()
        self.assertEqual(self.asr.calls,2) # Focus reuses canonical transcripts.
        state=self.store.state();self.assertEqual(state['session']['audioSeconds'],5)
        self.assertEqual(state['focuses'][0]['audioSeconds'],3)
        self.assertEqual(state['session']['gapCount'],1)
        docs=[dict(r) for r in self.store.db.execute("select * from documents where kind='ambient' order by occurred_at")]
        self.assertEqual(len(docs),2)
        self.assertEqual(docs[0]['occurred_at'],'2026-10-26T09:00:00+08:00')
        self.assertEqual(docs[1]['occurred_at'],'2026-10-26T09:00:12+08:00')
        self.assertEqual(json.loads(docs[1]['evidence'])[0]['bytes_per_second'],32000)
        code,audio=self.binary_audio(first['id']);self.assertEqual(code,200)
        self.assertEqual(hashlib.sha256(audio).hexdigest(),first['sha256'])
    def binary_audio(self,bid):
        import urllib.request
        request=urllib.request.Request(self.base+'/v1/audio?batch_id='+bid,headers={'Authorization':'Bearer '+self.mac['token']})
        with urllib.request.urlopen(request,timeout=5) as response:return response.code,response.read()
    def test_watch_cannot_finish_before_missing_segment_or_change_policy(self):
        b=self.audio();self.send(b)
        finish=self.control(b,'ended',offset_ms=2000,segment_count=2)
        self.assertEqual(self.send(finish)[0],409)
        changed=copy.deepcopy(b);changed['id']=str(uuid.uuid4());changed['sequence']=1;changed['offset_ms']=2000
        changed['session']['processing']['source_kind']='unknown'
        self.assertEqual(self.send(changed)[0],409)
        self.assertEqual(self.store.session(b['session']['id'])['status'],'recording')
    def test_watch_overlap_and_sequence_rejected(self):
        b=self.audio();self.send(b)
        second=self.audio(sequence=2,offset=2000);second['session']=b['session']
        self.assertEqual(self.send(second)[0],409)
        second['sequence']=1;second['offset_ms']=1000;self.assertEqual(self.send(second)[0],409)
    def test_watch_resume_uses_persisted_receipt_after_reopen(self):
        b=self.audio();self.send(b)
        reopened=WatchIngest(self.store,self.processor.agent)
        self.assertTrue(self.server.shared.accept(reopened,b,self.phone['deviceId'])['duplicate'])
    def test_full_minute_with_foundation_escaped_base64_slashes_is_accepted(self):
        import urllib.request
        b=self.audio(seconds=60)
        wav=canonical_wav(b'\xff'*(60*32000))
        b.update(sha256=hashlib.sha256(wav).hexdigest(),audio_base64=base64.b64encode(wav).decode())
        raw=json.dumps(b,separators=(',',':'),sort_keys=True).replace('/','\\/').encode()
        self.assertGreater(len(raw),5_100_000)
        self.assertLess(len(raw),5_200_000)
        req=urllib.request.Request(self.base+'/v1/watch/ingest',data=raw,
            headers={'Content-Type':'application/json','Authorization':'Bearer '+self.phone['token']})
        with urllib.request.urlopen(req,timeout=10) as response:
            self.assertEqual(response.code,200);self.assertFalse(json.load(response)['duplicate'])
        # The same logical envelope remains immutable with normal JSON encoding.
        self.assertTrue(self.send(b)[1]['duplicate'])
        self.assertEqual(self.store.db.execute('select count(*) from batches').fetchone()[0],1)
    def test_wav_asr_adapter_passes_original_wav_without_cb08_wrapping(self):
        b=self.audio();wav=base64.b64decode(b['audio_base64']);path=self.root/'test.wav';path.write_bytes(wav)
        # Exercise the actual format branch without calling an external service.
        adapter=object.__new__(VoxgateAdapter);adapter.client=MagicMock();adapter.provider='synthetic-adapter'
        adapter.client.audio.transcriptions.create.return_value.model_dump.return_value={'text':'synthetic','segments':[]}
        result=adapter.transcribe(path,self.root/'transcript.json')
        self.assertEqual(result['text'],'synthetic')
        args=adapter.client.audio.transcriptions.create.call_args.kwargs
        self.assertEqual(args['file'][0],'audio.wav');self.assertEqual(args['file'][2],'audio/wav')
    def test_cloud_audio_receipt_checks_original_owner_and_canonical_file(self):
        b=self.audio();self.assertEqual(self.send(b)[0],200)
        path='/v1/watch/audio-receipt?session_id='+b['session']['id']+'&segment_id='+b['id']
        self.assertEqual(self.request(path)[0],401)
        self.assertEqual(self.request(path,self.mac)[0],403)
        self.assertEqual(self.request(path,self.reader)[0],403)
        code,proof=self.request(path,self.phone)
        self.assertEqual(code,200);self.assertTrue(proof['verified'])
        self.assertEqual(proof['sha256'],b['sha256']);self.assertEqual(proof['frame_count'],32000)
        self.assertEqual(proof['byte_count'],64044);self.assertEqual(proof['device_id'],self.phone['deviceId'])
        self.assertEqual(proof['workspace_id'],self.server.shared.workspace_id)
    def test_cloud_audio_receipt_rechecks_missing_changed_and_revoked_audio(self):
        b=self.audio();self.send(b)
        path='/v1/watch/audio-receipt?session_id='+b['session']['id']+'&segment_id='+b['id']
        filename=Path(self.store.db.execute('select filename from batches where id=?',(b['id'],)).fetchone()[0])
        original=filename.read_bytes();self.assertEqual(self.request(path,self.phone)[0],200)
        changed=bytearray(original);changed[-1]^=1;filename.write_bytes(changed)
        self.assertEqual(self.request(path,self.phone)[0],409)
        filename.unlink();self.assertEqual(self.request(path,self.phone)[0],503)
        filename.write_bytes(original)
        self.processor.agent.policy(b['session']['id'],asr=False,agent=False,source_kind='unknown')
        self.assertEqual(self.request(path,self.phone)[0],403)

if __name__=='__main__':unittest.main()

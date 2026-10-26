"""Recording clocks must survive imports/reprocessing without using wall-clock processing time."""
import hashlib
import datetime as dt
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
from heartball_store import Store
from heartball_agent_store import AgentStore
from heartball_recording_time import recording_time,event_sort_key,device_local_start,query_display_times


class RecordingTimeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.s=Store(Path(self.temp.name)/'ledger');self.a=AgentStore(self.s)
        self.sid=str(uuid.uuid4());self.s.create_session(self.sid);self.s.update_session(self.sid,status='completed')
        self.a.policy(self.sid,asr=False,agent=True,source_kind='live_conversation')
    def tearDown(self):self.s.db.close();self.temp.cleanup()
    def doc(self):return dict(id=str(uuid.uuid4()),session_id=self.sid,occurred_at=None,evidence=[{'start_byte':40000}])
    def test_unknown_recording_time_never_uses_processing_import_or_mtime(self):
        doc={**self.doc(),'created_at':'2099-01-01T00:00:00+00:00'}
        result=recording_time(self.s.db,doc)
        self.assertIsNone(result['occurred_at']);self.assertIsNone(result['recorded_local_time'])
        self.assertEqual(event_sort_key({**doc,**result}),(0,''))
        self.assertGreater(event_sort_key({'occurred_at':'2020-01-01T00:00:00+00:00'}),event_sort_key(doc))
    def test_query_display_converts_the_instant_without_replacing_original_or_inventing_unknown_time(self):
        original=[{'occurred_at':'2026-10-20T20:00:00Z'},{'occurred_at':None,'created_at':'2099-01-01T00:00:00Z'},{'occurred_at':'2026-10-21T04:00:00'}]
        result=query_display_times(original,dt.timezone(dt.timedelta(hours=8)))
        self.assertEqual(result[0]['recording_display_time'],'2026-10-21T04:00:00+08:00')
        self.assertEqual(result[0]['occurred_at'],original[0]['occurred_at'])
        self.assertNotIn('recording_display_time',original[0])
        self.assertNotIn('recording_display_time',result[1]);self.assertNotIn('recording_display_time',result[2])
    def test_original_device_time_plus_selection_and_batch_offsets_remains_unverified(self):
        self.a.recording_origin(self.sid,'note20260913-142643.opus','a'*64,120,{'kind':'fixture'})
        result=recording_time(self.s.db,self.doc())
        self.assertEqual(result['recorded_local_time'],'2026-09-13T14:29:03')
        self.assertEqual(result['recording_time_basis'],'device_clock_unverified');self.assertIsNone(result['occurred_at'])
        self.assertIsNone(device_local_start('download-20261021.opus'))
    def test_import_requires_exact_original_bytes_and_retains_device_origin(self):
        root=Path(self.temp.name);original=root/'note20260913-142643.opus';raw=root/'selection.bin'
        original.write_bytes(b'a'*2000+b'b'*2000+b'c'*2000);raw.write_bytes(b'b'*2000)
        dest=root/'imported'
        command=[sys.executable,str(Path(__file__).with_name('heartball-import.py')),'--root',str(dest),'--raw',str(raw),'--seconds','1','--expected-sha256',hashlib.sha256(raw.read_bytes()).hexdigest(),'--source-kind','unknown','--recording-file',str(original),'--recording-offset-seconds','1']
        result=subprocess.run(command,capture_output=True,text=True);self.assertEqual(result.returncode,0,result.stderr)
        sid=json.loads(result.stdout)['session_id'];store=Store(dest);agent=AgentStore(store)
        self.assertEqual(store.db.execute('SELECT offset_seconds FROM recording_origins WHERE session_id=?',(sid,)).fetchone()[0],1)
        self.assertIsNone(agent._policy(sid)['occurred_at']);store.db.close()
        raw.write_bytes(b'z'*2000);command[command.index('--expected-sha256')+1]=hashlib.sha256(raw.read_bytes()).hexdigest()
        self.assertNotEqual(subprocess.run(command,capture_output=True).returncode,0)

if __name__=='__main__':unittest.main()

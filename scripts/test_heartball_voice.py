"""Enrollment/attribution controls. Artificial vectors do not measure accuracy."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from heartball_store import Store,Conflict,now
from heartball_agent_store import AgentStore
from heartball_acoustic_worker import AcousticWorker


class VoiceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(Path(self.temp.name));self.agent=AgentStore(self.store);self.voice=self.agent.voice
        self.device=str(uuid.uuid4());self.eid=str(uuid.uuid4());self.v=[1.0]+[0.0]*15
        self.store.db.execute('CREATE TABLE shared_session_owners(session_id TEXT PRIMARY KEY,device_id TEXT)');self.store.db.commit()
    def tearDown(self):self.store.db.close();self.temp.cleanup()
    def session(self,device=None,source='unknown',agent=False):
        sid=str(uuid.uuid4());self.store.create_session(sid);self.store.update_session(sid,status='completed')
        self.store.db.execute('INSERT INTO shared_session_owners VALUES(?,?)',(sid,device or self.device));self.store.db.commit()
        self.agent.policy(sid,asr=False,agent=agent,source_kind=source)
        return sid
    def sample(self,slot,vector=None):
        sid=self.session();self.voice.bind(self.eid,slot,sid,self.device,True)
        row=dict(self.store.db.execute('SELECT * FROM voice_samples WHERE session_id=?',(sid,)).fetchone())
        self.voice.record_sample(row,[vector or self.v]*5,'a'*64,25,0)
        return row
    def enroll(self):
        self.voice.begin(self.eid,self.device,True)
        for slot in (1,2,3):self.sample(slot)
    def test_only_fresh_explicit_owned_solo_samples_are_eligible(self):
        with self.assertRaises(ValueError):self.voice.begin(self.eid,self.device,False)
        self.voice.begin(self.eid,self.device,True)
        other=self.session(device=str(uuid.uuid4()))
        with self.assertRaises(Conflict):self.voice.bind(self.eid,1,other,self.device,True)
        sid=self.session()
        with self.assertRaises(ValueError):self.voice.bind(self.eid,1,sid,self.device,False)
        self.store.db.execute("UPDATE sessions SET started_at='2020-01-01T00:00:00+00:00' WHERE id=?",(sid,));self.store.db.commit()
        with self.assertRaises(Conflict):self.voice.bind(self.eid,1,sid,self.device,True)
    def test_three_independent_samples_and_holdout_required(self):
        self.voice.begin(self.eid,self.device,True);self.sample(1);self.sample(2)
        self.assertIsNone(self.voice.active());self.sample(3)
        self.assertEqual(self.voice.status()['status'],'registered')
        self.assertFalse(self.voice.status()['personal_attribution_allowed'])
        self.assertNotIn('vector',json.dumps(self.voice.status()))
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM transcripts').fetchone()[0],0)
    def test_short_noisy_or_empty_registration_rejected(self):
        self.voice.begin(self.eid,self.device,True);sid=self.session();self.voice.bind(self.eid,1,sid,self.device,True)
        row=dict(self.store.db.execute('SELECT * FROM voice_samples').fetchone())
        for vectors,seconds,clipped in [([],25,0),([self.v]*5,10,0),([self.v]*5,30,.02)]:
            self.voice.record_sample(row,vectors,'a'*64,seconds,clipped)
            self.assertIsNone(self.voice.active())
            self.assertEqual(self.store.db.execute('SELECT status FROM voice_samples').fetchone()[0],'rejected')
            # Re-test the same explicitly bound grant; real UI binds a new session.
            self.store.db.execute("UPDATE voice_samples SET status='waiting_audio'");self.store.db.commit()
    def test_inconsistent_second_speaker_does_not_enroll(self):
        self.voice.begin(self.eid,self.device,True);self.sample(1);self.sample(2,vector=[0.0,1.0]+[0.0]*14);self.sample(3)
        self.assertIsNone(self.voice.active())
        self.assertEqual(self.store.db.execute('SELECT status FROM voice_samples WHERE slot=2').fetchone()[0],'rejected')
    def test_replayed_owner_voice_can_match_but_never_proves_identity_or_experience(self):
        self.enroll();windows=[{'start_seconds':0,'end_seconds':5}]
        self.voice.match('observation',windows,[self.v],'a'*64);hint=self.voice.hints('observation')
        self.assertEqual(hint['windows'][0]['match'],'similar_to_owner')
        self.assertFalse(hint['windows'][0]['personal_attribution_allowed'])
        self.assertFalse(hint['windows'][0]['live_source_verified'])
        self.assertEqual(hint['windows'][0]['user_identity'],'unverified')
    def test_model_change_or_revocation_cannot_reuse_biometric_match(self):
        self.enroll();self.voice.match('x',[{'start_seconds':0,'end_seconds':5}],[self.v],'b'*64)
        self.assertIsNone(self.voice.hints('x'))
        self.voice.match('x',[{'start_seconds':0,'end_seconds':5}],[self.v],'a'*64)
        self.voice.revoke();self.assertIsNone(self.voice.hints('x'));self.assertIsNone(self.voice.active())
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM voice_samples WHERE vector IS NOT NULL').fetchone()[0],0)
    def test_live_setting_does_not_turn_first_person_into_owner(self):
        sid=self.session(source='live_conversation',agent=True)
        doc={'id':str(uuid.uuid4()),'session_id':sid,'kind':'ambient','input_key':str(uuid.uuid4()),'text':'我明天去出差。',
            'source_kind':'live_conversation','occurred_at':now(),'evidence':[],'boundary_quality':'test'}
        self.agent.commit_document(doc,{'title':'讨论出差','summary':'讨论里提到出差。','claims':[{'project':'','kind':'fact','statement':'发言者提到出差','owner':'我','quote':doc['text']}]})
        self.assertEqual(self.store.db.execute('SELECT owner,status FROM claims').fetchone()[:],('unknown','proposed'))


class QueueTests(unittest.TestCase):
    setUp=VoiceTests.setUp
    tearDown=VoiceTests.tearDown
    session=VoiceTests.session
    def batch(self,sid):
        bid=str(uuid.uuid4());data=bid.encode()*2000;data=data[:60000];data=data[:len(data)//40*40]
        path=self.store.root/(bid+'.cb08');path.write_bytes(data);h=hashlib.sha256(data).hexdigest()
        sequence=self.store.db.execute('SELECT count(*) FROM batches WHERE session_id=?',(sid,)).fetchone()[0]
        self.store.db.execute('INSERT INTO batches VALUES(?,?,?,?,?,?,?,?,?)',(bid,sid,sequence,bid,0,len(data),h,str(path),'test'));self.store.db.commit()
        return bid
    def engine(self):
        test=self
        class Fake:
            profile='control-model';speaker_hash='a'*64;calls=0;hook=None
            def analyze(inner,path,expected_hash):
                inner.calls+=1
                if inner.hook:inner.hook()
                observation={'source_sha256':expected_hash,'source_format':'raw_cb08_40','producer_version':'xinlika-sherpa-worker-v1',
                    'selection':{'start':0,'duration':30},'models':[{'name':'control.onnx','sha256':'a'*64}],
                    'speech_intervals':[{'start_seconds':0,'end_seconds':25}], 'scene_windows':[],
                    'speaker_windows':[], 'anonymous_clusters':0,'model_elapsed_seconds':1,'enrollment_present':False,'asr_called':False,'limits':[]}
                return {'observation':observation,'vectors':[test.v]*5,'speech_seconds':25,'clipped_fraction':0}
        return Fake()
    def test_future_batches_automatic_once_restart_without_historical_scan(self):
        sid=self.session(agent=True);old=self.batch(sid);engine=self.engine();worker=AcousticWorker(self.agent,engine)
        self.assertFalse(worker.tick());new=self.batch(sid);self.assertTrue(worker.tick());self.assertFalse(worker.tick())
        self.assertEqual(engine.calls,1);worker=AcousticWorker(self.agent,engine);self.assertFalse(worker.tick())
        rows=self.store.db.execute('SELECT batch_id,status FROM acoustic_jobs').fetchall()
        self.assertEqual([tuple(r) for r in rows],[(new,'completed')]);self.assertNotEqual(old,new)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
    def test_inflight_revocation_prevents_persist(self):
        sid=self.session(agent=True);engine=self.engine();worker=AcousticWorker(self.agent,engine);self.batch(sid)
        engine.hook=lambda:self.agent.policy(sid,asr=False,agent=False,source_kind='unknown')
        worker.tick();self.assertEqual(self.store.db.execute('SELECT count(*) FROM acoustic_observations').fetchone()[0],0)
        self.assertEqual(self.store.db.execute('SELECT status FROM acoustic_jobs').fetchone()[0],'blocked_permission')
    def test_expired_lease_is_recoverable_without_new_queue_identity(self):
        sid=self.session(agent=True);engine=self.engine();worker=AcousticWorker(self.agent,engine);self.batch(sid);q=worker.queue;q.discover(worker.profile)
        first=q.claim(worker.profile,'before',clock=100);second=q.claim(worker.profile,'after',clock=701)
        self.assertEqual(first['id'],second['id']);self.assertEqual(second['attempts'],2)
    def test_elapsed_telemetry_does_not_break_import_idempotency(self):
        sid=self.session(agent=True);engine=self.engine();worker=AcousticWorker(self.agent,engine);bid=self.batch(sid);worker.tick()
        row=self.store.db.execute('SELECT * FROM batches WHERE id=?',(bid,)).fetchone();result=engine.analyze(Path(row['filename']),row['sha256'])['observation']
        result['model_elapsed_seconds']=99
        self.agent.acoustics.import_probe(result)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM acoustic_observations').fetchone()[0],1)


if __name__=='__main__':unittest.main()

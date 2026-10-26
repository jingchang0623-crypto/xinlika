"""Durable isolated CPU worker: future sealed batches, no ASR or card controls."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import signal
import threading
import time
import uuid

from heartball_store import Store,Conflict
from heartball_agent_store import AgentStore


class AcousticQueue:
    def __init__(self,agent):
        self.agent,self.store,self.db,self.lock=agent,agent.store,agent.db,agent.lock
        with self.lock,self.store.transaction():
            self.db.execute('CREATE TABLE IF NOT EXISTS acoustic_workers(profile TEXT PRIMARY KEY,cursor INTEGER NOT NULL,heartbeat REAL,state TEXT NOT NULL,error TEXT)')
            self.db.execute('CREATE TABLE IF NOT EXISTS acoustic_jobs(id TEXT PRIMARY KEY,profile TEXT NOT NULL,batch_id TEXT NOT NULL,audio_hash TEXT NOT NULL,status TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,lease_owner TEXT,lease_until REAL,available_at REAL NOT NULL DEFAULT 0,error TEXT,observation_id TEXT,UNIQUE(profile,audio_hash))')

    def allowed(self,batch):
        return self.agent.allowed(batch['session_id'],'agent') or self.agent.voice.audio_granted(batch['session_id'])

    def initialize(self,profile):
        with self.lock,self.store.transaction():
            # First activation begins at the current ledger tip. Only explicitly
            # selected validation batches may backfill older audio.
            cursor=self.db.execute('SELECT coalesce(max(rowid),0) FROM batches').fetchone()[0]
            self.db.execute("INSERT OR IGNORE INTO acoustic_workers VALUES(?,?,?,'ready',NULL)",(profile,cursor,time.time()))

    def enqueue(self,profile,batch_id):
        with self.lock,self.store.transaction():
            batch=self.db.execute('SELECT * FROM batches WHERE id=?',(batch_id,)).fetchone()
            if not batch or not self.allowed(batch):raise Conflict('Acoustic processing not granted')
            self.db.execute("INSERT OR IGNORE INTO acoustic_jobs(id,profile,batch_id,audio_hash,status) VALUES(?,?,?,?,'queued')",(str(uuid.uuid4()),profile,batch_id,batch['sha256']))

    def discover(self,profile):
        with self.lock,self.store.transaction():
            cursor=self.db.execute('SELECT cursor FROM acoustic_workers WHERE profile=?',(profile,)).fetchone()[0]
            for row in self.db.execute('SELECT rowid,* FROM batches WHERE rowid>? ORDER BY rowid LIMIT 100',(cursor,)).fetchall():
                if self.allowed(row):self.enqueue(profile,row['id'])
                cursor=row['rowid']
            # A registration can be bound after its first batch arrives. Explicit
            # registration consent is independent of the ambient scan watermark.
            for row in self.db.execute("SELECT b.* FROM batches b JOIN voice_samples v ON v.session_id=b.session_id WHERE v.status='waiting_audio'").fetchall():
                if self.allowed(row):self.enqueue(profile,row['id'])
            self.db.execute("UPDATE acoustic_workers SET cursor=?,heartbeat=?,state='ready',error=NULL WHERE profile=?",(cursor,time.time(),profile))

    def claim(self,profile,owner,clock=None):
        clock=time.time() if clock is None else clock
        with self.lock,self.store.transaction():
            self.db.execute("UPDATE acoustic_jobs SET status='retryable',lease_owner=NULL WHERE status='running' AND lease_until<?",(clock,))
            row=self.db.execute("SELECT * FROM acoustic_jobs WHERE profile=? AND status IN ('queued','retryable') AND attempts<4 AND available_at<=? ORDER BY rowid LIMIT 1",(profile,clock)).fetchone()
            if not row:return None
            self.db.execute("UPDATE acoustic_jobs SET status='running',attempts=attempts+1,lease_owner=?,lease_until=? WHERE id=?",(owner,clock+600,row['id']))
            return dict(self.db.execute('SELECT * FROM acoustic_jobs WHERE id=?',(row['id'],)).fetchone())

    def status(self):
        with self.lock:
            row=self.db.execute('SELECT * FROM acoustic_workers ORDER BY heartbeat DESC LIMIT 1').fetchone()
            return {'enabled':row is not None,'last_heartbeat':row['heartbeat'] if row else None,
                'state':row['state'] if row and time.time()-(row['heartbeat'] or 0)<60 else 'offline',
                'error':row['error'] if row else None,
                'jobs':[dict(r) for r in self.db.execute('SELECT status,count(*) count FROM acoustic_jobs GROUP BY status')],
                'owner_identity_is_not_inferred_from_scene_labels':True}


class AcousticWorker:
    def __init__(self,agent,engine):
        self.agent,self.engine=agent,engine;self.queue=AcousticQueue(agent);self.profile=engine.profile
        self.queue.initialize(self.profile);self.owner=str(uuid.uuid4());self.cache=collections.OrderedDict()

    def infer(self,batch):
        if hashlib.sha256(Path(batch['filename']).read_bytes()).hexdigest()!=batch['sha256']:raise ValueError('Canonical audio changed')
        if batch['sha256'] not in self.cache:
            self.cache[batch['sha256']]=self.engine.analyze(Path(batch['filename']),batch['sha256'])
            while len(self.cache)>32:self.cache.popitem(last=False)
        return self.cache[batch['sha256']]

    def enrollment_tick(self):
        with self.agent.lock:
            samples=[dict(r) for r in self.agent.db.execute("SELECT v.* FROM voice_samples v JOIN sessions s ON s.id=v.session_id WHERE v.status='waiting_audio' AND s.status='completed'")]
        for sample in samples:
            with self.agent.lock:
                if not self.agent.voice.audio_granted(sample['session_id']):continue
                batches=[dict(r) for r in self.agent.db.execute('SELECT * FROM batches WHERE session_id=? ORDER BY sequence',(sample['session_id'],))]
                if not batches:continue
                # Three short dedicated sessions, never an unbounded recording.
                if sum(b['end_byte']-b['start_byte'] for b in batches)>600000:
                    with self.agent.store.transaction():self.agent.db.execute("UPDATE voice_samples SET status='rejected',metrics=? WHERE id=?",(json.dumps({'quality_gate':'sample_longer_than_300_seconds'}),sample['id']))
                    continue
                ready=all(self.agent.db.execute("SELECT 1 FROM acoustic_jobs WHERE profile=? AND audio_hash=? AND status='completed'",(self.profile,b['sha256'])).fetchone() for b in batches)
            if not ready:continue
            results=[self.infer(b) for b in batches]
            vectors=[v for r in results for v in r['vectors']]
            self.agent.voice.record_sample(sample,vectors,self.engine.speaker_hash,sum(r['speech_seconds'] for r in results),max(r['clipped_fraction'] for r in results))

    def tick(self):
        self.queue.discover(self.profile);job=self.queue.claim(self.profile,self.owner)
        if not job:
            self.enrollment_tick();return False
        try:
            with self.agent.lock:
                batch=dict(self.agent.db.execute('SELECT * FROM batches WHERE id=?',(job['batch_id'],)).fetchone())
                if not self.queue.allowed(batch):raise Conflict('Acoustic grant revoked')
            result=self.infer(batch)
            with self.agent.lock,self.agent.store.transaction():
                current=self.agent.db.execute('SELECT * FROM acoustic_jobs WHERE id=?',(job['id'],)).fetchone()
                if current['lease_owner']!=self.owner or current['status']!='running':raise Conflict('Acoustic lease changed')
                if not self.queue.allowed(batch):raise Conflict('Acoustic grant revoked')
                observation=self.agent.acoustics.import_probe(result['observation'])
                self.agent.voice.match(observation,result['observation']['speaker_windows'],result['vectors'],self.engine.speaker_hash)
                self.agent.db.execute("UPDATE acoustic_jobs SET status='completed',observation_id=?,error=NULL,lease_owner=NULL,lease_until=NULL WHERE id=?",(observation,job['id']))
            self.enrollment_tick()
        except Exception as error:
            with self.agent.lock,self.agent.store.transaction():
                status='blocked_permission' if isinstance(error,Conflict) else 'failed' if job['attempts']>=4 else 'retryable'
                self.agent.db.execute('UPDATE acoustic_jobs SET status=?,error=?,available_at=?,lease_owner=NULL,lease_until=NULL WHERE id=? AND lease_owner=?',(status,type(error).__name__,time.time()+min(300,5*2**job['attempts']),job['id'],self.owner))
        return True


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--workspace',type=Path,required=True);p.add_argument('--models',type=Path,required=True)
    p.add_argument('--backfill-batch-id',action='append',default=[]);p.add_argument('--once',action='store_true');a=p.parse_args()
    from heartball_acoustic_engine import AcousticEngine
    store=Store(a.workspace);agent=AgentStore(store);worker=AcousticWorker(agent,AcousticEngine(a.models))
    for bid in a.backfill_batch_id:worker.queue.enqueue(worker.profile,bid)
    stop=threading.Event()
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,lambda *_:stop.set())
    try:
        while not stop.is_set():
            try:worked=worker.tick()
            except Exception as error:
                with store.lock,store.transaction():store.db.execute("UPDATE acoustic_workers SET state='error',error=?,heartbeat=? WHERE profile=?",(type(error).__name__,time.time(),worker.profile))
                worked=False
            if a.once:break
            stop.wait(.1 if worked else 2)
    finally:store.db.close()


if __name__=='__main__':main()

"""Explicit fresh owner enrollment and revocable similarity observations.

No sample is enrolled from ambient history. A matching voice is not proof of a
live source or of a personal experience. Vectors never leave the private ledger.
"""
import datetime as dt
import json
import math
import uuid
from heartball_store import Conflict, identifier, now


def unit(vector):
    if not isinstance(vector, list) or not 16 <= len(vector) <= 2048 or any(type(x) not in (int,float) or not math.isfinite(x) for x in vector):
        raise ValueError('Invalid speaker embedding')
    norm=math.sqrt(sum(x*x for x in vector))
    if norm<1e-8:raise ValueError('Empty speaker embedding')
    return [x/norm for x in vector]


def similarity(a,b):
    if len(a)!=len(b):raise ValueError('Speaker model dimension changed')
    return sum(x*y for x,y in zip(a,b))


def centroid(vectors):
    vectors=[unit(v) for v in vectors]
    if not vectors or len({len(v) for v in vectors})!=1:raise ValueError('Incompatible embeddings')
    return unit([sum(v[i] for v in vectors)/len(vectors) for i in range(len(vectors[0]))])


class VoiceStore:
    def __init__(self,agent):
        self.agent,self.store,self.db,self.lock=agent,agent.store,agent.db,agent.lock
        with self.lock,self.store.transaction():
            self.db.execute('CREATE TABLE IF NOT EXISTS voice_enrollments(id TEXT PRIMARY KEY,device_id TEXT NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,expires_at TEXT NOT NULL)')
            self.db.execute('CREATE TABLE IF NOT EXISTS voice_samples(id TEXT PRIMARY KEY,enrollment_id TEXT NOT NULL,slot INTEGER NOT NULL,session_id TEXT UNIQUE NOT NULL,status TEXT NOT NULL,metrics TEXT,vector TEXT,model_hash TEXT)')
            self.db.execute("CREATE UNIQUE INDEX IF NOT EXISTS voice_current_slot ON voice_samples(enrollment_id,slot) WHERE status!='superseded'")
            self.db.execute('CREATE TABLE IF NOT EXISTS voice_profiles(version INTEGER PRIMARY KEY AUTOINCREMENT,enrollment_id TEXT NOT NULL,model_hash TEXT NOT NULL,vector TEXT,status TEXT NOT NULL,threshold REAL NOT NULL,created_at TEXT NOT NULL)')
            self.db.execute('CREATE TABLE IF NOT EXISTS voice_matches(observation_id TEXT NOT NULL,profile_version INTEGER NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(observation_id,profile_version))')

    def begin(self,eid,device_id,consent):
        eid=identifier(eid)
        if consent is not True:raise ValueError('Explicit owner enrollment consent required')
        with self.lock,self.store.transaction():
            old=self.db.execute('SELECT * FROM voice_enrollments WHERE id=?',(eid,)).fetchone()
            if old:
                if old['device_id']!=device_id:raise Conflict('Enrollment belongs to another device')
                return self.status()
            if self.db.execute("SELECT 1 FROM voice_enrollments WHERE status='collecting' AND expires_at>?",(now(),)).fetchone():raise Conflict('An enrollment is already collecting')
            expires=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(hours=24)).isoformat()
            self.db.execute("INSERT INTO voice_enrollments VALUES(?,?,'collecting',?,?)",(eid,device_id,now(),expires))
            return self.status()

    def bind(self,eid,slot,sid,device_id,solo):
        eid,sid=identifier(eid),identifier(sid)
        if type(slot) is not int or slot not in (1,2,3) or solo is not True:raise ValueError('Dedicated solo recording required')
        with self.lock,self.store.transaction():
            enrollment=self.db.execute("SELECT * FROM voice_enrollments WHERE id=? AND device_id=? AND status='collecting' AND expires_at>?",(eid,device_id,now())).fetchone()
            if not enrollment:raise Conflict('Enrollment inactive or belongs to another device')
            previous=self.db.execute("SELECT * FROM voice_samples WHERE enrollment_id=? AND slot=? AND status!='superseded'",(eid,slot)).fetchone()
            if previous and previous['session_id']==sid:return self.status()
            if previous and previous['status']!='rejected':raise Conflict('This enrollment sample is already bound')
            session=self.db.execute('SELECT * FROM sessions WHERE id=?',(sid,)).fetchone()
            if session and not self.owned_fresh(session,enrollment):raise Conflict('Use a fresh recording owned by the enrolling device')
            if previous:self.db.execute("UPDATE voice_samples SET status='superseded',vector=NULL WHERE id=?",(previous['id'],))
            self.db.execute("INSERT INTO voice_samples VALUES(?,?,?,?,'waiting_audio',NULL,NULL,NULL)",(str(uuid.uuid4()),eid,slot,sid))
            return self.status()

    def owned_fresh(self,session,enrollment):
        owner=self.db.execute('SELECT device_id FROM shared_session_owners WHERE session_id=?',(session['id'],)).fetchone()
        return bool(owner and owner[0]==enrollment['device_id'] and dt.datetime.fromisoformat(session['started_at'])>=dt.datetime.fromisoformat(enrollment['created_at'])-dt.timedelta(seconds=120))

    def audio_granted(self,sid):
        row=self.db.execute("SELECT e.* FROM voice_samples s JOIN voice_enrollments e ON e.id=s.enrollment_id WHERE s.session_id=? AND s.status IN ('waiting_audio','ready') AND e.status='collecting' AND e.expires_at>?",(sid,now())).fetchone()
        session=self.db.execute('SELECT * FROM sessions WHERE id=?',(sid,)).fetchone()
        return bool(row and session and self.owned_fresh(session,row))

    def active(self):
        return self.db.execute("SELECT * FROM voice_profiles WHERE status='active_provisional' AND vector IS NOT NULL ORDER BY version DESC LIMIT 1").fetchone()

    def record_sample(self,sample,vectors,model_hash,speech_seconds,clipped_fraction):
        # Caller supplies only fresh explicitly bound canonical recordings. Quality
        # thresholds are operational checks, not calibrated verification accuracy.
        with self.lock,self.store.transaction():
            if not self.audio_granted(sample['session_id']):raise Conflict('Enrollment grant changed')
            try:centre=centroid(vectors) if vectors else None
            except ValueError:centre=None
            scores=sorted(similarity(unit(v),centre) for v in vectors) if centre else []
            consistency=scores[max(0,len(scores)//10)] if scores else 0
            accepted=speech_seconds>=20 and len(vectors)>=4 and consistency>=.65 and clipped_fraction<.01
            metrics={'speech_seconds':speech_seconds,'windows':len(vectors),'within_sample_p10_similarity':consistency,'clipped_fraction':clipped_fraction,
                'quality_gate':'accepted' if accepted else 'need_cleaner_longer_solo_sample','not_an_accuracy_score':True}
            self.db.execute('UPDATE voice_samples SET status=?,metrics=?,vector=?,model_hash=? WHERE id=?',
                ('ready' if accepted else 'rejected',json.dumps(metrics),json.dumps(centre) if accepted else None,model_hash,sample['id']))
            self.finalize(sample['enrollment_id'])

    def finalize(self,eid):
        rows=self.db.execute("SELECT * FROM voice_samples WHERE enrollment_id=? AND status='ready' ORDER BY slot",(eid,)).fetchall()
        if len(rows)!=3:return
        if len({r['model_hash'] for r in rows})!=1:raise Conflict('Enrollment speaker models differ')
        first,second,holdout=[json.loads(r['vector']) for r in rows]
        try:
            if similarity(first,second)<.70:raise ValueError('Training samples inconsistent')
            reference=centroid([first,second])
        except ValueError:
            self.db.execute("UPDATE voice_samples SET status='rejected',vector=NULL WHERE id=?",(rows[1]['id'],));return
        if len(reference)!=len(holdout) or similarity(reference,holdout)<.70:
            self.db.execute("UPDATE voice_samples SET status='rejected',vector=NULL WHERE id=?",(rows[2]['id'],));return
        self.db.execute("UPDATE voice_profiles SET status='replaced',vector=NULL WHERE status='active_provisional'")
        self.db.execute("INSERT INTO voice_profiles(enrollment_id,model_hash,vector,status,threshold,created_at) VALUES(?,?,?,'active_provisional',.78,?)",(eid,rows[0]['model_hash'],json.dumps(reference),now()))
        self.db.execute("UPDATE voice_enrollments SET status='registered' WHERE id=?",(eid,))

    def match(self,observation_id,windows,vectors,model_hash):
        with self.lock,self.store.transaction():
            profile=self.active()
            if not profile or profile['model_hash']!=model_hash:return
            reference=json.loads(profile['vector']);values=[]
            for window,vector in zip(windows,vectors):
                score=similarity(unit(vector),reference)
                values.append({'start_seconds':window['start_seconds'],'end_seconds':window['end_seconds'],'cosine_similarity':score,
                    'match':'similar_to_owner' if score>=profile['threshold'] else 'not_matched',
                    'user_identity':'unverified','live_source_verified':False,'personal_attribution_allowed':False})
            payload={'profile_version':profile['version'],'calibration':'provisional_threshold_not_field_calibrated','windows':values}
            self.db.execute('INSERT OR IGNORE INTO voice_matches VALUES(?,?,?)',(observation_id,profile['version'],json.dumps(payload)))

    def hints(self,observation_id):
        profile=self.active()
        if not profile:return None
        r=self.db.execute('SELECT payload FROM voice_matches WHERE observation_id=? AND profile_version=?',(observation_id,profile['version'])).fetchone()
        return json.loads(r[0]) if r else None

    def revoke(self):
        with self.lock,self.store.transaction():
            self.db.execute("UPDATE voice_enrollments SET status='revoked' WHERE status IN ('collecting','registered')")
            self.db.execute("UPDATE voice_profiles SET status='revoked',vector=NULL")
            self.db.execute('UPDATE voice_samples SET vector=NULL')
            self.db.execute('DELETE FROM voice_matches')
            return self.status()

    def status(self):
        with self.lock:
            row=self.db.execute('SELECT * FROM voice_enrollments ORDER BY rowid DESC LIMIT 1').fetchone()
            samples=[{'slot':r['slot'],'session_id':r['session_id'],'status':r['status'],'metrics':json.loads(r['metrics']) if r['metrics'] else None} for r in self.db.execute("SELECT * FROM voice_samples WHERE enrollment_id=? AND status!='superseded' ORDER BY slot",(row['id'],))] if row else []
            profile=self.active()
            return {'enrollment_id':row['id'] if row else None,'status':row['status'] if row else 'not_enrolled','samples':samples,
                'profile_version':profile['version'] if profile else None,'calibration':'awaiting_field_negative_tests',
                'personal_attribution_allowed':False,'replay_detection_supported':False}

"""Versioned Watch PCM ingress. Existing CB08 messages remain unchanged."""
import base64
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import uuid
from zoneinfo import ZoneInfo

from heartball_store import Conflict, identifier
from heartball_mobile import timestamp

RATE = 32000
MAX_FRAMES = 960000


def canonical_wav(pcm):
    return struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', len(pcm)+36, b'WAVE', b'fmt ', 16,
                       1, 1, 16000, RATE, 2, 16, b'data', len(pcm)) + pcm


def wav_pcm(data):
    if not 46 <= len(data) <= MAX_FRAMES*2+44 or (len(data)-44) % 2:
        raise ValueError('Invalid PCM WAV size')
    pcm = data[44:]
    if canonical_wav(pcm) != data:
        raise ValueError('Only canonical 16 kHz mono signed 16-bit PCM WAV is supported')
    return pcm


class WatchIngest:
    def __init__(self, store, agent):
        self.store, self.agent, self.db = store, agent, store.db
        with store.lock, store.transaction():
            self.db.executescript('''
              CREATE TABLE IF NOT EXISTS watch_sessions(id TEXT PRIMARY KEY,manifest TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS watch_receipts(id TEXT PRIMARY KEY,digest TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS watch_segments(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,offset_ms INTEGER NOT NULL,frame_count INTEGER NOT NULL,
                UNIQUE(session_id,sequence));
            ''')

    def accept(self, body):
        mid = identifier(body['id'])
        digest = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()
        s, db = self.store, self.db
        with s.lock, s.transaction():
            old = db.execute('SELECT digest FROM watch_receipts WHERE id=?', (mid,)).fetchone()
            if old:
                if old[0] != digest: raise Conflict('Changed replay of an immutable Watch message')
                return {'id': mid, 'accepted': True, 'duplicate': True}
            manifest = body['session']; sid = identifier(manifest['id'])
            identifier(manifest['device_id']); identifier(manifest['workspace_id'])
            started = timestamp(manifest['started_at'])
            ZoneInfo(manifest['time_zone'])
            policy = manifest['processing']
            if (set(manifest) != {'schema_version','id','device_id','workspace_id','started_at','time_zone','capture_source','sample_rate','channels','processing'}
                or type(manifest['schema_version']) is not int or manifest['schema_version'] != 1
                or manifest['capture_source'] != 'apple_watch' or type(manifest['sample_rate']) is not int
                or manifest['sample_rate'] != 16000 or type(manifest['channels']) is not int or manifest['channels'] != 1
                or set(policy) != {'asr','agent','source_kind'}
                or policy['source_kind'] not in {'live_conversation','background_playback','unknown'}
                or any(type(policy[k]) is not bool for k in ('asr','agent'))):
                raise ValueError('Unsupported Watch manifest')
            encoded = json.dumps(manifest, sort_keys=True)
            prior = db.execute('SELECT manifest FROM watch_sessions WHERE id=?', (sid,)).fetchone()
            if prior and prior[0] != encoded: raise Conflict('Watch identity or processing policy changed')
            if not prior:
                if db.execute('SELECT 1 FROM sessions WHERE id=?', (sid,)).fetchone(): raise Conflict('Capture already belongs to another ingress')
                folder = s.root/'watch'/sid; folder.mkdir(parents=True, exist_ok=True, mode=0o700)
                db.execute("INSERT INTO sessions(id,status,started_at,batch_seconds,directory,owned_file) VALUES(?,'recording',?,60,?,?)",
                           (sid, manifest['started_at'], str(folder), 'watch-'+sid))
                db.execute('INSERT INTO audio_formats VALUES(?,?)', (sid,'pcm_s16le_16000'))
                db.execute('INSERT INTO watch_sessions VALUES(?,?)', (sid,encoded))
                self.agent.policy(sid, **policy, occurred_at=manifest['started_at'], time_precision='watch_sample_clock')
                s.event(sid, 'recording_context', {'capture_source':'apple_watch','time_zone':manifest['time_zone'],
                                                  'clock_basis':'watch_wall_clock_with_sample_offsets'})
            kind = body['kind']
            if kind == 'segment': self.segment(sid, mid, body, started)
            elif kind == 'focus': self.focus(sid, mid, body, started)
            elif kind == 'interrupted':
                offset = self.offset(body['offset_ms'])
                reason = body.get('reason','audio_interrupted')
                if not isinstance(reason,str) or len(reason)>120: raise ValueError('Invalid interruption')
                s.event(sid,'unexpected_disconnect',{'watch_offset_ms':offset,'reason':reason,'repair_status':'audio_not_recorded'})
            elif kind == 'ended':
                offset = self.offset(body['offset_ms']); count = body['segment_count']
                if type(count) is not int or not 0 <= count <= 100000: raise ValueError('Invalid final sequence')
                segments = db.execute('SELECT * FROM watch_segments WHERE session_id=? ORDER BY sequence',(sid,)).fetchall()
                if [r['sequence'] for r in segments] != list(range(count)): raise Conflict('Watch audio still incomplete')
                if any(r['offset_ms']+r['frame_count']/16 > offset+1 for r in segments): raise Conflict('End precedes saved audio')
                ended = (started+dt.timedelta(milliseconds=offset)).isoformat()
                prior_end = s.session(sid)['ended_at']
                if prior_end and timestamp(prior_end) != timestamp(ended): raise Conflict('Recording end changed')
                s.update_session(sid,status='completed',ended_at=ended,
                    archive=json.dumps({'status':'watch_segments_verified','segment_count':count,'capture_source':'apple_watch'}))
            else: raise ValueError('Unknown Watch message')
            db.execute('INSERT INTO watch_receipts VALUES(?,?)',(mid,digest))
            return {'id':mid,'accepted':True,'duplicate':False}

    @staticmethod
    def offset(value):
        if type(value) is not int or not 0 <= value < 7*86400000: raise ValueError('Invalid Watch offset')
        return value

    def audio_receipt(self, sid, bid, device_id, workspace_id):
        """Re-read canonical evidence before a relay can release its local WAV."""
        sid, bid = identifier(sid), identifier(bid)
        with self.store.lock:
            owner = self.db.execute('SELECT device_id FROM shared_session_owners WHERE session_id=?',(sid,)).fetchone()
            if not owner or owner[0] != device_id: raise PermissionError('Receipt belongs to original uploader')
            manifest = self.db.execute('SELECT manifest FROM watch_sessions WHERE id=?',(sid,)).fetchone()
            if not manifest or json.loads(manifest[0])['workspace_id'] != workspace_id:
                raise LookupError('Unknown Watch recording')
            if not self.agent.allowed(sid,'asr'): raise PermissionError('Audio access revoked')
            row = self.db.execute('SELECT w.*,b.filename,b.sha256 FROM watch_segments w JOIN batches b ON b.id=w.id WHERE w.session_id=? AND w.id=?',(sid,bid)).fetchone()
            if not row: raise LookupError('Unknown Watch segment')
            audio = Path(row['filename']).read_bytes()
            pcm = wav_pcm(audio)
            if len(pcm) != row['frame_count']*2 or hashlib.sha256(audio).hexdigest() != row['sha256']:
                raise Conflict('Remote Watch audio changed')
            return {'schema_version':1,'workspace_id':workspace_id,'device_id':device_id,
                'session_id':sid,'segment_id':bid,'sequence':row['sequence'],'offset_ms':row['offset_ms'],
                'frame_count':row['frame_count'],'byte_count':len(audio),'sha256':row['sha256'],'verified':True}

    def segment(self, sid, mid, body, started):
        db, s = self.db, self.store
        if s.session(sid)['status'] != 'recording': raise Conflict('Recording already ended')
        sequence, frames = body['sequence'], body['frame_count']; offset = self.offset(body['offset_ms'])
        if type(sequence) is not int or not 0<=sequence<100000 or type(frames) is not int or not 0<frames<=MAX_FRAMES:
            raise ValueError('Invalid Watch segment')
        if sequence != db.execute('SELECT count(*) FROM watch_segments WHERE session_id=?',(sid,)).fetchone()[0]:
            raise Conflict('Submit contiguous Watch sequence before finalizing')
        previous = db.execute('SELECT * FROM watch_segments WHERE session_id=? ORDER BY sequence DESC LIMIT 1',(sid,)).fetchone()
        if previous and offset < previous['offset_ms'] + previous['frame_count']/16 - 1:
            raise Conflict('Overlapping Watch sample intervals')
        audio = base64.b64decode(body['audio_base64'],validate=True); pcm = wav_pcm(audio)
        if len(pcm) != frames*2 or hashlib.sha256(audio).hexdigest() != body['sha256']: raise ValueError('Watch audio hash/frames mismatch')
        folder = Path(s.session(sid)['directory'])/'batches'; folder.mkdir(exist_ok=True,mode=0o700)
        path = folder/(mid+'.wav')
        if path.exists():
            if path.read_bytes()!=audio: raise Conflict('Existing Watch evidence changed')
        else:
            with path.open('xb') as f:
                os.chmod(path,0o600);f.write(audio);f.flush();os.fsync(f.fileno())
        first = (started+dt.timedelta(milliseconds=offset)).isoformat()
        last = (started+dt.timedelta(milliseconds=offset+frames/16)).isoformat()
        db.execute('INSERT INTO streams(id,session_id,filename,received,sealed,first_at,last_at) VALUES(?,?,?,?,?,?,?)',
                   (mid,sid,path.name,len(pcm),len(pcm),first,last))
        db.execute('INSERT INTO batches VALUES(?,?,?,?,?,?,?,?,?)',(mid,sid,sequence,mid,0,len(pcm),body['sha256'],str(path),'watch_segment'))
        db.execute('INSERT INTO watch_segments VALUES(?,?,?,?,?)',(mid,sid,sequence,offset,frames))
        s._job('asr_audio',body['sha256'],{'batch_id':mid,'sha256':body['sha256'],
            'source_kind':json.loads(db.execute('SELECT manifest FROM watch_sessions WHERE id=?',(sid,)).fetchone()[0])['processing']['source_kind'],
            'external_upload_allowed':False})

    def focus(self,sid,mid,body,started):
        begin,end=self.offset(body['offset_ms']),self.offset(body['end_ms'])
        if end<=begin:raise ValueError('Empty Watch focus')
        ranges=[]
        for row in self.db.execute('SELECT * FROM watch_segments WHERE session_id=? ORDER BY sequence',(sid,)):
            a=max(begin,row['offset_ms']);b=min(end,row['offset_ms']+row['frame_count']/16)
            if b>a:
                start=max(0,int((a-row['offset_ms'])*32)//2*2)
                stop=min(row['frame_count']*2,int((b-row['offset_ms'])*32)//2*2)
                if stop>start:ranges.append({'stream_id':row['id'],'start_byte':start,'end_byte':stop,'bytes_per_second':RATE})
        if not ranges: raise Conflict('Focus requires received audio')
        self.db.execute("INSERT INTO focuses(id,session_id,status,started_at,ended_at,start_positions,ranges,end_reason,boundary_basis) VALUES(?,?,'audio_saved',?,?,'{}',?,'user','watch_sample_range_with_batch_context')",
            (mid,sid,(started+dt.timedelta(milliseconds=begin)).isoformat(),(started+dt.timedelta(milliseconds=end)).isoformat(),json.dumps(ranges)))
        self.store._job('focus_analysis',mid,{'focus_id':mid,'ranges':ranges,'reuse_batch_transcripts':True,'create_personal_memory':False})

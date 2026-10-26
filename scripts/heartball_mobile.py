"""Phone-owned capture ingestion. No Bluetooth, subprocess, or Mac capture Engine."""
import base64
import datetime as dt
import hashlib
import json
import os
import uuid
from pathlib import Path

from heartball_store import Conflict, identifier


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError('Timestamp required')
    parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('Timezone required')
    return parsed


class MobileIngest:
    def __init__(self, store, agent):
        self.store, self.agent = store, agent
        with store.lock, store.transaction():
            store.db.executescript('''
              CREATE TABLE IF NOT EXISTS mobile_sessions(id TEXT PRIMARY KEY, manifest TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS mobile_receipts(id TEXT PRIMARY KEY, digest TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS mobile_card_segments(root_id TEXT NOT NULL,filename TEXT NOT NULL,
                session_id TEXT UNIQUE NOT NULL,previous_file TEXT NOT NULL,expected_bytes INTEGER NOT NULL,
                sha256 TEXT NOT NULL,started_at TEXT NOT NULL,PRIMARY KEY(root_id,filename));
            ''')

    def segments(self, root):
        root=identifier(root);result=[]
        with self.store.lock:
            rows=self.store.db.execute('SELECT * FROM sessions WHERE id=? OR id IN (SELECT session_id FROM mobile_card_segments WHERE root_id=?)',(root,root)).fetchall()
            for row in rows:
                proof=json.loads(row['archive'] or '{}')
                if proof.get('status')=='phone_card_bytes_verified':
                    result.append({'filename':row['owned_file'],'bytes':proof['bytes'],'sha256':proof['sha256'],'started_at':row['started_at']})
        return {'segments':result}

    def accept(self, body):
        # An immutable outbox message is the idempotency unit, including control
        # evidence. A changed replay is never acknowledged as the original.
        mid = identifier(body['id'])
        digest = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        s, db = self.store, self.store.db
        with s.lock, s.transaction():
            old = db.execute('SELECT digest FROM mobile_receipts WHERE id=?', (mid,)).fetchone()
            if old:
                if old[0] != digest:
                    raise Conflict('Message identity reused with different evidence')
                return {'id': mid, 'accepted': True, 'duplicate': True}
            manifest = body['session']
            sid = identifier(manifest['id'])
            identifier(manifest['device_id'])
            timestamp(manifest['started_at'])
            seconds = manifest['batch_seconds']
            policy = manifest['processing']
            if type(seconds) is not int or not 60 <= seconds <= 300:
                raise ValueError('Invalid batch duration')
            if not isinstance(manifest['card_file'], str) or not manifest['card_file'].startswith('note') or '/' in manifest['card_file'] or len(manifest['card_file']) > 64:
                raise ValueError('Invalid physical file identity')
            if set(policy) != {'asr', 'agent', 'source_kind'} or policy['source_kind'] not in {'live_conversation', 'background_playback', 'unknown'} or any(type(policy[k]) is not bool for k in ('asr', 'agent')):
                raise ValueError('Invalid processing permission')
            encoded = json.dumps(manifest, sort_keys=True)
            prior = db.execute('SELECT manifest FROM mobile_sessions WHERE id=?', (sid,)).fetchone()
            if prior and prior[0] != encoded:
                raise Conflict('Phone session identity or policy changed')
            if not prior:
                if db.execute('SELECT 1 FROM sessions WHERE id=?', (sid,)).fetchone():
                    raise Conflict('Session is not phone owned')
                recovery = self._validate_segment(manifest) if manifest.get('recovery') else None
                directory = s.root / 'mobile' / sid
                directory.mkdir(parents=True, exist_ok=True, mode=0o700)
                db.execute("INSERT INTO sessions(id,status,started_at,batch_seconds,directory,owned_file) VALUES(?,'recording',?,?,?,?)",
                           (sid, manifest['started_at'], seconds, str(directory), manifest['card_file']))
                db.execute('INSERT INTO mobile_sessions VALUES(?,?)', (sid, encoded))
                self.agent.policy(sid, **policy, occurred_at=manifest['started_at'], time_precision='device_filename_delta_from_phone_start' if recovery else 'phone_receive_start_estimate')
                if recovery:
                    db.execute('INSERT INTO mobile_card_segments VALUES(?,?,?,?,?,?,?)',
                      (recovery['root_id'],manifest['card_file'],sid,recovery['previous_file'],recovery['expected_bytes'],recovery['sha256'],manifest['started_at']))
            kind = body['kind']
            if kind == 'batch':
                self._batch(sid, body, manifest)
            elif kind == 'gap':
                timestamp(body['at'])
                s.event(sid, 'unexpected_disconnect', {'phone_at': body['at'], 'reason': body['reason'], 'repair_status': 'unresolved'})
            elif kind == 'focus':
                fid = identifier(body['focus_id'])
                timestamp(body['started_at']); timestamp(body['ended_at'])
                ranges = body['ranges']
                if not isinstance(ranges, list) or not ranges:
                    raise ValueError('No focus audio')
                for r in ranges:
                    stream = db.execute('SELECT * FROM streams WHERE id=? AND session_id=?', (identifier(r['stream_id']), sid)).fetchone()
                    if not stream or type(r['start_byte']) is not int or type(r['end_byte']) is not int or not 0 <= r['start_byte'] < r['end_byte'] <= stream['received'] or r['start_byte'] % 40 or r['end_byte'] % 40:
                        raise Conflict('Focus requires acknowledged audio ranges')
                db.execute("INSERT INTO focuses(id,session_id,status,started_at,ended_at,start_positions,ranges,end_reason) VALUES(?,?,'audio_saved',?,?,'{}',?,'user')",
                           (fid, sid, body['started_at'], body['ended_at'], json.dumps(ranges)))
                s._job('focus_analysis', fid, {'focus_id': fid, 'ranges': ranges, 'reuse_batch_transcripts': True, 'create_personal_memory': False})
            elif kind == 'reference_chunk':
                self._reference_chunk(sid, body)
            elif kind == 'reference_complete':
                self._reference_complete(sid, body)
            elif kind == 'finish':
                timestamp(body['at'])
                # Card-file reconciliation is a separate proof; network completion
                # does not prove that Bluetooth gaps or the device tail were recovered.
                session=s.session(sid)
                if session['status']=='completed':
                    if timestamp(session['ended_at'])!=timestamp(body['at']):raise Conflict('Saved end time changed')
                else:s.update_session(sid, status='completed', ended_at=body['at'], archive=json.dumps({'status': 'phone_saved_card_verification_pending'}))
            else:
                raise ValueError('Unknown mobile message')
            db.execute('INSERT INTO mobile_receipts VALUES(?,?)', (mid, digest))
            return {'id': mid, 'accepted': True, 'duplicate': False}

    def _validate_segment(self, manifest):
        from heartball_card_segments import continuation_clock,segment_id
        db=self.store.db;r=manifest['recovery']
        if set(r)!={'root_id','previous_file','previous_sha256','expected_bytes','sha256'}:raise ValueError('Invalid recovery lineage')
        root=identifier(r['root_id']);row=db.execute('SELECT manifest FROM mobile_sessions WHERE id=?',(root,)).fetchone()
        if not row:raise Conflict('Unknown original phone recording')
        original=json.loads(row[0]);session=self.store.session(root)
        if session['status']!='completed' or not session['ended_at'] or original.get('recovery'):raise Conflict('Original recording must be saved')
        if original['device_id']!=manifest['device_id'] or original['processing']!=manifest['processing'] or original['batch_seconds']!=manifest['batch_seconds']:raise Conflict('Segment device or permission changed')
        if manifest['id']!=segment_id(root,manifest['card_file']):raise Conflict('Segment must use its canonical identity')
        previous=root if r['previous_file']==original['card_file'] else None
        if previous is None:
            prior=db.execute('SELECT session_id FROM mobile_card_segments WHERE root_id=? AND filename=?',(root,r['previous_file'])).fetchone()
            if not prior:raise Conflict('Previous segment not verified')
            previous=prior[0]
        proof=json.loads(self.store.session(previous)['archive'] or '{}')
        if proof.get('status')!='phone_card_bytes_verified' or proof.get('sha256')!=r['previous_sha256']:raise Conflict('Previous file hash not verified')
        if not isinstance(r['sha256'],str) or len(r['sha256'])!=64 or any(c not in '0123456789abcdef' for c in r['sha256']):raise ValueError('Invalid segment hash')
        clock=continuation_clock(original,session['ended_at'],r['previous_file'],proof['bytes'],manifest['card_file'],r['expected_bytes'])
        if timestamp(clock)!=timestamp(manifest['started_at']):raise Conflict('Import time is not recording time')
        return r

    def _batch(self, sid, body, manifest):
        s, db = self.store, self.store.db
        stream_id = identifier(body['stream_id'])
        begin, end, sequence = body['start_byte'], body['end_byte'], body['sequence']
        if any(type(v) is not int for v in (begin, end, sequence)) or begin < 0 or sequence < 0 or end <= begin or begin % 40 or end % 40 or end - begin > manifest['batch_seconds'] * 2000:
            raise ValueError('Invalid codec range')
        first, received = timestamp(body['stream_started_at']), timestamp(body['received_at'])
        if received < first or first < timestamp(manifest['started_at']) - dt.timedelta(seconds=5):
            raise ValueError('Invalid capture clock')
        raw = base64.b64decode(body['audio_base64'], validate=True)
        digest = hashlib.sha256(raw).hexdigest()
        if len(raw) != end - begin or digest != body['sha256']:
            raise ValueError('Audio size or hash mismatch')
        stream = db.execute('SELECT * FROM streams WHERE id=?', (stream_id,)).fetchone()
        if stream and (stream['session_id'] != sid or stream['first_at'] != body['stream_started_at']):
            raise Conflict('Stream identity changed')
        if (stream['received'] if stream else 0) != begin:
            raise Conflict('Noncontiguous phone stream; use a new stream after a gap')
        if sequence != db.execute('SELECT COUNT(*) FROM batches WHERE session_id=?', (sid,)).fetchone()[0]:
            raise Conflict('Batch sequence is out of order')
        if s.session(sid)['status'] != 'recording':
            raise Conflict('Capture already finished')
        folder = Path(s.session(sid)['directory']) / 'batches'
        folder.mkdir(exist_ok=True, mode=0o700)
        path = folder / (identifier(body['id']) + '.cb08')
        if path.exists():
            if path.read_bytes() != raw:
                raise Conflict('Persisted audio differs')
        else:
            with path.open('xb') as out:
                os.chmod(path, 0o600); out.write(raw); out.flush(); os.fsync(out.fileno())
        if not stream:
            db.execute('INSERT INTO streams(id,session_id,filename,first_at,last_at) VALUES(?,?,?,?,?)',
                       (stream_id, sid, 'phone-' + stream_id + '.bin', body['stream_started_at'], body['received_at']))
        db.execute('UPDATE streams SET received=?,sealed=?,last_at=? WHERE id=?', (end, end, body['received_at'], stream_id))
        db.execute('INSERT INTO batches VALUES(?,?,?,?,?,?,?,?,?)',
                   (body['id'], sid, sequence, stream_id, begin, end, digest, str(path), body['reason']))
        s._job('asr_audio', digest, {'batch_id': body['id'], 'sha256': digest, 'source_kind': manifest['processing']['source_kind'], 'external_upload_allowed': False})

    def _reference_chunk(self, sid, body):
        session = self.store.session(sid)
        if session['status'] != 'completed':
            raise Conflict('Card reference is accepted only after saved capture')
        offset = body['offset']
        raw = base64.b64decode(body['audio_base64'], validate=True)
        if type(offset) is not int or offset < 0 or offset + len(raw) > 172800000 or offset % 40 or not 0 < len(raw) <= 600000 or len(raw) % 40 or hashlib.sha256(raw).hexdigest() != body['sha256']:
            raise ValueError('Invalid reference range')
        folder = Path(session['directory']) / 'reference-parts'
        folder.mkdir(exist_ok=True, mode=0o700)
        path = folder / str(offset)
        if path.exists():
            if path.read_bytes() != raw:
                raise Conflict('Reference part changed')
        else:
            with path.open('xb') as out:
                os.chmod(path, 0o600); out.write(raw); out.flush(); os.fsync(out.fileno())

    def _reference_complete(self, sid, body):
        s, db = self.store, self.store.db
        session = s.session(sid)
        expected = body['expected_bytes']
        if session['status'] != 'completed' or type(expected) is not int or not 0 < expected <= 172800000 or expected % 40 or body['end_code'] != 0 or body['card_file'] != session['owned_file']:
            raise ValueError('Saved card identity, size, or end code unconfirmed')
        folder = Path(session['directory'])
        (folder / 'batches').mkdir(exist_ok=True,mode=0o700)
        segment=db.execute('SELECT * FROM mobile_card_segments WHERE session_id=?',(sid,)).fetchone()
        if segment and (segment['expected_bytes']!=expected or segment['sha256']!=body['sha256']):raise Conflict('Segment identity changed')
        parts = sorted((folder / 'reference-parts').iterdir(), key=lambda p: int(p.name))
        data = bytearray()
        for part in parts:
            if int(part.name) != len(data):
                raise Conflict('Reference has an unfilled range')
            data.extend(part.read_bytes())
        if len(data) != expected or hashlib.sha256(data).hexdigest() != body['sha256']:
            raise ValueError('Complete reference size/hash mismatch')
        coverage = []
        origin = timestamp(json.loads(db.execute('SELECT manifest FROM mobile_sessions WHERE id=?',(sid,)).fetchone()[0])['started_at']) if db.execute('SELECT 1 FROM mobile_card_segments WHERE session_id=?',(sid,)).fetchone() else None
        for stream in db.execute("SELECT * FROM streams WHERE session_id=? AND filename NOT LIKE 'card-repair-%' ORDER BY rowid", (sid,)).fetchall():
            live = b''.join(Path(b['filename']).read_bytes() for b in db.execute('SELECT filename FROM batches WHERE stream_id=? ORDER BY start_byte', (stream['id'],)))
            at = data.find(live) if live else -1
            if at < 0 or at % 40 or data.find(live, at + 1) >= 0:
                raise Conflict('Reference alignment is missing or ambiguous')
            if coverage and at < coverage[-1][1]:
                raise Conflict('Reference stream ranges overlap or reorder')
            coverage.append([at, at + len(live)])
            if origin is None:
                origin = timestamp(stream['first_at']) - dt.timedelta(seconds=at / 2000)
        missing, cursor = [], 0
        for begin, end in coverage:
            if begin > cursor: missing.append([cursor, begin])
            cursor = end
        if cursor < len(data): missing.append([cursor, len(data)])
        card = folder / 'card-reference.cb08'
        with card.open('wb') as out:
            os.chmod(card, 0o600); out.write(data); out.flush(); os.fsync(out.fileno())
        proof = {'status': 'phone_card_bytes_verified', 'sha256': body['sha256'], 'bytes': expected,
                 'cardFile': str(card), 'liveCoverage': coverage, 'missingLiveRanges': missing,
                 'note': 'Identity, bytes, and exact alignment only; decode and semantic repair pending'}
        # Long missed ranges are real, disjoint card bytes, not guessed text or a
        # replay of already transcribed live audio. Tiny boundaries need context
        # review; do not feed isolated tail packets to ASR.
        proof['contextReviewRanges'] = [r for r in missing if r[1] - r[0] < 10000]
        proof['automaticRepairRanges'], proof['repairHashes'] = [], []
        manifest = json.loads(db.execute('SELECT manifest FROM mobile_sessions WHERE id=?', (sid,)).fetchone()[0])
        for begin, end in missing:
            if end - begin < 10000 or origin is None:
                continue
            stream_id = str(uuid.uuid5(uuid.UUID(sid), f'card-repair:{body["sha256"]}:{begin}:{end}'))
            first_at = (origin + dt.timedelta(seconds=begin / 2000)).isoformat()
            db.execute('INSERT OR IGNORE INTO streams(id,session_id,filename,received,sealed,first_at,last_at) VALUES(?,?,?,?,?,?,?)',
                       (stream_id, sid, 'card-repair-' + stream_id + '.bin', end - begin, end - begin, first_at, first_at))
            for start in range(begin, end, manifest['batch_seconds'] * 2000):
                stop = min(end, start + manifest['batch_seconds'] * 2000)
                raw = bytes(data[start:stop]); digest = hashlib.sha256(raw).hexdigest()
                bid = str(uuid.uuid5(uuid.UUID(stream_id), f'{start}:{stop}:{digest}'))
                if not db.execute('SELECT 1 FROM batches WHERE id=?', (bid,)).fetchone():
                    path = folder / 'batches' / (bid + '.cb08')
                    with path.open('wb') as out:
                        os.chmod(path, 0o600); out.write(raw); out.flush(); os.fsync(out.fileno())
                    sequence = db.execute('SELECT COALESCE(MAX(sequence),-1)+1 FROM batches WHERE session_id=?', (sid,)).fetchone()[0]
                    db.execute('INSERT INTO batches VALUES(?,?,?,?,?,?,?,?,?)',
                        (bid, sid, sequence, stream_id, start - begin, stop - begin, digest, str(path), 'card_gap_repair'))
                    s._job('asr_audio', digest, {'batch_id': bid, 'sha256': digest, 'source_kind': manifest['processing']['source_kind'], 'external_upload_allowed': False})
                    s.event(sid, 'card_gap_repair_queued', {'batch_id': bid, 'card_start_byte': start, 'card_end_byte': stop, 'card_sha256': body['sha256']})
                proof['automaticRepairRanges'].append({'cardRange': [start, stop], 'batchId': bid})
                proof['repairHashes'].append(digest)
        s.archive_review(sid, proof)

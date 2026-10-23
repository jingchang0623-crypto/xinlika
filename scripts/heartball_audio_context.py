"""Hash-bound acoustic observations, separate from semantic facts and identities.

The producer is an explicit local probe today. No inference, ASR, hardware I/O,
source-policy changes or automatic filtering happens in this module.
"""
import hashlib
import json
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator
from heartball_store import Conflict, now


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False)


class Shape(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)


class Interval(Shape):
    start_seconds: float = Field(ge=0)
    end_seconds: float = Field(gt=0)

    @model_validator(mode='after')
    def ordered(self):
        if self.end_seconds <= self.start_seconds:
            raise ValueError('Empty or reversed acoustic interval')
        return self


class Tag(Shape):
    name: str = Field(min_length=1, max_length=120)
    score: float = Field(ge=0, le=1)
    index: int = Field(ge=0)


class Scene(Interval):
    tags: list[Tag] = Field(max_length=16)
    source_medium: Literal['unknown'] = 'unknown'
    user_identity: Literal['unknown'] = 'unknown'


class Speaker(Interval):
    anonymous_cluster: str = Field(pattern=r'^speaker_[1-9][0-9]{0,3}$')
    best_similarity_before_assignment: float | None = Field(default=None, ge=-1.00001, le=1.00001)
    user_identity: Literal['not_enrolled'] = 'not_enrolled'
    boundary_precision: Literal['coarse_5s_window_not_verified_turn']


class Model(Shape):
    name: str = Field(min_length=1, max_length=120)
    sha256: str = Field(pattern=r'^[0-9a-f]{64}$')


class Selection(Shape):
    start: float = Field(ge=0)
    duration: float = Field(gt=0, le=300)


class Observation(Shape):
    source_sha256: str = Field(pattern=r'^[0-9a-f]{64}$')
    source_format: Literal['raw_cb08_40']
    producer_version: Literal['xinlika-sherpa-probe-v1','xinlika-sherpa-worker-v1']
    selection: Selection
    models: list[Model] = Field(min_length=1, max_length=8)
    speech_intervals: list[Interval] = Field(max_length=3000)
    scene_windows: list[Scene] = Field(max_length=300)
    speaker_windows: list[Speaker] = Field(max_length=300)
    anonymous_clusters: int = Field(ge=0, le=300)
    model_elapsed_seconds: float = Field(ge=0)
    enrollment_present: Literal[False]
    asr_called: Literal[False]
    limits: list[str] = Field(max_length=20)

    @model_validator(mode='after')
    def within_selection(self):
        begin, end = self.selection.start, self.selection.start + self.selection.duration
        for window in [*self.speech_intervals, *self.scene_windows, *self.speaker_windows]:
            if window.start_seconds < begin or window.end_seconds > end + 1e-6:
                raise ValueError('Acoustic window exceeds selected original audio')
        return self


class AudioContextStore:
    def __init__(self, agent):
        self.agent, self.db, self.lock = agent, agent.db, agent.lock
        with self.lock, agent.store.transaction():
            self.db.execute('CREATE TABLE IF NOT EXISTS acoustic_observations('
                'id TEXT PRIMARY KEY, slot TEXT UNIQUE NOT NULL, audio_hash TEXT NOT NULL, '
                'payload TEXT NOT NULL, created_at TEXT NOT NULL)')
            self.db.execute('CREATE INDEX IF NOT EXISTS acoustic_audio ON acoustic_observations(audio_hash)')

    def import_probe(self, value):
        value = Observation.model_validate(value).model_dump()
        payload = encode(value)
        semantic={k:v for k,v in value.items() if k!='model_elapsed_seconds'}
        digest = hashlib.sha256(encode(semantic).encode()).hexdigest()
        slot = hashlib.sha256(encode({k:value[k] for k in
            ('source_sha256', 'source_format', 'producer_version', 'selection', 'models')}).encode()).hexdigest()
        with self.lock, self.agent.store.transaction():
            batches = self.db.execute('SELECT * FROM batches WHERE sha256=?', (value['source_sha256'],)).fetchall()
            if not batches or not any(self.agent.allowed(b['session_id'], 'agent') or self.agent.voice.audio_granted(b['session_id']) for b in batches):
                raise Conflict('No authorized canonical audio matches this observation')
            length = value['selection']['start'] + value['selection']['duration']
            if any(length > (b['end_byte']-b['start_byte'])/2000 + 1e-6 for b in batches):
                raise ValueError('Observation exceeds canonical batch duration')
            old = self.db.execute('SELECT id,payload FROM acoustic_observations WHERE slot=?', (slot,)).fetchone()
            if old:
                prior=json.loads(old['payload']);prior.pop('model_elapsed_seconds',None)
                if prior!=semantic:raise Conflict('Same model/selection already has immutable observations')
                return old['id']
            self.db.execute('INSERT OR IGNORE INTO acoustic_observations VALUES(?,?,?,?,?)',
                (digest, slot, value['source_sha256'], payload, now()))
        return digest

    def signature(self):
        # Empty annotations must not trigger a historical analysis on upgrade.
        result=[r[0] for r in self.db.execute('SELECT id FROM acoustic_observations ORDER BY id')]
        profile=self.agent.voice.active()
        if profile:result.append('voice-profile:'+str(profile['version']))
        result.extend('voice-match:'+str(r[0])+':'+str(r[1]) for r in self.db.execute('SELECT observation_id,profile_version FROM voice_matches ORDER BY observation_id,profile_version'))
        return result

    @staticmethod
    def sample(rows, limit):
        if len(rows) <= limit:
            return rows
        return [rows[round(i*(len(rows)-1)/(limit-1))] for i in range(limit)]

    def for_document(self, doc):
        with self.lock:
            if not self.agent.allowed(doc['session_id'], 'agent') or doc.get('status') == 'superseded':
                return []
            evidence = doc.get('evidence', [])
            evidence = json.loads(evidence) if isinstance(evidence, str) else evidence
            result = []
            for ref in evidence:
                batch = self.db.execute('SELECT * FROM batches WHERE id=? AND session_id=? AND sha256=?',
                    (ref.get('batch_id'), doc['session_id'], ref.get('audio_hash'))).fetchone()
                if not batch:
                    continue
                for row in self.db.execute('SELECT * FROM acoustic_observations WHERE audio_hash=? ORDER BY rowid DESC LIMIT 2', (batch['sha256'],)):
                    value = json.loads(row['payload'])
                    scenes=[]
                    for window in self.sample(value['scene_windows'], 6):
                        scenes.append({**window,'tags':sorted(window['tags'],key=lambda t:t['score'],reverse=True)[:5],
                            'tag_count':len(window['tags'])})
                    hint={'observation_id':row['id'], 'batch_id':batch['id'],
                        'audio_hash':batch['sha256'], 'selection':value['selection'], 'models':value['models'],
                        'time_basis':'seconds_from_canonical_batch_start_not_word_alignment',
                        'stream_start_byte':batch['start_byte'],
                        'focus_includes_boundary_context':not ref.get('focus_exact_batches', True),
                        'scene_windows':scenes,
                        'scene_window_count':len(value['scene_windows']),
                        'speech_intervals':self.sample(value['speech_intervals'], 8),
                        'speech_interval_count':len(value['speech_intervals']),
                        'anonymous_speaker_windows':self.sample(value['speaker_windows'], 4),
                        'speaker_window_count':len(value['speaker_windows']),
                        'speaker_scope':'this_observation_only_not_cross_recording_identity',
                        'source_medium':'unknown', 'user_identity':'not_enrolled',
                        'context_scope':'bounded_sample_full_observation_persisted',
                        'authority':'uncalibrated_acoustic_hints_not_semantic_facts'}
                    voice=self.agent.voice.hints(row['id'])
                    if voice:
                        hint['owner_voice_similarity']={**voice,'windows':self.sample(voice['windows'],4),'window_count':len(voice['windows'])}
                        hint['user_identity']='unverified'
                    if len(encode(result+[hint]))<=12000:result.append(hint)
                if len(result) >= 4:
                    break
            return result


if __name__ == '__main__':
    import argparse
    from heartball_store import Store
    from heartball_agent_store import AgentStore
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--workspace', type=Path, required=True)
    p.add_argument('--probe-result', type=Path, required=True)
    args = p.parse_args()
    if args.probe_result.stat().st_size > 2_000_000:
        p.error('Probe result too large')
    store = Store(args.workspace)
    try:
        agent = AgentStore(store)
        identity = agent.acoustics.import_probe(json.loads(args.probe_result.read_text()))
        print(encode({'observation_id':identity, 'asr_called':False, 'source_policy_changed':False}))
    finally:
        store.db.close()

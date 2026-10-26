"""Semantic event consolidation over transport batches; original documents/audio are immutable."""
import hashlib
import json
import datetime as dt
from pydantic import BaseModel, ConfigDict, Field
from heartball_agent_store import encoded, stable
from heartball_recording_time import recording_time, event_sort_key
from heartball_store import Conflict, now
from heartball_content import has_semantic_content


def event_interval(db,event):
    """Conservative batch bounds, never a claimed word-level timestamp."""
    bounds=[]
    for row in db.execute('SELECT DISTINCT d.* FROM documents d JOIN workspace_event_sources s ON s.document_id=d.id WHERE s.event_id=?',(event['id'],)):
        doc=dict(row);clock=recording_time(db,doc).get('occurred_at')
        if not clock:continue
        try:
            start=dt.datetime.fromisoformat(clock.replace('Z','+00:00'))
            if start.tzinfo is None:continue
            evidence=json.loads(doc['evidence'])
            seconds=max([max(0,e['end_byte']-e['start_byte'])/2000 for e in evidence if 'start_byte' in e and 'end_byte' in e] or [60])
            bounds.append((start.timestamp(),start.timestamp()+seconds))
        except (ValueError,TypeError,KeyError):continue
    return (min(a for a,b in bounds),max(b for a,b in bounds)) if bounds else None


def crosses_other_discussion(db,group,context):
    selected={r['id'] for r in group['events']}
    intervals=[event_interval(db,e) for e in context['events'] if e['id'] in selected]
    if not intervals or any(x is None for x in intervals):return False
    intervals.sort();end=intervals[0][1]
    from heartball_card_segments import logical_members
    members=logical_members(db,context['session_id'])
    others=[event_interval(db,dict(e)) for e in db.execute("SELECT * FROM workspace_events WHERE session_id IN ("+','.join('?' for _ in members)+") AND status='active' AND kind!='focus'",members) if e['id'] not in selected]
    for begin,stop in intervals[1:]:
        if begin-end>300 and any(x and x[0]>=end and x[1]<=begin for x in others):return True
        end=max(end,stop)
    return False


class MergeRef(BaseModel):
    model_config = ConfigDict(extra='forbid')
    id: str
    version: int


class EventMerge(BaseModel):
    model_config = ConfigDict(extra='forbid')
    title: str = Field(min_length=1, max_length=100)
    summary: str = Field(min_length=1, max_length=1600)
    events: list[MergeRef] = Field(min_length=2, max_length=20)


class TranscriptOnlyRef(MergeRef):
    reason:str=Field(min_length=1,max_length=300)


class EventMerges(BaseModel):
    model_config = ConfigDict(extra='forbid')
    merges: list[EventMerge] = Field(default_factory=list, max_length=8)
    transcript_only:list[TranscriptOnlyRef]=Field(default_factory=list,max_length=16)


class EventMergeStore:
    def __init__(self, agent, refine=False, preserve_identity=False):
        self.agent, self.db, self.lock = agent, agent.db, agent.lock
        self.preserve_identity=preserve_identity
        with self.lock, agent.store.transaction():
            exists = self.db.execute("SELECT 1 FROM sqlite_master WHERE name='workspace_event_scans'").fetchone()
            self.db.execute('CREATE TABLE IF NOT EXISTS workspace_event_scans(session_id TEXT PRIMARY KEY,document_count INTEGER,finished INTEGER)')
            self.db.execute('CREATE TABLE IF NOT EXISTS workspace_event_merge_runs(run_key TEXT PRIMARY KEY)')
            self.db.execute('CREATE TABLE IF NOT EXISTS workspace_event_merge_coverage(event_id TEXT,version INTEGER,PRIMARY KEY(event_id,version))')
            self.db.execute('CREATE TABLE IF NOT EXISTS workspace_merge_migrations(key TEXT PRIMARY KEY)')
            self.db.execute('CREATE TABLE IF NOT EXISTS workspace_event_merge_parents(run_key TEXT,parent_id TEXT,event_id TEXT,PRIMARY KEY(run_key,parent_id))')
            self.db.execute('CREATE TABLE IF NOT EXISTS workspace_refined_ranges(event_id TEXT,document_id TEXT,revision INTEGER,start_char INTEGER,end_char INTEGER,quote TEXT,PRIMARY KEY(event_id,document_id,start_char,end_char))')
            # Repair only the reversible presentation state created by a previous
            # broad classifier. Raw documents/sources were never deleted.
            for row in self.db.execute("SELECT id FROM workspace_events WHERE status='transcript_only'").fetchall():
                quotes=' '.join(r[0] for r in self.db.execute('SELECT quote FROM workspace_event_sources WHERE event_id=?',(row['id'],)))
                if has_semantic_content(quotes):
                    self.db.execute("UPDATE workspace_events SET status='active',version=version+1 WHERE id=?",(row['id'],))
                    self.agent._invalidate_advice(row['id'])
            if not exists:
                self.db.execute("INSERT INTO workspace_event_scans SELECT s.id,(SELECT COUNT(*) FROM documents d WHERE d.session_id=s.id AND d.kind='ambient' AND d.status!='superseded'),s.status='completed' FROM sessions s")

        self.repair_unsafe_projection()
        from heartball_event_refinement import EventRefinementStore
        self.refinement=EventRefinementStore(agent) if refine else None
        if self.refinement:self.refinement.prime_history()

    def repair_unsafe_projection(self):
        """Replace reversible trial projections, never source audio/text or corrections."""
        with self.lock,self.agent.store.transaction():
            if self.db.execute("SELECT 1 FROM workspace_merge_migrations WHERE key='reviewed-evidence-v7'").fetchone():return
            unsafe=[dict(r) for r in self.db.execute("SELECT * FROM workspace_event_merge_parents WHERE run_key LIKE '%:window-v2:%' OR run_key LIKE '%:window-v3:%' OR run_key LIKE '%:window-v4:%' OR run_key LIKE '%:window-v5:%' OR run_key LIKE '%:window-v6:%'")]
            generated={r['event_id'] for r in unsafe};roots={r['parent_id'] for r in unsafe}-generated
            restored=[]
            for eid in roots:
                current=self.db.execute('SELECT status,session_id FROM workspace_events WHERE id=?',(eid,)).fetchone()
                if not current or current['status'] not in {'active','merged','transcript_only'}:continue
                sources=list(self.db.execute('SELECT s.revision,s.quote,d.revision current_revision,d.status,d.text FROM workspace_event_sources s JOIN documents d ON d.id=s.document_id WHERE s.event_id=?',(eid,)))
                if not sources or any(r['revision']!=r['current_revision'] or r['status']=='superseded' or r['quote'] not in r['text'] for r in sources):continue
                self.db.execute("UPDATE workspace_events SET status='active',version=version+1,updated_at=? WHERE id=?",(now(),eid))
                self.agent._invalidate_advice(eid);restored.append(eid)
            for eid in generated:
                self.db.execute("UPDATE workspace_events SET status='superseded',version=version+1,updated_at=? WHERE id=? AND status IN ('active','transcript_only')",(now(),eid))
                self.agent._invalidate_advice(eid)
            self.db.execute("UPDATE jobs SET status='superseded',lease_owner=NULL,lease_until=NULL,error='replaced_by_literal_evidence_projection' WHERE kind='event_consolidate' AND status IN ('queued','retryable','running') AND (input_key LIKE '%:window-v2:%' OR input_key LIKE '%:window-v3:%' OR input_key LIKE '%:window-v4:%' OR input_key LIKE '%:window-v5:%' OR input_key LIKE '%:window-v6:%')")
            self.db.execute("INSERT INTO workspace_merge_migrations VALUES('reviewed-evidence-v7')")
            if restored:self.agent.store.event(self.db.execute('SELECT session_id FROM workspace_events WHERE id=?',(restored[0],)).fetchone()[0],'semantic_projection_replaced',{'restored_events':len(restored),'superseded_generated':len(generated),'reason':'literal_evidence_required'})

    def schedule(self):
        with self.lock:
            sessions = [r[0] for r in self.db.execute("SELECT id FROM sessions WHERE status IN ('recording','reconciling','completed')")]
        for sid in sessions:
            self.request(sid, force=False)

    def request(self, sid, force=True):
        from heartball_card_segments import logical_root
        sid=logical_root(self.db,sid)
        with self.lock, self.agent.store.transaction():
            if not self.agent.allowed(sid, 'agent'):
                return False
            session = self.db.execute('SELECT status FROM sessions WHERE id=?', (sid,)).fetchone()
            if not session: return False
            from heartball_card_segments import logical_members
            members=logical_members(self.db,sid)
            docs = [dict(r) for r in self.db.execute("SELECT id,revision FROM documents WHERE session_id IN ("+','.join('?' for _ in members)+") AND kind='ambient' AND status NOT IN ('superseded','no_text','transcript_only') ORDER BY rowid", members)]
            finished = session[0] == 'completed'
            previous = self.db.execute('SELECT * FROM workspace_event_scans WHERE session_id=?', (sid,)).fetchone()
            count = len(docs)
            if not count:return False
            if not force and not previous and count < 3 and not finished:
                return False
            # A running model call owns its immutable context. Keep no queue of
            # obsolete document-count snapshots behind it.
            if self.db.execute("SELECT 1 FROM jobs WHERE kind='event_consolidate' AND status='running' AND json_extract(payload,'$.session_id')=?",(sid,)).fetchone():return False
            context=self.next_context(sid)
            if context is None:return False
            key=context['window_key']
            if self.db.execute("SELECT 1 FROM jobs WHERE kind='event_consolidate' AND input_key=? AND status IN ('queued','retryable')",(key,)).fetchone():return False
            self.db.execute("UPDATE jobs SET status='superseded',error='replaced_by_latest_context',lease_owner=NULL,lease_until=NULL WHERE kind='event_consolidate' AND status IN ('queued','retryable') AND json_extract(payload,'$.session_id')=? AND input_key!=?",(sid,key))
            self.db.execute('INSERT INTO workspace_event_scans VALUES(?,?,?) ON CONFLICT(session_id) DO UPDATE SET document_count=excluded.document_count,finished=excluded.finished', (sid,count,int(finished)))
            self.agent.enqueue('event_consolidate', key, {'session_id':sid,'run_key':key,'merge_context':context})
            return True

    def context(self, sid):
        with self.lock:
            from heartball_card_segments import logical_members
            members=logical_members(self.db,sid)
            events = [dict(r) for r in self.db.execute("SELECT * FROM workspace_events WHERE session_id IN ("+','.join('?' for _ in members)+") AND status='active' AND kind!='focus' ORDER BY rowid",members) if self.agent.allowed(r['session_id'],'agent')]
            for event in events:
                event['sources'] = [dict(r) for r in self.db.execute('SELECT document_id,revision,quote,precision FROM workspace_event_sources WHERE event_id=?', (event['id'],))]
                event['topic_id'] = next((r[0] for r in self.db.execute('SELECT topic_id FROM workspace_all_event_topics WHERE event_id=?', (event['id'],))), None)
            from heartball_timeline import visible
            events=[e for e in events if visible(self.db,e)]
            events=[e for e in events if has_semantic_content(' '.join(s['quote'] for s in e['sources']))]
            events.sort(key=lambda e:(event_sort_key(e),e['id']))
            return {'session_id':sid,'events':events}

    def next_context(self,sid):
        if self.refinement:return self.refinement.next_context(sid)
        context=self.context(sid)
        events=[e for e in context['events'] if not self.db.execute('SELECT 1 FROM workspace_event_merge_coverage WHERE event_id=? AND version=?',(e['id'],e['version'])).fetchone()]
        for start in range(0,len(events),6):
            window=events[start:start+8]
            if len(window)<2:continue
            key=sid+':window-v7:'+hashlib.sha256(encoded([(e['id'],e['version']) for e in window]).encode()).hexdigest()[:24]
            completed=self.db.execute('SELECT 1 FROM workspace_event_merge_runs WHERE run_key=?',(key,)).fetchone()
            terminal=self.db.execute("SELECT 1 FROM jobs WHERE input_key=? AND kind='event_consolidate' AND status IN ('failed','blocked_quality_review','blocked_provider')",(key,)).fetchone()
            if completed or terminal:continue
            return {'session_id':sid,'events':window,'window_key':key,'scope':'chronological_window_not_activity_boundary','final_window':start+8>=len(events)}
        return None

    def persist(self, key, value, context):
        if context.get('refinement'):
            if not self.refinement:raise ValueError('Source refiner not configured')
            return self.refinement.persist(key,value,context)
        with self.lock, self.agent.store.transaction():
            if self.db.execute('SELECT 1 FROM workspace_event_merge_runs WHERE run_key=?', (key,)).fetchone(): return
            from heartball_card_segments import logical_root
            candidates = {e['id']: e for e in context['events']}
            groups, seen = [], set()
            for proposal in value['merges']:
                if crosses_other_discussion(self.db,proposal,context):raise Conflict('Event merge crosses a later independent discussion; keep separate events and link their topic instead')
                sources, topic_ids, source_kinds = {}, set(), set()
                for ref in proposal['events']:
                    old = candidates.get(ref['id'])
                    current = self.db.execute('SELECT * FROM workspace_events WHERE id=?', (ref['id'],)).fetchone()
                    if ref['id'] in seen or not old or not current or old['version'] != ref['version'] or current['version'] != ref['version'] or current['status'] != 'active' or current['kind'] == 'focus' or logical_root(self.db,current['session_id']) != logical_root(self.db,context['session_id']):
                        raise Conflict('Event merge source changed')
                    if not self.agent.allowed(current['session_id'], 'agent'): raise Conflict('Merge permission revoked')
                    seen.add(ref['id']); source_kinds.add(current['source_kind'])
                    topic = self.db.execute('SELECT topic_id FROM workspace_all_event_topics WHERE event_id=?', (ref['id'],)).fetchone()
                    topic_ids.update(r[0] for r in self.db.execute('SELECT topic_id FROM workspace_all_event_topics WHERE event_id=?',(ref['id'],)))
                    for source in old['sources']:
                        doc = self.db.execute('SELECT * FROM documents WHERE id=?', (source['document_id'],)).fetchone()
                        if not doc or doc['revision'] != source['revision'] or doc['status'] == 'superseded' or source['quote'] not in doc['text']:
                            raise Conflict('Merged source transcript changed')
                        entry = sources.setdefault(doc['id'], {'doc':dict(doc),'spans':[]})
                        precise=list(self.db.execute('SELECT start_char,end_char FROM workspace_refined_ranges WHERE event_id=? AND document_id=? AND revision=? AND quote=?',(old['id'],doc['id'],source['revision'],source['quote'])))
                        if precise:entry['spans'].extend(tuple(r) for r in precise)
                        else:
                            begin=doc['text'].index(source['quote']);entry['spans'].append((begin,begin+len(source['quote'])))
                if len(proposal['events']) < 2 or len(source_kinds) != 1:
                    raise ValueError('Merge requires multiple events from one source and compatible sources')
                groups.append((proposal, sources, topic_ids, source_kinds.pop()))
            retained=[]
            for ref in value.get('transcript_only',[]):
                old=candidates.get(ref['id'])
                current=self.db.execute('SELECT * FROM workspace_events WHERE id=?',(ref['id'],)).fetchone()
                if ref['id'] in seen or not old or not current or old['version']!=ref['version'] or current['version']!=ref['version'] or current['status']!='active' or current['kind']=='focus':
                    raise Conflict('Transcript-only source changed or overlaps a merge')
                if not self.agent.allowed(current['session_id'],'agent'):raise Conflict('Processing permission revoked')
                for source in old['sources']:
                    doc=self.db.execute('SELECT * FROM documents WHERE id=?',(source['document_id'],)).fetchone()
                    if not doc or doc['revision']!=source['revision'] or doc['status']=='superseded' or source['quote'] not in doc['text']:raise Conflict('Transcript-only document changed')
                if has_semantic_content(' '.join(s['quote'] for s in old['sources'])):continue
                seen.add(ref['id']);retained.append(ref)
            for ref in retained:
                self.agent._invalidate_advice(ref['id'])
                self.db.execute("UPDATE workspace_events SET status='transcript_only',version=version+1,updated_at=? WHERE id=?",(now(),ref['id']))
                self.agent.store.event(context['session_id'],'semantic_transcript_only',{'event_id':ref['id'],'run_key':key,'reason':ref['reason']})
            for index, (proposal, sources, topic_ids, source_kind) in enumerate(groups):
                eid = stable('merged-event:' + key + ':' + str(index))
                ordered = sorted(sources.values(), key=lambda s:event_sort_key(recording_time(self.db,s['doc'])))
                occurred = recording_time(self.db,ordered[0]['doc'])['occurred_at']
                if self.preserve_identity:
                    eid=min(proposal['events'],key=lambda ref:(event_sort_key(candidates[ref['id']]),ref['id']))['id']
                    self.db.execute('UPDATE workspace_events SET title=?,summary=?,occurred_at=?,version=version+1,updated_at=? WHERE id=?',(proposal['title'],proposal['summary'],occurred,now(),eid))
                    self.db.execute('DELETE FROM workspace_event_sources WHERE event_id=?',(eid,))
                    self.db.execute('DELETE FROM workspace_refined_ranges WHERE event_id=?',(eid,))
                else:
                    self.db.execute("INSERT INTO workspace_events VALUES(?,?,'ambient',?,?,?,?,'active',1,?,?)", (eid,context['session_id'],proposal['title'],proposal['summary'],source_kind,occurred,now(),now()))
                for source in ordered:
                    doc, spans = source['doc'], sorted(source['spans'])
                    ranges=[]
                    for a,b in spans:
                        if ranges and a<=ranges[-1][1]:ranges[-1]=(ranges[-1][0],max(b,ranges[-1][1]))
                        else:ranges.append((a,b))
                    for begin,end in ranges:
                        self.db.execute('INSERT INTO workspace_event_sources VALUES(?,?,?,?,?)', (eid,doc['id'],doc['revision'],doc['text'][begin:end],'literal_anchor'))
                        self.db.execute('INSERT INTO workspace_refined_ranges VALUES(?,?,?,?,?,?)',(eid,doc['id'],doc['revision'],begin,end,doc['text'][begin:end]))
                for ref in proposal['events']:
                    self.agent._invalidate_advice(ref['id'])
                    if self.preserve_identity and ref['id']==eid:continue
                    self.db.execute("UPDATE workspace_events SET status='merged',version=version+1 WHERE id=?", (ref['id'],))
                    self.db.execute('INSERT INTO workspace_event_merge_parents VALUES(?,?,?)', (key,ref['id'],eid))
                version=self.db.execute('SELECT version FROM workspace_events WHERE id=?',(eid,)).fetchone()[0]
                self.db.execute('INSERT OR IGNORE INTO workspace_event_merge_coverage VALUES(?,?)',(eid,version))
                for topic_index,tid in enumerate(sorted(topic_ids)):
                    self.agent._invalidate_advice(tid)
                    if self.preserve_identity:
                        self.db.execute('INSERT OR IGNORE INTO workspace_event_topic_lineage VALUES(?,?)',(eid,tid))
                    else:
                        self.db.execute('INSERT INTO '+('workspace_event_topics' if topic_index==0 else 'workspace_event_topic_lineage')+' VALUES(?,?)', (eid,tid))
                    self.db.execute('UPDATE workspace_topics SET version=version+1,updated_at=? WHERE id=?', (now(),tid))
            inputs=context['events'] if context.get('final_window') else context['events'][:-2]
            for event in inputs:self.db.execute('INSERT OR IGNORE INTO workspace_event_merge_coverage VALUES(?,?)',(event['id'],event['version']))
            self.db.execute('INSERT INTO workspace_event_merge_runs VALUES(?)', (key,))

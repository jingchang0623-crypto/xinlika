"""Personal Agent observation -> response -> independent review, on the job ledger.

Design references and pinned prompt provenance: prompts/personal-agent/SOURCES.md.
Model notes never become facts. Delivery is an in-app card, never an external action.
"""
import datetime as dt
import hashlib
import json
import re
import time
from typing import Literal, TypedDict

from langgraph.graph import END, START, StateGraph
from langsmith import tracing_context
from pydantic import BaseModel, ConfigDict, Field

from heartball_agent_store import encoded, stable
from heartball_prompts import PROFILE
from heartball_store import Conflict, now


class Ref(BaseModel):
    model_config = ConfigDict(extra='forbid')
    id: str
    version: int = Field(ge=1)


class Observation(BaseModel):
    model_config = ConfigDict(extra='forbid')
    should_intervene: bool = False
    reason: str = Field(max_length=1200)
    working_note: str = Field(default='', max_length=1000)
    refs: list[Ref] = Field(default_factory=list, max_length=8)


class Response(BaseModel):
    model_config = ConfigDict(extra='forbid')
    kind: Literal['conflict', 'connection', 'follow_up', 'opportunity']
    title: str = Field(min_length=1, max_length=40)
    body: str = Field(min_length=1, max_length=240)
    refs: list[Ref] = Field(min_length=1, max_length=8)


class Review(BaseModel):
    model_config = ConfigDict(extra='forbid')
    approved: bool = False
    reason: str = Field(max_length=1200)


class State(TypedDict, total=False):
    run_key: str
    context: dict
    observation: dict
    response: dict
    review: dict


class PersonalAgent:
    # Audio transport is still 60 s. These are separate analysis/delivery budgets.
    scan_interval = 300
    delivery_cooldown = 900
    daily_limit = 6

    def __init__(self, agent, model, checkpointer):
        self.agent, self.model = agent, model
        self.db, self.lock = agent.db, agent.lock
        with self.lock, agent.store.transaction():
            self.db.execute('CREATE TABLE IF NOT EXISTS personal_agent_runs('
                'run_key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, status TEXT NOT NULL,'
                'context TEXT NOT NULL, observation TEXT, response TEXT, review TEXT,'
                'advice_id TEXT, created_at TEXT NOT NULL, finished_at TEXT)')
            self.db.execute('CREATE TABLE IF NOT EXISTS personal_agent_monitor('
                'id INTEGER PRIMARY KEY CHECK(id=1), fingerprint TEXT NOT NULL, last_scan REAL NOT NULL)')
            # Establish an upgrade baseline: do not re-send the historical archive.
            self.db.execute('INSERT OR IGNORE INTO personal_agent_monitor VALUES(1,?,?)',
                (self.fingerprint(), time.time()))
        graph = StateGraph(State)
        graph.add_node('observe', self.observe)
        graph.add_node('respond', self.respond)
        graph.add_node('review', self.review)
        graph.add_node('publish', self.publish)
        graph.add_edge(START, 'observe')
        graph.add_conditional_edges('observe', lambda s: 'respond' if s['observation']['should_intervene'] else 'publish')
        graph.add_edge('respond', 'review')
        graph.add_edge('review', 'publish')
        graph.add_edge('publish', END)
        self.graph = graph.compile(checkpointer=checkpointer)

    def documents(self):
        return [dict(r) for r in self.db.execute("SELECT d.* FROM documents d JOIN processing_policies p ON p.session_id=d.session_id "
            "WHERE p.agent_allowed=1 AND p.source_kind IN ('live_conversation','verified_text','unknown') "
            "AND d.source_kind IN ('live_conversation','verified_text','unknown') AND d.status NOT IN ('superseded','no_text') "
            "AND length(trim(d.text))>0 ORDER BY d.rowid DESC LIMIT 12")]

    def fingerprint(self):
        # Include current corrections, revocations, semantic organization, and
        # dismissals, even when none of the latest transcript strings changed.
        parts = []
        for table, columns in [('documents','id,revision,status'), ('claims','id,version,status'),
                ('workspace_events','id,version,status'), ('workspace_topics','id,version,status'),
                ('feedback','id'), ('processing_policies','session_id,agent_allowed,source_kind,updated_at'),
                ('preferences','key,value')]:
            parts.append([tuple(r) for r in self.db.execute('SELECT '+columns+' FROM '+table+' ORDER BY rowid')])
        if self.db.execute("SELECT 1 FROM sqlite_master WHERE name='workspace_activities'").fetchone():
            rows=[tuple(r) for r in self.db.execute('SELECT id,status,version FROM workspace_activities ORDER BY rowid')]
            if rows:parts.append(rows)
        hints=self.agent.acoustics.signature()
        if hints:parts.append(hints)
        return hashlib.sha256(encoded(parts).encode()).hexdigest()

    def controls(self):
        parts=[]
        for table,columns in [('feedback','id'),('preferences','key,value')]:
            parts.append([tuple(r) for r in self.db.execute('SELECT '+columns+' FROM '+table+' ORDER BY rowid')])
        return hashlib.sha256(encoded(parts).encode()).hexdigest()

    def valid_ref(self, ref):
        """Current version AND eligible provenance, checked again at delivery."""
        rid, version = ref['id'], ref['version']
        row = self.db.execute('SELECT * FROM claims WHERE id=?', (rid,)).fetchone()
        if row:
            doc = self.db.execute('SELECT * FROM documents WHERE id=?', (row['document_id'],)).fetchone()
            return (row['version']==version and row['status'] in {'proposed','confirmed','completed'}
                and self.eligible_doc(doc))
        doc = self.db.execute('SELECT * FROM documents WHERE id=?', (rid,)).fetchone()
        if doc: return doc['revision']==version and self.eligible_doc(doc)
        event = self.db.execute('SELECT * FROM workspace_events WHERE id=?', (rid,)).fetchone()
        if event:
            docs = self.db.execute('SELECT d.* FROM workspace_event_sources s JOIN documents d ON d.id=s.document_id WHERE s.event_id=?', (rid,)).fetchall()
            return (event['version']==version and event['status']=='active' and bool(docs)
                and all(self.eligible_doc(d) for d in docs))
        topic = self.db.execute('SELECT * FROM workspace_topics WHERE id=?', (rid,)).fetchone()
        if topic:
            events = self.db.execute('SELECT e.id,e.version FROM workspace_all_event_topics l JOIN workspace_events e ON e.id=l.event_id WHERE l.topic_id=?', (rid,)).fetchall()
            return (topic['version']==version and topic['status']=='active' and bool(events)
                and all(self.valid_ref(dict(e)) for e in events))
        return False

    def eligible_doc(self, doc):
        if not doc or doc['status'] in {'superseded','no_text'} or doc['source_kind'] not in {'live_conversation','verified_text','unknown'}:
            return False
        p = self.agent._policy(doc['session_id'])
        return bool(p.get('agent_allowed') and p.get('source_kind') in {'live_conversation','verified_text','unknown'})

    def context(self):
        docs = self.documents()
        records = {}
        # Cross-conversation retrieval goes beyond the UI's recent preview. Keep
        # provider input bounded; whole-day audio is never re-transcribed here.
        for doc in docs[:4]:
            records[doc['id']] = dict(id=doc['id'], version=doc['revision'], record_type='record',
                session_id=doc['session_id'], statement=doc['summary'], quote=doc['text'][:4000],
                source_kind=doc['source_kind'], occurred_at=doc['occurred_at'])
            hints=self.agent.acoustics.for_document(doc)
            if hints:records[doc['id']]['acoustic_hints']=hints
            for record in self.agent.query_context(question=doc['title']+' '+doc['summary'])[:20]:
                if self.valid_ref(record) and record['id'] not in records:records[record['id']] = record
        recent = {d['id'] for d in docs[:4]}
        for r in self.db.execute('SELECT id,document_id FROM claims WHERE document_id IN (SELECT value FROM json_each(?))', (encoded(list(recent)),)):
            if r['id'] in records:recent.add(r['id'])
        recent.update(r[0] for r in self.db.execute('SELECT DISTINCT event_id FROM workspace_event_sources WHERE document_id IN (SELECT value FROM json_each(?))', (encoded([d['id'] for d in docs[:4]]),)) if r[0] in records)
        advice = [dict(r) for r in self.db.execute("SELECT kind,title,body,status FROM advice ORDER BY rowid DESC LIMIT 25")]
        # Notes are explicitly tentative, and expire with their evidence versions.
        notes = []
        for row in self.db.execute("SELECT observation FROM personal_agent_runs WHERE finished_at IS NOT NULL AND observation IS NOT NULL ORDER BY rowid DESC LIMIT 4"):
            o = json.loads(row[0])
            if o.get('working_note') and o['refs'] and all(self.valid_ref(r) for r in o['refs']):
                notes.append({'note':o['working_note'], 'refs':o['refs'], 'authority':'tentative_observation'})
        # Soft budget measured in serialized characters. Keep entire records and
        # preserve the newest source first instead of truncating JSON arbitrarily.
        bounded = []
        for record in records.values():
            if len(encoded(bounded+[record])) <= 36000:bounded.append(record)
        activities=[]
        if self.db.execute("SELECT 1 FROM sqlite_master WHERE name='workspace_activities'").fetchone():
            from heartball_activities import activity_projection
            projection=activity_projection(self.db)
            by_id={a['id']:a for a in projection.values()}
            for a in list(by_id.values())[-8:]:
                refs=[dict(id=eid,version=self.db.execute('SELECT version FROM workspace_events WHERE id=?',(eid,)).fetchone()[0]) for eid,value in projection.items() if value['id']==a['id']]
                if all(self.valid_ref(r) for r in refs):activities.append({'title':a['title'],'summary':a['summary'],'kind':a['kind'],'refs':refs})
        return {'now':now(), 'records':bounded, 'recent_ids':sorted(recent), 'controls':self.controls(), 'prompt_profile':PROFILE,'activities':activities,
            'working_notes':notes, 'recent_advice':advice,
            'preferences':[dict(r) for r in self.db.execute("SELECT key,value FROM preferences WHERE key LIKE 'mute:%'")]}

    def schedule(self, clock=None):
        clock = time.time() if clock is None else clock
        with self.lock, self.agent.store.transaction():
            monitor = self.db.execute('SELECT * FROM personal_agent_monitor WHERE id=1').fetchone()
            if clock-monitor['last_scan']<self.scan_interval:return False
            fingerprint = self.fingerprint()
            if fingerprint==monitor['fingerprint']:
                self.db.execute('UPDATE personal_agent_monitor SET last_scan=? WHERE id=1',(clock,))
                return False
            if self.db.execute("SELECT 1 FROM jobs WHERE kind='personal_analysis' AND status IN ('queued','running','retryable')").fetchone():return False
            context = self.context()
            self.db.execute('UPDATE personal_agent_monitor SET fingerprint=?,last_scan=? WHERE id=1', (fingerprint,clock))
            if not context['records']:return False
            key = PROFILE['sha256']+':'+fingerprint
            self.db.execute("INSERT OR IGNORE INTO personal_agent_runs(run_key,fingerprint,status,context,created_at) VALUES(?,?,'queued',?,?)", (key,fingerprint,encoded(context),now()))
            self.agent.enqueue('personal_analysis',key,{'run_key':key})
            return True

    def check_refs(self, refs, context):
        allowed = {(r['id'],r['version']) for r in context['records']}
        if any((r['id'],r['version']) not in allowed for r in refs):
            raise ValueError('Agent output cites a record outside its input')

    def unclassified(self, refs, context):
        records={r['id']:r for r in context['records']}
        return any(records.get(r['id'],{}).get('source_kind')!='verified_text' and records.get(r['id'],{}).get('record_type')!='personal_memory' for r in refs)

    def observe(self, state):
        if getattr(self,'stopping',lambda:False)():raise InterruptedError('Stopping before model call')
        result = Observation.model_validate(self.model.personal_observe(state['context'])).model_dump()
        self.check_refs(result['refs'],state['context'])
        if result['should_intervene'] and not result['refs']:
            raise ValueError('Intervention needs evidence')
        return {'observation':result}

    def respond(self, state):
        if getattr(self,'stopping',lambda:False)():raise InterruptedError('Stopping before model call')
        value = Response.model_validate(self.model.personal_respond(state['context'],state['observation'])).model_dump()
        self.check_refs(value['refs'],state['context'])
        if not any(r['id'] in state['context']['recent_ids'] for r in value['refs']):
            raise ValueError('Agent response ignores the current observation')
        return {'response':value}

    def review(self, state):
        if getattr(self,'stopping',lambda:False)():raise InterruptedError('Stopping before model call')
        return {'review':Review.model_validate(self.model.personal_review(state['context'],state['observation'],state['response'])).model_dump()}

    def publish(self, state):
        with self.lock, self.agent.store.transaction():
            run = self.db.execute('SELECT * FROM personal_agent_runs WHERE run_key=?',(state['run_key'],)).fetchone()
            if run['finished_at']:return {}
            result, aid = 'quiet', None
            o, draft, review = state['observation'], state.get('response'), state.get('review')
            valid = all(self.valid_ref(r) for r in o['refs']) and (not draft or all(self.valid_ref(r) for r in draft['refs']))
            if not valid:result='stale'
            elif draft and review and review['approved']:
                # Context can change while the provider runs (user correction,
                # dismissal or policy revocation). Never publish its stale view.
                if self.controls()!=state['context']['controls']:result='stale'
                elif self.unclassified(draft['refs'],state['context']) and re.search(r'你|您|本人',draft['title']+draft['body']):result='rejected_attribution'
                else:
                    kind='personal_'+draft['kind']
                    latest=self.db.execute("SELECT created_at FROM advice WHERE kind LIKE 'personal_%' ORDER BY rowid DESC LIMIT 1").fetchone()
                    cutoff=(dt.datetime.now(dt.timezone.utc)-dt.timedelta(hours=24)).isoformat()
                    count=self.db.execute("SELECT count(*) FROM advice WHERE kind LIKE 'personal_%' AND created_at>=?",(cutoff,)).fetchone()[0]
                    muted=self.db.execute("SELECT 1 FROM preferences WHERE key=? AND value='true'",('mute:'+kind,)).fetchone()
                    if muted:result='muted'
                    elif count>=self.daily_limit or latest and time.time()-dt.datetime.fromisoformat(latest[0]).timestamp()<self.delivery_cooldown:result='limited'
                    else:
                        refs=sorted(draft['refs'],key=lambda r:r['id'])
                        # Changing wording/versions cannot re-notify the same issue.
                        dedup=kind+':'+encoded([r['id'] for r in refs])
                        aid=stable('advice:'+dedup)
                        exists=self.db.execute('SELECT 1 FROM advice WHERE dedup_key=?',(dedup,)).fetchone()
                        if exists:result='duplicate'
                        else:
                            body=('录音中的讨论：' if self.unclassified(refs,state['context']) else '')+draft['body']
                            self.db.execute("INSERT INTO advice VALUES(?,?,?,?,?,'active',?,?)",(aid,dedup,kind,draft['title'],body,encoded(refs),now()))
                            result='delivered'
            elif draft:result='rejected'
            self.db.execute('UPDATE personal_agent_runs SET status=?,observation=?,response=?,review=?,advice_id=?,finished_at=? WHERE run_key=?',
                (result,encoded(o),encoded(draft) if draft else None,encoded(review) if review else None,aid,now(),state['run_key']))
        return {}

    def run(self, key):
        with self.lock:
            row=self.db.execute('SELECT * FROM personal_agent_runs WHERE run_key=?',(key,)).fetchone()
            if not row or row['finished_at']:return
            context=json.loads(row['context'])
            # No provider request after an input was revoked or corrected.
            if self.fingerprint()!=row['fingerprint']:
                with self.agent.store.transaction():
                    self.db.execute("UPDATE personal_agent_runs SET status='stale',finished_at=? WHERE run_key=?",(now(),key))
                return
        config={'configurable':{'thread_id':'personal:'+key},'callbacks':[]}
        with tracing_context(enabled=False):
            snapshot=self.graph.get_state(config)
            if snapshot.values:
                if snapshot.next:self.graph.invoke(None,config)
            else:self.graph.invoke({'run_key':key,'context':context},config)

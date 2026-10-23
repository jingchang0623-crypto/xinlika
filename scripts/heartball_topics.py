"""Bounded retrospective topic linking over grounded events, on the existing ledger."""
import json
from pydantic import BaseModel, ConfigDict, Field
from heartball_agent_store import encoded, stable
from heartball_store import Conflict, now


class EventLink(BaseModel):
    model_config = ConfigDict(extra='forbid')
    id: str
    version: int


class TopicLink(BaseModel):
    model_config = ConfigDict(extra='forbid')
    topic_id: str | None = None
    title: str = Field(min_length=1, max_length=100)
    summary: str = Field(min_length=1, max_length=2200)
    events: list[EventLink] = Field(min_length=1, max_length=30)


class TopicLinks(BaseModel):
    model_config = ConfigDict(extra='forbid')
    topics: list[TopicLink] = Field(default_factory=list, max_length=6)


class TopicLinkStore:
    def __init__(self, agent):
        self.agent, self.db, self.lock = agent, agent.db, agent.lock
        with self.lock, agent.store.transaction():
            exists = self.db.execute("SELECT 1 FROM sqlite_master WHERE name='workspace_topic_scans'").fetchone()
            self.db.execute('CREATE TABLE IF NOT EXISTS workspace_topic_scans(session_id TEXT PRIMARY KEY,requested_at TEXT NOT NULL)')
            self.db.execute('CREATE TABLE IF NOT EXISTS workspace_topic_link_runs(run_key TEXT PRIMARY KEY)')
            if not exists:
                # Do not silently send the entire pre-upgrade archive back to a model.
                self.db.execute("INSERT INTO workspace_topic_scans SELECT id,? FROM sessions", (now(),))

    def schedule(self):
        with self.lock:
            ids = [r[0] for r in self.db.execute("SELECT id FROM sessions WHERE status='completed' AND id NOT IN (SELECT session_id FROM workspace_topic_scans)")]
        for sid in ids:
            self.request(sid)

    def request(self, sid):
        with self.lock, self.agent.store.transaction():
            if not self.agent.allowed(sid, 'agent'):
                return False
            policy = self.agent._policy(sid)
            if policy['source_kind'] not in {'live_conversation', 'verified_text'}:
                return False
            session = self.db.execute('SELECT status FROM sessions WHERE id=?', (sid,)).fetchone()
            if not session or session[0] != 'completed':
                return False
            pending = self.db.execute("SELECT COUNT(*) FROM batches b LEFT JOIN jobs j ON j.kind='ambient_analysis' AND j.input_key=b.id WHERE b.session_id=? AND (j.status IS NULL OR j.status!='completed')", (sid,)).fetchone()[0]
            if pending:
                return False
            key = 'completed-conversation:' + sid
            self.db.execute('INSERT OR IGNORE INTO workspace_topic_scans VALUES(?,?)', (sid, now()))
            self.agent.enqueue('topic_reconcile', key, {'session_id': sid, 'run_key': key})
            return True

    def context(self, sid):
        with self.lock:
            events = [dict(r) for r in self.db.execute("SELECT e.* FROM workspace_events e JOIN processing_policies p ON p.session_id=e.session_id LEFT JOIN workspace_all_event_topics l ON l.event_id=e.id WHERE e.status='active' AND e.kind!='focus' AND l.event_id IS NULL AND p.agent_allowed=1 AND e.source_kind IN ('live_conversation','verified_text') ORDER BY e.rowid DESC LIMIT 40")]
            for event in events:
                event['quote'] = '\n'.join(r[0] for r in self.db.execute('SELECT quote FROM workspace_event_sources WHERE event_id=?', (event['id'],)))[:1800]
                provenance = self.db.execute("SELECT payload FROM events WHERE session_id=? AND kind='recording_context' ORDER BY id DESC LIMIT 1", (event['session_id'],)).fetchone()
                event['recording_context'] = json.loads(provenance[0]) if provenance else None
            topics = [dict(r) for r in self.db.execute("SELECT * FROM workspace_topics WHERE status='active' AND source_group='conversation' ORDER BY updated_at DESC LIMIT 30")]
            return {'session_id': sid, 'events': events, 'topics': topics}

    def persist(self, run_key, value, context):
        with self.lock, self.agent.store.transaction():
            if self.db.execute('SELECT 1 FROM workspace_topic_link_runs WHERE run_key=?', (run_key,)).fetchone():
                return
            candidates = {e['id']: e for e in context['events']}
            topics = {t['id']: t for t in context['topics']}
            seen = set()
            # Validate the complete result before writing even one association.
            for proposal in value['topics']:
                sessions = set()
                tid = proposal.get('topic_id')
                if tid:
                    current = self.db.execute('SELECT * FROM workspace_topics WHERE id=?', (tid,)).fetchone()
                    if tid not in topics or not current or current['status'] != 'active' or current['version'] != topics[tid]['version']:
                        raise Conflict('Topic context changed')
                for ref in proposal['events']:
                    previous = candidates.get(ref['id'])
                    current = self.db.execute('SELECT * FROM workspace_events WHERE id=?', (ref['id'],)).fetchone()
                    if ref['id'] in seen or not previous or ref['version'] != previous['version'] or not current or current['status'] != 'active' or current['version'] != ref['version'] or self.db.execute('SELECT 1 FROM workspace_all_event_topics WHERE event_id=?', (ref['id'],)).fetchone():
                        raise Conflict('Event context changed or not available')
                    if not self.agent.allowed(current['session_id'], 'agent'):
                        raise Conflict('Event processing permission changed')
                    seen.add(ref['id']); sessions.add(current['session_id'])
                if not tid and len(sessions) < 2:
                    raise ValueError('Retrospective new topics require two conversations')
                if context['session_id'] not in sessions:
                    raise ValueError('Topic sweep must concern the triggering conversation')
            for index, proposal in enumerate(value['topics']):
                tid = proposal.get('topic_id') or stable('linked-topic:' + run_key + ':' + str(index))
                if proposal.get('topic_id'):
                    self.agent._invalidate_advice(tid)
                    self.db.execute('UPDATE workspace_topics SET summary=?,version=version+1,updated_at=? WHERE id=?', (proposal['summary'], now(), tid))
                else:
                    self.db.execute("INSERT INTO workspace_topics VALUES(?,?,?,'conversation','active',1,?)", (tid, proposal['title'], proposal['summary'], now()))
                for ref in proposal['events']:
                    self.agent._invalidate_advice(ref['id'])
                    self.db.execute('INSERT INTO workspace_event_topics VALUES(?,?)', (ref['id'], tid))
                    self.db.execute('UPDATE workspace_events SET version=version+1 WHERE id=?', (ref['id'],))
            self.db.execute('INSERT INTO workspace_topic_link_runs VALUES(?)', (run_key,))

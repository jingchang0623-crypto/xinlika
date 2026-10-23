"""Semantic events/topics on the existing ledger; model orchestration stays in LangGraph."""
import json
import re
from heartball_store import Conflict, now
from heartball_agent_store import encoded, stable
from heartball_recording_time import recording_time, event_sort_key


class OrganizationStore:
    def __init__(self, agent):
        self.agent, self.db, self.lock = agent, agent.db, agent.lock
        with self.lock:
            self.db.executescript('''
            CREATE TABLE IF NOT EXISTS workspace_events(
              id TEXT PRIMARY KEY,session_id TEXT NOT NULL,kind TEXT NOT NULL,title TEXT NOT NULL,
              summary TEXT NOT NULL,source_kind TEXT NOT NULL,occurred_at TEXT,status TEXT NOT NULL,
              version INTEGER NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS workspace_event_sources(
              event_id TEXT NOT NULL,document_id TEXT NOT NULL,revision INTEGER NOT NULL,quote TEXT NOT NULL,
              PRIMARY KEY(event_id,document_id));
            CREATE TABLE IF NOT EXISTS workspace_topics(
              id TEXT PRIMARY KEY,title TEXT NOT NULL,summary TEXT NOT NULL,source_group TEXT NOT NULL,
              status TEXT NOT NULL,version INTEGER NOT NULL,updated_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS workspace_event_topics(event_id TEXT PRIMARY KEY,topic_id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS workspace_event_topic_lineage(event_id TEXT NOT NULL,topic_id TEXT NOT NULL,PRIMARY KEY(event_id,topic_id));
            CREATE VIEW IF NOT EXISTS workspace_all_event_topics AS SELECT event_id,topic_id FROM workspace_event_topics UNION SELECT event_id,topic_id FROM workspace_event_topic_lineage;
            CREATE TABLE IF NOT EXISTS workspace_organization_runs(run_key TEXT PRIMARY KEY,document_id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS workspace_generations(document_id TEXT PRIMARY KEY,generation INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS workspace_source_document ON workspace_event_sources(document_id);
            ''')
            self.db.commit()
            if 'precision' not in {r[1] for r in self.db.execute('PRAGMA table_info(workspace_event_sources)')}:
                self.db.execute("ALTER TABLE workspace_event_sources ADD COLUMN precision TEXT NOT NULL DEFAULT 'literal_anchor'")
                self.db.commit()
            from heartball_timeline import ensure
            ensure(self.db);self.db.commit()
            # One matter may return after an unrelated sentence in the same
            # minute. Store separate literal ranges instead of their envelope.
            primary = [r[1] for r in self.db.execute('PRAGMA table_info(workspace_event_sources)') if r[5]]
            if primary == ['event_id', 'document_id']:
                with agent.store.transaction():
                    self.db.execute('ALTER TABLE workspace_event_sources RENAME TO workspace_event_sources_v1')
                    self.db.execute('CREATE TABLE workspace_event_sources(event_id TEXT NOT NULL,document_id TEXT NOT NULL,revision INTEGER NOT NULL,quote TEXT NOT NULL,precision TEXT NOT NULL,PRIMARY KEY(event_id,document_id,quote))')
                    self.db.execute('INSERT INTO workspace_event_sources SELECT * FROM workspace_event_sources_v1')
                    self.db.execute('DROP TABLE workspace_event_sources_v1')
                    self.db.execute('CREATE INDEX workspace_source_document ON workspace_event_sources(document_id)')

    @staticmethod
    def source_group(source):
        return 'conversation' if source in {'live_conversation', 'verified_text'} else source

    def run_key(self, doc):
        r = self.db.execute('SELECT generation FROM workspace_generations WHERE document_id=?', (doc['id'],)).fetchone()
        return doc['id'] + ':' + str(doc['revision']) + ':' + str(r[0] if r else 0) + ':semantic-v1'

    def schedule(self):
        with self.lock, self.agent.store.transaction():
            for row in self.db.execute("SELECT * FROM documents WHERE status NOT IN ('superseded','no_text','transcript_only') ORDER BY rowid").fetchall():
                doc = dict(row)
                if not doc['text'].strip() or not self.agent.allowed(doc['session_id'], 'agent'):
                    continue
                key = self.run_key(doc)
                if not self.db.execute('SELECT 1 FROM workspace_organization_runs WHERE run_key=?', (key,)).fetchone():
                    self.agent.enqueue('semantic_analysis', key, {'document_id':doc['id'], 'session_id':doc['session_id'], 'run_key':key})

    def context(self, doc):
        with self.lock:
            from heartball_card_segments import logical_members
            members=logical_members(self.db,doc['session_id'])
            candidates = [dict(r) for r in self.db.execute("SELECT * FROM workspace_events WHERE session_id IN ("+','.join('?' for _ in members)+") AND kind!='focus' AND status='active' ORDER BY rowid DESC LIMIT 50", members) if self.agent.allowed(r['session_id'],'agent')]
            current_key = event_sort_key(recording_time(self.db, doc))
            preceding = []
            for candidate in candidates:
                sources = [dict(r) for r in self.db.execute('SELECT d.* FROM documents d JOIN workspace_event_sources s ON s.document_id=d.id WHERE s.event_id=?', (candidate['id'],))]
                if any(s['id'] == doc['id'] for s in sources):
                    continue
                keys = [event_sort_key(recording_time(self.db, source)) for source in sources]
                # Focus priority/retries can finish newer audio first. Processing
                # insertion order must not make that future event a predecessor.
                if current_key[0] and (not keys or any(k[0] != current_key[0] or k > current_key for k in keys)):
                    continue
                preceding.append((max(keys, default=(0, '')), candidate))
            previous = [max(preceding, key=lambda pair: pair[0])[1]] if preceding else []
            for event in previous:
                event['sources'] = [dict(r) for r in self.db.execute('SELECT document_id,revision,quote FROM workspace_event_sources WHERE event_id=?',(event['id'],))]
            topics = [dict(r) for r in self.db.execute("SELECT * FROM workspace_topics WHERE status='active' AND source_group=? ORDER BY updated_at DESC LIMIT 40", (self.source_group(doc['source_kind']),))]
            corrections = [dict(r) for r in self.db.execute("SELECT statement,owner,due_at,status FROM claims WHERE document_id=? AND status IN ('confirmed','completed')", (doc['id'],))]
            unassigned=[dict(r) for r in self.db.execute("SELECT e.* FROM workspace_events e LEFT JOIN workspace_all_event_topics l ON l.event_id=e.id WHERE e.status='active' AND e.kind!='focus' AND l.event_id IS NULL ORDER BY e.rowid DESC LIMIT 40") if self.source_group(r['source_kind'])==self.source_group(doc['source_kind'])]
            return {'previous_events':previous, 'topics':topics, 'unassigned_events':unassigned, 'corrections':corrections, 'run_key':self.run_key(doc)}

    def persist(self, doc, value, context):
        with self.lock, self.agent.store.transaction():
            current = self.db.execute('SELECT * FROM documents WHERE id=?', (doc['id'],)).fetchone()
            if not current or current['status'] == 'superseded' or current['revision'] != doc['revision'] or self.run_key(dict(current)) != context['run_key']:
                raise Conflict('Source changed during organization')
            if self.db.execute('SELECT 1 FROM workspace_organization_runs WHERE run_key=?', (context['run_key'],)).fetchone():
                return
            from heartball_card_segments import logical_root
            previous = {e['id']:e for e in context['previous_events']}
            topics = {t['id']:t for t in context['topics']}
            # Validate the whole model result before mutating any event or topic.
            spans = []
            for i, event in enumerate(value['events']):
                for quote in event.get('_literal_quotes') or [event['quote']]:
                    if not quote.strip() or quote not in doc['text']:
                        raise ValueError('Event quote is not in the source transcript')
                    start = doc['text'].index(quote)
                    spans.append((start,start+len(quote)))
                continuation = event.get('continues_id')
                if continuation:
                    row = self.db.execute('SELECT * FROM workspace_events WHERE id=?', (continuation,)).fetchone()
                    if i != 0 or doc['kind']=='focus' or continuation not in previous or not row or row['status']!='active' or row['version']!=previous[continuation]['version'] or logical_root(self.db,row['session_id'])!=logical_root(self.db,doc['session_id']) or self.source_group(row['source_kind'])!=self.source_group(doc['source_kind']):
                        raise Conflict('Event continuation changed or crosses a conversation')
                tid = event.get('topic_id')
                if tid:
                    row = self.db.execute('SELECT * FROM workspace_topics WHERE id=?', (tid,)).fetchone()
                    if tid not in topics or not row or row['status']!='active' or row['version']!=topics[tid]['version']:
                        raise Conflict('Topic context changed')
                for related in event.get('related_event_ids',[]):
                    candidate=next((e for e in context.get('unassigned_events',[]) if e['id']==related),None)
                    row=self.db.execute('SELECT * FROM workspace_events WHERE id=?',(related,)).fetchone()
                    if not candidate or not row or row['status']!='active' or row['version']!=candidate['version'] or self.db.execute('SELECT 1 FROM workspace_all_event_topics WHERE event_id=?',(related,)).fetchone():
                        raise Conflict('Related event changed or already has a topic')
                    if not tid and not event.get('topic_title'):raise ValueError('Related events require a topic')
            for i, event in enumerate(value['events']):
                eid = event.get('continues_id') or stable('event:'+context['run_key']+':'+str(i))
                if event.get('continues_id'):
                    self.agent._invalidate_advice(eid)
                    self.db.execute('UPDATE workspace_events SET title=?,summary=?,version=version+1,updated_at=? WHERE id=?', (event['title'],event['summary'],now(),eid))
                else:
                    self.db.execute("INSERT INTO workspace_events VALUES(?,?,?,?,?,?,?,'active',1,?,?)", (eid,doc['session_id'],doc['kind'],event['title'],event['summary'],doc['source_kind'],doc.get('occurred_at'),now(),now()))
                for quote in event.get('_literal_quotes') or [event['quote']]:
                    self.db.execute('INSERT OR IGNORE INTO workspace_event_sources(event_id,document_id,revision,quote,precision) VALUES(?,?,?,?,?)', (eid,doc['id'],doc['revision'],quote,event.get('_source_precision','literal_anchor')))
                from heartball_timeline import save
                current=dict(self.db.execute('SELECT * FROM workspace_events WHERE id=?',(eid,)).fetchone())
                save(self.db,current,event.get('display','event'),'semantic_source_admission')
                tid = event.get('topic_id')
                if not tid and event.get('topic_title'):
                    tid = stable('topic:'+context['run_key']+':'+str(i))
                    self.db.execute("INSERT INTO workspace_topics VALUES(?,?,?,?,'active',1,?)", (tid,event['topic_title'],event.get('topic_summary') or event['summary'],self.source_group(doc['source_kind']),now()))
                elif tid and doc['kind']!='focus':
                    self.agent._invalidate_advice(tid)
                    self.db.execute('UPDATE workspace_topics SET summary=?,version=version+1,updated_at=? WHERE id=?', (event.get('topic_summary') or event['summary'],now(),tid))
                if tid:
                    self.db.execute('INSERT OR REPLACE INTO workspace_event_topics VALUES(?,?)', (eid,tid))
                    for related in event.get('related_event_ids',[]):
                        self.db.execute('INSERT OR REPLACE INTO workspace_event_topics VALUES(?,?)',(related,tid))
                        self.db.execute('UPDATE workspace_events SET version=version+1 WHERE id=?',(related,))
                        self.agent._invalidate_advice(related)
            self.db.execute('INSERT INTO workspace_organization_runs VALUES(?,?)', (context['run_key'],doc['id']))
            if value['events']:
                self.db.execute("UPDATE memory_answers SET status='outdated' WHERE status='ready' AND refs='[]'")

    def invalidate_document(self, did):
        # Invalidate the whole spanning event and its derived topic immediately.
        affected, pending, seen_events, seen_topics = set(), [did], set(), set()
        while pending:
            document_id = pending.pop()
            if document_id in affected: continue
            affected.add(document_id)
            for source in self.db.execute("SELECT s.event_id FROM workspace_event_sources s JOIN workspace_events e ON e.id=s.event_id WHERE s.document_id=? AND e.status IN ('active','fragment')", (document_id,)).fetchall():
                eid = source[0]
                if eid in seen_events: continue
                seen_events.add(eid)
                self.db.execute("UPDATE workspace_events SET status='invalidated',version=version+1 WHERE id=?", (eid,))
                self.agent._invalidate_advice(eid)
                pending.extend(r[0] for r in self.db.execute('SELECT document_id FROM workspace_event_sources WHERE event_id=?', (eid,)))
                for link in self.db.execute('SELECT topic_id FROM workspace_all_event_topics WHERE event_id=?', (eid,)).fetchall():
                    tid=link[0]
                    if tid in seen_topics:continue
                    seen_topics.add(tid)
                    self.db.execute("UPDATE workspace_topics SET status='invalidated',version=version+1 WHERE id=?", (tid,))
                    self.agent._invalidate_advice(tid)
                    pending.extend(r[0] for r in self.db.execute("SELECT s.document_id FROM workspace_event_sources s JOIN workspace_all_event_topics t ON t.event_id=s.event_id JOIN workspace_events e ON e.id=s.event_id WHERE t.topic_id=? AND e.status='active'",(tid,)))
        for document_id in affected:
            self.db.execute('INSERT INTO workspace_generations VALUES(?,1) ON CONFLICT(document_id) DO UPDATE SET generation=generation+1', (document_id,))
            self.db.execute('DELETE FROM workspace_organization_runs WHERE document_id=?', (document_id,))

    def state(self):
        with self.lock:
            events = [dict(r) for r in self.db.execute("SELECT * FROM workspace_events WHERE status='active' ORDER BY rowid DESC LIMIT 500")]
            for e in events:
                e['sources'] = [dict(r) for r in self.db.execute('SELECT document_id,revision,quote,precision FROM workspace_event_sources WHERE event_id=? ORDER BY rowid', (e['id'],))]
                e['topic_id'] = next((r[0] for r in self.db.execute('SELECT topic_id FROM workspace_all_event_topics WHERE event_id=?', (e['id'],))),None)
                e.update(self.event_clock(e['id']))
            events.sort(key=event_sort_key,reverse=True)
            events=events[:100]
            topics = [dict(r) for r in self.db.execute("SELECT * FROM workspace_topics WHERE status='active' ORDER BY updated_at DESC LIMIT 60")]
            for t in topics:
                ids={r[0] for r in self.db.execute("SELECT e.id FROM workspace_events e JOIN workspace_all_event_topics l ON e.id=l.event_id WHERE l.topic_id=? AND e.status='active'",(t['id'],))}
                t['event_ids']=[e['id'] for e in reversed(events) if e['id'] in ids]
                t['conversation_count'] = self.db.execute("SELECT COUNT(DISTINCT e.session_id) FROM workspace_events e JOIN workspace_all_event_topics l ON e.id=l.event_id WHERE l.topic_id=? AND e.status='active'", (t['id'],)).fetchone()[0]
            received=self.db.execute('SELECT last_at FROM streams ORDER BY rowid DESC LIMIT 1').fetchone()
            organized=self.db.execute("SELECT MAX(updated_at) FROM workspace_events WHERE status='active'").fetchone()
            return {'events':events,'topics':[t for t in topics if t['event_ids']],
                    'workspaceProgress':{'receivedAt':received[0] if received else None,'organizedAt':organized[0]}}

    def event_clock(self,eid):
        clocks=[recording_time(self.db,dict(r)) for r in self.db.execute('SELECT DISTINCT d.* FROM documents d JOIN workspace_event_sources s ON s.document_id=d.id WHERE s.event_id=?',(eid,))]
        known=[c for c in clocks if event_sort_key(c)[0]]
        return min(known,key=event_sort_key) if known else {'occurred_at':None,'recorded_local_time':None,'recording_time_basis':'unknown'}

    def query_context(self, ids=None):
        state = self.state()
        if ids:
            present={r['id'] for r in state['events']+state['topics']}
            for identity in ids-present:
                row=self.db.execute("SELECT * FROM workspace_events WHERE id=? AND status='active'",(identity,)).fetchone()
                if row:
                    event=dict(row)
                    event['sources']=[dict(r) for r in self.db.execute('SELECT document_id,revision,quote FROM workspace_event_sources WHERE event_id=?',(identity,))]
                    event['topic_id']=next((r[0] for r in self.db.execute('SELECT topic_id FROM workspace_all_event_topics WHERE event_id=?',(identity,))),None)
                    event.update(self.event_clock(identity))
                    state['events'].append(event)
                row=self.db.execute("SELECT * FROM workspace_topics WHERE id=? AND status='active'",(identity,)).fetchone()
                if row:
                    topic=dict(row);topic['event_ids']=[r[0] for r in self.db.execute("SELECT e.id FROM workspace_events e JOIN workspace_all_event_topics l ON l.event_id=e.id WHERE l.topic_id=? AND e.status='active'",(identity,))]
                    state['topics'].append(topic)
        return [dict(id=e['id'],version=e['version'],record_type='event',statement=e['summary'],title=e['title'],source_kind=e['source_kind'],occurred_at=e['occurred_at'],recorded_local_time=e['recorded_local_time'],recording_time_basis=e['recording_time_basis'],topic_id=e['topic_id'],quote='\n'.join(s['quote'] for s in e['sources'])[:6000]) for e in state['events']] + [dict(id=t['id'],version=t['version'],record_type='topic',statement=t['summary'],title=t['title'],source_kind=t['source_group'],event_ids=t['event_ids']) for t in state['topics']]

    def validate_ref(self, ref):
        for table in ('workspace_events','workspace_topics'):
            row = self.db.execute('SELECT version,status FROM '+table+' WHERE id=?', (ref['id'],)).fetchone()
            if row:
                if row['version']!=ref['version'] or row['status']!='active':raise Conflict('Answer cites an outdated event or topic')
                return True
        return False

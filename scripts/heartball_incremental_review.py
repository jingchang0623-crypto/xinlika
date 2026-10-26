"""Optional rolling consolidation of already committed incremental evidence.

Dayflow's rolling lookback is adapted; the existing event merger owns validation
and transactions. Never sends audio, requests ASR, deletes sources, or rewrites
memories. Each source-watermark window is reviewed once, with a fixed call budget.
"""
import hashlib
import json
from pathlib import Path
import time

from heartball_agent_store import encoded
from heartball_event_merge import EventMergeStore,EventMerges,crosses_other_discussion
from heartball_incremental import IncrementalDomain,instant
from heartball_incremental_reuse import rolling_contains
from heartball_runtime_adapters import ModelMeter,private_json
from heartball_timeline import save
from heartball_skill_bundle import load_bundle

PROMPT=load_bundle().text('rolling')
REVIEW=load_bundle().text('review')




def allocated_groups(proposal,events):
    allocations=proposal['allocations'];groups=proposal['groups']
    handles=['e'+str(i) for i in range(len(events))]
    if not isinstance(allocations,dict) or set(allocations)!=set(handles):raise ValueError('allocations must be an object with exactly these handles: '+','.join(handles))
    keys=[g['key'] for g in groups]
    if len(keys)!=len(set(keys)) or 'keep' in keys:raise ValueError('Unique group keys required')
    if any(not isinstance(a,str) or a not in keys+['keep'] for a in allocations.values()):raise ValueError('Unknown group key')
    result=[]
    for g in groups:
        refs=[{'id':e['id'],'version':e['version']} for h,e in zip(handles,events) if allocations[h]==g['key']]
        if len(refs)<2:continue  # A singleton stays unchanged; no invented member.
        result.append(dict(title=g['title'],summary=g['summary'],events=refs))
    return EventMerges.model_validate({'merges':result}).model_dump()['merges']


def ensure_ranges(db):
    db.execute('CREATE TABLE IF NOT EXISTS workspace_refined_ranges(event_id TEXT,document_id TEXT,revision INTEGER,start_char INTEGER,end_char INTEGER,quote TEXT,PRIMARY KEY(event_id,document_id,start_char,end_char))')


def preserve_ranges(db,result):
    """Use exact span positions, including repeated identical words."""
    from heartball_source_spans import source_spans
    ensure_ranges(db)
    for issue in result['proposal']['issues']:
        eid=result['receipt']['event_keys'][issue['key']]
        for ref in issue['sources']:
            doc=db.execute('SELECT * FROM documents WHERE id=?',(ref['document_id'],)).fetchone()
            if not doc or doc['revision']!=ref['revision'] or doc['status']=='superseded':continue
            spans=source_spans(doc['text']);ids=list(range(len(spans))) if ref.get('all_spans') else ref['span_ids']
            if not ids:continue
            begin=sum(len(s) for s in spans[:min(ids)]);end=sum(len(s) for s in spans[:max(ids)+1])
            quote=''.join(spans[i] for i in ids)
            if doc['text'][begin:end]!=quote or ref.get('quote') and quote!=ref['quote']:raise ValueError('Source span positions differ from original')
            db.execute('INSERT OR IGNORE INTO workspace_refined_ranges VALUES(?,?,?,?,?,?)',(eid,doc['id'],doc['revision'],begin,end,quote))


def audit_sources(db,documents):
    """Final active projection + retained fragments, not just initial receipts."""
    from heartball_source_spans import source_spans
    expected=assigned=missing=duplicates=stale=0;unchanged=True
    for doc in documents:
        current=db.execute('SELECT * FROM documents WHERE id=?',(doc['id'],)).fetchone()
        unchanged=unchanged and bool(current) and all(current[k]==doc[k] for k in ('text','revision','occurred_at'))
        ranges=list(db.execute("SELECT r.* FROM workspace_refined_ranges r JOIN workspace_events e ON e.id=r.event_id WHERE r.document_id=? AND e.status='active'",(doc['id'],)))
        fragments={r[0] for r in db.execute('SELECT span_id FROM agent_source_fragments WHERE document_id=? AND revision=?',(doc['id'],doc['revision']))}
        for r in ranges:
            if r['revision']!=doc['revision'] or doc['text'][r['start_char']:r['end_char']]!=r['quote']:stale+=1
        begin=0
        for index,span in enumerate(source_spans(doc['text'])):
            end=begin+len(span);expected+=1
            owners={r['event_id'] for r in ranges if r['revision']==doc['revision'] and r['start_char']<=begin and r['end_char']>=end}
            count=len(owners)+int(index in fragments)
            assigned+=int(count>0);missing+=int(count==0);duplicates+=int(count>1);begin=end
    return dict(expected_spans=expected,assigned_spans=assigned,missing_spans=missing,duplicate_spans=duplicates,stale_ranges=stale,
        original_documents_unchanged=unchanged,passed=unchanged and not (missing or duplicates or stale))


class RollingReview:
    def __init__(self,agent,configuration):
        self.agent=agent;self.db=agent.db;self.cfg=configuration;self.inc=IncrementalDomain(agent)
        self.bundle=load_bundle(configuration.get('skill_bundle'))
        self.prompt=self.bundle.text('rolling');self.review_prompt=self.bundle.text('review')
        self.merger=EventMergeStore(agent,preserve_identity=True)
        self.root=Path(agent.store.root)/'incremental-reviews'
        with agent.store.lock,agent.store.transaction():
            self.db.execute('CREATE TABLE IF NOT EXISTS incremental_reviews(run_key TEXT PRIMARY KEY,scope TEXT,cutoff REAL,status TEXT,payload TEXT)')
            self.db.execute('CREATE TABLE IF NOT EXISTS incremental_review_plans(plan_key TEXT PRIMARY KEY,contexts TEXT)')
            for row in self.db.execute('SELECT payload FROM incremental_commits').fetchall():preserve_ranges(self.db,json.loads(row[0]))

    def next_context(self):
        with self.agent.store.lock:
            for state in self.db.execute('SELECT * FROM incremental_states ORDER BY last_at,scope').fetchall():
                scope=state['scope'];sid,day,focus,source_group=json.loads(scope)
                if focus:continue
                docs=[]
                for row in self.db.execute('SELECT document_id FROM incremental_state_sources WHERE scope=?',(scope,)).fetchall():
                    doc=self.db.execute('SELECT * FROM documents WHERE id=?',(row[0],)).fetchone()
                    if doc and self.inc.source_signature(doc['id']) and self.inc.scope(dict(doc))==scope:docs.append(dict(doc))
                if not docs:continue
                start=min(instant(d['occurred_at']) for d in docs);end=max(instant(d['occurred_at']) for d in docs)
                # Final tail is keyed by the latest observed recording clock;
                # active captures wait for the next 30-minute watermark.
                finished=all(self.db.execute('SELECT status FROM sessions WHERE id=?',(d['session_id'],)).fetchone()[0]=='completed' for d in docs)
                cutoffs=list(range(int(start)+1800,int(end)+1,1800))
                if finished and (not cutoffs or cutoffs[-1]<end):cutoffs.append(end)
                all_events=self.merger.context(sid)['events']
                for cutoff in cutoffs:
                    deps={d['id']:self.inc.source_signature(d['id']) for d in docs if cutoff-2700<=instant(d['occurred_at'])<=cutoff}
                    key=hashlib.sha256(encoded([scope,cutoff,deps,self.prompt,self.review_prompt]).encode()).hexdigest()
                    if self.db.execute('SELECT 1 FROM incremental_reviews WHERE run_key=?',(key,)).fetchone():continue
                    events=[]
                    for event in all_events:
                        refs=event['sources'];source_docs=[self.db.execute('SELECT * FROM documents WHERE id=?',(s['document_id'],)).fetchone() for s in refs]
                        if not source_docs or any(not d or self.inc.scope(dict(d))!=scope for d in source_docs):continue
                        clocks=[instant(d['occurred_at']) for d in source_docs]
                        if max(clocks)>cutoff or not rolling_contains(min(clocks),max(clocks),cutoff,cutoff,2700):continue
                        events.append(event)
                        deps.update({d['id']:self.inc.source_signature(d['id']) for d in source_docs})
                    # Explicit bounded subwindows: no truncation of original quotes.
                    saved=self.db.execute('SELECT contexts FROM incremental_review_plans WHERE plan_key=?',(key,)).fetchone()
                    if saved:
                        for context in json.loads(saved[0]):
                            if not self.db.execute('SELECT 1 FROM incremental_reviews WHERE run_key=?',(context['window_key'],)).fetchone():return context
                        self.db.execute('INSERT OR IGNORE INTO incremental_reviews VALUES(?,?,?,?,?)',(key,scope,cutoff,'completed','{}'));self.db.commit();continue
                    chunks=[];chunk=[];size=0
                    for event in events:
                        cost=len(encoded(event))
                        if chunk and (len(chunk)>=24 or size+cost>22000):chunks.append(chunk);chunk=[];size=0
                        chunk.append(event);size+=cost
                    if chunk:chunks.append(chunk)
                    if not chunks:chunks=[[]]
                    pending=[]
                    for index,chunk in enumerate(chunks):
                        subkey=key+':'+str(index)
                        if self.db.execute('SELECT 1 FROM incremental_reviews WHERE run_key=?',(subkey,)).fetchone():continue
                        pending.append(dict(session_id=sid,scope=scope,cutoff=cutoff,window_key=subkey,events=chunk,dependencies=deps,final_window=True))
                    if pending:
                        self.db.execute('INSERT INTO incremental_review_plans VALUES(?,?)',(key,encoded(pending)));self.db.commit()
                        return pending[0]
                    self.db.execute('INSERT OR IGNORE INTO incremental_reviews VALUES(?,?,?,?,?)',(key,scope,cutoff,'completed','{}'));self.db.commit()
            return None

    def apply(self,context,value):
        value=EventMerges.model_validate(value).model_dump()
        if value['transcript_only']:raise ValueError('Rolling review cannot hide events')
        with self.agent.store.lock,self.agent.store.transaction():
            if any(self.inc.source_signature(did)!=sig for did,sig in context['dependencies'].items()):raise ValueError('Review evidence changed')
            self.merger.persist(context['window_key'],value,context)
            for group in value['merges']:
                active=[dict(r) for ref in group['events'] for r in self.db.execute("SELECT * FROM workspace_events WHERE id=? AND status='active'",(ref['id'],))]
                if len(active)!=1:raise ValueError('Merge survivor identity mismatch')
                save(self.db,active[0],'event','同一事项滚动归并，原文与关联保留',card_style='summary')
        return value

    def tick(self):
        context=self.next_context()
        if context is None:return False
        key=context['window_key'];folder=self.root/key;folder.mkdir(parents=True,exist_ok=True,mode=0o700)
        started=time.monotonic();meter=None;client=None;payload={'skill_bundle_sha256':self.bundle.digest};status='completed'
        if self.cfg.get('capture_model_payloads',False):private_json(folder/'context-private.json',context)
        try:
            if len(context['events'])>=2:
                meter=ModelMeter(self.cfg,folder/'model-meter',max_calls=3)
                from openai import OpenAI
                client=OpenAI(base_url=meter.base_url,api_key=meter.key,timeout=180,max_retries=0)
                public=[dict(index=i,handle='e'+str(i),title=e['title'],summary=e['summary'],sources=e['sources']) for i,e in enumerate(context['events'])]
                messages=[dict(role='system',content=self.prompt),dict(role='user',content=encoded({'events':public,'time_basis':'recording_time','window_seconds':2700}))]
                draft_root=self.cfg.get('review_draft_root')
                if draft_root:
                    # Reuse hypotheses only when the complete original context is
                    # identical. Changed projections use a fresh bounded review.
                    for old in Path(draft_root).iterdir():
                        saved=old/'context-private.json'
                        if not saved.exists():continue
                        prior=json.loads(saved.read_text())
                        if encoded(prior['events'])!=encoded(context['events']) or prior['dependencies']!=context['dependencies']:continue
                        responses=sorted((old/'model-meter').glob('response-*.body'))
                        if not responses:break
                        try:
                            candidate=json.loads(json.loads(responses[0].read_text())['choices'][0]['message']['content'])
                            groups=candidate['groups']
                            if not groups:break
                            messages.append(dict(role='user',content='已有候选如下。复用其标题、摘要与语义，仅根据原文校正显式handle分配；不要按旧数组位置猜测。不合适的候选可不采用：'+encoded([dict(key=g['key'],title=g['title'],summary=g['summary']) for g in groups])))
                            payload['saved_hypotheses_reused']=True
                        except (ValueError,KeyError,TypeError):pass
                        break
                groups=None
                for attempt in range(2):
                    response=client.chat.completions.create(model=self.cfg['model'],messages=messages,max_tokens=min(6000,self.cfg.get('max_tokens',6000)),response_format={'type':'json_object'})
                    raw=response.choices[0].message.content or ''
                    try:
                        if response.choices[0].finish_reason=='length':raise ValueError('Truncated')
                        proposal=json.loads(raw);groups=allocated_groups(proposal,context['events']);break
                    except (ValueError,KeyError,TypeError) as exc:
                        groups=None;messages += [dict(role='assistant',content=raw),dict(role='user',content='仅修复结构错误：'+str(exc)[:600])]
                if groups is None:raise ValueError('Invalid review proposal after bounded repair')
                groups=[g for g in groups if not crosses_other_discussion(self.db,g,context)]
                payload['proposed_merges']=groups
                if groups:
                    evidence=[dict(index=i,title=g['title'],summary=g['summary'],events=[e for e in public if context['events'][e['index']]['id'] in {r['id'] for r in g['events']}]) for i,g in enumerate(groups)]
                    response=client.chat.completions.create(model=self.cfg['model'],messages=[dict(role='system',content=self.review_prompt),dict(role='user',content=encoded(evidence))],max_tokens=2000,response_format={'type':'json_object'})
                    approved=json.loads(response.choices[0].message.content)['approved_indices']
                    if response.choices[0].finish_reason=='length' or len(set(approved))!=len(approved) or any(type(i)!=int or i<0 or i>=len(groups) for i in approved):raise ValueError('Invalid independent review indices')
                    groups=[g for i,g in enumerate(groups) if i in approved]
                payload['result']=self.apply(context,{'merges':groups})
            else:payload['result']={'merges':[],'reason':'fewer_than_two_events_zero_calls'}
        except Exception as exc:
            status='failed';payload['error']=type(exc).__name__+': '+str(exc)[:500]
        finally:
            if client:client.close()
            if meter:meter.close()
        payload.update(seconds=time.monotonic()-started,usage=meter.summary() if meter else {'calls':0,'total_tokens':0,'usage_complete':True})
        private_json(folder/'receipt.json',dict(status=status,**payload))
        with self.agent.store.lock,self.agent.store.transaction():
            self.db.execute('INSERT OR IGNORE INTO incremental_reviews VALUES(?,?,?,?,?)',(key,context['scope'],context['cutoff'],status,encoded(payload)))
        return True

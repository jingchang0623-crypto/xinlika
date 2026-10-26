"""Bounded post-consolidation relation review, using the existing domain commit.

Only adds grounded topic edges. It cannot merge events, re-extract ASR, change
personal claims, or infer a speaker's identity. Disabled unless explicitly used.
"""
import hashlib
import json
from pathlib import Path
import time

from heartball_agent_runtime import AgentDomain
from heartball_agent_store import encoded
from heartball_incremental import IncrementalDomain,instant,terms
from heartball_runtime_adapters import ModelMeter,private_json
from heartball_skill_bundle import load_bundle
from heartball_store import Conflict
from heartball_harness2_safety import semantic_configuration

CAPABILITY='operation=cross_conversation_links'


def implementation_digest():return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


class CrossConversationReview:
    def __init__(self,agent,configuration,*,prime_existing=True):
        self.agent=agent;self.db=agent.db;self.cfg=configuration
        self.bundle=load_bundle(configuration.get('skill_bundle'));self.prompt=self.bundle.text('review')
        if CAPABILITY not in self.prompt:raise ValueError('Skill bundle does not support cross-conversation review')
        self.domain=AgentDomain(agent);self.inc=IncrementalDomain(agent)
        self.epoch=hashlib.sha256(encoded([self.bundle.digest,implementation_digest(),semantic_configuration(configuration)]).encode()).hexdigest()
        self.root=Path(agent.store.root)/'incremental-topic-reviews'
        with agent.store.lock,agent.store.transaction():
            self.db.execute('CREATE TABLE IF NOT EXISTS incremental_topic_reviews(review_key TEXT PRIMARY KEY,status TEXT,payload TEXT)')
            self.db.execute('CREATE TABLE IF NOT EXISTS incremental_topic_epochs(epoch TEXT PRIMARY KEY)')
            existed=self.db.execute('SELECT 1 FROM incremental_topic_epochs WHERE epoch=?',(self.epoch,)).fetchone()
            if not existed and prime_existing:
                # Keep initialization in one transaction: another worker must
                # not race startup and send old archive contents to a model.
                for _ in range(1000):
                    context=self.next_context()
                    if context is None:break
                    self.db.execute("INSERT OR IGNORE INTO incremental_topic_reviews VALUES(?,'pre_upgrade_baseline','{}')",(context['key'],))
                else:raise ValueError('Historical relation baseline exceeds startup bound')
            self.db.execute('INSERT OR IGNORE INTO incremental_topic_epochs VALUES(?)',(self.epoch,))

    def next_context(self):
        with self.agent.store.lock:
            events=[]
            for row in self.db.execute("SELECT * FROM workspace_events WHERE status='active' AND kind!='focus' ORDER BY julianday(occurred_at),id"):
                e=dict(row)
                if not self.domain.event_eligible(e['id']):continue
                refs=[dict(r) for r in self.db.execute('SELECT s.document_id,s.revision,s.quote,d.occurred_at,d.session_id FROM workspace_event_sources s JOIN documents d ON d.id=s.document_id WHERE s.event_id=? ORDER BY julianday(d.occurred_at),s.rowid',(e['id'],))]
                if not refs:continue
                groups={self.inc.scope(dict(self.db.execute('SELECT * FROM documents WHERE id=?',(r['document_id'],)).fetchone())) for r in refs}
                if len(groups)!=1:continue
                provenance=self.db.execute("SELECT payload FROM events WHERE session_id=? AND kind='recording_context' ORDER BY id DESC LIMIT 1",(e['session_id'],)).fetchone()
                context=json.loads(provenance[0]) if provenance else {}
                events.append({**e,'sources':refs,'scope':next(iter(groups)),'recording_context':context,
                    'clock':max(instant(r['occurred_at']) for r in refs),'terms':terms(e['title']+' '+e['summary']+' '.join(r['quote'] for r in refs))})
            scopes=sorted({e['scope'] for e in events},key=lambda s:max(e['clock'] for e in events if e['scope']==s))
            for scope in scopes:
                current=[e for e in events if e['scope']==scope][-8:]
                start=min(instant(r['occurred_at']) for e in current for r in e['sources'])
                query=set().union(*(e['terms'] for e in current));context_ids={e['recording_context'].get('group_id') for e in current}-{None}
                group=self.agent.workspace.source_group(current[0]['source_kind'])
                history=[]
                for e in events:
                    if e['scope']==scope or e['clock']>start or self.agent.workspace.source_group(e['source_kind'])!=group:continue
                    score=len(query&e['terms'])/max(1,len(query|e['terms']))
                    shared=e['recording_context'].get('group_id') in context_ids
                    if shared or score>0:history.append((shared,score,e))
                history=[e for _,_,e in sorted(history,key=lambda x:(x[0],x[1],x[2]['clock']),reverse=True)[:8]]
                if not history:continue
                selected=current+history;aliases={'e'+str(i):e['id'] for i,e in enumerate(selected)}
                public=[];dependencies={}
                for i,e in enumerate(selected):
                    refs=[]
                    for r in e['sources'][:3]:
                        dependencies[r['document_id']]=self.inc.source_signature(r['document_id'])
                        refs.append({'index':len(refs),'quote':r['quote'][:1200],'excerpt':len(r['quote'])>1200,'occurred_at':r['occurred_at']})
                    public.append({'handle':'e'+str(i),'side':'current' if i<len(current) else 'history','title':e['title'],'summary':e['summary'][:500],
                        'recording_context':e['recording_context'],'sources':refs})
                # Selection and source text, not topic-side effects, define the
                # watermark. A valid no-link is not polled until it says yes.
                identities=[{k:e[k] for k in ('id','title','summary','sources','scope')} for e in selected]
                key=hashlib.sha256(encoded([identities,dependencies,self.epoch]).encode()).hexdigest()
                if self.db.execute('SELECT 1 FROM incremental_topic_reviews WHERE review_key=?',(key,)).fetchone():continue
                topics=[]
                for t in self.db.execute("SELECT * FROM workspace_topics WHERE status='active' ORDER BY id"):
                    members={r[0] for r in self.db.execute('SELECT event_id FROM workspace_all_event_topics WHERE topic_id=?',(t['id'],))}
                    if t['source_group']!=group or any(not self.domain.event_eligible(eid) for eid in members):continue
                    handles=[h for h,eid in aliases.items() if eid in members]
                    if not handles:continue
                    topics.append({'handle':'t'+str(len(topics)),'id':t['id'],'version':t['version'],'title':t['title'],'event_handles':handles})
                    if len(topics)>=8:break
                shared=[]
                for gid in sorted(context_ids):
                    members=[p['handle'] for p in public if p['recording_context'].get('group_id')==gid]
                    sides={p['side'] for p in public if p['handle'] in members}
                    if sides!={'current','history'}:continue
                    metadata=next(p['recording_context'] for p in public if p['handle'] in members)
                    shared.append({'context_handle':'c'+str(len(shared)),'member_events':members,'medium':metadata.get('medium'),
                        'reported_start_local':metadata.get('reported_start_local'),'provided_by':metadata.get('provided_by'),
                        'meaning':'These captures share the same registered conversation context. Compare their activities and original references; this does not establish same-issue identity.',
                        'same_issue_is_not_asserted':True})
                model={'operation':'cross_conversation_links','events':public,'shared_conversation_contexts':shared,'topics':[{k:v for k,v in t.items() if k!='id'} for t in topics],
                    'candidate_retrieval_is_not_truth':True,'candidates_not_exhaustive':True}
                if len(encoded(model))>24000:raise ValueError('Topic review context exceeds bound; no silent whole-input truncation')
                return {'key':key,'model':model,'events':selected,'aliases':aliases,'topics':topics,'dependencies':dependencies}
            return None

    def apply(self,context,answer,task):
        links=answer['links']
        if not isinstance(links,list) or len(links)>6:raise ValueError('Bounded links list required')
        allowed={e['handle']:e for e in context['model']['events']};topics=[]
        for i,link in enumerate(links):
            handles=link['events']
            if not isinstance(handles,list) or not 2<=len(handles)<=8 or len(set(handles))!=len(handles) or any(h not in allowed for h in handles):raise ValueError('Invalid linked event handles')
            if {allowed[h]['side'] for h in handles}!={'current','history'}:raise ValueError('Link must bridge current and historical conversations')
            proven=set()
            for anchor in link['evidence']:
                h=anchor['event'];idx=anchor['source_index'];quote=anchor['quote']
                if h not in handles or type(idx)!=int or not 0<=idx<len(allowed[h]['sources']) or not isinstance(quote,str) or len(quote.strip())<8 or quote not in allowed[h]['sources'][idx]['quote']:
                    raise ValueError('Every link anchor must be literal in the presented event source')
                proven.add(h)
            if proven!=set(handles):raise ValueError('Every linked event requires its own literal anchor')
            prior=None
            if link.get('existing_topic'):
                prior=next((t for t in context['topics'] if t['handle']==link['existing_topic']),None)
                if not prior:raise ValueError('Unknown topic handle')
            topics.append({'key':'link'+str(i),'title':link['title'],'summary':link['summary'],'event_keys':[context['aliases'][h] for h in handles],
                'existing_topic_id':prior['id'] if prior else None,'existing_topic_version':prior['version'] if prior else None})
        with self.agent.store.lock,self.agent.store.transaction():
            if any(self.inc.source_signature(did)!=sig for did,sig in context['dependencies'].items()):raise Conflict('Link sources or corrections changed')
            return self.domain.commit(task,{'topics':topics,'omitted_document_ids':task.document_ids})

    def tick(self):
        context=self.next_context()
        if context is None:return False
        key=context['key'];folder=self.root/key;folder.mkdir(parents=True,exist_ok=True,mode=0o700)
        with self.agent.store.lock,self.agent.store.transaction():
            claimed=self.db.execute("INSERT OR IGNORE INTO incremental_topic_reviews VALUES(?,'running','{}')",(key,)).rowcount
        if not claimed:return True
        private_json(folder/'context-private.json',context['model'])
        task=self.domain.task(sorted(context['dependencies']),'仅复核已整理事件的跨对话关系；保留事件、原文与用户纠正，不提取个人记忆。',self.bundle.digest).model_copy(update={'topic_repair_only':True})
        meter=None;client=None;status='failed';payload={};started=time.monotonic()
        try:
            meter=ModelMeter(self.cfg,folder/'model-meter',max_calls=2)
            from openai import OpenAI
            client=OpenAI(base_url=meter.base_url,api_key=meter.key,timeout=180,max_retries=0)
            messages=[{'role':'system','content':self.prompt},{'role':'user','content':encoded(context['model'])}]
            for attempt in range(2):
                response=client.chat.completions.create(model=self.cfg['model'],messages=messages,max_tokens=4000,response_format={'type':'json_object'})
                raw=response.choices[0].message.content or '';private_json(folder/f'answer-{attempt}-private.json',{'content':raw})
                try:
                    if response.choices[0].finish_reason=='length':raise ValueError('Truncated link review')
                    answer=json.loads(raw);payload['receipt']=self.apply(context,answer,task);payload['links']=answer['links'];status='completed';break
                except (ValueError,KeyError,TypeError) as error:
                    if isinstance(error,Conflict) or attempt:raise
                    messages += [{'role':'assistant','content':raw},{'role':'user','content':'仅修复结构或逐字依据校验错误：'+str(error)[:500]}]
        except Exception as exc:payload['error']=type(exc).__name__+': '+str(exc)[:500]
        finally:
            if client:client.close()
            if meter:meter.close()
        payload.update(status=status,seconds=time.monotonic()-started,skill_bundle_sha256=self.bundle.digest,usage=meter.summary() if meter else {})
        private_json(folder/'receipt.json',payload)
        with self.agent.store.lock,self.agent.store.transaction():self.db.execute('UPDATE incremental_topic_reviews SET status=?,payload=? WHERE review_key=?',(status,encoded(payload),key))
        return True

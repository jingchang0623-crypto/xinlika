"""Opt-in bounded incremental editor. Reuses the canonical domain transaction.

One structured model call per window (+ at most one structural repair), not a
new generic Agent loop. Native harness remains responsible for answer/repair.
No audio, ASR, hardware, deployments, or independently authoritative memory.
"""
from __future__ import annotations
import datetime as dt
import copy
import hashlib
import json
import math
from pathlib import Path
import re
import time
from zoneinfo import ZoneInfo

from heartball_agent_runtime import AgentDomain,AgentReceipt,RuntimeProjection
from heartball_agent_store import AgentStore,encoded,stable
from heartball_store import Store,Conflict,now
from heartball_source_spans import source_spans
from heartball_incremental_reuse import bounded_state,rolling_contains

PROJECT=Path(__file__).resolve().parents[1]
SKILL=PROJECT/'prompts/skills/xinlika-incremental/SKILL.md'


def skill_version(bundle=None):
    if bundle is not None:return bundle.digest
    return hashlib.sha256(SKILL.read_bytes()+Path(__file__).with_name('heartball_incremental_reuse.py').read_bytes()).hexdigest()


def instant(value):
    result=dt.datetime.fromisoformat(value.replace('Z','+00:00'))
    if result.tzinfo is None:raise ValueError('Recording clock needs timezone')
    return result.timestamp()


def terms(text):
    """Cheap candidate retrieval only; no claim of semantic or entity accuracy."""
    values=set(re.findall(r'[a-z0-9_]{3,}',text.casefold()))
    for run in re.findall(r'[\u4e00-\u9fff]+',text):
        values.update(run[i:i+2] for i in range(len(run)-1))
    return values


class IncrementalDomain:
    def __init__(self,agent,lookback_seconds=2700):
        self.agent,self.store,self.db=agent,agent.store,agent.db
        self.domain=AgentDomain(agent);self.lookback_seconds=lookback_seconds
        with self.store.lock,self.store.transaction():
            self.db.execute('CREATE TABLE IF NOT EXISTS incremental_states(scope TEXT PRIMARY KEY,version INTEGER NOT NULL,state TEXT NOT NULL,last_at TEXT NOT NULL)')
            self.db.execute('CREATE TABLE IF NOT EXISTS incremental_state_sources(scope TEXT NOT NULL,document_id TEXT NOT NULL,signature TEXT NOT NULL,PRIMARY KEY(scope,document_id))')
            self.db.execute('CREATE TABLE IF NOT EXISTS incremental_commits(task_id TEXT PRIMARY KEY,scope TEXT NOT NULL,context_version INTEGER NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL)')
            from heartball_fragment_projection import repair_completed_reallocations
            repair_completed_reallocations(self.db)

    def source_signature(self,did):
        d=self.db.execute('SELECT * FROM documents WHERE id=?',(did,)).fetchone()
        if not d or d['status']=='superseded' or not self.agent.allowed(d['session_id'],'agent'):return None
        generation=self.db.execute('SELECT generation FROM workspace_generations WHERE document_id=?',(did,)).fetchone()
        feedback=[list(r) for r in self.db.execute('SELECT id,version,status,owner,due_at FROM claims WHERE document_id=? ORDER BY id',(did,))]
        metadata=[list(r) for r in self.db.execute("SELECT kind,payload FROM events WHERE session_id=? AND kind IN ('recording_context','scene_context') ORDER BY id",(d['session_id'],))]
        policy=dict(self.agent._policy(d['session_id']) or {})
        return hashlib.sha256(encoded([dict(d),generation[0] if generation else 0,feedback,metadata,policy]).encode()).hexdigest()

    def scope(self,d):
        from heartball_card_segments import logical_root
        day=dt.datetime.fromisoformat(d['occurred_at'].replace('Z','+00:00')).astimezone(ZoneInfo('Asia/Shanghai')).date().isoformat()
        return encoded([logical_root(self.db,d['session_id']),day,d['kind']=='focus',self.agent.workspace.source_group(d['source_kind'])])

    def prepare(self,task):
        with self.store.lock:
            if self.domain.fingerprint(task.document_ids)!=task.expected_snapshot:raise Conflict('Task evidence changed')
            docs=[dict(self.db.execute('SELECT * FROM documents WHERE id=?',(did,)).fetchone()) for did in task.document_ids]
            if len({self.scope(d) for d in docs})!=1:raise ValueError('Incremental window crosses recording/provenance/day boundary')
            scope=self.scope(docs[0]);row=self.db.execute('SELECT * FROM incremental_states WHERE scope=?',(scope,)).fetchone()
            prior=json.loads(row['state']) if row else {};version=row['version'] if row else 0
            invalid=any(self.source_signature(r['document_id'])!=r['signature'] for r in self.db.execute('SELECT * FROM incremental_state_sources WHERE scope=?',(scope,)))
            start=min(instant(d['occurred_at']) for d in docs);end=max(instant(d['occurred_at']) for d in docs)
            late=bool(row and instant(row['last_at'])>end)
            # A correction is made now about an earlier source. Its former
            # event may already have been rebuilt/continued using sibling
            # sources. Retrieve those exact descendants even when their latest
            # recording clock is later; ordinary late ASR still cannot see or
            # rewrite future work. Never infer lineage from matching words.
            correction_siblings=set();correction_context={}
            for d in docs:
                siblings=set();previous_texts=[];pending=[d['id']];visited=set()
                while pending:
                    did=pending.pop()
                    if did in visited:continue
                    visited.add(did)
                    prior_doc=self.db.execute('SELECT evidence FROM documents WHERE id=?',(did,)).fetchone()
                    if not prior_doc:continue
                    for item in json.loads(prior_doc['evidence']):
                        previous=item.get('previous_document_id') if item.get('kind')=='user_correction' else None
                        if not previous:continue
                        old=self.db.execute('SELECT text FROM documents WHERE id=?',(previous,)).fetchone()
                        if old and old[0] not in previous_texts:previous_texts.append(old[0])
                        pending.append(previous)
                        siblings.update(r[0] for r in self.db.execute('SELECT DISTINCT sibling.document_id FROM workspace_event_sources original JOIN workspace_event_sources sibling ON sibling.event_id=original.event_id WHERE original.document_id=?',(previous,)))
                if previous_texts:correction_context[d['id']]={'siblings':siblings,'previous_texts':previous_texts}
                correction_siblings.update(siblings)
            if invalid or late:prior={}
            dependencies={r['document_id']:r['signature'] for r in self.db.execute('SELECT * FROM incremental_state_sources WHERE scope=?',(scope,))} if not invalid and not late else {}
            def recording_context(sid):
                entry=self.db.execute("SELECT payload FROM events WHERE session_id=? AND kind='recording_context' ORDER BY id DESC LIMIT 1",(sid,)).fetchone()
                return json.loads(entry[0]) if entry else None
            new_terms=terms(' '.join(d['text'] for d in docs));candidates=[]
            for e in self.db.execute("SELECT * FROM workspace_events WHERE status='active'").fetchall():
                if not self.domain.event_eligible(e['id']):continue
                refs=[dict(r) for r in self.db.execute('SELECT s.document_id,s.revision,s.quote,d.occurred_at,d.session_id,d.source_kind,d.kind FROM workspace_event_sources s JOIN documents d ON d.id=s.document_id WHERE s.event_id=?',(e['id'],))]
                if not refs or any(self.agent.workspace.source_group(r['source_kind'])!=self.agent.workspace.source_group(docs[0]['source_kind']) or (r['kind']=='focus')!=(docs[0]['kind']=='focus') for r in refs):continue
                clocks=[instant(r['occurred_at']) for r in refs if r['occurred_at']]
                if not clocks:continue
                same=all(self.scope(r)==scope for r in refs)
                corrected_descendant=same and bool(correction_siblings&{r['document_id'] for r in refs})
                if max(clocks)>end and not corrected_descendant:continue
                recent=same and (corrected_descendant or rolling_contains(min(clocks),max(clocks),start,end,self.lookback_seconds))
                old_terms=terms(e['title']+' '+e['summary']+' '.join(r['quote'] for r in refs))
                score=len(new_terms&old_terms)/math.sqrt(max(1,len(new_terms))*max(1,len(old_terms)))
                if recent or (not same and score>0):candidates.append((recent,score,max(clocks),dict(e),refs))
            recent=sorted((c for c in candidates if c[0]),key=lambda c:c[2],reverse=True)[:10]
            history=sorted((c for c in candidates if not c[0]),key=lambda c:c[1],reverse=True)[:8]
            aliases={};events=[];event_source_ids={}
            for _,score,_,e,refs in recent+history:
                alias='e'+str(len(events)+1);aliases[alias]=e['id']
                event_source_ids[alias]={r['document_id'] for r in refs}
                dependencies.update({r['document_id']:self.source_signature(r['document_id']) for r in refs})
                events.append({'id':alias,'version':e['version'],'title':e['title'],'summary':e['summary'][:550],
                    'continuation_allowed':any(e['id']==r[3]['id'] for r in recent),'candidate_score_not_truth':round(score,4),
                    'sources':[{'occurred_at':r['occurred_at'],'quote':r['quote'][:450],'quote_is_excerpt':len(r['quote'])>450,
                        'recording_context':recording_context(r['session_id'])} for r in refs[:3]]})
            topics=[]
            for t in self.db.execute("SELECT * FROM workspace_topics WHERE status='active'"):
                ids=[r[0] for r in self.db.execute('SELECT event_id FROM workspace_all_event_topics WHERE topic_id=?',(t['id'],))]
                if not set(ids)&set(aliases.values()):continue
                alias='t'+str(len(topics)+1);aliases[alias]=t['id']
                topics.append({'id':alias,'version':t['version'],'title':t['title'],'summary':t['summary'][:300],
                    'event_ids':[k for k,v in aliases.items() if k.startswith('e') and v in ids]})
                if len(topics)>=6:break
            new=[]
            for i,d in enumerate(docs):
                alias='d'+str(i+1);aliases[alias]=d['id']
                new.append({'id':alias,'revision':d['revision'],'occurred_at':d['occurred_at'],'source_kind':d['source_kind'],
                    'kind':d['kind'],'recording_context':recording_context(d['session_id']),
                    'source_spans':[{'id':i,'text':s} for i,s in enumerate(source_spans(d['text']))]})
                if d['id'] in correction_context:
                    # Replacement documents have a fresh UUID/revision=1. Tell
                    # the editor that this is an update to old recorded speech,
                    # rather than another newly observed standalone incident.
                    new[-1]['source_update']={'kind':'user_correction_to_existing_recording',
                        'new_occurrence':False,'previous_texts':[text for text in correction_context[d['id']]['previous_texts'] if len(text)<=1200],
                        'long_previous_texts_not_included':sum(len(text)>1200 for text in correction_context[d['id']]['previous_texts']),
                        'previous_context_candidates':[handle for handle,ids in event_source_ids.items() if ids&correction_context[d['id']]['siblings']],
                        'previous_machine_association_is_not_truth':True}
            from heartball_interest import context as interest_context
            context={'attention_preferences':interest_context(self.db),'previous_state':prior,'state_invalidated':invalid,'state_version':version,
                'recent_events':[e for e in events if e['continuation_allowed']],
                'related_history':[e for e in events if not e['continuation_allowed']],
                'topics':topics,'new_sources':new,'time_basis':'recording_time_only','instructions_are_data':True}
            signatures={d['id']:self.source_signature(d['id']) for d in docs}
            if any(sig is None for sig in [*dependencies.values(),*signatures.values()]):raise Conflict('Source grant changed while preparing context')
            return {'scope':scope,'version':version,'context':context,'aliases':aliases,'documents':docs,
                'state_reset':invalid,'late':late,'dependencies':dependencies,'signatures':signatures}

    def normalize(self,prepared,answer):
        if not isinstance(answer,dict):raise ValueError('Expected object')
        aliases=prepared['aliases'];value={k:copy.deepcopy(answer.get(k,[])) for k in ('issues','topics','fragments')}
        if 'allocations' in answer:
            if answer.get('fragments') or any(i.get('sources') for i in value['issues']):raise ValueError('Use exclusive allocations, not duplicate source references')
            allocations=answer['allocations'];expected={d['id']:d for d in prepared['context']['new_sources']}
            if not isinstance(allocations,dict) or set(allocations)!=set(expected):raise ValueError('allocations must contain exactly '+','.join(expected))
            issue_map={i['key']:i for i in value['issues']}
            if len(issue_map)!=len(value['issues']):raise ValueError('Issue keys must be unique')
            for issue in value['issues']:issue['sources']=[]
            reasons={'~filler','~incomplete_reference','~unintelligible','~noise_without_context'}
            for did,doc in expected.items():
                owners=allocations[did];count=len(doc['source_spans'])
                if isinstance(owners,dict):
                    if set(owners)!={str(i) for i in range(count)}:raise ValueError(did+' needs exactly the current span-id keys')
                    owners=[owners[str(i)] for i in range(count)]
                if not isinstance(owners,list) or len(owners)!=count:raise ValueError(did+' needs exactly '+str(count)+' ownership entries')
                groups=[]
                for index,owner in enumerate(owners):
                    if not isinstance(owner,str) or owner not in issue_map and owner not in reasons:raise ValueError('Unknown owner at '+did+':'+str(index))
                    if not groups or owner!=groups[-1][0]:groups.append((owner,[]))
                    groups[-1][1].append(index)
                for owner,ids in groups:
                    ref={'document_id':did,'revision':doc['revision'],'span_ids':ids}
                    if owner in issue_map:issue_map[owner]['sources'].append(ref)
                    else:value['fragments'].append({'source':ref,'reason':owner[1:]})
            if any(not issue['sources'] for issue in value['issues']):raise ValueError('Every issue needs an allocated original span')
        def resolve(ref,prefix):
            if not isinstance(ref,str) or not ref.startswith(prefix) or ref not in aliases:raise ValueError('Unknown '+prefix+' reference')
            return aliases[ref]
        for issue in value['issues']:
            for ref in issue['sources']:ref['document_id']=resolve(ref['document_id'],'d')
            # Reuse the existing MCP normalization: disjoint exact selections
            # become distinct continuous references, never a fabricated quote.
            expanded=[]
            for ref in issue['sources']:
                ids=ref.get('span_ids',[])
                if ids and ids==sorted(set(ids)) and not ref.get('quote'):
                    groups=[]
                    for index in ids:
                        if not groups or index!=groups[-1][-1]+1:groups.append([])
                        groups[-1].append(index)
                    expanded.extend({**ref,'span_ids':group} for group in groups)
                else:expanded.append(ref)
            issue['sources']=expanded
            if issue.get('continues_id'):
                if issue['continues_id'] not in {e['id'] for e in prepared['context']['recent_events']}:raise ValueError('Continuation is not in rolling window')
                issue['continues_id']=resolve(issue['continues_id'],'e')
        for fragment in value['fragments']:fragment['source']['document_id']=resolve(fragment['source']['document_id'],'d')
        continuations=[i['continues_id'] for i in value['issues'] if i.get('continues_id')]
        if len(continuations)!=len(set(continuations)):raise ValueError('One prior event may be continued only once per update')
        keys={i['key'] for i in value['issues']}
        if keys&set(aliases):raise ValueError('Issue keys collide with source/event handles')
        # One member is an index, not an association. Preserve its event and
        # audit the omitted index; do not invent a second member to pass schema.
        if any(not isinstance(t,dict) for t in value['topics']):raise ValueError('Topic must be an object')
        value['topics']=[t for t in value['topics'] if not isinstance(t.get('event_keys'),list) or len(t['event_keys'])>=2]
        for topic in value['topics']:
            topic['event_keys']=[k if k in keys else resolve(k,'e') for k in topic['event_keys']]
            if topic.get('existing_topic_id'):
                handle=topic['existing_topic_id']
                topic['existing_topic_id']=resolve(handle,'t')
                expected=next(t['version'] for t in prepared['context']['topics'] if t['id']==handle)
                # The model chooses a handle; the host binds its read version.
                # The domain still rejects a real concurrent version change.
                topic['existing_topic_version']=expected
        projection=RuntimeProjection.model_validate(value).model_dump()
        if prepared['documents'][0]['kind']=='focus' and (len(projection['issues'])!=1 or projection['fragments'] or projection['topics']):
            raise ValueError('Focus stays one independent event, no ordinary topic/fragment rewrite')
        if not isinstance(answer.get('state',{}),dict):raise ValueError('state must be an object')
        if any(answer.get(k) for k in ('memories','activities','omitted_document_ids')):raise ValueError('Incremental editor cannot silently change memory/activity/omissions')
        return projection,bounded_state(answer.get('state',{}))

    def commit(self,task,prepared,answer):
        projection,state=self.normalize(prepared,answer)
        with self.store.lock,self.store.transaction():
            old=self.db.execute('SELECT payload FROM incremental_commits WHERE task_id=?',(task.id,)).fetchone()
            if old:return json.loads(old[0])
            row=self.db.execute('SELECT version FROM incremental_states WHERE scope=?',(prepared['scope'],)).fetchone()
            if (row[0] if row else 0)!=prepared['version']:raise Conflict('Incremental state advanced')
            if any(self.source_signature(did)!=sig for did,sig in prepared['dependencies'].items()):raise Conflict('Prior context grant/version changed')
            if any(self.source_signature(did)!=sig for did,sig in prepared['signatures'].items()):raise Conflict('Source changed during incremental update')
            receipt=self.domain.commit(task,projection,interest_context=prepared['context'].get('attention_preferences'))
            version=prepared['version']+(0 if prepared['late'] else 1)
            last=max((d['occurred_at'] for d in prepared['documents']),key=instant)
            if not prepared['late']:
                self.db.execute('INSERT OR REPLACE INTO incremental_states VALUES(?,?,?,?)',(prepared['scope'],version,encoded(state),last))
                if prepared['state_reset']:self.db.execute('DELETE FROM incremental_state_sources WHERE scope=?',(prepared['scope'],))
                for did,sig in prepared['signatures'].items():self.db.execute('INSERT OR REPLACE INTO incremental_state_sources VALUES(?,?,?)',(prepared['scope'],did,sig))
            result={'receipt':receipt,'state_version':version,'state':state,'proposal':projection,
                'structural_diagnostics':{'singleton_indexes_not_relations':sum(isinstance(t.get('event_keys'),list) and len(t['event_keys'])<2 for t in answer.get('topics',[]))}}
            from heartball_incremental_review import preserve_ranges
            preserve_ranges(self.db,result)
            self.db.execute('INSERT INTO incremental_commits VALUES(?,?,?,?,?)',(task.id,prepared['scope'],version,encoded(result),now()))
            return result


class IncrementalProcessAdapter:
    def __init__(self,root,configuration,fallback=None):
        self.root=Path(root);self.cfg=configuration;self.fallback=fallback
        from heartball_skill_bundle import load_bundle
        self.bundle=load_bundle(configuration.get('skill_bundle'))
        self.expected_skill_version=skill_version(self.bundle if configuration.get('skill_bundle') else None)
        self.implementation_version=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        if not (self.root/'.agent-runtime-owned').is_file():raise ValueError('Explicit owned root required')

    def run(self,task):
        if task.mode=='answer' or task.topic_repair_only:
            if not self.fallback:raise ValueError('Native fallback required for answer/relation repair')
            return self.fallback.run(task)
        from heartball_runtime_adapters import ModelMeter,private_json
        store=Store(self.root);domain=IncrementalDomain(AgentStore(store));started=time.monotonic();meter=None
        try:
            prior=store.db.execute('SELECT payload FROM incremental_commits WHERE task_id=?',(task.id,)).fetchone()
            if prior:return AgentReceipt(runtime='incremental-editor',task_id=task.id,status='completed',receipt=json.loads(prior[0])['receipt'],usage={'calls':0,'calls_with_usage':0,'usage_complete':True,'total_tokens':0,'cost_basis':'existing_durable_receipt'})
            if task.skill_version!=self.expected_skill_version:raise Conflict('Incremental Skill version changed')
            folder=self.root/'incremental-runs'/task.id
            folder.mkdir(parents=True,exist_ok=True,mode=0o700)
            attempt=folder/('attempt-'+str(len(list(folder.glob('attempt-*')))+1).zfill(3));attempt.mkdir(mode=0o700)
            prepared=domain.prepare(task)
            if self.cfg.get('capture_model_payloads',False):private_json(attempt/'context-private.json',prepared['context'])
            private_json(attempt/'task.json',task.model_dump())
            context_hash=hashlib.sha256(encoded(prepared['context']).encode()).hexdigest()
            # Retry completed inference only when the exact context, task and
            # Skill still match. Revalidate with the normal domain transaction.
            for old in sorted(folder.glob('attempt-*'),reverse=True):
                if old==attempt or not (old/'receipt.json').exists():continue
                previous=json.loads((old/'receipt.json').read_text())
                if previous['status']!='failed':continue
                candidate=None
                if (old/'candidate.json').exists():
                    item=json.loads((old/'candidate.json').read_text())
                    if item.get('context_hash')==context_hash and item.get('skill_version')==task.skill_version:candidate=item['answer']
                elif self.cfg.get('capture_model_payloads',False) and (old/'context-private.json').exists():
                    if hashlib.sha256(encoded(json.loads((old/'context-private.json').read_text())).encode()).hexdigest()==context_hash:
                        outputs=sorted(old.glob('answer-*-private.json'))
                        if outputs:
                            try:candidate=json.loads(json.loads(outputs[-1].read_text())['content'])
                            except (ValueError,KeyError):pass
                if candidate is None:continue
                try:recovered=domain.commit(task,prepared,candidate)
                except (ValueError,KeyError,TypeError):continue
                receipt=AgentReceipt(runtime='incremental-editor',task_id=task.id,status='completed',receipt=recovered['receipt'],
                    seconds=time.monotonic()-started,usage={'calls':0,'calls_with_usage':0,'usage_complete':True,'total_tokens':0,
                        'cost_basis':'validated_saved_model_candidate','recovered_from':old.name,'implementation_sha256':self.implementation_version})
                private_json(attempt/'receipt.json',receipt.model_dump());return receipt
            meter=ModelMeter(self.cfg,attempt/'model-meter',max_calls=2)
            from openai import OpenAI
            client=OpenAI(base_url=meter.base_url,api_key=meter.key,timeout=180,max_retries=0)
            schema={k:v for k,v in RuntimeProjection.model_json_schema().items() if k in {'$defs','properties'}}
            schema['properties']={k:v for k,v in schema['properties'].items() if k in {'issues','topics','fragments'}}
            schema['$defs']={k:v for k,v in schema['$defs'].items() if k in {'RuntimeIssue','RuntimeTopic','RuntimeFragment','SourceReference'}}
            schema['properties'].pop('fragments')
            schema['$defs'].pop('RuntimeFragment');schema['$defs'].pop('SourceReference')
            schema['$defs']['RuntimeIssue']['properties'].pop('sources');schema['$defs']['RuntimeIssue']['required'].remove('sources')
            schema['properties']['allocations']={'type':'object','additionalProperties':False,'required':[d['id'] for d in prepared['context']['new_sources']],
                'properties':{d['id']:{'type':'array','items':{'type':'string'},'minItems':len(d['source_spans']),'maxItems':len(d['source_spans'])} for d in prepared['context']['new_sources']}}
            response_format={'type':'json_object'}
            if self.cfg.get('structured_incremental',False):
                from heartball_incremental_contract import strict_incremental_schema
                schema=strict_incremental_schema(prepared['context'])
                response_format={'type':'json_schema','json_schema':{'name':'incremental_event_update','strict':True,'schema':schema}}
            from heartball_interest import GUIDANCE
            messages=[{'role':'system','content':self.bundle.text('incremental')+'\n用户关注偏好：\n'+GUIDANCE+'\ninterest_level=normal/high/low；interest_reason 写具体理由；interest_example_ids 引用原始历史 event_id。不确定时 normal、空理由、空引用。\n字段契约（另需state）：'+encoded(schema)},
                {'role':'user','content':encoded(prepared['context'])}]
            result=None;error=None
            for correction in range(2):
                response=client.chat.completions.create(model=self.cfg['model'],messages=messages,
                    max_tokens=int(self.cfg.get('max_tokens',6000)),response_format=response_format)
                raw=response.choices[0].message.content or ''
                if self.cfg.get('capture_model_payloads',False):private_json(attempt/f'answer-{correction}-private.json',{'content':raw,'finish_reason':response.choices[0].finish_reason})
                try:
                    if response.choices[0].finish_reason=='length':raise ValueError('Output truncated')
                    answer=json.loads(raw)
                    if 'allocations' not in answer:raise ValueError('allocations is required')
                    private_json(attempt/'candidate.json',{'context_hash':context_hash,'skill_version':task.skill_version,'answer':answer})
                    result=domain.commit(task,prepared,answer);break
                except (ValueError,KeyError,TypeError) as exc:
                    error=type(exc).__name__+': '+str(exc)
                    for alias,identity in prepared['aliases'].items():error=error.replace(identity,alias)
                    if isinstance(exc,Conflict):break
                    messages += [{'role':'assistant','content':raw},{'role':'user','content':'只修复结构或引用分配错误，不改变语义判断、不重读历史。错误：'+error[:1800]}]
            usage=meter.summary();usage.update(input_context_characters=len(encoded(prepared['context'])),new_documents=len(task.document_ids),state_reset=prepared['state_reset'])
            usage['implementation_sha256']=self.implementation_version
            usage['skill_bundle_sha256']=self.bundle.digest
            receipt=AgentReceipt(runtime='incremental-editor',task_id=task.id,status='completed' if result else 'failed',
                receipt=result['receipt'] if result else None,error=None if result else error,seconds=time.monotonic()-started,usage=usage)
            private_json(attempt/'receipt.json',receipt.model_dump());return receipt
        except Exception as exc:
            receipt=AgentReceipt(runtime='incremental-editor',task_id=task.id,status='failed',error=type(exc).__name__,seconds=time.monotonic()-started,usage=meter.summary() if meter else {'calls':0,'total_tokens':0})
            if 'attempt' in locals():private_json(attempt/'receipt.json',receipt.model_dump())
            return receipt
        finally:
            if 'client' in locals():client.close()
            if meter:meter.close()
            store.db.close()

    def close(self):
        if self.fallback:self.fallback.close()

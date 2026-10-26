"""Opt-in native Agent integration retaining existing ASR/ingest/feedback/sync.

This is a durable application queue, not an agent reasoning framework. Only the
selected external harness executes the model/tool loop. Default service behavior
is unchanged unless processing config explicitly contains agent_runtime.
"""
import datetime as dt
import hashlib
import json
from pathlib import Path
import time
from types import SimpleNamespace
from zoneinfo import ZoneInfo

from heartball_agent_runtime import AgentDomain,AgentTask
from heartball_agent_store import encoded,stable
from heartball_store import Conflict
from heartball_processing import Processor,ModelAdapter
from heartball_runtime_adapters import adapter_from_config
from heartball_processing_profiles import apply_processing_profile


class NativeRuntimeService:
    def analysis_skill_version(self,topic_repair=False):
        if self.configuration.get('analysis_strategy')=='incremental' and not topic_repair:
            from heartball_incremental import skill_version
            from heartball_skill_bundle import load_bundle
            return skill_version(load_bundle(self.configuration['model']['skill_bundle'])) if self.configuration.get('model',{}).get('skill_bundle') else skill_version()
        return hashlib.sha256((Path(__file__).resolve().parents[1]/'prompts/skills/xinlika-context/SKILL.md').read_bytes()).hexdigest()

    def __init__(self,agent,configuration,adapter=None):
        configuration=apply_processing_profile(configuration)
        self.agent,self.store,self.db=agent,agent.store,agent.db
        self.domain=AgentDomain(agent);self.configuration=configuration
        self.worker=stable('native-worker:'+str(id(self)))
        self.coalesce_seconds=max(0,int(configuration.get('coalesce_seconds',180)))
        self.max_documents=max(1,min(50,int(configuration.get('max_documents',20))))
        self.max_characters=max(2000,min(20000,int(configuration.get('max_characters',10000))))
        self.skill_version=self.analysis_skill_version()
        with self.store.lock,self.store.transaction():
            exists=self.db.execute("SELECT 1 FROM sqlite_master WHERE name='native_source_receipts'").fetchone()
            self.db.execute('CREATE TABLE IF NOT EXISTS native_source_receipts(document_id TEXT NOT NULL,revision INTEGER NOT NULL,generation INTEGER NOT NULL,task_id TEXT NOT NULL,PRIMARY KEY(document_id,revision,generation))')
            self.db.execute('CREATE TABLE IF NOT EXISTS native_topic_repairs(topic_id TEXT NOT NULL,version INTEGER NOT NULL,evidence_hash TEXT NOT NULL,task_id TEXT NOT NULL,PRIMARY KEY(topic_id,version,evidence_hash))')
            if not exists:
                # Do not automatically send the pre-upgrade archive to a model.
                self.db.execute("INSERT INTO native_source_receipts SELECT d.id,d.revision,coalesce(g.generation,0),'pre_upgrade_baseline' FROM documents d JOIN processing_policies p ON p.session_id=d.session_id LEFT JOIN workspace_generations g ON g.document_id=d.id WHERE p.agent_allowed=1")
        (self.store.root/'.agent-runtime-owned').touch(mode=0o600,exist_ok=True)
        self.adapter=adapter or adapter_from_config(configuration,self.store.root)

    def schedule(self):
        with self.store.lock,self.store.transaction():
            for job in self.db.execute("SELECT id,payload FROM jobs WHERE kind='native_agent_analysis' AND status='blocked_quality_review'").fetchall():
                payload=json.loads(job['payload']);docs=[self.db.execute('SELECT session_id,status FROM documents WHERE id=?',(did,)).fetchone() for did in payload['document_ids']]
                if any(not d or d['status']=='superseded' for d in docs):self.db.execute("UPDATE jobs SET status='obsolete' WHERE id=?",(job['id'],))
                elif all(self.agent.allowed(d['session_id'],'agent') for d in docs):self.db.execute("UPDATE jobs SET status='queued',available_at=0 WHERE id=?",(job['id'],))
            if self.db.execute("SELECT 1 FROM jobs WHERE kind='native_agent_analysis' AND status IN ('queued','running','retryable')").fetchone():return False
            rows=[dict(r) for r in self.db.execute("SELECT d.*,coalesce(g.generation,0) generation FROM documents d JOIN processing_policies p ON p.session_id=d.session_id LEFT JOIN workspace_generations g ON g.document_id=d.id LEFT JOIN native_source_receipts n ON n.document_id=d.id AND n.revision=d.revision AND n.generation=coalesce(g.generation,0) WHERE n.document_id IS NULL AND p.agent_allowed=1 AND d.status NOT IN ('superseded','no_text') AND NOT EXISTS (SELECT 1 FROM jobs j,json_each(j.payload,'$.versions') v WHERE j.kind='native_agent_analysis' AND j.status='failed' AND json_extract(v.value,'$.id')=d.id AND json_extract(v.value,'$.revision')=d.revision AND json_extract(v.value,'$.generation')=coalesce(g.generation,0)) ORDER BY CASE WHEN d.kind='focus' THEN 0 ELSE 1 END,julianday(d.occurred_at),d.rowid LIMIT 150")]
            if not rows:return self.schedule_topic_repair()
            first=rows[0];sid=first['session_id'];session=self.store.session(sid)
            oldest=dt.datetime.fromisoformat(first['created_at']).timestamp()
            if first['kind']!='focus' and session['status']!='completed' and time.time()-oldest<self.coalesce_seconds:return False
            from heartball_card_segments import logical_root
            logical=logical_root(self.db,sid);docs=[];size=0
            def source_day(row):return dt.datetime.fromisoformat(row['occurred_at'].replace('Z','+00:00')).astimezone(ZoneInfo('Asia/Shanghai')).date() if row['occurred_at'] else None
            for row in rows:
                if logical_root(self.db,row['session_id'])!=logical or source_day(row)!=source_day(first) or (row['kind']=='focus')!=(first['kind']=='focus'):continue
                if docs and self.configuration.get('analysis_strategy')=='incremental' and first['occurred_at'] and row['occurred_at']:
                    span=(dt.datetime.fromisoformat(row['occurred_at'].replace('Z','+00:00'))-dt.datetime.fromisoformat(first['occurred_at'].replace('Z','+00:00'))).total_seconds()
                    if span>=max(60,min(900,int(self.configuration.get('analysis_window_seconds',300)))):break
                if docs and size+len(row['text'])>self.max_characters:break
                docs.append(row);size+=len(row['text'])
                if len(docs)>=self.max_documents:break
            signature=hashlib.sha256(encoded([(d['id'],d['revision'],d['generation']) for d in docs]).encode()).hexdigest()
            self.agent.enqueue('native_agent_analysis','native-v1:'+signature,{'session_id':sid,'document_ids':[d['id'] for d in docs],
                'versions':[{'id':d['id'],'revision':d['revision'],'generation':d['generation']} for d in docs]})
            return True

    def schedule_topic_repair(self):
        # Only after ordinary source generations have drained. One bounded
        # reconsideration per evidence version, including a valid "no link";
        # never poll the model repeatedly until it produces the desired edge.
        for candidate in self.domain.topic_repairs():
            if not candidate['ready'] or len(candidate['source_ids'])>150:continue
            versions=[list(r) for m in candidate['members'] for eid in m['replacement_event_ids'] for r in self.db.execute('SELECT id,version FROM workspace_events WHERE id=?',(eid,))]
            signature=hashlib.sha256(encoded([candidate,versions]).encode()).hexdigest()
            if self.db.execute('SELECT 1 FROM native_topic_repairs WHERE topic_id=? AND version=? AND evidence_hash=?',(candidate['id'],candidate['version'],signature)).fetchone():continue
            key='native-topic-repair:'+signature
            if self.db.execute('SELECT 1 FROM jobs WHERE input_key=?',(key,)).fetchone():continue
            sid=self.db.execute('SELECT session_id FROM documents WHERE id=?',(candidate['source_ids'][0],)).fetchone()[0]
            self.agent.enqueue('native_agent_analysis',key,{'session_id':sid,'document_ids':candidate['source_ids'],'versions':[],
                'topic_repair':{'id':candidate['id'],'version':candidate['version'],'evidence_hash':signature}})
            return True
        return False

    def tick(self):
        self.schedule()
        query=self.agent.claim_job(self.worker,kinds={'memory_query'})
        if query:return self.run_query(query)
        with self.store.lock,self.store.transaction():
            self.db.execute("UPDATE jobs SET status='retryable',lease_owner=NULL WHERE kind='native_agent_analysis' AND status='running' AND lease_until<?",(time.time(),))
            row=self.db.execute("SELECT * FROM jobs WHERE kind='native_agent_analysis' AND status IN ('queued','retryable') AND attempts<4 AND available_at<=? ORDER BY rowid LIMIT 1",(time.time(),)).fetchone()
            if not row:return False
            self.db.execute("UPDATE jobs SET status='running',attempts=attempts+1,lease_owner=?,lease_until=? WHERE id=?",(self.worker,time.time()+700,row['id']))
            job=dict(self.db.execute('SELECT * FROM jobs WHERE id=?',(row['id'],)).fetchone())
        payload=json.loads(job['payload'])
        try:
            objective='维护本任务的持续活动、完整事项和跨对话主题。先读取当前契约与工作区，再读来源；不要按上传批次拆事项，不猜用户本人，不恢复已撤回记忆。最后提交有来源的分析。'
            if payload.get('topic_repair'):
                objective='本任务仅复核用户纠正后失效的跨对话关系。读取工作区 topic_repairs、当前原文和纠正字段，独立决定同一具体事项关联是否仍成立；旧关系只是候选，不是答案。只提交 topics（证据不足可留空），不重复生成 issues、activities、memories；omitted_document_ids 列全本任务来源。不重转写，不修改用户纠正。'
            with self.store.lock:
                self.skill_version=self.analysis_skill_version(bool(payload.get('topic_repair')))
                task=AgentTask.model_validate(payload['task']) if payload.get('task') else None
                # A committed receipt wins over a stale workspace fingerprint after
                # the commit itself. Losing job_done must not buy another inference.
                if task is None or (not self.domain.receipt(task.id) and (self.domain.fingerprint(task.document_ids)!=task.expected_snapshot or task.skill_version!=self.skill_version)):
                    task=self.domain.task(payload['document_ids'],objective,self.skill_version)
                    if payload.get('topic_repair'):task=task.model_copy(update={'topic_repair_only':True})
                    elif self.configuration.get('complete_events',True) and self.db.execute('SELECT kind FROM documents WHERE id=?',(task.document_ids[0],)).fetchone()[0]!='focus':
                        task=task.model_copy(update={'complete_events':True})
                    payload['task']=task.model_dump()
                    with self.store.transaction():self.db.execute('UPDATE jobs SET payload=? WHERE id=?',(encoded(payload),job['id']))
            result=self.adapter.run(task)
            if result.status!='completed':
                self.fail(job,result)
                return True
            with self.store.lock,self.store.transaction():
                for ref in payload['versions']:
                    self.db.execute('INSERT OR IGNORE INTO native_source_receipts VALUES(?,?,?,?)',(ref['id'],ref['revision'],ref['generation'],task.id))
                if payload.get('topic_repair'):
                    ref=payload['topic_repair']
                    self.db.execute('INSERT OR IGNORE INTO native_topic_repairs VALUES(?,?,?,?)',(ref['id'],ref['version'],ref['evidence_hash'],task.id))
            self.agent.job_done(job)
        except Exception as error:self.agent.job_done(job,type(error).__name__)
        return True

    def fail(self,job,result):
        transient=result.usage.get('guardrail_reason') in {None,'provider_transport_unavailable'} and any(r.get('http_status') in {429,500,502,503,504} or r.get('status')=='transport_error' for r in result.usage.get('requests',[]))
        self.agent.job_done(job,'native_'+(result.error or 'no_receipt'))
        if not transient:
            with self.store.lock,self.store.transaction():self.db.execute("UPDATE jobs SET status='failed' WHERE id=?",(job['id'],))

    def run_query(self,job):
        payload=json.loads(job['payload'])
        try:
            with self.store.lock:
                self.skill_version=hashlib.sha256((Path(__file__).resolve().parents[1]/'prompts/skills/xinlika-context/SKILL.md').read_bytes()).hexdigest()
                records=self.agent.query_context(question=payload['question'])
                ids=[]
                for record in records:
                    did=record.get('document_id') or (record['id'] if record.get('record_type')=='record' else None)
                    if did and did not in ids:
                        doc=self.db.execute('SELECT session_id FROM documents WHERE id=?',(did,)).fetchone()
                        if doc and self.agent.allowed(doc[0],'agent'):ids.append(did)
                    if len(ids)>=20:break
                if not ids:
                    self.agent.answer(payload['question_id'],{'answer':'现有记录中还没找到相关内容。','refs':[]})
                    self.agent.job_done(job);return True
                task=self.domain.task(ids,payload['question']+' 本次为问答，请读取当前记忆与纠正字段并调用 submit_answer，不改事实。',self.skill_version)
                task=task.model_copy(update={'id':stable('native-answer:'+task.id+':'+payload['question_id']),
                    'mode':'answer','question_id':payload['question_id']})
            result=self.adapter.run(task)
            if result.status!='completed':self.fail(job,result);return True
            self.agent.job_done(job)
        except Exception as error:self.agent.job_done(job,type(error).__name__)
        return True


class NativeProcessor(Processor):
    def __init__(self,store,configuration,asr=None,adapter=None,feedback_model=None):
        configuration=apply_processing_profile(configuration)
        super().__init__(store,model=None,asr=asr)
        self.native=NativeRuntimeService(self.agent,configuration,adapter=adapter)
        self.rolling=None
        self.topic_review=None
        if configuration.get('analysis_strategy')=='incremental' and configuration.get('rolling_review',False):
            from heartball_incremental_review import RollingReview
            self.rolling=RollingReview(self.agent,configuration['model'])
        if configuration.get('analysis_strategy')=='incremental' and configuration.get('cross_conversation_review',False):
            from heartball_incremental_topics import CrossConversationReview
            self.topic_review=CrossConversationReview(self.agent,configuration['model'])
        self.model=SimpleNamespace(runtime='incremental-editor' if configuration.get('analysis_strategy')=='incremental' else configuration.get('runtime','native'),supports_organization=False)
        # Preserve the existing observation -> response -> independent review
        # delivery controls during the primary runtime migration. This is not
        # counted as a native-runtime benchmark or silently replaced by one draft.
        self.personal.model=(feedback_model or ModelAdapter(configuration['model'])) if configuration.get('proactive_feedback',True) and configuration.get('model') else feedback_model

    def tick(self,context_only=None,lane=None):
        if lane=='asr':return super().tick(lane='asr')
        if lane=='reconcile':return False
        if context_only is True:
            if self.native.tick():return True
            if self.rolling and self.rolling.tick():return True
            if self.topic_review and self.topic_review.tick():return True
            if self.personal.model:
                self.personal.schedule()
                job=self.agent.claim_job(self.native.worker,kinds={'personal_analysis'})
                if job:
                    try:self.personal.run(json.loads(job['payload'])['run_key']);self.agent.job_done(job)
                    except Exception as error:self.agent.job_done(job,type(error).__name__)
                    return True
            return False
        self.agent.schedule()
        job=self.agent.claim_job(self.worker_id,kinds={'ambient_analysis','focus_analysis','text_analysis'})
        if job:
            try:
                payload=json.loads(job['payload'])
                doc=payload['document'] if job['kind']=='text_analysis' else self.agent.prepare_document(job)
                if not self.agent.allowed(doc['session_id'],'agent'):raise Conflict('Source processing revoked')
                # Materialize ASR text once; do not invoke a per-minute extraction model.
                self.agent.commit_document(doc,{'title':'','summary':'','claims':[]})
                self.agent.job_done(job)
            except Exception as error:self.agent.job_done(job,type(error).__name__)
            return True
        if context_only is None:
            if super().tick(lane='asr'):return True
            if self.native.tick():return True
            if self.rolling and self.rolling.tick():return True
            return self.topic_review.tick() if self.topic_review else False
        return False

    def close(self):
        super().close()
        # The native worker owns its meter until it exits. Do not close the proxy
        # under an in-flight task if the base processor's join deadline elapsed.
        if not self.context_thread or not self.context_thread.is_alive():self.native.adapter.close()

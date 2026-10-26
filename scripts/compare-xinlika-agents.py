#!/usr/bin/env python3
"""Replay existing real transcripts into isolated native Agent projections; never ASR.

Quality labels are evaluation-only. They are never included in Agent tasks.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

from heartball_store import Store
from heartball_agent_store import AgentStore,stable
from heartball_agent_runtime import AgentDomain,readonly_database
from heartball_runtime_adapters import NativeProcessAdapter,private_json

PROJECT=Path(__file__).resolve().parents[1]


def prepare(args):
    root=args.root.resolve();root.mkdir(mode=0o700,parents=True,exist_ok=True)
    if not root.is_relative_to(PROJECT/'.build'):raise ValueError('Replay writes belong under the private .build directory')
    if (root/'corpus-private.json').exists():raise ValueError('Corpus already exists; reuse it without overwriting evidence')
    labels=json.loads(args.labels.read_text());meeting_ids=json.loads(args.meeting_run.read_text())
    a=readonly_database(args.dinner_database,immutable=True);m=readonly_database(args.meeting_database)
    try:
        dinner=[dict(r) for r in a.execute("SELECT * FROM documents WHERE session_id=? AND kind!='focus' AND status!='superseded' ORDER BY occurred_at,id",(labels['session_id'],))]
        first=[dict(r) for r in m.execute("SELECT * FROM documents WHERE session_id=? AND kind!='focus' AND status!='superseded' ORDER BY occurred_at,id",(meeting_ids['round1'],))]
        followup=[dict(r) for r in m.execute("SELECT * FROM documents WHERE session_id IN (?,?) AND kind!='focus' AND status!='superseded' ORDER BY occurred_at,id",(meeting_ids['round2'],meeting_ids['round3']))]
    finally:a.close();m.close()
    if not dinner or not first or not followup:raise ValueError('Required real transcript corpus is incomplete')
    all_docs=dinner+first+followup
    data={'stages':{'meeting-first':[d['id'] for d in first],'meeting-followup':[d['id'] for d in followup],'dinner':[d['id'] for d in dinner]},
          'documents':all_docs,'labels':{'dinner':labels,'meeting':{'same_sessions':[meeting_ids['round1'],meeting_ids['round3']],'different_session':meeting_ids['round2']}},
          'input_sha256':hashlib.sha256(json.dumps([(d['id'],d['revision'],d['text'],d['occurred_at']) for d in all_docs],ensure_ascii=False,sort_keys=True).encode()).hexdigest(),
          'asr_invoked':False,'labels_in_model_prompts':False}
    private_json(root/'corpus-private.json',data)
    for runtime in ('hermes','deepseek-harness'):
        path=root/runtime
        if (path/'heartball.sqlite').exists():raise ValueError('Refusing to overwrite an existing replay')
        path.mkdir(mode=0o700,parents=True,exist_ok=True);(path/'.agent-runtime-owned').touch(mode=0o600)
        store=Store(path);agent=AgentStore(store)
        try:
            for d in all_docs:
                if not d['occurred_at']:raise ValueError('Real source lacks original recording time')
                sid=d['session_id']
                store.db.execute("INSERT OR IGNORE INTO sessions(id,status,started_at,ended_at,batch_seconds,directory,source_kind) VALUES(?,'completed',?,?,60,?,?)",(sid,d['occurred_at'],d['occurred_at'],str(path/'no-hardware-capture'),d['source_kind']))
                if not agent._policy(sid):agent.policy(sid,asr=False,agent=True,source_kind=d['source_kind'],occurred_at=d['occurred_at'],time_precision='copied_original_recording_time')
                agent.commit_document({**d,'evidence':json.loads(d['evidence'])},{'title':'','summary':'','claims':[]})
            store.db.commit();AgentDomain(agent)
        finally:store.db.close()
    return {'prepared':True,'documents':len(all_docs),'characters':sum(len(d['text']) for d in all_docs),'source_sha256':data['input_sha256'],'asr_calls':0}


def correction_task(domain,corpus,skill_version):
    # Controlled rejection on a real literal source, NOT an invented transcript
    # or a claim that this was the user's historical correction.
    ref=corpus['labels']['dinner']['cases'][0]['refs'][0]
    doc=domain.db.execute('SELECT * FROM documents WHERE id=?',(ref['document_id'],)).fetchone()
    cid=stable('runtime-comparison-controlled-rejection:'+doc['id'])
    quote=ref['quote'];start=doc['text'].index(quote)
    if not domain.db.execute('SELECT 1 FROM claims WHERE id=?',(cid,)).fetchone():
        with domain.store.transaction():
            domain.db.execute("INSERT INTO claims(id,document_id,project,kind,statement,owner,due_at,status,quote,quote_start,quote_end,version,replaces_id,created_at,replaces_version) VALUES(?,?,'','fact',?,'unknown',NULL,'proposed',?,?,?,1,NULL,?,NULL)",(cid,doc['id'],quote,quote,start,start+len(quote),__import__('heartball_store').now()))
        domain.agent.feedback({'id':stable('controlled-rejection-feedback:'+cid),'target_id':cid,'expected_version':1,'action':'reject'})
    qid=stable('controlled-rejection-question:'+cid)
    question='有一条记忆已在本轮受控测试中撤回。请查当前状态，说明该记录是否还应作为我的个人事实，以及原始讨论内容是否仍可检索。不要恢复被撤回的事实。'
    domain.agent.ask(qid,question)
    task=domain.task([doc['id']],question+' 先 analysis_contract/read_workspace，最后 submit_answer；本次不修改事项或事实。',skill_version)
    return task.model_copy(update={'mode':'answer','question_id':qid}),cid


def run(args):
    corpus=json.loads((args.root/'corpus-private.json').read_text())
    skill_version=hashlib.sha256((PROJECT/'prompts/skills/xinlika-context/SKILL.md').read_bytes()).hexdigest()
    model=json.loads(args.model_config.read_text())
    model['capture_model_payloads']=True  # Explicit private evaluation evidence.
    runtimes=('hermes','deepseek-harness') if args.runtime=='both' else (args.runtime,)
    stages=('meeting-first','meeting-followup','dinner','correction') if args.stage=='all' else (args.stage,)
    if args.dinner_window:
        if not 1<=args.dinner_window<=50:raise ValueError('Dinner window must be 1..50 documents')
        expanded=[]
        for stage in stages:
            if stage=='dinner':expanded.extend('dinner-'+str(i//args.dinner_window+1).zfill(3) for i in range(0,len(corpus['stages']['dinner']),args.dinner_window))
            else:expanded.append(stage)
        stages=tuple(expanded)
    for runtime in runtimes:
        path=args.root/runtime;store=Store(path);domain=AgentDomain(AgentStore(store))
        adapter=NativeProcessAdapter(runtime,python=args.hermes_python if runtime=='hermes' else args.client_python,client_python=args.client_python,root=path,configuration=model,timeout=args.timeout)
        try:
            for stage in stages:
                result_file=path/(stage+'-result.json')
                if result_file.exists() and not args.retry:
                    previous=json.loads(result_file.read_text())
                    if previous['status']=='completed':
                        print(json.dumps({'runtime':runtime,'stage':stage,'status':'existing_completed_receipt','model_calls':0}),flush=True);continue
                if stage=='correction':
                    task,cid=correction_task(domain,corpus,skill_version)
                    private_json(path/'controlled-correction.json',{'claim_id':cid,'kind':'controlled_rejection_on_real_source_not_historical_user_correction'})
                else:
                    objective='读取本任务全部真实来源，并结合工具查到的既有内容，维护完整事项和活动。不要按上传批次拆事项；不同事情分开，残句不占首页；跨对话确实延续同一具体事项才建立主题。可以保留有来源的讨论提及，不能猜本人身份。先 analysis_contract/read_workspace，再读取来源，最后 submit_analysis。'
                    if stage.startswith('dinner-'):
                        begin=(int(stage.split('-')[1])-1)*args.dinner_window
                        ids=corpus['stages']['dinner'][begin:begin+args.dinner_window]
                    else:ids=corpus['stages'][stage]
                    if getattr(args,'complete_events',False) and len(ids)>20:
                        objective=objective.replace('最后 submit_analysis。','最后用 stage_analysis 分块保存完整草稿，再 commit_staged_analysis 取得原子提交回执。')
                    task=domain.task(ids,objective,skill_version)
                    if getattr(args,'complete_events',False):task=task.model_copy(update={'complete_events':True})
                private_json(path/(stage+'-task.json'),task.model_dump())
                print(json.dumps({'runtime':runtime,'stage':stage,'status':'started','documents':len(task.document_ids)}),flush=True)
                receipt=adapter.run(task);private_json(result_file,receipt.model_dump())
                if receipt.status=='completed':
                    target=path/(stage+'-snapshot.sqlite')
                    if not target.exists():
                        snapshot=sqlite3.connect(target)
                        try:store.db.backup(snapshot)
                        finally:snapshot.close()
                        target.chmod(0o600)
                print(json.dumps({'runtime':runtime,'stage':stage,'status':receipt.status,'seconds':round(receipt.seconds,2),'calls':receipt.usage['calls'],'total_tokens':receipt.usage['total_tokens'],'error':receipt.error}),flush=True)
                if receipt.status!='completed':break
        finally:adapter.close();store.db.close()


def evaluate(args):
    corpus=json.loads((args.root/'corpus-private.json').read_text());out={}
    for runtime in ('hermes','deepseek-harness'):
        path=args.root/runtime;postdb=readonly_database(path/'heartball.sqlite')
        snapshots=sorted(path.glob('dinner-*-snapshot.sqlite'))
        projection=(snapshots[-1] if snapshots else path/'dinner-snapshot.sqlite')
        if not projection.exists():projection=path/'meeting-followup-snapshot.sqlite'
        if not projection.exists():projection=path/'heartball.sqlite'
        db=readonly_database(projection)
        completed_documents=set()
        for result_file in path.glob('*-result.json'):
            stage=result_file.name.removesuffix('-result.json');task_file=path/(stage+'-task.json')
            if stage!='correction' and task_file.exists() and json.loads(result_file.read_text())['status']=='completed':
                completed_documents.update(json.loads(task_file.read_text())['document_ids'])
        # Score the actual committed organization, separately from the later
        # controlled rejection. Rejection invalidates derived events but never
        # changes their titles, source anchors or association edges. Receipt IDs
        # let older runs be inspected without resurrecting anything in the ledger.
        receipt_event_ids=set();receipt_topic_ids=set()
        for receipt_row in db.execute('SELECT receipt FROM agent_runtime_receipts'):
            receipt=json.loads(receipt_row[0]);receipt_event_ids.update(receipt.get('event_ids',[]));receipt_topic_ids.update(receipt.get('topic_ids',[]))
        events={r['id']:dict(r) for r in db.execute('SELECT * FROM workspace_events') if r['id'] in receipt_event_ids}
        from heartball_timeline import visible
        shown={eid for eid,e in events.items() if visible(db,e)}
        sources={eid:[dict(r) for r in db.execute('SELECT * FROM workspace_event_sources WHERE event_id=?',(eid,))] for eid in events}
        def matches(ref):return {eid for eid in events if any(s['document_id']==ref['document_id'] and ref['quote'] in s['quote'] for s in sources[eid])}
        checks=[]
        for case in corpus['labels']['dinner']['cases']:
            if not {r['document_id'] for r in case['refs']}<=completed_documents:
                checks.append({'id':case['id'],'result':'unscored_incomplete_processing'});continue
            groups=[matches(ref) for ref in case['refs']];kind=case['kind'];missing=any(not x for x in groups)
            if kind=='fragment':
                did=case['refs'][0]['document_id'];ok=not any(eid in shown and {s['document_id'] for s in sources[eid]}=={did} for eid in events)
            elif missing:ok=None
            elif kind=='same_event':ok=bool(set.intersection(*groups))
            elif kind=='visible':ok=bool(groups[0]&shown)
            else:ok=not bool(set.intersection(*groups))
            checks.append({'id':case['id'],'result':'passed' if ok is True else 'failed' if ok is False else 'unscored_missing_literal_anchor'})
        topics={r[0]:[x[0] for x in db.execute('SELECT event_id FROM workspace_all_event_topics WHERE topic_id=?',(r[0],))] for r in db.execute('SELECT id FROM workspace_topics') if r[0] in receipt_topic_ids}
        topic_sessions=[]
        for eids in topics.values():
            topic_sessions.append({db.execute('SELECT session_id FROM documents WHERE id=?',(ref['document_id'],)).fetchone()[0] for eid in eids for ref in sources.get(eid,[])})
        labels=corpus['labels']['meeting'];positive=set(labels['same_sessions']);negative=labels['different_session']
        checks += [{'id':'meeting_same_specific_matter_across_conversations','result':'passed' if any(positive<=x and negative not in x for x in topic_sessions) else 'failed'},
                   {'id':'meeting_different_matter_not_linked','result':'passed' if not any(negative in x and bool(positive&x) for x in topic_sessions) else 'failed'}]
        costs=[]
        stage_names=['meeting-first','meeting-followup']+(['dinner'] if (path/'dinner-result.json').exists() else [])
        stage_names += sorted(p.name.removesuffix('-result.json') for p in path.glob('dinner-*-result.json'))
        stage_names += ['correction']
        for stage in stage_names:
            p=path/(stage+'-result.json')
            if p.exists():
                r=json.loads(p.read_text());costs.append({'stage':stage,'status':r['status'],'seconds':r['seconds'],**{k:v for k,v in r['usage'].items() if k!='requests'}})
        correction=path/'controlled-correction.json'
        correction_result=None
        if correction.exists():
            cid=json.loads(correction.read_text())['claim_id'];row=postdb.execute('SELECT status,version FROM claims WHERE id=?',(cid,)).fetchone()
            answers=[dict(x) for x in postdb.execute("SELECT answer,refs,status FROM memory_answers WHERE status='ready'")]
            correction_result={'claim_still_rejected':row[0]=='rejected','version':row[1],'answers_committed':len(answers),'rejected_claim_not_cited_as_active':all(cid not in {ref['id'] for ref in json.loads(a['refs'])} for a in answers),'method':'controlled_rejection_of_literal_real_source_not_historical_user_feedback'}
        from heartball_activities import activity_projection
        out[runtime]={'checks':checks,'costs':costs,'completed_source_documents':len(completed_documents),
            'organization_snapshot':projection.name,'committed_issues_before_controlled_rejection':len(events),
            'visible_issues_before_controlled_rejection':len(shown),'committed_topics':len(topics),
            'current_active_issues_after_correction':postdb.execute("SELECT count(*) FROM workspace_events WHERE status='active'").fetchone()[0],
            'visible_activity_containers_before_correction':len({a['id'] for a in activity_projection(db).values()}),
            'correction':correction_result,'asr_jobs':postdb.execute("SELECT count(*) FROM jobs WHERE kind='asr_audio'").fetchone()[0]}
        private_json(path/'review-private.json',{'events':list(events.values()),'sources':sources,'topics':topics})
        db.close();postdb.close()
    result={'input_sha256':corpus['input_sha256'],'evidence':'real_existing_transcripts','labels_in_prompts':False,'quality_method':'source-relationship regression checks plus assistant source review; not independent human annotation or transcript accuracy','results':out}
    private_json(args.root/'comparison-result.json',result)
    print(json.dumps(result,ensure_ascii=False,indent=2))


def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='command',required=True)
    prep=sub.add_parser('prepare');prep.add_argument('--root',type=Path,required=True);prep.add_argument('--dinner-database',type=Path,required=True);prep.add_argument('--meeting-database',type=Path,required=True);prep.add_argument('--labels',type=Path,required=True);prep.add_argument('--meeting-run',type=Path,required=True)
    execute=sub.add_parser('run');execute.add_argument('--root',type=Path,required=True);execute.add_argument('--runtime',choices=['hermes','deepseek-harness','both'],default='both');execute.add_argument('--stage',choices=['all','meeting-first','meeting-followup','dinner','correction'],default='all');execute.add_argument('--model-config',type=Path,required=True);execute.add_argument('--hermes-python',type=Path,required=True);execute.add_argument('--client-python',type=Path,required=True);execute.add_argument('--timeout',type=int,default=540);execute.add_argument('--retry',action='store_true');execute.add_argument('--dinner-window',type=int,default=0)
    report=sub.add_parser('evaluate');report.add_argument('--root',type=Path,required=True)
    args=parser.parse_args()
    if args.command=='prepare':print(json.dumps(prepare(args)))
    elif args.command=='run':run(args)
    else:evaluate(args)


if __name__=='__main__':main()

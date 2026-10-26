#!/usr/bin/env python3
"""Real-model semantic acceptance in a private, isolated fictional ledger. No ASR/hardware."""
import argparse
import json
from pathlib import Path
import uuid
from heartball_store import Store
from heartball_processing import Processor, ModelAdapter

p=argparse.ArgumentParser();p.add_argument('--config',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--resume',action='store_true');args=p.parse_args()
if args.output.exists() and not args.resume:p.error('Choose a fresh private directory')
args.output.mkdir(mode=0o700,parents=True,exist_ok=args.resume)
s=Store(args.output);cfg=json.loads(args.config.read_text());proc=Processor(s,ModelAdapter(cfg['model']));a=proc.agent
checks={}
def session():
    sid=str(uuid.uuid4());s.create_session(sid);s.update_session(sid,status='completed')
    a.policy(sid,asr=False,agent=True,source_kind='verified_text',occurred_at='2026-10-21T10:00:00+08:00');return sid

def record(sid,text,when):
    did=str(uuid.uuid4());doc=dict(id=did,input_key='fiction:'+did,session_id=sid,kind='text',text=text,evidence=[{'kind':'fictional_acceptance_fixture'}],source_kind='verified_text',occurred_at=when,boundary_quality='user_text')
    proc.run_document(doc,str(uuid.uuid4()));print('fictional document processed',flush=True);return doc

def ask(q):
    qid=str(uuid.uuid4());a.ask(qid,q);proc.run_query({'question_id':qid,'question':q},str(uuid.uuid4()));return next(x for x in a.state()['answers'] if x['id']==qid)

if args.resume:
    previous=json.loads((args.output/'result.json').read_text())
    for _ in range(50):
        if not proc.tick():break
    revised=ask('青苔相机最新交付日期是哪天，预算多少？请使用更正后的记录。')
    state=a.state();checks=dict(previous['checks'])
    checks['same_event_continues_across_batches']=any(len(e['sources'])>=2 for e in state['events'] if e['kind']!='focus')
    checks['cross_conversation_topic']=any(t['conversation_count']>=2 and '青苔' in t['title'] for t in state['topics'])
    checks['corrected_answer']=revised['status']=='ready' and ('30' in revised['answer'] or '三十' in revised['answer'])
    checks['no_provider_failures']=not any(j['status'] in {'failed','blocked_provider','blocked_quality_review'} for j in state['processingJobs'])
    result={'checks':checks,'passed':all(checks.values()),'scope':previous['scope'],'recovered_from':previous}
    (args.output/'result-recovered.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False),flush=True)
    proc.close();s.db.close()
    raise SystemExit(0 if result['passed'] else 1)

try:
    sid=session()
    d1=record(sid,'小陈：青苔相机计划首版原定2026年10月25日交付，镜头标定由小周负责。先测夜景再测白天，预算控制在八千元。','2026-10-21T10:00:00+08:00')
    d2=record(sid,'继续刚才的青苔相机计划，小周答应先寄两颗镜头做标定，小陈会准备夜景样片。另一个事，午饭去楼下吃面。','2026-10-21T10:01:00+08:00')
    state=a.state();ev=[e for e in state['events'] if any(x['document_id']==d1['id'] for x in e['sources'])]
    checks['same_event_continues_across_batches']=any(len(e['sources'])==2 for e in ev)
    d3=record(session(),'今天复盘昨天的青苔相机项目：镜头运输比预期慢。小陈和小周决定把首版交付改为2026年10月29日，八千元预算不变。','2026-10-22T10:00:00+08:00')
    state=a.state();checks['cross_conversation_topic']=any(t['conversation_count']>=2 and '青苔' in t['title'] for t in state['topics'])
    answer=ask('青苔相机现在什么时候交付，为什么调整，预算多少？')
    checks['answer_without_confirmation']=answer['status']=='ready' and ('29' in answer['answer'] or '二十九' in answer['answer']) and ('八千' in answer['answer'] or '8000' in answer['answer'] or '8,000' in answer['answer']) and bool(answer['refs'])
    checks['zero_manual_confirmations']=a.state()['confirmedMemoryCount']==0
    a.feedback({'id':str(uuid.uuid4()),'target_id':d3['id'],'expected_version':1,'action':'correct_document','values':{'text':'青苔相机项目更正：原先说的2026年10月29日有误，最新确定首版在2026年10月30日交付，因为镜头运输延误；预算仍为八千元。'}})
    checks['old_answer_invalidated']=next(x for x in a.state()['answers'] if x['id']==answer['id'])['status']=='outdated'
    for _ in range(40):
        if not proc.tick():break
    revised=ask('青苔相机最新交付日期是哪天？请使用更正后的记录。')
    checks['corrected_answer']=revised['status']=='ready' and ('30' in revised['answer'] or '三十' in revised['answer'])
    checks['no_provider_failures']=not any(j['status'] in {'failed','blocked_provider','blocked_quality_review'} for j in a.state()['processingJobs'])
    before=a.state();proc.close();s.db.close()
    s=Store(args.output);proc=Processor(s,ModelAdapter(cfg['model']));a=proc.agent
    checks['restart_preserves_workspace']=before==a.state()
    result={'checks':checks,'passed':all(checks.values()),'scope':'Fictional text + real configured model; no hardware/ASR/real-user factual accuracy claim'}
    (args.output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False),flush=True)
    assert result['passed'], 'Semantic acceptance failed; see private evidence'
finally:
    proc.close();s.db.close()

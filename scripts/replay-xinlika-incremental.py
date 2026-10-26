#!/usr/bin/env python3
"""Chronological, resumable text-only replay into a NEW private .build workspace.

Uses a frozen corpus verbatim. Evaluation labels never enter prepare/run.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

from heartball_agent_runtime import AgentDomain,readonly_database
from heartball_agent_store import AgentStore
from heartball_incremental import IncrementalProcessAdapter,skill_version,instant
from heartball_runtime_adapters import private_json
from heartball_store import Store

PROJECT=Path(__file__).resolve().parents[1]


def windows(documents,seconds=300,max_documents=8,max_characters=2200):
    """Observed-clock input windows, not semantic event boundaries."""
    result=[];current=[];size=0
    for d in sorted(documents,key=lambda d:(instant(d['occurred_at']),d['id'])):
        if current and (d['session_id']!=current[0]['session_id'] or d['source_kind']!=current[0]['source_kind']
            or instant(d['occurred_at'])-instant(current[0]['occurred_at'])>=seconds
            or len(current)>=max_documents or size+len(d['text'])>max_characters):
            result.append([d['id'] for d in current]);current=[];size=0
        current.append(d);size+=len(d['text'])
    if current:result.append([d['id'] for d in current])
    return result


def prepare(args):
    root=args.root.resolve()
    if not root.is_relative_to(PROJECT/'.build') or root.exists():raise ValueError('Use a NEW .build replay directory')
    corpus=json.loads(args.corpus.read_text());docs=corpus['documents']
    digest=hashlib.sha256(json.dumps([(d['id'],d['revision'],d['text'],d['occurred_at']) for d in docs],ensure_ascii=False,sort_keys=True).encode()).hexdigest()
    if digest!=corpus['input_sha256']:raise ValueError('Frozen source digest mismatch')
    root.mkdir(parents=True,mode=0o700);private_json(root/'corpus-private.json',corpus)
    path=root/'incremental';path.mkdir(mode=0o700);(path/'.agent-runtime-owned').touch(mode=0o600)
    store=Store(path);agent=AgentStore(store)
    try:
        for d in docs:
            sid=d['session_id']
            store.db.execute("INSERT OR IGNORE INTO sessions(id,status,started_at,ended_at,batch_seconds,directory,source_kind) VALUES(?,'completed',?,?,60,?,?)",(sid,d['occurred_at'],d['occurred_at'],str(path/'no-hardware'),d['source_kind']))
            if not agent._policy(sid):agent.policy(sid,asr=False,agent=True,source_kind=d['source_kind'],occurred_at=d['occurred_at'])
            agent.commit_document({**d,'evidence':json.loads(d['evidence'])},{'title':'','summary':'','claims':[]})
        if args.source_snapshot:
            db=readonly_database(args.source_snapshot,immutable=True)
            try:
                for row in db.execute("SELECT session_id,kind,payload FROM events WHERE kind='recording_context'"):
                    if store.db.execute('SELECT 1 FROM sessions WHERE id=?',(row['session_id'],)).fetchone():store.event(row['session_id'],row['kind'],json.loads(row['payload']))
            finally:db.close()
        AgentDomain(agent);store.db.commit()
        target=__import__('sqlite3').connect(path/'day-snapshot.sqlite')
        try:
            with store.lock:store.db.backup(target)
        finally:target.close()
    finally:store.db.close()
    plan=windows(docs);private_json(root/'plan-private.json',{'windows':plan,'skill_version':skill_version(),'window_seconds':300,'max_documents':8,'max_characters':2200})
    print(json.dumps({'prepared':True,'documents':len(docs),'windows':len(plan),'input_sha256':digest,'asr_calls':0}),flush=True)


def run(args):
    root=args.root.resolve();plan=json.loads((root/'plan-private.json').read_text())
    if plan['skill_version']!=skill_version():raise ValueError('Skill changed since freezing replay')
    path=root/'incremental';cfg=json.loads(args.model_config.read_text());adapter=IncrementalProcessAdapter(path,cfg)
    store=Store(path);domain=AgentDomain(AgentStore(store));task_ids=[];receipts=[];completed=0
    try:
        for index,ids in enumerate(plan['windows']):
            saved=path/'replay-tasks'/f'{index:03}.json'
            if saved.exists():
                from heartball_agent_runtime import AgentTask
                task=AgentTask.model_validate_json(saved.read_text())
            else:
                task=domain.task(ids,'只处理本次新增来源，续写滚动窗口内完整事项，并独立核对历史具体事项关联。',plan['skill_version']).model_copy(update={'complete_events':True})
                private_json(saved,task.model_dump())
            task_ids.append(task.id);receipt=adapter.run(task);receipts.append(receipt.model_dump())
            if receipt.status=='completed':completed+=1
            progress={'windows_completed':completed,'windows_total':len(plan['windows']),'last_status':receipt.status,'error':receipt.error,
                'calls_this_invocation':sum(r.get('usage',{}).get('calls',0) for r in receipts),'asr_calls':0}
            private_json(root/'progress.json',progress);print(json.dumps(progress),flush=True)
            if receipt.status!='completed':break
        result={'status':'completed' if completed==len(plan['windows']) else 'failed','incremental_replay':True,'task_ids':task_ids,
            'error':next((r['error'] for r in receipts if r['status']!='completed'),None),'windows_completed':completed,'windows_total':len(plan['windows']),
            'seconds':sum(r.get('seconds',0) for r in receipts),'usage':{},'asr_calls':0,'skill_version':plan['skill_version']}
        spec=importlib.util.spec_from_file_location('cost_compare',Path(__file__).with_name('compare-xinlika-day.py'))
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        totals=module.attempt_totals(path,task_ids)['totals']
        result.update(seconds=totals['seconds'],usage=totals)
        private_json(path/'day-result.json',result)
    finally:adapter.close();store.db.close()


def evaluate(args):
    spec=importlib.util.spec_from_file_location('frozen_day',Path(__file__).with_name('compare-xinlika-day.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    module.evaluate(SimpleNamespace(root=args.root,cases=args.cases,meeting_run=args.meeting_run,runtimes=('incremental',)))


def review(args):
    from heartball_incremental_review import RollingReview
    import sqlite3
    root=args.root.resolve();path=root/'incremental'
    if not root.is_relative_to(PROJECT/'.build') or not (path/'.agent-runtime-owned').is_file():raise ValueError('Use owned private replay only')
    result=json.loads((path/'day-result.json').read_text())
    if result['status']!='completed':raise ValueError('Complete incremental replay first')
    store=Store(path)
    try:
        backup=path/'before-review.sqlite'
        if not backup.exists():
            target=sqlite3.connect(backup)
            try:store.db.backup(target)
            finally:target.close()
            if (root/'comparison.json').exists():private_json(root/'comparison-before-review.json',json.loads((root/'comparison.json').read_text()))
        reviewer=RollingReview(AgentStore(store),json.loads(args.model_config.read_text()))
        for _ in range(100):
            if not reviewer.tick():break
            counts=dict(store.db.execute('SELECT status,count(*) FROM incremental_reviews GROUP BY status').fetchall())
            print(json.dumps({'review_windows':counts,'asr_calls':0}),flush=True)
        else:raise ValueError('Review bound exceeded')
    finally:store.db.close()


def main():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='command',required=True)
    a=sub.add_parser('prepare');a.add_argument('--root',type=Path,required=True);a.add_argument('--corpus',type=Path,required=True);a.add_argument('--source-snapshot',type=Path)
    a=sub.add_parser('run');a.add_argument('--root',type=Path,required=True);a.add_argument('--model-config',type=Path,required=True)
    a=sub.add_parser('evaluate');a.add_argument('--root',type=Path,required=True);a.add_argument('--cases',type=Path,required=True);a.add_argument('--meeting-run',type=Path,required=True)
    a=sub.add_parser('review');a.add_argument('--root',type=Path,required=True);a.add_argument('--model-config',type=Path,required=True)
    args=p.parse_args();{'prepare':prepare,'run':run,'evaluate':evaluate,'review':review}[args.command](args)


if __name__=='__main__':main()

#!/usr/bin/env python3
"""Small synthetic preference check using the configured model; never touches user data."""
import argparse
import hashlib
import json
from pathlib import Path
import uuid
from heartball_store import Store
from heartball_agent_store import AgentStore
from heartball_agent_runtime import AgentDomain
from heartball_incremental import IncrementalDomain,IncrementalProcessAdapter,skill_version
from heartball_skill_bundle import load_bundle
from heartball_incremental_review import audit_sources
from heartball_interest import project


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=False,mode=0o700)
    cfg=json.loads(args.config.read_text());bundle=load_bundle(cfg.get('skill_bundle'))
    high=['心力卡在锁屏后停止接收原声，需要排查蓝牙后台断连。','心力卡在蜂窝网络下待传积压，要修复自动上传与重试。']
    low=['楼下奶茶店换了杯子颜色，随口聊珍珠奶茶的甜度。','闲聊楼下奶茶店的杯套图案和奶茶口味。']
    cases=[
        ('specific-high',[(t,'important') for t in high]+[(low[0],'unimportant')],
            '今天心力卡又出现蜂窝网络上传卡住的问题，要确认手机锁屏后自动补传是否还能工作。','high'),
        ('specific-low',[(t,'unimportant') for t in low]+[(high[0],'important')],
            '又闲聊楼下奶茶店，今天杯套是绿色，讨论了珍珠奶茶口味。','low'),
        ('same-category-is-insufficient',[(t,'important') for t in high]+[(low[0],'unimportant')],
            '讨论本季度团队预算，财务给出了新的费用分类标准。','normal'),
        ('cold-start',[(high[0],'important')],
            '心力卡在锁屏后又断开了蓝牙，需要继续排查后台接收问题。','normal')]
    results=[]
    for name,seeds,text,expected in cases:
        root=args.output/name;root.mkdir(mode=0o700);(root/'.agent-runtime-owned').touch(mode=0o600)
        store=Store(root);agent=AgentStore(store);domain=AgentDomain(agent)
        def document(text,index):
            sid=str(uuid.uuid4());did=str(uuid.uuid4());at=f'2026-10-25T12:{index:02d}:00+08:00'
            store.create_session(sid);store.update_session(sid,status='completed')
            agent.policy(sid,asr=False,agent=True,source_kind='live_conversation',occurred_at=at)
            doc=dict(id=did,kind='ambient',session_id=sid,input_key=did,text=text,evidence=[],
                source_kind='live_conversation',occurred_at=at,boundary_quality='source_interval')
            agent.commit_document(doc,dict(title='',summary='',claims=[]));return did
        for index,(seed,rating) in enumerate(seeds):
            did=document(seed,index)
            task=domain.task([did],'隔离的人工标记示例','synthetic-seed')
            result=domain.commit(task,dict(issues=[dict(key='seed',title=seed[:24],summary=seed,
                sources=[dict(document_id=did,revision=1,quote=seed)],display='event')]))
            eid=result['event_ids'][0];event=store.db.execute('SELECT * FROM workspace_events WHERE id=?',(eid,)).fetchone()
            agent.feedback(dict(id=str(uuid.uuid4()),target_id=eid,action='rate_event',expected_version=event['version'],
                expected_interest_version=0,values={'interest':rating}))
        did=document(text,10);inc=IncrementalDomain(agent)
        task=domain.task([did],'从新原文提炼完整事项，参考明确反馈但不泛化。',skill_version(bundle if cfg.get('skill_bundle') else None)).model_copy(update={'complete_events':True})
        before=[tuple(r) for r in store.db.execute('SELECT id,text,revision FROM documents ORDER BY id')]
        response=IncrementalProcessAdapter(root,cfg).run(task)
        row=dict(case=name,expected=expected,status=response.status,asr_calls=0,usage=response.usage)
        if response.status=='completed':
            events=[project(store.db,dict(store.db.execute('SELECT * FROM workspace_events WHERE id=?',(eid,)).fetchone())) for eid in response.receipt['event_ids']]
            actual=[e['suggested_interest'] for e in events]
            documents=[dict(store.db.execute('SELECT * FROM documents WHERE id=?',(did,)).fetchone())]
            row.update(actual=actual,expected_met=bool(actual) and all(v==expected for v in actual),
                integrity=audit_sources(store.db,documents),original_documents_unchanged=before==[tuple(r) for r in store.db.execute('SELECT id,text,revision FROM documents ORDER BY id')])
        else:row.update(expected_met=False,error=response.error)
        results.append(row);store.db.close()
        print(json.dumps({k:v for k,v in row.items() if k!='usage'},ensure_ascii=False),flush=True)
    result=dict(synthetic_only=True,real_user_preference_improvement_measured=False,cases=results,
        passed=all(r['expected_met'] and r['integrity']['passed'] and r['original_documents_unchanged'] for r in results),
        bundle_sha256=bundle.digest)
    (args.output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    raise SystemExit(0 if result['passed'] else 1)


if __name__=='__main__':main()

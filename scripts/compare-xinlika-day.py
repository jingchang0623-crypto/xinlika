#!/usr/bin/env python3
"""One recording day's existing authorized transcripts; isolated native replay, no ASR.

The input contains raw sources, timestamps and recording provenance only. Quality
anchors are loaded by evaluate, never by prepare/run or the model task.
"""
import argparse
import hashlib
import html
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
from zoneinfo import ZoneInfo
import datetime as dt

from heartball_agent_runtime import AgentDomain,readonly_database
from heartball_agent_store import AgentStore
from heartball_runtime_adapters import private_json
from heartball_store import Store
from heartball_source_spans import source_spans

PROJECT=Path(__file__).resolve().parents[1]


def audit_partition(documents,proposal):
    """Independent exact-span conservation check, not a semantic accuracy score."""
    expected={(d['id'],d['revision'],i) for d in documents for i in range(len(source_spans(d['text'])))}
    hits={}
    refs=[r for issue in proposal.get('issues',[]) for r in issue.get('sources',[])]+[f['source'] for f in proposal.get('fragments',[])]
    source_counts={d['id']:len(source_spans(d['text'])) for d in documents}
    for ref in refs:
        ids=range(source_counts.get(ref['document_id'],0)) if ref.get('all_spans') else ref.get('span_ids',[])
        for i in ids:
            key=(ref['document_id'],ref['revision'],i);hits[key]=hits.get(key,0)+1
    return {'expected_spans':len(expected),'assigned_spans':len(expected&hits.keys()),
        'missing_spans':len(expected-hits.keys()),'duplicate_spans':sum(v>1 for v in hits.values()),
        'unknown_or_stale_spans':len(hits.keys()-expected),
        'passed':set(hits)==expected and all(v==1 for v in hits.values()) and not proposal.get('omitted_document_ids')}


def committed_proposal(path,result):
    if result.get('status')!='completed':return None
    if result.get('incremental_replay'):
        db=readonly_database(path/'heartball.sqlite')
        try:
            combined={'issues':[],'topics':[],'fragments':[],'omitted_document_ids':[]}
            for tid in result['task_ids']:
                row=db.execute('SELECT payload FROM incremental_commits WHERE task_id=?',(tid,)).fetchone()
                if not row:return None
                proposal=json.loads(row[0])['proposal']
                for key in combined:combined[key]+=proposal.get(key,[])
            return combined
        finally:db.close()
    for audit in sorted(path.glob('runtime-runs/**/tool-audit.jsonl')):
        for line in audit.read_text().splitlines():
            entry=json.loads(line)
            if entry.get('tool') in {'submit_analysis','commit_staged_analysis'} and entry.get('result',{}).get('task_id')==result['task_id']:
                return entry['args']['proposal']
    return None


def attempt_totals(path,task_id):
    attempts=[]
    ids=set(task_id if isinstance(task_id,list) else [task_id])
    files=sorted([*path.glob('runtime-runs/*/attempt-*/receipt.json'),*path.glob('incremental-runs/*/attempt-*/receipt.json')])
    for file in files:
        data=json.loads(file.read_text())
        if data.get('task_id') not in ids:continue
        usage=data.get('usage',{})
        attempts.append({'attempt':file.parent.name,'status':data['status'],'error':data.get('error'),'seconds':data.get('seconds'),
            'usage':{k:v for k,v in usage.items() if k!='requests'}})
    if not attempts and (path/'day-result.json').exists():
        inherited=json.loads((path/'day-result.json').read_text()).get('inherited_execution')
        if inherited:return {**inherited,'inherited_receipts':True,'new_model_calls_for_ingest':0}
    totals={key:sum(a['usage'].get(key,0) for a in attempts) for key in ('calls','calls_with_usage','prompt_tokens','completion_tokens','total_tokens','cached_tokens')}
    totals.update(usage_complete=bool(attempts) and all(a['usage'].get('usage_complete',False) for a in attempts),currency_cost=None,
        cost_basis='provider_usage_only_including_failed_attempts_no_unverified_price',seconds=sum(a['seconds'] or 0 for a in attempts))
    return {'attempts':attempts,'totals':totals}


def review_totals(path):
    rows=[json.loads(p.read_text()) for p in sorted(path.glob('incremental-reviews/*/receipt.json'))]
    totals={key:sum(r.get('usage',{}).get(key,0) for r in rows) for key in ('calls','calls_with_usage','prompt_tokens','completion_tokens','total_tokens','cached_tokens')}
    return dict(windows=len(rows),failed=sum(r['status']!='completed' for r in rows),
        approved_merges=sum(len(r.get('result',{}).get('merges',[])) for r in rows),
        totals=dict(**totals,seconds=sum(r.get('seconds',0) for r in rows),usage_complete=all(r.get('usage',{}).get('usage_complete',False) for r in rows),currency_cost=None))


def anchor_verdict(status,kind,matches,shown,available=True):
    if status!='completed':return 'unscored_incomplete_run'
    if not available:return 'unscored_source_anchor_unavailable'
    if kind=='separate_sources':return 'passed' if not set.intersection(*matches) else 'failed'
    # An available literal source omitted from issues is a retention miss, not
    # missing test data. Complete-event commits may retain it as a fragment.
    if any(not group for group in matches):return 'failed'
    ok=bool(set.intersection(*matches)) if kind=='same_event' else bool(matches[0]&shown) if kind=='visible' else not bool(set.intersection(*matches))
    return 'passed' if ok else 'failed'


def review_html(corpus,projections):
    """Private source/outputs page. No external assets or transcript in public metrics."""
    esc=lambda x:html.escape(str(x))
    output=['<!doctype html><meta charset="utf-8"><title>全天事件原文复核</title>',
        '<style>body{font:16px system-ui;max-width:1400px;margin:32px auto;padding:0 24px;color:#242624}section{padding:16px;background:#f4f5f3;margin:16px 0;border-radius:12px}article{border-top:1px solid #ddd;padding:12px 0}p{white-space:pre-wrap;line-height:1.6}small{color:#666}table{width:100%;table-layout:fixed}td{vertical-align:top;padding:12px}</style>',
        '<h1>'+esc(corpus['day'])+' · 全天事件原文复核</h1><p>已有转写，无重复 ASR。以下是自动输出和原文，不是人工真值。失败运行不可评分；卡片数量不代表质量。先检查是否同事项完整、不同事项分开、短反馈保留及残句隐藏。</p><table><tr>']
    for runtime,data in projections.items():
        output+=['<td><h2>'+esc(runtime)+'</h2><p>状态：'+esc(data['status'])+'</p>']
        for topic in data.get('topics',[]):
            output+=['<details><summary>主题：'+esc(topic['title'])+'</summary><p>'+esc(topic['summary'])+'</p>']
            for eid in topic['event_ids']:output+=['<p><a href="#event-'+esc(eid)+'">'+esc(next((e['title'] for e in data.get('events',[]) if e['id']==eid),eid))+'</a></p>']
            output+=['</details>']
        for event in data.get('timeline',[]):
            output+=['<article id="event-'+esc(event['id'])+'"><small>'+esc(event.get('start_local') or event.get('occurred_at'))+' · '+esc(event.get('card_style'))+'</small><h3>'+esc(event['title'])+'</h3><p>'+esc(event['summary'])+'</p>']
            for ref in data['refs'].get(event['id'],[]):
                output+=['<p><a href="#'+esc(ref['document_id'])+'">原文来源</a>：'+esc(ref['quote'])+'</p>']
            output+=['</article>']
        output+=['</td>']
    output+=['</tr></table><h2>完整来源</h2>']
    for d in corpus['documents']:
        output+=['<section id="'+esc(d['id'])+'"><small>'+esc(d['occurred_at'])+' · '+esc(d['id'])+'</small>']
        for i,span in enumerate(source_spans(d['text'])):output+=['<p><small>'+str(i)+'</small> '+esc(span)+'</p>']
        output+=['</section>']
    return ''.join(output)


def prepare(args):
    root=args.root.resolve()
    if not root.is_relative_to(PROJECT/'.build') or root.exists():raise ValueError('Use a NEW private .build directory')
    docs={};contexts={};excluded={};zone=ZoneInfo('Asia/Shanghai')
    for path,immutable in [(p,False) for p in args.database]+[(p,True) for p in args.snapshot]:
        db=readonly_database(path,immutable=immutable)
        try:
            for row in db.execute('SELECT d.*,p.agent_allowed FROM documents d LEFT JOIN processing_policies p ON p.session_id=d.session_id'):
                d=dict(row)
                if not d['occurred_at']:continue
                stamp=dt.datetime.fromisoformat(d['occurred_at'].replace('Z','+00:00'))
                if stamp.tzinfo is None or stamp.astimezone(zone).date().isoformat()!=args.day:continue
                reason=('revoked_or_no_grant' if not d.pop('agent_allowed') else 'obsolete_or_no_text' if d['status'] in {'superseded','no_text'} or not d['text'].strip() else 'focus_overlap_separate_path' if d['kind']=='focus' else 'test_unverified' if d['source_kind']=='test_unverified' else None)
                if reason:excluded[reason]=excluded.get(reason,0)+1;continue
                old=docs.get(d['id'])
                if old and old['revision']==d['revision'] and old['text']!=d['text']:raise ValueError('Same source version has conflicting text')
                if not old or d['revision']>=old['revision']:docs[d['id']]=d
                for r in db.execute("SELECT payload FROM events WHERE session_id=? AND kind='recording_context' ORDER BY id DESC LIMIT 1",(d['session_id'],)):
                    contexts[d['session_id']]=json.loads(r[0])
        finally:db.close()
    ordered=sorted(docs.values(),key=lambda d:(dt.datetime.fromisoformat(d['occurred_at'].replace('Z','+00:00')),d['id']))
    if not ordered or len(ordered)>150:raise ValueError('Whole-day replay currently supports 1..150 source documents, not a truncated day')
    root.mkdir(mode=0o700,parents=True)
    corpus={'day':args.day,'documents':ordered,'stages':{'day':[d['id'] for d in ordered]},
        'input_sha256':hashlib.sha256(json.dumps([(d['id'],d['revision'],d['text'],d['occurred_at']) for d in ordered],ensure_ascii=False,sort_keys=True).encode()).hexdigest(),
        'excluded':excluded,'asr_invoked':False,'labels_in_model_prompts':False,
        'scope':'all_available_authorized_ambient_transcripts_on_recording_day_not_24h_audio_coverage',
        'characters':sum(len(d['text']) for d in ordered),'source_spans':sum(len(source_spans(d['text'])) for d in ordered)}
    # Strip previous derived summaries/claims from the persisted inference input.
    for d in ordered:
        d['title']='';d['summary']=''
    private_json(root/'corpus-private.json',corpus)
    for runtime in ('hermes','deepseek-harness'):
        path=root/runtime;path.mkdir(mode=0o700);(path/'.agent-runtime-owned').touch(mode=0o600)
        store=Store(path);agent=AgentStore(store)
        try:
            for d in ordered:
                sid=d['session_id']
                store.db.execute("INSERT OR IGNORE INTO sessions(id,status,started_at,ended_at,batch_seconds,directory,source_kind) VALUES(?,'completed',?,?,60,?,?)",(sid,d['occurred_at'],d['occurred_at'],str(path/'no-hardware'),d['source_kind']))
                if not agent._policy(sid):agent.policy(sid,asr=False,agent=True,source_kind=d['source_kind'],occurred_at=d['occurred_at'])
                agent.commit_document({**d,'evidence':json.loads(d['evidence'])},{'title':'','summary':'','claims':[]})
            for sid,context in contexts.items():
                if store.db.execute('SELECT 1 FROM sessions WHERE id=?',(sid,)).fetchone():store.event(sid,'recording_context',context)
            AgentDomain(agent);store.db.commit()
        finally:store.db.close()
    print(json.dumps({k:corpus[k] for k in ('day','characters','source_spans','input_sha256','excluded','scope')}|{'documents':len(ordered),'asr_calls':0},ensure_ascii=False),flush=True)


def run(args):
    spec=importlib.util.spec_from_file_location('native_comparison',Path(__file__).with_name('compare-xinlika-agents.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    module.run(SimpleNamespace(root=args.root,runtime=args.runtime,stage='day',dinner_window=None,complete_events=True,
        model_config=args.model_config,hermes_python=args.hermes_python,client_python=args.client_python,timeout=args.timeout,retry=False))


def evaluate(args):
    corpus=json.loads((args.root/'corpus-private.json').read_text())
    anchors=json.loads(args.cases.read_text())['cases']
    docs={d['id']:d for d in corpus['documents']}
    meeting=json.loads(args.meeting_run.read_text());positive={meeting['round1'],meeting['round3']};negative=meeting['round2']
    outputs={};projections={}
    for runtime in getattr(args,'runtimes',('hermes','deepseek-harness')):
        path=args.root/runtime
        result=json.loads((path/'day-result.json').read_text()) if (path/'day-result.json').exists() else {'status':'not_finished'}
        db=readonly_database(path/'heartball.sqlite')
        try:
            events={r['id']:dict(r) for r in db.execute("SELECT * FROM workspace_events WHERE status='active'")}
            refs={eid:[dict(r) for r in db.execute('SELECT * FROM workspace_event_sources WHERE event_id=?',(eid,))] for eid in events}
            from heartball_timeline import visible
            shown={eid for eid,e in events.items() if visible(db,e)}
            checks=[]
            for case in anchors:
                matches=[{eid for eid in events if any(s['document_id']==r['document_id'] and r['quote'] in s['quote'] for s in refs[eid])} for r in case['refs']]
                kind=case['kind']
                available=all(r['document_id'] in docs and docs[r['document_id']]['revision']==r['revision'] and r['quote'] in docs[r['document_id']]['text'] for r in case['refs'])
                if result['status']!='completed':verdict='unscored_incomplete_run'
                elif not available:verdict='unscored_source_anchor_unavailable'
                elif kind=='fragment':
                    did=case['refs'][0]['document_id'];ok=not any(eid in shown and {s['document_id'] for s in refs[eid]}=={did} for eid in events)
                    verdict='passed' if ok else 'failed'
                else:verdict=anchor_verdict(result['status'],kind,matches,shown,available)
                checks.append({'id':case['id'],'result':verdict})
            groups=[{r[0] for r in db.execute("SELECT DISTINCT e.session_id FROM workspace_events e JOIN workspace_all_event_topics l ON l.event_id=e.id WHERE l.topic_id=? AND e.status='active'",(t[0],))} for t in db.execute("SELECT id FROM workspace_topics WHERE status='active'")]
            from heartball_day import daily_workspace
            timeline=daily_workspace(db,corpus['day'])
            usage=result.get('usage',{})
            completed=result['status']=='completed'
            proposal=committed_proposal(path,result)
            partition=audit_partition(corpus['documents'],proposal) if proposal is not None else {'status':'unscored_no_committed_proposal'}
            outputs[runtime]={'status':result['status'],'error':result.get('error'),'seconds':result.get('seconds'),'usage':{k:v for k,v in usage.items() if k!='requests'},
                'execution':attempt_totals(path,result.get('task_ids') or result.get('task_id')),
                'rolling_review':review_totals(path),
                'homepage_events':len(timeline['timeline']),'retained_fragment_spans':db.execute('SELECT count(*) FROM agent_source_fragments').fetchone()[0],
                'checks':checks,'span_partition':partition,'same_matter_cross_conversation_link':any(positive<=g and negative not in g for g in groups) if completed else None,
                'different_matter_kept_separate':not any(negative in g and bool(positive&g) for g in groups) if completed else None,
                'asr_jobs':db.execute("SELECT count(*) FROM jobs WHERE kind='asr_audio'").fetchone()[0]}
            topics=[dict(t)|{'event_ids':[r[0] for r in db.execute('SELECT event_id FROM workspace_all_event_topics WHERE topic_id=?',(t['id'],))]} for t in db.execute("SELECT * FROM workspace_topics WHERE status='active'")]
            projections[runtime]={'status':result['status'],'timeline':timeline['timeline'],'refs':refs,'events':list(events.values()),'topics':topics}
            private_json(path/'timeline-private.json',timeline)
        finally:db.close()
    report={'day':corpus['day'],'input_sha256':corpus['input_sha256'],'documents':len(corpus['documents']),'characters':corpus['characters'],
        'source_spans':corpus['source_spans'],'source_scope':corpus['scope'],'quality_method':'project_regression_anchors_not_independent_human_gold; original source review required',
        'labels_in_prompts':False,'asr_calls':0,'cross_conversation_metric_scope':'session_level_source_coverage_requires_manual_issue_range_review','results':outputs}
    private_json(args.root/'comparison.json',report)
    review=args.root/'review-private.html';review.write_text(review_html(corpus,projections));review.chmod(0o600)
    print(json.dumps(report,ensure_ascii=False,indent=2))


def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('prepare');p.add_argument('--root',type=Path,required=True);p.add_argument('--day',required=True)
    p.add_argument('--database',type=Path,action='append',default=[]);p.add_argument('--snapshot',type=Path,action='append',default=[])
    r=sub.add_parser('run');r.add_argument('--root',type=Path,required=True);r.add_argument('--runtime',choices=['both','hermes','deepseek-harness'],default='both')
    r.add_argument('--model-config',type=Path,required=True);r.add_argument('--hermes-python',type=Path,required=True);r.add_argument('--client-python',type=Path,required=True);r.add_argument('--timeout',type=int,default=900)
    e=sub.add_parser('evaluate');e.add_argument('--root',type=Path,required=True);e.add_argument('--cases',type=Path,required=True);e.add_argument('--meeting-run',type=Path,required=True)
    args=parser.parse_args();{'prepare':prepare,'run':run,'evaluate':evaluate}[args.command](args)


if __name__=='__main__':main()

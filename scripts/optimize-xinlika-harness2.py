#!/usr/bin/env python3
"""Opt-in, isolated Harness² experiment. Existing text only; no production APIs."""
import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

from heartball_harness2 import digest,owned_root,UPSTREAM,FrozenReplayAdapter,model_proposer
from heartball_runtime_adapters import private_json,ModelMeter
from heartball_skill_bundle import FILES,load_bundle,publish_manifest
from heartball_harness2_safety import finished_or_claim,evaluation_registration,verify_evaluation_registration


def upstream(path):
    path=Path(path).resolve()
    actual=subprocess.check_output(['git','-C',str(path),'rev-parse','HEAD'],text=True).strip()
    if actual!=UPSTREAM:raise ValueError('Use the pinned upstream Harness² commit')
    if subprocess.check_output(['git','-C',str(path),'status','--porcelain','--untracked-files=no'],text=True).strip():raise ValueError('Upstream tracked source must be unmodified')
    sys.path.insert(0,str(path))


def prepare(args):
    root=owned_root(args.root)
    if root.exists():raise ValueError('Use a NEW experiment root')
    root.mkdir(parents=True,mode=0o700)
    corpus=json.loads(args.corpus.read_text());meeting=json.loads(args.meeting_run.read_text())
    plan=json.loads(args.split_plan.read_text());development=plan['development']
    def selected(d):
        clock=dt.datetime.fromisoformat(d['occurred_at'].replace('Z','+00:00'))
        return d['session_id'] in development.get('session_ids',[]) or any(d['session_id']==r['session_id'] and dt.datetime.fromisoformat(r['start'])<=clock<=dt.datetime.fromisoformat(r['end']) for r in development.get('ranges',[]))
    docs=[d for d in corpus['documents'] if selected(d)]
    contexts={}
    db=sqlite3.connect(args.source_snapshot.resolve().as_uri()+'?mode=ro&immutable=1',uri=True)
    try:
        for sid,payload in db.execute("SELECT session_id,payload FROM events WHERE kind='recording_context'"):
            if sid in {d['session_id'] for d in docs}:contexts[sid]=json.loads(payload)
    finally:db.close()
    # The holdout date and entire physical recording ranges are selected before
    # any optimization. Never split adjacent minutes across development/test.
    held=json.loads(args.holdout_snapshot.read_text())['documents']
    holdout_sids=set(plan['holdout']['session_ids'])
    held=[d for d in held if d['session_id'] in holdout_sids and d.get('text','').strip() and d['kind']=='ambient']
    if {d['session_id'] for d in held}!=holdout_sids:raise ValueError('Incomplete selected holdout recordings')
    if {d['id'] for d in docs}&{d['id'] for d in held}:raise ValueError('Source overlap')
    fields=('id','kind','session_id','input_key','text','evidence','source_kind','status','revision','occurred_at','boundary_quality')
    def export(split,task,documents,context):
        path=root/'data'/split/task
        clean=[{k:d[k] for k in fields if k in d} for d in documents]
        value={'documents':clean,'recording_contexts':context}
        private_json(path/'sources.json',value)
        private_json(path.parent/'index.json',{'split':split,'tasks':{task:digest(value)}})
        return {'documents':len(documents),'characters':sum(len(d['text']) for d in documents),'sha256':digest(value),'sessions':sorted({d['session_id'] for d in documents}),'dates':sorted({d['occurred_at'][:10] for d in documents})}
    dev=export('dev','recorded-contexts',docs,contexts);test=export('holdout','unseen-recordings',held,{})
    # Labels live outside sources. Optimizer sees neither these nor holdout.
    private_json(root/'evaluation/dev-labels-private.json',json.loads(args.cases.read_text()))
    private_json(root/'evaluation/holdout-labels-private.json',json.loads(args.holdout_cases.read_text()))
    private_json(root/'evaluation/meeting-labels-private.json',{k:meeting[k] for k in ('round1','round2','round3')})
    private_json(root/'evaluation/freeze.json',dict(frozen_before_candidate_and_holdout=True,**evaluation_registration(root)))
    manifest={'schema':1,'upstream_commit':UPSTREAM,'base_bundle_sha256':load_bundle(args.base_bundle).digest,'base_bundle_path':str(load_bundle(args.base_bundle).manifest),'development':dev,'holdout':test,
        'partition':'explicit_private_plan; whole_selected_recording_groups_in_holdout; zero_document_overlap',
        'split_plan_sha256':digest(plan),
        'historical_exposure':plan.get('historical_exposure','Must be documented by the experiment owner; isolation here proves no source overlap, not prior research exposure.'),
        'asr_calls':0,'source_overlap':0,'frozen_before_optimization':True}
    private_json(root/'manifest-private.json',manifest)
    print(json.dumps({k:manifest[k] for k in ('upstream_commit','development','holdout','asr_calls','source_overlap')},ensure_ascii=False),flush=True)


def optimize(args):
    root=owned_root(args.root)
    existing=finished_or_claim(root)
    if existing is not None:
        print(json.dumps(dict(status=existing['status'],reused=True,additional_model_calls=0,asr_calls=0,automatic_activation=False)),flush=True)
        return
    upstream(args.upstream);verify_evaluation_registration(root)
    manifest=json.loads((root/'manifest-private.json').read_text())
    if load_bundle(manifest.get('base_bundle_path')).digest!=manifest['base_bundle_sha256']:raise ValueError('Published base changed after freeze')
    from harness2.core.schedule import run_domain,Namespace
    # One outer meter is the authoritative provider ledger. Child meters are
    # execution traces, not additional paid calls; never add both together.
    cfg=json.loads(args.model_config.read_text());meter=ModelMeter(cfg,root/'provider-ledger',max_calls=args.max_calls)
    token=root/'loopback-key';token.write_text(meter.key);token.chmod(0o600)
    local={**cfg,'base_url':meter.base_url,'api_key_file':str(token),'capture_model_payloads':True}
    local['base_skill_bundle']=manifest.get('base_bundle_path')
    local.pop('review_draft_root',None)
    status={}
    try:
        adapter=FrozenReplayAdapter(root/'development',root/'data/dev',local)
        proposer=model_proposer(local,root/'editor-runs',adapter.spec.channels['proposer'])
        result=run_domain('ambient-conversation',adapter.tasks(),1,adapter=adapter,prop=proposer,runs_root=adapter.spec.runs_root,library_root=root/'experience-library',modes=('seq',))
        private_json(root/'upstream-result-private.json',result)
        summaries=list(adapter.spec.runs_root.glob('**/summary.json'))
        if result['failed'] or not summaries:raise ValueError('Upstream optimization incomplete')
        summary=json.loads(summaries[0].read_text());selection=summary['selections']['seq'];candidate=summaries[0].parent
        # Sequential namespace differs from the shared-base namespace.
        candidate=Namespace('xinlika',adapter.substrate.name,'seq',1).task_dir(adapter.spec.runs_root,'recorded-contexts')/'harnesses'/selection['chosen_label']
        if not candidate.is_dir():raise ValueError('Missing composed candidate')
        from harness2.core import tree
        value=tree.read_tree(adapter.substrate.surface(),candidate);adapter.validate_tree(value)
        frozen=root/'frozen-candidate';tree.write_tree(adapter.substrate.surface(),value,frozen,stubs=False)
        bundle=publish_manifest(frozen,'harness2-candidate-v1')
        private_json(root/'candidate-frozen.json',dict(bundle_sha256=bundle.digest,upstream_commit=UPSTREAM,selected_label=selection['chosen_label'],holdout_not_read_by_optimizer=True))
        # No proposal/selection/reflection is invoked from here onward. Holdout
        # results cannot feed back into the frozen candidate or its library.
        held_adapter=FrozenReplayAdapter(root/'independent-test',root/'data/holdout',local)
        task=held_adapter.tasks()[0]
        baseline=held_adapter.execute(task,None,'holdout-base')
        trial=held_adapter.execute(task,frozen,'holdout-candidate')
        status=dict(status='completed' if held_adapter.delivered(baseline) and held_adapter.delivered(trial) else 'holdout_incomplete',
            candidate_sha256=bundle.digest,baseline_run=str(baseline),candidate_run=str(trial),development_executions=adapter.execution_records,holdout_executions=held_adapter.execution_records,
            automatic_activation=False,asr_calls=0)
    except Exception as exc:status=dict(status='failed',error=type(exc).__name__+': '+str(exc)[:1200],automatic_activation=False,asr_calls=0)
    finally:
        meter.close();status['provider_usage']=meter.summary();private_json(root/'experiment-private.json',status)
    print(json.dumps({k:status.get(k) for k in ('status','error','asr_calls','automatic_activation')}),flush=True)


def main():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='command',required=True)
    a=sub.add_parser('prepare');a.add_argument('--root',type=Path,required=True);a.add_argument('--corpus',type=Path,required=True);a.add_argument('--meeting-run',type=Path,required=True);a.add_argument('--cases',type=Path,required=True);a.add_argument('--holdout-cases',type=Path,required=True);a.add_argument('--source-snapshot',type=Path,required=True);a.add_argument('--holdout-snapshot',type=Path,required=True);a.add_argument('--base-bundle',type=Path);a.add_argument('--split-plan',type=Path,required=True)
    a=sub.add_parser('optimize');a.add_argument('--root',type=Path,required=True);a.add_argument('--upstream',type=Path,required=True);a.add_argument('--model-config',type=Path,required=True);a.add_argument('--max-calls',type=int,default=200)
    args=p.parse_args();{'prepare':prepare,'optimize':optimize}[args.command](args)


if __name__=='__main__':main()

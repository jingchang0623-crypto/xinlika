#!/usr/bin/env python3
"""Matched frozen-text replay. Development first, one sealed independent test.

This validates an explicitly supplied Skill revision; it does not claim to run
Harness² automatic proposal/selection. The same upstream adapter executes it.
"""
import argparse
import json
from pathlib import Path
import sys

from heartball_harness2 import FrozenReplayAdapter,owned_root,digest
from heartball_harness2_evaluation import assess,usage_under
from heartball_harness2_safety import finished_or_claim,verify_evaluation_registration,semantic_configuration,engine_snapshot
from heartball_runtime_adapters import ModelMeter,private_json
from heartball_skill_bundle import FILES,load_bundle,publish_manifest


def run(args):
    root=owned_root(args.root);trial=root/'trials'/args.trial;phase=trial/args.phase
    if args.trial not in {'v3','v4','v5','v6'}:raise ValueError('Use a bounded named development revision')
    if args.candidate_only and args.phase!='development':raise ValueError('Independent test always needs a matched baseline')
    verify_evaluation_registration(root)
    phase.mkdir(parents=True,exist_ok=True,mode=0o700)
    existing=finished_or_claim(phase)
    if existing is not None:
        print(json.dumps({'status':existing['status'],'reused':True,'additional_model_calls':0}));return
    cfg=json.loads(args.model_config.read_text())
    if args.phase=='holdout':
        dev=json.loads((trial/'development/experiment-private.json').read_text())
        c=dev['results']['candidate']
        if c['status']!='completed' or c['failed'] or c['unscored'] or not c['source_integrity']['passed']:
            raise ValueError('Candidate must pass every registered development check before independent test')
        if any(p!=phase and ((p/'experiment-private.json').exists() or (p/'provider-ledger').exists()) for p in (root/'trials').glob('*/holdout')):
            raise ValueError('Independent test is sealed after its first evaluation; do not tune against it')
        frozen=trial/'frozen-candidate'
        registered=json.loads((trial/'candidate-frozen.json').read_text())
        if load_bundle(frozen/'bundle.json').digest!=registered['bundle_sha256']:raise ValueError('Frozen candidate changed')
        if registered.get('engine_sha256')!=digest(engine_snapshot(Path(__file__).parent)) or registered.get('model_identity')!=semantic_configuration(cfg):
            raise ValueError('Engine or model changed after development freeze; independent test is not eligible')
    meter=ModelMeter(cfg,phase/'provider-ledger',max_calls=args.max_calls)
    key=phase/'loopback-key';key.write_text(meter.key);key.chmod(0o600)
    local={**cfg,'base_url':meter.base_url,'api_key_file':str(key),'capture_model_payloads':True,'base_skill_bundle':str(args.base_bundle.resolve())}
    local.pop('review_draft_root',None)
    result={'status':'failed','phase':args.phase,'asr_calls':0,'automatic_activation':False}
    try:
        split='dev' if args.phase=='development' else 'holdout'
        adapter=FrozenReplayAdapter(phase/'replay',root/f'data/{split}',local)
        if args.phase=='development':
            from harness2.core import tree
            value=dict(adapter.initial_tree);bundle=load_bundle(args.candidate_bundle)
            value.update({rel:bundle.texts[name] for name,rel in FILES.items()})
            frozen=trial/'frozen-candidate';tree.write_tree(adapter.substrate.surface(),value,frozen,stubs=False)
            published=publish_manifest(frozen,bundle.version)
            private_json(trial/'candidate-frozen.json',{'bundle_sha256':published.digest,'engine_sha256':adapter.code_hash,
                'model_identity':semantic_configuration(cfg),'before_independent_test':True,'manual_semantic_revision':True})
        sources=json.loads((adapter.task_files(adapter.tasks()[0])/'sources.json').read_text())
        labels=json.loads((root/f'evaluation/{split}-labels-private.json').read_text())
        reports={};paths={}
        executions=[('candidate',frozen)] if args.candidate_only else [('baseline',None),('candidate',frozen)]
        for role,harness in executions:
            path=adapter.execute(adapter.tasks()[0],harness,args.phase+'-'+role)
            reports[role]={**assess(path,labels,sources['documents']),'cost':usage_under(path)};paths[role]=str(path)
        result.update(status='completed' if all(r['status']=='completed' for r in reports.values()) else 'incomplete',results=reports,paths=paths,
            candidate_sha256=load_bundle(frozen/'bundle.json').digest,
            measured_checks_passed=reports['candidate']['status']=='completed' and not reports['candidate']['failed'] and not reports['candidate']['unscored'])
    except Exception as exc:result['error']=type(exc).__name__+': '+str(exc)[:700]
    finally:
        meter.close();result['provider_usage']=meter.summary();private_json(phase/'experiment-private.json',result)
    print(json.dumps({k:result.get(k) for k in ('status','phase','error','measured_checks_passed','asr_calls','automatic_activation')},ensure_ascii=False),flush=True)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--trial',required=True);p.add_argument('--phase',choices=['development','holdout'],required=True)
    p.add_argument('--base-bundle',type=Path,required=True);p.add_argument('--candidate-bundle',type=Path);p.add_argument('--model-config',type=Path,required=True);p.add_argument('--max-calls',type=int,default=24);p.add_argument('--candidate-only',action='store_true',help='Development only; do not buy another baseline already characterized in previous revisions')
    args=p.parse_args();run(args)


if __name__=='__main__':main()

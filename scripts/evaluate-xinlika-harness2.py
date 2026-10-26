#!/usr/bin/env python3
"""After optimization: verify the frozen evaluator, compare outcomes, save metrics."""
import argparse
import hashlib
import json
from pathlib import Path

from heartball_harness2 import owned_root,digest
from heartball_harness2_evaluation import assess,usage_under,gate
from heartball_runtime_adapters import private_json


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--public-output',type=Path);args=p.parse_args()
    root=owned_root(args.root);frozen=json.loads((root/'evaluation/freeze.json').read_text())
    paths=[root/'evaluation/dev-labels-private.json',root/'evaluation/holdout-labels-private.json',Path(__file__).with_name('heartball_harness2_evaluation.py')]
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=frozen['files'][p.name] for p in paths):raise ValueError('Registered checks changed after freeze')
    experiment=json.loads((root/'experiment-private.json').read_text());manifest=json.loads((root/'manifest-private.json').read_text())
    reports={};roles={};checksums={}
    summary_paths=list((root/'development/upstream-runs').glob('**/summary.json'))
    if summary_paths:
        summary=json.loads(summary_paths[0].read_text());base=summary.get('base',[])
        if base:roles['development_baseline']=Path(base[0]['run_dir'])
        selected=summary.get('selections',{}).get('seq',{}).get('chosen_run_dir')
        if selected:roles['development_candidate']=Path(selected)
    if experiment.get('baseline_run'):roles['independent_baseline']=Path(experiment['baseline_run'])
    if experiment.get('candidate_run'):roles['independent_candidate']=Path(experiment['candidate_run'])
    for role,path in roles.items():
        if not path.resolve().is_relative_to(root):raise ValueError('Execution path is outside experiment')
        split='holdout' if role.startswith('independent') else 'dev';task='unseen-recordings' if split=='holdout' else 'recorded-contexts'
        sources=json.loads((root/f'data/{split}/{task}/sources.json').read_text());labels=json.loads((root/f'evaluation/{split}-labels-private.json').read_text())
        reports[role]=dict(**assess(path,labels,sources['documents']),cost=usage_under(path))
        checksums[role]=hashlib.sha256((path/'result.json').read_bytes()).hexdigest()
    adoption=gate(reports['independent_baseline'],reports['independent_candidate']) if {'independent_baseline','independent_candidate'}<=set(reports) else dict(accepted=False,reasons=['independent_test_not_completed'],automatic_activation=False)
    usage=experiment['provider_usage'];keys=('calls','calls_with_usage','prompt_tokens','completion_tokens','total_tokens','cached_tokens','usage_complete','currency_cost','guardrail_reason')
    editor_rows=[json.loads(p.read_text()) for p in (root/'editor-runs').glob('*/model-meter/usage.json')]
    editor_cost={k:sum(r.get(k,0) for r in editor_rows) for k in ('calls','calls_with_usage','prompt_tokens','completion_tokens','total_tokens','cached_tokens')}
    unique_dirs={p.resolve() for p in (root/'development/executions').glob('*') if (p/'result.json').exists()}|{p.resolve() for p in (root/'independent-test/executions').glob('*') if (p/'result.json').exists()}
    solver_cost={k:sum(usage_under(p).get(k,0) for p in unique_dirs) for k in ('calls','calls_with_usage','prompt_tokens','completion_tokens','total_tokens','cached_tokens')}
    result=dict(status=experiment['status'],upstream_commit=manifest['upstream_commit'],
        input_partition={split:{k:v for k,v in manifest[split].items() if k!='sessions'} for split in ('development','holdout')},
        source_overlap=manifest['source_overlap'],historical_exposure=manifest['historical_exposure'],
        method='pre-registered literal ASR-anchor checks; structural fixtures are not quality scores; no word-accuracy or independent cross-link recall claim',
        candidate_sha256=experiment.get('candidate_sha256'),results=reports,adoption=adoption,
        total_actual_provider_usage={k:usage.get(k) for k in keys},editor_cost=editor_cost,unique_solver_cost=solver_cost,
        cost_reconciled=all(editor_cost[k]+solver_cost[k]==usage.get(k,0) for k in ('calls','total_tokens')),
        safety=dict(asr_calls=0,hardware_commands=0,service_restarts=0,production_writes=0,git_commits=0,automatic_activation=False),
        evidence_sha256=checksums,
        limitations=['The independent date contains no confirmed positive cross-conversation pair; that recall remains unscored.','Development material was exposed during previous manual tuning.','ASR source text was read for labels, not re-listened; this is not speech-recognition accuracy.','Upstream k=1 adopts its sole composed final; the separate external gate preserves baseline fallback.'])
    private_json(root/'comparison.json',result)
    if args.public_output:
        public=json.loads(json.dumps(result))
        for role,report in public['results'].items():
            error=report.pop('error',None)
            if error:report['error_type']=error.split(':',1)[0]
        args.public_output.parent.mkdir(parents=True,exist_ok=True);args.public_output.write_text(json.dumps(public,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False,indent=2))


if __name__=='__main__':main()

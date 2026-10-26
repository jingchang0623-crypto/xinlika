"""Post-freeze literal-anchor comparisons; never imported by the optimizer."""
import json
from pathlib import Path


def assess(run_dir,labels,documents):
    run_dir=Path(run_dir);result=json.loads((run_dir/'result.json').read_text())
    output=json.loads((run_dir/'deliverable.json').read_text()) if result['status']=='completed' else {'events':[],'topics':[]}
    events={e['id']:e for e in output['events']};shown={eid for eid,e in events.items() if e['visible']};docs={d['id']:d for d in documents}
    groups=[set(t['event_ids']) for t in output['topics']];checks=[]
    for case in labels['cases']:
        refs=case['refs'];kind=case['kind']
        available=all(r['document_id'] in docs and r['revision']==docs[r['document_id']]['revision'] and r['quote'] in docs[r['document_id']]['text'] for r in refs)
        owners=[{eid for eid,e in events.items() if any(s['document_id']==r['document_id'] and r['quote'] in s['quote'] for s in e['sources'])} for r in refs]
        if not available:status='unscored_source_unavailable'
        elif result['status']!='completed':status='unscored_incomplete_execution'
        elif kind=='fragment':
            did=refs[0]['document_id'];status='failed' if any(eid in shown and {s['document_id'] for s in events[eid]['sources']}=={did} for eid in events) else 'passed'
        elif kind=='visible':status='passed' if owners[0]&shown else 'failed'
        elif kind=='same_event':status='passed' if owners and all(owners) and set.intersection(*owners) else 'failed'
        elif kind=='different_events':status='passed' if all(owners) and not set.intersection(*owners) else 'failed'
        elif kind=='separate_sources':status='passed' if not set.intersection(*owners) else 'failed'
        elif kind=='same_relation':status='passed' if all(owners) and any(all(g&o for o in owners) for g in groups) else 'failed'
        elif kind=='different_relation':status='unscored_missing_event_owner' if not all(owners) else 'failed' if set.intersection(*owners) or any(all(g&o for o in owners) for g in groups) else 'passed'
        else:raise ValueError('Unknown literal check')
        checks.append(dict(id=case['id'],kind=kind,result=status))
    return dict(status=result['status'],error=result.get('error'),source_integrity=result.get('source_integrity'),
        homepage_events=result.get('homepage_events'),checks=checks,passed=sum(c['result']=='passed' for c in checks),
        failed=sum(c['result']=='failed' for c in checks),unscored=sum(c['result'].startswith('unscored') for c in checks),
        independent_positive_cross_conversation=labels.get('positive_cross_conversation'))


def usage_under(run_dir):
    """Only domain-call meters; excludes the outer provider ledger and editors."""
    rows=[json.loads(p.read_text()) for p in Path(run_dir).glob('workspace/**/model-meter/usage.json')]
    keys=('calls','calls_with_usage','prompt_tokens','completion_tokens','total_tokens','cached_tokens')
    return dict(**{k:sum(r.get(k,0) for r in rows) for k in keys},usage_complete=all(r.get('usage_complete',False) for r in rows),currency_cost=None)


def gate(baseline,candidate):
    """External baseline fallback; upstream k=1 itself always adopts its final."""
    reasons=[]
    if baseline['status']!='completed':reasons.append('matched_baseline_incomplete')
    if candidate['status']!='completed':reasons.append('candidate_incomplete')
    before={c['id']:c['result'] for c in baseline['checks']}
    if any(c['result']=='failed' and before.get(c['id'])=='passed' for c in candidate['checks']):reasons.append('literal_regression')
    if candidate['failed']:reasons.append('unresolved_independent_checks')
    if candidate['unscored']:reasons.append('independent_checks_unscored')
    if not (candidate.get('source_integrity') or {}).get('passed'):reasons.append('source_integrity_not_proven')
    return dict(accepted=not reasons,reasons=reasons,automatic_activation=False)

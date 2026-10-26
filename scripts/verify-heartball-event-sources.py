#!/usr/bin/env python3
"""Read-only source-relationship acceptance. Private labels never belong in Git.

The expected file contains document IDs/revisions and literal character ranges,
with same_event, different_events, visible or fragment relationships. It never
uses a second ASR result or model agreement as accuracy ground truth.
"""
import argparse
import json
import sqlite3
from pathlib import Path


def covered(ranges,start,end):
    cursor=start
    for a,b in sorted(ranges):
        if a>cursor:return False
        cursor=max(cursor,b)
        if cursor>=end:return True
    return False


def holders(db,ref,status):
    doc=db.execute('SELECT * FROM documents WHERE id=?',(ref['document_id'],)).fetchone()
    if not doc or doc['revision']!=ref['revision'] or doc['text'][ref['start']:ref['end']]!=ref['quote']:
        raise ValueError('Acceptance reference no longer matches the original document')
    events={r[0] for r in db.execute('SELECT s.event_id FROM workspace_event_sources s JOIN workspace_events e ON e.id=s.event_id WHERE s.document_id=? AND e.status=?',(doc['id'],status))}
    precise=db.execute("SELECT 1 FROM sqlite_master WHERE name='workspace_refined_ranges'").fetchone()
    result=set()
    for eid in events:
        ranges=[]
        if precise:ranges=[tuple(r) for r in db.execute('SELECT start_char,end_char FROM workspace_refined_ranges WHERE event_id=? AND document_id=? AND revision=?',(eid,doc['id'],ref['revision']))]
        if not ranges:
            for row in db.execute('SELECT quote FROM workspace_event_sources WHERE event_id=? AND document_id=? AND revision=?',(eid,doc['id'],ref['revision'])):
                start=doc['text'].find(row[0])
                if start>=0:ranges.append((start,start+len(row[0])))
        if covered(ranges,ref['start'],ref['end']):result.add(eid)
    return result


def evaluate(db,expected):
    results=[]
    for case in expected['cases']:
        visible=[holders(db,r,'active') for r in case['refs']]
        if case['kind']=='same_event':passed=bool(set.intersection(*visible))
        elif case['kind']=='different_events':passed=all(visible) and not any(a&b for i,a in enumerate(visible) for b in visible[i+1:])
        elif case['kind']=='separate_sources':
            retained=[v|holders(db,r,'fragment') for v,r in zip(visible,case['refs'])]
            passed=all(retained) and not any(a&b for i,a in enumerate(visible) for b in visible[i+1:])
        elif case['kind']=='visible':passed=all(visible)
        elif case['kind']=='fragment':passed=not any(visible) and all(holders(db,r,'fragment') for r in case['refs'])
        else:raise ValueError('Unknown source relationship')
        results.append({'case_id':case['id'],'kind':case['kind'],'passed':bool(passed)})
    return {'passed':all(r['passed'] for r in results),'checks':results,'scope':'Specified literal source relationships only; not word/speaker accuracy or general semantic accuracy.'}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database',type=Path,required=True)
    parser.add_argument('--expected',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--immutable-snapshot',action='store_true',help='Only for a closed, checkpointed snapshot with no writer or WAL; never use for a live ledger')
    args=parser.parse_args()
    if args.immutable_snapshot and Path(str(args.database)+'-wal').exists():parser.error('Checkpoint and close snapshot before immutable reading')
    db=sqlite3.connect(args.database.resolve().as_uri()+'?mode=ro'+('&immutable=1' if args.immutable_snapshot else ''),uri=True);db.row_factory=sqlite3.Row
    result=evaluate(db,json.loads(args.expected.read_text()));args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)

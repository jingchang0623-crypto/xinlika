#!/usr/bin/env python3
"""Private real-model activity projection over a read-only ledger snapshot.

No capture, ASR, production writes, or manufactured dialogue. A successful
projection is not evidence that inferred activity labels/boundaries are accurate.
"""
import argparse
import json
from pathlib import Path
import sqlite3
import time
from heartball_processing import Processor,ModelAdapter
from heartball_store import Store

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source-db',type=Path,required=True);p.add_argument('--config',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=False,mode=0o700)
src=sqlite3.connect(a.source_db.resolve().as_uri()+'?mode=ro',uri=True);dst=sqlite3.connect(a.output/'heartball.sqlite');src.backup(dst);src.close();dst.close()
s=Store(a.output);proc=Processor(s,ModelAdapter(json.loads(a.config.read_text())['model']))
try:
    assert proc.activities.request(force=True),'No eligible bounded activity context'
    row=s.db.execute('SELECT * FROM workspace_activity_runs ORDER BY rowid DESC LIMIT 1').fetchone();begun=time.monotonic()
    proc.activities.run(row['run_key'],proc.model)
    day=proc.agent.state()['today'];groups=day['groups'];context=json.loads(row['context'])
    result={'scope':'Authorized real transcript ledger + actual model, private snapshot only','input_issues':len(context['events']),
        'groups':len(groups),'classified_groups':sum(g['activity_kind']!='unclassified' for g in groups),
        'events':day['event_count'],'focuses':day['focus_count'],
        'group_kind_counts':{k:sum(g['activity_kind']==k for g in groups) for k in {g['activity_kind'] for g in groups}},
        'elapsed_seconds':time.monotonic()-begun,'source_events_not_merged':True,'new_asr_calls':0,'production_writes':False,
        'duration_precision':'observed_source_envelope_not_word_or_meeting_boundary','activity_boundary_accuracy_accepted':False}
    (a.output/'today-private.json').write_text(json.dumps(day,ensure_ascii=False,indent=2))
    (a.output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result),flush=True)
finally:proc.close();s.db.close()

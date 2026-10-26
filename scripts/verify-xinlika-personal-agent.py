#!/usr/bin/env python3
"""Shadow-test the Personal Agent with explicitly selected, existing real records.

Read-only source DB; isolated output only. No recording, ASR, production advice,
fabricated progress, or automatic source relabelling. Silence is a valid result.
"""
import argparse
import json
from pathlib import Path
import sqlite3

from heartball_processing import ModelAdapter, Processor
from heartball_store import Store


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-db',type=Path,required=True)
    p.add_argument('--session',action='append',required=True)
    p.add_argument('--config',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    if a.output.exists():p.error('Use a new private output directory')
    source=sqlite3.connect(a.source_db.resolve().as_uri()+'?mode=ro',uri=True);source.row_factory=sqlite3.Row
    out=Store(a.output);proc=Processor(out,ModelAdapter(json.loads(a.config.read_text())['model']))
    records=[]
    try:
        for sid in a.session:
            policy=source.execute('SELECT * FROM processing_policies WHERE session_id=?',(sid,)).fetchone()
            if not policy or not policy['agent_allowed']:raise ValueError('Existing model processing grant required')
            if policy['source_kind'] in {'background_playback','test_unverified'}:raise ValueError('Not a personal-context sample')
            rows=source.execute("SELECT * FROM documents WHERE session_id=? AND status NOT IN ('superseded','no_text') AND length(trim(text))>0 ORDER BY rowid LIMIT 3",(sid,)).fetchall()
            if not rows:raise ValueError('Selected session has no usable records')
            out.create_session(sid);out.update_session(sid,status='completed')
            proc.agent.policy(sid,asr=False,agent=True,source_kind=policy['source_kind'],occurred_at=policy['occurred_at'],time_precision=policy['time_precision'])
            for row in rows:
                doc=dict(row);doc['evidence']=json.loads(doc['evidence'])
                proc.agent.commit_document(doc,{'title':doc['title'],'summary':doc['summary'],'claims':[], 'validation_notes':json.loads(doc['validation_notes'])})
                # Preserve the original evidence version as well as recording time.
                out.db.execute('UPDATE documents SET revision=? WHERE id=?',(doc['revision'],doc['id']));out.db.commit()
                records.append({'id':doc['id'],'version':doc['revision'],'source_kind':doc['source_kind'],'occurred_at':doc['occurred_at']})
        out.db.execute('UPDATE personal_agent_monitor SET last_scan=0');out.db.commit()
        if not proc.personal.schedule():raise ValueError('No eligible observation context')
        run=out.db.execute('SELECT run_key FROM personal_agent_runs ORDER BY rowid DESC LIMIT 1').fetchone()[0]
        proc.personal.run(run)
        row=dict(out.db.execute('SELECT * FROM personal_agent_runs WHERE run_key=?',(run,)).fetchone())
        refs=json.loads(row['response'])['refs'] if row['response'] else json.loads(row['observation'])['refs']
        result={'scope':'Existing real speech transcripts + actual configured model; isolated shadow, no new ASR or production advice',
            'records':records,'result':row['status'],'finished':bool(row['finished_at']),
            'current_references_valid':all(proc.personal.valid_ref(r) for r in refs),
            'manual_confirmations':out.db.execute('SELECT count(*) FROM feedback').fetchone()[0],
            'original_audio_uploaded':False,'private_outputs':'heartball.sqlite and agent-checkpoints.sqlite',
            'limits':['Not a transcription accuracy score','Quiet observation does not prove useful proactive advice','No inference of speaker identity']}
        (a.output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k not in {'records','private_outputs'}}),flush=True)
    finally:
        proc.close();out.db.close();source.close()


if __name__=='__main__':main()

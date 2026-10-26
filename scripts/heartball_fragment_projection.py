"""Current fragment allocations, with reversible retirement of old projections.

Raw text and immutable task receipts stay intact. No ASR or model calls.
"""
import json

from heartball_source_spans import source_spans
from heartball_store import now


def ensure_history(db):
    db.execute('CREATE TABLE IF NOT EXISTS agent_source_fragment_history(task_id TEXT NOT NULL,document_id TEXT NOT NULL,revision INTEGER NOT NULL,span_id INTEGER NOT NULL,reason TEXT NOT NULL,replaced_by_task TEXT NOT NULL,retired_at TEXT NOT NULL,PRIMARY KEY(task_id,document_id,revision,span_id))')


def retire(db, document_id, revision, replacement_task):
    ensure_history(db)
    db.execute('INSERT OR IGNORE INTO agent_source_fragment_history SELECT task_id,document_id,revision,span_id,reason,?,? FROM agent_source_fragments WHERE document_id=? AND revision=? AND task_id!=?',
               (replacement_task, now(), document_id, revision, replacement_task))
    db.execute('DELETE FROM agent_source_fragments WHERE document_id=? AND revision=? AND task_id!=?', (document_id, revision, replacement_task))


def repair_completed_reallocations(db):
    """Only a current, durably completed, fully allocated update can retire rows.

    A pending new generation, baseline receipt, missing/partial proposal or an
    invalidated document is not evidence of a replacement. Caller owns the tx.
    """
    ensure_history(db)
    if not db.execute("SELECT 1 FROM sqlite_master WHERE name='native_source_receipts'").fetchone():
        return 0
    rows=db.execute("SELECT DISTINCT d.id,d.revision,d.text,n.task_id,c.payload FROM documents d JOIN agent_source_fragments f ON f.document_id=d.id AND f.revision=d.revision LEFT JOIN workspace_generations g ON g.document_id=d.id JOIN native_source_receipts n ON n.document_id=d.id AND n.revision=d.revision AND n.generation=coalesce(g.generation,0) JOIN incremental_commits c ON c.task_id=n.task_id WHERE d.status NOT IN ('superseded','no_text') AND f.task_id!=n.task_id").fetchall()
    repaired=0
    for row in rows:
        proposal=json.loads(row['payload'])['proposal']
        refs=[r for issue in proposal['issues'] for r in issue['sources']]+[f['source'] for f in proposal['fragments']]
        counts={}
        for ref in refs:
            if ref['document_id']!=row['id'] or ref['revision']!=row['revision']:
                continue
            indices=range(len(source_spans(row['text']))) if ref.get('all_spans') and not ref['span_ids'] else ref['span_ids']
            for index in indices:
                counts[index]=counts.get(index,0)+1
        if counts!={i:1 for i in range(len(source_spans(row['text'])))}:
            continue
        retire(db,row['id'],row['revision'],row['task_id'])
        repaired+=1
    return repaired

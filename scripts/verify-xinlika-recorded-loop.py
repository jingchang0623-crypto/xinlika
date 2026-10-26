#!/usr/bin/env python3
"""Read-only audit of explicitly selected real captures; never connects, uploads or transcribes."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import sqlite3


def audit(root, run):
    selected = [run[k] for k in ('round1', 'round2', 'round3') if run.get(k)]
    db = sqlite3.connect((root.resolve() / 'heartball.sqlite').as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    db.execute('BEGIN')
    docs = [dict(r) for r in db.execute("SELECT * FROM documents WHERE status!='superseded'")]
    events = [dict(r) for r in db.execute("SELECT * FROM workspace_events WHERE status='active'")]
    topics = [dict(r) for r in db.execute("SELECT * FROM workspace_topics WHERE status='active'")]
    for topic in topics:
        topic['event_ids'] = [r[0] for r in db.execute('SELECT event_id FROM workspace_event_topics WHERE topic_id=?', (topic['id'],))]
    answers = [dict(r) for r in db.execute('SELECT * FROM memory_answers')]
    for answer in answers:
        answer['refs'] = json.loads(answer['refs'])
    state = {'documents': docs, 'events': events, 'topics': topics, 'answers': answers,
             'confirmedMemoryCount': db.execute("SELECT COUNT(*) FROM claims WHERE status='confirmed'").fetchone()[0]}
    captures = []
    for sid in selected:
        session = dict(db.execute('SELECT * FROM sessions WHERE id=?', (sid,)).fetchone())
        folder = Path(session['directory'])
        rows = [json.loads(line) for line in (folder / 'probe/events.ndjson').read_text().splitlines()]
        clocks = [r for r in rows if r.get('event') == 'clock_verification']
        clock = clocks[-1] if clocks else {}
        summary = json.loads((folder / 'probe/capture-summary.json').read_text())
        source_analysis = json.loads((folder / 'source-analysis/analysis.json').read_text())
        archive = json.loads(session['archive'] or '{}')
        card = Path(archive['cardFile']) if archive.get('cardFile') else None
        card_hash_matches = card is not None and card.is_file() and hashlib.sha256(card.read_bytes()).hexdigest() == archive.get('sha256')
        documents = [d for d in state['documents'] if d['session_id'] == sid]
        events = [e for e in state['events'] if e['session_id'] == sid]
        times = []
        for doc in documents:
            evidence = doc['evidence']
            if isinstance(evidence, str):
                evidence = json.loads(evidence)
            first = evidence[0]
            stream = db.execute('SELECT first_at FROM streams WHERE id=?', (first['stream_id'],)).fetchone()
            expected = dt.datetime.fromisoformat(stream[0].replace('Z', '+00:00')) + dt.timedelta(seconds=first['start_byte'] / 2000)
            actual = dt.datetime.fromisoformat(doc['occurred_at'].replace('Z', '+00:00')) if doc['occurred_at'] else None
            created = dt.datetime.fromisoformat(doc['created_at'])
            times.append({'documentId': doc['id'], 'kind': doc['kind'], 'hasText': bool(doc['text'].strip()),
                          'recordedAt': doc['occurred_at'], 'processedAt': doc['created_at'],
                          'matchesRecordingAnchor': actual is not None and abs((actual - expected).total_seconds()) < .001,
                          'processingDelaySeconds': (created - actual).total_seconds() if actual else None})
        hashes_ok = all(hashlib.sha256(Path(b['filename']).read_bytes()).hexdigest() == b['sha256']
                        for b in db.execute('SELECT * FROM batches WHERE session_id=?', (sid,)))
        captures.append({'sessionId': sid, 'status': session['status'], 'ownedFile': session['owned_file'],
                         'clock': clock, 'clockWriteCount': sum(r.get('event') == 'clock_sync_tx' for r in rows),
                         'clockVerified': clock.get('status') == 'new_filename_matches_host_start' and clock.get('filename') == session['owned_file'],
                         'droppedSubmissions': summary.get('droppedSubmissions'), 'writeFailure': summary.get('failure'),
                         'integrityProblems': source_analysis['problems'],
                         'unexpectedDisconnects': sum(r.get('event') == 'unexpected_disconnect' for r in rows),
                         'cardReferenceStatus': archive.get('status'), 'cardSha256': archive.get('sha256'),
                         'cardHashMatchesArchive': card_hash_matches,
                         'decodedSeconds': archive.get('decodedSeconds'), 'liveCoverageBytes': archive.get('liveCoverage'),
                         'missingLiveRanges': archive.get('missingLiveRanges'), 'batchHashesMatch': hashes_ok,
                         'documents': times, 'semanticEventCount': len(events)})
    focuses = []
    for row in db.execute('SELECT * FROM focuses WHERE id=?', (run['focus1'],)):
        focus = dict(row)
        ranges = json.loads(focus['ranges'])
        evidence = [dict(b) for b in db.execute('SELECT * FROM batches WHERE session_id=? ORDER BY sequence', (focus['session_id'],))
                    if any(b['stream_id'] == r['stream_id'] and b['end_byte'] > r['start_byte'] and b['start_byte'] < r['end_byte'] for r in ranges)]
        exact = bool(ranges) and all(any(r['stream_id'] == b['stream_id'] and r['start_byte'] <= b['start_byte'] and r['end_byte'] >= b['end_byte'] for r in ranges) for b in evidence)
        probe = Path(db.execute('SELECT directory FROM sessions WHERE id=?', (focus['session_id'],)).fetchone()[0]) / 'probe/events.ndjson'
        journal = [json.loads(line) for line in probe.read_text().splitlines()]
        filenames = {r['stream_id']: db.execute('SELECT filename FROM streams WHERE id=?', (r['stream_id'],)).fetchone()[0] for r in ranges}
        focused_frames = [row for row in journal if row.get('audioFile') and any(row['audioFile'] == filenames[r['stream_id']] and row['audioOffset'] < r['end_byte'] and row['audioOffset'] + row['audioBytes'] > r['start_byte'] for r in ranges)]
        # Journal wall time is rounded to seconds. Comparing it with subsecond
        # focus API timestamps can put the subsequent global save inside focus.
        # Use the monotonic arrival times of the exact selected audio instead.
        first_frame = min(row['uptime'] for row in focused_frames)
        last_frame = max(row['uptime'] for row in focused_frames)
        commands = [r['event'] for r in journal if r.get('event') in {'start_owned_tx', 'save_owned_tx', 'experimental_rearm_tx', 'button_response_tx'} and first_frame <= r['uptime'] <= last_frame]
        continues = all(db.execute('SELECT received FROM streams WHERE id=?', (r['stream_id'],)).fetchone()[0] > r['end_byte'] for r in ranges)
        focuses.append({'id': focus['id'], 'status': focus['status'], 'seconds': sum(r['end_byte']-r['start_byte'] for r in ranges)/2000,
                        'boundaryBasis': focus['boundary_basis'], 'exactBatchRanges': exact,
                        'hardwareControlsWithinFocusAudio': commands, 'controlTimingBasis': 'monotonic_arrival_of_exact_selected_audio_frames', 'audioReceivedPastFocusEnd': continues,
                        'independentDocumentCount': sum(d['kind'] == 'focus' and d['session_id'] == focus['session_id'] for d in state['documents']),
                        'sourceAudioHashes': [b['sha256'] for b in evidence]})
    topic_sessions = {}
    event_by_id = {e['id']: e for e in state['events']}
    for topic in state['topics']:
        topic_sessions[topic['id']] = sorted({event_by_id[e]['session_id'] for e in topic['event_ids'] if e in event_by_id})
    positive = [tid for tid, sessions in topic_sessions.items() if run.get('round3') and {run['round1'], run['round3']} <= set(sessions)]
    negative = [tid for tid, sessions in topic_sessions.items() if {run['round1'], run['round2']} <= set(sessions)]
    answers = [{'id': a['id'], 'status': a['status'], 'referenceIds': [r['id'] for r in a['refs']]}
               for a in state['answers'] if a['id'] in {run.get('question1'), run.get('question2')}]
    report = {'schema': 1, 'evidenceKind': 'physical_cb08_new_captures_not_synthetic_dialogue',
              'generatedAt': dt.datetime.now(dt.timezone.utc).isoformat(), 'captures': captures, 'focuses': focuses,
              'sourceFeedback': run.get('source_feedback'), 'positiveTopicIds': positive,
              'modelEvaluation': run.get('model_evaluation'),
              'negativeControlIncorrectTopicIds': negative, 'answers': answers,
              'ordinaryConfirmationCount': state['confirmedMemoryCount'],
              'unknown': ['No human word-level transcript or CER/WER ground truth',
                          'Recording timestamps are batch start estimates, not word or event onset alignment',
                          'Missing live card tail ranges are retained locally; no zero-loss claim',
                          'The app focus control is not a verified hardware short-press bookmark']}
    report['checks'] = {
        'allCapturesSavedAndCardVerified': all(c['status'] == 'completed' and c['cardReferenceStatus'] == 'card_verified' and c['cardHashMatchesArchive'] for c in captures),
        'automaticClockVerifiedOnEveryNewFile': all(c['clockVerified'] and c['clockWriteCount'] == 1 for c in captures),
        'noDroppedWritesOrUnexpectedDisconnects': all(c['droppedSubmissions'] == 0 and not c['writeFailure'] and not c['unexpectedDisconnects'] and not c['integrityProblems'] for c in captures),
        'recordingTimeNotProcessingTime': all(c['documents'] and all(d['matchesRecordingAnchor'] for d in c['documents']) for c in captures),
        'allBatchHashesMatch': all(c['batchHashesMatch'] for c in captures),
        'eventsAutomaticallyCreated': all(c['semanticEventCount'] > 0 for c in captures),
        'focusIndependentlyProcessed': bool(focuses) and all(f['exactBatchRanges'] and f['independentDocumentCount'] == 1 and not f['hardwareControlsWithinFocusAudio'] and f['audioReceivedPastFocusEnd'] for f in focuses),
        'differentMattersNotLinked': not negative,
        'sameMatterAcrossConversationsLinked': bool(positive) if run.get('source_feedback', {}).get('round1_round3_relationship') == 'same_matter' else None,
        'realAudioQuestionAnsweredWithSources': any(a['id'] == run.get('question2') and a['status'] == 'ready' and a['referenceIds'] for a in answers),
    }
    checks = report['checks'].values()
    report['status'] = ('passed_with_stated_limits' if all(checks) else
                        'partial_verified_positive_association_unmeasured' if all(v is not False for v in checks) else 'incomplete_or_failed_checks')
    db.close()
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--run', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = audit(args.root, json.loads(args.run.read_text()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'status': result['status'], 'checks': result['checks']}, ensure_ascii=False))
    raise SystemExit(0 if result['status'] == 'passed_with_stated_limits' else 1)

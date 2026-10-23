"""Complete recording-day projection. Presentation groups never rewrite semantic topics."""
import datetime as dt
import json
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from heartball_recording_time import recording_time
from heartball_content import has_semantic_content


def daily_workspace(db, day=None, time_zone='Asia/Shanghai'):
    try:
        zone = ZoneInfo(time_zone)
        date = dt.date.fromisoformat(day) if day else dt.datetime.now(zone).date()
    except (ValueError, TypeError, ZoneInfoNotFoundError) as error:
        raise ValueError('Invalid recording day or time zone') from error
    begin = dt.datetime.combine(date, dt.time(), zone)
    end = dt.datetime.combine(date + dt.timedelta(days=1), dt.time(), zone)
    # Read all source identities before filtering. Row insertion order and the
    # recent-workspace cap must never exclude today's delayed/reprocessed audio.
    documents = {}
    for row in db.execute('SELECT DISTINCT d.* FROM documents d JOIN workspace_event_sources s ON s.document_id=d.id JOIN workspace_events e ON e.id=s.event_id WHERE e.status=\'active\''):
        doc = dict(row)
        clock = recording_time(db, doc)
        raw = clock['occurred_at'] or clock['recorded_local_time']
        try:
            stamp = dt.datetime.fromisoformat(raw.replace('Z', '+00:00'))
            stamp = stamp.replace(tzinfo=zone) if stamp.tzinfo is None else stamp.astimezone(zone)
        except (AttributeError, ValueError):
            documents[doc['id']] = (clock, None, None)
            continue
        evidence = json.loads(doc['evidence'])
        duration = sum(max(0, e.get('end_byte', 0) - e.get('start_byte', 0)) for e in evidence) / 2000
        documents[doc['id']] = (clock, stamp, stamp + dt.timedelta(seconds=duration))
    sources = {}
    for row in db.execute('SELECT s.* FROM workspace_event_sources s JOIN workspace_events e ON e.id=s.event_id WHERE e.status=\'active\' ORDER BY s.rowid'):
        sources.setdefault(row['event_id'], []).append(dict(row))
    contexts = {}
    for row in db.execute("SELECT session_id,payload FROM events WHERE kind='recording_context' ORDER BY id"):
        contexts[row['session_id']] = json.loads(row['payload'])
    from heartball_activities import activity_projection
    activities=activity_projection(db)
    activity_intervals={}
    for eid,activity in activities.items():
        for source in sources.get(eid,[]):
            if source['document_id'] in documents:
                clock,start,stop=documents[source['document_id']]
                row=db.execute('SELECT session_id FROM documents WHERE id=?',(source['document_id'],)).fetchone()
                if start is not None:activity_intervals.setdefault(activity['id'],[]).append((row[0],start,stop,activity))
    grouped, unknown = {}, 0
    for row in db.execute("SELECT * FROM workspace_events WHERE status='active'"):
        event = dict(row)
        from heartball_timeline import visible
        if not visible(db,event):continue
        from heartball_timeline import project
        event=project(db,event)
        refs = sources.get(event['id'], [])
        if event['kind']!='focus' and refs and not has_semantic_content(' '.join(s['quote'] for s in refs)):continue
        known = [documents[s['document_id']] for s in refs if s['document_id'] in documents and documents[s['document_id']][1] is not None]
        if not known:
            unknown += 1
            continue
        intervals = [(max(start, begin), min(stop, end)) for _, start, stop in known if start < end and (stop > begin or start >= begin)]
        if not intervals:
            continue
        first = min(known, key=lambda x: x[1])
        event.update(first[0]); event['sources'] = refs
        event['_day_sort'] = min(a for a, _ in intervals).timestamp()
        topic = db.execute('SELECT topic_id FROM workspace_all_event_topics WHERE event_id=?', (event['id'],)).fetchone()
        event['topic_id'] = topic[0] if topic else None
        context = contexts.get(event['session_id'], {})
        activity=activities.get(event['id'])
        if not activity and event['kind']=='focus':
            matches={aid for aid,intervals in activity_intervals.items() if any(sid==event['session_id'] and any(start<=b and stop>=a for _,a,b in known) for sid,start,stop,_ in intervals)}
            if len(matches)==1:activity=activity_intervals[matches.pop()][0][3]
        meeting = context.get('medium') == 'live_video_meeting' and bool(context.get('group_id'))
        # Explicit shared meeting provenance is a container, never proof of one
        # semantic topic. Unknown sessions never combine merely because adjacent.
        from heartball_card_segments import logical_root
        logical_sid=logical_root(db,event['session_id']) if event['session_id'] else event['id']
        key = ('meeting:' + context['group_id'] if meeting else 'session:' + logical_sid) + ':' + event['source_kind']
        if activity:key='activity:'+activity['id']+':'+event['source_kind']
        group = grouped.setdefault(key, {'id': key + ':' + date.isoformat(), 'kind': 'meeting' if meeting or activity and activity['kind']=='meeting' else 'conversation', 'events': [], 'session_ids': set(), 'start': end, 'end': begin,'_activity':activity,'_intervals':[]})
        group['events'].append(event); group['session_ids'].add(event['session_id'])
        group['start'] = min(group['start'], min(a for a, _ in intervals))
        group['end'] = max(group['end'], max(b for _, b in intervals))
        group['_intervals']+=intervals
    groups = []
    for group in grouped.values():
        group['events'].sort(key=lambda e: (e['_day_sort'], e['id']))
        for event in group['events']: event.pop('_day_sort')
        group['start_local'] = group.pop('start').isoformat()
        group['end_local'] = group.pop('end').isoformat()
        group['session_count'] = len(group.pop('session_ids'))
        group['event_count'] = sum(e['kind'] != 'focus' for e in group['events'])
        group['focus_count'] = sum(e['kind'] == 'focus' for e in group['events'])
        activity=group.pop('_activity')
        group['title'] = activity['title'] if activity else ('视频会议' if group['kind'] == 'meeting' else ('对话记录' if len(group['events']) > 1 else group['events'][0]['title']))
        group['summary']=activity['summary'] if activity else ''
        group['activity_kind']=activity['kind'] if activity else 'unclassified'
        group['boundary_precision']='observed_source_envelope'
        covered=[]
        for a,b in sorted(group.pop('_intervals')):
            if covered and a<=covered[-1][1]:covered[-1]=(covered[-1][0],max(b,covered[-1][1]))
            else:covered.append((a,b))
        group['observed_audio_seconds']=sum((b-a).total_seconds() for a,b in covered)
        groups.append(group)
    groups.sort(key=lambda g: (g['start_local'], g['id']), reverse=True)
    return {'date': date.isoformat(), 'time_zone': time_zone, 'groups': groups, 'event_count': sum(g['event_count'] for g in groups), 'focus_count': sum(g['focus_count'] for g in groups), 'unknown_time_count': unknown}

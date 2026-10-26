"""Recording time evidence. Processing/import/file mtime are never recording clocks."""
import datetime as dt
import re


def device_local_start(filename):
    match=re.fullmatch(r'note(\d{8})-(\d{6})\.opus',filename)
    if not match:return None
    try:return dt.datetime.strptime(''.join(match.groups()),'%Y%m%d%H%M%S')
    except ValueError:return None


def recording_time(db,doc):
    occurred=doc.get('occurred_at')
    if occurred:
        policy=db.execute('SELECT time_precision FROM processing_policies WHERE session_id=?',(doc['session_id'],)).fetchone()
        return {'occurred_at':occurred,'recorded_local_time':None,'recording_time_basis':policy[0] if policy else 'provided_recording_time'}
    origin=db.execute('SELECT * FROM recording_origins WHERE session_id=?',(doc['session_id'],)).fetchone()
    if origin:
        import json
        evidence=doc.get('evidence',[])
        if isinstance(evidence,str):evidence=json.loads(evidence)
        byte_start=min((e.get('start_byte',0) for e in evidence),default=0)
        # CB08 mode verified by this project: 40B/20ms packets. Precision remains
        # a batch start, not forced word alignment for individual semantic events.
        local=dt.datetime.fromisoformat(origin['local_start'])+dt.timedelta(seconds=origin['offset_seconds']+byte_start/2000)
        return {'occurred_at':None,'recorded_local_time':local.isoformat(),'recording_time_basis':'device_clock_unverified'}
    return {'occurred_at':None,'recorded_local_time':None,'recording_time_basis':'unknown'}


def event_sort_key(event):
    if event.get('occurred_at'):
        try:return (2,dt.datetime.fromisoformat(event['occurred_at'].replace('Z','+00:00')).timestamp())
        except ValueError:pass
    if event.get('recorded_local_time'):
        # Uncalibrated device dates are kept separately below calibrated captures.
        return (1,event['recorded_local_time'])
    return (0,'')


def query_display_times(memory, time_zone=None):
    """Provide the Mac user's local display clock without changing source timestamps."""
    result = []
    for item in memory:
        item = dict(item)
        if item.get('occurred_at'):
            try:
                stamp = dt.datetime.fromisoformat(item['occurred_at'].replace('Z', '+00:00'))
                # A timezone-free value cannot be safely converted to a real instant.
                if stamp.tzinfo is not None:
                    item['recording_display_time'] = stamp.astimezone(time_zone).isoformat()
            except (ValueError, TypeError):
                pass
        result.append(item)
    return result

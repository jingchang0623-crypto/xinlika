"""Saved CB08 segment lineage; filenames are evidence, not proof of no lost samples."""
import datetime as dt
import hashlib
import uuid
from heartball_recording_time import device_local_start
from heartball_store import Conflict


def segment_id(root, filename):
    raw=bytearray(hashlib.sha256(('xinlika-card-segment:'+root+':'+filename).encode()).digest()[:16])
    raw[6]=(raw[6]&15)|80;raw[8]=(raw[8]&63)|128
    return str(uuid.UUID(bytes=bytes(raw)))


def continuation_clock(root_manifest, root_ended_at, previous_name, previous_bytes, filename, expected_bytes):
    first=device_local_start(root_manifest['card_file']);previous=device_local_start(previous_name);current=device_local_start(filename)
    if not all((first,previous,current)) or not 21600000<=previous_bytes<=21608000 or previous_bytes%40:
        raise Conflict('Previous physical file does not establish a three-hour split candidate')
    if not isinstance(expected_bytes,int) or expected_bytes<=0 or expected_bytes%40 or expected_bytes>172800000:
        raise ValueError('Invalid segment size')
    delta=(current-previous).total_seconds()-previous_bytes/2000
    if not -2<=delta<=3 or current<=previous or previous<first:
        raise Conflict('Physical file clock is not adjacent; preserve the unresolved interval')
    anchor=dt.datetime.fromisoformat(root_manifest['started_at'].replace('Z','+00:00'))
    end=dt.datetime.fromisoformat(root_ended_at.replace('Z','+00:00'))
    start=anchor+dt.timedelta(seconds=(current-first).total_seconds())
    # Clock granularity is seconds; never absorb another recording after end.
    if start>=end:raise Conflict('Segment starts outside the authorized recording interval')
    if start+dt.timedelta(seconds=expected_bytes/2000)>end+dt.timedelta(seconds=3):
        raise Conflict('Segment exceeds the authorized recording interval')
    return start.isoformat()


def logical_root(db,sid):
    if not db.execute("SELECT 1 FROM sqlite_master WHERE name='mobile_card_segments'").fetchone():return sid
    row=db.execute('SELECT root_id FROM mobile_card_segments WHERE session_id=?',(sid,)).fetchone()
    return row[0] if row else sid


def logical_members(db,sid):
    root=logical_root(db,sid)
    if not db.execute("SELECT 1 FROM sqlite_master WHERE name='mobile_card_segments'").fetchone():return [root]
    return [root]+[r[0] for r in db.execute('SELECT session_id FROM mobile_card_segments WHERE root_id=?',(root,))]

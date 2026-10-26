"""One personal workspace, independently revocable devices, durable snapshot revisions."""
import datetime as dt
import hashlib
import json
import secrets
import uuid
from heartball_store import Conflict, identifier, now
from heartball_day import daily_workspace


class SharedWorkspace:
    def __init__(self, store, agent):
        self.store, self.agent, self.db = store, agent, store.db
        with store.lock, store.transaction():
            self.db.executescript('''
              CREATE TABLE IF NOT EXISTS shared_devices(
                id TEXT PRIMARY KEY,name TEXT NOT NULL,token_hash TEXT NOT NULL UNIQUE,
                access TEXT NOT NULL,created_at TEXT NOT NULL,revoked_at TEXT);
              CREATE TABLE IF NOT EXISTS shared_revision(id INTEGER PRIMARY KEY,value INTEGER NOT NULL);
              INSERT OR IGNORE INTO shared_revision VALUES(1,0);
              CREATE TABLE IF NOT EXISTS shared_identity(id INTEGER PRIMARY KEY,value TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS shared_session_owners(session_id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS shared_write_audit(
                id INTEGER PRIMARY KEY,device_id TEXT NOT NULL,route TEXT NOT NULL,status INTEGER NOT NULL,at TEXT NOT NULL);
            ''')
            self.db.execute('INSERT OR IGNORE INTO shared_identity VALUES(1,?)',(str(uuid.uuid4()),))
            self.workspace_id=self.db.execute('SELECT value FROM shared_identity WHERE id=1').fetchone()[0]
            # Observe the existing ledger, including processing/correction invalidation.
            # There is one truth, not a second memory/event database to reconcile.
            tables = ('sessions','streams','batches','focuses','jobs','documents','claims','advice',
                      'memory_answers','feedback','event_interest_ratings','event_interest_predictions','processing_policies','workspace_events',
                      'workspace_event_sources','workspace_topics','workspace_event_topics','workspace_timeline_decisions',
                      'workspace_activities','workspace_activity_events','acoustic_observations',
                      'voice_enrollments','voice_samples','voice_profiles','voice_matches')
            for table in tables:
                if not self.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",(table,)).fetchone():
                    continue
                for action in ('INSERT','UPDATE','DELETE'):
                    self.db.execute(f'CREATE TRIGGER IF NOT EXISTS shared_{table}_{action.lower()} AFTER {action} ON {table} BEGIN UPDATE shared_revision SET value=value+1 WHERE id=1; END')

    def provision(self, name, access='editor'):
        if access not in ('editor','reader') or not isinstance(name,str) or not 0 < len(name.strip()) <= 100:
            raise ValueError('Device name/access invalid')
        device_id, token = str(uuid.uuid4()), secrets.token_urlsafe(48)
        with self.store.lock, self.store.transaction():
            self.db.execute('INSERT INTO shared_devices VALUES(?,?,?,?,?,NULL)',
                            (device_id,name.strip(),hashlib.sha256(token.encode()).hexdigest(),access,now()))
        return {'deviceId':device_id,'token':token,'name':name.strip(),'access':access}

    def authenticate(self, authorization):
        if not isinstance(authorization,str) or not authorization.startswith('Bearer ') or len(authorization)>1024:
            return None
        digest = hashlib.sha256(authorization[7:].encode()).hexdigest()
        with self.store.lock:
            row = self.db.execute('SELECT id,name,access FROM shared_devices WHERE token_hash=? AND revoked_at IS NULL',(digest,)).fetchone()
            return dict(row) if row else None

    def revoke(self, device_id):
        with self.store.lock, self.store.transaction():
            result=self.db.execute('UPDATE shared_devices SET revoked_at=? WHERE id=? AND revoked_at IS NULL',(now(),identifier(device_id)))
            return result.rowcount==1

    def devices(self):
        with self.store.lock:
            return [dict(r) for r in self.db.execute('SELECT id,name,access,created_at,revoked_at FROM shared_devices ORDER BY created_at')]

    def accept(self, mobile, body, device_id):
        sid=identifier(body['session']['id'])
        with self.store.lock, self.store.transaction():
            owner=self.db.execute('SELECT device_id FROM shared_session_owners WHERE session_id=?',(sid,)).fetchone()
            if owner and owner[0]!=device_id:
                raise Conflict('Capture belongs to another device; start a separate capture identity')
            if not owner and self.db.execute('SELECT 1 FROM sessions WHERE id=?',(sid,)).fetchone():
                raise Conflict('Existing capture cannot be adopted by this device')
            recovery=body['session'].get('recovery')
            if recovery:
                original=self.db.execute('SELECT device_id FROM shared_session_owners WHERE session_id=?',(identifier(recovery['root_id']),)).fetchone()
                if not original or original[0]!=device_id:raise Conflict('Recovery belongs to the original capture device')
            receipt=mobile.accept(body)
            self.db.execute('INSERT OR IGNORE INTO shared_session_owners VALUES(?,?)',(sid,device_id))
            return receipt

    def snapshot(self, cursor=None, view=None, day=None, time_zone='Asia/Shanghai'):
        # Validate view/date before a no-change response. A midnight roll-over
        # must refresh even if there were no writes to the ledger overnight.
        from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
        try:
            zone=ZoneInfo(time_zone)
            date=dt.date.fromisoformat(day) if day else dt.datetime.now(zone).date()
        except (ValueError,TypeError,ZoneInfoNotFoundError) as error:
            raise ValueError('Invalid recording day or time zone') from error
        view_key=hashlib.sha256(json.dumps([self.workspace_id,date.isoformat(),time_zone]).encode()).hexdigest()[:24]
        if cursor is not None:
            if not isinstance(cursor,str) or not cursor.isdecimal() or len(cursor)>19:
                raise ValueError('Invalid sync cursor')
            cursor=int(cursor)
        with self.store.lock:
            revision=self.db.execute('SELECT value FROM shared_revision WHERE id=1').fetchone()[0]
            if cursor is not None and cursor>revision:
                raise Conflict('Sync cursor is ahead of this workspace; reset local sync state')
            unchanged=cursor==revision and view==view_key
            return {'workspace_id':self.workspace_id,'revision':revision,'view_key':view_key,'changed':not unchanged,
                    'state':None if unchanged else self.agent.state(day=date.isoformat(),time_zone=time_zone)}

    def audit(self, device_id, route, status):
        with self.store.lock, self.store.transaction():
            self.db.execute('INSERT INTO shared_write_audit(device_id,route,status,at) VALUES(?,?,?,?)',
                            (device_id,route,status,now()))

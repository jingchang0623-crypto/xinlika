from pathlib import Path
import hashlib
import sqlite3
import tempfile
import unittest
import uuid
from heartball_store import Store
from heartball_backup import create,verify,restore

class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.base=Path(self.temp.name);self.store=Store(self.base/'live')
        sid=str(uuid.uuid4());self.store.create_session(sid)
        folder=self.base/'live'/'evidence';folder.mkdir();self.audio=folder/'sealed.cb08';self.audio.write_bytes(b'raw-evidence'*40)
        self.hash=hashlib.sha256(self.audio.read_bytes()).hexdigest()
        self.store.db.execute('INSERT INTO batches VALUES(?,?,?,?,?,?,?,?,?)',(str(uuid.uuid4()),sid,0,'test',0,self.audio.stat().st_size,self.hash,str(self.audio),'test'))
        self.store.db.commit()
    def tearDown(self):self.store.db.close();self.temp.cleanup()
    def test_wal_snapshot_incremental_objects_and_restore_to_new_root(self):
        b=self.base/'backups';first=create(self.store.root,b);second=create(self.store.root,b)
        self.assertEqual(len(list((b/'objects').iterdir())),1)
        dest=self.base/'restored';restore(b,second['id'],dest)
        db=sqlite3.connect(dest/'heartball.sqlite');path=Path(db.execute('SELECT filename FROM batches').fetchone()[0]);db.close()
        self.assertTrue(path.is_relative_to(dest.resolve()));self.assertEqual(path.read_bytes(),self.audio.read_bytes())
        self.assertFalse((dest/'model-api-key').exists())
        with self.assertRaises(FileExistsError):restore(b,first['id'],dest)
    def test_tampered_object_is_rejected_before_restore_destination_is_created(self):
        b=self.base/'backups';m=create(self.store.root,b);(b/'objects'/self.hash).write_bytes(b'corrupt')
        dest=self.base/'restore'
        with self.assertRaises(ValueError):restore(b,m['id'],dest)
        self.assertFalse(dest.exists())
    def test_missing_source_never_produces_a_completed_snapshot(self):
        self.audio.unlink();b=self.base/'backups'
        with self.assertRaises(FileNotFoundError):create(self.store.root,b)
        self.assertFalse(list((b/'snapshots').glob('*/manifest.json')))

if __name__=='__main__':unittest.main()

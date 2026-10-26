"""Consistent SQLite snapshots plus deduplicated, hash-verified sealed audio.

Only the product ledger and its referenced immutable evidence are authoritative.
Model/checkpoint caches and provider credentials are deliberately excluded.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile
import uuid


def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()


def inside(root, relative):
    path=(root/relative).resolve()
    if not path.is_relative_to(root.resolve()) or path==root.resolve():raise ValueError('Evidence path escapes root')
    return path


def sync_write(path, data):
    with path.open('xb') as f:
        os.chmod(path,0o600);f.write(data);f.flush();os.fsync(f.fileno())


def create(root, backup_root):
    root, backup_root=root.resolve(),backup_root.resolve()
    backup_root.mkdir(parents=True,exist_ok=True,mode=0o700);backup_root.chmod(0o700)
    if shutil.disk_usage(backup_root).free < 512*1024*1024:raise OSError('Insufficient backup reserve')
    objects=backup_root/'objects';objects.mkdir(exist_ok=True,mode=0o700)
    snapshots=backup_root/'snapshots';snapshots.mkdir(exist_ok=True,mode=0o700)
    sid=dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8]
    folder=snapshots/sid;folder.mkdir(mode=0o700)
    database=folder/'heartball.sqlite'
    source=sqlite3.connect((root/'heartball.sqlite').as_uri()+'?mode=ro',uri=True,timeout=15)
    target=sqlite3.connect(database)
    try:source.backup(target)
    finally:source.close();target.close()
    database.chmod(0o600)
    db=sqlite3.connect(database);db.row_factory=sqlite3.Row
    try:
        if db.execute('PRAGMA quick_check').fetchone()[0]!='ok':raise ValueError('Snapshot integrity failed')
        paths={r['filename']:r['sha256'] for r in db.execute('SELECT filename,sha256 FROM batches')}
        for row in db.execute("SELECT archive FROM sessions WHERE archive IS NOT NULL"):
            a=json.loads(row[0])
            if a.get('cardFile') and a.get('sha256'):paths[a['cardFile']]=a['sha256']
    finally:db.close()
    files=[]
    for filename,expected in paths.items():
        if not re.fullmatch('[a-f0-9]{64}',expected):raise ValueError('Invalid evidence hash')
        source=Path(filename).resolve()
        if not source.is_relative_to(root):raise ValueError('Evidence outside workspace')
        obj=objects/expected
        if not obj.exists():
            if shutil.disk_usage(backup_root).free < source.stat().st_size+20*1024*1024:raise OSError('Insufficient backup space')
            with tempfile.NamedTemporaryFile(dir=objects,delete=False) as out:
                tmp=Path(out.name)
                try:
                    with source.open('rb') as audio:shutil.copyfileobj(audio,out)
                    out.flush();os.fsync(out.fileno());out.close()
                    if digest(tmp)!=expected:raise ValueError('Source evidence hash mismatch')
                    tmp.chmod(0o600);os.replace(tmp,obj)
                finally:tmp.unlink(missing_ok=True)
        if digest(obj)!=expected:raise ValueError('Backup object hash mismatch')
        files.append({'path':str(source.relative_to(root)),'sha256':expected,'bytes':obj.stat().st_size})
    manifest={'version':1,'id':sid,'created_at':dt.datetime.now(dt.timezone.utc).isoformat(),'origin_root':str(root),
        'database_sha256':digest(database),'files':files,'checkpoint_cache_included':False}
    sync_write(folder/'manifest.json',json.dumps(manifest,ensure_ascii=False,sort_keys=True).encode())
    fd=os.open(folder,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)
    verify(backup_root,sid)
    return manifest


def verify(backup_root,sid):
    if not re.fullmatch(r'[A-Za-z0-9T\-Z]+',sid):raise ValueError('Invalid snapshot ID')
    folder=inside(backup_root,'snapshots/'+sid)
    manifest=json.loads((folder/'manifest.json').read_text())
    if manifest.get('version')!=1 or manifest['id']!=sid or digest(folder/'heartball.sqlite')!=manifest['database_sha256']:
        raise ValueError('Snapshot identity/hash mismatch')
    db=sqlite3.connect((folder/'heartball.sqlite').resolve().as_uri()+'?mode=ro',uri=True)
    try:
        if db.execute('PRAGMA quick_check').fetchone()[0]!='ok':raise ValueError('Snapshot integrity failed')
    finally:db.close()
    for item in manifest['files']:
        if not re.fullmatch('[a-f0-9]{64}',item['sha256']):raise ValueError('Invalid object hash')
        inside(Path('/restore-fixture'),item['path'])
        obj=inside(backup_root,'objects/'+item['sha256'])
        if obj.stat().st_size!=item['bytes'] or digest(obj)!=item['sha256']:raise ValueError('Backup evidence incomplete or changed')
    return manifest


def restore(backup_root,sid,destination):
    manifest=verify(backup_root,sid)
    destination=destination.resolve();destination.mkdir(parents=True,exist_ok=False,mode=0o700)
    shutil.copy2(backup_root/'snapshots'/sid/'heartball.sqlite',destination/'heartball.sqlite')
    for item in manifest['files']:
        path=inside(destination,item['path']);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        shutil.copy2(backup_root/'objects'/item['sha256'],path)
    db=sqlite3.connect(destination/'heartball.sqlite')
    try:
        old=manifest['origin_root'].rstrip('/')+'/'
        with db:
            for table,column in [('sessions','directory'),('batches','filename'),('streams','filename')]:
                for rowid,path in db.execute(f'SELECT rowid,{column} FROM {table}').fetchall():
                    if path.startswith('/'):
                        path=str(Path(path).resolve())
                    if path.startswith(old):db.execute(f'UPDATE {table} SET {column}=? WHERE rowid=?',(str(inside(destination,path[len(old):])),rowid))
            for rowid,archive in db.execute('SELECT rowid,archive FROM sessions WHERE archive IS NOT NULL').fetchall():
                a=json.loads(archive)
                if isinstance(a.get('cardFile'),str) and a['cardFile'].startswith(old):
                    a['cardFile']=str(inside(destination,a['cardFile'][len(old):]));db.execute('UPDATE sessions SET archive=? WHERE rowid=?',(json.dumps(a),rowid))
    finally:db.close()
    return manifest


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['create','verify','restore']);p.add_argument('--backup-root',type=Path,required=True);p.add_argument('--root',type=Path);p.add_argument('--snapshot');p.add_argument('--destination',type=Path);a=p.parse_args()
    if a.action=='create':
        if not a.root:p.error('--root required')
        m=create(a.root,a.backup_root)
    else:
        if not a.snapshot:p.error('--snapshot required')
        if a.action=='restore':
            if not a.destination:p.error('--destination required')
            m=restore(a.backup_root,a.snapshot,a.destination)
        else:m=verify(a.backup_root,a.snapshot)
    print(json.dumps({'snapshot':m['id'],'files':len(m['files']),'verified':True,'checkpoint_cache_included':False}))

if __name__=='__main__':main()

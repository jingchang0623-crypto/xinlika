"""Supervise the reused local ASR bridge and shared worker in one private namespace."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request

stop=threading.Event()
for signum in (signal.SIGTERM,signal.SIGINT):signal.signal(signum,lambda *_:stop.set())
children=[]
processing=Path('/config/processing.json')
host=socket.gethostbyname(socket.gethostname())
command=[sys.executable,'/app/scripts/heartball-shared-service.py','serve','--root','/data/workspace','--host',host,'--port','18778']
handoff_release=os.environ.get('XINLIKA_HANDOFF_RELEASE')
if handoff_release:
    command=[sys.executable,'/app/scripts/heartball_shared_handoff.py','--root','/data/workspace','--host',host,'--port','18778','--release',handoff_release]
    if os.environ.get('XINLIKA_PROCESSING_BOUNDARY_RELEASE'):
        command+=['--boundary-release',os.environ['XINLIKA_PROCESSING_BOUNDARY_RELEASE']]

def backup_loop():
    # Read-only SQLite online snapshots and sealed-object copies. This loop has
    # no hardware access, model calls, retention deletes, or credential copies.
    folder=Path('/data/backups');folder.mkdir(exist_ok=True,mode=0o700)
    status_path=folder/'status.json'
    while not stop.wait(30):
        started=time.time()
        child=subprocess.Popen([sys.executable,'/app/scripts/heartball_backup.py','create',
            '--root','/data/workspace','--backup-root',str(folder)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        while child.poll() is None and not stop.wait(.5):
            if time.time()-started>900:child.terminate();break
        if stop.is_set():child.terminate()
        try:stdout,_=child.communicate(timeout=15)
        except subprocess.TimeoutExpired:child.kill();stdout,_=child.communicate()
        if stop.is_set():return
        try:previous=json.loads(status_path.read_text()) if status_path.exists() else {}
        except (ValueError,OSError):previous={}
        if child.returncode==0:
            try:previous.update(last_success=time.time(),snapshot=json.loads(stdout)['snapshot'],error=None)
            except (ValueError,KeyError):previous['error']='invalid_backup_result'
        else:previous['error']='backup_failed'
        previous['last_attempt']=started
        temporary=folder/'status.tmp'
        with temporary.open('w') as f:
            os.chmod(temporary,0o600);json.dump(previous,f);f.flush();os.fsync(f.fileno())
        os.replace(temporary,status_path)
        if stop.wait(6*3600-30):return

try:
    if processing.exists():
        config=json.loads(processing.read_text())
        if config.get('voxgate_config'):
            asr_path=Path(config['voxgate_config']);asr=json.loads(asr_path.read_text())
            if asr['server']['host']!='127.0.0.1':raise ValueError('ASR must remain internal loopback')
            children.append(subprocess.Popen(['voxgate','--config',str(asr_path),'serve','--chunk-duration','15s']))
            deadline=time.monotonic()+20
            while True:
                try:
                    req=urllib.request.Request(f"http://127.0.0.1:{asr['server']['port']}/health",headers={'Authorization':'Bearer '+asr['server']['auth_token']})
                    with urllib.request.urlopen(req,timeout=2) as response:
                        if response.status==200:break
                except OSError:
                    if time.monotonic()>deadline or children[0].poll() is not None:raise RuntimeError('ASR startup failed')
                    if stop.wait(.2):raise InterruptedError('Stopping')
        command+=['--processing-config',str(processing)]
    worker=subprocess.Popen(command);children.append(worker)
    backup_thread=threading.Thread(target=backup_loop,daemon=True,name='xinlika-backups');backup_thread.start()
    while not stop.wait(.2):
        if any(child.poll() is not None for child in children):
            raise RuntimeError('A service exited; restarting container is required')
finally:
    stop.set()
    if 'backup_thread' in globals():backup_thread.join(timeout=20)
    # Finish/persist the current bounded ASR/model call before stopping its bridge.
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
            try:child.wait(timeout=360)
            except subprocess.TimeoutExpired:child.kill();child.wait(timeout=10)

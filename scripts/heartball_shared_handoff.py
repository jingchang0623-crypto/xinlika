"""Rolling shared-service handoff: keep ingest online, fence processing with flock.

The existing service owns service.lock until all of its workers have drained.
This replacement may serve ingest/sync meanwhile, but must not run any worker
until it acquires that same lock. No capture commands or historical ASR resets.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import ipaddress
import json
from pathlib import Path
import signal
import threading
import time

from heartball_store import now
from heartball_native_processing import NativeProcessor
from heartball_processing import configured_asr


class ForwardOnlyBoundary:
    """Durable input boundary, including old audio whose ASR finishes later.

    Old text remains available as retrieval evidence. Corrections are new source
    versions and remain eligible; neither ASR jobs nor transcript rows are edited.
    """
    def __init__(self, agent, release):
        self.agent, self.store, self.db, self.release = agent, agent.store, agent.db, release
        with self.store.lock, self.store.transaction():
            self.db.execute('CREATE TABLE IF NOT EXISTS processing_releases(release TEXT PRIMARY KEY,activated_at TEXT NOT NULL,baseline_documents INTEGER NOT NULL,baseline_inputs INTEGER NOT NULL)')
            self.db.execute('CREATE TABLE IF NOT EXISTS processing_release_inputs(release TEXT NOT NULL,input_key TEXT NOT NULL,PRIMARY KEY(release,input_key))')
            if not self.db.execute('SELECT 1 FROM processing_releases WHERE release=?', (release,)).fetchone():
                # Atomically include sources already materialized AND pending old
                # sealed batches/focuses. Do this once, never again on restart.
                self.db.execute("INSERT OR IGNORE INTO processing_release_inputs SELECT ?,'ambient_analysis:'||id FROM batches", (release,))
                self.db.execute("INSERT OR IGNORE INTO processing_release_inputs SELECT ?,'focus_analysis:'||id FROM focuses", (release,))
                self.db.execute("INSERT OR IGNORE INTO native_source_receipts SELECT d.id,d.revision,coalesce(g.generation,0),? FROM documents d LEFT JOIN workspace_generations g ON g.document_id=d.id", ('release_baseline:'+release,))
                self.db.execute('INSERT INTO processing_releases VALUES(?,?,(SELECT count(*) FROM documents),(SELECT count(*) FROM processing_release_inputs WHERE release=?))', (release, now(), release))

    def exclude_late_baseline(self):
        with self.store.lock, self.store.transaction():
            self.db.execute("INSERT OR IGNORE INTO native_source_receipts SELECT d.id,d.revision,coalesce(g.generation,0),? FROM documents d JOIN processing_release_inputs i ON i.input_key=d.input_key AND i.release=? LEFT JOIN workspace_generations g ON g.document_id=d.id WHERE coalesce(g.generation,0)=0 AND d.revision=1", ('release_baseline:'+self.release,self.release))


class ForwardOnlyProcessor(NativeProcessor):
    def __init__(self, store, configuration, asr, release):
        super().__init__(store, configuration, asr)
        self.boundary = ForwardOnlyBoundary(self.agent, release)
        schedule=self.native.schedule
        def guarded_schedule():
            # Only scheduling is locked, never the paid model call. A late old
            # ASR document cannot slip between exclusion and source selection.
            with store.lock:
                self.boundary.exclude_late_baseline()
                return schedule()
        self.native.schedule=guarded_schedule


class ProcessingLease:
    def __init__(self, root):
        self.file=(Path(root)/'service.lock').open('a+')
        self.owned=False

    def acquire(self):
        if self.owned:return True
        try:fcntl.flock(self.file.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return False
        self.owned=True
        return True

    def close(self):
        self.file.close()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--host',required=True)
    p.add_argument('--port',type=int,default=18778)
    p.add_argument('--processing-config',type=Path,required=True)
    p.add_argument('--release',required=True)
    p.add_argument('--boundary-release',help='Reuse the existing forward-only input boundary for a host-only repair')
    args=p.parse_args()
    address=ipaddress.ip_address(args.host)
    if address.is_unspecified or not address.is_private:p.error('Explicit private interface required')
    spec=importlib.util.spec_from_file_location('shared_handoff_http',Path(__file__).with_name('heartball-shared-service.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    root=module.safe_root(args.root);root.mkdir(parents=True,exist_ok=True,mode=0o700)
    # A separate HTTP lease permits exactly one standby ingress, while the
    # original process still exclusively owns the processing lease.
    ingress=(root/('handoff-ingress-'+hashlib.sha256(args.release.encode()).hexdigest()[:16]+'.lock')).open('a+')
    fcntl.flock(ingress.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
    server=module.make_server(root,args.host,args.port)
    original_handler=server.RequestHandlerClass
    state={'release':args.release,'processing':'waiting_for_previous_workers'}
    class Handler(original_handler):
        def do_GET(self):
            if self.path=='/v1/mobile/capabilities':
                if not self.authorized():return self.reply(401,{'error':'Unauthorized'})
                return self.reply(200,{'protocolVersion':1,'maxBatchSeconds':300,
                    'asrConfigured':bool(config.get('asr') or config.get('voxgate_config')),'agentConfigured':True,
                    'hardwareControl':False})
            if self.path=='/v1/shared/processing':
                if not self.authorized():return self.reply(401,{'error':'Unauthorized'})
                return self.reply(200,dict(state))
            return super().do_GET()
    server.RequestHandlerClass=Handler
    stop=threading.Event();lease=ProcessingLease(root)
    config=json.loads(args.processing_config.read_text())
    # Validate the approved engine/profile before serving or waiting for a cutover.
    from heartball_processing_profiles import apply_processing_profile
    apply_processing_profile(config['agent_runtime'])
    def activate():
        try:
            while not stop.is_set():
                if not lease.acquire():stop.wait(.25);continue
                with server.engine.store.lock:
                    processor=ForwardOnlyProcessor(server.engine.store,config['agent_runtime'],
                        configured_asr(config),args.boundary_release or args.release)
                    server.processor=processor
                    server.mobile.agent=processor.agent
                    server.shared.agent=processor.agent
                    server.acoustic_queue.agent=processor.agent
                processor.start()
                state.update(processing='active',profile=config['agent_runtime']['processing_profile'],activatedAt=now())
                print(json.dumps(state),flush=True)
                return
        except Exception as error:
            state.update(processing='activation_failed',error=type(error).__name__)
            lease.close() # Permit the previous worker to resume during rollback.
            import traceback
            traceback.print_exc()
            print(json.dumps(state),flush=True)
            # Keep accepting immutable uploads for operator rollback/recovery.
    thread=threading.Thread(target=activate,daemon=True);thread.start()
    def shutdown(*_):
        stop.set();threading.Thread(target=server.shutdown,daemon=True).start()
    signal.signal(signal.SIGTERM,shutdown);signal.signal(signal.SIGINT,shutdown)
    print(json.dumps(state),flush=True)
    try:server.serve_forever()
    finally:
        stop.set();thread.join(timeout=360)
        if server.processor:server.processor.close()
        server.server_close();server.engine.store.db.close();lease.close();ingress.close()


if __name__=='__main__':main()

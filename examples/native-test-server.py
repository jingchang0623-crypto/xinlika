#!/usr/bin/env python3
"""Loopback-only native integration fixture; synthetic model, no ASR or hardware."""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from heartball_processing import Processor
from test_heartball_organization import SemanticModel

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, required=True)
parser.add_argument('--port', type=int, default=28788)
args = parser.parse_args()
if args.root.exists() and any(args.root.iterdir()): parser.error('Use a new empty fixture directory')
spec = importlib.util.spec_from_file_location('native_fixture_service', Path(__file__).resolve().parents[1] / 'scripts/heartball-shared-service.py')
service = importlib.util.module_from_spec(spec); spec.loader.exec_module(service)
server = service.make_server(args.root, '127.0.0.1', args.port)
processor = Processor(server.engine.store, SemanticModel())
server.processor = processor; server.mobile.agent = processor.agent; server.shared.agent = processor.agent
server.shared.provision('native-local-fixture')
# A clearly fake credential accepted ONLY by this separate loopback fixture.
digest = hashlib.sha256(b'native-test-local-only').hexdigest()
server.engine.store.db.execute('UPDATE shared_devices SET token_hash=?', (digest,))
server.engine.store.db.commit()
processor.start()
print(f'SYNTHETIC native test server on 127.0.0.1:{args.port}; no ASR/model network/hardware.', flush=True)
try: server.serve_forever()
except KeyboardInterrupt: pass
finally: processor.close(); server.server_close(); server.engine.store.db.close()

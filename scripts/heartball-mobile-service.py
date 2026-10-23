#!/usr/bin/env python3
"""Independent phone processing service. Defaults to loopback; never controls a card."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import secrets
from urllib.parse import urlparse,parse_qs
from types import SimpleNamespace

from heartball_store import Store, Conflict
from heartball_mobile import MobileIngest
from heartball_agent_store import AgentStore

spec = importlib.util.spec_from_file_location('heartball_http', Path(__file__).with_name('heartball_http.py'))
http = importlib.util.module_from_spec(spec)
spec.loader.exec_module(http)


class Handler(http.Handler):
    def do_GET(self):
        route=urlparse(self.path)
        if route.path=='/v1/mobile/segments':
            if not self.authorized():return self.reply(401,{'error':'Unauthorized'})
            try:return self.reply(200,self.server.mobile.segments(parse_qs(route.query)['session_id'][0]))
            except (ValueError,KeyError):return self.reply(400,{'error':'Invalid recording identity'})
        if self.path == '/v1/mobile/capabilities':
            if not self.authorized():
                return self.reply(401, {'error': 'Unauthorized'})
            processor = self.server.processor
            return self.reply(200, {'protocolVersion': 1, 'maxBatchSeconds': 300,
                'asrConfigured': bool(processor and processor.asr), 'agentConfigured': bool(processor and processor.model),
                'hardwareControl': False})
        return super().do_GET()

    def do_POST(self):
        if not self.authorized():
            return self.reply(401, {'error': 'Unauthorized'})
        if self.path.startswith('/v1/capture/') or self.path.startswith('/v1/focus/'):
            return self.reply(405, {'error': 'This service cannot control a recorder'})
        if self.path != '/v1/mobile/ingest':
            return super().do_POST()
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 900000 or self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
                raise ValueError('Invalid upload')
            self.reply(200, self.server.mobile.accept(json.loads(self.rfile.read(length))))
        except Conflict as error:
            self.reply(409, {'error': str(error)})
        except (ValueError, KeyError, TypeError):
            self.reply(400, {'error': 'Invalid phone evidence'})
        except Exception:
            self.reply(500, {'error': 'Evidence retained; retry this immutable message'})


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--host', default='127.0.0.1', help='Explicit private interface for LAN use; never bind all interfaces')
    p.add_argument('--port', type=int, default=18776)
    p.add_argument('--processing-config', type=Path)
    args = p.parse_args()
    if args.host in {'0.0.0.0', '::'}:
        p.error('Choose a specific private interface or loopback')
    import ipaddress
    if not ipaddress.ip_address(args.host).is_private:
        p.error('Public serving requires a separately configured TLS deployment')
    # Guard the active Mac storage even when the caller supplies a symlink.
    project = Path(__file__).resolve().parents[1]
    if args.root.resolve() == (project / '.build/heartball-lab').resolve():
        p.error('Use isolated mobile storage; Mac capture storage is forbidden')
    args.root.mkdir(parents=True, exist_ok=True, mode=0o700)
    lease = (args.root / 'service.lock').open('a+')
    fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    store = Store(args.root)
    processor = None
    if args.processing_config:
        from heartball_processing import Processor
        processor = Processor.configured(store, args.processing_config)
    agent = processor.agent if processor else AgentStore(store)
    runtime = args.root / 'runtime.json'
    token = json.loads(runtime.read_text())['token'] if runtime.exists() else secrets.token_urlsafe(32)
    server = http.Server((args.host, args.port), Handler)
    server.token, server.processor = token, processor
    server.engine = SimpleNamespace(store=store, max_seconds=86400)
    server.mobile = MobileIngest(store, agent)
    runtime.write_text(json.dumps({'baseURL': f'http://{args.host}:{args.port}', 'token': token, 'pid': os.getpid()}))
    runtime.chmod(0o600)
    if processor:
        processor.start()
    print(f'Phone service listening on {args.host}:{args.port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if processor:
            processor.close()
        server.server_close()


if __name__ == '__main__':
    main()

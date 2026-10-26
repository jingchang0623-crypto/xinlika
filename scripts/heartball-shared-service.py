#!/usr/bin/env python3
"""Deployable single-user shared workspace. No Bluetooth or capture Engine."""
import argparse
import fcntl
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import signal
import ssl
import threading
from types import SimpleNamespace
from urllib.parse import parse_qs,urlparse

from heartball_store import Store,Conflict
from heartball_agent_store import AgentStore
from heartball_mobile import MobileIngest
from heartball_shared import SharedWorkspace

spec=importlib.util.spec_from_file_location('shared_mobile_http',Path(__file__).with_name('heartball-mobile-service.py'))
mobile_http=importlib.util.module_from_spec(spec);spec.loader.exec_module(mobile_http)


class Handler(mobile_http.Handler):
    def authorized(self):
        self.device=self.server.shared.authenticate(self.headers.get('Authorization'))
        return self.device is not None

    def reply(self,code,body):
        device=getattr(self,'device',None)
        if self.command=='POST' and device:
            self.server.shared.audit(device['id'],urlparse(self.path).path,code)
        return super().reply(code,body)

    def do_GET(self):
        route=urlparse(self.path)
        if route.path=='/health':
            return self.reply(200,{'status':'ok','service':'xinlika-shared','hardwareControl':False})
        if not self.authorized():return self.reply(401,{'error':'Unauthorized'})
        if route.path=='/v1/shared/capabilities':
            return self.reply(200,{'protocolVersion':1,'workspaceMode':'single_user','sync':'revision_snapshot',
                                   'workspaceId':self.server.shared.workspace_id,'deviceId':self.device['id'],'access':self.device['access'],'hardwareControl':False})
        if route.path=='/v1/shared/sync':
            query=parse_qs(route.query)
            try:
                snapshot=self.server.shared.snapshot(query.get('cursor',[None])[0],query.get('view',[None])[0],
                                                      query.get('day',[None])[0],query.get('time_zone',['Asia/Shanghai'])[0])
                return self.reply(200,snapshot)
            except Conflict as error:return self.reply(409,{'error':str(error)})
            except ValueError as error:return self.reply(400,{'error':str(error)})
        if route.path=='/v1/voice':
            return self.reply(200,self.server.mobile.agent.voice.status())
        if route.path=='/v1/acoustics':
            return self.reply(200,self.server.acoustic_queue.status())
        if route.path in {'/v1/context/search','/v1/context/source'}:
            from heartball_agent_runtime import ContextReader
            query=parse_qs(route.query)
            try:
                with self.server.engine.store.lock:
                    reader=ContextReader(self.server.engine.store.db)
                    if route.path.endswith('/search'):
                        result=reader.search(query.get('q',[''])[0],int(query.get('limit',['8'])[0]))
                    else:
                        result=reader.source(query.get('id',[''])[0],int(query.get('offset',['0'])[0]),int(query.get('limit',['8000'])[0]))
                return self.reply(200,result)
            except PermissionError:return self.reply(403,{'error':'Source access revoked'})
            except Conflict:return self.reply(409,{'error':'Source corrected; refresh context'})
            except (ValueError,TypeError):return self.reply(400,{'error':'Invalid context request'})
        return super().do_GET()

    def do_POST(self):
        if not self.authorized():return self.reply(401,{'error':'Unauthorized'})
        if self.device['access']!='editor':return self.reply(403,{'error':'This device has read-only access'})
        if self.path=='/v1/context/import':
            try:
                import base64,hashlib
                from heartball_external_import import ExternalImporter,load_messages
                length=int(self.headers.get('Content-Length','0'))
                if not 0<length<=27_000_000 or self.headers.get('Content-Type','').split(';')[0]!='application/json':raise ValueError('Invalid import')
                body=json.loads(self.rfile.read(length));suffix=Path(body['filename']).suffix.lower()
                if suffix not in {'.json','.txt','.html','.htm'} or type(body.get('analyze',False)) is not bool:raise ValueError('Invalid export format')
                raw=base64.b64decode(body['content_base64'],validate=True)
                if len(raw)>20_000_000:raise ValueError('Export exceeds 20 MB')
                folder=self.server.engine.store.root/'imports'/'originals';folder.mkdir(parents=True,exist_ok=True,mode=0o700)
                original=folder/(hashlib.sha256(raw).hexdigest()+suffix)
                if not original.exists():
                    with original.open('xb') as output:output.write(raw)
                    original.chmod(0o600)
                parsed=load_messages(original,conversation_id=body.get('conversation_id'),time_zone=body.get('time_zone','Asia/Shanghai'))
                result=ExternalImporter(self.server.mobile.agent).ingest(parsed,account_id=body['account_id'],analyze=body.get('analyze',False))
                return self.reply(200,result)
            except Conflict:return self.reply(409,{'error':'Message identity conflicts with a preserved original'})
            except (ValueError,KeyError,TypeError,UnicodeError):return self.reply(400,{'error':'Unsupported export or missing original time/sender/conversation'})
        if self.path=='/v1/voice':
            try:
                length=int(self.headers.get('Content-Length','0'))
                if not 0<length<=4096 or self.headers.get('Content-Type','').split(';')[0]!='application/json':raise ValueError('Invalid voice request')
                body=json.loads(self.rfile.read(length));voice=self.server.mobile.agent.voice
                if not isinstance(body,dict):raise ValueError('Expected object')
                if body.get('action')=='begin':result=voice.begin(body['id'],self.device['id'],body.get('consent'))
                elif body.get('action')=='bind':result=voice.bind(body['enrollment_id'],body['slot'],body['session_id'],self.device['id'],body.get('solo'))
                elif body.get('action')=='revoke':result=voice.revoke()
                else:raise ValueError('Unknown voice action')
                return self.reply(200,result)
            except Conflict as error:return self.reply(409,{'error':str(error)})
            except (ValueError,KeyError,TypeError):return self.reply(400,{'error':'Invalid voice enrollment request'})
        if self.path!='/v1/mobile/ingest':return super().do_POST()
        try:
            length=int(self.headers.get('Content-Length','0'))
            if not 0<length<=900000 or self.headers.get('Content-Type','').split(';')[0]!='application/json':
                raise ValueError('Invalid upload')
            body=json.loads(self.rfile.read(length))
            if not isinstance(body,dict):raise ValueError('Expected object')
            return self.reply(200,self.server.shared.accept(self.server.mobile,body,self.device['id']))
        except Conflict as error:return self.reply(409,{'error':str(error)})
        except (ValueError,KeyError,TypeError):return self.reply(400,{'error':'Invalid phone evidence'})
        except Exception:return self.reply(500,{'error':'Evidence retained; retry this immutable message'})


class Server(mobile_http.http.Server):
    def get_request(self):
        connection,address=super().get_request()
        connection.settimeout(30)
        return connection,address


def make_server(root,host,port,processing_config=None):
    store=Store(root)
    processor=None
    if processing_config:
        from heartball_processing import Processor
        processor=Processor.configured(store,processing_config)
    agent=processor.agent if processor else AgentStore(store)
    server=Server((host,port),Handler)
    server.processor=processor
    server.engine=SimpleNamespace(store=store,max_seconds=86400)
    server.mobile=MobileIngest(store,agent)
    from heartball_acoustic_worker import AcousticQueue
    server.acoustic_queue=AcousticQueue(agent)
    server.shared=SharedWorkspace(store,agent)
    return server


def safe_root(root):
    root=root.resolve()
    project=Path(__file__).resolve().parents[1]
    # Refuse the existing live/test phone and Mac roots, including symlinks.
    if root in {(project/'.build'/name).resolve() for name in ('heartball-lab','xinlika-mobile','xinlika-mobile-dev')}:
        raise ValueError('Shared service needs a separate data directory; existing validation storage is protected')
    return root


def write_private(path,value):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    with os.fdopen(fd,'w') as output:
        json.dump(value,output,ensure_ascii=False,indent=2);output.write('\n')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    commands=parser.add_subparsers(dest='command',required=True)
    serve=commands.add_parser('serve')
    serve.add_argument('--root',type=Path,required=True);serve.add_argument('--host',default='127.0.0.1')
    serve.add_argument('--port',type=int,default=18778);serve.add_argument('--processing-config',type=Path)
    serve.add_argument('--tls-cert',type=Path);serve.add_argument('--tls-key',type=Path)
    device=commands.add_parser('device');device.add_argument('action',choices=('add','list','revoke'))
    device.add_argument('--root',type=Path,required=True);device.add_argument('--name');device.add_argument('--id')
    device.add_argument('--access',choices=('editor','reader'),default='editor')
    device.add_argument('--output',type=Path);device.add_argument('--base-url')
    args=parser.parse_args()
    try:root=safe_root(args.root)
    except ValueError as error:parser.error(str(error))
    if args.command=='device':
        if args.action=='add' and (not args.name or not args.output or not args.base_url):
            parser.error('device add requires --name --output --base-url; the token is only saved to that private file')
        if args.action=='add' and args.output.exists():parser.error('Connection file exists; preserve it and choose a new output path')
        if args.action=='add':
            url=urlparse(args.base_url)
            try:private=ipaddress.ip_address(url.hostname).is_private
            except ValueError:private=url.hostname=='localhost' or bool(url.hostname and url.hostname.endswith('.local'))
            if not url.hostname or url.username or url.password or url.query or url.fragment or not (url.scheme=='https' or url.scheme=='http' and private):
                parser.error('Device connection requires HTTPS or explicit private HTTP')
        store=Store(root);workspace=SharedWorkspace(store,AgentStore(store))
        try:
            if args.action=='add':
                result=workspace.provision(args.name,args.access)
                try:write_private(args.output,{'baseURL':args.base_url,**result})
                except BaseException:workspace.revoke(result['deviceId']);raise
                print(json.dumps({k:v for k,v in result.items() if k!='token'}))
            elif args.action=='list':print(json.dumps(workspace.devices(),ensure_ascii=False))
            else:
                if not args.id:parser.error('device revoke requires --id')
                print(json.dumps({'revoked':workspace.revoke(args.id)}))
        finally:store.db.close()
        return
    try:address=ipaddress.ip_address(args.host)
    except ValueError:parser.error('Bind an explicit numeric interface address')
    if address.is_unspecified:parser.error('Bind an explicit interface; wildcard listeners are disabled')
    if bool(args.tls_cert)!=bool(args.tls_key):parser.error('Provide both --tls-cert and --tls-key')
    if not address.is_private and not args.tls_cert:parser.error('Public serving requires TLS certificates')
    root.mkdir(parents=True,exist_ok=True,mode=0o700)
    lease=(root/'service.lock').open('a+');fcntl.flock(lease.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
    server=make_server(root,args.host,args.port,args.processing_config)
    if args.tls_cert:
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.minimum_version=ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(str(args.tls_cert),str(args.tls_key))
        server.socket=context.wrap_socket(server.socket,server_side=True)
    if not server.shared.devices():
        print('No devices provisioned; authenticated routes reject all requests. Use device add locally.')
    (root/'pid').write_text(str(os.getpid()))
    if server.processor:server.processor.start()
    signal.signal(signal.SIGTERM,lambda *_:threading.Thread(target=server.shutdown,daemon=True).start())
    print(f'Xinlika shared workspace listening on {args.host}:{args.port}; no hardware control',flush=True)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:
        server.shutdown()
        if server.processor:server.processor.close()
        server.server_close();server.engine.store.db.close()


if __name__=='__main__':main()

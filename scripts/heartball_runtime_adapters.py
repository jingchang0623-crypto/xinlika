"""Isolated native Hermes/DSH processes behind the same business task contract."""
from __future__ import annotations

import hashlib
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request

from heartball_agent_runtime import AgentReceipt


def private_json(path,value):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n');path.chmod(0o600)


def external_environment(configuration_file):
    """Forward only operator-declared MCP variable names, never the whole env."""
    if not configuration_file:return {}
    servers=json.loads(Path(configuration_file).expanduser().read_text()).get('servers',{})
    names={name for server in servers.values() for name in
        [*server.get('env_allowlist',[]),*server.get('headers_env',{}).values()]}
    return {name:os.environ[name] for name in names if isinstance(name,str) and name in os.environ}


def invalid_tool_loop(messages):
    """Lifecycle budget only; native harness still decides and executes tools."""
    calls={};failures={};total=0
    for message in messages:
        for call in message.get('tool_calls',[]):
            fn=call.get('function',{});arguments=fn.get('arguments')
            try:arguments=json.dumps(json.loads(arguments) if isinstance(arguments,str) else arguments,sort_keys=True)
            except ValueError:pass
            calls[call.get('id')]=(fn.get('name'),arguments)
        if message.get('role')!='tool':continue
        content=message.get('content','')
        if not isinstance(content,str):continue
        error=(('Error executing tool ' in content and ('{"error":' in content or content.lstrip().startswith('Error:')))
               or ('{"error":' in content and 'rejected the last' in content and 'MCP server' in content))
        if not error:
            total=0 # A successful tool ends the consecutive failure streak.
            signature=calls.get(message.get('tool_call_id'))
            if signature and signature[0] and signature[0].split('__')[-1] in {'stage_analysis','submit_analysis','commit_staged_analysis'}:
                failures.clear() # The same finalize arguments now refer to changed draft state.
            continue
        total+=1;signature=calls.get(message.get('tool_call_id'))
        if signature:
            failures[signature]=failures.get(signature,0)+1
            if failures[signature]>=2:return 'repeated_invalid_tool_call'
        if total>=4:return 'invalid_tool_call_budget'
    return None


class ModelMeter:
    """Loopback proxy: same provider/settings; observed provider usage, no price guesses.

    Native harnesses still perform all planning and tool execution. Only the API
    route, request limits, optional thinking setting and usage logging are shared.
    """
    def __init__(self,configuration,root,max_calls=30):
        self.cfg=configuration;self.root=Path(root);self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.key=secrets.token_urlsafe(24);self.rows=[];self.lock=threading.Lock();self.max_calls=max_calls
        self.guardrail_reason=None;self.guardrail_rejections=0
        self.transport_failures=0
        self.api_key=Path(configuration['api_key_file']).expanduser().read_text().strip() if 'api_key_file' in configuration else os.environ[configuration['api_key_env']]
        meter=self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def send_json(self,status,value):
                raw=json.dumps(value).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
            def do_GET(self):
                if self.headers.get('Authorization')!='Bearer '+meter.key:return self.send_json(401,{'error':{'message':'Unauthorized'}})
                return self.send_json(200,{'object':'list','data':[{'id':meter.cfg['model'],'object':'model','context_length':131072}]})
            def do_POST(self):
                if self.headers.get('Authorization')!='Bearer '+meter.key:return self.send_json(401,{'error':{'message':'Unauthorized'}})
                if self.path!='/v1/chat/completions':return self.send_json(404,{'error':{'message':'Only chat completions is enabled'}})
                length=int(self.headers.get('Content-Length','0'))
                if not 0<length<3_000_000:return self.send_json(413,{'error':{'message':'Request too large'}})
                try:
                    body=json.loads(self.rfile.read(length))
                    if meter.transport_failures>=3:
                        meter.guardrail_rejections+=1
                        return self.send_json(422,{'error':{'message':'Provider connection unavailable; retry through the durable queue after backoff.','type':'provider_transport_unavailable'}})
                    reason=invalid_tool_loop(body.get('messages',[]))
                    if reason:
                        meter.guardrail_reason=reason;meter.guardrail_rejections+=1
                        return self.send_json(422,{'error':{'message':'Task stopped after repeated invalid tool calls; keep evidence and fix the task contract before retrying.','type':reason}})
                    if any(k in body for k in ('dsh_session_log','dsh_plugin_packages')):raise ValueError('Extra harness log upload is disabled')
                    with meter.lock:
                        if len(meter.rows)>=meter.max_calls:
                            meter.guardrail_reason='model_call_budget'
                            return self.send_json(422,{'error':{'message':'Task model call budget reached','type':'budget_exceeded'}})
                        row={'index':len(meter.rows),'started_at':time.time(),'status':'running'};meter.rows.append(row)
                    body['model']=meter.cfg['model'];body.update(meter.cfg.get('extra_body',{}))
                    body['max_tokens']=min(int(body.pop('max_completion_tokens',body.get('max_tokens',12000))),int(meter.cfg.get('max_tokens',12000)))
                    body.pop('reasoning_effort',None)
                    if body.get('stream'):body['stream_options']={'include_usage':True}
                    if meter.cfg.get('capture_model_payloads',False):private_json(meter.root/f"request-{row['index']:03}.json",body)
                    url=meter.cfg['base_url'].rstrip('/')+'/chat/completions'
                    request=urllib.request.Request(url,data=json.dumps(body).encode(),headers={'Authorization':'Bearer '+meter.api_key,'Content-Type':'application/json'})
                    try:response=urllib.request.urlopen(request,timeout=180)
                    except urllib.error.HTTPError as error:
                        raw=error.read();row.update(status='provider_error',http_status=error.code,seconds=time.time()-row['started_at'])
                        if meter.cfg.get('capture_model_payloads',False):private_json(meter.root/f"response-{row['index']:03}.json",{'status':error.code,'body':raw.decode(errors='replace')})
                        return self.send_json(error.code,{'error':{'message':'Provider refused evaluation request','type':'provider_error'}})
                    except urllib.error.URLError:
                        meter.transport_failures+=1
                        row.update(status='transport_error',error='URLError',seconds=time.time()-row['started_at'])
                        if meter.transport_failures>=3:meter.guardrail_reason='provider_transport_unavailable'
                        return self.send_json(422 if meter.transport_failures>=3 else 502,{'error':{'message':'Provider connection unavailable','type':'provider_transport_unavailable'}})
                    with response:
                        self.send_response(200);self.send_header('Content-Type',response.headers.get('Content-Type','application/json'));self.end_headers()
                        chunks=[];usage=None
                        if body.get('stream'):
                            for line in response:
                                chunks.append(line)
                                if line.startswith(b'data: '):
                                    try:
                                        event=json.loads(line[6:])
                                        if event.get('usage'):usage=event['usage']
                                    except (ValueError,TypeError):pass
                                self.wfile.write(line);self.wfile.flush()
                        else:
                            raw=response.read();chunks=[raw];usage=json.loads(raw).get('usage');self.wfile.write(raw)
                        if meter.cfg.get('capture_model_payloads',False):(meter.root/f"response-{row['index']:03}.body").write_bytes(b''.join(chunks))
                        row.update(status='completed',seconds=time.time()-row['started_at'],usage=usage)
                except (BrokenPipeError,ConnectionResetError):
                    if 'row' in locals():row.update(status='client_disconnected',seconds=time.time()-row['started_at'])
                except Exception as error:
                    if 'row' in locals():row.update(status='failed',error=type(error).__name__,seconds=time.time()-row['started_at'])
                    self.send_json(502,{'error':{'message':type(error).__name__}})
                finally:private_json(meter.root/'usage.json',meter.summary())
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler);self.server.daemon_threads=True
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.base_url=f'http://127.0.0.1:{self.server.server_port}/v1'

    def summary(self):
        totals={'prompt_tokens':0,'completion_tokens':0,'total_tokens':0,'cached_tokens':0}
        known=0
        for row in self.rows:
            usage=row.get('usage')
            if not usage:continue
            known+=1
            for key in ('prompt_tokens','completion_tokens','total_tokens'):totals[key]+=usage.get(key,0)
            totals['cached_tokens']+=usage.get('prompt_tokens_details',{}).get('cached_tokens',0)
        return {'provider_model':self.cfg['model'],'calls':len(self.rows),'calls_with_usage':known,'usage_complete':known==len(self.rows),**totals,'guardrail_reason':self.guardrail_reason,'guardrail_rejections':self.guardrail_rejections,'currency_cost':None,'cost_basis':'provider_usage_only_no_unverified_price','requests':self.rows}

    def close(self):
        self.server.shutdown();self.server.server_close();self.thread.join(timeout=5)
        private_json(self.root/'usage.json',self.summary())


class NativeProcessAdapter:
    def __init__(self,runtime,*,python,client_python,root,configuration,timeout=600):
        if runtime not in {'hermes','deepseek-harness'}:raise ValueError('Unknown native runtime')
        # Preserve venv launchers: resolving their symlink would select system Python.
        self.runtime=runtime;self.python=Path(os.path.abspath(python));self.client_python=Path(os.path.abspath(client_python))
        self.root=Path(root).resolve();self.cfg=configuration;self.timeout=timeout
        self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
        if not (self.root/'.agent-runtime-owned').is_file():raise ValueError('Native adapter requires an explicitly owned data root')
        self.meter=None

    def run(self,task):
        from heartball_agent_runtime import readonly_database
        db=readonly_database(self.root/'heartball.sqlite')
        try:
            previous=db.execute('SELECT receipt FROM agent_runtime_receipts WHERE task_id=?',(task.id,)).fetchone()
        finally:db.close()
        if previous:
            return AgentReceipt(runtime=self.runtime,task_id=task.id,status='completed',receipt=json.loads(previous[0]),
                usage={'calls':0,'calls_with_usage':0,'usage_complete':True,'prompt_tokens':0,'completion_tokens':0,
                       'total_tokens':0,'cached_tokens':0,'currency_cost':None,'cost_basis':'existing_durable_receipt'})
        run_folder=self.root/'runtime-runs'/task.id;run_folder.mkdir(parents=True,exist_ok=True,mode=0o700)
        folder=run_folder/('attempt-'+str(len(list(run_folder.glob('attempt-*')))+1).zfill(3))
        folder.mkdir(parents=True,exist_ok=False,mode=0o700)
        task_path=folder/'task.json';private_json(task_path,task.model_dump())
        skill_source=Path(__file__).resolve().parents[1]/'prompts/skills/xinlika-context/SKILL.md'
        skill=folder/'SKILL.md';skill.write_bytes(skill_source.read_bytes());skill.chmod(0o600)
        if hashlib.sha256(skill.read_bytes()).hexdigest()!=task.skill_version:
            value=AgentReceipt(runtime=self.runtime,task_id=task.id,status='failed',error='skill_version_changed',usage={'calls':0,'total_tokens':0})
            private_json(folder/'receipt.json',value.model_dump());return value
        call_budget=int(self.cfg.get('model_call_budget',24))
        if not 1<=call_budget<=96:raise ValueError('Model call budget must be 1..96')
        self.meter=ModelMeter(self.cfg,folder/'model-meter',max_calls=call_budget)
        request={'runtime':self.runtime,'root':str(self.root),'task':str(task_path),'skill':str(skill),
                 'model':self.cfg['model'],'model_url':self.meter.base_url,'proxy_key':self.meter.key,
                 'client_python':str(self.client_python),'max_tokens':int(self.cfg.get('max_tokens',12000)),'timeout':self.timeout,
                 'output':str(folder/'native-result.json'),'home':str(folder/'home'),
                 'retain_native_transcript':bool(self.cfg.get('capture_model_payloads',False))}
        request['max_turns']=call_budget
        request['finalize_only']=bool(self.cfg.get('finalize_only',False))
        db=readonly_database(self.root/'heartball.sqlite')
        try:request['resume_drafts']=bool(db.execute('SELECT 1 FROM agent_analysis_chunks WHERE task_id=? LIMIT 1',(task.id,)).fetchone())
        finally:db.close()
        if self.cfg.get('analysis_context_tokens') is not None:
            request['analysis_context_tokens']=int(self.cfg['analysis_context_tokens'])
            request['context_window']=131072
        if self.cfg.get('external_mcp_config'):request['external_mcp_config']=str(Path(self.cfg['external_mcp_config']).expanduser().resolve())
        private_json(folder/'request.json',request)
        worker=Path(__file__).with_name('xinlika-runtime-worker.py').resolve()
        started=time.monotonic();error=None
        env={k:v for k,v in os.environ.items() if k in {'PATH','LANG','LC_ALL','TMPDIR','SYSTEMROOT','SystemRoot'}}
        env.update(external_environment(self.cfg.get('external_mcp_config')))
        env.update(PYTHONUNBUFFERED='1',PYTHONPATH=str(worker.parent))
        with (folder/'console.log').open('w') as console:
            try:process=subprocess.Popen([str(self.python),str(worker),str(folder/'request.json')],env=env,cwd=folder,
                stdout=console,stderr=subprocess.STDOUT,start_new_session=True)
            except OSError as failure:
                usage=self.meter.summary();self.meter.close();self.meter=None
                value=AgentReceipt(runtime=self.runtime,task_id=task.id,status='failed',error='native_startup_'+type(failure).__name__,usage=usage)
                private_json(folder/'receipt.json',value.model_dump());return value
            try:
                code=process.wait(timeout=self.timeout+40)
                if code:error='native_exit_'+str(code)
            except subprocess.TimeoutExpired:
                error='runtime_timeout'
                # This is a new group containing only this task's owned harness,
                # SDK child and scoped MCP. Never signal a recording/service PID.
                try:os.killpg(process.pid,signal.SIGTERM)
                except ProcessLookupError:pass
                try:process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    try:os.killpg(process.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
                    process.wait(timeout=10)
        # A receipt survives loss of the final assistant message or worker reply.
        db=readonly_database(self.root/'heartball.sqlite')
        try:
            row=db.execute('SELECT receipt FROM agent_runtime_receipts WHERE task_id=?',(task.id,)).fetchone()
            receipt=json.loads(row[0]) if row else None
        finally:db.close()
        status='completed' if receipt else 'failed'
        if not receipt and self.meter.guardrail_reason:error=self.meter.guardrail_reason
        if not receipt and error is None:error='no_committed_receipt'
        value=AgentReceipt(runtime=self.runtime,task_id=task.id,status=status,seconds=time.monotonic()-started,
                           receipt=receipt,error=error if not receipt else None,usage=self.meter.summary())
        self.meter.close();self.meter=None;private_json(folder/'receipt.json',value.model_dump())
        if receipt and not self.cfg.get('capture_model_payloads',False):
            import shutil
            shutil.rmtree(folder/'home',ignore_errors=True)
        return value

    def close(self):
        if self.meter:self.meter.close();self.meter=None


def adapter_from_config(configuration,root):
    cfg=dict(configuration)
    model=dict(cfg['model'])
    if cfg.get('external_mcp_config'):model['external_mcp_config']=cfg['external_mcp_config']
    native=NativeProcessAdapter(cfg['runtime'],python=cfg['python'],client_python=cfg['client_python'],root=root,
                                configuration=model,timeout=int(cfg.get('timeout_seconds',240)))
    if cfg.get('analysis_strategy')=='incremental':
        from heartball_incremental import IncrementalProcessAdapter
        return IncrementalProcessAdapter(root,model,fallback=native)
    if cfg.get('analysis_strategy') not in (None,'native'):
        raise ValueError('Unknown analysis strategy')
    return native

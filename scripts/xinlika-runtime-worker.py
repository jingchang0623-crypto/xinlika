#!/usr/bin/env python3
"""Native harness entry points. Contains no custom agent reasoning/execution loop."""
import json
import os
from pathlib import Path
import re
import sys


def task_objective(config,task):
    text=task['objective']
    if config.get('resume_drafts'):
        text+='\n这是失败后的继续执行：先 analysis_contract 查看已持久化的 staged_chunks，使用 read_analysis_chunk 按需读取既有草稿，保留已有完整事件与来源分配，继续未完成部分。不要从头生成重复事件或重复已成功草稿；需要改某块时沿用 chunk_id 和 expected_digest。最终仍须完整来源校验和数据库回执。'
    if config.get('finalize_only'):
        text+='\n本次是提交收尾：系统已独立核对全部来源片段分配完整，无需重新读全部来源或重提炼。保留 issues/topics/memories/fragments 的内容不变。先尝试 commit_staged_analysis；若只因可选 activities 失败，只读取含 activities 的既有草稿并修正这一部分。活动只是可选背景，不要求包住其他首页事件；无法可靠满足活动边界/来源约束时可将该草稿 activities 留空，待后续独立重建，不要硬造活动。最后取得提交回执。'
    return text


def run_hermes(config,task,skill,command):
    home=Path(config['home']);home.mkdir(parents=True,exist_ok=True,mode=0o700)
    os.environ['HERMES_HOME']=str(home)
    from heartball_runtime_adapters import private_json
    settings={'memory':{'memory_enabled':False,'user_profile_enabled':False},'tools':{'tool_search':{'enabled':'off'}},
        'skills':{'creation_nudge_interval':0},'agent':{'max_turns':config.get('max_turns',24)},'display':{'quiet':True}}
    if config.get('analysis_context_tokens') is not None:
        window=config['context_window'];threshold=config['analysis_context_tokens']
        if not 20000<threshold<window-config.get('max_tokens',12000):raise ValueError('Invalid analysis context budget')
        settings.update(model={'default':config['model'],'provider':'custom','base_url':config['model_url'],'context_length':window},
            compression={'threshold':threshold/window,'threshold_tokens':threshold},tool_budget={'mcp_result_size_chars':100000})
    private_json(home/'config.yaml',settings)
    from run_agent import AIAgent
    from tools.mcp_tool_discovery import register_mcp_servers
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers
    from tools.registry import registry
    names=register_mcp_servers({'xinlika':{'command':command[0],'args':command[1:],'enabled':True,'trust':'full'}})
    if not names:raise RuntimeError('Domain MCP discovery returned no tools')
    mapping=registry.get_tool_to_toolset_map()
    sets=list({mapping[name] for name in names if name in mapping})
    agent=AIAgent(base_url=config['model_url'],api_key=config['proxy_key'],model=config['model'],provider='custom',
        api_mode='chat_completions',max_iterations=config.get('max_turns',24),enabled_toolsets=sets,quiet_mode=True,
        ephemeral_system_prompt=skill,skip_context_files=True,skip_memory=True,skip_background_review=True,
        load_soul_identity=False,session_id=task['id'],cwd=str(Path(config['root'])),max_tokens=config.get('max_tokens',12000),
        run_budget_seconds=config['timeout'])
    try:
        value=agent.run_conversation(task_objective(config,task))
        return {'runtime':'hermes','tool_names':names,'result':value}
    finally:
        if callable(getattr(agent,'close',None)):agent.close()
        shutdown_mcp_servers()


def run_dsh(config,task,skill,command):
    from deepseek_harness import DeepSeekHarness
    from heartball_runtime_adapters import private_json
    home=Path(config['home']);home.mkdir(parents=True,exist_ok=True,mode=0o700)
    # Standard SDK profile, with unrelated tools/instructions/telemetry removed.
    # Keep native tool execution, persistence, compaction and the MCP client.
    import subprocess
    env={**os.environ,'DSH_HOME':str(home),'XINLIKA_MODEL_PROXY_KEY':config['proxy_key'],'DSH_TELEMETRY_MODE':'OFF'}
    binary=Path(sys.executable).parent/'dsh'
    dump=subprocess.run([str(binary),'--profile','sdk','--dump-config'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=45)
    if dump.returncode:raise RuntimeError('DSH SDK profile initialization failed')
    ids=re.findall(r'^- id: (\S+)',dump.stdout,re.M)
    disabled={name for name in ids if name.startswith('tool-')}
    disabled.update({'workspace-dependencies','skill-office','agent-instructions','session-title-llm','plan-mode',
                     'session-telemetry-otel','plugin-package-inventory-deepseek','goal-round-driver','llm-deepseek','llm-deepseek-account'})
    patch=[{'id':name,'disabled':True} for name in sorted(disabled) if name in ids]
    patch += [
        {'id':'session-log-deepseek','config':{'enabled':False}},
        {'id':'system-prompt','config':{'personaPrefix':skill}},
        {'id':'skill-filesystem','config':{'includeDefaultRoots':False,'customSkillDirs':[str(Path(config['skill']).parent.parent)],'watch':False}},
        {'id':'llm-pi-ai','config':{'providers':{'xinlika':{'apiKeyEnv':'XINLIKA_MODEL_PROXY_KEY','api':'openai-completions',
            'baseURL':config['model_url'],'retryPolicy':{'mode':'normal','maxRetries':0},
            'compat':{'supportsDeveloperRole':False,'maxTokensField':'max_tokens'},
            'models':[{'id':config['model'],'contextWindow':131072,'maxTokens':config.get('max_tokens',12000)}]}}}},
        {'insert':[{'id':'xinlika-mcp','name':'@deepseek-ai/dsh-mcp-client','config':{
            'serverName':'xinlika','transport':'stdio','command':command[0],'args':command[1:]}}]}
    ]
    if config.get('analysis_context_tokens') is not None:
        window=config['context_window'];threshold=config['analysis_context_tokens']
        if not 20000<threshold<window-config.get('max_tokens',12000):raise ValueError('Invalid analysis context budget')
        patch.append({'id':'compaction-basic','config':{'thresholdRatio':threshold/window,'headroomTokens':8192,'retainTokens':60000,'maxTokens':6000}})
    path=Path(config['output']).with_name('dsh.patch.yml');private_json(path,patch)
    with DeepSeekHarness(dsh_home=str(home),cwd=config['root'],profile='sdk',provider='xinlika',model=config['model'],
         max_tokens=config.get('max_tokens',12000),patches=(str(path),),env=env,request_timeout_seconds=config['timeout'],initialize_timeout_seconds=60,shutdown_timeout_seconds=15) as harness:
        value=harness.run(task_objective(config,task),session_id=task['id'])
        return {'runtime':'deepseek-harness','finish_reason':value.finish_reason,'final_response':value.final_response,
                'events':[{'type':e.get('type'), 'data':e.get('data')} if isinstance(e,dict) else str(e) for e in value.events]}


def main():
    config=json.loads(Path(sys.argv[1]).read_text());task=json.loads(Path(config['task']).read_text())
    skill=Path(config['skill']).read_text()
    command=[config['client_python'],str(Path(__file__).with_name('xinlika-mcp.py').resolve()),
             '--database',str(Path(config['root'])/'heartball.sqlite'),'--analysis-task',config['task']]
    if config.get('retain_native_transcript',True):command+=['--audit',str(Path(config['output']).with_name('tool-audit.jsonl'))]
    if config.get('external_mcp_config'):command+=['--external-config',config['external_mcp_config']]
    result=run_hermes(config,task,skill,command) if config['runtime']=='hermes' else run_dsh(config,task,skill,command)
    if not config.get('retain_native_transcript',True):
        result={k:v for k,v in result.items() if k in {'runtime','tool_names','finish_reason'}}
    from heartball_runtime_adapters import private_json
    private_json(Path(config['output']),result)


if __name__=='__main__':main()

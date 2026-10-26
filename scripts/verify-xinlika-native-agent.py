#!/usr/bin/env python3
"""Real frozen-transcript integration, isolated HTTP sync/MCP/native answer.

No Bluetooth, ASR, or live service writes. Controlled feedback is not historical
user feedback and is labeled separately from the real source corpus.
"""
import argparse
import asyncio
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import threading
import urllib.request
import uuid

from heartball_runtime_adapters import private_json
from heartball_agent_runtime import readonly_database
from heartball_agent_store import encoded,stable
from heartball_store import now


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True);parser.add_argument('--snapshot',type=Path,required=True)
    parser.add_argument('--runtime',choices=['hermes','deepseek-harness'],required=True)
    parser.add_argument('--model-config',type=Path,required=True);parser.add_argument('--runtime-python',type=Path,required=True)
    parser.add_argument('--focus-database',type=Path);parser.add_argument('--focus-session')
    parser.add_argument('--repair-cases',type=Path);parser.add_argument('--repair-only',action='store_true')
    parser.add_argument('--relations-only',action='store_true');parser.add_argument('--relation-evaluation-corpus',type=Path)
    args=parser.parse_args();root=args.root.resolve();project=Path(__file__).resolve().parents[1]
    if not root.is_relative_to(project/'.build') or root.exists():raise ValueError('Use a new private .build root')
    root.mkdir(parents=True,mode=0o700)
    source=readonly_database(args.snapshot);target=sqlite3.connect(root/'heartball.sqlite')
    try:source.backup(target)
    finally:source.close();target.close()
    configuration={'agent_runtime':{'runtime':args.runtime,'python':str(args.runtime_python.absolute()),
        'client_python':str(Path(sys.executable).absolute()),'model':json.loads(args.model_config.read_text()),
        'coalesce_seconds':180,'timeout_seconds':240,'proactive_feedback':False}}
    configuration['agent_runtime']['model']['capture_model_payloads']=True
    private_json(root/'processing.json',configuration)
    spec=importlib.util.spec_from_file_location('native_shared_validation',Path(__file__).with_name('heartball-shared-service.py'))
    service=importlib.util.module_from_spec(spec);spec.loader.exec_module(service)
    server=service.make_server(root,'127.0.0.1',0,root/'processing.json')
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    base=f'http://127.0.0.1:{server.server_port}'
    phone=server.shared.provision('isolated-phone');mac=server.shared.provision('isolated-mac');reader=server.shared.provision('isolated-mcp','reader')
    def request(path,device,body=None):
        req=urllib.request.Request(base+path,headers={'Authorization':'Bearer '+device['token'],'Content-Type':'application/json'},
            data=json.dumps(body).encode() if body is not None else None)
        with urllib.request.urlopen(req,timeout=30) as response:return json.load(response)
    def sync(device):return request('/v1/shared/sync?day=2026-10-21&time_zone=Asia%2FShanghai',device)
    try:
        # The seed is a real pre-correction native organization snapshot. Current
        # domain data is immediately visible to both clients without re-analysis.
        a,b=sync(phone),sync(mac)
        same_projection=a['state']['events']==b['state']['events']
        agent=server.processor.agent;db=agent.db
        if args.relations_only:
            if not args.relation_evaluation_corpus:raise ValueError('Post-run evaluation corpus required')
            def semantic_relations():
                # Labels are used here only, after native inference; never in a task.
                labels=json.loads(args.relation_evaluation_corpus.read_text())['labels']['meeting']
                groups=[{r[0] for r in db.execute("SELECT DISTINCT e.session_id FROM workspace_events e JOIN workspace_all_event_topics l ON l.event_id=e.id WHERE l.topic_id=? AND e.status='active'",(topic[0],))} for topic in db.execute("SELECT id FROM workspace_topics WHERE status='active'")]
                positive=set(labels['same_sessions']);negative=labels['different_session']
                return {'same_specific_matter_linked':any(positive<=g and negative not in g for g in groups),
                    'different_matter_kept_separate':not any(negative in g and bool(positive&g) for g in groups)}
            before=semantic_relations()
            unchanged_tables=('workspace_events','claims','documents')
            digest=lambda table:hashlib.sha256(encoded([list(r) for r in db.execute('SELECT * FROM '+table+' ORDER BY id')]).encode()).hexdigest()
            hashes={table:digest(table) for table in unchanged_tables}
            steps=[]
            for _ in range(4):
                worked=server.processor.tick(context_only=True);steps.append(worked)
                if not worked:break
            from heartball_activities import activity_projection
            from heartball_timeline import visible
            coverage=activity_projection(db)
            result={'runtime':args.runtime,'method':'real_source_correction_repair_not_new_blind_comparison','before':before,'after':semantic_relations(),
                'steps':steps,'source_events_memories_unchanged':all(digest(table)==value for table,value in hashes.items()),
                'completed_repair_tasks':db.execute('SELECT count(*) FROM native_topic_repairs').fetchone()[0],
                'pending_native_jobs':db.execute("SELECT count(*) FROM jobs WHERE kind='native_agent_analysis' AND status IN ('queued','running','retryable')").fetchone()[0],
                'failed_native_jobs':db.execute("SELECT count(*) FROM jobs WHERE kind='native_agent_analysis' AND status='failed'").fetchone()[0],
                'visible_issues_without_valid_activity':sum(1 for e in db.execute("SELECT * FROM workspace_events WHERE status='active' AND kind!='focus'") if visible(db,dict(e)) and e['id'] not in coverage),
                'corrected_memory_version_three_preserved':bool(db.execute("SELECT 1 FROM claims WHERE version=3 AND status='confirmed' AND owner='参与者（身份待确认）'").fetchone()),
                'asr_jobs_created':db.execute("SELECT count(*) FROM jobs WHERE kind='asr_audio'").fetchone()[0],
                'phone_mac_protocol_projection_equal':sync(phone)['state']['events']==sync(mac)['state']['events'],
                'hardware_operations':0,'existing_service_restarts':0,'evaluation_labels_in_task':False}
            private_json(root/'relation-result.json',result);print(json.dumps(result,ensure_ascii=False,indent=2));return
        if args.repair_cases:
            # Development regression repair. Only its source ID selects input;
            # expected wording and the quality label are NOT fed to the Agent.
            cases=json.loads(args.repair_cases.read_text())['cases'];case=next(c for c in cases if c['kind']=='visible')
            ref=case['refs'][0];did=ref['document_id'];doc=dict(db.execute('SELECT * FROM documents WHERE id=?',(did,)).fetchone())
            if db.execute('SELECT 1 FROM workspace_event_sources WHERE document_id=?',(did,)).fetchone():raise ValueError('Repair expects an actually omitted source, not duplicate re-extraction')
            generation=db.execute('SELECT generation FROM workspace_generations WHERE document_id=?',(did,)).fetchone()
            with agent.store.transaction():
                agent.enqueue('native_agent_analysis','explicit-missed-source:'+did+':'+server.processor.native.skill_version,
                    {'session_id':doc['session_id'],'document_ids':[did],'versions':[{'id':did,'revision':doc['revision'],'generation':generation[0] if generation else 0}]})
            server.processor.tick(context_only=True)
            from heartball_timeline import visible
            repaired=[dict(r) for r in db.execute("SELECT e.* FROM workspace_events e JOIN workspace_event_sources s ON s.event_id=e.id WHERE e.status='active' AND s.document_id=? AND instr(s.quote,?)>0",(did,ref['quote'])) if visible(db,dict(r))]
            repair={'case':case['id'],'visible_with_literal_source':bool(repaired),
                'time_uses_recording_day':bool(repaired) and all(r['occurred_at'][:10]==doc['occurred_at'][:10] for r in repaired),
                'method':'targeted_development_regression_not_independent_holdout',
                'expected_label_in_model_prompt':False,'asr_jobs_created':db.execute("SELECT count(*) FROM jobs WHERE kind='asr_audio'").fetchone()[0]}
            private_json(root/'repair-result.json',repair)
            if args.repair_only:print(json.dumps(repair,ensure_ascii=False,indent=2));return
        focus_check=None
        if args.focus_database:
            if not args.focus_session:raise ValueError('Focus session identity required')
            source=readonly_database(args.focus_database)
            try:focus=source.execute("SELECT * FROM documents WHERE session_id=? AND kind='focus' AND status NOT IN ('superseded','no_text') ORDER BY occurred_at LIMIT 1",(args.focus_session,)).fetchone()
            finally:source.close()
            if not focus:raise ValueError('No known real focus transcript available')
            focus=dict(focus);before_ambient={r[0] for r in db.execute("SELECT id FROM workspace_events WHERE kind!='focus'")}
            if db.execute('SELECT 1 FROM documents WHERE id=?',(focus['id'],)).fetchone():raise ValueError('Focus was already imported into this replay')
            agent.commit_document({**focus,'evidence':json.loads(focus['evidence'])},{'title':'','summary':'','claims':[]})
            server.processor.tick(context_only=True)
            rows=db.execute("SELECT e.* FROM workspace_events e JOIN workspace_event_sources s ON s.event_id=e.id WHERE s.document_id=?",(focus['id'],)).fetchall()
            focus_check={'source':'existing_real_focus_transcript_no_new_asr','events':len(rows),
                'source_sha256':hashlib.sha256(focus['text'].encode()).hexdigest(),
                'independent_focus_events':bool(rows) and all(r['kind']=='focus' for r in rows),
                'recording_time_retained':bool(focus['occurred_at']) and bool(rows) and all(r['occurred_at']==focus['occurred_at'] for r in rows),
                'ambient_event_identities_unchanged':before_ambient=={r[0] for r in db.execute("SELECT id FROM workspace_events WHERE kind!='focus'")}}
            assert focus_check['independent_focus_events'],'Real focus task failed'
            assert sync(phone)['state']['events']==sync(mac)['state']['events']
        d=dict(db.execute("SELECT * FROM documents WHERE source_kind='live_conversation' AND status!='superseded' AND length(text)>30 ORDER BY occurred_at LIMIT 1").fetchone())
        quote=d['text'][:min(80,len(d['text']))];cid=stable('native-verification-controlled-memory:'+d['id'])
        with agent.store.transaction():
            db.execute("INSERT INTO claims(id,document_id,project,kind,statement,owner,due_at,status,quote,quote_start,quote_end,version,replaces_id,created_at,replaces_version) VALUES(?,?,'','fact',?,'unknown',NULL,'proposed',?,0,?,1,NULL,?,NULL)",(cid,d['id'],quote,quote,len(quote),now()))
        request('/v1/feedback',phone,{'id':str(uuid.uuid4()),'target_id':cid,'expected_version':1,'action':'correct','values':{'owner':'发言者（身份未核实）'}})
        corrected=db.execute('SELECT owner,version,status FROM claims WHERE id=?',(cid,)).fetchone()
        after_phone,after_mac=sync(phone),sync(mac)
        correction_synced=after_phone['state']['claims']==after_mac['state']['claims']
        request('/v1/feedback',mac,{'id':str(uuid.uuid4()),'target_id':cid,'expected_version':2,'action':'correct','values':{'owner':'参与者（身份待确认）'}})
        corrected=db.execute('SELECT owner,version,status FROM claims WHERE id=?',(cid,)).fetchone()
        correction_synced=correction_synced and sync(phone)['state']['claims']==sync(mac)['state']['claims']
        # A real native model/tool answer, rather than a deterministic stub.
        qid=str(uuid.uuid4());question='检索关于'+quote[:12]+'的讨论。当前记忆归属以更正后的 owner 字段为准，说明是否能认定为我本人，不要从旧原句的第一人称猜测身份。'
        request('/v1/memory/ask',mac,{'id':qid,'question':question})
        server.processor.native.tick()
        answer=db.execute('SELECT status,answer,refs FROM memory_answers WHERE id=?',(qid,)).fetchone()
        assert answer and answer['status']=='ready','Native answer did not complete'
        private_json(root/'answer-private.json',dict(answer))
        private_json(root/'reader.json',{'baseURL':base,'token':reader['token']})
        async def verify_mcp():
            from mcp import ClientSession,StdioServerParameters
            from mcp.client.stdio import stdio_client
            params=StdioServerParameters(command=sys.executable,args=[str(Path(__file__).with_name('xinlika-mcp.py').resolve()),'--connection',str(root/'reader.json')])
            async with stdio_client(params) as (read,write):
                async with ClientSession(read,write) as session:
                    await session.initialize();tools=await session.list_tools()
                    result=await session.call_tool('search_context',{'query':quote[:8]})
                    assert not result.isError
                    return {'tools':[t.name for t in tools.tools],'corrected_owner_visible':'参与者（身份待确认）' in str(result),'source_version_visible':'revision' in str(result)}
        mcp=asyncio.run(verify_mcp())
        result={'runtime':args.runtime,'source':'real_existing_meeting_and_dinner_transcripts',
            'controlled_feedback_not_historical':True,'same_phone_mac_event_projection':same_projection,
            'correction_synced':correction_synced,'corrected_version':corrected['version'],
            'native_answer_committed':answer['status']=='ready','answer_uses_corrected_owner':'参与者（身份待确认）' in answer['answer'],
            'mcp':mcp,'asr_jobs_created':db.execute("SELECT count(*) FROM jobs WHERE kind='asr_audio'").fetchone()[0],
            'focus':focus_check,'bluetooth_calls':0,'live_services_restarted':0}
        private_json(root/'result.json',result);print(json.dumps(result,ensure_ascii=False,indent=2))
    finally:
        server.shutdown();server.server_close();thread.join();server.processor.close();server.engine.store.db.close()


if __name__=='__main__':main()

#!/usr/bin/env python3
"""Explicit phone-recorded sample replay; original phone validation remains read-only.

Reuses the matching existing ASR cache to avoid occupying the phone's ASR slot.
This verifies the shared protocol and two-device corrections, not a live phone switch.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import time
import urllib.error
import urllib.request
import uuid


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-root',type=Path,required=True);p.add_argument('--document-id',required=True)
    p.add_argument('--shared-root',type=Path,required=True)
    p.add_argument('--admin-ssh-config',type=Path,help='Explicit private SSH control configuration for the isolated cloud container')
    p.add_argument('--fresh-asr',action='store_true',help='Send the explicitly selected excerpt through cloud ASR instead of seeding an existing transcript')
    p.add_argument('--phone-connection',type=Path,required=True);p.add_argument('--mac-connection',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    if not args.admin_ssh_config and args.source_root.resolve()==args.shared_root.resolve():p.error('Source and isolated shared workspace must differ')
    args.output.mkdir(parents=True,exist_ok=False,mode=0o700)
    phone=json.loads(args.phone_connection.read_text());mac=json.loads(args.mac_connection.read_text())
    with sqlite3.connect((args.source_root/'heartball.sqlite').resolve().as_uri()+'?mode=ro',uri=True) as db:
        db.row_factory=sqlite3.Row
        doc=dict(db.execute("SELECT * FROM documents WHERE id=? AND kind='ambient' AND status!='superseded'",(args.document_id,)).fetchone())
        evidence=json.loads(doc['evidence'])
        batch_id=next(e['batch_id'] for e in evidence if e.get('batch_id'))
        batch=dict(db.execute('SELECT * FROM batches WHERE id=?',(batch_id,)).fetchone())
        manifest=json.loads(db.execute('SELECT manifest FROM mobile_sessions WHERE id=?',(doc['session_id'],)).fetchone()[0])
        transcript=dict(db.execute('SELECT * FROM transcripts WHERE audio_hash=?',(batch['sha256'],)).fetchone())
    raw=Path(batch['filename']).read_bytes()
    assert hashlib.sha256(raw).hexdigest()==batch['sha256'] and transcript['text']==doc['text']
    assert doc['text'].strip() and doc['occurred_at']
    sid=str(uuid.uuid4());stream=str(uuid.uuid4());mid=str(uuid.uuid4())
    # This is a named excerpt with its own identity, never the original live
    # session. All source times and the exact codec bytes remain unchanged.
    manifest.update(id=sid,started_at=doc['occurred_at'])
    start=dt.datetime.fromisoformat(doc['occurred_at'].replace('Z','+00:00'))
    stop=start+dt.timedelta(seconds=len(raw)/2000)
    body={'id':mid,'kind':'batch','session':manifest,'stream_id':stream,'sequence':0,'start_byte':0,'end_byte':len(raw),
          'stream_started_at':start.isoformat(),'received_at':stop.isoformat(),'reason':'shared_verification_excerpt',
          'sha256':batch['sha256'],'audio_base64':base64.b64encode(raw).decode()}
    def workspace_write(statements):
        if not args.admin_ssh_config:
            with sqlite3.connect(args.shared_root/'heartball.sqlite') as db:
                for sql,values in statements:db.execute(sql,values)
            return
        # Administrative seeding is limited to this explicitly selected cached
        # transcript and excerpt closure. Audio still uses the public device API.
        config=json.loads(args.admin_ssh_config.read_text())
        script="import json,sqlite3,sys\nwith sqlite3.connect('/data/workspace/heartball.sqlite') as db:\n for sql,values in json.load(sys.stdin):db.execute(sql,values)\n"
        import shlex
        command=shlex.join(['docker','exec','-i','xinlika-shared','python','-c',script])
        subprocess.run(['ssh','-o','BatchMode=yes','-S',config['control'],config['host'],command],
                       input=json.dumps(statements),text=True,check=True,capture_output=True,timeout=30)
    if not args.fresh_asr:
        workspace_write([('INSERT OR IGNORE INTO transcripts VALUES(?,?,?,?,?,?)',
                         [transcript[k] for k in ('audio_hash','text','segments','provider','created_at','quality')])])
    def request(connection,path,value=None):
        req=urllib.request.Request(connection['baseURL']+path,headers={'Authorization':'Bearer '+connection['token'],'Content-Type':'application/json'},
                                   data=json.dumps(value).encode() if value is not None else None)
        try:r=urllib.request.urlopen(req,timeout=15)
        except urllib.error.HTTPError as error:r=error
        with r:return r.code,json.load(r)
    assert request(phone,'/v1/mobile/ingest',body)[0]==200
    assert request(phone,'/v1/mobile/ingest',body)[1]['duplicate']
    def current(connection,text=None):
        deadline=time.monotonic()+210
        while time.monotonic()<deadline:
            code,state=request(connection,'/v1/agent')
            assert code==200
            docs=[d for d in state['documents'] if d['session_id']==sid and d['status']!='superseded']
            events=[e for e in state['events'] if e['session_id']==sid]
            if docs and events and (text is None or docs[0]['text']==text):return docs[0],state
            time.sleep(.5)
        raise RuntimeError('Shared processing did not finish; preserve the private workspace for diagnosis')
    first,state=current(mac)
    stale={'id':str(uuid.uuid4()),'target_id':first['id'],'expected_version':first['revision'],'action':'correct_document',
           'values':{'text':first['text']+'\n【共享同步验证注记，非原声内容】'}}
    assert request(phone,'/v1/feedback',stale)[0]==200
    second,_=current(mac,stale['values']['text'])
    bad={**stale,'id':str(uuid.uuid4())}
    assert request(mac,'/v1/feedback',bad)[0]==409
    restore={'id':str(uuid.uuid4()),'target_id':second['id'],'expected_version':second['revision'],'action':'correct_document','values':{'text':first['text']}}
    assert request(mac,'/v1/feedback',restore)[0]==200
    latest,state=current(phone,first['text'])
    assert latest['occurred_at']==first['occurred_at']==doc['occurred_at']
    # End only this isolated excerpt in the ledger. This is not a claim that
    # the original phone/card recording was saved, and sends no hardware command.
    workspace_write([("UPDATE sessions SET status='completed',ended_at=?,archive=? WHERE id=?",
                     [stop.isoformat(),json.dumps({'status':'excerpt_validation_only','source_session_id':doc['session_id'],'source_batch_id':batch_id}),sid])])
    details={'source_document_id':doc['id'],'source_session_id':doc['session_id'],'source_batch_id':batch_id,'shared_session_id':sid,
             'batch_sha256':batch['sha256'],'recorded_at':doc['occurred_at'],'sample_seconds':len(raw)/2000,
             'original_text':first['text'],'final_document_id':latest['id'],'state':state}
    private=args.output/'private.json';private.write_text(json.dumps(details,ensure_ascii=False,indent=2));private.chmod(0o600)
    result={'realPhoneRecordedAudio':True,'livePhoneSwitchedToSharedService':False,'sourceReadOnly':True,'sampleOnly':True,
            'sharedSessionId':sid,'recordedAtPreserved':True,'sampleSeconds':len(raw)/2000,'matchingExistingASRReused':not args.fresh_asr,
            'additionalASRRequests':None if args.fresh_asr else 0,'freshCloudASRRequested':args.fresh_asr,'uploadLostReceiptReplayPassed':True,'macReceivedAutomaticEvent':True,
            'phoneProtocolCorrectionVisibleToMac':True,'macProtocolCorrectionVisibleToPhone':True,'staleWriteRejected':True,
            'originalTextRestoredAfterSyncNote':True,'verification':'two independent HTTP device credentials, real model, selected phone-recorded audio',
            'limits':['Phone hardware/UI continues separate validation; no active phone configuration or service changed',
                      ('Cloud ASR was requested; content needs comparison with original sound, no word accuracy claim' if args.fresh_asr else 'Cached actual ASR was reused; this run does not establish new ASR accuracy or a new direct phone upload')]}
    (args.output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False))


if __name__=='__main__':main()

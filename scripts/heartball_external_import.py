"""File imports as timestamped third-party observations, never as ASR or self facts."""
from __future__ import annotations

import datetime as dt
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from zoneinfo import ZoneInfo

from heartball_agent_store import encoded,stable
from heartball_store import Conflict,now


def timestamp(value,time_zone):
    if isinstance(value,(float,int)) and not isinstance(value,bool):
        seconds=value/1000 if abs(value)>100_000_000_000 else value
        return dt.datetime.fromtimestamp(seconds,dt.timezone.utc).astimezone(ZoneInfo(time_zone)).isoformat()
    if not isinstance(value,str) or not value.strip():raise ValueError('Message original time is required')
    value=value.strip()
    if value.isdecimal():return timestamp(int(value),time_zone)
    parsed=dt.datetime.fromisoformat(value.replace('Z','+00:00'))
    if parsed.tzinfo is None:parsed=parsed.replace(tzinfo=ZoneInfo(time_zone))
    return parsed.isoformat()


class TableHTML(HTMLParser):
    def __init__(self):super().__init__();self.rows=[];self.row=None;self.cell=None;self.blocked=0
    def handle_starttag(self,tag,attrs):
        if tag in ('script','style'):self.blocked+=1
        if tag=='tr':self.row=[]
        if tag in ('td','th') and self.row is not None:self.cell=[]
        if tag=='br' and self.cell is not None:self.cell.append('\n')
    def handle_endtag(self,tag):
        if tag in ('script','style'):self.blocked=max(0,self.blocked-1)
        if tag in ('td','th') and self.cell is not None:
            self.row.append(''.join(self.cell).strip());self.cell=None
        if tag=='tr' and self.row is not None:self.rows.append(self.row);self.row=None
    def handle_data(self,data):
        if self.cell is not None and not self.blocked:self.cell.append(data)


def load_messages(path,*,conversation_id=None,time_zone='Asia/Shanghai'):
    path=Path(path)
    if path.stat().st_size>20_000_000:raise ValueError('Split exports larger than 20 MB before import')
    raw=path.read_text(encoding='utf-8-sig');suffix=path.suffix.lower()
    if suffix=='.json':
        data=json.loads(raw)
        if isinstance(data,dict):
            conversation_id=conversation_id or data.get('conversation_id') or data.get('chat_id')
            meta=data.get('meta',{})
            if isinstance(meta,dict):conversation_id=conversation_id or meta.get('chatId') or meta.get('name')
            rows=data.get('messages',data.get('records',data.get('data')))
        else:rows=data
        if not isinstance(rows,list):raise ValueError('JSON requires messages/records array')
    elif suffix=='.txt':
        rows=[];current=None
        pattern=re.compile(r'^\[?(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})\]?\s+([^:：]+)[:：]\s?(.*)$')
        for line in raw.splitlines():
            match=pattern.match(line)
            if match:
                current={'timestamp':match[1],'sender':match[2],'content':match[3]};rows.append(current)
            elif current is not None:current['content']+='\n'+line
            elif line.strip():raise ValueError('TXT header unsupported; expected timestamp sender: text')
    elif suffix in ('.html','.htm'):
        parser=TableHTML();parser.feed(raw)
        rows=[]
        for row in parser.rows:
            if len(row)<3:continue
            if not re.match(r'^\d{4}-\d{2}-\d{2}',row[0]):continue
            rows.append({'timestamp':row[0],'sender':row[1],'content':row[2]})
        if not rows:raise ValueError('HTML requires table columns: timestamp, sender, content')
    else:raise ValueError('Supported export formats: JSON, TXT, table HTML')
    if len(rows)>20000:raise ValueError('Split exports containing more than 20000 messages')
    normalized=[];skipped=0
    for row in rows:
        if not isinstance(row,dict):raise ValueError('Message must be an object')
        message_type=row.get('type',row.get('Type','text'))
        if message_type not in ('text','Text',0,1,'0','1'):skipped+=1;continue
        content=row.get('content',row.get('text',row.get('StrContent')))
        if not isinstance(content,str) or not content.strip():skipped+=1;continue
        if len(content)>20000:raise ValueError('Message text exceeds 20000 characters')
        sender=row.get('sender',row.get('sender_id',row.get('DisplayName',row.get('StrTalker'))))
        if isinstance(sender,dict):sender=sender.get('id') or sender.get('name')
        if not isinstance(sender,(str,int)) or not str(sender).strip():raise ValueError('Message sender is required')
        original=row.get('timestamp',row.get('time',row.get('CreateTime')))
        stamp=timestamp(original,time_zone)
        conversation=row.get('conversation_id') or row.get('chat_id') or conversation_id
        if not conversation:raise ValueError('Conversation identity is required; supply --conversation')
        identity=row.get('id',row.get('message_id',row.get('MsgSvrID')))
        value={'conversation_id':str(conversation),'sender_id':str(sender),'occurred_at':stamp,'text':content,'is_self_reported':row.get('is_self',row.get('IsSender')) in (True,1,'1')}
        value['external_id']=str(identity) if identity is not None else hashlib.sha256(encoded(value).encode()).hexdigest()
        normalized.append(value)
    normalized.sort(key=lambda r:dt.datetime.fromisoformat(r['occurred_at']))
    return {'messages':normalized,'skipped_non_text':skipped,'file_sha256':hashlib.sha256(path.read_bytes()).hexdigest()}


class ExternalImporter:
    def __init__(self,agent):
        self.agent,self.store,self.db=agent,agent.store,agent.db
        with self.store.lock,self.store.transaction():
            self.db.execute('CREATE TABLE IF NOT EXISTS external_messages(id TEXT PRIMARY KEY,account_id TEXT NOT NULL,channel TEXT NOT NULL,conversation_id TEXT NOT NULL,external_id TEXT NOT NULL,body_hash TEXT NOT NULL,original_time TEXT NOT NULL,sender_id TEXT NOT NULL,is_self_reported INTEGER NOT NULL,document_id TEXT NOT NULL,UNIQUE(account_id,channel,conversation_id,external_id))')
            self.db.execute('CREATE TABLE IF NOT EXISTS external_imports(id TEXT PRIMARY KEY,file_sha256 TEXT NOT NULL,account_id TEXT NOT NULL,channel TEXT NOT NULL,receipt TEXT NOT NULL,created_at TEXT NOT NULL)')

    def ingest(self,parsed,*,account_id,channel='wechat',analyze=False):
        if not isinstance(account_id,str) or not 0<len(account_id)<=200 or channel not in {'wechat','text_export'}:raise ValueError('Invalid import account/channel')
        if type(analyze) is not bool:raise ValueError('Explicit analyze choice required')
        messages=parsed['messages']
        if not messages:raise ValueError('No supported text messages found')
        new=[];duplicates=0;seen={}
        with self.store.lock,self.store.transaction():
            for message in messages:
                digest=hashlib.sha256(encoded(message).encode()).hexdigest()
                local_key=(message['conversation_id'],message['external_id'])
                if local_key in seen:
                    if seen[local_key]!=digest:raise Conflict('Duplicate message identity has conflicting content')
                    duplicates+=1;continue
                seen[local_key]=digest
                old=self.db.execute('SELECT body_hash FROM external_messages WHERE account_id=? AND channel=? AND conversation_id=? AND external_id=?',(account_id,channel,message['conversation_id'],message['external_id'])).fetchone()
                if old:
                    if old[0]!=digest:raise Conflict('An imported message identity changed; original is preserved')
                    duplicates+=1
                else:new.append((message,digest))
            groups=[]
            for message,digest in new:
                line=f"[{message['occurred_at']}] {message['sender_id']}: {message['text']}"
                # Message identity/time is the source unit, never the homepage
                # unit. Packing hours of chat into one source would date every
                # later issue at the first message's time. Agent windows group
                # these units semantically without losing their exact clocks.
                groups.append([(message,digest,line)])
            document_ids=[]
            for group in groups:
                first=group[0][0];sid=stable('external-session:'+account_id+':'+channel+':'+first['conversation_id']+':'+first['occurred_at'][:10]+':'+parsed['file_sha256'])
                self.db.execute("INSERT OR IGNORE INTO sessions(id,status,started_at,ended_at,batch_seconds,directory,source_kind) VALUES(?,'completed',?,?,60,?,'unknown')",(sid,first['occurred_at'],group[-1][0]['occurred_at'],str(self.store.root/'imports'/sid)))
                self.db.execute('UPDATE sessions SET started_at=CASE WHEN julianday(?)<julianday(started_at) THEN ? ELSE started_at END,ended_at=CASE WHEN julianday(?)>julianday(ended_at) THEN ? ELSE ended_at END WHERE id=?',(first['occurred_at'],first['occurred_at'],group[-1][0]['occurred_at'],group[-1][0]['occurred_at'],sid))
                if not self.db.execute('SELECT 1 FROM processing_policies WHERE session_id=?',(sid,)).fetchone():
                    self.agent.policy(sid,asr=False,agent=analyze,source_kind='unknown',occurred_at=first['occurred_at'],time_precision='original_message_timestamp')
                elif analyze and not self.agent.allowed(sid,'agent'):
                    self.agent.policy(sid,asr=False,agent=True,source_kind='unknown',occurred_at=first['occurred_at'],time_precision='original_message_timestamp')
                text='\n'.join(row[2] for row in group)
                did=stable('external-document:'+sid+':'+hashlib.sha256(text.encode()).hexdigest())
                evidence=[{'kind':'external_message','channel':channel,'account_id':account_id,'conversation_id':first['conversation_id'],'file_sha256':parsed['file_sha256'],'message_count':len(group),'first_message_at':first['occurred_at'],'last_message_at':group[-1][0]['occurred_at'],'sender_identity':'export_reported_not_voice_verified'}]
                doc=dict(id=did,kind='text',session_id=sid,input_key='external:'+did,text=text,evidence=evidence,source_kind='unknown',occurred_at=first['occurred_at'],boundary_quality='original_message_timestamp_not_audio')
                self.agent.commit_document(doc,{'title':'微信聊天记录' if channel=='wechat' else '导入文字','summary':'已保留原始消息、发送者与时间。','claims':[]})
                for message,digest,_ in group:
                    mid=stable('external-message:'+account_id+':'+channel+':'+message['conversation_id']+':'+message['external_id'])
                    self.db.execute('INSERT INTO external_messages VALUES(?,?,?,?,?,?,?,?,?,?)',(mid,account_id,channel,message['conversation_id'],message['external_id'],digest,message['occurred_at'],message['sender_id'],int(message['is_self_reported']),did))
                document_ids.append(did)
            if analyze:
                # Re-enable only this exact, explicitly selected original file.
                # A partly overlapping export must not authorize older files.
                old_sessions={r[0] for r in self.db.execute("SELECT DISTINCT d.session_id FROM external_messages m JOIN documents d ON d.id=m.document_id WHERE m.account_id=? AND m.channel=? AND json_extract(d.evidence,'$[0].file_sha256')=?",(account_id,channel,parsed['file_sha256']))}
                for sid in old_sessions:
                    if not self.agent.allowed(sid,'agent'):
                        first_time=self.db.execute('SELECT started_at FROM sessions WHERE id=?',(sid,)).fetchone()[0]
                        self.agent.policy(sid,asr=False,agent=True,source_kind='unknown',occurred_at=first_time,time_precision='original_message_timestamp')
            selected_ids=[stable('external-message:'+account_id+':'+channel+':'+m['conversation_id']+':'+m['external_id']) for m in messages]
            policy_state=self.db.execute('SELECT min(p.agent_allowed),sum(CASE WHEN p.agent_allowed=0 THEN 1 ELSE 0 END) FROM external_messages m JOIN documents d ON d.id=m.document_id JOIN processing_policies p ON p.session_id=d.session_id WHERE m.id IN (SELECT value FROM json_each(?))',(encoded(selected_ids),)).fetchone()
            receipt={'documents':document_ids,'imported_messages':len(new),'duplicates':duplicates,'skipped_non_text':parsed.get('skipped_non_text',0),'asr_jobs_created':0,'personal_identity':'export_reported_only','analysis_requested':analyze,'analysis_enabled':bool(policy_state[0]),'analysis_blocked_messages':policy_state[1] or 0}
            iid=stable('external-import:'+account_id+':'+channel+':'+parsed['file_sha256'])
            self.db.execute('INSERT OR IGNORE INTO external_imports VALUES(?,?,?,?,?,?)',(iid,parsed['file_sha256'],account_id,channel,encoded(receipt),now()))
            return receipt

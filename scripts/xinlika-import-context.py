#!/usr/bin/env python3
"""Import explicit chat exports without ASR; credentials/account databases are never inspected."""
import argparse
import json
from pathlib import Path
from heartball_store import Store
from heartball_agent_store import AgentStore
from heartball_external_import import ExternalImporter,load_messages

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file',type=Path)
    destination=parser.add_mutually_exclusive_group(required=True)
    destination.add_argument('--root',type=Path);destination.add_argument('--connection',type=Path)
    parser.add_argument('--account',required=True);parser.add_argument('--conversation')
    parser.add_argument('--time-zone',default='Asia/Shanghai');parser.add_argument('--analyze',action='store_true')
    args=parser.parse_args()
    parsed=load_messages(args.file,conversation_id=args.conversation,time_zone=args.time_zone)
    if args.connection:
        import base64
        from heartball_mcp import CloudContextReader
        reader=CloudContextReader(args.connection)
        try:
            result=reader.client.post(reader.base+'/v1/context/import',json={'filename':args.file.name,
                'content_base64':base64.b64encode(args.file.read_bytes()).decode(),'account_id':args.account,
                'conversation_id':args.conversation,'time_zone':args.time_zone,'analyze':args.analyze},timeout=90)
            result.raise_for_status();print(json.dumps(result.json(),ensure_ascii=False));return
        finally:reader.client.close()
    store=Store(args.root)
    try:print(json.dumps(ExternalImporter(AgentStore(store)).ingest(parsed,account_id=args.account,analyze=args.analyze),ensure_ascii=False))
    finally:store.db.close()

if __name__=='__main__':main()

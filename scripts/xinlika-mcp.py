#!/usr/bin/env python3
"""Read-only MCP for external agents, or explicitly scoped internal analysis tools."""
import argparse
import json
from pathlib import Path

from heartball_agent_runtime import AgentDomain,AgentTask,ContextReader,readonly_database
from heartball_mcp import CloudContextReader,create_mcp


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    source=parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--database',type=Path);source.add_argument('--connection',type=Path)
    parser.add_argument('--analysis-task',type=Path)
    parser.add_argument('--audit',type=Path);parser.add_argument('--external-config',type=Path)
    args=parser.parse_args()
    domain=task=store=None
    if args.analysis_task:
        if not args.database:parser.error('Internal analysis requires a local isolated database')
        root=args.database.resolve().parent
        if not (root/'.agent-runtime-owned').is_file():parser.error('Analysis requires a dedicated runtime-owned root')
        from heartball_store import Store
        from heartball_agent_store import AgentStore
        store=Store(root);domain=AgentDomain(AgentStore(store))
        reader=ContextReader(store.db);task=AgentTask.model_validate_json(args.analysis_task.read_text())
    elif args.connection:reader=CloudContextReader(args.connection)
    else:reader=ContextReader(readonly_database(args.database))
    external=json.loads(args.external_config.read_text()).get('servers',{}) if args.external_config else None
    try:create_mcp(reader,domain=domain,task=task,audit=args.audit,external_servers=external).run(transport='stdio')
    finally:
        if store:store.db.close()
        elif args.database:reader.db.close()
        else:reader.client.close()


if __name__=='__main__':main()

#!/usr/bin/env python3
"""Create private config and two device identities without printing credentials."""
import argparse
import json
import os
import sys
from pathlib import Path
from urllib.parse import urlparse
from heartball_store import Store
from heartball_agent_store import AgentStore
from heartball_shared import SharedWorkspace

ROOT = Path(__file__).resolve().parents[1]


def private_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        json.dump(value, file, ensure_ascii=False, indent=2)
        file.write('\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', default='http://127.0.0.1:18778')
    parser.add_argument('--model-url', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--model-key-env', default='XINLIKA_MODEL_API_KEY')
    parser.add_argument('--asr-url')
    parser.add_argument('--asr-model')
    parser.add_argument('--asr-key-env', default='XINLIKA_ASR_API_KEY')
    parser.add_argument('--processing-profile', choices=['xinlika-events-v6'], help='Opt in to versioned incremental Agent; install requirements-agent-runtime.txt first')
    parser.add_argument('--workspace', type=Path, default=ROOT / '.build/workspace')
    parser.add_argument('--config-dir', type=Path, default=ROOT / 'private-config')
    args = parser.parse_args()
    address = urlparse(args.base_url)
    if not address.hostname or address.username or address.password or address.query or address.fragment:
        parser.error('Invalid base URL')
    import ipaddress
    try: private = ipaddress.ip_address(address.hostname).is_private
    except ValueError: private = address.hostname == 'localhost' or address.hostname.endswith('.local')
    if address.scheme != 'https' and not (address.scheme == 'http' and private):
        parser.error('Device URL requires HTTPS or private HTTP')
    if bool(args.asr_url) != bool(args.asr_model): parser.error('Provide both --asr-url and --asr-model')
    files = [args.config_dir / name for name in ['processing.json', 'connection-mac.json', 'connection-iphone.json']]
    if any(path.exists() for path in files): parser.error('Config exists; edit it explicitly or choose a new --config-dir')
    config = {'model': {'base_url': args.model_url, 'api_key_env': args.model_key_env, 'model': args.model}}
    if args.asr_url:
        config['asr'] = {'base_url': args.asr_url, 'api_key_env': args.asr_key_env, 'model': args.asr_model}
    if args.processing_profile:
        config['agent_runtime'] = {
            'runtime': 'deepseek-harness', 'python': sys.executable, 'client_python': sys.executable,
            'processing_profile': args.processing_profile, 'model': config.pop('model')}
    store = Store(args.workspace)
    workspace = SharedWorkspace(store, AgentStore(store))
    created = []
    try:
        private_write(files[0], config)
        for name, path in zip(['mac', 'iphone'], files[1:]):
            device = workspace.provision(name)
            created.append(device['deviceId'])
            private_write(path, {'baseURL': args.base_url, **device})
    except BaseException:
        for identity in created: workspace.revoke(identity)
        raise
    finally: store.db.close()
    print('Private config: ' + str(files[0]))
    print('Mac connection: ' + str(files[1]))
    print('iPhone connection: ' + str(files[2]))
    print('Configure the named API-key environment variables before starting the server. No keys were saved or printed.')


if __name__ == '__main__': main()

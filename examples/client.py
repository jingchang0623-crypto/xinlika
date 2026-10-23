#!/usr/bin/env python3
"""Small authenticated client; tokens are read from a local ignored file."""
import argparse
import json
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--connection', type=Path, default=Path('private-config/connection.json'))
    commands = parser.add_subparsers(dest='command', required=True)
    text = commands.add_parser('text'); text.add_argument('text'); text.add_argument('--occurred-at', required=True)
    state = commands.add_parser('state'); state.add_argument('--day')
    ask = commands.add_parser('ask'); ask.add_argument('question')
    args = parser.parse_args()
    connection = json.loads(args.connection.read_text())
    body = None
    if args.command == 'text':
        path = '/v1/dialogues/text'
        body = {'id': str(uuid.uuid4()), 'session_id': str(uuid.uuid4()), 'text': args.text, 'occurred_at': args.occurred_at}
    elif args.command == 'ask':
        path = '/v1/memory/ask'; body = {'id': str(uuid.uuid4()), 'question': args.question}
    else:
        path = '/v1/agent' + ('?' + urlencode({'day': args.day}) if args.day else '')
    request = Request(connection['baseURL'].rstrip('/') + path,
                      data=json.dumps(body).encode() if body is not None else None,
                      headers={'Authorization': 'Bearer ' + connection['token'], 'Content-Type': 'application/json'})
    try:
        with urlopen(request, timeout=30) as response:
            print(json.dumps(json.load(response), ensure_ascii=False, indent=2))
    except HTTPError as error:
        with error:
            print('HTTP ' + str(error.code) + ': ' + error.read().decode(), flush=True)
        raise SystemExit(1)


if __name__ == '__main__':
    main()

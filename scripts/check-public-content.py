#!/usr/bin/env python3
"""Fail closed on private artifact paths and common credential formats.

Print locations and rule names only. Use alongside a full secret scanner;
neither tool can prove that arbitrary prose contains no private information.
"""
import argparse
import hashlib
from pathlib import PurePosixPath
import re
import subprocess
import sys

SAFE_SCREENSHOTS={'docs/validation/xinlika-interest-2026-10-26/feedback-preview.png'}
SAFE_PUBLIC_MEDIA={'assets/launch/native-walkthrough.mp4':'25ebbaa105afee11a80e478bac994fb9abff05aed7c21ce421277468d69fd42e'}
PRIVATE_SUFFIXES={'.wav','.pcm','.opus','.ogg','.m4a','.caf','.aac','.mp3','.flac',
                  '.cb08','.sqlite','.sqlite3','.db','.p8','.p12','.pem','.key',
                  '.mobileprovision','.ipa','.mp4','.mov'}
PATTERNS={
    'provider-credential':re.compile(rb'\b(?:sk-[A-Za-z0-9_-]{24,}|ark-[0-9a-f-]{30,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{30,})\b'),
    'signed-jwt':re.compile(rb'\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}'),
    'private-key':re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'private-chat-link':re.compile(rb'codex://threads/[0-9a-f-]{30,}'),
}


def private_path(name):
    p=PurePosixPath(name)
    if name in SAFE_PUBLIC_MEDIA:return False
    if any(x in {'.build','.venv','venv','node_modules','research','xcuserdata'} for x in p.parts):return True
    if p.suffix.lower() in PRIVATE_SUFFIXES or '-private.' in p.name:return True
    if p.name.startswith('.env') and p.name!='.env.example':return True
    if name=='Config/Local.xcconfig':return True
    return p.parts[0]=='docs' and p.suffix.lower() in {'.png','.jpg','.jpeg','.webp'} and name not in SAFE_SCREENSHOTS


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged',action='store_true',help='Read the complete Git index, not working-tree content')
    args=parser.parse_args()
    paths=subprocess.check_output(['git','ls-files','-z']).decode().split('\0')
    findings=[];checked=0
    for name in filter(None,paths):
        checked+=1
        if private_path(name):findings.append((name,0,'private-artifact-path'));continue
        try:
            data=subprocess.check_output(['git','show',':'+name]) if args.staged else __import__('pathlib').Path(name).read_bytes()
        except (OSError,subprocess.CalledProcessError):
            findings.append((name,0,'unreadable-content'));continue
        if name in SAFE_PUBLIC_MEDIA and hashlib.sha256(data).hexdigest()!=SAFE_PUBLIC_MEDIA[name]:
            findings.append((name,0,'unreviewed-public-media'));continue
        if b'\0' in data[:8192]:continue
        for rule,pattern in PATTERNS.items():
            for match in pattern.finditer(data):findings.append((name,data.count(b'\n',0,match.start())+1,rule))
    for name,line,rule in findings:print(f'{name}:{line}: {rule}',file=sys.stderr)
    print(f'Checked {checked} indexed files; {len(findings)} findings.')
    return int(bool(findings))


if __name__=='__main__':raise SystemExit(main())

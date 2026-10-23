#!/usr/bin/env python3
"""Export explicitly named synthetic XCTest screenshots, without device identifiers."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from zoneinfo import ZoneInfo

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--result', type=Path, required=True)
args = parser.parse_args()
summary = json.loads(subprocess.check_output([
    'xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
    '--path', str(args.result.resolve())], text=True))
if summary.get('result') != 'Passed' or summary.get('failedTests') != 0:
    raise SystemExit('Only a fully passed test result can supply the successful demo')
root = Path(__file__).resolve().parents[1]
dest = root / 'assets' / 'launch'
dest.mkdir(parents=True, exist_ok=True)
names = {'01 Synthetic native event': 'native-event.png',
         '02 Synthetic native literal source': 'native-source.png',
         '03 Synthetic native corrected answer': 'native-answer.png'}
records = []
with tempfile.TemporaryDirectory(prefix='xinlika-media-') as directory:
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path',
                    str(args.result.resolve()), '--output-path', directory], check=True)
    directory = Path(directory)
    manifest = json.loads((directory / 'manifest.json').read_text())
    for title, filename in names.items():
        found = [(test, item) for test in manifest for item in test['attachments']
                 if item['suggestedHumanReadableName'].startswith(title + '_')]
        if len(found) != 1:
            raise SystemExit(f'Expected exactly one successful attachment: {title}')
        test, item = found[0]
        if item['isAssociatedWithFailure']:
            raise SystemExit('Do not export failed-test screenshots as a successful demo')
        original = directory / item['exportedFileName']
        shutil.copyfile(original, dest / filename)
        records.append({'file': filename, 'attachment': title,
                        'test': test['testIdentifier'],
                        'captured_at': datetime.fromtimestamp(item['timestamp'], ZoneInfo('Asia/Shanghai')).isoformat(),
                        'sha256': hashlib.sha256(original.read_bytes()).hexdigest()})
(dest / 'provenance.json').write_text(json.dumps({
    'scenario': 'Synthetic inputs and fixed model responses; actual native UI/HTTP/SQLite/LangGraph',
    'capture_dates': sorted({r['captured_at'][:10] for r in records}),
    'license': 'GPL-3.0-only',
    'originals_unmodified': True,
    'files': records}, ensure_ascii=False, indent=2) + '\n')
print('Exported three unmodified synthetic screenshots; device identifiers omitted.')

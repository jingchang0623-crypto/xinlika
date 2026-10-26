#!/usr/bin/env python3
"""Export an allowlisted build context; audio, private config and .build never enter it."""
import argparse
from pathlib import Path
import shutil

project=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
(out/'scripts').mkdir()
shutil.copytree(project/'prompts',out/'prompts')
for path in (project/'scripts').glob('heartball*.py'):shutil.copy2(path,out/'scripts'/path.name)
for name in ('xinlika-mcp.py','xinlika-runtime-worker.py','xinlika-import-context.py'):
    shutil.copy2(project/'scripts'/name,out/'scripts'/name)
for name in ('requirements-heartball.txt','requirements-agent-runtime.txt'):
    shutil.copy2(project/name,out/name)
shutil.copy2(project/'scripts/analyze-cb08-capture.py',out/'scripts/analyze-cb08-capture.py')
shutil.copy2(project/'requirements-heartball.lock',out/'requirements-heartball.lock')
for name in ('voxgate-file-chunks.patch','voxgate-empty-final.patch'):
    shutil.copy2(project/'scripts/patches'/name,out/name)
for name in ('Dockerfile','entrypoint.py','compose.yaml','Dockerfile.acoustics',
             'requirements-acoustics-linux-amd64.lock','compose.acoustics.yaml','ACOUSTICS.md','acoustic-models.json'):
    shutil.copy2(project/'deployment/shared-server'/name,out/name)
print(f'Exported source-only server context: {out}')

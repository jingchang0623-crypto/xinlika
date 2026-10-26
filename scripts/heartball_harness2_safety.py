"""Local-only experiment reuse guards and reproducibility fingerprints."""
import copy
import hashlib
import json
import os
from pathlib import Path


def finished_or_claim(root):
    """Never reset an existing paid ledger, including after interruption.

    The exclusive marker intentionally survives the process. Finished runs are
    read-only; unfinished runs require a new root, preserving all prior costs.
    """
    root=Path(root)
    result=root/'experiment-private.json'
    if result.exists():return json.loads(result.read_text())
    if (root/'provider-ledger').exists():
        raise ValueError('Existing provider ledger: preserve it and use a NEW experiment root')
    marker=root/'optimizer-started.json'
    try:
        fd=os.open(marker,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    except FileExistsError:
        raise ValueError('Experiment already claimed; use a NEW root after an interrupted run') from None
    with os.fdopen(fd,'w') as f:json.dump({'schema':1,'pid':os.getpid()},f)
    # Another invocation may have created an old ledger before our marker.
    if (root/'provider-ledger').exists():
        raise ValueError('Provider ledger appeared during claim; refusing to overwrite it')
    return None


def engine_snapshot(folder):
    folder=Path(folder)
    paths=sorted(folder.glob('heartball*.py'))+[folder/'replay-xinlika-incremental.py']
    return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def semantic_configuration(configuration):
    """Private endpoints/credentials never enter the public cache identity.

    The endpoint is hashed (the full configuration remains private); keys and
    their file paths do not affect the requested model's semantic contract.
    """
    value=copy.deepcopy({k:configuration.get(k) for k in
        ('model','extra_body','max_tokens','structured_incremental','cross_conversation_review')})
    value['endpoint_sha256']=hashlib.sha256(str(configuration.get('base_url','')).encode()).hexdigest()
    return value


def evaluation_registration(root,evaluator=None):
    root=Path(root)
    paths=[root/'evaluation/dev-labels-private.json',root/'evaluation/holdout-labels-private.json',
        Path(evaluator) if evaluator else Path(__file__).with_name('heartball_harness2_evaluation.py')]
    return {'files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}


def verify_evaluation_registration(root):
    path=Path(root)/'evaluation/freeze.json'
    frozen=json.loads(path.read_text())
    if frozen['files']!=evaluation_registration(root)['files']:
        raise ValueError('Registered checks changed; use a NEW experiment before optimization')


def failed_attempt_evidence(workspace):
    """Supply the actual rejected proposal, not only its validation error."""
    receipts=list(Path(workspace).glob('**/attempt-*/receipt.json'))
    failed=[p for p in receipts if json.loads(p.read_text()).get('status')!='completed']
    if not failed:return {}
    folder=max(failed,key=lambda p:p.stat().st_mtime_ns).parent
    answers=sorted(folder.glob('answer-*-private.json'))
    paths=[folder/'context-private.json',folder/'receipt.json']+(answers[-1:] if answers else [])
    result={}
    for p in paths:
        if not p.exists():continue
        data=p.read_bytes()
        result[p.name]=json.loads(data) if len(data)<=200000 else {'omitted_oversized_bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
    return result

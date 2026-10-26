"""Explicit, verified processing profiles. No default switch or service writes."""
import copy
import hashlib
import json
from pathlib import Path
import re

from heartball_skill_bundle import load_bundle,PROJECT


def apply_processing_profile(configuration,project=PROJECT):
    result=copy.deepcopy(configuration);name=result.get('processing_profile')
    if not name:return result
    if not isinstance(name,str) or not re.fullmatch(r'xinlika-events-v[0-9]+',name):raise ValueError('Unknown processing profile name')
    project=Path(project).resolve()
    def resource(relative):
        path=(project/relative).resolve()
        if not path.is_relative_to(project):raise ValueError('Profile resource escapes project')
        return path
    profile=json.loads(resource('prompts/profiles/'+name+'.json').read_text())
    if profile.get('schema')!=1 or profile.get('accepted') is not True or profile.get('name')!=name:raise ValueError('Profile has not passed validation')
    evidence=resource(profile['validation_file']).read_bytes()
    if hashlib.sha256(evidence).hexdigest()!=profile['validation_sha256']:raise ValueError('Profile validation evidence changed')
    accepted=json.loads(evidence)
    if accepted.get('accepted_for_opt_in_incremental_profile') is not True or accepted.get('candidate_bundle_sha256')!=profile['bundle_sha256']:raise ValueError('Validation does not approve this bundle')
    bundle=load_bundle(resource(profile['bundle']))
    if bundle.digest!=profile['bundle_sha256']:raise ValueError('Approved Skill bundle changed')
    for relative,expected in profile.get('engine_sha256',{}).items():
        if hashlib.sha256(resource(relative).read_bytes()).hexdigest()!=expected:raise ValueError('Approved processing engine changed')
    if set(profile['settings'])-{'analysis_strategy','rolling_review','cross_conversation_review','complete_events'} or set(profile['model_settings'])-{'structured_incremental'}:raise ValueError('Profile cannot override endpoints, credentials or unrelated runtime settings')
    result.update(profile['settings'])
    result['model']={**result.get('model',{}),**profile['model_settings'],'skill_bundle':str(bundle.manifest)}
    return result

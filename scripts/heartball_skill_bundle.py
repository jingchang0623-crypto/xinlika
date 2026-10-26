"""Immutable, content-addressed prompt resources. No service activation or writes."""
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from types import MappingProxyType

PROJECT=Path(__file__).resolve().parents[1]
DEFAULT=PROJECT/'prompts/bundles/xinlika-events-v1.json'
FILES={'incremental':'skills/xinlika-incremental/SKILL.md','rolling':'skills/xinlika-rolling/SKILL.md','review':'skills/xinlika-rolling-review/SKILL.md'}


@dataclass(frozen=True)
class SkillBundle:
    version: str
    digest: str
    texts: object
    manifest: Path

    def text(self,name):
        text=self.texts[name]
        # Preserve the historical incremental request byte-for-byte. The newly
        # extracted rolling Skills have metadata separate from their body.
        if name!='incremental' and text.startswith('---\n'):
            text=text.split('---\n',2)[2].lstrip('\n').rstrip('\n')
        return text


def load_bundle(manifest=None):
    path=Path(manifest or DEFAULT).expanduser().resolve();value=json.loads(path.read_text())
    if value.get('schema')!=1 or value.get('files')!=FILES:raise ValueError('Unsupported Skill bundle contract')
    root=(path.parent/value.get('root','.')).resolve();texts={};hashes={}
    for name,rel in FILES.items():
        target=(root/rel).resolve()
        if not target.is_relative_to(root):raise ValueError('Skill path escapes bundle')
        data=target.read_bytes();digest=hashlib.sha256(data).hexdigest()
        if value['sha256'].get(name)!=digest:raise ValueError('Skill bundle digest mismatch: '+name)
        text=data.decode()
        if not text.strip() or len(text)>24000:raise ValueError('Empty or oversized Skill')
        texts[name]=text;hashes[name]=digest
    digest=hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest()
    return SkillBundle(value['version'],digest,MappingProxyType(texts),path)


def publish_manifest(root,version):
    """Only the isolated experiment materializer calls this; never activates it."""
    root=Path(root).resolve()
    value=dict(schema=1,version=version,root='.',files=FILES,sha256={name:hashlib.sha256((root/rel).read_bytes()).hexdigest() for name,rel in FILES.items()})
    target=root/'bundle.json';target.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n');target.chmod(0o600)
    return load_bundle(target)

"""Opt-in profile loading and isolation from credentials and unrelated config."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from heartball_processing_profiles import apply_processing_profile
from heartball_skill_bundle import PROJECT


class ProfileTests(unittest.TestCase):
    def test_default_configuration_and_caller_remain_unchanged(self):
        cfg={'runtime':'hermes','model':{'model':'example','api_key_file':'private-path'},'asr':False}
        self.assertEqual(apply_processing_profile(cfg),cfg)
        configured=apply_processing_profile({**cfg,'processing_profile':'xinlika-events-v6'})
        self.assertEqual(cfg['model'],{'model':'example','api_key_file':'private-path'})
        self.assertEqual(configured['model']['api_key_file'],'private-path');self.assertFalse(configured['asr'])
        self.assertTrue(configured['cross_conversation_review']);self.assertEqual(configured['analysis_strategy'],'incremental')
        self.assertIn('xinlika-events-v6',configured['model']['skill_bundle'])
        self.assertEqual(apply_processing_profile(configured),configured)
    def test_profile_names_cannot_escape_registry(self):
        with self.assertRaises(ValueError):apply_processing_profile({'processing_profile':'../../private'})
    def test_modified_evidence_or_bundle_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);shutil.copytree(PROJECT/'prompts/profiles',root/'prompts/profiles');shutil.copytree(PROJECT/'prompts/versions/xinlika-events-v6',root/'prompts/versions/xinlika-events-v6')
            profile=json.loads((root/'prompts/profiles/xinlika-events-v6.json').read_text())
            for rel in profile.get('engine_sha256',{}):
                p=root/rel;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(PROJECT/rel,p)
            cfg={'processing_profile':'xinlika-events-v6'}
            self.assertTrue(apply_processing_profile(cfg,root)['rolling_review'])
            p=root/'prompts/versions/xinlika-events-v6/skills/xinlika-rolling/SKILL.md';p.write_text('modified')
            with self.assertRaises(ValueError):apply_processing_profile(cfg,root)
    def test_engine_identity_is_pinned_as_well_as_prompt_content(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);shutil.copytree(PROJECT/'prompts/profiles',root/'prompts/profiles');shutil.copytree(PROJECT/'prompts/versions/xinlika-events-v6',root/'prompts/versions/xinlika-events-v6')
            profile=json.loads((root/'prompts/profiles/xinlika-events-v6.json').read_text())
            for rel in profile['engine_sha256']:
                p=root/rel;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(PROJECT/rel,p)
            p=root/'scripts/heartball_incremental_topics.py';p.write_text(p.read_text()+'\n# changed engine\n')
            with self.assertRaisesRegex(ValueError,'engine changed'):apply_processing_profile({'processing_profile':'xinlika-events-v6'},root)
    def test_unapproved_profile_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);folder=root/'prompts/profiles';folder.mkdir(parents=True);(folder/'xinlika-events-v3.json').write_text(json.dumps({'schema':1,'name':'xinlika-events-v3','accepted':False}))
            with self.assertRaises(ValueError):apply_processing_profile({'processing_profile':'xinlika-events-v3'},root)


if __name__=='__main__':unittest.main()

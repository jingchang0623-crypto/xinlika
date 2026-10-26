"""Local ASR lifecycle checks without recording, network calls, or provider credentials."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location('heartball_launcher', Path(__file__).with_name('run-heartball-lab.py'))
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class LocalASRLifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = self.root / '.build/voxgate-evaluation/runtime/config.json'
        self.config.parent.mkdir(parents=True)
        self.config.write_text(json.dumps({'server': {'host': '127.0.0.1', 'port': 18765, 'auth_token': 'fixture'}}))
        self.processing = self.root / 'processing.json'
        self.processing.write_text(json.dumps({'voxgate_config': str(self.config)}))
        self.project = patch.object(launcher, 'PROJECT', self.root)
        self.project.start()

    def tearDown(self):
        self.project.stop()
        self.temp.cleanup()

    def test_healthy_listener_is_reused_without_starting_another_service(self):
        response = MagicMock()
        response.__enter__.return_value.status = 200
        with patch.object(launcher.urllib.request, 'urlopen', return_value=response), patch.object(launcher.subprocess, 'Popen') as spawn:
            launcher.ensure_local_asr(self.processing)
            spawn.assert_not_called()

    def test_refused_authentication_preserves_the_existing_listener(self):
        error = urllib.error.HTTPError('http://127.0.0.1/health', 401, 'fixture', {}, None)
        with patch.object(launcher.urllib.request, 'urlopen', side_effect=error), patch.object(launcher.subprocess, 'Popen') as spawn:
            with self.assertRaises(RuntimeError):
                launcher.ensure_local_asr(self.processing)
            spawn.assert_not_called()
        error.close()

    def test_missing_local_bridge_is_started_then_health_checked(self):
        response = MagicMock()
        response.__enter__.return_value.status = 200
        with patch.object(launcher.urllib.request, 'urlopen', side_effect=[OSError('fixture unavailable'), response]), patch.object(launcher.subprocess, 'Popen') as spawn:
            launcher.ensure_local_asr(self.processing)
            self.assertEqual(spawn.call_count, 1)
            self.assertIn('serve', spawn.call_args.args[0])

    def test_other_configurations_are_not_automatically_launched(self):
        self.processing.write_text(json.dumps({'voxgate_config': str(self.root / 'other.json')}))
        with patch.object(launcher.urllib.request, 'urlopen') as network, patch.object(launcher.subprocess, 'Popen') as spawn:
            launcher.ensure_local_asr(self.processing)
            network.assert_not_called()
            spawn.assert_not_called()


if __name__ == '__main__':
    unittest.main()

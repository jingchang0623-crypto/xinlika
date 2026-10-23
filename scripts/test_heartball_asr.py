import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from heartball_asr import CompatibleASR


class ASRTests(unittest.TestCase):
    @patch.dict(os.environ, {'XINLIKA_TEST_ASR_KEY': 'test-key-not-a-credential'})
    def test_strict_container_and_provider_contract_preserve_empty_result(self):
        with tempfile.TemporaryDirectory() as d, patch('heartball_asr.OpenAI') as client:
            adapter = CompatibleASR({'base_url': 'http://127.0.0.1:12345/v1',
                                     'api_key_env': 'XINLIKA_TEST_ASR_KEY', 'model': 'fixture-asr'})
            raw = Path(d) / 'raw.bin'; raw.write_bytes(b'a' * 80)
            client.return_value.audio.transcriptions.create.return_value = SimpleNamespace(model_dump=lambda: {'text': ''})
            result = adapter.transcribe(raw, Path(d) / 'result.json')
            self.assertEqual(result['text'], '')
            self.assertEqual((Path(d) / 'result.ogg').read_bytes()[:4], b'OggS')
            raw.write_bytes(b'bad-frame')
            with self.assertRaises(ValueError):
                adapter.transcribe(raw, Path(d) / 'invalid.json')
            self.assertEqual(client.return_value.audio.transcriptions.create.call_count, 1)

    def test_endpoint_restrictions_precede_credential_access(self):
        for endpoint in ['http://public.example/v1', 'https://name:secret@example.com/v1', 'file:///tmp/test']:
            with self.assertRaises(ValueError):
                CompatibleASR({'base_url': endpoint, 'api_key_env': 'UNSET_TEST_KEY', 'model': 'fixture'})


if __name__ == '__main__': unittest.main()

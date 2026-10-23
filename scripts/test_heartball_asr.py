import os
from pathlib import Path
import tempfile
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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

    @patch.dict(os.environ, {'XINLIKA_TEST_ASR_KEY': 'local-protocol-fixture'})
    def test_actual_sdk_posts_ogg_multipart_and_decodes_json(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                payload = self.rfile.read(int(self.headers['Content-Length']))
                requests.append((self.path, self.headers['Authorization'], payload))
                data = json.dumps({'text': '合成接口响应，不是音频准确率结果。'}).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            with tempfile.TemporaryDirectory() as d:
                raw = Path(d) / 'raw.bin'; raw.write_bytes(b'a' * 80)
                adapter = CompatibleASR({'base_url': f'http://127.0.0.1:{server.server_port}/v1',
                                         'api_key_env': 'XINLIKA_TEST_ASR_KEY', 'model': 'test-asr'})
                result = adapter.transcribe(raw, Path(d) / 'result.json')
                self.assertIn('合成接口响应', result['text'])
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0][:2], ('/v1/audio/transcriptions', 'Bearer local-protocol-fixture'))
                self.assertIn(b'OggS', requests[0][2])
                self.assertIn(b'test-asr', requests[0][2])
                adapter.client.close()
        finally:
            server.shutdown(); server.server_close(); thread.join()


if __name__ == '__main__': unittest.main()

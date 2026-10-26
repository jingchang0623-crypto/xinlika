#!/usr/bin/env python3
"""Local HTTP contract tests using a synthetic capture, no hardware or ASR."""
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid

from heartball_store import Store

spec = importlib.util.spec_from_file_location("heartball_service", Path(__file__).resolve().parents[1] / "clients/tools/local-service.py")
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name))
        self.sid = str(uuid.uuid4())
        session = self.store.create_session(self.sid)
        self.store.update_session(self.sid, status="recording")
        folder = Path(session["directory"]) / "probe"
        folder.mkdir()
        (folder / "audio-test-AE22.bin").write_bytes(b"a" * 400)
        self.store.ingest(self.sid, {"audioFile": "audio-test-AE22.bin", "audioOffset": 0, "audioBytes": 40, "time": "synthetic"})
        class NoHardware:
            def start(self, *args): raise AssertionError("Focus API must not start hardware")
            def stop(self, *args): raise AssertionError("Focus API must not stop hardware")
        fake = NoHardware()
        fake.store = self.store
        self.server = service.Server(("127.0.0.1", 0), service.Handler)
        self.server.engine = fake
        self.server.token = "synthetic-test-token"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.thread.join(timeout=3)
        self.server.server_close()
        self.store.db.close()
        self.temp.cleanup()

    def request(self, path, body=None, authenticated=True):
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["Authorization"] = "Bearer synthetic-test-token"
        request = urllib.request.Request(self.base + path,
            data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=3)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.code, json.load(response)

    def test_authentication_before_capture_mutations(self):
        self.assertEqual(self.request("/v1/state", authenticated=False)[0], 401)
        self.assertEqual(self.request("/v1/capture/stop", {"id": self.sid}, authenticated=False)[0], 401)
        self.assertEqual(self.store.state()["session"]["status"], "recording")

    def test_focus_contract_and_retry_never_calls_hardware(self):
        fid = str(uuid.uuid4())
        body = {"id": fid, "session_id": self.sid}
        self.assertEqual(self.request("/v1/focus/start", body)[0], 200)
        self.assertEqual(self.request("/v1/focus/start", body)[0], 200)
        self.store.ingest(self.sid, {"audioFile": "audio-test-AE22.bin", "audioOffset": 40, "audioBytes": 360, "time": "synthetic"})
        self.assertEqual(self.request("/v1/focus/end", {"id": fid})[0], 200)
        code, state = self.request("/v1/focus/end", {"id": fid})
        self.assertEqual(code, 200)
        self.assertEqual(len(state["focuses"]), 1)
        self.assertEqual(state["session"]["status"], "recording")
        self.assertFalse(state["asrEnabled"])

    def test_unknown_record_and_path_are_rejected(self):
        self.assertEqual(self.request("/v1/focus/end", {"id": str(uuid.uuid4())})[0], 400)
        self.assertEqual(self.request("/v1/does-not-exist", {})[0], 404)


if __name__ == "__main__":
    unittest.main()

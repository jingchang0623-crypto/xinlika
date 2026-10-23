"""Shared HTTP transport extracted from the local prototype; no hardware control."""
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from heartball_store import Conflict, identifier, now
PROJECT = Path(__file__).resolve().parents[1]

class Server(ThreadingHTTPServer):
    daemon_threads = True
    playback_lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        if "asrEnabled" in body:
            body["captureLimitSeconds"] = getattr(self.server.engine, "max_seconds", 1800)
            processor = getattr(self.server, "processor", None)
            body["processingConfigured"] = processor is not None and processor.asr is not None
            body["agentConfigured"] = processor is not None and processor.model is not None
            if processor and body.get("session"):
                body["asrEnabled"] = processor.agent.allowed(body["session"]["id"], "asr")
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        expected = "Bearer " + self.server.token
        return hmac.compare_digest(self.headers.get("Authorization", "").encode(), expected.encode())

    def do_GET(self):
        if not self.authorized():
            return self.reply(401, {"error": "Unauthorized"})
        processor = getattr(self.server, "processor", None)
        path = urlparse(self.path)
        if path.path == "/v1/agent" and processor:
            query = parse_qs(path.query)
            try:
                state = processor.agent.state(day=query.get('day', [None])[0], time_zone=query.get('time_zone', ['Asia/Shanghai'])[0])
            except ValueError as error:
                return self.reply(400, {'error': str(error)})
            state["workerError"] = processor.last_error
            return self.reply(200, state)
        if path.path == "/v1/audio" and processor:
            try:
                bid = identifier(parse_qs(path.query)["batch_id"][0])
                with self.server.engine.store.lock:
                    row = self.server.engine.store.db.execute("SELECT filename,sha256 FROM batches WHERE id=?", (bid,)).fetchone()
                    if row is None:
                        raise ValueError("Unknown audio")
                    raw = Path(row["filename"])
                    if hashlib.sha256(raw.read_bytes()).hexdigest() != row["sha256"]:
                        raise ValueError("Changed audio")
                with self.server.playback_lock:
                    out = self.server.engine.store.root / "playback"
                    out.mkdir(mode=0o700, exist_ok=True)
                    ogg = out / (row["sha256"] + ".ogg")
                    if not ogg.exists():
                        spec = importlib.util.spec_from_file_location("playback_codec", PROJECT / "scripts/analyze-cb08-capture.py")
                        codec = importlib.util.module_from_spec(spec); spec.loader.exec_module(codec)
                        codec.wrap_cb08(raw, ogg); ogg.chmod(0o600)
                    wav = ogg.with_suffix(".wav")
                    if not wav.exists():
                        temp = wav.with_suffix(".tmp.wav")
                        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-xerror", "-y", "-i", str(ogg), "-ar", "16000", "-ac", "1", str(temp)], check=True, capture_output=True, timeout=30)
                        temp.chmod(0o600); os.replace(temp, wav)
                data = wav.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "audio/wav")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers(); self.wfile.write(data)
                return
            except (ValueError, KeyError):
                return self.reply(400, {"error": "Unknown audio evidence"})
        if self.path != "/v1/state":
            return self.reply(404, {"error": "Not found"})
        self.reply(200, self.server.engine.store.state())

    def do_POST(self):
        if not self.authorized():
            return self.reply(401, {"error": "Unauthorized"})
        try:
            if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                raise ValueError("Expected JSON")
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 16384:
                raise ValueError("Invalid body length")
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("Expected object")
            engine = self.server.engine
            processor = getattr(self.server, "processor", None)
            if self.path == "/v1/feedback" and processor:
                processor.agent.feedback(body)
                return self.reply(200, processor.agent.state())
            elif self.path == "/v1/memory/ask" and processor:
                if processor.model is None:
                    raise ValueError("No model configured")
                processor.agent.ask(body["id"], body["question"])
                return self.reply(200, processor.agent.state())
            elif self.path == "/v1/jobs/retry" and processor:
                jid = identifier(body["id"])
                with engine.store.lock, engine.store.transaction():
                    job = engine.store.db.execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
                    if not job or job["kind"] not in {"asr_audio", "ambient_analysis", "focus_analysis", "text_analysis", "memory_query", "semantic_analysis", "topic_reconcile","event_consolidate","personal_analysis","activity_analysis"}:
                        raise ValueError("Unknown processing job")
                    if job["status"] in {"failed", "blocked_provider", "retryable"}:
                        engine.store.db.execute("UPDATE jobs SET status='queued',attempts=0,error=NULL,available_at=0 WHERE id=?", (jid,))
                return self.reply(200, processor.agent.state())
            elif self.path == "/v1/dialogues/text" and processor:
                sid = identifier(body["session_id"])
                if not isinstance(body.get("text"), str) or not 0 < len(body["text"]) <= 12000:
                    raise ValueError("Invalid text")
                with engine.store.lock, engine.store.transaction():
                    existing = engine.store.db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
                    if not existing:
                        directory = engine.store.root / "text-dialogues" / sid
                        directory.mkdir(parents=True, mode=0o700)
                        engine.store.db.execute("INSERT INTO sessions(id,status,started_at,ended_at,batch_seconds,directory,source_kind) VALUES(?,'completed',?,?,60,?,'verified_text')",
                            (sid, now(), now(), str(directory)))
                    elif existing["source_kind"] != "verified_text":
                        raise Conflict("Existing session is not a text dialogue")
                    processor.agent.policy(sid, asr=False, agent=True, source_kind="verified_text", occurred_at=body.get("occurred_at"))
                    processor.agent.import_text(body["id"], sid, body["text"], occurred_at=body.get("occurred_at"))
                return self.reply(200, processor.agent.state())
            else:
                return self.reply(404, {"error": "Not found"})
            self.reply(200, engine.store.state())
        except Conflict as error:
            self.reply(409, {"error": str(error)})
        except (ValueError, KeyError, TypeError):
            self.reply(400, {"error": "Invalid request or unknown recording"})
        except Exception:
            self.reply(500, {"error": "Local operation failed; evidence preserved"})

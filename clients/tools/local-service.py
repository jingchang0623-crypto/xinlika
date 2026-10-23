# SPDX-License-Identifier: GPL-3.0-only
#!/usr/bin/env python3
"""Authenticated loopback capture/focus service with opt-in processing adapters."""
from __future__ import annotations
import sys
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[2] / "scripts"))

import argparse
import fcntl
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

from heartball_store import Conflict, Store, identifier, now

PROJECT = Path(__file__).resolve().parents[2]


class Engine:
    def __init__(self, store: Store, probe: Path, device: str, max_seconds: int = 1800):
        self.store, self.probe, self.device = store, probe.resolve(), device
        self.max_seconds = max_seconds
        self.control = threading.RLock()
        self.process = None
        self.sid = None
        self.worker = None
        self.stop_requested = threading.Event()
        # Never adopt/kill an old PID or reconnect to unknown ongoing hardware work.
        with store.lock, store.transaction():
            store.db.execute("UPDATE sessions SET status='interrupted',error=? WHERE status IN ('starting','recording','stopping','reconciling')",
                             ("服务中断；原始证据保留，未自动控制录音笔",))

    def start(self, sid: str, batch_seconds: int, processing_policy=None, agent_store=None):
        sid = identifier(sid)
        with self.control, self.store.lock:
            if self.store.db.execute("SELECT 1 FROM sessions WHERE id=?", (sid,)).fetchone():
                existing = self.store.session(sid)
                if existing["batch_seconds"] != batch_seconds:
                    raise Conflict("Session settings changed under the same ID")
                if processing_policy is not None:
                    previous = agent_store._policy(sid)
                    if not previous or any(previous[k + "_allowed"] != int(processing_policy[k]) for k in ("asr", "agent")) or previous["source_kind"] != processing_policy["source_kind"]:
                        raise Conflict("Existing session processing settings cannot be changed by start retry")
                return
            if self.process is not None and self.process.poll() is None:
                raise Conflict("The previous capture process is still finalizing")
            session = self.store.create_session(sid, batch_seconds)
            # Persist/validate permission before launching a recorder. A failed
            # policy write must never leave an unreported capture running.
            if processing_policy is not None:
                try:
                    agent_store.policy(sid, **processing_policy, occurred_at=session["started_at"], time_precision="host_capture_start_estimate")
                except Exception:
                    self.store.update_session(sid, status="error", error="处理设置未保存；未启动录音笔")
                    raise
            folder = Path(session["directory"])
            source_files = [PROJECT / "clients/tools/local-service.py", PROJECT / "scripts/heartball_store.py",
                            PROJECT / "scripts/heartball_agent_store.py", PROJECT / "scripts/heartball_processing.py",
                            PROJECT / "requirements-heartball.txt",
                            PROJECT / "clients/Sources/cb08-probe/main.swift",
                            PROJECT / "clients/Sources/LuyinbiCore/RecorderButtonHandshake.swift"]
            (folder / "as-run-code.json").write_text(json.dumps({"startedAt": now(),
                "probeSha256": hashlib.sha256(self.probe.read_bytes()).hexdigest(),
                "sourceSha256": {str(p.relative_to(PROJECT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}}, indent=2) + "\n")
            command = [str(self.probe), "capture", "--device", self.device,
                       "--observe-buttons", "--button-response", "vendor", "--app-state", "foreground",
                       "--start-if-idle", "--sync-clock-before-start", "--stop-owned-at-end", "--seconds", str(self.max_seconds),
                       "--output", str(folder / "probe")]
            try:
                with (folder / "probe-console.txt").open("xb") as log:
                    self.process = subprocess.Popen(command, cwd=PROJECT, stdin=subprocess.DEVNULL,
                                                    stdout=log, stderr=subprocess.STDOUT)
            except Exception:
                self.store.update_session(sid, status="error", error="采集进程未能启动")
                raise
            self.sid = sid
            self.stop_requested = threading.Event()
            self.worker = threading.Thread(target=self._monitor, args=(sid, self.process), daemon=False)
            self.worker.start()

    def stop(self, sid: str):
        with self.control:
            if sid != self.sid:
                if self.store.session(sid)["status"] in ("completed", "error", "interrupted"):
                    return
                raise Conflict("Not the active owned process")
            if self.process is not None and self.process.poll() is None and not self.stop_requested.is_set():
                self.stop_requested.set()
                self.store.update_session(sid, status="stopping")
                self.process.send_signal(signal.SIGINT)

    def _monitor(self, sid: str, process):
        capture = self.store.root / "captures" / identifier(sid) / "probe"
        position = 0
        failure = None

        def drain():
            nonlocal position
            journal = capture / "events.ndjson"
            if not journal.exists():
                return
            with journal.open("rb") as source:
                source.seek(position)
                for line in source:
                    if not line.endswith(b"\n"):
                        break
                    row = json.loads(line)
                    if "audioFile" in row:
                        self.store.ingest(sid, row)
                        if self.store.session(sid)["status"] == "starting":
                            self.store.update_session(sid, status="recording")
                    elif row.get("event") == "owned_recording_confirmed":
                        self.store.update_session(sid, owned_file=row["filename"])
                    elif row.get("event") in ("clock_sync_tx", "clock_verification", "unexpected_disconnect", "physical_file_change", "button_response_tx", "run_error", "save_skipped"):
                        with self.store.lock, self.store.transaction():
                            self.store.event(sid, row["event"], row)
                    elif row.get("event") == "snapshot" and row.get("state") == "2" and self.store.session(sid)["owned_file"]:
                        # Physical global stop ends observation. Focus APIs never call this.
                        self.stop(sid)
                    position += len(line)

        try:
            while process.poll() is None:
                drain()
                # Event.wait would busy-spin once stop is requested; use a timed join.
                try:
                    process.wait(timeout=0.25)
                except subprocess.TimeoutExpired:
                    pass
            drain()
            summary = json.loads((capture / "capture-summary.json").read_text())
            if process.returncode or summary.get("failure") or summary.get("droppedSubmissions"):
                failure = "采集异常，原始数据保留，请核对证据"
            self.store.finish(sid, failure)
            if not failure and self.store.session(sid)["owned_file"]:
                self._reconcile(sid, capture)
            elif not failure:
                self.store.update_session(sid, status="error", error="未确认本次新建的卡上文件身份")
        except Exception as error:
            if process.poll() is None:
                self.stop(sid)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    # Keep the process alive; never SIGKILL an in-flight card save.
                    pass
            self.store.update_session(sid, status="error", error=f"本机处理未完成：{type(error).__name__}；原始证据保留")

    def _reconcile(self, sid: str, capture: Path):
        session = self.store.session(sid)
        folder = Path(session["directory"])
        reference = folder / "card-reference"
        with (folder / "reference-console.txt").open("xb") as log:
            result = subprocess.run([str(self.probe), "reference", "--device", self.device,
                "--filename", session["owned_file"], "--output", str(reference)],
                cwd=PROJECT, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=600)
        if result.returncode:
            raise ValueError("Card is not safely available; recording left untouched")
        receipt = json.loads((reference / "reference.json").read_text())
        card = reference / session["owned_file"]
        data = card.read_bytes()
        if not receipt.get("sizeAndEndConfirmed") or receipt.get("endCode") != 0 or len(data) != receipt["expectedBytes"]:
            raise ValueError("Incomplete card reference")
        spec = importlib.util.spec_from_file_location("cb08_analysis", PROJECT / "scripts/analyze-cb08-capture.py")
        codec = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(codec)
        output = folder / "source-analysis"
        analysis = codec.analyze(capture, output, True, "ffmpeg", -50, [card])
        if analysis["problems"]:
            raise ValueError("Raw audio integrity/decoding check failed")
        codec.wrap_cb08(card, output / "card.ogg")
        decode = codec.decode_energy(output / "card.ogg", output, "ffmpeg", -50)
        if decode["decoderExitCode"]:
            raise ValueError("Saved card decoding failed")
        coverage = []
        for stream in analysis["streams"]:
            matches = stream["exactCardMatches"]
            if len(matches) != 1 or not matches[0]["uniqueWithinFile"]:
                raise ValueError("Live/card alignment ambiguous")
            match = matches[0]
            coverage.append([match["offset"], match["offset"] + match["length"]])
        missing = []
        cursor = 0
        for begin, end in sorted(coverage):
            if begin > cursor:
                missing.append([cursor, begin])
            cursor = max(cursor, end)
        if cursor < len(data):
            missing.append([cursor, len(data)])
        proof = {"status": "card_verified", "sha256": hashlib.sha256(data).hexdigest(),
                 "bytes": len(data), "decodedSeconds": decode["decodedSeconds"], "liveCoverage": coverage,
                 "missingLiveRanges": missing, "repairHashes": [hashlib.sha256(data[a:b]).hexdigest() for a, b in missing], "cardFile": str(card), "note": "Byte alignment, not acoustic timing or speech accuracy"}
        self.store.archive_review(sid, proof)


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
            if self.path == "/v1/capture/start":
                policy = body.get("processing")
                if policy is not None:
                    if not processor or not isinstance(policy, dict) or set(policy) != {"asr", "agent", "source_kind"} or type(policy["asr"]) is not bool or type(policy["agent"]) is not bool or policy["source_kind"] not in {"live_conversation", "background_playback", "unknown"}:
                        raise ValueError("Invalid processing policy")
                    if policy["asr"] and processor.asr is None or policy["agent"] and processor.model is None:
                        raise ValueError("Adapter not configured")
                if policy is None:
                    engine.start(body["id"], body.get("batch_seconds", 60))
                else:
                    engine.start(body["id"], body.get("batch_seconds", 60), policy, processor.agent)
            elif self.path == "/v1/capture/stop":
                engine.stop(identifier(body["id"]))
            elif self.path == "/v1/focus/start":
                engine.store.focus_start(body["id"], identifier(body["session_id"]))
            elif self.path == "/v1/focus/end":
                engine.store.focus_end(body["id"])
            elif self.path == "/v1/feedback" and processor:
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=PROJECT / ".build/heartball-lab")
    parser.add_argument("--probe", type=Path, default=PROJECT / ".build/swift/debug/cb08-probe")
    parser.add_argument("--device", required=True)
    parser.add_argument("--port", type=int, default=18766)
    parser.add_argument("--max-seconds", type=int, default=1800)
    parser.add_argument("--processing-config", type=Path, help="Private adapter config; every audio session still requires opt-in")
    args = parser.parse_args()
    if not 60 <= args.max_seconds <= 86400:
        parser.error("Capture maximum must be 60–86400 seconds (at most 24 hours per run)")
    args.root.mkdir(parents=True, exist_ok=True, mode=0o700)
    lease = (args.root / "service.lock").open("a+")
    try:
        fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("A Heartball service already owns this storage directory")
    store = Store(args.root)
    config = store.root / "runtime.json"
    token = json.loads(config.read_text())["token"] if config.exists() else secrets.token_urlsafe(32)
    server = Server(("127.0.0.1", args.port), Handler)
    server.token = token
    server.engine = Engine(store, args.probe, args.device, args.max_seconds)
    server.processor = None
    if args.processing_config:
        from heartball_processing import Processor
        server.processor = Processor.configured(store, args.processing_config)
        server.processor.start()
    config.write_text(json.dumps({"baseURL": f"http://127.0.0.1:{args.port}", "token": token,
                                 "device": args.device, "pid": os.getpid()}, indent=2) + "\n")
    config.chmod(0o600)
    print(f"Heartball local service at 127.0.0.1:{args.port}; processing {'configured, session opt-in required' if server.processor else 'disabled'}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        if server.engine.sid:
            server.engine.stop(server.engine.sid)
        if server.engine.worker:
            server.engine.worker.join(timeout=35)
    finally:
        if server.processor:
            server.processor.close()
        server.server_close()


if __name__ == "__main__":
    main()

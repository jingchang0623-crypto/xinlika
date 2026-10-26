"""Local evidence/intent store for the open Heartball prototype. No ASR or cloud I/O."""
from __future__ import annotations

from contextlib import contextmanager
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import threading
import uuid


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def identifier(value: str) -> str:
    return str(uuid.UUID(value))


class Conflict(ValueError):
    pass


class Store:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.root.chmod(0o700)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(self.root / "heartball.sqlite", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS sessions(
          id TEXT PRIMARY KEY, status TEXT NOT NULL, started_at TEXT NOT NULL,
          ended_at TEXT, batch_seconds INTEGER NOT NULL, directory TEXT NOT NULL,
          owned_file TEXT, error TEXT, archive TEXT, source_kind TEXT NOT NULL DEFAULT 'test_unverified');
        CREATE TABLE IF NOT EXISTS streams(
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL, filename TEXT NOT NULL,
          received INTEGER NOT NULL DEFAULT 0, sealed INTEGER NOT NULL DEFAULT 0,
          first_at TEXT, last_at TEXT, UNIQUE(session_id,filename));
        CREATE TABLE IF NOT EXISTS batches(
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL, sequence INTEGER NOT NULL,
          stream_id TEXT NOT NULL, start_byte INTEGER NOT NULL, end_byte INTEGER NOT NULL,
          sha256 TEXT NOT NULL, filename TEXT NOT NULL, reason TEXT NOT NULL,
          UNIQUE(session_id,sequence), UNIQUE(stream_id,start_byte,end_byte));
        CREATE TABLE IF NOT EXISTS focuses(
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL, status TEXT NOT NULL,
          started_at TEXT NOT NULL, ended_at TEXT, start_positions TEXT NOT NULL,
          ranges TEXT, end_reason TEXT, boundary_basis TEXT NOT NULL DEFAULT 'received_audio_packet_boundary');
        CREATE TABLE IF NOT EXISTS jobs(
          id TEXT PRIMARY KEY, kind TEXT NOT NULL, input_key TEXT NOT NULL,
          status TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(kind,input_key));
        CREATE TABLE IF NOT EXISTS events(
          id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, kind TEXT NOT NULL, at TEXT NOT NULL,
          payload TEXT NOT NULL);
        """)
        (self.root / "heartball.sqlite").chmod(0o600)

    @contextmanager
    def transaction(self):
        outer = not self.db.in_transaction
        if outer:
            self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            if outer:
                self.db.commit()
        except BaseException:
            if outer:
                self.db.rollback()
            raise

    def session(self, sid: str) -> dict:
        # check_same_thread=False permits access, not concurrent use of a shared
        # connection. Reads must share the transaction/ingest lock too.
        with self.lock:
            row = self.db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
            if row is None:
                raise ValueError("Unknown capture session")
            return dict(row)

    def create_session(self, sid: str, seconds: int = 60) -> dict:
        sid = identifier(sid)
        if type(seconds) is not int or not 60 <= seconds <= 300:
            raise ValueError("batch_seconds must be an integer from 60 to 300")
        with self.lock, self.transaction():
            old = self.db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
            if old:
                if old["batch_seconds"] != seconds:
                    raise Conflict("Same session ID with different settings")
                return dict(old)
            if self.db.execute("SELECT 1 FROM sessions WHERE status IN ('starting','recording','stopping','reconciling','interrupted')").fetchone():
                raise Conflict("A capture is active or requires device recovery")
            directory = self.root / "captures" / sid
            directory.mkdir(parents=True, mode=0o700)
            self.db.execute("INSERT INTO sessions(id,status,started_at,batch_seconds,directory) VALUES(?,?,?,?,?)",
                            (sid, "starting", now(), seconds, str(directory)))
            return self.session(sid)

    def update_session(self, sid: str, **values):
        if not values.keys() <= {"status", "ended_at", "owned_file", "error", "archive"}:
            raise ValueError("Invalid update")
        with self.lock, self.transaction():
            self.db.execute("UPDATE sessions SET " + ",".join(k + "=?" for k in values) + " WHERE id=?",
                            (*values.values(), sid))

    def event(self, sid: str, kind: str, payload: dict):
        self.db.execute("INSERT INTO events(session_id,kind,at,payload) VALUES(?,?,?,?)",
                        (sid, kind, now(), json.dumps(payload, ensure_ascii=False)))

    def _job(self, kind: str, key: str, payload: dict):
        # Recognition is deliberately gated; analysis tasks reference evidence ranges
        # instead of re-uploading/re-transcribing the same audio for each focus.
        self.db.execute("INSERT OR IGNORE INTO jobs(id,kind,input_key,status,payload) VALUES(?,?,?,?,?)",
                        (str(uuid.uuid4()), kind, key, "blocked_quality_review",
                         json.dumps(payload, ensure_ascii=False, sort_keys=True)))

    def archive_review(self, sid: str, proof: dict):
        """Missing tail needs a context merge, never standalone subsecond ASR."""
        with self.lock, self.transaction():
            review_ranges = proof.get("contextReviewRanges", proof.get("missingLiveRanges", []))
            if review_ranges:
                key = "repair-review:" + proof["sha256"]
                proof["repairReviewKey"] = key
                self._job("audio_repair_review", key, {"session_id": sid,
                    "missing_ranges": review_ranges, "card_sha256": proof["sha256"],
                    "context_merge_required": True, "standalone_asr_allowed": False,
                    "external_upload_allowed": False})
            self.update_session(sid, status="completed", archive=json.dumps(proof))

    def _raw(self, session: dict, filename: str) -> Path:
        if Path(filename).name != filename or not filename.startswith("audio-") or not filename.endswith(".bin"):
            raise ValueError("Invalid evidence filename")
        directory = (Path(session["directory"]) / "probe").resolve()
        path = (directory / filename).resolve()
        if path.parent != directory:
            raise ValueError("Evidence path escapes capture")
        return path

    def _seal(self, session: dict, stream: dict, end: int, reason: str):
        begin = stream["sealed"]
        if end <= begin:
            return
        if begin % 40 or end % 40:
            raise ValueError("A batch cannot trim a partial codec packet")
        with self._raw(session, stream["filename"]).open("rb") as source:
            source.seek(begin)
            data = source.read(end - begin)
        if len(data) != end - begin:
            raise ValueError("Audio not completely persisted yet")
        digest = hashlib.sha256(data).hexdigest()
        seq = self.db.execute("SELECT COALESCE(MAX(sequence),-1)+1 FROM batches WHERE session_id=?", (session["id"],)).fetchone()[0]
        folder = Path(session["directory"]) / "batches"
        folder.mkdir(exist_ok=True, mode=0o700)
        path = folder / f"{seq:06d}-{digest}.cb08"
        if path.exists():
            if path.read_bytes() != data:
                raise Conflict("Existing batch differs from source evidence")
        else:
            with path.open("xb") as output:
                os.chmod(path, 0o600)
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
        bid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"heartball:{stream['id']}:{begin}:{end}:{digest}"))
        self.db.execute("INSERT INTO batches VALUES(?,?,?,?,?,?,?,?,?)",
                        (bid, session["id"], seq, stream["id"], begin, end, digest, str(path), reason))
        self.db.execute("UPDATE streams SET sealed=? WHERE id=?", (end, stream["id"]))
        stream["sealed"] = end
        self._job("asr_audio", digest, {"batch_id": bid, "sha256": digest,
                  "source_kind": session["source_kind"], "external_upload_allowed": False})

    def ingest(self, sid: str, row: dict):
        with self.lock, self.transaction():
            session = self.session(sid)
            filename = row["audioFile"]
            offset, count = row["audioOffset"], row["audioBytes"]
            if type(offset) is not int or type(count) is not int or offset < 0 or count <= 0:
                raise ValueError("Invalid audio range")
            path = self._raw(session, filename)
            if path.stat().st_size < offset + count:
                raise ValueError("Journal is ahead of audio persistence")
            stream_id = str(uuid.uuid5(uuid.UUID(sid), filename))
            item = self.db.execute("SELECT * FROM streams WHERE id=?", (stream_id,)).fetchone()
            if item is None:
                # Different connections never share a raw stream or partial packet.
                self.flush(sid, "stream_change")
                self.db.execute("INSERT INTO streams(id,session_id,filename,first_at,last_at) VALUES(?,?,?,?,?)",
                                (stream_id, sid, filename, row["time"], row["time"]))
                item = self.db.execute("SELECT * FROM streams WHERE id=?", (stream_id,)).fetchone()
            stream = dict(item)
            if offset + count <= stream["received"]:
                return  # Replay after service recovery, not duplicate samples.
            if offset != stream["received"]:
                raise Conflict("Noncontiguous raw evidence; do not hide a gap")
            stream["received"] = offset + count
            self.db.execute("UPDATE streams SET received=?,last_at=? WHERE id=?",
                            (stream["received"], row["time"], stream_id))
            size = session["batch_seconds"] * 2000
            while stream["received"] - stream["sealed"] >= size:
                self._seal(session, stream, stream["sealed"] + size, "duration")

    def flush(self, sid: str, reason: str):
        with self.lock, self.transaction():
            session = self.session(sid)
            for row in self.db.execute("SELECT * FROM streams WHERE session_id=? ORDER BY rowid", (sid,)).fetchall():
                stream = dict(row)
                self._seal(session, stream, stream["received"] // 40 * 40, reason)

    def focus_start(self, fid: str, sid: str) -> dict:
        fid = identifier(fid)
        with self.lock, self.transaction():
            existing = self.db.execute("SELECT * FROM focuses WHERE id=?", (fid,)).fetchone()
            if existing:
                if existing["session_id"] != sid:
                    raise Conflict("Focus ID belongs to another session")
                return dict(existing)
            if self.session(sid)["status"] != "recording":
                raise Conflict("No active capture")
            if self.db.execute("SELECT 1 FROM focuses WHERE session_id=? AND status='recording'", (sid,)).fetchone():
                raise Conflict("A focus is already open")
            positions = {r["id"]: r["received"] // 40 * 40 for r in self.db.execute("SELECT * FROM streams WHERE session_id=?", (sid,))}
            if not positions:
                raise Conflict("Wait for the first audio packet")
            # A fresh focus gets its own batch boundary without touching hardware.
            # ASR can then reuse whole batches without pretending to have word alignment.
            self.flush(sid, "focus_start")
            self.db.execute("INSERT INTO focuses(id,session_id,status,started_at,start_positions) VALUES(?,?,?,?,?)",
                            (fid, sid, "recording", now(), json.dumps(positions)))
            self.event(sid, "focus_start", {"id": fid, "hardware_commands": 0})
            return dict(self.db.execute("SELECT * FROM focuses WHERE id=?", (fid,)).fetchone())

    def focus_end(self, fid: str, reason: str = "user") -> dict:
        fid = identifier(fid)
        with self.lock, self.transaction():
            row = self.db.execute("SELECT * FROM focuses WHERE id=?", (fid,)).fetchone()
            if not row:
                raise ValueError("Unknown focus")
            item = dict(row)
            if item["status"] != "recording":
                return item  # Idempotent: no second transcription or analysis task.
            starts = json.loads(item["start_positions"])
            ranges = []
            for stream in self.db.execute("SELECT * FROM streams WHERE session_id=? ORDER BY rowid", (item["session_id"],)):
                begin, end = starts.get(stream["id"], 0), stream["received"] // 40 * 40
                if end > begin:
                    ranges.append({"stream_id": stream["id"], "start_byte": begin, "end_byte": end})
            self.flush(item["session_id"], "focus_end")
            status = "audio_saved" if ranges and reason == "user" else "needs_review"
            self.db.execute("UPDATE focuses SET status=?,ended_at=?,ranges=?,end_reason=? WHERE id=?",
                            (status, now(), json.dumps(ranges), reason, fid))
            self._job("focus_analysis", fid, {"focus_id": fid, "ranges": ranges,
                      "reuse_batch_transcripts": True, "create_personal_memory": False})
            self.event(item["session_id"], "focus_end", {"id": fid, "hardware_commands": 0, "reason": reason})
            return dict(self.db.execute("SELECT * FROM focuses WHERE id=?", (fid,)).fetchone())

    def finish(self, sid: str, error: str | None = None):
        with self.lock, self.transaction():
            self.flush(sid, "capture_end")
            for row in self.db.execute("SELECT id FROM focuses WHERE session_id=? AND status='recording'", (sid,)).fetchall():
                self.focus_end(row["id"], "capture_end")
            partial = self.db.execute("SELECT SUM(received%40) FROM streams WHERE session_id=?", (sid,)).fetchone()[0] or 0
            self.update_session(sid, status="error" if error or partial else "reconciling", ended_at=now(),
                                error=error or ("Partial codec packet preserved in original raw evidence" if partial else None))

    def state(self) -> dict:
        with self.lock:
            row = self.db.execute("SELECT * FROM sessions ORDER BY CASE WHEN status IN ('preparing','recording','reconciling') THEN 1 ELSE 0 END DESC,julianday(started_at) DESC,rowid DESC LIMIT 1").fetchone()
            if row is None:
                return {"session": None, "focuses": [], "batches": [], "jobs": [], "asrEnabled": False}
            s = dict(row)
            sid = s["id"]
            batches = [dict(r) for r in self.db.execute("SELECT * FROM batches WHERE session_id=? ORDER BY sequence", (sid,))]
            focuses = []
            has_documents = self.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='documents'").fetchone() is not None
            for f in self.db.execute("SELECT * FROM focuses WHERE session_id=? ORDER BY started_at DESC", (sid,)):
                ranges = json.loads(f["ranges"] or "[]")
                seconds = sum(r["end_byte"] - r["start_byte"] for r in ranges) / 2000
                if f["status"] == "recording":
                    starts = json.loads(f["start_positions"])
                    seconds = sum(max(0, r["received"] // 40 * 40 - starts.get(r["id"], 0))
                                  for r in self.db.execute("SELECT * FROM streams WHERE session_id=?", (sid,))) / 2000
                processing = next((r[0] for r in self.db.execute("SELECT status FROM jobs WHERE kind='focus_analysis' AND input_key=?", (f["id"],))), None)
                if has_documents and processing == "completed":
                    doc = self.db.execute("SELECT text FROM documents WHERE input_key=?", ("focus_analysis:" + f["id"],)).fetchone()
                    if doc and not doc[0].strip(): processing = "no_text"
                focuses.append({"id": f["id"], "status": f["status"], "startedAt": f["started_at"],
                                "endedAt": f["ended_at"], "audioSeconds": seconds,
                                "rangeCount": len(ranges), "boundaryBasis": f["boundary_basis"],
                                "processingStatus": processing})
            size = self.db.execute("SELECT COALESCE(SUM(received),0) FROM streams WHERE session_id=?", (sid,)).fetchone()[0]
            gaps = self.db.execute("SELECT COUNT(*) FROM events WHERE session_id=? AND kind='unexpected_disconnect'", (sid,)).fetchone()[0]
            clock_row = self.db.execute("SELECT payload FROM events WHERE session_id=? AND kind='clock_verification' ORDER BY id DESC LIMIT 1", (sid,)).fetchone()
            clock = json.loads(clock_row[0]) if clock_row else {}
            return {"session": {"id": sid, "status": s["status"], "startedAt": s["started_at"],
                     "audioSeconds": size / 2000, "batchCount": len(batches), "gapCount": gaps,
                     "ownedFile": s["owned_file"], "error": s["error"], "archiveStatus": json.loads(s["archive"] or "{}").get("status", "pending"),
                     "batchSeconds": s["batch_seconds"],
                     "clockStatus": clock.get("status", "unverified"),
                     "clockVerifiedAt": clock.get("time"), "clockTimezone": clock.get("timezone")}, "focuses": focuses,
                    "batches": [{"id": b["id"], "sequence": b["sequence"], "audioSeconds": (b["end_byte"] - b["start_byte"]) / 2000,
                                 "sha256": b["sha256"], "reason": b["reason"]} for b in batches],
                    "jobs": [{"id": r["id"], "kind": r["kind"], "status": r["status"]} for r in self.db.execute("SELECT * FROM jobs") if r["input_key"] in ({b["sha256"] for b in batches} | {f["id"] for f in focuses} | set(json.loads(s["archive"] or "{}").get("repairHashes", [])) | {json.loads(s["archive"] or "{}").get("repairReviewKey")})],
                    "asrEnabled": False}

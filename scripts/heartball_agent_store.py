"""Heartball evidence, revision and feedback rules, on the existing audio ledger.

Model orchestration/checkpoints live in LangGraph. These are product rules, not
a second agent framework. No model output is silently promoted to a personal fact.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
import time
import uuid

from heartball_store import Conflict, identifier, now


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def stable(value):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "heartball:" + value))


class AgentStore:
    def __init__(self, store):
        self.store, self.db, self.lock = store, store.db, store.lock
        with self.lock:
            columns = {r[1] for r in self.db.execute("PRAGMA table_info(jobs)")}
            for name, declaration in {"attempts": "INTEGER NOT NULL DEFAULT 0", "lease_until": "REAL",
                    "lease_owner": "TEXT", "available_at": "REAL NOT NULL DEFAULT 0", "error": "TEXT"}.items():
                if name not in columns:
                    self.db.execute(f"ALTER TABLE jobs ADD COLUMN {name} {declaration}")
            self.db.executescript("""
            CREATE TABLE IF NOT EXISTS processing_policies(
              session_id TEXT PRIMARY KEY, asr_allowed INTEGER NOT NULL, agent_allowed INTEGER NOT NULL,
              source_kind TEXT NOT NULL, occurred_at TEXT, time_precision TEXT NOT NULL, updated_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS transcripts(
              audio_hash TEXT PRIMARY KEY, text TEXT NOT NULL, segments TEXT NOT NULL,
              provider TEXT NOT NULL, created_at TEXT NOT NULL, quality TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS documents(
              id TEXT PRIMARY KEY, kind TEXT NOT NULL, session_id TEXT NOT NULL, input_key TEXT UNIQUE NOT NULL,
              text TEXT NOT NULL, evidence TEXT NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL,
              source_kind TEXT NOT NULL, status TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
              created_at TEXT NOT NULL, occurred_at TEXT, boundary_quality TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS claims(
              id TEXT PRIMARY KEY, document_id TEXT NOT NULL, project TEXT NOT NULL, kind TEXT NOT NULL,
              statement TEXT NOT NULL, owner TEXT NOT NULL, due_at TEXT, status TEXT NOT NULL,
              quote TEXT NOT NULL, quote_start INTEGER NOT NULL, quote_end INTEGER NOT NULL,
              version INTEGER NOT NULL, replaces_id TEXT, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS advice(
              id TEXT PRIMARY KEY, dedup_key TEXT UNIQUE NOT NULL, kind TEXT NOT NULL,
              title TEXT NOT NULL, body TEXT NOT NULL, status TEXT NOT NULL,
              evidence TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS feedback(
              id TEXT PRIMARY KEY, target_id TEXT NOT NULL, request TEXT NOT NULL,
              before_state TEXT NOT NULL, after_state TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS preferences(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS memory_answers(id TEXT PRIMARY KEY,question TEXT NOT NULL,
              answer TEXT NOT NULL,refs TEXT NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS recording_origins(session_id TEXT PRIMARY KEY,filename TEXT NOT NULL,
              original_sha256 TEXT NOT NULL,local_start TEXT NOT NULL,offset_seconds REAL NOT NULL,
              evidence TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS claims_document ON claims(document_id);
            CREATE INDEX IF NOT EXISTS claims_project ON claims(project,status);
            """)
            if "replaces_version" not in {r[1] for r in self.db.execute("PRAGMA table_info(claims)")}:
                self.db.execute("ALTER TABLE claims ADD COLUMN replaces_version INTEGER")
            if "validation_notes" not in {r[1] for r in self.db.execute("PRAGMA table_info(documents)")}:
                self.db.execute("ALTER TABLE documents ADD COLUMN validation_notes TEXT NOT NULL DEFAULT '[]'")
            self.db.commit()
        from heartball_organization import OrganizationStore
        self.workspace = OrganizationStore(self)
        from heartball_recall import RecallIndex
        self.recall = RecallIndex(self.db)
        from heartball_voice import VoiceStore
        self.voice = VoiceStore(self)
        from heartball_audio_context import AudioContextStore
        self.acoustics = AudioContextStore(self)

    def policy(self, sid, *, asr, agent, source_kind, occurred_at=None, time_precision="unknown"):
        if source_kind not in {"live_conversation", "background_playback", "unknown", "test_unverified", "verified_text"}:
            raise ValueError("Unknown source kind")
        if type(asr) is not bool or type(agent) is not bool:
            raise ValueError("Explicit boolean processing choices required")
        if occurred_at is not None:
            value = dt.datetime.fromisoformat(occurred_at)
            if value.tzinfo is None:
                raise ValueError("An occurrence time needs a timezone")
        with self.lock, self.store.transaction():
            self.store.session(sid)
            self.db.execute("INSERT INTO processing_policies VALUES(?,?,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET "
                "asr_allowed=excluded.asr_allowed,agent_allowed=excluded.agent_allowed,source_kind=excluded.source_kind,"
                "occurred_at=excluded.occurred_at,time_precision=excluded.time_precision,updated_at=excluded.updated_at",
                (sid, int(asr), int(agent), source_kind, occurred_at, time_precision, now()))
            self.db.execute("UPDATE sessions SET source_kind=? WHERE id=?", (source_kind, sid))
            self.store.event(sid, "processing_policy", {"asr": asr, "agent": agent, "source_kind": source_kind})
            # Revocation blocks queued work. An already sent provider request cannot be recalled.
            self._invalidate_ineligible()

    def _policy(self, sid):
        with self.lock:
            r = self.db.execute("SELECT * FROM processing_policies WHERE session_id=?", (sid,)).fetchone()
            return dict(r) if r else {}

    def allowed(self, sid, stage):
        p = self._policy(sid)
        return bool(p.get("asr_allowed" if stage == "asr" else "agent_allowed"))

    def recording_origin(self,sid,filename,digest,offset_seconds,evidence):
        from heartball_recording_time import device_local_start
        local=device_local_start(filename)
        if local is None or offset_seconds<0 or not re.fullmatch('[a-f0-9]{64}',digest):raise ValueError('Invalid recording origin')
        with self.lock,self.store.transaction():
            self.store.session(sid)
            values=(sid,filename,digest,local.isoformat(),offset_seconds,encoded(evidence))
            old=self.db.execute('SELECT * FROM recording_origins WHERE session_id=?',(sid,)).fetchone()
            if old:
                if tuple(old)!=values:raise Conflict('Recording origin already differs')
                return
            self.db.execute('INSERT OR IGNORE INTO recording_origins VALUES(?,?,?,?,?,?)',values)
            for row in self.db.execute('SELECT id FROM documents WHERE session_id=?',(sid,)).fetchall():self._invalidate_advice(row[0])
            for row in self.db.execute('SELECT id FROM workspace_events WHERE session_id=?',(sid,)).fetchall():
                self.db.execute('UPDATE workspace_events SET version=version+1 WHERE id=?',(row[0],))
                self._invalidate_advice(row[0])

    def _invalidate_ineligible(self):
        for r in self.db.execute("SELECT * FROM jobs WHERE status IN ('queued','retryable')").fetchall():
            payload = json.loads(r["payload"])
            sid = payload.get("session_id")
            if r["kind"] == "asr_audio":
                ok = any(self.allowed(x[0], "asr") for x in self.db.execute("SELECT DISTINCT session_id FROM batches WHERE sha256=?", (r["input_key"],)))
            elif r["kind"] in {"personal_analysis","activity_analysis"}:
                ok = True  # Its runner validates every snapshotted source grant.
            elif r["kind"] == "memory_query":
                ok = True  # Explicit authenticated user query, not a background audio grant.
            else:
                ok = sid and self.allowed(sid, "agent")
            if not ok:
                self.db.execute("UPDATE jobs SET status='blocked_quality_review' WHERE id=?", (r["id"],))

    def enqueue(self, kind, key, payload):
        jid = stable("job:" + kind + ":" + key)
        self.db.execute("INSERT OR IGNORE INTO jobs(id,kind,input_key,status,payload) VALUES(?,?,?,'queued',?)",
                        (jid, kind, key, encoded(payload)))

    def schedule(self):
        """Incremental work: receive continuously; only completed audio batches are sent."""
        with self.lock, self.store.transaction():
            self._invalidate_ineligible()
            for b in self.db.execute("SELECT * FROM batches ORDER BY rowid").fetchall():
                sid = b["session_id"]
                if self.allowed(sid, "asr"):
                    self.db.execute("UPDATE jobs SET status='queued' WHERE kind='asr_audio' AND input_key=? AND status='blocked_quality_review'",
                                    (b["sha256"],))
                t = self.db.execute("SELECT * FROM transcripts WHERE audio_hash=?", (b["sha256"],)).fetchone()
                if t and self.allowed(sid, "agent"):
                    self.enqueue("ambient_analysis", b["id"], {"session_id": sid, "batch_id": b["id"]})
            for f in self.db.execute("SELECT * FROM focuses WHERE status!='recording'").fetchall():
                if not self.allowed(f["session_id"], "agent"):
                    continue
                batches = self.focus_batches(dict(f))
                if batches and all(self.db.execute("SELECT 1 FROM transcripts WHERE audio_hash=?", (b["sha256"],)).fetchone() for b in batches):
                    self.db.execute("UPDATE jobs SET status='queued',payload=? WHERE kind='focus_analysis' AND input_key=? AND status='blocked_quality_review'",
                                    (encoded({"session_id": f["session_id"], "focus_id": f["id"]}), f["id"]))

    def focus_batches(self, focus):
        ranges = json.loads(focus["ranges"] or "[]")
        return [dict(b) for b in self.db.execute("SELECT * FROM batches WHERE session_id=? ORDER BY sequence", (focus["session_id"],))
                if any(b["stream_id"] == r["stream_id"] and b["end_byte"] > r["start_byte"] and b["start_byte"] < r["end_byte"] for r in ranges)]

    def claim_job(self, worker, clock=None, kinds=None):
        clock = time.time() if clock is None else clock
        with self.lock, self.store.transaction():
            # Completed artifacts survive; only work without a persisted result is re-leased.
            self.db.execute("UPDATE jobs SET status='retryable',lease_owner=NULL WHERE status='running' AND lease_until<?", (clock,))
            selection="";arguments=[]
            if kinds is not None:
                if not kinds:return None
                selection='AND kind IN ('+','.join('?' for _ in kinds)+') '
                arguments.extend(sorted(kinds))
            r = self.db.execute("SELECT * FROM jobs WHERE kind IN ('asr_audio','ambient_analysis','focus_analysis','text_analysis','memory_query','semantic_analysis','topic_reconcile','event_consolidate','personal_analysis','activity_analysis') "
                +selection+
                "AND status IN ('queued','retryable') AND attempts<4 AND available_at<=? ORDER BY "
                "CASE kind WHEN 'memory_query' THEN 0 WHEN 'focus_analysis' THEN 0 WHEN 'asr_audio' THEN 1 WHEN 'semantic_analysis' THEN 3 WHEN 'event_consolidate' THEN 3 WHEN 'activity_analysis' THEN 4 WHEN 'topic_reconcile' THEN 4 WHEN 'personal_analysis' THEN 5 ELSE 2 END,rowid LIMIT 1", (*arguments,clock)).fetchone()
            if not r:
                return None
            self.db.execute("UPDATE jobs SET status='running',attempts=attempts+1,lease_owner=?,lease_until=? WHERE id=?", (worker, clock + 600, r["id"]))
            return dict(self.db.execute("SELECT * FROM jobs WHERE id=?", (r["id"],)).fetchone())

    def job_done(self, job, error=None):
        with self.lock, self.store.transaction():
            self.db.execute("UPDATE jobs SET status=?,error=?,lease_owner=NULL,lease_until=NULL,available_at=? WHERE id=? AND lease_owner=?",
                ("failed" if error and job["attempts"] >= 4 else "retryable" if error else "completed",
                 error, time.time() + min(300, 2 ** job["attempts"] * 5) if error else 0, job["id"], job["lease_owner"]))

    def save_transcript(self, digest, result):
        with self.lock, self.store.transaction():
            self.db.execute("INSERT OR IGNORE INTO transcripts VALUES(?,?,?,?,?,?)", (digest, result["text"],
                encoded(result.get("segments", [])), result["provider"], now(), "unreviewed_asr"))

    def prepare_document(self, job):
        payload = json.loads(job["payload"])
        with self.lock:
            if job["kind"] == "focus_analysis":
                f = dict(self.db.execute("SELECT * FROM focuses WHERE id=?", (payload["focus_id"],)).fetchone())
                batches = self.focus_batches(f)
                ranges = json.loads(f["ranges"] or "[]")
                exact = all(any(r["stream_id"] == b["stream_id"] and r["start_byte"] <= b["start_byte"] and r["end_byte"] >= b["end_byte"] for r in ranges) for b in batches)
                kind = "focus"
            else:
                batches = [dict(self.db.execute("SELECT * FROM batches WHERE id=?", (payload["batch_id"],)).fetchone())]
                exact, kind = True, "ambient"
            text, evidence = "", []
            for b in batches:
                t = self.db.execute("SELECT * FROM transcripts WHERE audio_hash=?", (b["sha256"],)).fetchone()
                if t is None:
                    raise Conflict("Transcript dependency not ready")
                # Legacy focuses may straddle a batch. Whole-batch text is clearly
                # labelled context; no fabricated word alignment or silent clipping.
                start = len(text)
                text += ("\n" if text else "") + t["text"]
                evidence.append({"batch_id": b["id"], "audio_hash": b["sha256"], "stream_id": b["stream_id"],
                    "start_byte": b["start_byte"], "end_byte": b["end_byte"], "text_start": start, "text_end": len(text),
                    "precision": "batch_range", "focus_exact_batches": exact})
            sid = batches[0]["session_id"]
            p = self._policy(sid)
            occurred_at = p.get("occurred_at")
            if p.get("time_precision") in {"host_capture_start_estimate", "phone_receive_start_estimate"}:
                stream = self.db.execute("SELECT first_at FROM streams WHERE id=?", (batches[0]["stream_id"],)).fetchone()
                if stream and stream[0]:
                    try:
                        first = dt.datetime.fromisoformat(stream[0].replace("Z", "+00:00"))
                        occurred_at = (first + dt.timedelta(seconds=batches[0]["start_byte"] / 2000)).isoformat()
                    except ValueError:
                        occurred_at = None
            elif occurred_at:
                occurred_at=(dt.datetime.fromisoformat(occurred_at)+dt.timedelta(seconds=batches[0]['start_byte']/2000)).isoformat()
            return {"id": stable("document:" + job["kind"] + ":" + job["input_key"]), "input_key": job["kind"] + ":" + job["input_key"],
                "session_id": sid, "kind": kind, "text": text, "evidence": evidence,
                "source_kind": p.get("source_kind", "unknown"), "occurred_at": occurred_at,
                "boundary_quality": "batch_exact" if exact else "includes_boundary_context"}

    def context(self, limit=80, question=None):
        return [r for r in self.query_context(limit=limit,question=question) if r['record_type']=='personal_memory']

    def query_context(self, limit=80, question=None):
        """Retrievable observations are not silently promoted to personal truth."""
        with self.lock:
            from heartball_recall import terms
            hits = self.recall.search(question) if question else []
            matched = {h['record_id'] for h in hits}
            priority = {h['record_id']: h['score'] for h in hits}
            ids = list(matched) or ['']
            placeholders = ','.join('?' for _ in ids)
            claims = [dict(r) for r in self.db.execute(
                "SELECT c.id,c.document_id,c.project,c.kind,c.statement,c.owner,c.due_at,c.status,c.version,c.quote,d.source_kind,d.occurred_at,d.session_id,d.evidence "
                "FROM claims c JOIN documents d ON d.id=c.document_id "
                "WHERE c.status IN ('proposed','confirmed','completed') AND d.status!='superseded' "
                "AND d.source_kind IN ('live_conversation','verified_text') "
                f"ORDER BY (c.id IN ({placeholders})) DESC,CASE WHEN c.status='proposed' THEN 1 ELSE 0 END,c.rowid DESC LIMIT ?", (*ids,limit))]
            for claim in claims:
                claim["record_type"] = "mention" if claim["status"] == "proposed" else "personal_memory"
                from heartball_recording_time import recording_time
                claim.update(recording_time(self.db,claim))
                claim.pop('evidence',None)
            covered = {c["document_id"] for c in claims}
            records = []
            for doc in self.db.execute(f"SELECT * FROM documents WHERE status NOT IN ('superseded','no_text','transcript_only') ORDER BY (id IN ({placeholders})) DESC,rowid DESC LIMIT ?",(*ids,limit)):
                if doc["id"] in covered or not doc["text"].strip():
                    continue
                records.append({"id": doc["id"], "version": doc["revision"], "record_type": "record",
                    "status": "recorded", "source_kind": doc["source_kind"], "statement": doc["summary"],
                    "quote": doc["text"][:6000], "owner": "unknown", "due_at": None, "project": ""})
                from heartball_recording_time import recording_time
                records[-1].update(recording_time(self.db,dict(doc)))
            context = claims + records + self.workspace.query_context(ids=matched if question else None)
            if question:
                # Cheap local recall before model synthesis; this is ranking, not attribution.
                words = set(re.findall(r"[a-z0-9]+", question.lower()))
                chinese = re.findall(r"[\u4e00-\u9fff]+", question)
                words.update(s[i:i+2] for s in chinese for i in range(len(s)-1))
                def score(item):
                    text = encoded(item).lower()
                    return priority.get(item['id'], 0) + sum(1 for w in words if w in text)
                context.sort(key=score,reverse=True)
            # Bound model context independently of how long the ledger is.
            result, budget = [], 36000
            for item in context[:limit]:
                item = dict(item)
                if isinstance(item.get('quote'),str) and len(item['quote'])>1800:
                    offsets=[item['quote'].lower().find(w) for w in terms(question or '')]
                    offset=min((x for x in offsets if x>=0),default=0)
                    begin=max(0,offset-240);item['quote']=item['quote'][begin:begin+1800]
                cost=len(encoded(item))
                if cost>budget:continue
                result.append(item);budget-=cost
            return result


    def commit_document(self, doc, result):
        with self.lock, self.store.transaction():
            if self.db.execute("SELECT 1 FROM documents WHERE id=?", (doc["id"],)).fetchone():
                return
            eligible = doc["source_kind"] in {"live_conversation", "verified_text"}
            self.db.execute("INSERT INTO documents(id,kind,session_id,input_key,text,evidence,title,summary,source_kind,status,created_at,occurred_at,boundary_quality) "
                "VALUES(?,?,?,?,?,?,?,?,?,'review_pending',?,?,?)", (doc["id"], doc["kind"], doc["session_id"], doc["input_key"], doc["text"], encoded(doc["evidence"]),
                    result["title"], result["summary"], doc["source_kind"], now(), doc.get("occurred_at"), doc["boundary_quality"]))
            self.db.execute("UPDATE documents SET validation_notes=? WHERE id=?", (encoded(result.get("validation_notes", [])), doc["id"]))
            if not doc["text"].strip():
                self.db.execute("UPDATE documents SET status='no_text' WHERE id=?", (doc["id"],))
            # Focus is a separate user result, sharing canonical ambient facts.
            # This avoids a second commitment for the same overlapping sound.
            if eligible and doc["kind"] != "focus":
                for index, claim in enumerate(result.get("claims", [])):
                    claim=dict(claim)
                    # A live-conversation label establishes the setting, not the
                    # identity of every first-person utterance in the recording.
                    if doc['source_kind']=='live_conversation' and claim.get('owner','').strip().lower() in {'我','本人','用户','你','您','user','me','myself','owner'}:
                        claim['owner']='unknown'
                    quote = claim["quote"]
                    start = doc["text"].find(quote)
                    if not quote.strip() or start < 0:
                        raise ValueError("Model evidence quote is absent from transcript")
                    replaces = claim.get("replaces_id")
                    if replaces:
                        old = self.db.execute("SELECT * FROM claims WHERE id=? AND status IN ('confirmed','completed')", (replaces,)).fetchone()
                        if not old or old["project"] != claim["project"] or old["kind"] != claim["kind"] or old["owner"] != claim["owner"]:
                            raise ValueError("Invalid memory replacement reference")
                        if old["version"] != claim.get("_replaces_version"):
                            raise Conflict("Replacement memory changed during extraction")
                    cid = stable("claim:" + doc["id"] + ":" + str(index))
                    # Dates are not guessed when device/history occurrence time is unknown.
                    due = claim.get("due_at") if doc.get("occurred_at") else None
                    if due:
                        date = dt.datetime.fromisoformat(due)
                        if date.tzinfo is None:
                            raise ValueError("Due date needs timezone")
                    self.db.execute("INSERT INTO claims(id,document_id,project,kind,statement,owner,due_at,status,quote,quote_start,quote_end,version,replaces_id,created_at,replaces_version) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (cid, doc["id"], claim["project"], claim["kind"],
                        claim["statement"], claim["owner"], due, "proposed", quote, start, start + len(quote), 1, replaces, now(), old["version"] if replaces else None))
            self.store.event(doc["session_id"], "document_ready", {"id": doc["id"], "kind": doc["kind"], "memory_auto_confirmed": False})

    def import_text(self, doc_id, sid, text, source_kind="verified_text", occurred_at=None):
        if not isinstance(text, str) or not 0 < len(text) <= 24000:
            raise ValueError("Text length invalid")
        doc_id, sid = identifier(doc_id), identifier(sid)
        with self.lock, self.store.transaction():
            old = self.db.execute("SELECT * FROM documents WHERE id=?", (doc_id,)).fetchone()
            if old:
                if old["text"] != text or old["source_kind"] != source_kind:
                    raise Conflict("Same document ID with different content")
                return
            self.store.session(sid)
            if not self.allowed(sid, "agent"):
                raise Conflict("Text model processing is not enabled for this session")
            self.enqueue("text_analysis", doc_id, {"session_id": sid, "document": {"id": doc_id, "session_id": sid,
                "kind": "text", "input_key": "text:" + doc_id, "text": text, "evidence": [{"kind": "user_supplied_text", "sha256": hashlib.sha256(text.encode()).hexdigest()}],
                "source_kind": source_kind, "occurred_at": occurred_at, "boundary_quality": "user_text"}})

    def _invalidate_advice(self, cid):
        for a in self.db.execute("SELECT * FROM advice WHERE status='active'").fetchall():
            if any(e["id"] == cid for e in json.loads(a["evidence"])):
                self.db.execute("UPDATE advice SET status='invalidated' WHERE id=?", (a["id"],))
        for a in self.db.execute("SELECT * FROM memory_answers WHERE status='ready'").fetchall():
            if any(e["id"] == cid for e in json.loads(a["refs"])):
                self.db.execute("UPDATE memory_answers SET status='outdated' WHERE id=?", (a["id"],))

    def ask(self, qid, question):
        qid = identifier(qid)
        if not isinstance(question, str) or not 0 < len(question.strip()) <= 1000:
            raise ValueError("Invalid memory question")
        with self.lock, self.store.transaction():
            r = self.db.execute("SELECT question FROM memory_answers WHERE id=?", (qid,)).fetchone()
            if r and r[0] != question:
                raise Conflict("Question identity conflict")
            self.db.execute("INSERT OR IGNORE INTO memory_answers VALUES(?,?,'','[]','pending',?)", (qid, question, now()))
            self.enqueue("memory_query", qid, {"question_id": qid, "question": question})

    def answer(self, qid, value):
        with self.lock, self.store.transaction():
            observations, authoritative = [], []
            for ref in value["refs"]:
                if self.workspace.validate_ref(ref):continue
                row = self.db.execute("SELECT c.*,d.source_kind,d.status AS document_status FROM claims c JOIN documents d ON d.id=c.document_id WHERE c.id=?", (ref["id"],)).fetchone()
                if row:
                    if row["version"] != ref["version"] or row["status"] not in {"proposed", "confirmed", "completed"} or row["document_status"] == "superseded" or row["source_kind"] not in {"live_conversation", "verified_text"}:
                        raise Conflict("Answer cites changed or unavailable memory")
                    if row["status"] == "proposed":
                        observations.append((row["quote"], row["source_kind"]))
                    else:
                        authoritative.append(row)
                else:
                    doc = self.db.execute("SELECT * FROM documents WHERE id=?", (ref["id"],)).fetchone()
                    quote = ref.get("quote")
                    if not doc or doc["revision"] != ref["version"] or doc["status"] in {"superseded", "no_text"} or not isinstance(quote, str) or not quote.strip() or quote not in doc["text"]:
                        raise Conflict("Answer cites changed record or ungrounded transcript quote")
                    observations.append((quote, doc["source_kind"]))
            answer = value["answer"]
            restricted = [(quote,source) for quote,source in observations if source not in {'live_conversation','verified_text'}]
            if restricted:
                # The model selects relevant evidence; the server controls attribution.
                # Unreviewed speech can be recalled without inventing a personal identity.
                names = {"background_playback": "背景播放", "unknown": "来源未识别", "test_unverified": "测试录音", "live_conversation": "现场对话", "verified_text": "文字记录"}
                lines = ["相关内容来自以下记录："]
                for quote, source in restricted[:4]:
                    lines.append("• 「" + quote[:240] + ("…" if len(quote) > 240 else "") + "」 · " + names.get(source, "对话记录"))
                if authoritative:
                    lines.append("已核实的相关记忆：")
                    for row in authoritative[:8]:
                        lines.append("• " + row["statement"] + "；当前归属：" + row["owner"] + "；当前时间：" + (row["due_at"] or "未设定") + "；" + row["status"])
                answer = "\n".join(lines)
            elif not value["refs"]:
                answer = "现有记录中还没找到相关内容。"
            self.db.execute("UPDATE memory_answers SET answer=?,refs=?,status='ready' WHERE id=?", (answer, encoded(value["refs"]), qid))

    def feedback(self, request):
        rid, target = identifier(request["id"]), identifier(request["target_id"])
        action = request["action"]
        with self.lock, self.store.transaction():
            old = self.db.execute("SELECT * FROM feedback WHERE id=?", (rid,)).fetchone()
            canonical = encoded({**request, "id": rid, "target_id": target})
            if old:
                if old["request"] != canonical:
                    raise Conflict("Feedback ID reused with different content")
                return
            row = self.db.execute("SELECT * FROM claims WHERE id=?", (target,)).fetchone()
            if row:
                before = dict(row)
                if request.get("expected_version") != before["version"]:
                    raise Conflict("Memory changed; refresh before correcting")
                if before["status"] in {"rejected", "superseded"}:
                    raise Conflict("This memory version is no longer active")
                if before["replaces_id"] and action in {"confirm", "correct"}:
                    dependency = self.db.execute("SELECT version,status FROM claims WHERE id=?", (before["replaces_id"],)).fetchone()
                    if not dependency or dependency["version"] != before["replaces_version"] or dependency["status"] not in {"confirmed", "completed"}:
                        raise Conflict("The memory being replaced changed; re-evaluate this proposal")
                values = {k: before[k] for k in ("statement", "owner", "due_at", "status")}
                if action == "confirm":
                    if before["status"] != "proposed":
                        raise Conflict("Only a proposed memory can be confirmed")
                    values["status"] = "confirmed"
                elif action == "correct":
                    patch = request.get("values", {})
                    if not patch or not patch.keys() <= {"statement", "owner", "due_at"}:
                        raise ValueError("Invalid correction")
                    for k, v in patch.items():
                        if k != "due_at" and (not isinstance(v, str) or not v.strip() or len(v) > 1500):
                            raise ValueError("Invalid corrected text")
                        if k == "due_at" and v is not None and dt.datetime.fromisoformat(v).tzinfo is None:
                            raise ValueError("Due date needs timezone")
                    values.update(patch)
                    values["status"] = "confirmed"
                elif action in {"complete", "reject"}:
                    values["status"] = "completed" if action == "complete" else "rejected"
                else:
                    raise ValueError("Unknown memory feedback action")
                self.db.execute("UPDATE claims SET statement=?,owner=?,due_at=?,status=?,version=version+1 WHERE id=?",
                    (values["statement"], values["owner"], values["due_at"], values["status"], target))
                self._invalidate_advice(target)
                if action in {'correct','complete','reject'}:self.workspace.invalidate_document(before['document_id'])
                if values["status"] == "confirmed" and before["replaces_id"]:
                    self.db.execute("UPDATE claims SET status='superseded',version=version+1 WHERE id=?", (before["replaces_id"],))
                    self._invalidate_advice(before["replaces_id"])
                after = dict(self.db.execute("SELECT * FROM claims WHERE id=?", (target,)).fetchone())
            elif action in {"correct_document", "reclassify_document"}:
                row = self.db.execute("SELECT * FROM documents WHERE id=?", (target,)).fetchone()
                if row is None or row["status"] == "superseded" or request.get("expected_version") != row["revision"]:
                    raise Conflict("Document changed; refresh before correcting")
                text = request.get("values", {}).get("text") if action == "correct_document" else row["text"]
                if not isinstance(text, str) or not 0 < len(text) <= 12000:
                    raise ValueError("Invalid corrected transcript")
                source_kind = request.get("values", {}).get("source_kind", row["source_kind"])
                if source_kind not in {"live_conversation", "background_playback", "unknown", "verified_text", "test_unverified"}:
                    raise ValueError("Invalid corrected source")
                before = dict(row)
                revised_id = stable("corrected-document:" + target + ":" + str(row["revision"] + 1))
                self.enqueue("text_analysis", revised_id, {"session_id": row["session_id"], "document": {
                    "id": revised_id, "session_id": row["session_id"], "kind": row["kind"], "input_key": "correction:" + revised_id,
                    "text": text, "evidence": json.loads(row["evidence"]) + [{"kind": "user_correction", "previous_document_id": target}],
                    "source_kind": source_kind, "occurred_at": row["occurred_at"], "boundary_quality": row["boundary_quality"]}})
                self.db.execute("UPDATE documents SET status='superseded',revision=revision+1 WHERE id=?", (target,))
                for c in self.db.execute("SELECT id FROM claims WHERE document_id=?", (target,)).fetchall():
                    self.db.execute("UPDATE claims SET status='superseded',version=version+1 WHERE id=?", (c["id"],))
                    self._invalidate_advice(c["id"])
                self._invalidate_advice(target)
                self.workspace.invalidate_document(target)
                after = {"replacement_document_id": revised_id, "text": text}
            else:
                row = self.db.execute("SELECT * FROM advice WHERE id=?", (target,)).fetchone()
                if not row or action not in {"dismiss", "mute_kind"}:
                    raise ValueError("Unknown feedback target/action")
                before = dict(row)
                self.db.execute("UPDATE advice SET status='dismissed' WHERE id=?", (target,))
                if action == "mute_kind":
                    self.db.execute("INSERT OR REPLACE INTO preferences VALUES(?,?)", ("mute:" + row["kind"], "true"))
                    self.db.execute("UPDATE advice SET status='dismissed' WHERE kind=? AND status='active'", (row["kind"],))
                after = dict(self.db.execute("SELECT * FROM advice WHERE id=?", (target,)).fetchone())
            self.db.execute("INSERT INTO feedback VALUES(?,?,?,?,?,?)", (rid, target, canonical, encoded(before), encoded(after), now()))
        self.evaluate()

    def evaluate(self, clock=None):
        """Evidence-backed triggers independent of a user asking a chat question.

        Follow-up timers recheck claim status/version, as in Omi's follow-up
        contract. Generated prose is not allowed to invent new factual evidence.
        """
        clock = clock or dt.datetime.now(dt.timezone.utc)
        with self.lock, self.store.transaction():
            claims = [dict(r) for r in self.db.execute("SELECT * FROM claims WHERE status IN ('proposed','confirmed')")]
            # Retire the early per-fact review cards, preserving history. Passive
            # listening must not demand an acknowledgement for every extracted fact.
            self.db.execute("UPDATE advice SET status='invalidated' WHERE kind IN ('review','review_intent') AND status='active'")
            pending_intents = {}
            for c in claims:
                if c["status"] == "proposed" and c["kind"] in {"commitment", "dependency"}:
                    pending_intents.setdefault(c["document_id"], []).append(c)
                elif c["kind"] == "commitment" and c["due_at"] and dt.datetime.fromisoformat(c["due_at"]) <= clock:
                    if c["status"] == "confirmed":
                        self._advice("due", [c], "有一项承诺已到期", c["owner"] + "：" + c["statement"])
            for c in claims:
                if c["status"] == "proposed" and c["kind"] == "commitment" and c["due_at"] and dt.datetime.fromisoformat(c["due_at"]) <= clock:
                    self._advice("due_observed", [c], "对话中有一项约定可能需要跟进", c["statement"] + "（来自对话记录，归属尚未核实）")
            # Concrete first cross-dialogue rule: an explicitly confirmed dependency
            # is later than an explicitly confirmed commitment in the same project.
            for c in claims:
                if c["status"] not in {"confirmed", "proposed"} or c["kind"] != "commitment" or not c["due_at"] or not c["project"]:
                    continue
                for dep in claims:
                    if dep["status"] in {"confirmed", "proposed"} and dep["kind"] == "dependency" and dep["due_at"] and dep["project"] == c["project"] and dep["document_id"] != c["document_id"]:
                        if dt.datetime.fromisoformat(dep["due_at"]) > dt.datetime.fromisoformat(c["due_at"]):
                            certain = c["status"] == dep["status"] == "confirmed"
                            self._advice("dependency_conflict" if certain else "potential_dependency_conflict", [c, dep],
                                "跨对话发现交付时间冲突" if certain else "对话中的两个时间可能有冲突",
                                "项目“" + c["project"] + "”的依赖晚于交付约定。" + ("" if certain else "来自对话提及，归属与日期尚未核实。"))

    def _advice(self, kind, claims, title, body):
        if self.db.execute("SELECT 1 FROM preferences WHERE key=? AND value='true'", ("mute:" + kind,)).fetchone():
            return
        refs = sorted([{"id": c["id"], "version": c["version"]} for c in claims], key=lambda e: e["id"])
        key = kind + ":" + encoded(refs)
        self.db.execute("INSERT OR IGNORE INTO advice VALUES(?,?,?,?,?,'active',?,?)", (stable("advice:" + key), key, kind, title, body, encoded(refs), now()))

    def state(self, day=None, time_zone='Asia/Shanghai'):
        with self.lock:
            from heartball_day import daily_workspace
            today = daily_workspace(self.db, day, time_zone)
            day_documents = list({s['document_id'] for g in today['groups'] for e in g['events'] for s in e['sources']})
            docs = [dict(r) for r in self.db.execute("SELECT * FROM documents WHERE rowid IN (SELECT rowid FROM documents ORDER BY rowid DESC LIMIT 60) OR id IN (SELECT value FROM json_each(?)) ORDER BY rowid DESC", (encoded(day_documents),))]
            claims = [dict(r) for r in self.db.execute("SELECT * FROM claims ORDER BY rowid DESC LIMIT 150")]
            advice = [dict(r) for r in self.db.execute("SELECT * FROM advice ORDER BY rowid DESC LIMIT 100")]
            jobs = [dict(r) for r in self.db.execute("SELECT id,kind,status,attempts,error FROM jobs ORDER BY rowid DESC LIMIT 100")]
            answers = [dict(r) for r in self.db.execute("SELECT * FROM memory_answers ORDER BY rowid DESC LIMIT 20")]
            for d in docs:
                d["evidence"] = json.loads(d["evidence"])
                from heartball_recording_time import recording_time
                d.update(recording_time(self.db,d))
                d["validation_notes"] = json.loads(d["validation_notes"])
                if not d["text"].strip() and d["status"] != "superseded":
                    # Preserve original stored/model evidence; display an honest
                    # no-result state for older empty-transcript runs as well.
                    d.update(status="no_text", title="暂无可用转写", summary="语音服务没有返回文字，原声已保留，可回听核对。")
            for a in advice:
                a["evidence"] = json.loads(a["evidence"])
            for a in answers:
                a["refs"] = json.loads(a["refs"])
                if a["status"] == "pending":
                    job = self.db.execute("SELECT status FROM jobs WHERE kind='memory_query' AND input_key=?", (a["id"],)).fetchone()
                    if job and job[0] in {"failed", "blocked_provider"}:
                        a["status"] = "needs_retry"
                        a["answer"] = "本次查询未完成，请检查处理进度或模型服务后重试。"
            activity_progress=None
            if self.db.execute("SELECT 1 FROM sqlite_master WHERE name='workspace_activity_runs'").fetchone():
                last=self.db.execute('SELECT status FROM workspace_activity_runs ORDER BY rowid DESC LIMIT 1').fetchone()
                activity_progress={'status':last[0] if last else 'waiting_for_new_records','validated_issue_limit':300,'scope':'current_recording_day'}
            return {**self.workspace.state(), "today": today, "documents": docs, "claims": claims, "advice": advice, "processingJobs": jobs,"activityProgress":activity_progress,
                    "confirmedMemoryCount": self.db.execute("SELECT COUNT(*) FROM claims WHERE status='confirmed'").fetchone()[0],
                    "answers": answers,
                    "sourcePolicy": "Explicit session permission; background/unknown sources never create personal claims"}

#!/usr/bin/env python3
"""Explicitly import one selected CB08 raw range, without connecting to hardware."""
import argparse
import hashlib
import json
from pathlib import Path
import uuid
import datetime as dt

from heartball_store import Store, now
from heartball_agent_store import AgentStore, stable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(".build/heartball-lab"))
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--start-seconds", type=int, default=0)
    parser.add_argument("--seconds", type=int, required=True)
    parser.add_argument("--expected-sha256", required=True, help="SHA-256 of the explicitly selected source file")
    parser.add_argument("--source-kind", required=True, choices=["live_conversation", "background_playback", "unknown", "test_unverified"])
    parser.add_argument("--allow-asr", action="store_true", help="Permit sending only this selected range to the configured ASR")
    parser.add_argument("--allow-agent", action="store_true", help="Permit sending resulting text to the configured model")
    parser.add_argument("--focus", type=int, nargs=2, metavar=("START", "END"), help="Focus inside selected range, after the first packet")
    parser.add_argument("--occurred-at", help="Only a known timezone-aware capture time; do not guess from import time")
    parser.add_argument("--recording-file",type=Path,help="Original noteYYYYMMDD-HHMMSS.opus; selected raw must match its bytes")
    parser.add_argument("--recording-offset-seconds",type=int,default=0,help="Where raw begins inside recording-file")
    args = parser.parse_args()
    if args.start_seconds < 0 or not 1 <= args.seconds <= 300:
        parser.error("Select 1–300 seconds explicitly")
    data = args.raw.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != args.expected_sha256 or len(data) % 40:
        parser.error("Source hash differs or file contains a partial codec packet")
    selected = data[args.start_seconds * 2000:(args.start_seconds + args.seconds) * 2000]
    if len(selected) != args.seconds * 2000:
        parser.error("Selected audio range is unavailable")
    if args.focus and not 0 < args.focus[0] < args.focus[1] <= args.seconds:
        parser.error("Focus must be within selected audio and start after zero")
    from heartball_recording_time import device_local_start
    origin_file=args.recording_file or (args.raw if device_local_start(args.raw.name) else None)
    origin=None
    if origin_file:
        original=origin_file.read_bytes();offset=args.recording_offset_seconds if args.recording_file else 0
        if offset<0 or original[offset*2000:offset*2000+len(data)]!=data or not device_local_start(origin_file.name):parser.error('Original recording provenance does not match raw bytes')
        origin={'filename':origin_file.name,'sha256':hashlib.sha256(original).hexdigest(),'offset_seconds':offset+args.start_seconds}
    manifest = {"original_sha256": digest, "selected_sha256": hashlib.sha256(selected).hexdigest(),
        "selected_byte_range": [args.start_seconds * 2000, (args.start_seconds + args.seconds) * 2000],
        "source_kind": args.source_kind, "focus": args.focus, "occurred_at": args.occurred_at,
        "asr_allowed": args.allow_asr, "agent_allowed": args.allow_agent}
    if origin:manifest['recording_origin']=origin
    sid = stable("explicit-import:" + json.dumps(manifest, sort_keys=True))
    store = Store(args.root); agent = AgentStore(store)
    existing = store.db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
    if existing:
        old = json.loads((Path(existing["directory"]) / "import-manifest.json").read_text())
        if old != manifest:
            raise ValueError("Import identity conflict")
        print(json.dumps({"session_id": sid, "status": existing["status"], "reused": True})); return
    session = store.create_session(sid)
    directory = Path(session["directory"])
    (directory / "import-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    folder = directory / "probe"; folder.mkdir(mode=0o700)
    name = "audio-import-AE22.bin"
    (folder / name).write_bytes(selected); (folder / name).chmod(0o600)
    store.update_session(sid, status="recording")
    selected_time=(dt.datetime.fromisoformat(args.occurred_at)+dt.timedelta(seconds=(origin['offset_seconds'] if origin else args.start_seconds))).isoformat() if args.occurred_at else None
    agent.policy(sid, asr=args.allow_asr, agent=args.allow_agent, source_kind=args.source_kind, occurred_at=selected_time,time_precision='provided_recording_time' if selected_time else 'unknown')
    if origin:agent.recording_origin(sid,origin['filename'],origin['sha256'],origin['offset_seconds'],{'kind':'original_bytes_verified'})
    boundaries = sorted({0, args.seconds, *(args.focus or [])})
    fid = stable("import-focus:" + sid)
    for a, b in zip(boundaries, boundaries[1:]):
        if args.focus and a == args.focus[0]:store.focus_start(fid, sid)
        store.ingest(sid, {"audioFile": name, "audioOffset": a * 2000, "audioBytes": (b - a) * 2000, "time": now()})
        if args.focus and b == args.focus[1]:store.focus_end(fid)
    store.finish(sid)
    store.update_session(sid, status="completed", archive=json.dumps({"status": "explicit_local_selection", "sha256": manifest["selected_sha256"], "not_live_capture": True}))
    print(json.dumps({"session_id": sid, "selected_seconds": args.seconds, "focus_id": fid if args.focus else None,
                     "not_live_capture": True, "hardware_commands": 0}))


if __name__ == "__main__":main()

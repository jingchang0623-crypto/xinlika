#!/usr/bin/env python3
"""Inspect saved/live evidence without opening BLE or controlling the recorder."""
import argparse
import datetime as dt
import json
from pathlib import Path
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("capture", type=Path)
args = parser.parse_args()
events = args.capture / "events.ndjson"
summary = args.capture / "capture-summary.json"
last = last_audio = last_snapshot = beginning = None
recovery = []
changes = []
audio_frames = audio_bytes = 0
with events.open(encoding="utf-8") as source:
    for line in source:
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue  # A live writer may not have finished its last line yet.
        beginning = beginning or row
        last = row
        if "audioFile" in row:
            last_audio = row
            audio_frames += 1
            audio_bytes += row["audioBytes"]
        if row.get("event") == "snapshot":
            last_snapshot = row
        if row.get("event") == "recovery_result":
            recovery.append(row)
        if row.get("event") == "physical_file_change":
            changes.append(row)

def age(row):
    if row is None:
        return None
    return time.time() - dt.datetime.fromisoformat(row["time"].replace("Z", "+00:00")).timestamp()

result = {"capture": str(args.capture.resolve()), "captureSummaryExists": summary.exists(),
          "audioFramesIndexed": audio_frames, "audioBytesIndexed": audio_bytes,
          "lastAudioAgeSeconds": age(last_audio), "lastEvidenceAgeSeconds": age(last),
          "lastSnapshot": last_snapshot, "recoveryResults": recovery, "fileChanges": changes,
          "continuousAudioProven": False, "hardwareVadProven": False}
if beginning:
    result["beganAt"] = beginning.get("time")
    result["requestedSeconds"] = beginning.get("requestedSeconds")
if summary.exists():
    result["summary"] = json.loads(summary.read_text())
print(json.dumps(result, ensure_ascii=False, indent=2))

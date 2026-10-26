#!/usr/bin/env python3
"""Read-only analysis of local CB08 probe evidence. Never treats a transport gap as silence.

Uses only Python's standard library plus a configured ffmpeg executable. The explicit
--decode-cb08-40 option selects the vendor's 40-byte/20ms baseline; no tail is trimmed.
Energy measurements are silence candidates, not a speech detector or a hardware VAD test.
"""
from __future__ import annotations

import argparse
import array
import bisect
import datetime as dt
import hashlib
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import uuid


def ogg_crc(data: bytes) -> int:
    value = 0
    for byte in data:
        value ^= byte << 24
        for _ in range(8):
            value = ((value << 1) ^ (0x04C11DB7 if value & 0x80000000 else 0)) & 0xFFFFFFFF
    return value


def page(packets: list[bytes], sequence: int, granule: int, flags: int) -> bytes:
    laces = []
    for packet in packets:
        count = len(packet)
        while count >= 255:
            laces.append(255)
            count -= 255
        laces.append(count)
    header = struct.pack("<4sBBQIIIB", b"OggS", 0, flags, granule, 0x43423038, sequence, 0, len(laces))
    encoded = bytearray(header + bytes(laces) + b"".join(packets))
    struct.pack_into("<I", encoded, 22, ogg_crc(encoded))
    return bytes(encoded)


def wrap_cb08(raw: Path, output: Path) -> int:
    size = raw.stat().st_size
    if size == 0 or size % 40:
        raise ValueError(f"{raw.name}: {size} bytes is not a positive multiple of 40; no bytes trimmed")
    # Zero pre-skip is deliberate: the raw stream has no encoder-delay metadata.
    # This is a decoding fixture, not a claim about capture start latency or source time.
    head = struct.pack("<8sBBHIhB", b"OpusHead", 1, 1, 0, 16000, 0, 0)
    tags = b"OpusTags" + struct.pack("<I", 10) + b"CB08 probe" + struct.pack("<I", 0)
    with raw.open("rb") as source, output.open("xb") as dest:
        dest.write(page([head], 0, 0, 2))
        dest.write(page([tags], 1, 0, 0))
        index, granule = 2, 0
        while chunk := source.read(40 * 50):
            packets = [chunk[i:i + 40] for i in range(0, len(chunk), 40)]
            granule += 960 * len(packets)
            dest.write(page(packets, index, granule, 4 if source.tell() == size else 0))
            index += 1
    return size // 40


def decode_energy(ogg: Path, directory: Path, ffmpeg: str, quiet_dbfs: float) -> dict:
    stderr = directory / (ogg.stem + "-decoder.txt")
    windows = directory / (ogg.stem + "-energy.ndjson")
    sample_count = quiet_samples = count = 0
    with stderr.open("wb") as log, windows.open("x", encoding="utf-8") as energy:
        process = subprocess.Popen([
            ffmpeg, "-nostdin", "-v", "error", "-xerror", "-err_detect", "explode",
            "-i", str(ogg), "-map", "0:a:0", "-ac", "1", "-ar", "16000", "-f", "s16le", "pipe:1",
        ], stdout=subprocess.PIPE, stderr=log)
        assert process.stdout is not None
        try:
            while block := process.stdout.read(6400):  # <= 200ms of PCM in memory
                if len(block) % 2:
                    raise ValueError("decoder produced a partial Int16 sample")
                samples = array.array("h", block)
                if sys.byteorder != "little":
                    samples.byteswap()
                square = sum(x * x for x in samples)
                rms = math.sqrt(square / len(samples)) / 32768
                peak = max(abs(x) for x in samples) / 32768
                dbfs = 20 * math.log10(max(rms, 1e-12))
                quiet = dbfs < quiet_dbfs
                row = {"contentOffsetSeconds": sample_count / 16000, "samples": len(samples),
                       "rmsDbfs": round(dbfs, 3), "peakDbfs": round(20 * math.log10(max(peak, 1e-12)), 3),
                       "quietCandidate": quiet}
                energy.write(json.dumps(row) + "\n")
                sample_count += len(samples)
                quiet_samples += len(samples) if quiet else 0
                count += 1
            return_code = process.wait(timeout=15)
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
    return {"decoderExitCode": return_code, "decodedSamples": sample_count, "decodedSeconds": sample_count / 16000,
            "quietCandidateSeconds": quiet_samples / 16000, "energyWindows": count,
            "energyFile": windows.name, "decoderLog": stderr.name,
            "warning": "Energy only; quiet speech may be below threshold; no audio removed. Offsets exclude transport gaps."}


def analyze(capture: Path, output: Path, decode: bool, ffmpeg: str, quiet_dbfs: float,
            card_paths: list[Path]) -> dict:
    capture = capture.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    summary = json.loads((capture / "capture-summary.json").read_text())
    expected: dict[str, int] = {}
    frames: dict[str, int] = {}
    arrivals: list[float] = []
    rollovers, recoveries, problems = [], [], []
    derived_changes = []
    last_known_snapshot = None
    actual_events = 0
    with (capture / "events.ndjson").open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                problems.append(f"invalid/truncated event at line {line_number}")
                continue
            actual_events += 1
            if row.get("event") == "recovery_result":
                recoveries.append(row)
            if row.get("event") == "physical_file_change":
                rollovers.append(row)
            if row.get("event") == "snapshot" and row.get("filename") not in (None, "", "unknown"):
                if last_known_snapshot and row["filename"].split(".")[0].lower() != last_known_snapshot["filename"].split(".")[0].lower():
                    derived_changes.append({
                        "event": "physical_file_change_derived_from_snapshots",
                        "previous": last_known_snapshot["filename"], "current": row["filename"],
                        "previousSeconds": last_known_snapshot.get("seconds", "unknown"),
                        "currentSeconds": row.get("seconds", "unknown"),
                        "earliestObservationUptime": str(last_known_snapshot["uptime"]),
                        "latestObservationUptime": str(row["uptime"]),
                        "cause": "unknown_verify_cap_rollover_vs_manual_change",
                    })
                last_known_snapshot = row
            if "audioFile" not in row:
                continue
            name = row["audioFile"]
            if not isinstance(name, str) or Path(name).name != name or not name.startswith("audio-") or not name.endswith(".bin"):
                raise ValueError("unsafe audio filename in evidence")
            if row["audioOffset"] != expected.get(name, 0):
                problems.append(f"noncontiguous audio index: {name} at event {line_number}")
            expected[name] = row["audioOffset"] + row["audioBytes"]
            frames[name] = frames.get(name, 0) + 1
            arrivals.append(float(row["uptime"]))

    for change in derived_changes:
        if not any(r["previous"] == change["previous"] and r["current"] == change["current"]
                   and abs(float(r["latestObservationUptime"]) - float(change["latestObservationUptime"])) < 1
                   for r in rollovers):
            rollovers.append(change)
    rollovers.sort(key=lambda r: float(r["latestObservationUptime"]))
    references = [(str(path), path.read_bytes()) for path in card_paths]
    # Deliberately do not concatenate card files: their real-time gap is not known.
    streams = []
    for name, size in expected.items():
        raw = (capture / name).resolve()
        if raw.parent != capture:
            raise ValueError("audio symlink escapes capture directory")
        with raw.open("rb") as source:
            hasher = hashlib.sha256()
            while chunk := source.read(1024 * 1024):
                hasher.update(chunk)
            digest = hasher.hexdigest()
        item = {"file": name, "indexedBytes": size, "actualBytes": raw.stat().st_size,
                "businessFrames": frames[name], "sha256": digest}
        if item["actualBytes"] != size:
            problems.append(f"audio size differs from journal: {name}")
        if references:
            payload = raw.read_bytes()
            matches = []
            for path, data in references:
                at = data.find(payload) if payload else -1
                if at >= 0:
                    matches.append({"cardFile": path, "offset": at, "length": len(payload),
                                    "uniqueWithinFile": data.find(payload, at + 1) < 0})
            item["exactCardMatches"] = matches
            item["referenceVerdict"] = (
                "exact_unique_card_range_found" if len(matches) == 1 and matches[0]["uniqueWithinFile"] else
                "ambiguous_exact_matches" if matches else
                "no_whole_stream_match_may_cross_card_files_or_contain_gap_or_different_encoding"
            )
        if decode:
            try:
                ogg = output / (Path(name).stem + ".ogg")
                packets = wrap_cb08(raw, ogg)
                item["decode"] = decode_energy(ogg, output, ffmpeg, quiet_dbfs)
                item["decode"]["expectedSamplesUnder20msBaseline"] = packets * 320
                item["decode"]["baselineSampleCountMatches"] = item["decode"]["decodedSamples"] == packets * 320
                if item["decode"]["decoderExitCode"] != 0 or not item["decode"]["baselineSampleCountMatches"]:
                    problems.append(f"decoder failure or baseline sample count mismatch: {name}")
            except (OSError, ValueError) as error:
                item["decodeError"] = str(error)
                problems.append(str(error))
        streams.append(item)

    if summary.get("failure") or summary.get("droppedSubmissions", 0):
        problems.append("capture reports queue drops or write failure")
    if sum(expected.values()) != summary.get("audio", {}).get("bytes", 0):
        problems.append("summary audio byte count differs from indexed bytes")
    if not expected:
        problems.append("no realtime audio captured")
    gaps = [{"fromUptime": a, "toUptime": b, "arrivalSeconds": b - a}
            for a, b in zip(arrivals, arrivals[1:]) if b - a > 1]
    for boundary in rollovers:
        begin = float(boundary["earliestObservationUptime"])
        end = float(boundary["latestObservationUptime"])
        left = max(0, bisect.bisect_left(arrivals, begin) - 1)
        right = min(len(arrivals), bisect.bisect_right(arrivals, end) + 1)
        window = arrivals[left:right]
        boundary["maxArrivalGapInObservationBracket"] = max((b - a for a, b in zip(window, window[1:])), default=None)
        boundary["audioContinuityVerdict"] = "not_established_requires_decoded_time_markers_and_card_reference"
    result = {"capture": str(capture), "captureOutcome": summary.get("outcome"), "eventsRead": actual_events, "streams": streams,
              "problems": problems, "integrityVerdict": "failed_or_incomplete" if problems else "indexed_audio_consistent",
              "recoveryObservations": recoveries, "fileChanges": rollovers, "arrivalGapsOverOneSecond": gaps,
              "quietThresholdDbfs": quiet_dbfs,
              "hardwareVadVerdict": "not_tested_energy_on_host_cannot_establish_firmware_vad",
              "threeHourContinuityVerdict": "not_established" if not rollovers else "file_change_observed_continuity_requires_reference",
              "note": "Arrival gaps are not silence and are not exact lost-audio durations. Decoding success alone cannot prove completeness."}
    (output / "analysis.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--decode-cb08-40", action="store_true")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--quiet-dbfs", type=float, default=-50)
    parser.add_argument("--card-raw", type=Path, action="append", default=[])
    args = parser.parse_args()
    if not math.isfinite(args.quiet_dbfs) or not -120 <= args.quiet_dbfs <= 0:
        parser.error("quiet-dbfs must be within -120..0")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = args.output or args.capture / ("analysis-" + stamp + "-" + uuid.uuid4().hex[:8])
    ffmpeg = shutil.which(args.ffmpeg) if args.decode_cb08_40 else args.ffmpeg
    if args.decode_cb08_40 and ffmpeg is None:
        parser.error("ffmpeg not found")
    try:
        result = analyze(args.capture, output, args.decode_cb08_40, ffmpeg, args.quiet_dbfs, args.card_raw)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Analysis failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"analysis": str(output / "analysis.json"), "integrityVerdict": result["integrityVerdict"],
                      "streams": len(result["streams"]), "problems": result["problems"],
                      "threeHourContinuityVerdict": result["threeHourContinuityVerdict"]}, ensure_ascii=False, indent=2))
    return 0 if not result["problems"] else 1


if __name__ == "__main__":
    sys.exit(main())

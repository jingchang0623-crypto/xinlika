#!/usr/bin/env python3
"""Compare real CB08 audio across upload boundaries; ASR agreement is not ground truth."""

import argparse
from datetime import datetime, timezone
import difflib
import hashlib
import html
import importlib.util
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", required=True, type=Path, help="explicit fixed CB08 snapshot, 40B/20ms")
    parser.add_argument("--output", required=True, type=Path, help="new private output directory")
    parser.add_argument("--seconds", type=int, default=300, choices=[60, 120, 180, 240, 300])
    parser.add_argument("--start-seconds", type=int, default=0, help="explicit offset in the selected saved file")
    parser.add_argument("--prepare-only", action="store_true", help="create private listening materials without loading credentials or calling ASR")
    parser.add_argument("--baseline", type=Path, help="optional previously measured result for this exact input")
    parser.add_argument("--source-kind", choices=["unverified", "background_playback", "live_conversation"], default="unverified",
                        help="caller-confirmed source category; never inferred from the transcript")
    args = parser.parse_args()
    if args.start_seconds < 0:
        parser.error("start-seconds must be non-negative")
    if args.prepare_only and args.baseline:
        parser.error("prepare-only cannot import an ASR baseline")
    helper = module("voxgate_synthetic", ROOT / "scripts/evaluate-voxgate.py")
    codec = module("cb08_codec", ROOT / "scripts/analyze-cb08-capture.py")
    # This command explicitly submits the selected private sample to the configured ASR backend.
    with args.raw.open("rb") as source:
        source.seek(args.start_seconds * 2000)
        raw = source.read(args.seconds * 2000)
    if len(raw) != args.seconds * 2000:
        parser.error("Not enough complete audio for the requested fixed snapshot")
    digest = hashlib.sha256(raw).hexdigest()
    cached = json.loads(args.baseline.read_text()) if args.baseline else None
    if cached is not None and cached.get("source_sha256") != digest:
        parser.error("Baseline source_sha256 does not match this exact raw snapshot")
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    config = None if args.prepare_only else json.loads((ROOT / ".build/voxgate-evaluation/runtime/config.json").read_text())
    base = None if config is None else f"http://127.0.0.1:{config['server']['port']}"
    original_hash = hashlib.sha256()
    with args.raw.open("rb") as source:
        while block := source.read(1024 * 1024):
            original_hash.update(block)
    report = {"started_at": datetime.now(timezone.utc).isoformat(), "source_sha256": digest,
              "source_bytes": len(raw), "source_audio_seconds": args.seconds,
              "ground_truth": None, "source_kind": args.source_kind,
              "speaker_labels": "unverified", "field_noise_labels": "unverified",
              "warning": "Cross-run disagreements require listening; no accuracy or speaker-count claim is made.",
              "original_file_sha256": original_hash.hexdigest(), "original_file_bytes": args.raw.stat().st_size,
              "original_start_seconds": args.start_seconds,
              "selected_byte_range": [args.start_seconds * 2000, (args.start_seconds + args.seconds) * 2000],
              "asr_requested": not args.prepare_only,
              "evaluation_config": None if config is None else config.get("evaluation"), "batches": [], "boundary_windows": []}

    def save():
        (args.output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))

    def request(name, start, end):
        source = args.output / (name + ".bin")
        source.write_bytes(raw[start * 2000:end * 2000])
        source.chmod(0o600)
        ogg = source.with_suffix(".ogg")
        codec.wrap_cb08(source, ogg)
        if args.prepare_only:
            result = {"http_status": None, "response": {}, "asr_requested": False}
        else:
            result = helper.transcribe(base, config["server"]["auth_token"], ogg, 330)
        result.update({"start_seconds": start, "end_seconds": end, "audio_file": ogg.name})
        print(f"{name}: local listening material only" if args.prepare_only else
              f"{name}: HTTP {result['http_status']}, {result['elapsed_seconds']}s, "
              f"{len(result.get('response', {}).get('text', ''))} characters", flush=True)
        return result

    if args.baseline:
        report["baseline"] = cached
        report["baseline_provenance"] = "Previously measured result with matching raw snapshot hash"
    else:
        report["baseline"] = request("whole", 0, args.seconds)
    save()
    for start in range(0, args.seconds, 60):
        report["batches"].append(request(f"minute-{start // 60:02d}", start, start + 60))
        save()
    joined = "".join(r.get("response", {}).get("text", "") for r in report["batches"])
    baseline = report["baseline"].get("response", {}).get("text", "")
    a, b = helper.normalize(baseline), helper.normalize(joined)
    report["minute_batch_text"] = joined
    report["whole_vs_minutes_normalized_edit_fraction"] = None if args.prepare_only else round(helper.distance(a, b) / max(1, len(a)), 4)
    save()
    for boundary in range(60, args.seconds, 60):
        result = request(f"boundary-{boundary:03d}", boundary - 5, boundary + 5)
        text = helper.normalize(result.get("response", {}).get("text", ""))
        match = difflib.SequenceMatcher(None, text, b, autojunk=False).find_longest_match()
        result["longest_exact_run_fraction_in_minute_text"] = None if args.prepare_only else round(match.size / max(1, len(text)), 4)
        report["boundary_windows"].append(result)
        save()
    sections = []
    for title, result in [("Whole-file baseline", report["baseline"])] + [
        (f"Minute {i + 1}", item) for i, item in enumerate(report["batches"])
    ] + [(f"Boundary {item['start_seconds'] + 5}s", item) for item in report["boundary_windows"]]:
        player = f'<audio controls src="{html.escape(result["audio_file"])}"></audio>' if "audio_file" in result else ""
        text = html.escape(result.get("response", {}).get("text", ""))
        sections.append(f"<section><h2>{html.escape(title)}</h2>{player}<p>{text}</p></section>")
    labels = {"unverified": "来源尚未确认", "background_playback": "背景播放声音，不计入现场多人对话验收", "live_conversation": "调用者确认的现场对话，仍需核对说话人及原话"}
    review = '<!doctype html><meta charset="utf-8"><title>Real CB08 ASR review</title><style>body{font:18px/1.8 system-ui;max-width:900px;margin:32px auto;padding:0 20px}section{border-top:1px solid #ccc;padding:20px 0}audio{width:100%}</style><h1>真实录音分段复核</h1><p>' + labels[args.source_kind] + '</p><p>未提供人工参考稿；模型之间一致不等于准确。请听边界前后的原声，核对漏字、错词、重复及说话人来源。</p>' + "".join(sections)
    (args.output / "review.html").write_text(review)
    print(f"Private review: {args.output / 'review.html'}", flush=True)
    failures = [] if args.prepare_only else [r for r in [report["baseline"], *report["batches"], *report["boundary_windows"]]
                                           if r["http_status"] != 200 or not r.get("response", {}).get("text", "").strip()]
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()

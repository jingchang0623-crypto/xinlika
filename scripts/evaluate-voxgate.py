#!/usr/bin/env python3
"""Generate synthetic Chinese fixtures and measure minute-batch ASR over HTTP."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
import wave


ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / ".build/voxgate-evaluation"
FIXTURES = STATE / "fixtures"

# Each thirty-second slot has a different opening and closing checkpoint.
PASSAGES = [
    ("云杉计划", "保留原始录音", "今天开始讨论云杉计划。我们准备把蓝牙录音卡接入深脑个人助手。手机收到音频以后先保存，再按分钟上传，服务端负责转成文字并整理上下文。网络断开时不要丢掉已经收到的内容，等连接恢复以后继续补传。这个实验先看内容有没有遗漏，不要求每句话立刻显示。请保留原始录音。"),
    ("松鼠会议", "确认交付日期", "接下来是松鼠会议的安排。明天下午我会和张经理讨论新版本的同步方案。请把会议地点记为海棠会议室，把主要议题记为离线恢复和重复上传。负责人需要检查失败记录，不能把下载完成直接当成识别成功。如果中途有人更正内容，要让后面的分析使用更正后的结果。会议结束前确认交付日期。"),
    ("海豚清单", "检查尾部内容", "现在记录海豚清单。采购录音设备以前，需要比较声音质量、续航和蓝牙连接稳定性。测试应该包括安静房间、普通办公室和走路时的环境。不能只拿合成语音的效果代表真实会议，也不能用一次成功证明全天可靠。遇到没有声音的片段，仍然保留时间信息。完成以后检查尾部内容。"),
    ("银杏预算", "避免重复计费", "下面讨论银杏预算。转写服务要统计实际处理了多少音频，失败重试用了多少时间，以及结果是否可以复用。同一段录音重传以后，应该得到同一个任务，不能重复触发分析。服务暂时不可用时，先显示等待处理，并让用户知道原始文件仍然安全保存。恢复以后继续排队，避免重复计费。"),
    ("白鹭反馈", "区分事实推断", "这一段是白鹭反馈。个人助手需要理解用户当前的目标，但没有必要不停打断用户。几分钟汇总一次上下文，也能发现承诺、提醒和没有完成的事项。如果一句话来自旁边播放的视频，不应该直接写成用户自己的经历。用户指出不是自己说的以后，需要修正相关记忆。请区分事实推断。"),
    ("珊瑚旅程", "保存时间范围", "接下来记录珊瑚旅程。周末准备带家人去海边散步，出门以前检查天气和交通。路上如果临时改变目的地，助手应当更新安排，而不是继续提醒旧计划。录音中的日期来自实际采集时间，不能使用上传时间代替。网络恢复后收到昨天的内容，也要按昨天归档。每个片段保存时间范围。"),
    ("青竹项目", "核对说话归属", "现在回到青竹项目。产品讨论中有人负责设计，有人负责开发，也有人只是提出建议。整理任务时需要区分谁承诺了行动，谁只是描述一种可能性。没有明确负责人时可以标记待确认，不要随便替用户接下任务。后续补充的信息要能关联回原来的讨论。最终结果需要核对说话归属。"),
    ("星河备忘", "展示处理进度", "这部分叫作星河备忘。手机应用可以先显示已经保存了多少音频，再显示上传和识别分别进行到了哪里。如果蓝牙断开期间存在缺口，应当明确记录，不要假装中间一直安静。回到设备附近以后可以补齐历史内容，但补回来的片段需要去重。用户打开页面时能够看到结果，并且展示处理进度。"),
    ("山茶复盘", "保留纠正记录", "接下来进行山茶复盘。今天的实验需要检查开头、中间和结尾的内容是否都在。不能只因为接口返回成功，就认为整段录音完全正确。我们还要检查名字、项目名称和任务状态，观察分段位置有没有切断句子。如果用户修改转写，系统应该保存修改来源和版本，并且保留纠正记录。"),
    ("灯塔收尾", "全部测试结束", "最后进入灯塔收尾。我们已经讨论了采集、上传、转写、记忆和反馈这几个环节。下一步先用分钟级音频跑通完整链路，再决定是否需要更快的更新。手机负责可靠保存，服务端负责持续处理，出现故障时都能从记录的位置继续。这是长音频的最后一个检查点，请确认没有遗漏，全部测试结束。"),
]


def run(command):
    return subprocess.check_output(command, text=True)


def probe(path):
    return json.loads(run(["ffprobe", "-v", "error", "-show_entries", "format=duration,size", "-of", "json", str(path)]))["format"]


def fixed_opus_packets(path, count):
    data, offset, pending, packets = path.read_bytes(), 0, bytearray(), []
    while offset < len(data):
        if data[offset:offset + 4] != b"OggS":
            raise ValueError("Invalid synthetic Ogg page")
        n = data[offset + 26]
        sizes = data[offset + 27:offset + 27 + n]
        cursor = offset + 27 + n
        for size in sizes:
            pending.extend(data[cursor:cursor + size])
            cursor += size
            if size < 255:
                packet = bytes(pending)
                pending.clear()
                if not packet.startswith((b"OpusHead", b"OpusTags")):
                    if len(packet) != 40:
                        raise ValueError("Synthetic Opus frame does not match CB08's 40B baseline")
                    packets.append(packet)
        offset = cursor
    if pending or len(packets) < count:
        raise ValueError("Incomplete synthetic Opus fixture")
    return b"".join(packets[:count])


def fixtures():
    FIXTURES.mkdir(parents=True, exist_ok=True)
    slots = []
    for i, (_, _, text) in enumerate(PASSAGES):
        assert all(normalize(marker) in normalize(text) for marker in PASSAGES[i][:2])
        stem = FIXTURES / f"slot-{i:02d}"
        stem.with_suffix(".txt").write_text(text)
        subprocess.run(["say", "-v", "Tingting", "-r", "210", "-f", str(stem.with_suffix('.txt')), "-o", str(stem.with_suffix('.aiff'))], check=True)
        duration = float(probe(stem.with_suffix(".aiff"))["duration"])
        speed = max(1.0, duration / 29.0)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(stem.with_suffix('.aiff')),
                        "-af", f"atempo={speed:.8f},apad,atrim=duration=30", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(stem.with_suffix('.wav'))], check=True)
        with wave.open(str(stem.with_suffix('.wav')), "rb") as source:
            slots.append(source.readframes(source.getnframes()))
    manifest = {"source": "macOS say / Tingting, synthetic, no personal recordings", "cases": {}}
    for seconds in (60, 300):
        count = seconds // 30
        wav = FIXTURES / f"batch-{seconds}s.wav"
        with wave.open(str(wav), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(16000)
            output.writeframes(b"".join(slots[:count]))
        ogg = wav.with_suffix(".ogg")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-c:a", "libopus", "-b:a", "16k", "-vbr", "off", str(ogg)], check=True)
        (FIXTURES / f"batch-{seconds}s-cb08-raw.bin").write_bytes(fixed_opus_packets(ogg, seconds * 50))
        manifest["cases"][str(seconds)] = {
            "expected_text": "".join(p[2] for p in PASSAGES[:count]),
            "checkpoints": [p[j] for p in PASSAGES[:count] for j in (0, 1)],
            "wav": probe(wav), "ogg": probe(ogg),
        }
    (FIXTURES / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(json.dumps({k: {"wav": v["wav"], "ogg": v["ogg"]} for k, v in manifest["cases"].items()}, ensure_ascii=False), flush=True)


def normalize(text):
    return "".join(c.lower() for c in unicodedata.normalize("NFKC", text) if c.isalnum())


def distance(reference, actual):
    previous = list(range(len(actual) + 1))
    for i, char in enumerate(reference, 1):
        current = [i]
        for j, other in enumerate(actual, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (char != other)))
        previous = current
    return previous[-1]


def transcribe(base, token, audio, timeout):
    boundary = "shennao-" + uuid.uuid4().hex
    body = bytearray()
    for key, value in (("model", "voxgate"), ("response_format", "json")):
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
    mime = "audio/ogg" if audio.suffix == ".ogg" else "audio/wav"
    body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{audio.name}"\r\nContent-Type: {mime}\r\n\r\n'.encode())
    body.extend(audio.read_bytes())
    body.extend(f'\r\n--{boundary}--\r\n'.encode())
    request = urllib.request.Request(base + "/v1/audio/transcriptions", bytes(body), {
        "Authorization": "Bearer " + token, "Content-Type": "multipart/form-data; boundary=" + boundary})
    start = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status, payload = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, payload = error.code, error.read()
    except (OSError, TimeoutError) as error:
        return {"http_status": None, "elapsed_seconds": round(time.monotonic() - start, 3), "error": str(error)}
    return {"http_status": status, "elapsed_seconds": round(time.monotonic() - start, 3),
            "response": json.loads(payload)}


def benchmark(args):
    config = json.loads((STATE / "runtime/config.json").read_text())
    base = f"http://127.0.0.1:{config['server']['port']}"
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    destination = STATE / "results" / datetime.now(timezone.utc).strftime("batch-%Y%m%dT%H%M%SZ")
    destination.mkdir(parents=True, exist_ok=False)
    report = {"started_at": datetime.now(timezone.utc).isoformat(), "base_url": base,
              "source_revision": run(["git", "-C", str(STATE / 'source'), "rev-parse", "HEAD"]).strip(),
              "evaluation_config": config.get("evaluation", {"asr_chunk_seconds": 30, "patch": "unmodified baseline"}),
              "fixture_source": manifest["source"], "results": []}
    for seconds in args.seconds:
        case = manifest["cases"][str(seconds)]
        for fmt in args.formats:
            audio = FIXTURES / f"batch-{seconds}s.{fmt}"
            for iteration in range(args.runs):
                print(f"Submitting {seconds}s {fmt}, run {iteration + 1}", flush=True)
                result = transcribe(base, config["server"]["auth_token"], audio, args.timeout)
                text = result.get("response", {}).get("text", "")
                reference, actual = normalize(case["expected_text"]), normalize(text)
                positions = [actual.find(normalize(c)) for c in case["checkpoints"]]
                result.update({"audio_seconds": seconds, "format": fmt, "file_bytes": audio.stat().st_size,
                               "run": iteration + 1, "processing_ratio": round(result["elapsed_seconds"] / seconds, 4),
                               "expected_characters": len(reference), "recognized_characters": len(actual),
                               "normalized_character_error_rate": round(distance(reference, actual) / max(1, len(reference)), 4),
                               "checkpoints_found": sum(p >= 0 for p in positions), "checkpoints_total": len(positions),
                               "checkpoints_in_order": all(p >= 0 for p in positions) and positions == sorted(positions),
                               "found_checkpoints_in_order": [p for p in positions if p >= 0] == sorted(p for p in positions if p >= 0),
                               "missing_checkpoints": [c for c, p in zip(case["checkpoints"], positions) if p < 0]})
                report["results"].append(result)
                (destination / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
                print(json.dumps({k: v for k, v in result.items() if k != "response"}, ensure_ascii=False), flush=True)
    print(f"Report: {destination / 'report.json'}", flush=True)
    if any(r["http_status"] != 200 or not r.get("response", {}).get("text", "").strip()
           or r["normalized_character_error_rate"] > args.max_cer for r in report["results"]):
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["fixtures", "benchmark"])
    parser.add_argument("--seconds", type=int, choices=[60, 300], nargs="+", default=[60, 300])
    parser.add_argument("--formats", choices=["wav", "ogg"], nargs="+", default=["ogg"])
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=330)
    parser.add_argument("--max-cer", type=float, default=0.15, help="fail a synthetic run if normalized character error exceeds this fraction")
    args = parser.parse_args()
    if args.runs < 1 or args.timeout <= 0 or not 0 <= args.max_cer <= 1:
        parser.error("runs and timeout must be positive; max-cer must be between zero and one")
    if args.action == "fixtures":
        fixtures()
    else:
        benchmark(args)


if __name__ == "__main__":
    main()

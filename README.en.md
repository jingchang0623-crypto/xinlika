# Xinlika · 心力卡

**Everyday context for your personal agent, on iPhone too. Trace a claim, correct its source, ask again.**

An independent open-source project inspired by OPPO's AI Xinliqiu. Native **iPhone + Mac source is available**; cross-brand Android is planned. Self-host the backend and choose your ASR and text model.

[中文](README.md) · [Full app setup](docs/full-app.md) · [No-hardware quickstart](docs/quickstart.md) · [Demo kit](docs/launch/demo.md) · [Fork guide](docs/fork-guide.md)

![Xinlika: iPhone and Mac today; Android planned](assets/launch/cover.png)

Developer preview [v0.2.0](https://github.com/jingchang0623-crypto/xinlika/releases/tag/v0.2.0). Backend MIT; native clients GPL-3.0-only. Build from source; no pre-signed app is supplied.

## Main update · 2026-10-26

The latest source includes iPhone 0.3.10 capture/recovery queues, a shared event timeline, reversible interest feedback, versioned v6 Skills, incremental/rolling event processing, cross-conversation links and read-only MCP. [Update evidence](docs/github-sync-2026-10-26.md) · [Optional runtime setup](docs/runtime-v6.md). The v0.2.0 tag remains unchanged. This export does not claim a new physical-device or semantic-quality acceptance test.

## What makes it worth trying?

- **iPhone today, Android next.** iOS 17+ and macOS 14+ clients are included. No public Android or Watch app exists yet. Android is a concrete [staged contribution plan](docs/android-plan.md), not a universal compatibility claim.
- **A low hardware entry point.** The maintainer reports a sub-CNY 200 price for the recorder used in this project (2026-10-23). This is a hardware-only reference, not a verified current retailer quote or total running cost. Verify CB08 model/firmware before purchase; ASR, models, servers and storage are extra.
- **Your deployment, your model choice.** Use your own service and device credentials. When you use external models, the relevant content is sent to those services.
- **Sources that can be corrected.** Keep literal sources and revisions; corrections invalidate dependent answers. A transport batch is not automatically a semantic event, and a topic may span conversations.
- **Code you can extend.** Capture/recovery protocols, event/topic processing and observe → respond → review → publish prompts are included. Read-only MCP export and explicit chat-file import are now included; see [runtime setup](docs/runtime-v6.md).

The [October 16 GeekPark hands-on report](https://www.geekpark.net/news/372428) described the Xinliqiu preview as requiring OPPO, OnePlus or Realme phones, with other brands unsupported at that time. This dated report is not a permanent official compatibility list. Xinlika uses **CB08, not OPPO hardware or services**. See [comparison sources and boundaries](docs/oppo-context.md).

## Watch the native path

![Three native iPhone screenshots: synthetic event, literal source and corrected answer](assets/launch/native-walkthrough.gif)

This is a three-screenshot slideshow from the actual iPhone simulator, not continuous footage. Inputs and model responses are synthetic fixtures; native UI, HTTP, SQLite and LangGraph are real. It demonstrates the workflow, not ASR or model quality. [Originals and reproduction](docs/launch/demo.md).

## Run it

For the no-credential, no-hardware synthetic demo:

```bash
git clone https://github.com/jingchang0623-crypto/xinlika.git
cd xinlika
PYTHON=python3.12 ./scripts/bootstrap.sh
.venv/bin/python examples/demo.py
```

Use an installed Python 3.11+ executable. Open the HTML path printed by the demo to compare a timeline, linked topics and cited answers before/after a correction.

For the complete app: provision your own model/ASR services, generate private connection files, start the shared backend, then build the Mac and iPhone clients. Follow the [full guide](docs/full-app.md). A Mac, Xcode and XcodeGen are required; physical iPhone installation needs your signing setup. Start with text input without a recorder. The CB08 path additionally needs authorized ASR. A physical phone cannot reach a Mac through the phone's own `127.0.0.1`.

The recommended shared path is CB08 → iPhone → your backend → iPhone/Mac. Optional Mac-local capture uses a separate workspace and does not automatically forward into the shared one.

## Fork something concrete

| Direction | First deliverable |
|---|---|
| Android | Connect, sync and add text; then correction/Q&A, microphone/BLE and device-specific background tests |
| Read-only MCP | Authenticated search/source/topic tools with revisions, timestamps and revocation checks |
| Personal-agent prompts | Grounded, quiet responses with counterexamples and correction invalidation |
| Hardware / ASR | One documented format/device with immutable retry, hashes and source preservation |
| Event and topic quality | Reproducible rescheduling, retraction, late upload and source-correction cases |

The [fork guide](docs/fork-guide.md) lists source files and acceptance criteria. [Report a first run](https://github.com/jingchang0623-crypto/xinlika/issues/new?template=first-run.yml), including failures, without sharing private audio or credentials. [Contributing](CONTRIBUTING.md) · [Roadmap](ROADMAP.md)

## Evidence and limits

v0.2.0 passed clean-clone builds, 193 backend tests, 23 iPhone capture tests, one full native UI flow and 100 core/session-clock checks. The native model is synthetic; Mac native API readback is not a completed Mac window test. [Native validation](docs/native-validation.md).

Earlier development builds have specific locked-iPhone, 75-second outage and CB08 recovery evidence. The new public bundle still needs physical BLE/lock-screen revalidation. All-day lossless capture, battery life, general speaker attribution, automatic activity boundaries and long-term advice quality remain unverified. [Evidence table](docs/evidence.md).

Independent project, not affiliated with or endorsed by OPPO. No equivalent-quality, universal-device, free-service or quantified savings claim. Backend MIT; `clients/` and native-derived launch visuals GPL-3.0-only. Vendor binaries, firmware and model weights are excluded. [Licensing](docs/client-licensing.md) · [Architecture](docs/architecture.md) · [Third-party notices](THIRD_PARTY_NOTICES.md).

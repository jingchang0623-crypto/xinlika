# Xinlika · 心力卡

**Turn everyday recordings into continuous context for a personal agent.**

Inspired by the product idea behind OPPO's AI Xinliqiu, Xinlika explores self-hosted processing, source-linked events, evolving topics and feedback that can be corrected.

[中文](README.md) · [Quickstart](docs/quickstart.md) · [Evidence and limitations](docs/evidence.md)

This first release contains the Python backend, persistent LangGraph workflows, Chinese agent prompts, device ingestion/recovery protocols and regression tests. Version 0.2.0 includes native iPhone/Mac source under GPL-3.0-only, with the backend remaining MIT after the rights holder confirmed relicensing authority. Follow the [full app guide](docs/full-app.md) to build, configure your own model/ASR services and connect a CB08 recorder. No vendor binary SDK is required.

```bash
git clone https://github.com/jingchang0623-crypto/xinlika.git
cd xinlika
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-heartball.txt
python examples/demo.py
```

Python 3.11+; release validation currently covers macOS. The demo needs no hardware, credentials or paid calls. It uses explicitly synthetic inputs and deterministic model responses with the actual persistence, source-validation, query and correction workflows. It writes an HTML report. It does not evaluate ASR or model intelligence.

Core ideas:

- Transport batches are not semantic events; events are not whole activities; topics can span conversations.
- Recording time is distinct from upload or processing time.
- Preserve literal sources and revisions; a correction invalidates dependent answers and suggestions.
- Observe → respond → review → publish. Stay quiet without a useful change.
- A voice match or first-person sentence is not proof of the recorder owner's experience.

Development hardware tests covered iPhone locked capture, recovery after a 75-second server outage, and same-file CB08 streaming recovery under specific firmware conditions. All-day continuity, battery life, general speaker attribution, automatic activity boundaries and long-term coaching quality remain unverified. See the [evidence table](docs/evidence.md).

Good fork directions include new capture adapters, grounded personal-agent prompts, Chinese event segmentation, authorized ASR adapters and a read-only MCP bridge. **No MCP server or Watch app is included yet.**

Independent project; not affiliated with OPPO, and not a client for OPPO hardware or services. No equivalent-quality or cost-saving claims. MIT applies to the backend; clients/ is GPL-3.0-only; model weights and external services have separate terms. See [third-party notices](THIRD_PARTY_NOTICES.md).

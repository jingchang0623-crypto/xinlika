# Changelog

## v0.2.0 — 2026-10-23

- Added native iPhone/Mac source, CoreBluetooth capture, background outbox, recorder recovery, source reading and correction UI under GPL-3.0-only after confirmed relicensing authority. Backend remains MIT.
- Added standalone XcodeGen/SwiftPM builds, private configuration/provisioning and local Mac app packaging. No former team, vendor binaries or old cloud account is required.
- Added configurable authorized ASR adapter, removing the mandatory research input-method service dependency.
- Fixed native text occurrence timestamps and made missing model/ASR configuration explicit before automatic recorder capture.
- Added iPhone UI integration and Mac native readback, with synthetic models and real backend persistence; hardware/quality limits remain explicit.
- See docs/full-app.md, docs/client-licensing.md and docs/native-validation.md.

## v0.1.0 — 2026-10-23

First public developer preview, extracted from the Xinlika development workspace.

- Python backend: immutable ingestion, evidence/revision storage, event/topic/activity projections, feedback invalidation, recovery and backup primitives.
- Persistent observe → respond → review → publish workflow and original Chinese prompts.
- Single-user multi-device API with revocable device credentials.
- Credential-free synthetic walkthrough using the actual backend and LangGraph code.
- Chinese/English README, quickstart, evidence limitations and contribution roadmap.

Legacy Swift clients, vendor SDKs, private recordings and model weights are excluded. MCP and Watch are planned, not shipped. This release does not claim all-day continuity, equivalent OPPO functionality or validated long-term coaching quality.

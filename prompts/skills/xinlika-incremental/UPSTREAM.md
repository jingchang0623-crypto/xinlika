# Upstream reuse

The Python adaptations carry both MIT copyright notices and the full license in
`scripts/heartball_incremental_reuse.py`; the server source export includes that
file. No upstream executable, service, model weights, firmware or private data is
bundled.

- **Omi / Based Hardware Contributors**, MIT,
  `4b4e35fdc9d61a5fb74380202cbc65d0432ecc6e`:
  `backend/utils/episodes/state.py` — clean_text, _clean_list (renamed), bounded
  state rendering; changed to discard complete fields rather than cut JSON.
  `backend/utils/episodes/incremental.py` — adapted new-speech plus prior-state
  prompt semantics, without importing the Firestore/Redis/provider infrastructure.
- **Dayflow / Jerry Liu**, MIT,
  `730d6f84b919998158ff7fdab15e3f032f7d8135`:
  `Dayflow/Dayflow/Core/AI/LLMTypes.swift` and
  `Dayflow/Dayflow/Core/Recording/StorageManager+TimelineCards.swift` — Python
  port of the 45-minute lookback/range-overlap approach, protecting unseen later
  work. The card continuation rules inform the Skill. Minimum ten-minute cards,
  delete-and-reinsert identities and screen-specific attribution are not adopted.

The domain ledger, source-span validation, permissions, retries, ASR reuse,
corrections and client projections remain Xinlika's existing implementation.
The bounded structured editor is a domain operation; Hermes/DeepSeek continue to
provide the general Agent loop for query and explicit relation-repair tasks.

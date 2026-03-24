# OpenOats Review for Contora (2026-03)

## Scope

This review evaluates what `Contora` can productively borrow from `OpenOats` and what should be explicitly excluded.

Reference repository reviewed:
- https://github.com/yazinsai/OpenOats
- latest main commit observed during review: `03ec69a`

## What OpenOats Gets Right

### 1. Simple first-run story

OpenOats keeps the user flow short:
- launch app,
- grant permissions,
- download model on first run,
- start using it.

This is aligned with Contora's product direction: local-first and low-friction.

### 2. Optional advanced flows

OpenOats makes advanced functionality optional:
- knowledge base,
- cloud LLM providers,
- local providers,
- meeting detection.

The base flow still works without forcing complex setup.

This is directly relevant to Contora. Our architecture should preserve:
- recording without cloud account,
- transcription without calendar integration,
- optional enrichment layers.

### 3. Clear artifact model

OpenOats treats the meeting as a durable local artifact rather than a transient transcript string.

Useful patterns:
- saved session files,
- stable local notes folder,
- structured meeting format,
- batch post-processing after recording ends.

This matches Contora's archive-first identity more than Dictator's low-latency action loop.

### 4. Two-pass processing model

OpenOats separates:
- live/online transcription,
- higher-quality batch refinement after the meeting.

This is strong and should influence Contora.

For Contora, this maps well to:
- immediate transcript after stop,
- optional background refinement,
- optional later diarization/post-processing.

### 5. Explicit meeting transcript format

The `meeting-format-spec.md` is one of the most reusable ideas in the repo.

Good properties:
- human-readable,
- grep-friendly,
- LLM-friendly,
- incrementally enrichable,
- suitable as an interop artifact.

Contora should adopt the spirit of this idea, even if not the exact schema.

### 6. Audio import as first-class path

OpenOats supports external audio import through the same transcription flow.

This is useful for Contora because imported recordings, browser downloads, voice notes, and exported meeting files should become first-class sessions rather than second-tier attachments.

### 7. Settings discipline

OpenOats is good at exposing practical operational settings:
- model selection,
- save audio toggle,
- transcription cleanup toggle,
- batch refinement toggle,
- local/cloud provider choice.

This is a better pattern than hiding core pipeline choices behind magic defaults.

## What Contora Should Not Borrow

### 1. Hidden-from-screen-share / anti-detection positioning

OpenOats explicitly markets being hidden from screen sharing.

Even if technically interesting, this is not aligned with Contora's intended use.

Reasons to exclude:
- high abuse potential,
- conflicts with Contora's archive/context identity,
- encourages deceptive use during interviews or monitored calls,
- creates unnecessary trust and reputational risk.

Contora should remain privacy-first, not stealth-first.

### 2. “Talk back during the call” primary interaction model

OpenOats is optimized for real-time prompting and speaking assistance.

Contora should not center its product around:
- answering for the user,
- live interview copilot behavior,
- covert assistance loops.

Contora should center on:
- capture,
- transcript,
- context archive,
- post-meeting processing.

## Recommended Adaptations for Contora

### Adopt Soon

1. Session artifact set
- Keep `.wav`
- Add `.txt`
- Add structured session file (`.json` or `.md`)

2. Import-first architecture
- Imported audio should become a normal session
- Video import should feed the same path after audio extraction

3. Batch refinement stage
- Initial transcript after stop
- Optional background re-transcription with a better backend/model

4. Optional enrichment
- summaries,
- decisions,
- action items,
- speaker labels,
- semantic layers

### Adopt With Modification

1. Meeting file format
- Adopt a Contora-specific meeting/session artifact
- Preserve:
  - frontmatter/metadata,
  - transcript section,
  - incremental enrichment
- Do not blindly copy OpenOats naming or fields

2. Meeting detection
- Consider as optional convenience only
- Never make it mandatory
- Never require calendar access to use the app

3. Model UX
- Keep first-run model download and clear model/status messaging
- For macOS, route this through the shared local server/runtime flow

## Concrete Product Implications for Contora

### High-confidence additions to roadmap

1. Add structured session file output alongside transcript text.
2. Add background batch refinement after initial transcription.
3. Add optional meeting detection as a convenience feature, not a dependency.
4. Add storage settings:
   - save raw audio,
   - save compressed archive,
   - keep/delete temporary intermediates.
5. Keep cloud integrations strictly optional.

### Product guardrails

1. No stealth/anti-detection positioning.
2. No mandatory calendar integration for basic use.
3. No requirement to connect cloud services for recording/transcription.
4. No “AI answers for you” product direction.

## Conclusion

OpenOats is valuable less as a codebase to copy wholesale and more as proof of a good macOS product shape:
- compact,
- local-first,
- optional advanced layers,
- session-oriented artifacts,
- clear settings,
- strong first-run simplicity.

For Contora, the best reuse is:
- architecture patterns,
- session artifact design,
- batch refinement flow,
- optional detection/import/storage ideas.

The anti-detection layer should be treated as explicitly out of scope.

# Golden corpus annotation policy

The quality corpus must be reviewed while listening to the canonical 16 kHz
audio, not copied from an engine prediction. Automatic output may be used only
as an editable draft and must be checked word by word and boundary by boundary.

## Required coverage

The final corpus must include Russian studio speech, a call/remote microphone,
background noise, names, numbers, punctuation, long pauses, rapid speaker
changes, and overlapping speech. At least one sample must be 56–60 minutes so
quality and thermal/resource behaviour are measured on the same duration class.

## Word rules

- Preserve the spoken lexical form; do not silently rewrite meaning.
- Put punctuation in `text`, attached to the relevant word. Scoring separately
  reports normalized WER/CER and punctuation F1.
- Mark proper names with `tags: ["name"]`; numeric expressions are detected
  automatically and may also be tagged `number`.
- `start` is the audible beginning and `end` the audible end of the word, in
  seconds from the canonical file. Times must be finite and `end > start`.
- Assign a speaker to every word. During true overlap, keep the actually spoken
  speaker on each word; do not invent an `OVERLAP` speaker.

## Speaker-turn rules

- Speaker labels are anonymous and stable within a sample (`SPEAKER_00`, ...).
- Turns contain speech only; do not span long silence merely for continuity.
- Overlap is represented by overlapping turns from different speakers.
- Keep exact boundaries: the scorer uses a zero collar and scores overlap.

## Review and acceptance

Every file needs one annotator and a second reviewer. Set `annotation.status` to
`golden` only after the reviewer has checked text, word timing, turns, overlap,
speaker consistency, names, numbers, and punctuation. Record tool/version and
pseudonymous reviewer IDs in `annotation`; never put participant identities in
the repository.

# DictateRounds - Handover

## Last updated
2026-05-21 - branch: main - latest pushed commit: 1c62dfb

## Current state
- Single-file app in `DictateRounds.html`; no build step.
- Served locally by `LaunchDictateRounds.command` on `localhost:8091`.
- State lives in `localStorage` for metadata/API keys/keyterms and IndexedDB for audio blobs.
- `.DS_Store` is now ignored and should be removed from version control in the next commit.

## Recent committed work
- `1c62dfb` - Fixed recording state and review safety:
  - Stable patient IDs with import reconciliation.
  - Today-only scoping for process/retry/review/export counts.
  - Appended audio stored as separate segments instead of concatenated WebM.
  - Safer attribute escaping.
  - Error cards no longer copy error text as notes.
  - 731 renderer/review form tolerates partial structured data.
- `391f656` - Review screen search, typed note preview, Scribe field guide, persistent field-guide visibility during recording, search contrast.
- `9d1ec25` - Hardened event handling.
- `936374d` - Surfaced awaiting_review 731 patients in Review Notes.
- `3dbd36d` - 731 field guide on patient card.

## Current uncommitted session
- Added `.gitignore` for `.DS_Store`.
- Added retry button for failed cards in Review Notes.
- Added `+ Add dictation` / stop control inside 731 awaiting-review form for audio recordings.
- Normalised DOB values from Excel before stable ID generation.
- Corrected privacy wording: audio goes to Deepgram; typed text/transcripts go to Claude; identifiers remain client-side.
- Added Settings diagnostics summary.
- Added this `HANDOVER.md` to be tracked going forward.

## Important implementation notes
- Patient IDs are deterministic from facility/name/DOB when DOB exists, otherwise facility/ward/bed/name.
- Existing old random-ID recordings are reconciled on import where the previous cached patient matches the new stable patient key.
- Audio append now stores multiple `audioIds`. Playback is sequential; transcription/export converts segments to a single WAV when needed.
- `audioId` is still retained as the latest segment for backwards compatibility, but new logic should use `recordingAudioIds(rec)`.
- Review, process, retry and export should use `todayRecordingEntries()` unless intentionally inspecting all cached state.
- `renderFacility()` still replaces `#patientList` with `innerHTML`; avoid relying on DOM state surviving re-render.
- Generated HTML attribute values should use `escAttr()`, not `escHtml()`.

## Deferred / watch items
- Live browser QA is still important for microphone, append playback, transcription, export ZIP and 731 review flows.
- Scribe field guide content is still hardcoded in JS.
- Diagnostics currently reports metadata counts only; it does not enumerate raw IndexedDB blobs.
- Stable DOB normalisation handles Date objects, Excel serial numbers and strings, but live import should still be checked against real Patient Master Lists.

## How to resume
1. Open terminal: `cd "/Users/anthonymarinucci/Library/CloudStorage/Dropbox/Downloads (DB)/DictateRounds App" && bash LaunchDictateRounds.command`
2. Open Chrome at `http://localhost:8091/DictateRounds.html`
3. Test local app flows, then commit and push any validated changes.

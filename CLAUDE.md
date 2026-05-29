# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DictateRounds is a **single-file** clinical dictation web app used daily by an Australian GP doing rounds in residential aged care (RACH). Everything — HTML, CSS, and JavaScript — lives in `DictateRounds.html`. There is **no build step, no framework, no package manager, and no test suite**. The only external runtime dependencies are two CDN scripts loaded in the `<head>`: `xlsx` (SheetJS, for patient-list import) and `jszip` (for the export ZIP).

The user copies the finished note text into their EMR (Clinic to Cloud) manually.

## Run

```bash
bash LaunchDictateRounds.command
```

This starts `python3 -m http.server 8091` in the repo directory and opens Chrome at `http://localhost:8091/DictateRounds.html`. It must be served over HTTP (not opened as a `file://`) because `getUserMedia` (microphone) requires a secure/localhost context. Re-running while the server is already up just reopens the tab.

There is no automated testing — validation is **live browser QA in Chrome**. Always manually exercise the affected flow (mic capture, append/playback, transcription, 731 review, export ZIP) before claiming a change works.

## Architecture

All logic is in the `<script>` block of `DictateRounds.html` (~line 224 onward), organized as plain top-level functions over module-level mutable state variables (`allPatients`, `todayPatients`, `selectedFacilities`, `recordings`, `patientNotes`, `expandedPatient`, `isProcessing`, …). Key seams:

### Persistence (two stores, deliberately split)
- **`localStorage`** — patient/recording metadata, API keys, and keyterms. Keys: `dr_deepgramKey`, `dr_anthropicKey`, `dr_keyterms`; recording/note metadata in `dr_recordings` + `dr_patientNotes` (written by `saveState()`); the day's selection in `dr_selectedFacilities` + `dr_todayPatients` (written by `saveTodayState()`).
- **IndexedDB** — audio blobs only. DB `DictateRoundsAudio`, store `blobs`, keyed by audio id, accessed via `openDB`/`saveBlob`/`loadBlob`/`deleteBlob`. Metadata never holds the blob.

### External APIs (called directly from the browser)
- **Deepgram** `nova-3-medical` at `https://api.deepgram.com/v1/listen` (in `processOne`) — audio → transcript. Keyterms are passed as repeated `keyterm` query params.
- **Anthropic** `https://api.anthropic.com/v1/messages` — transcript or typed text → note. The model is **hardcoded** as `claude-sonnet-4-20250514` (there is no model selector). Called directly with `x-api-key` + `anthropic-dangerous-direct-browser-access: true`. Scribe uses the `SCRIBE_PROMPT` system prompt with plain text output; 731 uses `MDCP_731_PROMPT` with a forced tool call (`tool_choice` → `submit_mdcp_731`, schema in `MDCP_731_TOOL_SCHEMA`/`MDCP_731_TOOL_SPEC`) and reads the structured JSON from the `tool_use` block.
- **Privacy invariant:** audio goes to Deepgram; transcripts and typed text go to Claude; patient names/DOB/bed stay client-side and are never sent (there is **no** deidentify/reidentify round-trip — identifiers simply never enter the recorded/typed content). Preserve this separation when touching the processing path.

### Note pipeline (per-recording, not per-patient)
Each recording carries a **`noteType`** (`scribe` | `mdcp_731`) and an **`inputMode`** (`audio` | `text`), set via `setNoteType`/`setInputMode`. This is intentionally a per-recording attribute so the same transcript can be re-processed under a different type.

- `scribe` → SOAP-style note (History / Examination / Plan), rendered straight to text output. No review screen.
- `mdcp_731` → MBS item 731 care-plan contribution. Claude returns structured JSON (stored on `rec.structuredData`, status `awaiting_review`); the user edits it in `renderReviewForm` (conflict flags via `checks_to_confirm`, "not documented" dismissals via `not_documented`, plus the goal/action editors `addGoal731`/`addAction731`/`updateField731`/`removeItem731`); `generateFinalNote` then calls `renderMdcp731` to produce the final text and set status `processed`. `reExtract731` re-runs Claude on the stored transcript. **Only 731 has a review screen.**

Recording lifecycle: `startRecording`/`stopRecording` (MediaRecorder → WebM/Opus blob), appended segments stored as **multiple `audioIds`** (use `recordingAudioIds(rec)`, not the legacy single `audioId`); `processOne` (per recording), `batchProcess` (all/retry), and `processSingle` drive transcription + structuring; `exportAllAudio` builds the export ZIP (segments converted to a single WAV via `webmSegmentsToWav`/`recordingToWav`/`audioBuffersToWav` when needed).

### Patient import & identity
`importFile` parses the .xlsx Patient Master List (via the `XLSX` global; first sheet only, with facility/ward header rows detected inline). Patient IDs are **deterministic** (`patientStableId`): facility/name/DOB when DOB exists, else facility/ward/bed/name; `normaliseDobValue` handles Date objects, Excel serials, and strings before id generation, and `uniquePatientId` de-dupes collisions. On import, old random-id recordings are reconciled onto the matching stable patient key by `reconcileImportedPatientState`. Counts for process/retry/review/export are scoped to today via `todayRecordingEntries()` — use it unless you intentionally need all cached state.

### Rendering
View routing is `showView(name)` over a string view name (`import` / `select` / `home` / `facility` / `review` / `settings`); `getInitialView()` picks the landing view based on whether patients/today's round exist. `renderFacility()` rebuilds `#patientList` via `innerHTML` — **DOM state does not survive a re-render**, so don't rely on it. Generated attribute values must use `escAttr()` (not `escHtml()`).

## Conventions & gotchas

- **One file.** Add features by editing `DictateRounds.html` in place; match the existing plain top-level-function, no-module style.
- Static control event handlers are wired in `bindStaticControls()`; persisted state is loaded by `loadState()`.
- Commit/push only validated changes (the user runs live QA first). `.DS_Store` is gitignored.

## Authoritative references

- **`731-handoff.md`** — full design spec for the 731 MDCP mode, text input, and structured review screen, including explicit **out-of-scope** items (no prompt-editing UI, no 721/frequency tracking, no mode refactor, no PDF, no audit log). Read before doing 731 work and enforce that scope.
- **`HANDOVER.md`** — running session log: current state, recent commits, implementation notes, and deferred/watch items. Update it when you finish a session.

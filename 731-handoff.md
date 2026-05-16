# DictateRounds — V1 Addition: 731 MDCP Mode, Text Input, Structured Review Screen

**Purpose of this document:** complete design spec for adding three new capabilities to DictateRounds. Read this in full before writing code. Implementation decisions in this doc have already been made — do not re-litigate them with the user unless flagging a concrete technical obstacle.

---

## 1. Project context

DictateRounds is a single-HTML clinical dictation app used daily by an Australian GP working in residential aged care (RACH). It runs on `localhost:8091` via a Python HTTP server (`LaunchDictateRounds.command`). Patient list is imported from .xlsx and stored in localStorage; audio blobs in IndexedDB.

Current pipeline (Scribe mode):
- Per-patient audio recording via `getUserMedia` → WebM/Opus blob
- Deepgram Nova-3 Medical for transcription (Australian medical keyterms)
- Claude Sonnet for structuring into a fixed SOAP-style format (History / Examination / Plan)
- Output is copied into the user's EMR (Clinic to Cloud) manually

The app currently supports **one** note type (SOAP-style scribe) and **one** input modality (audio dictation).

---

## 2. What we're building (V1 scope)

Three additions, in priority order:

1. **Per-recording note type selector.** Each patient recording can be processed as one of:
   - `scribe` — existing SOAP-style note (unchanged behaviour)
   - `mdcp_731` — new MBS item 731 contribution to a multidisciplinary care plan
   
   Architected as a *per-recording* attribute, not per-patient, so the user can change note type before processing and re-process the same transcript with a different type.

2. **Text input mode** (for all note types). Per-recording alternative to dictation:
   - `audio` — existing flow (record → Deepgram → Claude)
   - `text` — typed/pasted free narrative goes directly to Claude (no Deepgram step)
   
   Useful for desk work, retrospective writing-up, or when dictation isn't practical.

3. **Structured review screen for 731 mode.** Between extraction and final text output, the user sees an editable form representing the structured JSON. They can correct fields, address flagged conflicts, and dismiss "not documented" items before generating the final text. Scribe mode does **not** get a review screen — direct text output is preserved.

---

## 3. What we're explicitly NOT building in V1

Enforce this scope discipline. If the user asks for these mid-implementation, push back and defer:

- Settings UI to edit the 731 prompt (prompt is in the code, editable manually)
- 3-month / 721 frequency tracking (requires persistent per-patient billing history)
- Multi-mode platform refactor — modes are hardcoded in V1, future refactor can extract them
- Per-patient persistent condition/goal templates / reusable libraries
- PDF output
- Audit log of edits (what the LLM proposed vs what the user approved)
- Mode-specific Deepgram keyterm prompts (single global list for now)
- Cross-mode review screen generalisation (731 only for V1; if another mode later needs review, generalise then)
- Migration of the existing single-file architecture into modules

---

## 4. Architectural decisions (already made — do not revisit)

1. **Single HTML file maintained.** No build step. No bundler. Keep the file deployable as-is.
2. **Tool use with strict `input_schema`** for 731. The Anthropic API call sets `tools` and `tool_choice: {type: "tool", name: "submit_mdcp_731"}`, forcing valid JSON output matching the schema. This is the consistency mechanism — eliminates format drift entirely.
3. **Deterministic JS renderer** turns the JSON into the final text. No LLM in the rendering step. Same JSON in → byte-identical text out.
4. **Review screen between extraction and rendering** (for 731 only). New status: `awaiting_review`. User must explicitly click "Generate Final Note" to move to `processed`.
5. **Backwards compatibility.** Existing recordings in localStorage have no `noteType` or `inputMode`. Default both on read: `noteType = 'scribe'`, `inputMode = 'audio'`. Existing audio + transcript + note continue to work unchanged.
6. **Same Anthropic model** as current code (`claude-sonnet-4-20250514`). *Optional follow-up*: upgrade to `claude-sonnet-4-6` for better tool use reliability — but this is a separate decision and out of scope unless tool use fails on Sonnet 4.
7. **Privacy posture unchanged.** Patient identifiers stay client-side. Only the transcript/typed text is sent to Claude. Audio stays in IndexedDB. No new data leaves the device.

---

## 5. Data model changes

### Current `recordings[pid]` shape

```js
{
  audioId: 'audio_xxx',     // IndexedDB key
  duration: 123,            // seconds
  status: 'recorded' | 'processed' | 'done' | 'error',
  note: 'final text...',
  transcript: 'STT output...'
}
```

### New `recordings[pid]` shape

```js
{
  // Existing fields preserved
  audioId: string | null,
  duration: number,
  transcript: string | null,
  note: string | null,                          // final rendered text
  status: 'recorded' | 'text-ready' | 'processed' | 'awaiting_review' | 'done' | 'error',

  // New fields (defaults handle backwards compat)
  noteType: 'scribe' | 'mdcp_731',              // default 'scribe'
  inputMode: 'audio' | 'text',                  // default 'audio'
  textInput: string | null,                     // for text mode; null for audio mode
  structuredData: object | null                 // for mdcp_731 only: the JSON from tool use
}
```

### New status values

- `text-ready` — text input has been provided, awaiting processing (analogous to `recorded` for audio)
- `awaiting_review` — 731 extraction complete, user has not yet approved the review form

### Backwards compat rule

In `loadState()` and anywhere `recordings[pid]` is read, apply defaults:

```js
const rec = recordings[pid] || {};
const noteType = rec.noteType || 'scribe';
const inputMode = rec.inputMode || 'audio';
```

Do not run a migration that rewrites existing records — let defaults apply at read time.

---

## 6. The complete 731 JSON schema (verbatim — use as `input_schema`)

```json
{
  "type": "object",
  "required": [
    "source_material_reviewed",
    "medication_chart_review",
    "rmmr",
    "immunisations",
    "assessments",
    "mdt_case_conference",
    "health_status_summary",
    "conditions",
    "goals",
    "checks_to_confirm",
    "not_documented"
  ],
  "properties": {
    "source_material_reviewed": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Documents/records reviewed. Examples: 'RACH facility multidisciplinary care plan', 'Medication chart', 'RMMR dated [date]', 'Geriatrician CGA dated [date]'. If a source isn't explicitly mentioned in input, omit it rather than invent."
    },
    "medication_chart_review": {
      "type": "object",
      "required": ["reviewed_today", "changes"],
      "properties": {
        "reviewed_today": { "type": "boolean" },
        "changes": { "type": "string", "description": "Either 'No changes' or specific changes made today" }
      }
    },
    "rmmr": {
      "type": "object",
      "required": ["status", "date"],
      "properties": {
        "status": { "type": "string", "enum": ["Completed", "Due", "Not stated"] },
        "date": { "type": "string", "description": "Date if completed, 'Not stated' if missing, 'NA' if not applicable" }
      }
    },
    "immunisations": {
      "type": "object",
      "required": ["influenza_current_year", "pneumococcal", "covid_booster", "shingles", "rsv", "adt", "source"],
      "properties": {
        "influenza_current_year": { "type": "string", "enum": ["Up to date", "DUE", "Not stated"] },
        "pneumococcal": { "type": "string", "enum": ["Up to date", "DUE", "Not stated"] },
        "covid_booster": { "type": "string", "enum": ["Up to date", "DUE", "Not stated"] },
        "shingles": { "type": "string", "enum": ["Up to date", "DUE", "Not stated"] },
        "rsv": { "type": "string", "enum": ["Up to date", "DUE", "Not stated"] },
        "adt": { "type": "string", "enum": ["Up to date", "DUE if sustains tetanus prone wound", "Not stated"] },
        "source": { "type": "string", "description": "Source of immunisation status, e.g. 'AIR', 'RACH record', 'Not stated'" }
      }
    },
    "assessments": {
      "type": "object",
      "required": ["cma_gp", "cga_geriatrician"],
      "properties": {
        "cma_gp": {
          "type": "object",
          "required": ["completed", "date", "recommendations_actioned", "details"],
          "properties": {
            "completed": { "type": "string", "enum": ["Yes", "No", "Not stated"] },
            "date": { "type": "string" },
            "recommendations_actioned": { "type": "string", "enum": ["Yes", "No", "Partial", "NA"] },
            "details": { "type": "string", "description": "Brief detail of recommendations and what was actioned. Empty string if NA." }
          }
        },
        "cga_geriatrician": {
          "type": "object",
          "required": ["completed", "date", "recommendations_actioned", "details"],
          "properties": {
            "completed": { "type": "string", "enum": ["Yes", "No", "Not stated"] },
            "date": { "type": "string" },
            "recommendations_actioned": { "type": "string", "enum": ["Yes", "No", "Partial", "NA"] },
            "details": { "type": "string" }
          }
        }
      }
    },
    "mdt_case_conference": {
      "type": "object",
      "required": ["recent", "date", "goals_met"],
      "properties": {
        "recent": { "type": "string", "enum": ["Yes", "No", "Not stated"] },
        "date": { "type": "string" },
        "goals_met": { "type": "string", "enum": ["Yes", "No", "Partial", "NA"] }
      }
    },
    "health_status_summary": {
      "type": "string",
      "description": "One-line overall health status, e.g. 'Stable with advanced frailty in residential aged care setting'"
    },
    "conditions": {
      "type": "array",
      "items": { "type": "string" },
      "description": "List of current chronic conditions (active for this patient)"
    },
    "goals": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["condition", "goal", "actions"],
        "properties": {
          "condition": { "type": "string" },
          "goal": { "type": "string", "description": "The clinical goal of care for this condition" },
          "actions": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["provider", "action", "monitoring", "review"],
              "properties": {
                "provider": { "type": "string", "description": "e.g., GP, PT, Podiatrist, Audiologist, Optometrist, Facility care staff, Neurology clinic" },
                "action": { "type": "string", "description": "What will be done" },
                "monitoring": { "type": "string", "description": "How it will be monitored" },
                "review": { "type": "string", "description": "When it will be reviewed" }
              }
            }
          }
        }
      }
    },
    "checks_to_confirm": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Items requiring clinician confirmation before finalising. Include: clinical conflicts (e.g. BP target vs postural hypotension); ambiguities in dictation; internal inconsistencies; statements that may not match clinical risk profile. Empty array if none."
    },
    "not_documented": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Relevant standard items not addressed in input. Always check for: advance care plan / goals-of-care direction; SDM priorities / 'what matters to the resident'; allergies; source of immunisation status (if immunisations mentioned without a source); behavioural/cognitive monitoring plan (if dementia mentioned). Empty array if all standard items addressed."
    }
  }
}
```

---

## 7. The 731 system prompt (verbatim)

Store as a JS constant `MDCP_731_PROMPT`:

```
ROLE
You are a passive AI clinical documentation assistant supporting an Australian GP working in residential aged care. You are NOT a clinical decision-maker. Your job is to organise the GP's dictated or typed clinical narrative into a structured MBS item 731 contribution to a multidisciplinary care plan, using only what the GP has explicitly stated.

INPUT
The user input is the GP's free-text narrative about a single residential aged care resident. It may be dictated speech (transcribed) or typed. It may have informal language, repetition, self-corrections, or speech-to-text artefacts.

OUTPUT
Call the `submit_mdcp_731` tool exactly once. Populate the schema using only information explicitly stated by the GP. Do not infer clinical content the GP did not state.

CRITICAL RULES
1. Do not invent facts. If a field is not mentioned in input, mark it 'Not stated' or use an empty value per the schema rather than guess.
2. Do not infer completion of actions unless the GP explicitly states it. ('RMMR completed Jan 2026' = Completed; 'RMMR pending' = Due; silence on RMMR = Not stated.)
3. Use Australian spelling throughout (optimise, organisation, paediatric, behaviour, etc.).
4. Convert spoken numbers to numerics ('one hundred and thirty' → '130'; 'three times weekly' → '3 times weekly').
5. Preserve patient-specific details. Do not generalise specific clinical statements into generic phrases.
6. Flag clinical conflicts in `checks_to_confirm`. Specifically watch for:
   - BP targets that conflict with reported postural hypotension or recent antihypertensive reduction
   - Goals that may conflict with documented frailty status or care goals
   - Monitoring intervals that don't match the stated clinical risk
   - Internal inconsistencies in the GP's dictation
   - Stated targets that exceed evidence base for the patient's age/frailty profile
7. Surface relevant standard items missing from input in `not_documented`. Always check for:
   - Advance care plan / goals-of-care direction
   - Substitute decision-maker priorities or 'what matters to the resident'
   - Allergies
   - Source of immunisation status (if immunisations mentioned without a stated source like AIR or RACH record)
   - Behavioural/cognitive monitoring plan (if dementia mentioned)
8. For each goal, you MUST include a condition, a goal, and at least one action with provider/action/monitoring/review specified. If any of these are not stated in input, write 'Not stated' for that field rather than fabricate plausible content.
9. Avoid boilerplate review-interval phrases. Use 'Reviewed on regular GP RACH rounds' style language ONLY if the GP explicitly indicated regular rounds. Do not default to 'weekly ward rounds' unless the GP said weekly.
10. Goals must be individualised. A goal of 'monitor condition' is too generic — push it into `checks_to_confirm` asking the GP to specify what is being monitored and why.

CONTRIBUTION FRAMING
This output is a GP CONTRIBUTION to a multidisciplinary care plan prepared by the residential aged care facility (or another provider before discharge from hospital). It is NOT a standalone GP care plan. The output frames the GP's input as additions and recommendations to an existing facility-prepared plan.

QUALITY CHECK BEFORE SUBMITTING THE TOOL CALL
- All required schema fields populated
- No invented clinical content
- `checks_to_confirm` populated if any clinical conflict or ambiguity exists; empty array if none
- `not_documented` populated with relevant standard items not addressed in input
- Australian spelling throughout
- Patient-specific language preserved (not generalised)
```

---

## 8. The deterministic renderer (text output format)

Function signature: `renderMdcp731(data) -> string`

The renderer takes the validated JSON object and produces the final text. Format must match exactly (whitespace, dashes, punctuation):

```
GP Contribution to MDCP (Residential Aged Care Facility plan)

Source material reviewed:
- [each item in source_material_reviewed, one per line, dash prefix]

This contribution is to the multidisciplinary care plan prepared by the residential aged care facility. The following review and recommendations are provided by the GP for inclusion in that plan.

1) Medication charts reviewed today
- [if medication_chart_review.reviewed_today is true: medication_chart_review.changes; else: "Not reviewed today"]

2) Recent RMMR completed? [rmmr.status]
- Date: [rmmr.date]

3) Immunisations reviewed (source: [immunisations.source]):
-- Influenza (current year): [immunisations.influenza_current_year]
-- Pneumococcal: [immunisations.pneumococcal]
-- COVID booster: [immunisations.covid_booster]
-- Shingles: [immunisations.shingles]
-- RSV: [immunisations.rsv]
-- ADT: [immunisations.adt]

4) Recent comprehensive medical assessment?
- CMA (GP)? [assessments.cma_gp.completed]
  - Date: [assessments.cma_gp.date]
  - Specific recommendations actioned? [assessments.cma_gp.recommendations_actioned]
  - [if assessments.cma_gp.details is non-empty: assessments.cma_gp.details]
- CGA (Geriatrician)? [assessments.cga_geriatrician.completed]
  - Date: [assessments.cga_geriatrician.date]
  - Specific recommendations actioned? [assessments.cga_geriatrician.recommendations_actioned]
  - [if assessments.cga_geriatrician.details is non-empty: assessments.cga_geriatrician.details]

5) Recent MDT care conference? [mdt_case_conference.recent]
- Date: [mdt_case_conference.date]
- Goals met? [mdt_case_conference.goals_met]

6) Health status and current conditions:
[health_status_summary]

[each condition in conditions, one per line, no prefix]

7) Current Individualised Goals of Care:

[for each goal in goals:]
Condition: [goal.condition]
Goal: [goal.goal]
Who will be involved, how will it be achieved, how will it be monitored and when will it be reviewed:
[for each action in goal.actions:]
- [action.provider]: [action.action], [action.monitoring], [action.review]

[blank line between goals]

---

Checks to confirm before finalising:
[if checks_to_confirm is non-empty, each item on own line with "- " prefix]
[if checks_to_confirm is empty, this entire section is omitted]

Items not documented in source information:
[if not_documented is non-empty, each item on own line with "- " prefix]
[if not_documented is empty, this entire section is omitted]
```

Rules:
- Australian English throughout (the schema enforces this, but the renderer must not introduce US spellings)
- No em dashes anywhere in the output
- Use only `-` and `--` as list markers (matching existing Scribe convention)
- Trim trailing whitespace per line
- Single blank line between numbered sections, double blank line before the `---` separator

---

## 9. UI requirements

### 9.1 Patient card expanded view

When a patient card is expanded, show **above** the existing record button:

```
Note type:  [Scribe]  [MDCP 731]
Input mode: [Dictate] [Type]
```

Two segmented controls. Defaults: Scribe + Dictate. Selection persists per recording.

If `Type` mode is selected, replace the record button with a textarea ("Paste or type patient narrative here...") and a "Process this" button. The textarea autosaves to `recordings[pid].textInput` on change; status becomes `text-ready` when text is non-empty.

If `Dictate` mode is selected, use the existing record button flow unchanged.

### 9.2 Status badges

Add badge for `awaiting_review` status — distinct from `recorded`/`processed`/`done`. Suggest amber-blue tone (separate from existing amber/green/red).

### 9.3 Review screen (731 mode only, status = awaiting_review)

When a 731 recording reaches `awaiting_review`, the expanded patient card shows an editable form mirroring the schema. Layout:

```
[Patient name] [Bed]   [Status: Awaiting Review badge]
[Raw transcript/text — collapsible <details>]

─── Structured Review ───

Source material reviewed:
[editable list of strings, each removable, with "+ Add" button]

Section 1 — Medication chart review
  Reviewed today: [checkbox]
  Changes: [text input]

Section 2 — RMMR
  Status: [dropdown: Completed / Due / Not stated]
  Date: [text input]

Section 3 — Immunisations
  Source: [text input]
  Influenza: [dropdown]
  Pneumococcal: [dropdown]
  COVID booster: [dropdown]
  Shingles: [dropdown]
  RSV: [dropdown]
  ADT: [dropdown]

Section 4 — Assessments
  CMA (GP):
    Completed: [dropdown]
    Date: [input]
    Recommendations actioned: [dropdown]
    Details: [textarea]
  CGA (Geriatrician):
    [same fields]

Section 5 — MDT Case Conference
  Recent: [dropdown]
  Date: [input]
  Goals met: [dropdown]

Section 6 — Health status & conditions
  Summary: [text input]
  Conditions: [editable list, removable items, "+ Add"]

Section 7 — Goals
  [for each goal:]
    Condition: [input]
    Goal: [input]
    Actions:
      [for each action:]
        Provider: [input]
        Action: [input]
        Monitoring: [input]
        Review: [input]
        [Remove action button]
      [+ Add action]
    [Remove goal button]
  [+ Add goal]

─── Flags ───

Checks to confirm before finalising:
  [each item with text input + "Dismiss" button]
  [+ Add manual check]

Not documented in source:
  [each item with text input + "Dismiss" button]
  [+ Add manual item]

─── Actions ───

[Cancel]  [Re-extract from transcript]  [Generate Final Note]
```

Behaviour:
- All edits write to `recordings[pid].structuredData` on change → `saveState()`
- `Generate Final Note` → calls `renderMdcp731(structuredData)` → writes to `recordings[pid].note` → sets status to `processed` → returns to standard patient card view
- `Re-extract from transcript` → re-calls Claude with the existing transcript/text → overwrites `structuredData` → user reviews fresh
- `Cancel` → leaves status at `awaiting_review`, allows user to return later

### 9.4 Scribe mode flow (unchanged)

Scribe-mode recordings go directly from `recorded`/`text-ready` → `processed` (no review screen). User sees final text and copies as today.

---

## 10. Processing flow changes

### `processOne(pid, rec, dgKey, anKey, kt)` modifications

Branch on `rec.noteType` and `rec.inputMode`:

```
if inputMode == 'audio':
  transcript = call Deepgram on audio blob (existing flow)
else if inputMode == 'text':
  transcript = rec.textInput
  (skip Deepgram entirely)

if noteType == 'scribe':
  call Claude with SCRIBE_PROMPT + transcript (existing flow)
  return { transcript, note: response.content[0].text }
  → status becomes 'processed'

else if noteType == 'mdcp_731':
  call Claude with MDCP_731_PROMPT + transcript
    + tools: [MDCP_731_TOOL_SPEC]
    + tool_choice: { type: 'tool', name: 'submit_mdcp_731' }
    + max_tokens: 4096
  parse response: find content block with type === 'tool_use' and name === 'submit_mdcp_731'
  return { transcript, structuredData: toolUseBlock.input, note: null }
  → status becomes 'awaiting_review'
  (note remains null until user clicks Generate Final Note in review screen)
```

### `batchProcess` modifications

Update the filter so `text-ready` recordings are also picked up:

```js
const toProc = retryMode
  ? Object.entries(recordings).filter(([_,r]) =>
      r.status === 'error' && (r.audioId || r.textInput))
  : Object.entries(recordings).filter(([_,r]) =>
      (r.status === 'recorded' && r.audioId) ||
      (r.status === 'text-ready' && r.textInput));
```

The Anthropic key check stays. Deepgram key check applies only if at least one audio-mode recording is in the batch.

### `copyNote` modifications

The existing cleanup regex is SOAP-specific:

```js
recordings[pid].note.replace(/(History Of Presenting Illness|Examination|Plan)\n\n+/g,'$1\n');
```

Make this conditional on `noteType`:

```js
let cleaned = recordings[pid].note;
if (rec.noteType === 'scribe' || !rec.noteType) {
  cleaned = cleaned.replace(/(History Of Presenting Illness|Examination|Plan)\n\n+/g, '$1\n');
}
// no cleanup needed for mdcp_731 — renderer produces final form
```

---

## 11. Compliance touchpoints (AN.15.8)

Design decisions driven by MBS Note AN.15.8 (item 731 explanatory note). The user is a senior GP who knows this — these are baked in so the LLM doesn't undermine compliance:

- **Contribution framing.** The output explicitly states it's a contribution to a facility-prepared plan, not a standalone GP plan. This matches AN.15.8 which defines 731 as contributing to a plan prepared by the RACF or by another provider pre-discharge.
- **Source material section.** Documents what was reviewed, supporting the "adequate and contemporaneous records" requirement.
- **"Not stated" discipline.** The schema and prompt enforce that missing fields are flagged, not silently completed. This protects against the failure mode of polished-but-fabricated content during PSR review.
- **No frequency tracking in V1.** The 3-month rule and 721 conflict check require persistent billing history. Out of scope; user is responsible for checking manually.

If the user adds modes for items 232, 92027, or 92058 in future, the same schema/renderer can be reused with different prompt framing.

---

## 12. Acceptance criteria

Use the following test case (the geriatric stroke patient from design discussions) to validate the build:

**Test input** (paste into Type mode, 731 mode):

```
78 year old male in RACH with history of stroke without significant residual deficits. Goals of care: prevent recurrent stroke by optimising cardiovascular risk factors including blood pressure and lipids, aim systolic BP less than 130 and total cholesterol less than 4 by GP on regular ward rounds with weekly BPs and 6 monthly lipid pathology, and participate in group based exercise class by PT 3 times weekly, and maintain mobility with good foot health by podiatry with 5 yearly visits. Has COPD, current smoker, goals of care ongoing brief intervention for smoking cessation and prevent COPD exacerbations by GP with optimisation of inhaler therapy reviewed on regular ward round. Has a meningioma, slow growing, goal yearly surveillance MRI by hospital neurology clinic. Has vascular dementia without BPSD, goals prevent further cognitive decline, keep socially engaged, monitor for and prevent delirium, by facility care staff to monitor for behavioural changes and by GP to review at least 6 weekly and intervene for delirium, optimise hearing and vision by audiologist and optometrist with regular screening. No medication changes today. Recent RMMR January 2026. All immunisations up to date except RSV which is due. No recent GP CMA. Recent geriatrician CGA February 2026 with recommendation to reduce ramipril for postural hypotension which has been actioned. No recent MDT case conference. Overall stable with advanced frailty in residential aged care setting.
```

**Expected JSON output must include:**

- `source_material_reviewed`: includes the RMMR date, the CGA date, and a reference to the facility care plan
- `rmmr.status: "Completed"`, `rmmr.date: "January 2026"`
- `immunisations.rsv: "DUE"`, all others `"Up to date"`, `source: "Not stated"`
- `assessments.cga_geriatrician.completed: "Yes"`, `date: "February 2026"`, `recommendations_actioned: "Yes"`, `details` mentions ramipril reduction
- `conditions` includes all five (prior CVA, COPD/smoker, meningioma, vascular dementia, frailty)
- `goals` has 4 entries (CVA, COPD, meningioma, vascular dementia)
- `checks_to_confirm` **must include** a flag about the BP target <130 conflicting with the recent ramipril reduction for postural hypotension. **If this flag is absent, the prompt is broken — fix the prompt.**
- `not_documented` includes at minimum: advance care plan, SDM priorities, allergies, source of immunisation status

**Expected behaviour:**

- Existing Scribe recordings (from before the update) continue to render and process unchanged
- Switching note type on an existing recording works (re-process with new type)
- Type mode works for both Scribe and 731
- Review screen edits propagate to the final rendered text
- "Generate Final Note" produces text matching the renderer spec
- localStorage round-trips correctly (close browser, reopen, state preserved)
- No regression in audio recording, Deepgram call, or batch processing concurrency

---

## 13. Suggested implementation order

Implement in phases. Commit after each. Test in browser before moving to the next.

**Phase 1 — Constants and helpers** (small, isolated)
- Add `MDCP_731_PROMPT` constant
- Add `MDCP_731_TOOL_SCHEMA` constant (the `input_schema` object)
- Add `MDCP_731_TOOL_SPEC` constant (the full `{name, description, input_schema}` for the tools array)
- Add `renderMdcp731(data)` function
- No UI changes. Verify constants are syntactically valid by loading the page.

**Phase 2 — Data model & defaults**
- Update `loadState()` and any read site to default `noteType='scribe'` and `inputMode='audio'`
- Ensure existing recordings load without breaking
- Test: open with existing recordings → all render correctly

**Phase 3 — Text input mode (Scribe only)**
- Add Dictate/Type segmented control to expanded patient card
- Add textarea + "Process this" button for Type mode
- Add `text-ready` status handling
- Update `batchProcess` filter
- Update `processOne` to skip Deepgram when `inputMode === 'text'`
- Test: type a SOAP-style narrative, process, verify output matches existing Scribe behaviour

**Phase 4 — 731 mode (no review screen yet)**
- Add Scribe/MDCP 731 segmented control
- Update `processOne` to branch on `noteType`, call Claude with tools for 731
- On success, render with `renderMdcp731` and set status to `processed` (skip review temporarily)
- Test: process the acceptance test input, verify JSON shape, verify rendered text matches spec, verify the BP/postural hypotension conflict is flagged

**Phase 5 — Review screen**
- Add `awaiting_review` status; 731 processing now lands here, not `processed`
- Build the structured edit form (renderReviewForm function)
- Wire field edits to `structuredData` updates
- Add Generate Final Note / Re-extract / Cancel actions
- Test: edit fields, dismiss flags, generate final note, verify text reflects edits

**Phase 6 — Polish**
- Status badges for `awaiting_review` and `text-ready`
- Copy/cleanup branching by note type
- Settings panel: surface 731 prompt preview (optional)
- Hotkey review (does the existing R/A/S behaviour still make sense in 731 review mode? probably disable in review screen)
- End-to-end test with mixed batch (some Scribe audio, some 731 typed)

---

## 14. Conventions & constraints

- **Single HTML file.** No new files unless absolutely necessary. If you propose splitting, flag it for user decision first.
- **Vanilla JS only.** No new dependencies. The existing `xlsx` and `jszip` CDN scripts are fine; do not add others.
- **Inline styles consistent with existing CSS vars** (`--bg`, `--surface`, `--accent`, etc.). Do not introduce new colour values.
- **Australian English** in any new user-facing strings.
- **Do not touch:** the Deepgram call signature, the existing SCRIBE_PROMPT, the IndexedDB audio storage, the .xlsx import logic, the facility selection flow.
- **Privacy.** Never log patient identifiers. Never send patient names, DOBs, or beds to any external API.
- **Test in actual browser** (Chrome on macOS) at `localhost:8091` after each phase. Do not rely on linting alone.
- **Commit messages** should reference the phase (e.g. `Phase 3: text input mode for Scribe`).

---

## 15. Open questions to surface to user (only if encountered)

These were deliberately deferred or unresolved. Only raise if blocking:

- If tool use returns malformed JSON despite strict schema (rare on Sonnet 4+, but possible), how to fall back: retry once, then surface as an error with the raw response?
- If a user processes a recording as 731, then changes the note type to Scribe and re-processes, should `structuredData` be cleared? Suggested: yes, clear on note type change.
- If the user is in the middle of editing the review screen and navigates away, should edits autosave or require explicit Save? Suggested: autosave on every field change (consistent with existing `patientNotes` autosave pattern).

End of handoff document.

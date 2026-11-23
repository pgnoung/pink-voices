# Mixed Thai and English display vocabulary

`dictation_text.py` is a local presentation formatter after OpenThai ASR has
returned a final utterance. It receives only the utterance text and never sends
it to another service. The recogniser's `text` field remains raw. The formatter
changes only `final.display_text` in `local_dictation.py`.

## Provenance

The canonical spellings were selected from current, local Pink Cuts sources.

- `Pink Cuts`, `Claude`, `Codex`, and `ElevenLabs` occur in
  `outputs/apps/agent-cuts/README.md`.
- `Pink Cuts`, `LINE OA`, `ChatGPT`, `Gemini`, `Canva`, `CapCut`, `Make`, and
  `Facebook` occur in reviewed local name prompts stored with Pink Cuts
  transcripts. Only the existing prompt name lists were inspected for this
  vocabulary pass. Their spoken content is neither copied here nor used as a
  training corpus.
- `OpenThai`, `th-mix`, `README`, `npm test`, and `ตลาดสี่มุมเมือง` are
  prototype-specific terms already covered by its original tests.

## Pink Cuts method that informs the next stage

Pink Cuts has a stronger name-recovery workflow than a static formatter. Its
current local source maintains a user/brand-scoped list of names, reads only a
short audio window again, compares a plain and a prompted read, then changes a
name only when the extra read corroborates it. It keeps word timing and
confidence alongside the transcript. The documented workflow also keeps names
local to the relevant brand or clip.

Pink voices currently reuses only the conservative principle, a closed
allow-list, explicit context for short forms, and an idempotent display-only
pass in this service. The shipped Mac app also has a local `คำศัพท์ส่วนตัว`
editor, implemented by `BrandDictionaryEditor` and `TextCleanup`, for
user-entered exact replacements after ASR. The acoustic decoder has no
per-user vocabulary bias, a second name decode, or Pink Cuts word timings. A
future decoder-side vocabulary feature should follow the same local scope and
corroboration rule before it corrects a sound-alike.

## Correction policy

1. Correct explicit Thai phonetic forms and ordinary separated English forms
   for a compact, reviewed vocabulary list.
   Composite forms may combine an English brand component with its Thai
   initials, for example `LINE โอ๊เอ้`. The clipped own-name form `พิงวอย`
   is accepted only before a short, reviewed action or particle context.
2. Insert a readable space when a Thai token touches a corrected canonical
   name.
3. Preserve URLs, email addresses, paths, file names, and identifier-shaped
   code exactly. Leave ambiguous Thai words and larger Latin identifiers
   untouched. Short Thai forms need context. For example, `โคลดิน`,
   `แคนว่า`, and `พิงคับ` are never treated as product names. `ซูม` becomes
   `Zoom` only in a meeting context.
4. Keep the operation idempotent so a displayed final can safely pass through
   the formatter again.

## Partial-result boundary

The live protocol exposes a partial string and an utterance identifier. The
service currently uses it only for a complete calendar phrase, where day,
month, and minute are independent anchors shared by the final result. Partial
brand text has neither confidence values nor word timing nor comparable
independent anchors. It is therefore not used to replace a plausible brand
near-match. Doing so would make a transient, prompt-sensitive partial override
the final decoder result without a corroborating signal or an extra decode.

`Pink voices` is the exact product display name in this prototype.

This improves capitalization and known names after recognition. It does not
claim to improve OpenThai acoustic recognition, infer arbitrary product names,
or rewrite ordinary Thai/English prose.

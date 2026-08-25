# ARCHIVED — FieldWorks / FLEx testing

**Archived 2026-08-25. The reproduction needs only Notepad.** Nothing in this
folder is part of the live method. It is kept because the FLEx work cost real
time and twice corrupted live language data, and neither of those lessons should
have to be re-learned by whoever points a harness at FieldWorks again.

## Why it was dropped

FieldWorks was in the picture from the start — the bug was first noticed while
typing Ngoreme into a FLEx lexicon, so FLEx looked like part of the reproduction.
It is not. The defect is in Keyman's Windows engine and is system-wide: the
three-arm proof (`TRIGGER.md` §3) and the modifier sweep (`kmmods.ps1`) both run
entirely in Notepad and both reproduce. FLEx only ever added:

- **risk** — real Ngoreme lexical data in the target, corrupted twice;
- **friction** — no UI Automation text at all, so every read went through the
  clipboard or a screenshot, and every field switch through an absolute click;
- **noise** — a keyboard-switch path (the writing-system combo) that is
  programmatic rather than a user TSF switch, which made the HKL oracle behave
  differently there than anywhere else and produced a caveat that was never
  resolved.

Notepad has none of those. It exposes a clean `ValuePattern` on `RichEditD2DPT`,
holds nothing anyone cares about, and switches keyboards the ordinary way.

`TEST-PLAN.md` §7 records "any FieldWorks-based testing" as out of scope.

## What is here

| file | what it is |
|---|---|
| `HAZARDS-flex.md` | the full former root `HAZARDS.md`, verbatim under an archive banner. §1 gotchas 4-7 and 10 and **all of §2 (live-language-data safety rules)** are FLEx-only and live only here |
| `screenshots/` | `flex-final.png`, `flex-testentry.png` — the FLEx test entry. **Untracked by design**: `.gitignore` excludes images because these show real Ngoreme entries, which are the language community's data rather than this project's |

The scripts that drove FieldWorks — `kmflex.ps1` and its screen-capture helper
`kmshot.ps1` — were archived separately to
[`../superseded-scripts/`](../superseded-scripts/README.md).

## What survived, and where

The hazards in `HAZARDS-flex.md` that are **not** FieldWorks-specific were kept
in the live root [`HAZARDS.md`](../../HAZARDS.md), renumbered:

| was | now | why it survived |
|---|---|---|
| gotcha 1 — navigation keys need `KEYEVENTF_EXTENDEDKEY` | H1 | true of any target; unextended `0x4B` is numpad-4 whatever the app. The *lexicon corruption* framing stays here |
| gotcha 2 — PowerShell names are case-insensitive, aliases outrank functions | H2 | a PowerShell fact, target-independent |
| gotcha 3 — the HKL frame-thread/focus-thread correction | H3 | the Notepad half is settled and load-bearing for `kmproof.ps1` / `kmmods.ps1`. **The unresolved FLEx caveat stays here** and is not retracted — it was never re-tested with the focus-thread fix |
| gotcha 8 — `keybd_event` with `dwExtraInfo = 0` is deliberate | H4 | the single most important rule in the harness. "Fixing" it to `SendInput` with a marker makes the whole rig invisible to Keyman and every test silently passes |
| gotcha 9 — read the `keyman.exe` version from the registry | H5 | unrelated to the target app |

Everything else — gotchas 4, 5, 6, 7, 10 and the whole of §2 — is FLEx-only.

## If you ever do drive FieldWorks again

Read `HAZARDS-flex.md` §2 first, in full, before writing a line. The short
version: the database holds real Ngoreme language data; use only the dedicated
test entry (headword `Ngq`); make every write self-cleaning; and do not spam
Ctrl+Z to fix a mistake, because the undo stack is shared with the user's own
work.

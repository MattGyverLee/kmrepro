# kmrepro — Keyman for Windows stuck-modifier investigation

An investigation harness, not a product. It exists to characterise, reproduce and
attribute one class of Keyman for Windows bug:

> Typing suddenly comes out capitalised, or stops appearing entirely, while
> Keyman still shows the correct keyboard as active. It behaves exactly as if a
> modifier key were physically held down, but no key is stuck. Restarting Keyman or the computer 
> clears it.

Investigated on **Keyman for Windows 18.0.249.0**, Windows 11 Pro 26200, against
`sil_cameroon_qwerty` in Notepad and FieldWorks (Ngoreme project).

Companion Keyman checkout: `../keyman`, branch
`fix/windows/16422-caps-lock-state-on-keyboard-switch`.

## Upstream issue

This is **[keymanapp/keyman#8064][i8064]** — *"bug(windows): modifier key
occasionally is 'stuck on'"*, opened by **rc-swag (Ross)** on 2023-01-23, still
open, milestone 20.0. Its original report — typing `Lonh does does` and getting
`LOnh DOes DOes` — is the same defect this repo reproduces. **File evidence
there; do not open a new issue.**

Ross has independently reached much of the same conclusion from field logs
(`m_ModifierKeyboardState` never returning to 0; an `extra: 4b4d0000` KEYDOWN
with no release; a latched Shift cleared only by the *right* Shift). His notes
are mirrored in [`issue-8064/`](issue-8064/). Read
**[MEETING-PREP.md](MEETING-PREP.md)** before talking to the Keyman team.

Prior attempts on the same symptom: [#1620][i1620] (2019, sticky Left Control
from AltGr), [#4884][i4884], [#7337][i7337] (2022 — the commit that created the
cache feed), [#15179][p15179]/[#15219][p15219] (2025 hook watchdog, which
mcdurdin has already noted did not resolve it).

The **Caps Lock / un-read-state** defect ([#16422][i16422] / [#16423][i16423]) is
a *different bug* that was explored here too. It has been split out to
**[`capslock/`](capslock/README.md)** — same staleness shape, different cache,
different symptom, no phantom keypress.

Plan for porting this into Keyman's own test structures:
**[TEST-PLAN.md](TEST-PLAN.md)**.

[i8064]: https://github.com/keymanapp/keyman/issues/8064
[i1620]: https://github.com/keymanapp/keyman/issues/1620
[i4884]: https://github.com/keymanapp/keyman/issues/4884
[i7337]: https://github.com/keymanapp/keyman/issues/7337
[i16422]: https://github.com/keymanapp/keyman/issues/16422
[i16423]: https://github.com/keymanapp/keyman/issues/16423
[p15179]: https://github.com/keymanapp/keyman/pull/15179
[p15219]: https://github.com/keymanapp/keyman/pull/15219

---

## The finding, in short

Keyman's low-level keyboard hook is serviced by **keyman.exe's UI thread**
(`keyman32.cpp:279` installs `WH_KEYBOARD_LL` against the thread resolved at
`:368`). If that thread stalls for about a second, Windows bypasses the hook and
Keyman never observes the event. When the missed event is a **modifier KEYUP**,
Keyman's cached modifier state stays latched — and it is never reconciled with the
OS again, having been seeded exactly once at `serialkeyeventserver.cpp:251`.

From then on `keybd_shift_reset()` (`keybd_shift.cpp:161-176`) **re-presses that
modifier for real**, with no matching KEYUP, ahead of every injected batch. So the
symptom is not a Keyman-typing glitch: it is a genuinely stuck modifier
**machine-wide**, affecting every keyboard and every application, until something
happens to correct the cache.

Two consequences that took the longest to establish:

- **The damage is charged even when no Keyman keyboard is active.** The modifier
  post at `k32_lowlevelkeyboardhook.cpp:198` runs 35 lines *before* the
  `!isKeymanKeyboardActive` pass-through at `:233` and does not consult it. So
  "no Keyman keyboard was active, therefore Keyman is uninvolved" is false
  reasoning — and it is exactly the reasoning that kept getting applied.
- **Only six keys are in scope**, and Right Ctrl is the worst case. See
  `MODIFIERS.md`.

## Status

| claim | standing |
|---|---|
| The mechanism, as described above | **proven from code, and reproduced 3/3** |
| It is Keyman, not the layout / Windows / the harness | **measured.** Three-arm controlled test: US 0/10, Microsoft Cameroon QWERTY 2017 0/10, Keyman wedged. `TRIGGER.md` §3 |
| The wedge is charged while a non-Keyman keyboard is active | **measured 3/3** (`kmproof.ps1 -ChargeTest`) |
| Blast radius is machine-wide, not Keyman-only | **measured** |
| Scope is exactly six keys: L/R Shift, Ctrl, Alt | **MEASURED 2026-08-24.** All six latch 2/2 (Ctrl 7/7 per side); Insert / NumLock / CapsLock / ScrollLock 0/2 under the identical stimulus. `MODIFIERS.md` §2b |
| Right Ctrl can be phantom-stuck with no physical Right Ctrl key | **MEASURED 2026-08-24.** A latched Right Ctrl is cleared only by the exact matching KEYUP — not by typing, not by tapping Left Ctrl. Still unconfirmed on affected *hardware*. `MODIFIERS.md` §3b |
| A stuck Ctrl can read CLEAN to a text-only oracle | **measured.** `held=RCTRL` with the text probe returning correct lowercase. `kmproof.ps1` would have scored those trials CLEAN. `MODIFIERS.md` §2b |
| The latch set accumulates within a session | **observed, mechanism still unknown.** Survives a 30 s wait, a verified focus round-trip, one KEYUP sweep and two consecutive sweeps. Cleared only by crossing a process boundary, 9 s later. Four hypotheses tested and killed. `MODIFIERS.md` §2c, `TODO.md` I12 |
| The phantom KEYDOWN, observed directly | **measured 2026-08-25.** A `WH_KEYBOARD_LL` capture during a live trial shows `keybd_shift_reset` emitting `DN LSHIFT scan=0xFF` with no matching KEYUP. Not inferred — on the wire. `MODIFIERS.md` §2a-wire |
| The freeze is the mechanism, for all six keys | **measured.** Candidate A (identical stimulus, no freeze posted) latched 0/20 across all ten keys. Previously known for LShift only. `MODIFIERS.md` §2b |
| A stuck **letter or number** is not this bug | **proven from code.** `do_keybd_event` has four call sites, all emitting `modifiers[6]` or the prefix VK. `MODIFIERS.md` §2a |
| …but a stuck letter *is* reachable by a **different** defect | **proven from code, unmeasured.** Dropped `QIT_VKEYUP` at the queue-full boundary — `kmprocess.cpp:181-182` ignores both `QueueAction` return values. Narrow reachability. `TODO.md` I10 |
| A stuck **prefix VK** is reachable by a third defect | **proven from code, unmeasured.** `PostDummyKeyEvent` uses two non-atomic `keybd_event` calls. Invisible to every text oracle; only `GetAsyncKeyState` sees it. `TODO.md` I11 |
| AltGr is the seed for a stuck **Right** Ctrl | **NO, on this machine — MEASURED 2026-08-25, physically, on all three arms.** MSKLC is the only arm setting `KLLF_ALTGR`, and all 22 physical AltGr presses paired with a **non-extended LEFT Ctrl** (44/44 carrying Windows' `scan=0x21D` fake-Ctrl marker). The Keyman arm emits no Ctrl at all — its US base layout lacks the flag. Affected field hardware is now the only gap. `MODIFIERS.md` §3d-measured, `TODO.md` I1 |
| The dev machine is itself the no-Right-Ctrl hardware class | **confirmed 2026-08-25.** It has no physical Right Ctrl key, so §3b's "the workaround is unavailable to the user" is a direct observation here rather than an extrapolation. `MODIFIERS.md` §3b |
| Keyman's serializer replays keystrokes on non-Keyman layouts | **NO — measured 2026-08-25.** The Keyman arm doubled every keystroke with a `KM-SERIALIZED` replay; the MSKLC arm produced zero across 102 events. Holds alongside the charge-test row above — charging the wedge is not the same act as replaying a key, so do not read this as "Keyman is inert on other layouts". `MODIFIERS.md` §3d-measured |
| **What stalls the thread in the field** | **NOT established.** The stall is induced deliberately; CPU load alone did not reproduce it (32 hogs / 16 cores, 0/10). This is the main open gap — `TODO.md` I3. Ross's focus-change observation is the best lead, see `issue-8064/README.md` §2. Note the stimulus is **not** debug-only: the handler is an ungated `Sleep(5000)` and already ships as `fakefreeze`; it simply has no `build.sh` |
| The hypothesis this started from — that 18.0.245's `LowLevelHookWatchDog` tears the hook out and reinstalls it | **NOT SUPPORTED, and retracted.** The ghost key was absent from every reproducing run: 27 iterations, 0 failures. This agrees with mcdurdin's own note on #8064 that the watchdog PRs probably did not resolve it |

---

## Reading order

Start here and stop when you have what you need.

| doc | what it is |
|---|---|
| **`issue-8064/README.md`** | **Read first.** This is #8064 and it is Ross's. His field evidence, the crosswalk against these findings, the two questions to ask him, and the ordered path to closing the issue. |
| **`TRIGGER.md`** | The full write-up: plain-language description, the defect chain with code refs, the reproduction, and **§3, the three-arm controlled proof**. Also carries the hard-won harness traps — read those before writing any test here. |
| **`MODIFIERS.md`** | Which modifier keys are actually in scope. Rules Win, Fn, Scroll Lock and Insert out; explains phantom Right Ctrl on hardware that has no such key; separates the two independent caches. |
| **`FIX-PROPOSAL.md`** | Proposed fixes in order of value, with the caveats not to overstate in a PR. |
| **`HAZARDS.md`** | **Read before writing or changing harness code.** FLEx and FieldWorks operational hazards plus the safety rules for the live language data. Two of these corrupted the user's lexicon. |
| **`TODO.md`** | Working list: investigations, deferred Cache A work, harness gaps, test gates, and suggested order. The Cache B fixes moved to [`capslock/TODO.md`](capslock/TODO.md). |
| **`TEST-PLAN.md`** | Plan for porting these findings into Keyman's own test structures: the repro recipe, the gtest and manual-test deliverables, and the cross-platform prevention work. Companion: `MEETING-PREP.md`. |
| **`capslock/`** | The separate Caps Lock / Cache B defect (#16422 / #16423). |

---

## Scripts

Three, and all three are correct on both known measurement hazards. `kmproof` and
`kmmods` test perpendicular axes of the same experiment: `kmproof` fixes the
modifier and varies the keyboard, `kmmods` fixes the keyboard and varies the
modifier. `kmaltgr` reads the wire underneath both.

| script | role |
|---|---|
| **`kmproof.ps1`** | **Attribution.** Three-arm controlled test — US / MSKLC / Keyman, one stimulus, only the active keyboard varies. This is what supports the "it is Keyman" claim. Modes include `-ChargeTest` (charge while inactive, fire on activation) and `-Sweep` (separate Keyman-only causation from machine-wide blast radius). Exercises **LShift and RAlt only**. |
| **`kmmods.ps1`** | **Scope.** Which of the thirteen candidate keys can actually be stuck. Same stimulus applied to each of the six Cache A slots *and* to Insert / Win / Apps / NumLock / CapsLock / ScrollLock as negative controls, so `MODIFIERS.md` §2 stops being inference. Carries the modifier-agnostic **state oracle** (`GetAsyncKeyState`) that `kmproof`'s case-change oracles cannot provide, which is what makes Ctrl measurable at all. `-Latch <MOD>` is the missing-key permanence arm. Covers `TODO.md` H1, H2 and H3. |
| **`kmaltgr.ps1`** | **Wire-level logger.** A `WH_KEYBOARD_LL` hook recording `vkCode` / `scanCode` / `flags` / `dwExtraInfo` for every event on the machine, with the hook and message pump in C# so the callback cannot exceed `LowLevelHooksTimeout`. Decodes Keyman's two markers (`scan 0xFF` = synthesized, `extraInfo 0x4B4D0000` = serializer replay) and Windows' AltGr fake-Ctrl marker (`scan 0x21D`). Built for `TODO.md` I1; it also captured `keybd_shift_reset`'s unmatched KEYDOWN directly. **Logs every keystroke while running — do not type passwords.** |

Both `kmproof.ps1` and `kmmods.ps1` implement the freeze stimulus themselves, and
both **confirm the asynchronous `PostMessage` actually landed** before the trial
proceeds. That confirmation is the whole difference between candidate B
(intermittent) and candidate I (deterministic), and any new harness needs it.

Build identification needs no script:

```powershell
(Get-Item "${env:ProgramFiles(x86)}\Keyman\Keyman Desktop\keyman.exe").VersionInfo.FileVersion
```

### [WARN] Two hazards to design against

Both cost a round of false results. Any new harness can reintroduce them.

1. **Do not resolve the keyboard layout from the top-level window.** Windows 11
   Notepad's frame window sits on a thread pinned at `0x0409` forever, while the
   focused edit control is on a different thread that tracks the input locale
   correctly. Reading the frame thread reports `0x0409` while Keyman is
   demonstrably live. Resolve from `GetGUIThreadInfo(0).hwndFocus` instead.
2. **Do not use `Write-Host`.** Measured on this machine with a congested console:
   `Write-Host` **4301 ms/line** versus `[Console]::Out.WriteLine` 0.4 ms/line.
   That is a *correctness* hazard here, not a speed one — multi-second dead time
   can let a 5 s freeze expire before the probe runs, silently turning a trial
   into a no-freeze control.

A third was suspected and then **disproved** — recorded because the retraction is
the useful part:

3. **Right Shift marked extended — cosmetic, not a bug.** `kmproof.ps1:288` had
   `@{V=0xA1;E=$true; L='RShift'}`. Right Shift really is scan `0x36` and
   unextended, so the entry was wrong on its face, and the first write-up
   concluded `ClearMods` had never released RShift and that `TODO.md` I4 needed
   re-running against a "five-key sweep".

   **That conclusion was wrong.** Measured at the wire with `kmaltgr.ps1`
   (2026-08-25), injecting `VK_RSHIFT` with and without the extended flag yields
   byte-identical events at a `WH_KEYBOARD_LL` hook — both `RSHIFT scan=0x36
   EXT|INJ`. Windows resolves the side from the side-specific **virtual key**
   (`0xA1`), not the scan code or the flag. The sweeps were always six keys and
   I4 is unaffected. The entry is now `E=$false` for form only.

   The bit *does* decide the side when the caller passes the **generic** VK —
   which is what Keyman's `do_keybd_event` does, and why it sets
   `scan = SCANCODE_RSHIFT` explicitly for Right Shift.

---

## Quick start

Requires an elevated-enough PowerShell to post to keyman.exe, Keyman running, and
Notepad open with the Keyman Cameroon keyboard active.

```powershell
cd D:\Github\_Projects\_KM\kmrepro

# Confirm the three keyboards are distinguishable and output-identical
powershell -ExecutionPolicy Bypass -File .\kmproof.ps1 -FingerprintOnly

# The attribution result
powershell -ExecutionPolicy Bypass -File .\kmproof.ps1 -LoadThreads 4

# Charge on a Microsoft keyboard, fire on switching back to Keyman
powershell -ExecutionPolicy Bypass -File .\kmproof.ps1 -ChargeTest 5

# --- scope: which keys can actually stick -------------------------------
# Catalog + live modifier state. Injects nothing, needs no Notepad.
powershell -ExecutionPolicy Bypass -File .\kmmods.ps1 -CatalogOnly

# The scope matrix: 6 Cache A slots + immune-key negative controls
powershell -ExecutionPolicy Bypass -File .\kmmods.ps1 -LoadThreads 4

# The Ctrl gap, which no run has ever covered
powershell -ExecutionPolicy Bypass -File .\kmmods.ps1 -Mods LCTRL,RCTRL -Only I -Repeat 5

# Missing-key permanence: latch Right Ctrl, then see what clears it
powershell -ExecutionPolicy Bypass -File .\kmmods.ps1 -Latch RCTRL
```

Logs land in `$env:TEMP\kmrepro` by default (`-LogDir` to change).

### Recovery, if you wedge your own machine

Send a plain **KEYUP for each of the six modifiers** — no press needed. Ordinary
physical typing does the same, which is why the symptom appears to "fix itself"
once a user starts interacting. Restarting Keyman is the reliable fallback.

Note this workaround **cannot** work for a modifier your keyboard does not
physically have; see `MODIFIERS.md` §3b.

---

## Before you write a test here

`TRIGGER.md` has the full list of measurement traps; `HAZARDS.md` covers the
ways you can break the target rather than mis-measure it. The four below have
each already cost a round of false results:

- **PowerShell `-eq` / `-ne` / `-match` are case-insensitive**, and U+014A/U+014B
  are the upper/lowercase ENG pair — so wedged output compares *equal* to clean
  output. Use `-ceq` / `-cne`. **The symptom is a case change; the comparison must
  be case-sensitive.**
- **A stuck Ctrl produces no case change at all.** The `abc`/`ABC` oracle reads
  CLEAN under a stuck Ctrl. Any Ctrl arm needs a different probe or it will
  report false negatives the same way the case-insensitive comparison did.
- **Never clear the test field with keystrokes.** `Ctrl+A` + `Delete` works on a
  clean machine and fails silently the instant the wedge fires — with Shift
  latched it arrives as `Ctrl+Shift+A` and `Shift+Delete`, the field is never
  emptied, and every later probe reads the whole accumulated buffer. Use UIA
  `ValuePattern.SetValue('')`, which touches no keys.
- **A bare Alt press+release is the Windows menu-activation gesture**, and
  produces a near-perfect impersonation of this bug with Keyman uninvolved.
  Prefer LShift for modifier tests.

Two environment facts that invalidated earlier runs:

- **This machine has two Cameroon keyboards** — the Keyman TIP (langid `0x2000`)
  and a Microsoft/MSKLC layout (`0x0436`). **Both map `;e` to U+0259**, so a
  behavioural check alone cannot tell them apart, and Win+Space cycling lands on
  either. Results that predate per-trial layout logging are unattributable.
- **Compare the full HKL, not just the langid.** en-US carries two input methods
  here; Win+Space can land on Dvorak as `0xF0020409`. Since `abc` is not `abc` on
  Dvorak, a langid-only check lets the ASCII oracle silently lie. Require
  `0x04090409` exactly.

---

## Data and privacy

`.gitignore` excludes all image formats. The FieldWorks screenshots show real
Ngoreme lexical entries, which are the language community's data rather than this
project's, so they are kept out of the repository by default. To publish a
specific set deliberately:

```powershell
git add -f <path-to-the-screenshots>/*.png
```

`logs/` holds raw run evidence from the three live scripts and is tracked:
`altgr-physical-keyman-arm.{txt,csv}` and `altgr-physical-msklc-arm.{txt,csv}` are
the two physical AltGr captures — 20 and 22 real presses — and the MSKLC one is the
actual answer to `TODO.md` I1. `mods-prefix-latch-evidence.txt` is the six-key
scope matrix. A negative result is only citable with its raw evidence attached,
which is why these are here rather than summarised away.

⚠️ The summary table *inside* `mods-prefix-latch-evidence.txt` predates the `self`
column and shows the immune keys as "2/2 latched" from §2c residue — **quote
`MODIFIERS.md` §2b instead.**

Nothing in `logs/` carries a measurement hazard: output from superseded harnesses
was moved out, and seven byte-identical duplicate runs were removed outright.


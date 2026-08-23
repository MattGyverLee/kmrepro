# kmrepro — Keyman for Windows stuck-modifier investigation

An investigation harness, not a product. It exists to characterise, reproduce and
attribute one class of Keyman for Windows bug:

> Typing suddenly comes out capitalised, or stops appearing entirely, while
> Keyman still shows the correct keyboard as active. It behaves exactly as if a
> modifier key were physically held down, but no key is stuck. Restarting Keyman
> clears it.

Investigated on **Keyman for Windows 18.0.249.0**, Windows 11 Pro 26200, against
`sil_cameroon_qwerty` in Notepad and FieldWorks (Ngoreme project).

Companion Keyman checkout: `../keyman`, branch
`fix/windows/16422-caps-lock-state-on-keyboard-switch`.

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
| Scope is exactly six keys: L/R Shift, Ctrl, Alt | **proven from code.** `MODIFIERS.md` §2 |
| Right Ctrl can be phantom-stuck with no physical Right Ctrl key | **proven from code**, not yet confirmed on affected hardware. `MODIFIERS.md` §3 |
| **What stalls the thread in the field** | **NOT established.** The repro induces the stall with a debug-only command. CPU load alone did not reproduce it. This is the main open gap — `TODO.md` I3 |
| The original watchdog hypothesis | **not supported.** See "Historical record" below |

---

## Reading order

Start here and stop when you have what you need.

| doc | what it is |
|---|---|
| **`report.md`** | One-page summary. Read first. |
| **`TRIGGER.md`** | The full write-up: plain-language description, the defect chain with code refs, the reproduction, and **§3, the three-arm controlled proof**. Also carries the hard-won harness traps — read those before writing any test here. |
| **`MODIFIERS.md`** | Which modifier keys are actually in scope. Rules Win, Fn, Scroll Lock and Insert out; explains phantom Right Ctrl on hardware that has no such key; separates the two independent caches. |
| **`FIX-PROPOSAL.md`** | Proposed fixes in order of value, with the caveats not to overstate in a PR. |
| **`HAZARDS.md`** | **Read before writing or changing harness code.** FLEx and FieldWorks operational hazards plus the safety rules for the live language data. Two of these corrupted the user's lexicon. |
| **`TODO.md`** | Working list: investigations, the PR #16423 fixes, deferred Cache A work, harness gaps, test gates, and suggested order. |

### Historical record — read with a date in mind

These predate the current understanding and are kept because they contain the
measurements, not because their conclusions hold.

| doc | caveat |
|---|---|
| `PROTOCOL.md` | Test protocol for the **original hypothesis** — that the `LowLevelHookWatchDog` added in 18.0.245 tears out and reinstalls the hook. **That hypothesis was not supported**; the ghost key was absent from every reproducing run. |
| `RESULTS-control-18.0.238.md` | Control baseline, pre-watchdog build. All clean. |
| `RESULTS-treatment-18.0.249.md` | Treatment run. Watchdog confirmed present and live, but the hypothesised failure did not reproduce in 45 iterations. This is the null result that redirected the investigation. |
| `archive/HANDOFF.md` | Archived 2026-08-23. Framed around the unsupported watchdog hypothesis, and its status header predates the upgrade it was waiting on. Its live content was extracted first: the hazards and safety rules to `HAZARDS.md`, the secondary suspects and ruled-out list to `TODO.md` §1 and §1a. |
| `archive/` | Superseded scripts: `kmwedge.ps1` (structured on the wrong assumption — trigger inside each iteration), `kmstick.ps1`, and earlier reports. |

---

## Scripts

**Use `kmproof.ps1`.** It is the only script correct on both known harness
hazards (see the warning below).

| script | role |
|---|---|
| **`kmproof.ps1`** | **Current tool.** Three-arm controlled test — US / MSKLC / Keyman, one stimulus, only the active keyboard varies. This is what supports the attribution claim. Modes include `-ChargeTest` (charge while inactive, fire on activation) and `-Sweep` (separate Keyman-only causation from machine-wide blast radius). |
| `kmhunt.ps1` | Earlier single-keyboard version. Answers "what *transitions* Keyman from clean to wedged" via probe -> action -> probe. Can show the wedge but **cannot attribute it** — with one keyboard you cannot separate Keyman from the layout, from Windows, or from the harness. |
| `kmrepro.ps1` | Rig for the original watchdog hypothesis. `Status`, `Arm`, `Freeze`, `GhostKey`, `ModWatch`, `Soak`, `AutoTest`. Still useful for `Status` (build/watchdog identification) and for inducing the stall. |
| `kmflex.ps1` | FieldWorks driver. FLEx auto-switches keyboard per writing system, which makes clicking between an Ngoreme field and an English field a clean keyboard-switch vector. FLEx RootSite views expose no UI Automation text, so verification is by screenshot. |
| `kmshot.ps1` | Screen capture and positional click helper, for targets UI Automation cannot read. |

### [WARN] Three of the four scripts carry known-bad patterns

`kmhunt.ps1`, `kmrepro.ps1` and `kmflex.ps1` have **not** been updated for two
hazards that were found the hard way. **Any number quoted from those three is
suspect until `TODO.md` H4 is done.**

1. **They resolve the keyboard layout from the top-level window.** Windows 11
   Notepad's frame window sits on a thread pinned at `0x0409` forever, while the
   focused edit control is on a different thread that tracks the input locale
   correctly. Reading the frame thread reports `0x0409` while Keyman is
   demonstrably live. Resolve from `GetGUIThreadInfo(0).hwndFocus` instead.
2. **They use `Write-Host`.** Measured on this machine with a congested console:
   `Write-Host` **4301 ms/line** versus `[Console]::Out.WriteLine` 0.4 ms/line.
   That is a *correctness* hazard here, not a speed one — multi-second dead time
   can let a 5 s freeze expire before the probe runs, silently turning a trial
   into a no-freeze control.

---

## Quick start

Requires an elevated-enough PowerShell to post to keyman.exe, Keyman running, and
Notepad open with the Keyman Cameroon keyboard active.

```powershell
cd D:\Github\_Projects\_KM\kmrepro

# What build is this, and is the watchdog present?
powershell -ExecutionPolicy Bypass -File .\kmrepro.ps1 Status

# Confirm the three keyboards are distinguishable and output-identical
powershell -ExecutionPolicy Bypass -File .\kmproof.ps1 -FingerprintOnly

# The attribution result
powershell -ExecutionPolicy Bypass -File .\kmproof.ps1 -LoadThreads 4

# Charge on a Microsoft keyboard, fire on switching back to Keyman
powershell -ExecutionPolicy Bypass -File .\kmproof.ps1 -ChargeTest 5
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
git add -f archive/reports-control/*.png
```

`logs-treatment/` holds the raw run logs from the treatment build and is tracked.

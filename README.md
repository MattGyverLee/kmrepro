# kmrepro — Keyman for Windows stuck-modifier investigation

An investigation harness, not a product. It exists to characterise, reproduce and
attribute one class of Keyman for Windows bug:

> Typing suddenly comes out capitalised, or stops appearing entirely, while
> Keyman still shows the correct keyboard as active. It behaves exactly as if a
> modifier key were physically held down, but no key is stuck. Restarting Keyman or the computer 
> clears it.

Investigated on **Keyman for Windows 18.0.249.0**, Windows 11 Pro 26200, against
`sil_cameroon_qwerty` in **Notepad**. It was first noticed while typing Ngoreme
into FieldWorks, but the defect is system-wide and needs nothing but Notepad to
reproduce; FieldWorks testing is out of scope.

Companion Keyman checkout: `../keyman`, branch
`fix/windows/8064-reconcile-modifier-cache` (based on upstream `master` @ `deeff0456f`).

> **The fix has landed in that branch.** As of 2026-08-26 this repo is no longer analysis-only:
> Cache A is re-validated against the OS before every injected batch, the defect and the fix are
> both asserted by tests inside Keyman's own gtest suite, and the stall stimulus is buildable
> through the standard builder. See **[IN-TREE.md](IN-TREE.md)** for what shipped, on what evidence,
> and for the eleven corrections that session made to the analysis in this repo.

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

The **Caps Lock / un-read-state** defect ([#16422][i16422], PR [#16423][i16423]) is
a *different bug* that was explored here too. It has been split out to
**[`capslock/`](capslock/README.md)** — same staleness shape, different cache,
different symptom, no phantom keypress.

It is **already its own pull request on its own branch**, and it is out of scope for the
#8064 branch: that one is based on `origin/master`, not on
`fix/windows/16422-caps-lock-state-on-keyboard-switch`, so none of PR #16423's commits are
ancestors of it. The only Caps Lock references there are negative controls asserting the
boundary between the two defects. See [IN-TREE.md](IN-TREE.md).

Plan for porting this into Keyman's own test structures:
**[TEST-PLAN.md](TEST-PLAN.md)** — the Cache A parts of which are **done**; see
**[IN-TREE.md](IN-TREE.md)**.

[i8064]: https://github.com/keymanapp/keyman/issues/8064
[i1620]: https://github.com/keymanapp/keyman/issues/1620
[i4884]: https://github.com/keymanapp/keyman/issues/4884
[i7337]: https://github.com/keymanapp/keyman/issues/7337
[i16422]: https://github.com/keymanapp/keyman/issues/16422
[i16423]: https://github.com/keymanapp/keyman/pull/16423
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
  post at `k32_lowlevelkeyboardhook.cpp:198` runs 31 lines *before* the
  `!isKeymanKeyboardActive` pass-through at `:229` and does not consult it. So
  "no Keyman keyboard was active, therefore Keyman is uninvolved" is false
  reasoning — and it is exactly the reasoning that kept getting applied.
- **Only six keys are in scope**, and Right Ctrl is the worst case. See
  `MODIFIERS.md`.

## Status

| claim | standing |
|---|---|
| The mechanism, as described above | **proven from code, reproduced 3/3, and now asserted by a test inside Keyman.** `KEYBD_SHIFT.ResetRepressesFromCache` takes one stale byte and shows the unmatched KEYDOWN, on unmodified production code. `IN-TREE.md` §2 |
| **The fix works** | **implemented, compiled, tested, committed.** `ReconcileModifierCache` at the top of `PrepareInjectedInput`; `test:x86` 19/19, `test:x64` 18/18, both engine DLLs link clean. 64 production lines across 3 files. **The follow-on branch takes this to 33/33 and 32/32** and closes four of the review's six items. `IN-TREE.md` §2 |
| **The Keyman gtest suite is buildable on this machine** | **established 2026-08-26.** Every earlier document here was written against a checkout where nothing had been through a compiler. Two blockers, both solvable: a one-time NuGet restore, and avoiding `build.sh configure` (it builds core for arm64 and dies on missing ARM64 MSVC libs). `IN-TREE.md` §1 |
| The phantom is re-pressed **per output batch**, not per keystroke | **corrected 2026-08-26.** `keybd_shift` has exactly two call sites repo-wide, both in `PrepareInjectedInput`, reached only on `WM_USER`. The symptom is unchanged — plain replays arrive shifted once the phantom lands — but the stronger claim is false and must not go in a PR. `IN-TREE.md` §3 C-1 |
| The fix is **preventive, not curative** | **established 2026-08-26.** Once the phantom KEYDOWN has been sent the modifier is genuinely held, cache and OS agree, and no `GetAsyncKeyState` check can still see the fault. Batch start is the last point at which prevention is possible — and it cannot recover an already-latched process. `IN-TREE.md` §3 C-2 |
| Cache A is fed by Keyman's **own** synthetic modifier events | **proven from code 2026-08-26.** The post at `k32_lowlevelkeyboardhook.cpp:198` does not exclude them; release drives the byte to 0 and reset drives it back to 0x80 every batch. The fix works with that loop, and it is why filtering Keyman's markers is unnecessary here. `IN-TREE.md` §3 C-10 |
| A watchdog-driven reconcile would help | **NO — refuted 2026-08-26.** `ISerialKeyEventServer::GetServer()` is `NULL` in every process but keyman.exe, and there the GetMessage hook sees only keyman.exe's own keystrokes. Dropped from the fix. `IN-TREE.md` §3 C-3 |
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
| The dev machine is itself the no-Right-Ctrl hardware class | **established 2026-08-25, on the user's report** — corroborated by the wire capture (seven Ctrl taps, all `LCTRL`), which cannot by itself prove a key's absence. So §3b's "the workaround is unavailable to the user" is a direct observation here rather than an extrapolation. `MODIFIERS.md` §3b |
| Keyman's serializer replays keystrokes on non-Keyman layouts | **NO — measured 2026-08-25.** The Keyman arm doubled every keystroke with a `KM-SERIALIZED` replay; the MSKLC arm produced zero across 102 events. Holds alongside the charge-test row above — charging the wedge is not the same act as replaying a key, so do not read this as "Keyman is inert on other layouts". `MODIFIERS.md` §3d-measured |
| **What stalls the thread in the field** | **NOT established.** The stall is induced deliberately; CPU load alone did not reproduce it (32 hogs / 16 cores, 0/10). This is the main open gap — `TODO.md` I3. Ross's focus-change observation is the best lead, see `issue-8064/README.md` §2. Note the stimulus is **not** debug-only: the handler is an ungated `Sleep(5000)` and already ships as `fakefreeze` — which **now has a `build.sh` and is registered in `support/build.sh`**, so `./windows/build.sh` reaches it and a second person can run the repro. `IN-TREE.md` §5 |
| **Whether Cache A exists in the 64-bit engine** | **NOT established — inference only.** `serialkeyeventserver.cpp` is wrapped `#ifndef _WIN64` (`:7`/`:595`). The working assumption is that keyman.exe is 32-bit, hosts the single server, and its `SendInput` reaches 64-bit hosts like any other injected input — which is what makes the "machine-wide" and "blast radius" rows above cover 64-bit apps. **That step is unverified.** `TODO.md` I5 |
| The hypothesis this started from — that 18.0.245's `LowLevelHookWatchDog` tears the hook out and reinstalls it | **NOT SUPPORTED, and retracted.** Every reproduction in this repo was obtained with the watchdog's hook-reinstall never provoked at all: `kmproof.ps1` 3/3 on candidate I and 10/10 on the sweep, `kmmods.ps1` six slots 2/2. The freeze alone is sufficient; provoking the hook reinstall is not required at all. This agrees with mcdurdin's own note on #8064 that the watchdog PRs probably did not resolve it |

---

## Reading order

Start here and stop when you have what you need.

| doc | what it is |
|---|---|
| **`issue-8064/README.md`** | **Read first.** This is #8064 and it is Ross's. His field evidence, the crosswalk against these findings, the two questions to ask him, and the ordered path to closing the issue. |
| **`IN-TREE.md`** | **Read second, and before trusting any code claim in the older docs.** What has actually landed in Keyman, the build environment that made it possible, the eleven corrections that session made to the analysis here, and the three test-plan risks it turned from reasoning into measurement. The only document in this repo describing compiled, executed, committed work. |
| **`TRIGGER.md`** | The full write-up: plain-language description, the defect chain with code refs, the reproduction, and **§3, the three-arm controlled proof**. Also carries the hard-won harness traps — read those before writing any test here. |
| **`MODIFIERS.md`** | Which modifier keys are actually in scope. Rules Win, Fn, Scroll Lock and Insert out; explains phantom Right Ctrl on hardware that has no such key; separates the two independent caches. |
| **`FIX-PROPOSAL.md`** | Proposed fixes in order of value, with the caveats not to overstate in a PR. |
| **`HAZARDS.md`** | **Read before writing or changing harness code.** Five ways to break the target rather than mis-measure it — extended navigation keys, PowerShell name collisions, the HKL focus thread, `dwExtraInfo = 0`, the version read. |
| **`TODO.md`** | Working list: investigations, deferred Cache A work, harness gaps, test gates, and suggested order. The Cache B fixes moved to [`capslock/TODO.md`](capslock/TODO.md). |
| **`TEST-PLAN.md`** | Plan for porting these findings into Keyman's own test structures: the repro recipe, the gtest and manual-test deliverables, and the cross-platform prevention work. The Cache A gtests, the manual test and the `fakefreeze` build entry point are **done** — `IN-TREE.md` records what shipped; the cross-platform work (X1-X10) and the `NormalizeModifierVk` seam are still open. Companion: `MEETING-PREP.md`. |
| **`capslock/`** | The separate Caps Lock / Cache B defect (#16422 / #16423). |

---

## Scripts

Three, and all three are correct on both known measurement hazards. `kmproof` and
`kmmods` test perpendicular axes of the same experiment: `kmproof` fixes the
modifier and varies the keyboard, `kmmods` fixes the keyboard and varies the
modifier. `kmaltgr` reads the wire underneath both.

| script | role |
|---|---|
| **`kmproof.ps1`** | **Attribution.** Controlled cross-keyboard test — English / MSKLC / Keyman, one stimulus, only the active keyboard varies. The English arm is any non-Dvorak English QWERTY (US, UK, Australian, …) and MSKLC is optional, so a reviewer needs only an English keyboard plus the Keyman one. This is what supports the "it is Keyman" claim. Modes include `-ChargeTest` (charge while inactive, fire on activation) and `-Sweep` (separate Keyman-only causation from machine-wide blast radius). Exercises **LShift and RAlt only**. |
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

A third was raised and **disproved** — the one-line retraction, so nobody
re-raises it:

3. **Right Shift marked extended is cosmetic, not a bug.** Measured at the wire
   with `kmaltgr.ps1` (2026-08-25): injecting `VK_RSHIFT` with and without the
   extended flag yields byte-identical events at a `WH_KEYBOARD_LL` hook.

   Windows resolves the side from the side-specific **virtual key** (`0xA1`), not
   the scan code or the flag. The bit *does* decide the side when the caller
   passes the **generic** VK — which is what Keyman's `do_keybd_event` does, and
   why it sets `scan = SCANCODE_RSHIFT` explicitly for Right Shift.

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

This section is about the **PowerShell harnesses in this repo**. Tests written
inside the Keyman tree have a different and non-overlapping set of traps — gtest
1.8.1 with no `GTEST_SKIP()` and no gmock, a `_CrtMemDifference` leak detector
that fails on `SCOPED_TRACE`, warnings compiled as errors, and a test project
with no glob so an unlisted file silently never runs. Those are in
[`TEST-PLAN.md`](TEST-PLAN.md) and [`IN-TREE.md`](IN-TREE.md).

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



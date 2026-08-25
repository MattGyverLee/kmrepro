# TODO — stuck modifier / un-read modifier state

Working list across two defects that share a cache-staleness shape but land in
different places. See `MODIFIERS.md` §1 for the Cache A / Cache B split and §7
for why the destinations differ.

**Status legend:** `[ ]` open `[~]` in progress `[x]` done `[-]` deferred by
decision (not forgotten)

**Destinations:**
- **Cache A** (stuck modifier, phantom keypresses) -> this repo for now.
  **Not being fixed in Keyman code yet** — explicit direction 2026-08-23.
- **Cache B** (un-read modifier/toggle state) -> branch
  `fix/windows/16422-caps-lock-state-on-keyboard-switch`, i.e. **PR #16423**.

Code refs are `windows/src/engine/keyman32/` at `a70538106c` unless noted.

---

## 1. Investigations

Ordered by value-per-hour. I1 and I5 change what the other sections should say,
so they come first.

- [ ] **I1 — Does the AltGr-synthesized Ctrl ever carry the extended bit?**
  The linchpin of the Right Ctrl seed question (`MODIFIERS.md` §3d.3). Standard
  Windows behaviour is a *Left*, non-extended Ctrl, which would seed `LCTRL`. But
  `aiTIP.cpp:467` special-cases `TF_MOD_RALT|TF_MOD_LCONTROL`, so Keyman already
  knows the pairing is quirky.
  **Why it matters:** the Cameroon keyboards use AltGr on *every* accented
  character. If any driver emits that Ctrl extended, the seed is not exotic — it
  is every keystroke, and the severity of the whole bug goes up sharply.
  **Method:** standalone `WH_KEYBOARD_LL` logger recording `vkCode`, `scanCode`,
  `flags & LLKHF_EXTENDED`, `dwExtraInfo` for the Ctrl accompanying AltGr. Run on
  the Keyman TIP, the MSKLC layout, and US, on both this machine and affected
  field hardware.

  **Built: `kmaltgr.ps1`. Half answered, 2026-08-25.**

  Injected RAlt, all three arms (`-Arms`):

  | arm | synthetic Ctrl? | side | extended? |
  |---|---|---|---|
  | US | none | — | — |
  | MSKLC | **yes**, `scan=0x21D` | **LEFT** | **no** |
  | Keyman | **none at all** | — | — |

  So on this machine the AltGr path seeds `LCTRL`, non-extended — the standard
  behaviour — and on the Keyman arm it does not fire at all, because the TIP
  handles RAlt itself rather than relying on the layout's AltGr.

  Two incidental results worth keeping:
  - **Injection does trigger the layout's AltGr synthesis.** It was not obvious
    it would; it does. `scan=0x21D` is Windows' own marker for the fake Ctrl, so
    this is positive identification rather than a nearby Ctrl coincidence.
  - An `LCTRL` seed is **still a stuck Ctrl** — `LCTRL` latches 7/7 (s2b). It is
    merely clearable, because every keyboard has a physical Left Ctrl. The
    severity escalation this item is really about needs the *extended* variant.

  **STILL OPEN, and it is the half that matters: the PHYSICAL test.**
  Everything above used `keybd_event`. Only a real finger on a real AltGr key
  exercises the actual keyboard driver and any vendor Fn-layer remapping sitting
  in front of it — which is exactly the population s3d item 2 is about, and
  exactly where a Right Ctrl remap would live. Two attempts on 2026-08-25
  captured zero events because nobody was at the keyboard during the window; the
  hook itself is verified working (it caught a cross-process injection
  immediately).

  **To finish it:** run `.\kmaltgr.ps1 -Watch 45` interactively so the countdown
  is visible, then press the physical AltGr several times, type `;` `e`
  `AltGr+N`, and tap a physical Right Ctrl if the keyboard has one. Then run the
  same on affected field hardware, which is the reading that actually decides
  the severity.

- [ ] **I5 — Does Cache A exist in the 64-bit engine?**
  `serialkeyeventserver.cpp` is wrapped `#ifndef _WIN64` (`:7` / `:595`), so the
  server object is compiled into the 32-bit engine only, while the LL hook calls
  `GetServer()` at `:201` and `:258`. Working assumption: keyman.exe is 32-bit and
  hosts the single server, and its `SendInput` reaches 64-bit host apps like any
  other injected input — so 64-bit hosts are *affected* even though the cache
  lives in the 32-bit engine. **This is inference, not verified.**
  **Why it matters:** every blast-radius and fix-coverage claim depends on it.
  `FIX-PROPOSAL.md` already flags it as an open caveat. Resolve before any fix
  claims to cover 64-bit.

- [ ] **I8 — Mixed engine versions after an in-place upgrade.**
  Rescued from `HANDOFF.md` §4 when it was archived, because it is an independent
  candidate mechanism that no other doc carries.
  `keyman32.dll` / `kmtip.dll` are mapped into every running application, so an
  in-place upgrade with `REBOOT=ReallySuppress` (`RunTools.pas:514`,
  `REINSTALLMODE=vomus REINSTALL=ALL`) replaces `keyman.exe` immediately while the
  injected DLLs keep serving the *old* code until reboot. **There is no version
  handshake anywhere between engine components** (grepped).
  **Why it matters:** this independently explains two things the current write-ups
  attribute to the stall — the "started right after the update" clustering, and
  why rebooting fixes it more thoroughly than restarting Keyman. It may be a
  co-factor rather than an alternative, and it is a candidate for the unexplained
  run in **I4**.

- [ ] **I9 — Does a failed hook reinstall leave Keyman unrecoverable?**
  Also from `HANDOFF.md`. `InitLowLevelHook()` is not retried on failure, so a
  failed reinstall appears to leave Keyman with no hook and no recovery path. The
  watchdog hypothesis was not supported as *the* cause of the wedge, but this is a
  separate robustness defect that would produce "Keyman active, nothing works at
  all" — which matches the field description better than the stuck-modifier wedge
  does. Verify by forcing a reinstall failure.

- [ ] **I10 — The dropped `QIT_VKEYUP`: a stuck LETTER or NUMBER key.**
  Raised 2026-08-24 by "can a letter/number get stuck?". Written up in
  `MODIFIERS.md` §2a. Cache A provably cannot do it — `do_keybd_event` has four
  call sites, all in `keybd_shift.cpp`, all emitting `modifiers[6]` or the prefix
  VK. But `kmprocess.cpp:181-182` queues `QIT_VKEYDOWN` then `QIT_VKEYUP` for
  `_td->state.vkey` and **ignores both return values**, while `QueueAction`
  (`appint/appint.cpp:51-57`) refuses and beeps at `MAXACTIONQUEUE - 1` = 1023.
  At exactly that boundary the down lands and the up is dropped, and
  `aiWin2000Unicode.cpp:138-166` — where VKEYDOWN and VKEYUP are independent
  `case` arms with nothing pairing them — `SendInput`s an unmatched KEYDOWN for
  the key the user just pressed.
  **Why it matters:** it is the only known path to a stuck *ordinary* key, and it
  is the correct destination for any field report of one. Filing that against
  Cache A would send the fix to the wrong file.
  **Reachability is narrow and must not be overstated:** needs `IsLegacy()`, a
  `use(final)`-style default-output request, and ≥1023 queued actions from one
  keystroke. Nothing says this has happened in the field.
  **Method:** the failure is audible — `QueueAction` calls `MessageBeep` when it
  refuses. Construct a keyboard whose rule queues >1023 actions, drive it in a
  legacy app, and watch `GetAsyncKeyState` on the pressed key.
  **Fix, if confirmed:** check the first `QueueAction`'s return and skip the pair
  if it fails, or reserve two slots. One line either way.

- [ ] **I11 — `PostDummyKeyEvent` is not atomic.** `MODIFIERS.md` §5a.
  The prefix VK has two emitters. `keybd_sendprefix()` writes down+up into one
  `SendInput` batch and cannot split. `PostDummyKeyEvent()`
  (`keyman32.cpp:923-926`, called from `k32_lowlevelkeyboardhook.cpp:294` and
  `kmhook_keyboard.cpp:146`/`:195`) uses **two separate legacy `keybd_event`
  calls**. A stall between them — the same UI-thread stall this whole
  investigation is about — loses the KEYUP and latches the prefix VK.
  **Why it matters:** on a default machine that key is `0x0E`, a reserved VK no
  application maps, so it is **invisible to every text-based oracle**;
  `kmproof.ps1` could not have detected it under any circumstances.
  `GetAsyncKeyState` sees it fine.
  **Method:** `kmmods.ps1` already watches it as `ZAPVK` and never injects it, so
  any high bit there can only be Keyman's. Check the logs of any run. Currently
  **unmeasured** — nothing prevents it and nothing was looking.
  **Fix, if confirmed:** route `PostDummyKeyEvent` through the same atomic
  `SendInput` batch `keybd_sendprefix` uses.

- [ ] **I12 — What resets the accumulated latch set between runs?**
  Observed 2026-08-24, written up in `MODIFIERS.md` §2c. Within one run the held
  set grows monotonically — six arms, six additions, never a removal — even
  though the OS-level state is verifiably cleared after every trial and every
  following trial's pre-check reads `held=none`. But a run started minutes later
  begins completely clean, **with no Keyman restart**. So something resets it on
  a timescale longer than the ~5 s between trials and shorter than the couple of
  minutes between runs.
  **Why it matters:** it decides whether §2c is a real field prediction (the
  symptom compounds across a session) or a harness artefact. It also bears
  directly on **D1** — if some existing path already re-validates Cache A on a
  timer, the fix may be to make that path reliable rather than to add a new one.
  **Candidates:** an idle/timeout resync somewhere in the engine; `InitThread`
  re-seeding from `GetKeyboardState` (`serialkeyeventserver.cpp:251`) when a new
  process attaches or a thread is recycled; the focus change as PowerShell exits
  and Notepad regains focus firing `KM_FOCUSCHANGED` → `GetCapsAndNumlockState`
  (`kmhook_getmessage.cpp:357`) — note that helper resyncs **five modifiers**, not
  just the toggles (finding 4a), which would explain this exactly.
  **Status 2026-08-24: two hypotheses tested, both dead.** `kmmods.ps1 -FocusTest`
  latches LShift, clears OS state, confirms the cache still re-asserts it, then
  applies one intervention:
  - wait 30 s, foreground untouched -> **not cleared**
  - minimise + restore the target, focus verified returned -> **not cleared**
  - new process 9 s later -> **cleared**

  So it is **not a timer** and **not** the `KM_FOCUSCHANGED` ->
  `GetCapsAndNumlockState` resync, which was the neat answer and is now refuted.
  Crossing a process boundary clears it in *less* elapsed time than the wait that
  did not.

  **The sweep confound was tested and is also dead.** `-SweepTest -SweepCount N`,
  one N per process: 1 sweep -> not cleared; 2 consecutive sweeps (reproducing
  the `finally` path) -> not cleared. Both confirmed OS state `held=none` in
  between, so the sweep does its job and the next injected batch simply undoes
  it.

  **Score so far:** wait 30 s no; focus out and back no; 1 sweep no; 2 sweeps no;
  **new process 9 s later yes.** Crossing a process boundary is the only thing
  that has ever cleared this.

  **The remaining fork, and it is not cheap.** The injecting process is not the
  host — Notepad and keyman.exe both ran continuously throughout — so either
  (a) this is Keyman state scoped to something tracking the injector, which is
  surprising and is real support for **I6**, or (b) part of what is being
  observed is cleaned up by **Windows** on process exit and is not Keyman state
  at all. Separating them needs an injector that can exit while the observer
  survives; this harness cannot do that today. Options: a small standalone
  injector exe driven by the harness, or observe from a third process while the
  injector dies.

  **Do not quote (a) without (b) attached.** It is the more interesting reading
  and that is exactly why it needs the control.

- [ ] **I2 — Enumerate the real-world `E0 1D` emitters.**
  Other seed candidates from `MODIFIERS.md` §3d.2: RDP / Citrix / VNC, VM guest
  tools, PowerToys / AutoHotkey remaps, KVM switches, on-screen keyboard, and
  vendor Fn-layer drivers on laptops lacking a Right Ctrl — which is precisely
  where that key tends to get remapped. Cross-reference against the hardware in
  the field reports.

- [ ] **I3 — What actually stalls keyman.exe's UI thread in the field?**
  The repro induces the stall with `KMC_WATCHDOG_FAKEFREEZE`, a **debug-only**
  command (`UfrmKeyman7Main.pas:868`). CPU load alone (32 hogs / 16 cores) did
  **not** reproduce. So the mechanism is proven but the field path is not.
  Candidates to instrument: update-check COM calls, modal dialogs, OSK
  show/hide, Sentry init, TIP profile enumeration, font/registry enumeration.
  Until this is answered, the PR cannot say what users should avoid.

- [ ] **I4 — The one run that went from wedged to emitting nothing at all.**
  `FIX-PROPOSAL.md` records a single trial that did not recover under the
  six-modifier KEYUP sweep. Every other wedge recovered. May be a second
  contributing factor; currently unexplained and unreproduced. Re-run enough
  trials to establish whether it recurs before deciding it matters.

- [ ] **I6 — Confirm Cache A's instance scope.**
  One `ISerialKeyEventServer` per machine (started at `keyman32.cpp:398`) or one
  per host process? `GetKeyboardState` at `:251` seeds it per `InitThread`. If
  per-process, the "charge on keyboard X, fire on keyboard Y" result needs
  re-reading, because the charge and the fire may not share a cache.

- [ ] **I7 — Verify on hardware with no physical Right Ctrl.**
  `MODIFIERS.md` §3 is derived from code and is the strongest claim in the
  document. Confirm on real affected hardware: phantom RCtrl reported by
  `GetAsyncKeyState`, no physical tap clears it, Keyman restart does. Pairs with
  **H3**, which tests the same claim by injection without needing the hardware.


---

## 1a. Ruled out

Kept so they are not re-investigated. From `HANDOFF.md` §5 and this session's
work.

- **Core normalization changes in 18.0.246** — LDML keyboards only.
  `kmx_processor::supports_normalization()` returns `false`
  (`core/src/kmx/kmx_processor.hpp:83`), so KMN/KMX keyboards, i.e. essentially
  all SIL keyboards, never enter that path. Cannot cause complete input failure.
- **18.0.247, 248, 249** contain no `windows/` or `core/` changes at all.
- **The VC++ v142 -> v143 rebuild** (`d7b16aece9`, 18.0.245). Runtime linkage
  stayed `MultiThreaded` (static), so this is not a VC redist problem. New codegen
  can surface latent races, so it is a confounder, not a cause.
- **`LangSwitchManager.pas` rework** (18.0.245). An intermediate commit had a real
  bug (bare `Free` freeing `Self`) but it was fixed within the same release.
  Nothing shipped broken.
- **The original watchdog hypothesis** — that `LowLevelHookWatchDog` (18.0.245,
  `83251358b0`) tears out and reinstalls the hook on a healthy system and loses a
  modifier KEYUP in the gap. Not supported: the ghost key was absent from every
  reproducing run. See `RESULTS-treatment-18.0.249.md` for the null result.
- **Win, Apps, Fn, Scroll Lock and Insert as stuck-modifier candidates** — see
  `MODIFIERS.md` §2. Absent from `isModifierKey()` and from the `modifiers[6]`
  arrays; Fn never reaches Windows as a virtual key.

### Version timeline

| version | date | Windows engine change |
|---|---|---|
| 18.0.235 | 2025-04-23 | first stable |
| 18.0.239 | 2025-08-21 | update-check rework (kmshell only) |
| 18.0.242 | 2025-09-29 | locale-name caching; MSI advertised-shortcut fix |
| **18.0.245** | **2025-11-28** | **`LowLevelHookWatchDog` + all C++ rebuilt v142 -> v143** |
| 18.0.246 | 2026-02-04 | core normalization (LDML only) |
| 18.0.247-249 | Mar 2026 | nothing in `windows/` or `core/` |

Anyone upgrading from <= 18.0.244 to 18.0.249 gets the watchdog for the first
time — which is what made it the initial suspect.

---

## 2. Fixes for PR #16423 (Cache B — un-read state)

Same class as the Caps Lock fix already on that branch: stop trusting cached
lock/modifier state, re-derive it from the OS. `MODIFIERS.md` §4.

- [ ] **F1 — Resync all seven flags on keyboard switch, not two.** (finding 4a)
  `aiTIP.cpp:186-189` fires `RefreshToggleState()` (Caps + Num only), leaving
  `K_SHIFTFLAG`, `LCTRLFLAG`, `RCTRLFLAG`, `LALTFLAG`, `RALTFLAG` stale across a
  keyboard switch. `GetCapsAndNumlockState()` (`kmhook_getmessage.cpp:418`)
  already does all seven, but is reachable only from `KM_FOCUSCHANGED` (`:357`).
  Sub-steps:
  - [ ] Add a header declaration — it currently has **none**, only a file-local
        forward decl at `kmhook_getmessage.cpp:71`. Natural home is `capsstate.h`
        beside `RefreshToggleState`.
  - [ ] Call it from the `FToggleStateRefreshRequired` branch.
  - [ ] Decide whether the focus-change and keyboard-switch paths should share one
        helper or keep the toggle-only variant for other callers.

- [ ] **F2 — Use `GetAsyncKeyState` for the modifier half.** (finding 4b)
  `kmhook_getmessage.cpp:423-436` tests the five modifiers with
  `GetKeyState(...) < 0`, which reports the calling thread's *processed input
  queue* — exactly what is stale after dropped events. Switch those five to
  `GetAsyncKeyState`. **Leave the `& 1` toggle reads on `GetKeyState`**; toggles
  are not queue-dependent the same way, and `GetAsyncKeyState` does not report
  toggle state at all.

- [ ] **F3 — Rename or comment `GetCapsAndNumlockState`.**
  It resyncs five modifiers as well as the two toggles. The name is why F1 was
  missed. `RefreshModifierAndToggleState` or similar; at minimum a comment.
  Cosmetic, but it is the direct cause of a real bug surviving review.

- [ ] **F4 — Put finding 4c in the PR description.**
  Not a code change. `ProcessModifierChange` (`:453-457`) gives Shift a single
  `K_SHIFTFLAG` while Ctrl and Alt get independent L/R flags, so a left-side
  release cannot clear a right-side latch. This explains *why* users report RAlt
  and Right Ctrl rather than the left-hand keys, and is useful context for
  reviewers even though nothing needs fixing.

- [ ] **F5 — Decide whether F1/F2 belong in #16423 or a follow-up.**
  They are the same shape as the Caps fix and touch adjacent lines, which argues
  for one PR. Against: #16423 is scoped to Caps Lock and already has review
  history. Ask the reviewer rather than deciding unilaterally.

---

## 3. Deferred — Cache A fixes in Keyman code

`[-]` throughout: **not being implemented yet**, by explicit direction. Kept here
so the proposal is ready when it is wanted. Detail in `FIX-PROPOSAL.md`.

- [-] **D1 — Re-validate Cache A from the OS at batch start.** The real fix.
  In `PrepareInjectedInput()` (`serialkeyeventserver.cpp:384-400`), before the
  first `keybd_shift()`, refresh the six modifier bytes and let the OS win.
  Constraints already established: resync **only** at batch start, before
  Keyman's own synthetic events; prefer `GetAsyncKeyState` over
  `GetKeyboardState`; ignore events carrying `SCAN_FLAG_KEYMAN_KEY_EVENT` /
  `EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT`. Should share a helper with the
  Caps resync in #16423 rather than duplicating it.

- [-] **D2 — Move the LL hook off the UI thread.** The structural fix.
  `keyman32.cpp:279` installs `WH_KEYBOARD_LL` against keyman.exe's Delphi main
  thread (`:368`), so every keystroke on the machine is gated on a thread that
  also runs dialogs, COM and the updater. The serializer already owns a dedicated
  pump thread (`serialkeyeventserver.cpp:90`); the hook should follow the same
  pattern. Until it does, no downstream repair fully covers the drop.

- [-] **D3 — Watch modifier sanity, not just hook liveness.**
  `LowLevelHookWatchDog` checks whether the hook looks alive. Add an idle
  invariant: any cached modifier at `0x80` while `GetAsyncKeyState` says up gets
  cleared. Self-healing, no user action.

- [-] **D4 — Make the phantom re-press non-silent.**
  `keybd_shift_reset()` emitting an unmatched KEYDOWN is intentional for a
  genuinely-held modifier and indistinguishable from asserting a stale one. Gate
  it on a fresh OS check and log the disagreement — that disagreement *is* the
  bug, and nothing reports it today.

- [-] **D5 — Do NOT gate the `:198` modifier post on `isKeymanKeyboardActive`.**
  Recorded as a decision, not a task. Per the comment at `:193` (#7337) the post
  exists to keep the serialized queue in sync across keystrokes Keyman does not
  otherwise process. Suppressing it trades this bug for a different desync. D1
  handles the case instead, by correcting the cache immediately before use.

- [-] **D6 — Cherry-pick the hook-reinstall telemetry.**
  `930ae121c4` (Sentry event on hook reinstall) is master-only; stable-18 is
  blind. Extend it to report cache/OS modifier disagreement, not just reinstalls.

---

## 4. Harness work

- [x] **H1 — Add L/R Ctrl arms.** Done in `kmmods.ps1`, which inverts kmproof's
  axis: the keyboard is the constant and the **key** is the variable. All six
  Cache A slots are stimulus targets, and Insert / Win / Apps / NumLock /
  CapsLock / ScrollLock run as **negative controls** under the identical
  stimulus, so `MODIFIERS.md` §2 stops being inference. **Not yet run** — see
  **T9**.

- [x] **H2 — A Ctrl-capable oracle.** Done. `kmmods.ps1` carries a
  **state oracle**: `GetAsyncKeyState` across all 17 watched VKs plus the three
  aggregates, taken while the harness holds nothing, so any high bit is a
  phantom by definition. It names *which* key is stuck, is identical for every
  key, and cannot be fooled by accelerators, menus or swallowed keys. The text
  oracle is kept but demoted to second, and only runs when the state oracle says
  typing is safe.
  Crossing the two is the actual payoff — it splits four states the old harness
  scored identically: `PHANTOM:<mod>` (Cache A, real OS key state),
  `CACHEB-SHIFT` (uppercase text but nothing held — the #16423 class),
  `SWALLOWED` (no text, nothing held) and `CLEAN`.
  Probe alphabet changed from kmproof's `abc` to **`jkq`**: current Notepad binds
  Ctrl+B/I/U to bold/italic/underline and Ctrl+A/C to select-all/copy, so `abc`
  is no longer safe to type with a possible Ctrl latch. `j`, `k`, `q` are bound
  to nothing under Ctrl or Alt.

- [x] **H3 — Missing-key permanence arm.** Done: `kmmods.ps1 -Latch <MOD>`.
  Latches the key by injection using the exact byte pattern
  `do_keybd_event` produces (`keybd_shift.cpp:69-73` rewrites `VK_RCONTROL` to
  `VK_CONTROL` + `KEYEVENTF_EXTENDEDKEY`), then tries each clearing action in
  turn — ordinary typing, a tap of the **other side**, then the exact matching
  KEYUP — and reports which one worked. The sibling-tap step is the crux: if
  tapping LCtrl clears a latched RCtrl, the "no physical Right Ctrl" story in
  §3b collapses, because every keyboard has a Left Ctrl. Pairs with **I7**.
  **Not yet run** — see **T9**.

- [ ] **H4 — Propagate the known harness traps to the older scripts.**
  Per `TRIGGER.md`: `kmhunt.ps1`, `kmrepro.ps1` and `kmflex.ps1` still resolve the
  HKL from the top-level window (stale — must use `GetGUIThreadInfo(0).hwndFocus`)
  and still use `Write-Host` (measured 4301 ms/line on a congested console, which
  can silently let a 5 s freeze expire and turn a trial into a no-freeze
  control). `kmproof.ps1` and `kmmods.ps1` are correct on both counts. **Any
  number quoted from the other three is suspect until this is done.**

- [x] **H6 — Right Shift extended flag. RAISED, THEN DISPROVED.**
  `kmproof.ps1:288` had `@{V=0xA1;E=$true; L='RShift'}`. Right Shift is scan
  `0x36` and is not extended, so the entry was wrong on its face; it is now
  `E=$false`. Changed for form only.

  **The consequence originally claimed here was WRONG and is retracted.** This
  entry said `ClearMods` had never released RShift, that the six-modifier sweep
  was really five keys, and that **I4** needed re-running because of it. None of
  that holds.

  Measured at the wire with `kmaltgr.ps1`, 2026-08-25: injecting `VK_RSHIFT`
  with the extended flag and without it produces byte-identical events at a
  `WH_KEYBOARD_LL` hook — both `RSHIFT scan=0x36 EXT|INJ`. Windows resolves the
  side from the side-specific **virtual key** (`0xA1`); the scan code and
  extended flag are ignored on this path, and it reports `LLKHF_EXTENDED` for
  Right Shift either way. Every sweep this repo has ever run was six keys.

  **I4 is therefore unaffected** and needs no re-run on this account.

  Worth keeping for the mechanism it exposed: the extended bit *does* decide the
  side when the caller passes the **generic** VK. Keyman's `do_keybd_event`
  (`keybd_shift.cpp:63-88`) collapses the side-specific VKs to `VK_SHIFT` /
  `VK_CONTROL` / `VK_MENU`, leaving the scan code and extended bit as the only
  discriminators — which is why it sets `scan = SCANCODE_RSHIFT` explicitly for
  Right Shift, and why its bare `0xFF` for Ctrl and Alt is worth asking about
  (`MODIFIERS.md` s2b).

- [ ] **H5 — Diagnostic script for affected machines.** One pass collecting:
  `Zap Virtual Key Code` (both registry hives), `LowLevelHooksTimeout`,
  async + sync + toggle state for all 17 relevant VKs, focus-thread HKL, Keyman
  version, and whether the machine has a physical Right Ctrl.
  **Mostly done by `kmmods.ps1 -CatalogOnly`**, which needs no Notepad and
  injects nothing: it prints the full key catalog with each scan code checked
  against `MapVirtualKey`, the resolved prefix VK and where it came from, and a
  live async + toggle snapshot. Still missing: `LowLevelHooksTimeout`, the Keyman
  version from the registry, and the physical-Right-Ctrl question.

---

## 5. Final testing

Gates before either defect is called done.

**For PR #16423 (F1, F2):**

- [ ] **T1 — Keyboard-switch resync, live.** Set each of Caps, Num, Shift,
  LCtrl, RCtrl, LAlt, RAlt stale while another keyboard is active, switch to the
  Keyman keyboard, confirm all seven flags resync on the first key event. Seven
  arms; pre-fix expect Caps and Num to pass and the other five to fail.
- [ ] **T2 — AltGr regression.** The `TF_MOD_RALT|TF_MOD_LCONTROL` special case
  at `aiTIP.cpp:467` is the most likely thing F1/F2 breaks. Every AltGr character
  on `sil_cameroon_qwerty` must still produce the same codepoints. Use the
  measured baseline in `TRIGGER.md` §3 (`;e` + RAlt+N -> U+0259 U+014B).
- [ ] **T3 — Deadkey and multi-key rule regression.** Resyncing modifier state
  mid-sequence could disturb rule matching across a deadkey. Exercise the
  keyboard's deadkeys and any multi-keystroke rules.
- [ ] **T4 — Cost of `GetAsyncKeyState` on the key path.** F2 adds five calls per
  key event on a path that is already the thing that stalls. Measure; it should be
  negligible, but "should be" is not a measurement on this code path.
- [ ] **T5 — 64-bit host apps.** Blocked on **I5**. Verify in a 64-bit host
  (FieldWorks) as well as a 32-bit one, and in a UWP app — `ProcessModifierChange`
  exists in duplicate precisely because the GetMessage hook and TSF paths do not
  both fire everywhere (`kmhook_getmessage.cpp:444-449`).

**For the scope question (`kmmods.ps1`, H1-H3):**

- [x] **T9 — Run it.** Done 2026-08-24. Results in `MODIFIERS.md` §2b and §3b.
  - Ctrl arm, 5 passes: **LCTRL 5/5, RCTRL 5/5**.
  - Full matrix, controls first from a clean cache, 2 passes: all six Cache A
    slots **2/2 self-latched**; Insert / NumLock / CapsLock / ScrollLock
    **0/2**, never appearing in the held list at all.
  - `-Latch RCTRL`: cleared **only** by the exact matching KEYUP. Not by typing,
    not by tapping Left Ctrl.
  Caveats carried forward: run was at `-LoadThreads 0` (the freeze stimulus alone
  was sufficient — no load needed), only candidate `I` was exercised, and
  candidate `A` (the no-freeze internal control) has **not** been run here, so
  this run cannot by itself say the freeze is the mechanism. See **T10**.

- [x] **T10 — Candidate A on the modifier matrix.** Done 2026-08-24: **0/20**
  across all ten keys, every trial `CLEAN`, including the six that latch 2/2
  under candidate `I`. The freeze is the mechanism for all six, not just LShift
  by inheritance from `kmproof.ps1`. Also worth recording: every latch in this
  session was obtained at `-LoadThreads 0`, so the confirmed freeze alone is
  sufficient and no CPU load is required.

**For the Cache A work, whenever it is taken up:**

- [ ] **T6 — Re-run the three-arm proof with Ctrl included.** US / MSKLC / Keyman,
  same stimulus and load, now covering all six modifiers rather than LShift and
  RAlt. Blocked on H1 + H2.
- [ ] **T7 — Confirm self-healing.** Post-fix, a latched modifier must clear on
  the next injected batch rather than persisting. Includes the missing-key case
  (H3), which is the one that cannot heal today.
- [ ] **T8 — Blast-radius recheck.** Post-fix, verify US and MSKLC layouts no
  longer produce capitals with no trigger applied to them, and that Ctrl+A is no
  longer delivered as Ctrl+Shift+A system-wide.

---

## 6. Suggested order

1. **I1** and **I5** first — both change what the rest of this list should say.
   I1 sets the severity of the Right Ctrl finding; I5 sets the coverage claims.
2. **H4** next, and before quoting any further numbers. Three of four scripts
   carry two known-bad patterns.
3. **F1 / F2 / F3** — self-contained, reviewable, and independent of the Cache A
   question. Gate on **T1-T5**. Settle **F5** with the reviewer before opening.
4. ~~**H2 -> H1 -> H3**~~ (built as `kmmods.ps1`), ~~**T9**~~ and ~~**T10**~~ are
   done, all 2026-08-24. **I12** has had four hypotheses killed and is down to
   one fork that needs a separate injector process to resolve — no longer cheap,
   so weigh it against **I1**, which is cheap and higher-value. Then **I7** if
   affected hardware can be found.
5. **I2 / I3 / I4 / I6 / I8 / I9 / I10 / I11 / I12** as the remaining open
   questions.
   **I3** is the one that blocks a complete field story for the Cache A PR.
   **I8** is the one most likely to turn out to be a co-factor rather than a dead
   end, since it independently explains the post-update clustering. **I10** and
   **I11** are cheap to check and both are *different defects* that would
   otherwise be misfiled as this one — I11 costs nothing at all, since every
   `kmmods.ps1` run already collects the evidence. **H6 is closed and was a false
   alarm** — I4 does *not* need re-running on its account, contrary to what this
   list said earlier.
6. **D1-D6** only when the Cache A work is picked up. **D1** should land as a
   shared helper with #16423's resync, not as a second independent patch.

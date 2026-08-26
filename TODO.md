# TODO — stuck modifier (Cache A, #8064)

Working list for the **stuck-modifier / phantom-keypress** defect (Cache A),
upstream [#8064]. The Caps Lock / un-read-state defect (Cache B, #16422/#16423)
shares the staleness shape but is a different bug and now lives in
[`capslock/`](capslock/README.md). See `MODIFIERS.md` §1 for the split.

**Status legend:** `[ ]` open `[~]` in progress `[x]` done `[-]` deferred by
decision (not forgotten)

**Upstream:** [#8064] (rc-swag/Ross, open since 2023-01-23, milestone 20.0) — see
`README.md` "Upstream issue" and `MEETING-PREP.md`. **Not being fixed in Keyman
code yet**, explicit direction 2026-08-23. Port plan: `TEST-PLAN.md`, whose **P**
(port), **X** (cross-platform) and **T11-T13** (gates) series continue this list
and are not repeated here.

Code refs are `windows/src/engine/keyman32/` at `a70538106c` unless noted.

---

## 1. Investigations

Ordered by value-per-hour. I1 and I5 change what the other sections should say,
so they come first.

- [~] **I1 — Does the AltGr-synthesized Ctrl ever carry the extended bit?**
  ***ANSWERED NO on this machine, all three arms, physical where it matters —
  2026-08-25. Only affected field hardware still owed.***
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

  **Built: `kmaltgr.ps1`.** One incidental result from the injected `-Arms` pass
  worth keeping on its own: **injection does trigger the layout's AltGr
  synthesis.** It was not obvious it would — the synthesis is a layout behaviour,
  not an application one — but it does, and `scan=0x21D` identifies the fake
  positively. That is what made `-Arms` usable as a proxy at all.

  **PHYSICAL TEST DONE ON ALL THREE ARMS OF THIS MACHINE, 2026-08-25.**
  Written up in `MODIFIERS.md` §3d-measured. **The answer is NO.**

  | arm | input | synthetic Ctrl? | side | extended? | n |
  |---|---|---|---|---|---|
  | Keyman TIP | **physical** | **none at all** | — | — | 20 presses |
  | MSKLC (`0x0436`) | **physical** | **yes**, `scan=0x21D` | **LEFT** | **no** | 22 presses |
  | MSKLC | injected | yes, `scan=0x21D` | LEFT | no | `-Arms` |
  | US | injected | none | — | — | `-Arms` |

  **MSKLC is the arm that decides it**, being the only one whose layout sets
  `KLLF_ALTGR`. All 22 physical presses paired with a non-extended LEFT Ctrl,
  14.5–17.1 ms ahead of the RAlt, and 44/44 Ctrl events carried `scan=0x21D` —
  Windows' own marker for the fake, so this is positive identification rather
  than a nearby Ctrl coincidence. Analysis 3: no E0-prefixed Ctrl from any source.
  The physical result is identical to the injected one, which retroactively
  justifies `-Arms` as a cheap proxy on this path.

  **Keyman arm produced no Ctrl at all** — not extended, not non-extended. The
  synthesis belongs to the *layout* (`KBDTABLES` with `KLLF_ALTGR`) and the TIP
  sits on a US base layout that does not set it, so there is nothing to observe.
  Stronger than "non-extended, therefore merely clearable".

  Two incidental results, both kept in `MODIFIERS.md`:
  - **The serializer only engages on a Keyman keyboard.** Keyman arm doubled every
    keystroke with a `KM-SERIALIZED` replay; MSKLC arm produced zero across 102
    events. Must be held alongside the separately-measured "wedge is charged while
    a non-Keyman keyboard is active" (3/3) — both true, not in conflict, but
    "Keyman is inert on other layouts" is the wrong conclusion to draw.
  - **This machine has no physical Right Ctrl key** (confirmed by the user
    2026-08-25; the seven captured Ctrl taps were all `LCTRL scan=0x1D`). So the
    dev machine is a member of the §3 hardware class, and §3b's "the workaround is
    unavailable" is a direct observation here, not an extrapolation.

  **STILL OPEN — one thing, and it is the only thing that decides severity:**
  **affected field hardware.** A vendor Fn-layer driver emitting `E0 1D` on a
  laptop with no Right Ctrl key is where an extended seed would come from, and
  nothing measurable on this machine touches it. Everything local is now done.

  **Deliberately NOT doing:** the US arm physically (not an AltGr layout, not a
  configuration any Cameroon user runs, injected `-Arms` already shows no
  synthesis); and a physical Right Ctrl via external keyboard, because
  `kmmods.ps1` injects with `dwExtraInfo = 0` and a real `scan=0x1D`, so the
  filter at `k32_lowlevelkeyboardhook.cpp:233` cannot distinguish it from
  hardware and `LLKHF_INJECTED` is never consulted — a positive control on a path
  with no branch in it.

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
  An independent candidate mechanism that no other doc carries.
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
  `InitLowLevelHook()` is not retried on failure, so a
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
  `aiWin2000Unicode.cpp:138-172` — where VKEYDOWN (`:138`) and VKEYUP (`:168`) are independent
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
  any high bit there can only be Keyman's. Check the logs of any run.

  **MEASURED — the latch is real, 1/116 trials, 2026-08-24.** The logs already
  held the answer; nothing new had to be run. Sweeping all `mods-*.txt` for a
  `ZAPVK` inside a `held=` set returns exactly one hit in 116 trial lines:

  ```
  14:19:20.739  RALT  p1 [I] PREFIX-LATCH:ZAPVK
     held=LSHIFT,RSHIFT,LCTRL,RCTRL,LALT,RALT+ZAPVK  text=EMPTY  <empty>
  ```

  So the prefix VK **does** latch. It is no longer a code-derived hypothesis, and
  the "invisible to every text oracle" claim is confirmed in the same line —
  `text=EMPTY`, and `kmproof.ps1` would have had nothing to look at.

  **Mechanism hint worth chasing:** the one hit co-occurred with the *fully
  accumulated* six-modifier latch set from §2c, i.e. late in a run after the most
  injection had happened. More batches means more chances for a non-atomic
  down/up pair to be split by a stall, which is exactly what `PostDummyKeyEvent`
  predicts and what `keybd_sendprefix` cannot do.

  **Still open — which emitter did it.** 1/116 does not distinguish them, and
  `MODIFIERS.md` §2a-wire's `kmaltgr.ps1` capture saw *every* prefix KEYDOWN
  matched by a KEYUP, so that run caught the atomic path only. Resolving it needs
  a wire capture running during a trial that actually latches — i.e. `kmaltgr.ps1`
  alongside `kmmods.ps1` for long enough to hit the ~1% event, with the `0xFF` /
  `dwExtraInfo` markers distinguishing the two emitters.
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

- [ ] **I13 — does `fakefreeze.exe` reproduce on a clean VM?** The direct test of
  the non-repro question. `windows/src/support/fakefreeze/` posts the same
  `KMC_WATCHDOG_FAKEFREEZE` this harness posts, and the handler
  (`UfrmKeyman7Main.pas:868`) is an ungated `Sleep(5000)` — no debug flag, no
  special build. **It has no `build.sh`**, so `./windows/build.sh` never produces
  it (`TEST-PLAN.md` P0). A null result here means something else differs and is
  worth knowing.

- [ ] **I14 — which emitter latched the prefix VK?** I11 measured it 1/116, but
  `kmaltgr.ps1`'s wire capture saw every prefix KEYDOWN matched by a KEYUP, so
  that run caught only the **atomic** path (`keybd_sendprefix`,
  `keybd_shift.cpp:112-118`, one `SendInput`). `PostDummyKeyEvent`
  (`keyman32.cpp:923-926`) uses two separate `keybd_event` calls and is **not**
  atomic; it is called from `k32_lowlevelkeyboardhook.cpp:294`,
  `kmhook_keyboard.cpp:146` and `:195`.

- [ ] **I15 — does Ross's focus-change observation answer I3?** His notes
  (`issue-8064/ross-observations-2025-11-27.txt`) list three co-occurring events:
  a modifier pressed, a backspace pressed, and **application focus changed**.
  Backspace forces an injected batch, i.e. the *emission* step. A focus change is
  a plausible **stall source** — which is exactly I3, the gap this repo could not
  close. If it holds, the field story completes without the debug-only stimulus.

## 1a. Ruled out

Kept so they are not re-investigated.

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
  modifier KEYUP in the gap. Not supported: every reproduction in this repo was
  obtained with the reinstall never provoked at all — the freeze alone is
  sufficient (`kmproof.ps1` 3/3 candidate I, 10/10 sweep; `kmmods.ps1` six slots
  2/2).
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

## 2. Fixes for the Caps Lock / un-read-state bug (Cache B)

**Moved to [`capslock/TODO.md`](capslock/TODO.md).** Separate defect, separate
issues (#16422 / #16423), separate branch. Items **F1-F5** and gates **T1-T5**
live there.

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
  stimulus, so `MODIFIERS.md` §2 stops being inference. **Run 2026-08-24** — see
  **T9** and `MODIFIERS.md` §2b.

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

- [x] **H3 — Missing-key permanence arm.** Done: `kmmods.ps1 -Latch <MOD>`, run
  2026-08-24 (**T9**).
  Latches the key by injecting an unmatched `VK_CONTROL` + `KEYEVENTF_EXTENDEDKEY`
  — the same VK and flag `do_keybd_event` uses for `VK_RCONTROL`
  (`keybd_shift.cpp:68-72`), but with the **real scan `0x1D`**, not Keyman's
  `SCAN_FLAG_KEYMAN_KEY_EVENT` (`0xFF`). That is deliberate: `0x1D` keeps the
  injection indistinguishable from hardware at the `:229-233` filter, and makes
  the result a statement about the *general* seed rather than about Keyman's own
  re-assertion loop (`Phantom_RCTRL.md` §5). It then tries each clearing action in
  turn — ordinary typing, a tap of the **other side**, then the exact matching
  KEYUP — and reports which one worked. The sibling-tap step is the crux: if
  tapping LCtrl clears a latched RCtrl, the "no physical Right Ctrl" story in
  §3b collapses, because every keyboard has a Left Ctrl. Pairs with **I7**.

- [x] **H4 — Propagate the known harness traps to the older scripts. CLOSED
  2026-08-25 by retiring them instead of fixing them.**
  The earlier harness scripts all resolved the HKL from the top-level window
  (stale — must use `GetGUIThreadInfo(0).hwndFocus`) and all used `Write-Host`
  (measured 4301 ms/line on a congested console, which can silently let a 5 s
  freeze expire and turn a trial into a no-freeze control).

  None had remaining unique capability. `kmproof.ps1` and `kmmods.ps1` each
  implement the freeze stimulus correctly *and* confirm the async `PostMessage`
  landed before proceeding, which none of the older ones did; the only other
  residual value was a build-version read, and that is one line:
  `(Get-Item "${env:ProgramFiles(x86)}\Keyman\Keyman Desktop\keyman.exe").VersionInfo.FileVersion`.
  The rest drove FieldWorks, which is out of scope.

  **Every number in this repo comes from `kmproof.ps1`, `kmmods.ps1` or
  `kmaltgr.ps1`.** Fixing dead scripts was never worth it; removing the ambiguity
  was.

- [x] **H6 — Right Shift extended flag. RAISED, THEN DISPROVED.**
  Measured at the wire with `kmaltgr.ps1`, 2026-08-25: injecting `VK_RSHIFT` with
  the extended flag and without it produces byte-identical events at a
  `WH_KEYBOARD_LL` hook — both `RSHIFT scan=0x36 EXT|INJ`. Windows resolves the
  side from the side-specific **virtual key** (`0xA1`); the scan code and extended
  flag are ignored on this path. The sweeps were always six keys, and **I4** is
  unaffected.

  The bit *does* decide the side when the caller passes the **generic** VK, which
  is what Keyman's `do_keybd_event` does — hence its explicit
  `scan = SCANCODE_RSHIFT` for Right Shift.
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

Gates before the stuck-modifier defect is called done. The Caps Lock / Cache B
gates live in [`capslock/TODO.md`](capslock/TODO.md).

**For the Caps Lock / Cache B defect (F1, F2):** gates **T1-T5** moved to
[`capslock/TODO.md`](capslock/TODO.md).

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

1. **I5** sets the coverage claims for everything else in this list, and today it
   is inference rather than measurement. Do it first — it decides what the rest
   may claim.
2. **F1 / F2 / F3** — self-contained, reviewable, and independent of the Cache A
   question. Gate on **T1-T5**. Settle **F5** with the reviewer before opening.
3. **I12** is down to one fork that needs a separate injector process to resolve —
   no longer cheap, so weigh it against **I7**, which needs affected hardware to be
   found first.
4. Quote numbers from `kmproof.ps1`, `kmmods.ps1` and `kmaltgr.ps1` only.
5. **I2 / I3 / I4 / I6 / I8 / I9 / I10 / I11** as the remaining open
   questions.
   **I3** is the one that blocks a complete field story for the Cache A PR.
   **I8** is the one most likely to turn out to be a co-factor rather than a dead
   end, since it independently explains the post-update clustering. **I10** and
   **I11** are cheap to check and both are *different defects* that would
   otherwise be misfiled as this one — I11 costs nothing at all, since every
   `kmmods.ps1` run already collects the evidence. **H6 is closed** — I4 does
   *not* need re-running on its account.
6. **D1-D6** only when the Cache A work is picked up. **D1** should land as a
   shared helper with #16423's resync, not as a second independent patch.

[#8064]: https://github.com/keymanapp/keyman/issues/8064

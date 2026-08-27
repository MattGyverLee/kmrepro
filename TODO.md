# TODO — stuck modifier (Cache A, #8064)

Working list for the **stuck-modifier / phantom-keypress** defect (Cache A),
upstream [#8064]. The Caps Lock / un-read-state defect (Cache B, #16422/#16423)
shares the staleness shape but is a different bug and now lives in
[`capslock/`](capslock/README.md). See `MODIFIERS.md` §1 for the split.

**Status legend:** `[ ]` open `[~]` in progress `[x]` done `[-]` deferred by
decision (not forgotten)

**Upstream:** [#8064] (rc-swag/Ross, open since 2023-01-23, milestone 20.0) — see
`README.md` "Upstream issue" and `MEETING-PREP.md`. ~~**Not being fixed in Keyman
code yet**, explicit direction 2026-08-23.~~ **Superseded by direction 2026-08-26:
the Cache A fix was to be written, tested and made minimal, and it has been** —
**D1** is done and committed. Compiled, executed, committed evidence is in
[`IN-TREE.md`](IN-TREE.md); it is the source of truth wherever this file and it
disagree. Port plan: `TEST-PLAN.md`, whose **P** (port), **X** (cross-platform)
and **T11-T13** (gates) series continue this list and are not repeated here —
except for the two whose standing changed on 2026-08-26, recorded in §5a.

Code refs are `windows/src/engine/keyman32/` at `a70538106c` unless noted. The
in-tree work sits on `fix/windows/8064-reconcile-modifier-cache` in the companion
checkout, based on upstream `origin/master` @ `deeff0456f`. **Every code claim in
this repo was re-checked against that base on 2026-08-26 and all of them held**
([`IN-TREE.md`](IN-TREE.md) §3); the corrections that section adds are folded in
below, item by item.

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
  filter at `k32_lowlevelkeyboardhook.cpp:229-240` cannot distinguish it from
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
  **STILL OPEN, AND THE D1 LANDING DID NOT TOUCH IT — 2026-08-26.** Do not read
  the landing as an answer. `ReconcileModifierCache` is architecture-neutral and
  is unit-tested on both architectures (`test:x86` 19/19, `test:x64` 18/18), and
  both engine DLLs link clean — but its *call site* is inside `#ifndef _WIN64` by
  construction, exactly as the server is, so the fix inherits this question
  rather than settling it ([`IN-TREE.md`](IN-TREE.md) §6).

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

  **Citation re-checked 2026-08-26 against `fix/windows/8064-reconcile-modifier-cache`
  and still true, unchanged.** `PostDummyKeyEvent` is `keyman32.cpp:923-926`, with
  the two separate `keybd_event` calls at `:924` (down) and `:925` (up) and
  nothing between them; the three call sites are still
  `k32_lowlevelkeyboardhook.cpp:294`, `kmhook_keyboard.cpp:146` and `:195`.
  Untouched by the D1 landing, which changes nothing on this path.

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
  **STILL OPEN, AND THE D1 LANDING DID NOT TOUCH IT — 2026-08-26.** The fix makes
  the *consequence* of the stall harmless; it does not explain the cause, and the
  PR still cannot tell a user what to avoid ([`IN-TREE.md`](IN-TREE.md) §6).
  **I15** — Ross's focus-change observation — is still the best lead.

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
  special build. ~~**It has no `build.sh`**, so `./windows/build.sh` never produces
  it (`TEST-PLAN.md` P0).~~ **That blocker is gone as of 2026-08-26:** commit
  `bbb22576c2` (cited elsewhere in this repo as `5274fec612`, a hash rebased away
  from `HEAD` — see [`IN-TREE.md`](IN-TREE.md) §2) adds `support/fakefreeze/build.sh` and registers `:fakefreeze` in
  `support/build.sh`, so `./windows/build.sh` reaches it; built and verified x86
  and x64 ([`IN-TREE.md`](IN-TREE.md) §5). The investigation itself — does it
  reproduce on a clean VM — is **still open**. A null result here means something
  else differs and is worth knowing.

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

- [x] **I16 — Cache A is fed by Keyman's *own* synthetic modifier events.
  ESTABLISHED FROM CODE 2026-08-26** ([`IN-TREE.md`](IN-TREE.md) §3 C-10). Nothing
  in this repo noted it before, and it matters twice. The modifier post at
  `k32_lowlevelkeyboardhook.cpp:198` fires on `isModifierKey(vkCode)` alone and
  does **not** exclude Keyman's own injected events, because the
  `SCAN_FLAG_KEYMAN_KEY_EVENT` pass-through is 31 lines further down (`:229-240`).
  So on every output batch `keybd_shift_release`'s KEYUP drives the cache byte to
  `0` and `keybd_shift_reset`'s KEYDOWN drives it back to `0x80` — the closed loop
  `MODIFIERS.md` §3c describes, now stated as a *feed* rather than as a
  consequence. Two things follow:
  - **The fix works *with* the loop, not against it.** When D1's reconcile clears
    a stale byte, the release and reset halves emit *nothing*, so no feedback
    messages are generated and there is nothing to race. Keyman's own events
    cannot resurrect the stale byte.
  - **The mid-feedback window is pre-existing, not introduced.** The feed is a
    `PostMessage`, so a later batch can begin while the cache sits at the
    intermediate `0`, and reset then restores nothing. That is equally true
    *without* D1, since reconcile only ever clears and a byte already `0` is
    untouched. D1 adds no exposure here; the C-9 residual risk recorded under
    **D1** is the only one it does add.
  **This is also why filtering Keyman's own markers is unnecessary** for a
  `GetAsyncKeyState`-based reconcile — there is no event in that path to filter.
  See the retraction inside **D1**.

- [x] **I17 — there is a *second* unguarded emitter above the pass-through.
  ESTABLISHED FROM CODE 2026-08-26** ([`IN-TREE.md`](IN-TREE.md) §3 C-7).
  `PostVisualKeyboardModifierEvent` at `k32_lowlevelkeyboardhook.cpp:186-188` sits
  above the `!isKeymanKeyboardActive` pass-through on the **same** `isModifierKey`
  predicate as the `:198` post, and is **not even gated on
  `flag_ShouldSerializeInput`**. It feeds the on-screen keyboard, not Cache A, so
  it is **not part of #8064** and nothing here should touch it. Recorded because an
  auditor asking "what runs before the pass-through?" will find **two** things, not
  one, and needs to know which of them this bug lives in.
  The same correction fixes a count: the gap between the modifier post
  (`:198-202`) and the pass-through (`:229-240`) is **31 lines**, not the 35 that
  `MODIFIERS.md` §3c claimed. Conclusion unaffected — the post still precedes the
  filter and is not guarded by it.

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

## 3. Cache A fixes in Keyman code — D1 landed, the rest still deferred

~~`[-]` throughout: **not being implemented yet**, by explicit direction.~~ No
longer true of **D1**, which was written, compiled, tested and committed on
2026-08-26. The remaining `[-]` items keep their standing: the proposal is ready
when it is wanted. Drafts in `FIX-PROPOSAL.md`; what actually shipped, and on what
evidence, in [`IN-TREE.md`](IN-TREE.md).

- [x] **D1 — Re-validate Cache A from the OS at batch start. DONE — implemented,
  compiled, tested and committed 2026-08-26.**
  Commit `4aff8fc10e` (`fix(windows): clear cached modifiers the OS reports up
  before injecting` — reworded and its content extended by a later rebase; cited
  elsewhere in this repo as `a26aa611b5`, a hash no longer reachable from `HEAD`,
  see [`IN-TREE.md`](IN-TREE.md) §2) on branch
  `fix/windows/8064-reconcile-modifier-cache`, over
  `keymanengine.h`, `keybd_shift.cpp` and `serialkeyeventserver.cpp` plus tests.
  **64 lines of production change across 3 files, roughly 40 of them comment**: one
  typedef, one declaration, a ten-line loop, and one call. Full account, including
  the build environment it was proven in, in [`IN-TREE.md`](IN-TREE.md).
  **Gates at landing, historical:** `test:x86` 19/19, `test:x64` 18/18 (1 disabled
  each; the x86-only `isModifierKey` case correctly compiles out of the x64 run).
  **Current, 2026-08-27, after two further rounds of work:** `test:x86` **72
  pass**, `test:x64` **71 pass**, 1 disabled each — see `IN-TREE.md` §2.
  `keyman32.dll` Win32 Debug and `keyman64.dll` x64 Debug both **link clean, 0
  warnings** — which matters, because `keyman32.vcxproj` compiles with warnings as
  errors. No name collisions and no blast radius: `keymanengine.h` is included by
  exactly two files, both PCHs.
  **As shipped:** `ReconcileModifierCache(LPBYTE const kbd, PGETASYNCKEYSTATE
  pfnGetAsyncKeyState)` in `keybd_shift.cpp`, called as the **first statement** of
  `PrepareInjectedInput`, clearing any of the six slots the cache holds at `0x80`
  while `GetAsyncKeyState` reports up, and logging each disagreement with
  `SendDebugMessageFormat`. Declared above the `#ifndef _WIN64` region so both
  architectures see it.
  Two constraints this item used to carry did **not** make it into the shipped
  change, and neither omission was an oversight:
  - ~~"ignore events carrying `SCAN_FLAG_KEYMAN_KEY_EVENT` /
    `EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT`"~~ — **retracted.** That advice
    applied to a design that reads the event stream. This one reads
    `GetAsyncKeyState`, so there is no event to filter. See **I16**.
  - ~~"should share a helper with the Caps resync in #16423"~~ — **not done.**
    Shipped as a standalone helper in `keybd_shift.cpp`; #16423 is a separate
    branch. Recorded as not done rather than as refuted — the sharing is still
    worth doing when both land.
  Two properties of the landing that must not be over-claimed, both from
  [`IN-TREE.md`](IN-TREE.md) §3:
  - **The fix is preventive, not curative** (C-2). Once the first phantom KEYDOWN
    has been sent the modifier is *genuinely* held at the OS, cache and OS agree,
    and a `GetAsyncKeyState`-based reconcile can no longer detect anything. Batch
    start is therefore not merely a good placement — it is the **last point at
    which prevention is possible**. It cannot recover an already-latched process.
  - **One residual regression risk (C-9), substantially closed 2026-08-27.** As
    originally landed: if the previous batch's re-press KEYDOWN had not yet been
    reflected in `GetAsyncKeyState`, reconcile could clear a genuinely held
    modifier: one output batch emitted unshifted, re-arming on that modifier's next
    physical KEYDOWN. Self-healing, and strictly smaller than a machine-wide latch
    on a key the keyboard may not have; the window was many milliseconds and
    several thread transitions wide, and no debounce was added at the time.
    **Commit `5ba72fa3c9` closes the batch-produced instance of this** with a
    post-batch verification pass rather than a debounce — see `IN-TREE.md` §2a and
    §3 C-9. Still batch-scoped, not a continuous invariant.
  Also for the PR description rather than for a reviewer to discover (C-8):
  `GetAsyncKeyState`'s low "pressed since last query" bit is shared across
  processes, and the fix adds six reads per output batch.
  `kmhook_callwndproc.cpp:121-123` already calls it, so this is not a new
  dependency. **Gates still owed:** **T14** (ARM64) below, and **T7** / **T8**.

- [-] **D2 — Move the LL hook off the UI thread.** The structural fix.
  `keyman32.cpp:279` installs `WH_KEYBOARD_LL` against keyman.exe's Delphi main
  thread (`:368`), so every keystroke on the machine is gated on a thread that
  also runs dialogs, COM and the updater. The serializer already owns a dedicated
  pump thread (`serialkeyeventserver.cpp:90`); the hook should follow the same
  pattern. Until it does, no downstream repair fully covers the drop.
  **Standing confirmed 2026-08-26, and deliberately kept out of the D1 change**
  ([`IN-TREE.md`](IN-TREE.md) §3 C-5): `FIX-PROPOSAL.md` itself says fix 1 "should
  land first and independently", and the fix-2 draft still leaves
  `RestartLowLevelHook`, the per-thread globals and shutdown ordering unresolved.
  Separate PR.

- [-] **~~D3 — Watch modifier sanity, not just hook liveness.~~ REFUTED
  2026-08-26 — would be close to a no-op. Dropped.**
  Kept with its retraction rather than deleted. The idea was to add an idle
  invariant to `LowLevelHookWatchDog`: any cached modifier at `0x80` while
  `GetAsyncKeyState` says up gets cleared, self-healing, no user action.
  **Why it does not work** ([`IN-TREE.md`](IN-TREE.md) §3 C-3):
  `LowLevelHookWatchDog::KeyEventReceivedInGetMessageProc()` runs from the
  GetMessage hook, which is injected into **every** application's process, while
  `ISerialKeyEventServer::GetServer()` returns `sm_server` — only ever constructed
  where the server runs, i.e. keyman.exe. In every other process it is `NULL` and
  the proposed reconcile returns immediately; in keyman.exe itself the GetMessage
  hook only sees keyman.exe's own keystrokes. So it buys almost nothing while
  adding a cross-process write to a 256-byte array. `FIX-PROPOSAL.md` argued this
  was needed to catch "the case where the user stops typing into Keyman entirely";
  on this reading it does not catch that case either.

- [x] **D4 — Make the phantom re-press non-silent. DONE, subsumed by D1 as
  shipped.**
  `keybd_shift_reset()` emitting an unmatched KEYDOWN is intentional for a
  genuinely-held modifier and indistinguishable from asserting a stale one. The
  ask was to gate it on a fresh OS check and log the disagreement — that
  disagreement *is* the bug, and nothing reported it. `ReconcileModifierCache`
  does exactly both: it is the fresh OS check, placed so `keybd_shift_reset` can
  only be reached through it, and it emits
  `SendDebugMessageFormat("cache says held but OS says up, clearing vkey=%s", …)`
  per disagreeing slot. **Log-level only** — the Sentry half of this is **D6**,
  which stays out.

- [-] **D5 — Do NOT gate the `:198` modifier post on `isKeymanKeyboardActive`.**
  Recorded as a decision, not a task. Per the comment at `:193` (#7337) the post
  exists to keep the serialized queue in sync across keystrokes Keyman does not
  otherwise process. Suppressing it trades this bug for a different desync. D1
  handles the case instead, by correcting the cache immediately before use.
  **Held to, 2026-08-26.** D1 landed without touching the `:198` post, exactly as
  this decision said it should. **I16** now explains why that is the right call
  from the other direction as well: the post is the cache's *feed*, and D1 works
  with that feed rather than against it.

- [-] **D6 — Cherry-pick the hook-reinstall telemetry. OUT OF THE MINIMAL CHANGE,
  2026-08-26.** Not refuted — deferred, for three concrete reasons
  ([`IN-TREE.md`](IN-TREE.md) §3 C-4). `930ae121c4` (Sentry event on hook
  reinstall) is master-only; stable-18 is blind. Extending it to report cache/OS
  modifier disagreement means `WHR_MODIFIER_DESYNC`, and:
  1. **It needs Delphi.** `WHR_MODIFIER_DESYNC` spans `keymancontrol.h`,
     `KeymanControlMessages.pas` and `UfrmKeyman7Main.pas`. Delphi is **not
     installed** on the dev machine — `delphi_environment_generated.inc.sh` is an
     empty stub — so this could only ever have been another never-compiled draft.
  2. **It is reported *by* the dropped fix 3**, i.e. **D3**, which is refuted
     above. The reporter went away before the report did.
  3. **It needs a rate limiter first**, as `FIX-PROPOSAL.md` itself flags: a
     stranded cache could emit one Sentry event per keystroke.
  What covers the diagnostic need meanwhile: `SendDebugMessageFormat` inside
  `ReconcileModifierCache`, with no cross-language edit at all. See **D4**.

- [ ] **D7 — Correct the stale doc comment on `keybd_shift_release`.** One line,
  worth fixing in passing, found 2026-08-26 ([`IN-TREE.md`](IN-TREE.md) §3 C-11).
  `keybd_shift.cpp:129-130` describes the `kbd` parameter as the array "in which we
  will store the initial modifier state for later restoration by
  `keybd_shift_reset`". **The function never writes `kbd` — it only ever reads it.**
  Both halves read a cache owned entirely by the server. Deliberately not touched
  by the D1 commit, which was kept minimal; recorded so the next reader is not
  misled by it.

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

**For the Cache A work — taken up 2026-08-26, see D1.** T7 and T8 are the two
that D1 does not discharge: the unit tests prove the helper, not the machine.

- [ ] **T6 — Re-run the cross-keyboard proof with Ctrl included.** English / MSKLC / Keyman,
  same stimulus and load, now covering all six modifiers rather than LShift and
  RAlt. Blocked on H1 + H2.
- [ ] **T7 — Confirm self-healing.** Post-fix, a latched modifier must clear on
  the next injected batch rather than persisting. Includes the missing-key case
  (H3), which is the one that cannot heal today.
- [ ] **T8 — Blast-radius recheck.** Post-fix, verify the English and MSKLC layouts no
  longer produce capitals with no trigger applied to them, and that Ctrl+A is no
  longer delivered as Ctrl+Shift+A system-wide.

---

## 5a. Follow-ups from the 2026-08-26 landing

Three items the 2026-08-26 landing created or moved. **P1** and **S2** belong to
`TEST-PLAN.md` and are not otherwise repeated here; only their standing is, because
it changed.

- [ ] **T14 — Confirm the ARM64 leg. THE ONE UNBUILT ARCHITECTURE.**
  `keymanarm64.dll` was **not built** and the new code is therefore **unverified on
  ARM64** ([`IN-TREE.md`](IN-TREE.md) §1, §6). The reason is environmental, not
  design: there are **no ARM64 MSVC libraries on the dev machine** —
  `VC\Tools\MSVC\14.44.35207\lib\` holds only `x86`, `x64` and `onecore`, which is
  also why `build.sh configure` dies with `LNK1104: cannot open file
  'libcpmtd.lib'` and must not be run here.
  **What is expected, and it is an expectation, not a result:** `keybd_shift.cpp`
  has **no architecture guard**, and the `ReconcileModifierCache` declaration sits
  *above* the `#ifndef _WIN64` region in `keymanengine.h` so both architectures see
  it, so it **should** compile. Nothing has compiled it. **Do not write "builds on
  all three architectures" in the PR.**
  **Who can close this:** CI, or any machine with the ARM64 MSVC toolset installed.
  Until then the claim is x86 and x64 only, both measured.

- [ ] **P1 — Restore `RightAltEmulationCheck.tests.cpp` to the vcxproj.
  PROBED AND IT PASSES — 2026-08-26 — deliberately not landed.**
  `TEST-PLAN.md` risk 6 asked whether it would fail on restore. **MEASURED: it
  compiles and passes**, 20 tests / 7 cases with it enabled. So P1 is a safe
  one-line change. It was kept **off** this branch on purpose: it is unrelated to
  #8064 and belongs in its own commit, so that a future failure there is never
  read as a regression from this work ([`IN-TREE.md`](IN-TREE.md) §4).

- [ ] **S2 — Extract `NormalizeModifierVk`. Now the highest-value remaining
  test-side item.**
  `TEST-PLAN.md` **S2**, with its tests `T-S5`-`T-S7`: not done. A pure testability
  refactor that D1 does not need, which is exactly why it survived a minimal change
  ([`IN-TREE.md`](IN-TREE.md) §6) — and why it is now the highest-value item left on
  the test side: `NormalizeModifierVk` is the seam that would let Cache A's *writer*
  be tested at all.
  **One trap to carry into `T-S5`-`T-S7`, measured the hard way:** do **not** use
  `SCOPED_TRACE`. gtest 1.8.1's `ScopedTrace` pushes onto a trace-stack vector whose
  capacity is retained after the scope exits, and `gtest_main.cpp`'s
  `_CrtMemDifference` check reports that as a **168-byte leak**, failing the suite.
  It is what invalidated `T-P6` and `T-S4` **as drafted** — both had to be rewritten
  with per-assertion `<<` messages before they could land
  ([`IN-TREE.md`](IN-TREE.md) §4, risk 3).

---

## 5b. Follow-ups from the 2026-08-27 OSK verification run

One item, found while running the `MODIFIER-PRODUCERS.md` checklist against a
Delphi 12 build of `keyman.exe` on `fix/windows/8064-reconcile-modifier-cache`.
It is **not** a defect of that branch and must not be folded into it.

- [ ] **I18 — File the OSK character/modifier delivery race as its own issue.
  MEASURED 2026-08-27, NOT FILED, NOT THIS BRANCH'S BUG.**
  **Reproduction, as observed:** OSK open with nothing latched, physically hold
  Left Shift, click `c` **on the OSK**, into Notepad.
  Release Shift *immediately* after the click completes -> **lowercase `c`**.
  Release Shift *a moment later* -> **uppercase `C`**.
  Same click, same held modifier, different outcome.
  **Why it is a defect and not a timing curiosity:** the mouse has already gone
  **down and up** on the key before the release. The character is decided at that
  point, and what the Shift finger does afterwards must not be able to reach back
  and change it. The tester's own framing is the cleanest statement of it and
  should go in the issue verbatim: *"releasing the shift after click down and up
  on the c should not have an effect in the outcome."*
  **Mechanism, and this is an expectation, not a measurement:** `do_keybd_event`
  calls `keybd_event()`, which *posts* to the system input queue rather than
  delivering synchronously; the physical Shift release posts to the same queue,
  and Keyman's serial key event server additionally queues and replays injected
  batches, widening the window. If the release is processed before the `c` is
  translated, `ToUnicode` sees Shift up. **Nothing has instrumented this** --
  `KL.Log` is compiled out (`KLOGGING` is commented out at `klog.pas:26`), so the
  actual event ordering has not been observed. Do not state the mechanism as fact
  in the issue.
  **Why it is not this branch's bug:** the character injection path is textually
  unchanged by `3d64aad790` and `cd2bd44dd0` -- `do_keybd_event(vk, scan, 0, 0)`
  and its KEYUP are untouched. In this scenario `PrepState` and `FinalState` are
  both no-ops anyway, because the 50 ms `tmrCheckTimer` resync has already put
  `essShift` into `kbd.ShiftState`, so `fkcss` and `ass` both contain it and
  neither branch fires. Confirmed by inspection only.
  **Cheapest way to close the pre-existing question empirically:** swap back the
  release binary kept at
  `C:\Program Files (x86)\Common Files\Keyman\Keyman Engine\keyman.exe.bak-20260827-085104`
  and repeat the `Cc` reproduction. Identical behaviour there settles it.
  **Why it deserves priority over the other open OSK gap:** it is reachable in
  entirely ordinary use -- hold a modifier, click a key on the OSK, let go. No
  keyboard switching, no teardown, no unusual sequence, no chirality involved.

---

## 6. Suggested order

Reordered 2026-08-26; branch state re-checked 2026-08-27. The code is written; what is left is
getting it in front of people and closing the one architecture nobody has compiled.

1. **Push the branch.** `fix/windows/8064-reconcile-modifier-cache` is **still not
   usably pushed**, re-verified 2026-08-27: the local branch's upstream tracking ref
   reports **gone**, and no branch of this name is visible on the fork remote —
   consistent with an earlier push having been superseded by a later rebase that was
   never force-pushed. The branch is no longer four commits; it is 27, after a
   ten-commit follow-on, a `host32` reproduction-harness round, and four more
   commits closing residual pathways ([`IN-TREE.md`](IN-TREE.md) §2, §2a, §6).
   Nothing below can be reviewed until it is pushed.
   The first commit, `914795bf58` (cited elsewhere in this repo by its pre-rebase
   hash `204e63493b`), is landable on its own: it characterises the
   defect without proposing a fix, so it keeps its value even if **D1** is reworked
   in review.
2. **Open the PR**, leading with §2a-wire of `MODIFIERS.md` — the unmatched KEYDOWN
   caught on the wire — and carrying the four things a reviewer will otherwise find
   for themselves: **D1**'s preventive-not-curative limit (C-2), its one residual
   risk (C-9), the shared `GetAsyncKeyState` low bit (C-8), and **T14**, the unbuilt
   ARM64 leg. Do **not** claim per-keystroke re-pressing — the cadence is per queued
   output batch, and a reviewer who checks will find the stronger claim false.
   See `MODIFIERS.md` §3c.
3. **Comment on #8064.** It is **Ross's** issue, open since 2023-01-23, and it has
   not been commented on. `MEETING-PREP.md` is still the brief; that is the
   document to work from, not this list.
4. **Confirm the ARM64 leg — T14.** CI or an ARM64-toolset machine. Until it is
   confirmed, the coverage claim is x86 and x64 only.
5. **S2** (`NormalizeModifierVk`) — the highest-value remaining test-side item, and
   the only one whose absence is felt. **P1** is a safe one-line follow-up commit
   whenever it is wanted; both are in §5a.
6. **I5** still sets the coverage claims for everything in this list, and it is
   still inference rather than measurement. The landing did not answer it. It now
   ranks below the push only because the code no longer waits on it.
7. **F1 / F2 / F3** — self-contained, reviewable, and independent of the Cache A
   question. Gate on **T1-T5**. Settle **F5** with the reviewer before opening.
8. **I12** is down to one fork that needs a separate injector process to resolve —
   no longer cheap, so weigh it against **I7**, which needs affected hardware to be
   found first.
9. Quote numbers from `kmproof.ps1`, `kmmods.ps1` and `kmaltgr.ps1` only.
10. **I2 / I3 / I4 / I6 / I8 / I9 / I10 / I11** as the remaining open
    questions.
    **I3** is the one that blocks a complete field story for the Cache A PR, and
    **D1 did not close it** — the fix makes the consequence harmless without
    explaining the cause. **I15** is the cheapest attempt at it.
    **I8** is the one most likely to turn out to be a co-factor rather than a dead
    end, since it independently explains the post-update clustering. **I10** and
    **I11** are cheap to check and both are *different defects* that would
    otherwise be misfiled as this one — I11 costs nothing at all, since every
    `kmmods.ps1` run already collects the evidence. **H6 is closed** — I4 does
    *not* need re-running on its account. **I13**'s build blocker is gone
    (`bbb22576c2`), so that one is now just a matter of finding a clean VM.
11. **D2 / D6 / D7** are what is left of the D series. **D1** and **D4** are done,
    **D3** is refuted, **D5** was always a decision rather than a task. ~~**D1**
    should land as a shared helper with #16423's resync, not as a second independent
    patch.~~ It did not; it landed standalone, and the sharing is still worth doing
    when both are in.

[#8064]: https://github.com/keymanapp/keyman/issues/8064

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

- [ ] **H1 — Add L/R Ctrl arms.** Ctrl has never been exercised on either side,
  despite being the strongest field signal and the only modifier that cannot
  self-heal. **Blocked on H2** — without a working oracle a Ctrl arm reports
  false negatives.

- [ ] **H2 — A Ctrl-capable oracle.** The `abc`/`ABC` check reads **CLEAN** under
  a stuck Ctrl, because Ctrl produces no case change — it swallows keys and fires
  stray accelerators. Same false-negative shape as the case-insensitive `-eq`
  trap. Probe "did a literal `a` arrive at all", plus `GetAsyncKeyState` on all
  six modifiers inside the failing iteration.

- [ ] **H3 — Missing-key permanence arm.** Tests the distinctive claim in
  `MODIFIERS.md` §3b without special hardware: latch `VK_RCONTROL` by injection,
  then confirm no amount of physical typing clears it and only a Keyman restart
  does. This is the arm that would explain the field reports the current repro
  cannot. Pairs with **I7**.

- [ ] **H4 — Propagate the two known harness traps to the older scripts.**
  Per `TRIGGER.md`: `kmhunt.ps1`, `kmrepro.ps1` and `kmflex.ps1` still resolve the
  HKL from the top-level window (stale — must use `GetGUIThreadInfo(0).hwndFocus`)
  and still use `Write-Host` (measured 4301 ms/line on a congested console, which
  can silently let a 5 s freeze expire and turn a trial into a no-freeze
  control). Only `kmproof.ps1` is correct on both counts. **Any number quoted
  from the other three is suspect until this is done.**

- [ ] **H5 — Diagnostic script for affected machines.** One pass collecting:
  `Zap Virtual Key Code` (both registry hives), `LowLevelHooksTimeout`,
  async + sync + toggle state for all 17 relevant VKs, focus-thread HKL, Keyman
  version, and whether the machine has a physical Right Ctrl. Most of this exists
  as one-off snippets from this session; consolidate it.

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
4. **H2 -> H1 -> H3** to close the Ctrl gap in the repro, with **I7** if hardware
   can be found.
5. **I2 / I3 / I4 / I6** as the remaining open questions. **I3** is the one that
   blocks a complete field story for the Cache A PR.
6. **D1-D6** only when the Cache A work is picked up. **D1** should land as a
   shared helper with #16423's resync, not as a second independent patch.

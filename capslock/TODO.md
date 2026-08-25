# TODO — Caps Lock / un-read modifier state (Cache B)

> Split out of the parent [kmrepro](../README.md) investigation. This is a
> **different defect** from the stuck-modifier bug ([#8064]) that repo is about —
> different cache, different symptom, different fix. Keep them apart.
>
> [#8064]: https://github.com/keymanapp/keyman/issues/8064
> [#16422]: https://github.com/keymanapp/keyman/issues/16422
> [#16423]: https://github.com/keymanapp/keyman/issues/16423

**Status legend:** `[ ]` open `[~]` in progress `[x]` done `[-]` deferred by
decision (not forgotten)

**Destination:** branch `fix/windows/16422-caps-lock-state-on-keyboard-switch`,
i.e. **[#16423]**. Code refs are `windows/src/engine/keyman32/` at `a70538106c`
unless noted.

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

---

## Gates

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
- [ ] **T5 — 64-bit host apps.** Blocked on **I5**. Verify in a 64-bit host as
  well as a 32-bit one, and in a UWP app — any host will do — `ProcessModifierChange`
  exists in duplicate precisely because the GetMessage hook and TSF paths do not
  both fire everywhere (`kmhook_getmessage.cpp:444-449`).

# Caps Lock / un-read modifier state — Keyman for Windows

> Split out of the parent [kmrepro](../README.md) investigation on 2026-08-25.
> This is a **different defect** from the stuck-modifier bug ([#8064]) that repo
> exists for. Same staleness *shape*, different cache, different symptom,
> different severity, different branch. Keeping them apart is the point.

## The bug

Keyman caches modifier and lock-key state in `Globals::ShiftState()` — **Cache
B** — and does not reliably resync it from the OS. When the cached value is
wrong, rules match against the wrong shift state, so typing comes out in the
wrong case or not at all.

The trigger that surfaced it: **switch from a Microsoft keyboard to a Keyman
keyboard with Caps Lock on.** `ProcessToggleChange` only runs when Keyman
observes a Caps/NumLock keydown, so if the toggle changed while another keyboard
was active, `CAPITALFLAG` is stale.

**No key is ever physically held.** Nothing is injected. That is the whole
difference from [#8064], where Keyman re-presses a modifier for real and latches
the entire machine.

## Upstream

| | |
|---|---|
| [#16422] | `bug(windows): Caps Lock state ignored when switching from MS to KM keyboard` — **open** |
| [#16423] | `fix(windows): resync caps lock state when Keyman keyboard is activated` — **open**, labelled `user-test-required` |

Branch: `fix/windows/16422-caps-lock-state-on-keyboard-switch`, which already
carries `RefreshToggleState()` and the `_td->FToggleStateRefreshRequired`
deferred-resync flag.

## Contents

| file | what |
|---|---|
| [FINDINGS.md](FINDINGS.md) | findings **4a**, **4b**, **4c**, plus the Cache A / Cache B table |
| [TODO.md](TODO.md) | fixes **F1-F5**, gates **T1-T5** |
| [TEST-PLAN.md](TEST-PLAN.md) | the two red tests **T-R1** / **T-R2**, in Keyman's gtest format |

## The three findings, in one line each

- **4a** — a keyboard switch resyncs Caps and Num but leaves `K_SHIFTFLAG`,
  `LCTRLFLAG`, `RCTRLFLAG`, `LALTFLAG`, `RALTFLAG` stale. Same bug, same cache,
  same trigger, one field over. The naming is why it was missed: the function
  that resyncs all five modifiers is called `GetCapsAndNumlockState`.
- **4b** — both resync helpers test modifiers with `GetKeyState(...) < 0`, which
  reports the **calling thread's processed input queue** — precisely the thing
  that is stale after events were dropped. `GetAsyncKeyState` is the correct
  oracle. *(Leave the `& 1` toggle reads on `GetKeyState`; `GetAsyncKeyState`
  does not report toggle state at all.)*
- **4c** — Shift gets one flag while Ctrl and Alt get two each, so a left-side
  release cannot clear a right-side latch. Not a bug; it explains why field
  reports name RAlt and Right Ctrl. Belongs in the PR description.

## Why the two red tests live here

**T-R1** and **T-R2** are the cleanest red-to-green tests in the whole
investigation — they fail today, pass once F1/F2 land, and need no new API, no
stall, no timing, no elevation and no desktop. They live here because this is the
defect they test.

The parent repo keeps the harness description and the Cache A material. Both sets
of tests land in the same [`keyman32` gtest suite][tests].

[#8064]: https://github.com/keymanapp/keyman/issues/8064
[#16422]: https://github.com/keymanapp/keyman/issues/16422
[#16423]: https://github.com/keymanapp/keyman/issues/16423
[tests]: https://github.com/keymanapp/keyman/tree/master/windows/src/engine/keyman32/tests
